import Automation
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Draw
import Foundation

// What `canvas draw` needs from plugins it doesn't know, as tests give it: names (a tile is called
// by its label, a card by its nickname, else "Card, 100 × 60", worked out from its size), edges
// (links, with a tone, a head at each end and a caption as added properties, and what each kind may carry from
// each side), and checks (a card that says nothing, a glossy tile).

/// How the test plugins fold a title: runs of whitespace one space, trimmed; nil if blank.
@Sendable func fold(_ title: String) -> String? {
    let folded = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return folded.isEmpty ? nil : folded
}

/// Names shapes: a tile by its label, a card by its nickname (worked out from its size without
/// one), a disc by its size, a pocket by its nickname (`namedPockets`), a pen by its label. Only the
/// kinds in `nameable` can be given a title.
@MainActor func namesPlugin(nameable: Set<ShapeKind> = [Card.kind, Tile.kind, Pen.kind]) -> Contributor {
    Contributor(id: "names") { registrar in
        registrar.drawNames(name: { record, _ in
            if let tile = record.typed(as: Tile.self) { return fold(tile.props.label) }
            if let pen = record.typed(as: Pen.self) { return fold(pen.props.label) }
            if let disc = record.typed(as: Disc.self) { return "Disc, \(Int(disc.props.frame.width)) × \(Int(disc.props.frame.height))" }
            if record.kind == Pocket.kind { return fold(record[Nickname.self] ?? "") }
            guard let card = record.typed(as: Card.self) else { return nil }
            return fold(record[Nickname.self] ?? "") ?? "Card, \(Int(card.props.frame.width)) × \(Int(card.props.frame.height))"
        }, namingProperty: { kind, _ in
            guard nameable.contains(kind) else { return nil }
            return kind == Tile.kind || kind == Pen.kind ? "label" : kind == Card.kind ? Nickname.key.rawValue : nil
        }, isDerived: { kind, _ in kind == Card.kind || kind == Disc.kind }, fold: fold)
    }
}

/// The tone a link is drawn in.
enum Tone {}

extension Tone: ShapeProperty {
    static let key: PropertyKey = "tone"
    static var defaultValue: String? { nil }
}

/// Whether a link has a head at its start as well as its end.
enum BothHeads {}

extension BothHeads: ShapeProperty {
    static let key: PropertyKey = "heads"
    static var defaultValue: Bool? { nil }
}

/// What a link says: an attribute of the link's kind, not the edge maker's, so `draw` sets it.
enum Caption {}

extension Caption: ShapeProperty {
    static let key: PropertyKey = "caption"
    static var defaultValue: String? { nil }
}

/// What the edges plugin was asked to make: each request, and the connection it was to change.
@MainActor final class EdgeLog {
    var requests: [EdgeRequest] = []
    var existing: [ShapeID?] = []
}

/// Makes edges as links: a tile may carry warm from its left and warm or cool from its right, a
/// card cool from its bottom. A link can't be icy, or join a shape to itself.
@MainActor func edgesPlugin(_ log: EdgeLog = EdgeLog()) -> Contributor {
    Contributor(id: "edges") { registrar in
        registrar.declare(Tone.self)
        registrar.optIn(Link.self, to: Tone.self)
        registrar.declare(BothHeads.self)
        registrar.optIn(Link.self, to: BothHeads.self)
        registrar.declare(Caption.self)
        registrar.optIn(Link.self, to: Caption.self)
        registrar.drawEdges(kind: { _ in Link.kind }, attributes: [Tone.key.rawValue], sides: { kind, _ in
            kind == Tile.kind ? [.left: ["warm"], .right: ["warm", "cool"]] : kind == Card.kind ? [.bottom: ["cool"]] : [:]
        }, ends: { record, _ in
            guard let link = record.typed(as: Link.self), let from = link.props.from, let to = link.props.to else { return nil }
            return (from, to)
        }, make: { request, existing, shapes throws(DrawError) in
            log.requests.append(request)
            log.existing.append(existing?.id)
            let tone = request.attributes[Tone.key.rawValue]
            if tone == "icy" {
                throw DrawError("a link can't be icy", reason: "invalid_value", hint: "tone: takes warm or cool")
            }
            guard request.from != request.to else {
                throw DrawError("\(request.fromName) can't be linked to itself", reason: "cannot_connect")
            }
            guard shapes.shape(request.from) != nil, shapes.shape(request.to) != nil else {
                throw DrawError("\(request.written) names a shape that isn't there", reason: "cannot_connect")
            }
            var record = existing ?? AnyShapeRecord(ShapeRecord(Link(from: request.from, to: request.to)))
            if let tone { record[Tone.self] = tone }
            record[BothHeads.self] = request.bothHeads ? true : nil
            return record
        })
    }
}

/// Checks shapes: a card with no text says nothing (a warning), a glossy tile glares (an error).
func checksPlugin() -> Contributor {
    Contributor(id: "checks") { registrar in
        registrar.drawChecks { record, _ in
            if let card = record.typed(as: Card.self), card.props.text.isEmpty { return [DrawIssue("A card says nothing.", field: "text")] }
            if let tile = record.typed(as: Tile.self), tile.props.finish == .glossy {
                return [DrawIssue("A glossy tile glares.", isError: true, field: "finish")]
            }
            return []
        }
    }
}

/// Names and edges (and checks, if asked).
@MainActor func drawPlugins(_ log: EdgeLog = EdgeLog(), checks: Bool = false) -> [any CanvasPlugin] {
    [namesPlugin(), edgesPlugin(log)] + (checks ? [checksPlugin()] : [])
}

/// An editor with names and edges installed.
@MainActor func drawEditor(_ plugins: [any CanvasPlugin] = [], log: EdgeLog = EdgeLog(), checks: Bool = false) throws -> CanvasEditor {
    try makeEditor(drawPlugins(log, checks: checks) + plugins)
}

/// `canvas draw -`, the script on standard input.
@MainActor func draw(_ script: String, on editor: CanvasEditor, _ options: [String] = []) throws -> Result<JSON, RPCError> {
    try run(["draw", "-"] + options, on: editor, input: script)
}

/// What a draw that succeeds says.
@MainActor func drawn(_ script: String, on editor: CanvasEditor, _ options: [String] = []) throws -> JSON {
    switch try draw(script, on: editor, options) {
    case .success(let json): return json
    case .failure(let error): throw DrawFailed(error: error)
    }
}

/// Why a draw that should fail did.
@MainActor func refused(_ script: String, on editor: CanvasEditor, _ options: [String] = []) throws -> RPCError {
    switch try draw(script, on: editor, options) {
    case .success(let json): throw DrewAnyway(result: json)
    case .failure(let error): return error
    }
}

struct DrawFailed: Error, CustomStringConvertible {
    let error: RPCError
    var description: String { "the draw failed: \(error) \(error.data?.compactText ?? "")" }
}

struct DrewAnyway: Error, CustomStringConvertible {
    let result: JSON
    var description: String { "the draw should have failed, and said \(result.compactText)" }
}

/// A result's rows.
func rows(_ result: JSON) -> [JSON] { result["changes"]?.arrayValue ?? [] }

/// Rows without their `id`, which a test over fixtures can't know before the run makes the shapes.
func withoutIDs(_ rows: [JSON]) -> [JSON] {
    rows.map { row in
        guard case .object(var members) = row else { return row }
        members["id"] = nil
        return .object(members)
    }
}

/// A result's warnings' messages.
func messages(_ result: JSON) -> [String] { (result["warnings"]?.arrayValue ?? []).compactMap { $0["message"]?.stringValue } }

/// The board shape called this (a tile's label, a pen's, a card's nickname).
@MainActor func shape(_ title: String, in editor: CanvasEditor) -> AnyShapeRecord? {
    editor.document.shapes.first { $0.typed(as: Tile.self)?.props.label == title || $0.typed(as: Pen.self)?.props.label == title || $0[Nickname.self] == title }
}

/// Puts a tile on the board, labeled.
@MainActor @discardableResult func tile(_ label: String, _ frame: CGRect, in editor: CanvasEditor) -> AnyShapeRecord {
    let record = AnyShapeRecord(ShapeRecord(Tile(frame, label: label)))
    editor.transact { $0.insert(record) }
    return editor.document[record.id]!
}

/// Links two shapes directly, as a drawn edge would.
@MainActor @discardableResult func link(_ from: AnyShapeRecord, _ to: AnyShapeRecord, in editor: CanvasEditor) -> AnyShapeRecord {
    let record = AnyShapeRecord(ShapeRecord(Link(from: from.id, to: to.id)))
    editor.transact { $0.insert(record) }
    return editor.document[record.id]!
}

/// The links on the board, as (from, to) by title.
@MainActor func links(in editor: CanvasEditor) -> [String] {
    func name(_ id: ShapeID?) -> String {
        guard let record = id.flatMap({ editor.document[$0] }) else { return "?" }
        return record.typed(as: Tile.self)?.props.label ?? record[Nickname.self] ?? "?"
    }
    return editor.document.shapes.compactMap { $0.typed(as: Link.self) }.map { "\(name($0.props.from)) -> \(name($0.props.to))" }
}

/// Hub, East right of it, and AB below it: Hub (340, 290, 120, 80), East (540, 290, 120, 80), AB (350, 450, 100, 60).
let threeShapes = #"""
tile "Hub"
tile "East" right of "Hub"
card "AB" below "Hub"
"""#

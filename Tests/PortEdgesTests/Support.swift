import AppKit
import Automation
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import Connections
import CoreGraphics
import DrawLexicon
import Keyboard
import Selection
import TestKit
import Topology

// `canvas draw`'s edges as Connections' connections, over fixtures: tiles (named by their label) have
// ports on the wire, on every side; cards (named by their text) on the pipe, on their right and
// bottom, and take the wire on their left, but have no dot there. The connector draws links
// (CanvasTesting's), without a drag: it notes each request, keeps the sides a request names and
// whether it has a head at each end, and can't connect a glossy tile.

enum Wire {}
extension Wire: Channel {
    static let id: ChannelID = "wire"
    static var color: NSColor { .systemRed }
}

enum Pipe {}
extension Pipe: Channel {
    static let id: ChannelID = "pipe"
}

/// The family of connections links are, as Topology's edge type.
enum Hookup {}
extension Hookup: EdgeType {
    static let id: EdgeTypeID = "hookup"
}

/// Where a link's ends aim, as the requests that made it named them: `right`, `-` for none.
enum Aim {}
extension Aim: ShapeProperty {
    static let key: PropertyKey = "aim"
    static var defaultValue: String? { nil }
}

/// Whether a link has a head at its start too.
enum BothHeads {}
extension BothHeads: ShapeProperty {
    static let key: PropertyKey = "heads"
    static var defaultValue: Bool? { nil }
}

/// The channels, and the fixtures' ports on them (cards' only if `cards`).
@MainActor func channelsPlugin(cards: Bool = true) -> Contributor {
    Contributor(id: "channels") { registrar in
        registrar.channel(Wire.self)
        registrar.channel(Pipe.self)
        registrar.ports(Tile.self, on: Wire.self)
        if cards {
            registrar.ports(Card.self, on: Pipe.self, sides: [.right, .bottom])
            registrar.ports(Card.self, on: Wire.self, sides: [.left], role: .target)
        }
    }
}

/// What the connector was asked for.
@MainActor final class Requests {
    var made: [ConnectionRequest] = []
}

/// Draws links without a drag: from the request's first shape to its second, on its channel when
/// new (a change keeps it); the sides it names kept as `Aim` (a side it doesn't name keeps what the
/// link had), and a head at its start with `bothHeads`. A glossy tile can't be connected. With
/// `makes` false, it only draws from a port (and draws nothing).
@MainActor func linkConnector(_ requests: Requests = Requests(), makes: Bool = true) -> Contributor {
    Contributor(id: "link-connector") { registrar in
        registrar.declare(Aim.self)
        registrar.optIn(Link.self, to: Aim.self)
        registrar.declare(BothHeads.self)
        registrar.optIn(Link.self, to: BothHeads.self)
        let canConnect: @MainActor (ShapeID, ShapeContext) -> Bool = { id, shapes in
            shapes.geometry(of: id)?.isClosed == true && shapes.shape(id)?.typed(as: Tile.self)?.props.finish != .glossy
        }
        guard makes else {
            registrar.connects(Link.self, edgeType: Hookup.self, canConnect: canConnect) { _, _ in nil }
            return
        }
        registrar.connects(Link.self, edgeType: Hookup.self, canConnect: canConnect, make: { request, existing, shapes in
            requests.made.append(request)
            guard shapes.shape(request.from) != nil, shapes.shape(request.to) != nil else { return nil }
            var link = existing?.typed(as: Link.self) ?? ShapeRecord(Link())
            if existing == nil { link[ChannelProperty.self] = request.channel }
            link.props.from = request.from
            link.props.to = request.to
            let old = (link[Aim.self] ?? "- -").split(separator: " ").map(String.init)
            func word(_ side: PortSide?, _ kept: String) -> String {
                switch side {
                case .top?: "top"
                case .right?: "right"
                case .bottom?: "bottom"
                case .left?: "left"
                case nil: kept
                }
            }
            let aim = "\(word(request.fromSide, old[0])) \(word(request.toSide, old[1]))"
            link[Aim.self] = aim == "- -" ? nil : aim
            link[BothHeads.self] = request.bothHeads ? true : nil
            var made = AnyShapeRecord(link)
            if let existing { made.meta = existing.meta }
            return made
        }, ends: { record in
            guard let link = record.typed(as: Link.self)?.props, let from = link.from, let to = link.to else { return nil }
            return (from, to)
        }) { _, _ in nil }
    }
}

/// Names tiles by their label and cards by their text.
let fixtureNames = Contributor(id: "fixture-names") { registrar in
    registrar.drawNames(name: { record, _ in
        let name = record.typed(as: Tile.self)?.props.label ?? record.typed(as: Card.self)?.props.text
        return name.flatMap { $0.isEmpty ? nil : $0 }
    }, namingProperty: { kind, _ in kind == Tile.kind ? "label" : kind == Card.kind ? "text" : nil },
    isDerived: { _, _ in false },
    fold: { title in
        let folded = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return folded.isEmpty ? nil : folded
    })
}

/// An editor 800 × 600 points with the fixtures, Ports, the channels, the link connector, names
/// and `PortEdgesPlugin` (unless not).
@MainActor func edgesEditor(_ requests: Requests = Requests(), cards: Bool = true, makes: Bool = true, withPlugin: Bool = true,
                                        names: Contributor = fixtureNames) throws -> CanvasEditor {
    let plugins: [any CanvasPlugin] = [KeyboardPlugin(), SelectionPlugin(), TopologyPlugin(), AutomationPlugin(), FixturesPlugin(), CardsPlugin(), TilesPlugin(),
                                       LinksPlugin(), PortsPlugin(), channelsPlugin(cards: cards), linkConnector(requests, makes: makes),
                                       names] + (withPlugin ? [PortEdgesPlugin()] : [])
    let editor = CanvasEditor(registry: try Registry(plugins: plugins))
    editor.viewportDidResize(to: CGSize(width: 800, height: 600))
    return editor
}

/// A command, as the command line spells it, run as the app's server runs it; `input` is its
/// standard input.
@MainActor func run(_ line: [String], on editor: CanvasEditor, input: String = "") throws -> Result<JSON, RPCError> {
    let spec = try require(editor.registry.automationCommands.first { $0.name == line[0] })
    let params = try spec.params(from: Array(line.dropFirst()), standardInput: { input })
    return try awaitResult { () async -> Result<JSON, RPCError> in
        do throws(RPCError) {
            return .success(try await editor.registry.runAutomationCommand(spec.name, params: .object(params), editor: editor))
        } catch {
            return .failure(error)
        }
    }
}

/// What `canvas draw -` says of a script that runs.
@MainActor func drawn(_ script: String, on editor: CanvasEditor) throws -> JSON {
    try run(["draw", "-"], on: editor, input: script).get()
}

/// Why `canvas draw -` refused a script: its error's data (`reason`, `hint`, `line`), and its
/// `message`.
@MainActor func refused(_ script: String, on editor: CanvasEditor) throws -> JSON {
    switch try run(["draw", "-"], on: editor, input: script) {
    case .success(let result): throw DrewAnyway(result: result)
    case .failure(let error):
        var data = try require(error.data?.objectValue)
        data["message"] = .string(error.message)
        return .object(data)
    }
}

struct DrewAnyway: Error, CustomStringConvertible {
    let result: JSON
    var description: String { "the draw should have failed, and said \(result.compactText)" }
}

/// A result's rows about edges.
func edgeRows(_ result: JSON) -> [JSON] { (result["changes"]?.arrayValue ?? []).filter { $0["from"] != nil } }

/// The links on the board: `A -> B`, by name, with their channel (`on wire`) and aim.
@MainActor func links(in editor: CanvasEditor) -> [String] {
    func name(_ id: ShapeID?) -> String {
        guard let record = id.flatMap({ editor.document[$0] }) else { return "?" }
        return record.typed(as: Tile.self)?.props.label ?? record.typed(as: Card.self)?.props.text ?? "?"
    }
    return editor.document.shapes.compactMap { record -> String? in
        guard let link = record.typed(as: Link.self) else { return nil }
        let channel = record[ChannelProperty.self].map { " on \($0)" } ?? ""
        let aim = record[Aim.self].map { " aimed \($0)" } ?? ""
        let heads = record[BothHeads.self] == true ? " both heads" : ""
        return "\(name(link.props.from)) -> \(name(link.props.to))\(channel)\(aim)\(heads)"
    }
}

/// Two tiles, A and B, B right of A, and two cards under them, C and D, D right of C.
let board = #"""
tile "A"
tile "B" right of "A"
card "C" below "A"
card "D" below "B"
"""#

/// Names tiles by their label, and cards not at all: nothing a script can write on one, and no title
/// worked out (`derived`: one is, from its text).
func namesOnlyTiles(derived: Bool = false) -> Contributor {
    Contributor(id: "tile-names") { registrar in
        registrar.drawNames(name: { record, _ in
            record.typed(as: Tile.self).map(\.props.label).flatMap { $0.isEmpty ? nil : $0 }
                ?? (derived ? record.typed(as: Card.self)?.props.text : nil)
        }, namingProperty: { kind, _ in kind == Tile.kind ? "label" : nil },
        isDerived: { kind, _ in derived && kind == Card.kind },
        fold: { title in
            let folded = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return folded.isEmpty ? nil : folded
        })
    }
}

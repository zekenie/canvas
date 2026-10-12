import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import Connections
import CoreGraphics
import Draw
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

/// Whether a relay may stand for a shape: metadata a test writes on a shape, as a person makes one public.
enum Open: ShapeMetaKey {
    static let owner: PluginID = "relays"
    static let name = "open"
    typealias Value = Bool
}

/// A box that stands for the shape it cites, and says what it stands for, with ports on every channel
/// on its left and right (`portsOnEveryChannel`), so what it takes follows what it stands for.
struct Relay: BoxShapeProps {
    static let kind: ShapeKind = "relay"
    static let properties = Properties<Relay> {
        Property("frame", \.frame).required()
        Property("stands", \.stands)
        Property("says", \.says)
    }
    var frame: CGRect
    var stands: [Citation]
    var says: String
    init(_ frame: CGRect, stands: [ShapeID] = [], says: String = "") {
        self.frame = frame
        self.stands = stands.map(Citation.init)
        self.says = says
    }
}

extension Relay {
    init() { self.init(CGRect(x: 0, y: 0, width: 80, height: 40)) }
}

struct RelayDefinition {}

extension RelayDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Relay>, in context: RenderContext) {}
}

/// Relays, which stand for the open shapes they cite, are made to stand for one, and are placed by a tool.
func relaysPlugin() -> Contributor {
    Contributor(id: "relays") { registrar in
        registrar.shape(RelayDefinition()) { relay in
            relay.portsOnEveryChannel(sides: [.left, .right])
            relay.standsIn(admitting: { target, _ in target.meta[Open.self] == true }, needs: "open", makes: { props, target, label in
                props.stands = [Citation(target)]
                props.says = label
            }) { shape, _ in shape.props.stands.isEmpty ? nil : .shapes(shape.props.stands.map(\.shape)) }
            relay.tool(label: "Relay", systemImage: "arrow.right", placing: relay.placement(size: CGSize(width: 80, height: 40)) { Relay() })
        }
    }
}

/// An editor 800 × 600 points with the fixtures, Ports, the channels, the link connector, names
/// and `PortEdgesPlugin` (unless not), and `more` before them (with the file's boards, the pockets they
/// are in).
@MainActor func edgesEditor(_ requests: Requests = Requests(), cards: Bool = true, makes: Bool = true, withPlugin: Bool = true,
                                        names: Contributor = fixtureNames, more: [any CanvasPlugin] = []) throws -> CanvasEditor {
    let plugins: [any CanvasPlugin] = [KeyboardPlugin(), SelectionPlugin(), TopologyPlugin(), DrawPlugin(), FixturesPlugin(), CardsPlugin(), TilesPlugin(),
                                       LinksPlugin(), PortsPlugin(), channelsPlugin(cards: cards), linkConnector(requests, makes: makes),
                                       names] + more + (withPlugin ? [PortEdgesPlugin()] : [])
    let editor = CanvasEditor(registry: try Registry(plugins: plugins))
    editor.viewportDidResize(to: CGSize(width: 800, height: 600))
    return editor
}

/// The board of `board`, and a pocket P with a board of its own, holding tile Z and card Y (both open): the
/// shapes a script reaches through a relay on this board, which only an open shape can have.
struct Harbor {
    let p = ShapeID(), z = ShapeID(), y = ShapeID()

    /// An editor on it: tiles A and B and cards C and D, as `board` draws them, are on the root.
    @MainActor func editor(_ requests: Requests = Requests(), cards: Bool = true, makes: Bool = true) throws -> CanvasEditor {
        let editor = try edgesEditor(requests, cards: cards, makes: makes, more: [PocketsPlugin(), relaysPlugin()])
        _ = try drawn(board, on: editor)
        let root = CanvasDocument(shapes: editor.file.root.shapes + [AnyShapeRecord(ShapeRecord(id: p, Pocket(CGRect(x: 600, y: 450, width: 100, height: 100))))])
        var tile = AnyShapeRecord(ShapeRecord(id: z, Tile(CGRect(x: 50, y: 50, width: 120, height: 80), label: "Z")))
        var card = AnyShapeRecord(ShapeRecord(id: y, Card(CGRect(x: 400, y: 50, width: 100, height: 60), text: "Y")))
        tile.meta[Open.self] = true
        card.meta[Open.self] = true
        let file = CanvasFile(root: root, children: [p: CanvasDocument(shapes: [tile, card])])
        editor.replaceFile(with: file)
        return editor
    }
}

extension CanvasEditor {
    /// The relays on a board.
    func relays(on board: BoardID = .root) -> [ShapeRecord<Relay>] { contents(of: board).shapes.compactMap { $0.typed(as: Relay.self) } }
}

/// What `canvas draw -` says of a script that runs, as the wire carries it.
@MainActor func drawn(_ script: String, on editor: CanvasEditor) throws -> JSON {
    try JSON(encoding: draw(script: script, dryRun: false, reveal: false, program: RPC.commandName, in: editor))
}

/// Why `canvas draw -` refused a script: its error's fields (`reason`, `hint`, `line`), and its
/// `message`.
@MainActor func refused(_ script: String, on editor: CanvasEditor) throws -> JSON {
    let result: DrawResult
    do throws(DrawError) {
        result = try draw(script: script, dryRun: false, reveal: false, program: RPC.commandName, in: editor)
    } catch {
        var data: [String: JSON] = ["reason": .string(error.reason), "message": .string(error.message)]
        if let hint = error.hint { data["hint"] = .string(hint) }
        if let line = error.line { data["line"] = .number(Double(line)) }
        if let statement = error.statement { data["statement"] = .string(statement) }
        return .object(data)
    }
    throw DrewAnyway(result: try JSON(encoding: result))
}

/// What `canvas kinds` says, as the wire carries it: a list.
@MainActor func kindsListed(in registry: Registry) throws -> JSON {
    try JSON(encoding: kinds(in: registry))
}

struct DrewAnyway: Error, CustomStringConvertible {
    let result: JSON
    var description: String { "the draw should have failed, and said \(result.compactText)" }
}

/// A result's rows about edges.
func edgeRows(_ result: JSON) -> [JSON] { (result["changes"]?.arrayValue ?? []).filter { $0["from"] != nil } }

/// The links on the board: `A -> B`, by name, with their channel (`on wire`) and aim; a relay by what it
/// says (`relay Z`).
@MainActor func links(in editor: CanvasEditor) -> [String] {
    func name(_ id: ShapeID?) -> String {
        guard let record = id.flatMap({ editor.document[$0] }) else { return "?" }
        if let relay = record.typed(as: Relay.self) { return "relay \(relay.props.says)" }
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

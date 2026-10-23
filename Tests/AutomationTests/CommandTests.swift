import Automation
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Draw
import Foundation
import Geometry
import TestKit

// The command line's own commands, run as the app's command server runs them, on an editor with
// the fixtures' kinds (a box, a disc and a tag, which no tool places; links, which no tool places
// either), and a card and a tile, which their tools place at 100 × 60 and 120 × 80. No real kind:
// the commands know none.

/// A kind with no frame that moves by its own rules: a point.
struct Dot: ShapeProps {
    static let kind: ShapeKind = "dot"
    static let properties = Properties<Dot> { Property("point", \.point) }
    var point = CGPoint.zero
}

struct DotDefinition {}

extension DotDefinition: ShapeDefinition, CustomTranslation {
    func render(_ shape: ShapeRecord<Dot>, in context: RenderContext) {}
    func geometry(of shape: ShapeRecord<Dot>, in context: ShapeContext) -> ShapeGeometry {
        ShapeGeometry(outline: CGRect(center: shape.props.point, size: CGSize(width: 10, height: 10)).polygon)
    }
    func beginTranslation(of shape: ShapeRecord<Dot>, movingWith moving: Set<ShapeID>, in transaction: inout Transaction) -> ShapeTranslation<Dot> {
        let start = shape.props.point
        return ShapeTranslation { delta, shape, _ in shape.props.point = CGPoint(x: start.x + delta.x, y: start.y + delta.y) }
    }
}

/// A name a card may have, of at most 3 characters: a bound a shape can break.
enum Nickname {}

extension Nickname: ShapeProperty {
    static let key: PropertyKey = "nickname"
    static var defaultValue: String? { nil }
    static var keywords: PropertyKeywords<String> { PropertyKeywords().maxLength(3) }
}

/// When a card is due: a date and time.
enum Due {}

extension Due: ShapeProperty {
    static let key: PropertyKey = "due"
    static var defaultValue: Date? { nil }
}

/// A tile's rank, from 1.
enum Rank {}

extension Rank: ShapeProperty {
    static let key: PropertyKey = "rank"
    static var defaultValue: Int? { nil }
    static var keywords: PropertyKeywords<Int> { PropertyKeywords().minimum(1) }
}

/// Whether a tile is pinned.
enum Pinned {}

extension Pinned: ShapeProperty {
    static let key: PropertyKey = "pinned"
    static var defaultValue: Bool? { nil }
}

/// A step of a tile's: what it says, and an id no one writes (a missing one reads as a new one).
struct Step: SchemaDefined, Equatable {
    static let properties = Properties<Step> {
        Property("id", \.id)
        Property("text", \.text)
    }
    var id = UUID()
    var text = ""
}

/// A tile's steps.
enum Steps {}

extension Steps: ShapeProperty {
    static let key: PropertyKey = "steps"
    static var defaultValue: [Step]? { [] }
}

let extras = Contributor(id: "extras") { registrar in
    registrar.declare(Steps.self)
    registrar.optIn(Tile.self, to: Steps.self)
    registrar.shape(DotDefinition())
    registrar.declare(Nickname.self)
    registrar.optIn(Card.self, to: Nickname.self)
    registrar.declare(Due.self)
    registrar.optIn(Card.self, to: Due.self)
    registrar.declare(Rank.self)
    registrar.optIn(Tile.self, to: Rank.self)
    registrar.declare(Pinned.self)
    registrar.optIn(Tile.self, to: Pinned.self)
}

/// An editor 800 × 600 points, whose view is (100, 100) to (900, 700), its middle (500, 400).
@MainActor func makeEditor(_ plugins: [any CanvasPlugin] = [], viewport: CGSize = CGSize(width: 800, height: 600)) throws -> CanvasEditor {
    let editor = CanvasEditor(registry: try Registry(plugins: [DrawPlugin(), AutomationPlugin(), FixturesPlugin(), CardsPlugin(), TilesPlugin(), LinksPlugin(),
                                                               extras] + plugins))
    editor.viewportDidResize(to: viewport)
    editor.camera = Camera(origin: CGPoint(x: 100, y: 100))
    return editor
}

/// A command, as the command line spells it, run on `editor` as the app's server runs it; `input`
/// is its standard input.
@MainActor func run(_ line: [String], on editor: CanvasEditor?, registry: Registry? = nil, input: String = "") throws -> Result<JSON, RPCError> {
    let registry = try require(registry ?? editor?.registry)
    let spec = try require(registry.automationCommands.first { $0.name == line[0] })
    let params = try spec.params(from: Array(line.dropFirst()), standardInput: { input })
    return try awaitResult { () async -> Result<JSON, RPCError> in
        do throws(RPCError) {
            return .success(try await registry.runAutomationCommand(spec.name, params: .object(params), editor: editor))
        } catch {
            return .failure(error)
        }
    }
}

@MainActor let kindsTests = Suite("kinds", [
    test("it lists every kind: whether a script draws it, its names, size, attributes and edges; --schema adds the schema") {
        let editor = try makeEditor(drawPlugins())
        let all = try run(["kinds"], on: nil, registry: editor.registry).get()
        expectEqual(all.arrayValue?.compactMap { $0["kind"]?.stringValue }, ["box", "card", "disc", "dot", "link", "tag", "tile"])
        let card = try require(all.arrayValue?.first { $0["kind"] == "card" })
        expectEqual(card, ["kind": "card", "title": "card", "tool": "Card", "drawable": true, "names": "named", "size": "100x60",
                           "attributes": ["due": "date (YYYY-MM-DD or date-time)", "text": "text"], "edges": ["bottom": ["cool"]]])
        let tile = try require(all.arrayValue?.first { $0["kind"] == "tile" })
        expectEqual(tile["attributes"], ["finish": "matte|glossy", "pinned": "true|false", "rank": "integer ≥ 1", "steps": "JSON [{text}]"])
        expectEqual(tile["edges"], ["left": ["warm"], "right": ["warm", "cool"]])
        let box = try require(all.arrayValue?.first { $0["kind"] == "box" })
        expectEqual(box["drawable"], false)
        expectEqual(box["why"], "no tool places one")
        expectEqual(box["names"], "none")
        expectEqual(box["attributes"], [:], "its frame is where it is, which a script never says")
        let link = try require(all.arrayValue?.first { $0["kind"] == "link" })
        expectEqual(link["why"], #"it joins two shapes: write edge "A" -> "B""#)
        let one = try run(["kinds", "card", "--schema"], on: nil, registry: editor.registry).get()
        expectEqual(one.arrayValue?.count, 1)
        expectEqual(one.arrayValue?.first?["schema"]?["properties"]?["nickname"]?["maxLength"], 3)
        guard case .failure(let error) = try run(["kinds", "cards"], on: nil, registry: editor.registry) else { return expect(false, "no cards") }
        expectEqual(error.reason, "unknown_kind")
        expectEqual(error.hint, "did you mean card? the kinds: box, card, disc, dot, link, tag, tile")
    },
    test("without a plugin that names shapes, a kind's naming property is an attribute, and a key the language keeps is marked") {
        let editor = try makeEditor([Contributor(id: "sizes") { registrar in
            registrar.declare(SizeWord.self)
            registrar.optIn(Tile.self, to: SizeWord.self)
        }])
        let all = try run(["kinds"], on: nil, registry: editor.registry).get()
        let card = try require(all.arrayValue?.first { $0["kind"] == "card" })
        expectEqual(card["names"], "none")
        expectEqual(card["attributes"]?["nickname"], "text (≤ 3)")
        expectEqual(card["edges"], nil)
        let tile = try require(all.arrayValue?.first { $0["kind"] == "tile" })
        expectEqual(tile["attributes"]?["label"], "text")
        expectEqual(tile["attributes"]?["size"], "text — can't be written: size: is one of the language's own keys")
    },
    test("a kind whose tool draws it by hand names the tool, and says a script can't place one") {
        let editor = try makeEditor(drawPlugins() + [Contributor(id: "boxer") { registrar in
            registrar.tool(ToolDescriptor(id: ToolID(placing: Box.kind), label: "Boxer", systemImage: "square")) { _ in NoTool() }
        }])
        let box = try require(run(["kinds", "box"], on: nil, registry: editor.registry).get().arrayValue?.first)
        expectEqual(box["tool"], "Boxer")
        expectEqual(box["drawable"], false)
        expectEqual(box["why"], "its tool (Boxer) draws one by hand, so a script can't place one")
        let placing = try refused("box", on: editor)
        expectEqual(placing.reason, "not_placeable")
        expectEqual(placing.message, "a box isn't drawn on its own: its tool (Boxer) draws one by hand, so a script can't place one")
    },
    test("a bound written beside a reference to a definition is what the attribute takes") {
        let editor = try makeEditor([Contributor(id: "partners") { registrar in
            registrar.declare(Partner.self)
            registrar.optIn(Tile.self, to: Partner.self)
        }])
        let tile = try require(run(["kinds", "tile"], on: nil, registry: editor.registry).get().arrayValue?.first)
        expectEqual(tile["attributes"]?["partner"], "text (≤ 36)")
    },
])

/// A shape's partner, by id (the core's shape id, a definition referred to), with a bound beside it.
enum Partner {}

extension Partner: ShapeProperty {
    static let key: PropertyKey = "partner"
    static var defaultValue: ShapeID? { nil }
    static var keywords: PropertyKeywords<ShapeID> { PropertyKeywords().maxLength(36) }
}

/// A property named like one of the language's keys.
enum SizeWord {}

extension SizeWord: ShapeProperty {
    static let key: PropertyKey = "size"
    static var defaultValue: String? { nil }
}

@MainActor let registrationTests = Suite("Registering commands", [
    test("each command is described for the command line: its scope, positionals and params' schema") {
        let registry = try makeEditor().registry
        let draw = try require(registry.automationCommands.first { $0.name == "draw" })
        expectEqual(draw.scope, .board)
        expectEqual(draw.positionals, ["script"])
        expectEqual(draw.params["required"], ["script"])
        expectEqual(draw.params["properties"]?.objectValue.map { $0.keys.sorted() }, ["dryRun", "reveal", "script"])
        expectEqual(draw.usage(), "canvas draw <script>|- [--dry-run] [--reveal] [--board <board>]")
        expect(draw.arguments.first { $0.name == "script" }?.readsStandardInput == true)
        expectEqual(registry.automationCommands.first { $0.name == "kinds" }?.scope, .app)
        expect(registry.report.contains("automation    command line draw · command line show · command line capture · command line kinds · command line measure · host commands"), registry.report)
    },
    test("the app's command server is handed every command, the plugin's own and another's, and runs each by name") {
        let more = Contributor(id: "more") { $0.automationCommand("ping", "Answers pong.", scope: .app, params: NoParams.self) { _, _ throws(AutomationError) in "pong" } }
        let registry = try Registry(plugins: [AutomationPlugin(), more])
        let commands = registry.hostCommands
        expectEqual(commands.specs, registry.automationCommands)
        expectEqual(commands.specs.map(\.name), ["draw", "show", "capture", "kinds", "measure", "ping"])
        expectEqual(try awaitResult { try await commands.run("ping", [:], nil) }, "pong")
        do {
            _ = try awaitResult { try await commands.run("pang", [:], nil) }
            expect(false, "no such command")
        } catch let error as RPCError {
            expectEqual(error.reason, "unknown_command")
        }
        expectEqual(try Registry(plugins: []).hostCommands.specs, [], "a list without the command line gives the server none")
    },
    test("the registry refuses a command the command line couldn't type or spell, or two of one name") {
        let nothing: @MainActor (NoParams, AutomationContext) throws(AutomationError) -> String = { _, _ in "" }
        expectEqual(refusal { $0.automationCommand("Make It", "", params: NoParams.self, run: nothing) },
                    "AutomationCommands: command Make It: a name is words of lowercase letters, digits and hyphens, one space apart")
        for name in ["help", "boards", "status", "new", "describe", "install"] {
            expectEqual(refusal { $0.automationCommand(name, "", params: NoParams.self, run: nothing) },
                        "AutomationCommands: command \(name): the app answers that one itself, or canvas does (boards, describe, help, install, new, status)")
        }
        expectEqual(refusal { $0.automationCommand("go", "", params: BoardParam.self) { _, _ throws(AutomationError) in "" } },
                    "AutomationCommands: command go: a param can't be named board, which canvas keeps for itself")
        expectEqual(refusal { $0.automationCommand("go", "", params: NoParams.self, positionals: ["what"], run: nothing) },
                    "AutomationCommands: command go: positional what isn't one of its params")
        expectEqual(refusal { $0.automationCommand("draw", "", params: NoParams.self, run: nothing) },
                    "automation and more both claim command draw in AutomationCommands")
        expectEqual(refusal { $0.automationCommand("board list", "", params: NoParams.self, run: nothing) }, nil)
    },
    test("a board command with no board says so") {
        let editor = try makeEditor()
        guard case .failure(let error) = try run(["draw", "tile"], on: nil, registry: editor.registry) else { return expect(false, "no board") }
        expectEqual(error.reason, "no_board")
    },
])

/// Why the registry refuses the command line's plugin with `register`'s contributions, if it does.
@MainActor func refusal(_ register: @escaping @MainActor (inout PluginRegistrar) -> Void) -> String? {
    do throws(RegistryError) {
        _ = try Registry(plugins: [DrawPlugin(), AutomationPlugin(), Contributor(id: "more", register)])
        return nil
    } catch {
        return error.description
    }
}

struct NoParams: SchemaDefined {
    static let properties = Properties<NoParams> {}
}

/// Params with one named as the board a command works on is.
struct BoardParam: SchemaDefined {
    static let properties = Properties<BoardParam> { Property("board", \.board) }
    var board = ""
}

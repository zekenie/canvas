import Automation
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Foundation
import Geometry
import TestKit

// The command line's own commands, run as the app's command server runs them, on an editor with
// the fixtures' kinds (a box, a disc and a tag, which no tool places) and a card, which its tool
// places at 100 × 60. No real kind: the commands know none.

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

let extras = Contributor(id: "extras") { registrar in
    registrar.shape(DotDefinition())
    registrar.declare(Nickname.self)
    registrar.optIn(Card.self, to: Nickname.self)
}

/// An editor 800 × 600 points, whose view's middle is (500, 400).
@MainActor func makeEditor(_ plugins: [any CanvasPlugin] = []) throws -> CanvasEditor {
    let editor = CanvasEditor(registry: try Registry(plugins: [AutomationPlugin(), FixturesPlugin(), CardsPlugin(), extras] + plugins))
    editor.viewportDidResize(to: CGSize(width: 800, height: 600))
    editor.camera = Camera(origin: CGPoint(x: 100, y: 100))
    return editor
}

/// A command, as the command line spells it, run on `editor` as the app's server runs it.
@MainActor func run(_ line: [String], on editor: CanvasEditor?, registry: Registry? = nil) throws -> Result<JSON, RPCError> {
    let registry = try require(registry ?? editor?.registry)
    let spec = try require(registry.automationCommands.first { $0.name == line[0] })
    let params = try spec.params(from: Array(line.dropFirst()), standardInput: { "" })
    return Result { () throws(RPCError) in try registry.runAutomationCommand(spec.name, params: .object(params), editor: editor) }
}

@MainActor func created(_ result: Result<JSON, RPCError>, in editor: CanvasEditor) throws -> AnyShapeRecord {
    let json = try result.get()
    let id = try require(json["id"]?.stringValue.flatMap(UUID.init(uuidString:)))
    return try require(editor.document[ShapeID(id)])
}

@MainActor let createTests = Suite("create", [
    test("it puts what the kind's tool places in the middle of the view, and says what and where") {
        let editor = try makeEditor()
        let result = try run(["create", "card"], on: editor)
        let card = try created(result, in: editor)
        expectEqual(card.box, CGRect(x: 450, y: 370, width: 100, height: 60))
        expectEqual(try result.get()["kind"], "card")
        expectEqual(try result.get()["bounds"], [[450, 370], [100, 60]])
        expectEqual(try result.get()["warnings"], nil)
        expectEqual(editor.document.shapes.count, 1)
    },
    test("--at puts its middle there, and --size sizes it") {
        let editor = try makeEditor()
        expectEqual(try created(run(["create", "card", "--at", "10,20"], on: editor), in: editor).box, CGRect(x: -40, y: -10, width: 100, height: 60))
        expectEqual(try created(run(["create", "card", "--at", "10,20", "--size", "40,30"], on: editor), in: editor).box,
                    CGRect(x: -10, y: 5, width: 40, height: 30))
        expectEqual(try created(run(["create", "card", "--size", "40,30"], on: editor), in: editor).box, CGRect(x: 480, y: 385, width: 40, height: 30))
    },
    test("--set takes text as typed for a property of text, and JSON for any other; each is set over --props") {
        let editor = try makeEditor()
        let card = try created(run(["create", "card", "--set", "text=42", "--set", "nickname=Al"], on: editor), in: editor)
        expectEqual(card.typed(as: Card.self)?.props.text, "42")
        expectEqual(card[Nickname.self], "Al")
        let box = try created(run(["create", "box", "--props", #"{"frame": [[0, 0], [10, 10]]}"#, "--set", "frame=[[1, 2], [3, 4]]"], on: editor),
                              in: editor)
        expectEqual(box.box, CGRect(x: 1, y: 2, width: 3, height: 4))
    },
    test("a kind no tool places starts from the properties given; one without a frame moves to --at by its own rules") {
        let editor = try makeEditor()
        let dot = try created(run(["create", "dot", "--set", "point=[5, 5]", "--at", "100,50"], on: editor), in: editor)
        expectEqual(dot.typed(as: Dot.self)?.props.point, CGPoint(x: 100, y: 50))
        guard case .failure(let error) = try run(["create", "box"], on: editor) else { return expect(false, "a box needs its frame") }
        expectEqual(error.reason, "invalid_properties")
        expect(error.message.contains("frame is missing"), error.message)
        expectEqual(error.hint, "`canvas kinds box --schema` says what each property takes.")
    },
    test("a shape may be bound only to shapes on its board") {
        let editor = try makeEditor()
        let box = try created(run(["create", "box", "--set", "frame=[[0, 0], [10, 10]]"], on: editor), in: editor)
        let tag = try created(run(["create", "tag", "--set", "target=\(box.id)"], on: editor), in: editor)
        expectEqual(tag.typed(as: Tag.self)?.props.target, box.id)
        let elsewhere = ShapeID()
        guard case .failure(let error) = try run(["create", "tag", "--set", "target=\(elsewhere)"], on: editor) else {
            return expect(false, "it was bound to a shape that isn't there")
        }
        expectEqual(error.reason, "unknown_shape")
        expectEqual(error.message, "A tag can't be bound to shapes that aren't on this board: \(elsewhere).")
        expectEqual(error.hint, "Bind it only to shapes on the board the command works on (--board).")
        expectEqual(editor.document.shapes.count, 2)
    },
    test("a shape may name shapes that aren't on its board (ShapeNaming): it's made, keeps naming them, and says which") {
        let editor = try makeEditor([NamingPlugin()])
        let box = try created(run(["create", "box", "--set", "frame=[[0, 0], [10, 10]]"], on: editor), in: editor)
        let gone = ShapeID(), alsoGone = ShapeID()
        let result = try run(["create", "memo", "--set", "frame=[[0, 0], [10, 10]]", "--set", "lead=\(gone)",
                              "--props", #"{"sources": {"here": "\#(box.id)", "there": "\#(alsoGone)", "again": "\#(alsoGone)"}}"#], on: editor)
        let memo = try created(result, in: editor)
        expectEqual(memo.typed(as: Memo.self)?.props.lead, Citation(gone))
        expectEqual(memo.typed(as: Memo.self)?.props.sources, ["here": Citation(box.id), "there": Citation(alsoGone), "again": Citation(alsoGone)])
        expectEqual(try result.get()["warnings"], [
            .string("lead names shapes that aren't on this board: \(gone); they show as missing."),
            .string("sources names shapes that aren't on this board: \(alsoGone); they show as missing."),
        ])
        let named = try run(["create", "memo", "--set", "frame=[[0, 0], [10, 10]]", "--set", "lead=\(box.id)"], on: editor)
        expectEqual(try named.get()["warnings"], nil, "every shape it names is there")
    },
    test("what a shape is bound to must still be on its board, though what it names needn't be") {
        let editor = try makeEditor([NamingPlugin()])
        let box = try created(run(["create", "box", "--set", "frame=[[0, 0], [10, 10]]"], on: editor), in: editor)
        let gone = ShapeID(), alsoGone = ShapeID()
        let cited = try run(["create", "citing-tag", "--set", "target=\(box.id)", "--set", "cite=\(gone)"], on: editor)
        expectEqual(try created(cited, in: editor).typed(as: CitingTag.self)?.props, CitingTag(target: box.id, cite: Citation(gone)))
        expectEqual(try cited.get()["warnings"], [.string("cite names shapes that aren't on this board: \(gone); they show as missing.")])
        guard case .failure(let error) = try run(["create", "citing-tag", "--set", "target=\(alsoGone)", "--set", "cite=\(gone)"], on: editor) else {
            return expect(false, "it was bound to a shape that isn't there")
        }
        expectEqual(error.reason, "unknown_shape")
        expectEqual(error.message, "A citing-tag can't be bound to shapes that aren't on this board: \(alsoGone).",
                    "what it's bound to is refused, where what it names is only warned about")
        expectEqual(editor.document.shapes.count, 2)
    },
    test("a shape past its schema's bounds is made anyway, with a warning") {
        let editor = try makeEditor()
        let result = try run(["create", "card", "--set", "nickname=Robert"], on: editor)
        let card = try created(result, in: editor)
        expectEqual(card[Nickname.self], "Robert")
        let warnings = try result.get()["warnings"]?.arrayValue ?? []
        expectEqual(warnings.count, 1)
        expect(warnings.first?.stringValue?.contains("at most 3") == true, "\(warnings)")
    },
    test("a kind or a property that isn't there says what there is, and what was probably meant") {
        let editor = try makeEditor()
        guard case .failure(let kind) = try run(["create", "crad"], on: editor) else { return expect(false, "there's no crad") }
        expectEqual(kind.code, RPCError.failed)
        expectEqual(kind.reason, "unknown_kind")
        expectEqual(kind.message, "There's no kind of shape called crad.")
        expectEqual(kind.hint, "Did you mean card? The kinds: box, card, disc, dot, tag.")
        guard case .failure(let property) = try run(["create", "card", "--set", "txt=Hi"], on: editor) else { return expect(false, "no txt") }
        expectEqual(property.reason, "unknown_property")
        expectEqual(property.hint, "Did you mean text? Its properties: frame, nickname, text.")
        guard case .failure(let json) = try run(["create", "card", "--props", #"{"colour": 1}"#], on: editor) else { return expect(false, "no colour") }
        expectEqual(json.reason, "unknown_property")
        expectEqual(editor.document.shapes.count, 0, "nothing was made")
    },
    test("a value that isn't one is refused as the params, before anything's made") {
        let editor = try makeEditor()
        for line in [["create", "card", "--set", "text"], ["create", "card", "--size", "0,10"], ["create", "card", "--set", "frame=nope"]] {
            guard case .failure(let error) = try run(line, on: editor) else { return expect(false, "\(line)") }
            expectEqual(error.code, RPCError.invalidParams, "\(line)")
            expectEqual(error.reason, "invalid_params", "\(line)")
        }
        let registry = editor.registry
        for params: JSON in [["kind": 3], ["kind": "card", "colour": 1], [:]] {
            let result = Result { () throws(RPCError) in try registry.runAutomationCommand("create", params: params, editor: editor) }
            guard case .failure(let error) = result else { return expect(false, "\(params)") }
            expectEqual(error.code, RPCError.invalidParams, "\(params)")
        }
        expectEqual(editor.document.shapes.count, 0)
    },
    test("a board command with no board says so") {
        let editor = try makeEditor()
        guard case .failure(let error) = try run(["create", "card"], on: nil, registry: editor.registry) else { return expect(false, "no board") }
        expectEqual(error.reason, "no_board")
    },
])

@MainActor let kindsTests = Suite("kinds", [
    test("it lists every kind, what places it and its properties; --schema adds the schema") {
        let editor = try makeEditor()
        let all = try run(["kinds"], on: nil, registry: editor.registry).get()
        expectEqual(all.arrayValue?.compactMap { $0["kind"]?.stringValue }, ["box", "card", "disc", "dot", "tag"])
        let card = try require(all.arrayValue?.first { $0["kind"] == "card" })
        expectEqual(card, ["kind": "card", "title": "card", "tool": "Card", "size": [100, 60], "properties": ["frame", "nickname", "text"]])
        let box = try require(all.arrayValue?.first { $0["kind"] == "box" })
        expectEqual(box["tool"], nil, "no tool places a box")
        let one = try run(["kinds", "card", "--schema"], on: nil, registry: editor.registry).get()
        expectEqual(one.arrayValue?.count, 1)
        expectEqual(one.arrayValue?.first?["schema"]?["properties"]?["nickname"]?["maxLength"], 3)
        guard case .failure(let error) = try run(["kinds", "cards"], on: nil, registry: editor.registry) else { return expect(false, "no cards") }
        expectEqual(error.reason, "unknown_kind")
    },
])

@MainActor let registrationTests = Suite("Registering commands", [
    test("each command is described for the command line: its scope, positionals and params' schema") {
        let registry = try makeEditor().registry
        let create = try require(registry.automationCommands.first { $0.name == "create" })
        expectEqual(create.scope, .board)
        expectEqual(create.positionals, ["kind"])
        expectEqual(create.params["required"], ["kind"])
        expectEqual(create.params["properties"]?.objectValue.map { $0.keys.sorted() }, ["at", "kind", "props", "set", "size"])
        expectEqual(create.usage(), "canvas create <kind> [--at <x,y>] [--props <json>] [--set <name=value>]... [--size <width,height>] [--board <board>]")
        expectEqual(registry.automationCommands.first { $0.name == "kinds" }?.scope, .app)
        expect(registry.report.contains("automation    command line create · command line kinds"), registry.report)
    },
    test("the registry refuses a command the command line couldn't type or spell, or two of one name") {
        let nothing: @MainActor (NoParams, AutomationContext) throws(AutomationError) -> String = { _, _ in "" }
        expectEqual(refusal { $0.automationCommand("Make It", "", params: NoParams.self, run: nothing) },
                    "AutomationCommands: command Make It: a name is words of lowercase letters, digits and hyphens, one space apart")
        for name in ["help", "boards", "status", "describe"] {
            expectEqual(refusal { $0.automationCommand(name, "", params: NoParams.self, run: nothing) },
                        "AutomationCommands: command \(name): the app answers that one itself, or canvas does (boards, describe, help, status)")
        }
        expectEqual(refusal { $0.automationCommand("go", "", params: BoardParam.self) { _, _ throws(AutomationError) in "" } },
                    "AutomationCommands: command go: a param can't be named board, which canvas keeps for itself")
        expectEqual(refusal { $0.automationCommand("go", "", params: NoParams.self, positionals: ["what"], run: nothing) },
                    "AutomationCommands: command go: positional what isn't one of its params")
        expectEqual(refusal { $0.automationCommand("create", "", params: NoParams.self, run: nothing) },
                    "automation and more both claim command create in AutomationCommands")
        expectEqual(refusal { $0.automationCommand("board list", "", params: NoParams.self, run: nothing) }, nil)
    },
])

/// Why the registry refuses the command line's plugin with `register`'s contributions, if it does.
@MainActor func refusal(_ register: @escaping @MainActor (inout PluginRegistrar) -> Void) -> String? {
    do throws(RegistryError) {
        _ = try Registry(plugins: [AutomationPlugin(), Contributor(id: "more", register)])
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

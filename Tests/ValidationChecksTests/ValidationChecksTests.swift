@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Draw
import TestKit
import Validation

// `canvas draw` saying what Validation finds wrong with the shapes it draws: each rule's issues on
// each shape it makes or changes, errors and warnings, the schema's bounds among them (Validation's
// own rule), as warnings on the statement's line. The shape is drawn all the same.

/// A card's nickname, at most 3 characters: a bound a script can break.
enum Nickname {}

extension Nickname: ShapeProperty {
    static let key: PropertyKey = "nickname"
    static var defaultValue: String? { nil }
    static var keywords: PropertyKeywords<String> { PropertyKeywords().maxLength(3) }
}

/// A card that says nothing is warned about, on its text; a glossy tile is an error.
let fixtureRules = Contributor(id: "fixture-rules") { registrar in
    registrar.declare(Nickname.self)
    registrar.optIn(Card.self, to: Nickname.self)
    registrar.validate(Card.self) { card, _ in card.props.text.isEmpty ? [.warning("A card should say something.", field: "text")] : [] }
    registrar.validate(Tile.self) { tile, _ in tile.props.finish == .glossy ? [.error("A glossy tile glares.", field: "finish")] : [] }
}

/// What the weather rule reads besides the shapes: the editor whose board it scans for clouds.
@MainActor final class Sky {
    weak var editor: CanvasEditor?
}

/// A tile is in shadow (an error) while a card on its board says "cloud": an issue of the tile that a card brings.
/// The rule says which tiles a card written reaches (`touches`): every tile of the board, when the card is or was a cloud.
@MainActor func weatherRules(_ sky: Sky, saying issue: ValidationIssue = .error("A cloud is over it.", field: "weather")) -> Contributor {
    func isCloud(_ record: AnyShapeRecord?) -> Bool { record?.typed(as: Card.self)?.props.text == "cloud" }
    return Contributor(id: "weather-rules") { registrar in
        registrar.validate(Tile.self, ignoringMoves: true, touches: { changes, shapes in
            guard let board = sky.editor?.document, changes.shapeIDs.contains(where: { isCloud(shapes.shape($0)) || isCloud(board[$0]) }) else { return [] }
            return Set(board.shapes.filter { $0.kind == Tile.kind }.map(\.id))
        }) { _, context in
            // The engine's own check has no reading (the board as committed); a run's has the transaction's.
            guard let board = sky.editor?.document else { return [] }
            let reading = context.reading
            let committed = board.shapes.contains { isCloud($0) && reading?.isChanged($0.id) != true }
            let written = reading?.changes.contains { isCloud(reading?.shape(inFile: $0)) } ?? false
            return committed || written ? [issue] : []
        }
    }
}

/// An editor 800 × 600 points with Validation, the rules, and (unless not) `ValidationChecksPlugin`.
@MainActor func checkedEditor(withPlugin: Bool = true) throws -> CanvasEditor {
    let plugins: [any CanvasPlugin] = [DrawPlugin(), FixturesPlugin(), CardsPlugin(), TilesPlugin(), ValidationPlugin(), fixtureRules]
        + (withPlugin ? [ValidationChecksPlugin()] : [])
    let editor = CanvasEditor(registry: try Registry(plugins: plugins))
    editor.viewportDidResize(to: CGSize(width: 800, height: 600))
    return editor
}

/// What `canvas draw -` says of a script, which must run, as the wire carries it.
@MainActor func drawn(_ script: String, on editor: CanvasEditor) throws -> JSON {
    try JSON(encoding: draw(script: script, dryRun: false, reveal: false, program: RPC.commandName, in: editor))
}

/// A result's warnings, as `severity line: message (attribute)`.
func warnings(_ result: JSON) -> [String] {
    (result["warnings"]?.arrayValue ?? []).map { warning in
        let attribute = warning["attribute"]?.stringValue.map { " (\($0))" } ?? ""
        return "\(warning["severity"]?.stringValue ?? "?") \(warning["line"]?.intValue ?? 0): \(warning["message"]?.stringValue ?? "")\(attribute)"
    }
}

@MainActor let validationChecksTests = Suite("Validation checks what canvas draw draws", [
    test("each shape drawn is checked by Validation's rules: an error or a warning on its line, about its property, and drawn anyway") {
        let editor = try checkedEditor()
        expectEqual(warnings(try drawn("card", on: editor)), ["warning 1: the card on line 1: A card should say something. (text)"])
        let result = try drawn("""
            // Under what's there.
            tile finish: glossy below board
            card text: "Hello" right of board
            """, on: editor)
        expectEqual(warnings(result).filter { !$0.contains("landed outside") }, ["error 2: the tile on line 2: A glossy tile glares. (finish)"])
        expectEqual(editor.document.shapes.count, 3, "drawn all the same")
    },
    test("a value past its schema's bound is Validation's warning too, once") {
        let editor = try checkedEditor()
        let result = try drawn(#"card text: "Hi" nickname: "Longer""#, on: editor)
        let said = warnings(result)
        expectEqual(said.count, 1, "\(said)")
        expect(said.first?.hasPrefix("warning 1: ") == true && said.first?.hasSuffix("(nickname)") == true, "\(said)")
        expectEqual(editor.document.shapes.first?[Nickname.self], "Longer", "kept, and warned about")
    },
    test("a shape the script leaves as it was isn't checked again") {
        let editor = try checkedEditor()
        _ = try drawn("tile finish: glossy", on: editor)
        let again = try drawn("tile finish: matte", on: editor)
        expectEqual(warnings(again), [], "a matte tile glares at no one")
    },
    test("an issue a run brings to a shape it did not write is Validation's too: the rule says what the write reaches, and the run warns of what is new, naming the shape") {
        let sky = Sky()
        let editor = CanvasEditor(registry: try Registry(plugins: [DrawPlugin(), FixturesPlugin(), CardsPlugin(), TilesPlugin(), ValidationPlugin(), weatherRules(sky), ValidationChecksPlugin()]))
        editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        sky.editor = editor
        expectEqual(warnings(try drawn("tile", on: editor)), [])
        let tile = try require(editor.document.shapes.first)
        let box = try require(tile.box)
        let named = "tile at \(Int(box.midX)),\(Int(box.midY))"
        expectEqual(warnings(try drawn(#"card text: "sun" below board"#, on: editor)).filter { !$0.contains("landed outside") }, [], "a card that is no cloud reaches no tile")
        let clouded = try drawn(#"card text: "cloud" right of board"#, on: editor)
        expectEqual(warnings(clouded).filter { !$0.contains("landed outside") }, ["error 1: \(named): A cloud is over it. (weather)"])
        expectEqual(editor.validation?.result(for: tile.id)?.issues.map(\.message), ["A cloud is over it."], "and the board says the same of it")
        // The tile had the issue before this run, so it is not the run's.
        expectEqual(warnings(try drawn(#"card text: "cloud" above board"#, on: editor)).filter { !$0.contains("landed outside") }, [])
    },
    test("what a shape still needs is the third level: a run says it of a shape it did not write with its own severity, never of one it wrote, and the board holds it valid") {
        let sky = Sky()
        let needs = ValidationIssue.incomplete("It needs sun.", field: "light")
        let editor = CanvasEditor(registry: try Registry(plugins: [DrawPlugin(), FixturesPlugin(), CardsPlugin(), TilesPlugin(), ValidationPlugin(), weatherRules(sky, saying: needs), ValidationChecksPlugin()]))
        editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        sky.editor = editor
        expectEqual(warnings(try drawn("tile", on: editor)), [])
        let tile = try require(editor.document.shapes.first)
        let box = try require(tile.box)
        let named = "tile at \(Int(box.midX)),\(Int(box.midY))"
        let clouded = try drawn(#"card text: "cloud" right of board"#, on: editor)
        expectEqual(warnings(clouded).filter { !$0.contains("landed outside") }, ["incomplete 1: \(named): It needs sun. (light)"])
        expectEqual(editor.validation?.result(for: tile.id)?.issues, [needs], "and the board holds it")
        expectEqual(editor.validation?.result(for: tile.id)?.isValid, true)
        expectEqual(editor.validation?.result(for: tile.id)?.worst, nil, "valid, with no ring")
        // The tile had it before this run, so it is not the run's; a tile this run draws needs it too, and the run does not warn of it.
        expectEqual(warnings(try drawn(#"card text: "cloud" above board"#, on: editor)).filter { !$0.contains("landed outside") }, [])
        expectEqual(warnings(try drawn("tile below board", on: editor)).filter { !$0.contains("landed outside") }, [], "a tile the run wrote")
    },
    test("without ValidationChecksPlugin, only the schema's bounds are checked") {
        let editor = try checkedEditor(withPlugin: false)
        let result = try drawn(#"card nickname: "Longer""#, on: editor)
        let said = warnings(result)
        expectEqual(said.count, 1, "\(said)")
        expect(said.first?.hasSuffix("(nickname)") == true, "\(said)")
    },
])

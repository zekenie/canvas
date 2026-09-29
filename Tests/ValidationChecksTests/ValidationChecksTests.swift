import Automation
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import TestKit
import Validation
import ValidationChecks

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

/// An editor 800 × 600 points with Validation, the rules, and (unless not) the bridge.
@MainActor func checkedEditor(bridge: Bool = true) throws -> CanvasEditor {
    let plugins: [any CanvasPlugin] = [AutomationPlugin(), FixturesPlugin(), CardsPlugin(), TilesPlugin(), ValidationPlugin(), fixtureRules]
        + (bridge ? [ValidationChecksPlugin()] : [])
    let editor = CanvasEditor(registry: try Registry(plugins: plugins))
    editor.viewportDidResize(to: CGSize(width: 800, height: 600))
    return editor
}

/// What `canvas draw -` says of a script, which must run.
@MainActor func drawn(_ script: String, on editor: CanvasEditor) throws -> JSON {
    let spec = try require(editor.registry.automationCommands.first { $0.name == "draw" })
    let params = try spec.params(from: ["-"], standardInput: { script })
    return try awaitResult { try await editor.registry.runAutomationCommand(spec.name, params: .object(params), editor: editor) }
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
    test("without the bridge, only the schema's bounds are checked") {
        let editor = try checkedEditor(bridge: false)
        let result = try drawn(#"card nickname: "Longer""#, on: editor)
        let said = warnings(result)
        expectEqual(said.count, 1, "\(said)")
        expect(said.first?.hasSuffix("(nickname)") == true, "\(said)")
    },
])

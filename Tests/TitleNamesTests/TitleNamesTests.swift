import Adornments
import Automation
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Keyboard
import Selection
import TestKit
import TitleNames
import Titles

// `canvas draw` naming shapes by their titles, as Titles has them: cards are named (the title
// Titles keeps), tiles named with a title worked out for those nobody named ("Tile, 120 × 80", as
// an unnamed ellipse's), discs only worked out, and boxes have none.

/// Titles for the fixtures: cards named, tiles named or worked out from their size, discs worked out.
@MainActor func fixtureTitles(tilesNamed: Bool = true) -> Contributor {
    Contributor(id: "fixture-titles") { registrar in
        registrar.title(Card.self, contents: false)
        if tilesNamed { registrar.optIn(Tile.self, to: TitleProperty.self) }
        registrar.title(Tile.self, contents: false) { tile in
            TitleProperty.folded(tile[TitleProperty.self]) ?? "Tile, \(Int(tile.props.frame.width)) × \(Int(tile.props.frame.height))"
        }
        registrar.title(Disc.self, contents: false) { disc in "Disc, \(Int(disc.props.frame.width)) × \(Int(disc.props.frame.height))" }
    }
}

/// An editor 800 × 600 points, its view (0, 0) to (800, 600), with Titles and the bridge.
@MainActor func namedEditor(tilesNamed: Bool = true, bridge: Bool = true) throws -> CanvasEditor {
    let plugins: [any CanvasPlugin] = [KeyboardPlugin(), SelectionPlugin(), AutomationPlugin(), FixturesPlugin(), CardsPlugin(), TilesPlugin(),
                                       AdornmentsPlugin(), TitlesPlugin(), fixtureTitles(tilesNamed: tilesNamed)] + (bridge ? [TitleNamesPlugin()] : [])
    let editor = CanvasEditor(registry: try Registry(plugins: plugins))
    editor.viewportDidResize(to: CGSize(width: 800, height: 600))
    return editor
}

/// A command, as the command line spells it, run as the app's server runs it; `input` is its
/// standard input.
@MainActor func run(_ line: [String], on editor: CanvasEditor, input: String = "") throws -> Result<JSON, RPCError> {
    let spec = try require(editor.registry.automationCommands.first { $0.name == line[0] })
    let params = try spec.params(from: Array(line.dropFirst()), standardInput: { input })
    return Result { () throws(RPCError) in try editor.registry.runAutomationCommand(spec.name, params: .object(params), editor: editor) }
}

/// What `canvas draw -` says of a script that runs.
@MainActor func drawn(_ script: String, on editor: CanvasEditor) throws -> JSON {
    try run(["draw", "-"], on: editor, input: script).get()
}

/// Why `canvas draw -` refused a script: its error's data, and its message.
@MainActor func refused(_ script: String, on editor: CanvasEditor) throws -> JSON {
    guard case .failure(let error) = try run(["draw", "-"], on: editor, input: script) else { throw Unexpected() }
    var data = try require(error.data?.objectValue)
    data["message"] = .string(error.message)
    return .object(data)
}

struct Unexpected: Error {}

/// The board shape Titles calls this.
@MainActor func shape(called title: String, in editor: CanvasEditor) -> AnyShapeRecord? {
    editor.document.shapes.first { editor.registry.title(of: $0) == title }
}

@MainActor let titleNamesTests = Suite("Titles name shapes for canvas draw", [
    test("a titled statement makes a shape with that title, in the property Titles keeps; restated, it's the same shape") {
        let editor = try namedEditor()
        let made = try drawn(#"card "API""#, on: editor)
        let card = try require(shape(called: "API", in: editor))
        expectEqual(card[TitleProperty.self], "API")
        expectEqual(made["changes"]?.arrayValue?.first?["title"], "API")
        let again = try drawn(#"card "API" text: "Serves the app""#, on: editor)
        expectEqual(again["changes"]?.arrayValue?.first?["did"], "updated")
        expectEqual(editor.document.shapes.count, 1)
        expectEqual(editor.document[card.id]?.typed(as: Card.self)?.props.text, "Serves the app")
    },
    test("a title is folded as Titles folds one: a board title matches however the script spaces it") {
        let editor = try namedEditor()
        _ = try drawn("card \"  Auth \\n  service \"", on: editor)
        expectEqual(try require(shape(called: "Auth service", in: editor))[TitleProperty.self], "Auth service")
        let restated = try drawn(#"card "Auth   service" text: "Logs people in""#, on: editor)
        expectEqual(restated["changes"]?.arrayValue?.first?["did"], "updated")
        expectEqual(editor.document.shapes.count, 1)
        expectEqual(try refused(#"card "   ""#, on: editor)["reason"], "syntax")
    },
    test("canvas kinds says how each kind is named: named, worked out, or not at all") {
        let editor = try namedEditor()
        let kinds = try run(["kinds"], on: editor).get().arrayValue ?? []
        func names(_ kind: ShapeKind) -> JSON? { kinds.first { $0["kind"]?.stringValue == kind.rawValue }?["names"] }
        expectEqual(names(Card.kind), "named")
        expectEqual(names(Tile.kind), "named", "named, with a title worked out for those nobody named")
        expectEqual(names(Disc.kind), "derived")
        expectEqual(names(Box.kind), "none")
        let tile = kinds.first { $0["kind"]?.stringValue == Tile.kind.rawValue }
        expectEqual(tile?["attributes"]?[TitleProperty.key.rawValue], nil, "a title goes after the kind, never as an attribute")
    },
    test("a shape nobody named is called by the title worked out for it, which a script may rename but not change under it") {
        let editor = try namedEditor()
        _ = try drawn("tile", on: editor)
        let tile = try require(shape(called: "Tile, 120 × 80", in: editor))
        expectEqual(tile[TitleProperty.self], nil)
        expectEqual(try refused(#"tile "Tile, 120 × 80" size: 200x100"#, on: editor)["reason"], "renames")
        let renamed = try drawn(#"tile "Tile, 120 × 80" title: "Kiosk""#, on: editor)
        expectEqual(renamed["changes"]?.arrayValue?.first?["did"], "renamed")
        expectEqual(renamed["changes"]?.arrayValue?.first?["was"], "Tile, 120 × 80")
        expectEqual(editor.document[tile.id]?[TitleProperty.self], "Kiosk")
        _ = try drawn(#"tile "Kiosk" size: 200x100"#, on: editor)
        expectEqual(editor.document[tile.id]?.box?.size, CGSize(width: 200, height: 100), "named, its size is its own")
    },
    test("a kind whose titles are only worked out can't be given one") {
        let editor = try namedEditor(tilesNamed: false)
        let error = try refused(#"tile "Kiosk""#, on: editor)
        expectEqual(error["reason"], "untitlable")
        expect(error["message"]?.stringValue?.contains("worked out from what it is") == true, "\(error)")
        let kinds = try run(["kinds", Tile.kind.rawValue], on: editor).get()
        expectEqual(kinds.arrayValue?.first?["names"], "derived")
    },
    test("without the bridge, nothing is named: a titled statement is no_names") {
        let editor = try namedEditor(bridge: false)
        expectEqual(try refused(#"card "API""#, on: editor)["reason"], "no_names")
        expectEqual(try drawn("card", on: editor)["changes"]?.arrayValue?.count, 1, "untitled shapes still draw")
    },
])

import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Frames
import LanguageModels
import Mentions
import Selection
import ShippedTesting
import StickyNotes
import TestKit
import Titles
import Types

// Keyboard navigation's P12, pro speed, on a new board's window as the app makes it: the first minute's tasks (a note,
// its words, a type, its fields, two notes connected and a frame around them) each take no more key presses than
// clicks, typing aside, counted from the walk's log of presses. A task that takes more is a line of the pending list.

/// What the model writes for the person type, its title first, as the sync's prompt asks.
private let personAnswer = """
{
  "title": "Person",
  "type": "object",
  "properties": {
    "name": {
      "type": "string"
    },
    "email": {
      "type": "string"
    }
  }
}
"""

/// The first minute's tasks that take more presses than clicks, each "<gap>, <slice id>".
let firstMinutePending: [String] = []

@MainActor let firstMinuteKeysTests = Suite("The first minute by the keys", [
    test("a note, its words, a type, its fields, two notes connected and a frame around them each take no more presses than clicks, typing aside (P12)") {
        let model = ScriptedLanguageModel()
        let w = try EmptyBoardWindow(model: model)
        defer { w.board.close() }
        let walk = w.walk()
        let editor = w.editor
        var gaps: [String] = [], said: [String] = []
        /// A task done by `keys`, against the clicks the pointer takes for it.
        @MainActor func task(_ name: String, clicks: Int, _ keys: @MainActor () -> Void) {
            let before = walk.presses.count
            keys()
            let presses = walk.presses.count - before
            said.append("\(name): \(presses) presses, \(clicks) clicks")
            if presses > clicks { gaps.append("\(name): \(presses) presses to \(clicks) clicks") }
        }
        // By the pointer: the Note tool, then the canvas. By the keys, Insert › Note's ⇧Return.
        task("a note", clicks: 2) {
            walk.press(Chord(Key.return, .shift))
        }
        let person = try require(editor.editingShapeID, "a note edited")
        task("its words", clicks: 0) { w.type("Someone we work with", with: walk) }
        // `/is-a type` on a line of its own, typed; the list's Type row picked: by the pointer, a click on it. The model
        // writes its fields from its words.
        model.queue(personAnswer)
        task("a type", clicks: 1) {
            w.type("\r/is-a type", with: walk)
            walk.press(.return)
        }
        expect(editor.types?.isType(person) == true, "a type: \(walk.traceText)")
        // Done with it: by the pointer, a click away.
        task("its fields", clicks: 1) { walk.press(.escape) }
        w.window.spin(until: { editor.typeSync?.status(of: person) == .idle && editor.document[person]?[TitleProperty.self] != nil }, timeout: 5)
        let schema = editor.document[person]?[TypeSchemaProperty.self]?.text ?? ""
        expect(schema.contains("email") && schema.contains("name"), "its fields: \(schema)")
        expectEqual(editor.document[person]?[TitleProperty.self], "Person")
        // By the pointer: the Note tool and the canvas, twice, and a port's drag from one to the other.
        task("two notes connected", clicks: 5) {
            walk.press(Chord(Key.return, .shift))
            w.type("Ada", with: walk)
            walk.press(Chord(Key.return, .shift))
            w.type("Grace", with: walk)
            walk.press(.escape)
            // Grace lands right of Ada, the view panning (T1 panel 3): nothing joins Ada to the type it would pan off, so the pan
            // takes away nothing the person works with (UX walk 4 firstminute-4-2), and ⌥⇧⌘← extends to Ada, as approved.
            walk.press(Chord(Key.left, [.option, .shift, .command]))
            walk.press(Chord("l", .command))
        }
        let named = { (text: String) in w.notes.first { $0.typed(as: StickyNote.self)?.props.text.plainText() == text }?.id }
        let ada = try require(named("Ada"), "Ada: \(walk.traceText)"), grace = try require(named("Grace"), "Grace: \(walk.traceText)")
        let joining = editor.document.shapes.filter { $0.kind != StickyNote.kind && $0.kind != Frame.kind }
        expectEqual(joining.count, 1, "one arrow joins them: \(walk.traceText)")
        expectEqual(Set(editor.selectedShapeIDs), [ada, grace], "both selected")
        // By the pointer: the Frame tool and its drag around both.
        task("a frame around them", clicks: 2) { walk.press(Chord("f", [.command, .shift])) }
        let frame = try require(editor.document.shapes.first { $0.kind == Frame.kind }, "a frame: \(walk.traceText)")
        for note in [ada, grace] { expectEqual(editor.holder(of: note), frame.id, "in the frame") }
        expectEqual(editor.holder(of: person), nil, "the type stays out of it")
        walk.pending = firstMinutePending
        walk.expectGaps(gaps)
    },
])

import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Foundation
import Geometry
import LanguageModels
import Mentions
import ProseMaps
import Selection
import StickyNotes
import TestKit
import Titles
import Types

// A note that's a type (Types: a note that holds a schema): its highlights drawn under its text by
// its render, under its editor too; its editor following the sync, read-only and faint while the
// model writes its text, showing what lands; and the popover its highlights show in the editor.

/// Sends Return to a text view as a key, with `modifiers`.
@MainActor func pressReturn(_ textView: NSTextView, _ modifiers: NSEvent.ModifierFlags = []) {
    textView.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 1, windowNumber: 0, context: nil,
                                            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!)
}

/// What a type note says and is: the owner's example, and what the model linked in the evals.
let jiraWords = "a jira ticket we point to: its key, a one-line summary and a link to it"
let jiraSchema = """
{
  "type": "object",
  "properties": {
    "key": {
      "type": "string",
      "pattern": "^[A-Z][A-Z0-9]+-[0-9]+$"
    },
    "summary": {
      "type": "string",
      "maxLength": 255
    },
    "url": {
      "type": "string",
      "format": "uri"
    }
  },
  "required": ["key", "summary", "url"]
}
"""
let jiraAnswer = #"[{"text": "jira ticket", "address": ""}, {"text": "key", "address": "/properties/key"}, {"text": "one-line", "address": "/properties/summary/maxLength"}, {"text": "summary", "address": "/properties/summary"}, {"text": "link to it", "address": "/properties/url"}]"#
/// A schema of three fields, as the model writes one: its title first, which the note keeps as its name.
let petSchema = """
{
  "title": "Pet",
  "type": "object",
  "properties": {
    "name": {
      "type": "string"
    },
    "birthYear": {
      "type": "integer"
    }
  }
}
"""

/// The note's plugins, Types among them, a scripted model answering highlights with `answer` and
/// the sync from its queue, and prose maps; time moving only when the test says.
@MainActor
final class TypeNoteBench {
    let model = ScriptedLanguageModel()
    let harness: EditorHarness
    var editor: CanvasEditor { harness.editor }
    var scheduler: ManualScheduler { harness.scheduler }
    var answer: Result<ModelResponse, LanguageModelError> = .success(ModelResponse(text: jiraAnswer))

    init() throws {
        ProseMapService.forgetEveryAnswer()
        ProseHighlights.forgetEverything()
        let model = model
        harness = try EditorHarness { scheduler in
            CanvasEditor(registry: try Registry(plugins: notePlugins + [LanguageModelsPlugin(model: model), ProseMapsPlugin()]), scheduler: scheduler)
        }
        model.fallback = { [unowned self] request in
            request.messages.first?.text.hasPrefix("<prose>") == true ? self.answer : .failure(.server(status: 0, message: "no answer queued"))
        }
    }

    var sync: TypeSync<TypeSchemaProperty> { editor.typeSync! }
    func status(_ id: ShapeID) -> TypeSyncStatus { sync.status(of: id) }

    /// A type note saying `words`, at `origin`.
    func add(_ schema: String, words: String, at origin: CGPoint = CGPoint(x: 100, y: 100), width: CGFloat = 320) -> ShapeID {
        var note = ShapeRecord(StickyNote(frame: CGRect(origin: origin, size: CGSize(width: width, height: 200)), text: MentionText(plain: words)))
        note[TypeSchemaProperty.self] = SchemaText(schema)
        let record = AnyShapeRecord(note)
        editor.transact { $0.insert(record) }
        return record.id
    }

    func note(_ id: ShapeID) -> StickyNote? { editor.document[id]?.typed(as: StickyNote.self)?.props }
    func schema(_ id: ShapeID) -> String? { editor.document[id]?[TypeSchemaProperty.self]?.text }

    /// A frame of the canvas, as the canvas draws it, and every highlights call landed.
    func frame(size: CGSize = CGSize(width: 800, height: 600)) {
        _ = renderBitmap(editor, size: size)
        spinRunLoop(until: { self.editor.proseMaps?.callsOut == 0 && self.editor.proseMaps?.callsWaiting == 0 })
    }

    /// Where the note's highlight of `words` is drawn, its first line, in world units.
    func line(of words: String, on id: ShapeID) throws -> CGRect {
        let record = try require(editor.document[id])
        let text = try require(note(id)).text.stored as NSString
        let placed = TypeHighlights.placed(for: record, in: editor)
        let index = try require(placed.firstIndex { text.substring(with: $0.range) == words }, "no highlight of \(words)")
        return try require(TypeHighlights.lines(for: record, in: editor)[index].first)
    }

    func settle() {
        for _ in 0..<10 { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.002)) }
    }
}

/// Whether a pixel (0...255, as `pixel` reads it) of a note's yellow (255, 222, 115) has a field's
/// pale blue over it (about 220, 206, 137).
private func isFieldTinted(_ pixel: [Int]) -> Bool { pixel[2] >= 128 && pixel[0] <= 240 }

@MainActor let typeNoteTests = Suite("Type notes", [
    test("a type note's highlights are drawn under its text, from its render; a note that isn't a type has none") {
        let b = try TypeNoteBench()
        let id = b.add(jiraSchema, words: jiraWords)
        b.frame()
        let key = try b.line(of: "key", on: id)
        let drawn = renderBitmap(b.editor, size: CGSize(width: 500, height: 360))
        expect(isFieldTinted(pixel(drawn, at: CGPoint(x: key.minX + 1, y: key.minY + 1))), "behind the field's words: \(pixel(drawn, at: CGPoint(x: key.minX + 1, y: key.minY + 1)))")
        b.editor.removeType(id)
        let plain = renderBitmap(b.editor, size: CGSize(width: 500, height: 360))
        expect(!isFieldTinted(pixel(plain, at: CGPoint(x: key.minX + 1, y: key.minY + 1))), "no longer a type: the note's yellow")
    },
    test("editing a type note keeps its highlights, where the canvas draws them, under its text: pixel for pixel but anti-aliasing, at 1× and 2×, zoomed in and out") {
        for (scale, zoom) in [(1, 1), (2, 1), (1, 2), (2, 0.6)] as [(CGFloat, CGFloat)] {
            let b = try TypeNoteBench()
            b.editor.camera.setZoom(zoom, around: .zero)
            let id = b.add(jiraSchema, words: jiraWords)
            b.frame()
            let frame = try require(b.editor.document[id]?.box)
            let size = CGSize(width: (frame.maxX + 20) * zoom, height: (frame.maxY + 20) * zoom), inView = b.editor.camera.toView(frame)
            let drawn = renderBitmap(b.editor, size: size, scale: scale)
            let key = b.editor.camera.toView(try b.line(of: "key", on: id))
            expect(isFieldTinted(pixel(drawn, at: CGPoint(x: key.minX + 1, y: key.minY + 1), scale: scale)), "at \(scale)×, zoom \(zoom): drawn")
            expect(b.editor.beginEditing(id))
            let edited = renderBitmap(b.editor, size: size, scale: scale, editing: try require(b.editor.makeEditingView()))
            let difference = largestDifference(drawn, edited, in: inView, excluding: [], scale: scale)
            expect(difference <= antiAliasing, "at \(scale)×, zoom \(zoom): a pixel differs by \(difference)")
            b.editor.endEditing()
        }
    },
    test("in the editor, words kept as the text's typed keep their highlights; words typed over lose theirs") {
        let b = try TypeNoteBench()
        let id = b.add(jiraSchema, words: jiraWords)
        b.frame()
        let size = CGSize(width: 500, height: 360)
        let key = try b.line(of: "key", on: id), link = try b.line(of: "link to it", on: id)
        expect(b.editor.beginEditing(id))
        let editing = try require(b.editor.makeEditingView())
        let textView = try require(editing.firstResponder as? NSTextView)
        var shown = renderBitmap(b.editor, size: size, editing: editing)
        expect(isFieldTinted(pixel(shown, at: CGPoint(x: key.minX + 1, y: key.minY + 1))), "the caret placed: still there")
        let at = (textView.string as NSString).range(of: "link to it")
        textView.insertText("url", replacementRange: at)
        textView.insertText("Its ", replacementRange: NSRange(location: 0, length: 0))
        shown = renderBitmap(b.editor, size: size, editing: editing)
        expect(b.note(id)?.text.stored.hasPrefix("Its a jira ticket") == true)
        expect(!isFieldTinted(pixel(shown, at: CGPoint(x: link.minX + 1, y: link.minY + 1))), "typed over")
        let moved = try b.line(of: "key", on: id)
        expect(moved.minX > key.minX, "along with what's typed before it")
        expect(isFieldTinted(pixel(shown, at: CGPoint(x: moved.minX + 1, y: moved.minY + 1))), "kept, where it's gone")
    },
    test("in the editor, resting the pointer on a highlight's words shows their popover over the editor; typing takes it down") {
        let b = try TypeNoteBench()
        let id = b.add(jiraSchema, words: jiraWords)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        let canvas = CanvasView(editor: b.editor)
        canvas.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        window.contentView = canvas
        window.settle()
        b.frame()
        let summary = try b.line(of: "summary", on: id)
        b.editor.selection = id
        expect(b.editor.beginEditing(id))
        window.spin { canvas.descendants(NSTextView.self).first != nil }
        let view = try require(canvas.descendants(NSTextView.self).first)
        window.makeFirstResponder(view)
        window.settle()
        let point = canvas.convert(b.editor.camera.toView(CGPoint(x: summary.midX, y: summary.midY)), to: nil)
        view.mouseMoved(with: window.mouse(.mouseMoved, at: CGPoint(x: point.x, y: window.contentView!.frame.height - point.y), time: 1))
        b.scheduler.advance(by: .milliseconds(500))
        window.spin { b.editor.popover != nil }
        expectEqual(b.editor.popover?.text.string, "\"summary\": {\n  \"type\": \"string\",\n  \"maxLength\": 255\n}")
        expect(canvas.popoverView != nil && canvas.subviews.last === canvas.popoverView, "over the editor")
        window.type("x")
        expect(b.editor.popover == nil, "typing takes it down")
        b.editor.endEditing()
    },
    test("while the model writes a type note's text, its editor is read-only and faint, and shows the text once it lands") {
        let b = try TypeNoteBench()
        let id = b.add(petSchema, words: "", at: .zero, width: 200)
        b.model.holdsAnswers = true
        b.model.queue("A pet: its name and birth year, and a good deal more about it, enough for a second line or three.")
        b.editor.transact { $0.update(id) { $0[TypeSchemaProperty.self] = SchemaText(petSchema.replacingOccurrences(of: "\"integer\"", with: "\"number\"")) } }
        b.sync.commit(id)
        spinRunLoop(until: { b.model.waiting == 1 })
        expectEqual(b.status(id), .updating(.words))
        b.editor.selection = id
        expect(b.harness.key("\r"))
        let editing = try require(b.editor.makeEditingView())
        let textView = try require(editing.firstResponder as? NSTextView)
        expect(!textView.isEditable, "the model is writing it")
        expect(textView.alphaValue < 1, "faint")
        pressReturn(textView)
        expectEqual(textView.string, "", "Return types nothing")
        b.model.release()
        spinRunLoop(until: { b.status(id) == .idle && textView.isEditable })
        expectEqual(textView.string, "A pet: its name and birth year, and a good deal more about it, enough for a second line or three.", "what landed")
        expectEqual(textView.alphaValue, 1)
        expectEqual(b.note(id)?.text, "A pet: its name and birth year, and a good deal more about it, enough for a second line or three.")
        textView.insertText(" Its weight too.", replacementRange: NSRange(location: textView.string.count, length: 0))
        expectEqual(b.note(id)?.text, "A pet: its name and birth year, and a good deal more about it, enough for a second line or three. Its weight too.",
                    "typed after what landed")
        b.editor.endEditing()
    },
    test("read-only while the model writes its text, ⌘↩ still ends editing") {
        let b = try TypeNoteBench()
        let id = b.add(petSchema, words: "", at: .zero, width: 200)
        b.model.holdsAnswers = true
        b.model.queue("A pet: its name and birth year.")
        b.editor.transact { $0.update(id) { $0[TypeSchemaProperty.self] = SchemaText(petSchema.replacingOccurrences(of: "\"integer\"", with: "\"number\"")) } }
        b.sync.commit(id)
        spinRunLoop(until: { b.model.waiting == 1 })
        b.editor.selection = id
        expect(b.harness.key("\r"))
        let textView = try require(b.editor.makeEditingView()?.firstResponder as? NSTextView)
        expect(!textView.isEditable)
        pressReturn(textView, .command)
        expectEqual(b.editor.editingShapeID, nil, "⌘↩ ends it")
        b.model.release()
        spinRunLoop(until: { b.status(id) == .idle })
    },
    test("once editing a type note ends, however it ends, its words ask for the schema, the next turn; before that, only after 3 s idle") {
        let b = try TypeNoteBench()
        let id = b.add(TypeSchemaProperty.starter, words: "", at: .zero, width: 200)
        b.editor.selection = id
        expect(b.harness.key("\r"))
        let textView = try require(b.editor.makeEditingView()?.firstResponder as? NSTextView)
        textView.insertText("a pet in my household", replacementRange: NSRange(location: 0, length: 0))
        b.settle()
        expectEqual(b.model.requests.count, 0, "not while it's typed")
        b.model.queue(petSchema)
        b.harness.move(to: CGPoint(x: 600, y: 400))
        b.harness.press(); b.harness.release()          // a click on the canvas
        expectEqual(b.editor.editingShapeID, nil)
        b.scheduler.advance(by: .zero)
        expectEqual(b.status(id), .updating(.schema), "asked the next turn")
        spinRunLoop(until: { b.status(id) == .idle })
        expectEqual(b.model.lastRequest?.messages, [.user("<prompt>\na pet in my household\n</prompt>\n\n<schema>\n\(TypeSchemaProperty.starter)\n</schema>")])
        expectEqual(b.editor.undoHistory.undoName, "Update Schema", "a step of its own")
        expectEqual(b.editor.document[id]?[TitleProperty.self], "Pet", "the untitled note named by the model's title")
        // Looked at and left as it was: nothing asked.
        b.editor.selection = id
        expect(b.harness.key("\r"))
        _ = try require(b.editor.makeEditingView())
        b.editor.endEditing()
        b.scheduler.advance(by: .zero)
        b.settle()
        expectEqual(b.model.requests.count, 1, "in step")
        // A pause while typing asks too.
        b.model.queue(petSchema.replacingOccurrences(of: "\"birthYear\"", with: "\"weight\""))
        expect(b.harness.key("\r"))
        let typing = try require(b.editor.makeEditingView()?.firstResponder as? NSTextView)
        typing.insertText(", and its weight", replacementRange: NSRange(location: (typing.string as NSString).length, length: 0))
        b.scheduler.advance(by: .seconds(3))
        expectEqual(b.status(id), .updating(.schema), "asked after 3 s, still editing")
        expectEqual(b.editor.editingShapeID, id)
        spinRunLoop(until: { b.status(id) == .idle })
        expect(b.schema(id)?.contains("weight") == true)
    },
    test("editing that ends commits only an edit still waiting: looking in and out asks nothing, a failure stays, and an undo or a file put in place that ends it asks nothing") {
        let b = try TypeNoteBench()
        let id = b.add(TypeSchemaProperty.starter, words: "", at: .zero, width: 200)
        b.editor.selection = id
        expect(b.harness.key("\r"))
        let textView = try require(b.editor.makeEditingView()?.firstResponder as? NSTextView)
        textView.insertText("a pet", replacementRange: NSRange(location: 0, length: 0))
        b.model.queue("", stopReason: .refusal)
        b.editor.endEditing()
        b.scheduler.advance(by: .zero)
        spinRunLoop(until: { b.status(id) != .updating(.schema) })
        let declined = TypeSyncStatus.failed(TypeSyncFailure(writing: .schema, "Claude declined", remedy: .editByHand))
        expectEqual(b.status(id), declined)
        // Looked into and left: a decline isn't asked again, since it would be again.
        expect(b.harness.key("\r"))
        _ = try require(b.editor.makeEditingView())
        b.editor.endEditing()
        b.scheduler.advance(by: .zero)
        b.settle()
        expectEqual(b.model.requests.count, 1)
        expectEqual(b.status(id), declined, "the failure stays")
        // Typed, and taken back by an undo that ends the editing: nothing to ask.
        expect(b.harness.key("\r"))
        let again = try require(b.editor.makeEditingView()?.firstResponder as? NSTextView)
        again.insertText(" in my household", replacementRange: NSRange(location: (again.string as NSString).length, length: 0))
        b.editor.undo()
        b.scheduler.advance(by: .seconds(5))
        b.settle()
        expectEqual(b.note(id)?.text.stored, "a pet")
        expectEqual(b.model.requests.count, 1, "the undo took back what would have been asked")
        // Typed, and the file put in place as it was on disk (a revert of an autosaved file): the
        // type is taken afresh, with nothing waiting.
        expect(b.harness.key("\r"))
        let third = try require(b.editor.makeEditingView()?.firstResponder as? NSTextView)
        third.insertText(" in my household", replacementRange: NSRange(location: (third.string as NSString).length, length: 0))
        b.editor.replaceFile(with: b.editor.file)
        b.scheduler.advance(by: .seconds(5))
        b.settle()
        expectEqual(b.note(id)?.text.stored, "a pet in my household")
        expectEqual(b.model.requests.count, 1, "nothing waits for, or asks about, a type a file put in place")
        expectEqual(b.status(id), .idle)
    },
])

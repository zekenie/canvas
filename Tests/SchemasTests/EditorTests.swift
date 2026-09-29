import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Foundation
import Geometry
import LanguageModels
import Schemas
import Selection
import TestKit

/// Sends Return to a text view as a key, with `modifiers`.
@MainActor func pressReturn(_ textView: NSTextView, _ modifiers: NSEvent.ModifierFlags = []) {
    textView.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 1, windowNumber: 0, context: nil,
                                            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!)
}

/// The most a pixel may differ, in any channel (0...255), between the card's render and its editor
/// over it: anti-aliasing. A line a point off differs by more than 200.
let antiAliasing = 16

@MainActor let editorTests = Suite("Schema card description", [
    test("S and a click place an empty card, 240 × 52, centered there, its description being edited, in Select") {
        let h = try EditorHarness(plugins: schemaPlugins())
        expect(h.key("s"))
        h.press(at: CGPoint(x: 300, y: 300)); h.release()
        let record = try require(h.editor.document.shapes.first)
        expectEqual(record.box, CGRect(x: 180, y: 274, width: 240, height: 52))
        expectEqual(record.typed(as: SchemaCard.self)?.props, SchemaCard(frame: CGRect(x: 180, y: 274, width: 240, height: 52)))
        expectEqual(h.editor.editingShapeID, record.id)
        expectEqual(h.editor.currentToolID, .select)
        expectEqual(h.editor.issues(record.id), [], "an empty schema is a schema")
    },
    test("typing writes the description; the card grows with it, in the typing's step, and shrinks back, never under a line") {
        let h = try EditorHarness(plugins: schemaPlugins())
        let id = h.add(SchemaCard(frame: CGRect(x: 0, y: 0, width: 240, height: 52)))
        h.editor.replaceDocument(with: h.editor.document)
        h.editor.selection = id
        expect(h.key("\r"), "Return edits it, as a note's")
        let editing = try require(h.editor.makeEditingView())
        let textView = try require(editing.firstResponder as? NSTextView)
        @MainActor func height() -> CGFloat? { h.editor.document[id]?.box?.height }
        textView.insertText("a pet", replacementRange: NSRange(location: 0, length: 0))
        expectEqual(h.editor.schemaCard(id)?.prompt, "a pet")
        expectEqual(height(), cardHeight(lines: 1))
        textView.insertText("\nits name\nits species", replacementRange: NSRange(location: textView.string.count, length: 0))
        expectEqual(height(), cardHeight(lines: 3))
        expectEqual(h.editor.document[id]?.box?.origin, .zero, "from its top")
        // The editor over it grows with it, as the canvas lays it out.
        editing.view.frame = CGRect(x: 0, y: 0, width: 240, height: cardHeight(lines: 3))
        editing.view.bounds = CGRect(x: 0, y: 0, width: 240, height: cardHeight(lines: 3))
        expectEqual(textView.frame.height, cardHeight(lines: 3))
        textView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        expectEqual(h.editor.editingShapeID, nil, "Escape ends it")
        expectEqual(h.editor.schemaCard(id)?.prompt, "a pet\nits name\nits species", "keeping what's typed")
        expectEqual(h.editor.undoHistory.undoName, "Typing", "growing is part of the typing's step")
        h.editor.undo()
        expectEqual(height(), cardHeight(lines: 1))
        expectEqual(h.editor.schemaCard(id)?.prompt, "")
        h.editor.redo()
        expectEqual(height(), cardHeight(lines: 3))
        expect(h.key("\r"))
        let again = try require(h.editor.makeEditingView()?.firstResponder as? NSTextView)
        again.selectAll(nil)
        again.insertText("a pet", replacementRange: again.selectedRange())
        expectEqual(height(), cardHeight(lines: 1), "back to a line's")
    },
    test("Return says the description is done and ends editing, keeping what's typed; ⇧↩ is a new line; ⌘↩ ends it too") {
        let h = try EditorHarness(plugins: schemaPlugins())
        let id = h.add(SchemaCard(frame: CGRect(x: 0, y: 0, width: 240, height: 52)))
        h.editor.selection = id
        expect(h.key("\r"))
        let textView = try require(h.editor.makeEditingView()?.firstResponder as? NSTextView)
        textView.insertText("a pet", replacementRange: NSRange(location: 0, length: 0))
        pressReturn(textView, .shift)
        expectEqual(h.editor.editingShapeID, id, "⇧↩ is the text's")
        textView.insertText("in my household", replacementRange: NSRange(location: textView.string.count, length: 0))
        pressReturn(textView)
        expectEqual(h.editor.editingShapeID, nil, "Return is done")
        expectEqual(h.editor.schemaCard(id)?.prompt, "a pet\nin my household")
        expect(h.key("\r"))
        let again = try require(h.editor.makeEditingView()?.firstResponder as? NSTextView)
        pressReturn(again, .command)
        expectEqual(h.editor.editingShapeID, nil, "⌘↩ too")
        expectEqual(h.editor.schemaCard(id)?.prompt, "a pet\nin my household")
    },
    test("placing a card and typing into it are one undo step, Add Schema") {
        let h = try EditorHarness(plugins: schemaPlugins())
        h.key("s")
        h.press(at: CGPoint(x: 300, y: 300)); h.release()
        let id = try require(h.editor.editingShapeID)
        let textView = try require(h.editor.makeEditingView()?.firstResponder as? NSTextView)
        textView.insertText("a pet", replacementRange: NSRange(location: 0, length: 0))
        h.editor.endEditing()
        expectEqual(h.editor.undoHistory.undoName, "Add Schema")
        h.editor.undo()
        expectEqual(h.editor.document[id], nil, "one undo takes the card and its description")
    },
    test("a card too short for its description (drawn with a size) grows to it as editing begins, in the editing's step; a taller one keeps its height") {
        let h = try EditorHarness(plugins: schemaPlugins())
        let short = h.add(SchemaCard(frame: CGRect(x: 0, y: 0, width: 240, height: 52), prompt: "a pet\nits name\nits species"))
        let tall = h.add(SchemaCard(frame: CGRect(x: 300, y: 0, width: 240, height: 300), prompt: "a pet"))
        h.editor.replaceDocument(with: h.editor.document)
        h.editor.selection = short
        expect(h.key("\r"))
        let editing = try require(h.editor.makeEditingView())
        expectEqual(h.editor.document[short]?.box?.height, cardHeight(lines: 3), "all of it, before anything's typed")
        expectEqual(try require(editing.firstResponder as? NSTextView).frame.height, cardHeight(lines: 3))
        h.editor.endEditing()
        expectEqual(h.editor.undoHistory.undoName, "Typing")
        h.editor.undo()
        expectEqual(h.editor.document[short]?.box?.height, 52)
        h.editor.selection = tall
        expect(h.key("\r"))
        _ = try require(h.editor.makeEditingView())
        expectEqual(h.editor.document[tall]?.box?.height, 300, "a card drawn taller keeps its height until it's typed into")
        h.editor.endEditing()
        expect(!h.editor.canUndo, "a card that fits wrote nothing")
    },
    test("once editing ends, however it ends, the description asks for the schema, the next turn; before that, only after 3 s idle") {
        let b = try SyncBench()
        let id = b.place()
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
        expectEqual(b.model.lastRequest?.messages, [.user("<prompt>\na pet in my household\n</prompt>\n\n<schema>\n\(SchemaCard.starter)\n</schema>")])
        expectEqual(b.card(id)?.schema, petSchema)
        expectEqual(b.editor.undoHistory.undoName, "Update Schema", "a step of its own")
        // Looked at and left as it was: nothing asked.
        b.editor.selection = id                          // the click let go of it
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
        typing.insertText(", and its weight", replacementRange: NSRange(location: typing.string.count, length: 0))
        b.scheduler.advance(by: .seconds(3))
        expectEqual(b.status(id), .updating(.schema), "asked after 3 s, still editing")
        expectEqual(b.editor.editingShapeID, id)
        spinRunLoop(until: { b.status(id) == .idle })
        expect(b.card(id)?.schema.contains("weight") == true)
    },
    test("editing that ends commits only an edit still waiting: looking in and out asks nothing, a failure stays, and an undo or a file put in place that ends it asks nothing") {
        let b = try SyncBench()
        let id = b.place()
        b.editor.selection = id
        expect(b.harness.key("\r"))
        let textView = try require(b.editor.makeEditingView()?.firstResponder as? NSTextView)
        textView.insertText("a pet", replacementRange: NSRange(location: 0, length: 0))
        b.model.queue("", stopReason: .refusal)
        b.editor.endEditing()
        b.scheduler.advance(by: .zero)
        spinRunLoop(until: { !b.isUpdating(id) })
        let declined = SchemaSyncStatus.failed(SchemaSyncFailure(writing: .schema, "Claude declined", remedy: .editByHand))
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
        expectEqual(b.card(id)?.prompt, "a pet")
        expectEqual(b.model.requests.count, 1, "the undo took back what would have been asked")
        // Typed, and the file put in place as it was on disk (a revert of an autosaved file): the
        // card is taken afresh, with nothing waiting.
        expect(b.harness.key("\r"))
        let third = try require(b.editor.makeEditingView()?.firstResponder as? NSTextView)
        third.insertText(" in my household", replacementRange: NSRange(location: (third.string as NSString).length, length: 0))
        b.editor.replaceFile(with: b.editor.file)
        b.scheduler.advance(by: .seconds(5))
        b.settle()
        expectEqual(b.card(id)?.prompt, "a pet in my household")
        expectEqual(b.model.requests.count, 1, "nothing waits for, or asks about, a card a file put in place")
        expectEqual(b.status(id), .idle)
    },
    test("read-only while the model writes the description, Return and ⌘↩ still end editing, as Escape does") {
        let b = try SyncBench()
        let id = b.editor.add(card(petSchema, at: .zero))
        b.model.holdsAnswers = true
        b.model.queue("A pet: its name, species and birth year.")
        b.typeSchema(id, petSchema.replacingOccurrences(of: "\"integer\"", with: "\"number\""))
        b.sync.commit(id)
        spinRunLoop(until: { b.model.waiting == 1 })
        b.editor.selection = id
        for modifiers in [[], .command] as [NSEvent.ModifierFlags] {
            expect(b.harness.key("\r"))
            let textView = try require(b.editor.makeEditingView()?.firstResponder as? NSTextView)
            expect(!textView.isEditable)
            pressReturn(textView, modifiers)
            expectEqual(b.editor.editingShapeID, nil, "\(modifiers.contains(.command) ? "⌘↩" : "Return") ends it")
        }
        b.model.release()
        spinRunLoop(until: { b.status(id) == .idle })
        expectEqual(b.model.requests.count, 1, "nothing typed, nothing asked")
    },
    test("while the model writes the description, the card's editor is read-only and faint, and shows the description once it lands") {
        let b = try SyncBench()
        let id = b.editor.add(card(petSchema, at: .zero))
        b.model.holdsAnswers = true
        b.model.queue("A pet: its name, species and birth year.")
        b.typeSchema(id, petSchema.replacingOccurrences(of: "\"integer\"", with: "\"number\""))
        b.sync.commit(id)
        spinRunLoop(until: { b.model.waiting == 1 })
        expectEqual(b.status(id), .updating(.prompt))
        b.editor.selection = id
        expect(b.harness.key("\r"))
        let editing = try require(b.editor.makeEditingView())
        let textView = try require(editing.firstResponder as? NSTextView)
        expect(!textView.isEditable, "the model is writing it")
        expect(textView.alphaValue < 1, "faint")
        b.model.release()
        spinRunLoop(until: { b.status(id) == .idle && textView.isEditable })
        expectEqual(textView.string, "A pet: its name, species and birth year.", "what landed")
        expectEqual(textView.alphaValue, 1)
        expectEqual(b.card(id)?.prompt, "A pet: its name, species and birth year.")
        expectEqual(b.card(id)?.frame.height, cardHeight(lines: 2), "the card fitted to it")
        textView.insertText(" Its weight too.", replacementRange: NSRange(location: textView.string.count, length: 0))
        expectEqual(b.card(id)?.prompt, "A pet: its name, species and birth year. Its weight too.", "typed after what landed")
    },
    test("its text falls on the render's lines, pixel for pixel but anti-aliasing, at 1× and 2×, zoomed in and out: nothing moves as editing starts") {
        for (scale, zoom) in [(1, 1), (2, 1), (1, 2), (2, 0.6)] as [(CGFloat, CGFloat)] {
            let editor = try schemaEditor()
            editor.camera.setZoom(zoom, around: .zero)
            let id = editor.add(card(fixture(3), prompt: petPrompt, at: CGPoint(x: 20, y: 15)))
            let frame = try require(editor.document[id]?.box)
            let size = CGSize(width: 280 * zoom, height: (frame.maxY + 20) * zoom), inView = editor.camera.toView(frame)
            let drawn = renderBitmap(editor, size: size, scale: scale)
            expect(editor.beginEditing(id))
            let fill = renderBitmap(editor, size: size, scale: scale)       // the canvas leaves the text to the editing view
            let edited = renderBitmap(editor, size: size, scale: scale, editing: try require(editor.makeEditingView()))
            let tops = lineTops(drawn, over: fill, in: inView, scale: scale)
            expectEqual(tops.count, 5, "at \(scale)×, zoom \(zoom): the render's lines")
            expectEqual(lineTops(edited, over: fill, in: inView, scale: scale), tops, "at \(scale)×, zoom \(zoom): the editor's lines")
            let difference = largestDifference(drawn, edited, in: inView, scale: scale)
            expect(difference <= antiAliasing, "at \(scale)×, zoom \(zoom): a pixel differs by \(difference)")
            editor.endEditing()
        }
    },
])

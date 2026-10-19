import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Colors
import Mentions
import Selection
import StickyNotes
import TestKit

// The keys in a note's editor that go on to another note (tldraw's adjacent notes): ⇧↩ puts a new note
// down beside the one edited, and Tab and ⇧Tab edit the next and previous note in reading order.

/// The text view of the note being edited.
@MainActor private func editingText(_ h: EditorHarness) throws -> NSTextView {
    try require(h.editor.makeEditingView()?.firstResponder as? NSTextView)
}

/// Tab, or ⇧Tab, sent to a text view as a key.
@MainActor private func pressTab(_ textView: NSTextView, back: Bool = false) {
    let typed = back ? "\u{19}" : "\t"
    textView.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: back ? .shift : [], timestamp: 1, windowNumber: 0,
                                            context: nil, characters: typed, charactersIgnoringModifiers: typed, isARepeat: false, keyCode: 48)!)
}

@MainActor private func text(of id: ShapeID, in h: EditorHarness) -> MentionText? {
    h.editor.document[id]?.typed(as: StickyNote.self)?.props.text
}

@MainActor let noteHopsTests = Suite("Going on to another note", [
    test("Tab and ⇧Tab in a note's editor edit the next and previous note in reading order, wrapping, each selected, what was typed kept") {
        let h = try EditorHarness(plugins: notePlugins)
        let a = h.add(StickyNote(frame: CGRect(x: 0, y: 0, width: 200, height: 200)))
        let c = h.add(StickyNote(frame: CGRect(x: 600, y: 20, width: 200, height: 200)))
        let b = h.add(StickyNote(frame: CGRect(x: 300, y: 0, width: 200, height: 200)))
        let d = h.add(StickyNote(frame: CGRect(x: 0, y: 400, width: 200, height: 200)))
        h.editor.selection = a
        expect(h.key("\r"))
        var textView = try editingText(h)
        textView.insertText("One", replacementRange: NSRange(location: 0, length: 0))
        for next in [b, c, d, a] {
            pressTab(textView)
            expectEqual(h.editor.editingShapeID, next)
            expectEqual(h.editor.selectedShapeIDs, [next])
            textView = try editingText(h)
        }
        pressTab(textView, back: true)
        expectEqual(h.editor.editingShapeID, d, "⇧Tab, back round from the first")
        expectEqual(text(of: a, in: h), "One")
        expect(!(try editingText(h).string.contains("\t")), "no tab typed")
    },
    test("Tab with no other note to go to does nothing, in the text too") {
        let h = try EditorHarness(plugins: notePlugins)
        let a = h.add(StickyNote(frame: CGRect(x: 0, y: 0, width: 200, height: 200)))
        h.editor.selection = a
        expect(h.key("\r"))
        let textView = try editingText(h)
        textView.insertText("One", replacementRange: NSRange(location: 0, length: 0))
        pressTab(textView)
        expectEqual(h.editor.editingShapeID, a)
        expectEqual(textView.string, "One")
    },
    test("⇧↩ in a note's editor puts a new note down beside it, in its color, and edits it: one step, Add Note, after the note's typing") {
        let h = try EditorHarness(plugins: notePlugins)
        var note = ShapeRecord(StickyNote(frame: CGRect(x: 0, y: 0, width: 200, height: 200)))
        note[ColorProperty.self] = ShapeColor("blue")
        let a = AnyShapeRecord(note)
        h.editor.transact { $0.insert(a) }
        h.editor.replaceDocument(with: h.editor.document)
        h.editor.selection = a.id
        expect(h.key("\r"))
        let textView = try editingText(h)
        textView.insertText("One", replacementRange: NSRange(location: 0, length: 0))
        pressReturn(textView, .shift)
        let made = try require(h.editor.editingShapeID)
        expect(made != a.id, "the new note is edited")
        expectEqual(h.editor.selectedShapeIDs, [made])
        expectEqual(text(of: a.id, in: h), "One", "what was typed kept")
        let old = try require(h.editor.document[a.id]?.box), new = try require(h.editor.document[made]?.box)
        expect(new.minX >= old.maxX, "to its right: \(new)")
        expect(new.minY < old.maxY && new.maxY > old.minY, "beside it, not above or below: \(new)")
        expectEqual(h.editor.document[made]?[ColorProperty.self], ShapeColor("blue"))
        try editingText(h).insertText("Two", replacementRange: NSRange(location: 0, length: 0))
        h.editor.endEditing()
        expectEqual(text(of: made, in: h), "Two")
        expectEqual(h.editor.undoHistory.undoName, "Add Note")
        h.editor.undo()
        expectEqual(h.editor.document[made], nil, "one undo takes the note and what was typed in it")
        expectEqual(text(of: a.id, in: h), "One")
        h.editor.undo()
        expectEqual(text(of: a.id, in: h), "", "then the first note's typing")
    },
    test("⇧↩ held makes one note: its repeats are kept from the new note's editor") {
        let h = try EditorHarness(plugins: notePlugins)
        let a = h.add(StickyNote(frame: CGRect(x: 0, y: 0, width: 200, height: 200)))
        h.editor.selection = a
        expect(h.key("\r"))
        pressReturn(try editingText(h), .shift)
        let made = try require(h.editor.editingShapeID)
        let repeated = try editingText(h)
        repeated.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 1, windowNumber: 0, context: nil,
                                                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: true, keyCode: 36)!)
        expectEqual(h.editor.document.shapes.count, 2)
        expectEqual(h.editor.editingShapeID, made)
        expectEqual(repeated.string, "", "nor a new line typed")
    },
    test("⇧↩ ends a note's editing only where it can go on; ↩ alone and ⌥↩ are the text's") {
        let h = try EditorHarness(plugins: notePlugins)
        let a = h.add(StickyNote(frame: CGRect(x: 0, y: 0, width: 200, height: 200)))
        h.editor.selection = a
        expect(h.key("\r"))
        let textView = try editingText(h)
        pressReturn(textView)
        pressReturn(textView, .option)
        expectEqual(h.editor.editingShapeID, a)
        expectEqual(h.editor.document.shapes.count, 1)
    },
])

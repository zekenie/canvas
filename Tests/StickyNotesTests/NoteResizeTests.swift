import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Geometry
import Mentions
import Selection
import StickyNotes
import TestKit

// A note resizes with Selection's handles on its paper (`CustomSizing`): it takes the width it's given and keeps a
// height it's given as the least it is, so its words rewrap, a side dragged past them stops there, and typing grows it
// past that height and brings it back as the words go. Never smaller than 80 by 52.

/// `count` short lines, each its own, so how tall they are doesn't depend on where they wrap.
private func lines(_ count: Int) -> String { (1...count).map { "x\($0)" }.joined(separator: "\n") }

/// How tall a note is for `count` lines: 19 points each, half a point spare rounded up, and the padding.
private func linesHeight(_ count: Int) -> CGFloat { CGFloat(count) * 19 + 1 + 32 }

/// Where a resize handle is on a frame.
private func point(of handle: ResizeHandle, on frame: CGRect) -> CGPoint {
    CGPoint(x: handle == .topLeft || handle == .left || handle == .bottomLeft ? frame.minX : handle == .top || handle == .bottom ? frame.midX : frame.maxX,
            y: handle == .topLeft || handle == .top || handle == .topRight ? frame.minY : handle == .left || handle == .right ? frame.midY : frame.maxY)
}

extension EditorHarness {
    @MainActor fileprivate func note(_ id: ShapeID) throws -> StickyNote {
        try require(editor.document[id]?.typed(as: StickyNote.self)).props
    }

    /// Presses `handle` of the paper `id` is laid out on, drags it `by` in two steps, and lets go.
    @MainActor fileprivate func resizeNote(_ id: ShapeID, _ handle: ResizeHandle, by delta: CGPoint) throws {
        let start = view(point(of: handle, on: try require(editor.shapeContext.frame(of: id))))
        move(to: start)
        press(at: start)
        drag(to: start + delta / 2)
        drag(to: start + delta)
        release()
    }

    /// Edits the note, puts `text` in place of its words, and ends editing.
    @MainActor fileprivate func type(_ text: String, into id: ShapeID) throws {
        expect(editor.beginEditing(id))
        let textView = try require(editor.makeEditingView()?.firstResponder as? NSTextView)
        textView.selectAll(nil)
        textView.insertText(text, replacementRange: textView.selectedRange())
        editor.endEditing()
    }
}

/// A note selected alone in an editor with nothing to undo.
@MainActor private func noteHarness(_ note: StickyNote) throws -> (EditorHarness, ShapeID) {
    let h = try EditorHarness(plugins: notePlugins)
    let id = h.add(note)
    h.editor.replaceDocument(with: h.editor.document)
    h.editor.selection = id
    return (h, id)
}

@MainActor let noteResizeTests = Suite("Resizing a note", [
    test("a selected note has handles on its paper; a corner's drag sizes it, one step, Resize, which undo takes back whole") {
        let (h, id) = try noteHarness(StickyNote(frame: CGRect(x: 100, y: 100, width: 260, height: 200), text: MentionText(plain: lines(3))))
        expectEqual(h.editor.handle(atViewPoint: CGPoint(x: 360, y: 300)), AnyHashable(ResizeHandle.bottomRight))
        try h.resizeNote(id, .bottomRight, by: CGPoint(x: 40, y: 60))
        expectEqual(try h.note(id).frame, CGRect(x: 100, y: 100, width: 300, height: 260))
        expectEqual(try h.note(id).givenHeight, 260)
        expectEqual(h.editor.undoHistory.undoName, "Resize")
        h.editor.undo()
        expectEqual(try h.note(id), StickyNote(frame: CGRect(x: 100, y: 100, width: 260, height: 200), text: MentionText(plain: lines(3))))
    },
    test("the height it's given is kept: typing grows it past and it comes back as the words go, where an unsized note comes back to a new one's") {
        let (h, id) = try noteHarness(StickyNote(frame: CGRect(x: 100, y: 100, width: 260, height: 200)))
        let other = h.add(StickyNote(frame: CGRect(x: 600, y: 100, width: 260, height: 200)))
        try h.resizeNote(id, .bottom, by: CGPoint(x: 0, y: 100))
        expectEqual(try h.note(id).frame.height, 300)
        try h.type(lines(20), into: id)
        expectEqual(try h.note(id).frame.height, linesHeight(20), "past it with its words")
        try h.type("", into: id)
        expectEqual(try h.note(id).frame.height, 300, "and back to it")
        try h.type(lines(20), into: other)
        try h.type("", into: other)
        expectEqual(try h.note(other).frame.height, 200, "a new note's height, as ever")
    },
    test("dragged above its words, the bottom stops there, and the top too with its bottom put; the words gone, it is as short as it was given") {
        let frame = CGRect(x: 100, y: 100, width: 200, height: linesHeight(14))
        let (h, id) = try noteHarness(StickyNote(frame: frame, text: MentionText(plain: lines(14))))
        try h.resizeNote(id, .bottom, by: CGPoint(x: 0, y: -150))
        expectEqual(try h.note(id).frame, frame, "no shorter than its words")
        expectEqual(try h.note(id).givenHeight, frame.height - 150)
        try h.resizeNote(id, .top, by: CGPoint(x: 0, y: 100))
        expectEqual(try h.note(id).frame, frame, "its bottom stays put, so nothing moves")
        expectEqual(try h.note(id).givenHeight, frame.height - 100)
        try h.type("", into: id)
        expectEqual(try h.note(id).frame.height, frame.height - 100, "as short as the height it was last given")
    },
    test("narrowed, its words wrap onto more lines and it grows; widened again, it comes back") {
        let words = MentionText(plain: Array(repeating: "words that wrap", count: 12).joined(separator: " "))
        let (h, id) = try noteHarness(StickyNote(frame: CGRect(x: 100, y: 100, width: 260, height: 200), text: words))
        let fitted = try require(h.editor.registry.derived(try require(h.editor.document[id])).box)
        h.editor.transact { $0.update(id) { $0.box = fitted } }
        try h.resizeNote(id, .right, by: CGPoint(x: -120, y: 0))
        let narrow = try h.note(id).frame
        expectEqual(narrow.width, 140)
        expect(narrow.height > fitted.height, "taller: \(narrow.height) over \(fitted.height)")
        expectEqual(narrow.origin, fitted.origin, "down from its top: a side's drag moves neither its top nor its left")
        expectEqual(try h.note(id).givenHeight, nil, "a side's drag gives no height")
        try h.resizeNote(id, .right, by: CGPoint(x: 120, y: 0))
        expectEqual(try h.note(id).frame, fitted)
    },
    test("⌥↑ at its words' height changes nothing and leaves no step; Escape mid-drag keeps words another writer put there") {
        let frame = CGRect(x: 100, y: 100, width: 200, height: linesHeight(14))
        let (h, id) = try noteHarness(StickyNote(frame: frame, text: MentionText(plain: lines(14))))
        h.hold(.option)
        expect(h.key("\u{F700}"))
        expectEqual(try h.note(id).frame, frame)
        expectEqual(try h.note(id).givenHeight, nil, "nothing written")
        expect(!h.editor.canUndo, "and no step")
        h.hold([])
        // A drag, a write from elsewhere while it runs, and Escape: the size goes back, the words stay.
        let corner = h.view(CGPoint(x: frame.maxX, y: frame.maxY))
        h.move(to: corner)
        h.press(at: corner)
        h.drag(to: corner + CGPoint(x: 40, y: 60))
        h.editor.transact { $0.update(id, as: StickyNote.self) { $0.props.text = MentionText(plain: "Written meanwhile") } }
        h.escape()
        expectEqual(try h.note(id).text, MentionText(plain: "Written meanwhile"))
        expectEqual(try h.note(id).frame.origin, frame.origin)
        expectEqual(try h.note(id).frame.size, frame.size)
        h.release()
    },
    test("never smaller than 80 by 52, a line of a few letters") {
        let (h, id) = try noteHarness(StickyNote(frame: CGRect(x: 100, y: 100, width: 260, height: 200)))
        try h.resizeNote(id, .topLeft, by: CGPoint(x: 400, y: 400))
        expectEqual(try h.note(id).frame, CGRect(x: 280, y: 248, width: 80, height: 52))
        expectEqual(StickyNote.minimumSize, CGSize(width: 80, height: 52))
        try h.type("x", into: id)
        expectEqual(try h.note(id).frame.height, 52, "one line fits")
    },
])

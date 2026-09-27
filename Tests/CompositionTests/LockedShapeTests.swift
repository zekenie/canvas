import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import Checklists
import Clipboard
import Composition
import CoreGraphics
import Foundation
import Locking
import Selection
import StickyNotes
import TestKit
import Titles

/// A board of the shipped plugins with nothing on it, its clipboard on a pasteboard of the test's own.
@MainActor private func emptyBoard(_ pasteboard: NSPasteboard = .withUniqueName()) -> EditorHarness {
    EditorHarness { ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: $0, pasteboard: pasteboard) }
}

@MainActor let lockedShapeTests = Suite("Locked shapes, as shipped", [
    test("the lock chip stays clear of a long title's pill and of the checklist chip, though none of the three knows the others' sizes") {
        // A note with the lock, its checklist (the chip, on its top-right corner) or its long title
        // (the pill, above its top-left corner, up to the corner the lock takes), or none of them.
        @MainActor func render(locked: Bool = false, checklist: Bool = false, title: Bool = false) -> NSBitmapImageRep {
            var note = AnyShapeRecord(ShapeRecord(StickyNote(frame: CGRect(x: 100, y: 100, width: 200, height: 200), text: "Buy milk")))
            note[TitleProperty.self] = title ? "A title much longer than the note is wide" : nil
            note[ChecklistProperty.self] = checklist ? [ChecklistItem(text: "oat milk")] : []
            if locked { note[LockedProperty.self] = true }
            let editor = ShippedPlugins.makeEditor(document: CanvasDocument(shapes: [note]), scheduler: ManualScheduler())
            return renderBitmap(editor, size: CGSize(width: 400, height: 340))
        }
        let plain = render(), lock = render(locked: true)
        let chip = render(checklist: true), pill = render(title: true)
        expect(changedPixels(plain, lock, in: CGRect(x: 286, y: 77, width: 10, height: 10)) > 90, "the lock, above the top-right corner")
        expect(changedPixels(plain, pill, in: CGRect(x: 100, y: 75, width: 170, height: 12)) > 1000, "the pill, nearly to the corner")
        for (name, other) in [("the pill", pill), ("the checklist chip", chip)] {
            var both = 0
            for y in 60..<130 {
                for x in 90..<330 {
                    let point = CGPoint(x: x, y: y), under = pixel(plain, at: point)
                    if pixel(lock, at: point) != under && pixel(other, at: point) != under { both += 1 }
                }
            }
            expectEqual(both, 0, "no pixel is both the lock chip's and \(name)'s")
        }
    },
    test("a locked note's copy is locked; cutting a locked note copies it and leaves it, shaking") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = emptyBoard(pasteboard)
        h.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        let note = h.add(StickyNote(frame: CGRect(x: 100, y: 100, width: 200, height: 200), text: "Keep"))
        h.editor.lock([note])
        h.editor.selection = note
        h.editor.copySelection()
        let before = h.editor.document
        h.editor.paste()
        let copy = try require(h.editor.shapes(since: before).first)
        expect(copy.isLocked, "copies keep what a shape knows, and a lock is that")
        expectEqual(copy.box, CGRect(x: 100, y: 100, width: 200, height: 200), "pasted in place")
        h.editor.selection = note
        h.editor.cutSelection()
        expect(h.editor.document[note] != nil)
        h.wait(16)
        expect(h.editor.drawingOffset(of: note) != .zero)
        let beforeSecond = h.editor.document
        h.editor.paste()
        expectEqual(h.editor.shapes(since: beforeSecond).count, 1, "it was copied all the same")
    },
    test("deleting a note a locked arrow is bound to lets the arrow go where it's drawn, and doesn't shake it") {
        let h = EditorHarness { ShippedPlugins.makeEditor(scheduler: $0) }
        let notes = h.editor.document.shapes.filter { $0.kind == StickyNote.kind }.map(\.id)
        let arrow = try require(h.editor.document.shapes.first { $0.typed(as: Arrow.self)?.props.end.binding?.shapeID == notes[1] }?.id)
        let drawn = try require(h.editor.arrowGeometry(of: arrow)).bodyPath.boundingBoxOfPath
        h.editor.lock([arrow])
        h.editor.selection = notes[1]
        h.editor.perform(.delete)
        expectEqual(h.editor.document[notes[1]], nil)
        let props = try require(h.editor.document[arrow]?.typed(as: Arrow.self)?.props)
        expectEqual(props.end.binding, nil)
        expect(h.editor.isLocked(arrow))
        let after = try require(h.editor.arrowGeometry(of: arrow)).bodyPath.boundingBoxOfPath
        expectClose(after.maxX, drawn.maxX, within: 0.5)
        h.wait(16)
        expectEqual(h.editor.drawingOffset(of: arrow), .zero)
    },
    test("a locked arrow shows no handles: a press where its end's would be presses the arrow, and dragging it shakes it") {
        let h = emptyBoard()
        let arrow = h.add(Arrow(start: .free(CGPoint(x: 100, y: 300)), end: .free(CGPoint(x: 400, y: 300))))
        h.editor.selection = arrow
        let end = h.view(try require(h.editor.arrowGeometry(of: arrow)).endHandle)
        expect(h.editor.handle(atViewPoint: end) != nil)
        h.editor.lock([arrow])
        expectEqual(h.editor.handle(atViewPoint: end), nil)
        let before = try require(h.editor.document[arrow])
        h.press(at: CGPoint(x: end.x - 5, y: end.y))
        h.drag(to: CGPoint(x: end.x + 60, y: end.y + 80))
        h.wait(16)
        expectEqual(h.editor.document[arrow], before)
        expect(h.editor.drawingOffset(of: arrow) != .zero)
        h.release()
    },
    test("the eraser leaves a locked note and shakes it; Arrange › Bring to Front leaves it where it is in the stack") {
        let h = emptyBoard()
        let back = h.add(StickyNote(frame: CGRect(x: 100, y: 100, width: 200, height: 200), text: "Back"))
        let front = h.add(StickyNote(frame: CGRect(x: 200, y: 200, width: 200, height: 200), text: "Front"))
        h.editor.lock([back])
        h.key("e")
        h.press(at: CGPoint(x: 120, y: 150))
        h.drag(to: CGPoint(x: 180, y: 150))
        h.release()
        expect(h.editor.document[back] != nil)
        h.wait(16)
        expect(h.editor.drawingOffset(of: back) != .zero)
        h.wait(400)
        h.key("v")
        try require(h.secondaryClick(at: CGPoint(x: 120, y: 150))).choose("Arrange", "Bring to Front")
        expectEqual(h.editor.document.shapes.map(\.id), [back, front])
        h.wait(16)
        expect(h.editor.drawingOffset(of: back) != .zero)
    },
    test("a locked note saves as locked, and opens locked") {
        let registry = try ShippedPlugins.registry()
        var note = AnyShapeRecord(ShapeRecord(StickyNote(frame: CGRect(x: 0, y: 0, width: 200, height: 200), text: "Hi")))
        note[LockedProperty.self] = true
        let codec = BoardCodec(registry: registry)
        let data = try codec.encode(CanvasDocument(shapes: [note]))
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        expectEqual(json["shapes"]?.arrayValue?.first?["added"], ["locked": true])
        expectEqual(json["format"], 3)
        let opened = try codec.decode(data).document
        expect(opened.shapes.first?.isLocked == true)
    },
])

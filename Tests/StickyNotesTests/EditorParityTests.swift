import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Geometry
import StickyNotes
import TestKit

// The note's editing view (a TextKit 2 text view) against the canvas's render (string drawing): the
// same text must fall on the same lines, so nothing moves when editing starts or ends.

/// Wraps, breaks, and leaves a line blank. No i or j, so each line is one run of inked rows.
let multiLineText = "Buy bread, butter and coffee for the party, then ask Sam about the cake tomorrow\nat noon.\n\nAnd tell the others."

/// The most a pixel may differ, in any channel (0...255), between the two: anti-aliasing. A line a
/// point off differs by more than 200.
let antiAliasing = 16

/// Draws `text` in `frame` into `rep` (a `renderBitmap` of `size` at `scale`), as the note's render
/// drew it before its lines had a fixed height: the font and the color alone.
@MainActor func drawAsBefore(_ text: String, in frame: CGRect, into rep: NSBitmapImageRep, size: CGSize, scale: CGFloat) {
    let cg = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    cg.translateBy(x: 0, y: size.height * scale)
    cg.scaleBy(x: scale, y: -scale)
    NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor(white: 0.12, alpha: 1)])
            .draw(with: frame.insetBy(dx: 16, dy: 16), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        NSGraphicsContext.restoreGraphicsState()
    }
}

@MainActor let noteEditorTests = Suite("Note editor", [
    test("the render draws a note's text as it did before its lines had a fixed height, to the pixel, at 1× and 2×") {
        let editor = CanvasEditor(registry: try Registry(plugins: notePlugins), scheduler: ManualScheduler())
        let note = ShapeRecord(StickyNote(frame: CGRect(x: 20, y: 15, width: 200, height: 200), text: multiLineText))
        editor.transact { $0.insert(note) }
        let size = CGSize(width: 240, height: 240)
        for scale in [CGFloat(1), 2] {
            let drawn = renderBitmap(editor, size: size, scale: scale)
            expect(editor.beginEditing(note.id))
            let before = renderBitmap(editor, size: size, scale: scale)      // the note, but not its text
            editor.endEditing()
            drawAsBefore(multiLineText, in: note.frame, into: before, size: size, scale: scale)
            expectEqual(largestDifference(drawn, before, in: note.frame, scale: scale), 0, "at \(scale)×")
        }
    },
    test("its lines fall on the render's, pixel for pixel but anti-aliasing, at 1× and 2×, zoomed in and out: a note doesn't move when editing starts") {
        for (scale, zoom) in [(1, 1), (2, 1), (1, 2), (2, 0.6)] as [(CGFloat, CGFloat)] {
            let editor = CanvasEditor(registry: try Registry(plugins: notePlugins), scheduler: ManualScheduler())
            editor.camera.setZoom(zoom, around: .zero)
            let note = ShapeRecord(StickyNote(frame: CGRect(x: 20, y: 15, width: 200, height: 200), text: multiLineText))
            editor.transact { $0.insert(note) }
            let size = CGSize(width: 240 * zoom, height: 240 * zoom), inView = editor.camera.toView(note.frame)
            let drawn = renderBitmap(editor, size: size, scale: scale)
            expect(editor.beginEditing(note.id))
            let fill = renderBitmap(editor, size: size, scale: scale)       // the canvas leaves the text to the editing view
            let edited = renderBitmap(editor, size: size, scale: scale, editing: try require(editor.makeEditingView()))
            let tops = lineTops(drawn, over: fill, in: inView, scale: scale)
            expectEqual(tops.count, 6, "at \(scale)×, zoom \(zoom): the render's lines")
            expectEqual(lineTops(edited, over: fill, in: inView, scale: scale), tops, "at \(scale)×, zoom \(zoom): the editor's lines")
            let difference = largestDifference(drawn, edited, in: inView, scale: scale)
            expect(difference <= antiAliasing, "at \(scale)×, zoom \(zoom): a pixel differs by \(difference)")
        }
    },
    test("text typed into a new note, even once all it had was deleted, is on the lines the render will draw it on") {
        let editor = CanvasEditor(registry: try Registry(plugins: notePlugins), scheduler: ManualScheduler())
        let note = ShapeRecord(StickyNote(frame: CGRect(x: 20, y: 15, width: 200, height: 200)))
        editor.transact { $0.insert(note) }
        expect(editor.beginEditing(note.id))
        let editing = try require(editor.makeEditingView())
        let textView = try require(editing.firstResponder as? NSTextView)
        textView.insertText("Scratch that", replacementRange: textView.selectedRange())
        textView.selectAll(nil)
        textView.deleteBackward(nil)
        textView.insertText(multiLineText, replacementRange: textView.selectedRange())
        expectEqual(editor.document[note.id]?.typed(as: StickyNote.self)?.props.text, multiLineText)

        let size = CGSize(width: 240, height: 240), scales: [CGFloat] = [1, 2]
        let fill = scales.map { renderBitmap(editor, size: size, scale: $0) }
        let edited = scales.map { renderBitmap(editor, size: size, scale: $0, editing: editing) }
        editor.endEditing()
        let drawn = scales.map { renderBitmap(editor, size: size, scale: $0) }
        for (i, scale) in scales.enumerated() {
            let tops = lineTops(drawn[i], over: fill[i], in: note.frame, scale: scale)
            expectEqual(tops.count, 6, "at \(scale)×: the render's lines")
            expectEqual(lineTops(edited[i], over: fill[i], in: note.frame, scale: scale), tops, "at \(scale)×: the editor's lines")
            let difference = largestDifference(drawn[i], edited[i], in: note.frame, scale: scale)
            expect(difference <= antiAliasing, "at \(scale)×: a pixel differs by \(difference)")
        }
    },
])

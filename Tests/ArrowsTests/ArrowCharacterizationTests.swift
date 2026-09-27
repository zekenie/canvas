import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Keyboard
import Selection
import TableOfContents
import TestKit

// Pins how a lone arrow moves: what its press and drags commit, when its handles and indicator
// show, and how it re-binds. Don't edit these to make a change pass. (One deliberate change: the
// POC hid the indicator once the arrow moved, as tldraw does; it now stays.)
@MainActor let arrowCharacterizationTests = Suite("Arrow characterization", [
    test("an arrow body press commits nothing through 4 pt; the first drag past it commits twice (precise ends, then the move); later drags once each") {
        let board = try Board(arrow: 0)
        let h = board.h
        let revision = h.editor.revision
        h.move(to: CGPoint(x: 364, y: 180)); h.press()
        expectEqual(h.editor.selection, board.arrow)
        h.drag(to: CGPoint(x: 364, y: 182)); h.drag(to: CGPoint(x: 364, y: 184))       // 4 pt: not past it
        expectEqual(h.editor.revision, revision)
        expectEqual(board.arrows.first?.start.binding?.isPrecise, false)
        h.drag(to: CGPoint(x: 364, y: 184.5))
        expectEqual(h.editor.revision, revision + 2)
        h.drag(to: CGPoint(x: 364, y: 200))
        expectEqual(h.editor.revision, revision + 3)
        h.drag(to: CGPoint(x: 364, y: 210))
        expectEqual(h.editor.revision, revision + 4)
        h.release()
        expectEqual(h.editor.revision, revision + 4)
    },
    test("a click on an arrow body leaves imprecise bindings untouched and commits nothing") {
        let board = try Board(arrow: 0)
        let h = board.h
        let before = board.arrows, revision = h.editor.revision
        h.move(to: CGPoint(x: 364, y: 180)); h.press(); h.release()
        expectEqual(h.editor.selection, board.arrow)
        expectEqual(board.arrows, before)
        expectEqual(h.editor.revision, revision)
    },
    test("handles hide while an arrow body is pressed and moved; the indicator stays throughout") {
        let size = CGSize(width: 700, height: 300)
        let handle = CGPoint(x: 180, y: 180)       // the start handle, at A's center
        let body = CGPoint(x: 320, y: 180)         // on the body, clear of every handle
        let idle = try Board(arrow: 0)
        let unselected = renderBitmap(idle.h.editor, size: size)
        idle.h.editor.selection = idle.arrow
        let selected = renderBitmap(idle.h.editor, size: size)
        expect(pixel(selected, at: handle) != pixel(unselected, at: handle), "a selected arrow shows its handles")
        expect(pixel(selected, at: body) != pixel(unselected, at: body), "and its outline")

        let board = try Board(arrow: 0)
        board.h.move(to: CGPoint(x: 364, y: 180)); board.h.press()
        let pressed = renderBitmap(board.h.editor, size: size)
        expect(pixel(pressed, at: handle) != pixel(selected, at: handle), "no handles while pressed")
        expectEqual(pixel(pressed, at: body), pixel(selected, at: body))
        board.h.drag(to: CGPoint(x: 364, y: 184))
        expectEqual(pixel(renderBitmap(board.h.editor, size: size), at: body), pixel(selected, at: body))
        board.h.drag(to: CGPoint(x: 364, y: 200))
        // Past the threshold the arrow moves, still outlined, with no handles: between the ends it
        // draws as the same arrow selected would with its handles away.
        let moved = renderBitmap(board.h.editor, size: size)
        let reference = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), ArrowsPlugin(), TableOfContentsPlugin()], document: board.h.editor.document)
        let between = CGRect(x: 290, y: 170, width: 150, height: 60)
        expect(changedPixels(moved, renderBitmap(reference.editor, size: size), in: between) > 0, "unselected, it wouldn't be outlined")
        reference.editor.selection = board.arrow
        reference.editor.session = IdleSession()                      // hides the handles, as moving does
        expectEqual(changedPixels(moved, renderBitmap(reference.editor, size: size), in: between), 0)
        board.h.release()
    },
    test("a lone arrow dragged off its shape and back re-binds precisely") {
        let board = try Board(arrow: 0)
        let h = board.h
        h.move(to: CGPoint(x: 364, y: 180)); h.press()
        h.drag(to: CGPoint(x: 364, y: 200))
        h.drag(to: CGPoint(x: 364, y: 520))
        expectEqual(board.arrows.first?.start, .free(CGPoint(x: 180, y: 520)))
        expectEqual(board.arrows.first?.end, .free(CGPoint(x: 560, y: 520)))
        h.drag(to: CGPoint(x: 364, y: 210))
        h.release()
        // Each end's handle (the note's center) moved by (0, 30), normalized in its box.
        func anchor(_ box: CGRect) -> CGPoint {
            CGPoint(x: (box.midX - box.minX) / box.width, y: (box.midY + 30 - box.minY) / box.height)
        }
        expectEqual(board.arrows.first?.start, .bound(ArrowBinding(shapeID: board.a, normalizedAnchor: anchor(boxA), isPrecise: true, isExact: false)))
        expectEqual(board.arrows.first?.end, .bound(ArrowBinding(shapeID: board.b, normalizedAnchor: anchor(boxB), isPrecise: true, isExact: false)))
    },
])

@_spi(Host) import Canvas
import CanvasTesting
import Connections
import CoreGraphics
import Geometry
import Selection
import TestKit

@MainActor let handleTests = Suite("Arrow handles", [
    test("a selected arrow has three handles; the bend handle hides when it would crowd an end") {
        let board = try Board(arrow: 0)
        board.h.editor.selection = board.arrow
        // Handles sit at the anchors (here the boxes' centers), not at the visible ends.
        expectEqual(board.h.editor.handle(atViewPoint: CGPoint(x: 180, y: 180)), AnyHashable(ArrowHandle.terminal(.start)))
        expectEqual(board.h.editor.handle(atViewPoint: CGPoint(x: 560, y: 180)), AnyHashable(ArrowHandle.terminal(.end)))
        expectEqual(board.h.editor.handle(atViewPoint: CGPoint(x: 364.125, y: 180)), AnyHashable(ArrowHandle.middle))
        board.h.editor.camera = Camera(origin: .zero, zoom: 0.1)                 // 18 pt from the start: hidden
        expectEqual(board.h.editor.handle(atViewPoint: board.h.view(CGPoint(x: 364.125, y: 180))), nil)
    },
    test("a handle is grabbed within 12 view points of it, at any zoom") {
        for zoom: CGFloat in [1, 2] {
            let board = try Board(arrow: 0)
            board.h.editor.selection = board.arrow
            board.h.editor.camera = Camera(origin: .zero, zoom: zoom)
            let end = board.h.view(CGPoint(x: 560, y: 180))
            expectEqual(board.h.editor.handle(atViewPoint: CGPoint(x: end.x + 11.9, y: end.y)), AnyHashable(ArrowHandle.terminal(.end)), "zoom \(zoom)")
            expectEqual(board.h.editor.handle(atViewPoint: CGPoint(x: end.x + 12.1, y: end.y)), nil, "zoom \(zoom)")
        }
    },
    test("a handle drag starts past 4 view points, not before") {
        let board = try Board(arrow: 0)
        board.h.editor.selection = board.arrow
        board.h.press(at: CGPoint(x: 364.125, y: 180))
        board.h.drag(to: CGPoint(x: 364.125, y: 184))
        expectEqual(board.arrows.first?.bend, 0)
        board.h.drag(to: CGPoint(x: 364.125, y: 185))
        expectClose(try require(board.arrows.first?.bend), 5)
    },
    test("the bend follows the pointer's projection onto the bisector; sideways motion does nothing") {
        let board = try Board(arrow: 0)
        board.h.editor.selection = board.arrow
        board.h.move(to: CGPoint(x: 364.125, y: 180))
        board.h.press()
        board.h.drag(to: CGPoint(x: 364.125, y: 250))
        board.h.drag(to: CGPoint(x: 360, y: 260))
        board.h.release()
        expectClose(try require(board.arrows.first?.bend), 80)
    },
    test("double-clicking an end handle toggles its arrowhead and starts no drag") {
        let board = try Board(arrow: 0)
        board.h.editor.selection = board.arrow
        board.h.press(at: CGPoint(x: 560, y: 180), clickCount: 2)
        expectEqual(board.arrows.first?.endArrowhead, false)
        expect(board.h.editor.session == nil)
        board.h.release()
    },
    test("pressing a bound end outlines its shape; releasing clears the outline") {
        let board = try Board(arrow: 0)
        board.h.editor.selection = board.arrow
        board.h.press(at: CGPoint(x: 560, y: 180))
        expectEqual(board.h.editor.hintedShapeID, board.b)
        expectEqual(board.h.editor.cursor, .closedHand)
        board.h.release()
        expectEqual(board.h.editor.hintedShapeID, nil)
    },
    test("handles win over the shape under them; hovering one shows an open hand") {
        let board = try Board(arrow: 0)
        board.h.editor.selection = board.arrow
        board.h.move(to: CGPoint(x: 560, y: 180))
        expectEqual(board.h.editor.hoveredHandle, AnyHashable(ArrowHandle.terminal(.end)))
        expectEqual(board.h.editor.hovered, nil)
        expectEqual(board.h.editor.cursor, .openHand)
    },
    test("re-aiming an end slowly binds it precisely") {
        let board = try Board(arrow: 0)
        board.h.editor.selection = board.arrow
        board.h.move(to: CGPoint(x: 560, y: 180))
        board.h.press()
        board.h.drag(to: CGPoint(x: 600, y: 150), speed: slow)
        board.h.release()
        let end = try require(board.arrows.first?.end.binding)
        expect(end.isPrecise)
        expectClose(end.normalizedAnchor, CGPoint(x: 0.7, y: 0.35))
    },
    test("Escape while re-aiming an end does nothing") {
        let board = try Board(arrow: 0)
        board.h.editor.selection = board.arrow
        board.h.press(at: CGPoint(x: 560, y: 180))
        board.h.drag(to: CGPoint(x: 760, y: 400), speed: fast)
        board.h.escape()
        expect(board.h.editor.session != nil)
        board.h.release()
        expectEqual(board.arrows.first?.end, .free(CGPoint(x: 760, y: 400)))
    },
])

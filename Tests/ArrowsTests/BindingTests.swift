@_spi(Host) import Canvas
import CanvasTesting
import Connections
import CoreGraphics
import Geometry
import Keyboard
import Selection
import TableOfContents
import TestKit

// How a dragged end binds, by tldraw's rules: an arrow's end re-aimed from its handle, the drag a
// port's connection is drawn with too (ArrowPortsTests draw those).
@MainActor let bindingTests = Suite("Binding an end", [
    test("arriving fast binds the end to the shape's center; releasing leaves the arrow selected") {
        let board = try Board(arrow: 0)
        board.reaimEnd(to: CGPoint(x: 500, y: 120))
        let arrow = try require(board.arrows.first)
        expectEqual(arrow.start.binding?.shapeID, board.a)
        expectEqual(arrow.end.binding, ArrowBinding(shapeID: board.b, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false))
        expectEqual(board.h.editor.currentToolID, .select)
        expectEqual(board.h.editor.selection, board.arrow)
        expectEqual(board.h.editor.hintedShapeID, nil)
    },
    test("arriving slowly binds precisely where the pointer is") {
        let board = try Board(arrow: 0)
        board.reaimEnd(to: CGPoint(x: 500, y: 120), speed: slow)
        let end = try require(board.arrows.first?.end.binding)
        expect(end.isPrecise)
        expectClose(end.normalizedAnchor, CGPoint(x: 0.2, y: 0.2))
    },
    test("pausing 320 ms on a shape while dragging makes the end precise; 319 ms doesn't") {
        for (pause, precise) in [(319, false), (320, true)] {
            let board = try Board(arrow: 0)
            board.pressEnd()
            board.h.drag(to: CGPoint(x: 400, y: 120), speed: fast)
            board.h.drag(to: CGPoint(x: 500, y: 120))                        // into B, fast
            board.h.wait(pause - 16)
            board.h.release()                                                // 16 ms later
            expectEqual(board.arrows.first?.end.binding?.isPrecise, precise, "pause \(pause)")
        }
    },
    test("entering a shape under 0.5 pt/ms binds precisely; over it, to the center") {
        for (speed, precise) in [(CGFloat(0.4), true), (0.6, false)] {
            let board = try Board(arrow: 0)
            board.reaimEnd(to: CGPoint(x: 500, y: 120), speed: speed)
            expectEqual(board.arrows.first?.end.binding?.isPrecise, precise, "speed \(speed)")
        }
    },
    test("a small shape's center snaps within 15% of its short side: 9 units for a 60-unit box") {
        let small = CGRect(x: 460, y: 80, width: 60, height: 60)
        for (x, snapped) in [(CGFloat(498), true), (500, false)] {            // 8 and 10 from its center
            let board = try Board(arrow: 0, second: small)
            board.reaimEnd(via: CGPoint(x: 400, y: 110), to: CGPoint(x: x, y: 110), speed: slow)
            let end = try require(board.arrows.first?.end.binding)
            expect(end.isPrecise)
            expectEqual(end.normalizedAnchor == CGPoint(x: 0.5, y: 0.5), snapped, "x \(x): \(end.normalizedAnchor)")
        }
    },
    test("⌥ binds exactly: the visible end is the anchor") {
        let board = try Board(arrow: 0)
        board.pressEnd()
        board.h.hold(.option)
        board.h.drag(to: CGPoint(x: 500, y: 120), speed: fast)
        board.h.release()
        let arrow = try require(board.arrows.first)
        expectEqual(arrow.end.binding?.isExact, true)
        let geometry = try require(board.h.editor.arrowGeometry(of: try require(board.arrow)))
        expectClose(geometry.end, CGPoint(x: 500, y: 120))
    },
    test("⌘ and ⌃ bind nothing and outline nothing") {
        for modifier in [Modifiers.command, .control] {
            let board = try Board(arrow: 0)
            board.pressEnd()
            board.h.hold(modifier)
            board.h.drag(to: CGPoint(x: 500, y: 120), speed: fast)
            expectEqual(board.h.editor.hintedShapeID, nil)
            board.h.release()
            expectEqual(board.arrows.first?.end, .free(CGPoint(x: 500, y: 120)))
        }
    },
    test("letting go of ⌥ with the mouse keeps the end exact; 150 ms before, it doesn't, and stays precise") {
        let board = try Board(arrow: 0)
        board.pressEnd()
        board.h.hold(.option)
        board.h.drag(to: CGPoint(x: 400, y: 120), speed: fast)
        board.h.drag(to: CGPoint(x: 500, y: 120), speed: fast)             // into B with ⌥ held: aiming precisely
        board.h.hold([])
        board.h.wait(149)
        expectEqual(board.arrows.first?.end.binding?.isExact, true)
        board.h.wait(1)
        expectEqual(board.arrows.first?.end.binding?.isExact, false)
        expectEqual(board.arrows.first?.end.binding?.isPrecise, true)
    },
    test("a drag within 150 ms of letting go of ⌥ still binds exactly") {
        let board = try Board(arrow: 0)
        board.pressEnd()
        board.h.hold(.option)
        board.h.drag(to: CGPoint(x: 500, y: 120), speed: fast)
        board.h.hold([])
        board.h.drag(to: CGPoint(x: 502, y: 121))                         // 16 ms later
        expectEqual(board.arrows.first?.end.binding?.isExact, true)
    },
    test("⇧ snaps the dragged end's angle to 15° steps around the other end") {
        let board = try Board(arrow: 0)
        board.pressEnd()
        board.h.hold(.shift)
        board.h.drag(to: CGPoint(x: 380, y: 210), speed: fast)
        board.h.release()
        guard case .free(let end)? = board.arrows.first?.end else { throw RequireFailed() }
        let angle = atan2(end.y - boxA.center.y, end.x - boxA.center.x)
        expectClose(angle, (angle / (.pi / 12)).rounded() * (.pi / 12), within: 1e-9)
    },
    test("⇧ still held when the pause timer fires keeps the precise end on a 15° step") {
        let board = try Board(arrow: 0)
        board.pressEnd()
        board.h.hold(.shift)
        board.h.drag(to: CGPoint(x: 520, y: 150), speed: fast)             // 5° off the start's level: snaps to 0°
        board.h.wait(400)
        board.h.release()
        let end = try require(board.arrows.first?.end.binding)
        expect(end.isPrecise)
        let geometry = try require(board.h.editor.arrowGeometry(of: try require(board.arrow)))
        let angle = atan2(geometry.endHandle.y - geometry.startHandle.y, geometry.endHandle.x - geometry.startHandle.x)
        expectClose(angle, (angle / (.pi / 12)).rounded() * (.pi / 12), within: 1e-9)
        expect(geometry.endHandle.x < 555, "precise, not the center: \(geometry.endHandle)")
    },
    test("an end brought into the shape of a precise start binds precisely too, nudged off the start's anchor") {
        let board = try Board(arrow: 0)
        board.h.editor.selection = board.arrow
        board.h.move(to: boxA.center)                                      // the start's handle
        board.h.press()
        board.h.drag(to: CGPoint(x: 330, y: 300), speed: fast)             // off A
        board.h.drag(to: CGPoint(x: 130, y: 130), speed: fast)
        board.h.wait(400)                                                  // precise by the timer
        board.h.release()
        expectClose(try require(board.arrows.first?.start.binding?.normalizedAnchor), CGPoint(x: 0.25, y: 0.25))
        board.reaimEnd(via: CGPoint(x: 380, y: 130), to: CGPoint(x: 130, y: 130))
        let end = try require(board.arrows.first?.end.binding)
        expectEqual(end.shapeID, board.a)
        expect(end.isPrecise)
        expectClose(end.normalizedAnchor, CGPoint(x: 0.30, y: 0.25))
    },
    test("a precise end near the center snaps to it, by a distance measured on screen") {
        for (zoom, anchor) in [(CGFloat(1), CGPoint(x: 0.5, y: 0.5)), (2, CGPoint(x: 0.55, y: 0.5))] {
            let board = try Board(arrow: 0)
            board.h.editor.camera = Camera(origin: .zero, zoom: zoom)
            let v = board.h.view
            // 10 units from B's center: inside the 16 pt snap at zoom 1, outside it at zoom 2 (20 pt).
            board.reaimEnd(via: v(CGPoint(x: 400, y: 170)), to: v(CGPoint(x: 570, y: 180)), speed: slow)
            let end = try require(board.arrows.first?.end.binding)
            expect(end.isPrecise)
            expectClose(end.normalizedAnchor, anchor, within: 1e-9)
        }
    },
    test("Escape while re-aiming an end lets the drag go on") {
        let board = try Board(arrow: 0)
        board.pressEnd()
        board.h.drag(to: CGPoint(x: 400, y: 120), speed: fast)
        board.h.escape()
        expect(board.h.editor.session != nil)
        board.h.drag(to: CGPoint(x: 380, y: 400), speed: fast)
        board.h.release()
        expectEqual(board.arrows.first?.end, .free(CGPoint(x: 380, y: 400)))
    },
    test("switching tools mid-drag cancels the drag's precise timer, as before") {
        for switchTools in [false, true] {
            let board = try Board(arrow: 0)
            board.pressEnd()                                              // the end handle, at its anchor
            board.h.drag(to: CGPoint(x: 800, y: 500), speed: fast)        // off B: the end frees
            board.h.drag(to: CGPoint(x: 600, y: 150), speed: fast)        // back onto B, imprecise
            if switchTools { board.h.key("h") }
            board.h.wait(400)
            board.h.release()
            expectEqual(board.arrows.first?.end.binding?.isPrecise, !switchTools, "switched: \(switchTools)")
        }
    },
])

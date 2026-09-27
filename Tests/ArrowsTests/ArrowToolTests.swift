import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Selection
import TableOfContents
import TestKit

@MainActor let arrowToolTests = Suite("Arrow tool", [
    test("arriving fast binds the end to the shape's center; finishing selects the arrow and switches to select") {
        let board = try Board()
        board.drawArrow(from: boxA.center, to: CGPoint(x: 500, y: 120))
        let arrow = try require(board.arrows.first)
        expectEqual(arrow.start.binding?.shapeID, board.a)
        expectEqual(arrow.end.binding, ArrowBinding(shapeID: board.b, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false))
        expectEqual(board.h.editor.currentToolID, .select)
        expectEqual(board.h.editor.selection, board.arrowIDs.first)
        expectEqual(board.h.editor.hintedShapeID, nil)
    },
    test("without the selection installed, drawing an arrow still works and returns to the default tool") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), ArrowsPlugin(), TableOfContentsPlugin()])
        h.add(Box(CGRect(x: 80, y: 80, width: 200, height: 200)))
        h.key("a")
        h.press(at: CGPoint(x: 180, y: 180))
        h.drag(to: CGPoint(x: 500, y: 120), speed: 2)
        h.release()
        expect(h.editor.document.shapes.contains { $0.kind == Arrow.kind })
        expectEqual(h.editor.currentToolID, .hand)
        expectEqual(h.editor.selection, nil)
    },
    test("arriving slowly binds precisely where the pointer is") {
        let board = try Board()
        board.drawArrow(from: boxA.center, to: CGPoint(x: 400, y: 120), release: false)
        board.h.drag(to: CGPoint(x: 500, y: 120), speed: slow)
        board.h.release()
        let end = try require(board.arrows.first?.end.binding)
        expect(end.isPrecise)
        expectClose(end.normalizedAnchor, CGPoint(x: 0.2, y: 0.2))
    },
    test("hovering a shape 600 ms before pressing starts the arrow precisely; 599 ms doesn't") {
        for (dwell, precise) in [(599, false), (600, true)] {
            let board = try Board()
            board.h.key("a")
            board.h.move(to: CGPoint(x: 130, y: 130))
            board.h.wait(dwell - 16)
            board.h.press()                                   // 16 ms later
            board.h.drag(to: CGPoint(x: 500, y: 120), speed: fast)
            board.h.release()
            let start = try require(board.arrows.first?.start.binding)
            expectEqual(start.isPrecise, precise, "dwell \(dwell)")
            if precise { expectClose(start.normalizedAnchor, CGPoint(x: 0.25, y: 0.25)) }
        }
    },
    test("holding still 320 ms after pressing starts the arrow precisely; 319 ms doesn't") {
        for (hold, precise) in [(319, false), (320, true)] {
            let board = try Board()
            board.h.key("a")
            board.h.move(to: CGPoint(x: 130, y: 130))
            board.h.press()
            board.h.wait(hold - 16)
            board.h.drag(to: CGPoint(x: 140, y: 130))          // 16 ms later, past the threshold
            board.h.drag(to: CGPoint(x: 500, y: 120), speed: fast)
            board.h.release()
            expectEqual(board.arrows.first?.start.binding?.isPrecise, precise, "hold \(hold)")
        }
    },
    test("pausing 320 ms on a shape while dragging makes the end precise; 319 ms doesn't") {
        for (pause, precise) in [(319, false), (320, true)] {
            let board = try Board()
            board.drawArrow(from: boxA.center, to: CGPoint(x: 500, y: 120), release: false)
            board.h.wait(pause - 16)
            board.h.release()
            expectEqual(board.arrows.first?.end.binding?.isPrecise, precise, "pause \(pause)")
        }
    },
    test("entering a shape under 0.5 pt/ms binds precisely; over it, to the center") {
        for (speed, precise) in [(CGFloat(0.4), true), (0.6, false)] {
            let board = try Board()
            board.drawArrow(from: boxA.center, to: CGPoint(x: 400, y: 120), release: false)
            board.h.drag(to: CGPoint(x: 500, y: 120), speed: speed)
            board.h.release()
            expectEqual(board.arrows.first?.end.binding?.isPrecise, precise, "speed \(speed)")
        }
    },
    test("a small shape's center snaps within 15% of its short side: 9 units for a 60-unit box") {
        let small = CGRect(x: 460, y: 80, width: 60, height: 60)
        for (x, snapped) in [(CGFloat(498), true), (500, false)] {            // 8 and 10 from its center
            let board = try Board(second: small)
            board.drawArrow(from: boxA.center, to: CGPoint(x: 400, y: 110), release: false)
            board.h.drag(to: CGPoint(x: x, y: 110), speed: slow)
            board.h.release()
            let end = try require(board.arrows.first?.end.binding)
            expect(end.isPrecise)
            expectEqual(end.normalizedAnchor == CGPoint(x: 0.5, y: 0.5), snapped, "x \(x): \(end.normalizedAnchor)")
        }
    },
    test("⌥ binds exactly: the visible end is the anchor") {
        let board = try Board()
        board.h.key("a"); board.h.move(to: boxA.center); board.h.press()
        board.h.hold(.option)
        board.h.drag(to: CGPoint(x: 500, y: 120), speed: fast)
        board.h.release()
        let arrow = try require(board.arrows.first)
        expectEqual(arrow.start.binding?.isExact, true)
        expectEqual(arrow.end.binding?.isExact, true)
        let geometry = try require(board.h.editor.arrowGeometry(of: board.arrowIDs[0]))
        expectClose(geometry.end, CGPoint(x: 500, y: 120))
    },
    test("⌘ and ⌃ bind nothing and outline nothing") {
        for modifier in [Modifiers.command, .control] {
            let board = try Board()
            board.h.key("a"); board.h.move(to: boxA.center); board.h.press()
            board.h.hold(modifier)
            board.h.drag(to: CGPoint(x: 500, y: 120), speed: fast)
            expectEqual(board.h.editor.hintedShapeID, nil)
            board.h.release()
            expectEqual(board.arrows.first?.end, .free(CGPoint(x: 500, y: 120)))
        }
    },
    test("letting go of ⌥ with the mouse keeps the end exact; 150 ms before, it doesn't") {
        let board = try Board()
        board.h.key("a"); board.h.move(to: boxA.center); board.h.press()
        board.h.hold(.option)
        board.h.drag(to: CGPoint(x: 500, y: 120), speed: fast)
        board.h.hold([])
        board.h.wait(149)
        expectEqual(board.arrows.first?.end.binding?.isExact, true)
        board.h.wait(1)
        expectEqual(board.arrows.first?.end.binding?.isExact, false)
        expectEqual(board.arrows.first?.end.binding?.isPrecise, true)
    },
    test("a drag within 150 ms of letting go of ⌥ still binds exactly") {
        let board = try Board()
        board.h.key("a"); board.h.move(to: boxA.center); board.h.press()
        board.h.hold(.option)
        board.h.drag(to: CGPoint(x: 500, y: 120), speed: fast)
        board.h.hold([])
        board.h.drag(to: CGPoint(x: 502, y: 121))                         // 16 ms later
        expectEqual(board.arrows.first?.end.binding?.isExact, true)
    },
    test("holding ⌘ while hovering drops the target; 150 ms after letting go, it's back") {
        let board = try Board()
        board.h.key("a"); board.h.move(to: boxB.center)
        board.h.hold(.command)
        expectEqual(board.h.editor.hintedShapeID, nil)
        board.h.hold([])
        board.h.wait(149)
        expectEqual(board.h.editor.hintedShapeID, nil)
        board.h.wait(1)
        expectEqual(board.h.editor.hintedShapeID, board.b)
    },
    test("the pointer leaving the canvas drops the arrow tool's target") {
        let board = try Board()
        board.h.key("a"); board.h.move(to: boxB.center)
        board.h.editor.pointerExited()
        expectEqual(board.h.editor.hintedShapeID, nil)
    },
    test("⇧ snaps the dragged end's angle to 15° steps around the other end") {
        let board = try Board()
        board.h.key("a"); board.h.move(to: boxA.center); board.h.press()
        board.h.hold(.shift)
        board.h.drag(to: CGPoint(x: 380, y: 210), speed: fast)
        board.h.release()
        guard case .free(let end)? = board.arrows.first?.end else { throw RequireFailed() }
        let angle = atan2(end.y - boxA.center.y, end.x - boxA.center.x)
        expectClose(angle, (angle / (.pi / 12)).rounded() * (.pi / 12), within: 1e-9)
    },
    test("⇧ still held when the pause timer fires keeps the precise end on a 15° step") {
        let board = try Board()
        board.h.key("a"); board.h.move(to: boxA.center); board.h.press()
        board.h.hold(.shift)
        board.h.drag(to: CGPoint(x: 520, y: 150), speed: fast)             // 5° off the start's level: snaps to 0°
        board.h.wait(400)
        board.h.release()
        let end = try require(board.arrows.first?.end.binding)
        expect(end.isPrecise)
        let geometry = try require(board.h.editor.arrowGeometry(of: board.arrowIDs[0]))
        let angle = atan2(geometry.endHandle.y - geometry.startHandle.y, geometry.endHandle.x - geometry.startHandle.x)
        expectClose(angle, (angle / (.pi / 12)).rounded() * (.pi / 12), within: 1e-9)
        expect(geometry.endHandle.x < 555, "precise, not the center: \(geometry.endHandle)")
    },
    test("an arrow back into its own shape binds both ends precisely, nudged apart") {
        let board = try Board()
        board.h.key("a")
        board.h.move(to: CGPoint(x: 130, y: 130)); board.h.wait(700)
        board.h.press()
        board.h.drag(to: CGPoint(x: 380, y: 130), speed: fast)
        board.h.drag(to: CGPoint(x: 130, y: 130), speed: fast)
        board.h.release()
        let end = try require(board.arrows.first?.end.binding)
        expectEqual(end.shapeID, board.a)
        expect(end.isPrecise)
        expectClose(end.normalizedAnchor, CGPoint(x: 0.30, y: 0.25))
    },
    test("a precise end near the center snaps to it, by a distance measured on screen") {
        for (zoom, anchor) in [(CGFloat(1), CGPoint(x: 0.5, y: 0.5)), (2, CGPoint(x: 0.55, y: 0.5))] {
            let board = try Board()
            board.h.editor.camera = Camera(origin: .zero, zoom: zoom)
            let v = board.h.view
            board.drawArrow(from: v(boxA.center), to: v(CGPoint(x: 400, y: 170)), release: false)
            // 10 units from B's center: inside the 16 pt snap at zoom 1, outside it at zoom 2 (20 pt).
            board.h.drag(to: v(CGPoint(x: 570, y: 180)), speed: slow)
            board.h.release()
            let end = try require(board.arrows.first?.end.binding)
            expect(end.isPrecise)
            expectClose(end.normalizedAnchor, anchor, within: 1e-9)
        }
    },
    test("a click without a drag makes no arrow, stays in the arrow tool, and targets again") {
        let board = try Board()
        board.h.key("a"); board.h.move(to: boxA.center); board.h.press(); board.h.release()
        expect(board.arrows.isEmpty)
        expectEqual(board.h.editor.currentToolID, .arrow)
        expectEqual(board.h.editor.hintedShapeID, board.a)
    },
    test("Escape while drawing deletes the new arrow and stays in the arrow tool") {
        let board = try Board()
        board.drawArrow(from: boxA.center, to: CGPoint(x: 300, y: 180), release: false)
        board.h.escape()
        expect(board.arrows.isEmpty)
        board.h.release()
        expect(board.arrows.isEmpty)
        expectEqual(board.h.editor.currentToolID, .arrow)
        expectEqual(board.h.editor.selection, nil)
    },
    test("hovering with the arrow tool outlines the shape an arrow would start from") {
        let board = try Board()
        board.h.key("a")
        board.h.move(to: boxB.center)
        expectEqual(board.h.editor.hintedShapeID, board.b)
        board.h.move(to: CGPoint(x: 400, y: 600))
        expectEqual(board.h.editor.hintedShapeID, nil)
    },
    test("switching tools mid-drag cancels the drag's precise timer, as before") {
        for switchTools in [false, true] {
            let board = try Board(arrow: 0)
            board.h.editor.selection = board.arrow
            board.h.move(to: CGPoint(x: 560, y: 180))
            board.h.press()                                               // the end handle, at its anchor
            board.h.drag(to: CGPoint(x: 800, y: 500), speed: fast)        // off B: the end frees
            board.h.drag(to: CGPoint(x: 600, y: 150), speed: fast)        // back onto B, imprecise
            if switchTools { board.h.key("a") }
            board.h.wait(400)
            board.h.release()
            expectEqual(board.arrows.first?.end.binding?.isPrecise, !switchTools, "switched: \(switchTools)")
        }
    },
])

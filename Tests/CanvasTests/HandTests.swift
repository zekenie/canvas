@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import TestKit

/// Runs a camera slide a frame at a time until nothing is pending: how far each frame moved the
/// content, in view points. The last frame, where the speed would drop too low, moves nothing.
@MainActor func slideFrames(_ h: EditorHarness) -> [CGPoint] {
    var moves: [CGPoint] = []
    while h.scheduler.pendingCount > 0, moves.count < 1000 {
        let before = h.editor.camera.origin
        h.wait(16)
        moves.append((before - h.editor.camera.origin) * h.editor.camera.zoom)
    }
    return moves
}

/// A hand drag from (100, 100) to (400, 250) at `speed` view points per millisecond, released
/// `holding` ms after the last move: the pointer velocity at the release, and the slide's frames.
@MainActor func fling(at speed: CGFloat, zoom: CGFloat = 1, holding ms: Int = 0) throws -> (velocity: CGPoint, moves: [CGPoint]) {
    let h = try EditorHarness(plugins: [])
    h.editor.camera = Camera(origin: .zero, zoom: zoom)
    h.key("h")
    h.press(at: CGPoint(x: 100, y: 100))
    h.drag(to: CGPoint(x: 400, y: 250), speed: speed)
    h.release(after: ms)
    return (h.editor.pointerVelocity, slideFrames(h))
}

@MainActor let handTests = Suite("Hand", [
    test("the core registers Select V then Hand H, ahead of every plugin's tools; a plugin claiming H conflicts") {
        let registry = try Registry(plugins: [CardsPlugin()])
        expectEqual(registry.tools.map(\.id), [.select, .hand, ToolID(placing: Card.kind)])
        expectEqual(registry.tools.map(\.shortcut), ["v", "h", "c"])
        expectEqual(registry.tools[1].label, "Hand")
        expectEqual(registry.tools[1].systemImage, "hand.raised")
        expectThrows(RegistryError.conflict(point: "Tools", key: "shortcut h", plugins: ["core", "clash"])) {
            _ = try Registry(plugins: [Contributor(id: "clash") {
                $0.tool(ToolDescriptor(id: "other", label: "Other", systemImage: "circle", shortcut: "H")) { _ in NoTool() }
            }])
        }
    },
    test("H selects the hand: open hand; closed while pressed and dragging; no hover outlines or handles") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), KnobsPlugin()])
        let knob = h.add(Knob(CGRect(x: 0, y: 0, width: 100, height: 100)))   // its handle is at (50, 50)
        h.add(Box(CGRect(x: 200, y: 0, width: 100, height: 100)))
        h.editor.selection = knob
        let size = CGSize(width: 400, height: 200)
        let inSelect = renderBitmap(h.editor, size: size)
        expect(h.key("h"))
        expectEqual(h.editor.currentToolID, .hand)
        expectEqual(h.editor.cursor, .openHand)
        h.move(to: CGPoint(x: 50, y: 50))
        expectEqual(h.editor.hoveredHandle, nil)
        h.move(to: CGPoint(x: 250, y: 50))
        expectEqual(h.editor.hovered, nil)
        let inHand = renderBitmap(h.editor, size: size)
        expect(changedPixels(inSelect, inHand, in: CGRect(x: 40, y: 40, width: 20, height: 20)) > 0, "select draws the handle; the hand doesn't")
        expectEqual(changedPixels(inSelect, inHand, in: CGRect(x: 190, y: 0, width: 120, height: 120)), 0, "no hover outline on the box")
        h.press(at: CGPoint(x: 50, y: 50))
        expectEqual(h.editor.cursor, .closedHand)
        h.drag(to: CGPoint(x: 70, y: 60))
        expectEqual(h.editor.cursor, .closedHand)
        h.release(after: 200)
        expectEqual(h.editor.cursor, .openHand)
        expectEqual(h.editor.selection, knob)
    },
    test("a hand drag pans absolutely from the press: after (0,0) → (3,0) → (30,10), camera.origin = start − (30,10)/zoom") {
        for zoom: CGFloat in [1, 0.5, 0.6] {
            let h = try EditorHarness(plugins: [])
            h.editor.camera = Camera(origin: CGPoint(x: 7, y: -3), zoom: zoom)
            h.key("h")
            h.press(at: CGPoint(x: 100, y: 100))
            h.drag(to: CGPoint(x: 103, y: 100))                                  // under the threshold
            expectEqual(h.editor.camera.origin, CGPoint(x: 7, y: -3))
            h.drag(to: CGPoint(x: 130, y: 110))                                  // the threshold's points aren't lost
            expectEqual(h.editor.camera.origin, CGPoint(x: 7 - 30 / zoom, y: -3 - 10 / zoom))
            // Bitwise from the press, not summed event by event (at zoom 0.6 those sums round apart).
            h.drag(to: CGPoint(x: 111.3, y: 97.7))
            h.drag(to: CGPoint(x: 90.45, y: 95.15))
            let end = CGPoint(x: 7 - (90.45 - 100) / zoom, y: -3 - (95.15 - 100) / zoom)
            expectEqual(h.editor.camera.origin, end)
            expectEqual(h.editor.camera.zoom, zoom)
            h.release(after: 200)                                                // held still: no slide
            expectEqual(h.scheduler.pendingCount, 0)
            expectEqual(h.editor.camera.origin, end)
        }
    },
    test("a hand click selects, deselects and moves nothing; a press on a shape pans instead") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let b = h.add(Box(CGRect(x: 200, y: 0, width: 100, height: 100)))
        h.editor.selection = a
        let revision = h.editor.revision
        h.key("h")
        h.press(at: CGPoint(x: 500, y: 500)); h.release()
        expectEqual(h.editor.selectedShapeIDs, [a])
        // A quick 4 pt jiggle on B: not a drag, so no pan and no slide.
        h.press(at: CGPoint(x: 250, y: 50)); h.drag(to: CGPoint(x: 254, y: 50)); h.release(after: 0)
        expectEqual(h.editor.selectedShapeIDs, [a])
        expectEqual(h.editor.camera.origin, .zero)
        expectEqual(h.scheduler.pendingCount, 0)
        h.press(at: CGPoint(x: 250, y: 50)); h.drag(to: CGPoint(x: 280, y: 70)); h.release(after: 200)
        expectEqual(h.editor.camera.origin, CGPoint(x: -30, y: -20))
        expectEqual(h.editor.revision, revision)
        expectEqual(h.editor.document.shapes.map(\.id), [a, b])
        expectEqual(h.editor.document[b]?.box?.origin, CGPoint(x: 200, y: 0))
        expectEqual(h.editor.selectedShapeIDs, [a])
    },
    test("a scroll or pinch mid hand-drag isn't undone: the drag carries on from there") {
        let h = try EditorHarness(plugins: [])
        h.key("h")
        h.press(at: CGPoint(x: 100, y: 100))
        h.drag(to: CGPoint(x: 130, y: 110))
        expectEqual(h.editor.camera.origin, CGPoint(x: -30, y: -10))
        h.editor.camera.pan(by: CGSize(width: 0, height: 50))                   // a scroll
        h.drag(to: CGPoint(x: 140, y: 110))
        expectEqual(h.editor.camera.origin, CGPoint(x: -30, y: -60))
        h.drag(to: CGPoint(x: 150, y: 125))
        expectEqual(h.editor.camera.origin, CGPoint(x: -40, y: -75))
        h.editor.camera.setZoom(2, around: CGPoint(x: 150, y: 125))             // a pinch
        let pinched = h.editor.camera
        h.drag(to: CGPoint(x: 160, y: 125))
        expectEqual(h.editor.camera, pinched)
        h.drag(to: CGPoint(x: 170, y: 135))
        expectEqual(h.editor.camera, Camera(origin: CGPoint(x: pinched.origin.x - 5, y: pinched.origin.y - 5), zoom: 2))
    },
    test("Escape mid-drag stops without a slide; Escape in idle returns to select") {
        let h = try EditorHarness(plugins: [])
        h.key("h")
        h.press(at: CGPoint(x: 100, y: 100))
        h.drag(to: CGPoint(x: 400, y: 100), speed: 2)
        let stopped = h.editor.camera
        h.escape()
        expect(h.editor.session == nil)
        expectEqual(h.editor.currentToolID, .hand)
        expectEqual(h.editor.cursor, .openHand)
        h.drag(to: CGPoint(x: 500, y: 100))
        h.release(after: 0)
        expectEqual(h.scheduler.pendingCount, 0)
        h.wait(100)
        expectEqual(h.editor.camera, stopped)
        h.escape()
        expectEqual(h.editor.currentToolID, .select)
    },
    test("a flung release slides with tldraw's friction") {
        let (v, moves) = try fling(at: 1.5)
        expect(v.x > 1 && v.y > 0.5, "flung down and to the right, faster than 1 pt/ms")
        // Starting at speed 1: 1 × 0.91^48 ≥ 0.01 > 1 × 0.91^49, so 48 frames move and the 49th doesn't.
        expectEqual(moves.count, 49)
        expectClose(moves[0], v * 16)
        for (previous, move) in zip(moves, moves.dropFirst()).dropLast() {
            expectClose(move, previous * 0.91, within: 1e-9)
        }
        expectEqual(moves.last, .zero)
    },
    test("a release after holding still 100 ms, or at |v| ≤ 0.1, doesn't slide; the start speed is |v|, at most 1") {
        let held = try fling(at: 1.5, holding: 100)
        expect(held.velocity != .zero && held.velocity.length < 0.1)
        expectEqual(held.moves, [])
        let crawl = try fling(at: 0.1)
        expect(crawl.velocity.length <= 0.1)
        expectEqual(crawl.moves, [])
        let slow = try fling(at: 0.2)
        expect(slow.velocity.length > 0.1 && slow.velocity.length < 1)
        expectClose(try require(slow.moves.first), slow.velocity * (slow.velocity.length * 16))
        let fast = try fling(at: 3)
        expect(fast.velocity.length > 2)
        expectClose(try require(fast.moves.first), fast.velocity * 16)
    },
    test("the slide covers the same view distance at any zoom") {
        let near = try fling(at: 1.5), far = try fling(at: 1.5, zoom: 0.5)
        expectEqual(far.velocity, near.velocity)
        expectEqual(far.moves.count, near.moves.count)
        for (a, b) in zip(near.moves, far.moves) { expectClose(a, b, within: 1e-9) }
    },
    test("a press with any tool, setting the camera (as scroll and pinch do), or a new flick stops the slide; a tool switch doesn't") {
        let h = try EditorHarness(plugins: [])
        @MainActor func flick() {
            h.key("h")
            h.press(at: CGPoint(x: 100, y: 100))
            h.drag(to: CGPoint(x: 400, y: 250), speed: 1.5)
            h.release(after: 0)
            h.wait(16)
            expectEqual(h.scheduler.pendingCount, 1, "sliding")
        }
        @MainActor func expectStill() {
            expectEqual(h.scheduler.pendingCount, 0)
            let camera = h.editor.camera
            h.wait(100)
            expectEqual(h.editor.camera, camera)
        }
        flick()
        h.key("v")
        let before = h.editor.camera
        h.wait(16)
        expect(h.editor.camera != before, "still sliding after a tool switch")
        h.editor.camera.pan(by: CGSize(width: 0, height: 10))                   // a scroll
        expectStill()
        flick()
        h.editor.camera.setZoom(1.5, around: .zero)                             // a pinch
        expectStill()
        flick()
        h.press(after: 0); h.release()                                          // the hand catches it
        expectStill()
        flick()
        h.key("v")
        h.press(at: CGPoint(x: 700, y: 700), after: 0); h.release()             // a select press
        expectStill()
        flick()
        flick()                                                                 // one slide, not two
    },
    test("the 'pan' transcript steps end at camera (−40, −30) with nothing pending") {
        @MainActor func pan(waiting ms: Int) throws -> EditorHarness {
            let h = try EditorHarness(plugins: [])
            h.key("h")
            h.move(to: CGPoint(x: 380, y: 500))
            h.press(at: CGPoint(x: 380, y: 500))
            h.drag(to: CGPoint(x: 400, y: 520))
            h.drag(to: CGPoint(x: 420, y: 530))
            h.wait(ms)
            h.release()
            return h
        }
        let h = try pan(waiting: 100)
        expectEqual(h.editor.pointerVelocity, .zero)
        expectEqual(h.scheduler.pendingCount, 0)
        h.wait(200)                                                             // as the transcript does
        expectEqual(h.editor.camera.origin, CGPoint(x: -40, y: -30))
        expectEqual(try pan(waiting: 0).scheduler.pendingCount, 1, "without the wait, the release would slide")
    },
])

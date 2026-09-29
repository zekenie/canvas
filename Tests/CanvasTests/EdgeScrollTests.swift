@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import TestKit

// Scrolling at the canvas's edges (tldraw's), for a drag that asks for it: a `TranslatingSession`
// started by hand on the Hand's press (the core has no Selection), in a 1200 × 1100 view, big enough
// for full speed on both axes.

/// A box at (500, 500), 100 across, pressed at its middle and moving with the pointer.
@MainActor private func dragging(view: CGSize = CGSize(width: 1200, height: 1100)) throws -> (EditorHarness, ShapeID) {
    let h = try EditorHarness(plugins: [FixturesPlugin()])
    h.editor.viewportDidResize(to: view)
    let box = h.add(Box(CGRect(x: 500, y: 500, width: 100, height: 100)))
    h.press(at: CGPoint(x: 550, y: 550))
    h.editor.session = TranslatingSession(ids: [box], from: CGPoint(x: 550, y: 550), in: h.editor)
    return (h, box)
}

/// Where the box is if it's under the pointer, grabbed at its middle.
@MainActor private func underPointer(_ h: EditorHarness) -> CGPoint { h.editor.camera.toWorld(h.location) - CGPoint(x: 50, y: 50) }

@MainActor let edgeScrollTests = Suite("Scrolling at the edges", [
    test("at an edge, past 200 ms, the canvas scrolls that way, easing in, faster nearer the edge, and what's dragged stays under the pointer") {
        let (h, box) = try dragging()
        h.drag(to: CGPoint(x: 1196, y: 550))                     // 4 points in: half speed
        h.wait(192)
        expectEqual(h.editor.camera, Camera(), "not before 200 ms")
        h.wait(16)
        let first = h.editor.camera.origin.x
        expectClose(first, 25 * 16 / (1000.0 / 60) * pow(208.0 / 400, 3) * 0.5, within: 1e-9)
        expectClose(try require(h.editor.document[box]?.box?.origin), underPointer(h), within: 1e-9)
        h.wait(400)
        let eased = h.editor.camera.origin.x
        h.wait(16)
        expectClose(h.editor.camera.origin.x - eased, 12, within: 1e-9)     // eased in: half of 24 a frame
        expectEqual(h.editor.camera.origin.y, 0)
        h.drag(to: CGPoint(x: 1300, y: -40))                     // past the corner: full speed both ways
        h.wait(16)
        let corner = h.editor.camera.origin
        h.wait(16)
        expectClose(h.editor.camera.origin - corner, CGPoint(x: 24, y: -24), within: 1e-9)
        expectClose(try require(h.editor.document[box]?.box?.origin), underPointer(h), within: 1e-9)
        h.drag(to: CGPoint(x: 600, y: 600))
        let still = h.editor.camera
        h.wait(500)
        expectEqual(h.editor.camera, still, "off the edges: it stops")
        h.drag(to: CGPoint(x: 1199, y: 600))
        h.wait(192)
        expectEqual(h.editor.camera, still, "back at an edge: the delay starts over")
        h.release()
        h.wait(500)
        expectEqual(h.scheduler.pendingCount, 0, "released: no more frames")
        expectEqual(h.editor.undoHistory.undoName, "Move")
    },
    test("a view under 1,000 points across or up and down scrolls that way slower, as tldraw's does") {
        let (h, _) = try dragging(view: CGSize(width: 900, height: 1100))
        h.drag(to: CGPoint(x: 950, y: 550))
        h.wait(608)
        let x = h.editor.camera.origin.x
        h.wait(16)
        expectClose(h.editor.camera.origin.x - x, 24 * 0.612, within: 1e-9)
    },
    test("nothing scrolls short of the drag threshold, for a drag that doesn't ask (the Hand's), or with no view") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        h.editor.viewportDidResize(to: CGSize(width: 1200, height: 1100))
        let edge = h.add(Box(CGRect(x: 1150, y: 500, width: 100, height: 100)))
        h.press(at: CGPoint(x: 1196, y: 550))                    // 4 points in from the right edge
        h.editor.session = TranslatingSession(ids: [edge], from: CGPoint(x: 1196, y: 550), in: h.editor)
        h.drag(to: CGPoint(x: 1198, y: 551))
        h.wait(1000)
        expectEqual(h.editor.camera, Camera(), "the pointer hasn't gone past the threshold")
        let hand = try EditorHarness(plugins: [FixturesPlugin()])
        hand.editor.viewportDidResize(to: CGSize(width: 1200, height: 1100))
        hand.press(at: CGPoint(x: 600, y: 600))
        hand.drag(to: CGPoint(x: 1199, y: 600))
        let panned = hand.editor.camera
        hand.wait(1000)
        expectEqual(hand.editor.camera, panned, "the Hand pans; it doesn't scroll at edges")
        let headless = try EditorHarness(plugins: [FixturesPlugin()])
        let box = headless.add(Box(CGRect(x: 500, y: 500, width: 100, height: 100)))
        headless.press(at: CGPoint(x: 550, y: 550))
        headless.editor.session = TranslatingSession(ids: [box], from: CGPoint(x: 550, y: 550), in: headless.editor)
        headless.drag(to: CGPoint(x: -500, y: 550))
        headless.wait(1000)
        expectEqual(headless.editor.camera, Camera())
    },
    test("the camera moving mid-drag (a scroll, a pinch) takes what's dragged with it, under the pointer, without the pointer's velocity") {
        let (h, box) = try dragging()
        h.drag(to: CGPoint(x: 600, y: 600))
        let velocity = h.editor.pointerVelocity
        h.editor.camera.pan(by: CGSize(width: -130, height: 20))
        expectClose(try require(h.editor.document[box]?.box?.origin), underPointer(h), within: 1e-9)
        h.editor.camera.zoom(by: 2, around: CGPoint(x: 300, y: 300))
        expectClose(try require(h.editor.document[box]?.box?.origin), underPointer(h), within: 1e-9)
        expectEqual(h.editor.pointerVelocity, velocity)
        h.release()
        let placed = h.editor.document[box]?.box
        h.editor.camera.pan(by: CGSize(width: 50, height: 0))
        expectEqual(h.editor.document[box]?.box, placed, "released: the camera moves alone")
    },
])

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
    h.editor.setTool(.hand)
    h.press(at: CGPoint(x: 100, y: 100))
    h.drag(to: CGPoint(x: 400, y: 250), speed: speed)
    h.release(after: ms)
    return (h.editor.pointerVelocity, slideFrames(h))
}

@MainActor let cameraTests = Suite("Camera motion", [
    test("animateCamera eases each edge of the world rect the view shows to the target's in a straight line, a frame every 16 ms, so a point both cameras show at one place stays there; it lands on the target at the duration") {
        let h = try EditorHarness(plugins: [])
        let target = Camera(origin: CGPoint(x: 300, y: -200), zoom: 2)
        // The view point where both show one world point: (600, -400) at 100% from the origin, and
        // at 200% from (300, -200).
        let fixed = CGPoint(x: 600, y: -400)
        expectEqual(target.toWorld(fixed), fixed)
        h.editor.animateCamera(to: target, duration: .milliseconds(200))
        expectEqual(h.editor.camera, Camera(), "nothing moves before the first frame")
        var zooms: [CGFloat] = []
        for _ in 0..<12 {
            h.wait(16)
            let camera = h.editor.camera, along = camera.origin.x / 300
            zooms.append(camera.zoom)
            expectClose(camera.toWorld(fixed), fixed, within: 1e-9)
            // The rect's edges share the easing: its top left goes as far along as the world units a view point covers do.
            expectClose(camera.origin.y / -200, along, within: 1e-9)
            expectClose(1 / camera.zoom, 1 + (1.0 / 2 - 1) * along, within: 1e-9)
        }
        expect(zip(zooms, zooms.dropFirst()).allSatisfy { $0 < $1 }, "zooms in every frame: \(zooms)")
        let first = 4 * pow(16.0 / 200, 3)      // eases in: 0.2% of the way, not 8%
        expectClose(zooms[0], 1 / (1 - first / 2), within: 1e-9)
        h.wait(7)
        expect(h.editor.camera != target, "192 ms: one short frame to go")
        h.wait(1)
        expectEqual(h.editor.camera, target)
        expectEqual(h.scheduler.pendingCount, 0)
    },
    test("any camera change stops an animation where it is; a new animation or a press replaces it") {
        let h = try EditorHarness(plugins: [])
        h.editor.animateCamera(to: Camera(origin: CGPoint(x: 1000, y: 0)), duration: .milliseconds(200))
        h.wait(48)
        h.editor.camera.pan(by: CGSize(width: 10, height: 0))
        let stopped = h.editor.camera
        h.wait(300)
        expectEqual(h.editor.camera, stopped)
        h.editor.animateCamera(to: Camera(origin: CGPoint(x: 0, y: 500)), duration: .milliseconds(200))
        h.editor.animateCamera(to: Camera(origin: CGPoint(x: 0, y: -500)), duration: .milliseconds(200))
        h.wait(200)
        expectEqual(h.editor.camera, Camera(origin: CGPoint(x: 0, y: -500)))
        h.editor.animateCamera(to: Camera(origin: CGPoint(x: 500, y: 500)), duration: .milliseconds(200))
        h.wait(48)
        h.press(at: CGPoint(x: 10, y: 10), after: 0)
        let pressed = h.editor.camera
        h.wait(300)
        expectEqual(h.editor.camera, pressed)
    },
    test("cameraTarget is where an animation is headed while it runs, and the camera once it lands or stops") {
        let h = try EditorHarness(plugins: [])
        let target = Camera(origin: CGPoint(x: 300, y: -200), zoom: 2)
        expectEqual(h.editor.cameraTarget, Camera())
        h.editor.animateCamera(to: target, duration: .milliseconds(200))
        expectEqual(h.editor.cameraTarget, target, "before the first frame")
        h.wait(80)
        expect(h.editor.camera != target)
        expectEqual(h.editor.cameraTarget, target, "mid-way")
        h.wait(120)
        expectEqual(h.editor.cameraTarget, target, "landed")
        h.editor.animateCamera(to: Camera(), duration: .milliseconds(200))
        h.wait(48)
        h.press(at: CGPoint(x: 10, y: 10), after: 0)          // stops it where it is
        expectEqual(h.editor.cameraTarget, h.editor.camera)
    },
    test("an animation of no duration, or to where the camera is, jumps and leaves nothing pending") {
        let h = try EditorHarness(plugins: [])
        h.editor.animateCamera(to: Camera(zoom: 3), duration: .zero)
        expectEqual(h.editor.camera, Camera(zoom: 3))
        h.editor.animateCamera(to: Camera(zoom: 3), duration: .milliseconds(200))
        expectEqual(h.scheduler.pendingCount, 0)
    },
    test("a fit keeps to its rect while the view settles: the view narrowed mid-move or just after fits it again into what's left, and not once something else moved the camera or its time is up") {
        let h = try EditorHarness(plugins: [])
        let rect = CGRect(x: 0, y: 0, width: 2000, height: 400)
        let wide = CGSize(width: 1200, height: 800), narrow = CGSize(width: 920, height: 800)
        @MainActor func fitted(in size: CGSize) -> Camera { Camera(fitting: rect, in: CGRect(origin: .zero, size: size), inset: 100, maxZoom: 1.2) }
        h.editor.viewportDidResize(to: wide)
        // Mid-move: an inspector sliding in beside the canvas as the selection's shown.
        h.editor.animateCamera(toFit: rect, inset: 100, maxZoom: 1.2, duration: .milliseconds(200))
        expectEqual(h.editor.cameraTarget, fitted(in: wide))
        h.wait(48)
        h.editor.viewportDidResize(to: narrow)
        expectEqual(h.editor.cameraTarget, fitted(in: narrow), "headed for the fit into what's left")
        h.wait(400)
        expectEqual(h.editor.camera, fitted(in: narrow))
        // Just after the move: at once.
        h.editor.viewportDidResize(to: wide)
        h.editor.animateCamera(toFit: rect, inset: 100, maxZoom: 1.2, duration: .milliseconds(200))
        h.wait(250)
        h.editor.viewportDidResize(to: narrow)
        expectEqual(h.editor.camera, fitted(in: narrow))
        h.editor.viewportDidResize(to: wide)
        expectEqual(h.editor.camera, fitted(in: narrow), "wider again (the inspector sliding out), it's all in view: nothing moves")
        // Something else moved the camera since: the view's size moves nothing.
        h.editor.animateCamera(toFit: rect, inset: 100, maxZoom: 1.2, duration: .milliseconds(200))
        h.wait(250)
        h.editor.camera.pan(by: CGSize(width: 30, height: 0))
        let panned = h.editor.camera
        h.editor.viewportDidResize(to: narrow)
        expectEqual(h.editor.camera, panned)
        // Its time is up: a window resized later keeps the camera, as ever.
        h.editor.viewportDidResize(to: wide)
        h.editor.animateCamera(toFit: rect, inset: 100, maxZoom: 1.2, duration: .milliseconds(200))
        h.wait(700)
        let settled = h.editor.camera
        h.editor.viewportDidResize(to: narrow)
        expectEqual(h.editor.camera, settled)
        expectEqual(h.scheduler.pendingCount, 0, "no timer of its own: its time is the scheduler's clock")
    },
    test("what of a rect is in view stays in view while the view settles: a narrower view that leaves part of it out pans by as little as brings it back (the part that showed, of one cut by the view's edge), unless none of it was in view, the camera moved, a press is under way or its time is up; a fit replaces it") {
        let h = try EditorHarness(plugins: [])
        let wide = CGSize(width: 1200, height: 800), narrow = CGSize(width: 900, height: 800)
        // In the wide view, past the narrow one's right edge.
        let rect = CGRect(x: 1000, y: 300, width: 150, height: 100)
        h.editor.viewportDidResize(to: wide)
        h.editor.keepInViewWhileSettling(rect)
        h.wait(100)
        h.editor.viewportDidResize(to: narrow)
        // Its right edge `keepInViewMargin`, 16 points, in from the view's: 1150 - (900 - 16).
        expectEqual(h.editor.camera, Camera(origin: CGPoint(x: 266, y: 0)))
        h.editor.viewportDidResize(to: wide)
        expectEqual(h.editor.camera, Camera(origin: CGPoint(x: 266, y: 0)), "wider, it's still in view: nothing moves")
        // Cut by the view's edge as it's kept: the part that showed (1100 to 1200) comes back into view.
        h.editor.camera = Camera()
        h.editor.keepInViewWhileSettling(CGRect(x: 1100, y: 300, width: 200, height: 100))
        h.editor.viewportDidResize(to: narrow)
        expectEqual(h.editor.camera, Camera(origin: CGPoint(x: 316, y: 0)), "1200 - (900 - 16)")
        // None of it in view: nothing.
        h.editor.viewportDidResize(to: wide)
        h.editor.camera = Camera()
        h.editor.keepInViewWhileSettling(CGRect(x: 1300, y: 300, width: 200, height: 100))
        h.editor.viewportDidResize(to: narrow)
        expectEqual(h.editor.camera, Camera())
        // The camera moved since: nothing.
        h.editor.viewportDidResize(to: wide)
        h.editor.keepInViewWhileSettling(rect)
        h.editor.camera.pan(by: CGSize(width: -10, height: 0))
        let panned = h.editor.camera
        h.editor.viewportDidResize(to: narrow)
        expectEqual(h.editor.camera, panned)
        // A press under way (the Hand's): nothing until it's over, while there's time.
        h.editor.camera = Camera()
        h.editor.viewportDidResize(to: wide)
        h.editor.keepInViewWhileSettling(rect)
        h.press(at: CGPoint(x: 100, y: 100))
        h.editor.viewportDidResize(to: narrow)
        expectEqual(h.editor.camera, Camera())
        h.release()
        h.editor.viewportDidResize(to: CGSize(width: 899, height: 800))
        expectEqual(h.editor.camera, Camera(origin: CGPoint(x: 267, y: 0)))
        // A fit replaces it: fitted again into a view that cuts it (centered in the wide view at 120%, it
        // ends 690 points in).
        h.editor.camera = Camera()
        h.editor.viewportDidResize(to: wide)
        h.editor.keepInViewWhileSettling(rect)
        h.editor.animateCamera(toFit: rect, inset: 100, maxZoom: 1.2, duration: .milliseconds(200))
        h.wait(250)
        let cutting = CGSize(width: 600, height: 800)
        h.editor.viewportDidResize(to: cutting)
        expectEqual(h.editor.camera, Camera(fitting: rect, in: CGRect(origin: .zero, size: cutting), inset: 100, maxZoom: 1.2))
        // Its time is up: nothing.
        h.editor.camera = Camera()
        h.editor.viewportDidResize(to: wide)
        h.editor.keepInViewWhileSettling(rect)
        h.wait(700)
        h.editor.viewportDidResize(to: narrow)
        expectEqual(h.editor.camera, Camera())
        expectEqual(h.scheduler.pendingCount, 0)
    },
    test("what the host's chrome comes to cover keeps a rect in view as a narrower view does, easing with the pane; covering it later moves nothing") {
        let h = try EditorHarness(plugins: [])
        let size = CGSize(width: 1200, height: 800)
        let rect = CGRect(x: 1000, y: 300, width: 150, height: 100)
        h.editor.viewportDidResize(to: size)
        h.editor.keepInViewWhileSettling(rect)
        h.wait(100)
        // The inspector comes in over the canvas's trailing 300 points: the rect's right edge 16 in from its edge, 1150 - (900 - 16).
        h.editor.coveredEdges = CoveredEdges(right: 300)
        expectEqual(h.editor.cameraTarget, Camera(origin: CGPoint(x: 266, y: 0)))
        expect(h.editor.camera != h.editor.cameraTarget, "easing there, as the pane slides in")
        h.wait(250)
        expectEqual(h.editor.camera, Camera(origin: CGPoint(x: 266, y: 0)))
        h.editor.coveredEdges = CoveredEdges()
        expectEqual(h.editor.camera, Camera(origin: CGPoint(x: 266, y: 0)), "uncovered, it's still in view: nothing moves")
        // Its time up (a sidebar shown or hidden later, say): nothing moves.
        h.editor.camera = Camera()
        h.editor.keepInViewWhileSettling(rect)
        h.wait(700)
        h.editor.coveredEdges = CoveredEdges(left: 240, right: 300)
        expectEqual(h.editor.camera, Camera())
        expectEqual(h.editor.unobscuredViewport, CGRect(x: 240, y: 0, width: 660, height: 800), "the clear part, between the sheets")
    },
    test("a rect is brought into the view the chrome will leave (coveredEdgesAhead) by the least pan: never centered, nothing when it is in view, and the part in view now is kept as the pane comes") {
        let h = try EditorHarness(plugins: [])
        h.editor.viewportDidResize(to: CGSize(width: 1200, height: 800))
        let rect = CGRect(x: 1000, y: 300, width: 150, height: 100)
        expect(!h.editor.animateCamera(toShow: rect, margin: 16, duration: .milliseconds(200)), "in view: nothing to do")
        expectEqual(h.editor.cameraTarget, Camera())
        // The inspector the selection will show covers the trailing 300 points: the clear view is 900 wide, before it slides in.
        h.editor.coveredEdgesAhead = { CoveredEdges(right: 300) }
        expectEqual(h.editor.unobscuredViewport, CGRect(x: 0, y: 0, width: 900, height: 800))
        expect(h.editor.animateCamera(toShow: rect, margin: 16, duration: .milliseconds(200)), "past the clear view's edge")
        expectEqual(h.editor.cameraTarget, Camera(origin: CGPoint(x: 266, y: 0)), "its right edge a margin in from the clear view's: the least pan, not a centering")
        h.wait(250)
        expectEqual(h.editor.camera, Camera(origin: CGPoint(x: 266, y: 0)))
        // The pane slides in as headed: what was brought into view stays where it is.
        h.editor.coveredEdges = CoveredEdges(right: 300)
        expectEqual(h.editor.cameraTarget, Camera(origin: CGPoint(x: 266, y: 0)))
        // Above the clear view's top edge: only the vertical pan.
        h.editor.coveredEdgesAhead = nil
        h.editor.coveredEdges = CoveredEdges()
        h.editor.camera = Camera()
        expect(h.editor.animateCamera(toShow: CGRect(x: 100, y: -300, width: 100, height: 100), margin: 16, duration: .milliseconds(200)))
        expectEqual(h.editor.cameraTarget, Camera(origin: CGPoint(x: 0, y: -316)))
        // A rect too big keeps its top-left corner in view; a null one does nothing.
        h.editor.camera = Camera()
        expect(h.editor.animateCamera(toShow: CGRect(x: 1500, y: 1000, width: 3000, height: 3000), margin: 16, duration: .milliseconds(200)))
        expectEqual(h.editor.cameraTarget, Camera(origin: CGPoint(x: 1484, y: 984)))
        expect(!h.editor.animateCamera(toShow: .null, margin: 16, duration: .milliseconds(200)))
    },
    test("services hear each move a kept view makes, from where the camera was headed to where it goes; nothing when it moves nothing") {
        let log = KeptViews()
        let h = try EditorHarness(plugins: [Contributor(id: "kept") { r in r.service { _ in KeptViewListener(log: log) } }])
        let wide = CGSize(width: 1200, height: 800), narrow = CGSize(width: 900, height: 800)
        let rect = CGRect(x: 1000, y: 300, width: 150, height: 100)
        h.editor.viewportDidResize(to: wide)
        h.editor.keepInViewWhileSettling(rect)
        h.editor.viewportDidResize(to: narrow)
        expectEqual(log.moves, [[Camera(), Camera(origin: CGPoint(x: 266, y: 0))]])
        h.editor.viewportDidResize(to: wide)
        expectEqual(log.moves.count, 1, "wider again, nothing moves and no one hears")
        // A fit fitted again as the view narrows mid-move: from where it was headed.
        h.editor.camera = Camera()
        h.editor.animateCamera(toFit: rect, inset: 100, maxZoom: 1.2, duration: .milliseconds(200))
        let headed = h.editor.cameraTarget
        h.wait(64)
        let cutting = CGSize(width: 600, height: 800)
        h.editor.viewportDidResize(to: cutting)
        expectEqual(log.moves.last, [headed, Camera(fitting: rect, in: CGRect(origin: .zero, size: cutting), inset: 100, maxZoom: 1.2)])
        h.wait(400)
        expectEqual(log.moves.count, 2)
        expectEqual(h.scheduler.pendingCount, 0)
    },
])

/// The moves a kept view made (`viewWasKept`), each from and to.
@MainActor final class KeptViews {
    var moves: [[Camera]] = []
}

final class KeptViewListener {
    let log: KeptViews
    init(log: KeptViews) { self.log = log }
}

extension KeptViewListener: EditorService {
    func viewWasKept(from old: Camera, to new: Camera, in editor: CanvasEditor) { log.moves.append([old, new]) }
}

@MainActor let handTests = Suite("Hand", [
    test("the core registers Hand, ahead of every plugin's tools, and starts in it (its key is the Keyboard plugin's)") {
        let registry = try Registry(plugins: [CardsPlugin()])
        expectEqual(registry.tools.map(\.id), [.hand, ToolID(placing: Card.kind)])
        expectEqual(registry.tools[0].label, "Hand")
        expectEqual(registry.tools[0].systemImage, "hand.raised")
        expectEqual(registry.defaultTool, .hand)
        expectEqual(CanvasEditor(registry: registry, scheduler: ManualScheduler()).currentToolID, .hand)
    },
    test("a hand drag pans absolutely from the press: after (0,0) → (3,0) → (30,10), camera.origin = start − (30,10)/zoom") {
        for zoom: CGFloat in [1, 0.5, 0.6] {
            let h = try EditorHarness(plugins: [])
            h.editor.camera = Camera(origin: CGPoint(x: 7, y: -3), zoom: zoom)
            h.editor.setTool(.hand)
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
    test("a scroll or pinch mid hand-drag isn't undone: the drag carries on from there") {
        let h = try EditorHarness(plugins: [])
        h.editor.setTool(.hand)
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
    test("Escape mid-drag stops without a slide; Escape in idle returns to the default tool") {
        let h = try EditorHarness(plugins: [idleTool(isDefault: true)])
        h.editor.setTool(.hand)
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
        expectEqual(h.editor.currentToolID, "idle")
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
        let h = try EditorHarness(plugins: [idleTool()])
        @MainActor func flick() {
            h.editor.setTool(.hand)
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
        h.editor.setTool("idle")
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
        h.editor.setTool("idle")
        h.press(at: CGPoint(x: 700, y: 700), after: 0); h.release()             // another tool's press
        expectStill()
        flick()
        flick()                                                                 // one slide, not two
    },
    test("the 'pan' transcript steps end at camera (−40, −30) with nothing pending") {
        @MainActor func pan(waiting ms: Int) throws -> EditorHarness {
            let h = try EditorHarness(plugins: [])
            h.editor.setTool(.hand)
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
    test("while the hand is held, a press pans as the Hand's does, with its cursors, and the tool stays the tool; let go, the tool presses again") {
        let h = try EditorHarness(plugins: [CardsPlugin()])
        h.editor.setTool(ToolID(placing: Card.kind))
        h.editor.isHandHeld = true
        expectEqual(h.editor.cursor, .openHand)
        h.press(at: CGPoint(x: 100, y: 100))
        expectEqual(h.editor.cursor, .closedHand)
        h.drag(to: CGPoint(x: 160, y: 140))
        expectEqual(h.editor.camera.origin, CGPoint(x: -60, y: -40))
        expectEqual(h.editor.document.shapes, [], "nothing placed")
        h.editor.isHandHeld = false
        h.drag(to: CGPoint(x: 170, y: 140))
        expectEqual(h.editor.camera.origin, CGPoint(x: -70, y: -40), "a pan under way goes on to its release")
        h.release(after: 100)
        expectEqual(h.editor.currentToolID, ToolID(placing: Card.kind), "no setTool")
        expectEqual(h.editor.cursor, .crosshair)
        expectEqual(h.editor.undoHistory.undoName, nil, "panning is no step")
        h.click(at: CGPoint(x: 300, y: 300))
        expectEqual(h.editor.document.shapes.count, 1, "the tool's press again")
    },
    test("a press of the middle button pans, whatever the tool, editing going on; not while another press is under way") {
        let h = try EditorHarness(plugins: [CardsPlugin()])
        let card = h.add(Card(CGRect(x: 0, y: 0, width: 100, height: 60)))
        expect(h.editor.beginEditing(card))
        h.editor.setTool(ToolID(placing: Card.kind))
        expect(h.editor.panPointerDown(PointerEvent(location: CGPoint(x: 100, y: 100), timestamp: h.time)))
        h.drag(to: CGPoint(x: 150, y: 100))
        expectEqual(h.editor.camera.origin, CGPoint(x: -50, y: 0))
        h.release(after: 100)
        expectEqual(h.editor.editingShapeID, card, "editing goes on")
        expectEqual(h.editor.currentToolID, ToolID(placing: Card.kind))
        expectEqual(h.editor.document.shapes.count, 1)
        h.editor.setTool(.hand)
        h.press(at: CGPoint(x: 100, y: 100))
        expect(!h.editor.panPointerDown(PointerEvent(location: CGPoint(x: 100, y: 100), timestamp: h.time)), "a press is under way")
        h.release()
    },
])

/// A tool that does nothing, "idle"; with `isDefault`, the default tool.
@MainActor func idleTool(isDefault: Bool = false) -> Contributor {
    Contributor(id: "idle") {
        $0.tool(ToolDescriptor(id: "idle", label: "Idle", systemImage: "circle")) { _ in NoTool() }
        if isDefault { $0.defaultTool("idle") }
    }
}

@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Observation
import TestKit

@MainActor let zoomTests = Suite("Zoom commands", [
    test("Zoom In and Zoom Out ease to the next stop past the zoom, from where the camera's headed, around the view's center; dimmed at the ends") {
        let h = try EditorHarness(plugins: [])
        h.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        h.editor.camera = Camera(origin: CGPoint(x: 10, y: 20), zoom: 0.87)
        expectEqual(h.editor.zoomPercentage, 87)
        let center = h.editor.camera.toWorld(CGPoint(x: 400, y: 300))
        expect(h.editor.perform(.zoomIn))
        expectEqual(h.editor.camera.zoom, 0.87, "it eases: nothing moves before the first frame")
        expectEqual(h.editor.zoomPercentage, 100, "the zoom it's headed for")
        h.wait(160)
        expect(h.editor.camera.zoom > 0.87 && h.editor.camera.zoom < 1)
        h.wait(160)
        expectEqual(h.editor.camera.zoom, 1, "the next stop, not 87% × 1.25")
        expectClose(h.editor.camera.toWorld(CGPoint(x: 400, y: 300)), center, within: 1e-9)
        expect(h.editor.perform(.zoomIn))
        expect(h.editor.perform(.zoomIn))
        expectEqual(h.editor.zoomPercentage, 400, "a second press before the first lands goes on from where it's headed")
        h.wait(320)
        expectEqual(h.editor.camera.zoom, 4)
        h.editor.perform(.zoomIn)
        h.wait(320)
        expectEqual(h.editor.camera.zoom, 8)
        expect(!h.editor.canPerform(.zoomIn), "800%: the last stop")
        expect(!h.editor.perform(.zoomIn))
        for stop in [4, 2, 1, 0.5, 0.25, 0.1] as [CGFloat] {
            expect(h.editor.perform(.zoomOut))
            h.wait(320)
            expectEqual(h.editor.camera.zoom, stop)
        }
        expect(!h.editor.canPerform(.zoomOut), "10%: the first stop")
        h.editor.camera.zoom = 0.996
        expectEqual(h.editor.zoomPercentage, 100)
        expect(!h.editor.canPerform(.zoomToActualSize), "Actual Size is dimmed at what shows as 100%")
        h.editor.perform(.zoomIn)
        expectEqual(h.editor.zoomPercentage, 200, "and Zoom In goes on to 200%")
        h.wait(320)
        h.editor.camera.zoom = 0.3
        expect(h.editor.perform(.zoomToActualSize))
        h.wait(320)
        expectEqual(h.editor.camera.zoom, 1)
        expectEqual(h.editor.undoHistory.undoName, nil, "zooming is no step")
    },
    test("the zoom percentage changes only as the rounded zoom does: a pan, or an animation's frames, leave it") {
        let h = try EditorHarness(plugins: [])
        h.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        let changed = Flag()
        withObservationTracking { _ = h.editor.zoomPercentage } onChange: { changed.set() }
        h.editor.camera.pan(by: CGSize(width: 40, height: 10))
        h.editor.camera.zoom = 1.001
        expect(!changed.isSet, "a pan, and a zoom that still shows 100%")
        h.editor.perform(.zoomIn)
        expect(changed.isSet)
        expectEqual(h.editor.zoomPercentage, 200)
        let changedAgain = Flag()
        withObservationTracking { _ = h.editor.zoomPercentage } onChange: { changedAgain.set() }
        h.wait(320)
        expect(!changedAgain.isSet, "the frames on the way leave it at the target")
        expectEqual(h.editor.camera.zoom, 2)
        h.editor.animateCamera(to: Camera(zoom: 0.5), duration: .milliseconds(320))
        h.wait(100)
        h.editor.camera.pan(by: CGSize(width: 1, height: 0))
        expectEqual(h.editor.zoomPercentage, h.editor.camera.zoomPercentage, "stopped on the way: the zoom it stopped at")
    },
    test("Zoom to Fit eases every shape into view with a first visit's margin, as close as the zoom goes; dimmed with nothing to fit or no view") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        expect(!h.editor.canPerform(.zoomToFit), "nothing to fit")
        h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 50)))
        h.add(Box(CGRect(x: 300, y: 400, width: 100, height: 50)))
        expect(!h.editor.canPerform(.zoomToFit), "no view to fit into")
        h.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        expect(h.editor.perform(.zoomToFit))
        h.wait(320)
        expectEqual(h.editor.camera, Camera(fitting: CGRect(x: 0, y: 0, width: 400, height: 450), in: CGSize(width: 800, height: 600), inset: 64))
        let small = try EditorHarness(plugins: [FixturesPlugin()])
        small.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        small.add(Box(CGRect(x: 0, y: 0, width: 10, height: 10)))
        small.editor.perform(.zoomToFit)
        small.wait(320)
        expectEqual(small.editor.camera.zoom, 8, "one small box: as close as the zoom goes (tldraw's), where a first visit stops at 100%")
        expectEqual(Camera(fitting: CGRect(x: 5, y: 7, width: 30, height: 40), in: CGSize(width: 800, height: 600), inset: 64, maxZoom: 1),
                    Camera(fitting: CGRect(x: 5, y: 7, width: 30, height: 40), in: CGRect(x: 0, y: 0, width: 800, height: 600), inset: 64, maxZoom: 1),
                    "fitting a view's size is fitting its rect")
    },
    test("Zoom to Fit again, while the camera is still where the fit left it, goes back to the camera from before the fit, and once more fits") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        h.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let start = Camera(origin: CGPoint(x: -300, y: 120), zoom: 0.5)
        h.editor.camera = start
        let fit = Camera(fitting: CGRect(x: 0, y: 0, width: 100, height: 100), in: CGSize(width: 800, height: 600), inset: 64)
        expect(h.editor.perform(.zoomToFit))
        h.wait(320)
        expectEqual(h.editor.camera, fit)
        expect(h.editor.perform(.zoomToFit))
        h.wait(320)
        expectEqual(h.editor.camera, start, "back to where it was, exactly")
        expect(h.editor.perform(.zoomToFit))
        h.wait(320)
        expectEqual(h.editor.camera, fit, "and the next press fits again")
        expect(h.editor.perform(.zoomToFit))
        h.wait(320)
        expectEqual(h.editor.camera, start)
    },
    test("pressed again after the view was resized, or a shape added, it fits again rather than going back") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        h.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let start = Camera(origin: CGPoint(x: -300, y: 120), zoom: 0.5)
        h.editor.camera = start
        h.editor.perform(.zoomToFit)
        h.wait(320)
        h.editor.viewportDidResize(to: CGSize(width: 600, height: 600))
        h.editor.perform(.zoomToFit)
        h.wait(320)
        let narrower = Camera(fitting: CGRect(x: 0, y: 0, width: 100, height: 100), in: CGSize(width: 600, height: 600), inset: 64)
        expectEqual(h.editor.camera, narrower, "the view is narrower: fitted again")
        h.add(Box(CGRect(x: 400, y: 0, width: 100, height: 100)))
        h.editor.perform(.zoomToFit)
        h.wait(320)
        expectEqual(h.editor.camera, Camera(fitting: CGRect(x: 0, y: 0, width: 500, height: 100), in: CGSize(width: 600, height: 600), inset: 64),
                    "a shape added: fitted again")
        h.editor.perform(.zoomToFit)
        h.wait(320)
        expectEqual(h.editor.camera, narrower, "and the press after goes back to where that fit began")
    },
    test("pressed again before the fit lands, it goes back from where the camera is: the fit is what it's headed for") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        h.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let start = Camera(origin: CGPoint(x: -300, y: 120), zoom: 0.5)
        h.editor.camera = start
        h.editor.perform(.zoomToFit)
        h.wait(120)
        let halfway = h.editor.camera
        expect(halfway != start && halfway.zoom > 0.5, "on its way")
        h.editor.perform(.zoomToFit)
        expectEqual(h.editor.camera, halfway, "it eases: nothing moves before the next frame")
        h.wait(320)
        expectEqual(h.editor.camera, start, "back to the camera from before the fit, not the halfway one")
    },
    test("any other camera change forgets the fit's memory: a pan, a zoom, a stop on the way; Zoom to Fit then fits, and remembers where it left") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), PocketsPlugin()])
        h.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let fit = Camera(fitting: CGRect(x: 0, y: 0, width: 100, height: 100), in: CGSize(width: 800, height: 600), inset: 64)
        @MainActor func fitted(from start: Camera) {
            h.editor.camera = start
            h.editor.perform(.zoomToFit)
            h.wait(320)
            expectEqual(h.editor.camera, fit)
        }
        // A pan.
        fitted(from: Camera(origin: CGPoint(x: 50, y: 50), zoom: 2))
        h.editor.camera.pan(by: CGSize(width: 30, height: 0))
        let panned = h.editor.camera
        h.editor.perform(.zoomToFit)
        h.wait(320)
        expectEqual(h.editor.camera, fit, "fits, not back")
        h.editor.perform(.zoomToFit)
        h.wait(320)
        expectEqual(h.editor.camera, panned, "and goes back to where the pan left it")
        // A zoom command.
        fitted(from: Camera(origin: CGPoint(x: 50, y: 50), zoom: 2))
        h.editor.perform(.zoomIn)
        h.wait(320)
        h.editor.perform(.zoomToFit)
        h.wait(320)
        expectEqual(h.editor.camera, fit)
        // Stopped on the way by a pan.
        h.editor.camera = Camera(origin: CGPoint(x: 50, y: 50), zoom: 2)
        h.editor.perform(.zoomToFit)
        h.wait(100)
        h.editor.camera.pan(by: CGSize(width: 1, height: 0))
        let stopped = h.editor.camera
        h.editor.perform(.zoomToFit)
        h.wait(320)
        expectEqual(h.editor.camera, fit)
        h.editor.perform(.zoomToFit)
        h.wait(320)
        expectEqual(h.editor.camera, stopped, "back to where the stop left it")
    },
    test("showing another board forgets it too: back on the board, the camera is where the fit left it, with nothing to go back to") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), PocketsPlugin()])
        h.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let pocket = h.add(Pocket(CGRect(x: 400, y: 400, width: 50, height: 50)))
        let fit = Camera(fitting: CGRect(x: 0, y: 0, width: 450, height: 450), in: CGSize(width: 800, height: 600), inset: 64)
        h.editor.camera = Camera(origin: CGPoint(x: 50, y: 50), zoom: 2)
        h.editor.perform(.zoomToFit)
        h.wait(320)
        expectEqual(h.editor.camera, fit)
        expect(h.enter(pocket))
        expect(h.editor.showBoard(.root))
        expectEqual(h.editor.camera, fit, "the camera the board was left with")
        h.editor.perform(.zoomToFit)
        h.wait(320)
        expectEqual(h.editor.camera, fit, "not back to before the fit: a board was shown since")
    },
    test("a fit from where the camera already is leaves nothing to go back to, and with nothing to fit the command is off") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        h.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        expect(!h.editor.canPerform(.zoomToFit))
        h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        h.editor.perform(.zoomToFit)
        h.wait(320)
        let fit = h.editor.camera
        h.editor.camera = Camera(origin: CGPoint(x: 9, y: 9), zoom: 3)
        h.editor.perform(.zoomToFit)
        h.wait(320)
        expectEqual(h.editor.camera, fit)
        h.editor.perform(.zoomToFit)
        h.wait(320)
        expectEqual(h.editor.camera, Camera(origin: CGPoint(x: 9, y: 9), zoom: 3))
        h.editor.camera = fit
        h.editor.perform(.zoomToFit)
        h.wait(320)
        expectEqual(h.editor.camera, fit, "already there: nothing is remembered")
        h.editor.perform(.zoomToFit)
        h.wait(320)
        expectEqual(h.editor.camera, fit, "so nothing to go back to")
    },
])

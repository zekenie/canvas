@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Selection
import TableOfContents
import TestKit

let viewport = CGSize(width: 1000, height: 700)

@MainActor let revealTests = Suite("Table of contents: selecting brings shapes into view", [
    test("selecting a row centers its shape, no closer than 120%, over 200 ms") {
        let scheduler = ManualScheduler()
        let editor = try contentsEditor(scheduler: scheduler)
        editor.viewportDidResize(to: viewport)
        let widget = editor.add(Widget(name: "Far"))
        editor.contents.select([widget])
        expectEqual(editor.camera, Camera(), "nothing moves before the first frame")
        scheduler.advance(by: .milliseconds(100))
        expect(editor.camera.zoom > 1 && editor.camera.zoom < 1.2, "halfway, part of the way in: \(editor.camera.zoom)")
        scheduler.advance(by: .milliseconds(100))
        expectClose(editor.camera.zoom, 1.2)
        expectClose(editor.camera.toView(CGPoint(x: widgetFrame.midX, y: widgetFrame.midY)), CGPoint(x: 500, y: 350), within: 1e-9)
        expectEqual(scheduler.pendingCount, 0, "the animation is over")
    },
    test("selecting several rows fits them all, with 100 points of margin in all") {
        let scheduler = ManualScheduler()
        let editor = try contentsEditor(scheduler: scheduler)
        editor.viewportDidResize(to: viewport)
        let a = editor.add(Widget(CGRect(x: 0, y: 0, width: 100, height: 600), name: "Left"))
        let b = editor.add(Widget(CGRect(x: 1900, y: 0, width: 100, height: 100), name: "Right"))
        editor.contents.select([a, b])
        scheduler.advance(by: .milliseconds(200))
        expectClose(editor.camera.zoom, 0.45)          // (1000 - 100) / 2000 across; (700 - 100) / 600 down
        expectClose(editor.camera.toView(CGPoint(x: 1000, y: 300)), CGPoint(x: 500, y: 350), within: 1e-9)
    },
    test("selecting what's already selected moves nothing") {
        let scheduler = ManualScheduler()
        let editor = try contentsEditor(scheduler: scheduler)
        editor.viewportDidResize(to: viewport)
        let widget = editor.add(Widget(name: "Here"))
        editor.selectedShapeIDs = [widget]
        editor.contents.select([widget])
        scheduler.advance(by: .milliseconds(300))
        expectEqual(editor.camera, Camera())
    },
    test("before the view has a size, selecting a row only selects") {
        let scheduler = ManualScheduler()
        let editor = try contentsEditor(scheduler: scheduler)
        let widget = editor.add(Widget(name: "Unseen"))
        editor.contents.select([widget])
        scheduler.advance(by: .milliseconds(300))
        expectEqual(editor.selection, widget)
        expectEqual(editor.camera, Camera())
    },
    test("a scroll mid-way stops the camera where it is") {
        let h = try EditorHarness { try contentsEditor(scheduler: $0) }
        h.editor.viewportDidResize(to: viewport)
        let widget = h.add(Widget(name: "Far"))
        h.editor.contents.select([widget])
        h.wait(96)
        let midway = h.editor.camera
        h.editor.camera.pan(by: CGSize(width: 5, height: 0))
        h.wait(200)
        expectClose(h.editor.camera.origin.x, midway.origin.x - 5 / midway.zoom, within: 1e-9)
        expectEqual(h.editor.camera.zoom, midway.zoom)
    },
])

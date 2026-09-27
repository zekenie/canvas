@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Selection
import TestKit

@MainActor private func boxes(_ h: EditorHarness, _ count: Int) -> [ShapeID] {
    (0..<count).map { h.add(Box(CGRect(x: CGFloat($0) * 150, y: 0, width: 100, height: 100))) }
}

@MainActor let historyTests = Suite("Going back", [
    test("each change of the selection is a step back, with the camera as it was when it was left; going back restores both, the camera animated, and isn't a step") {
        let h = try EditorHarness(plugins: [SelectionPlugin(), FixturesPlugin()])
        let shapes = boxes(h, 2), a = shapes[0], b = shapes[1]
        expect(!h.editor.canGoBack, "nothing selected yet, nothing to go back to")
        h.click(at: CGPoint(x: 50, y: 50))
        expectEqual(h.editor.selectedShapeIDs, [a])
        expect(h.editor.canGoBack)
        let left = Camera(origin: CGPoint(x: 100, y: 40), zoom: 1.5)
        h.editor.camera = left
        h.editor.selection = b                                  // as a row of the table of contents does
        h.editor.camera = Camera(origin: CGPoint(x: -300, y: 0), zoom: 0.5)

        h.editor.goBack()
        expectEqual(h.editor.selectedShapeIDs, [a], "at once")
        h.wait(100)
        expect(h.editor.camera != left, "the camera is on its way")
        h.wait(100)
        expectEqual(h.editor.camera, left, "and there after 200 ms")

        h.editor.goBack()
        expectEqual(h.editor.selectedShapeIDs, [], "back to nothing selected, where the board started")
        h.wait(200)
        expectEqual(h.editor.camera, Camera())
        expect(!h.editor.canGoBack, "going back took no steps of its own")
    },
    test("a step taken while the camera glides keeps where it was headed, not where it was that moment") {
        let h = try EditorHarness(plugins: [SelectionPlugin(), FixturesPlugin()])
        let shapes = boxes(h, 2)
        h.editor.selection = shapes[0]
        let zoomed = Camera(origin: CGPoint(x: 500, y: 500), zoom: 2)
        h.editor.animateCamera(to: zoomed, duration: .milliseconds(200))     // as a row's zoom does
        h.wait(80)
        h.editor.selection = shapes[1]                                       // another row, 80 ms in
        h.wait(200)
        h.editor.goBack()
        h.wait(200)
        expectEqual(h.editor.selectedShapeIDs, [shapes[0]])
        expectEqual(h.editor.camera, zoomed)
    },
    test("a press and its drag are one step: a marquee goes back to what was selected before the press, not the nothing the press left") {
        let h = try EditorHarness(plugins: [SelectionPlugin(), FixturesPlugin()])
        let shapes = boxes(h, 3)
        h.click(at: CGPoint(x: 50, y: 50))
        h.press(at: CGPoint(x: 140, y: 150))                   // empty canvas: deselects on the press…
        expectEqual(h.editor.selectedShapeIDs, [])
        h.drag(to: CGPoint(x: 200, y: 50))
        h.drag(to: CGPoint(x: 400, y: 50))                     // …then the marquee selects, and selects more
        h.release()
        expectEqual(h.editor.selectedShapeIDs, [shapes[1], shapes[2]])
        h.editor.goBack()
        expectEqual(h.editor.selectedShapeIDs, [shapes[0]])
        h.click(at: CGPoint(x: 600, y: 600))                   // a click on empty canvas: one step
        h.editor.goBack()
        expectEqual(h.editor.selectedShapeIDs, [shapes[0]])
        h.editor.goBack()
        expectEqual(h.editor.selectedShapeIDs, [])
        expect(!h.editor.canGoBack)
    },
    test("a press on a shape of several selected, released without a drag, is one step, back to all of them") {
        let h = try EditorHarness(plugins: [SelectionPlugin(), FixturesPlugin()])
        let shapes = boxes(h, 2)
        h.editor.selectedShapeIDs = shapes
        h.click(at: CGPoint(x: 200, y: 50))                    // selects only the one released on
        expectEqual(h.editor.selectedShapeIDs, [shapes[1]])
        h.editor.goBack()
        expectEqual(h.editor.selectedShapeIDs, shapes)
    },
    test("reordering the same shapes isn't a step, nor is selecting what's selected") {
        let h = try EditorHarness(plugins: [SelectionPlugin(), FixturesPlugin()])
        let shapes = boxes(h, 2)
        h.editor.selectedShapeIDs = shapes
        h.editor.selectedShapeIDs = shapes.reversed()
        h.editor.selectedShapeIDs = shapes.reversed()
        h.editor.goBack()
        expectEqual(h.editor.selectedShapeIDs, [])
        expect(!h.editor.canGoBack)
    },
    test("the stack keeps the last 50 steps") {
        let h = try EditorHarness(plugins: [SelectionPlugin(), FixturesPlugin()])
        let shapes = boxes(h, 60)
        for id in shapes { h.editor.selection = id }            // 60 steps: nothing, then the first 59
        var steps = 0
        while h.editor.canGoBack {
            h.editor.goBack()
            steps += 1
        }
        expectEqual(steps, 50)
        expectEqual(h.editor.selectedShapeIDs, [shapes[9]], "the ten oldest steps are gone")
    },
    test("going back leaves out shapes that are gone, skips a step whose shapes all are, and still goes back to nothing selected") {
        let h = try EditorHarness(plugins: [SelectionPlugin(), FixturesPlugin()])
        let shapes = boxes(h, 4), a = shapes[0], b = shapes[1], c = shapes[2], d = shapes[3]
        h.editor.selection = a
        h.editor.selectedShapeIDs = [b, c]
        h.editor.selection = d
        h.editor.transact { $0.delete([a, c]) }
        h.editor.goBack()
        expectEqual(h.editor.selectedShapeIDs, [b], "c is gone")
        h.editor.goBack()
        expectEqual(h.editor.selectedShapeIDs, [], "a is gone, so its step is skipped for the one before")
        expect(!h.editor.canGoBack)
    },
    test("Back isn't offered when going back would change nothing, as after deleting the only shape selected") {
        let h = try EditorHarness(plugins: [SelectionPlugin(), FixturesPlugin()])
        let shapes = boxes(h, 2)
        h.editor.selection = shapes[0]
        h.editor.deleteSelection()                    // steps: nothing (what's selected now), then the deleted shape
        expect(!h.editor.canGoBack)
        expect(!h.editor.canPerform(.goBack))
        h.editor.selection = shapes[1]
        expect(h.editor.canGoBack, "back to nothing selected, past the deleted shape")
        h.editor.goBack()
        expectEqual(h.editor.selectedShapeIDs, [])
        expect(!h.editor.canGoBack)
    },
    test("deleting the selection is a step, which going back skips once its shapes are gone") {
        let h = try EditorHarness(plugins: [SelectionPlugin(), FixturesPlugin()])
        let shapes = boxes(h, 2)
        h.editor.selection = shapes[0]
        h.editor.selection = shapes[1]
        h.editor.deleteSelection()
        expectEqual(h.editor.selectedShapeIDs, [])
        h.editor.goBack()
        expectEqual(h.editor.selectedShapeIDs, [shapes[0]])
    },
    test("Back is a command, enabled only with a step to go back to, and not mid-gesture") {
        let h = try EditorHarness(plugins: [SelectionPlugin(), FixturesPlugin()])
        let shapes = boxes(h, 2)
        expect(!h.editor.canPerform(.goBack))
        expect(!h.editor.perform(.goBack))
        h.click(at: CGPoint(x: 50, y: 50))
        expect(h.editor.canPerform(.goBack))
        h.press(at: CGPoint(x: 200, y: 50))
        h.drag(to: CGPoint(x: 260, y: 80))                     // moving the other shape
        expect(!h.editor.canPerform(.goBack), "not while it moves")
        expect(!h.editor.perform(.goBack))
        expect(h.editor.canGoBack, "though there's still a step back, so the panel's button stays")
        h.editor.goBack()
        expectEqual(h.editor.selectedShapeIDs, [shapes[1]])
        h.release()
        expect(h.editor.perform(.goBack))
        expectEqual(h.editor.selectedShapeIDs, [shapes[0]])
    },
    test("without the Selection plugin there's nothing to go back to, and no one claims Back") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        expect(!h.editor.canGoBack)
        expect(!h.editor.canPerform(.goBack))
        h.editor.goBack()
    },
])

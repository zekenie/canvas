@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Keyboard
import Selection
import TestKit

/// The view's size in these tests: a board starts showing the world from 0, 0 to 1000, 700.
private let view = CGSize(width: 1000, height: 700)

/// The keyboard, the selection and the fixtures, in a view of `view`'s size.
@MainActor private func historyHarness() throws -> EditorHarness {
    let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin()])
    h.editor.viewportDidResize(to: view)
    return h
}

/// `count` boxes in a row along the top of the view, 150 apart: all in view where a board starts.
@MainActor private func boxes(_ h: EditorHarness, _ count: Int) -> [ShapeID] {
    (0..<count).map { h.add(Box(CGRect(x: CGFloat($0) * 150, y: 0, width: 100, height: 100))) }
}

/// A box `n` views' worth to the right of where a board starts, out of view there and of every other
/// such box's view, and the camera that shows it, at (150, 150) in the view: where a pan of the
/// person's own takes them.
@MainActor private func away(_ h: EditorHarness, _ n: Int) -> (ShapeID, Camera) {
    let x = CGFloat(n) * 3000
    return (h.add(Box(CGRect(x: x + 100, y: 100, width: 100, height: 100))), Camera(origin: CGPoint(x: x, y: 0)))
}

@MainActor let historyTests = Suite("Going back", [
    test("selecting what's in view is no step: clicks, the marquee and a row only move where the person is") {
        let h = try historyHarness()
        let shapes = boxes(h, 3)
        h.click(at: CGPoint(x: 50, y: 50))
        h.click(at: CGPoint(x: 200, y: 50))
        h.press(at: CGPoint(x: 140, y: 150))                   // empty canvas: deselects on the press…
        h.drag(to: CGPoint(x: 200, y: 50))
        h.drag(to: CGPoint(x: 400, y: 50))                     // …then the marquee selects, and selects more
        h.release()
        expectEqual(Set(h.editor.selectedShapeIDs), [shapes[1], shapes[2]])
        h.click(at: CGPoint(x: 200, y: 50))                    // one of several, released without a drag
        expectEqual(h.editor.selectedShapeIDs, [shapes[1]])
        h.editor.selection = shapes[0]                         // as a plugin selects
        h.click(at: CGPoint(x: 600, y: 600))                   // empty canvas
        expectEqual(h.editor.selectedShapeIDs, [])
        expect(!h.editor.canGoBack, "every selection was in the view the person had")
    },
    test("selecting what wasn't in view is a place of its own: Back returns to what was selected and the camera the person had there, not the one they panned to, and isn't a step; Forward comes back") {
        let h = try historyHarness()
        let a = boxes(h, 1)[0]
        let (far, there) = away(h, 1)
        h.click(at: CGPoint(x: 50, y: 50))
        h.editor.camera = there                                // the person pans off…
        h.editor.selection = far                               // …and selects there
        expect(h.editor.canGoBack)

        h.editor.goBack()
        expectEqual(h.editor.selectedShapeIDs, [a], "at once")
        h.wait(100)
        expect(h.editor.camera != there && h.editor.camera != Camera(), "the camera on its way: \(h.editor.camera)")
        h.wait(100)
        expectEqual(h.editor.camera, Camera(), "and where a was selected, not where the pan left it")
        expect(!h.editor.canGoBack, "going back took no step of its own")

        h.editor.goForward()
        expectEqual(h.editor.selectedShapeIDs, [far])
        h.wait(200)
        expectEqual(h.editor.camera, there, "Forward returns to where Back was gone from")
    },
    test("a zoom of the person's own out to a shape is left the same way: Back returns to the closer view") {
        let h = try historyHarness()
        let a = boxes(h, 1)[0]
        let (far, _) = away(h, 1)
        h.editor.selection = a
        h.editor.camera = Camera(origin: CGPoint(x: -1000, y: -1000), zoom: 0.1)     // both in view from here
        h.editor.selection = far
        h.editor.goBack()
        h.wait(200)
        expectEqual(h.editor.selectedShapeIDs, [a])
        expectEqual(h.editor.camera, Camera())
    },
    test("where the person is follows Selection bringing the selection into view: a click near it then is no step, and a place left keeps where the glide was headed") {
        let h = try historyHarness()
        let a = boxes(h, 1)[0]
        let (far, there) = away(h, 1)
        let near = h.add(Box(CGRect(x: 3300, y: 100, width: 100, height: 100)))
        h.editor.selection = far                               // a plugin's: out of view, a step…
        h.editor.reveal([far])                                 // …and brought into view
        h.editor.selection = near                              // in the view the reveal brought
        h.editor.selection = far
        h.editor.goBack()
        expectEqual(h.editor.selectedShapeIDs, [], "back to where the board started, nothing selected")
        expect(!h.editor.canGoBack, "near and far again, in the view the reveal brought, were no steps")

        h.editor.selection = a
        h.editor.reveal([a])                                   // Zoom to Selection's glide
        let glide = h.editor.cameraTarget
        h.wait(80)
        h.editor.camera = there                                // a pan mid-glide stops it
        h.editor.selection = far
        h.editor.goBack()
        h.wait(200)
        expectEqual(h.editor.selectedShapeIDs, [a])
        expectEqual(h.editor.camera, glide, "where the reveal was headed, not where it was when the pan stopped it")
    },
    test("what a plugin does inside navigate is going somewhere: one step however near what it selects, none when it changes nothing, and nothing inside records a step of its own") {
        let h = try historyHarness()
        let shapes = boxes(h, 3)
        let (far, _) = away(h, 1)
        h.editor.selection = shapes[0]
        h.editor.navigate { h.editor.selection = shapes[1] }      // in view, as a row of the table of contents picks it
        expect(h.editor.canGoBack, "a place of its own, however near")
        h.editor.navigate {
            h.editor.selection = far                              // out of view: no step of its own inside
            h.editor.selection = shapes[2]
            h.editor.reveal([shapes[2]])
        }
        h.editor.navigate { h.editor.reveal([shapes[2]]) }        // the selection as it was: no step
        h.editor.goBack()
        expectEqual(h.editor.selectedShapeIDs, [shapes[1]], "one step for the second, whatever it went through")
        h.editor.goBack()
        expectEqual(h.editor.selectedShapeIDs, [shapes[0]])
        expect(!h.editor.canGoBack)
    },
    test("bringing shapes that aren't selected into view moves the camera as a pan does: selecting one there is a place of its own") {
        let h = try historyHarness()
        let a = boxes(h, 1)[0]
        let (far, _) = away(h, 1)
        h.editor.selection = a
        h.editor.reveal([far])                                 // a Find hit's, say
        h.wait(200)
        h.editor.selection = far
        h.editor.goBack()
        h.wait(200)
        expectEqual(h.editor.selectedShapeIDs, [a])
        expectEqual(h.editor.camera, Camera(), "the view a was selected in")
    },
    test("where the person is follows a view the core keeps as the inspector slides in: what the kept view shows is in view, and Back returns to it; a Find hit's fit kept so leaves the place where it was") {
        let h = try historyHarness()
        let narrow = CGSize(width: 700, height: 700)
        let edge = h.add(Box(CGRect(x: 880, y: 300, width: 100, height: 100)))
        let beside = h.add(Box(CGRect(x: 900, y: 450, width: 80, height: 80)))
        h.editor.selection = edge
        h.editor.viewportDidResize(to: narrow)                 // the inspector slides in: edge is brought back into view
        let kept = Camera(origin: CGPoint(x: 296, y: 0))
        expectEqual(h.editor.camera, kept)
        h.editor.selection = beside                            // in the kept view, out of the narrow one the camera had
        expect(!h.editor.canGoBack, "selected in the view the person has")
        let (far, there) = away(h, 1)
        h.editor.camera = there
        h.editor.selection = far
        h.editor.goBack()
        h.wait(400)
        expectEqual(h.editor.selectedShapeIDs, [beside])
        expectEqual(h.editor.camera, kept, "the view kept, not the one before it")

        // Revealed without being selected (a Find hit, wide enough that the narrower view cuts its fit), then the
        // view narrows: the fit is kept, the place isn't moved.
        let g = try historyHarness()
        let a = boxes(g, 1)[0]
        let hit = g.add(Box(CGRect(x: 3100, y: 100, width: 800, height: 100)))
        g.editor.selection = a
        g.editor.reveal([hit])
        let fitted = g.editor.cameraTarget
        g.wait(64)
        g.editor.viewportDidResize(to: narrow)
        g.wait(400)
        expect(g.editor.camera != fitted, "the fit was fitted again into the narrower view")
        g.editor.selection = hit
        expect(g.editor.canGoBack, "the hit's view isn't where the person was")
        g.editor.goBack()
        g.wait(400)
        expectEqual(g.editor.selectedShapeIDs, [a])
        expectEqual(g.editor.camera, Camera())
    },
    test("following a link mid-glide leaves the place where the camera was headed") {
        let h = try historyHarness()
        let a = boxes(h, 1)[0]
        let (far, _) = away(h, 1)
        h.editor.selection = a
        let zoomed = Camera(origin: CGPoint(x: 20, y: 20), zoom: 2)
        h.editor.animateCamera(to: zoomed, duration: .milliseconds(200))
        h.wait(80)
        h.editor.goTo([far])
        h.wait(200)
        h.editor.goBack()
        h.wait(200)
        expectEqual(h.editor.selectedShapeIDs, [a])
        expectEqual(h.editor.camera, zoomed)
    },
    test("a press and its drag are one step at most: after a pan, a marquee goes back to what was selected before the press, not the nothing the press left") {
        let h = try historyHarness()
        let a = boxes(h, 1)[0]
        let (b, there) = away(h, 1)
        let c = h.add(Box(CGRect(x: 3300, y: 100, width: 100, height: 100)))
        h.click(at: CGPoint(x: 50, y: 50))
        h.editor.camera = there
        h.press(at: CGPoint(x: 50, y: 400))                    // empty canvas: deselects on the press…
        expectEqual(h.editor.selectedShapeIDs, [])
        h.drag(to: CGPoint(x: 250, y: 150))
        h.drag(to: CGPoint(x: 450, y: 150))                    // …then the marquee selects b, then c too
        h.release()
        expectEqual(Set(h.editor.selectedShapeIDs), [b, c])
        h.editor.goBack()
        expectEqual(h.editor.selectedShapeIDs, [a], "one step, back to what the press found")
        expect(!h.editor.canGoBack)
    },
    test("reordering the same shapes isn't a step, nor is selecting what's selected, wherever the camera is") {
        let h = try historyHarness()
        let shapes = boxes(h, 2)
        let (_, there) = away(h, 1)
        h.editor.selectedShapeIDs = shapes
        h.editor.camera = there
        h.editor.selectedShapeIDs = shapes.reversed()
        h.editor.selectedShapeIDs = shapes.reversed()
        expect(!h.editor.canGoBack)
    },
    test("with no view to judge by, nothing is out of it") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin()])
        let a = boxes(h, 1)[0]
        let (far, there) = away(h, 1)
        h.editor.selection = a
        h.editor.camera = there
        h.editor.selection = far
        expect(!h.editor.canGoBack)
    },
    test("the stack keeps the last 50 places") {
        let h = try historyHarness()
        let places = (1...60).map { away(h, $0) }
        for (id, camera) in places {
            h.editor.camera = camera
            h.editor.selection = id                            // out of the view the one before was selected in
        }
        var steps = 0
        while h.editor.canGoBack {
            h.editor.goBack()
            steps += 1
        }
        expectEqual(steps, 50)
        expectEqual(h.editor.selectedShapeIDs, [places[9].0], "the oldest are gone")
    },
    test("going back leaves out shapes that are gone, skips a place whose shapes all are, and still goes back to nothing selected") {
        let h = try historyHarness()
        let (a, _) = away(h, 1)
        let (b, two) = away(h, 2)
        let c = h.add(Box(CGRect(x: 6300, y: 100, width: 100, height: 100)))
        let (d, three) = away(h, 3)
        h.editor.selection = a                                 // a plugin's, out of view: back to nothing selected
        h.editor.camera = two
        h.editor.selectedShapeIDs = [b, c]
        h.editor.camera = three
        h.editor.selection = d
        h.editor.transact { $0.delete([a, c]) }
        h.editor.goBack()
        expectEqual(h.editor.selectedShapeIDs, [b], "c is gone")
        h.editor.goBack()
        expectEqual(h.editor.selectedShapeIDs, [], "a is gone, so its place is skipped for the one before")
        expect(!h.editor.canGoBack)
    },
    test("Back isn't offered when going back would change nothing, as after deleting the only shape selected") {
        let h = try historyHarness()
        let (a, _) = away(h, 1)
        let b = boxes(h, 1)[0]
        h.editor.selection = a                                 // out of view: a step back to nothing selected
        h.editor.deleteSelection()                             // nothing selected now, and no step
        expect(!h.editor.canGoBack)
        expect(!h.editor.canPerform(.goBack))
        h.editor.selection = b
        expect(h.editor.canGoBack, "back to nothing selected")
        h.editor.goBack()
        expectEqual(h.editor.selectedShapeIDs, [])
        expect(!h.editor.canGoBack)
    },
    test("deleting the selection is no step: Back goes past it to the place before") {
        let h = try historyHarness()
        let a = boxes(h, 1)[0]
        let (far, there) = away(h, 1)
        h.editor.selection = a
        h.editor.camera = there
        h.editor.selection = far
        h.editor.deleteSelection()
        expectEqual(h.editor.selectedShapeIDs, [])
        h.editor.goBack()
        expectEqual(h.editor.selectedShapeIDs, [a])
    },
    test("Forward stays through selections in view after Back, and goes once the person goes somewhere new") {
        let h = try historyHarness()
        let shapes = boxes(h, 2)
        let (far, there) = away(h, 1)
        let (farther, _) = away(h, 2)
        h.editor.selection = shapes[0]
        h.editor.camera = there
        h.editor.selection = far
        h.editor.goBack()
        h.wait(200)
        h.editor.selection = shapes[1]                         // in view where Back arrived
        expect(h.editor.canGoForward, "a selection in view keeps the way forward, as VS Code's replaces its current place")
        h.editor.goForward()
        expectEqual(h.editor.selectedShapeIDs, [far])
        h.editor.goBack()
        expectEqual(h.editor.selectedShapeIDs, [shapes[1]], "the place Back left was shapes[1], where the person had got to")
        h.editor.goTo([farther])
        expect(!h.editor.canGoForward, "going somewhere new lets the way forward go")
    },
    test("Back is a command, enabled only with a place to go back to, and not mid-gesture") {
        let h = try historyHarness()
        let a = boxes(h, 1)[0]
        let (far, there) = away(h, 1)
        expect(!h.editor.canPerform(.goBack))
        expect(!h.editor.perform(.goBack))
        h.click(at: CGPoint(x: 50, y: 50))
        expect(!h.editor.canPerform(.goBack), "a click in view is no place to go back to")
        h.editor.camera = there
        h.press(at: CGPoint(x: 150, y: 150))                   // far, out of the view a was selected in
        h.drag(to: CGPoint(x: 210, y: 180))                    // moving it
        expect(!h.editor.canPerform(.goBack), "not while it moves")
        expect(!h.editor.perform(.goBack))
        expect(h.editor.canGoBack, "though there's still a place back, so the panel's button stays")
        h.editor.goBack()
        expectEqual(h.editor.selectedShapeIDs, [far])
        h.release()
        expect(h.editor.perform(.goBack))
        expectEqual(h.editor.selectedShapeIDs, [a])
    },
    test("without the Selection plugin there's nothing to go back to, and no one claims Back") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        expect(!h.editor.canGoBack)
        expect(!h.editor.canPerform(.goBack))
        h.editor.goBack()
    },
    test("a way around that moved only the camera, the selection kept, is a place of its own: Back returns the camera with the selection as it is, and Forward goes there again") {
        let h = try historyHarness()
        let a = boxes(h, 1)[0]
        let (far, _) = away(h, 1)
        h.editor.selection = a
        let start = try require(h.editor.navigationStart)
        h.editor.navigate(from: start) { h.editor.revealIfOffscreen([far]) }
        h.wait(300)
        let there = h.editor.camera
        expect(there != Camera(), "the camera went to it")
        expectEqual(h.editor.selectedShapeIDs, [a], "nothing more selected")
        expect(h.editor.canGoBack)
        h.editor.goBack()
        h.wait(300)
        expectEqual(h.editor.camera, Camera(), "where it was")
        expectEqual(h.editor.selectedShapeIDs, [a])
        expect(!h.editor.canGoBack)
        expect(h.editor.canGoForward)
        h.editor.goForward()
        h.wait(300)
        expectEqual(h.editor.camera, there)
        expectEqual(h.editor.selectedShapeIDs, [a])
    },
    test("two ways around in a row that each moved only the camera, the selection kept, are two places: Back returns to each in turn") {
        let h = try historyHarness()
        let a = boxes(h, 1)[0]
        let (far, _) = away(h, 1)
        let (farther, _) = away(h, 2)
        h.editor.selection = a
        let first = try require(h.editor.navigationStart)
        h.editor.navigate(from: first) { h.editor.revealIfOffscreen([far]) }
        h.wait(300)
        let between = h.editor.camera
        let second = try require(h.editor.navigationStart)
        h.editor.navigate(from: second) { h.editor.revealIfOffscreen([farther]) }
        h.wait(300)
        h.editor.goBack()
        h.wait(300)
        expectEqual(h.editor.camera, between, "where the second began")
        h.editor.goBack()
        h.wait(300)
        expectEqual(h.editor.camera, Camera(), "and then where the first did")
    },
    test("a place left by selecting, whose shapes are selected again in view, is passed over whatever the camera: only a way around's place is gone back to by its camera") {
        let h = try historyHarness()
        let a = boxes(h, 1)[0]
        let (far, _) = away(h, 1)
        h.editor.selection = a
        h.editor.camera = Camera(zoom: 0.1)                    // a zoom of the person's own: both in view
        h.editor.selection = far                               // away from the view A was selected in: (A, the start) goes on
        h.editor.selection = a                                 // in view of where far was: no step, A selected again
        expect(!h.editor.canGoBack, "A's place would only pan the camera: passed over")
    },
    test("a way around's start goes on the history though a place left earlier looks just the same: Back returns to it, not past it") {
        let h = try historyHarness()
        let a = boxes(h, 1)[0]
        let (far, there) = away(h, 1)
        let (farther, _) = away(h, 2)
        h.editor.selection = a
        h.editor.camera = there
        h.editor.selection = far                               // a place of its own: A, where the board starts
        h.editor.camera = Camera()
        h.editor.selection = a                                 // and far's: the person is where they began
        let start = try require(h.editor.navigationStart)
        h.editor.navigate(from: start) { h.editor.revealIfOffscreen([farther]) }
        h.wait(300)
        h.editor.goBack()
        h.wait(300)
        expectEqual(h.editor.selectedShapeIDs, [a], "where the way around began, not the place before it")
        expectEqual(h.editor.camera, Camera())
    },
    test("⌘[ and ⌃- go back and ⌘] and ⌃⇧- forward, as Go › Back and Forward do; with nowhere to go, the keys pass, as those items are dimmed") {
        let h = try historyHarness()
        let a = boxes(h, 1)[0]
        let (far, there) = away(h, 1)
        h.hold(.command)
        expect(!h.key("["), "nothing to go back to")
        h.hold(.control)
        expect(!h.key("-"), "nor by VS Code's key")
        h.hold([])
        h.editor.selection = a
        h.editor.camera = there
        h.editor.selection = far
        h.hold(.command)
        expect(h.key("["))
        expectEqual(h.editor.selectedShapeIDs, [a])
        expect(h.key("]"))
        expectEqual(h.editor.selectedShapeIDs, [far])
        h.hold(.control)
        expect(h.key("-"))
        expectEqual(h.editor.selectedShapeIDs, [a])
        h.hold([.control, .shift])
        expect(h.key("_"), "⌃⇧- types ⌃_ on a US keyboard")
        expectEqual(h.editor.selectedShapeIDs, [far])
        expect(!h.key("_"), "nowhere forward: the key passes")
        h.hold([])
    },
])

@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Keyboard
import Selection
import TestKit

/// The view's size in these tests.
private let view = CGSize(width: 1000, height: 700)

/// The keyboard, the selection, the fixtures, editable cards and ghosts (which can't be selected),
/// in a view 1000 × 700 points.
@MainActor private func goToHarness() throws -> EditorHarness {
    let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), CardsPlugin(), GhostsPlugin()])
    h.editor.viewportDidResize(to: view)
    return h
}

/// Where bringing `frame` into view takes the camera: centered, fitted with 100 points of margin in
/// all, no closer than 120%.
private func revealed(_ frame: CGRect) -> Camera { Camera(fitting: frame, in: view, inset: 100, maxZoom: 1.2) }

private let far = CGRect(x: 3000, y: 2000, width: 100, height: 100)

@MainActor let goToTests = Suite("Going to shapes", [
    test("going to a shape ends editing, selects it and brings it into view over 200 ms; that's one step back, to the selection and the camera it left") {
        let h = try goToHarness()
        let card = h.add(Card(CGRect(x: 100, y: 100, width: 100, height: 60)))
        let box = h.add(Box(far))
        h.editor.selection = card
        expect(h.editor.beginEditing(card))
        h.editor.goTo([box])
        expectEqual(h.editor.editingShapeID, nil)
        expectEqual(h.editor.selectedShapeIDs, [box])
        h.wait(100)
        expect(h.editor.camera != Camera() && h.editor.camera != revealed(far), "on its way: \(h.editor.camera)")
        h.wait(100)
        expectEqual(h.editor.camera, revealed(far))
        expectEqual(h.editor.camera.zoom, 1.2, "no closer than 120%")
        h.editor.goBack()
        expectEqual(h.editor.selectedShapeIDs, [card], "one step back, to the card")
        h.wait(200)
        expectEqual(h.editor.camera, Camera(), "and the camera as it was")
    },
    test("going to what's selected already takes no step and leaves the selection as it is; the camera still goes") {
        let h = try goToHarness()
        let a = h.add(Box(CGRect(x: 100, y: 100, width: 100, height: 100)))
        let b = h.add(Box(far))
        h.editor.selection = a
        h.editor.selection = b
        let revision = h.editor.selectionRevision
        h.editor.goTo([b])
        expectEqual(h.editor.selectionRevision, revision)
        h.wait(200)
        expectEqual(h.editor.camera, revealed(far))
        h.editor.goBack()
        expectEqual(h.editor.selectedShapeIDs, [a], "the step back is the one before")

        h.editor.selectedShapeIDs = [a, b]
        let both = h.editor.selectionRevision
        h.editor.goTo([b, a])
        expectEqual(h.editor.selectedShapeIDs, [a, b], "not even reordered")
        expectEqual(h.editor.selectionRevision, both)
    },
    test("going to a shape that can't be selected leaves the selection as it is and takes no step; the camera still goes") {
        let h = try goToHarness()
        let a = h.add(Box(CGRect(x: 100, y: 100, width: 100, height: 100)))
        let ghost = h.add(Ghost(far))
        h.editor.selection = a
        h.editor.goTo([ghost])
        expectEqual(h.editor.selectedShapeIDs, [a])
        h.wait(200)
        expectEqual(h.editor.camera, revealed(far))
        h.editor.goBack()
        expectEqual(h.editor.selectedShapeIDs, [], "the step back is the one before the box")
    },
    test("going to several shapes selects those that can be, and brings them all into view") {
        let h = try goToHarness()
        let left = CGRect(x: 0, y: 0, width: 100, height: 600), right = CGRect(x: 1900, y: 0, width: 100, height: 100)
        let box = h.add(Box(left))
        let ghost = h.add(Ghost(right))
        h.editor.goTo([ghost, box])
        expectEqual(h.editor.selectedShapeIDs, [box])
        h.wait(200)
        expectEqual(h.editor.camera, revealed(left.union(right)))
        expectClose(h.editor.camera.zoom, 0.45)
    },
    test("the camera stays where the shapes are all in view at 70% or closer, and goes where one is partly out of view, or too small to read") {
        let h = try goToHarness()
        let near = CGRect(x: 100, y: 100, width: 100, height: 100), edge = CGRect(x: 950, y: 100, width: 100, height: 100)
        let a = h.add(Box(near))
        let b = h.add(Box(CGRect(x: 600, y: 400, width: 100, height: 100)))
        let c = h.add(Box(edge))
        h.editor.goTo([a])
        expectEqual(h.editor.selectedShapeIDs, [a])
        expectEqual(h.scheduler.pendingCount, 0, "no motion")
        expectEqual(h.editor.camera, Camera())

        h.editor.camera = Camera(zoom: 0.7)                         // as far out as reads
        h.editor.goTo([b])
        expectEqual(h.editor.selectedShapeIDs, [b])
        expectEqual(h.scheduler.pendingCount, 0)
        expectEqual(h.editor.camera, Camera(zoom: 0.7))

        h.editor.camera = Camera()
        h.editor.goTo([c])                                          // half out of the view
        h.wait(200)
        expectEqual(h.editor.camera, revealed(edge))

        h.editor.camera = Camera(zoom: 0.6)                         // in view, but further out than reads
        h.editor.goTo([a])
        h.wait(200)
        expectEqual(h.editor.camera, revealed(near))
    },
    test("a kind that reads closer than 70% (its readable zoom) is brought closer: at 70% it's revealed; with another, the closest of theirs counts") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), Contributor(id: "small-print") { $0.readableZoom(Disc.self, 1) }])
        h.editor.viewportDidResize(to: view)
        let spot = CGRect(x: 100, y: 100, width: 100, height: 100)
        let disc = h.add(Disc(spot))
        let box = h.add(Box(CGRect(x: 300, y: 100, width: 100, height: 100)))
        expectEqual(h.editor.readableZoom(of: try require(h.editor.document[disc])), 1)
        expectEqual(h.editor.readableZoom(of: try require(h.editor.document[box])), 0.7, "a kind that says nothing")
        h.editor.camera = Camera(zoom: 0.7)
        h.editor.goTo([box])
        expectEqual(h.scheduler.pendingCount, 0, "a box reads at 70%")
        h.editor.goTo([disc])
        h.wait(200)
        expectEqual(h.editor.camera, revealed(spot), "a disc doesn't: brought to 120%")
        h.editor.camera = Camera(zoom: 0.9)
        h.editor.goTo([box, disc])
        h.wait(200)
        expectEqual(h.editor.camera.zoom, revealed(spot.union(CGRect(x: 300, y: 100, width: 100, height: 100))).zoom, "the disc's counts")
        h.editor.camera = Camera(zoom: 1)
        h.editor.goTo([disc])
        expectEqual(h.scheduler.pendingCount, 0, "at 100% it reads")
        expectThrows(RegistryError.invalid(point: "ReadableZoom", reason: "small-print says disc reads at 0.0, which isn't a zoom")) {
            _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), Contributor(id: "small-print") { $0.readableZoom(Disc.self, 0) }])
        }
        expectThrows(RegistryError.invalid(point: "ReadableZoom", reason: "small-print says disc reads at 1.5, closer than going to a shape brings it (1.2)")) {
            _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), Contributor(id: "small-print") { $0.readableZoom(Disc.self, 1.5) }])
        }
        _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), Contributor(id: "small-print") { $0.readableZoom(Disc.self, 1.2) }])
    },
    test("a shape too big to read whole stays as it's shown when all of it is in view as close as fitting it would bring it") {
        let h = try goToHarness()
        let big = CGRect(x: 0, y: 0, width: 3000, height: 1500)     // fitted: 900 / 3000 across, 30%
        let id = h.add(Box(big))
        let shown = Camera(origin: CGPoint(x: -50, y: -50), zoom: 0.32)
        h.editor.camera = shown                                     // 3125 × 2187.5 from (-50, -50): all of it
        h.editor.goTo([id])
        expectEqual(h.scheduler.pendingCount, 0, "not out to 30% to show what's shown")
        expectEqual(h.editor.camera, shown)

        h.editor.camera = Camera(origin: CGPoint(x: -50, y: -50), zoom: 0.25)
        h.editor.goTo([id])
        h.wait(200)
        expectEqual(h.editor.camera, revealed(big))
        expectClose(h.editor.camera.zoom, 0.3)
    },
    test("the camera is judged where it's headed: a shape in view now but not where the camera is gliding to is brought into view") {
        let h = try goToHarness()
        let frame = CGRect(x: 100, y: 100, width: 100, height: 100)
        let id = h.add(Box(frame))
        h.editor.animateCamera(to: Camera(origin: CGPoint(x: 5000, y: 5000), zoom: 1), duration: .milliseconds(200))
        h.wait(16)
        expect(h.editor.camera.toWorld(CGRect(origin: .zero, size: view)).contains(frame), "still in view, for now")
        h.editor.goTo([id])
        h.wait(300)
        expectEqual(h.editor.camera, revealed(frame))
    },
    test("mid-gesture, or with none of the shapes on the board, going to them does nothing") {
        let h = try goToHarness()
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let card = h.add(Card(CGRect(x: 300, y: 0, width: 100, height: 60)))
        let b = h.add(Box(far))
        h.editor.selection = card
        h.editor.beginEditing(card)
        h.editor.goTo([ShapeID()])
        expectEqual(h.editor.editingShapeID, card, "editing goes on")
        expectEqual(h.editor.selectedShapeIDs, [card])

        h.editor.endEditing()
        h.press(at: CGPoint(x: 50, y: 50))
        h.drag(to: CGPoint(x: 80, y: 60))                           // moving the box
        h.editor.goTo([b])
        expectEqual(h.editor.selectedShapeIDs, [a], "not while it moves")
        h.release()
        h.wait(200)
        expectEqual(h.editor.camera, Camera())
    },
    test("a face's click runs once its press is over, so it can go to a shape: that's selected and brought into view, a step back from the face's shape") {
        // Faces (FaceTests' `face(of:)`) that go to the shape `log.names` names when clicked, as a link would.
        let log = FaceLog()
        let links = Contributor(id: "links") { r in
            r.shapeFaces(at: { _, shape, point in shape.box.map(face(of:))?.contains(point) == true ? shape.id : nil },
                         click: { _, editor in
                             if let target = log.names { editor.goTo([target]) }
                         })
        }
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), links])
        h.editor.viewportDidResize(to: view)
        let box = h.add(Box(CGRect(x: 100, y: 100, width: 200, height: 100)))     // its face: 110 to 130, 110 to 130
        let target = h.add(Box(far))
        log.names = target
        h.click(at: CGPoint(x: 120, y: 120))
        expectEqual(h.editor.selectedShapeIDs, [target])
        h.wait(200)
        expectEqual(h.editor.camera, revealed(far))
        h.editor.goBack()
        expectEqual(h.editor.selectedShapeIDs, [box], "back to the face's shape, which the press selected")
        h.editor.goBack()
        expectEqual(h.editor.selectedShapeIDs, [], "and to what was selected before the press")
    },
    test("the rest of a double-click whose first click went to a shape is that click's: the camera goes on to the shape, and nothing is placed, edited or pressed where it's brought") {
        let log = FaceLog()
        let links = Contributor(id: "links") { r in
            r.shapeFaces(at: { _, shape, point in shape.box.map(face(of:))?.contains(point) == true ? shape.id : nil },
                         click: { id, editor in
                             log.clicks.append(id)
                             if let target = log.names { editor.goTo([target]) }
                         },
                         doubleClick: { id, _ in log.doubleClicks.append(id) })
        }
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), doubleClickCards(), links])
        h.editor.viewportDidResize(to: view)
        let box = h.add(Box(CGRect(x: 100, y: 100, width: 200, height: 100)))     // its face: 110 to 130, 110 to 130
        let target = h.add(Box(far))
        log.names = target
        h.click(at: CGPoint(x: 120, y: 120))
        h.wait(120)
        expect(h.editor.camera != Camera() && h.editor.camera != revealed(far), "gliding: \(h.editor.camera)")
        h.press(at: CGPoint(x: 120, y: 120), clickCount: 2)          // over empty canvas, where the camera has got to
        h.drag(to: CGPoint(x: 300, y: 300))
        h.release()
        expectEqual(h.editor.document.shapes.count, 2, "no card placed by the double-click")
        expectEqual(h.editor.editingShapeID, nil)
        expectEqual(h.editor.selectedShapeIDs, [target], "no marquee from its drag")
        h.wait(200)
        expectEqual(h.editor.camera, revealed(far), "the camera went on to the shape")
        h.press(at: CGPoint(x: 500, y: 350), clickCount: 3)          // on the shape, a third press of the same clicks
        h.drag(to: CGPoint(x: 600, y: 350))
        h.release()
        expectEqual(h.editor.document[target]?.box, far, "not moved")
        expectEqual(log.clicks, [box])
        expectEqual(log.doubleClicks, [])
        h.click(at: CGPoint(x: 500, y: 100))
        h.click(at: CGPoint(x: 500, y: 100), clickCount: 2)
        expectEqual(h.editor.document.shapes.count, 3, "a new click's double-click is as ever: a card")
        expect(h.editor.editingShapeID != nil)

        h.editor.endEditing()
        h.editor.camera = Camera()
        log.names = box                                               // a face that goes to its own shape: nowhere
        h.click(at: CGPoint(x: 120, y: 120))
        h.press(at: CGPoint(x: 120, y: 120), clickCount: 2)
        h.release()
        expectEqual(log.clicks, [box, box])
        expectEqual(log.doubleClicks, [box], "a click that went nowhere leaves its double-click to the face")
    },
    test("without the Selection plugin, going to a shape ends editing and brings it into view") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), CardsPlugin()])
        h.editor.viewportDidResize(to: view)
        let card = h.add(Card(CGRect(x: 100, y: 100, width: 100, height: 60)))
        let box = h.add(Box(far))
        h.editor.beginEditing(card)
        h.editor.goTo([box])
        expectEqual(h.editor.editingShapeID, nil)
        expectEqual(h.editor.selectedShapeIDs, [])
        h.wait(200)
        expectEqual(h.editor.camera, revealed(far))
    },
    test("revealing shapes, as the table of contents does, only moves the camera; before the view has a size, or for shapes not on the board, it does nothing") {
        let h = try goToHarness()
        let a = h.add(Box(CGRect(x: 100, y: 100, width: 100, height: 100)))
        h.editor.selection = a
        h.editor.reveal([h.add(Box(far))])
        h.wait(200)
        expectEqual(h.editor.camera, revealed(far))
        expectEqual(h.editor.selectedShapeIDs, [a])
        h.editor.reveal([ShapeID()])
        expectEqual(h.scheduler.pendingCount, 0)

        let unsized = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin()])
        unsized.editor.reveal([unsized.add(Box(far))])
        expectEqual(unsized.scheduler.pendingCount, 0)
        expectEqual(unsized.editor.camera, Camera())
    },
    test("revealing shapes, and going to them, leave clear what the host covers of the view's top (the path over a subboard's canvas)") {
        let h = try goToHarness()
        h.editor.coveredTop = { _ in 35 }
        let box = h.add(Box(far))
        let clear = Camera(fitting: far, in: CGRect(x: 0, y: 35, width: 1000, height: 665), inset: 100, maxZoom: 1.2)
        h.editor.reveal([box])
        h.wait(200)
        expectEqual(h.editor.camera, clear)
        h.editor.camera = Camera(origin: CGPoint(x: far.minX - 100, y: far.minY - 20))
        h.editor.goTo([box])
        h.wait(200)
        expectEqual(h.editor.camera, clear, "its top under the covered top: not in view, so it's brought there")
    },
    test("⇧2 and Zoom to Selection bring what's selected into view, as revealing it does; with nothing selected, or no view, the key passes") {
        let h = try goToHarness()
        let a = h.add(Box(far)), b = h.add(Box(CGRect(x: 100, y: 100, width: 100, height: 100)))
        h.hold(.shift)
        expect(!h.editor.keyDown(KeyStroke("@", modifiers: .shift, numberRowKey: "2")), "nothing selected")
        h.editor.selectedShapeIDs = [a, b]
        expect(h.editor.keyDown(KeyStroke("@", modifiers: .shift, numberRowKey: "2")))
        h.wait(200)
        expectEqual(h.editor.camera, revealed(CGRect(x: 100, y: 100, width: 3000, height: 2000)))
        expectEqual(h.editor.selectedShapeIDs, [a, b])
        let unsized = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin()])
        unsized.editor.selection = unsized.add(Box(far))
        expect(!unsized.editor.canPerform(.zoomToSelection))
    },
    test("a smart zoom brings the shape under the pointer into view; the next goes back, unless the camera has moved since; nothing under it, nothing") {
        let h = try goToHarness()
        let box = CGRect(x: 100, y: 100, width: 100, height: 100)
        h.add(Box(box))
        let start = Camera(origin: CGPoint(x: -200, y: -100), zoom: 0.5)
        h.editor.camera = start
        h.move(to: h.view(CGPoint(x: 150, y: 150)))
        expect(h.editor.perform(.smartMagnify))
        h.wait(200)
        expectEqual(h.editor.camera, revealed(box))
        h.editor.perform(.smartMagnify)
        h.wait(200)
        expectEqual(h.editor.camera, start, "again: back where it was")
        h.editor.perform(.smartMagnify)
        h.wait(200)
        h.editor.camera.pan(by: CGSize(width: 5, height: 0))
        let moved = h.editor.camera
        h.move(to: CGPoint(x: 1, y: 1))
        h.editor.perform(.smartMagnify)
        h.wait(200)
        expectEqual(h.editor.camera, moved, "moved since, and nothing under the pointer: nothing")
    },
    test("a smart zoom where no move reached the canvas (a window that isn't key) goes by where the gesture was, hovering nothing") {
        let h = try goToHarness()
        let box = CGRect(x: 100, y: 100, width: 100, height: 100)
        h.add(Box(box))
        let start = Camera(origin: CGPoint(x: -200, y: -100), zoom: 0.5)
        h.editor.camera = start
        h.move(to: CGPoint(x: 900, y: 600))
        h.move(to: CGPoint(x: 950, y: 650))
        let over = h.editor.pointerOverCanvas
        expect(h.editor.pointerSpeed > 0)
        h.editor.pointerLocated(at: h.view(CGPoint(x: 150, y: 150)))
        expectEqual(h.editor.pointerWorldLocation, CGPoint(x: 150, y: 150))
        expectEqual(h.editor.pointerSpeed, 0, "the jump is no motion")
        expectEqual(h.editor.hovered, nil, "nor a hover")
        expectEqual(h.editor.pointerOverCanvas, over, "the tool heard nothing")
        expect(h.editor.perform(.smartMagnify))
        h.wait(200)
        expectEqual(h.editor.camera, revealed(box))
    },
])

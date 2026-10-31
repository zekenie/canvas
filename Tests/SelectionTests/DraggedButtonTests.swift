@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Keyboard
import Selection
import TestKit

// Canvas buttons that are dragged (`canvasButtons(at:drag:)`, as a port's dot is): a plugin's lever,
// a 20-point square at (40, 40) in view points, over a box's middle where there's one, whose drag
// starts a session that records what it hears.

/// What a plugin's levers saw: each drag it was asked to start, and what the session it started heard.
@MainActor final class Pulls {
    /// Each drag the plugin was asked to start.
    var started: [Pull] = []
    /// Whether the plugin starts a session for a drag: false, and it returns nil.
    var starts = true
    /// The cursor the session asks for (nil: the tool's).
    var cursor: CanvasCursor?
    /// What the session does with each drag it gets, besides recording it (select, say).
    var onDrag: @MainActor (Pointer, CanvasEditor) -> Void = { _, _ in }
    /// Each drag the session got, in view points and in world units.
    var drags: [CGPoint] = []
    var worldDrags: [CGPoint] = []
    /// Where it was let go, in view points.
    var ends: [CGPoint] = []
    var cancels = 0
}

/// A drag the plugin was asked to start: the button pressed, as the plugin knows it, and where it
/// was pressed (world units).
struct Pull: Equatable {
    let button: AnyHashable
    let origin: CGPoint
    init(_ button: AnyHashable, at origin: CGPoint) {
        self.button = button
        self.origin = origin
    }
}

/// What a lever's drag starts: it records what it hears.
final class PullSession {
    let pulls: Pulls
    init(_ pulls: Pulls) { self.pulls = pulls }
}

extension PullSession: Session {
    func cursor(in editor: CanvasEditor) -> CanvasCursor? { pulls.cursor }

    func drag(_ pointer: Pointer, in editor: CanvasEditor) {
        pulls.drags.append(pointer.view)
        pulls.worldDrags.append(pointer.world)
        pulls.onDrag(pointer, editor)
    }

    func end(_ pointer: Pointer, in editor: CanvasEditor) { pulls.ends.append(pointer.view) }

    func cancel(in editor: CanvasEditor) -> Bool {
        pulls.cancels += 1
        return true
    }
}

/// A plugin whose buttons, found by `find` (view points), are dragged: a drag from one starts a
/// `PullSession`, unless `pulls.starts` is false.
@MainActor func leversPlugin<Button: Hashable & Sendable>(_ pulls: Pulls, id: PluginID,
                                                          at find: @escaping @MainActor (CGPoint) -> Button?) -> Contributor {
    Contributor(id: id) { r in
        r.canvasButtons(at: { _, point in find(point) }, drag: { button, origin, _ in
            pulls.started.append(Pull(button, at: origin))
            return pulls.starts ? PullSession(pulls) : nil
        })
    }
}

/// A plugin with one lever named `name`, in `rect` (view points).
@MainActor func leverPlugin(_ pulls: Pulls, _ name: String = "lever", at rect: CGRect = CGRect(x: 40, y: 40, width: 20, height: 20)) -> Contributor {
    leversPlugin(pulls, id: PluginID(name)) { rect.contains($0) ? name : nil }
}

/// A button a plugin knows by its own type: one of a row of notches.
struct Notch: Hashable, Sendable {
    let index: Int
}

@MainActor let draggedButtonTests = Suite("Dragged canvas buttons", [
    test("the open hand shows over a button that's dragged, the pointing hand still over one that's clicked, and the closed hand while one's pressed") {
        let bell = Bell(), pulls = Pulls()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(),
                                            bellPlugin(bell, at: CGRect(x: 100, y: 40, width: 20, height: 20)), leverPlugin(pulls)])
        h.move(to: CGPoint(x: 50, y: 50))
        expectEqual(h.editor.cursor, .openHand)
        h.move(to: CGPoint(x: 110, y: 50))
        expectEqual(h.editor.cursor, .pointingHand, "the bell")
        h.move(to: CGPoint(x: 50, y: 50))
        expectEqual(h.editor.cursor, .openHand)
        h.press(at: CGPoint(x: 50, y: 50))
        expectEqual(h.editor.cursor, .closedHand)
        h.drag(to: CGPoint(x: 52, y: 51))
        expectEqual(h.editor.cursor, .closedHand, "still pressed, short of a drag")
        h.release()
        expectEqual(h.editor.cursor, .openHand, "let go, and still over it")
        h.move(to: CGPoint(x: 80, y: 80))
        expectEqual(h.editor.cursor, .standard)
    },
    test("a dragged button is hovered under the pointer, not the shape under it, and pressed from the press until the drag starts, as the pointer wavers off it") {
        let pulls = Pulls()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), leverPlugin(pulls)])
        h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        h.move(to: CGPoint(x: 42, y: 50))
        expectEqual(h.editor.hoveredButton, AnyHashable("lever"))
        expectEqual(h.editor.hovered, nil, "not the shape under it")
        expectEqual(h.editor.pressedButton, nil)
        h.press(at: CGPoint(x: 42, y: 50))
        expectEqual(h.editor.pressedButton, AnyHashable("lever"))
        expectEqual(h.editor.hoveredButton, AnyHashable("lever"))
        h.drag(to: CGPoint(x: 39, y: 50))                          // just off its edge, short of a drag
        expectEqual(h.editor.pressedButton, AnyHashable("lever"), "the drag, when it comes, is from it")
        h.release()
        expectEqual(h.editor.pressedButton, nil)
        expectEqual(pulls.started, [])
    },
    test("a drag of 4 view points or less does nothing, at any zoom; past them, the plugin's drag starts") {
        let pulls = Pulls()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), leverPlugin(pulls)])
        h.editor.camera = Camera(origin: .zero, zoom: 0.5)          // 3 view points are 6 world units
        h.press(at: CGPoint(x: 50, y: 50))
        h.drag(to: CGPoint(x: 53, y: 50))
        h.drag(to: CGPoint(x: 50, y: 54))                           // 4 exactly: not past them
        expectEqual(pulls.started, [])
        expectEqual(pulls.drags, [])
        expectEqual(h.editor.pressedButton, AnyHashable("lever"))
        h.release()
        expectEqual(pulls.started, [], "nor after a release")

        h.editor.camera = Camera(origin: .zero, zoom: 2)            // 5 view points are 2.5 world units
        h.press(at: CGPoint(x: 50, y: 50))
        h.drag(to: CGPoint(x: 55, y: 50))
        expectEqual(pulls.started.count, 1)
        expectEqual(pulls.drags, [CGPoint(x: 55, y: 50)])
        h.release()
    },
    test("past the threshold, the plugin's drag gets the button and where it was pressed in world units, and its session gets that drag at once, then the rest") {
        let pulls = Pulls()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), leverPlugin(pulls)])
        h.editor.camera = Camera(origin: CGPoint(x: 100, y: -40), zoom: 2)
        h.press(at: CGPoint(x: 50, y: 50))                          // world (125, -15)
        h.drag(to: CGPoint(x: 52, y: 51))
        h.drag(to: CGPoint(x: 60, y: 50))
        expectEqual(pulls.started, [Pull("lever", at: CGPoint(x: 125, y: -15))], "from the press, not where the drag passed the threshold")
        expect(h.editor.session is PullSession)
        expectEqual(pulls.drags, [CGPoint(x: 60, y: 50)], "the drag that started it")
        expectEqual(pulls.worldDrags, [CGPoint(x: 130, y: -15)])
        h.drag(to: CGPoint(x: 90, y: 70))
        expectEqual(pulls.drags, [CGPoint(x: 60, y: 50), CGPoint(x: 90, y: 70)])
        expectEqual(pulls.started.count, 1, "started once")
        h.release()
        expectEqual(pulls.ends, [CGPoint(x: 90, y: 70)])
        expect(h.editor.session == nil)
    },
    test("the plugin's drag gets its own value for the button, the one pressed of several") {
        let pulls = Pulls()
        let notches = [CGRect(x: 40, y: 40, width: 20, height: 20), CGRect(x: 80, y: 40, width: 20, height: 20)]
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(),
                                            leversPlugin(pulls, id: "notches") { point in notches.firstIndex { $0.contains(point) }.map(Notch.init) }])
        h.move(to: CGPoint(x: 90, y: 50))
        expectEqual(h.editor.hoveredButton, AnyHashable(Notch(index: 1)))
        h.press(at: CGPoint(x: 90, y: 50))
        expectEqual(h.editor.pressedButton, AnyHashable(Notch(index: 1)))
        h.drag(to: CGPoint(x: 90, y: 80))
        expectEqual(pulls.started, [Pull(Notch(index: 1), at: CGPoint(x: 90, y: 50))])
        h.release()
    },
    test("at the hand-over the button is neither hovered nor pressed, though the pointer's still on it, and the cursor is the session's") {
        let pulls = Pulls()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), leverPlugin(pulls)])
        h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        h.move(to: CGPoint(x: 45, y: 50))
        h.press(at: CGPoint(x: 45, y: 50))
        h.drag(to: CGPoint(x: 55, y: 50))                          // past the threshold, still on the lever
        expectEqual(pulls.started.count, 1)
        expectEqual(h.editor.pressedButton, nil)
        expectEqual(h.editor.hoveredButton, nil)
        expectEqual(h.editor.hovered, nil)
        expectEqual(h.editor.cursor, .standard, "the session names none, and the open hand went with the hover")
        pulls.cursor = .crosshair
        expectEqual(h.editor.cursor, .crosshair)
        h.drag(to: CGPoint(x: 150, y: 150))
        h.drag(to: CGPoint(x: 50, y: 50))
        expectEqual(h.editor.hoveredButton, nil, "not hovered while the session runs")
        h.release()
        expectEqual(h.editor.hoveredButton, AnyHashable("lever"), "let go on it, it's hovered again")
        expectEqual(h.editor.cursor, .openHand)
    },
    test("Escape once the drag's handed over is the session's") {
        let pulls = Pulls()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), leverPlugin(pulls)])
        h.press(at: CGPoint(x: 50, y: 50))
        h.drag(to: CGPoint(x: 70, y: 50))
        h.escape()
        expectEqual(pulls.cancels, 1)
        expect(h.editor.session == nil)
        h.drag(to: CGPoint(x: 90, y: 50))
        h.release()
        expectEqual(pulls.drags, [CGPoint(x: 70, y: 50)], "nothing after it")
        expectEqual(pulls.ends, [])
        expectEqual(pulls.started.count, 1)
    },
    test("a plugin that starts nothing for the drag ends the press: the rest of the drag and the release do nothing") {
        let pulls = Pulls()
        pulls.starts = false
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), leverPlugin(pulls)])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        h.press(at: CGPoint(x: 50, y: 50))
        h.drag(to: CGPoint(x: 60, y: 50))
        expectEqual(pulls.started, [Pull("lever", at: CGPoint(x: 50, y: 50))])
        expect(h.editor.session == nil)
        expectEqual(h.editor.pressedButton, nil)
        h.drag(to: CGPoint(x: 200, y: 200))
        h.drag(to: CGPoint(x: 80, y: 80))                           // over the box
        expectEqual(pulls.started.count, 1, "asked once")
        expectEqual(h.editor.brush, nil, "no marquee")
        h.release()
        expectEqual(h.editor.selectedShapeIDs, [])
        expectEqual(h.editor.document[box]?.box?.origin, .zero)
        expect(h.editor.session == nil)
    },
    test("a press released without a drag does nothing: the plugin isn't asked, and the selection stays") {
        let pulls = Pulls()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), leverPlugin(pulls)])
        h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))      // under the lever
        let other = h.add(Box(CGRect(x: 200, y: 0, width: 100, height: 100)))
        h.click(at: CGPoint(x: 50, y: 50))
        expectEqual(h.editor.selectedShapeIDs, [])
        h.editor.selection = other
        h.click(at: CGPoint(x: 50, y: 50))
        h.click(at: CGPoint(x: 50, y: 50), clickCount: 2)
        expectEqual(pulls.started, [])
        expectEqual(pulls.drags, [])
        expectEqual(h.editor.selection, other)
        expectEqual(h.editor.editingShapeID, nil)
    },
    test("Escape while a dragged button is pressed lets go of it: the drag that follows starts nothing") {
        let pulls = Pulls()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), leverPlugin(pulls)])
        let box = h.add(Box(CGRect(x: 200, y: 0, width: 100, height: 100)))
        h.editor.selection = box
        h.move(to: CGPoint(x: 50, y: 50))
        h.press(at: CGPoint(x: 50, y: 50))
        h.escape()
        expectEqual(h.editor.pressedButton, nil)
        expect(h.editor.session == nil)
        expectEqual(h.editor.cursor, .openHand, "let go of, the pointer still over it")
        expectEqual(h.editor.selection, box, "Escape went to the press, not the select tool")
        h.drag(to: CGPoint(x: 80, y: 80))
        expectEqual(h.editor.brush, nil)
        h.release()
        expectEqual(pulls.started, [])
        expectEqual(h.editor.selection, box)
    },
    test("a dragged button wins over the shape under it, even a lone selected box, which doesn't follow the press") {
        let pulls = Pulls()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), leverPlugin(pulls)])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        h.editor.selection = box
        h.move(to: CGPoint(x: 50, y: 50))
        expectEqual(h.editor.hoveredButton, AnyHashable("lever"))
        expectEqual(h.editor.hovered, nil)
        expectEqual(h.editor.cursor, .openHand)
        h.press(at: CGPoint(x: 50, y: 50))
        h.drag(to: CGPoint(x: 51, y: 51))
        expectEqual(h.editor.document[box]?.box?.origin, .zero, "not before the threshold")
        h.drag(to: CGPoint(x: 80, y: 80))
        expectEqual(pulls.started.count, 1)
        expect(h.editor.session is PullSession)
        expectEqual(h.editor.document[box]?.box?.origin, .zero)
        h.release()
        expectEqual(h.editor.document[box]?.box?.origin, .zero)
        expectEqual(h.editor.selection, box)
    },
    test("a dragged button wins over empty space in the box around several selected shapes") {
        let pulls = Pulls()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), leverPlugin(pulls)])
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 30, height: 30)))
        let b = h.add(Box(CGRect(x: 70, y: 70, width: 30, height: 30)))
        h.editor.selectedShapeIDs = [a, b]                          // their box spans the lever
        h.press(at: CGPoint(x: 50, y: 50))
        h.drag(to: CGPoint(x: 80, y: 60))
        h.release()
        expectEqual(pulls.started.count, 1)
        expectEqual(h.editor.document[a]?.box?.origin, .zero)
        expectEqual(h.editor.document[b]?.box?.origin, CGPoint(x: 70, y: 70))
        expectEqual(h.editor.selectedShapeIDs, [a, b])
    },
    test("a dragged button wins over the only selected shape's handle") {
        let pulls = Pulls()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), KnobsPlugin(), leverPlugin(pulls)])
        let knob = h.add(Knob(CGRect(x: 0, y: 0, width: 100, height: 100)))   // its handle is at (50, 50)
        h.editor.selection = knob
        expect(h.editor.handle(atViewPoint: CGPoint(x: 50, y: 50)) != nil)
        h.move(to: CGPoint(x: 50, y: 50))
        expectEqual(h.editor.hoveredButton, AnyHashable("lever"))
        expectEqual(h.editor.hoveredHandle, nil)
        h.press(at: CGPoint(x: 50, y: 50))
        h.drag(to: CGPoint(x: 80, y: 50))
        expectEqual(pulls.started.count, 1)
        expect(h.editor.session is PullSession, "not the handle's")
        h.release()
        expectEqual(h.editor.selection, knob)
    },
    test("where a dragged and a clicked button overlap, the later plugin's is pressed, whichever it is") {
        let bell = Bell(), pulls = Pulls()
        let bellFirst = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), bellPlugin(bell),
                                                    leverPlugin(pulls, at: CGRect(x: 50, y: 50, width: 20, height: 20))])
        bellFirst.move(to: CGPoint(x: 55, y: 55))
        expectEqual(bellFirst.editor.cursor, .openHand)
        bellFirst.click(at: CGPoint(x: 55, y: 55))
        expectEqual(bell.rings, [], "a click on the lever does nothing")
        bellFirst.press(at: CGPoint(x: 55, y: 55))
        bellFirst.drag(to: CGPoint(x: 90, y: 90))
        bellFirst.release()
        expectEqual(pulls.started.count, 1)
        bellFirst.click(at: CGPoint(x: 45, y: 45))
        expectEqual(bell.rings, ["bell"], "beside the lever, the bell")

        let leverFirst = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(),
                                                     leverPlugin(pulls, at: CGRect(x: 50, y: 50, width: 20, height: 20)), bellPlugin(bell)])
        leverFirst.move(to: CGPoint(x: 55, y: 55))
        expectEqual(leverFirst.editor.cursor, .pointingHand)
        leverFirst.press(at: CGPoint(x: 55, y: 55))
        leverFirst.drag(to: CGPoint(x: 90, y: 90))
        leverFirst.release()
        expectEqual(pulls.started.count, 1, "the bell's press: dragged off, nothing")
        leverFirst.click(at: CGPoint(x: 55, y: 55))
        expectEqual(bell.rings, ["bell", "bell"])
    },
    test("in other tools a dragged button is only drawn: a drag from it is the tool's") {
        let pulls = Pulls()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), leverPlugin(pulls)])
        h.editor.setTool(.hand)
        h.move(to: CGPoint(x: 50, y: 50))
        expectEqual(h.editor.hoveredButton, nil)
        h.press(at: CGPoint(x: 50, y: 50))
        expectEqual(h.editor.pressedButton, nil)
        h.drag(to: CGPoint(x: 80, y: 70))
        expectEqual(h.editor.camera.origin, CGPoint(x: -30, y: -20), "the hand pans")
        h.release()
        expectEqual(pulls.started, [])
    },
    test("a press on a dragged button is no step back, unless its session selects what's out of view, and then it's one step, however many changes") {
        let pulls = Pulls()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), leverPlugin(pulls)])
        h.editor.viewportDidResize(to: CGSize(width: 1000, height: 700))
        let a = h.add(Box(CGRect(x: 200, y: 0, width: 100, height: 100)))
        let b = h.add(Box(CGRect(x: 4000, y: 0, width: 100, height: 100)))      // out of view
        h.press(at: CGPoint(x: 50, y: 50))
        h.drag(to: CGPoint(x: 80, y: 50))
        h.release()
        h.click(at: CGPoint(x: 50, y: 50))
        expect(!h.editor.canGoBack, "a drag and a click that select nothing")

        pulls.onDrag = { pointer, editor in editor.selection = pointer.view.x < 100 ? a : b }
        h.press(at: CGPoint(x: 50, y: 50))
        h.drag(to: CGPoint(x: 60, y: 50))
        expectEqual(h.editor.selectedShapeIDs, [a])
        h.drag(to: CGPoint(x: 120, y: 50))
        h.release()
        expectEqual(h.editor.selectedShapeIDs, [b])
        expect(h.editor.canGoBack, "b was out of view")
        h.editor.goBack()
        expectEqual(h.editor.selectedShapeIDs, [], "the drag's two changes were one step, back to what the press found")
        expect(!h.editor.canGoBack)
    },
])

@MainActor let pointerOverCanvasTests = Suite("The pointer over the canvas", [
    test("it's where the pointer last moved in the select tool, over shapes and buttons alike, and nil once the pointer leaves") {
        let pulls = Pulls()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), leverPlugin(pulls)])
        h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        expectEqual(h.editor.pointerOverCanvas, nil, "not seen yet")
        h.move(to: CGPoint(x: 200, y: 20))
        expectEqual(h.editor.pointerOverCanvas, CGPoint(x: 200, y: 20))
        h.move(to: CGPoint(x: 80, y: 80))                            // over the box
        expectEqual(h.editor.pointerOverCanvas, CGPoint(x: 80, y: 80))
        h.move(to: CGPoint(x: 50, y: 50))                            // over the lever
        expectEqual(h.editor.pointerOverCanvas, CGPoint(x: 50, y: 50))
        h.editor.pointerExited()
        expectEqual(h.editor.pointerOverCanvas, nil)
        h.move(to: CGPoint(x: 10, y: 10))
        expectEqual(h.editor.pointerOverCanvas, CGPoint(x: 10, y: 10), "back over it")
    },
    test("leaving the canvas and coming back redraw it, for what's drawn only while the pointer's over it (a port's dots), though nothing's hovered") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin()])
        let host = DisplayCounter()
        h.editor.delegate = host
        h.move(to: CGPoint(x: 200, y: 200))                          // empty canvas
        let redraws = host.redraws
        h.editor.pointerExited()
        expect(host.redraws > redraws, "the pointer left")
        let left = host.redraws
        h.move(to: CGPoint(x: 210, y: 200))
        expect(host.redraws > left, "the pointer's back")
    },
    test("it's nil once another tool is current, and stays nil there however the pointer moves") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin()])
        h.move(to: CGPoint(x: 10, y: 20))
        h.editor.setTool(.hand)
        expectEqual(h.editor.pointerOverCanvas, nil)
        h.move(to: CGPoint(x: 30, y: 40))
        h.click(at: CGPoint(x: 30, y: 40))
        expectEqual(h.editor.pointerOverCanvas, nil)
        h.escape()                                                   // back to the select tool
        expectEqual(h.editor.currentToolID, .select)
        h.move(to: CGPoint(x: 50, y: 60))
        expectEqual(h.editor.pointerOverCanvas, CGPoint(x: 50, y: 60))
    },
    test("while a session runs it stays where the pointer last moved, whatever the pointer does, and the release sets it again") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin()])
        h.move(to: CGPoint(x: 200, y: 200))
        h.press(at: CGPoint(x: 200, y: 200))                         // empty canvas: a marquee
        h.drag(to: CGPoint(x: 300, y: 260))
        expectEqual(h.editor.pointerOverCanvas, CGPoint(x: 200, y: 200))
        h.move(to: CGPoint(x: 310, y: 270))                          // a move mid-drag goes to no tool
        h.editor.pointerExited()                                     // nor does leaving
        expectEqual(h.editor.pointerOverCanvas, CGPoint(x: 200, y: 200))
        h.release()
        expectEqual(h.editor.pointerOverCanvas, CGPoint(x: 310, y: 270), "where it was let go")
    },
    test("while a dragged button's session runs it stays where the pointer was when it pressed, and the release sets it again") {
        let pulls = Pulls()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), leverPlugin(pulls)])
        h.move(to: CGPoint(x: 50, y: 50))
        h.press(at: CGPoint(x: 50, y: 50))
        h.drag(to: CGPoint(x: 90, y: 60))
        expect(h.editor.session is PullSession)
        h.drag(to: CGPoint(x: 120, y: 90))
        expectEqual(h.editor.pointerOverCanvas, CGPoint(x: 50, y: 50))
        h.release()
        expectEqual(h.editor.pointerOverCanvas, CGPoint(x: 120, y: 90))
    },
    test("placing a shape changes the tool: nil until the placed shape is let go in the select tool") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), discTools()])
        h.move(to: CGPoint(x: 90, y: 90))
        h.editor.setTool(ToolID(placing: Disc.kind))
        h.move(to: CGPoint(x: 100, y: 100))
        h.press(at: CGPoint(x: 100, y: 100))
        expectEqual(h.editor.currentToolID, .select)
        h.drag(to: CGPoint(x: 130, y: 110))
        expectEqual(h.editor.pointerOverCanvas, nil)
        h.release()
        expectEqual(h.editor.pointerOverCanvas, CGPoint(x: 130, y: 110))
    },
])

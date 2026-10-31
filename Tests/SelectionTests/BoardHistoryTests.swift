@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Keyboard
import Selection
import TestKit

// Going back across boards: showing another board is a step back, with its board, and going back
// to a step on another board shows that board first.

/// Keeps whether each switch's change set had been worked out by the time it heard of it.
@MainActor private final class ChangeSetWatch {
    var workedOut: [Bool] = []
}

private final class ChangeSetWatcher {
    let watch: ChangeSetWatch
    init(watch: ChangeSetWatch) { self.watch = watch }
}

extension ChangeSetWatcher: EditorService {
    func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        #if DEBUG
        watch.workedOut.append(change.hasWorkedOutChanges)
        #endif
    }
}

@MainActor let boardHistoryTests = Suite("Going back across boards", [
    test("⌘[ after opening a shape's board goes back to the board left, the shape selected, the camera where it was, at once") {
        let t = PocketBoards()
        let h = try pocketsHarness(t)
        h.click(at: t.pPoint)
        let left = Camera(origin: CGPoint(x: 30, y: 20), zoom: 1.5)
        h.editor.camera = left
        expect(h.editor.perform(.openSelection))
        expectEqual(h.editor.board, t.pBoard)
        expectEqual(h.editor.selectedShapeIDs, [], "nothing selected on arrival")
        h.editor.camera = Camera(origin: CGPoint(x: -300, y: 0), zoom: 0.5)
        h.hold(.command)
        expect(h.key("["))
        h.hold([])
        expectEqual(h.editor.board, .root)
        expectEqual(h.editor.selectedShapeIDs, [t.p])
        expectEqual(h.editor.camera, left, "set, not animated")
        expect(!h.editor.canGoBack, "the click on the root, in view, was no step of its own")
    },
    test("a file put in place on another board (opened on the board left open) is no step back") {
        let t = PocketBoards()
        let h = try pocketsHarness(t)
        h.editor.replaceFile(with: h.editor.file, showing: t.pBoard)
        expectEqual(h.editor.board, t.pBoard)
        expect(!h.editor.canGoBack, "no one went there")
        h.enter(t.q)
        expect(h.editor.canGoBack, "going on in is")
    },
    test("showing a board with nothing selected is a step too, which Back sees, back to the board left with nothing selected") {
        let t = PocketBoards()
        let h = try pocketsHarness(t)
        expect(!h.editor.canGoBack)
        h.enter(t.p)
        expect(h.editor.canGoBack)
        expect(h.editor.canPerform(.goBack))
        h.editor.goBack()
        expectEqual(h.editor.board, .root)
        expectEqual(h.editor.selectedShapeIDs, [])
        expect(!h.editor.canGoBack, "going back took no step of its own")
    },
    test("a step repeats the one below it only on the same board: nothing selected on two boards is two steps") {
        let t = PocketBoards()
        let h = try pocketsHarness(t)
        h.enter(t.p)                                             // a step: the root, nothing selected
        expect(h.editor.showBoard(.root))                        // and another: P's board, nothing selected
        h.editor.goBack()
        expectEqual(h.editor.board, t.pBoard)
        h.editor.goBack()
        expectEqual(h.editor.board, .root)
        expect(!h.editor.canGoBack)
    },
    test("going back to an older visit of a board sets the camera of that visit, not the one the board was left with last") {
        let t = PocketBoards()
        let h = try pocketsHarness(t)
        let first = Camera(origin: CGPoint(x: 40, y: 10), zoom: 2), second = Camera(origin: CGPoint(x: -90, y: 60), zoom: 0.75)
        h.enter(t.p)
        h.editor.camera = first
        expect(h.editor.showBoard(.root))                        // a step: P's board at the first camera
        h.enter(t.p)
        h.editor.camera = second
        expect(h.editor.showBoard(.root))                        // and another: P's board at the second
        h.editor.goBack()
        expectEqual(h.editor.board, t.pBoard)
        expectEqual(h.editor.camera, second)
        h.editor.goBack()
        expectEqual(h.editor.board, .root)
        h.editor.goBack()
        expectEqual(h.editor.board, t.pBoard)
        expectEqual(h.editor.camera, first, "the older visit's, though P's board was left at the second")
    },
    test("going back skips a step on a board that's gone with its owner") {
        let t = PocketBoards()
        let h = try pocketsHarness(t)
        h.editor.selection = t.a                                 // places: none here, in view;
        h.enter(t.p)                                             // the root with A;
        h.editor.selection = t.b                                 // none here;
        expect(h.editor.showBoard(.root))                        // and P's board with B
        h.editor.transact { $0.delete([t.p]) }
        expect(h.editor.canGoBack)
        h.editor.goBack()
        expectEqual(h.editor.board, .root)
        expectEqual(h.editor.selectedShapeIDs, [t.a], "past P's board's place")
        expect(!h.editor.canGoBack)
    },
    test("showing a board and selecting there is one step: back returns to the board left and what was selected there") {
        let t = PocketBoards()
        let h = try pocketsHarness(t)
        h.editor.selection = t.a
        expect(h.editor.showBoard(t.pBoard, selecting: [t.b]))
        expectEqual(h.editor.board, t.pBoard)
        expectEqual(h.editor.selectedShapeIDs, [t.b])
        expect(h.editor.showBoard(.root, selecting: [t.p]))      // up, the owner selected, as the path goes
        expectEqual(h.editor.selectedShapeIDs, [t.p])
        expect(h.editor.showBoard(.root, selecting: [t.c]), "on the board shown, it only selects")
        expectEqual(h.editor.selectedShapeIDs, [t.c])
        h.editor.goBack()
        expectEqual(h.editor.board, t.pBoard, "selecting C in view was no step: back past it, to P's board")
        expectEqual(h.editor.selectedShapeIDs, [t.b])
        h.editor.goBack()
        expectEqual(h.editor.board, .root)
        expectEqual(h.editor.selectedShapeIDs, [t.a])
        expect(!h.editor.canGoBack)
        expect(!h.editor.showBoard(BoardID(owner: t.a), selecting: [t.a]), "a box owns no board")
        expectEqual(h.editor.board, .root)
    },
    test("a switch lets go of the hover, the hovered handle and canvas button, and where the pointer was, and the selection goes without a step of its own") {
        let bell = Bell()
        let t = PocketBoards()
        let h = try pocketsHarness(t, [KnobsPlugin(), bellPlugin(bell, at: CGRect(x: 600, y: 600, width: 20, height: 20))])
        let knob = h.add(Knob(CGRect(x: 0, y: 200, width: 100, height: 100)))    // its handle is at (50, 250)
        h.move(to: t.aPoint)
        expectEqual(h.editor.hovered, t.a)
        h.enter(t.p)
        expectEqual(h.editor.hovered, nil)
        h.editor.showBoard(.root)

        h.editor.selection = knob
        h.move(to: CGPoint(x: 50, y: 250))
        expect(h.editor.hoveredHandle != nil)
        h.enter(t.p)
        expectEqual(h.editor.hoveredHandle, nil)
        expectEqual(h.editor.selectedShapeIDs, [])
        h.editor.showBoard(.root)

        h.move(to: CGPoint(x: 610, y: 610))
        expectEqual(h.editor.hoveredButton, AnyHashable("bell"))
        h.enter(t.p)
        expectEqual(h.editor.hoveredButton, nil)
        expectEqual(h.editor.pressedButton, nil)
        h.editor.canvasButtonsDidChange()
        expectEqual(h.editor.hoveredButton, nil, "the pointer's place on the board left is forgotten")

        h.editor.goBack()
        expectEqual(h.editor.board, .root)
        expectEqual(h.editor.selectedShapeIDs, [], "the root as it was left the last time")
        h.editor.goBack()
        expectEqual(h.editor.board, t.pBoard)
        h.editor.goBack()
        expectEqual(h.editor.board, .root)
        expectEqual(h.editor.selectedShapeIDs, [knob], "the steps are the boards left and the knob's selection, nothing more")
    },
    test("the selection follows a switch without working out the switch's change set") {
        let watch = ChangeSetWatch()
        let t = PocketBoards()
        // Services hear a switch in plugin order: the watcher, last, hears it after the selection's.
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), CardsPlugin(), PocketsPlugin(), openingPockets(),
                                            Contributor(id: "watch") { r in r.service { _ in ChangeSetWatcher(watch: watch) } }],
                                  file: t.file)
        h.editor.selection = t.p
        h.enter(t.p)
        h.editor.goBack()
        #if DEBUG
        expectEqual(watch.workedOut, [false, false])
        #endif
    },
    test("Select All selects the board shown, no other") {
        let t = PocketBoards()
        let h = try pocketsHarness(t)
        h.enter(t.p)
        h.editor.selectAll()
        expectEqual(h.editor.selectedShapeIDs, [t.b, t.q])
        h.editor.showBoard(.root)
        h.editor.selectAll()
        expectEqual(h.editor.selectedShapeIDs, [t.a, t.p, t.c])
    },
    test("⌘Z on P undoes a Delete made on the root: the root is shown, the shape comes back selected there; ⇧⌘Z from P again deletes it there") {
        let t = PocketBoards()
        let h = try pocketsHarness(t)
        h.click(at: t.aPoint)
        expect(h.key("\u{7f}"))
        expectEqual(h.editor.document[t.a], nil)
        h.click(at: t.pPoint)
        expect(h.editor.perform(.openSelection))
        h.click(at: CGPoint(x: -500, y: -500))
        h.hold(.command)
        expect(h.key("z"))
        expectEqual(h.editor.board, .root)
        expect(h.editor.document[t.a] != nil)
        expectEqual(h.editor.selectedShapeIDs, [t.a], "selected as the step began, on its board")
        h.editor.goBack()
        expectEqual(h.editor.board, t.pBoard, "one Back: P, where ⌘Z was pressed (the switch and the selection are one step)")

        h.hold([.command, .shift])
        expect(h.key("z"))
        h.hold([])
        expectEqual(h.editor.board, .root)
        expectEqual(h.editor.document[t.a], nil)
        expectEqual(h.editor.selectedShapeIDs, [], "as the step left it")
    },
])

import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Frames
import Geometry
import Grouping
import Selection
import ShippedTesting
import StickyNotes
import TestKit
import Titles

// Moving between shapes as the app ships them, walked with the keys a keyboard sends (`KeyWalk`): Tab
// and ⇧Tab through a board's shapes, ⌥⌘ and an arrow to the nearest shape that way, ⌘↓ and ⌘↑ through a
// group, a frame and the boards around them, and the Go item named for the step ⌘↑ would take.

extension NestedWindow {
    /// A walk of this window with the canvas's keyboard: the selection named by `names` (else by
    /// title), and the panel beside it.
    func walk(names: [ShapeID: String] = [:]) -> KeyWalk {
        window.makeFirstResponder(canvas)
        return KeyWalk(window, editor: editor, readers: [.canvas(canvas, editor: editor, names: names), .panel(of: canvas)])
    }

    /// ⌘↑ or ⌘↓ as the keyboard sends it: whether the canvas took it (as its key equivalent).
    @discardableResult func command(up: Bool) -> Bool {
        window.makeFirstResponder(canvas)
        return KeyDriver(window).send(Chord(up ? Key.up : Key.down, .command)).isKeyEquivalent
    }

    /// A frame holding `ids`, on the board shown, the middle of the board.
    func frame(holding ids: [ShapeID]) -> ShapeID {
        var frame = ShapeRecord(Frame(frame: CGRect(x: 20, y: 40, width: 700, height: 300)))
        frame[TitleProperty.self] = "Sprint"
        editor.transact { $0.insert(frame) }
        editor.put(ids, in: frame.id)
        return frame.id
    }
}

@MainActor let steppingShippedTests = Suite("Moving between shapes, shipped", [
    test("Tab and ⇧Tab step through a board's shapes in reading order, round to the first, ⇧Tab undoing each step, every shape shown; an arrow, which has no box, is never one") {
        let w = try NestedWindow()
        defer { w.board.close() }
        expect(w.editor.showBoard(w.nest.sBoard))
        let (first, second) = w.nest.notes(on: 2)
        let walk = w.walk(names: [first: "first", second: "second", w.nest.t: "T"])
        expectEqual(walk.focus.id, "canvas", "nothing selected")
        expectEqual(walk.press(.tab).id, "canvas/first", "with nothing selected, the first")
        let cycle = walk.expectCycle(["canvas/first", "canvas/second", "canvas/T"])
        expectEqual(walk.presses.count, 1 + 3 * 3, "a step, and its way back and forth again, at each stop")
        walk.expectShows(cycle.stops)
    },
    test("⌥⌘ and an arrow key select the nearest shape that way, and add it with ⇧") {
        let w = try NestedWindow()
        defer { w.board.close() }
        expect(w.editor.showBoard(w.nest.sBoard))
        let (first, second) = w.nest.notes(on: 2)
        let walk = w.walk(names: [first: "first", second: "second", w.nest.t: "T"])
        w.editor.selectedShapeIDs = [first]
        expectEqual(walk.press(Chord(Key.right, [.command, .option])).id, "canvas/second")
        expectEqual(walk.press(Chord(Key.down, [.command, .option])).id, "canvas/T", "from the second note, the subboard is south, in the wedge")
        w.editor.selectedShapeIDs = [first]
        expectEqual(walk.press(Chord(Key.right, [.command, .option, .shift])).id, "canvas/first+second")
    },
    test("⌘↑ with a note in a frame selects the frame, then goes up the board; the Go item is named for each step") {
        let w = try NestedWindow()
        defer { w.board.close() }
        let up = try w.goItems().up
        expect(w.editor.showBoard(w.nest.sBoard))
        let (first, second) = w.nest.notes(on: 2)
        let frame = w.frame(holding: [first, second])
        w.editor.selectedShapeIDs = [first]
        expect(w.controller.validateMenuItem(up))
        expectEqual(up.title, "Enclosing Frame")
        expect(w.command(up: true))
        expectEqual(w.editor.selectedShapeIDs, [frame])
        expectEqual(w.editor.board, w.nest.sBoard)
        expect(w.controller.validateMenuItem(up))
        expectEqual(up.title, "Enclosing Board")
        expect(w.command(up: true))
        expectEqual(w.editor.board, .root)
        expectEqual(w.editor.selectedShapeIDs, [w.nest.s], "the subboard left")
        expect(!w.controller.validateMenuItem(up), "nothing above the root, and the subboard is on the board itself")
        expectEqual(up.title, "Enclosing Board")
        expect(!w.command(up: true), "its key passes")
    },
    test("on the root, ⌘↑ is enabled while the selection is in a frame or a group, and then not") {
        let w = try NestedWindow()
        defer { w.board.close() }
        let up = try w.goItems().up
        let (a, b) = w.nest.notes(on: 1)
        let frame = w.frame(holding: [a])
        w.editor.selectedShapeIDs = [a]
        expect(w.controller.validateMenuItem(up))
        expectEqual(up.title, "Enclosing Frame")
        expect(w.command(up: true))
        expectEqual(w.editor.selectedShapeIDs, [frame])
        expect(!w.controller.validateMenuItem(up))
        expect(!w.command(up: true))
        expect(w.editor.group([a, b]))
        w.editor.selectedShapeIDs = [b]
        expectEqual(w.editor.selectionFocus.count, 1, "inside the group")
        expect(w.controller.validateMenuItem(up))
        expectEqual(up.title, "Enclosing Group")
        expect(w.command(up: true))
        expectEqual(Set(w.editor.selectedShapeIDs), [a, b])
        expect(!w.controller.validateMenuItem(up), "a is in the frame and b is not: nowhere to step out to")
        expectEqual(up.title, "Enclosing Board")
        // The Keyboard Shortcuts window lists the command as it is called, not as its item is named now.
        let menus = BoardMenus.make(appName: "Infinite Canvas", registry: w.editor.registry)
        let go = try require(menus.main.item(withTitle: "Go")?.submenu)
        go.item(withTitle: "Enclosing Board")?.title = "Enclosing Frame"
        let sections = KeyboardShortcutsWindow(registry: w.editor.registry, menu: { menus.main }, autosaveName: nil).sections
        let row = sections.first { $0.title == "Go" }?.rows.first { $0.keys == ["⌘↑"] }
        expectEqual(row?.title, "Enclosing Board")
    },
    test("⌘↓ on a group selects its first part, and on a frame the first shape in it, in reading order; Return does too; a double-click is as it was") {
        let w = try NestedWindow()
        defer { w.board.close() }
        expect(w.editor.showBoard(w.nest.sBoard))
        let (first, second) = w.nest.notes(on: 2)
        expect(w.editor.group([second, first]))
        w.editor.selectedShapeIDs = [second, first]
        expectEqual(w.editor.selectionFocus.count, 0)
        expect(w.command(up: false))
        expectEqual(w.editor.selectedShapeIDs, [first], "the one on the left, which comes second in the stack")
        expect(w.editor.ungroup([first, second]))
        let frame = w.frame(holding: [second, first])
        w.editor.selectedShapeIDs = [frame]
        w.window.makeFirstResponder(w.canvas)
        w.window.pressReturn()
        expectEqual(w.editor.selectedShapeIDs, [first], "Return goes in too")
        w.editor.selectedShapeIDs = [frame]
        expect(w.command(up: false))
        expectEqual(w.editor.selectedShapeIDs, [first])
        expectEqual(w.editor.board, w.nest.sBoard, "a frame opens no board")
        w.editor.selectedShapeIDs = [w.nest.t]
        expect(w.command(up: false))
        expectEqual(w.editor.board, w.nest.tBoard, "a subboard still opens")
    },
    test("Escape climbs one level at a time, as ⌘↑ steps out: from a note in a group in a frame, the group, the frame, then nothing, on the same board") {
        let w = try NestedWindow()
        defer { w.board.close() }
        expect(w.editor.showBoard(w.nest.sBoard))
        let (first, second) = w.nest.notes(on: 2)
        let frame = w.frame(holding: [first, second])
        expect(w.editor.group([first, second]))
        let walk = w.walk(names: [first: "first", second: "second", frame: "Sprint"])
        w.editor.selectedShapeIDs = [first]
        expectEqual(walk.focus.id, "canvas/first")
        walk.expectEscapeLadder(["canvas/first+second", "canvas/Sprint", "canvas"])
        expectEqual(w.editor.board, w.nest.sBoard, "Escape never leaves the board")
        w.editor.selectedShapeIDs = [first]
        for level in ["canvas/first+second", "canvas/Sprint"] {
            expect(w.command(up: true))
            expectEqual(walk.focus.id, level, "⌘↑ steps where Escape does")
        }
    },
    test("⇧Tab after Tab from two shapes selects the two again; ⌥⌘ and an arrow, then the opposite, come back; with ⇧, the opposite takes off what it added") {
        let w = try NestedWindow()
        defer { w.board.close() }
        expect(w.editor.showBoard(w.nest.sBoard))
        let (first, second) = w.nest.notes(on: 2)
        let walk = w.walk(names: [first: "first", second: "second", w.nest.t: "T"])
        w.editor.selectedShapeIDs = [first, w.nest.t]
        expectEqual(walk.press(.tab).id, "canvas/second")
        expectEqual(walk.press(.backTab).id, "canvas/first+T", "exactly the two")
        for (arrow, back) in [(Key.right, Key.left), (Key.down, Key.up)] {
            w.editor.selectedShapeIDs = [first]
            expect(walk.press(Chord(arrow, [.command, .option])).id != "canvas/first", "a step \(arrow)")
            expectEqual(walk.press(Chord(back, [.command, .option])).id, "canvas/first", "and back")
        }
        w.editor.selectedShapeIDs = [second]
        expectEqual(walk.press(Chord(Key.left, [.command, .option])).id, "canvas/first")
        expectEqual(walk.press(Chord(Key.right, [.command, .option])).id, "canvas/second")
        w.editor.selectedShapeIDs = [first]
        expectEqual(walk.press(Chord(Key.right, [.command, .option, .shift])).id, "canvas/first+second")
        expectEqual(walk.press(Chord(Key.left, [.command, .option, .shift])).id, "canvas/first", "the one it added taken off")
    },
    test("Tab from a selected arrow goes on from its middle in reading order, never from the board's first, and the opposite key comes back to it") {
        let w = try NestedWindow()
        defer { w.board.close() }
        expect(w.editor.showBoard(w.nest.sBoard))
        let (first, second) = w.nest.notes(on: 2)
        let arrow = w.nest.arrow(on: 2)
        let walk = w.walk(names: [first: "first", second: "second", w.nest.t: "T", arrow: "arrow"])
        w.editor.selectedShapeIDs = [arrow]
        expectEqual(walk.focus.id, "canvas/arrow")
        expectEqual(walk.press(.tab).id, "canvas/second", "the arrow's middle reads between the notes")
        expectEqual(walk.press(.backTab).id, "canvas/arrow")
        expectEqual(walk.press(.backTab).id, "canvas/first")
        expectEqual(walk.press(.tab).id, "canvas/arrow")
    },
    test("Go › Forward (⌘]) undoes Back") {
        let w = try NestedWindow()
        defer { w.board.close() }
        expect(w.editor.showBoard(w.nest.sBoard))
        let (first, second) = w.nest.notes(on: 2)
        let walk = w.walk(names: [first: "first", second: "second", w.nest.t: "T"])
        w.editor.selectedShapeIDs = [first]
        walk.press(.tab)
        expectEqual(walk.press(Chord("[", .command)).id, "canvas/first")
        expectEqual(walk.press(Chord("]", .command)).id, "canvas/second")
        let menus = BoardMenus.make(appName: "Infinite Canvas", registry: w.editor.registry)
        let forward = try require(menus.main.item(withTitle: "Go")?.submenu?.item(withTitle: "Forward"))
        expectEqual(forward.keyEquivalent, "]")
        expectEqual(forward.keyEquivalentModifierMask, .command)
    },
    test("Delete with the selection out of view brings it into view as it goes") {
        let w = try NestedWindow()
        defer { w.board.close() }
        let (first, _) = w.nest.notes(on: 1)
        w.window.makeFirstResponder(w.canvas)
        w.editor.camera = Camera(origin: CGPoint(x: 5000, y: 5000), zoom: 1)
        w.editor.selectedShapeIDs = [first]
        let target = w.editor.cameraTarget
        w.window.pressDelete()
        expectEqual(w.editor.document[first], nil, "deleted")
        expect(w.editor.cameraTarget != target, "the camera goes where it was")
    },
    test("the selection is outlined in the accent while the canvas has the keyboard, and in a quieter gray while another view has it") {
        let w = try NestedWindow()
        defer { w.board.close() }
        let (first, _) = w.nest.notes(on: 1)
        w.window.makeFirstResponder(w.canvas)
        expect(w.editor.hasKeyboard)
        let size = CGSize(width: 900, height: 700)
        let unselected = renderBitmap(w.editor, size: size)
        w.editor.selectedShapeIDs = [first]
        let accent = renderBitmap(w.editor, size: size)
        // The note's left edge, at its middle: the outline stands off it, a little to the left.
        let edge = w.editor.camera.toView(CGPoint(x: 80, y: 180))
        let spot = try require((0..<12).map { CGPoint(x: edge.x - CGFloat($0), y: edge.y) }
            .max { difference(accent, unselected, at: $0) < difference(accent, unselected, at: $1) })
        expect(difference(accent, unselected, at: spot) > 40, "outlined at \(spot)")
        w.window.makeFirstResponder(nil)
        expect(!w.editor.hasKeyboard)
        let quiet = renderBitmap(w.editor, size: size)
        let gray = pixel(quiet, at: spot)
        expect(difference(quiet, unselected, at: spot) > 40, "still outlined")
        expect(abs(gray[0] - gray[1]) <= 10 && abs(gray[1] - gray[2]) <= 10, "a neutral gray: \(gray)")
        let blue = pixel(accent, at: spot)
        if abs(blue[0] - blue[2]) > 30 { expect(difference(accent, quiet, at: spot) > 30, "not the accent: \(gray), \(blue)") }
        w.window.makeFirstResponder(w.canvas)
        expectEqual(changedPixels(accent, renderBitmap(w.editor, size: size), in: CGRect(origin: .zero, size: size)), 0, "the accent again")
    },
])

/// How far apart two bitmaps' colors are at a view point: the largest difference of a channel.
@MainActor private func difference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, at point: CGPoint) -> Int {
    zip(pixel(a, at: point), pixel(b, at: point)).map { abs($0 - $1) }.max() ?? 0
}

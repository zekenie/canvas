import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Frames
import Grouping
import Selection
import StickyNotes
import TestKit
import Titles

// Moving between shapes as the app ships them: Tab and ⇧Tab through a board's shapes with the keys the
// keyboard sends, ⌘↓ and ⌘↑ through a group, a frame and the boards around them, and the Go item named
// for the step ⌘↑ would take.

extension NestedWindow {
    /// ⌘↑ or ⌘↓ as the keyboard sends it to the canvas: whether the canvas took it.
    @discardableResult func command(up: Bool) -> Bool {
        window.makeFirstResponder(canvas)
        return canvas.performKeyEquivalent(with: commandArrow(window, up: up))
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
    test("Tab and ⇧Tab, as the keyboard sends them, step through a board's shapes in reading order; an arrow, which has no box, is never one") {
        let w = try NestedWindow()
        defer { w.board.close() }
        expect(w.editor.showBoard(w.nest.sBoard))
        let (first, second) = w.nest.notes(on: 2)
        w.window.makeFirstResponder(w.canvas)
        w.window.press("\t", code: 48)
        expectEqual(w.editor.selectedShapeIDs, [first], "with nothing selected, the first")
        w.window.press("\t", code: 48)
        expectEqual(w.editor.selectedShapeIDs, [second])
        w.window.press("\t", code: 48)
        expectEqual(w.editor.selectedShapeIDs, [w.nest.t], "the subboard below them, not the arrow between")
        w.window.press("\t", code: 48)
        expectEqual(w.editor.selectedShapeIDs, [first], "round to the first")
        // ⇧Tab types the back-tab character, with ⇧ held.
        w.window.press("\u{19}", code: 48, modifiers: .shift)
        expectEqual(w.editor.selectedShapeIDs, [w.nest.t], "⇧Tab goes back")
        w.window.press("\u{19}", code: 48, modifiers: .shift)
        expectEqual(w.editor.selectedShapeIDs, [second])
    },
    test("⌥⌘ and an arrow key select the nearest shape that way, and add it with ⇧") {
        let w = try NestedWindow()
        defer { w.board.close() }
        expect(w.editor.showBoard(w.nest.sBoard))
        let (first, second) = w.nest.notes(on: 2)
        w.editor.selectedShapeIDs = [first]
        w.window.makeFirstResponder(w.canvas)
        let option = NSEvent.ModifierFlags([.command, .option, .function, .numericPad])
        w.window.sendEvent(w.window.keyEvent("\u{F703}", code: 124, modifiers: option))
        expectEqual(w.editor.selectedShapeIDs, [second])
        w.window.sendEvent(w.window.keyEvent("\u{F701}", code: 125, modifiers: option))
        expectEqual(w.editor.selectedShapeIDs, [w.nest.t], "from the second note, the subboard is south, in the wedge")
        w.editor.selectedShapeIDs = [first]
        w.window.sendEvent(w.window.keyEvent("\u{F703}", code: 124, modifiers: option.union(.shift)))
        expectEqual(w.editor.selectedShapeIDs, [first, second])
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
])

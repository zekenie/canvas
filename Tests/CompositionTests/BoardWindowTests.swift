import AppKit
import Boards
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Composition
import CoreGraphics
import Foundation
import Mentions
import Selection
import StickyNotes
import TestKit
import Titles

/// A board window as the app makes it (`makeWindowControllers`, unshown), over the nested file: the
/// canvas with the path over it, and the panel.
@MainActor
final class NestedWindow {
    let board: BoardDocument
    let controller: BoardWindowController
    let window: NSWindow
    let canvas: CanvasView
    let nest = NestedFile()
    var editor: CanvasEditor { board.editor }

    init() throws {
        try configureBoards()
        board = try nestedDocument()
        board.makeWindowControllers()
        controller = try require(board.windowControllers.first as? BoardWindowController)
        window = try require(controller.window)
        window.settle()
        canvas = try require(board.focus.canvas, "the window's content made the canvas")
    }

    /// The path's crumbs that are buttons, over the canvas, leading first.
    var crumbs: [NSButton] {
        (window.contentView?.descendants(NSButton.self) ?? []).filter { !($0 is NSPopUpButton) && overCanvas($0) }
            .sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
    }

    /// The panel header's text field (Titles' `TitleHeader`), beside the canvas.
    var titleField: NSTextField? {
        guard let content = window.contentView else { return nil }
        return content.descendants(NSTextField.self).first { $0.isEditable && !overCanvas($0) && $0.isInPanelHeader(of: content) }
    }

    /// The app's menus, with Go's items sent to this window's controller (an unshown window isn't the
    /// key window, where they'd go).
    func goItems() throws -> (menus: BoardMenus.Menus, up: NSMenuItem, open: NSMenuItem) {
        let menus = BoardMenus.make(appName: "Infinite Canvas")
        let go = try require(menus.main.item(withTitle: "Go")?.submenu)
        for item in go.items { item.target = controller }
        return (menus, try require(go.item(withTitle: "Enclosing Board")), try require(go.item(withTitle: "Open")))
    }

    /// What a click at `point`, in the canvas's coordinates, would land on.
    func hit(_ point: CGPoint) -> NSView? {
        guard let content = window.contentView, let frame = content.superview else { return nil }
        return content.hitTest(frame.convert(canvas.convert(point, to: nil), from: nil))
    }

    func isCanvas(_ view: NSView?) -> Bool { view.map { $0 === canvas || $0.isDescendant(of: canvas) } ?? false }

    /// A point on the canvas, from its top left.
    func canvasPoint(x: CGFloat, fromTop y: CGFloat) -> CGPoint {
        CGPoint(x: x, y: canvas.isFlipped ? y : canvas.bounds.height - y)
    }

    private func overCanvas(_ view: NSView) -> Bool {
        let frame = canvas.convert(view.bounds, from: view)
        return canvas.bounds.contains(CGPoint(x: frame.midX, y: frame.midY))
    }
}

/// ⌘ and an arrow key as the keyboard sends it: with the function and keypad flags, which no chord
/// names.
@MainActor func commandArrow(_ window: NSWindow, up: Bool) -> NSEvent {
    window.keyEvent(up ? "\u{F700}" : "\u{F701}", code: up ? 126 : 125, modifiers: [.command, .function, .numericPad])
}

@MainActor let boardWindowTests = Suite("Boards in a window", [
    test("Go › Enclosing Board (⌘↑) and Open (⌘↓) go up and in, each enabled only while it can") {
        let w = try NestedWindow()
        defer { w.board.close() }
        let (_, up, open) = try w.goItems()
        expectEqual(up.keyEquivalent, "\u{F700}")
        expectEqual(open.keyEquivalent, "\u{F701}")
        expectEqual(up.keyEquivalentModifierMask, .command)
        expectEqual(open.keyEquivalentModifierMask, .command)
        expect(!w.controller.validateMenuItem(up), "nothing above the root")
        expect(!w.controller.validateMenuItem(open), "nothing selected")
        w.editor.selection = w.nest.s
        expect(w.controller.validateMenuItem(open))
        w.controller.openSelection(nil)
        expectEqual(w.editor.board, w.nest.sBoard)
        expect(w.controller.validateMenuItem(up))
        expect(!w.controller.validateMenuItem(open), "nothing selected on arrival")
        w.controller.enclosingBoard(nil)
        expectEqual(w.editor.board, .root)
        expectEqual(w.editor.selectedShapeIDs, [w.nest.s], "the subboard left")
        w.editor.selection = w.nest.arrow(on: 1)
        expect(!w.controller.validateMenuItem(open), "an arrow opens nothing")
        w.editor.selection = w.nest.s
        let (menus, _, _) = try w.goItems()
        expect(menus.main.performKeyEquivalent(with: commandArrow(w.window, up: false)), "the menu bar runs Open")
        expectEqual(w.editor.board, w.nest.sBoard, "⌘↓ from the menu bar, where the canvas doesn't have the keyboard")
    },
    test("⌘↑ and ⌘↓ in a panel's field move its caret: Go's items leave the keys to the text") {
        let w = try NestedWindow()
        defer { w.board.close() }
        expect(w.editor.showBoard(w.nest.sBoard))
        let (note, _) = w.nest.notes(on: 2)
        w.editor.selection = note
        w.window.spin { w.titleField != nil }
        let field = try require(w.titleField)
        w.window.focus(field)
        w.window.type("Groceries")
        let (menus, up, open) = try w.goItems()
        expect(!w.controller.validateMenuItem(up) && !w.controller.validateMenuItem(open), "off while text has the keyboard")
        // AppKit asks the menu bar for a ⌘ key before the text has it.
        expect(!menus.main.performKeyEquivalent(with: commandArrow(w.window, up: true)), "a disabled item leaves the key")
        w.window.sendEvent(commandArrow(w.window, up: true))
        let text = try require(w.window.firstResponder as? NSTextView)
        expectEqual(text.selectedRange(), NSRange(location: 0, length: 0), "to the start of the text")
        expect(!menus.main.performKeyEquivalent(with: commandArrow(w.window, up: false)))
        w.window.sendEvent(commandArrow(w.window, up: false))
        expectEqual(text.selectedRange(), NSRange(location: 9, length: 0), "to its end")
        expectEqual(w.editor.board, w.nest.sBoard, "still inside")
        expectEqual(w.editor.selectedShapeIDs, [note])
        expectEqual(w.editor.document[note]?[TitleProperty.self], "Groceries")
    },
    test("a ⌘↑ from the keyboard, with the flags a real one has, goes up from the canvas; ⌘↓ goes back in") {
        let w = try NestedWindow()
        defer { w.board.close() }
        expect(w.editor.showBoard(w.nest.sBoard))
        expect(w.editor.showBoard(w.nest.tBoard))
        w.window.makeFirstResponder(w.canvas)
        expect(w.canvas.performKeyEquivalent(with: commandArrow(w.window, up: true)))
        expectEqual(w.editor.board, w.nest.sBoard)
        expectEqual(w.editor.selectedShapeIDs, [w.nest.t])
        expect(w.canvas.performKeyEquivalent(with: commandArrow(w.window, up: false)))
        expectEqual(w.editor.board, w.nest.tBoard)
        expect(w.canvas.performKeyEquivalent(with: commandArrow(w.window, up: true)))
        expect(w.canvas.performKeyEquivalent(with: commandArrow(w.window, up: true)))
        expectEqual(w.editor.board, .root)
        w.editor.selection = nil
        expect(!w.canvas.performKeyEquivalent(with: commandArrow(w.window, up: true)), "on the root, with nothing selected, the keys pass")
        expect(!w.canvas.performKeyEquivalent(with: commandArrow(w.window, up: false)))
    },
    test("the path shows over the canvas inside a subboard, not on the root; only its pill takes clicks, and a crumb goes up") {
        let w = try NestedWindow()
        defer { w.board.close() }
        expectEqual(w.board.viewState.fileName, w.board.displayName, "the root's crumb is the file's name")
        expect(!w.board.viewState.fileName.isEmpty)
        w.window.settle()
        expectEqual(w.crumbs.count, 0, "nothing on the root")
        let top = w.canvasPoint(x: w.canvas.bounds.midX, fromTop: 20)
        expect(w.isCanvas(w.hit(top)), "the canvas, where the pill would be")

        expect(w.editor.showBoard(w.nest.sBoard))
        w.window.spin { w.crumbs.count == 1 }
        expect(w.editor.showBoard(w.nest.tBoard))
        w.window.spin { w.crumbs.count == 2 }
        let root = try require(w.crumbs.first)
        let pill = w.canvas.convert(root.bounds, from: root)
        expect(pill.minY >= 0 && w.canvas.convert(root.bounds, from: root).minX > 0, "over the canvas: \(pill)")
        expect(!w.isCanvas(w.hit(CGPoint(x: pill.midX, y: pill.midY))), "the pill takes a click on it")
        expect(w.isCanvas(w.hit(w.canvasPoint(x: 30, fromTop: 20))), "beside it, the canvas does")
        expect(w.isCanvas(w.hit(w.canvasPoint(x: w.canvas.bounds.midX, fromTop: 80))), "and below it")

        root.performClick(nil)
        w.window.settle()
        expectEqual(w.editor.board, .root)
        expectEqual(w.editor.selectedShapeIDs, [w.nest.s], "the subboard the path came through")
        w.window.spin { w.crumbs.isEmpty }
    },
    test("undo from another board shows the board its step was made on, through the window") {
        let w = try NestedWindow()
        defer { w.board.close() }
        let window = try require(w.window as? BoardWindow)
        expect(w.editor.showBoard(w.nest.sBoard))
        expect(w.editor.showBoard(w.nest.tBoard))
        let added = w.editor.add(StickyNote(frame: CGRect(x: 800, y: 80, width: 200, height: 200), text: "Deep"))
        w.controller.enclosingBoard(nil)
        w.controller.enclosingBoard(nil)
        expectEqual(w.editor.board, .root)
        w.window.makeFirstResponder(w.canvas)
        let undo = NSMenuItem(title: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        expect(window.validateMenuItem(undo))
        window.undo(nil)
        expectEqual(w.editor.board, w.nest.tBoard, "shown first")
        expectEqual(w.editor.document[added], nil)
        expect(!w.board.isDocumentEdited)
        w.controller.enclosingBoard(nil)
        window.redo(nil)
        expectEqual(w.editor.board, w.nest.tBoard)
        expect(w.editor.document[added] != nil)
        expect(w.board.isDocumentEdited)
    },
])

import Adornments
import AppKit
import Boards
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import CoreGraphics
import Foundation
import Geometry
import Mentions
import Schemas
import Selection
import StickyNotes
import TableOfContents
import TestKit
import TextEditing
import Titles

/// A menu item's target that counts what it's sent.
@MainActor final class MenuActionLog: NSObject {
    var fired = 0
    @objc func fire(_ sender: Any?) { fired += 1 }
}

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

    /// `extra`: plugins after the shipped list.
    init(extra: [any CanvasPlugin] = []) throws {
        try configureBoards(extra: extra)
        board = try nestedDocument()
        board.makeWindowControllers()
        controller = try require(board.windowControllers.first as? BoardWindowController)
        window = try require(controller.window)
        window.settle()
        canvas = try require(board.focus.canvas, "the window's content made the canvas")
    }

    /// The path's crumbs that are buttons, over the canvas, leading first ("…" isn't one).
    var crumbs: [NSButton] {
        guard let content = window.contentView else { return [] }
        let folds = pathFolds(under: content)
        return content.descendants(NSButton.self)
            .filter { button in !folds.contains { $0 === button } && overCanvas(button) && onCanvas(button).minY < Self.pathBottom }
            .sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
    }

    /// The buttons of the crumb's menu that shows, over the canvas below the path, top first: each
    /// row's, and a disclosure triangle's before a row with rows under it.
    var menuButtons: [NSButton] {
        (window.contentView?.descendants(NSButton.self) ?? []).filter { overCanvas($0) && onCanvas($0).minY >= Self.pathBottom }
            .sorted { (onCanvas($0).minY, onCanvas($0).minX) < (onCanvas($1).minY, onCanvas($1).minX) }
    }

    /// Where a view is on the canvas, in view points from its top left.
    func onCanvas(_ view: NSView) -> CGRect { canvas.convert(view.bounds, from: view) }

    /// The pointer moved to `point` on the canvas (view points), as AppKit tells the canvas wherever
    /// it is over it, even under a view over it.
    func move(to point: CGPoint, time: TimeInterval) {
        let event = NSEvent.mouseEvent(with: .mouseMoved, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: time,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 1)!
        canvas.mouseMoved(with: event)
    }

    /// Below the path, which is 8 points down and 27 tall (`BoardPath.coveredHeight`, 35).
    static let pathBottom: CGFloat = 40

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
        return (menus, try require(go.item(withTitle: "Enclosing Board")), try require(go.item(withTitle: "Open Selection")))
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

/// The path's "…" under `root`: each a button over the view its menu is placed against
/// (`BoardPath.foldedAnchor`), not a crumb. Never clicked here: its menu is modal on screen.
@MainActor func pathFolds(under root: NSView) -> [NSButton] {
    let anchors = root.descendants(NSView.self).filter { $0.identifier == BoardPath.foldedAnchor }.map { $0.convert($0.bounds, to: nil) }
    return root.descendants(NSButton.self).filter { button in
        let frame = button.convert(button.bounds, to: nil)
        return anchors.contains { frame.contains(CGPoint(x: $0.midX, y: $0.midY)) }
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
        expect(w.controller.validateMenuItem(open), "an arrow opens: its label is edited")
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
    test("the window's subtitle names the board shown inside a subboard, as its crumb does, and nothing on the root, where the title is the file's name") {
        let w = try NestedWindow()
        defer { w.board.close() }
        expectEqual(w.window.subtitle, "")
        expect(w.editor.showBoard(w.nest.sBoard))
        w.window.spin { w.window.subtitle == "Plans" }
        expect(w.editor.showBoard(w.nest.tBoard))
        w.window.spin { w.window.subtitle == "Untitled Subboard" }
        w.editor.goToEnclosingBoard()
        w.window.spin { w.window.subtitle == "Plans" }
        // Renamed there, and entered again: the name it has now.
        w.editor.transact("Rename") { $0.update(w.nest.t) { $0[TitleProperty.self] = "Pantry" } }
        expect(w.editor.showBoard(w.nest.tBoard))
        w.window.spin { w.window.subtitle == "Pantry" }
        w.editor.undo()                                  // the rename, made on Plans's board, which it shows first
        w.window.spin { w.window.subtitle == "Plans" }
        expect(w.editor.showBoard(.root))
        w.window.spin { w.window.subtitle.isEmpty }
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
    test("a crumb's menu shows over the canvas, its board's rows as the table of contents lists them, and takes clicks; a row picked goes there") {
        let w = try NestedWindow()
        defer { w.board.close() }
        expect(w.editor.showBoard(w.nest.sBoard))
        expect(w.editor.showBoard(w.nest.tBoard))
        w.window.spin { w.crumbs.count == 2 }
        let crumbs = try require(w.editor.boardCrumbs)
        let rows = try require(w.editor.tableOfContents).outline(of: w.nest.sBoard)
        expectEqual(rows.map { $0.label?.text }, ["Plans, first", "Plans, second", "Untitled Subboard"])
        expectEqual(rows.first?.children?.map(\.id), [w.nest.arrow(on: 2)], "the arrow, under the note it starts from")
        crumbs.pointerEntered(crumb: w.nest.sBoard)
        w.window.spin { w.menuButtons.count == 5 }
        // Front to back: the subboard's disclosure triangle and its row, the way you came (its board's rows
        // are under it); Plans, second's; and Plans, first's triangle and its row.
        let way = w.onCanvas(w.menuButtons[1])
        expect(!w.isCanvas(w.hit(CGPoint(x: way.midX, y: way.midY))), "the menu takes a click on it")
        try require(w.menuButtons.last).performClick(nil)
        w.window.spin { w.editor.board == w.nest.sBoard }
        expectEqual(w.editor.selectedShapeIDs, [w.nest.notes(on: 2).0], "the note, gone to")
        w.editor.goBack()
        expectEqual(w.editor.board, w.nest.tBoard, "one step back")
        w.window.spin { w.crumbs.count == 2 }
        crumbs.pointerEntered(crumb: .root)
        w.window.spin { w.menuButtons.count == 5 }
        // The root's, front to back: Plans (and its board's triangle), the way you came; Root, second; and
        // Root, first (and its arrow's triangle).
        w.menuButtons[1].performClick(nil)
        w.window.spin { w.editor.board == w.nest.sBoard }
        expectEqual(w.editor.selectedShapeIDs, [], "into Plans")
    },
    test("the pointer over the path doesn't hover what's under it on the canvas") {
        let w = try NestedWindow()
        defer { w.board.close() }
        expect(w.editor.showBoard(w.nest.sBoard))
        w.window.spin { w.crumbs.count == 1 }
        let crumb = w.onCanvas(try require(w.crumbs.first))
        let under = w.editor.add(StickyNote(frame: w.editor.camera.toWorld(CGRect(x: crumb.midX - 150, y: 0, width: 300, height: 200)), text: "Under"))
        w.move(to: CGPoint(x: crumb.midX, y: crumb.maxY + 60), time: 1)
        expectEqual(w.editor.hovered, under, "below the path, the note")
        w.move(to: CGPoint(x: crumb.midX, y: crumb.midY), time: 1.1)
        expectEqual(w.editor.hovered, nil, "on the path, not the note under it")
        w.move(to: CGPoint(x: crumb.midX + 2, y: crumb.midY), time: 1.2)
        expectEqual(w.editor.hovered, nil)
        w.move(to: CGPoint(x: crumb.midX, y: crumb.maxY + 60), time: 1.3)
        expectEqual(w.editor.hovered, under, "and back off it")
    },
    test("a subboard's first visit fits its board below the path's pill: the top note, and its title pill in full, are clear of the crumbs") {
        let w = try NestedWindow()
        defer { w.board.close() }
        let (note, _) = w.nest.notes(on: 2)
        w.editor.transact(on: w.nest.sBoard, "Tall") { tx in
            tx.update(note) { $0[TitleProperty.self] = "Top" }
            tx.insert(ShapeRecord(StickyNote(frame: CGRect(x: 80, y: 4000, width: 200, height: 200), text: "Far below")))
        }
        expect(w.editor.showBoard(w.nest.sBoard))
        w.window.spin { !w.crumbs.isEmpty }
        // A board this tall is fitted far out, where shapes are skeletons and show no pill: the note's
        // top is clear of the crumbs then, and its pill, 27 points above it, in full.
        let box = try require(w.editor.document[note]?.box)
        let pill = w.editor.adornmentFrames(of: note).first { $0.adornment == .of(TitlePill.self) }?.rect
        let crumbsBottom = try require(w.crumbs.map { w.onCanvas($0).maxY }.max())
        let top = w.editor.camera.toView(pill ?? box)
        expect(top.minY >= crumbsBottom, "the \(pill == nil ? "note" : "pill") at \(top), the crumbs down to \(crumbsBottom)")
    },
    test("⌃Space in a schema card's JSON, which no menu takes, opens its completions there") {
        let w = try NestedWindow()
        defer { w.board.close() }
        let code = try w.schemaCode(caret: 1)
        let controlSpace = w.window.keyEvent(" ", code: 49, modifiers: .control)
        let (menus, _, _) = try w.goItems()
        expect(!menus.main.performKeyEquivalent(with: controlSpace), "the menu bar leaves ⌃Space to the text")
        w.window.sendEvent(controlSpace)
        let list = try require(code.caretListWindow, "open")
        expectEqual(list.list.highlightedItem?.title, "title", "keywords, where the root's first key goes")
        expect(code.holdsKeys)
        w.window.pressEscape()
        expect(code.caretListWindow == nil)
        expect(w.window.firstResponder === code, "Escape closed the list; the panel stays")
    },
    test("⌘↩ with a schema card's completions open, in the app's window, closes them and commits the JSON, as with them closed") {
        let w = try NestedWindow()
        defer { w.board.close() }
        let code = try w.schemaCode(caret: 1)
        w.window.sendEvent(w.window.keyEvent(" ", code: 49, modifiers: .control))
        _ = try require(code.caretListWindow, "open")
        let commandReturn = w.window.keyEvent("\r", code: 36, modifiers: .command)
        expect(w.window.performKeyEquivalent(with: commandReturn), "the JSON's commit, before the menus")
        expect(code.caretListWindow == nil && !code.holdsKeys, "closed")
        expect(w.window.firstResponder === code, "the JSON keeps the keyboard")
        expectEqual(code.string, SchemaCard.starter, "nothing picked, no new line")
    },
    test("a pick with the mouse, in the list's own window, is part of the typing: one Change JSON step on the board") {
        let w = try NestedWindow()
        defer { w.board.close() }
        let code = try w.schemaCode(caret: 1)
        w.window.type("\"ti")
        w.window.sendEvent(w.window.keyEvent(" ", code: 49, modifiers: .control))
        let list = try require(code.caretListWindow, "open")
        expectEqual(list.list.highlightedItem?.title, "title")
        // Shown, the list is a child of the board's window (an unshown one's never is, so it's put there),
        // and a click in it is no click elsewhere: the window's watch for those leaves it alone.
        w.window.addChildWindow(list, ordered: .above)
        let rows = try require(list.contentView?.descendants.first { $0.accessibilityRole() == .list })
        @MainActor func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
            try require(NSEvent.mouseEvent(with: type, location: rows.convert(CGPoint(x: 100, y: 10), to: nil), modifierFlags: [], timestamp: 1,
                                           windowNumber: list.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        NSApp.sendEvent(try mouse(.leftMouseDown))
        NSApp.sendEvent(try mouse(.leftMouseUp))
        rows.mouseDown(with: try mouse(.leftMouseDown))       // an unshown window's clicks don't reach its views
        expect(code.string.hasPrefix(#"{"title": ""#), code.string)
        expect(code.caretListWindow == nil)
        let id = try require(w.editor.selection)
        expectEqual(w.editor.document[id]?.typed(as: SchemaCard.self)?.props.schema.text, code.string)
        expectEqual(w.editor.undoHistory.undoName, "Change JSON")
        w.editor.undo()
        expectEqual(w.editor.document[id]?.typed(as: SchemaCard.self)?.props.schema.text, SchemaCard.starter, "the typing and the pick, one step")
    },
    test("View's zoom items run the zoom commands, each dimmed while it can't run; Edit › Delete and Select All likewise") {
        let w = try NestedWindow()
        defer { w.board.close() }
        let menus = BoardMenus.make(appName: "Infinite Canvas")
        let view = try require(menus.main.item(withTitle: "View")?.submenu)
        @MainActor func enabled(_ title: String) throws -> Bool { w.controller.validateMenuItem(try require(view.item(withTitle: title), title)) }
        w.editor.camera = Camera()
        expect(try enabled("Zoom In") && enabled("Zoom Out") && enabled("Zoom to Fit"))
        expect(try !enabled("Actual Size"), "at 100%")
        expect(try !enabled("Zoom to Selection"), "nothing selected")
        w.editor.selection = w.nest.s
        expect(try enabled("Zoom to Selection"))
        w.editor.camera.zoom = 8
        expect(try !enabled("Zoom In"), "the last stop")
        w.controller.zoomToFit(nil)
        expect(w.editor.cameraTarget != w.editor.camera, "on its way")
        let edit = try require(menus.main.item(withTitle: "Edit")?.submenu)
        let delete = try require(edit.item(withTitle: "Delete")), all = try require(edit.item(withTitle: "Select All"))
        expect(w.canvas.validateMenuItem(delete) && w.canvas.validateMenuItem(all))
        w.editor.selection = nil
        expect(!w.canvas.validateMenuItem(delete), "nothing selected")
        expect(w.editor.showBoard(w.nest.sBoard))
        w.editor.transact { $0.delete(Set($0.document.shapes.map(\.id))) }
        expect(!w.canvas.validateMenuItem(all), "an empty board")
    },
    test("⇧1 at the menu bar zooms to fit by the number row's key, whatever it types; in text it types, and the menu leaves it") {
        let w = try NestedWindow()
        defer { w.board.close() }
        let menus = BoardMenus.make(appName: "Infinite Canvas")
        let view = try require(menus.main.item(withTitle: "View")?.submenu)
        for item in view.items { item.target = w.controller }
        w.editor.camera = Camera(origin: CGPoint(x: 5000, y: 5000))
        let bang = w.window.keyEvent("!", code: 18, modifiers: .shift)
        expect(menus.main.performKeyEquivalent(with: bang), "⇧1 as a US keyboard sends it: \"!\"")
        expect(w.editor.cameraTarget != w.editor.camera, "zooming to fit")
        w.editor.camera = Camera(origin: CGPoint(x: 5000, y: 5000))
        expect(menus.main.performKeyEquivalent(with: w.window.keyEvent("1", code: 18, modifiers: .shift)), "as a French one does")
        expect(!menus.main.performKeyEquivalent(with: w.window.keyEvent("!", code: 30, modifiers: .shift)), "\"!\" from another key isn't ⇧1")
        w.editor.selection = nil
        expect(!menus.main.performKeyEquivalent(with: w.window.keyEvent("@", code: 19, modifiers: .shift)), "nothing selected: Zoom to Selection leaves ⇧2")
        expect(w.editor.showBoard(w.nest.sBoard))
        let (note, _) = w.nest.notes(on: 2)
        w.editor.selection = note
        w.window.spin { w.titleField != nil }
        let field = try require(w.titleField)
        w.window.focus(field)
        w.editor.camera = Camera(origin: CGPoint(x: 5000, y: 5000))
        expect(!menus.main.performKeyEquivalent(with: bang), "text has the keyboard: the menu leaves the key")
        expectEqual(w.editor.cameraTarget, Camera(origin: CGPoint(x: 5000, y: 5000)))
    },
    test("a key held with fn (🌐E, Emoji & Symbols) is the menu bar's while text has the keyboard, as AppKit's items for them answer only there") {
        let w = try NestedWindow()
        defer { w.board.close() }
        let menus = BoardMenus.make(appName: "Infinite Canvas")
        let edit = try require(menus.main.item(withTitle: "Edit")?.submenu)
        let log = MenuActionLog()
        // In the place of the one AppKit adds to the app's Edit menu, hidden, keyed 🌐E: only AppKit
        // may key an item with fn, so this one is keyed E, which a key event made here (not one from
        // the keyboard) held with fn matches too. What it holds is that the key reaches AppKit's match.
        let emoji = NSMenuItem(title: "Emoji & Symbols", action: #selector(MenuActionLog.fire(_:)), keyEquivalent: "e")
        emoji.keyEquivalentModifierMask = []
        emoji.target = log
        emoji.isHidden = true
        edit.addItem(emoji)
        expect(w.editor.showBoard(w.nest.sBoard))
        let (note, _) = w.nest.notes(on: 2)
        w.editor.selection = note
        w.window.spin { w.titleField != nil }
        w.window.focus(try require(w.titleField))
        expect(w.window.firstResponder is NSText, "the title's field has the keyboard")
        let globeE = w.window.keyEvent("e", code: 14, modifiers: .function)
        expect(menus.main.performKeyEquivalent(with: globeE), "🌐E opens the character palette, not an \"e\" in the field")
        expectEqual(log.fired, 1)
        let bang = w.window.keyEvent("!", code: 18, modifiers: .shift)
        expect(!menus.main.performKeyEquivalent(with: bang), "⇧1 still types")
    },
    test("the window's controller runs View's zoom items, and dims them as their commands say") {
        let w = try NestedWindow()
        defer { w.board.close() }
        w.editor.camera = Camera()
        let actions = [#selector(BoardWindowController.zoomIn(_:)), #selector(BoardWindowController.zoomOut(_:)),
                       #selector(BoardWindowController.zoomToActualSize(_:)), #selector(BoardWindowController.zoomToFit(_:)),
                       #selector(BoardWindowController.zoomToSelection(_:))]
        let items = actions.map { NSMenuItem(title: "", action: $0, keyEquivalent: "") }
        expectEqual(items.map { w.controller.validateMenuItem($0) }, [true, true, false, true, false])
        w.editor.camera.zoom = 0.873
        w.editor.camera.pan(by: CGSize(width: 30, height: 0))
        w.controller.zoomIn(nil)
        expectEqual(w.editor.cameraTarget.zoomPercentage, 100, "the next stop past where it is")
    },
    test("Edit › Spelling and Grammar's items are the text's with the keyboard, a note's or a title's, which checks its words as the app does; on the canvas, nothing's") {
        let w = try NestedWindow()
        defer { w.board.close() }
        let edit = try require(BoardMenus.make(appName: "Infinite Canvas").main.item(withTitle: "Edit")?.submenu)
        let spelling = try require(edit.item(withTitle: "Spelling and Grammar")?.submenu)
        let items = spelling.items.filter { !$0.isSeparatorItem }
        expectEqual(items.map(\.title), ["Show Spelling and Grammar", "Check Document Now", "Check Spelling While Typing",
                                         "Check Grammar With Spelling", "Correct Spelling Automatically"])
        expectEqual(items.map(\.keyEquivalent), [":", ";", "", "", ""], "⌘: and ⌘;")
        let actions = items.compactMap(\.action).map(NSStringFromSelector)
        expectEqual(actions, ["showGuessPanel:", "checkSpelling:", "toggleContinuousSpellChecking:", "toggleGrammarChecking:",
                              "toggleAutomaticSpellingCorrection:"])
        w.window.makeFirstResponder(w.canvas)
        for action in actions { expect(target(of: action, from: w.window.firstResponder) == nil, "the canvas has the keyboard: \(action) is dimmed") }

        let (note, _) = w.nest.notes(on: 1)
        expect(w.editor.beginEditing(note))
        w.window.spin { w.window.firstResponder is EditingTextView }
        let text = try require(w.window.firstResponder as? EditingTextView)
        expect(text.spelling === Spelling.app, "a note's words")
        for action in actions { expect(target(of: action, from: text) === text, "a note being edited: \(action)") }
        let whileTyping = try require(spelling.item(withTitle: "Check Spelling While Typing"))
        expect(text.validateMenuItem(whileTyping))
        expectEqual(whileTyping.state, Spelling.app.checksWhileTyping ? .on : .off)

        w.editor.endEditing()
        w.editor.selection = note
        w.window.spin { w.titleField != nil }
        w.window.focus(try require(w.titleField))
        let title = try require(w.window.firstResponder as? EditingTextView, "the title's field editor")
        expect(title.isFieldEditor)
        expect(title.spelling === Spelling.app, "a title's words")
        for action in actions { expect(target(of: action, from: title) === title, "the title's field: \(action)") }
    },
])

extension NestedWindow {
    /// A new schema card on the root, selected, its JSON in the panel with the keyboard, the caret
    /// at `caret`.
    func schemaCode(caret: Int) throws -> EditingTextView {
        editor.selection = editor.add(SchemaCard(frame: CGRect(x: 40, y: 400, width: 240, height: 67)))
        let content = try require(window.contentView)
        window.spin { content.descendants(NSTextView.self).contains { $0.font?.isFixedPitch == true } }
        let code = try require(content.descendants(EditingTextView.self).first { $0.font?.isFixedPitch == true })
        window.makeFirstResponder(code)
        code.setSelectedRange(NSRange(location: caret, length: 0))
        window.settle()
        return code
    }
}

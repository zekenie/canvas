import AppKit
import Arrows
import Canvas
import CanvasTesting
import CanvasUI
import DetailPanel
import Geometry
import LanguageModels
import Selection
import ShippedTesting
import StickyNotes
import SwiftUI
import TableOfContents
import TestKit

/// The app's window over the sample board, unshown: the canvas with the table of contents in its
/// sidebar and the shipped detail panel in an `.inspector`, wired by a `CanvasFocus` as the app wires
/// them (InspectorHost).
@MainActor
final class SampleWindow {
    let editor = ShippedPlugins.makeEditor(scheduler: TaskScheduler(), model: ScriptedLanguageModel())
    let window = BoardWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
    let focus = CanvasFocus()
    let host: NSHostingView<InspectorHost>
    let canvas: CanvasView

    init() throws {
        host = NSHostingView(rootView: InspectorHost(editor: editor, focus: focus, showsDetails: true, showsSidebar: true))
        host.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        window.editor = editor
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        canvas = try require(focus.canvas, "the representable hands its canvas view to the focus")
        window.settle()
    }

    /// The table of contents' list, while the sidebar shows it.
    var contents: NSTableView? { host.descendants(NSTableView.self).first { $0.isTableOfContents && !$0.isHiddenOrHasHiddenAncestor } }
    /// Its rows, less its header.
    var rows: Int { max(0, (contents?.numberOfRows ?? 0) - 1) }
    var canvasHasKeyboard: Bool { window.firstResponder === canvas }
    var notes: [ShapeID] { editor.document.shapes.filter { $0.kind == StickyNote.kind }.map(\.id) }
    /// The panel header's back button, while the inspector shows and there's a selection to go back to.
    var backButton: NSButton? { host.descendants(NSButton.self).first { $0.isInInspector(beside: canvas) && $0.isInPanelHeader(of: host) } }
    /// The panel header's title field (Titles' `TitleHeader`), while the inspector shows a note.
    var titleField: NSTextField? {
        host.descendants(NSTextField.self).first { $0.isEditable && $0.isInInspector(beside: canvas) && $0.isInPanelHeader(of: host) }
    }
}

/// The app's window as `makeWindowControllers` makes it (unshown) over the sample board, the panel in
/// its inspector and, with `sidebar`, the table of contents in its sidebar, with the app's menus, View's
/// items sent to its controller (an unshown window isn't the key window, where they'd go), and a key
/// driver that routes keys through them.
@MainActor
final class SampleBoardWindow {
    let board: BoardDocument
    let controller: BoardWindowController
    let window: NSWindow
    let canvas: CanvasView
    let menus: BoardMenus.Menus
    let keys: KeyDriver
    var editor: CanvasEditor { board.editor }

    init(sidebar: Bool = false) throws {
        try configureBoards(sidebar: sidebar)
        board = BoardDocument()
        board.start(with: SampleBoard.document())
        board.makeWindowControllers()
        controller = try require(board.windowControllers.first as? BoardWindowController)
        window = try require(controller.window)
        window.settle()
        canvas = try require(board.focus.canvas, "the window's content made the canvas")
        menus = BoardMenus.make(appName: "Infinite Canvas", registry: board.editor.registry)
        for item in menus.main.item(withTitle: "View")?.submenu?.items ?? [] { item.target = controller }
        keys = KeyDriver(window, menu: menus.main)
    }

    /// The table of contents' list, while the sidebar shows it.
    var list: NSOutlineView? {
        window.contentView?.descendants(NSOutlineView.self).first { $0.isTableOfContents && !$0.isHiddenOrHasHiddenAncestor }
    }
    /// Its rows, less its header.
    var rows: Int { max(0, (list?.numberOfRows ?? 0) - 1) }
    var listHasKeyboard: Bool { list.map { window.firstResponder === $0 } ?? false }
    var canvasHasKeyboard: Bool { window.firstResponder === canvas }
    var notes: [ShapeID] { editor.document.shapes.filter { $0.kind == StickyNote.kind }.map(\.id) }
    /// The panel header's title field (Titles' `TitleHeader`): the inspector shows a shape's panel.
    var titleField: NSTextField? {
        guard let content = window.contentView else { return nil }
        return content.descendants(NSTextField.self).first { field in
            field.isEditable && field.isInPanelHeader(of: content) && !field.isDescendant(of: canvas) && field.isInInspector(beside: canvas)
        }
    }

    /// Picks row `row` of the list (the header is 0) as a click does: the outline's own selection, with no
    /// key, the outline having the keyboard (a click gives it it first). A synthesized click doesn't reach
    /// a table in an unshown window.
    func click(row: Int) throws {
        let list = try require(list, "no list")
        window.settle()                 // a click comes as an event of its own, a turn after any key
        window.makeFirstResponder(list)
        list.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        window.settle()
    }

    /// Whether the whole shape is in the canvas's view.
    func isShown(_ id: ShapeID) -> Bool {
        guard let box = editor.document[id]?.box else { return false }
        let view = CGRect(origin: .zero, size: editor.viewportSize)
        return view.contains(editor.camera.toView(box.origin)) && view.contains(editor.camera.toView(CGPoint(x: box.maxX, y: box.maxY)))
    }
}

extension Chord {
    /// View › Focus Inspector's.
    static let focusInspector = Chord("i", [.command, .option])
    /// View › Focus Sidebar's.
    static let focusSidebar = Chord("s", [.command, .option])
}

extension NSView {
    /// In the detail panel's header, the top 44 points (`DetailStyle.headerHeight`) of the window's
    /// content, where the back button is.
    func isInPanelHeader(of host: NSView) -> Bool { convert(bounds, to: host).maxY <= 44 }

    /// In the inspector: shown, and after the canvas (the sidebar is before it).
    func isInInspector(beside canvas: NSView) -> Bool {
        guard !isHiddenOrHasHiddenAncestor else { return false }
        return convert(bounds, to: nil).midX >= canvas.convert(canvas.bounds, to: nil).maxX
    }
}

extension NSTableView {
    /// The table of contents' list, as opposed to a list in a shape's panel: the one
    /// whose first row is a section header, its board's name.
    var isTableOfContents: Bool {
        guard let outline = self as? NSOutlineView, outline.numberOfRows > 0 else { return false }
        return outline.delegate?.outlineView?(outline, isGroupItem: outline.item(atRow: 0) as Any) == true
    }
}

@MainActor let contentsPanelTests = Suite("Table of contents in the sidebar", [
    test("the sidebar is the table of contents: the notes, each arrow under its note; with nothing selected the inspector is hidden") {
        let w = try SampleWindow()
        w.window.spin { w.rows == 6 }
        expect(w.titleField == nil && w.backButton == nil, "nothing in the inspector")
        expect(w.editor.viewportSize.width > 0 && w.editor.viewportSize.height > 0, "the canvas knows its size: \(w.editor.viewportSize)")
        let list = try require(w.contents)
        expect(list.convert(list.bounds, to: nil).maxX <= w.canvas.convert(w.canvas.bounds, to: nil).minX, "the list is before the canvas")
    },
    test("selecting one shape shows its details in the inspector, several their header; the list keeps every row") {
        let w = try SampleWindow()
        w.window.spin { w.rows == 6 }
        w.editor.selection = w.notes[0]
        w.window.spin { w.titleField != nil }
        expectEqual(w.rows, 6)
        w.editor.selectedShapeIDs = [w.notes[1], w.notes[2]]
        w.window.spin { w.titleField == nil && w.backButton != nil }        // the header of two, with a way back
        let header = try require(w.editor.detailPanel).selectionSummary(of: [w.notes[1], w.notes[2]].compactMap { w.editor.document[$0] })
        expectEqual(header.title, "2 Shapes")
        expectEqual(w.rows, 6)
        expectEqual(w.contents?.selectedRowIndexes.count, 2, "the two selected rows")
        w.editor.selection = nil
        w.window.spin { w.backButton == nil }
        expectEqual(w.rows, 6)
    },
    test("from several shapes to none, the list keeps its rows and AppKit logs no reentrant update") {
        let w = try SampleWindow()
        w.window.spin { w.rows == 6 }
        w.editor.selectedShapeIDs = [w.notes[1], w.notes[2]]
        w.window.spin { w.contents?.selectedRowIndexes.count == 2 }
        let log = standardError {
            w.editor.selection = nil
            w.window.spin { w.contents?.selectedRowIndexes.isEmpty == true }
        }
        expect(!log.contains(tableReentrancyWarning), "AppKit logged: \(log)")
        expectEqual(w.rows, 6)
    },
    test("the pointer on a note on the canvas tints the note's row, and only that; leaving the canvas takes the tint away") {
        let w = try SampleWindow()
        w.window.spin { w.rows == 6 }
        let list = try require(w.contents)
        let note = w.notes[1]
        let row = list.rect(ofRow: 5)                          // under the header, the six notes front to back: the second is fifth
        let probe = CGPoint(x: row.maxX - 30, y: row.midY)     // past the text
        let plain = snapshot(list)
        let box = try require(w.editor.document[note]?.box)
        let point = w.canvas.convert(w.editor.camera.toView(CGPoint(x: box.midX, y: box.midY)), to: nil)
        w.canvas.mouseMoved(with: w.window.mouse(.mouseMoved, at: CGPoint(x: point.x, y: w.host.frame.height - point.y), clicks: 0, time: 1))
        expectEqual(w.editor.hovered, note)
        w.window.spin { pixel(snapshot(list), at: probe) != pixel(plain, at: probe) }
        let hovering = snapshot(list)
        expectEqual(changedPixels(plain, hovering, in: list.bounds) - changedPixels(plain, hovering, in: row), 0, "only the note's row changes")
        w.canvas.mouseExited(with: try require(NSEvent.enterExitEvent(with: .mouseExited, location: point, modifierFlags: [], timestamp: 2,
                                                                      windowNumber: w.window.windowNumber, context: nil, eventNumber: 0,
                                                                      trackingNumber: 0, userData: nil)))
        expectEqual(w.editor.hovered, nil)
        w.window.spin { changedPixels(plain, snapshot(list), in: row) == 0 }
    },
    test("a row shows its note in the inspector; the header's back button goes back to nothing selected, and the view as it was") {
        let w = try SampleWindow()
        w.window.spin { w.rows == 6 }
        expect(w.backButton == nil, "no inspector with nothing selected")
        let start = w.editor.camera
        try require(w.editor.tableOfContents).select([w.notes[1]])
        w.window.spin { w.titleField != nil && w.backButton != nil }    // the note's own panel, and a way back
        w.window.spin { w.editor.camera != start }                      // zooming to the note
        try require(w.backButton).performClick(nil)
        expectEqual(w.editor.selectedShapeIDs, [])
        w.window.spin { w.backButton == nil }
        w.window.spin { w.editor.camera == start }
        expectEqual(w.rows, 6)
        expect(!w.editor.canGoBack, "nothing further back")
    },
    test("the back button in several shapes' header goes back to one of them, and from it to nothing selected") {
        let w = try SampleWindow()
        w.window.spin { w.rows == 6 }
        w.editor.selection = w.notes[0]
        w.editor.selectedShapeIDs = [w.notes[1], w.notes[2]]
        w.window.spin { w.titleField == nil && w.backButton != nil }
        try require(w.backButton).performClick(nil)
        expectEqual(w.editor.selectedShapeIDs, [w.notes[0]])
        w.window.spin { w.titleField != nil && w.backButton != nil }
        try require(w.backButton).performClick(nil)
        w.window.spin { w.backButton == nil }
        expectEqual(w.editor.selectedShapeIDs, [])
    },
    test("a click on a row shows its note in the inspector and gives the canvas the keyboard, so Return opens it there") {
        let w = try SampleBoardWindow(sidebar: true)
        defer { w.board.close() }
        w.window.spin { w.rows == 6 }
        w.keys.send(.focusSidebar)
        w.window.spin { w.listHasKeyboard }
        try w.click(row: 1)
        let note = try require(w.editor.selection, "the click picks the first row")
        w.window.spin { w.canvasHasKeyboard && w.titleField != nil }
        expectEqual(w.rows, 6, "the list stays")
        w.keys.send(.return)
        w.window.spin { w.editor.editingShapeID == note }
    },
    test("⌥⌘S, then ↓ ↓ ↑ walk the rows: each selects and reveals its shape, shown in the inspector, the list keeps the keyboard, no shape moves and no step opens; ↓ then ↑ lands where it was") {
        let w = try SampleBoardWindow(sidebar: true)
        defer { w.board.close() }
        w.window.spin { w.rows == 6 }
        expect(w.canvasHasKeyboard)
        expect(w.keys.send(.focusSidebar).menuItem?.title == "Focus Sidebar", "the chord is View's item")
        w.window.spin { w.listHasKeyboard }
        let before = w.editor.file
        var walked: [ShapeID] = []
        for key in [Chord.down, .down, .up] {
            w.keys.send(key)
            let shape = try require(w.editor.selectedShapeIDs.count == 1 ? w.editor.selection : nil, "\(key) selects one shape")
            walked.append(shape)
            w.window.spin { w.isShown(shape) && w.titleField != nil }
            w.window.settle()
            expect(w.listHasKeyboard, "the list still has the keyboard after \(key): \(String(describing: w.window.firstResponder))")
            expectEqual(w.list?.selectedRow, walked.count == 2 ? 2 : 1, "the row the walk is on")
        }
        expect(walked[0] != walked[1], "↓ went on to the next row")
        expectEqual(walked[2], walked[0], "↑ came back to the row ↓ left")
        expectEqual(w.editor.file, before, "no shape moved")
        expect(!w.editor.canUndo, "and no step opened")
    },
    test("held, ↓ walks on a row a press: its repeats are the list's, and move no shape") {
        let w = try SampleBoardWindow(sidebar: true)
        defer { w.board.close() }
        w.window.spin { w.rows == 6 }
        w.keys.send(.focusSidebar)
        w.window.spin { w.listHasKeyboard }
        let before = w.editor.file
        w.keys.hold(.down, repeats: 3)
        w.window.settle()
        expectEqual(w.list?.selectedRow, 4, "four presses, four rows")
        expect(w.listHasKeyboard, "the list kept the keyboard")
        expectEqual(w.editor.file, before, "held on, the key moves nothing")
        expect(!w.editor.canUndo, "nor is it a step")
    },
    test("Tab and ⇧Tab step the rows as ↓ and ↑ do, and stay in the list") {
        let w = try SampleBoardWindow(sidebar: true)
        defer { w.board.close() }
        w.window.spin { w.rows == 6 }
        w.keys.send(.focusSidebar)
        w.window.spin { w.listHasKeyboard }
        w.keys.send(.tab)
        w.keys.send(.tab)
        w.window.settle()
        expectEqual(w.list?.selectedRow, 2)
        let second = w.editor.selection
        w.keys.send(.backTab)
        w.window.settle()
        expectEqual(w.list?.selectedRow, 1)
        w.keys.send(.tab)
        w.window.settle()
        expectEqual(w.editor.selection, second, "⇧Tab then Tab lands where it was")
        expect(w.listHasKeyboard, "the list kept the keyboard")
    },
    test("→ and ← open and close a row's disclosure triangle, its arrow under it, and leave the selection") {
        let w = try SampleBoardWindow(sidebar: true)
        defer { w.board.close() }
        w.window.spin { w.rows == 6 }
        w.keys.send(.focusSidebar)
        w.window.spin { w.listHasKeyboard }
        // Front to back: the sixth note, then the fifth, which an arrow starts from.
        w.keys.send(.down)
        w.keys.send(.down)
        w.window.settle()
        let note = try require(w.editor.selection)
        let list = try require(w.list)
        expect(!list.isItemExpanded(list.item(atRow: 2)), "collapsed to start")
        w.keys.send(.right)
        w.window.spin { w.rows == 7 }
        expect(list.isItemExpanded(list.item(atRow: 2)))
        w.keys.send(.left)
        w.window.spin { w.rows == 6 }
        expectEqual(w.editor.selectedShapeIDs, [note])
        expect(w.listHasKeyboard)
    },
    test("an arrow selected on the canvas opens its note's row and shows its own selected") {
        let w = try SampleBoardWindow(sidebar: true)
        defer { w.board.close() }
        w.window.spin { w.rows == 6 }
        let arrow = try require(w.editor.document.shapes.first { $0.kind == Arrow.kind }?.id)
        w.editor.selection = arrow
        w.window.spin { w.rows == 7 && w.list?.selectedRowIndexes.count == 1 }
        let list = try require(w.list)
        expectEqual((list.item(atRow: list.selectedRow)).map { list.parent(forItem: $0) != nil }, true, "the arrow's row, under its note's")
        expect(w.canvasHasKeyboard, "the canvas keeps the keyboard")
    },
    test("Escape gives the canvas the keyboard with the row's shape selected") {
        let w = try SampleBoardWindow(sidebar: true)
        defer { w.board.close() }
        w.window.spin { w.rows == 6 }
        w.keys.send(.focusSidebar)
        w.window.spin { w.listHasKeyboard }
        w.keys.send(.down)
        w.window.settle()
        let note = try require(w.editor.selection)
        w.window.spin { w.titleField != nil }
        w.keys.send(.escape)
        w.window.spin { w.canvasHasKeyboard }
        expectEqual(w.editor.selectedShapeIDs, [note])
        expect(w.titleField != nil && w.rows == 6, "the inspector and the list as they were")
    },
    test("Return on a row walked to opens its shape") {
        let w = try SampleBoardWindow(sidebar: true)
        defer { w.board.close() }
        w.window.spin { w.rows == 6 }
        w.keys.send(.focusSidebar)
        w.window.spin { w.listHasKeyboard }
        w.keys.send(.down)
        w.window.settle()
        let note = try require(w.editor.selection)
        w.keys.send(.return)
        w.window.spin { w.editor.editingShapeID == note }
        w.window.spin { !w.listHasKeyboard }
        expect(!w.listHasKeyboard, "the note's text has the keyboard: \(String(describing: w.window.firstResponder))")
    },
    test("⇧↓ adds the next row: the inspector shows the header of two, and the list keeps the keyboard") {
        let w = try SampleBoardWindow(sidebar: true)
        defer { w.board.close() }
        w.window.spin { w.rows == 6 }
        w.keys.send(.focusSidebar)
        w.window.spin { w.listHasKeyboard }
        w.keys.send(.down)
        w.window.settle()
        let list = try require(w.list)
        w.keys.send(Chord(Key.down, .shift))
        w.window.settle()
        expectEqual(w.editor.selectedShapeIDs.count, 2)
        expect(w.list === list, "the same list")
        expect(w.listHasKeyboard, "with the keyboard: \(String(describing: w.window.firstResponder))")
        expectEqual(w.rows, 6, "still every row")
        w.window.spin { w.titleField == nil }
        w.keys.send(.up)
        w.window.settle()
        expectEqual(w.editor.selectedShapeIDs.count, 1)
        expect(w.list === list && w.listHasKeyboard, "back to one, still walking")
    },
    test("View › Show Sidebar (⌃⌘S) hides and shows the list, and Focus Sidebar (⌥⌘S) shows a hidden one; hidden with the keyboard, the canvas takes it") {
        let w = try SampleBoardWindow(sidebar: true)
        defer { w.board.close() }
        w.window.spin { w.rows == 6 }
        let view = try require(w.menus.main.item(withTitle: "View")?.submenu)
        let titles = view.items.map(\.title)
        expectEqual(Array(titles.prefix(5)), ["Show Toolbar", "Show Sidebar", "Focus Sidebar", "Show Inspector", "Focus Inspector"])
        expect(!titles.contains("Show All Shapes"), "the list is never narrowed")
        w.keys.send(.focusSidebar)
        w.window.spin { w.listHasKeyboard }
        // Found by its action: the menu bar's validation titles it for what it does now.
        let toggle = try require(view.items.first { $0.action == #selector(BoardWindowController.toggleSidebarShown(_:)) })
        expect(w.controller.validateMenuItem(toggle))
        expectEqual(toggle.title, "Hide Sidebar", "titled for what it does now")
        expectEqual(w.keys.send(Chord("s", [.command, .control])).menuItem?.action, #selector(BoardWindowController.toggleSidebarShown(_:)))
        w.window.spin { w.list == nil && w.canvasHasKeyboard }
        expect(!w.board.viewState.showsSidebar)
        expect(w.controller.validateMenuItem(toggle))
        expectEqual(toggle.title, "Show Sidebar")
        w.keys.send(.focusSidebar)
        w.window.spin { w.listHasKeyboard }
        expect(w.board.viewState.showsSidebar, "Focus Sidebar showed it")
    },
    test("Escape in the list gives the keyboard back to the canvas, where tool shortcuts work again") {
        let w = try SampleWindow()
        w.window.spin { w.rows == 6 }
        w.window.makeFirstResponder(try require(w.contents))
        w.window.settle()
        expect(!w.canvasHasKeyboard)
        w.window.pressEscape()
        w.window.spin { w.canvasHasKeyboard }
        w.window.press("n")
        expectEqual(w.editor.currentToolID, ToolID(placing: "sticky-note"))
    },
    test("⌘↑ and ⌘↩ in the list give the canvas the keyboard with the row's shape selected, as Escape does; ⌥Tab and ⌥⇧Tab, into parts a row has none of, do nothing") {
        let w = try SampleBoardWindow(sidebar: true)
        defer { w.board.close() }
        w.window.spin { w.rows == 6 }
        for key in [Chord(Key.up, .command), .commandReturn] {
            w.editor.selection = nil
            w.window.makeFirstResponder(w.canvas)
            w.window.spin { w.list != nil && w.titleField == nil }
            w.keys.send(.focusSidebar)
            w.window.spin { w.listHasKeyboard }
            w.keys.send(.down)
            w.window.settle()
            let note = try require(w.editor.selection)
            for part in [Chord.optionTab, .optionBackTab] {
                w.keys.send(part)
                w.window.settle()
                expect(w.listHasKeyboard, "\(part) leaves the list as it was")
                expectEqual(w.editor.selectedShapeIDs, [note])
            }
            w.keys.send(key)
            w.window.spin { w.canvasHasKeyboard }
            expectEqual(w.editor.selectedShapeIDs, [note], "\(key) keeps the row's shape selected")
            expectEqual(w.editor.editingShapeID, nil, "and opens nothing")
        }
    },
])

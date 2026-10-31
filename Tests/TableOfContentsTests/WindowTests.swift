import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Selection
import SwiftUI
import TableOfContents
import TestKit

/// The list's width in the window, about the sidebar's.
let listWidth: CGFloat = 260

/// The table of contents in an NSHostingView beside a canvas view, in an unshown window
/// (CanvasTesting drives it: `spin`, `press`). The editor keeps real time, so SwiftUI's updates and
/// the hand-back land while the main run loop runs.
@MainActor
final class ContentsWindow {
    let editor: CanvasEditor
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
    let canvas: CanvasView
    private(set) var hosting: NSView!
    /// How often the list handed the keyboard back.
    private(set) var exits = 0

    /// The header's heading is the editor's plugins' (BoardTests' `headingPlugin`).
    init(_ editor: CanvasEditor) {
        self.editor = editor
        canvas = CanvasView(editor: editor)
        canvas.frame = CGRect(x: listWidth, y: 0, width: 1000 - listWidth, height: 700)
        // Weak: the list may hand the keyboard back after the test let this go.
        let contents = TableOfContentsView(editor: editor, onExit: { [weak self] in
            guard let self else { return }
            exits += 1
            window.makeFirstResponder(canvas)
        })
        hosting = NSHostingView(rootView: contents)
        hosting.frame = CGRect(x: 0, y: 0, width: listWidth, height: 700)
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 1000, height: 700))
        root.addSubview(canvas)
        root.addSubview(hosting)
        window.contentView = root
        window.settle()
    }

    var table: NSTableView? { hosting.descendants(NSTableView.self).first }
    /// The list's rows, less its header.
    var rows: Int { max(0, (table?.numberOfRows ?? 0) - 1) }
    var canvasHasKeyboard: Bool { window.firstResponder === canvas }
    /// The buttons in the list's header (its first row).
    var headerButtons: [NSButton] {
        guard let table, table.numberOfRows > 0 else { return [] }
        let header = table.rect(ofRow: 0)
        return table.descendants(NSButton.self).filter { header.contains($0.convert($0.bounds, to: table)) }
    }

    /// Gives the list the keyboard, as View ▸ Focus Sidebar does.
    func focusList() throws {
        let table = try require(table, "no list")
        window.makeFirstResponder(table)
        window.settle()
    }

    /// Picks row `row` (the header is 0) as a click does: the outline's own selection, with no key, the
    /// outline having the keyboard (a click gives it it first). A synthesized click doesn't reach a table
    /// in an unshown window.
    func click(row: Int) throws {
        let table = try require(table, "no list")
        window.settle()                 // a click comes as an event of its own, a turn after any key
        window.makeFirstResponder(table)
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        window.settle()
    }
}

@MainActor let windowTests = Suite("Table of contents in a window", [
    test("an empty board says so, and has no list") {
        let w = ContentsWindow(try contentsEditor(scheduler: TaskScheduler()))
        expect(w.table == nil)
        w.editor.add(Widget(name: "First"))
        w.window.spin { w.table != nil }
        expectEqual(w.rows, 1)    },
    test("one row per shape, under a header; selecting on the canvas keeps every row, the selected ones selected") {
        let editor = try contentsEditor(scheduler: TaskScheduler())
        let (a, b, _) = threeWidgets(editor)
        let w = ContentsWindow(editor)
        w.window.spin { w.rows == 3 }
        editor.selectedShapeIDs = [b]
        w.window.spin { w.table?.selectedRowIndexes == [2] }        // front to back: C, B, A, under the header
        expectEqual(w.rows, 3)
        editor.selectedShapeIDs = [a, b]
        w.window.spin { w.table?.selectedRowIndexes == [2, 3] }
        editor.selectedShapeIDs = []
        w.window.spin { w.table?.selectedRowIndexes.isEmpty == true }
        expectEqual(w.rows, 3)
    },
    test("the selection changing on the canvas keeps the list's rows and its keyboard, and AppKit logs no reentrant update") {
        let editor = try contentsEditor(scheduler: TaskScheduler())
        let (a, b, _) = threeWidgets(editor)
        let w = ContentsWindow(editor)
        w.window.spin { w.rows == 3 }
        try w.focusList()
        let rows = try require(w.outline).rows(in: try require(w.outline).visibleRect)
        let log = standardError {
            editor.selectedShapeIDs = [b]
            w.window.spin { w.table?.selectedRowIndexes == [2] }
            editor.selectedShapeIDs = []
            w.window.spin { w.table?.selectedRowIndexes.isEmpty == true }
            editor.selectedShapeIDs = [a]
            w.window.spin { w.table?.selectedRowIndexes == [3] }
        }
        expect(!log.contains(tableReentrancyWarning), "AppKit logged: \(log)")
        expectEqual(try require(w.outline).rows(in: try require(w.outline).visibleRect), rows, "the same rows in view")
        expect(w.window.firstResponder === w.table, "the list keeps the keyboard")
    },
    test("a commit that brings rows in at several places at once brings each in where it goes: AppKit logs no reentrant update, the list keeps the keyboard") {
        let editor = try contentsEditor(scheduler: TaskScheduler())
        let ids = widgets(30, in: editor)
        let w = ContentsWindow(editor)
        w.window.spin { w.rows == 30 }
        try w.focusList()
        let log = standardError {
            editor.transact { transaction in
                transaction.insert(ShapeRecord(Pin("early", on: ids[1])))       // nested under the second row
                transaction.insert(ShapeRecord(Pin("late", on: ids[25])))       // and under the twenty-sixth
                transaction.insert(ShapeRecord(Widget(name: "New")))            // and at the end
            }
            w.window.spin { w.rows == 31 }
            w.window.settle()
        }
        expect(!log.contains(tableReentrancyWarning), "AppKit logged: \(log)")
        expectEqual(editor.contents.entries.filter { $0.children != nil }.map { $0.label?.text }, ["Widget 1", "Widget 25"])
        expect(w.window.firstResponder === w.table, "the rows are new, the list isn't: it keeps the keyboard")
        // Rows coming out from under a shape deleted, to their places at the top, far apart.
        editor.transact { $0.insert(ShapeRecord(Pin("later", on: ids[1]))) }
        w.window.spin { editor.contents.entries[1].children?.count == 2 }
        let out = standardError {
            editor.transact { $0.delete([ids[1]]) }
            w.window.spin { w.rows == 32 }
            w.window.settle()
        }
        expect(!out.contains(tableReentrancyWarning), "AppKit logged: \(out)")
        expectEqual(editor.contents.entries.map { $0.label?.text }.filter { $0?.hasPrefix("Widget") == false }, ["early", "New", "later"], "late stays under its widget")
    },
    test("on a list of more than 200 rows, a commit that brings rows in at several places logs no reentrant update") {
        let editor = try contentsEditor(scheduler: TaskScheduler())
        let ids = widgets(250, in: editor)
        let w = ContentsWindow(editor)
        w.window.spin { w.rows == 250 }
        w.window.settle()
        let log = standardError {
            editor.transact { transaction in
                transaction.insert(ShapeRecord(Pin("early", on: ids[1])))
                transaction.insert(ShapeRecord(Pin("late", on: ids[200])))
                transaction.insert(ShapeRecord(Widget(name: "New")))
            }
            w.window.spin { w.rows == 251 }
            w.window.settle()
        }
        // Rows all of one height: AppKit measures none as they come in around those kept.
        expect(!log.contains(tableReentrancyWarning), "AppKit logged: \(log)")
    },
    test("rows moved or replaced let go of no hover but one the pointer on them set: a shape hovered on the canvas stays hovered") {
        let editor = try contentsEditor(scheduler: TaskScheduler())
        let ids = widgets(30, in: editor)
        let w = ContentsWindow(editor)
        w.window.spin { w.rows == 30 }
        w.window.settle()
        editor.hovered = ids[25]                // the pointer on its shape, on the canvas; its row in view
        editor.transact { transaction in
            transaction.insert(ShapeRecord(Pin("early", on: ids[1])))
            transaction.insert(ShapeRecord(Pin("late", on: ids[25])))
            transaction.insert(ShapeRecord(Widget(name: "New")))
        }
        w.window.spin { w.rows == 31 }
        w.window.settle()
        expectEqual(editor.hovered, ids[25], "rows brought in around it")
        editor.transact { $0.move(ids[25], above: ids[29]) }        // its row out, and in again above ids[29]'s
        w.window.settle()
        w.window.settle()
        expectEqual(editor.hovered, ids[25], "its row moved")
        editor.transact { $0.delete(Set(ids[20..<25])) }          // the rows around it taken out
        w.window.spin { w.rows == 26 }
        w.window.settle()
        expectEqual(editor.hovered, ids[25], "the rows around it gone")
    },
    test("a commit that brings rows in at one place, or only changes rows, keeps the rows it has") {
        let editor = try contentsEditor(scheduler: TaskScheduler())
        let ids = widgets(30, in: editor)
        let w = ContentsWindow(editor)
        w.window.spin { w.rows == 30 }
        w.window.settle()
        /// How many rows the list redraws for `change`, once it has, and a few more turns have passed.
        @MainActor func redrawn(_ change: () -> Void) -> Int {
            let before = editor.contents.rowsRedrawn
            change()
            w.window.spin { editor.contents.rowsRedrawn > before }
            w.window.settle()
            return editor.contents.rowsRedrawn - before
        }
        let one = redrawn { editor.transact { $0.insert(ShapeRecord(Pin("one", on: ids[10]))) } }
        expect(one < 10, "a row nested under one: \(one) of 31 rows redrawn")
        let two = redrawn {
            editor.transact { transaction in
                transaction.insert(ShapeRecord(Widget(name: "New")))
                transaction.insert(ShapeRecord(Widget(name: "Newer")))
            }
        }
        expect(two < 10, "two rows in a run at the end: \(two) of 33 rows redrawn")
        let renamed = redrawn { editor.transact { $0.update(ids[25], as: Widget.self) { $0.props.name = "Renamed" } } }
        expect(renamed < 10, "a row changed: \(renamed) of 33 rows redrawn")
    },
    test("a long list makes views for the rows in view alone, first shown, replaced and walked to its end") {
        let editor = try contentsEditor(scheduler: TaskScheduler())
        let ids = widgets(5000, in: editor)
        let contents = editor.contents
        let before = contents.rowsRedrawn
        let w = ContentsWindow(editor)
        w.window.spin { w.rows == ids.count }
        w.window.settle()
        let outline = try require(w.outline)
        let inView = outline.rows(in: outline.visibleRect).length - 1         // less the header
        let shown = contents.rowsRedrawn - before
        expect(shown >= inView && shown < 4 * inView, "first shown: \(shown) rows drawn of \(ids.count), \(inView) in view")
        let replacing = contents.rowsRedrawn
        editor.transact { $0.delete(Set(ids.suffix(2500))) }      // too many rows gone to follow: listed afresh, shown whole
        w.window.spin { w.rows == 2500 }
        w.window.settle()
        let replaced = contents.rowsRedrawn - replacing
        expect(replaced >= inView && replaced < 4 * inView, "replaced: \(replaced) rows drawn of 2500")
        let selecting = contents.rowsRedrawn
        editor.contents.select([ids[0]])                            // the last row, selected and scrolled to: the rows there drawn
        w.window.spin { w.table?.selectedRow == 2500 }
        w.window.settle()
        let drawn = contents.rowsRedrawn - selecting
        expect(drawn < 2 * inView, "\(drawn) rows drawn for a selection out of view, scrolled to")
        expect(outline.visibleRect.intersects(outline.rect(ofRow: 2500)), "the row in view")
    },
    test("the list shows the selection as selected rows") {
        let editor = try contentsEditor(scheduler: TaskScheduler())
        let (_, b, _) = threeWidgets(editor)
        let w = ContentsWindow(editor)
        w.window.spin { w.rows == 3 }
        editor.contents.select([b])             // as a click on its row does: the list stays whole
        w.window.spin { w.table?.selectedRowIndexes.count == 1 }
        expectEqual(w.rows, 3)
        expectEqual(w.table?.selectedRow, 2, "B, under the header")
    },
    test("the canvas view tells the editor its size") {
        let w = ContentsWindow(try contentsEditor(scheduler: TaskScheduler()))
        expectEqual(w.editor.viewportSize, CGSize(width: 1000 - listWidth, height: 700))
        w.canvas.setFrameSize(CGSize(width: 600, height: 500))
        expectEqual(w.editor.viewportSize, CGSize(width: 600, height: 500))
    },
    test("Escape in the list gives the keyboard back to the canvas") {
        let editor = try contentsEditor(scheduler: TaskScheduler())
        _ = threeWidgets(editor)
        let w = ContentsWindow(editor)
        w.window.spin { w.rows == 3 }
        try w.focusList()
        expect(!w.canvasHasKeyboard)
        w.window.pressEscape()
        w.window.spin { w.canvasHasKeyboard }
        expectEqual(w.exits, 1)
    },
    test("Delete in the list deletes the selected shapes") {
        let editor = try contentsEditor(scheduler: TaskScheduler())
        let (a, b, c) = threeWidgets(editor)
        let w = ContentsWindow(editor)
        w.window.spin { w.rows == 3 }
        editor.contents.select([b])
        w.window.spin { w.table?.selectedRowIndexes.count == 1 }
        try w.focusList()
        w.window.pressDelete()
        w.window.spin { editor.document[b] == nil }
        expectEqual(editor.document.shapes.map(\.id), [a, c])
        expectEqual(editor.undoHistory.undoName, "Delete", "the .delete command's step, as on the canvas")
        editor.undo()
        expectEqual(editor.document.shapes.map(\.id), [a, b, c])
        expectEqual(editor.selectedShapeIDs, [b])
    },
    test("hiding the list while it has the keyboard gives the keyboard back to the canvas") {
        let editor = try contentsEditor(scheduler: TaskScheduler())
        _ = threeWidgets(editor)
        let w = ContentsWindow(editor)
        w.window.spin { w.rows == 3 }
        try w.focusList()
        w.hosting.isHidden = true
        w.window.spin { w.canvasHasKeyboard }
        expectEqual(w.exits, 1)
    },
    test("a click on a row selects its shape and gives the canvas the keyboard; a key walks the rows and keeps it in the list") {
        let editor = try contentsEditor(scheduler: TaskScheduler())
        let (a, b, c) = threeWidgets(editor)
        let w = ContentsWindow(editor)
        w.window.spin { w.rows == 3 }
        try w.focusList()
        let keys = KeyDriver(w.window)
        keys.send(.down)
        expectEqual(editor.selectedShapeIDs, [c], "front to back: C first")
        expect(w.window.firstResponder === w.table, "↓ walks the rows, in the list")
        try w.click(row: 2)
        expectEqual(editor.selectedShapeIDs, [b])
        w.window.spin { w.canvasHasKeyboard }
        expectEqual(w.exits, 1, "the click handed the keyboard to the canvas")
        try w.focusList()
        keys.send(.down)
        expectEqual(editor.selectedShapeIDs, [a])
        expect(w.window.firstResponder === w.table, "keys keep it")
    },
    test("a selection made on the canvas opens the rows it's nested under and scrolls to it; one made in the list moves nothing") {
        let editor = try contentsEditor(scheduler: TaskScheduler())
        let ids = widgets(60, in: editor)
        let pin = editor.add(Pin("Deep", on: ids[1]))           // under the second widget's row, near the list's end
        let w = ContentsWindow(editor)
        w.window.spin { w.rows == 60 }
        w.window.settle()
        let outline = try require(w.outline)
        let entry = try require(editor.contents.entries.first { $0.id == ids[1] })
        expect(!editor.contents.isExpanded(entry), "a widget's pins are folded away to start with")
        let top = outline.visibleRect
        editor.selectedShapeIDs = [pin]
        w.window.spin { outline.selectedRowIndexes.count == 1 }
        let row = outline.selectedRow
        expectEqual((outline.item(atRow: row) as AnyObject?).flatMap { outline.parent(forItem: $0) as AnyObject? } === outline.item(atRow: row - 1) as AnyObject?, true,
                    "its row shows, under the widget's")
        expect(editor.contents.isExpanded(entry), "the widget's row opened, and stays open")
        expect(outline.visibleRect.intersects(outline.rect(ofRow: row)), "scrolled to")
        expect(outline.visibleRect != top)
        // A row picked in the list stays where it is: the list is where the person is.
        outline.scroll(CGPoint(x: 0, y: 0))
        w.window.settle()
        let shown = outline.visibleRect
        try w.click(row: 2)
        expectEqual(editor.selectedShapeIDs.count, 1)
        expectEqual(outline.visibleRect, shown, "a row picked in the list scrolls nothing")
        // Several selected on the canvas open nothing (⌘A would open every row): only one does.
        editor.contents.setExpanded(entry, false)
        w.window.settle()
        editor.selectedShapeIDs = [pin, ids[5]]
        w.window.spin { outline.selectedRowIndexes.count == 1 }       // the pin's row is folded away: only ids[5]'s shows
        expect(!editor.contents.isExpanded(entry), "two selected: nothing opened")
    },
    test("Tab and ⇧Tab step the rows as ↓ and ↑ do, and keep the keyboard in the list") {
        let editor = try contentsEditor(scheduler: TaskScheduler())
        let (a, b, c) = threeWidgets(editor)
        let w = ContentsWindow(editor)
        w.window.spin { w.rows == 3 }
        try w.focusList()
        let keys = KeyDriver(w.window)
        var picked: [[ShapeID]] = []
        for chord in [Chord.tab, .tab, .tab, .tab, .backTab, .backTab, .backTab] {
            keys.send(chord)
            picked.append(editor.selectedShapeIDs)
            expect(w.window.firstResponder === w.table, "\(chord) stays in the list: \(String(describing: w.window.firstResponder))")
        }
        // Front to back: C, B, A; stopping at the ends, as the arrows do.
        expectEqual(picked, [[c], [b], [a], [a], [b], [c], [c]])
    },
    test("Caps Lock on, Tab and ⇧Tab still step the rows and keep the keyboard in the list") {
        let editor = try contentsEditor(scheduler: TaskScheduler())
        let (a, b, c) = threeWidgets(editor)
        let w = ContentsWindow(editor)
        w.window.spin { w.rows == 3 }
        try w.focusList()
        let keys = KeyDriver(w.window)
        var picked: [[ShapeID]] = []
        for chord in [Chord.tab.capsLock, .tab.capsLock, .backTab.capsLock] {
            keys.send(chord)
            picked.append(editor.selectedShapeIDs)
            expect(w.window.firstResponder === w.table, "\(chord) stays in the list: \(String(describing: w.window.firstResponder))")
        }
        expectEqual(picked, [[c], [b], [c]])
        _ = a
    },
    test("rows say their kind after their name, a stand-in \"Alias\"; each disclosure triangle is named by its row") {
        let editor = try contentsEditor(scheduler: TaskScheduler())
        let (a, _, _) = threeWidgets(editor)
        editor.add(Pin("P", on: a))
        let unnamed = editor.add(Widget(CGRect(x: 600, y: 0, width: 100, height: 60), name: ""))
        editor.add(Pin("Q", on: unnamed))
        let w = ContentsWindow(editor)
        w.window.spin { w.rows == 4 }
        let entries = editor.contents.entries
        let widget = try require(entries.first { $0.id == a })
        expectEqual(widget.kindName, "Widget")
        expectEqual(widget.label?.spokenValue(kind: widget.kindName), "Widget")
        expectEqual(ContentsLabel("Checkout", standsIn: true).spokenValue(kind: "Reference"), "Alias", "a stand-in's name is its shape's")
        expectEqual(widget.spokenName, "A")
        expectEqual(entries.first { $0.id == unnamed }?.spokenName, "Unnamed", "no name: the placeholder")
        // SwiftUI's accessibility tree isn't built in an unshown window, but the table's is AppKit's.
        @MainActor func triangles() -> [String?] {
            (w.table?.descendants(NSButton.self) ?? []).filter { $0.identifier == NSOutlineView.disclosureButtonIdentifier }
                .sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
                .map { $0.cell.map(AccessibilityProbe.label(of:)) ?? nil }
        }
        w.window.spin { triangles() == ["Unnamed", "A"] }
        try w.expand(1)
        w.window.spin { w.rows == 5 }
        w.window.settle()
        expectEqual(triangles(), ["Unnamed", "A"], "turned, still named")
        editor.add(Widget(CGRect(x: 800, y: 0, width: 100, height: 60), name: "D"))
        w.window.spin { w.rows == 6 }
        w.window.settle()
        expectEqual(triangles(), ["Unnamed", "A"], "rows replaced or moved, each still its own row's")
    },
])

import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Selection
import SwiftUI
import TableOfContents
import TestKit

/// The list's width in the window, about the detail panel's.
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

    /// Gives the list the keyboard, as a click on a row does.
    func focusList() throws {
        let table = try require(table, "no list")
        window.makeFirstResponder(table)
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
    test("one row per shape, under a header; selecting on the canvas lists just the selection") {
        let editor = try contentsEditor(scheduler: TaskScheduler())
        let (a, b, _) = threeWidgets(editor)
        let w = ContentsWindow(editor)
        w.window.spin { w.rows == 3 }
        editor.selectedShapeIDs = [b]
        w.window.spin { w.rows == 1 }
        editor.selectedShapeIDs = [a, b]
        w.window.spin { w.rows == 2 }
        editor.selectedShapeIDs = []
        w.window.spin { w.rows == 3 }
    },
    test("a change of what's listed brings the new rows in as one run: the list keeps the keyboard and the selection, and AppKit logs no reentrant update") {
        let editor = try contentsEditor(scheduler: TaskScheduler())
        let (_, b, _) = threeWidgets(editor)
        let w = ContentsWindow(editor)
        w.window.spin { w.rows == 3 }
        let log = try standardError {
            editor.selectedShapeIDs = [b]
            w.window.spin { w.rows == 1 }
            editor.selectedShapeIDs = []            // A's row and C's come back on either side of B's
            w.window.spin { w.rows == 3 }
            editor.selectedShapeIDs = [b]
            w.window.spin { w.rows == 1 }
            try w.focusList()
            editor.contents.showAll()
            w.window.spin { w.rows == 3 && w.table?.selectedRowIndexes == [2] }     // B's new row, under the header and A's
        }
        expect(!log.contains(tableReentrancyWarning), "AppKit logged: \(log)")
        expectEqual(editor.selectedShapeIDs, [b], "Show All keeps the selection")
        expect(w.window.firstResponder === w.table, "the rows are new, the list isn't: it keeps the keyboard")
    },
    test("a commit that brings rows in at several places at once replaces the rows: AppKit logs no reentrant update, the list keeps the keyboard") {
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
        let w = ContentsWindow(editor)          // AppKit logs one first showing 200 rows or more, whatever the list does
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
        // Rows brought in around those kept, AppKit logs one here too: replacing them is what it takes.
        expect(!log.contains(tableReentrancyWarning), "AppKit logged: \(log)")
    },
    test("rows replaced after a commit let go of no hover but one the pointer on them set: a shape hovered on the canvas stays hovered") {
        let editor = try contentsEditor(scheduler: TaskScheduler())
        let ids = widgets(30, in: editor)
        let w = ContentsWindow(editor)
        w.window.spin { w.rows == 30 }
        w.window.settle()
        editor.hovered = ids[5]                 // the pointer on its shape, on the canvas
        let before = editor.contents.rowsRedrawn
        editor.transact { transaction in
            transaction.insert(ShapeRecord(Pin("early", on: ids[1])))
            transaction.insert(ShapeRecord(Pin("late", on: ids[25])))
            transaction.insert(ShapeRecord(Widget(name: "New")))
        }
        w.window.spin { w.rows == 31 && editor.contents.rowsRedrawn >= before + 31 }
        w.window.settle()
        expectEqual(editor.hovered, ids[5])
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
        let renamed = redrawn { editor.transact { $0.update(ids[3], as: Widget.self) { $0.props.name = "Renamed" } } }
        expect(renamed < 10, "a row changed: \(renamed) of 33 rows redrawn")
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
])

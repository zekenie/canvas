import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Selection
import SwiftUI
import TableOfContents
import TestKit

// Shapes in containers in a window: the list's rows nested under their containers, open from the
// start, each level its own disclosure triangle, and AppKit never logging a reentrant update.

extension ContentsWindow {
    /// Whether the row at `row` (the header is 0) shows the rows nested under it.
    func isExpanded(_ row: Int) throws -> Bool {
        let outline = try require(outline, "no outline")
        return outline.isItemExpanded(outline.item(atRow: row))
    }

    /// Closes the row at `row`'s disclosure triangle, as a click on it does.
    func collapse(_ row: Int) throws {
        let outline = try require(outline, "no outline")
        outline.collapseItem(outline.item(atRow: row))
        window.settle()
    }
}

@MainActor let containerWindowTests = Suite("Table of contents: shapes in containers, in a window", [
    test("a container's row shows expanded, as deep as containers nest, with no reentrant update; another row's nested rows wait behind its triangle") {
        let editor = try corralEditor(scheduler: TaskScheduler())
        let nest = NestedCorrals(in: editor)
        editor.add(Pin("on C", on: nest.c))
        var w: ContentsWindow?
        let log = standardError {
            w = ContentsWindow(editor)
            w?.window.spin { w?.rows == 5 }
            w?.window.settle()
        }
        let window = try require(w)
        expect(!log.contains(tableReentrancyWarning), "AppKit logged: \(log)")
        // Front to back: C, its pin folded under it; then the outer corral, the inner corral, B, and A.
        expectEqual(try [1, 2, 3, 4, 5].map(window.isExpandable), [true, true, true, false, false])
        expectEqual(try [1, 2, 3].map(window.isExpanded), [false, true, true])
        try window.expand(1)
        window.window.spin { window.rows == 6 }
    },
    test("each level collapses on its own, and the state hears it: a collapsed row stays so when the rows are replaced, and opens onto its rows as they were") {
        let editor = try corralEditor(scheduler: TaskScheduler())
        let nest = NestedCorrals(in: editor)
        let w = ContentsWindow(editor)
        w.window.spin { w.rows == 5 }
        let log = try standardError {
            try w.collapse(3)
            w.window.spin { w.rows == 4 }
            expect(!editor.contents.isExpanded(try require(editor.contents.entry(nest.inner))))
            expect(try w.isExpanded(2), "the outer corral stays open")
            try w.collapse(2)
            w.window.spin { w.rows == 2 }
            expect(!editor.contents.isExpanded(try require(editor.contents.entry(nest.outer))))
            editor.selectedShapeIDs = [nest.outer, nest.c]          // other rows, listed again
            w.window.spin { w.rows == 2 }
            editor.selectedShapeIDs = []
            w.window.spin { w.rows == 2 }
            w.window.settle()
            expect(!(try w.isExpanded(2)), "still collapsed")
            try w.expand(2)
            w.window.spin { w.rows == 4 }
            expect(!(try w.isExpanded(3)), "the inner corral as it was left")
            expect(editor.contents.isExpanded(try require(editor.contents.entry(nest.outer))))
        }
        expect(!log.contains(tableReentrancyWarning), "AppKit logged: \(log)")
    },
    test("a shape joining an empty container opens its row onto it, and a container deleted lets what it held out as one run, with no reentrant update") {
        let editor = try corralEditor(scheduler: TaskScheduler())
        let nest = NestedCorrals(in: editor)
        let empty = editor.add(Corral(CGRect(x: 2000, y: 0, width: 400, height: 300)))
        _ = widgets(10, in: editor)
        let w = ContentsWindow(editor)
        w.window.spin { w.rows == 16 }
        w.window.settle()
        let log = standardError {
            editor.put([nest.c], in: empty)                     // C, raised above the empty corral, under it
            w.window.spin { editor.contents.entry(empty)?.children?.count == 1 && w.rows == 16 }
            w.window.settle()
            editor.transact { $0.delete([nest.inner]) }          // B out into the outer corral
            w.window.spin { w.rows == 15 }
            w.window.settle()
            editor.transact { $0.delete([nest.outer]) }          // A and B out onto the board
            w.window.spin { w.rows == 14 }
            w.window.settle()
        }
        expect(!log.contains(tableReentrancyWarning), "AppKit logged: \(log)")
        expect(try w.isExpanded(11), "the corral C joined (under the ten widgets, over B and A), open from the start")
        expectEqual(editor.contents.entries.tree, listedAfresh(editor))
    },
    test("a shape joining an open container, or leaving it, moves its row with no reentrant update") {
        let editor = try corralEditor(scheduler: TaskScheduler())
        let nest = NestedCorrals(in: editor)
        let more = widgets(20, in: editor)
        let w = ContentsWindow(editor)
        w.window.spin { w.rows == 25 }
        w.window.settle()
        let log = standardError {
            editor.put([more[10]], in: nest.inner)
            w.window.spin { editor.contents.entry(nest.inner)?.children?.count == 2 }
            w.window.settle()
            editor.put([nest.c], in: nest.outer)
            w.window.spin { editor.contents.entry(nest.outer)?.children?.count == 3 }
            w.window.settle()
            editor.put([more[10], nest.c], in: nil)
            w.window.spin { editor.contents.entries.count == 22 }
            w.window.settle()
        }
        expect(!log.contains(tableReentrancyWarning), "AppKit logged: \(log)")
        expectEqual(w.rows, 25)
    },
    test("a commit that brings rows in under two containers replaces the rows, with no reentrant update, the containers still open") {
        let editor = try corralEditor(scheduler: TaskScheduler())
        _ = widgets(20, in: editor)
        let nest = NestedCorrals(in: editor)            // in front, so at the top: a row out of view opens only once it's in view
        let w = ContentsWindow(editor)
        w.window.spin { w.rows == 25 }
        w.window.settle()
        try w.focusList()
        let log = standardError {
            editor.transact { transaction in
                let first = ShapeRecord(Widget(name: "In the outer")), second = ShapeRecord(Widget(name: "In the inner"))
                transaction.insert(first)
                transaction.insert(second)
                transaction.setContainer(first.id, to: nest.outer)
                transaction.setContainer(second.id, to: nest.inner)
            }
            w.window.spin { w.rows == 27 }
            w.window.settle()
        }
        expect(!log.contains(tableReentrancyWarning), "AppKit logged: \(log)")
        expect(try w.isExpanded(2) && w.isExpanded(4), "both corrals open: C; the outer corral, its new widget on top, the inner one")
        expect(w.window.firstResponder === w.table, "the rows are new, the list isn't: it keeps the keyboard")
    },
    test("a board's outline in its own panel shows a container's rows open from the start, each level closing on its own") {
        let editor = try corralEditor(scheduler: TaskScheduler())
        _ = NestedCorrals(in: editor)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: ContentsOutline(editor: editor, board: .root, maxHeight: 360) { _ in })
        hosting.frame = CGRect(x: 0, y: 0, width: 300, height: 400)
        window.contentView = hosting
        /// Its buttons, top to bottom, then left to right: each row's, after its triangle if it has one.
        @MainActor func buttons() -> [NSButton] {
            hosting.descendants(NSButton.self).map { ($0, hosting.convert($0.bounds, from: $0)) }
                .sorted { (hosting.isFlipped ? $0.1.minY : -$0.1.maxY, $0.1.minX) < (hosting.isFlipped ? $1.1.minY : -$1.1.maxY, $1.1.minX) }
                .map(\.0)
        }
        // Front to back: C; the outer corral's triangle and row, the inner corral's triangle and row, B; A.
        window.spin { buttons().count == 7 }
        buttons()[3].performClick(nil)                      // the inner corral closes
        window.spin { buttons().count == 6 }
        buttons()[1].performClick(nil)                      // the outer
        window.spin { buttons().count == 3 }
        buttons()[1].performClick(nil)
        window.spin { buttons().count == 6 }                // the inner as it was left: closed
    },
    test("selecting a row nested in a container selects its shape") {
        let editor = try corralEditor(scheduler: TaskScheduler())
        let nest = NestedCorrals(in: editor)
        let w = ContentsWindow(editor)
        w.window.spin { w.rows == 5 }
        try require(w.table).selectRowIndexes([4], byExtendingSelection: false)      // B, two corrals down
        w.window.spin { editor.selectedShapeIDs == [nest.b] }
        expectEqual(w.rows, 5, "what's listed stays")
        editor.contents.select([nest.a])                // as a click on its row does
        w.window.spin { w.table?.selectedRow == 5 }
    },
])

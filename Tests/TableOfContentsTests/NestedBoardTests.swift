import AppKit
import Canvas
import CanvasTesting
import CoreGraphics
import Selection
import TableOfContents
import TestKit

// A board under its owner's row: a shape that owns a board (`nestedBoard`) opens onto that board's
// rows in the list, as a shape opens onto the rows nested under it, read only once it's expanded.

/// On the root: widget A, pocket P with a pin on it, and an empty pocket E. On P's board: widget C
/// with a pin on it, widget D, and pocket Q, whose board holds widget F.
struct PocketsInPockets {
    let a = ShapeID(), p = ShapeID(), e = ShapeID(), c = ShapeID(), d = ShapeID(), q = ShapeID(), f = ShapeID()
    var pBoard: BoardID { BoardID(owner: p) }
    var qBoard: BoardID { BoardID(owner: q) }

    @MainActor func file(inside extra: [String] = []) -> CanvasFile {
        let frame = { (i: Int) in CGRect(x: i * 150, y: 0, width: 100, height: 60) }
        let widget = { (id: ShapeID, i: Int, name: String) in AnyShapeRecord(ShapeRecord(id: id, Widget(frame(i), name: name))) }
        let pocket = { (id: ShapeID, i: Int) in AnyShapeRecord(ShapeRecord(id: id, Pocket(frame(i)))) }
        let pin = { (name: String, target: ShapeID) in AnyShapeRecord(ShapeRecord(Pin(name, on: target))) }
        let more = extra.enumerated().map { widget(ShapeID(), 10 + $0.offset, $0.element) }
        return CanvasFile(root: CanvasDocument(shapes: [widget(a, 0, "A"), pocket(p, 1), pin("on P", p), pocket(e, 2)]),
                          children: [p: CanvasDocument(shapes: [widget(c, 0, "C"), pin("on C", c), widget(d, 1, "D"), pocket(q, 2)] + more),
                                     q: CanvasDocument(shapes: [widget(f, 0, "F")])])
    }
}

@MainActor let nestedBoardTests = Suite("Table of contents: a board under its owner's row", [
    test("a shape that owns a board names it, its rows under the shape's; listing the board shown reads none of them") {
        let nest = PocketsInPockets()
        let editor = try contentsEditor([PocketsPlugin()], file: nest.file())
        let entries = editor.contents.entries
        expectEqual(entries.outline, ["A", "pocket", "  on P", "pocket"], "the board shown's rows, the pin under its pocket")
        expectEqual(entries.map(\.nestedBoard), [nil, nest.pBoard, BoardID(owner: nest.e)], "an empty pocket owns a board too")
        expectEqual(entries[1].children?.first?.nestedBoard, nil)
        expectEqual(editor.contents.rowsMade, 4, "the root's rows alone")
        expectEqual(editor.contents.outline(of: nest.pBoard).outline, ["C", "  on C", "D", "pocket"])
        expectEqual(editor.contents.outline(of: nest.pBoard).last?.nestedBoard, nest.qBoard, "and so on down")
    },
    test("selecting a row of a nested board goes to its shape there, one step back; the rest selected stay behind") {
        let nest = PocketsInPockets()
        let editor = try contentsEditor([PocketsPlugin()], file: nest.file())
        editor.selectedShapeIDs = [nest.a]
        editor.contents.select([nest.a, nest.c])
        expectEqual(editor.board, nest.pBoard)
        expectEqual(editor.selectedShapeIDs, [nest.c])
        expectEqual(editor.contents.entries.outline, ["C"], "the board it went to, listing the selection")
        editor.goBack()
        expectEqual(editor.board, .root)
        expectEqual(editor.selectedShapeIDs, [nest.a])
        editor.contents.select([nest.f])
        expectEqual(editor.board, nest.qBoard, "two boards down")
        expectEqual(editor.selectedShapeIDs, [nest.f])
        editor.goBack()
        expectEqual(editor.board, .root, "one step back")
    },
    test("selecting rows of several nested boards goes to the board of the one listed first") {
        let nest = PocketsInPockets()
        let editor = try contentsEditor([PocketsPlugin()], file: nest.file())
        editor.contents.select([nest.f, nest.c, nest.d])
        expectEqual(editor.board, nest.pBoard, "C's, listed before Q's F, which is under Q, after C and D")
        expectEqual(editor.selectedShapeIDs, [nest.c, nest.d])
        editor.goBack()
        editor.contents.select([nest.f, nest.q])
        expectEqual(editor.board, nest.pBoard, "Q's, listed before what's under it")
        expectEqual(editor.selectedShapeIDs, [nest.q])
    },
    test("a selection that adds rows of the board shown too (a ⇧-click's range over an open board) selects those, and stays") {
        let nest = PocketsInPockets()
        let editor = try contentsEditor([PocketsPlugin()], file: nest.file())
        editor.selectedShapeIDs = [nest.a]
        editor.contents.select([nest.a, nest.p, nest.c, nest.d, nest.q, nest.e])
        expectEqual(editor.board, .root)
        expectEqual(editor.selectedShapeIDs, [nest.a, nest.p, nest.e])
        editor.contents.select([nest.a, nest.p, nest.e, nest.c])          // ⌘-click on C: all it adds is C
        expectEqual(editor.board, nest.pBoard)
        expectEqual(editor.selectedShapeIDs, [nest.c])
    },
    test("a nested row's primary action goes into its shape: a pocket's board shown, one step back; a widget only gone to") {
        let nest = PocketsInPockets()
        let editor = try contentsEditor([PocketsPlugin(), openingPockets()], file: nest.file())
        editor.contents.open([nest.q])
        expectEqual(editor.board, nest.qBoard)
        expectEqual(editor.contents.entries.outline, ["F"])
        editor.goBack()
        expectEqual(editor.board, .root, "one step back, through P's board")
        editor.contents.open([nest.d])
        expectEqual(editor.board, nest.pBoard)
        expectEqual(editor.selectedShapeIDs, [nest.d], "a widget doesn't open: gone to")
    },
    test("the pointer on a nested board's row hovers nothing, and leaves a hover alone") {
        let nest = PocketsInPockets()
        let editor = try contentsEditor([PocketsPlugin()], file: nest.file())
        editor.contents.hover(nest.c)
        expectEqual(editor.hovered, nil, "the canvas doesn't show C")
        expect(!editor.contents.isHovered(nest.c))
        editor.contents.hover(nest.a)
        editor.contents.hover(nest.c)
        editor.contents.endHover(nest.c)
        expectEqual(editor.hovered, nest.a)
    },
])

extension ContentsWindow {
    var outline: NSOutlineView? { table as? NSOutlineView }

    /// Whether the row at `row` (the header is 0) has a disclosure triangle.
    func isExpandable(_ row: Int) throws -> Bool {
        let outline = try require(outline, "no outline")
        return outline.isExpandable(outline.item(atRow: row))
    }

    /// Opens the row at `row`'s disclosure triangle, as a click on it does.
    func expand(_ row: Int) throws {
        let outline = try require(outline, "no outline")
        outline.expandItem(outline.item(atRow: row))
        window.settle()
    }
}

@MainActor let nestedBoardWindowTests = Suite("Table of contents: a board under its owner's row, in a window", [
    test("a shape whose board has shapes opens onto that board's rows, made only then, before those nested under it here; an empty board, nothing to open") {
        let nest = PocketsInPockets()
        let editor = try contentsEditor([PocketsPlugin()], file: nest.file(), scheduler: TaskScheduler())
        let w = ContentsWindow(editor)
        w.window.spin { w.rows == 3 }
        w.window.settle()
        expectEqual(editor.contents.rowsMade, 4, "the board shown's rows alone: P's board, collapsed, costs none")
        expectEqual(try [1, 2, 3].map(w.isExpandable), [false, true, false], "A; P, which holds shapes; and E, which holds none")
        try w.expand(2)
        w.window.spin { w.rows == 7 }
        // A; P, then C, D and Q from P's board and the pin on P from the root; E.
        expectEqual(editor.contents.rowsMade, 4 + 4, "P's board's rows, made as it opened")
        expectEqual(try [3, 4, 5, 6, 7].map(w.isExpandable), [true, false, true, false, false], "C has its pin; Q its board")
        try w.expand(5)
        w.window.spin { w.rows == 8 }
        try w.expand(3)
        w.window.spin { w.rows == 9 }
        expectEqual(editor.contents.rowsMade, 4 + 4 + 1, "F's, as Q opened; C's pin's was made with P's board")
    },
    test("an open board's rows follow it as it changes, though it isn't shown") {
        let nest = PocketsInPockets()
        let editor = try contentsEditor([PocketsPlugin()], file: nest.file(), scheduler: TaskScheduler())
        let w = ContentsWindow(editor)
        w.window.spin { w.rows == 3 }
        try w.expand(2)
        w.window.spin { w.rows == 7 }
        editor.transact(on: nest.pBoard, "Add") { $0.insert(ShapeRecord(Widget(widgetFrame, name: "G"))) }
        w.window.spin { w.rows == 8 }
        editor.transact(on: nest.pBoard, "Delete") { $0.delete([nest.c, nest.d]) }
        w.window.spin { w.rows == 7 }                           // A; P, then the pin on C, at the top now, Q and G, and the pin on P; E
        expect(!(try w.isExpandable(7)))
        editor.transact(on: BoardID(owner: nest.e), "Add") { $0.insert(ShapeRecord(Widget(widgetFrame, name: "H"))) }
        w.window.spin { (try? w.isExpandable(7)) == true }      // E holds a shape now
    },
    test("a click on a nested board's row goes to its shape there, its rows replacing the list's with no reentrant update; Back returns to the board") {
        let nest = PocketsInPockets()
        let editor = try contentsEditor([PocketsPlugin()], file: nest.file(), scheduler: TaskScheduler())
        let w = ContentsWindow(editor)
        w.window.spin { w.rows == 3 }
        try w.expand(2)
        w.window.spin { w.rows == 7 }
        let log = try standardError {
            try require(w.table).selectRowIndexes([4], byExtendingSelection: false)      // D
            w.window.spin { editor.board == nest.pBoard && w.rows == 1 }  // the list lists the selection there
            w.window.settle()
        }
        expect(!log.contains(tableReentrancyWarning), "AppKit logged: \(log)")
        expectEqual(editor.selectedShapeIDs, [nest.d])
        editor.goBack()
        // The root's rows again, P's open or not as the list keeps it (here, the same list as before).
        w.window.spin { editor.board == .root && editor.selectedShapeIDs.isEmpty && w.rows >= 3 }
    },
    test("opening a board of more than 200 rows brings them in as one run: AppKit logs no reentrant update") {
        let nest = PocketsInPockets()
        let editor = try contentsEditor([PocketsPlugin()], file: nest.file(inside: (0..<250).map { "Widget \($0)" }), scheduler: TaskScheduler())
        let w = ContentsWindow(editor)
        w.window.spin { w.rows == 3 }
        let log = try standardError {
            try w.expand(2)
            w.window.spin { w.rows == 257 }
            w.window.settle()
        }
        expect(!log.contains(tableReentrancyWarning), "AppKit logged: \(log)")
    },
])

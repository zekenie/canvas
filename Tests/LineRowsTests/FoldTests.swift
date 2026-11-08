import AppKit
@_spi(Host) import Canvas
import CanvasTesting
@_spi(Host) import CanvasUI
import Find
import Keyboard
import LineRows
import Selection
import TestKit
import TextEditing

// Folds (⌃⌘↑ ⌃⌘↓): a view of a shape written as lines, provided to its layout. A tally marks the entries that have a
// count, so it folds to those (the first two where it has none), with a "+N" line for the rest; an entry whose label ends
// in "/" heads the entries under it. Nothing is written and no step is made.

@MainActor let foldTests = Suite("Folds", [
    test("RowsShown: the marked rows, then a +N line standing for the rest; the first two where none is marked; peeks in place") {
        let rows = (0..<6).map { _ in FoldRow(id: PartID()) }
        let folded = try require(RowsShown.make(rows: rows, fold: RowFold(toMarked: true), marked: [rows[1].id, rows[4].id]))
        expectEqual(folded.lines, [.row(1), .row(4), .more(4)])
        expectEqual(folded.line(standingFor: 1), 0)
        expectEqual(folded.line(standingFor: 0), 2, "a hidden row stands at the +N line")
        expectEqual(folded.line(standingFor: rows[5].id), 2)
        expect(folded.isShown(4) && !folded.isShown(3), "shown and hidden")
        expectEqual(folded.more?.count, 4)
        let unmarked = try require(RowsShown.make(rows: rows, fold: RowFold(toMarked: true), marked: []))
        expectEqual(unmarked.lines, [.row(0), .row(1), .more(4)], "a shape that marks none keeps its first two")
        let peeked = try require(RowsShown.make(rows: rows, fold: RowFold(toMarked: true), marked: [rows[1].id], peeked: [rows[3].id]))
        expectEqual(peeked.lines, [.row(1), .row(3), .more(4)], "a peeked row shows in its place, out of the count")
        expect(RowsShown.make(rows: Array(rows.prefix(2)), fold: RowFold(toMarked: true), marked: []) == nil, "nothing hidden: every row shows")
        expect(RowsShown.make(rows: rows, fold: RowFold(), marked: []) == nil, "no fold asked for")
    },
    test("RowsShown: a closed header hides the rows under it, up to the next header, and counts them") {
        let rows = [FoldRow(id: PartID(), isHeader: true), FoldRow(id: PartID()), FoldRow(id: PartID()),
                    FoldRow(id: PartID(), isHeader: true), FoldRow(id: PartID())]
        let shown = try require(RowsShown.make(rows: rows, fold: RowFold(closed: [rows[0].id]), marked: []))
        expectEqual(shown.lines, [.header(0, hiding: 2), .row(3), .row(4)])
        expectEqual(shown.line(standingFor: 2), 0, "a row under a closed header stands at it")
        expectEqual(shown.row(atLine: 0), 0)
    },
    test("⌃⌘↑ folds the selected tally to its marked entries, laid out at their height with a +N line; ⌃⌘↓ unfolds; no step, nothing written") {
        let b = try Bench()
        let id = b.tally("apples", ["red 3", "green", "blue 2", "pink", "gold"])
        let before = try require(b.frame(id))
        let file = b.editor.file
        b.editor.selectedShapeIDs = [id]
        b.press(.controlCommandUp)
        expect(b.editor.rowFolds?.isFolded(id) == true)
        expectEqual(b.drawn(), ["red", "blue", "+3"])
        let folded = try require(b.frame(id))
        expectEqual(folded.height, Tally.head * 2 + Tally.rowHeight * 3, "two rows and the +N line")
        expectEqual(folded.width, before.width)
        expectEqual(b.editor.undoHistory.undoName, nil, "a fold is no step")
        expect(b.editor.file == file, "nothing written")
        expect(b.editor.announcements.contains("apples folded, 2 of 5 entries shown") || b.editor.announcements.last?.hasPrefix("Folded") == true,
               "VoiceOver hears it: \(b.editor.announcements)")
        let parts = try require(b.editor.shapeContext.geometry(of: id)?.parts)
        let green = b.rows(id)[1].id, blue = b.rows(id)[2].id
        expectEqual(parts.frame(green)?.rect, TallyLines.line(2, in: folded), "a hidden row's rect is the +N line")
        expectEqual(parts.frame(blue)?.rect, TallyLines.line(1, in: folded))
        b.press(.controlCommandDown)
        expect(b.editor.rowFolds?.isFolded(id) != true)
        expectEqual(try require(b.frame(id)), before, "unfolded: as it was")
        expectEqual(b.drawn(), ["red", "green", "blue", "pink", "gold"])
    },
    test("With nothing selected ⌃⌘↑ folds every tally on the board; a tally with no counts keeps its first two") {
        let b = try Bench()
        let a = b.tally("a", ["one", "two", "three", "four"])
        let c = b.tally("c", ["x 1", "y", "z"], at: CGPoint(x: 400, y: 100))
        b.editor.selectedShapeIDs = []
        b.press(.controlCommandUp)
        expect(b.editor.rowFolds?.isFolded(a) == true && b.editor.rowFolds?.isFolded(c) == true)
        expectEqual(b.drawn().sorted(), ["+2", "+2", "one", "two", "x"].sorted())
        expect(!b.editor.canPerform(.foldRows), "everything folded already: Fold Rows is off")
        expect(b.editor.canPerform(.unfoldRows))
    },
    test("A commit to a folded tally keeps it folded: a row added, a count given, read again from the provided input") {
        let b = try Bench()
        let id = b.tally("apples", ["red 3", "green", "blue"])
        b.editor.rowFolds?.fold([id])
        expectEqual(b.drawn(), ["red", "+2"])
        b.editor.transact("Count") { t in t.update(id, as: Tally.self) { $0.props.rows[1].count = 7 } }
        expectEqual(b.drawn(), ["red", "green", "+1"], "green has a count now, so it's kept")
        b.editor.transact("Add") { t in t.update(id, as: Tally.self) { $0.props.rows.append(TallyRow("plum")) } }
        expectEqual(b.drawn(), ["red", "green", "+2"])
        expectEqual(try require(b.frame(id)).height, Tally.head * 2 + Tally.rowHeight * 3)
        b.editor.undo()
        expectEqual(b.drawn(), ["red", "green", "+1"], "an undo keeps the fold")
    },
    test("Editing a folded tally shows every row; the fold comes back as editing ends") {
        let b = try Bench()
        let id = b.tally("apples", ["red 3", "green", "blue"])
        b.editor.rowFolds?.fold([id])
        let folded = try require(b.frame(id))
        b.begin(id)
        expectEqual(b.drawn(), ["red", "green", "blue"], "every row while edited")
        expectEqual(try require(b.frame(id)).height, Tally.head * 2 + Tally.rowHeight * 4, "the rows and the waiting line")
        b.press(.escape)
        expectEqual(try require(b.frame(id)), folded, "folded again")
        expectEqual(b.drawn(), ["red", "+2"])
    },
    test("The +N line opens with a click, and with Return or Space from ⌥Tab; a closed header opens the same way") {
        let b = try Bench()
        let id = b.tally("apples", ["red 3", "green", "blue"])
        b.editor.rowFolds?.fold([id])
        let frame = try require(b.frame(id))
        let more = TallyLines.line(1, in: frame)
        b.editor.selectedShapeIDs = []
        b.h.click(at: b.h.view(CGPoint(x: more.midX, y: more.midY)))
        expect(b.editor.rowFolds?.isFolded(id) != true, "a click on +N shows every row")
        b.editor.rowFolds?.fold([id])
        b.editor.selectedShapeIDs = [id]
        let parts = b.editor.shapeParts(of: id)
        let part = try require(parts.first { $0.title == "2 more entries" }, "the +N line is a part the keys reach: \(parts.map(\.title))")
        expectEqual(part.rect, more)
        b.press(.optionTab)
        expectEqual(b.editor.focusedPart?.title, "2 more entries")
        b.press(.space)
        expect(b.editor.rowFolds?.isFolded(id) != true, "Space presses it")
        let headed = b.tally("h", ["fruit/", "red", "green", "veg/", "kale"], at: CGPoint(x: 400, y: 100))
        let header = b.rows(headed)[0].id
        b.editor.rowFolds?.setClosed(true, header: header, of: headed)
        expectEqual(b.editor.shapeContext.layoutInput(LineRowsLayout.shown, of: try require(b.editor.document[headed]))?.lines,
                    [.header(0, hiding: 2), .row(3), .row(4)])
        b.editor.selectedShapeIDs = [headed]
        b.press(.optionTab)
        b.press(.return)
        expect(b.editor.rowFolds?.isFolded(headed) != true, "Return opens the header")
    },
    test("Peeks: rows asked for show in their place though folded, until let go; Find's hits peek while Find is open") {
        let b = try Bench(find: true)
        let id = b.tally("apples", ["red 3", "green", "blue", "pink"])
        b.editor.rowFolds?.fold([id])
        b.editor.rowFolds?.peek([b.rows(id)[2].id], of: id)
        expectEqual(b.drawn(), ["red", "blue", "+2"])
        b.editor.rowFolds?.release(of: id)
        expectEqual(b.drawn(), ["red", "+3"])
        let find = try require(b.editor.find)
        find.open()
        find.query = "pink"
        try b.settleFind()
        expectEqual(find.fieldsHit(of: id), [b.rows(id)[3].id.description])
        expectEqual(b.drawn(), ["red", "pink", "+2"], "the hit row peeks")
        expectEqual(find.results.count, 1, "one result a shape")
        find.close()
        b.window.settle()
        expectEqual(b.drawn(), ["red", "+3"], "let go as Find ends")
    },
    test("The folds are a view value: saved with the shapes in the file, and handed back to another editor; a shape gone isn't saved") {
        let b = try Bench()
        let kept = b.tally("kept", ["a 1", "b", "c"])
        let gone = b.tally("gone", ["a", "b", "c"], at: CGPoint(x: 400, y: 100))
        b.editor.rowFolds?.fold([kept, gone])
        b.editor.transact("Delete") { $0.delete([gone]) }
        let values = b.editor.viewValues
        expect(values["line-rows.folds"] != nil, "saved under its key")
        let other = try Bench()
        other.editor.replaceFile(with: b.editor.file, showing: .root)
        expect(other.editor.rowFolds?.isFolded(kept) != true)
        other.editor.restoreViewValues(values)
        expect(other.editor.rowFolds?.isFolded(kept) == true, "handed back")
        expect(other.editor.rowFolds?.isFolded(gone) != true, "a shape gone isn't saved")
        expectEqual(other.drawn(), ["a", "+2"], "laid out folded")
        b.editor.undo()
        expect(b.editor.rowFolds?.isFolded(gone) == true, "an undo brings it back folded in this session")
    },
    test("A line typed wider than the tally lays it out as wide as the line needs, nothing written; as stored again as editing ends") {
        let b = try Bench()
        let id = b.tally("apples", ["red 3"])
        let stored = try require(b.frame(id)).width
        b.begin(id)
        b.type("a very long entry label that runs past the edge of the tally by far")
        let wide = try require(b.frame(id)).width
        expect(wide > stored, "laid out wider: \(wide)")
        expectEqual(b.editor.document[id]?.box?.width, stored, "nothing written")
        expectEqual(b.editor.undoHistory.undoName, nil)
        b.press(.escape)
        expectEqual(try require(b.frame(id)).width, stored, "as stored again")
    },
])

extension Bench {
    func frame(_ id: ShapeID) -> CGRect? {
        editor.document[id].flatMap { editor.shapeContext.frame(of: $0) }
    }

    /// Runs Find's index (the harness's scheduler) and waits for its search.
    func settleFind() throws {
        let find = try require(editor.find)
        var turns = 0
        while find.isIndexing, turns < 10_000 {
            h.wait(0)
            turns += 1
        }
        _ = try awaitResult { await find.settled() }
        window.settle()
    }
}

extension Chord {
    static let controlCommandUp = Chord(Key.up, [.control, .command])
    static let controlCommandDown = Chord(Key.down, [.control, .command])
    static let optionTab = Chord(Key.tab, .option)
}

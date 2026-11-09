import AppKit
@_spi(Host) import Canvas
import CanvasTesting
@_spi(Host) import CanvasUI
import LineRows
import Selection
import TestKit
import TextEditing

// A tally's entries written as lines, by the keys of a row (rows-editing's table): a line is a draft until the caret leaves
// it, then one step the kind names; Return commits and opens a line under it, and ends on an empty one; ↑ ↓ and Tab walk
// the stops; ⌥↑ ⌥↓ move a row, repeats one step; ⌘⌫ then ⌫ takes a row out, one step; a held ⌫ stops at the row it took;
// a pasted block is a row a line; ⇧↩ puts a tally beside; Escape, ⌘↩ and ⌘↑ end, keeping the draft.

@MainActor let sessionTests = Suite("Rows written as lines", [
    test("Return on a selected tally edits it at its waiting line: the kind lays out a line more, leaves it empty and draws no row the field has") {
        let b = try Bench()
        let id = b.tally("apples", ["red 3", "green 4"])
        let before = try require(b.editor.shapeContext.frame(of: try require(b.editor.document[id])))
        b.editor.selectedShapeIDs = [id]
        b.press(.return)
        expectEqual(b.focus, "waiting", "titled, it starts at the waiting line")
        let during = try require(b.editor.shapeContext.frame(of: try require(b.editor.document[id])))
        expectEqual(during.height - before.height, Tally.rowHeight, "a line more for the waiting line")
        expectEqual(b.drawn(), ["red", "green"])
        b.press(.up)
        expectEqual(b.focus, "row green")
        expectEqual(b.field.string, "green 4", "printed from what's stored")
        expectEqual(b.drawn(), ["red"], "the row the field has isn't drawn by the kind")
        b.press(.escape)
        expectEqual(b.editor.editingShapeID, nil)
        let after = try require(b.editor.shapeContext.frame(of: try require(b.editor.document[id])))
        expectEqual(after, before, "the waiting line goes as editing ends")
        expectEqual(b.drawn(), ["red", "green"])
    },
    test("apis 26: Return with the caret at the very start of a row opens the waiting line above it, as a text editor does; what's typed there goes in above; at any other place, below") {
        let b = try Bench()
        let id = b.tally("apples", ["red 3", "green 4"])
        let ids = b.rows(id).map(\.id)
        b.begin(id)
        b.press(.up)
        b.press(.up)
        expectEqual(b.focus, "row red")
        b.field.setSelectedRange(NSRange(location: 0, length: 0))
        b.press(.return)
        expectEqual(b.focus, "waiting")
        expectEqual(b.view?.stops, [.waiting, .row(ids[0]), .row(ids[1])], "above the row it was on")
        expectEqual(b.labels(id), ["red", "green"], "nothing written")
        b.type("blue 1")
        b.press(.return)
        expectEqual(b.labels(id), ["blue", "red", "green"])
        expectEqual(b.undoName, "Add Entry")
        expectEqual(b.view?.stops, [.row(b.rows(id)[0].id), .waiting, .row(ids[0]), .row(ids[1])], "the next line under the one typed")
        b.press(.down)
        expectEqual(b.focus, "row red")
        b.field.setSelectedRange(NSRange(location: 1, length: 0))
        b.press(.return)
        expectEqual(b.view?.stops, [.row(b.rows(id)[0].id), .row(ids[0]), .waiting, .row(ids[1])], "mid-line: below")
        // Back up from the empty line, Return again: below. An empty line has no column to carry, so the row is entered at its end,
        // never at a start nothing the person did put the caret at.
        b.press(.up)
        expectEqual(b.focus, "row red")
        expectEqual(b.field.selectedRange().location, ("red 3" as NSString).length, "at the row's end")
        b.press(.return)
        expectEqual(b.view?.stops, [.row(b.rows(id)[0].id), .row(ids[0]), .waiting, .row(ids[1])], "below the row, as before")
        b.press(.escape)
    },
    test("Return commits a typed line as its own step, Add Entry, and opens a line under it; on the empty line it ends editing; announced") {
        let b = try Bench()
        let id = b.tally("apples", ["red 3"])
        b.begin(id)
        b.type("green 4")
        expectEqual(b.labels(id), ["red"], "a draft until the caret leaves it")
        b.press(.return)
        expectEqual(b.labels(id), ["red", "green"])
        expectEqual(b.rows(id).last?.count, 4)
        expectEqual(b.undoName, "Add Entry")
        expectEqual(b.focus, "waiting")
        expect(b.editor.announcements.contains("Add Entry"), "VoiceOver hears the step")
        b.type("yellow")
        b.press(.return)
        expectEqual(b.labels(id), ["red", "green", "yellow"])
        b.press(.return)
        expectEqual(b.editor.editingShapeID, nil, "Return on the empty line ends editing")
        expectEqual(b.editor.selectedShapeIDs, [id], "the tally selected")
        b.editor.undo()
        expectEqual(b.labels(id), ["red", "green"], "each line its own step")
    },
    test("Return on a row commits it and opens the waiting line right under it; the new line goes there") {
        let b = try Bench()
        let id = b.tally("apples", ["red", "green", "blue"])
        b.begin(id)
        b.press(.up, times: 3)
        expectEqual(b.focus, "row red")
        b.press(.return)
        expectEqual(b.focus, "waiting")
        b.type("pink")
        b.press(.return)
        expectEqual(b.labels(id), ["red", "pink", "green", "blue"])
        b.press(.down)
        expectEqual(b.focus, "row green", "left empty, the waiting line goes back to the end")
        b.press(.down, times: 2)
        expectEqual(b.focus, "waiting")
        b.press(.down)
        expectEqual(b.focus, "waiting", "nothing past the last stop")
    },
    test("a row's commit is named by what changed: Rename Entry for its label alone, Change Entry otherwise; nothing for no change") {
        let b = try Bench()
        let id = b.tally("apples", ["red 3", "green 4"])
        b.begin(id)
        b.press(.up, times: 2)
        b.press(.down)
        expect(b.undoName == nil, "leaving a row as it was writes nothing")
        b.press(.up)
        b.field.setSelectedRange(NSRange(location: 0, length: 3))
        b.type("crimson")
        b.press(.down)
        expectEqual(b.labels(id), ["crimson", "green"])
        expectEqual(b.undoName, "Rename Entry")
        b.field.setSelectedRange(NSRange(location: 6, length: 1))
        b.type("5")
        b.press(.up)
        expectEqual(b.rows(id).last?.count, 5)
        expectEqual(b.undoName, "Change Entry")
    },
    test("⌥↑ ⌥↓ move the row, held or repeated one step, Move Entry; the caret stays in it") {
        let b = try Bench()
        let id = b.tally("apples", ["a", "b", "c", "d"])
        b.begin(id)
        b.press(.up)
        expectEqual(b.focus, "row d")
        b.press(.optionUp)
        b.press(.optionUp)
        expectEqual(b.labels(id), ["a", "d", "b", "c"])
        expectEqual(b.focus, "row d")
        expectEqual(b.undoName, "Move Entry")
        b.editor.undo()
        expectEqual(b.labels(id), ["a", "b", "c", "d"], "two moves, one step")
        b.begin(id)
        b.press(.up, times: 4)
        b.press(.optionUp)
        expectEqual(b.labels(id), ["a", "b", "c", "d"], "nothing past the top")
        b.press(.optionDown)
        expectEqual(b.labels(id), ["b", "a", "c", "d"])
    },
    test("⌘⌫ empties the line and ⌫ on the empty row takes it out: one step, Delete Entry, one undo; the caret to the row above") {
        let b = try Bench()
        let id = b.tally("apples", ["red 3", "green 4", "blue"])
        b.begin(id)
        b.press(.up, times: 2)
        expectEqual(b.focus, "row green")
        b.field.setSelectedRange(NSRange(location: (b.field.string as NSString).length, length: 0))
        b.press(.commandDelete)
        expectEqual(b.field.string, "", "⌘⌫ empties the line")
        expectEqual(b.labels(id), ["red", "green", "blue"], "nothing written yet")
        b.press(.delete)
        expectEqual(b.labels(id), ["red", "blue"])
        expectEqual(b.undoName, "Delete Entry")
        expectEqual(b.focus, "row red")
        expectEqual(b.field.selectedRange().location, ("red 3" as NSString).length, "at the end of the row above")
        b.editor.undo()
        expectEqual(b.labels(id), ["red", "green", "blue"], "one undo brings it back, with its count")
        expectEqual(b.rows(id)[1].count, 4)
    },
    test("a held ⌫ empties a row, takes it out and stops there: the row above keeps its words") {
        let b = try Bench()
        let id = b.tally("apples", ["red", "go"])
        b.begin(id)
        b.press(.up)
        b.field.setSelectedRange(NSRange(location: 2, length: 0))
        b.hold(.delete, repeats: 8)
        expectEqual(b.labels(id), ["red"])
        expectEqual(b.field.string, "red", "the row above as it was")
    },
    test("a line emptied and left goes: Delete Entry; the empty waiting line left writes nothing") {
        let b = try Bench()
        let id = b.tally("apples", ["red", "green"])
        b.begin(id)
        b.press(.down)
        b.press(.up)
        expect(b.undoName == nil)
        b.field.selectAll(nil)
        b.press(.delete)
        b.press(.up)
        expectEqual(b.labels(id), ["red"])
        expectEqual(b.undoName, "Delete Entry")
    },
    test("Escape, ⌘↩ and ⌘↑ end editing, the draft written; so does the keyboard leaving") {
        let b = try Bench()
        let id = b.tally("apples", ["red"])
        for (chord, label) in [(Chord.escape, "a"), (.commandReturn, "b"), (.commandUp, "c")] {
            b.begin(id)
            b.type(label)
            b.press(chord)
            expectEqual(b.editor.editingShapeID, nil, "\(chord) ends it")
            expectEqual(b.labels(id).last, label, "\(chord) keeps the draft")
        }
        b.begin(id)
        b.type("d")
        b.window.makeFirstResponder(b.canvas)
        b.window.settle()
        expectEqual(b.labels(id).last, "d", "written as the keyboard leaves")
        expectEqual(b.undoName, "Add Entry")
    },
    test("⌥↩ and ⌃↩ type no line break; / and @ are letters") {
        let b = try Bench()
        let id = b.tally("apples", ["red"])
        b.begin(id)
        b.type("a/b@c")
        b.press(Chord(Key.return, .option))
        b.press(Chord(Key.return, .control))
        expectEqual(b.field.string, "a/b@c")
        expectEqual(b.editor.editingShapeID, id)
        expectEqual(b.labels(id), ["red"])
    },
    test("a pasted block is a row a line, inserted where the caret's line is, one step, Paste Entries; the caret at the end of the last") {
        let b = try Bench()
        let id = b.tally("apples", ["red", "blue"])
        b.begin(id)
        b.press(.up, times: 2)
        b.press(.return)
        b.field.paste(text: "one 1\ntwo 2\n\nthree 3\n")
        expectEqual(b.labels(id), ["red", "one", "two", "three", "blue"])
        expectEqual(b.undoName, "Paste Entries")
        expectEqual(b.focus, "row three")
        expectEqual(b.field.selectedRange().location, ("three 3" as NSString).length)
        b.editor.undo()
        expectEqual(b.labels(id), ["red", "blue"], "one step")
        b.begin(id)
        b.field.paste(text: "one line")
        expectEqual(b.field.string, "one line", "one line is typed")
    },
    test("a block pasted over an emptied row takes its place, and the step is still Paste Entries, one undo") {
        let b = try Bench()
        let id = b.tally("apples", ["red", "green", "blue"])
        b.begin(id)
        b.press(.up, times: 2)
        expectEqual(b.focus, "row green")
        b.press(.commandDelete)
        b.field.paste(text: "one 1\ntwo 2")
        expectEqual(b.labels(id), ["red", "one", "two", "blue"])
        expectEqual(b.undoName, "Paste Entries", "named for the block, not for the row it replaced")
        b.editor.undo()
        expectEqual(b.labels(id), ["red", "green", "blue"], "one step")
    },
    test("Tab and ⇧Tab walk the stops; past the last, the next tally in reading order, edited at its first stop; ⇧Tab comes back to the last") {
        let b = try Bench()
        let a = b.tally("a", ["x", "y"], at: CGPoint(x: 100, y: 100))
        let c = b.tally("c", ["z"], at: CGPoint(x: 400, y: 100))
        b.begin(a)
        b.press(.backTab, times: 2)
        expectEqual(b.focus, "row x")
        b.press(.backTab)
        expectEqual(b.editor.editingShapeID, c, "⇧Tab past the first: the previous tally, wrapping")
        expectEqual(b.focus, "waiting", "at its last stop")
        b.press(.tab)
        expectEqual(b.editor.editingShapeID, a, "Tab past the last: the next")
        expectEqual(b.focus, "row x", "at its first stop")
        expectEqual(b.editor.selectedShapeIDs, [a])
    },
    test("with no other tally, Tab and ⇧Tab come round inside it") {
        let b = try Bench()
        let a = b.tally("a", ["x"])
        b.begin(a)
        b.press(.tab)
        expectEqual(b.focus, "row x")
        b.press(.backTab)
        expectEqual(b.focus, "waiting")
        expectEqual(b.editor.editingShapeID, a)
    },
    test("⇧↩ writes the line, ends editing and puts a tally beside it, edited, Add Tally") {
        let b = try Bench()
        let a = b.tally("a", ["x"])
        b.begin(a)
        b.type("y")
        b.press(.shiftReturn)
        expectEqual(b.labels(a), ["x", "y"])
        let made = b.editor.document.shapes.filter { $0.kind == Tally.kind && $0.id != a }
        expectEqual(made.count, 1)
        expectEqual(b.editor.editingShapeID, made.first?.id)
        expectEqual(b.undoName, "Add Tally")
    },
    test("⇧↩ in a row: the tally left keeps no row's highlight, no waiting line and no width while the new one is edited") {
        let b = try Bench()
        let a = b.tally("a", ["x", "y"])
        b.begin(a)
        b.press(.up)
        expectEqual(b.focus, "row y")
        b.press(.shiftReturn)
        b.window.settle()
        expect(b.editor.editingShapeID != a)
        let drawn = b.editor.shapeContext
        expectEqual(drawn.layoutInput(LineRowsLayout.focused, for: a), nil, "the row's band went with the editing")
        expectEqual(drawn.layoutInput(LineRowsLayout.waiting, for: a), nil)
    },
    test("a locked tally isn't edited; one locked mid-session refuses the commit and shakes") {
        let b = try Bench()
        let a = b.tally("a", ["x"])
        b.editor.freeze([a])
        b.editor.selectedShapeIDs = [a]
        b.press(.return)
        expectEqual(b.editor.editingShapeID, nil)
        b.editor.freeze([a], false)
        b.begin(a)
        b.type("y")
        b.editor.freeze([a])
        b.refusals.refusals = []
        b.press(.return)
        expectEqual(b.labels(a), ["x"], "nothing written")
        expectEqual(b.refusals.refusals.last, [a], "it shakes")
    },
    test("a press on a row begins there, the caret where it was; a press under the rows at the waiting line") {
        let b = try Bench()
        let a = b.tally("a", ["red", "green"], at: CGPoint(x: 100, y: 100))
        b.begin(a, at: CGPoint(x: 100 + 24 + 2, y: 100 + Tally.head + Tally.rowHeight * 1.5))
        expectEqual(b.focus, "row green")
        b.press(.escape)
        b.begin(a, at: CGPoint(x: 150, y: 100 + Tally.head + Tally.rowHeight * 2.5))
        expectEqual(b.focus, "waiting")
    },
    test("a commit that moves the caret to another stop leaves the kind's layout and the field where the caret is: ⌘⌫ then ⌥↑, and the keyboard leaving a draft on the waiting line") {
        let b = try Bench()
        let id = b.tally("apples", ["red", "green", "blue"])
        b.begin(id)
        b.press(.up)
        b.field.setSelectedRange(NSRange(location: (b.field.string as NSString).length, length: 0))
        b.press(.commandDelete)
        b.press(.optionUp)
        expectEqual(b.labels(id), ["red", "green"], "the emptied row went")
        expectEqual(b.focus, "waiting")
        let shapes = b.editor.shapeContext
        expectEqual(shapes.layoutInput(LineRowsLayout.waiting, for: id), 2, "the kind leaves the waiting line's room, last")
        expectEqual(shapes.layoutInput(LineRowsLayout.focused, for: id), nil, "no row is the field's")
        b.press(.escape)
        // A draft on the waiting line, written as the keyboard leaves while the session goes on: the row it became is the field's.
        b.begin(id)
        b.type("pink 2")
        b.window.makeFirstResponder(nil)
        b.window.settle()
        expectEqual(b.labels(id), ["red", "green", "pink"])
        if b.editor.editingShapeID == id {
            let pink = try require(b.rows(id).last)
            expectEqual(b.editor.shapeContext.layoutInput(LineRowsLayout.focused, for: id), pink.id, "the row the field draws is the new one")
            expectEqual(b.editor.shapeContext.layoutInput(LineRowsLayout.waiting, for: id), nil, "the waiting line's room is given back")
        }
    },
    test("a row taken out by another writer while it has the caret: its line is a draft on the waiting line, the keyboard kept, written only as the caret leaves") {
        let b = try Bench()
        let id = b.tally("apples", ["red", "green"])
        b.begin(id)
        b.press(.up)
        b.field.setSelectedRange(NSRange(location: (b.field.string as NSString).length, length: 0))
        b.type(" 9")
        b.editor.transact("Take Out") { $0.update(id, as: Tally.self) { $0.props.rows.removeAll { $0.label == "green" } } }
        b.window.settle()
        expectEqual(b.labels(id), ["red"], "nothing written while the caret stays")
        expectEqual(b.undoName, "Take Out", "no step the person didn't ask for")
        expectEqual(b.focus, "waiting", "the draft is on the waiting line")
        expectEqual(b.field.string, "green 9", "its words kept")
        expect(b.window.firstResponder === b.field, "the line keeps the keyboard")
        let drawn = b.editor.shapeContext
        expectEqual(drawn.layoutInput(LineRowsLayout.focused, for: id), nil, "no row the line stands for")
        b.press(.return)
        expectEqual(b.labels(id), ["red", "green"], "the caret leaving writes it as a row")
        expectEqual(b.rows(id).last?.count, 9)
        expectEqual(b.undoName, "Add Entry")
    },
    test("a line break dropped into the line is a space, put in as typing is: the text's undo takes out what went in") {
        let b = try Bench()
        let id = b.tally("apples", ["red"])
        b.begin(id)
        b.type("x")
        b.field.insertText("a\r\nb", replacementRange: b.field.selectedRange())
        expectEqual(b.field.string, "xa b")
        b.field.insertText("c\nd", replacementRange: NSRange(location: 0, length: 1))
        expectEqual(b.field.string, "c da b", "over a selection too")
        b.window.settle()
        b.field.undoManager?.undo()
        b.window.settle()
        expectEqual(b.field.string, "xa b", "one undo takes back the last insert, whole, not a range past the text's end")
    },
    test("a line holds a draft when it has words that aren't written: a waiting line with any, a row changed (Undo and Redo are its own then, never the board's)") {
        let b = try Bench()
        let id = b.tally("apples", ["red", "green"])
        b.begin(id)
        expect(!b.field.holdsDraft, "the empty waiting line")
        b.type("b")
        expect(b.field.holdsDraft, "words on the waiting line")
        b.press(.up)
        expectEqual(b.focus, "row green")
        expect(!b.field.holdsDraft, "a row as it was shown")
        b.type("c")
        expect(b.field.holdsDraft, "a row changed")
        b.press(.down)
        expect(!b.field.holdsDraft, "written, it's the row as shown")
    },
])

@MainActor let offerTests = Suite("What fits at a line's caret", [
    test("the law: a line read and printed reads back as the same row, its unread words in order; a grammar that drops one is caught") {
        let b = try Bench()
        let a = b.tally("a", ["x"])
        b.tally("berries", [], at: CGPoint(x: 400, y: 100))
        let context = LineContext(editor: b.editor, shape: a)
        let corpus = ["red", "red 3", "red berries", "red 3 berries ! and more", "red !"]
        let kept = TallyGrammar().losses(in: corpus, unread: { $0.unread.split(separator: " ").map(String.init) }, in: context)
        expect(kept.isEmpty, "\(kept)")
        let lossy = DroppingGrammar().losses(in: ["red 3 and more"], unread: { $0.unread.split(separator: " ").map(String.init) }, in: context)
        expectEqual(lossy.map(\.line), ["red 3 and more"])
    },
    test("a word typed whole that longer offers still extend keeps the list, itself first and highlighted; ↑ ↓ on it are the line's") {
        let b = try Bench()
        let a = b.tally("a", ["x"])
        b.tally("berries", [], at: CGPoint(x: 400, y: 100))
        b.tally("berriesjam", [], at: CGPoint(x: 400, y: 300))
        b.begin(a)
        b.type("y berries")
        expectEqual(b.field.listedOffers.first, "berries", "the word typed whole, first")
        expect(b.field.listedOffers.contains("berriesjam"), "a longer one still offered: \(b.field.listedOffers)")
        expectEqual(b.field.highlightedOffer, "berries")
        b.press(.up)
        expect(b.field.offerList == nil, "↑ goes on to the rows, the list gone")
        expectEqual(b.rows(a).last?.ref, tallies(named: "berries", in: b.editor).first, "the line written as typed, never the longer offer")
    },
    test("after a label the list offers numbers and the other tallies, ranked by what's typed; Tab picks; Return never picks a word and commits") {
        let b = try Bench()
        let a = b.tally("a", ["x"])
        b.tally("berries", [], at: CGPoint(x: 400, y: 100))
        b.begin(a)
        b.type("y ")
        expectEqual(b.field.listedOffers, ["1", "2", "10", "berries"], "everything, as offered, before anything's typed")
        b.type("be")
        expectEqual(b.field.listedOffers, ["berries"])
        b.type("rries")
        expect(b.field.offerList == nil, "typed whole, nothing's left to offer")
        for _ in 0..<5 { b.press(.delete) }
        expectEqual(b.field.listedOffers, ["berries"])
        expectEqual(b.field.offerList?.returnPicks, .actionsOnly)
        b.press(.tab)
        expectEqual(b.field.string, "y berries", "Tab picks")
        expect(b.field.offerList == nil, "and the list goes")
        b.type("s")
        expect(b.field.offerList == nil, "picked, it stays closed in that word")
        b.press(.delete)
        b.field.setSelectedRange(NSRange(location: 3, length: 0))
        b.type("e")
        expectEqual(b.field.string, "y beerries")
        expect(b.field.offerList != nil, "after the caret moved, a change asks again")
        b.press(.return)
        expectEqual(b.rows(a).last?.label, "y", "Return commits the line, picking nothing")
        expectEqual(b.rows(a).last?.unread, "beerries")
        expectEqual(b.focus, "waiting")
    },
    test("Escape closes the list until the offers move, then ends editing; ⇧Tab closes it and goes on") {
        let b = try Bench()
        let a = b.tally("a", ["x"])
        b.begin(a)
        b.type("y ")
        expect(b.field.offerList != nil)
        b.press(.escape)
        expect(b.field.offerList == nil)
        expectEqual(b.editor.editingShapeID, a, "the first Escape closes the list")
        b.type("10")
        expect(b.field.offerList == nil, "not open again in the same place")
        b.press(.escape)
        expectEqual(b.editor.editingShapeID, nil, "the next ends editing")
        expectEqual(b.rows(a).last?.count, 10)
    },
    test("the highlighted tally is lit on the board; the light goes as the list does") {
        let b = try Bench()
        let a = b.tally("a", ["x"])
        let berries = b.tally("berries", [], at: CGPoint(x: 400, y: 100))
        b.begin(a)
        b.type("y ber")
        let service = try require(b.editor.service(LineRowsService.self))
        expectEqual(service.light, PartAddress(berries))
        b.type("qqq")
        expect(b.field.offerList == nil, "listed \(b.field.listedOffers) for \(b.field.string)")
        expectEqual(service.light, nil)
    },
    test("-> typed becomes →, one undo of the typing") {
        let b = try Bench()
        let a = b.tally("a", ["x"])
        b.begin(a)
        b.type("y -> z")
        expectEqual(b.field.string, "y → z")
    },
    test("a name printed or picked stands for its tally: an unchanged line keeps naming the same one when two share the name; typed into, it's found by name") {
        let b = try Bench()
        b.tally("twin", [], at: CGPoint(x: 400, y: 100))
        b.tally("twin", [], at: CGPoint(x: 400, y: 300))
        // The one found by name, and the other, which the row names.
        let twins = tallies(named: "twin", in: b.editor)
        let first = twins[0], second = twins[1]
        let a = b.h.add(Tally(CGRect(x: 100, y: 100, width: 240, height: 40), name: "a", rows: [TallyRow("y", ref: second)]))
        b.begin(a)
        b.press(.up)
        expectEqual(b.field.string, "y twin")
        expectEqual(b.field.line.references.map(\.target), [PartAddress(second)])
        b.field.setSelectedRange(NSRange(location: (b.field.string as NSString).length, length: 0))
        b.type(" !")
        b.press(.down)
        expectEqual(b.rows(a).first?.ref, second, "left as it was, it names the same tally")
        b.press(.up)
        b.field.setSelectedRange(NSRange(location: 6, length: 0))
        b.press(.delete)
        expect(b.field.offerList != nil, "a name part typed is offered")
        b.press(.down)
        expectEqual(b.field.listedOffers, ["twin", "twin"])
        expectEqual(b.field.offerList?.highlighted, 1, "↓ moves in the list while it's open")
        b.type("n")
        expect(b.field.line.references.isEmpty, "typed into, it's words again")
        expect(b.field.offerList == nil, "typed whole, it's offered no more")
        b.press(.down)
        expectEqual(b.rows(a).first?.ref, first, "and found by name: the first so called")
    },
])

@MainActor let referenceUndoTests = Suite("A name that stands for a tally, through the text's undo", [
    test("typing inside it makes it words, and undoing the typing makes it the tally's again: a line left as it was names the same one of two so called") {
        let b = try Bench()
        b.tally("twin", [], at: CGPoint(x: 400, y: 100))
        b.tally("twin", [], at: CGPoint(x: 400, y: 300))
        let twins = tallies(named: "twin", in: b.editor)
        let first = twins[0], second = twins[1]
        let a = b.h.add(Tally(CGRect(x: 100, y: 100, width: 240, height: 40), name: "a", rows: [TallyRow("y", ref: second)]))
        b.editor.undoHistory.seal()
        b.begin(a)
        b.press(.up)
        b.field.setSelectedRange(NSRange(location: 4, length: 0))
        b.type("z")
        expectEqual(b.field.string, "y twzin")
        expect(b.field.line.references.isEmpty, "typed into, it's words")
        b.window.settle()
        b.field.undoManager?.undo()
        b.window.settle()
        expectEqual(b.field.string, "y twin")
        expectEqual(b.field.line.references.map(\.target), [PartAddress(second)], "undone, it stands for the tally it did")
        b.field.undoManager?.redo()
        b.window.settle()
        expectEqual(b.field.string, "y twzin")
        expect(b.field.line.references.isEmpty, "redone, it's words again")
        b.field.undoManager?.undo()
        b.window.settle()
        b.press(.down)
        expectEqual(b.rows(a).first?.ref, second, "left as it was, it names the tally it did, not the first so called")
        expect(b.rows(a).first?.ref != first)
        expect(b.undoName == nil, "and writes no step: \(b.undoName ?? "-")")
    },
])

@MainActor let voiceOverTests = Suite("Rows written as lines, as VoiceOver reads them", [
    test("the view is a group, Entries of a tally; a row each, the one with the caret the field; the waiting line New entry") {
        let b = try Bench()
        let a = b.tally("apples", ["red 3", "green"])
        b.begin(a)
        let view = try require(b.view)
        expectEqual(view.accessibilityRole(), .group)
        expectEqual(view.accessibilityLabel(), "Entries")
        let children = try require(view.accessibilityChildren())
        expectEqual(children.count, 3)
        expectEqual((children[0] as? NSAccessibilityElement)?.accessibilityLabel(), "Entry 1 of 2")
        expectEqual((children[0] as? NSAccessibilityElement)?.accessibilityValue() as? String, "red 3")
        expectEqual((children[0] as? NSAccessibilityElement)?.accessibilityHelp(), "red, 3")
        expect(children[2] as? LineField === b.field, "the field is the waiting line's element")
        expectEqual(b.field.accessibilityLabel(), "New entry")
        b.press(.up)
        expectEqual(b.field.accessibilityLabel(), "Entry 2 of 2")
        expect(view.accessibilityChildren()?[1] as? LineField === b.field)
        let first = try require(view.accessibilityChildren()?[0] as? NSAccessibilityElement)
        expect(first.accessibilityPerformPress())
        expectEqual(b.focus, "row red", "pressed, the caret goes to it")
    },
])

/// A walk of a tally being edited: its stops "tally/row <label>" and "tally/waiting"; the canvas's selection by tally name.
@MainActor private func walk(_ b: Bench) -> KeyWalk {
    KeyWalk(b.window, editor: b.editor, readers: [
        .custom("tally") { [unowned b] window in
            guard let focus = b.focus, let view = b.view, let responder = window.firstResponder as? NSView, responder.isDescendant(of: view) else { return nil }
            return Focus.of(window, surface: "tally", element: focus)
        },
        .canvas(b.canvas, selection: { [unowned b] in
            b.editor.selectedShapeIDs.compactMap { b.editor.document[$0]?.typed(as: Tally.self)?.props.name }
        }),
    ], settle: .runLoop)
}

@MainActor let keyWalkTests = Suite("Rows written as lines, walked by keys", [
    test("Tab walks every stop and comes round, ⇧Tab undoing each; ↑ ↓ are a column, staying at its ends") {
        let b = try Bench()
        let a = b.tally("a", ["x", "y"])
        b.begin(a)
        let walk = walk(b)
        walk.go("tally/row x")
        walk.expectCycle(["tally/row x", "tally/row y", "tally/waiting"], wraps: .closed)
        walk.go("tally/row x")
        walk.expectAxis(down: .down, up: .up, over: ["tally/row x", "tally/row y", "tally/waiting"])
    },
    test("each stop shows its caret, in view, a text field named Entry n of 2 or New entry; Escape is one level out, to the tally selected, what was typed kept") {
        let b = try Bench()
        let a = b.tally("a", ["x", "y"])
        b.begin(a)
        let walk = walk(b)
        walk.go("tally/row x")
        let stops = (0..<3).map { _ -> Focus in
            let focus = walk.focus
            walk.press(.tab)
            return focus
        }
        expectEqual(stops.map(\.label), ["Entry 1 of 2", "Entry 2 of 2", "New entry"])
        walk.expectShows(stops)
        walk.go("tally/waiting")
        b.type("z")
        walk.expectEscapeLadder(["canvas/a"], keepsTyped: nil)
        expectEqual(b.labels(a), ["x", "y", "z"], "what was typed is kept")
    },
    test("every key means what the table says on a row, but Return, the named exception line-return") {
        let b = try Bench()
        let a = b.tally("a", ["x", "y"])
        let start = b.editor.file
        let walk = walk(b)
        let reset = { @MainActor in
            b.editor.endEditing()
            while b.editor.file != start, b.editor.canUndo { b.editor.undo() }
            b.begin(a)
            b.press(.up)
            b.window.settle()
        }
        reset()
        let surface = KeySurface("A row written as a line", axes: .vertical, overrides: [
            .init(.return, [.forward, .elsewhere, .acted], exception: "line-return"),
        ])
        walk.expectMeanings(of: surface, stops: ["tally/row x", "tally/row y", "tally/waiting"], at: 1,
                            depth: { _ in b.editor.card != nil ? 3 : b.editor.editingShapeID != nil ? 2 : b.editor.selectedShapeIDs.isEmpty ? 0 : 1 }, reset: reset)
    },
])

/// A tally's grammar that prints a row without its unread words: what the law catches.
private struct DroppingGrammar: LineGrammar {
    func read(_ line: LineText, id: PartID, in context: LineContext) -> LineReading<TallyRow> { TallyGrammar().read(line, id: id, in: context) }
    func print(_ row: TallyRow, in context: LineContext) -> LineText {
        var row = row
        row.unread = ""
        return TallyGrammar().print(row, in: context)
    }
    func spoken(_ row: TallyRow, in context: LineContext) -> String { row.label }
}

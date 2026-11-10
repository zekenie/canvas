import AppKit
@_spi(Host) import Canvas
import CanvasTesting
@_spi(Host) import CanvasUI
import Geometry
import LineRows
import Selection
import TestKit
import TextEditing

// Rows as wholes, over tallies: selected as items of their tally on the canvas (Selection's), moved within a tally, into
// another and out into one of their own (`moveRows`), each one step named from the noun, their ids kept; on the editor's
// pasteboard (a board file, their lines beside it), a cut taking the straps bound to them and its paste a move; and selected
// whole while a tally is edited (⇧↑ ⇧↓), where ⌫, ⌥↑ ⌥↓, ⌘C ⌘X ⌘V and Escape act on them.

extension Bench {
    /// The tally's entries' ids, by label.
    func ids(_ id: ShapeID, _ labels: String...) -> [PartID] {
        labels.compactMap { label in rows(id).first { $0.label == label }?.id }
    }

    /// The labels of the entries selected as items, in order.
    var itemLabels: [String] {
        guard let selection = editor.selectedItems else { return [] }
        return selection.ids.map { id in
            if let part = id.base as? PartID { return rows(selection.shape).first { $0.id == part }?.label ?? "?" }
            return "+N"
        }
    }

    /// The board as it saves, for one Undo's exactness.
    func bytes() throws -> Data { try BoardCodec(registry: editor.registry).encode(editor.document) }
}

@MainActor let moveTests = Suite("Rows moved as wholes", [
    test("⌥↑ ⌥↓ on entries selected as items move them as a block, a held key one step named from the noun; they stay selected; Undo puts them back, selected") {
        let b = try Bench()
        let id = b.tally("fruit", ["apple", "pear", "plum", "fig"])
        b.editor.selectItems(b.ids(id, "pear", "plum").map(AnyHashable.init), of: id)
        b.press(.optionDown)
        expectEqual(b.labels(id), ["apple", "fig", "pear", "plum"])
        expectEqual(b.undoName, "Move Entries", "the noun's plural, for two")
        expectEqual(b.itemLabels, ["pear", "plum"], "still selected")
        b.press(.optionDown)
        expectEqual(b.labels(id), ["apple", "fig", "pear", "plum"], "nothing past the end")
        b.hold(.optionUp, repeats: 1)
        expectEqual(b.labels(id), ["pear", "plum", "apple", "fig"])
        b.editor.undo()
        expectEqual(b.labels(id), ["apple", "fig", "pear", "plum"], "a held key is one step")
        expectEqual(b.itemLabels, ["pear", "plum"], "Undo restores the items with it")
        b.editor.selectItems(b.ids(id, "fig").map(AnyHashable.init), of: id)
        b.press(.optionUp)
        expectEqual(b.undoName, "Move Entry", "one row: the noun")
    },
    test("Entries moved into another tally keep their ids, a new one only where it holds the id; one step, the tally selected with them; a strap bound to one follows it and PartsMoved hears where") {
        let log = PartsMovedLog()
        let b = try Bench(extras: [StrapsPlugin(log: log)])
        let a = b.tally("a", ["one", "two", "three"])
        let c = b.tally("c", ["x", "y"], at: CGPoint(x: 400, y: 100))
        let two = b.ids(a, "two")[0]
        let strap = b.h.add(Strap(from: PartAddress(a, part: two), to: nil))
        b.editor.undoHistory.seal()
        let landed = b.editor.moveRows([two], of: a, to: .into(c, before: b.ids(c, "y")[0]))
        expectEqual(landed, c)
        expectEqual(b.labels(a), ["one", "three"])
        expectEqual(b.labels(c), ["x", "two", "y"])
        expectEqual(b.ids(c, "two"), [two], "the id kept")
        expectEqual(b.undoName, "Move Entry")
        expectEqual(b.editor.selectedShapeIDs, [c])
        expectEqual(b.itemLabels, ["two"])
        expectEqual(b.editor.document[strap]?.typed(as: Strap.self)?.props.from, PartAddress(c, part: two), "bound to the row where it went")
        expectEqual(log.moves.last, [PartAddress(a, part: two): PartAddress(c, part: two)])
        // A tally that holds the id already: the row comes in under a new one.
        let copy = b.h.add(Tally(CGRect(x: 100, y: 300, width: 240, height: 40), name: "copy", rows: [TallyRow(id: two, "twin")]))
        b.editor.moveRows([two], of: c, to: .into(copy, before: nil))
        let moved = try require(b.rows(copy).first { $0.label == "two" })
        expect(moved.id != two, "a new id where the target holds it")
        expectEqual(b.editor.document[strap]?.typed(as: Strap.self)?.props.from, PartAddress(copy, part: moved.id))
    },
    test("Entries moved out land in a tally of their own at the point, settled into the corral there, selected, Move Entries to New Tally; one Undo is exact in board-codec bytes") {
        let b = try Bench(extras: [CorralsPlugin()])
        let corral = b.h.add(Corral(CGRect(x: 500, y: 300, width: 400, height: 300)))
        let a = b.tally("a", ["one", "two", "three"])
        let before = try b.bytes()
        let out = try require(b.editor.moveRows(b.ids(a, "two", "three"), of: a, to: .board(origin: CGPoint(x: 560, y: 360))))
        expect(out != a)
        expectEqual(b.labels(a), ["one"])
        expectEqual(b.labels(out), ["two", "three"], "the take-out, by default its kind holding only them")
        expectEqual(b.editor.document[out]?.container, corral, "settled into the corral it landed in")
        expectEqual(b.undoName, "Move Entries to New Tally")
        expectEqual(b.editor.selectedShapeIDs, [out])
        b.editor.undo()
        expectEqual(try b.bytes(), before, "one Undo, exact")
    },
    test("A read-only tally takes no rows and gives none: nothing changes, no step, it shakes") {
        let b = try Bench()
        let a = b.tally("a", ["one", "two"])
        let c = b.tally("c", ["x"], at: CGPoint(x: 400, y: 100))
        b.editor.freeze([c])
        b.editor.undoHistory.seal()
        let steps = b.undoName
        expectEqual(b.editor.moveRows(b.ids(a, "two"), of: a, to: .into(c, before: nil)), nil)
        expectEqual(b.labels(a), ["one", "two"])
        expectEqual(b.labels(c), ["x"])
        expectEqual(b.undoName, steps, "no step")
        expect(b.refusals.refusals.last?.contains(c) == true, "it shakes")
        b.editor.freeze([c], false)
        b.editor.freeze([a])
        expectEqual(b.editor.moveRows(b.ids(a, "one"), of: a, to: .into(a, before: nil)), nil, "a read-only source keeps its order")
        expectEqual(b.labels(a), ["one", "two"])
    },
    test("A take-out refused by a read-only corral shakes the corral; the rows stay and no step is left") {
        let b = try Bench(extras: [CorralsPlugin()])
        let corral = b.h.add(Corral(CGRect(x: 500, y: 300, width: 400, height: 300)))
        let a = b.tally("a", ["one", "two"])
        b.editor.freeze([corral])
        b.editor.undoHistory.seal()
        let steps = b.undoName
        expectEqual(b.editor.moveRows(b.ids(a, "two"), of: a, to: .board(origin: CGPoint(x: 560, y: 360))), nil)
        expectEqual(b.labels(a), ["one", "two"])
        expectEqual(b.undoName, steps, "no step")
        expect(b.refusals.refusals.last?.contains(corral) == true, "the corral that would not take it shakes")
    },
    test("One Undo of each move is exact in board-codec bytes: within a tally, between two, and a cut then a paste") {
        let b = try Bench()
        let a = b.tally("a", ["one", "two", "three"])
        let c = b.tally("c", ["x", "y"], at: CGPoint(x: 400, y: 100))
        var before = try b.bytes()
        expect(b.editor.moveRows(b.ids(a, "one"), of: a, by: 1))
        expectEqual(b.labels(a), ["two", "one", "three"])
        b.editor.undo()
        expectEqual(try b.bytes(), before, "within")
        expect(b.editor.moveRows(b.ids(a, "two"), of: a, to: .into(c, before: nil)) != nil)
        b.editor.undo()
        expectEqual(try b.bytes(), before, "between")
        expect(b.editor.cutRows(b.ids(a, "three"), of: a))
        b.editor.undo()
        expectEqual(try b.bytes(), before, "the cut")
        expect(b.editor.cutRows(b.ids(a, "three"), of: a))
        before = try b.bytes()
        let payload = try require(b.editor.pasteboardRows)
        b.editor.pasteRows(payload, to: .into(c, before: nil))
        b.editor.undo()
        expectEqual(try b.bytes(), before, "the paste of a cut")
    },
    test("⌥↑ ⌥↓ on a folded tally step over the entries its fold hides: one press changes what is shown, and nothing moves where nothing shown is past") {
        let b = try Bench()
        // A fold keeps the entries that have a count: a and c shown, b and d behind the +N line.
        let id = b.tally("fruit", ["a 1", "b", "c 1", "d"])
        b.editor.rowFolds?.fold([id])
        b.window.settle()
        b.editor.selectItems(b.ids(id, "c").map(AnyHashable.init), of: id)
        b.editor.undoHistory.seal()
        b.press(.optionUp)
        expectEqual(b.labels(id), ["c", "a", "b", "d"], "c went above the shown a, past the hidden b")
        b.editor.selectItems(b.ids(id, "a").map(AnyHashable.init), of: id)
        b.editor.undoHistory.seal()
        let steps = b.undoName
        b.press(.optionDown)
        expectEqual(b.labels(id), ["c", "a", "b", "d"], "nothing shown below a: no move")
        expectEqual(b.undoName, steps, "and no step")
        b.editor.selectItems(b.ids(id, "c").map(AnyHashable.init), of: id)
        b.press(.optionDown)
        expectEqual(b.labels(id), ["a", "c", "b", "d"], "c back below the shown a")
    },
])

@MainActor let payloadTests = Suite("Rows on the pasteboard", [
    test("Entries copied go on the editor's pasteboard: a board file holding only them, untitled, their lines as text beside it") {
        let b = try Bench()
        let a = b.tally("a", ["one 1", "two 2", "three"])
        expect(b.editor.copyRows(b.ids(a, "two", "three"), of: a))
        expectEqual(b.pasteboard.string(forType: .string), "two 2\nthree", "the lines, as typed")
        let payload = try require(b.editor.pasteboardRows)
        expectEqual(payload.carrier.typed(as: Tally.self)?.props.rows.map(\.label), ["two", "three"])
        expectEqual(payload.cut, nil)
        expectEqual(b.labels(a), ["one", "two", "three"], "a copy changes nothing")
        // Pasted into another tally: after the row given, the ids kept where it doesn't hold them; Paste Entries.
        let c = b.tally("c", ["x", "y"], at: CGPoint(x: 400, y: 100))
        b.editor.pasteRows(payload, to: .into(c, before: b.ids(c, "y")[0]))
        expectEqual(b.labels(c), ["x", "two", "three", "y"])
        expectEqual(b.undoName, "Paste Entries")
        expectEqual(b.ids(c, "two"), b.ids(a, "two"), "the shape's own ids, kept where it doesn't hold them")
        b.editor.pasteRows(payload, to: .into(c, before: nil))
        expectEqual(b.labels(c), ["x", "two", "three", "y", "two", "three"])
        let twos = b.rows(c).filter { $0.label == "two" }.map(\.id)
        expectEqual(twos.count, 2)
        expect(twos.last != b.ids(a, "two").first, "a second time, new ids: it holds them")
    },
    test("A cut takes the entries and the straps bound to them, one step counting them; its paste is a move, the straps back under their ids; again, copies") {
        let log = PartsMovedLog()
        let b = try Bench(extras: [StrapsPlugin(log: log)])
        let a = b.tally("a", ["one", "two", "three"])
        let other = b.tally("other", ["z"], at: CGPoint(x: 400, y: 300))
        let two = b.ids(a, "two")[0], z = b.ids(other, "z")[0]
        let strap = b.h.add(Strap(from: PartAddress(a, part: two), to: PartAddress(other, part: z)))
        b.editor.undoHistory.seal()
        expect(b.editor.cutRows([two], of: a))
        expectEqual(b.labels(a), ["one", "three"])
        expectEqual(b.editor.document[strap], nil, "the strap went with the row")
        expectEqual(b.undoName, "Cut Entry and 1 strap", "counted as the registry calls the kind")
        let payload = try require(b.editor.pasteboardRows)
        expect(payload.cut != nil)
        expectEqual(payload.bound.map(\.id), [strap])
        let c = b.tally("c", ["x"], at: CGPoint(x: 400, y: 100))
        b.editor.pasteRows(payload, to: .into(c, before: nil))
        expectEqual(b.labels(c), ["x", "two"])
        expectEqual(b.ids(c, "two"), [two], "the same row")
        expectEqual(b.editor.document[strap]?.typed(as: Strap.self)?.props.from, PartAddress(c, part: two), "back under its id, bound where the row went")
        expectEqual(b.editor.document[strap]?.typed(as: Strap.self)?.props.to, PartAddress(other, part: z))
        expectEqual(log.moves.last, [PartAddress(a, part: two): PartAddress(c, part: two)], "a move: what names the row follows")
        let moves = log.moves.count
        b.editor.pasteRows(payload, to: .into(a, before: nil))
        expectEqual(b.labels(a), ["one", "three", "two"])
        expectEqual(log.moves.count, moves, "pasted again, a copy: the board holds the row already")
        let straps = b.editor.document.shapes.filter { $0.kind == Strap.kind }
        expectEqual(straps.count, 2, "the strap copied")
    },
    test("Rows pasted on the board are a tally of their own, beside the selection, selected; a strap whose other end isn't here is left out") {
        let b = try Bench(extras: [StrapsPlugin()])
        let a = b.tally("a", ["one", "two"])
        let other = b.tally("other", ["z"], at: CGPoint(x: 400, y: 300))
        let two = b.ids(a, "two")[0]
        b.h.add(Strap(from: PartAddress(a, part: two), to: PartAddress(other, part: b.ids(other, "z")[0])))
        expect(b.editor.cutRows([two], of: a))
        let payload = try require(b.editor.pasteboardRows)
        b.editor.transact { $0.delete([other]) }
        b.editor.selectedShapeIDs = [a]
        let out = try require(b.editor.pasteRows(payload, to: .beside([a])))
        expectEqual(b.labels(out), ["two"])
        expectEqual(b.undoName, "Move Entry to New Tally", "a cut's rows moved out")
        expectEqual(b.editor.selectedShapeIDs, [out])
        expect(!b.editor.document.shapes.contains { $0.kind == Strap.kind }, "its other end is gone: left out")
        let frame = try require(b.editor.document[out]?.box), beside = try require(b.editor.document[a]?.box)
        expect(!frame.intersects(beside), "beside, not over")
    },
    test("A paste whose carried strap names a row that is gone since binds that end to its tally as a whole: nothing is left bound to a part that is not there") {
        let b = try Bench(extras: [StrapsPlugin()])
        let a = b.tally("a", ["one", "two"])
        let other = b.tally("other", ["z", "w"], at: CGPoint(x: 400, y: 300))
        let two = b.ids(a, "two")[0], z = b.ids(other, "z")[0]
        b.h.add(Strap(from: PartAddress(a, part: two), to: PartAddress(other, part: z)))
        expect(b.editor.cutRows([two], of: a))
        let payload = try require(b.editor.pasteboardRows)
        b.editor.transact { $0.update(other, as: Tally.self) { $0.props.rows.removeAll { $0.id == z } } }
        b.editor.pasteRows(payload, to: .into(a, before: nil))
        let strap = try require(b.editor.document.shapes.compactMap { $0.typed(as: Strap.self) }.first)
        expectEqual(strap.props.from, PartAddress(a, part: two))
        expectEqual(strap.props.to, PartAddress(other), "the row z is gone: the tally as a whole")
    },
    test("A paste that cannot bring back a strap whose other end is not on the board says so") {
        let b = try Bench(extras: [StrapsPlugin()])
        let a = b.tally("a", ["one", "two"])
        let other = b.tally("other", ["z"], at: CGPoint(x: 400, y: 300))
        b.h.add(Strap(from: PartAddress(a, part: b.ids(a, "two")[0]), to: PartAddress(other, part: b.ids(other, "z")[0])))
        expect(b.editor.cutRows(b.ids(a, "two"), of: a))
        let payload = try require(b.editor.pasteboardRows)
        b.editor.transact { $0.delete([other]) }
        b.editor.pasteRows(payload, to: .into(a, before: nil))
        expect(b.editor.announcements.last?.contains("1 strap left out") == true, "said: \(b.editor.announcements.last ?? "")")
    },
])

@MainActor let bandTests = Suite("Rows selected whole while a tally is edited", [
    test("⇧↓ selects the caret's row whole, the next ⇧↓ the row below; the line hidden, the band drawn; ⇧↑ draws it back; VoiceOver hears how many") {
        let b = try Bench()
        let id = b.tally("fruit", ["apple", "pear", "plum", "fig"])
        b.begin(id)
        b.press(.up, times: 3)
        expectEqual(b.focus, "row pear")
        b.press(.shiftDown)
        expectEqual(b.view?.selectedRows, b.ids(id, "pear"), "the first selects the caret's row")
        expect(b.field.isBanded && !b.field.isEditable, "the line takes no typing")
        expect(b.editor.announcements.last == "1 entry selected")
        b.press(.shiftDown)
        expectEqual(b.view?.selectedRows, b.ids(id, "pear", "plum"))
        expectEqual(b.drawn(), ["apple", "pear", "plum", "fig"], "every row drawn by the kind: the line is hidden")
        b.type("zz")
        expectEqual(b.labels(id), ["apple", "pear", "plum", "fig"], "letters change nothing")
        b.press(.shiftUp)
        expectEqual(b.view?.selectedRows, b.ids(id, "pear"))
        b.press(.down)
        expectEqual(b.view?.selectedRows, [], "an arrow goes back to a line")
        expectEqual(b.focus, "row pear")
    },
    test("Escape with rows selected whole ends editing, the rows selected as items; Escape again goes to the tally; ⌥↓ ⌫ act on them while edited") {
        let b = try Bench()
        let id = b.tally("fruit", ["apple", "pear", "plum", "fig"])
        b.begin(id)
        b.press(.up, times: 3)
        b.press(.shiftDown, times: 2)
        b.press(.optionDown)
        expectEqual(b.labels(id), ["apple", "fig", "pear", "plum"])
        expectEqual(b.undoName, "Move Entries")
        expectEqual(b.view?.selectedRows, b.ids(id, "pear", "plum"), "the band follows its rows")
        b.press(.escape)
        expectEqual(b.editor.editingShapeID, nil)
        expectEqual(b.itemLabels, ["pear", "plum"], "the rows stay selected, as items")
        b.press(.escape)
        expectEqual(b.editor.selectedItems, nil)
        expectEqual(b.editor.selectedShapeIDs, [id], "one level out: the tally")
        b.begin(id)
        b.press(.up, times: 1)
        b.press(.shiftUp)
        b.press(.delete)
        expectEqual(b.labels(id), ["apple", "fig", "pear"])
        expectEqual(b.undoName, "Delete Entry")
        expectEqual(b.focus, "row pear", "the caret to the row above")
    },
    test("⌘X with rows selected whole cuts them, ⌘V in another tally's row pastes them after it, one step; the caret at the end of the last") {
        let b = try Bench()
        let a = b.tally("a", ["one", "two", "three"])
        let c = b.tally("c", ["x", "y"], at: CGPoint(x: 400, y: 100))
        b.begin(a)
        b.press(.up, times: 2)
        b.press(.shiftDown, times: 2)
        b.press(.commandX)
        expectEqual(b.labels(a), ["one"])
        expectEqual(b.undoName, "Cut Entries")
        expectEqual(b.focus, "row one")
        b.press(.escape)
        b.begin(c)
        b.press(.up, times: 2)
        expectEqual(b.focus, "row x")
        b.press(.commandV)
        expectEqual(b.labels(c), ["x", "two", "three", "y"])
        expectEqual(b.undoName, "Paste Entries")
        expectEqual(b.focus, "row three")
        b.press(.down, times: 2)
        expectEqual(b.focus, "waiting")
        b.press(.commandV)
        expectEqual(b.labels(c), ["x", "two", "three", "y", "two", "three"], "on the waiting line, at its place; a second paste, copies")
        b.press(.escape)
        b.editor.undo()
        expectEqual(b.labels(c), ["x", "two", "three", "y"], "each paste one step")
    },
    test("A press on rows selected whole goes through to the canvas: the band hits nothing") {
        let b = try Bench()
        let id = b.tally("fruit", ["apple", "pear"])
        b.begin(id)
        b.press(.up)
        b.press(.shiftDown)
        let view = try require(b.view)
        let row = try require(b.editor.shapeContext.geometry(of: id)?.parts.frame(b.ids(id, "pear")[0])?.rect)
        let inView = b.canvas.convert(b.editor.camera.toView(CGPoint(x: row.midX, y: row.midY)), to: view.superview)
        expectEqual(view.hitTest(inView), nil)
    },
    test("Rows selected whole that another writer took out are no selection: the line takes typing again") {
        let b = try Bench()
        let id = b.tally("fruit", ["apple", "pear", "plum"])
        b.begin(id)
        b.press(.up, times: 2)
        b.press(.shiftDown)
        expect(b.field.isBanded)
        let gone = b.ids(id, "pear")
        b.editor.transact("Delete") { $0.update(id, as: Tally.self) { $0.props.rows.removeAll { gone.contains($0.id) } } }
        b.window.settle()
        expect(!b.field.isBanded && b.field.isEditable, "the line is the caret's again")
        expectEqual(b.view?.selectedRows, [])
        b.type("fig")
        b.press(.return)
        expectEqual(b.labels(id), ["apple", "plum", "pearfig"], "and takes what is typed, after the draft of the row that went (the line that had the caret)")
    },
    test("A real press on rows selected whole ends editing and makes them items; a release on one of several selects it alone, on the only one edits it there") {
        let b = try Bench()
        let id = b.tally("fruit", ["apple", "pear", "plum"])
        let pear = b.ids(id, "pear")[0], plum = b.ids(id, "plum")[0]
        @MainActor func press(on row: PartID) throws {
            let rect = try require(b.editor.shapeContext.geometry(of: id)?.parts.frame(row)?.rect)
            let point = b.editor.camera.toView(CGPoint(x: rect.midX, y: rect.midY))
            if let view = b.view {
                expectEqual(view.hitTest(b.canvas.convert(point, to: view.superview)), nil, "the band is not a hit: the press goes to the canvas")
            }
            b.canvas.mouseDown(with: b.window.mouse(.leftMouseDown, at: point, time: 100 + TimeInterval(b.window.contentView?.subviews.count ?? 0)))
            expectEqual(b.editor.editingShapeID, nil, "editing ended with the press")
            b.canvas.mouseUp(with: b.window.mouse(.leftMouseUp, at: point, time: 100.1))
        }
        b.begin(id)
        b.press(.up, times: 2)
        b.press(.shiftDown, times: 2)
        expectEqual(b.view?.selectedRows, [pear, plum])
        try press(on: pear)
        expectEqual(b.itemLabels, ["pear"], "a release on one of several selected rows selects it alone, as on shapes")
        expectEqual(b.editor.selectedShapeIDs, [id])
        b.begin(id)
        b.press(.up, times: 2)
        b.press(.shiftDown)
        expectEqual(b.view?.selectedRows, [pear])
        try press(on: pear)
        expectEqual(b.editor.editingShapeID, id, "a release on the only selected row edits it there")
        expectEqual(b.focus, "row pear")
    },
    test("Edit ▸ Paste is lit while rows are selected whole and rows this tally takes are on the pasteboard, and dim with none") {
        let b = try Bench()
        let id = b.tally("fruit", ["apple", "pear"])
        let paste = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "")
        b.begin(id)
        b.press(.up)
        b.press(.shiftDown)
        expect(b.field.isBanded)
        b.pasteboard.clearContents()
        expectEqual(b.field.validateUserInterfaceItem(paste), false, "nothing to paste")
        expect(b.editor.copyRows(b.ids(id, "apple"), of: id))
        expectEqual(b.field.validateUserInterfaceItem(paste), true, "rows the tally takes")
    },
])

@MainActor let rowItemTests = Suite("Entries as items of their tally", [
    test("A tally's items are its entries, said as VoiceOver says a line; Return edits the first there; ⌫ deletes them, the next selected; Undo brings them back selected") {
        let b = try Bench()
        let id = b.tally("fruit", ["apple 1", "pear", "plum"])
        expectEqual(b.editor.shapeItems(of: id).map(\.title), ["apple 1", "pear", "plum"].map { b.spoken($0) })
        b.editor.selectItems(b.ids(id, "pear").map(AnyHashable.init), of: id)
        b.press(.delete)
        expectEqual(b.labels(id), ["apple", "plum"])
        expectEqual(b.undoName, "Delete Entry")
        expectEqual(b.itemLabels, ["plum"], "the next one selected")
        b.editor.undo()
        expectEqual(b.itemLabels, ["pear"], "back, selected")
        b.press(.return)
        expectEqual(b.focus, "row pear", "Return edits it")
    },
    test("A fold hiding a selected entry moves the selection to the +N line standing for it; unfolded, the entry is selected again; one Escape goes to the tally") {
        let b = try Bench()
        let id = b.tally("fruit", ["apple 1", "pear", "plum", "fig"])
        b.editor.selectItems(b.ids(id, "plum").map(AnyHashable.init), of: id)
        b.editor.rowFolds?.fold([id])
        b.window.settle()
        expectEqual(b.itemLabels, ["+N"], "the +N line stands for it")
        expectEqual(b.editor.shapeItems(of: id).last?.outline, .closed)
        b.editor.rowFolds?.unfold([id])
        b.window.settle()
        expectEqual(b.itemLabels, ["plum"], "given back")
        b.editor.rowFolds?.fold([id])
        b.window.settle()
        b.press(.escape)
        expectEqual(b.editor.selectedItems, nil)
        expectEqual(b.editor.selectedShapeIDs, [id])
        b.editor.selectItems(b.editor.shapeItems(of: id).suffix(1).map(\.id), of: id)
        b.press(.right)
        expectEqual(b.editor.rowFolds?.isFolded(id), false, "→ on the +N line opens it")
    },
    test("The selection's menu with entries selected takes them out into a tally of their own, one step") {
        let b = try Bench()
        let id = b.tally("fruit", ["apple", "pear", "plum"])
        b.editor.selectItems(b.ids(id, "pear", "plum").map(AnyHashable.init), of: id)
        let menu = try require(b.h.secondaryClick(at: b.editor.camera.toView(CGPoint(x: 150, y: 140))))
        let item = try require(menu.items.first { $0.title == "Move Entries to New Tally" })
        b.editor.selectItems(b.ids(id, "pear", "plum").map(AnyHashable.init), of: id)
        menu.performActionForItem(at: menu.index(of: item))
        expectEqual(b.labels(id), ["apple"])
        expectEqual(b.undoName, "Move Entries to New Tally")
        expect(b.editor.selectedShapeIDs != [id])
    },
    test("A selected entry a fold hides shows as the +N line, and ⌫ and ⌥↑ act on the entry selected, never on the line that stands for it") {
        let b = try Bench()
        let id = b.tally("fruit", ["a 1", "b", "c 1", "d"])
        b.editor.selectItems(b.ids(id, "b").map(AnyHashable.init), of: id)
        b.editor.rowFolds?.fold([id])
        b.window.settle()
        expectEqual(b.itemLabels, ["+N"])
        expectEqual(b.editor.selectedItems?.acting.compactMap { $0.base as? PartID }, b.ids(id, "b"), "the keys act on b")
        b.press(.delete)
        expectEqual(b.labels(id), ["a", "c", "d"], "b went, nothing nobody selected")
        expectEqual(b.undoName, "Delete Entry")
    },
    test("A run of entries drawn out, selected all, or toggled on the canvas is counted aloud as the band counts it; a step to one other is not") {
        let b = try Bench()
        let id = b.tally("fruit", ["apple", "pear", "plum", "fig"])
        b.editor.selectItems(b.ids(id, "apple").map(AnyHashable.init), of: id)
        let heard = b.editor.announcements.count
        b.press(.down)
        expectEqual(Array(b.editor.announcements.dropFirst(heard)), [], "one to one: the focus says it")
        b.press(.shiftDown)
        expectEqual(b.editor.announcements.last, "2 entries selected")
        b.press(.commandA)
        expectEqual(b.editor.announcements.last, "4 entries selected")
        b.press(.shiftUp)
        expectEqual(b.editor.announcements.last, "3 entries selected", "drawn back")
    },
    test("Return on an entry selected edits it; Escape, ⌘↑ and ⌘↩ come out on the caret's entry selected again, one level; editing begun on the tally, or left on the waiting line, ends on the tally") {
        let b = try Bench()
        let id = b.tally("fruit", ["apple", "pear", "plum"])
        for key in [Chord.escape, Chord(Key.up, .command), Chord.commandReturn] {
            b.editor.selectItems(b.ids(id, "pear").map(AnyHashable.init), of: id)
            b.press(.return)
            expectEqual(b.focus, "row pear")
            b.press(key)
            expectEqual(b.editor.editingShapeID, nil)
            expectEqual(b.itemLabels, ["pear"], "\(key) lands on the entry Return went into")
        }
        b.press(.return)
        b.press(.down)
        b.press(.escape)
        expectEqual(b.itemLabels, ["plum"], "the entry the caret was on")
        b.press(.return)
        b.press(.down)
        expectEqual(b.focus, "waiting")
        b.press(.escape)
        expectEqual(b.editor.selectedItems, nil, "the waiting line is no entry: the tally")
        expectEqual(b.editor.selectedShapeIDs, [id])
        b.begin(id)
        b.press(.up)
        b.press(.escape)
        expectEqual(b.editor.selectedItems, nil, "begun on the tally, ended on the tally")
    },
    test("Home and End in a line go to the first and the last entry from any stop, the title's and the waiting line's too; each the other's way back") {
        let b = try Bench()
        let id = b.tally("fruit", (1...12).map { "e\($0)" })
        b.begin(id)
        expectEqual(b.focus, "waiting")
        b.press(Chord(Key.home))
        expectEqual(b.focus, "row e1", "one key to the top of twelve")
        b.press(Chord(Key.end))
        expectEqual(b.focus, "row e12")
        b.press(Chord(Key.home))
        expectEqual(b.focus, "row e1")
        b.type("x")
        b.press(Chord(Key.end))
        expectEqual(b.labels(id).first, "e1x", "the line left is written, as any key that leaves it")
    },
    test("A click on a closed header's words selects it as an item, said closed with what it hides; → says which group opened and how many, ← that it closed; its chevron opens it") {
        let b = try Bench()
        let id = b.tally("h", ["fruit/", "red", "green", "veg/", "kale"])
        let header = b.rows(id)[0].id
        b.editor.rowFolds?.setClosed(true, header: header, of: id)
        b.editor.selectedShapeIDs = [id]
        b.window.settle()
        let frame = try require(b.frame(id))
        let line = TallyLines.line(0, in: frame)
        b.h.click(at: b.h.view(CGPoint(x: line.midX, y: line.midY)))
        expectEqual(b.editor.selectedItems?.ids, [AnyHashable(header)], "the header selected as an item")
        expectEqual((b.editor.rowFolds?.fold(of: id)?.closed.contains(header) ?? false), true, "and still closed")
        let title = try require(b.editor.shapeItems(of: id).first?.title)
        expect(title.hasSuffix("closed, 2 entries"), "said closed, with what it hides: \(title)")
        b.press(.right)
        expectEqual((b.editor.rowFolds?.fold(of: id)?.closed.contains(header) ?? false), false)
        expectEqual(b.editor.announcements.last, "fruit/ opened, 2 entries")
        b.press(.left)
        expectEqual((b.editor.rowFolds?.fold(of: id)?.closed.contains(header) ?? false), true)
        expectEqual(b.editor.announcements.last, "fruit/ closed")
        b.editor.selectedShapeIDs = []
        b.h.click(at: b.h.view(CGPoint(x: line.minX + 4, y: line.midY)))
        expectEqual((b.editor.rowFolds?.fold(of: id)?.closed.contains(header) ?? false), false, "a click on its chevron opens it")
    },
    test("Rows another writer deletes leave the tally selected, not an invisible items selection") {
        let b = try Bench()
        let id = b.tally("fruit", ["apple", "pear"])
        b.editor.selectItems(b.ids(id, "pear").map(AnyHashable.init), of: id)
        let gone = b.ids(id, "pear")
        b.editor.transact("Delete") { $0.update(id, as: Tally.self) { $0.props.rows.removeAll { gone.contains($0.id) } } }
        expectEqual(b.editor.selectedItems, nil, "none listed: none selected")
        expectEqual(b.editor.selectedShapeIDs, [id])
        b.press(.delete)
        expect(b.editor.document[id] == nil, "Delete is the tally's again, as the outline says")
    },
])

extension Bench {
    /// What the tally grammar says of a line, as VoiceOver does.
    func spoken(_ line: String) -> String {
        let grammar = TallyGrammar()
        guard let row = grammar.read(LineText(line), id: PartID(), in: LineContext(editor: editor, shape: ShapeID())).row else { return line }
        return grammar.spoken(row, in: LineContext(editor: editor, shape: ShapeID()))
    }
}

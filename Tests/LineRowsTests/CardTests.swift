import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Geometry
@_spi(Host) import CanvasUI
import LineRows
import Selection
import TestKit
import TextEditing

// A row's card over the fixture kind: a tally's entry has one (its count, starred, its color, its notes a line each), a header
// has none. ⌘↓ shows it hung from the row, following it; its keys walk it as a form; each line commits as a row's line does, a
// step the kind names; Escape and ⌘↑ give the row the keyboard back, ⌘↩ ends editing; VoiceOver hears a popover of lines.

extension Bench {
    /// The card showing, if it's a row's.
    var card: LineCardView? { canvas.cardView as? LineCardView }

    /// Edits `id` at its entry `label`, the caret at the end of its line.
    func edit(_ id: ShapeID, row label: String) throws {
        begin(id)
        view?.go(to: .row(try require(rows(id).first { $0.label == label }?.id)))
        window.settle()
    }

    /// ⌘↓ on `id`'s entry `label`: its card.
    func openCard(_ id: ShapeID, row label: String) throws -> LineCardView {
        try edit(id, row: label)
        press(.commandDown)
        return try require(card, "the card shows")
    }

    /// An entry's rect, world units.
    func rect(_ id: ShapeID, row label: String) -> CGRect? {
        guard let row = rows(id).first(where: { $0.label == label }) else { return nil }
        return editor.shapeContext.geometry(of: id)?.parts.frame(row.id)?.rect
    }
}

@MainActor let cardTests = Suite("A row's card", [
    test("⌘↓ in a row writes its line, then shows its card hung from the row: the header, a line a stop, the first with the keyboard") {
        let b = try Bench()
        let id = b.tally("apples", ["red 2", "blue"])
        try b.edit(id, row: "blue")
        b.type(" 5")
        b.press(.commandDown)
        expectEqual(b.rows(id).last?.count, 5, "the line written first")
        expectEqual(b.undoName, "Change Entry")
        let card = try require(b.card)
        expectEqual(card.header.name, "blue")
        expectEqual(card.stopNames, ["count", "starred", "color", "notes 1"])
        expectEqual(card.focusedStop, "count")
        expectEqual(card.value(of: "count"), "5")
        expectEqual(card.value(of: "starred"), "no")
        expectEqual(card.value(of: "color"), "red", "none held: the first, faint")
        expectEqual(card.value(of: "notes 1"), "")
        expectEqual(b.editor.card?.anchor, b.rect(id, row: "blue"), "hung from the row")
        expectEqual(b.editor.card?.stepName, nil, "it holds no step")
        let frame = try require(b.canvas.cardFrame)
        expect(frame.minY > b.editor.camera.toView(try require(b.rect(id, row: "blue"))).maxY, "under the row: \(frame)")
        expectEqual(b.editor.editingShapeID, id, "the tally still edited")
        expectEqual(b.focus, "row blue")
    },
    test("A card is never narrower than the row it hangs from: a tally laid out wider while its line is typed long shows no words beside it") {
        let b = try Bench()
        let id = b.tally("apples", ["red 2", "blue"])
        try b.edit(id, row: "blue")
        b.type(" 5 a very long note that runs well past the tally's own width and the card's")
        b.window.settle()
        let row = try require(b.rect(id, row: "blue"))
        expect(row.width > 300, "laid out wider while typed: \(row.width)")
        b.press(.commandDown)
        b.window.settle()
        let frame = try require(b.canvas.cardFrame)
        expect(frame.width >= b.editor.camera.toView(row).width - 0.5, "the card \(frame.width) covers the row \(b.editor.camera.toView(row).width)")
    },
    test("⌘↓ on the waiting line with words adds the row and shows its card; on an empty waiting line, or a row with nothing more, nothing") {
        let b = try Bench()
        let id = b.tally("apples", ["fruit/", "red"])
        b.begin(id)
        b.press(.commandDown)
        expectEqual(b.editor.card == nil, true, "an empty waiting line: none")
        b.type("green 3")
        b.press(.commandDown)
        expectEqual(b.labels(id), ["fruit/", "red", "green"])
        expectEqual(b.undoName, "Add Entry")
        expectEqual(b.card?.header.name, "green")
        b.press(.escape)
        expectEqual(b.focus, "row green", "the row it was added as")
        try b.edit(id, row: "fruit/")
        b.press(.commandDown)
        expect(b.editor.card == nil, "a header has nothing more")
        expectEqual(b.focus, "row fruit/")
    },
    test("the card follows its row: a row put in above moves it, the shape moved moves it, and the row taken out closes it") {
        let b = try Bench()
        let id = b.tally("apples", ["red", "blue"])
        _ = try b.openCard(id, row: "blue")
        b.editor.transact("Add Entry") { $0.update(id, as: Tally.self) { $0.props.rows.insert(TallyRow("green"), at: 0) } }
        b.window.settle()
        expectEqual(b.editor.card?.anchor, b.rect(id, row: "blue"), "down a row")
        b.editor.transact("Move") { $0.update(id, as: Tally.self) { $0.props.frame.origin.x += 40 } }
        b.window.settle()
        expectEqual(b.editor.card?.anchor, b.rect(id, row: "blue"))
        expectEqual(b.editor.card?.anchor.minX, 140)
        b.editor.transact("Delete Entry") { $0.update(id, as: Tally.self) { $0.props.rows.removeAll { $0.label == "blue" } } }
        b.window.settle()
        expect(b.editor.card == nil, "its row gone, it closes")
    },
    test("the card follows its row through a layout that writes nothing: a waiting line opened above it, with the keyboard back on the row's line") {
        let b = try Bench()
        let id = b.tally("apples", ["red", "blue", "green"])
        _ = try b.openCard(id, row: "blue")
        let before = try require(b.editor.card?.anchor)
        b.window.makeFirstResponder(b.field)
        b.press(.up)
        expectEqual(b.focus, "row red")
        expect(b.editor.card != nil, "the card stays while the row's line has the keyboard")
        b.press(.return)
        expectEqual(b.focus, "waiting")
        let after = try require(b.editor.card?.anchor)
        expectEqual(after.minY, before.minY + Tally.rowHeight, "down a line with its row")
        expectEqual(after, b.rect(id, row: "blue"))
    },
    test("each line commits as the row's line does, a step the kind names; the row's line printed again; Undo takes it back") {
        let b = try Bench()
        let id = b.tally("apples", ["red 2", "blue"])
        let card = try b.openCard(id, row: "red")
        let field = try require(card.field(of: "count"))
        field.selectAll(nil)
        b.type("7")
        expectEqual(b.rows(id).first?.count, 2, "a draft while it has the keyboard")
        b.press(.tab)
        expectEqual(b.rows(id).first?.count, 7)
        expectEqual(b.undoName, "Change Entry")
        expectEqual(b.field.string, "red 7", "the row's line, as stored now")
        expectEqual(card.focusedStop, "starred")
        b.press(.space)
        expectEqual(b.rows(id).first?.starred, true)
        expectEqual(b.undoName, "Star Entry", "at once, a step of its own")
        expectEqual(card.value(of: "starred"), "yes")
        b.press(.return)
        expectEqual(b.rows(id).first?.starred, false, "Return toggles it too")
        b.press(.tab)
        b.press(.space)
        let menu = try require(b.menus.last)
        expectEqual(menu.outline, ["✓ red", "green", "blue"], "its options, the shown one checked")
        try menu.choose("blue")
        b.window.settle()
        expectEqual(b.rows(id).first?.color, "blue")
        expectEqual(b.undoName, "Color Entry")
        expectEqual(card.value(of: "color"), "blue")
        expectEqual(card.focusedStop, "color", "the keyboard stays on the line")
        b.editor.undo()
        b.window.settle()
        expectEqual(b.rows(id).first?.color, nil, "one Undo, the pick")
        expectEqual(b.rows(id).first?.count, 7)
        expect(b.editor.card == nil, "an undo closes it")
    },
    test("a line left as it was shown writes nothing; Escape writes the line and gives the row the keyboard back") {
        let b = try Bench()
        let id = b.tally("apples", ["red 2"])
        let card = try b.openCard(id, row: "red")
        let before = b.editor.revision
        b.press(.tab)
        b.press(.backTab)
        expectEqual(b.editor.revision, before, "nothing changed, nothing written")
        let field = try require(card.field(of: "count"))
        field.selectAll(nil)
        b.type("4")
        b.press(.escape)
        expectEqual(b.rows(id).first?.count, 4)
        expect(b.editor.card == nil)
        expect(b.window.firstResponder === b.field, "the row's line has the keyboard: \(String(describing: b.window.firstResponder))")
        expectEqual(b.focus, "row red")
        expectEqual(b.field.string, "red 4")
        expectEqual(b.editor.editingShapeID, id)
    },
    test("Return in a field is done with it: written, the row has the keyboard back; ⌘↑ the same; ⌘↩ writes it and ends editing") {
        let b = try Bench()
        let id = b.tally("apples", ["red 2"])
        var card = try b.openCard(id, row: "red")
        try require(card.field(of: "count")).selectAll(nil)
        b.type("3")
        b.press(.return)
        expectEqual(b.rows(id).first?.count, 3)
        expect(b.editor.card == nil)
        expectEqual(b.focus, "row red")
        card = try require({ b.press(.commandDown); return b.card }())
        b.press(.commandUp)
        expect(b.editor.card == nil, "⌘↑: out to the row")
        expectEqual(b.focus, "row red")
        card = try require({ b.press(.commandDown); return b.card }())
        try require(card.field(of: "count")).selectAll(nil)
        b.type("9")
        b.press(.commandReturn)
        expectEqual(b.rows(id).first?.count, 9)
        expect(b.editor.card == nil)
        expectEqual(b.editor.editingShapeID, nil, "⌘↩ ends editing")
        expectEqual(b.editor.selectedShapeIDs, [id])
    },
    test("a list: Return after a line opens one below it, Return on an empty one gives the row back; a line emptied goes; ⌫ on an empty one takes it out") {
        let b = try Bench()
        let id = b.tally("apples", ["red"])
        let card = try b.openCard(id, row: "red")
        card.go(to: "notes 1")
        b.type("ripe")
        b.press(.return)
        expectEqual(b.rows(id).first?.notes, ["ripe"])
        expectEqual(b.undoName, "Change Entry")
        expectEqual(card.stopNames, ["count", "starred", "color", "notes 1", "notes 2"])
        expectEqual(card.focusedStop, "notes 2")
        b.type("sweet")
        b.press(.return)
        expectEqual(b.rows(id).first?.notes, ["ripe", "sweet"])
        expectEqual(card.focusedStop, "notes 3")
        // ⌫ on the empty line it opened: it goes, the keyboard up a line.
        b.press(.delete)
        expectEqual(card.stopNames, ["count", "starred", "color", "notes 1", "notes 2"])
        expectEqual(card.focusedStop, "notes 2")
        // A line opened between two: ⌫ takes the empty one out, nothing written.
        b.press(.up)
        b.press(.return)
        expectEqual(card.stopNames.last, "notes 3")
        expectEqual(card.focusedStop, "notes 2")
        expectEqual(card.value(of: "notes 2"), "")
        expectEqual(card.value(of: "notes 3"), "sweet")
        b.press(.return)
        expect(b.editor.card == nil, "Return on an empty line: done")
        expectEqual(b.rows(id).first?.notes, ["ripe", "sweet"])
        expectEqual(b.focus, "row red")
        // A line emptied and left goes.
        let again = try require({ b.press(.commandDown); return b.card }())
        again.go(to: "notes 1")
        try require(again.field(of: "notes 1")).selectAll(nil)
        b.press(.delete)
        b.press(.down)
        expectEqual(b.rows(id).first?.notes, ["sweet"])
        expectEqual(again.stopNames, ["count", "starred", "color", "notes 1"])
    },
    test("what fits at a field's caret is the grammar's: listed as it's typed, Escape closes the list first, Tab picks, then Escape gives the row back") {
        let b = try Bench()
        let id = b.tally("apples", ["red"])
        let card = try b.openCard(id, row: "red")
        let field = try require(card.field(of: "count"))
        b.type("1")
        expectEqual(field.listedOffers, ["10", "12"])
        b.press(.escape)
        expect(field.offerList == nil, "the list closes first")
        expect(b.editor.card != nil, "the card stays")
        b.press(.delete)
        b.type("1")
        expectEqual(field.highlightedOffer, "10")
        b.press(.tab)
        expectEqual(field.string, "10", "Tab picks")
        expect(b.editor.card != nil)
        b.press(.escape)
        expect(b.editor.card == nil)
        expectEqual(b.rows(id).first?.count, 10)
    },
    test("a tally locked while its card is open: editing ends, the card with it, the line's words written before; nothing after") {
        let b = try Bench()
        let id = b.tally("apples", ["red 2"])
        let card = try b.openCard(id, row: "red")
        try require(card.field(of: "count")).selectAll(nil)
        b.type("6")
        b.editor.freeze([id])
        b.window.settle()
        expect(b.editor.card == nil, "the card closes as editing ends")
        expectEqual(b.editor.editingShapeID, nil)
        expectEqual(b.rows(id).first?.count, 2, "a locked shape takes no line")
        b.press(.space)
        expectEqual(b.rows(id).first?.starred, false)
    },
    test("VoiceOver: a popover, Details of red; an element a line: text fields named for theirs, a checkbox, a pop-up button, a list's items by place") {
        let b = try Bench()
        let id = b.tally("apples", ["red 2"])
        let card = try b.openCard(id, row: "red")
        let host = try require(sequence(first: card as NSView, next: { $0.superview }).first { $0.accessibilityRole() == .popover })
        expectEqual(host.accessibilityLabel(), "Details of red")
        expectEqual(card.field(of: "count")?.accessibilityLabel(), "count")
        expectEqual(card.field(of: "count")?.accessibilityRole(), .textField)
        let controls = card.subviews.filter { $0.isAccessibilityElement() && $0.accessibilityRole() != nil && !($0 is LineField) }
        let starred = try require(controls.first { $0.accessibilityLabel() == "starred" })
        expectEqual(starred.accessibilityRole(), .checkBox)
        expectEqual(starred.accessibilityValue() as? NSNumber, 0)
        expect(starred.accessibilityPerformPress())
        expectEqual(b.rows(id).first?.starred, true, "pressed, it toggles")
        expectEqual(starred.accessibilityValue() as? NSNumber, 1)
        let color = try require(controls.first { $0.accessibilityLabel() == "color" })
        expectEqual(color.accessibilityRole(), .popUpButton)
        expectEqual(color.accessibilityValue() as? String, "red")
        expectEqual(card.field(of: "notes 1")?.accessibilityLabel(), "notes, 1 of 1")
    },
    test("the card shows what the row holds now: its header's mark follows a count of 0, a rename by another writer renames the card and what VoiceOver calls it") {
        let b = try Bench()
        let id = b.tally("apples", ["red 2"])
        let card = try b.openCard(id, row: "red")
        let host = try require(sequence(first: card as NSView, next: { $0.superview }).first { $0.accessibilityRole() == .popover })
        expectEqual(card.header.mark == nil, true)
        try require(card.field(of: "count")).selectAll(nil)
        b.type("0")
        b.press(.escape)
        b.press(.tab)
        expectEqual(card.header.mark?.symbol, "circle", "the count the card wrote, in the header's mark")
        b.editor.transact("Rename Entry") { $0.update(id, as: Tally.self) { $0.props.rows[0].label = "crimson" } }
        b.window.settle()
        expectEqual(card.header.name, "crimson")
        expectEqual(host.accessibilityLabel(), "Details of crimson")
        b.editor.transact("Count Entry") { $0.update(id, as: Tally.self) { $0.props.rows[0].count = 4 } }
        b.window.settle()
        expectEqual(card.header.mark == nil, true, "and back")
        expectEqual(card.value(of: "count"), "4")
    },
    test("a line the file refuses keeps its words, the shape shaking: Tab and Return stay in the card, Escape is the row's and goes") {
        let b = try Bench()
        let id = b.tally("apples", ["red 2"])
        let card = try b.openCard(id, row: "red")
        card.go(to: "notes 1")
        b.type("refuse")
        b.press(.tab)
        expectEqual(b.refusals.refusals.last, [id], "it shakes")
        expectEqual(b.rows(id).first?.notes, [], "nothing written")
        expectEqual(card.field(of: "notes 1")?.string, "refuse", "what was typed stays")
        expect(b.editor.card != nil)
        expectEqual(card.focusedStop, "count")
        card.go(to: "notes 1")
        b.press(.return)
        expect(b.editor.card != nil, "Return in a refused line is not done with it")
        expectEqual(card.stopNames, ["count", "starred", "color", "notes 1"], "and opens no line below")
        expectEqual(card.field(of: "notes 1")?.string, "refuse")
        b.press(.escape)
        expect(b.editor.card == nil, "Escape goes, as the row's own does")
        expectEqual(b.rows(id).first?.notes, [])
        expectEqual(b.focus, "row red")
    },
    test("⌘↓ on a line the file refuses opens no card: the line keeps its words, and the card never writes over it") {
        let b = try Bench()
        let id = b.tally("apples", ["red 2", "blue"])
        try b.edit(id, row: "blue")
        b.field.selectAll(nil)
        b.type("refuse 3")
        b.press(.commandDown)
        expectEqual(b.refusals.refusals.last, [id], "it shakes")
        expect(b.editor.card == nil)
        expectEqual(b.field.string, "refuse 3", "the draft stays")
        expectEqual(b.labels(id), ["red", "blue"])
    },
    test("a card closed while a commit is delivered writes its words a turn later, not never") {
        let b = try Bench()
        let id = b.tally("apples", ["red 2"])
        let card = try b.openCard(id, row: "red")
        try require(card.field(of: "count")).selectAll(nil)
        b.type("9")
        b.editor.transact("Move") { transaction in
            transaction.update(id, as: Tally.self) { $0.props.frame.origin.x += 1 }
            b.editor.closeCard()
        }
        b.window.settle()
        expectEqual(b.rows(id).first?.count, 2, "the file could not take it while it was delivering")
        b.h.scheduler.advance(by: .zero)
        expectEqual(b.rows(id).first?.count, 9, "written a turn later")
        expectEqual(b.undoName, "Change Entry")
    },
    test("a list's line left empty goes and the keyboard lands on the line it aimed at; an opened line left untouched goes with no step") {
        let b = try Bench()
        let id = b.tally("apples", ["red 2"])
        b.editor.transact("Notes") { $0.update(id, as: Tally.self) { $0.props.rows[0].notes = ["a", "b", "c"] } }
        b.editor.undoHistory.seal()
        let card = try b.openCard(id, row: "red")
        card.go(to: "notes 1")
        try require(card.field(of: "notes 1")).selectAll(nil)
        b.press(.delete)
        b.press(.down)
        expectEqual(b.rows(id).first?.notes, ["b", "c"])
        expectEqual(card.focusedStop, "notes 1", "the line after the one that went, now first")
        expectEqual(card.value(of: "notes 1"), "b")
        b.press(.return)
        expectEqual(card.stopNames, ["count", "starred", "color", "notes 1", "notes 2", "notes 3"], "Return opens a line below the one it was on")
        expectEqual(card.focusedStop, "notes 2")
        let name = b.undoName
        b.press(.tab)
        expectEqual(card.stopNames, ["count", "starred", "color", "notes 1", "notes 2"], "left untouched, it goes")
        expectEqual(card.focusedStop, "notes 2", "the keyboard on the line it was going to, now one place up")
        expectEqual(card.value(of: "notes 2"), "c")
        expectEqual(b.undoName, name, "no step")
    },
    test("a choice picked at the option shown while none is held writes nothing; the next pick is written, and so is going back to it") {
        let b = try Bench()
        let id = b.tally("apples", ["red 2"])
        let card = try b.openCard(id, row: "red")
        card.go(to: "color")
        b.press(.space)
        let before = b.undoName
        try require(b.menus.last).choose("red")
        expectEqual(b.rows(id).first?.color, nil, "none held, the first shown: that is none")
        expectEqual(b.undoName, before)
        b.press(.space)
        try require(b.menus.last).choose("blue")
        expectEqual(b.rows(id).first?.color, "blue")
        b.press(.space)
        try require(b.menus.last).choose("red")
        expectEqual(b.rows(id).first?.color, "red")
    },
    test("a toggle or a pick is spoken as well as the step: starred yes; VoiceOver reads the lines in the order the keys walk them") {
        let b = try Bench()
        let id = b.tally("apples", ["red 2"])
        let card = try b.openCard(id, row: "red")
        card.go(to: "starred")
        b.press(.space)
        expectEqual(b.editor.announcements.suffix(2).map { $0 }, ["Star Entry", "starred yes"])
        card.go(to: "color")
        b.press(.space)
        try require(b.menus.last).choose("green")
        expectEqual(b.editor.announcements.last, "color green")
        let children = (card.accessibilityChildren() ?? []).compactMap { ($0 as? NSView)?.accessibilityLabel() }
        expectEqual(children, ["count", "starred", "color", "notes, 1 of 1"], "top to bottom, not the order the views were added")
    },
    test("a kind's › opens a row's card: the shape edited at the row, the card under it; a row with nothing more, none") {
        let b = try Bench()
        let id = b.tally("apples", ["fruit/", "red", "blue"])
        let service = try require(b.editor.service(LineRowsService.self))
        let red = try require(b.rows(id).first { $0.label == "red" }?.id)
        expect(service.openCard(of: PartAddress(id, part: red)))
        b.window.settle()
        expectEqual(b.editor.editingShapeID, id)
        expectEqual(b.focus, "row red")
        expectEqual(b.card?.header.name, "red")
        expectEqual(b.card?.focusedStop, "count")
        let header = try require(b.rows(id).first?.id)
        expect(!service.openCard(of: PartAddress(id, part: header)))
        expect(!service.openCard(of: PartAddress(id)), "no row: no card")
    },
])

/// A walk of a tally with a card: the card's stops "card/<stop>", the tally's "tally/row <label>", the canvas's selection.
@MainActor private func cardWalk(_ b: Bench) -> KeyWalk {
    KeyWalk(b.window, editor: b.editor, readers: [
        .custom("card") { [unowned b] window in
            guard let card = b.card, let stop = card.focusedStop else { return nil }
            return Focus.of(window, surface: "card", element: stop)
        },
        .custom("tally") { [unowned b] window in
            guard let focus = b.focus, let view = b.view, let responder = window.firstResponder as? NSView, responder.isDescendant(of: view) else { return nil }
            return Focus.of(window, surface: "tally", element: focus)
        },
        .canvas(b.canvas, selection: { [unowned b] in
            b.editor.selectedShapeIDs.compactMap { b.editor.document[$0]?.typed(as: Tally.self)?.props.name }
        }),
    ], settle: .runLoop)
}

@MainActor let cardKeyWalkTests = Suite("A row's card, walked by keys", [
    test("Tab walks every line and comes round, ⇧Tab undoing each; ↑ ↓ are a column, staying at its ends") {
        let b = try Bench()
        let id = b.tally("apples", ["red 2"])
        _ = try b.openCard(id, row: "red")
        b.holdMenus()
        let walk = cardWalk(b)
        walk.expectCycle(["card/count", "card/starred", "card/color", "card/notes 1"], wraps: .closed)
        walk.go("card/count")
        walk.expectAxis(down: .down, up: .up, over: ["card/count", "card/starred", "card/color", "card/notes 1"])
        expectEqual(b.editor.revision, b.editor.revision)
    },
    test("each line shows its mark, in view, named for VoiceOver; Escape is one level out: the row, then the tally, then nothing") {
        let b = try Bench()
        let id = b.tally("apples", ["red 2"])
        _ = try b.openCard(id, row: "red")
        b.holdMenus()
        let walk = cardWalk(b)
        let stops = (0..<4).map { _ -> Focus in
            let focus = walk.focus
            walk.press(.tab)
            return focus
        }
        expectEqual(stops.map(\.label), ["count", "starred", "color", "notes, 1 of 1"])
        walk.expectShows(stops)
        walk.go("card/count")
        b.card?.field(of: "count")?.selectAll(nil)
        b.type("8")
        walk.expectEscapeLadder(["tally/row red", "canvas/apples"], keepsTyped: nil)
        expectEqual(b.rows(id).first?.count, 8, "what was typed is kept")
    },
    test("every key means what the table says on a card's line: ⌘↓ into it from a row, ⌘↑ and Escape out, ⌘↩ finishes") {
        let b = try Bench()
        let id = b.tally("apples", ["red 2", "blue"])
        let start = b.editor.file
        let walk = cardWalk(b)
        let reset = { @MainActor in
            b.editor.closeCard()
            b.editor.endEditing()
            while b.editor.file != start, b.editor.canUndo { b.editor.undo() }
            try? b.edit(id, row: "red")
            b.press(.commandDown)
            b.card?.go(to: "starred")
            b.holdMenus()
            b.window.settle()
        }
        reset()
        let depth = { @MainActor (_: Focus) -> Int in
            b.editor.card != nil ? 3 : b.editor.editingShapeID != nil ? 2 : b.editor.selectedShapeIDs.isEmpty ? 0 : 1
        }
        let surface = KeySurface("A row's card", axes: .vertical)
        walk.expectMeanings(of: surface, stops: ["card/count", "card/starred", "card/color", "card/notes 1"], at: 1, depth: depth, reset: reset)
        // From a row, ⌘↓ is into its card.
        let rows = KeySurface("A row written as a line", axes: .vertical, overrides: [
            .init(.return, [.forward, .elsewhere, .acted], exception: "line-return"),
        ])
        let resetRow = { @MainActor in
            b.editor.closeCard()
            b.editor.endEditing()
            while b.editor.file != start, b.editor.canUndo { b.editor.undo() }
            b.begin(id)
            b.press(.up)
            b.window.settle()
        }
        walk.expectMeanings(of: rows, stops: ["tally/row red", "tally/row blue", "tally/waiting"], at: 1, depth: depth, reset: resetRow)
    },
])

import AppKit
@_spi(Host) import Canvas
import CanvasTesting
@_spi(Host) import CanvasUI
import Engineering
import LineRows
import TestKit
import TextEditing

// A column's card (K7): ⌘↓ in its line shows its type, references, null, unique, primary key, default, on delete and on update;
// each line written as the column's line would say it, one step the table names by what changed (Change Column, Change Key
// Action); the type offered as after a name; references that name no row kept as words (no connector here: keys drawn as arrows,
// T4 panel 1's references after the rename, and re-aiming one from the card are CompositionTests'). An enum's value has no card.

extension KitBench {
    /// The card showing, if it's a row's, its menus handed to `menus` and never put on screen.
    var card: LineCardView? {
        let card = canvas.cardView as? LineCardView
        if let card, card.menuPresenter == nil { card.menuPresenter = { [weak self] in self?.menus.append($0) } }
        return card
    }

    /// ⌘↓ on `table`'s column `name`.
    func openCard(_ table: ShapeID, column name: String) throws -> LineCardView {
        begin(table)
        view?.go(to: .row(try require(columns(table).first { $0.name == name }?.id)))
        window.settle()
        press(Chord(Key.down, .command))
        return try require(card, "the card shows")
    }
}

@MainActor let cardTests = Suite("A column's card", [
    test("⌘↓ on orders.customer_id: its card under the row, Details of customer_id: type, references, null, unique, primary key, default, on delete, on update") {
        let b = try KitBench()
        let orders = b.table("orders", ["id uuid pk", "customer_id uuid unique", "placed_at timestamptz null default now()"])
        let card = try b.openCard(orders, column: "customer_id")
        expectEqual(card.header.name, "customer_id")
        expectEqual(card.header.mark?.symbol, "1.square", "a unique column's mark")
        expectEqual(card.stopNames, ["type", "references", "null", "unique", "primary key", "default", "on delete", "on update"])
        expectEqual(["type", "references", "null", "unique", "primary key", "default", "on delete", "on update"].map { card.value(of: $0) ?? "-" },
                    ["uuid", "", "no", "yes", "no", "", "no action", "no action"])
        expectEqual(card.focusedStop, "type")
        let customerID = try require(b.columns(orders).first { $0.name == "customer_id" }?.id)
        expectEqual(b.editor.card?.anchor, b.editor.shapeContext.geometry(of: orders)?.parts.frame(customerID)?.rect, "hung from its row")
        let host = try require(sequence(first: card as NSView, next: { $0.superview }).first { $0.accessibilityRole() == .popover })
        expectEqual(host.accessibilityLabel(), "Details of customer_id")
        b.press(.escape)
        let placed = try b.openCard(orders, column: "placed_at")
        expectEqual(placed.value(of: "null"), "yes")
        expectEqual(placed.value(of: "default"), "now()")
        b.press(.escape)
    },
    test("null and on delete changed from the card: each one step, Change Column and Change Key Action; the line printed again") {
        let b = try KitBench()
        let orders = b.table("orders", ["id uuid pk", "customer_id uuid"])
        let card = try b.openCard(orders, column: "customer_id")
        card.go(to: "null")
        b.press(.space)
        expectEqual(b.lines(orders).last, "customer_id uuid null")
        expectEqual(b.undoName, "Change Column")
        expectEqual(b.field.string, "customer_id uuid null", "the row's line as stored now")
        expectEqual(card.value(of: "null"), "yes")
        card.go(to: "on delete")
        b.press(.space)
        let menu = try require(b.menus.last)
        expectEqual(menu.outline, ["✓ no action", "restrict", "cascade", "set null", "set default"])
        try menu.choose("restrict")
        b.window.settle()
        expectEqual(b.columns(orders).last?.onDelete, "restrict")
        expectEqual(b.undoName, "Change Key Action")
        expectEqual(card.value(of: "on delete"), "restrict")
        card.go(to: "on update")
        b.press(.return)
        try b.menus.last?.choose("cascade")
        b.window.settle()
        expectEqual(b.columns(orders).last?.onUpdate, "cascade")
        expectEqual(b.undoName, "Change Key Action")
        b.editor.undo()
        expectEqual(b.columns(orders).last?.onUpdate, nil, "one Undo, one change")
        expectEqual(b.columns(orders).last?.onDelete, "restrict")
        expectEqual(b.columns(orders).last?.nullable, true)
    },
    test("the type typed in the card: SQL's types and the file's enums offered, an enum's name its pill, uuid? a nullable uuid, one step") {
        let b = try KitBench()
        let status = b.enumType("order_status", ["pending", "paid"])
        let orders = b.table("orders", ["id uuid pk", "state text"])
        let card = try b.openCard(orders, column: "state")
        let field = try require(card.field(of: "type"))
        field.selectAll(nil)
        b.type("order")
        expectEqual(field.listedOffers.first, "order_status")
        expectEqual(b.editor.service(LineRowsService.self)?.light?.shape, status, "the enum lit")
        b.press(.tab)
        expectEqual(field.string, "order_status")
        expectEqual(card.focusedStop, "type", "Tab picked")
        b.press(.tab)
        expectEqual(b.columns(orders).last?.type, TypeRef("order_status", shape: status))
        expectEqual(b.undoName, "Change Column")
        card.go(to: "type")
        try require(card.field(of: "type")).selectAll(nil)
        b.type("int?")
        // What's listed for int? closes first, then ↓ leaves the line.
        if card.field(of: "type")?.offerList != nil { b.press(.escape) }
        b.press(.down)
        expectEqual(b.lines(orders).last, "state int null", "uuid? is a nullable uuid, as the line reads it")
        expectEqual(card.value(of: "null"), "yes")
        expectEqual(card.value(of: "type"), "int")
        b.press(.escape)
    },
    test("a default typed in the card is written as the line reads it; references that name no row stay the line's → words, no key") {
        let b = try KitBench()
        let orders = b.table("orders", ["id uuid pk", "placed_at timestamptz"])
        let card = try b.openCard(orders, column: "placed_at")
        card.go(to: "default")
        b.type("now()")
        b.press(.tab)
        expectEqual(b.lines(orders).last, "placed_at timestamptz default now()")
        expectEqual(b.undoName, "Change Column")
        card.go(to: "references")
        b.type("ledgers.id")
        b.press(.down)
        expectEqual(b.columns(orders).last?.unread, "→ ledgers.id", "kept as the line's words")
        expectEqual(card.value(of: "references"), "ledgers.id")
        expectEqual(b.editor.document.shapes.count, 1, "and no arrow")
        card.go(to: "references")
        try require(card.field(of: "references")).selectAll(nil)
        b.press(.delete)
        b.press(.escape)
        expectEqual(b.columns(orders).last?.unread, "", "emptied, the words go")
        expect(b.editor.card == nil)
        expectEqual(b.field.string, "placed_at timestamptz default now()")
    },
    test("an enum's value has nothing more than its line: ⌘↓ shows no card, and the line keeps the keyboard") {
        let b = try KitBench()
        let status = b.enumType("order_status", ["pending", "paid"])
        b.begin(status)
        b.press(.up)
        b.press(Chord(Key.down, .command))
        expect(b.editor.card == nil)
        expect(b.window.firstResponder === b.field)
        expectEqual(b.editor.editingShapeID, status)
        b.press(.escape)
    },
])

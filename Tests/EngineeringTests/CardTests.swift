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
    test("the card's type line offers a type of several words as the row's line does: typed past its first word (UX walk 4 tables-4-3)") {
        let b = try KitBench()
        let orders = b.table("orders", ["id uuid pk", "ratio text"])
        let card = try b.openCard(orders, column: "ratio")
        let field = try require(card.field(of: "type"))
        field.selectAll(nil)
        b.type("double p")
        expect(field.listedOffers.contains("double precision"), "\(field.listedOffers)")
        expect(!field.listedOffers.contains("timestamp with time zone"), "\(field.listedOffers)")
    },
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
    test("unique, primary key and on update changed from the card: each one step, the header's mark following, the line printed again") {
        let b = try KitBench()
        let orders = b.table("orders", ["id uuid pk", "email text"])
        let card = try b.openCard(orders, column: "email")
        expectEqual(card.header.mark == nil, true)
        card.go(to: "unique")
        b.press(.space)
        expectEqual(b.columns(orders).last?.unique, true)
        expectEqual(b.undoName, "Change Column")
        expectEqual(card.header.mark?.symbol, "1.square")
        expectEqual(b.field.string, b.lines(orders).last, "the row's line as stored now")
        expect(b.lines(orders).last?.contains("unique") == true, "\(b.lines(orders))")
        card.go(to: "primary key")
        b.press(.space)
        expectEqual(b.columns(orders).last?.primaryKey, true)
        expectEqual(b.undoName, "Change Column")
        expectEqual(card.header.mark?.symbol, "key.horizontal", "a primary key's mark before a unique's")
        expectEqual(card.value(of: "primary key"), "yes")
        b.press(.space)
        expectEqual(b.columns(orders).last?.primaryKey, false)
        expectEqual(card.header.mark?.symbol, "1.square")
        card.go(to: "unique")
        b.press(.space)
        expectEqual(card.header.mark == nil, true)
        card.go(to: "on update")
        b.press(.space)
        let menu = try require(b.menus.last)
        expectEqual(menu.outline, ["✓ no action", "restrict", "cascade", "set null", "set default"])
        let undoName = b.undoName
        try menu.choose("no action")
        expectEqual(b.columns(orders).last?.onUpdate, nil, "the option shown while none is held is none")
        expectEqual(b.undoName, undoName)
        b.press(.space)
        try require(b.menus.last).choose("set null")
        b.window.settle()
        expectEqual(b.columns(orders).last?.onUpdate, "set null")
        expectEqual(b.undoName, "Change Key Action")
        expectEqual(card.value(of: "on update"), "set null")
        expectEqual(b.editor.announcements.last, "on update set null")
        b.press(.escape)
    },
    test("the card's reading order and look: the lines in the order the keys walk them, its pills in colors that follow the appearance") {
        let b = try KitBench()
        let status = b.enumType("order_status", ["pending", "paid"])
        let orders = b.table("orders", ["id uuid pk", "state order_status"])
        let card = try b.openCard(orders, column: "state")
        let labels = (card.accessibilityChildren() ?? []).compactMap { ($0 as? NSView)?.accessibilityLabel() }
        expectEqual(labels, card.stopNames, "type, references, null, unique, primary key, default, on delete, on update")
        let field = try require(card.field(of: "type"))
        expectEqual(card.value(of: "type"), "order_status")
        expectEqual(field.highlights.count, 1, "the enum's name in its pill")
        let ink = try require(field.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        // The pill's ink on the bubble, which is white in the light appearance and a dark gray in the dark: it reads in both.
        @MainActor func luminance(_ name: NSAppearance.Name, _ color: NSColor) throws -> Double {
            var rgb: [Double] = []
            try require(NSAppearance(named: name)).performAsCurrentDrawingAppearance {
                let c = color.usingColorSpace(.sRGB) ?? color
                rgb = [c.redComponent, c.greenComponent, c.blueComponent].map { Double($0) <= 0.03928 ? Double($0) / 12.92 : pow((Double($0) + 0.055) / 1.055, 2.4) }
            }
            return 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]
        }
        func contrast(_ a: Double, _ b: Double) -> Double { (max(a, b) + 0.05) / (min(a, b) + 0.05) }
        let light = contrast(try luminance(.aqua, ink), 1.0)
        let dark = contrast(try luminance(.darkAqua, ink), pow(0.15, 2.2))
        expect(light >= 4.5, "light \(light)")
        expect(dark >= 4.5, "dark \(dark)")
        _ = status
        b.press(.escape)
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

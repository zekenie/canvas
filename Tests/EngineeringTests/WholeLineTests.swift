import AppKit
@_spi(Host) import Canvas
import CanvasTesting
@_spi(Host) import CanvasUI
import Engineering
import LineRows
import Selection
import TestKit
import TextEditing
import Titles

// A line reads back what it prints, and what's shown at rest agrees with editing: a pasted column of several words (a type,
// a default, a name, an enum's name) edited on its line keeps every word; the card writes such a type and default whole; two
// enums of one name in two databases are told apart, typing binding the one in the table's own; a column whose words name an
// enum made later is that enum's pill at rest, as on its line; and an enum's values widen it to read whole.

extension KitBench {
    /// The caret on `table`'s column `name`, editing it.
    func go(to table: ShapeID, column name: String) throws {
        if editor.editingShapeID != table { begin(table) }
        view?.go(to: .row(try require(columns(table).first { $0.name == name }?.id, "no column \(name)")))
        window.settle()
    }

    /// A table titled `name` holding `columns` as given, in a step of its own.
    @discardableResult
    func table(_ name: String, columns: [Column], at origin: CGPoint = CGPoint(x: 100, y: 100)) -> ShapeID {
        let id = h.add(DatabaseTable(frame: CGRect(origin: origin, size: CGSize(width: 300, height: 100)), columns: columns), titled: name)
        editor.undoHistory.seal()
        return id
    }
}

@MainActor let wholeLineTests = Suite("A line reads back what it prints; rest agrees with editing", [
    test("a pasted column of several words, renamed on its line, keeps its type, its default and its enum: Rename Column") {
        let b = try KitBench()
        let status = b.enumType("Order Status", ["new", "paid"])
        let held = [
            Column(name: "created_at", type: TypeRef("timestamp with time zone"), default: "''::character varying"),
            Column(name: "order date", type: TypeRef("Order Status", shape: status), nullable: true),
            Column(name: "due", type: TypeRef("date"), default: "now() + interval '1 day'"),
            Column(name: "label", type: TypeRef("varchar(255) binary")),
        ]
        let items = b.table("Line Items", columns: held)
        try b.go(to: items, column: "created_at")
        expectEqual(b.field.string, "created_at timestamp with time zone default ''::character varying", "printed as SQL writes it")
        b.field.setSelectedRange(NSRange(location: 0, length: 7))
        b.type("made")
        b.press(.down)
        expectEqual(b.undoName, "Rename Column")
        var renamed = held[0]
        renamed.name = "made_at"
        renamed.id = b.columns(items)[0].id
        expectEqual(b.columns(items)[0], renamed, "every word as it was")
        expectEqual(b.field.string, "\"order date\" \"Order Status\" null", "a name and an enum's of several words quoted")
        expectEqual(b.field.line.references.map(\.target), [PartAddress(status)], "the enum's name stands for it")
        expect(b.field.highlights.contains { $0.range == NSRange(location: 14, length: 12) }, "its pill under its name, the quotes outside")
        b.field.setSelectedRange(NSRange(location: 1, length: 5))
        b.type("placed")
        b.press(.down)
        expectEqual(b.undoName, "Rename Column")
        expectEqual(b.columns(items)[1].name, "placed date")
        expectEqual(b.columns(items)[1].type, TypeRef("Order Status", shape: status), "still the enum's")
        expectEqual(b.field.string, "due date default \"now() + interval '1 day'\"")
        b.field.setSelectedRange(NSRange(location: 0, length: 3))
        b.type("due_on")
        b.press(.down)
        expectEqual(b.columns(items)[2].default, "now() + interval '1 day'")
        expectEqual(b.field.string, "label \"varchar(255) binary\"", "a type SQL's words don't explain, quoted")
        b.field.setSelectedRange(NSRange(location: 0, length: 5))
        b.type("tag")
        b.press(.down)
        expectEqual(b.columns(items)[3].type.words, "varchar(255) binary")
        expectEqual(b.undoName, "Rename Column")
        b.press(.escape)
    },
    test("typed as SQL writes them: timestamp with time zone, double precision, character varying(255)? and a cast default are each one part") {
        let b = try KitBench()
        let orders = b.table("orders", ["id uuid pk"])
        b.begin(orders)
        for line in ["placed_at timestamp with time zone not null default now()", "ratio double precision",
                     "note character varying(255)? default ''::character varying"] {
            b.type(line)
            b.press(.return)
        }
        b.press(.escape)
        expectEqual(b.columns(orders).dropFirst().map(\.type.words), ["timestamp with time zone", "double precision", "character varying(255)"])
        expectEqual(b.columns(orders).dropFirst().map(\.unread), ["", "", ""], "no word left over")
        expectEqual(b.columns(orders).last?.nullable, true)
        expectEqual(b.columns(orders).last?.default, "''::character varying")
    },
    test("the card writes a type and a default of several words whole, and a spaced enum's name binds it") {
        let b = try KitBench()
        let status = b.enumType("Order Status", ["new"])
        let orders = b.table("orders", ["id uuid pk", "state text"])
        let card = try b.openCard(orders, column: "state")
        try require(card.field(of: "type")).selectAll(nil)
        b.type("timestamp with time zone")
        if card.field(of: "type")?.offerList != nil { b.press(.escape) }
        b.press(.down)
        expectEqual(b.columns(orders).last?.type.words, "timestamp with time zone")
        expectEqual(b.columns(orders).last?.unread, "")
        card.go(to: "default")
        b.type("now() + interval '1 day'")
        b.press(.tab)
        expectEqual(b.columns(orders).last?.default, "now() + interval '1 day'")
        expectEqual(b.columns(orders).last?.type.words, "timestamp with time zone", "the type kept whole by a default's change")
        card.go(to: "type")
        try require(card.field(of: "type")).selectAll(nil)
        b.type("Order")
        expectEqual(card.field(of: "type")?.listedOffers.first, "Order Status")
        b.press(.tab)
        expectEqual(card.field(of: "type")?.string, "\"Order Status\"", "picked, quoted as the line reads it")
        b.press(.tab)
        expectEqual(b.columns(orders).last?.type, TypeRef("Order Status", shape: status))
        expectEqual(b.lines(orders).last, "state \"Order Status\" default \"now() + interval '1 day'\"")
        b.press(.escape)
    },
    test("two enums of one name in two databases: typing binds the one in the table's database; both offered, each saying where") {
        let b = try KitBench()
        let billing = b.h.add(Database(frame: CGRect(x: 0, y: 0, width: 400, height: 300)), titled: "billing")
        let shop = b.h.add(Database(frame: CGRect(x: 500, y: 0, width: 500, height: 600)), titled: "shop")
        let paid = b.enumType("status", ["paid", "refunded"], at: CGPoint(x: 40, y: 60))
        let sold = b.enumType("status", ["new", "sold"], at: CGPoint(x: 540, y: 400))
        let orders = b.table("orders", ["id uuid pk"], at: CGPoint(x: 540, y: 60))
        b.editor.transact {
            $0.setContainer(paid, to: billing)
            $0.setContainer(sold, to: shop)
            $0.setContainer(orders, to: shop)
        }
        b.editor.undoHistory.seal()
        b.begin(orders)
        b.type("state stat")
        let listed = Array(zip(b.field.listedOffers, b.field.listedDetails).filter { $0.0 == "status" })
        expectEqual(listed.map(\.1).sorted(), ["Enum · billing", "Enum · shop"], "both, each where it is")
        b.type("us")
        b.press(.return)
        expectEqual(b.columns(orders).last?.type, TypeRef("status", shape: sold), "the one in its own database, not the first made")
        b.press(.escape)
    },
    test("a column whose words name an enum made later is its pill at rest, as on its line; and again once it's deleted and made anew") {
        let b = try KitBench()
        let orders = b.table("orders", ["id uuid pk", "state order_status"])
        @MainActor func drawn(_ bench: KitBench) throws -> Data {
            bench.editor.selectedShapeIDs = []
            return try pngOf(render(bench.editor))
        }
        let words = try drawn(b)
        let status = b.enumType("order_status", ["pending", "paid"], at: CGPoint(x: 1200, y: 100))
        let late = try drawn(b)
        expect(late != words, "made later, the type is its pill at rest")
        // The same column bound when it was typed draws the same.
        let bound = try KitBench()
        let boundStatus = bound.enumType("order_status", ["pending", "paid"], at: CGPoint(x: 1200, y: 100))
        bound.table("orders", columns: [Column(name: "id", type: TypeRef("uuid"), primaryKey: true), Column(name: "state", type: TypeRef("order_status", shape: boundStatus))])
        expect(late == (try drawn(bound)), "drawn as a column bound to it is")
        b.begin(orders)
        b.press(.up)
        expect(b.field.highlights.contains { $0.range == NSRange(location: 6, length: 12) }, "its line says the same: the enum's pill")
        b.press(.escape)
        b.editor.transact("Delete") { $0.delete(Set([status])) }
        expect((try drawn(b)) == words, "gone, words again")
        b.enumType("order_status", ["pending"], at: CGPoint(x: 1200, y: 100))
        expect((try drawn(b)) == late, "made anew, its pill again")
    },
    test("an enum's values widen it to read whole as each is committed, never narrower, at most a table's widest") {
        let b = try KitBench()
        let status = b.enumType("order_status", ["pending"])
        let width = { b.editor.document[status]?.box?.width ?? 0 }
        let initial = width()
        b.begin(status)
        b.type("awaiting_customer_confirmation_of_the_shipping_address")
        b.press(.return)
        let whole = width()
        expect(whole > initial && whole <= 560, "\(initial) → \(whole)")
        expectEqual(b.undoName, "Add Value")
        b.type("x")
        b.press(.return)
        expectEqual(width(), whole)
        b.press(.escape)
    },
])

import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Engineering
import LineRows
import TestKit
import TextEditing

// A key in a column's line (K5): its words read apart (`→ customers.id`, a table alone, a quoted table's name), written back as
// a target is; the key column ⌘L names for a table; and, where nothing draws connections (no connector here), the offers after
// `→` still made and lit, a key's words kept as words, no arrow drawn. Keys drawn as arrows are CompositionTests' (Arrows ship
// there).

@MainActor let typedKeyTests = Suite("Keys typed in a line", [
    test("a key's words: → and the word after it, a table and a column, the rest of the unread words kept in order") {
        let key = try require(ColumnGrammar.key(in: "→ customers.id"))
        expectEqual([key.table, key.column, key.written, key.rest], ["customers", "id", "→ customers.id", ""])
        let quoted = try require(ColumnGrammar.key(in: "legacy -> \"order items\".id kept"))
        expectEqual([quoted.table, quoted.column, quoted.rest], ["order items", "id", "legacy kept"])
        let alone = try require(ColumnGrammar.key(in: "→ customers"))
        expectEqual(alone.column, nil, "a table alone: its primary key")
        expectEqual(ColumnGrammar.key(in: "→"), nil)
        expectEqual(ColumnGrammar.key(in: "whatever words"), nil)
        expectEqual(ColumnGrammar.written(table: "order items", column: "id"), "\"order items\".id")
        expectEqual(ColumnGrammar.written(table: "customers", column: "id"), "customers.id")
        expectEqual(ColumnGrammar.target("v1.2").map { [$0.table, $0.column ?? "-"] }, ["v1", "2"], "a dotted name unquoted splits at its last dot")
        expectEqual(ColumnGrammar.target("\"v1.2\".id").map { [$0.table, $0.column ?? "-"] }, ["v1.2", "id"], "quoted, it's whole")
    },
    test("the key column for a table: its name, singular, and _id; a second _2; a serial's key an integer") {
        expectEqual(KeyPicks.keyColumnName(for: "customers", among: ["id"]), "customer_id")
        expectEqual(KeyPicks.keyColumnName(for: "categories", among: []), "category_id")
        expectEqual(KeyPicks.keyColumnName(for: "addresses", among: []), "address_id")
        expectEqual(KeyPicks.keyColumnName(for: "Order Items", among: []), "order_item_id")
        expectEqual(KeyPicks.keyColumnName(for: "status", among: []), "status_id")
        expectEqual(KeyPicks.keyColumnName(for: "statuses", among: []), "status_id")
        expectEqual(KeyPicks.keyColumnName(for: "buses", among: []), "bus_id")
        expectEqual(KeyPicks.keyColumnName(for: "campus", among: []), "campus_id")
        expectEqual(KeyPicks.keyColumnName(for: "analysis", among: []), "analysis_id")
        expectEqual(KeyPicks.keyColumnName(for: "analyses", among: []), "analysis_id")
        expectEqual(KeyPicks.keyColumnName(for: "databases", among: []), "database_id")
        expectEqual(KeyPicks.keyColumnName(for: "customers", among: ["customer_id"]), "customer_id_2")
        expectEqual(KeyPicks.keyType(of: "serial"), "int")
        expectEqual(KeyPicks.keyType(of: "bigserial"), "bigint")
        expectEqual(KeyPicks.keyType(of: "uuid"), "uuid")
    },
    test("where nothing draws connections: → cus offers customers' key columns, lit; a picked key's words stay words, no arrow") {
        let b = try KitBench()
        let customers = b.table("customers", ["id uuid pk", "email text unique", "name text"])
        let orders = b.table("orders", ["id uuid pk"], at: CGPoint(x: 500, y: 100))
        b.begin(orders)
        b.type("customer_id uuid -> cus")
        expectEqual(b.field.listedOffers, ["customers.id", "customers.email"])
        expectEqual(b.editor.service(LineRowsService.self)?.light?.shape, customers)
        b.press(.tab)
        expectEqual(b.field.string, "customer_id uuid → customers.id")
        b.press(.return)
        expectEqual(b.undoName, "Add Column")
        expectEqual(b.columns(orders).last?.unread, "→ customers.id", "no connector: the key is words")
        expectEqual(b.editor.document.shapes.count, 2, "and no arrow")
        b.press(.escape)
    },
])

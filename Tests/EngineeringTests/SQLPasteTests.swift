import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Clipboard
import Connections
import CoreGraphics
import Draw
import Engineering
import Foundation
import Selection
import TestKit
import Titles

// SQL put down by names (`SQLPaste.program`, then Draw's `put`, as ⌘V does): a table found by its title, nearest first and
// file-wide (a schema's name the path into its database, else the bare title; a paste makes no database), its columns joined by
// name in place (ids kept, so keys bound to them stay; a new one after the column pasted before it; one the paste leaves out kept),
// an enum's values by text and a column's type bound to the enum it names, and a table's keys in the program as the edges it
// implies (to the row a column names, or the far table's primary key's: the pasted one's, else the file's, asked when the put
// finds the far table), each re-aiming its column's key. With no connector here the keys draw nothing, and the put still lands,
// never refused; the keys are drawn, re-aimed and kept in CompositionTests' `pasteSQLShippedTests`.

/// The kit's board with draw's names (Titles'), so a put finds shapes by their titles.
@MainActor private func pasteHarness() throws -> EditorHarness {
    let h = try EditorHarness(plugins: kitPlugins() + [TitleNamesPlugin()])
    h.editor.viewportDidResize(to: CGSize(width: 1000, height: 800))
    h.editor.turn(EngineeringKit.self, on: true)
    h.editor.undoHistory.seal()
    return h
}

/// SQL pasted beside the selection, as ⌘V puts it down: the shapes it landed.
@MainActor @discardableResult
private func paste(_ sql: String, in h: EditorHarness) throws -> [ShapeID] {
    let site = PutSite.beside(h.editor.selectedShapeIDs)
    let program = try require(SQLPaste.program(of: sql), "the SQL reads")
    return try h.editor.undoHistory.group("Paste SQL") { try put(program, at: site, in: h.editor, step: "Paste SQL") }
}

@MainActor private func columns(_ id: ShapeID, in editor: CanvasEditor) -> [Column] {
    editor.shape(inFile: id)?.typed(as: DatabaseTable.self)?.props.columns ?? []
}

@MainActor private func titled(_ title: String, _ kind: ShapeKind, in editor: CanvasEditor) -> [AnyShapeRecord] {
    editor.file.everyBoard.flatMap { editor.file[$0].shapes }.filter { $0.kind == kind && $0[TitleProperty.self] == title }
}

private let paymentsSQL = """
    CREATE TABLE payments (
      id uuid PRIMARY KEY,
      order_id uuid NOT NULL REFERENCES orders (id),
      stripe_charge_id text UNIQUE,
      amount_cents int NOT NULL,
      status text NOT NULL,
      created_at timestamptz NOT NULL DEFAULT now()
    );
    """

@MainActor let sqlPasteTests = Suite("SQL put down by names", [
    test("T1 panel 4: payments lands beside orders, its columns as SQL says them, a new table; its key to orders.id in the program, re-aiming the column's key; one step") {
        let h = try pasteHarness()
        let orders = h.add(orders(), titled: "orders")
        h.editor.selection = orders
        let program = try require(SQLPaste.program(of: paymentsSQL))
        expectEqual(program.block.map(\.count), [1])
        let edges = program.edges.values.flatMap { $0 }
        expectEqual(edges, [DrawPut.Edge(fromRow: "order_id", toKind: "table", toTitle: "orders", toRow: "id",
                                         attributes: ["channel": ForeignKey.id.rawValue], replacesType: ForeignKey.id.rawValue)])
        let before = h.editor.document
        let landed = try paste(paymentsSQL, in: h)
        let payments = try require(landed.first)
        expectEqual(landed, [payments])
        let record = try require(h.editor.document[payments])
        expectEqual(record[TitleProperty.self], "payments")
        expectEqual(columns(payments, in: h.editor).map(ColumnGrammar.print), [
            "id uuid pk", "order_id uuid", "stripe_charge_id text null unique", "amount_cents int", "status text", "created_at timestamptz default now()",
        ])
        let anchor = try require(h.editor.document[orders]?.box), box = try require(record.box)
        expect(!box.intersects(anchor), "beside orders, not on it")
        expect(abs(box.minX - anchor.maxX) < 200 || abs(anchor.minX - box.maxX) < 200, "beside: \(box) and \(anchor)")
        expectEqual(h.editor.undoHistory.undoName, "Paste SQL")
        h.editor.undo()
        expectEqual(h.editor.document, before, "one Undo takes it")
    },
    test("a pg_dump's long types: the table made as wide as its columns read whole, up to the widest; one the file has keeps its width, unless the paste changes it and its new lines need more") {
        let h = try pasteHarness()
        let dump = """
            CREATE TABLE public.shipments (
                id uuid NOT NULL,
                shipping_address character varying(255),
                tracking_number character varying(64) NOT NULL,
                shipped_at timestamp with time zone
            );
            """
        let landed = try paste(dump, in: h)
        let shipments = try require(landed.first)
        let width = try require(h.editor.document[shipments]?.box?.width)
        expect(width > 260 && width <= 560, "wider than a new table's 260, as its columns read whole at rest: \(width)")
        h.editor.transact { $0.update(shipments) { $0.box?.size.width = 300 } }
        try paste(dump, in: h)
        expectEqual(h.editor.document[shipments]?.box?.width, 300, "pasted again unchanged, the width the person left it at")
        // Pasted again with a column retyped and one added (after a migration): widened in the same step to read whole, never narrowed.
        let migrated = dump.replacingOccurrences(of: "tracking_number character varying(64) NOT NULL,",
                                                 with: "tracking_number character varying(128) NOT NULL,\n    delivered_at timestamp with time zone,")
        let undoName = h.editor.undoHistory.undoName
        try paste(migrated, in: h)
        let widened = try require(h.editor.document[shipments]?.box?.width)
        expect(widened > 300 && widened <= 560, "widened to its new widest line: \(widened)")
        expectEqual(h.editor.undoHistory.undoName, "Paste SQL", "in the paste's own step")
        h.editor.undo()
        expectEqual(h.editor.document[shipments]?.box?.width, 300, "one Undo takes the paste and the widening")
        expectEqual(h.editor.undoHistory.undoName, undoName)
        h.editor.redo()
        h.editor.transact { $0.update(shipments) { $0.box?.size.width = 600 } }
        try paste(migrated.replacingOccurrences(of: "(128)", with: "(129)"), in: h)
        expectEqual(h.editor.document[shipments]?.box?.width, 600, "a table wider than its lines need is never narrowed")
    },
    test("pasted again beside the table it widens, with a new table: the new one is placed against the width the table keeps, never under it") {
        let h = try pasteHarness()
        let first = try paste("CREATE TABLE shipments (id uuid PRIMARY KEY, note text);", in: h)
        let shipments = try require(first.first)
        h.editor.transact { $0.update(shipments) { $0.box?.size.width = 240 } }
        h.editor.selectedShapeIDs = [shipments]
        h.editor.undoHistory.seal()
        let landed = try paste("""
            CREATE TABLE shipments (id uuid PRIMARY KEY, note text, delivered_at_in_the_recipients_timezone timestamp with time zone NOT NULL);
            CREATE TABLE parcels (id uuid PRIMARY KEY, weight_grams int);
            """, in: h)
        let wide = try require(h.editor.document[shipments]?.box), parcels = try require(landed.first { $0 != shipments })
        expect(wide.width > 240 + 80, "widened by more than the gap beside it: \(wide)")
        let made = try require(h.editor.document[parcels]?.box)
        expect(!made.intersects(wide), "the new table clear of the widened one: \(made) \(wide)")
        expectEqual(h.editor.undoHistory.undoName, "Paste SQL")
        h.editor.undo()
        expectEqual(h.editor.document[shipments]?.box?.width, 240, "one Undo takes the widening and the table")
        expect(h.editor.document[parcels] == nil)
    },
    test("a table whose widest column is an enum's: measured as the pill it draws (its font and padding), not as the words of its type") {
        let name = "shipment_delivery_status_kind_long"
        let table = "CREATE TABLE shipments (\n    id uuid NOT NULL,\n    state \(name) NOT NULL\n);"
        let withEnum = try pasteHarness(), plain = try pasteHarness()
        let made = try paste("CREATE TYPE \(name) AS ENUM ('queued', 'sent');\n" + table, in: withEnum)
        let widths = try made.map { try require(withEnum.editor.document[$0]?.box?.width) }
        let landed = try paste(table, in: plain)
        let plainWidth = try require(plain.editor.document[landed[0]]?.box?.width)
        let shipments = try require(made.first { withEnum.editor.document[$0]?.kind == DatabaseTable.kind })
        let enumWidth = try require(withEnum.editor.document[shipments]?.box?.width)
        expect(enumWidth != plainWidth, "as wide as the pill reads, which is not the words' width: \(enumWidth) against \(plainWidth), enum and table \(widths)")
    },
    test("pasted again: the table found by its title, its columns updated in place with their ids, a new column after the one pasted before it, one left out kept") {
        let h = try pasteHarness()
        try paste(paymentsSQL, in: h)
        let payments = try require(titled("payments", DatabaseTable.kind, in: h.editor).first).id
        let ids = Dictionary(uniqueKeysWithValues: columns(payments, in: h.editor).map { ($0.name, $0.id) })
        // A column the person added since, which the paste doesn't name.
        h.editor.transact { $0.update(payments, as: DatabaseTable.self) { $0.props.columns.append(Column(name: "memo", type: TypeRef("text"), nullable: true)) } }
        let landed = try paste("""
            CREATE TABLE payments (
              id uuid PRIMARY KEY,
              order_id uuid NOT NULL REFERENCES orders (id),
              currency char(3) NOT NULL DEFAULT 'usd',
              amount_cents bigint NOT NULL,
              created_at timestamptz NOT NULL
            );
            """, in: h)
        expectEqual(landed, [payments], "restated, nothing made")
        expectEqual(titled("payments", DatabaseTable.kind, in: h.editor).count, 1)
        let after = columns(payments, in: h.editor)
        expectEqual(after.map(\.name), ["id", "order_id", "currency", "stripe_charge_id", "amount_cents", "status", "created_at", "memo"],
                    "currency after order_id, the column pasted before it; stripe_charge_id, status and memo kept where they were")
        for name in ["id", "order_id", "amount_cents", "created_at"] {
            expectEqual(after.first { $0.name == name }?.id, ids[name], "\(name) keeps its id")
        }
        expectEqual(after.first { $0.name == "amount_cents" }?.type.words, "bigint", "its type as pasted")
        expectEqual(after.first { $0.name == "created_at" }?.default, nil, "a default the paste doesn't say is gone, as a line's")
        expectEqual(after.first { $0.name == "currency" }?.default, "'usd'")
        expectEqual(h.editor.undoHistory.undoName, "Paste SQL")
    },
    test("a table found nearest first: the one on the board shown over the one on another board; a schema's name the path into its database, else the bare title; no database made") {
        let h = try pasteHarness()
        let loose = h.add(DatabaseTable(frame: CGRect(x: 100, y: 100, width: 260, height: 44), columns: [Column(name: "id", type: TypeRef("uuid"), primaryKey: true)]),
                          titled: "invoices")
        let billing = h.add(Database(frame: CGRect(x: 100, y: 300, width: 600, height: 300)), titled: "billing")
        let inBilling = h.add(DatabaseTable(frame: CGRect(x: 140, y: 360, width: 260, height: 44), columns: [Column(name: "id", type: TypeRef("uuid"), primaryKey: true)]),
                              titled: "invoices")
        h.editor.transact { $0.setContainer([inBilling], to: billing) }
        try paste("CREATE TABLE billing.invoices (id uuid PRIMARY KEY, total_cents int);", in: h)
        expectEqual(columns(inBilling, in: h.editor).map(\.name), ["id", "total_cents"], "billing.invoices is the invoices in billing")
        expectEqual(columns(loose, in: h.editor).map(\.name), ["id"])
        try paste("CREATE TABLE public.invoices (id uuid PRIMARY KEY, due date);", in: h)
        expectEqual(columns(loose, in: h.editor).map(\.name) + columns(inBilling, in: h.editor).map(\.name),
                    ["id", "due", "id", "total_cents"], "public. is dropped: a bare title, the nearest (the loose one is first on the board)")
        try paste("CREATE TABLE archive.invoices (id uuid PRIMARY KEY, archived_at timestamptz);", in: h)
        expectEqual(columns(loose, in: h.editor).map(\.name), ["id", "archived_at", "due"], "no database archive: the bare title, the nearest: the loose one, in no container; after id, the column pasted before it")
        expectEqual(columns(inBilling, in: h.editor).map(\.name), ["id", "total_cents"], "the one in billing untouched")
        expectEqual(h.shapes(Database.kind).count, 1, "a paste makes no database")
        expectEqual(h.shapes(DatabaseTable.kind).count, 2)
    },
    test("an enum: its values by text, a new one after the one pasted before it, one left out kept; a column typed public.order_status bound to it") {
        let h = try pasteHarness()
        try paste("""
            CREATE TYPE public.order_status AS ENUM ('pending', 'paid', 'refunded');
            CREATE TABLE orders (id uuid PRIMARY KEY, status public.order_status NOT NULL);
            """, in: h)
        let status = try require(titled("order_status", DatabaseEnum.kind, in: h.editor).first)
        expectEqual(status.typed(as: DatabaseEnum.self)?.props.values.map(\.text), ["pending", "paid", "refunded"])
        let orders = try require(titled("orders", DatabaseTable.kind, in: h.editor).first)
        let type = try require(columns(orders.id, in: h.editor).first { $0.name == "status" }?.type)
        expectEqual(type, TypeRef("order_status", shape: status.id), "the enum the paste made, by its name")
        let ids = status.typed(as: DatabaseEnum.self)?.props.values.map(\.id)
        try paste("CREATE TYPE order_status AS ENUM ('pending', 'void', 'paid');", in: h)
        let values = try require(h.editor.document[status.id]?.typed(as: DatabaseEnum.self)?.props.values)
        expectEqual(values.map(\.text), ["pending", "void", "paid", "refunded"])
        expectEqual(values.filter { $0.text != "void" }.map(\.id), ids, "the values it had keep their ids")
    },
    test("enums on a row of their own, first; tables four to a row, left to right; all returned, as ⌘V selects them") {
        let h = try pasteHarness()
        let sql = (1...6).map { "CREATE TABLE t\($0) (id int PRIMARY KEY);" }.joined(separator: "\n") + "\nCREATE TYPE mood AS ENUM ('ok');"
        let program = try require(SQLPaste.program(of: sql))
        expectEqual(program.block.map(\.count), [1, 4, 2], "the enum alone, then the tables")
        let landed = try paste(sql, in: h)
        expectEqual(landed.count, 7)
        let tables = landed.filter { h.editor.document[$0]?.kind == DatabaseTable.kind }
        let mood = try require(landed.first { h.editor.document[$0]?.kind == DatabaseEnum.kind }.flatMap { h.editor.document[$0]?.box })
        let boxes = tables.compactMap { h.editor.document[$0]?.box }
        expectEqual(Set(boxes.prefix(4).map(\.minY)).count, 1, "the first four in a row")
        expect(boxes.allSatisfy { $0.minY > mood.maxY }, "under the enums' row")
        expect(boxes[4].minY > boxes[0].maxY, "the rest below")
        expect(boxes[1].minX > boxes[0].maxX && boxes[2].minX > boxes[1].maxX, "no keys: left to right in paste order")
    },
    test("paste 02: a pg_dump laid out by its keys: orders, which four tables key to, in the middle of what keys to it; each table beside, above, below or corner to corner with the tables it keys to, in columns, so no key passes under a card (UX walk 3 paste-1)") {
        // A dump's alphabet: categories, customers, order_items, orders, payments, products, shipments.
        let sql = """
            CREATE TABLE categories (id int PRIMARY KEY);
            CREATE TABLE customers (id int PRIMARY KEY);
            CREATE TABLE order_items (id int PRIMARY KEY, order_id int REFERENCES orders, product_id int REFERENCES products);
            CREATE TABLE orders (id int PRIMARY KEY, customer_id int REFERENCES customers);
            CREATE TABLE payments (id int PRIMARY KEY, order_id int REFERENCES orders);
            CREATE TABLE products (id int PRIMARY KEY, category_id int REFERENCES categories);
            CREATE TABLE shipments (id int PRIMARY KEY, order_id int REFERENCES orders);
            CREATE TYPE order_status AS ENUM ('pending');
            """
        let h = try pasteHarness()
        let landed = try paste(sql, in: h)
        // The rows as they landed, top to bottom, each left to right.
        let shapes = landed.compactMap { h.editor.document[$0] }
        let tops = Array(Set(shapes.compactMap { $0.box?.minY })).sorted()
        let titles = tops.map { top in
            shapes.filter { $0.box?.minY == top }.sorted { $0.box!.minX < $1.box!.minX }.compactMap { $0[TitleProperty.self] }
        }
        expectEqual(titles, [["order_status"], ["customers", "orders", "order_items", "products"], ["payments", "shipments", "categories"]],
                    "orders in the middle of the tables that key to it; products beside order_items, categories under them")
        // In columns: each of the second row under the one of the first in its column.
        @MainActor func box(_ title: String) throws -> CGRect { try require(shapes.first { $0[TitleProperty.self] == title }?.box) }
        expectEqual(try box("payments").minX, try box("customers").minX)
        expectEqual(try box("shipments").minX, try box("orders").minX, "right under orders")
        expectEqual(try box("categories").minX, try box("order_items").minX)
        // Every key joins two tables next to each other, or corner to corner: its straight run passes under no card.
        let keys = [("order_items", "orders"), ("order_items", "products"), ("orders", "customers"), ("payments", "orders"),
                    ("products", "categories"), ("shipments", "orders")]
        for (from, to) in keys {
            let a = try box(from), b = try box(to)
            let run = (CGPoint(x: a.midX, y: a.midY), CGPoint(x: b.midX, y: b.midY))
            for other in shapes where ![from, to].contains(other[TitleProperty.self] ?? "") && other.kind == DatabaseTable.kind {
                let card = try require(other.box).insetBy(dx: 4, dy: 4)
                let under = (1..<40).contains { step in
                    let t = CGFloat(step) / 40
                    return card.contains(CGPoint(x: run.0.x + (run.1.x - run.0.x) * t, y: run.0.y + (run.1.y - run.0.y) * t))
                }
                expect(!under, "\(from) → \(to) passes under \(other[TitleProperty.self] ?? "?")")
            }
        }
    },
    test("paste 03: a table made as wide as its longest line, a dump's long type whole; capped; one the file has keeps its width") {
        let h = try pasteHarness()
        let sql = """
            CREATE TABLE shipments (id int PRIMARY KEY, tracking_number character varying(255), shipped_at timestamp with time zone);
            CREATE TABLE tiny (id int PRIMARY KEY);
            CREATE TABLE wide (id int PRIMARY KEY, \((1...3).map { "c\($0) character varying(255) DEFAULT 'a very long default that runs on and on'" }.joined(separator: ", ")), a_column_with_an_exceedingly_long_name_that_never_ends_at_all_really timestamp with time zone);
            """
        let landed = try paste(sql, in: h)
        let widths = landed.compactMap { h.editor.document[$0]?.box?.width }
        expectEqual(widths.count, 3)
        expect(widths[0] > 260, "shipments wider than a new table: \(widths[0])")
        // Its longest line, as a row lays it out: the names' inset, the name, a gap, the type, the `?`, the trailing inset.
        func width(_ text: String, _ font: NSFont) -> CGFloat { NSAttributedString(string: text, attributes: [.font: font]).size().width }
        let longest = KitStyle.nameInset + width("tracking_number", KitStyle.nameFont) + KitStyle.nameGap
            + width("character varying(255)", KitStyle.typeFont) + width("?", KitStyle.typeFont) + KitStyle.trailingInset
        expect(widths[0] >= longest - 1, "shipments as wide as tracking_number character varying(255)? needs: \(widths[0]) for \(longest)")
        expectEqual(widths[1], 260, "a short one as a new table is")
        expectEqual(widths[2], 560, "capped at the kit's `TableStyle.mostWholeWidth`, as a commit caps a table")
        h.editor.transact("Resize") { $0.update(landed[0]) { $0.box = CGRect(origin: $0.box!.origin, size: CGSize(width: 300, height: $0.box!.height)) } }
        try paste(sql, in: h)
        expectEqual(h.editor.document[landed[0]]?.box?.width, 300, "found: its width as the person left it")
    },
    test("paste 03: a column typed as an enum the file has (not the paste) is measured as the pill it is drawn as, wider than its words") {
        let sql = "CREATE TABLE shipments (id int PRIMARY KEY, carrier_service_level_name carrier_service_level);"
        let plain = try require(SQLPaste.program(of: sql)), known = try require(SQLPaste.program(of: sql, fileEnums: ["carrier_service_level"]))
        let was = try require(plain.sizes.values.first?.width), now = try require(known.sizes.values.first?.width)
        expect(now != was, "measured as the pill it is drawn as, not as its words: \(now) for \(was)")
    },
    test("a key's row: the column it names; REFERENCES t alone the pasted table's primary key, else asked of the table the put finds (the file's), and no edge where it has none; the paste lands whole") {
        let h = try pasteHarness()
        h.add(DatabaseTable(frame: CGRect(x: 100, y: 100, width: 260, height: 44), columns: [Column(name: "code", type: TypeRef("text"), primaryKey: true)]),
              titled: "currencies")
        let sql = """
            CREATE TABLE accounts (number int PRIMARY KEY);
            CREATE TABLE ledger (
              id int PRIMARY KEY,
              account int REFERENCES accounts,
              currency text REFERENCES currencies,
              branch uuid REFERENCES branches (id)
            );
            """
        let program = try require(SQLPaste.program(of: sql))
        let edges = program.edges.values.flatMap { $0 }
        expectEqual(edges.map { "\($0.fromRow ?? "") → \($0.toTitle).\($0.toRow ?? "")" }, ["account → accounts.number", "currency → currencies.", "branch → branches.id"],
                    "the pasted table's primary key is known; the file's currencies is asked of it when the put finds it")
        expect(edges[1].toRowOfShape != nil && edges[0].toRowOfShape == nil && edges[2].toRowOfShape == nil)
        let landed = try paste(sql, in: h)
        expectEqual(landed.count, 2, "landed whole, the keys it can't draw left out")
        let ledger = try require(titled("ledger", DatabaseTable.kind, in: h.editor).first)
        expectEqual(columns(ledger.id, in: h.editor).map(\.name), ["id", "account", "currency", "branch"])
    },
    test("two schemas' tables of one name, pasted and pasted again: two shapes, each found once and kept apart, never the one twice") {
        let h = try pasteHarness()
        let sql = """
            CREATE TABLE auth.users (id uuid PRIMARY KEY, email text);
            CREATE TABLE users (id uuid PRIMARY KEY, name text);
            CREATE TYPE a.status AS ENUM ('x');
            CREATE TYPE b.status AS ENUM ('y');
            """
        let landed = try paste(sql, in: h)
        expectEqual(landed.count, 4)
        // The enums on their row first, then the tables.
        let first = landed.filter { h.editor.document[$0]?.kind == DatabaseTable.kind } + landed.filter { h.editor.document[$0]?.kind == DatabaseEnum.kind }
        expectEqual(titled("users", DatabaseTable.kind, in: h.editor).count, 2, "no database auth: a table of its own")
        let before = columns(first[0], in: h.editor).map(\.name) + columns(first[1], in: h.editor).map(\.name)
        expectEqual(before, ["id", "email", "id", "name"])
        let again = try paste(sql + "\nCREATE TABLE audit (id int);", in: h)
        expectEqual(again.count, 5, "restated in place, the one new table made")
        expectEqual(Set(again).intersection(Set(first)), Set(first), "the same four shapes")
        expectEqual(titled("users", DatabaseTable.kind, in: h.editor).count, 2, "still two")
        expectEqual(titled("status", DatabaseEnum.kind, in: h.editor).count, 2, "still two")
        expectEqual(columns(first[0], in: h.editor).map(\.name) + columns(first[1], in: h.editor).map(\.name), before, "each one's columns its own")
        let values = Set(first[2...3].compactMap { h.editor.document[$0]?.typed(as: DatabaseEnum.self)?.props.values.map(\.text) })
        expectEqual(values, [["x"], ["y"]])
    },
    test("an enum named by its schema when its title is shared: each column typed by the enum it says, a bare name the table's own schema's") {
        let h = try pasteHarness()
        try paste("""
            CREATE TYPE a.status AS ENUM ('x');
            CREATE TYPE b.status AS ENUM ('y');
            CREATE TABLE a.status_log (kind a.status, other b.status);
            CREATE TABLE b.entries (kind status);
            """, in: h)
        let enums = titled("status", DatabaseEnum.kind, in: h.editor)
        @MainActor func valuesOf(_ type: TypeRef) -> [String]? {
            type.shape.flatMap { id in h.editor.document[id]?.typed(as: DatabaseEnum.self)?.props.values.map(\.text) }
        }
        let log = try require(titled("status_log", DatabaseTable.kind, in: h.editor).first)
        let kinds = columns(log.id, in: h.editor).map { valuesOf($0.type) }
        expectEqual(kinds, [["x"], ["y"]], "a.status and b.status, not the last status of the paste")
        let entries = try require(titled("entries", DatabaseTable.kind, in: h.editor).first)
        expectEqual(columns(entries.id, in: h.editor).map { valuesOf($0.type) }, [["y"]], "a bare status in a table of b: b's")
        expectEqual(enums.count, 2)
        // A table and an enum of one title, in different schemas.
        try paste("CREATE TABLE a.mood (id int); CREATE TYPE b.mood AS ENUM ('ok'); CREATE TABLE feelings (m b.mood);", in: h)
        let feelings = try require(titled("feelings", DatabaseTable.kind, in: h.editor).first)
        let mood = try require(columns(feelings.id, in: h.editor).first?.type.shape.flatMap { h.editor.document[$0] })
        expectEqual(mood.kind, DatabaseEnum.kind, "the enum, not the table a.mood")
    },
    test("pasted again, a key that now says no action has none: ON DELETE and ON UPDATE are the SQL's; a column pasted with no key keeps what it had") {
        let h = try pasteHarness()
        h.add(orders(), titled: "orders")
        try paste("CREATE TABLE payments (id uuid PRIMARY KEY, order_id uuid REFERENCES orders (id) ON DELETE CASCADE ON UPDATE RESTRICT);", in: h)
        let payments = try require(titled("payments", DatabaseTable.kind, in: h.editor).first).id
        @MainActor func order() -> Column? { columns(payments, in: h.editor).first { $0.name == "order_id" } }
        expectEqual(order()?.onDelete, "cascade")
        expectEqual(order()?.onUpdate, "restrict")
        try paste("CREATE TABLE payments (id uuid PRIMARY KEY, order_id uuid REFERENCES orders (id) ON DELETE SET NULL);", in: h)
        expectEqual(order()?.onDelete, "set null")
        expectEqual(order()?.onUpdate, nil, "no ON UPDATE said: none")
        try paste("CREATE TABLE payments (id uuid PRIMARY KEY, order_id uuid REFERENCES orders (id));", in: h)
        expectEqual(order()?.onDelete, nil, "no ON DELETE said: none")
        try paste("CREATE TABLE payments (id uuid PRIMARY KEY, order_id uuid REFERENCES orders (id) ON DELETE CASCADE);", in: h)
        try paste("CREATE TABLE payments (id uuid PRIMARY KEY, order_id uuid);", in: h)
        expectEqual(order()?.onDelete, "cascade", "a column pasted without a key keeps its key, and so its action")
    },
    test("a locked table is no match for a paste that writes it: a new one is made beside, never a refusal") {
        let refusals = RefusalLog()
        let h = try EditorHarness(plugins: kitPlugins(refusals) + [TitleNamesPlugin()])
        h.editor.viewportDidResize(to: CGSize(width: 1000, height: 800))
        h.editor.turn(EngineeringKit.self, on: true)
        let locked = h.add(orders(), titled: "orders")
        h.editor.transact { $0.update(locked) { $0[Frozen.self] = true } }
        let landed = try paste("CREATE TABLE orders (id uuid PRIMARY KEY, note text);", in: h)
        expectEqual(landed.count, 1)
        expect(landed.first != locked)
        expectEqual(columns(locked, in: h.editor).map(\.name), ["id", "customer_id", "status", "placed_at"], "untouched")
    },
])

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
    test("in paste order, four to a row; the tables and enums all returned, as ⌘V selects them") {
        let h = try pasteHarness()
        let sql = (1...6).map { "CREATE TABLE t\($0) (id int PRIMARY KEY);" }.joined(separator: "\n") + "\nCREATE TYPE mood AS ENUM ('ok');"
        let program = try require(SQLPaste.program(of: sql))
        expectEqual(program.block.map(\.count), [4, 3])
        let landed = try paste(sql, in: h)
        expectEqual(landed.count, 7)
        let boxes = landed.compactMap { h.editor.document[$0]?.box }
        expectEqual(Set(boxes.prefix(4).map(\.minY)).count, 1, "the first four in a row")
        expect(boxes[4].minY > boxes[0].maxY, "the rest below")
        expect(boxes[1].minX > boxes[0].maxX && boxes[2].minX > boxes[1].maxX, "left to right in paste order")
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
        let first = try paste(sql, in: h)
        expectEqual(first.count, 4)
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

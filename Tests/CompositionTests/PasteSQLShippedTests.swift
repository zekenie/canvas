import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Clipboard
import Connections
import Engineering
import Geometry
import References
import Selection
import ShippedTesting
import TestKit
import Titles

// ⌘V of SQL as shipped, on a pasteboard of the test's own (ShippedPlugins'): T1 panel 4 by the keys in a new board's window,
// payments landing selected beside orders with its key to orders drawn and one Undo, "Undo Paste SQL"; the same paste again
// updating payments in place (its columns' ids and its key's arrow kept, a new column after the one pasted before it, a column
// the paste doesn't say kept); a key re-aimed where the paste names another target and kept where it names none; an enum and the
// column it types; a key to a table that isn't there yet drawn by the same pasteboard once it is (the reading holds only the text);
// a key that names nothing the file has leaving the column's key; a key to a table on another board through its pill; a `.sql` file or two, before their names as text; SQL that reads
// nothing saying so; a schema wider than the view brought into it, and what the paste says it did; and the kit off, where ⌘V does
// nothing.

@MainActor private func pasteboardHolds(_ text: String) {
    let pasteboard = ShippedPlugins.pasteboard
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}

@MainActor private func table(_ editor: CanvasEditor, _ title: String) -> ShapeRecord<DatabaseTable>? {
    editor.document.shapes.first { $0[TitleProperty.self] == title && $0.kind == DatabaseTable.kind }?.typed(as: DatabaseTable.self)
}

/// Each key on the board as `from.column -> to.column` with its arrow's id, by the tables' titles and the columns' names now.
@MainActor private func keys(_ editor: CanvasEditor) -> [String: ShapeID] {
    var keys: [String: ShapeID] = [:]
    for arrow in editor.document.shapes.compactMap({ $0.typed(as: Arrow.self) }) where arrow[ChannelProperty.self] == ForeignKey.id {
        guard let start = arrow.props.start.binding, let end = arrow.props.end.binding else { continue }
        @MainActor func said(_ binding: ArrowBinding) -> String {
            let record = editor.document[binding.shapeID]
            let name = record.flatMap { editor.registry.parts(of: $0)?.first { $0.id == binding.part }?.name } ?? "?"
            return "\(record?[TitleProperty.self] ?? "?").\(name)"
        }
        keys["\(said(start)) -> \(said(end))"] = arrow.id
    }
    return keys
}

private let orders = #"""
    enum-type "order_status" values: "pending\npaid\nrefunded"
    table "orders" right of "order_status" columns: "id uuid pk\ncustomer_id uuid\nstatus order_status\ntotal_cents int\nplaced_at timestamptz?"
    """#

private let payments = """
    CREATE TABLE payments (
      id uuid PRIMARY KEY,
      order_id uuid NOT NULL REFERENCES orders (id) ON DELETE CASCADE,
      stripe_charge_id text UNIQUE NOT NULL,
      amount_cents int NOT NULL,
      status text NOT NULL,
      created_at timestamptz NOT NULL
    );
    """

/// A new board's window with the kit on, orders and its enum drawn, orders selected, the canvas with the keys.
@MainActor private func shopWindow() throws -> EmptyBoardWindow {
    let w = try EmptyBoardWindow()
    try w.turnKitOn()
    _ = try drawnInProcess(orders, on: w.editor)
    w.editor.selection = try require(table(w.editor, "orders")).id
    w.editor.undoHistory.seal()
    w.window.makeFirstResponder(w.canvas)
    return w
}

/// ⌘V, pressed in the window.
@MainActor private func commandV(_ w: EmptyBoardWindow) -> Bool {
    w.window.performKeyEquivalent(with: w.window.keyEvent("v", code: 9, modifiers: [.command]))
}

@MainActor let pasteSQLShippedTests = Suite("Paste SQL, shipped", [
    test("T1 panel 4: ⌘V with CREATE TABLE payments copied lands it selected beside orders, its key to orders drawn; Undo Paste SQL takes it whole") {
        let w = try shopWindow()
        defer { w.board.close() }
        let editor = w.editor
        let ordersID = try require(table(editor, "orders")).id
        pasteboardHolds(payments)
        expect(editor.canPaste, "Edit › Paste is on for SQL")
        let before = editor.document
        expect(commandV(w), "the canvas's ⌘V takes it")
        let landed = try require(table(editor, "payments"))
        expectEqual(editor.selectedShapeIDs, [landed.id], "payments selected, the key not")
        expectEqual(landed.props.columns.map(ColumnGrammar.print), [
            "id uuid pk", "order_id uuid", "stripe_charge_id text unique", "amount_cents int", "status text", "created_at timestamptz",
        ])
        expectEqual(landed.props.columns[1].onDelete, "cascade")
        let anchor = try require(editor.document[ordersID]?.box), box = try require(editor.document[landed.id]?.box)
        expect(!box.intersects(anchor), "beside orders, not on it")
        expectEqual(Set(keys(editor).keys), ["payments.order_id -> orders.id"], "its key to orders drawn, bound to both rows")
        expectEqual(undoTitle(w.window), "Undo Paste SQL")
        editor.undo()
        expectEqual(editor.document, before, "one Undo takes the table and its key")
    },
    test("pasted again with a column added: payments updated in place, its columns' ids and its key's arrow kept, the new column after the one pasted before it, a column it doesn't say kept") {
        let w = try shopWindow()
        defer { w.board.close() }
        let editor = w.editor
        pasteboardHolds(payments)
        expect(commandV(w))
        let first = try require(table(editor, "payments"))
        let key = try require(keys(editor)["payments.order_id -> orders.id"])
        // A column typed in since, which no paste says.
        _ = try drawnInProcess(#"table "payments" columns: "memo text""#, on: editor)
        editor.selection = try require(table(editor, "orders")).id
        pasteboardHolds(payments.replacingOccurrences(of: "  amount_cents int NOT NULL,", with: "  currency char(3) NOT NULL DEFAULT 'usd',\n  amount_cents bigint NOT NULL,"))
        let shapes = editor.document.shapes.count
        expect(commandV(w))
        expectEqual(editor.document.shapes.count, shapes + 0, "nothing made: payments restated")
        let again = try require(table(editor, "payments"))
        expectEqual(again.id, first.id)
        expectEqual(again.props.columns.map(\.name), ["id", "order_id", "stripe_charge_id", "currency", "amount_cents", "status", "created_at", "memo"])
        for column in first.props.columns {
            expectEqual(again.props.columns.first { $0.name == column.name }?.id, column.id, "\(column.name) keeps its id")
        }
        expectEqual(again.props.columns.first { $0.name == "amount_cents" }?.type.words, "bigint")
        expectEqual(keys(editor), ["payments.order_id -> orders.id": key], "the same arrow: its column kept its id")
        expectEqual(editor.selectedShapeIDs, [again.id])
        expectEqual(undoTitle(w.window), "Undo Paste SQL")
        editor.undo()
        expectEqual(table(editor, "payments")?.props.columns.map(\.name), ["id", "order_id", "stripe_charge_id", "amount_cents", "status", "created_at", "memo"])
    },
    test("a key the paste aims elsewhere is re-aimed, the same column's; a column pasted without REFERENCES keeps its key; a table found nowhere draws none") {
        let w = try shopWindow()
        defer { w.board.close() }
        let editor = w.editor
        _ = try drawnInProcess(#"table "invoices" below "orders" columns: "id uuid pk\nnumber text unique""#, on: editor)
        pasteboardHolds("CREATE TABLE refunds (id uuid PRIMARY KEY, paid_by uuid REFERENCES orders, ghost uuid REFERENCES nowhere (id));")
        expect(commandV(w))
        expectEqual(Set(keys(editor).keys), ["refunds.paid_by -> orders.id"], "REFERENCES orders: its primary key's row; nowhere draws nothing")
        expectEqual(table(editor, "refunds")?.props.columns.map(\.name), ["id", "paid_by", "ghost"], "the column stays, plain")
        pasteboardHolds("CREATE TABLE refunds (id uuid PRIMARY KEY, paid_by uuid REFERENCES invoices (number));")
        expect(commandV(w))
        expectEqual(Set(keys(editor).keys), ["refunds.paid_by -> invoices.number"], "re-aimed: the column has the one key the paste says")
        pasteboardHolds("CREATE TABLE refunds (id uuid PRIMARY KEY, paid_by uuid NOT NULL);")
        expect(commandV(w))
        expectEqual(Set(keys(editor).keys), ["refunds.paid_by -> invoices.number"], "a column pasted with no key keeps its key")
        expect(table(editor, "refunds")?.props.columns.first { $0.name == "paid_by" }?.nullable == false)
    },
    test("an enum and the table that types a column with it: the enum the paste makes, the column's type its pill; the enum pasted again joined by its values' text") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        try w.turnKitOn()
        let editor = w.editor
        pasteboardHolds("""
            CREATE TYPE public.ticket_state AS ENUM ('open', 'closed');
            CREATE TABLE tickets (id serial PRIMARY KEY, state ticket_state NOT NULL DEFAULT 'open');
            """)
        expect(commandV(w))
        let state = try require(editor.document.shapes.first { $0.kind == DatabaseEnum.kind })
        expectEqual(state[TitleProperty.self], "ticket_state")
        expectEqual(state.typed(as: DatabaseEnum.self)?.props.values.map(\.text), ["open", "closed"])
        let tickets = try require(table(editor, "tickets"))
        expectEqual(tickets.props.columns.first { $0.name == "state" }?.type, TypeRef("ticket_state", shape: state.id))
        expectEqual(Set(editor.selectedShapeIDs), [state.id, tickets.id], "both selected")
        expect((editor.document[tickets.id]?.box?.minY ?? 0) > (state.box?.maxY ?? 0), "the enums on a row of their own, the tables below (paste 02)")
        pasteboardHolds("CREATE TYPE ticket_state AS ENUM ('open', 'waiting', 'closed');")
        expect(commandV(w))
        expectEqual(editor.document[state.id]?.typed(as: DatabaseEnum.self)?.props.values.map(\.text), ["open", "waiting", "closed"])
    },
    test("a key to a table that isn't there is left out, and the same pasteboard pasted once the table is drawn draws it: the reading holds the text, not the file; REFERENCES t alone takes the primary key of the table it finds") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        try w.turnKitOn()
        let editor = w.editor
        let sql = "CREATE TABLE refunds (id uuid PRIMARY KEY, paid_by uuid REFERENCES charges, currency text REFERENCES currencies);"
        pasteboardHolds(sql)
        expect(commandV(w))
        expectEqual(keys(editor), [:], "charges and currencies are nowhere: the columns are plain")
        _ = try drawnInProcess(#"table "charges" below "refunds" columns: "ref text pk""#, on: editor)
        _ = try drawnInProcess(#"table "currencies" below "refunds" columns: "id int\ncode text pk""#, on: editor)
        expect(commandV(w), "the same pasteboard, as it was")
        expectEqual(Set(keys(editor).keys), ["refunds.paid_by -> charges.ref", "refunds.currency -> currencies.code"], "each table's primary key, as the file has it now")
    },
    test("a key to a table on another board reaches it through that table's pill, the column on the binding; the same paste again keeps the pill and the arrow") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        try w.turnKitOn()
        let editor = w.editor
        _ = try drawnInProcess(#"""
            table "customers" columns: "id uuid pk\nemail text unique"
            subboard "billing" below "customers"
            """#, on: editor)
        let customers = try require(table(editor, "customers"))
        let billing = BoardID(owner: try require(editor.document.shapes.first { $0[TitleProperty.self] == "billing" }).id)
        expect(editor.showBoard(billing))
        w.window.makeFirstResponder(w.canvas)
        @MainActor func pills() -> [ShapeRecord<Reference>] { editor.contents(of: billing).shapes.compactMap { $0.typed(as: Reference.self) } }
        @MainActor func keyArrows() -> [ShapeRecord<Arrow>] {
            editor.contents(of: billing).shapes.compactMap { $0.typed(as: Arrow.self) }.filter { $0[ChannelProperty.self] == ForeignKey.id }
        }
        pasteboardHolds("CREATE TABLE statements (id uuid PRIMARY KEY, customer_id uuid NOT NULL REFERENCES customers (id));")
        expect(commandV(w))
        let statements = try require(editor.contents(of: billing).shapes.first { $0[TitleProperty.self] == "statements" })
        let pill = try require(pills().first)
        expectEqual(pills().count, 1, "one pill, customers', on billing's board")
        expectEqual(pill.props.target?.id, customers.id)
        let arrow = try require(keyArrows().first)
        expectEqual(keyArrows().count, 1)
        expectEqual(arrow.props.start.binding?.shapeID, statements.id)
        expectEqual(arrow.props.end.binding?.shapeID, pill.id, "the key ends at the pill")
        expectEqual(arrow.props.end.binding?.part, customers.props.columns.first { $0.name == "id" }?.id, "the column on the binding")
        expectEqual(undoTitle(w.window), "Undo Paste SQL")
        // The pill is landed once the paste's table is placed, where its line from customer_id is clean (connect 24).
        let customerID = try require(editor.contents(of: billing).shapes.first { $0[TitleProperty.self] == "statements" }?.typed(as: DatabaseTable.self)?.props.columns.first { $0.name == "customer_id" }?.id)
        try expectClean(arrow.id, from: statements.id, row: customerID, in: editor, view: false, "a pasted key to another board")
        expect(commandV(w), "the same paste again")
        expectEqual(pills().map(\.id), [pill.id], "the same pill")
        expectEqual(keyArrows().map(\.id), [arrow.id], "the same arrow")
    },
    test("a column that has a key keeps it where the paste's REFERENCES names nothing the file has") {
        let w = try shopWindow()
        defer { w.board.close() }
        let editor = w.editor
        pasteboardHolds("CREATE TABLE refunds (id uuid PRIMARY KEY, paid_by uuid REFERENCES orders (id));")
        expect(commandV(w))
        let key = try require(keys(editor)["refunds.paid_by -> orders.id"])
        pasteboardHolds("CREATE TABLE refunds (id uuid PRIMARY KEY, paid_by uuid REFERENCES nowhere (id));")
        expect(commandV(w))
        expectEqual(keys(editor), ["refunds.paid_by -> orders.id": key], "the key it had stays: a name that finds nothing draws and removes nothing")
    },
    test("a .sql file reads as SQL, and two files as one schema, before their names which Finder also puts down as text; a file that is not .sql is not read") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        try w.turnKitOn()
        let editor = w.editor
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("paste-sql-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let one = folder.appendingPathComponent("people.sql"), two = folder.appendingPathComponent("pets.sql"), other = folder.appendingPathComponent("notes.txt")
        // The file's text has no CREATE TABLE in its first words for the sniff to read: the file's name is what says SQL is there.
        try "ALTER TABLE x ADD COLUMN y int;\n" .appending("CREATE TABLE people (id int PRIMARY KEY);").write(to: one, atomically: true, encoding: .utf8)
        try "CREATE TABLE pets (id int PRIMARY KEY, owner int REFERENCES people);".write(to: two, atomically: true, encoding: .utf8)
        try "CREATE TABLE ignored (id int);".write(to: other, atomically: true, encoding: .utf8)
        let pasteboard = ShippedPlugins.pasteboard
        pasteboard.clearContents()
        pasteboard.writeObjects([other as NSURL])
        pasteboard.setString("CREATE TABLE named_in_text (id int);", forType: .string)
        expect(!editor.canPaste, "a file that is not .sql: neither it nor the text beside it")
        pasteboard.clearContents()
        pasteboard.writeObjects([one as NSURL, two as NSURL])
        pasteboard.setString("people.sql\npets.sql\nCREATE TABLE named_in_text (id int);", forType: .string)
        expect(editor.canPaste)
        expect(commandV(w))
        expectEqual(Set(editor.document.shapes.filter { $0.kind == DatabaseTable.kind }.compactMap { $0[TitleProperty.self] }), ["people", "pets"], "the files' text, not the text beside them")
        expectEqual(Set(keys(editor).keys), ["pets.owner -> people.id"], "one schema: pets' key to the people the other file made")
    },
    test("SQL that reads as nothing (CREATE TABLE … AS SELECT, a prose mention) leaves Paste lit by its sniff, and ⌘V changes nothing and says so") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        try w.turnKitOn()
        let editor = w.editor
        pasteboardHolds("CREATE TABLE copy AS SELECT * FROM orders;")
        expect(editor.canPaste, "the sniff says maybe")
        let revision = editor.revision, announced = editor.announcements.count
        expect(commandV(w))
        expectEqual(editor.revision, revision, "nothing pasted")
        expectEqual(Array(editor.announcements.dropFirst(announced)), ["Nothing to paste"])
    },
    test("a schema wider than the view is brought into it (zoomed out to fit), one already in view leaves the camera; the announcement says what was made and what was updated") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        try w.turnKitOn()
        let editor = w.editor
        let camera = editor.cameraTarget
        pasteboardHolds("CREATE TABLE one (id int PRIMARY KEY);")
        expect(commandV(w))
        expectEqual(editor.cameraTarget, camera, "in view: the camera stays")
        expectEqual(editor.announcements.last, "Pasted Table")
        pasteboardHolds("CREATE TABLE one (id int PRIMARY KEY, more int);")
        expect(commandV(w))
        expectEqual(editor.announcements.last, "Updated Table")
        let tables = (1...24).map { "CREATE TABLE wide_\($0) (id int PRIMARY KEY, name text, note text, other text);" }
        pasteboardHolds(tables.joined(separator: "\n") + "\nCREATE TYPE kind AS ENUM ('a');\nCREATE TABLE one (id int PRIMARY KEY);")
        expect(commandV(w))
        // `one` restated as it is: not updated, and not selected (paste 04).
        expectEqual(editor.announcements.last, "Pasted Enum and 24 Tables")
        let landed = editor.selectedShapeIDs
        expectEqual(landed.count, 25)
        expect(editor.cameraTarget.zoom < camera.zoom, "zoomed out: \(editor.cameraTarget.zoom)")
        let bounds = try require(editor.shapeContext.bounds(of: landed))
        expect(editor.cameraTarget.toWorld(editor.unobscuredViewport).contains(bounds), "all of it in view")
    },
    test("paste 04: pasted again, only what changed is said and selected; pasted again as it is, \"Nothing changed\", no step, all it found selected") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        try w.turnKitOn()
        let editor = w.editor
        let schema = (1...4).map { "CREATE TABLE t\($0) (id int PRIMARY KEY, name text);" }
        pasteboardHolds(schema.joined(separator: "\n"))
        expect(commandV(w))
        expectEqual(editor.announcements.last, "Pasted 4 Tables")
        let all = Set(editor.selectedShapeIDs)
        var changed = schema
        changed[2] = "CREATE TABLE t3 (id int PRIMARY KEY, name text NOT NULL, added int);"
        pasteboardHolds(changed.joined(separator: "\n"))
        expect(commandV(w))
        expectEqual(editor.announcements.last, "Updated Table")
        expectEqual(editor.selectedShapeIDs.compactMap { editor.document[$0]?[TitleProperty.self] }, ["t3"], "the one it changed")
        expectEqual(undoTitle(w.window), "Undo Paste SQL")
        editor.selectedShapeIDs = []
        let revision = editor.revision
        expect(commandV(w))
        expectEqual(editor.announcements.last, "Nothing changed")
        expectEqual(editor.revision, revision, "nothing written")
        expectEqual(Set(editor.selectedShapeIDs), all, "what it found, selected")
        // No step: one Undo undoes the paste that changed t3.
        editor.undo()
        let t3 = try require(table(editor, "t3"))
        expectEqual(t3.props.columns.map(\.name), ["id", "name"], "the change undone, not an empty step")
    },
    test("paste new-1: a schema's keys pasted in one step are each painted just under their own table, as the whole list built again puts them; none above a card it crosses") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        try w.turnKitOn()
        let editor = w.editor
        pasteboardHolds("""
            CREATE TABLE categories (id uuid PRIMARY KEY, parent_id uuid REFERENCES categories (id), name text);
            CREATE TABLE customers (id uuid PRIMARY KEY, email character varying(255) NOT NULL, full_name text);
            CREATE TABLE addresses (id uuid PRIMARY KEY, customer_id uuid NOT NULL REFERENCES customers (id), line1 text);
            CREATE TABLE products (id uuid PRIMARY KEY, category_id uuid REFERENCES categories (id), sku text);
            CREATE TABLE orders (id uuid PRIMARY KEY, customer_id uuid NOT NULL REFERENCES customers (id),
                shipping_address_id uuid REFERENCES addresses (id), total_cents int);
            CREATE TABLE order_items (id uuid PRIMARY KEY, order_id uuid NOT NULL REFERENCES orders (id),
                product_id uuid NOT NULL REFERENCES products (id), qty int);
            """)
        expect(commandV(w))
        let kept = editor.paintOrder().map(\.id)
        let arrows = editor.document.shapes.filter { $0.kind == Arrow.kind }
        expectEqual(arrows.count, 7, "every key drawn")
        for arrow in arrows {
            guard let typed = arrow.typed(as: Arrow.self), let from = typed.props.start.binding?.shapeID, let to = typed.props.end.binding?.shapeID,
                  let at = kept.firstIndex(of: arrow.id), let a = kept.firstIndex(of: from), let b = kept.firstIndex(of: to) else { continue }
            expect(at < min(a, b) || from == to, "a key under both its tables")
            expectEqual(editor.document[kept[at + 1]]?.kind == Arrow.kind || [from, to].contains(kept[at + 1]), true, "just under one of its own")
        }
        editor.undo()
        editor.redo()
        expectEqual(editor.paintOrder().map(\.id), kept, "the order the list built afresh gives")
    },
    test("paste new-2: pasted again with a column retyped longer, the table it updates is widened to read whole, in Paste SQL's step; never narrowed") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        try w.turnKitOn()
        let editor = w.editor
        pasteboardHolds("CREATE TABLE shipments (id uuid PRIMARY KEY, tracking_number character varying(64) NOT NULL);")
        expect(commandV(w))
        let shipments = try require(table(editor, "shipments")).id
        editor.transact { $0.update(shipments) { $0.box?.size.width = 260 } }
        editor.undoHistory.seal()
        pasteboardHolds("CREATE TABLE shipments (id uuid PRIMARY KEY, tracking_number character varying(64) NOT NULL, delivered_at timestamp with time zone);")
        expect(commandV(w))
        expectEqual(editor.announcements.last, "Updated Table")
        let width = try require(editor.document[shipments]?.box?.width)
        expect(width > 260, "widened to its new widest line: \(width)")
        expectEqual(undoTitle(w.window), "Undo Paste SQL")
        editor.undo()
        expectEqual(editor.document[shipments]?.box?.width, 260, "one Undo takes the update and the widening")
    },
    test("pasted again with a table narrowed by hand left as it is: it keeps the width the person gave it, and the paste that changes only another table widens that one, in one step") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        try w.turnKitOn()
        let editor = w.editor
        let narrow = "CREATE TABLE shipments (id uuid PRIMARY KEY, tracking_number character varying(64) NOT NULL);"
        let other = "CREATE TABLE carriers (id uuid PRIMARY KEY);"
        pasteboardHolds([narrow, other].joined(separator: "\n"))
        expect(commandV(w))
        let shipments = try require(table(editor, "shipments")).id, carriers = try require(table(editor, "carriers")).id
        editor.transact { $0.update(shipments) { $0.box?.size.width = 160 } }
        editor.undoHistory.seal()
        let undo = undoTitle(w.window)
        pasteboardHolds([narrow, other].joined(separator: "\n"))
        expect(commandV(w))
        expectEqual(editor.document[shipments]?.box?.width, 160, "left as it is: the person's width")
        expectEqual(undoTitle(w.window), undo, "nothing changed, no step")
        let carriersWas = try require(editor.document[carriers]?.box?.width)
        pasteboardHolds([narrow, "CREATE TABLE carriers (id uuid PRIMARY KEY, service_level_agreement_reference_code character varying(255));"].joined(separator: "\n"))
        expect(commandV(w))
        expectEqual(editor.document[shipments]?.box?.width, 160, "still the person's width: the put didn't change it")
        expect((editor.document[carriers]?.box?.width ?? 0) > carriersWas, "the table it changed widened to read whole")
        expectEqual(undoTitle(w.window), "Undo Paste SQL")
        editor.undo()
        expectEqual(editor.document[carriers]?.box?.width, carriersWas, "one Undo")
        expectEqual(editor.document[shipments]?.box?.width, 160)
    },
    test("paste 04: pasted again with only a key re-aimed or added, the table the key starts from is what changed: said \"Updated Table\", and it alone selected") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        try w.turnKitOn()
        let editor = w.editor
        let tables = ["CREATE TABLE accounts (id int PRIMARY KEY);", "CREATE TABLE customers (id int PRIMARY KEY);"]
        pasteboardHolds((tables + ["CREATE TABLE orders (id int PRIMARY KEY, owner_id int REFERENCES customers (id));", "CREATE TABLE notes (id int PRIMARY KEY, order_id int);"]).joined(separator: "\n"))
        expect(commandV(w))
        expectEqual(editor.announcements.last, "Pasted 4 Tables")
        editor.selectedShapeIDs = []
        // The key of orders aimed at accounts instead: nothing in any table's own record changes.
        pasteboardHolds((tables + ["CREATE TABLE orders (id int PRIMARY KEY, owner_id int REFERENCES accounts (id));", "CREATE TABLE notes (id int PRIMARY KEY, order_id int);"]).joined(separator: "\n"))
        expect(commandV(w))
        expectEqual(editor.announcements.last, "Updated Table")
        expectEqual(editor.selectedShapeIDs.compactMap { editor.document[$0]?[TitleProperty.self] }, ["orders"], "the table the key starts from, alone")
        editor.selectedShapeIDs = []
        // A key added to a column that had none.
        pasteboardHolds((tables + ["CREATE TABLE orders (id int PRIMARY KEY, owner_id int REFERENCES accounts (id));", "CREATE TABLE notes (id int PRIMARY KEY, order_id int REFERENCES orders (id));"]).joined(separator: "\n"))
        expect(commandV(w))
        expectEqual(editor.announcements.last, "Updated Table")
        expectEqual(editor.selectedShapeIDs.compactMap { editor.document[$0]?[TitleProperty.self] }, ["notes"])
    },
    test("the kit off: ⌘V of SQL does nothing and Paste is off; on, it pastes") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        pasteboardHolds(payments)
        expect(!editor.canPaste, "no reader of SQL in a file with the kit off")
        let revision = editor.revision
        _ = commandV(w)
        expectEqual(editor.revision, revision, "nothing pasted")
        try w.turnKitOn()
        expect(editor.canPaste)
        expect(commandV(w))
        expect(table(editor, "payments") != nil)
    },
    test("a pasted schema keeps the room a table needs as a row is typed into it below each table, in a new board's window, so opening one covers nothing under it (UX walk 4 paste-4-1)") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        try w.turnKitOn()
        let editor = w.editor
        let sql = (1...6).map { "CREATE TABLE t\($0) (id int PRIMARY KEY, name text);" }.joined(separator: "\n")
        pasteboardHolds(sql)
        expect(commandV(w))
        let boxes = editor.document.shapes.filter { $0.kind == DatabaseTable.kind }.compactMap(\.box).sorted { $0.minY < $1.minY }
        expectEqual(boxes.count, 6)
        let first = boxes.filter { $0.minY == boxes[0].minY }, rest = boxes.filter { $0.minY > boxes[0].minY }
        expect(!rest.isEmpty, "a second row: \(boxes)")
        // The first table opened and a column typed past its end: its waiting line and the next row's pills clear of each other.
        for box in rest { expect(box.minY - (first.map(\.maxY).max() ?? 0) >= KitStyle.roomKeptBelow - 0.5, "\(box.minY - (first.map(\.maxY).max() ?? 0)) under the first row") }
    },
])

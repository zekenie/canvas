import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Connections
import Engineering
import Geometry
import LineRows
import Selection
import ShippedTesting
import TestKit
import TextEditing
import Titles
import Types

// What the whole-branch review found in the grammars and the model, as shipped in a board's window: a pg_dump pasted with
// types, defaults and names of several words, pasted again and a column renamed on its line, every column as it was; a column
// whose words name an enum drawn later drawn as its pill; a key's words typed before its table existed said once the key is
// drawn, never re-aiming it, and only a line's first arrow read; tables drawn by `columns:`, an enum by `values:` and a table
// given a key column by ⌘L as wide as their lines read; two tables of one name keyed to the one in the table's own database; a
// body's type whose note was deleted and made again bound at rest; and paths an agent writes without a slash.

@MainActor private func table(_ editor: CanvasEditor, _ title: String) -> ShapeRecord<DatabaseTable>? {
    editor.document.shapes.first { $0[TitleProperty.self] == title && $0.kind == DatabaseTable.kind }?.typed(as: DatabaseTable.self)
}

@MainActor private func column(_ editor: CanvasEditor, _ title: String, _ name: String) -> Column? {
    table(editor, title)?.props.columns.first { $0.name == name }
}

/// Each key on the board as `from.column -> to.column`, by the tables' titles and the columns' names now.
@MainActor private func keys(_ editor: CanvasEditor) -> [String] {
    editor.document.shapes.compactMap { $0.typed(as: Arrow.self) }.compactMap { arrow -> String? in
        guard arrow[ChannelProperty.self] == ForeignKey.id, let start = arrow.props.start.binding, let end = arrow.props.end.binding else { return nil }
        @MainActor func said(_ binding: ArrowBinding) -> String {
            let record = editor.document[binding.shapeID]
            let name = record.flatMap { editor.registry.parts(of: $0)?.first { $0.id == binding.part }?.name } ?? "?"
            return "\(record?[TitleProperty.self] ?? "?").\(name)"
        }
        return "\(said(start)) -> \(said(end))"
    }.sorted()
}

@MainActor private func pasteboardHolds(_ text: String) {
    let pasteboard = ShippedPlugins.pasteboard
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}

/// ⌘V, pressed in the window.
@MainActor private func commandV(_ w: EmptyBoardWindow) -> Bool {
    w.window.performKeyEquivalent(with: w.window.keyEvent("v", code: 9, modifiers: [.command]))
}

/// A pg_dump of one table and its enum: types, defaults and names of several words, an enum's name with a space.
private let dump = #"""
    CREATE TYPE public."Order Status" AS ENUM ('new', 'paid');
    CREATE TABLE public.orders (
        id integer NOT NULL,
        "placed on" timestamp with time zone DEFAULT now() NOT NULL,
        note character varying(255) DEFAULT ''::character varying NOT NULL,
        ratio double precision,
        due timestamp(6) without time zone DEFAULT '2020-01-01 00:00:00'::timestamp without time zone,
        status public."Order Status" DEFAULT 'new'::public."Order Status" NOT NULL
    );
    ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_pkey PRIMARY KEY (id);
    """#

@MainActor let wholeLineShippedTests = Suite("Lines read back what they print, shipped", [
    test("a pg_dump pasted twice, then a column renamed on its line: every column of the table as it was, but the one name; Rename Column") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        try w.turnKitOn()
        w.window.makeFirstResponder(w.canvas)
        pasteboardHolds(dump)
        expect(commandV(w))
        let pasted = try require(table(editor, "orders")).props.columns
        expectEqual(pasted.map(\.type.words), ["integer", "timestamp with time zone", "character varying(255)", "double precision",
                                               "timestamp(6) without time zone", "Order Status"])
        let status = try require(editor.document.shapes.first { $0[TitleProperty.self] == "Order Status" }).id
        expectEqual(pasted.last?.type.shape, status, "the enum of a spaced name, bound")
        editor.selectedShapeIDs = []
        expect(commandV(w), "pasted again")
        expectEqual(table(editor, "orders")?.props.columns, pasted, "nothing doubled, nothing changed")
        let walk = w.walk()
        try w.edit("orders", row: "note")
        expectEqual(w.line?.string, "note character varying(255) default ''::character varying")
        w.line?.setSelectedRange(NSRange(location: 0, length: 4))
        w.type("memo", with: walk)
        walk.press(.down)
        expectEqual(undoTitle(w.window), "Undo Rename Column")
        expectEqual(w.line?.string, "ratio double precision null")
        walk.press(.down)
        expectEqual(w.line?.string, "due timestamp(6) without time zone null default '2020-01-01 00:00:00'::timestamp without time zone")
        walk.press(.down)
        expectEqual(w.line?.string, "status \"Order Status\" default 'new'::public.\"Order Status\"",
                    "a literal cast to a schema's quoted type is one word, as SQL writes it")
        w.line?.setSelectedRange(NSRange(location: 0, length: 6))
        w.type("state", with: walk)
        walk.press(.escape)
        let now = try require(table(editor, "orders")).props.columns
        var expected = pasted
        expected[2].name = "memo"
        expected[5].name = "state"
        expectEqual(now, expected, "every column as it was stored, the two names aside")
        walk.press(.escape)
    },
    test("a column whose words name an enum drawn later is drawn as its pill, as a column bound to it is; its line says the same") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        try w.turnKitOn()
        try w.draw(#"table "orders" columns: "id uuid pk\nstate order_status""#)
        editor.selectedShapeIDs = []
        let size = CGSize(width: 700, height: 500)
        let words = try require(renderBitmap(editor, size: size).representation(using: .png, properties: [:]))
        try w.draw(#"enum-type "order_status" right of "orders" (gap: 2000) values: "pending\npaid""#)
        let status = try require(editor.document.shapes.first { $0[TitleProperty.self] == "order_status" }).id
        editor.selectedShapeIDs = []
        let late = try require(renderBitmap(editor, size: size).representation(using: .png, properties: [:]))
        expect(late != words, "its pill now")
        let orders = try require(table(editor, "orders")).id
        editor.transact("Bind") { $0.update(orders, as: DatabaseTable.self) { $0.props.columns[1].type.shape = status } }
        editor.selectedShapeIDs = []
        expect(late == (try require(renderBitmap(editor, size: size).representation(using: .png, properties: [:]))), "as a column bound to it")
        editor.undo()
        try w.edit("orders", row: "state")
        expect(w.line?.highlights.contains { $0.range == NSRange(location: 6, length: 12) } == true, "the pill on its line")
        let walk = w.walk()
        walk.press(.escape)
        walk.press(.escape)
    },
    test("a key's words typed before its table: once ⌘L draws the key they go; a drawn edge elsewhere leaves them after it, never re-aiming it; only the first → is read") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        try w.turnKitOn()
        try w.draw(#"""
            table "customers" columns: "id uuid pk\nemail text unique"
            table "orders" right of "customers" (gap: 200) columns: "id uuid pk"
            """#)
        let walk = w.walk()
        try w.edit("orders", row: "id")
        walk.press(Chord(Key.right, .command))
        walk.press(.return)
        for line in ["buyer_id uuid -> clients.id", "ref_id uuid -> accounts.id", "dup_id uuid -> ledger.id"] {
            w.type(line, with: walk)
            walk.press(.return)
        }
        walk.press(.escape)
        walk.press(.escape)
        expectEqual(column(editor, "orders", "buyer_id")?.unread, "→ clients.id", "no clients yet: words")
        try w.draw(#"""
            table "clients" below "customers" columns: "id uuid pk"
            table "accounts" below "clients" columns: "id uuid pk"
            table "ledger" below "accounts" columns: "id uuid pk"
            """#)
        // ⌘L in the row: the key drawn, the words gone.
        try w.edit("orders", row: "buyer_id")
        walk.press(Chord("l", .command))
        w.type("clients", with: walk)
        walk.press(.return)
        expect(keys(editor).contains("orders.buyer_id -> clients.id"), "\(keys(editor))")
        expectEqual(column(editor, "orders", "buyer_id")?.unread, "", "the key says where it goes")
        walk.press(.escape)
        walk.press(.escape)
        // A key drawn to the row its words name: said once, by the key.
        try w.draw(#"edge "orders".dup_id -> "ledger".id"#)
        try w.edit("orders", row: "dup_id")
        expectEqual(w.line?.string, "dup_id uuid → ledger.id")
        walk.press(.escape)
        walk.press(.escape)
        // A key drawn elsewhere: its arrow, and no words of another key beside it, and an edit keeps the key where it is.
        try w.draw(#"edge "orders".ref_id -> "customers".id"#)
        try w.edit("orders", row: "ref_id")
        expectEqual(w.line?.string, "ref_id uuid → customers.id", "the board's one key, not the words kept of another")
        w.line?.setSelectedRange(NSRange(location: 0, length: 3))
        w.type("refer", with: walk)
        walk.press(.down)
        expect(keys(editor).contains("orders.refer_id -> customers.id") && !keys(editor).contains("orders.refer_id -> accounts.id"), "\(keys(editor))")
        expectEqual(column(editor, "orders", "refer_id")?.unread, "", "the stale words go with the commit")
        walk.press(.escape)
        walk.press(.escape)
        // Only the first → is read, as draw reads it: one that names nothing leaves the line no key.
        try w.edit("orders", row: "id")
        walk.press(Chord(Key.right, .command))
        walk.press(.return)
        let before = keys(editor)
        w.type("a_id uuid -> nowhere.x -> customers.id", with: walk)
        walk.press(.return)
        expectEqual(keys(editor), before, "no key drawn")
        expectEqual(column(editor, "orders", "a_id")?.unread, "→ nowhere.x → customers.id")
        walk.press(.escape)
        walk.press(.escape)
    },
    test("a key to a column whose name has a space: its line reads back, and renaming the referencing row keeps the key") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        try w.turnKitOn()
        try w.draw(#"""
            table "customers" columns: "id uuid pk\n\"first name\" text unique"
            table "orders" right of "customers" (gap: 200) columns: "id uuid pk"
            """#)
        let walk = w.walk()
        try w.edit("orders", row: "id")
        walk.press(Chord(Key.right, .command))
        walk.press(.return)
        w.type(#"buyer uuid -> customers."first name""#, with: walk)
        walk.press(.return)
        expect(keys(editor).contains("orders.buyer -> customers.first name"), "\(keys(editor))")
        walk.press(.escape)
        walk.press(.escape)
        try w.edit("orders", row: "buyer")
        expectEqual(w.line?.string, #"buyer uuid → customers."first name""#)
        w.line?.setSelectedRange(NSRange(location: 0, length: 5))
        w.type("owner", with: walk)
        walk.press(.down)
        expectEqual(undoTitle(w.window), "Undo Rename Column")
        expect(keys(editor).contains("orders.owner -> customers.first name"), "kept: \(keys(editor))")
        walk.press(.escape)
        walk.press(.escape)
    },
    test("draw widens a table or an enum it writes rows to, never narrower, and not at a size the statement gives or when it writes no rows") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        try w.turnKitOn()
        @MainActor func width(_ title: String) -> CGFloat {
            editor.document.shapes.first { $0[TitleProperty.self] == title }?.box?.width ?? 0
        }
        try w.draw(#"table "sized" size: 200x columns: "shipping_address_line_two character varying(255) null""#)
        expectEqual(width("sized"), 200, "a size the statement gives wins")
        try w.draw(#"table "orders" columns: "id uuid pk""#)
        let narrow = width("orders")
        expectEqual(narrow, 260)
        try w.draw(#"table "orders" columns: "shipping_address_line_two character varying(255) null""#)
        let widened = width("orders")
        expect(widened > narrow, "an existing table given a longer row is widened: \(widened)")
        try w.draw(#"table "orders" columns: "id uuid pk""#)
        expectEqual(width("orders"), widened, "never narrower")
        let orders = try require(table(editor, "orders")).id
        editor.transact("Narrow") { $0.update(orders, as: DatabaseTable.self) { $0.props.frame.size.width = 260 } }
        try w.draw(#"table "orders" below "sized" (gap: 100)"#)
        expectEqual(width("orders"), 260, "a statement that writes no rows leaves the width a person chose")
        try w.draw(#"enum-type "states" below "orders" (gap: 100) values: "awaiting_customer_confirmation_of_the_shipping_address""#)
        let states = width("states")
        expect(states > 220 && states <= 560, "an enum: \(states)")
        try w.draw(#"enum-type "states" values: "new""#)
        expectEqual(width("states"), states, "and never narrower")
    },
    test("a table drawn with a long line, an enum with a long value and a table given a key column by ⌘L are as wide as their lines read") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        try w.turnKitOn()
        try w.draw(#"""
            table "addresses" columns: "shipping_address_line_two character varying(255) null"
            enum-type "states" right of "addresses" (gap: 200) values: "awaiting_customer_confirmation_of_the_shipping_address"
            table "international_customer_shipping_addresses" below "addresses" (gap: 200) columns: "id uuid pk"
            table "notes" right of "international_customer_shipping_addresses" (gap: 200) columns: "id uuid pk"
            """#)
        let addresses = try require(editor.document[try require(table(editor, "addresses")).id]?.box).width
        expect(addresses > 260 && addresses <= 560, "the table read whole: \(addresses)")
        let states = try require(editor.document.shapes.first { $0[TitleProperty.self] == "states" }?.box).width
        expect(states > 220 && states <= 560, "the enum read whole: \(states)")
        let notes = try require(table(editor, "notes"))
        expectEqual(notes.props.frame.width, 260, "a short one keeps a new table's width")
        editor.selectedShapeIDs = [notes.id]
        let walk = w.walk()
        walk.press(Chord("l", .command))
        w.type("international", with: walk)
        walk.press(.return)
        expectEqual(undoTitle(w.window), "Undo Add Key Column")
        expectEqual(table(editor, "notes")?.props.columns.map(\.name), ["id", "international_customer_shipping_address_id"])
        expect((table(editor, "notes")?.props.frame.width ?? 0) > 260, "widened in the step: \(table(editor, "notes")?.props.frame.width ?? 0)")
        walk.press(.escape)
    },
    test("two users tables in two databases: a key typed in shop's orders goes to shop's users; the offers say where each is") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        try w.turnKitOn()
        try w.draw("""
            database "auth"
            database "shop" right of "auth"
            """)
        try w.draw("""
            table "users" in "auth" columns: "id uuid pk"
            table "users" in "shop" columns: "id uuid pk"
            table "orders" in "shop" columns: "id uuid pk"
            """)
        let shop = try require(editor.document.shapes.first { $0[TitleProperty.self] == "shop" }).id
        let shopUsers = try require(editor.document.shapes.first { $0[TitleProperty.self] == "users" && editor.holder(of: $0.id) == shop }).id
        let walk = w.walk()
        try w.edit("orders", row: "id")
        walk.press(Chord(Key.right, .command))
        walk.press(.return)
        w.type("user_id uuid -> us", with: walk)
        let listed = Array(zip(w.line?.listedOffers ?? [], w.line?.listedDetails ?? []).filter { $0.0 == "users.id" }.map(\.1))
        expectEqual(listed.sorted(), ["uuid · auth", "uuid · shop"], "each says where it is")
        w.line?.selectAll(nil)
        w.type("user_id uuid -> users.id", with: walk)
        walk.press(.return)
        let arrow = try require(editor.document.shapes.compactMap { $0.typed(as: Arrow.self) }.first { $0[ChannelProperty.self] == ForeignKey.id })
        expectEqual(arrow.props.end.binding?.shapeID, shopUsers, "the users in its own database")
        walk.press(.escape)
        walk.press(.escape)
    },
    test("a body's type whose note was deleted and made again is bound at rest by its name, its pill the new note's") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        try w.turnKitOn()
        try w.draw(#"""
            sticky-note "Refund" schema: "{\"type\": \"object\"}"
            api "orders API" right of "Refund" (gap: 80) endpoints: "POST /refunds (Refund) → 201 Refund"
            """#)
        let old = try require(editor.document.shapes.first { $0[TitleProperty.self] == "Refund" }).id
        let api = try require(editor.document.shapes.first { $0.kind == API.kind }).id
        expectEqual(editor.document[api]?.typed(as: API.self)?.props.endpoints.first?.endpoint?.body?.shape, old)
        editor.transact("Delete") { $0.delete(Set([old])) }
        try w.draw(#"sticky-note "Refund" below "orders API" (gap: 80) schema: "{\"type\": \"object\"}""#)
        let made = try require(editor.document.shapes.first { $0[TitleProperty.self] == "Refund" }).id
        expect(made != old)
        editor.selectedShapeIDs = [api]
        editor.beginEditing(api)
        w.window.settle()
        w.lineRows?.go(to: .row(try require(editor.document[api]?.typed(as: API.self)?.props.endpoints.first?.id)))
        w.window.settle()
        expectEqual(w.line?.line.references.map(\.target), [PartAddress(made), PartAddress(made)], "the body and the response stand for the note made since")
        let walk = w.walk()
        walk.press(.escape)
        walk.press(.escape)
    },
    test("draw's endpoints written without a leading slash are written from one, so Group by Prefix keeps every full path") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        try w.turnKitOn()
        try w.draw(#"api "orders API" endpoints: [{"method": "GET", "path": "orders"}, {"method": "get", "path": "orders/{id}"}, {"header": "customers"}]"#)
        let api = try require(editor.document.shapes.first { $0.kind == API.kind }?.typed(as: API.self))
        expectEqual(APIGroups.fullPaths(in: api.props.endpoints), ["/orders", "/orders/{id}", "/customers"])
        expect(editor.groupByPrefix([api.id]))
        let grouped = try require(editor.document[api.id]?.typed(as: API.self)).props.endpoints
        expectEqual(Set(grouped.indices.compactMap { index in grouped[index].endpoint.map { _ in APIGroups.fullName(of: index, in: grouped) } }),
                    ["GET /orders", "GET /orders/{id}"])
    },
    test("a key line typed long in a table at the view's right edge, in a new board's window with its inspector, pans the view to keep the line's end clear of the inspector and the minimap (UX walk 4 tables-4-1)") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        try w.turnKitOn()
        let editor = w.editor
        _ = try drawnInProcess(#"table "orders" columns: "id uuid pk\ncustomer_id uuid""#, on: editor)
        let orders = try require(table(editor, "orders")).id
        let walk = w.walk()
        editor.selection = orders
        // The table put at the clear view's right edge, as a person scrolls it there.
        let clear = editor.unobscuredViewport
        let box = try require(editor.document[orders]?.box)
        editor.camera = Camera(origin: CGPoint(x: box.minX - (clear.maxX - 120), y: box.minY - clear.midY), zoom: 1)
        walk.press(.return)
        w.window.settle()
        w.type("created_at timestamptz not null default now() references customers", with: walk)
        let frame = try require(editor.shapeContext.geometry(of: orders)?.bounds)
        let shown = editor.cameraTarget.toView(frame)
        expect(frame.width > 300, "laid out wider than it was stored: \(frame)")
        expect(editor.clearView.rect.contains(CGRect(x: min(shown.maxX, editor.clearView.rect.maxX), y: shown.midY, width: 0, height: 0)), "the line's end in the clear view")
        expect(shown.maxX <= editor.clearView.rect.maxX + 0.5, "its end clear of the inspector: \(shown) in \(editor.clearView.rect)")
        walk.press(.escape)
    },
])

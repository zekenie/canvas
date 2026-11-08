import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CanvasUI
import Chrome
import Connections
import Engineering
import LanguageModels
import LineRows
import Selection
import ShippedTesting
import StickyNotes
import TestKit
import TextEditing
import Titles
import Topology

// Keys typed (K5), as shipped, on a board's window with real presses: T7 panels 4 to 7 (`customer_id uuid -> cus`, Tab, ↩, ↩ on
// the empty row, ⌥⇧Tab to the key), T3 panel 1 (`→ customers.` offering its columns, the row lit), a line's key re-aimed,
// taken out and left as words where it names nothing, each its own step; a rename followed by the line; ⌘L on a row (the
// picker listing tables and their columns, never an enum or a note) and on a table (T5 panel 4, Add Key Column; T3 panel 3,
// tables listed by where they are); `canvas draw`'s `columns:` lines drawing their keys, and `delete edge` with row ends.

@MainActor private func tables(_ editor: CanvasEditor) -> [ShapeRecord<DatabaseTable>] {
    editor.document.shapes.compactMap { $0.typed(as: DatabaseTable.self) }
}

@MainActor private func table(_ editor: CanvasEditor, _ title: String) -> ShapeRecord<DatabaseTable>? {
    editor.document.shapes.first { $0[TitleProperty.self] == title }?.typed(as: DatabaseTable.self)
}

@MainActor private func column(_ editor: CanvasEditor, _ title: String, _ name: String) -> PartID? {
    table(editor, title)?.props.columns.first { $0.name == name }?.id
}

@MainActor private func arrows(_ editor: CanvasEditor) -> [ShapeRecord<Arrow>] {
    editor.document.shapes.compactMap { $0.typed(as: Arrow.self) }
}

/// Each key on the board as `from.column -> to.column`, by the tables' titles and the columns' names now.
@MainActor private func keys(_ editor: CanvasEditor) -> [String] {
    arrows(editor).compactMap { arrow -> String? in
        guard let start = arrow.props.start.binding, let end = arrow.props.end.binding else { return nil }
        @MainActor func said(_ binding: ArrowBinding) -> String {
            let record = editor.document[binding.shapeID]
            let name = record.flatMap { editor.registry.parts(of: $0)?.first { $0.id == binding.part }?.name } ?? "?"
            return "\(record?[TitleProperty.self] ?? "?").\(name)"
        }
        return "\(said(start)) -> \(said(end))"
    }.sorted()
}

extension EmptyBoardWindow {
    /// Tables drawn by `canvas draw`, the step sealed, the canvas with the keyboard.
    func draw(_ script: String) throws {
        _ = try drawnInProcess(script, on: editor)
        editor.undoHistory.seal()
        window.makeFirstResponder(canvas)
        window.settle()
    }

    /// The line field of the table being edited.
    var line: LineField? { lineRows?.field }

    /// Edits `title`'s row `name`, the caret at the end of its line.
    func edit(_ title: String, row name: String) throws {
        let id = try require(table(editor, title)).id
        editor.selectedShapeIDs = [id]
        editor.beginEditing(id)
        window.settle()
        lineRows?.go(to: .row(try require(column(editor, title, name))))
        window.settle()
    }

    /// The line's text replaced by `text`, as a select-all and typing would.
    func retype(_ text: String, with walk: KeyWalk) {
        line?.selectAll(nil)
        type(text, with: walk)
    }
}

private let shop = #"""
    table "customers" columns: "id uuid pk\nemail text unique\nname text\ncreated_at timestamptz"
    table "orders" right of "customers" (gap: 200) columns: "id uuid pk\ncustomer_id uuid\ntotal_cents int"
    enum-type "customer_status" below "customers" values: "active\nclosed"
    """#

@MainActor let typedKeyShippedTests = Suite("Keys typed, shipped", [
    test("T7, panels 4 to 7, by the keys alone: customer_id uuid -> cus offers customers' key columns, Tab picks, ↩ draws the key, ↩ ends, ⌥⇧Tab is the key") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        try w.turnKitOn()
        let walk = w.walk()
        walk.press(Chord("/"))
        w.type("table customers", with: walk)
        walk.press(.return)
        w.type("email text unique", with: walk)
        walk.press(.return)
        w.type("name text", with: walk)
        walk.press(.return)
        walk.press(.return)
        walk.press(Chord(Key.return, .shift))
        w.type("orders", with: walk)
        walk.press(.return)
        let customers = try require(table(editor, "customers")), orders = try require(table(editor, "orders"))
        w.type("customer_id uuid -> cus", with: walk)
        expectEqual(w.line?.string, "customer_id uuid → cus", "-> is →")
        expectEqual(w.line?.listedOffers, ["customers.id", "customers.email"], "the key columns of customers: its primary key, then its unique one")
        expectEqual(w.line?.highlightedOffer, "customers.id")
        expectEqual(editor.service(LineRowsService.self)?.light, PartAddress(customers.id, part: column(editor, "customers", "id")), "its row lit")
        walk.press(.tab)
        expectEqual(w.line?.string, "customer_id uuid → customers.id", "Tab picks")
        expectEqual(w.line?.listedOffers, [], "and the list goes")
        expectEqual(keys(editor), [], "nothing drawn while it's typed")
        walk.press(.return)
        expectEqual(undoTitle(w.window), "Undo Add Column", "the column and its key, one step")
        expectEqual(keys(editor), ["orders.customer_id -> customers.id"])
        expectEqual(table(editor, "orders")?.props.columns.map(ColumnGrammar.print), ["id uuid pk", "customer_id uuid"], "the key is its arrow, not words")
        expectEqual(arrows(editor).first?[ChannelProperty.self], ForeignKey.id)
        expectEqual(w.lineRows?.focus, .waiting)
        walk.press(.return)
        expectEqual(editor.editingShapeID, nil, "↩ on the empty row ends editing")
        expectEqual(editor.selectedShapeIDs, [orders.id])
        // ⌥⇧Tab walks orders' parts back from the last in reading order, the resize handles' bottom corners after the key, to it.
        var presses = 0
        repeat {
            walk.press(.optionBackTab)
            presses += 1
        } while editor.focusedPart?.title.contains("id in customers") != true && presses < 8
        let part = try require(editor.focusedPart)
        expectEqual(part.title, "Arrow to id in customers", "its key, named by the row it goes to")
        // One Undo takes the column and its key.
        let board = try require(w.window as? BoardWindow)
        walk.press(.escape)
        board.undo(nil)
        expectEqual(keys(editor), [])
        expectEqual(table(editor, "orders")?.props.columns.map(\.name), ["id"])
    },
    test("T3, panel 1: → customers. offers its key columns by name, the highlighted one's row lit, and the table's name in its pill") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        try w.turnKitOn()
        try w.draw(shop)
        let walk = w.walk()
        try w.edit("orders", row: "customer_id")
        w.type(" -> customers.", with: walk)
        expectEqual(w.line?.listedOffers, ["id", "email"])
        expectEqual(editor.service(LineRowsService.self)?.light, PartAddress(try require(table(editor, "customers")).id, part: column(editor, "customers", "id")))
        expect(w.line?.highlights.count == 1, "customers. in its pill")
        w.type("em", with: walk)
        expectEqual(w.line?.listedOffers, ["email"])
        walk.press(.tab)
        expectEqual(w.line?.string, "customer_id uuid → customers.email")
        walk.press(.down)
        expectEqual(undoTitle(w.window), "Undo Add Key", "only the key changed")
        expectEqual(keys(editor), ["orders.customer_id -> customers.email"])
        walk.press(.escape)
    },
    test("a line's key: re-aimed (Change Key, the same arrow), taken out (Delete Key), and a → naming nothing kept as plain words, no arrow") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        try w.turnKitOn()
        try w.draw(shop + "\nedge \"orders\".customer_id -> \"customers\".id")
        let walk = w.walk()
        let arrow = try require(arrows(editor).first).id
        try w.edit("orders", row: "customer_id")
        expectEqual(w.line?.string, "customer_id uuid → customers.id", "a focused line prints its key")
        w.retype("customer_id uuid -> customers.email", with: walk)
        walk.press(.down)
        expectEqual(undoTitle(w.window), "Undo Change Key")
        expectEqual(keys(editor), ["orders.customer_id -> customers.email"])
        expectEqual(arrows(editor).map(\.id), [arrow], "re-aimed: the same arrow")
        walk.press(.up)
        expectEqual(w.line?.string, "customer_id uuid → customers.email")
        w.retype("customer_id uuid", with: walk)
        walk.press(.down)
        expectEqual(undoTitle(w.window), "Undo Delete Key")
        expectEqual(keys(editor), [])
        walk.press(.up)
        w.retype("customer_id uuid -> nowhere.id", with: walk)
        walk.press(.down)
        expectEqual(undoTitle(w.window), "Undo Change Column")
        expectEqual(keys(editor), [], "it names no table: no key")
        expectEqual(table(editor, "orders")?.props.columns.first { $0.name == "customer_id" }?.unread, "→ nowhere.id", "kept, as words")
        walk.press(.escape)
        let board = try require(w.window as? BoardWindow)
        board.undo(nil)
        board.undo(nil)
        expectEqual(keys(editor), ["orders.customer_id -> customers.email"], "each step comes back")
        board.undo(nil)
        expectEqual(keys(editor), ["orders.customer_id -> customers.id"])
        expectEqual(arrows(editor).map(\.id), [arrow])
    },
    test("T4, panel 1 (the rename): customers renamed accounts, the line prints the key's live names, and VoiceOver says them") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        try w.turnKitOn()
        try w.draw(shop + "\nedge \"orders\".customer_id -> \"customers\".id")
        let customers = try require(table(editor, "customers")).id
        editor.transact("Rename Table") { $0.update(customers) { $0[TitleProperty.self] = "accounts" } }
        try w.edit("orders", row: "id")
        expectEqual(w.lineRows?.line(of: .row(try require(column(editor, "orders", "customer_id")))), "customer_id uuid → accounts.id")
        let element = try require((w.lineRows?.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }.first {
            ($0.accessibilityValue() as? String)?.hasPrefix("customer_id") == true
        })
        expectEqual(element.accessibilityHelp(), "customer_id, uuid, key to id in accounts")
        walk(w).press(.down)
        expectEqual(w.line?.string, "customer_id uuid → accounts.id")
        walk(w).press(.down)
        expectEqual(undoTitle(w.window), "Undo Rename Table", "a line left as it was shown writes nothing")
    },
    test("⌘L in a row: the line written, the picker on the row; it lists tables and their columns, never an enum or a note; a pick draws the key in place of the one it had") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        try w.turnKitOn()
        try w.draw(shop + "\nsticky-note \"customer notes\" below \"orders\"\nedge \"orders\".customer_id -> \"customers\".id")
        let walk = w.walk()
        try w.edit("orders", row: "total_cents")
        w.type(" null", with: walk)
        walk.press(Chord("l", .command))
        let picker = try require(editor.connectPicker)
        expect(picker.isOpen, "the picker shows")
        expectEqual(picker.picker?.sourceEnd, ConnectEnd(try require(table(editor, "orders")).id, part: column(editor, "orders", "total_cents")))
        expectEqual(table(editor, "orders")?.props.columns.last?.nullable, true, "the line was written first")
        expectEqual(editor.editingShapeID, try require(table(editor, "orders")).id, "the table is still edited")
        w.type("cust", with: walk)
        let listed = (picker.picker?.list.rows ?? []).compactMap(\.item).map(\.title)
        expect(listed.contains("customers"), "\(listed)")
        expect(!listed.contains("customer_status") && !listed.contains("customer notes"), "no enum, no note: \(listed)")
        // A column by its table's name and its own, a dot between them.
        w.type(".em", with: walk)
        let rows = (picker.picker?.list.rows ?? []).compactMap(\.item)
        expectEqual(rows.first?.title, "email")
        expect(rows.first?.place?.steps.last?.name == "customers", "listed under its table")
        walk.press(.return)
        expect(!picker.isOpen)
        expectEqual(keys(editor), ["orders.customer_id -> customers.id", "orders.total_cents -> customers.email"])
        expectEqual(undoTitle(w.window), "Undo Connect")
        expect(w.window.firstResponder === w.line, "the keyboard back on the line: \(String(describing: w.window.firstResponder))")
        expectEqual(w.line?.string, "total_cents int null → customers.email", "printed again with its key")
        // Again on customer_id, a table picked: its primary key's row, the key it had gone.
        walk.press(.up)
        walk.press(Chord("l", .command))
        w.type("customers", with: walk)
        walk.press(.return)
        expectEqual(keys(editor), ["orders.customer_id -> customers.id", "orders.total_cents -> customers.email"])
        walk.press(.escape)
    },
    test("T5, panel 4: ⌘L on a table made by hand, customers picked: a customer_id typed as its primary key, after the table's keys, its key drawn, one step") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        try w.turnKitOn()
        try w.draw(shop + "\ntable \"addresses\" below \"orders\" columns: \"id uuid pk\\nstreet text\\ncity text\"")
        let addresses = try require(table(editor, "addresses")).id
        editor.selectedShapeIDs = [addresses]
        let walk = w.walk()
        walk.press(Chord("l", .command))
        let picker = try require(editor.connectPicker)
        expect(picker.isOpen)
        let listed = (picker.picker?.list.rows ?? []).compactMap(\.item).map(\.title)
        expect(!listed.contains("customer_status"), "tables only: \(listed)")
        w.type("customers", with: walk)
        walk.press(.return)
        expectEqual(table(editor, "addresses")?.props.columns.map(ColumnGrammar.print), ["id uuid pk", "customer_id uuid", "street text", "city text"])
        expectEqual(keys(editor), ["addresses.customer_id -> customers.id"])
        expectEqual(undoTitle(w.window), "Undo Add Key Column")
        let board = try require(w.window as? BoardWindow)
        board.undo(nil)
        expectEqual(table(editor, "addresses")?.props.columns.map(\.name), ["id", "street", "city"], "one Undo takes the column and its key")
        expectEqual(keys(editor), [])
    },
    test("T3, panel 3: ⌘L on order_items, → prod lists the products tables by where each is") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        try w.turnKitOn()
        try w.draw("""
            database "shop"
            database "archive" right of "shop"
            """)
        try w.draw("""
            table "products" in "shop" columns: "id uuid pk\\nsku text unique"
            table "products" in "archive" columns: "id uuid pk"
            table "order_items" below "shop" columns: "id uuid pk\\norder_id uuid"
            """)
        editor.selectedShapeIDs = [try require(table(editor, "order_items")).id]
        let walk = w.walk()
        walk.press(Chord("l", .command))
        w.type("prod", with: walk)
        let rows = (editor.connectPicker?.picker?.list.rows ?? []).compactMap(\.item)
        expectEqual(rows.map(\.title), ["products", "products", "Itself"], "Itself last, as on any shape")
        expectEqual(Set(rows.compactMap { $0.place?.steps.last?.name }), ["shop", "archive"])
        walk.press(.escape)
    },
    test("draw: a columns: line's → draws its key, an edge of the same rows written too is the one edge, a run again is unchanged, a line without → leaves it") {
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
        editor.viewportDidResize(to: CGSize(width: 1440, height: 900))
        let script = """
            table "customers" columns: "id uuid pk\\nemail text unique"
            table "orders" right of "customers" columns: "id uuid pk\\ncustomer_id uuid → customers.id\\nbuyer_id uuid -> customers.id"
            edge "orders".customer_id -> "customers".id
            """
        let first = try drawnInProcess(script, on: editor)
        expectEqual(keys(editor), ["orders.buyer_id -> customers.id", "orders.customer_id -> customers.id"])
        expectEqual(table(editor, "orders")?.props.columns.map(\.unread), ["", "", ""], "no column keeps its key's words")
        expect(arrows(editor).allSatisfy { $0[ChannelProperty.self] == ForeignKey.id })
        let rows = first["changes"]?.arrayValue ?? []
        expectEqual(rows.filter { $0["kind"]?.stringValue == "arrow" }.compactMap { $0["line"]?.intValue }.sorted(), [2, 3], "each on its own line")
        let again = try drawnInProcess(script, on: editor)
        expectEqual(Set(again["changes"]?.arrayValue?.compactMap { $0["did"]?.stringValue } ?? []), ["unchanged"])
        _ = try drawnInProcess(#"table "orders" columns: "customer_id uuid not null""#, on: editor)
        expectEqual(keys(editor).count, 2, "a line without → leaves the key alone")
        _ = try drawnInProcess(#"table "orders" columns: "seller_id uuid → customers""#, on: editor)
        expectEqual(keys(editor).count, 3)
        expect(keys(editor).contains("orders.seller_id -> customers.id"), "a table the file has, alone, is its primary key: \(keys(editor))")
        let unknown = try refusedInProcess(#"table "orders" columns: "x uuid → customers.nope""#, on: editor)
        expectEqual(unknown.reason, "unknown_row")
    },
    test("delete edge with row ends takes the key of those rows and leaves the pair's other; Undo brings it back; none there is nothing_to_delete") {
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
        editor.viewportDidResize(to: CGSize(width: 1440, height: 900))
        _ = try drawnInProcess("""
            table "customers" columns: "id uuid pk"
            table "orders" right of "customers" columns: "id uuid pk\\nbilling_customer_id uuid → customers.id\\nshipping_customer_id uuid → customers.id"
            """, on: editor)
        editor.undoHistory.seal()
        expectEqual(keys(editor).count, 2)
        let result = try drawnInProcess(#"delete edge "orders".shipping_customer_id -> "customers".id"#, on: editor)
        expectEqual(keys(editor), ["orders.billing_customer_id -> customers.id"])
        expectEqual(result["changes"]?.arrayValue?.compactMap { $0["did"]?.stringValue }, ["deleted"])
        editor.undo()
        expectEqual(keys(editor).count, 2)
        _ = try drawnInProcess(#"delete edge "orders".shipping_customer_id -> "customers""#, on: editor)
        expectEqual(keys(editor), ["orders.billing_customer_id -> customers.id"], "a whole end matches its row")
        let none = try refusedInProcess(#"delete edge "orders".shipping_customer_id -> "customers".id"#, on: editor)
        expectEqual(none.reason, "nothing_to_delete")
        _ = try drawnInProcess(#"delete edge "orders" -> "customers""#, on: editor)
        expectEqual(keys(editor), [], "a pair named whole takes every key between them")
    },
])

@MainActor private func walk(_ w: EmptyBoardWindow) -> KeyWalk {
    KeyWalk(w.window, editor: w.editor, readers: [.canvas(w.canvas, editor: w.editor, names: [:]), .panel(of: w.canvas)])
}

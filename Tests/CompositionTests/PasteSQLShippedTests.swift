import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Clipboard
import Connections
import Engineering
import Selection
import ShippedTesting
import TestKit
import Titles

// ⌘V of SQL as shipped, on a pasteboard of the test's own (ShippedPlugins'): T1 panel 4 by the keys in a new board's window,
// payments landing selected beside orders with its key to orders drawn and one Undo, "Undo Paste SQL"; the same paste again
// updating payments in place (its columns' ids and its key's arrow kept, a new column after the one pasted before it, a column
// the paste doesn't say kept); a key re-aimed where the paste names another target and kept where it names none; an enum and the
// column it types; and the kit off, where ⌘V does nothing.

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
        expect((editor.document[tickets.id]?.box?.minX ?? 0) > (state.box?.maxX ?? 0), "in paste order, left to right")
        pasteboardHolds("CREATE TYPE ticket_state AS ENUM ('open', 'waiting', 'closed');")
        expect(commandV(w))
        expectEqual(editor.document[state.id]?.typed(as: DatabaseEnum.self)?.props.values.map(\.text), ["open", "waiting", "closed"])
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
])

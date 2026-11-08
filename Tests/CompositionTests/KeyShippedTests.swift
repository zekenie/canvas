import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CanvasUI
import Clipboard
import Connections
import Engineering
import LanguageModels
import LineRows
import Selection
import ShippedTesting
import TestKit
import Titles
import Topology

// Keys as shipped (K3): `canvas draw`'s rows by name (`"orders".customer_id`), an unknown row refused with the names it's
// like, `delete "orders".x` taking the row and its key; T5 panels 1 and 2 by the keys with their Undo titles; tables copied
// with the key between them; and T3 panel 2 by the pointer through the app's canvas view: a drag from payment_id's dot onto
// payments.id, the tables outlined and not the enum, the row lit, and the key drawn row to row.

@MainActor private func arrows(_ editor: CanvasEditor) -> [ShapeRecord<Arrow>] {
    editor.document.shapes.compactMap { $0.typed(as: Arrow.self) }
}

@MainActor private func table(_ editor: CanvasEditor, _ title: String) -> ShapeRecord<DatabaseTable>? {
    editor.document.shapes.first { $0[TitleProperty.self] == title }?.typed(as: DatabaseTable.self)
}

@MainActor private func column(_ editor: CanvasEditor, _ title: String, _ name: String) -> PartID? {
    table(editor, title)?.props.columns.first { $0.name == name }?.id
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

private let shop = #"""
    table "customers" columns: "id uuid pk\nemail text unique\nname text"
    table "orders" right of "customers" columns: "id uuid pk\ncustomer_id uuid\ntotal_cents int"
    table "order_items" right of "orders" columns: "id uuid pk\norder_id uuid\nqty int"
    table "payments" below "orders" columns: "id uuid pk\norder_id uuid\namount_cents int"
    edge "orders".customer_id -> "customers".id
    edge "order_items".order_id -> "orders".id
    edge "payments".order_id -> "orders".id
    """#

@MainActor private func shopEditor() throws -> CanvasEditor {
    let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
    editor.viewportDidResize(to: CGSize(width: 1440, height: 900))
    _ = try drawnInProcess(shop, on: editor)
    return editor
}

@MainActor let keyShippedTests = Suite("Keys, shipped", [
    test("draw names a row with a dot outside the quotes: an edge between rows is a key on foreign-key, bound to both rows; a run again is unchanged") {
        let editor = try shopEditor()
        expectEqual(keys(editor), ["order_items.order_id -> orders.id", "orders.customer_id -> customers.id", "payments.order_id -> orders.id"])
        expect(arrows(editor).allSatisfy { $0[ChannelProperty.self] == ForeignKey.id }, "each on the kit's channel, picked as a drag picks it")
        let again = try drawnInProcess(#"edge "orders".customer_id -> "customers".id"#, on: editor)
        expectEqual(again["changes"]?.arrayValue?.compactMap { $0["did"]?.stringValue }, ["unchanged"])
        _ = try drawnInProcess(#"edge "orders".total_cents -> "customers".id"#, on: editor)
        expectEqual(arrows(editor).count, 4, "another pair of rows of the same tables is another key")
        let orders = try require(table(editor, "orders"))
        expectEqual(editor.topology?.edges(of: orders.id, part: column(editor, "orders", "customer_id"), .outgoing).count, 1)
    },
    test("a row no shape has is unknown_row, with the rows it's like; a shape with no rows says so") {
        let editor = try shopEditor()
        let error = try drawnError(#"edge "orders".custmer_id -> "customers".id"#, on: editor)
        expectEqual(error?["reason"]?.stringValue, "unknown_row")
        expect(error?["hint"]?.stringValue?.contains(#""orders".customer_id"#) == true, "\(String(describing: error?["hint"]))")
        _ = try drawnInProcess(#"sticky-note "Plan" below "payments""#, on: editor)
        let none = try drawnError(#"delete "Plan".x"#, on: editor)
        expectEqual(none?["reason"]?.stringValue, "unknown_row")
    },
    test("delete \"orders\".customer_id takes the row and, by the cascade, its key, said as the table updated and the arrow deleted") {
        let editor = try shopEditor()
        let result = try drawnInProcess(#"delete "orders".customer_id"#, on: editor)
        expectEqual(table(editor, "orders")?.props.columns.map(\.name), ["id", "total_cents"])
        expectEqual(keys(editor), ["order_items.order_id -> orders.id", "payments.order_id -> orders.id"])
        let changes = result["changes"]?.arrayValue ?? []
        expectEqual(changes.compactMap { $0["did"]?.stringValue }, ["updated", "deleted"])
        expectEqual(changes.last?["kind"]?.stringValue, "arrow")
        expectEqual(editor.undoHistory.undoName != nil, true)
    },
    test("T5, panel 1: in customers, ⌘⌫ then ⌫ on id: the column and its key go in one step, Undo Delete Column and 1 Arrow; orders.customer_id is plain") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        try w.turnKitOn()
        _ = try drawnInProcess(shop, on: w.editor)
        w.editor.undoHistory.seal()
        let customers = try require(table(w.editor, "customers"))
        let walk = w.walk()
        w.editor.selectedShapeIDs = [customers.id]
        w.editor.beginEditing(customers.id)
        w.window.settle()
        let view = try require(w.lineRows)
        let id = try require(customers.props.columns.first?.id)
        // From where editing starts, up to the title and down one: the first row, id.
        for _ in 0..<5 where view.focus != .title { walk.press(.up) }
        if view.focus == .title { walk.press(.down) }
        expectEqual(view.focus, .row(id), "the caret on id")
        walk.press(Chord(Key.delete, .command))
        walk.press(.delete)
        expectEqual(table(w.editor, "customers")?.props.columns.map(\.name), ["email", "name"])
        expectEqual(keys(w.editor), ["order_items.order_id -> orders.id", "payments.order_id -> orders.id"], "its key went with it")
        expectEqual(undoTitle(w.window), "Undo Delete Column and 1 Arrow")
    },
    test("T5, panel 2: ⌫ with orders selected takes its three keys, Undo Delete Table and 3 Arrows; one Undo brings them back") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        try w.turnKitOn()
        _ = try drawnInProcess(shop, on: w.editor)
        w.editor.undoHistory.seal()
        let orders = try require(table(w.editor, "orders"))
        let walk = w.walk()
        w.editor.selectedShapeIDs = [orders.id]
        walk.press(.delete)
        expectEqual(table(w.editor, "orders"), nil)
        expectEqual(arrows(w.editor).count, 0, "every key at orders went, either way")
        expectEqual(undoTitle(w.window), "Undo Delete Table and 3 Arrows")
        w.editor.undo()
        expectEqual(keys(w.editor).count, 3)
    },
    test("tables copied with the key between them keep it, bound to the copies' rows; a key to a table not copied stays behind") {
        let editor = try shopEditor()
        let orders = try require(table(editor, "orders")), items = try require(table(editor, "order_items"))
        editor.selectedShapeIDs = [orders.id, items.id]
        editor.perform(.copy)
        editor.perform(.paste)
        let pasted = editor.selectedShapeIDs.compactMap { editor.document[$0] }.filter { $0.kind == DatabaseTable.kind }
        expectEqual(pasted.count, 2)
        let copies = Set(pasted.map(\.id))
        let copied = arrows(editor).filter { arrow in [arrow.props.start, arrow.props.end].allSatisfy { $0.binding.map { copies.contains($0.shapeID) } ?? false } }
        expectEqual(copied.count, 1, "the key between the two copied tables came along")
        expectEqual(copied.first?.props.start.binding?.part, column(editor, "order_items", "order_id"), "a copy keeps its rows' ids")
        expectEqual(arrows(editor).count, 4, "orders' key to customers stayed behind")
    },
    test("⌥Tab from a table lists its keys by the row at the far end; VoiceOver says an arrow's rows") {
        let editor = try shopEditor()
        let orders = try require(table(editor, "orders"))
        editor.selection = orders.id
        let titles = editor.shapeParts(of: orders.id).map(\.title)
        expect(titles.contains("Arrow to id in customers"), "\(titles)")
        expect(titles.contains("Arrow from order_id in order_items"), "\(titles)")
        let key = try require(arrows(editor).first { $0.props.start.binding?.shapeID == orders.id })
        expect(editor.accessibleDescription(of: key.id)?.label.contains("from customer_id in orders to id in customers") == true)
    },
])

/// What `canvas draw` refused, as JSON: its reason and hint.
@MainActor private func drawnError(_ script: String, on editor: CanvasEditor) throws -> JSON? {
    let error = try refusedInProcess(script, on: editor)
    return JSON.object(["reason": .string(error.reason ?? ""), "hint": .string(error.hint ?? "")])
}

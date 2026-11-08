import AppKit
import Adornments
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Clipboard
import Connections
import Engineering
import Geometry
import LineRows
import References
import Selection
import ShippedTesting
import TestKit
import Titles

// Rows as items, shipped (K8): T5 panels 3 and 4 by the keys alone, with real presses through the app's window, each step's
// Undo as Edit ▸ Undo says it: ⇧↓ from street to country while customers is edited, ⌘X, ⌘V with nothing selected (a new table
// of them, its name typed: addresses), then ⌘L customers ↩ (Add Key Column). And rows selected on the canvas: a table's row
// clicked once it's selected, its keys and steps; a cut carrying a column's key and its paste a move, the key back.

@MainActor private func table(_ editor: CanvasEditor, _ title: String) -> ShapeRecord<DatabaseTable>? {
    editor.document.shapes.first { $0[TitleProperty.self] == title }?.typed(as: DatabaseTable.self)
}

@MainActor private func keys(_ editor: CanvasEditor) -> [String] {
    editor.document.shapes.compactMap { $0.typed(as: Arrow.self) }.compactMap { arrow -> String? in
        guard let start = arrow.props.start.binding, let end = arrow.props.end.binding else { return nil }
        @MainActor func said(_ binding: ArrowBinding) -> String {
            let record = editor.document[binding.shapeID]
            let name = record.flatMap { editor.registry.parts(of: $0)?.first { $0.id == binding.part }?.name } ?? "?"
            return "\(record?[TitleProperty.self] ?? "?").\(name)"
        }
        return "\(said(start)) -> \(said(end))"
    }.sorted()
}

private let customers = #"""
    table "customers" columns: "id uuid pk\nemail text unique\nname text\nstreet text\ncity text\npostcode text\ncountry char(2)\ncreated_at timestamptz"
    table "orders" right of "customers" columns: "id uuid pk\ncustomer_id uuid → customers.id\ntotal_cents int"
    """#

@MainActor let rowItemsShippedTests = Suite("Rows as items, shipped", [
    test("T5, panels 3 and 4, by the keys: ⇧↓ from street to country, ⌘X, ⌘V with nothing selected a table of them named addresses, ⌘L customers ↩ its key column") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        try w.turnKitOn()
        try w.draw(customers)
        editor.undoHistory.seal()
        let table0 = try require(table(editor, "customers"))
        let walk = w.walk()
        editor.selectedShapeIDs = [table0.id]
        walk.press(.return)
        expectEqual(w.lineRows?.focus, .waiting, "edited at its empty row")
        for _ in 0..<5 { walk.press(.up) }
        let street = try require(table0.props.columns.first { $0.name == "street" }?.id)
        expectEqual(w.lineRows?.focus, .row(street), "the caret on street")
        for _ in 0..<4 { walk.press(Chord(Key.down, .shift)) }
        expectEqual(w.lineRows?.selectedRows.compactMap { id in table0.props.columns.first { $0.id == id }?.name }, ["street", "city", "postcode", "country"],
                    "panel 3: street to country selected whole")
        walk.press(Chord("x", .command))
        expectEqual(table(editor, "customers")?.props.columns.map(\.name), ["id", "email", "name", "created_at"])
        expectEqual(undoTitle(w.window), "Undo Cut Columns")
        walk.press(.escape)
        walk.press(.escape)
        expectEqual(editor.selectedShapeIDs, [], "nothing selected")
        walk.press(Chord("v", .command))
        let made = try require(editor.editingShapeID, "the new table's name is typed at once")
        expectEqual(editor.document[made]?.typed(as: DatabaseTable.self)?.props.columns.map(ColumnGrammar.print),
                    ["id uuid pk", "street text", "city text", "postcode text", "country char(2)"], "its own key first, then the columns")
        expectEqual(w.lineRows?.focus, .title)
        // The new table's name field is as wide as its placeholder's pill, not the icon alone (the ring goes round the pill).
        let field = try require(w.canvas.descendants(TitleField.self).first, "the name's field")
        let scale = field.bounds.height / AdornmentLayout.rowHeight
        expect(field.chipWidth > 50, "the empty field's chip has its placeholder's room: \(field.chipWidth)")
        expect(field.chipWidth * scale <= field.bounds.width + 0.5, "the field's bounds hold its chip: \(field.chipWidth * scale) of \(field.bounds.width)")
        w.type("addresses", with: walk)
        walk.press(.escape)
        expectEqual(editor.editingShapeID, nil)
        expectEqual(editor.selectedShapeIDs, [made])
        expectEqual(undoTitle(w.window), "Undo Move Columns to New Table", "a cut's paste is a move, its name the same step")
        expectEqual(editor.document[made]?[TitleProperty.self], "addresses")
        // Panel 4: ⌘L customers ↩ adds the key column.
        walk.press(Chord("l", .command))
        w.type("customers", with: walk)
        walk.press(.return)
        expectEqual(table(editor, "addresses")?.props.columns.map(\.name), ["id", "customer_id", "street", "city", "postcode", "country"])
        expectEqual(keys(editor), ["addresses.customer_id -> customers.id", "orders.customer_id -> customers.id"])
        expectEqual(undoTitle(w.window), "Undo Add Key Column")
        let board = try require(w.window as? BoardWindow)
        board.undo(nil)
        board.undo(nil)
        expectEqual(table(editor, "addresses"), nil, "one Undo for the table and its name")
        expectEqual(table(editor, "customers")?.props.columns.map(\.name), ["id", "email", "name", "created_at"])
        board.undo(nil)
        expectEqual(table(editor, "customers")?.props.columns.map(\.name), table0.props.columns.map(\.name), "and one for the cut")
    },
    test("a table's row clicked once it's selected is an item, outlined; ↓ ⇧↓ ⌥↑ and ⌫ go to rows, Delete counting the key that went; Undo brings it back selected") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        try w.turnKitOn()
        try w.draw(customers)
        editor.undoHistory.seal()
        let orders = try require(table(editor, "orders"))
        let row = try require(editor.shapeContext.geometry(of: orders.id)?.parts.frame(orders.props.columns[1].id)?.rect)
        let walk = w.walk()
        w.click(at: CGPoint(x: row.midX, y: row.midY))
        expectEqual(editor.selectedShapeIDs, [orders.id])
        expectEqual(editor.selectedItems, nil, "the table first")
        w.click(at: CGPoint(x: row.midX, y: row.midY))
        expectEqual(editor.selectedItems?.ids, [AnyHashable(orders.props.columns[1].id)], "then its row")
        walk.press(.down)
        expectEqual(editor.selectedItems?.ids, [AnyHashable(orders.props.columns[2].id)])
        walk.press(Chord(Key.up, .shift))
        expectEqual(editor.selectedItems?.ids.count, 2)
        walk.press(Chord(Key.up, .option))
        expectEqual(table(editor, "orders")?.props.columns.map(\.name), ["customer_id", "total_cents", "id"])
        expectEqual(undoTitle(w.window), "Undo Move Columns")
        board(w).undo(nil)
        editor.selectItems([AnyHashable(orders.props.columns[1].id)], of: orders.id)
        walk.press(.delete)
        expectEqual(table(editor, "orders")?.props.columns.map(\.name), ["id", "total_cents"])
        expectEqual(undoTitle(w.window), "Undo Delete Column and 1 Arrow")
        board(w).undo(nil)
        expectEqual(editor.selectedItems?.ids, [AnyHashable(orders.props.columns[1].id)], "back, selected")
        expectEqual(keys(editor), ["orders.customer_id -> customers.id"])
        walk.press(.escape)
        expectEqual(editor.selectedItems, nil)
        expectEqual(editor.selectedShapeIDs, [orders.id], "one Escape: the table")
    },
    test("⌘C of a column carries the key it starts; ⌘X of it carries the key and counts it; ⌘V into another table's selected row is a move, the key back under its id") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        try w.turnKitOn()
        try w.draw(customers + "\ntable \"carts\" below \"orders\" columns: \"id uuid pk\"")
        editor.undoHistory.seal()
        let orders = try require(table(editor, "orders")), carts = try require(table(editor, "carts"))
        let key = try require(editor.document.shapes.first { $0.kind == Arrow.kind }?.id)
        let walk = w.walk()
        editor.selectItems([AnyHashable(orders.props.columns[1].id)], of: orders.id)
        walk.press(Chord("c", .command))
        expectEqual(editor.pasteboardRows?.bound.map(\.id), [key], "a copy carries the key the column starts")
        walk.press(Chord("x", .command))
        expectEqual(undoTitle(w.window), "Undo Cut Column and 1 Arrow")
        expectEqual(keys(editor), [])
        editor.selectItems([AnyHashable(carts.props.columns[0].id)], of: carts.id)
        walk.press(Chord("v", .command))
        expectEqual(table(editor, "carts")?.props.columns.map(\.name), ["id", "customer_id"])
        expectEqual(keys(editor), ["carts.customer_id -> customers.id"])
        expect(editor.document[key] != nil, "the key under its own id: a move")
        expectEqual(undoTitle(w.window), "Undo Paste Column")
    },
    test("a cut takes the keys that reach its column through a pill on another board and counts them; its paste is a move that puts them back under their ids; a second paste copies the column only") {
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
        @MainActor func keyArrows() -> [ShapeRecord<Arrow>] {
            editor.contents(of: billing).shapes.compactMap { $0.typed(as: Arrow.self) }.filter { $0[ChannelProperty.self] == ForeignKey.id }
        }
        ShippedPlugins.pasteboard.clearContents()
        ShippedPlugins.pasteboard.setString("CREATE TABLE statements (id uuid PRIMARY KEY, customer_id uuid NOT NULL REFERENCES customers (id));", forType: .string)
        expect(w.window.performKeyEquivalent(with: w.window.keyEvent("v", code: 9, modifiers: [.command])))
        let key = try require(keyArrows().first)
        let pill = try require(key.props.end.binding?.shapeID)
        let id = try require(customers.props.columns.first { $0.name == "id" }?.id)
        expectEqual(key.props.end.binding?.part, id, "the key ends at customers' pill, on its id")
        // Back on customers' board: its id column cut.
        expect(editor.showBoard(.root))
        w.window.makeFirstResponder(w.canvas)
        editor.undoHistory.seal()
        let walk = w.walk()
        editor.selectedShapeIDs = [customers.id]
        editor.selectItems([AnyHashable(id)], of: customers.id)
        walk.press(Chord("x", .command))
        expectEqual(table(editor, "customers")?.props.columns.map(\.name), ["email"])
        expectEqual(undoTitle(w.window), "Undo Cut Column and 1 Arrow", "the key on the other board is counted")
        expectEqual(keyArrows().count, 0, "it went with the column")
        // Pasted after the one left: the column the same column, the key where it was.
        editor.selectedShapeIDs = [customers.id]
        editor.selectItems([AnyHashable(try require(table(editor, "customers")?.props.columns.first?.id))], of: customers.id)
        walk.press(Chord("v", .command))
        expectEqual(table(editor, "customers")?.props.columns.map(\.name), ["email", "id"])
        expectEqual(table(editor, "customers")?.props.columns.last?.id, id, "the same column")
        let back = try require(keyArrows().first)
        expectEqual(keyArrows().count, 1)
        expectEqual(back.id, key.id, "under its own id")
        expectEqual(back.props.end.binding?.shapeID, pill)
        expectEqual(back.props.end.binding?.part, id, "on its column again, through the pill")
        walk.press(Chord("v", .command))
        expectEqual(table(editor, "customers")?.props.columns.map(\.name), ["email", "id", "id"], "a second paste is a copy")
        expectEqual(keyArrows().count, 1, "and carries no key from the cut")
    },
])

@MainActor private func board(_ w: EmptyBoardWindow) -> BoardWindow { w.window as! BoardWindow }

/// The time of the last click, so each is a click of its own.
@MainActor private var clickTime: TimeInterval = 100

extension EmptyBoardWindow {
    /// A click at a world point, as the canvas hands one to the editor, a second after the last.
    func click(at point: CGPoint) {
        clickTime += 1
        let location = editor.camera.toView(point)
        editor.pointerDown(PointerEvent(location: location, timestamp: clickTime, clickCount: 1))
        editor.pointerUp(PointerEvent(location: location, timestamp: clickTime + 0.05, clickCount: 1))
        window.settle()
    }
}

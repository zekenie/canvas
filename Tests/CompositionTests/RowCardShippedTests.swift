import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
@_spi(Host) import CanvasUI
import Engineering
import LineRows
import ShippedTesting
import TestKit
import TextEditing
import Titles

// A column's card (K7), as shipped, on a board's window with real presses: T4 panel 1 (customers renamed accounts, ⌘↓ on
// orders.customer_id: type uuid, references accounts.id, null no, on delete restrict), each line one step; the key re-aimed,
// taken out and made again from the card's references, the arrow kept where it's re-aimed; Escape back to the row's caret.

@MainActor private func table(_ editor: CanvasEditor, _ title: String) -> ShapeRecord<DatabaseTable>? {
    editor.document.shapes.first { $0[TitleProperty.self] == title }?.typed(as: DatabaseTable.self)
}

@MainActor private func arrows(_ editor: CanvasEditor) -> [ShapeRecord<Arrow>] {
    editor.document.shapes.compactMap { $0.typed(as: Arrow.self) }
}

/// Each key as `from.column -> to.column`, by the tables' titles and the columns' names now.
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
    table "customers" columns: "id uuid pk\nemail text unique\nname text\ncreated_at timestamptz"
    table "orders" right of "customers" (gap: 200) columns: "id uuid pk\ncustomer_id uuid\ntotal_cents int"
    edge "orders".customer_id -> "customers".id
    """#

extension EmptyBoardWindow {
    /// The row's card showing, its menus handed to `menus` rather than put on screen.
    func rowCard(menus: @escaping @MainActor (NSMenu) -> Void) -> LineCardView? {
        let card = canvas.cardView as? LineCardView
        card?.menuPresenter = menus
        return card
    }
}

@MainActor let rowCardShippedTests = Suite("A column's card, shipped", [
    test("T4, panel 1: customers renamed accounts, ⌘↓ on orders.customer_id: type uuid, references accounts.id, null no; on delete restrict and null each one step") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        try w.turnKitOn()
        try w.draw(shop)
        let customers = try require(table(editor, "customers")).id
        editor.transact("Rename Table") { $0.update(customers) { $0[TitleProperty.self] = "accounts" } }
        let walk = w.walk()
        try w.edit("orders", row: "customer_id")
        walk.press(Chord(Key.down, .command))
        var menus: [NSMenu] = []
        let card = try require(w.rowCard { menus.append($0) }, "⌘↓ shows the row's card")
        expectEqual(card.header.name, "customer_id")
        expectEqual(card.header.mark?.symbol, "link", "a key's mark")
        expectEqual(card.value(of: "type"), "uuid")
        expectEqual(card.value(of: "references"), "accounts.id", "the key's far row, by its names now")
        expectEqual(card.value(of: "null"), "no")
        expectEqual(card.value(of: "on delete"), "no action")
        expect(w.canvas.cardFrame != nil)
        card.go(to: "on delete")
        walk.press(.space)
        try require(menus.last).choose("restrict")
        w.window.settle()
        expectEqual(table(editor, "orders")?.props.columns[1].onDelete, "restrict")
        expectEqual(undoTitle(w.window), "Undo Change Key Action")
        expectEqual(card.value(of: "on delete"), "restrict")
        card.go(to: "null")
        walk.press(.space)
        expectEqual(table(editor, "orders")?.props.columns[1].nullable, true)
        expectEqual(undoTitle(w.window), "Undo Change Column")
        expectEqual(keys(editor), ["orders.customer_id -> accounts.id"], "the key stays")
        expectEqual(w.line?.string, "customer_id uuid null → accounts.id", "the row's line printed again")
        walk.press(.escape)
        expect(editor.card == nil)
        expect(w.window.firstResponder === w.line, "Escape: the row's line has the keyboard back")
        expectEqual(editor.editingShapeID, table(editor, "orders")?.id)
        walk.press(.escape)
    },
    test("the references changed from the card: re-aimed (Change Key, the same arrow), emptied (Delete Key), a table named (Add Key, its primary key)") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        try w.turnKitOn()
        try w.draw(shop)
        let arrow = try require(arrows(editor).first).id
        let walk = w.walk()
        try w.edit("orders", row: "customer_id")
        walk.press(Chord(Key.down, .command))
        let card = try require(w.rowCard { _ in })
        card.go(to: "references")
        let field = try require(card.field(of: "references"))
        field.selectAll(nil)
        w.type("customers.email", with: walk)
        walk.press(.down)
        expectEqual(keys(editor), ["orders.customer_id -> customers.email"])
        expectEqual(arrows(editor).map(\.id), [arrow], "the same arrow, re-aimed")
        expectEqual(undoTitle(w.window), "Undo Change Key")
        expectEqual(w.line?.string, "customer_id uuid → customers.email")
        card.go(to: "references")
        try require(card.field(of: "references")).selectAll(nil)
        walk.press(.delete)
        // Emptied, the line lists what it could reference: Escape closes the list, Tab leaves the line.
        if card.field(of: "references")?.offerList != nil { walk.press(.escape) }
        walk.press(.tab)
        expectEqual(keys(editor), [])
        expectEqual(undoTitle(w.window), "Undo Delete Key")
        expectEqual(card.value(of: "references"), "")
        expectEqual(card.header.mark == nil, true, "no key: no link in the header")
        card.go(to: "references")
        w.type("customers", with: walk)
        if card.field(of: "references")?.offerList != nil { walk.press(.escape) }
        walk.press(.return)
        expectEqual(keys(editor), ["orders.customer_id -> customers.id"], "a table alone: its primary key's row")
        expectEqual(undoTitle(w.window), "Undo Add Key")
        expectEqual(card.header.mark?.symbol, "link", "the key made from the card, its mark")
        expect(editor.card == nil, "Return is done with a field: the row has the keyboard back")
        expectEqual(w.line?.string, "customer_id uuid → customers.id")
        walk.press(.escape)
    },
    test("references typed with an arrow or more words: the target is the first word after the arrow, the others stay the line's, once; words naming no row stay words") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        try w.turnKitOn()
        try w.draw(shop)
        let walk = w.walk()
        try w.edit("orders", row: "customer_id")
        walk.press(Chord(Key.down, .command))
        let card = try require(w.rowCard { _ in })
        card.go(to: "references")
        try require(card.field(of: "references")).selectAll(nil)
        w.type("-> customers.email", with: walk)
        if card.field(of: "references")?.offerList != nil { walk.press(.escape) }
        walk.press(.down)
        expectEqual(keys(editor), ["orders.customer_id -> customers.email"], "the arrow typed is not a second one")
        expectEqual(table(editor, "orders")?.props.columns[1].unread, "")
        card.go(to: "references")
        try require(card.field(of: "references")).selectAll(nil)
        w.type("customers.id extra", with: walk)
        if card.field(of: "references")?.offerList != nil { walk.press(.escape) }
        walk.press(.down)
        expectEqual(keys(editor), ["orders.customer_id -> customers.id"], "the first word is the target")
        expectEqual(table(editor, "orders")?.props.columns[1].unread, "extra", "the rest is the line's own")
        expectEqual(w.line?.string, "customer_id uuid extra → customers.id")
        // Words that name no row: kept as the line's words, no key; the line, read again, makes none.
        card.go(to: "references")
        try require(card.field(of: "references")).selectAll(nil)
        w.type("nowhere", with: walk)
        if card.field(of: "references")?.offerList != nil { walk.press(.escape) }
        walk.press(.down)
        expectEqual(keys(editor), [])
        expectEqual(table(editor, "orders")?.props.columns[1].unread, "extra → nowhere")
        card.go(to: "type")
        walk.press(.escape)
        walk.press(.escape)
        expectEqual(keys(editor), [], "and the next change to the row's line draws none")
    },
])

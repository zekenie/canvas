import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Engineering
import Geometry
import LineRows
import Selection
import ShippedTesting
import TestKit
import Titles

// Rows dragged (K9), as shipped, through the app's canvas view with real mouse events, each step's Undo as Edit ▸ Undo says it:
// T4 panel 3 (status clicked in orders, then dragged by its row between qty and price_cents in order_items), T5 panel 3 (⇧↓ from
// street to country while customers is edited, the band dragged onto the board: a table of them, its name typed). And an API's
// rows, which rows as items met in the merge: ⌥↑ ⌥↓ by real presses keeping full paths across a header, ⌘X then ⌘V on the board
// a new API of them, and an endpoint dragged by its method chip into another API, under its header.

@MainActor private func table(_ editor: CanvasEditor, _ title: String) -> ShapeRecord<DatabaseTable>? {
    editor.document.shapes.first { $0[TitleProperty.self] == title }?.typed(as: DatabaseTable.self)
}

@MainActor private func api(_ editor: CanvasEditor, _ title: String) -> ShapeRecord<API>? {
    editor.document.shapes.first { $0[TitleProperty.self] == title }?.typed(as: API.self)
}

@MainActor private func fullNames(_ api: ShapeRecord<API>?) -> [String] {
    let rows = api?.props.endpoints ?? []
    return rows.indices.filter { rows[$0].endpoint != nil }.map { APIGroups.fullName(of: $0, in: rows) }
}

/// The time of the last mouse event, each a second after the last press so no two are a double-click.
@MainActor private var mouseTime: TimeInterval = 2000

extension EmptyBoardWindow {
    /// Row `index`'s rect on shape `id`, world units.
    func rowRect(_ index: Int, of id: ShapeID) throws -> CGRect {
        let record = try require(editor.document[id])
        let part = try require(editor.registry.parts(of: record)?[index].id)
        return try require(editor.shapeContext.geometry(of: id)?.parts.frame(part)?.rect)
    }

    /// A mouse event at a world point, as AppKit hands the canvas one.
    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        let location = canvas.convert(editor.camera.toView(point), to: nil)
        return NSEvent.mouseEvent(with: type, location: location, modifierFlags: modifiers, timestamp: mouseTime, windowNumber: window.windowNumber,
                                  context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    /// A click at a world point, the canvas's mouse down and up.
    func mouseClick(at point: CGPoint, modifiers: NSEvent.ModifierFlags = []) {
        mouseTime += 1
        canvas.mouseDown(with: mouse(.leftMouseDown, at: point, modifiers: modifiers))
        mouseTime += 0.05
        canvas.mouseUp(with: mouse(.leftMouseUp, at: point, modifiers: modifiers))
        window.settle()
    }

    /// A press at `from`, dragged in steps to `to` (world points); let go there unless `releasing` is false.
    func mouseDrag(from: CGPoint, to: CGPoint, releasing: Bool = true) {
        mouseTime += 1
        canvas.mouseDown(with: mouse(.leftMouseDown, at: from))
        for step in 1...6 {
            mouseTime += 0.016
            let t = CGFloat(step) / 6
            canvas.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)))
        }
        guard releasing else { return }
        mouseTime += 0.016
        canvas.mouseUp(with: mouse(.leftMouseUp, at: to))
        window.settle()
    }

    /// The mouse let go at a world point.
    func mouseUp(at point: CGPoint) {
        mouseTime += 0.016
        canvas.mouseUp(with: mouse(.leftMouseUp, at: point))
        window.settle()
    }
}

private let shop = #"""
    table "orders" columns: "id uuid pk\ncustomer_id uuid\nstatus text\ntotal_cents int\nplaced_at timestamptz null"
    table "order_items" right of "orders" (gap: 120) columns: "id uuid pk\norder_id uuid\nproduct_id uuid\nqty int\nprice_cents int"
    """#

private let shopAPI = #"""
    api "shop" endpoints: "GET /health\n/orders\nGET /orders/{id}\nPOST /orders/{id}/refunds\n/customers\nGET /customers/{id}/orders"
    api "billing" below "shop" (gap: 80) endpoints: "/orders\nGET /orders\n/payments\nGET /payments/{id}"
    """#

@MainActor let rowDragShippedTests = Suite("Rows dragged, shipped", [
    test("T4 panel 3 with the mouse: orders clicked, status clicked, then dragged by its row between qty and price_cents in order_items; Undo Move Column puts it back") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        try w.turnKitOn()
        try w.draw(shop)
        let editor = w.editor
        let orders = try require(table(editor, "orders")), items = try require(table(editor, "order_items"))
        let status = try w.rowRect(2, of: orders.id)
        w.mouseClick(at: CGPoint(x: status.midX, y: status.midY))
        w.mouseClick(at: CGPoint(x: status.midX, y: status.midY))
        expectEqual(editor.selectedItems?.ids, [AnyHashable(orders.props.columns[2].id)], "status selected as an item")
        let price = try w.rowRect(4, of: items.id)
        w.mouseDrag(from: CGPoint(x: status.midX, y: status.midY), to: CGPoint(x: price.midX, y: price.minY + 3), releasing: false)
        expectEqual(editor.hintedShapeID, items.id, "order_items outlined while it's over it")
        w.mouseUp(at: CGPoint(x: price.midX, y: price.minY + 3))
        expectEqual(table(editor, "order_items")?.props.columns.map(\.name), ["id", "order_id", "product_id", "qty", "status", "price_cents"])
        expectEqual(table(editor, "orders")?.props.columns.map(\.name), ["id", "customer_id", "total_cents", "placed_at"])
        expectEqual(undoTitle(w.window), "Undo Move Column")
        expectEqual(editor.hintedShapeID, nil)
        (w.window as! BoardWindow).undo(nil)
        expectEqual(table(editor, "orders")?.props.columns.map(\.name), orders.props.columns.map(\.name))
        expectEqual(table(editor, "order_items")?.props.columns.map(\.name), items.props.columns.map(\.name))
    },
    test("T5 panel 3: ⇧↓ from street to country while customers is edited, the band dragged with the mouse onto the board: a table of them, its name typed; Undo Move Columns to New Table") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        try w.turnKitOn()
        try w.draw(#"table "customers" columns: "id uuid pk\nemail text unique\nname text\nstreet text\ncity text\npostcode text\ncountry char(2)\ncreated_at timestamptz""#)
        let editor = w.editor
        let customers = try require(table(editor, "customers"))
        let walk = w.walk()
        editor.selectedShapeIDs = [customers.id]
        walk.press(.return)
        for _ in 0..<5 { walk.press(.up) }
        for _ in 0..<4 { walk.press(Chord(Key.down, .shift)) }
        expectEqual(w.lineRows?.selectedRows.count, 4, "street to country selected whole")
        let city = try w.rowRect(4, of: customers.id)
        let frame = try require(editor.shapeContext.frame(of: editor.document[customers.id]!))
        let drop = CGPoint(x: frame.maxX + 260, y: frame.maxY + 160)
        w.mouseDrag(from: CGPoint(x: city.midX, y: city.midY), to: drop)
        let made = try require(editor.editingShapeID, "the new table's name typed at once")
        expect(made != customers.id)
        expectEqual(editor.document[made]?.typed(as: DatabaseTable.self)?.props.columns.map(ColumnGrammar.print),
                    ["id uuid pk", "street text", "city text", "postcode text", "country char(2)"])
        expectEqual(table(editor, "customers")?.props.columns.map(\.name), ["id", "email", "name", "created_at"])
        expectEqual(editor.shapeContext.frame(of: editor.document[customers.id]!)?.height, KitStyle.height(rows: 4),
                    "customers as tall as its rows: the ended session lays no waiting line out as its band's rows go")
        expect(try require(editor.shapeContext.frame(of: editor.document[made]!)).contains(drop), "where it was dropped")
        w.type("addresses", with: walk)
        walk.press(.escape)
        expectEqual(undoTitle(w.window), "Undo Move Columns to New Table", "the move and the name one step")
        (w.window as! BoardWindow).undo(nil)
        expectEqual(editor.document[made], nil)
        expectEqual(table(editor, "customers")?.props.columns.count, 8)
    },
    test("an API's endpoints by real presses: ⌥↑ above the first header keeps the full path and ⌥↓ brings it back exactly; a header's ⌥↓ moves its group; ⌘X then ⌘V on the board a new API, full paths kept, its name typed") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        try w.turnKitOn()
        try w.draw(shopAPI)
        let editor = w.editor
        let shop = try require(api(editor, "shop"))
        let full = Set(fullNames(shop))
        let rows = shop.props.endpoints
        let walk = w.walk()
        editor.selectedShapeIDs = [shop.id]
        editor.selectItems([AnyHashable(rows[2].id)], of: shop.id)
        walk.press(Chord(Key.up, .option))
        expectEqual(undoTitle(w.window), "Undo Move Endpoint")
        expectEqual(fullNames(api(editor, "shop"))[1], "GET /orders/{id}")
        expectEqual(Set(fullNames(api(editor, "shop"))), full)
        walk.press(Chord(Key.down, .option))
        expectEqual(api(editor, "shop")?.props.endpoints, rows, "back, exactly")
        editor.selectItems([AnyHashable(rows[1].id)], of: shop.id)
        walk.press(Chord(Key.down, .option))
        expectEqual(undoTitle(w.window), "Undo Move Endpoints")
        expectEqual(api(editor, "shop")?.props.endpoints.map(EndpointGrammar.print), ["GET /health", "/customers", "GET /{id}/orders", "/orders", "GET /{id}", "POST /{id}/refunds"])
        expectEqual(Set(fullNames(api(editor, "shop"))), full)
        (w.window as! BoardWindow).undo(nil)
        editor.selectedShapeIDs = [shop.id]
        editor.selectItems([AnyHashable(rows[3].id), AnyHashable(rows[5].id)], of: shop.id)
        walk.press(Chord("x", .command))
        expectEqual(undoTitle(w.window), "Undo Cut Endpoints")
        walk.press(.escape)
        walk.press(.escape)
        expectEqual(editor.selectedShapeIDs, [])
        walk.press(Chord("v", .command))
        let made = try require(editor.editingShapeID, "the new API's name typed at once")
        expectEqual(fullNames(editor.document[made]?.typed(as: API.self)), ["POST /orders/{id}/refunds", "GET /customers/{id}/orders"])
        w.type("refunds API", with: walk)
        walk.press(.escape)
        expectEqual(undoTitle(w.window), "Undo Move Endpoints to New API")
        expectEqual(editor.document[made]?[TitleProperty.self], "refunds API")
    },
    test("an endpoint dragged with the mouse by its method chip into another API lands under its header, full path kept; Undo Move Endpoint") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        try w.turnKitOn()
        try w.draw(shopAPI)
        let editor = w.editor
        let shop = try require(api(editor, "shop")), billing = try require(api(editor, "billing"))
        editor.selectedShapeIDs = []
        let post = try w.rowRect(3, of: shop.id)
        let top = try w.rowRect(0, of: billing.id)
        w.mouseDrag(from: CGPoint(x: post.minX + 40, y: post.midY), to: CGPoint(x: top.midX, y: top.minY + 3), releasing: false)
        expectEqual(editor.hintedShapeID, billing.id)
        w.mouseUp(at: CGPoint(x: top.midX, y: top.minY + 3))
        expectEqual(api(editor, "billing")?.props.endpoints.map(EndpointGrammar.print), ["/orders", "GET /", "POST /{id}/refunds", "/payments", "GET /{id}"])
        expectEqual(fullNames(api(editor, "billing"))[1], "POST /orders/{id}/refunds")
        expectEqual(undoTitle(w.window), "Undo Move Endpoint")
        (w.window as! BoardWindow).undo(nil)
        expectEqual(api(editor, "shop")?.props.endpoints, shop.props.endpoints)
        expectEqual(api(editor, "billing")?.props.endpoints, billing.props.endpoints)
    },
])

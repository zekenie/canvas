import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
@_spi(Host) import CanvasUI
import Connections
import Engineering
import LineRows
import References
import Selection
import ShippedTesting
import TestKit
import Titles

// Changing and retiring an API, shipped (K16): E5 panels 2 to 4 through a new board's window with real presses, each step's Undo as
// Edit ▸ Undo says it (PATCH clicked and PUT picked from its chip's menu; ⌘↓ on the DELETE row and Space on deprecated, a storefront
// still calling it, unmarked; `/new-version`, v2 beside a faded v1); E6 panels 2 and 3 (a row's Delete taking its three arrows; the
// API deleted, storefront's pill for its row dashed with its arrow kept); E3 panel 4 by the mouse (the row dragged out by its chip
// stands alone as createRefund, its arrows following); Group by Prefix from the Shape menu; and the endpoint kind's fixture.

@MainActor private func api(_ editor: CanvasEditor, _ title: String) -> ShapeRecord<API>? {
    editor.document.shapes.first { $0[TitleProperty.self] == title }?.typed(as: API.self)
}

@MainActor private func arrows(_ editor: CanvasEditor) -> [ShapeRecord<Arrow>] { editor.document.shapes.compactMap { $0.typed(as: Arrow.self) } }

/// E5: the orders API grouped under /purchases and /customers, a storefront calling its DELETE row.
private let e5 = #"""
    api "orders API" server: "api.shop.dev/v1 bearer" endpoints: "/purchases\nGET /purchases/{id}\nPOST /purchases\nPOST /purchases/{id}/refunds\nPATCH /purchases/{id}\nPOST /purchases/{id}/cancel\nDELETE /purchases/{id}/items/{itemId}\n/customers\nGET /customers/{id}/orders"
    subboard "storefront" below "orders API" (gap: 120)
    edge "storefront" -> "orders API"."DELETE /purchases/{id}/items/{itemId}" channel: calls
    """#

/// E6: the orders API, refunds and payments right of it, storefront below; the refunds row called, writing refunds and reading
/// payments.
private let e6 = #"""
    api "orders API" server: "api.shop.dev/v1 bearer" endpoints: "GET /orders/{id}\nPOST /orders\nPOST /orders/{id}/refunds\nPATCH /orders/{id}"
    table "refunds" right of "orders API" (gap: 140) columns: "id uuid pk\namount_cents int"
    table "payments" below "refunds" (gap: 40) columns: "id uuid pk\namount_cents int"
    subboard "storefront" below "orders API" (gap: 120)
    edge "storefront" -> "orders API"."POST /orders/{id}/refunds" channel: calls
    edge "orders API"."POST /orders/{id}/refunds" -> "refunds" channel: writes
    edge "orders API"."POST /orders/{id}/refunds" -> "payments" channel: reads
    """#

/// E6 panel 3: a note on storefront's board that calls the refunds row, through a pill for it.
private let refundForm = #"""
    sticky-note "Refund form" in "storefront"
    edge "Refund form" -> "orders API"."POST /orders/{id}/refunds" channel: calls
    """#

@MainActor let apiChangeShippedTests = Suite("Changing and retiring an API, shipped", [
    test("E5 panels 2 to 4 by real presses: PATCH clicked, PUT picked from its chip's menu; ⌘↓ on DELETE and Space on deprecated, the storefront's call kept and unmarked; /new-version, v2 beside a faded v1; each Undo as Edit says it") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        try w.turnKitOn()
        try w.draw(e5)
        let editor = w.editor
        // The chip's menu is handed here as the window would pop it (its tracking would wait for a person), with the item it opens on.
        var popped: [(menu: NSMenu, highlighted: NSMenuItem?)] = []
        w.canvas.menuPresenter = { menu, _, item in popped.append((menu, item)) }
        let orders = try require(api(editor, "orders API"))
        let rows = orders.props.endpoints
        let call = try require(arrows(editor).first)
        editor.selectedShapeIDs = []
        // Panel 2: PATCH clicked, PUT picked.
        let patch = try w.rowRect(4, of: orders.id)
        w.mouseClick(at: CGPoint(x: patch.minX + 14 + 18 + 12, y: patch.midY))
        let (menu, highlighted) = try require(popped.last, "the chip's menu pops up")
        expectEqual(menu.outline, ["GET", "POST", "PUT", "✓ PATCH", "DELETE"], "the current method checked")
        expect(highlighted === menu.items[3], "and highlighted, so Return keeps it")
        try menu.choose("PUT")
        expectEqual(api(editor, "orders API")?.props.endpoints[4].endpoint?.method, "PUT")
        expectEqual(undoTitle(w.window), "Undo Change Method")
        // Panel 3: ⌘↓ on the DELETE row, then Space on deprecated.
        let walk = w.walk()
        editor.selectedShapeIDs = [orders.id]
        walk.press(.return)
        expectEqual(editor.editingShapeID, orders.id)
        for _ in 0..<3 { walk.press(.up) }
        expectEqual(w.lineRows?.focus, .row(rows[6].id), "↑ ↑ ↑ from the empty row: DELETE /{id}/items/{itemId}")
        walk.press(Chord(Key.down, .command))
        let card = try require(w.rowCard { _ in }, "its card")
        for _ in 0..<12 where card.focusedStop != "deprecated" { walk.press(.tab) }
        expectEqual(card.focusedStop, "deprecated", "reached by Tab")
        walk.press(.space)
        expectEqual(api(editor, "orders API")?.props.endpoints[6].endpoint?.deprecated, true)
        expectEqual(undoTitle(w.window), "Undo Deprecate Endpoint")
        let kept = try require(editor.document[call.id]?.typed(as: Arrow.self))
        expectEqual(kept.props, call.props, "the storefront still calls it, its arrow as it was")
        expectEqual(kept[ChannelProperty.self], Calls.id, "unmarked: no check of any kind")
        walk.press(.escape)
        walk.press(.escape)
        expectEqual(editor.editingShapeID, nil)
        expectEqual(editor.selectedShapeIDs, [orders.id])
        // Panel 4: /new-version on the API.
        walk.press(Chord("/"))
        w.type("new-version", with: walk)
        walk.press(.return)
        expectEqual(undoTitle(w.window), "Undo New Version")
        let v2 = try require(api(editor, "orders API v2"))
        expectEqual(editor.selectedShapeIDs, [v2.id], "v2 selected")
        expectEqual(v2.props.server.host, "api.shop.dev/v2")
        expectEqual(v2.props.endpoints.map(\.id), rows.map(\.id), "its rows under their ids")
        expectEqual(api(editor, "orders API")?.props.deprecated, true, "v1 faded")
        expectEqual(arrows(editor).count, 1, "the storefront calls v1 still, and nothing calls v2")
        let v1Frame = try require(editor.shapeContext.frame(of: orders.id)), v2Frame = try require(editor.shapeContext.frame(of: v2.id))
        expect(!v1Frame.intersects(v2Frame), "beside it")
        // Each step back, as Edit says it.
        (w.window as! BoardWindow).undo(nil)
        expectEqual(undoTitle(w.window), "Undo Deprecate Endpoint")
        (w.window as! BoardWindow).undo(nil)
        expectEqual(undoTitle(w.window), "Undo Change Method")
        (w.window as! BoardWindow).undo(nil)
        expectEqual(api(editor, "orders API")?.props.endpoints, rows)
    },
    test("E6 panel 2: a row selected and ⌫ takes the three arrows bound to it: Undo Delete Endpoint and 3 Arrows; one Undo brings them back") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        try w.turnKitOn()
        try w.draw(e6)
        let editor = w.editor
        let orders = try require(api(editor, "orders API"))
        expectEqual(arrows(editor).count, 3)
        let row = try w.rowRect(2, of: orders.id)
        editor.selectedShapeIDs = []
        w.mouseClick(at: CGPoint(x: row.midX, y: row.midY))
        w.mouseClick(at: CGPoint(x: row.midX, y: row.midY))
        expectEqual(editor.selectedItems?.ids, [AnyHashable(orders.props.endpoints[2].id)], "the row selected")
        let walk = w.walk()
        walk.press(.delete)
        expectEqual(undoTitle(w.window), "Undo Delete Endpoint and 3 Arrows")
        expectEqual(arrows(editor).count, 0)
        (w.window as! BoardWindow).undo(nil)
        expectEqual(arrows(editor).count, 3)
        expectEqual(api(editor, "orders API")?.props.endpoints, orders.props.endpoints)
    },
    test("E6 panel 3: the API deleted, storefront's board shows the pill for its refunds row dashed, its arrow kept; one Undo and it stands for the row again") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        try w.turnKitOn()
        try w.draw(e6)
        try w.draw(refundForm)
        let editor = w.editor
        let orders = try require(api(editor, "orders API"))
        let storefront = try require(editor.document.shapes.first { $0[TitleProperty.self] == "storefront" })
        let board = BoardID(owner: storefront.id)
        let pills = editor.contents(of: board).shapes.compactMap { $0.typed(as: Reference.self) }
        let pill = try require(pills.first, "a pill for the row on storefront's board")
        expectEqual(pill.props.target?.row, orders.props.endpoints[2].id)
        let far = try require(editor.contents(of: board).shapes.first { $0.kind == Arrow.kind })
        editor.selectedShapeIDs = [orders.id]
        let walk = w.walk()
        walk.press(.delete)
        expectEqual(undoTitle(w.window), "Undo Delete API and 3 Arrows")
        expect(editor.showBoard(board))
        w.window.settle()
        expect(editor.document[pill.id] != nil, "the pill stays")
        expectEqual(editor.document[far.id], far, "its arrow kept")
        let state = try require(editor.service(ReferenceState.self)?.state(of: pill.id))
        expect(state.standsForNothing, "dashed: \(state)")
        expect(editor.showBoard(.root))
        (w.window as! BoardWindow).undo(nil)
        expect(editor.showBoard(board))
        expectEqual(editor.service(ReferenceState.self)?.state(of: pill.id)?.standsForNothing, false, "it stands for the row again")
    },
    test("E3 panel 4 by the mouse: the refunds row dragged out by its chip stands alone as createRefund where it was let go, its call following; Undo Take Out Endpoint") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        try w.turnKitOn()
        try w.draw(e6)
        let editor = w.editor
        try w.draw(#"api "orders API" endpoints: [{"method": "POST", "path": "/orders/{id}/refunds", "name": "createRefund", "authScope": "orders:write"}]"#)
        let orders = try require(api(editor, "orders API"))
        let refunds = orders.props.endpoints[2]
        expectEqual(refunds.endpoint?.name, "createRefund")
        editor.selectedShapeIDs = []
        let row = try w.rowRect(2, of: orders.id)
        let chip = CGPoint(x: row.minX + 14 + 12, y: row.midY)
        let drop = CGPoint(x: row.minX + 40, y: row.maxY + 360)
        w.mouseDrag(from: chip, to: drop)
        expectEqual(undoTitle(w.window), "Undo Take Out Endpoint")
        let alone = try require(editor.document.shapes.first { $0.kind == StandaloneEndpoint.kind })
        expectEqual(editor.registry.title(of: alone), "createRefund")
        expectEqual(editor.accessibleDescription(of: alone.id)?.label, "createRefund, Endpoint")
        expectEqual(editor.accessibleDescription(of: alone.id)?.value, "POST /orders/{id}/refunds")
        let bound = arrows(editor).filter { $0.props.start.binding?.shapeID == alone.id || $0.props.end.binding?.shapeID == alone.id }
        expectEqual(bound.count, 3, "its call, its write and its read follow it")
        expect(bound.allSatisfy { $0.props.start.binding?.part == refunds.id || $0.props.end.binding?.part == refunds.id }, "bound to its row, under the row's id")
        // Agents name its row as an API's row is named: the same call drawn again is the one it has.
        let before = arrows(editor).count
        _ = try drawnInProcess(#"edge "storefront" -> "createRefund"."POST /orders/{id}/refunds" channel: calls"#, on: editor)
        expectEqual(arrows(editor).count, before, "the call it has: unchanged")
        (w.window as! BoardWindow).undo(nil)
        expectEqual(api(editor, "orders API")?.props.endpoints.map(\.id), orders.props.endpoints.map(\.id))
        expect(!editor.document.shapes.contains { $0.kind == StandaloneEndpoint.kind })
    },
    test("Shape ▸ Group by Prefix on an API whose rows aren't grouped: a header for each segment two share, one step, Undo Group by Prefix") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        try w.turnKitOn()
        try w.draw(#"api "shop API" endpoints: "GET /orders\nGET /orders/{id}\nGET /health\nPOST /customers\nGET /customers/{id}""#)
        let editor = w.editor
        let shop = try require(api(editor, "shop API"))
        editor.selectedShapeIDs = [shop.id]
        let menu = try require(w.menu(at: try w.rowRect(0, of: shop.id).origin.applying(CGAffineTransform(translationX: 100, y: 10))))
        expect(menu.outline.contains("Group by Prefix"), "\(menu.outline)")
        try menu.choose("Group by Prefix")
        expectEqual(api(editor, "shop API")?.props.endpoints.map(EndpointGrammar.print), ["GET /health", "/orders", "GET /", "GET /{id}", "/customers", "POST /", "GET /{id}"])
        expectEqual(undoTitle(w.window), "Undo Group by Prefix")
    },
])

import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Engineering
import Geometry
import Keyboard
import LineRows
import Selection
import TestKit
import Titles

// Rows dragged on the kit's kinds (K9): T4 panel 3 (status dragged by its row into order_items, a drop line between qty and
// price_cents, Move Column, one Undo) and T5 panel 3 (street to country dragged onto the board, Move Columns to New Table, its
// name typed at once), by the pointer; a column dragged by its key mark at once. And an API's rows, which K8's moves met in the
// merge: every move keeps each endpoint's full path, as the line editor does (⌥↑ ⌥↓ on endpoints selected as items across a
// header, a header moving its group; endpoints taken out to a new API; cut, copied or dragged into another, under its header).

extension KitBench {
    /// The middle of row `index` of shape `id`, world units (= view points at 100%).
    func middle(ofRow index: Int, in id: ShapeID) -> CGPoint {
        let record = editor.document[id]!
        let part = editor.registry.parts(of: record)![index].id
        let rect = editor.shapeContext.geometry(of: id)!.parts.frame(part)!.rect
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    /// Row `index`'s rect in shape `id`.
    func rect(ofRow index: Int, in id: ShapeID) -> CGRect {
        let record = editor.document[id]!
        return editor.shapeContext.geometry(of: id)!.parts.frame(editor.registry.parts(of: record)![index].id)!.rect
    }

    /// A click at a world point, a second after the last press, so it's a click of its own.
    func click(at point: CGPoint) {
        h.wait(1000)
        h.click(at: point)
    }

    /// A press at a world point dragged past the threshold, then to `to`; not let go.
    func drag(from: CGPoint, to: CGPoint) {
        h.wait(1000)
        h.press(at: from)
        h.drag(to: CGPoint(x: from.x, y: from.y + 8))
        h.drag(to: to)
    }

    func columnNames(_ id: ShapeID) -> [String] { columns(id).map(\.name) }
}

/// Whether a pixel is the accent's: bluer than it is red.
@MainActor private func isAccent(_ rgba: [Int]) -> Bool { rgba[2] > rgba[0] + 60 }

private let ordersLines = ["id uuid pk", "customer_id uuid", "status order_status", "total_cents int", "placed_at timestamptz null"]
private let itemsLines = ["id uuid pk", "order_id uuid", "product_id uuid", "qty int", "price_cents int"]
private let groupedAPI = ["GET /health", "/orders", "GET /{id}", "POST /{id}/refunds", "/customers", "GET /{id}/orders"]

@MainActor let rowDragTests = Suite("Rows dragged on the kit's kinds", [
    test("T4 panel 3: status clicked in orders, then dragged by its row into order_items: faded where it was, a drop line between qty and price_cents, order_items outlined; Move Column, one Undo") {
        let b = try KitBench()
        let orders = b.table("orders", ordersLines)
        let items = b.table("order_items", itemsLines, at: CGPoint(x: 520, y: 300))
        let status = b.middle(ofRow: 2, in: orders)
        b.click(at: status)
        expectEqual(b.editor.selectedShapeIDs, [orders], "the table first")
        b.click(at: status)
        expectEqual(b.editor.selectedItems?.ids, [AnyHashable(b.columns(orders)[2].id)], "then its row")
        let before = render(b.editor, size: CGSize(width: 1000, height: 800))
        let gap = b.rect(ofRow: 4, in: items).minY
        b.drag(from: status, to: CGPoint(x: b.rect(ofRow: 4, in: items).midX, y: gap + 3))
        expectEqual(b.editor.hintedShapeID, items, "order_items outlined")
        let during = render(b.editor, size: CGSize(width: 1000, height: 800))
        expect(isAccent(pixel(during, at: CGPoint(x: b.rect(ofRow: 4, in: items).midX + 60, y: gap))), "the drop line between qty and price_cents")
        let row = b.rect(ofRow: 2, in: orders)
        expect(changedPixels(before, during, in: row.insetBy(dx: 30, dy: 4)) > 20, "status faded where it is")
        expectEqual(b.columnNames(orders), ordersLines.map { String($0.split(separator: " ")[0]) }, "nothing written yet")
        b.h.release()
        expectEqual(b.columnNames(items), ["id", "order_id", "product_id", "qty", "status", "price_cents"])
        expectEqual(b.columnNames(orders), ["id", "customer_id", "total_cents", "placed_at"])
        expectEqual(b.undoName, "Move Column")
        expectEqual(b.editor.selectedShapeIDs, [items])
        expectEqual(b.editor.selectedItems?.ids.count, 1, "the column selected where it went")
        expectEqual(b.editor.hintedShapeID, nil)
        b.editor.undo()
        expectEqual(b.lines(orders), ordersLines.map { ColumnGrammar.print(ColumnGrammar.read($0)!) })
        expectEqual(b.columnNames(items), ["id", "order_id", "product_id", "qty", "price_cents"], "one Undo")
    },
    test("T5 panel 3 by the pointer: street clicked, ⇧-click on country, the four dragged onto the board: Move Columns to New Table, its own id first, its name typed at once") {
        let b = try KitBench()
        let customers = b.table("customers", ["id uuid pk", "email text unique", "name text", "street text", "city text", "postcode text",
                                              "country char(2)", "created_at timestamptz"])
        b.click(at: b.middle(ofRow: 3, in: customers))
        b.click(at: b.middle(ofRow: 3, in: customers))
        b.h.hold([.shift])
        b.click(at: b.middle(ofRow: 6, in: customers))
        b.h.hold([])
        expectEqual(b.editor.selectedItems?.ids.count, 4, "street to country")
        b.drag(from: b.middle(ofRow: 4, in: customers), to: CGPoint(x: 700, y: 560))
        expectEqual(b.editor.hintedShapeID, nil, "the board: nothing outlined")
        b.h.release()
        let made = try require(b.editor.editingShapeID, "its name typed at once")
        expectEqual(b.lines(made), ["id uuid pk", "street text", "city text", "postcode text", "country char(2)"])
        expectEqual(b.columnNames(customers), ["id", "email", "name", "created_at"])
        expectEqual(b.undoName, "Move Columns to New Table")
        let frame = try require(b.editor.shapeContext.frame(of: b.editor.document[made]!))
        expect(frame.contains(CGPoint(x: 700, y: 560)), "put down under the pointer: \(frame)")
        b.editor.endEditing()
        b.editor.undo()
        expectEqual(b.editor.document[made], nil)
        expectEqual(b.columnNames(customers).count, 8, "one Undo")
    },
    test("every drag has its keys: T4 panel 3 by ⌘X on status and ⌘V on qty, the same columns as the drag; within a table ⌥↑ ⌥↓; T5 panel 3 by ⌘X then ⌘V with nothing selected, the same new table") {
        let b = try KitBench()
        let orders = b.table("orders", ordersLines)
        let items = b.table("order_items", itemsLines, at: CGPoint(x: 520, y: 300))
        b.window.makeFirstResponder(b.canvas)
        b.editor.selectedShapeIDs = [orders]
        b.editor.selectItems([AnyHashable(b.columns(orders)[2].id)], of: orders)
        b.press(Chord("x", .command))
        b.editor.selectedShapeIDs = [items]
        b.editor.selectItems([AnyHashable(b.columns(items)[3].id)], of: items)
        b.press(Chord("v", .command))
        expectEqual(b.columnNames(items), ["id", "order_id", "product_id", "qty", "status", "price_cents"], "as the drag left them")
        expectEqual(b.columnNames(orders), ["id", "customer_id", "total_cents", "placed_at"])
        b.editor.selectItems([AnyHashable(b.columns(items)[4].id)], of: items)
        b.press(Chord(Key.down, .option))
        expectEqual(b.columnNames(items).suffix(2), ["price_cents", "status"], "a drag within the table, by ⌥↓")
        let customers = b.table("customers", ["id uuid pk", "street text", "city text"], at: CGPoint(x: 100, y: 500))
        b.editor.selectedShapeIDs = [customers]
        b.editor.selectItems(b.columns(customers).suffix(2).map { AnyHashable($0.id) }, of: customers)
        b.press(Chord("x", .command))
        b.editor.selectedShapeIDs = []
        b.press(Chord("v", .command))
        let made = try require(b.editor.editingShapeID, "a table of their own, its name typed")
        expectEqual(b.lines(made), ["id uuid pk", "street text", "city text"], "as a drag onto the board makes it")
        expectEqual(b.undoName, "Move Columns to New Table")
    },
    test("a column drags by its key mark at once, its table unselected; a column with no mark has no lead, and a press there moves the table") {
        let b = try KitBench()
        let orders = b.table("orders", ordersLines)
        let items = b.table("order_items", itemsLines, at: CGPoint(x: 520, y: 300))
        b.editor.selectedShapeIDs = []
        let mark = CGPoint(x: b.rect(ofRow: 0, in: orders).minX + 19, y: b.middle(ofRow: 0, in: orders).y)
        b.drag(from: mark, to: CGPoint(x: b.rect(ofRow: 1, in: items).midX, y: b.rect(ofRow: 1, in: items).minY + 3))
        b.h.release()
        expectEqual(b.columnNames(items), ["id", "id", "order_id", "product_id", "qty", "price_cents"], "the pk dragged in, after the first id")
        expectEqual(b.undoName, "Move Column")
        b.editor.undo()
        b.editor.selectedShapeIDs = []
        let box = b.editor.document[orders]?.box
        b.drag(from: CGPoint(x: b.rect(ofRow: 1, in: orders).minX + 19, y: b.middle(ofRow: 1, in: orders).y), to: CGPoint(x: 120, y: 600))
        b.h.release()
        expect(b.editor.document[orders]?.box != box, "the table moved")
        expectEqual(b.columnNames(orders).count, 5)
    },
    test("⌥↑ ⌥↓ on an endpoint selected as an item: above the first header it takes its prefix along, back under it its full path again, exactly; a header selected moves its group past the next, no full path changing") {
        let b = try KitBench()
        let api = b.api("shop", groupedAPI)
        let start = b.rows(api)
        let full = Set(b.fullNames(api))
        b.window.makeFirstResponder(b.canvas)
        b.editor.selectedShapeIDs = [api]
        b.editor.selectItems([AnyHashable(start[2].id)], of: api)
        b.press(Chord(Key.up, .option))
        expectEqual(b.rows(api).map(\.id), [start[0].id, start[2].id, start[1].id, start[3].id, start[4].id, start[5].id])
        expectEqual(b.rows(api)[1].endpoint?.path, "/orders/{id}", "under no header: its whole path")
        expectEqual(Set(b.fullNames(api)), full)
        expectEqual(b.undoName, "Move Endpoint")
        b.editor.undoHistory.seal()
        b.press(Chord(Key.down, .option))
        expectEqual(b.rows(api), start, "back under /orders, exactly")
        b.editor.selectItems([AnyHashable(start[1].id)], of: api)
        b.press(Chord(Key.down, .option))
        expectEqual(b.apiLines(api), ["GET /health", "/customers", "GET /{id}/orders", "/orders", "GET /{id}", "POST /{id}/refunds"])
        expectEqual(Set(b.fullNames(api)), full)
        expectEqual(b.undoName, "Move Endpoints")
        expectEqual(b.editor.selectedItems?.ids, [AnyHashable(start[1].id)], "the header still the one selected")
        b.press(Chord(Key.down, .option))
        expectEqual(b.apiLines(api).last, "POST /{id}/refunds", "the last group goes no further")
    },
    test("endpoints taken out to a new API carry their full paths, a header taken with its endpoints still theirs; served where it was, its name typed at once; Move Endpoints to New API from the selection's menu") {
        let b = try KitBench()
        let api = b.api("shop", groupedAPI, server: APIServer(host: "api.shop.dev/v1", auth: "bearer"))
        let rows = b.rows(api)
        b.editor.selectedShapeIDs = [api]
        b.editor.selectItems([AnyHashable(rows[2].id), AnyHashable(rows[5].id)], of: api)
        let menu = try require(b.h.secondaryClick(at: b.middle(ofRow: 2, in: api)))
        expect(menu.outline.contains("Move Endpoints to New API"), "\(menu.outline)")
        try menu.choose("Move Endpoints to New API")
        let made = try require(b.editor.editingShapeID, "its name typed at once")
        expectEqual(b.fullNames(made), ["GET /orders/{id}", "GET /customers/{id}/orders"])
        expectEqual(b.editor.document[made]?.typed(as: API.self)?.props.server, APIServer(host: "api.shop.dev/v1", auth: "bearer"))
        expectEqual(b.fullNames(api), ["GET /health", "POST /orders/{id}/refunds"])
        expectEqual(b.undoName, "Move Endpoints to New API")
        b.editor.endEditing()
        b.editor.undo()
        expectEqual(b.rows(api), rows, "one Undo")
        let group = try require(b.editor.moveRows([rows[1].id], of: api, to: .beside([api])), "a header alone takes its group")
        expectEqual(b.apiLines(group), ["/orders", "GET /{id}", "POST /{id}/refunds"])
        expectEqual(b.apiLines(api), ["GET /health", "/customers", "GET /{id}/orders"])
    },
    test("endpoints cut or copied into another API go under its longest matching header, their full paths kept; ⌘X then ⌘V on the board makes a new API of them") {
        let b = try KitBench()
        let api = b.api("shop", groupedAPI)
        let other = b.api("billing", ["/orders", "GET /", "/payments", "GET /{id}"], at: CGPoint(x: 100, y: 500))
        let rows = b.rows(api)
        expect(b.editor.copyRows([rows[3].id], of: api))
        let payload = try require(b.editor.pasteboardRows)
        b.editor.pasteRows(payload, to: .into(other, before: nil))
        expectEqual(b.apiLines(other), ["/orders", "GET /", "POST /{id}/refunds", "/payments", "GET /{id}"])
        expectEqual(b.undoName, "Paste Endpoint")
        expect(b.editor.cutRows([rows[0].id], of: api))
        b.editor.pasteRows(try require(b.editor.pasteboardRows), to: .into(other, before: b.rows(other)[4].id))
        expectEqual(b.fullNames(other).first, "GET /health", "under none of its headers: at the top")
        expect(b.editor.cutRows([rows[5].id], of: api))
        let made = try require(b.editor.pasteRows(try require(b.editor.pasteboardRows), to: .beside([])))
        expectEqual(b.fullNames(made), ["GET /customers/{id}/orders"])
        expectEqual(b.undoName, "Move Endpoint to New API")
    },
    test("an endpoint dragged by its method chip into another API lands under that API's header, the line drawn where it lands, not where the pointer is") {
        let b = try KitBench()
        let api = b.api("shop", groupedAPI)
        let other = b.api("billing", ["/orders", "GET /", "/payments", "GET /{id}"], at: CGPoint(x: 100, y: 500))
        b.editor.selectedShapeIDs = []
        let post = b.rect(ofRow: 3, in: api)
        b.drag(from: CGPoint(x: post.minX + 40, y: post.midY), to: CGPoint(x: b.rect(ofRow: 0, in: other).midX, y: b.rect(ofRow: 0, in: other).minY + 3))
        expectEqual(b.editor.hintedShapeID, other)
        let landing = b.rect(ofRow: 2, in: other).minY
        let picture = render(b.editor, size: CGSize(width: 1000, height: 800))
        expect(isAccent(pixel(picture, at: CGPoint(x: 400, y: landing))), "the line before /payments, where it goes")
        b.h.release()
        expectEqual(b.apiLines(other), ["/orders", "GET /", "POST /{id}/refunds", "/payments", "GET /{id}"])
        expectEqual(b.fullNames(other)[1], "POST /orders/{id}/refunds")
        expectEqual(b.fullNames(api), ["GET /health", "GET /orders/{id}", "GET /customers/{id}/orders"])
        expectEqual(b.undoName, "Move Endpoint")
    },
])

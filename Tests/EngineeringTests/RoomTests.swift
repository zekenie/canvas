import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Engineering
import Geometry
import Keyboard
import LineRows
import Selection
import TestKit

// The kit's kinds make room as their rows grow (`MakesRoomAsItGrows`, the core's push): a table, an enum and an API that
// gain rows in a database push what's below them in it down, keep their gaps, and the database grows to hold what the
// push takes past its bottom, pushing what's below it on the board.

@MainActor private func column(_ line: String) -> Column { ColumnGrammar.read(line)! }

extension EditorHarness {
    fileprivate func frame(_ id: ShapeID) -> CGRect? { editor.shapeContext.frame(of: id) }
}

@MainActor let roomTests = Suite("Making room", [
    test("a table given a column in a database pushes the table below it down by its line, in the step; Undo takes both") {
        let h = try kitHarness()
        let shop = h.add(Database(frame: CGRect(x: 100, y: 100, width: 800, height: 600)), titled: "shop")
        let customers = h.add(DatabaseTable(frame: CGRect(x: 132, y: 132, width: 260, height: 0), columns: [column("id uuid pk"), column("email text")]),
                              titled: "customers")
        let top = try require(h.frame(customers))
        let products = h.add(DatabaseTable(frame: CGRect(x: 132, y: top.maxY + 40, width: 260, height: 0), columns: [column("id uuid pk")]),
                             titled: "products")
        let beside = h.add(DatabaseTable(frame: CGRect(x: 500, y: top.maxY + 10, width: 260, height: 0), columns: [column("id uuid pk")]),
                           titled: "orders")
        h.editor.put([customers, products, beside], in: shop)
        h.editor.undoHistory.seal()
        let was = try require(h.frame(products)).minY
        h.editor.transact("Add Column") { $0.update(customers, as: DatabaseTable.self) { $0.props.columns.append(column("name text")) } }
        let grown = try require(h.frame(customers)).maxY - top.maxY
        expect(grown > 0, "a line taller")
        expectEqual(h.frame(products)?.minY, top.maxY + grown + max(40, KitStyle.roomKeptBelow), "the gap of 40 kept, at least the room it keeps below (a waiting line and a pill)")
        expectEqual(h.frame(beside)?.minY, top.maxY + 10, "not under it")
        expectEqual(h.editor.holder(of: products), shop)
        expectEqual(h.editor.undoHistory.undoName, "Add Column")
        h.editor.undo()
        expectEqual(h.frame(products)?.minY, was)
        expectEqual(h.frame(customers)?.maxY, top.maxY)
    },
    test("an enum given values pushes the table below it; an API given endpoints pushes the table below it and the database grows") {
        let h = try kitHarness()
        let shop = h.add(Database(frame: CGRect(x: 100, y: 100, width: 900, height: 400)), titled: "shop")
        let status = h.add(DatabaseEnum(frame: CGRect(x: 132, y: 132, width: 220, height: 0), values: [EnumValue(text: "pending")]), titled: "order_status")
        let statusBottom = try require(h.frame(status)).maxY
        let refunds = h.add(DatabaseTable(frame: CGRect(x: 132, y: statusBottom + 30, width: 260, height: 0), columns: [column("id uuid pk")]),
                            titled: "refunds")
        let api = h.add(API(frame: CGRect(x: 500, y: 132, width: 380, height: 100), endpoints: [EndpointGrammar.read("GET /orders")!]), titled: "orders api")
        let apiBottom = try require(h.frame(api)).maxY
        let payments = h.add(DatabaseTable(frame: CGRect(x: 500, y: apiBottom + 20, width: 260, height: 0), columns: [column("id uuid pk")]),
                             titled: "payments")
        h.editor.put([status, refunds, api, payments], in: shop)
        let outside = h.add(Box(CGRect(x: 100, y: 520, width: 900, height: 40)))   // 20 under the database
        h.editor.undoHistory.seal()

        let refundsWas = try require(h.frame(refunds)).minY
        h.editor.transact("Add Value") { $0.update(status, as: DatabaseEnum.self) { $0.props.values.append(EnumValue(text: "paid")) } }
        let enumGrowth = try require(h.frame(status)).maxY - statusBottom
        expect(enumGrowth > 0)
        expectEqual(h.frame(refunds)?.minY, statusBottom + enumGrowth + max(30, KitStyle.roomKeptBelow), "the gap of 30 kept, at least the room it keeps below")
        expect(refundsWas < statusBottom + KitStyle.roomKeptBelow, "a gap short of that room: made up")

        let paymentsWas = try require(h.frame(payments)).minY
        let lines = ["POST /orders", "GET /orders/{id}", "DELETE /orders/{id}", "GET /refunds", "POST /refunds", "GET /payments",
                     "GET /customers", "POST /customers", "GET /products", "POST /products"]
        h.editor.transact("Paste Endpoints") { $0.update(api, as: API.self) { $0.props.endpoints += lines.compactMap { EndpointGrammar.read($0) } } }
        let apiGrowth = try require(h.frame(api)).maxY - apiBottom
        let moved = try require(h.frame(payments))
        expectEqual(moved.minY, apiBottom + apiGrowth + max(20, KitStyle.roomKeptBelow), "the gap of 20 made up to the room an API keeps below it (UX walk 3 apis-1)")
        expect(moved.minY > paymentsWas + apiGrowth)
        let edge = try require(h.editor.document[shop]?.box)
        expect(moved.maxY > 500 - Settlement.gap, "the push took it past the database's bottom: \(moved.maxY)")
        expectEqual(edge.maxY, moved.maxY + Settlement.gap, "the database grows to hold it the gap inside")
        expectEqual(h.editor.holder(of: payments), shop)
        expectEqual(h.editor.document[outside]?.box?.minY, 520 + (edge.maxY - 500), "the box under the database pushed by its growth")
        h.editor.undo()
        expectEqual(h.editor.document[shop]?.box?.height, 400)
        expectEqual(h.frame(payments)?.minY, paymentsWas)
        expectEqual(h.editor.document[outside]?.box?.minY, 520)
    },
    test("a locked table under a table that grows stays, overlapped, and so does what's under it") {
        let refusals = RefusalLog()
        let h = try kitHarness(refusals)
        let customers = h.add(DatabaseTable(frame: CGRect(x: 100, y: 100, width: 260, height: 0), columns: [column("id uuid pk")]), titled: "customers")
        let bottom = try require(h.frame(customers)).maxY
        let locked = h.add(DatabaseTable(frame: CGRect(x: 100, y: bottom + 10, width: 260, height: 0), columns: [column("id uuid pk")]), titled: "products")
        h.editor.freeze([locked])
        h.editor.transact("Add Column") { $0.update(customers, as: DatabaseTable.self) { $0.props.columns += [column("a text"), column("b text")] } }
        expectEqual(h.frame(locked)?.minY, bottom + 10)
        expectEqual(refusals.refusals, [], "nothing refused: the push left it be")
    },
    test("a column cut from one table and pasted into another, or dragged there, pushes what's under the one it lands in, in the move's step; the table it left pulls nothing up") {
        let ordersLines = ["id uuid pk", "customer_id uuid", "status order_status", "total_cents int"]
        let itemsLines = ["id uuid pk", "order_id uuid", "qty int"]
        for dragged in [false, true] {
            let b = try KitBench()
            let orders = b.table("orders", ordersLines)
            let items = b.table("order_items", itemsLines, at: CGPoint(x: 520, y: 100))
            let itemsBottom = try require(b.h.frame(items)).maxY
            let refunds = b.table("refunds", ["id uuid pk"], at: CGPoint(x: 520, y: itemsBottom + 20))
            let under = b.table("payments", ["id uuid pk"], at: CGPoint(x: 100, y: try require(b.h.frame(orders)).maxY + 20))
            let ordersBottom = try require(b.h.frame(orders)).maxY
            let underAt = try require(b.h.frame(under)).minY
            let how = dragged ? "dragged" : "cut and pasted"
            if dragged {
                let status = b.middle(ofRow: 2, in: orders)
                b.click(at: status)
                b.click(at: status)
                b.drag(from: status, to: CGPoint(x: b.rect(ofRow: 2, in: items).midX, y: b.rect(ofRow: 2, in: items).minY + 3))
                b.h.release()
            } else {
                b.window.makeFirstResponder(b.canvas)
                b.editor.selectedShapeIDs = [orders]
                b.editor.selectItems([AnyHashable(b.columns(orders)[2].id)], of: orders)
                b.press(Chord("x", .command))
                b.editor.selectedShapeIDs = [items]
                b.editor.selectItems([AnyHashable(b.columns(items)[2].id)], of: items)
                b.press(Chord("v", .command))
            }
            expectEqual(b.columnNames(items).count, 4, "the column landed, \(how)")
            let growth = try require(b.h.frame(items)).maxY - itemsBottom
            expect(growth > 0, "the table it landed in is a line taller, \(how)")
            expectEqual(b.h.frame(refunds)?.minY, itemsBottom + growth + max(20, KitStyle.roomKeptBelow), "pushed by the line, the gap of 20 made up to the room it keeps below, \(how)")
            expect(try require(b.h.frame(orders)).maxY < ordersBottom, "the table it left is a line shorter, \(how)")
            expectEqual(b.h.frame(under)?.minY, underAt, "and pulls nothing up, \(how)")
            expectEqual(b.undoName, dragged ? "Move Column" : "Paste Column", "one step, as Edit says it")
            b.editor.undo()
            expectEqual(b.h.frame(refunds)?.minY, itemsBottom + 20, "one Undo puts the move and the push back, \(how)")
            expectEqual(b.columnNames(items), ["id", "order_id", "qty"])
        }
    },
    test("a column dragged into a table folded to its marks pushes what's under it for every row the table shows once it unfolds, not only the one it lands (review R9)") {
        let b = try KitBench()
        let orders = b.table("orders", ["id uuid pk", "customer_id uuid", "status text", "total_cents int"])
        let items = b.table("order_items", ["id uuid pk", "order_id uuid", "qty int", "note text", "a text", "b text", "c text", "d text", "e text"],
                            at: CGPoint(x: 520, y: 100))
        b.editor.rowFolds?.fold([items])
        b.window.settle()
        let folded = try require(b.h.frame(items))
        let refunds = b.table("refunds", ["id uuid pk"], at: CGPoint(x: 520, y: folded.maxY + 20))
        let refundsAt = try require(b.h.frame(refunds)).minY
        let status = b.middle(ofRow: 2, in: orders)
        b.click(at: status)
        b.click(at: status)
        b.drag(from: status, to: CGPoint(x: b.rect(ofRow: 0, in: items).midX, y: b.rect(ofRow: 0, in: items).maxY - 3))
        b.h.release()
        expectEqual(b.columnNames(items).count, 10, "the column landed")
        expectEqual(b.undoName, "Move Column")
        expectEqual(b.editor.rowFolds?.isFolded(items), false, "unfolded once it landed")
        let pushed = try require(b.h.frame(refunds)).minY, unfolded = try require(b.h.frame(items))
        expect(unfolded.maxY - folded.maxY > 5 * KitStyle.rowHeight, "the table unfolded shows rows the fold hid")
        expect(pushed >= unfolded.maxY + 20 - 0.5, "what's under it clears the unfolded table, the gap of 20 kept: \(refundsAt) → \(pushed), table to \(unfolded.maxY)")
        b.editor.undo()
        expectEqual(b.h.frame(refunds)?.minY, refundsAt, "one Undo puts it back")
    },
])

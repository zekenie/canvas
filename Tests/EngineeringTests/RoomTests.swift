@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Engineering
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
        expectEqual(h.frame(products)?.minY, was + grown, "the gap of 40 kept")
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
        expectEqual(h.frame(refunds)?.minY, refundsWas + enumGrowth, "the gap of 30 kept")

        let paymentsWas = try require(h.frame(payments)).minY
        let lines = ["POST /orders", "GET /orders/{id}", "DELETE /orders/{id}", "GET /refunds", "POST /refunds", "GET /payments",
                     "GET /customers", "POST /customers", "GET /products", "POST /products"]
        h.editor.transact("Paste Endpoints") { $0.update(api, as: API.self) { $0.props.endpoints += lines.compactMap { EndpointGrammar.read($0) } } }
        let apiGrowth = try require(h.frame(api)).maxY - apiBottom
        let moved = try require(h.frame(payments))
        expectEqual(moved.minY, paymentsWas + apiGrowth, "the gap of 20 kept")
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
])

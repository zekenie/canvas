import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CanvasUI
import Connections
import CoreGraphics
import Engineering
import Foundation
import LanguageModels
import LineRows
import Mentions
import Queries
import ShippedTesting
import StickyNotes
import TestKit
import Titles

// The live evaluation's fifth file (scripts/query-prompts, QueryLiveTests), for the questions about the engineering kit: a database
// of tables with their keys, an enum, a table outside it, two APIs whose endpoints write, read and call, and a note that calls one,
// built with the shipped kinds and connector as the other files are, with fixed ids, `00000000-0000-4000-8000-0000000D00NN`, and
// the rows' ids `00000000-0000-4000-9000-0000000D00NN`.
//
//     shop          …01  a database holding customers, orders, refunds and order_status
//     customers     …11  id uuid pk; email text unique; name text
//     orders        …12  id uuid pk; customer_id uuid → customers.id; status order_status; placed_at timestamptz null
//     refunds       …13  id uuid pk; order_id uuid → orders.id; amount_cents int
//     order_status  …14  an enum: pending, paid, refunded
//     audit_log     …15  outside the database: id uuid pk; actor_email text; action text
//     orders API    …21  api.shop.dev/v1 bearer; /orders: GET /{id} → 200 Order, POST /{id}/refunds (NewRefund) → 201 Refund;
//                        /customers: GET /{customer_id}/orders → 200 Order
//     billing API   …22  billing.shop.dev; POST /v1/refunds → 201; GET /v1/invoices/{id}
//     Storefront    …31  a note
//
// And the arrows: …51 and …52 the keys (orders.customer_id → customers.id, refunds.order_id → orders.id); …53 POST
// /orders/{id}/refunds writes refunds; …54 GET /orders/{id} and …55 GET /customers/{customer_id}/orders read orders; …56 POST
// /orders/{id}/refunds calls billing API's POST /v1/refunds; …57 that writes audit_log; …58 Storefront calls GET /orders/{id}.

/// The evaluation's file of the engineering kit: its shapes' ids, its rows', and the file (`file(in:)`) in an editor of the shipped
/// plugins (`harness`) or a board document (`document`).
@MainActor
enum QueryKitBoard {
    /// `…D00NN`: the file's shape `nn`.
    static func id(_ nn: UInt8) -> ShapeID {
        ShapeID(UUID(uuidString: String(format: "00000000-0000-4000-8000-0000000D00%02X", nn))!)
    }

    /// `9000-…D00NN`: the file's row `nn`.
    static func row(_ nn: UInt8) -> PartID {
        PartID(UUID(uuidString: String(format: "00000000-0000-4000-9000-0000000D00%02X", nn))!)
    }

    static let shop = id(0x01)
    static let customers = id(0x11), orders = id(0x12), refunds = id(0x13), orderStatus = id(0x14), auditLog = id(0x15)
    static let ordersAPI = id(0x21), billingAPI = id(0x22)
    static let storefront = id(0x31)
    static let customerKey = id(0x51), orderKey = id(0x52)
    static let writesRefunds = id(0x53), readsOrder = id(0x54), readsCustomerOrders = id(0x55), callsBilling = id(0x56), writesAudit = id(0x57)
    static let storefrontCalls = id(0x58)

    /// The rows: each table's, then each API's.
    static let customersID = row(0x11), customersEmail = row(0x12), customersName = row(0x13)
    static let ordersID = row(0x21), ordersCustomer = row(0x22), ordersStatus = row(0x23), ordersPlaced = row(0x24)
    static let refundsID = row(0x31), refundsOrder = row(0x32), refundsAmount = row(0x33)
    static let auditID = row(0x51), auditActor = row(0x52), auditAction = row(0x53)
    static let ordersHeader = row(0x61), getOrder = row(0x62), postRefund = row(0x63), customersHeader = row(0x64), getCustomerOrders = row(0x65)
    static let postBillingRefund = row(0x71), getInvoice = row(0x72)

    /// Every shape, in file order: the database followed by what it holds.
    static let fileOrder = [shop, customers, orders, refunds, orderStatus, auditLog, ordersAPI, billingAPI, storefront,
                            customerKey, orderKey, writesRefunds, readsOrder, readsCustomerOrders, callsBilling, writesAudit, storefrontCalls]

    static func file(in registry: Registry) -> CanvasFile {
        func titled<P: ShapeProps>(_ id: ShapeID, _ title: String, _ props: P, in container: ShapeID? = nil) -> AnyShapeRecord {
            var record = ShapeRecord(id: id, props)
            record[TitleProperty.self] = title
            let any = AnyShapeRecord(record)
            return container.map { any.copy(as: id, container: $0) } ?? any
        }
        func table(_ id: ShapeID, _ title: String, at x: CGFloat, _ y: CGFloat, _ columns: [Column], in container: ShapeID? = shop) -> AnyShapeRecord {
            titled(id, title, DatabaseTable(frame: CGRect(x: x, y: y, width: 280, height: 40 + 24 * CGFloat(columns.count)), columns: columns), in: container)
        }
        let shapes: [AnyShapeRecord] = [
            titled(shop, "shop", Database(frame: CGRect(x: 0, y: 0, width: 1040, height: 520))),
            table(customers, "customers", at: 40, 60, [
                Column(id: customersID, name: "id", type: TypeRef("uuid"), primaryKey: true),
                Column(id: customersEmail, name: "email", type: TypeRef("text"), unique: true),
                Column(id: customersName, name: "name", type: TypeRef("text")),
            ]),
            table(orders, "orders", at: 380, 60, [
                Column(id: ordersID, name: "id", type: TypeRef("uuid"), primaryKey: true),
                Column(id: ordersCustomer, name: "customer_id", type: TypeRef("uuid")),
                Column(id: ordersStatus, name: "status", type: TypeRef("order_status", shape: orderStatus)),
                Column(id: ordersPlaced, name: "placed_at", type: TypeRef("timestamptz"), nullable: true),
            ]),
            table(refunds, "refunds", at: 720, 60, [
                Column(id: refundsID, name: "id", type: TypeRef("uuid"), primaryKey: true),
                Column(id: refundsOrder, name: "order_id", type: TypeRef("uuid")),
                Column(id: refundsAmount, name: "amount_cents", type: TypeRef("int")),
            ]),
            titled(orderStatus, "order_status", DatabaseEnum(frame: CGRect(x: 380, y: 300, width: 220, height: 112),
                                                             values: ["pending", "paid", "refunded"].map { EnumValue(text: $0) }), in: shop),
            table(auditLog, "audit_log", at: 1140, 60, [
                Column(id: auditID, name: "id", type: TypeRef("uuid"), primaryKey: true),
                Column(id: auditActor, name: "actor_email", type: TypeRef("text")),
                Column(id: auditAction, name: "action", type: TypeRef("text")),
            ], in: nil),
            titled(ordersAPI, "orders API", API(frame: CGRect(x: 40, y: 640, width: 520, height: 200), server: APIServer(host: "api.shop.dev/v1", auth: "bearer"),
                                                endpoints: [
                .header(PathHeader(id: ordersHeader, prefix: "/orders")),
                .endpoint(Endpoint(id: getOrder, method: "GET", path: "/{id}", responses: [EndpointResponse(status: "200", type: TypeRef("Order"))])),
                .endpoint(Endpoint(id: postRefund, method: "POST", path: "/{id}/refunds", body: TypeRef("NewRefund"),
                                   responses: [EndpointResponse(status: "201", type: TypeRef("Refund"))])),
                .header(PathHeader(id: customersHeader, prefix: "/customers")),
                .endpoint(Endpoint(id: getCustomerOrders, method: "GET", path: "/{customer_id}/orders", responses: [EndpointResponse(status: "200", type: TypeRef("Order"))])),
            ])),
            titled(billingAPI, "billing API", API(frame: CGRect(x: 720, y: 640, width: 440, height: 120), server: APIServer(host: "billing.shop.dev"), endpoints: [
                .endpoint(Endpoint(id: postBillingRefund, method: "POST", path: "/v1/refunds", responses: [EndpointResponse(status: "201")])),
                .endpoint(Endpoint(id: getInvoice, method: "GET", path: "/v1/invoices/{id}")),
            ])),
            titled(storefront, "Storefront", StickyNote(frame: CGRect(origin: CGPoint(x: 1240, y: 640), size: StickyNote.defaultSize), text: MentionText(plain: ""))),
        ]
        /// An arrow made by the shipped connector between two rows (or a row and a whole shape), on a channel.
        func arrow(_ id: ShapeID, _ from: PartAddress, _ to: PartAddress, _ channel: ChannelID) -> AnyShapeRecord {
            let context = ShapeContext(document: CanvasDocument(shapes: shapes), registry: registry)
            let request = ConnectionRequest(from: from.shape, to: to.shape, fromPart: from.part, toPart: to.part, channel: channel)
            guard let arrow = registry.connection(request, in: context) else { preconditionFailure("the shipped connector connects \(from) to \(to)") }
            return arrow.copy(as: id)
        }
        return CanvasFile(root: CanvasDocument(shapes: shapes + [
            arrow(customerKey, PartAddress(orders, part: ordersCustomer), PartAddress(customers, part: customersID), ForeignKey.id),
            arrow(orderKey, PartAddress(refunds, part: refundsOrder), PartAddress(orders, part: ordersID), ForeignKey.id),
            arrow(writesRefunds, PartAddress(ordersAPI, part: postRefund), PartAddress(refunds), Writes.id),
            arrow(readsOrder, PartAddress(ordersAPI, part: getOrder), PartAddress(orders), Reads.id),
            arrow(readsCustomerOrders, PartAddress(ordersAPI, part: getCustomerOrders), PartAddress(orders), Reads.id),
            arrow(callsBilling, PartAddress(ordersAPI, part: postRefund), PartAddress(billingAPI, part: postBillingRefund), Calls.id),
            arrow(writesAudit, PartAddress(billingAPI, part: postBillingRefund), PartAddress(auditLog), Writes.id),
            arrow(storefrontCalls, PartAddress(storefront), PartAddress(ordersAPI, part: getOrder), Calls.id),
        ]))
    }

    /// The file in an editor of the shipped plugins, their clipboard on `pasteboard` (a test's own) and their model `model`: the
    /// board shown, in the story's viewport, nothing selected.
    static func harness(pasteboard: NSPasteboard, model: any LanguageModel = ScriptedLanguageModel()) throws -> EditorHarness {
        let registry = try ShippedPlugins.registry(pasteboard: pasteboard, model: model)
        let h = EditorHarness { CanvasEditor(registry: registry, file: file(in: registry), scheduler: $0) }
        h.editor.viewportDidResize(to: QueryStory.viewport)
        return h
    }

    /// The file as the app opens it: a board document read from the file as written, with the boards' configuration
    /// (`configureQueryBoards`, first), in no window, nothing selected.
    static func document() throws -> BoardDocument {
        let registry = try require(BoardDocument.configuration, "boards are configured").registry
        let board = BoardDocument()
        try board.read(from: try BoardCodec(registry: registry).encode(file(in: registry)), ofType: boardType)
        board.editor.viewportDidResize(to: QueryStory.viewport)
        return board
    }
}

/// A kit board's shapes, as `canvas` writes their ids.
@MainActor private func kitIDs(_ ids: [ShapeID]) -> [String] { ids.map(\.description) }

@MainActor let queryKitBoardTests = Suite("Query kit board", [
    test("the kit board through canvas as built: its shapes in file order, the rows at its arrows' ends, :route, tests inside its lists, and its relations") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureQueryBoards(pasteboard: pasteboard, model: ScriptedLanguageModel())
        let board = try QueryKitBoard.document()
        defer { board.close() }
        let server = try startQueryServer(for: board)
        defer { server.stop() }
        typealias K = QueryKitBoard
        @MainActor func ids(_ text: String) throws -> [String] {
            let answered = try query(text, on: board, server, ["--brief"])
            expectEqual(answered.status, 0, "\(text): \(answered.error)")
            return try rowIDs(answered.output)
        }
        expectEqual(try ids("*"), kitIDs(K.fileOrder))

        // A key's row names the column at each end; a write the endpoint it leaves and the table as a whole; a call from a note the
        // endpoint it ends at.
        let keys = try JSON(text: try query("arrow[channel=foreign-key]", on: board, server, ["--brief"]).output)
        expectEqual(keys["rows"]?.arrayValue?.map { $0["connection"] }, [
            ["type": "foreign-key", "from": ["id": .string(K.orders.description), "title": "orders", "row": "customer_id"],
             "to": ["id": .string(K.customers.description), "title": "customers", "row": "id"]],
            ["type": "foreign-key", "from": ["id": .string(K.refunds.description), "title": "refunds", "row": "order_id"],
             "to": ["id": .string(K.orders.description), "title": "orders", "row": "id"]],
        ])
        let writes = try JSON(text: try query("arrow[channel=writes]", on: board, server, ["--brief"]).output)
        expectEqual(writes["rows"]?.arrayValue?.map { $0["connection"] }, [
            ["type": "writes", "from": ["id": .string(K.ordersAPI.description), "title": "orders API", "row": "POST /orders/{id}/refunds"],
             "to": ["id": .string(K.refunds.description), "title": "refunds"]],
            ["type": "writes", "from": ["id": .string(K.billingAPI.description), "title": "billing API", "row": "POST /v1/refunds"],
             "to": ["id": .string(K.auditLog.description), "title": "audit_log"]],
        ])
        let calls = try JSON(text: try query("arrow[channel=calls]", on: board, server, ["--brief"]).output)
        expectEqual(calls["rows"]?.arrayValue?.last?["connection"], [
            "type": "calls", "from": ["id": .string(K.storefront.description), "title": "Storefront"],
            "to": ["id": .string(K.ordersAPI.description), "title": "orders API", "row": "GET /orders/{id}"],
        ])

        // :route: the API that serves it, its row saying the endpoints it matched.
        let route = try JSON(text: try query(#":route("POST /orders/{order_id}/refunds")"#, on: board, server, ["--brief"]).output)
        expectEqual(route["rows"]?.arrayValue?.map { $0["id"] }, [.string(K.ordersAPI.description)])
        expectEqual(route["rows"]?.arrayValue?.first?["routes"], ["POST /orders/{id}/refunds"])
        expectEqual(try ids(#":route("/v1/invoices/{n}")"#), kitIDs([K.billingAPI]))

        // Inside a list: a column's name and its type, an enum's value, an endpoint's body.
        expectEqual(try ids(#"table[columns.name="email"]"#), kitIDs([K.customers]))
        expectEqual(try ids(#"table[columns.name*="email"]"#), kitIDs([K.customers, K.auditLog]))
        expectEqual(try ids(#"table[columns.type="order_status"]"#), kitIDs([K.orders]))
        expectEqual(try ids(#"enum-type[values="paid"]"#), kitIDs([K.orderStatus]))
        expectEqual(try ids(#"api[endpoints.body="NewRefund"]"#), kitIDs([K.ordersAPI]))

        // What it holds, and what connects to what.
        expectEqual(try ids(#""shop" table"#), kitIDs([K.customers, K.orders, K.refunds]))
        expectEqual(try ids(#"table:edge-to("customers", foreign-key)"#), kitIDs([K.orders]))
        expectEqual(try ids(#":edge-from("orders", foreign-key)"#), kitIDs([K.customers]))
        expectEqual(try ids(#":edge-to("refunds", writes)"#), kitIDs([K.ordersAPI]))
        // Which endpoint: the arrows into the table, whose rows say it.
        let into = try JSON(text: try query(#"arrow[channel=writes]:ends-at("refunds")"#, on: board, server, ["--brief"]).output)
        expectEqual(into["rows"]?.arrayValue?.map { $0["id"] }, [.string(K.writesRefunds.description)])
        expectEqual(into["rows"]?.arrayValue?.first?["connection"]?["from"]?["row"], "POST /orders/{id}/refunds")
        expectEqual(try ids(#"table:edge-from("orders API", reads)"#), kitIDs([K.orders]))
        expectEqual(try ids(#":edge-to("billing API", calls)"#), kitIDs([K.ordersAPI]))
        expectEqual(try ids(#":edge-to("orders API", calls)"#), kitIDs([K.storefront]))
        expectEqual(try ids(#"table:downstream-of("orders API", writes|calls)"#), kitIDs([K.refunds, K.auditLog]))
        expect(!board.isDocumentEdited)
    },
    test("across boards: a key and a call drawn through pills name the rows at the original's ends (the pill itself no row), and --ask's blocks say them") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let model = ScriptedLanguageModel(answers: ["table"])
        try configureQueryBoards(pasteboard: pasteboard, model: model)
        let board = try QueryKitBoard.document()
        defer { board.close() }
        let editor = board.editor
        let server = try startQueryServer(for: board)
        defer { server.stop() }
        typealias K = QueryKitBoard
        // A ledger and a hook on a subboard: the ledger's key into orders.id, the hook's call into GET /orders/{id}, both across.
        _ = try drawnInProcess(#"""
            subboard "billing" below "orders API" (gap: 200)
            """#, on: editor)
        _ = try drawnInProcess(#"""
            table "ledger" in "billing" columns: "id uuid pk\norder_id uuid → orders.id"
            api "billing hooks" below "ledger" (gap: 60) in "billing" endpoints: "POST /hooks/paid"
            edge "billing hooks"."POST /hooks/paid" -> "orders API"."GET /orders/{id}" channel: calls
            """#, on: editor)
        let ledger = try require(editor.file.everyBoard.lazy.flatMap { editor.file[$0].shapes }.first { $0[TitleProperty.self] == "ledger" }).id
        let hooks = try require(editor.file.everyBoard.lazy.flatMap { editor.file[$0].shapes }.first { $0[TitleProperty.self] == "billing hooks" }).id
        let key = try JSON(text: try query(#"arrow[channel=foreign-key]"#, on: board, server, ["--brief"]).output)
        let far = try require(key["rows"]?.arrayValue?.first { $0["connection"]?["from"]?["title"] == "ledger" }, "the key on the billing board")
        expectEqual(far["connection"]?["from"], ["id": .string(ledger.description), "title": "ledger", "row": "order_id"], "the original's row at its own end")
        expectEqual(far["connection"]?["to"], ["id": .string(K.orders.description), "title": "orders", "row": "id"], "the table the pill stands for, and its column")
        expect(far["connection"]?["via"] != nil, "through the pill: \(far)")
        expectEqual(far["connection"]?["via"]?["to"]?["row"], nil, "the pill itself names no row")
        let calls = try JSON(text: try query(#"arrow[channel=calls]"#, on: board, server, ["--brief"]).output)
        let hook = try require(calls["rows"]?.arrayValue?.first { $0["connection"]?["from"]?["title"] == "billing hooks" }, "the call on the billing board")
        expectEqual(hook["connection"]?["from"]?["row"], "POST /hooks/paid")
        expectEqual(hook["connection"]?["to"], ["id": .string(K.ordersAPI.description), "title": "orders API", "row": "GET /orders/{id}"])
        // The model is told the key's far end by the table's name, and the call by the endpoint it ends at.
        let asked = try canvas(server, ["query", "--ask", "What calls the orders API?", "--board", "\(board.number)"])
        expectEqual(asked.status, 0, asked.error)
        let request = try require(model.lastRequest?.messages.first?.text)
        let tables = try require(request.range(of: "<tables>\n"), request)
        let tablesEnd = try require(request.range(of: "\n</tables>"))
        let ledgerLine = try require(request[tables.upperBound..<tablesEnd.lowerBound].split(separator: "\n").first { $0.hasPrefix("ledger") })
        expectEqual(String(ledgerLine), "ledger: id uuid pk; order_id uuid → orders.id", "a key through a pill, and a table in a subboard no database")
        let apis = try require(request.range(of: "<apis>\n"), request)
        let apisEnd = try require(request.range(of: "\n</apis>"))
        let lines = request[apis.upperBound..<apisEnd.lowerBound].split(separator: "\n").map(String.init)
        expect(lines.contains(#"- GET /orders/{id} → 200 Order; reads "orders"; called by "billing hooks" POST /hooks/paid; called by "Storefront""#)
               || lines.contains(#"- GET /orders/{id} → 200 Order; reads "orders"; called by "Storefront"; called by "billing hooks" POST /hooks/paid"#),
               "an endpoint called from a pill on another board: \(lines)")
        _ = hooks
    },
    test("an endpoint taken out of its API is read as it was a row: :route finds it, its arrows' ends name its row, and --ask's <apis> lists it with what it does") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let model = ScriptedLanguageModel(answers: [#":route("POST /orders/{id}/refunds")"#])
        try configureQueryBoards(pasteboard: pasteboard, model: model)
        let board = try QueryKitBoard.document()
        defer { board.close() }
        let editor = board.editor
        let server = try startQueryServer(for: board)
        defer { server.stop() }
        typealias K = QueryKitBoard
        // Take Out Endpoint: the refunds row on its own, its arrows still bound to its row, now the endpoint's.
        let alone = try require(editor.moveRows([K.postRefund], of: K.ordersAPI, to: .board(origin: CGPoint(x: 40, y: 1000))))
        expectEqual(editor.undoHistory.undoName, "Take Out Endpoint")
        expectEqual(editor.document[alone]?.kind, StandaloneEndpoint.kind)
        @MainActor func ids(_ text: String) throws -> [String] {
            let answered = try query(text, on: board, server, ["--brief"])
            expectEqual(answered.status, 0, "\(text): \(answered.error)")
            return try rowIDs(answered.output)
        }
        let route = try JSON(text: try query(#":route("POST /orders/{order_id}/refunds")"#, on: board, server, ["--brief"]).output)
        expectEqual(route["rows"]?.arrayValue?.map { $0["id"] }, [.string(alone.description)], "the endpoint, no longer its API")
        expectEqual(route["rows"]?.arrayValue?.first?["routes"], ["POST /orders/{id}/refunds"])
        expectEqual(try ids(#":route("/orders/{id}")"#), kitIDs([K.ordersAPI]), "the API's own rows still its")
        // Its arrows: the write and the call leave its row, named as the API's row was.
        let writes = try JSON(text: try query("arrow[channel=writes]", on: board, server, ["--brief"]).output)
        expectEqual(writes["rows"]?.arrayValue?.first?["connection"],
                    ["type": "writes", "from": ["id": .string(alone.description), "title": "POST /orders/{id}/refunds", "row": "POST /orders/{id}/refunds"],
                     "to": ["id": .string(K.refunds.description), "title": "refunds"]])
        let calls = try JSON(text: try query("arrow[channel=calls]", on: board, server, ["--brief"]).output)
        expectEqual(calls["rows"]?.arrayValue?.first?["connection"]?["from"]?["row"], "POST /orders/{id}/refunds")
        expectEqual(try ids(#":edge-to("refunds", writes)"#), kitIDs([alone]))
        // --ask: it is told the endpoint, a route of its own with its write and call, and the billing API that it calls it.
        let asked = try canvas(server, ["query", "--ask", "Which endpoint writes refunds?", "--board", "\(board.number)"])
        expectEqual(asked.status, 0, asked.error)
        expectEqual(try rowIDs(asked.output), kitIDs([alone]))
        let request = try require(model.lastRequest?.messages.first?.text)
        let apis = try require(request.range(of: "<apis>\n"), request)
        let apisEnd = try require(request.range(of: "\n</apis>"))
        let lines = request[apis.upperBound..<apisEnd.lowerBound].split(separator: "\n").map(String.init)
        let head = try require(lines.firstIndex(of: "POST /orders/{id}/refunds (endpoint)"), "\(lines)")
        expectEqual(lines.dropFirst(head + 1).first,
                    #"- POST /orders/{id}/refunds (NewRefund) → 201 Refund; writes "refunds"; calls "billing API" POST /v1/refunds"#, "\(lines)")
        expect(lines.contains(#"- POST /v1/refunds → 201; writes "audit_log"; called by "POST /orders/{id}/refunds" POST /orders/{id}/refunds"#), "\(lines)")
        expect(!lines.contains { $0.hasPrefix("- POST /orders/{id}/refunds") && $0.contains("orders API") }, "\(lines)")
    },
    test("a type note and an enum renamed: a body's type and a column's type are found by the name they have now, and <apis> and <tables> say it") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let model = ScriptedLanguageModel(answers: [#"api[endpoints.body="RefundRequest"]"#])
        try configureQueryBoards(pasteboard: pasteboard, model: model)
        let board = try QueryKitBoard.document()
        defer { board.close() }
        let editor = board.editor
        let server = try startQueryServer(for: board)
        defer { server.stop() }
        typealias K = QueryKitBoard
        @MainActor func ids(_ text: String) throws -> [String] {
            let answered = try query(text, on: board, server, ["--brief"])
            expectEqual(answered.status, 0, "\(text): \(answered.error)")
            return try rowIDs(answered.output)
        }
        // A type note the orders API's refund body names, by the shape.
        _ = try drawnInProcess(#"sticky-note "NewRefund" below "Storefront" (gap: 100) schema: "{\"type\": \"object\", \"properties\": {\"amount\": {\"type\": \"integer\"}}}""#, on: editor)
        let note = try require(editor.document.shapes.first { $0[TitleProperty.self] == "NewRefund" }).id
        editor.transact("Bind") { tx in
            tx.update(K.ordersAPI, as: API.self) { api in
                for place in api.props.endpoints.indices {
                    if case .endpoint(var endpoint) = api.props.endpoints[place], endpoint.id == K.postRefund {
                        endpoint.body = TypeRef("NewRefund", shape: note)
                        api.props.endpoints[place] = .endpoint(endpoint)
                    }
                }
            }
        }
        expectEqual(try ids(#"api[endpoints.body="NewRefund"]"#), kitIDs([K.ordersAPI]))
        editor.transact("Rename") { tx in
            tx.update(note) { $0[TitleProperty.self] = "RefundRequest" }
            tx.update(K.orderStatus) { $0[TitleProperty.self] = "order_state" }
        }
        expectEqual(try ids(#"api[endpoints.body="RefundRequest"]"#), kitIDs([K.ordersAPI]), "the name the card shows")
        expectEqual(try ids(#"api[endpoints.body="NewRefund"]"#), [], "the words it was written in no longer")
        expectEqual(try ids(#"table[columns.type="order_state"]"#), kitIDs([K.orders]))
        expectEqual(try ids(#"table[columns.type="order_status"]"#), [])
        let asked = try canvas(server, ["query", "--ask", "Which APIs take a RefundRequest?", "--board", "\(board.number)"])
        expectEqual(asked.status, 0, asked.error)
        expectEqual(try rowIDs(asked.output), kitIDs([K.ordersAPI]))
        let request = try require(model.lastRequest?.messages.first?.text)
        expect(request.contains("- POST /orders/{id}/refunds (RefundRequest) → 201 Refund;"), "the block says the name the card does: \(request)")
        expect(request.contains("status order_state;"), request)
    },
    test("--ask tells the model the file's tables, a line each with their keys and database, and its APIs, a route a line with what each does") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let model = ScriptedLanguageModel(answers: [#":edge-to("refunds", writes)"#])
        try configureQueryBoards(pasteboard: pasteboard, model: model)
        let board = try QueryKitBoard.document()
        defer { board.close() }
        let server = try startQueryServer(for: board)
        defer { server.stop() }
        let asked = try canvas(server, ["query", "--ask", "Which endpoint writes refunds?", "--board", "\(board.number)"])
        expectEqual(asked.status, 0, asked.error)
        expectEqual(try rowIDs(asked.output), kitIDs([QueryKitBoard.ordersAPI]))
        let request = try require(model.lastRequest?.messages.first?.text)
        let tables = try require(request.range(of: "<tables>\n"), request)
        let tablesEnd = try require(request.range(of: "\n</tables>"))
        // The table the question names first, then the rest in file order.
        expectEqual(request[tables.upperBound..<tablesEnd.lowerBound].split(separator: "\n").map(String.init), [
            #"refunds (in "shop"): id uuid pk; order_id uuid → orders.id; amount_cents int"#,
            #"customers (in "shop"): id uuid pk; email text unique; name text"#,
            #"orders (in "shop"): id uuid pk; customer_id uuid → customers.id; status order_status; placed_at timestamptz null"#,
            "order_status (enum-type): pending, paid, refunded",
            "audit_log: id uuid pk; actor_email text; action text",
        ])
        let apis = try require(request.range(of: "</tables>\n\n<apis>\n"), "the APIs after the tables: \(request)")
        let apisEnd = try require(request.range(of: "\n</apis>"))
        expectEqual(request[apis.upperBound..<apisEnd.lowerBound].split(separator: "\n").map(String.init), [
            "orders API (api.shop.dev/v1 bearer)",
            #"- GET /orders/{id} → 200 Order; reads "orders"; called by "Storefront""#,
            #"- POST /orders/{id}/refunds (NewRefund) → 201 Refund; writes "refunds"; calls "billing API" POST /v1/refunds"#,
            #"- GET /customers/{customer_id}/orders → 200 Order; reads "orders""#,
            "billing API (billing.shop.dev)",
            #"- POST /v1/refunds → 201; writes "audit_log"; called by "orders API" POST /orders/{id}/refunds"#,
            "- GET /v1/invoices/{id}",
        ])
        expect(!board.isDocumentEdited)
    },
])

import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import Geometry
@_spi(Host) import CanvasUI
import Engineering
import LineRows
import Selection
import TestKit
import TextEditing
import Titles

// An API written a line each (K12): the endpoint, header and server grammars and what they lose (nothing), the grouping full
// paths share, the kind kept and named, `/api`, E7 panels 1 and 2 and E2 by the keys on a real canvas in an unshown window (no
// Types here, so every type an endpoint names is a dashed pill: the type notes are CompositionTests'), headers and E5 panel 1's
// Rename Path Prefix, Change Method, the server line, an endpoint's card by ⌘↓ and by its "›", and the look at rest.

/// A corpus of API lines, each a way a person writes one.
let endpointCorpus = [
    "GET /orders/{id}", "POST /orders", "post /orders/{id}/refunds (NewRefund) → 201 Refund", "PATCH /orders/{id} -> 200 Order",
    "DELETE /orders/{id}/items/{itemId}", "GET /customers/{id}/orders → Order", "POST /webhooks/stripe (StripeEvent) → 200",
    "/orders", "/customers", "GET /x (A) → 404 Problem and some words", "PUT /y (Two Words) → default", "OPTIONS", "GET", "nonsense words here",
    "GET /a (Body → 201", "HEAD /h → → 200", "TRACE /t (B) (C)", #"POST /r (Refund Request) → 201 "Refund Result""#, #"GET /q → "Two Words" tail"#,
    "GET /a (Two Words → 201", "GET /o → Order", "GET /s → 4XX",
]

extension KitBench {
    /// An API titled `name` holding `lines` (in the endpoint grammar), served at `server`, in a step of its own.
    @discardableResult
    func api(_ name: String, _ lines: [String], server: APIServer = APIServer(), at origin: CGPoint = CGPoint(x: 100, y: 100)) -> ShapeID {
        let id = h.add(API(frame: CGRect(origin: origin, size: CGSize(width: 520, height: 100)), server: server, endpoints: lines.compactMap { EndpointGrammar.read($0) }),
                       titled: name)
        editor.undoHistory.seal()
        return id
    }

    func rows(_ id: ShapeID) -> [APIRow] { editor.document[id]?.typed(as: API.self)?.props.endpoints ?? [] }
    func apiLines(_ id: ShapeID) -> [String] { rows(id).map(EndpointGrammar.print) }
    func fullNames(_ id: ShapeID) -> [String] {
        let rows = rows(id)
        return rows.indices.filter { rows[$0].endpoint != nil }.map { APIGroups.fullName(of: $0, in: rows) }
    }
}

@MainActor let apiTests = Suite("APIs", [
    test("the endpoint grammar's corpus and the server's: printing what was read reads back the same, and keeps the unread in order") {
        let b = try KitBench()
        let api = b.api("orders API", [])
        let context = LineContext(editor: b.editor, shape: api)
        let lost = EngineeringAPILines.rows.losses(in: endpointCorpus, unread: { $0.endpoint?.unread.split(separator: " ").map(String.init) ?? [] }, in: context)
        expect(lost.isEmpty, "lost: \(lost)")
        let servers = EngineeringAPILines.server.losses(in: ["api.shop.dev/v1 bearer", "billing.shop.dev", "x.dev apikey X-Key", "y.dev oauth2 extra words"],
                                                        unread: { $0.auth.split(separator: " ").map(String.init) }, in: context)
        expect(servers.isEmpty, "lost: \(servers)")
    },
    test("a line's parts: its method in any case, its path and parameters, a body in brackets, the arrow, a status and a response; a path alone is a header") {
        let scan = EndpointGrammar.scan("post /orders/{id}/refunds (NewRefund) -> 201 Refund extra")
        let endpoint = try require(scan.row?.endpoint)
        expectEqual(endpoint.method, "POST")
        expectEqual(endpoint.path, "/orders/{id}/refunds")
        expectEqual(endpoint.body, TypeRef("NewRefund"))
        expectEqual(endpoint.responses, [EndpointResponse(status: "201", type: TypeRef("Refund"))])
        expectEqual(endpoint.unread, "extra")
        expectEqual(scan.words.map(\.role), [.method, .path, .bracket, .body, .bracket, .arrow, .status, .response, .unread])
        expectEqual(scan.parameters, [NSRange(location: 13, length: 4)])
        expectEqual(EndpointGrammar.print(scan.row!), "POST /orders/{id}/refunds (NewRefund) → 201 Refund extra")
        expectEqual(EndpointGrammar.read("GET /orders/{id} → Order")?.endpoint?.responses, [EndpointResponse(status: "", type: TypeRef("Order"))])
        expectEqual(EndpointGrammar.read("/orders")?.header?.prefix, "/orders")
        expectEqual(EndpointGrammar.read("GET /a (New")?.endpoint?.body, TypeRef("New"), "a bracket typed open names what's typed so far")
        expectEqual(EndpointGrammar.parameterNames(in: "/orders/{id}/items/{itemId}"), ["id", "itemId"])
        expectEqual(ServerGrammar.read("api.shop.dev/v1 bearer"), APIServer(host: "api.shop.dev/v1", auth: "bearer"))
    },
    test("groups: a member's full path is its header's and its own; a full path goes under the longest header it starts with, else at the top") {
        let rows = ["GET /health", "/orders", "GET /{id}", "POST /", "/orders/{id}/items", "DELETE /{itemId}", "/customers", "GET /{id}/orders"].compactMap { EndpointGrammar.read($0) }
        let full = rows.indices.filter { rows[$0].endpoint != nil }.map { APIGroups.fullName(of: $0, in: rows) }
        expectEqual(full, ["GET /health", "GET /orders/{id}", "POST /orders", "DELETE /orders/{id}/items/{itemId}", "GET /customers/{id}/orders"])
        expectEqual(APIGroups.place("/orders/{id}/items/{itemId}/notes", in: rows).path, "/{itemId}/notes", "under the longest")
        expectEqual(APIGroups.place("/orders/{id}/refunds", in: rows).index, 4, "the end of /orders's group")
        expectEqual(APIGroups.place("/ordersX", in: rows).index, 1, "by whole segments: none, so at the top, after the endpoints under no header")
        expectEqual(APIGroups.place("/orders", in: rows).path, "/")
        expectEqual(APIGroups.members(of: 1, in: rows), 2)
        expect(APIGroups.isMember(2, in: rows) && !APIGroups.isMember(0, in: rows))
    },
    test("every member of an API round-trips through a board; a body's type is a name a copy renames; its rows are its parts, an endpoint by its full name, standing alone") {
        let codec = BoardCodec(registry: try Registry(plugins: kitPlugins()))
        let type = ShapeID()
        var api = ShapeRecord(API(frame: CGRect(x: 0, y: 0, width: 420, height: 100), server: APIServer(host: "api.shop.dev/v1", auth: "bearer"), version: "1.2", deprecated: true,
                                  endpoints: [.header(PathHeader(prefix: "/orders")),
                                              .endpoint(Endpoint(method: "POST", path: "/{id}/refunds", name: "createRefund", summary: "Refund part or all of a paid order.",
                                                                 authScope: "orders:write", parameters: [PathParameter(name: "id", type: "uuid")], body: TypeRef("NewRefund", shape: type),
                                                                 responses: [EndpointResponse(status: "201", type: TypeRef("Refund")), EndpointResponse(status: "404")],
                                                                 deprecated: true, unread: "x"))]))
        api[TitleProperty.self] = "orders API"
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(api)]))
        expectEqual(try codec.decode(try codec.encode(file)).file, file)
        let json = String(decoding: try codec.encodeProps(api.props), as: UTF8.self)
        expect(json.contains(#""header" : "/orders""#) && json.contains(#""shape" : "\#(type)""#), json)
        let h = try kitHarness()
        h.editor.transact { $0.insert(AnyShapeRecord(api)) }
        let copy = ShapeID()
        let renamed = try require(h.editor.document[api.id]?.remappingReferences({ $0 == type ? copy : nil }, in: h.editor.shapeContext))
        expectEqual(renamed.typed(as: API.self)?.props.endpoints[1].endpoint?.body, TypeRef("NewRefund", shape: copy))
        let parts = try require(h.editor.registry.parts(of: try require(h.editor.document[api.id])))
        expectEqual(parts.map(\.name), ["/orders", "POST /orders/{id}/refunds"])
        expectEqual(parts.map(\.kindWord), ["Path Prefix", "Endpoint"])
        expectEqual(parts[1].lead, .chip("POST"))
        expect(parts[1].standsAlone && !parts[0].standsAlone)
        expectEqual(h.editor.accessibleName(of: PartAddress(api.id, part: parts[1].id)), "POST /orders/{id}/refunds")
        expectEqual(h.editor.accessibleDescription(of: try require(h.editor.document[api.id])).label, "orders API, API")
        expectEqual(h.editor.accessibleDescription(of: try require(h.editor.document[api.id])).value, "1 endpoint")
    },
    test("/api on a board named shop: shop API, edited at its empty row, the server faint above it; /api orders API, so titled; each one step, Add API") {
        let h = try kitHarness()
        h.editor.nameRoot("shop")
        expect(h.offered.contains("api"), "\(h.offered)")
        expect(h.slash("api", ""))
        let api = try require(h.shapes(API.kind).first)
        expectEqual(api[TitleProperty.self], "shop API")
        expectEqual(h.editor.editingShapeID, api.id)
        expectEqual((h.editor.makeEditingView()?.view as? LineRowsView)?.focus, .waiting, "the caret on its empty row (E1 panel 3)")
        expectEqual(h.editor.undoHistory.undoName, "Add API")
        h.editor.endEditing()
        h.editor.selectedShapeIDs = []
        expect(h.slash("api", "orders API"))
        expectEqual(h.shapes(API.kind).last?[TitleProperty.self], "orders API")
        expectEqual(h.editor.undoHistory.undoName, "Add API")
    },
    test("E7 panels 1 and 2 by the keys: an empty row under the faint server; two lines each Add Endpoint, a new row opening; methods offered at the start") {
        let b = try KitBench()
        let api = b.api("orders API", [])
        b.begin(api)
        let view = try require(b.view)
        expectEqual(view.focus, .waiting)
        expectEqual(view.stops, [.title, .fixed, .waiting], "the title, the server, the waiting line")
        b.type("PO")
        expectEqual(b.field.listedOffers.first, "POST", "the methods at a line's start")
        b.type("ST /orders (NewOrder) -> 201 Order")
        expectEqual(b.field.string, "POST /orders (NewOrder) → 201 Order", "-> is →")
        let chip = try require(b.field.highlights.first { $0.range == NSRange(location: 0, length: 4) }, "the method's chip")
        expect(chip.fill != .clear)
        let pills = b.field.highlights.filter(\.isDashed)
        expectEqual(pills.map(\.range), [NSRange(location: 14, length: 8), NSRange(location: 30, length: 5)], "a type named by nothing is a dashed pill")
        b.press(.return)
        expectEqual(b.undoName, "Add Endpoint")
        expectEqual(view.focus, .waiting, "a new row opens")
        b.type("POST /orders/{id}/refunds (NewRefund) -> 201 Refund")
        b.press(.return)
        expectEqual(b.undoName, "Add Endpoint")
        expectEqual(b.apiLines(api), ["POST /orders (NewOrder) → 201 Order", "POST /orders/{id}/refunds (NewRefund) → 201 Refund"])
        b.press(.up)
        expectEqual(view.focus, .row(b.rows(api)[1].id))
        expectEqual(b.field.accessibilityLabel(), "Endpoint 2 of 2")
        b.press(.escape)
        expectEqual(b.editor.editingShapeID, nil)
        b.editor.undo()
        expectEqual(b.apiLines(api), ["POST /orders (NewOrder) → 201 Order"], "each its own step")
    },
    test("E2 panel 1: post /orders/{id}/ref offers the refunds table, lit while highlighted, and the rest of another path; Tab takes refunds") {
        let b = try KitBench()
        let refunds = b.table("refunds", ["id uuid pk"], at: CGPoint(x: 700, y: 100))
        let api = b.api("orders API", ["GET /orders/{id}/refunds/{refundId}"])
        b.begin(api)
        b.type("post /orders/{id}/ref")
        expectEqual(b.field.listedOffers, ["refunds", "refunds/{refundId}"])
        expectEqual(b.field.listedDetails, ["table", "path"])
        expectEqual(b.editor.service(LineRowsService.self)?.light, PartAddress(refunds), "the table is lit")
        b.press(.tab)
        expectEqual(b.field.string, "post /orders/{id}/refunds")
        b.type(" (New")
        expectEqual(b.field.listedOffers, [], "no Types: no type notes and nothing to make them by")
        b.press(.escape)
    },
    test("E2 panel 4: four lines pasted are four rows, one step, Paste Endpoints; E2 panel 3's line keeps its row's id through a change") {
        let b = try KitBench()
        let api = b.api("orders API", ["GET /orders/{id}", "POST /orders", "POST /orders/{id}/refunds (NewRefund) → 201 Refund"])
        b.begin(api)
        let block = ["PATCH /orders/{id}", "POST /orders/{id}/cancel", "DELETE /orders/{id}/items/{itemId}", "GET /customers/{id}/orders"]
        b.field.paste(text: block.joined(separator: "\n"))
        expectEqual(b.apiLines(api).suffix(4), block[...])
        expectEqual(b.undoName, "Paste Endpoints")
        b.editor.undo()
        expectEqual(b.apiLines(api).count, 3, "one step")
    },
    test("headers: the rows under one indented, their full paths its; E5 panel 1, /orders retyped as /purchases, is one row's edit, Rename Path Prefix, and six full paths follow") {
        let b = try KitBench()
        let api = b.api("orders API", ["/orders", "GET /{id}", "POST /", "POST /{id}/refunds (NewRefund) → 201 Refund", "PATCH /{id}", "POST /{id}/cancel",
                                       "DELETE /{id}/items/{itemId}", "/customers", "GET /{id}/orders"])
        expectEqual(b.fullNames(api).prefix(2), ["GET /orders/{id}", "POST /orders"])
        let rows = b.rows(api)
        b.begin(api)
        expectEqual(b.view?.stops.prefix(3), [.title, .fixed, .row(rows[0].id)], "the title, the server, then the header")
        b.view?.go(to: .row(rows[0].id))
        expectEqual(b.field.string, "/orders")
        b.field.setSelectedRange(NSRange(location: 1, length: 6))
        b.type("purchases")
        b.press(.down)
        expectEqual(b.undoName, "Rename Path Prefix")
        expectEqual(b.fullNames(api), ["GET /purchases/{id}", "POST /purchases", "POST /purchases/{id}/refunds", "PATCH /purchases/{id}", "POST /purchases/{id}/cancel",
                                       "DELETE /purchases/{id}/items/{itemId}", "GET /customers/{id}/orders"])
        expectEqual(b.rows(api).map(\.id), rows.map(\.id), "every row keeps its id")
        let part = try require(b.editor.registry.parts(of: try require(b.editor.document[api]))?[3])
        expectEqual(part.name, "POST /purchases/{id}/refunds", "what pills, Find, the picker and agents name it by")
        // A member's field starts under its header's prefix, past the chevron.
        let header = try require(b.view?.rect(of: .row(rows[0].id))), member = try require(b.view?.rect(of: .row(rows[1].id)))
        expectEqual(header.minX, member.minX)
        b.press(.escape)
        b.editor.undo()
        expectEqual(b.fullNames(api).first, "GET /orders/{id}")
    },
    test("Change Method: a method retyped alone; a path changed, Change Endpoint; a header typed, Add Path Prefix") {
        let b = try KitBench()
        let api = b.api("orders API", ["PATCH /orders/{id}"])
        b.begin(api)
        b.press(.up)
        b.field.setSelectedRange(NSRange(location: 0, length: 5))
        b.type("PUT")
        b.press(.down)
        expectEqual(b.undoName, "Change Method")
        expectEqual(b.apiLines(api), ["PUT /orders/{id}"])
        b.type("/refunds")
        b.press(.return)
        expectEqual(b.undoName, "Add Path Prefix")
        b.press(.up)
        b.press(.up)
        b.field.setSelectedRange(NSRange(location: (b.field.string as NSString).length, length: 0))
        b.type("/x")
        b.press(.escape)
        expectEqual(b.undoName, "Change Endpoint")
    },
    test("the server line: ↑ from the first row, its placeholder faint while empty, typed it is Change Server; the schemes offered after the host; Return goes on to the empty row") {
        let b = try KitBench()
        let api = b.api("orders API", ["GET /orders"])
        b.begin(api)
        b.press(.up)
        b.press(.up)
        let view = try require(b.view)
        expectEqual(view.focus, .fixed)
        expectEqual(b.field.accessibilityLabel(), "Server")
        b.type("api.shop.dev/v1 be")
        expectEqual(b.field.listedOffers.first, "bearer")
        b.press(.tab)
        b.press(.return)
        expectEqual(b.editor.document[api]?.typed(as: API.self)?.props.server, APIServer(host: "api.shop.dev/v1", auth: "bearer"))
        expectEqual(b.undoName, "Change Server")
        expectEqual(view.focus, .waiting)
        // Left with the server's caret, the API draws its server again.
        b.press(.up)
        b.press(.up)
        let record = try require(b.editor.document[api])
        expectEqual(b.editor.shapeContext.layoutInput(LineRowsLayout.fixed, of: record), true, "the field draws it")
        b.press(.escape)
        expectEqual(b.editor.shapeContext.layoutInput(LineRowsLayout.fixed, of: try require(b.editor.document[api])), nil, "the API draws it again")
        b.editor.undo()
        expectEqual(b.editor.document[api]?.typed(as: API.self)?.props.server, APIServer())
    },
    test("an endpoint's card (⌘↓, and the › on its row): name, summary, auth, each parameter, body, its responses a line each, deprecated; a name typed is Change Endpoint, and a line's commit keeps what only the card says") {
        let b = try KitBench()
        let api = b.api("orders API", ["/orders", "POST /{id}/refunds (NewRefund) → 201 Refund"])
        b.begin(api)
        b.press(.up)
        b.press(Chord(Key.down, .command))
        let card = try require(b.canvas.cardView as? LineCardView)
        expectEqual(card.stopNames, ["name", "summary", "auth", "{id}", "body", "responses 1", "deprecated"])
        expectEqual(card.value(of: "body"), "→ NewRefund")
        expectEqual(card.value(of: "responses 1"), "201 → Refund")
        expectEqual(card.focusedStop, "name")
        b.type("createRefund")
        b.press(.tab)
        expectEqual(b.undoName, "Change Endpoint")
        expectEqual(b.rows(api)[1].endpoint?.name, "createRefund")
        b.type("Refund part or all of a paid order.")
        b.press(.escape)
        expectEqual(b.editor.editingShapeID, api, "Escape gives the row its keys back")
        // A line's commit keeps what only the card says.
        b.field.setSelectedRange(NSRange(location: (b.field.string as NSString).length, length: 0))
        b.type(" more")
        b.press(.escape)
        expectEqual(b.rows(api)[1].endpoint?.name, "createRefund")
        expectEqual(b.rows(api)[1].endpoint?.summary, "Refund part or all of a paid order.")
        // The › on the focused row opens it too.
        b.begin(api)
        b.press(.up)
        let view = try require(b.view)
        let row = try require(view.rect(of: view.focus))
        let point = view.convert(CGPoint(x: row.maxX - 20, y: row.midY), to: nil)
        let press = try require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: b.window.windowNumber,
                                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        view.mouseDown(with: press)
        b.window.settle()
        expect(b.canvas.cardView is LineCardView, "the › opens the row's card")
        expectEqual(view.accessibilityChildren()?.compactMap { ($0 as? NSAccessibilityElement)?.accessibilityLabel() }.contains("Show Details"), true)
    },
    test("an API at rest, light and dark: the paper, the server and its lock, chips in their methods' colors, a parameter in its chip's, a type named by nothing a dashed pill; skeleton bars") {
        let b = try KitBench()
        let api = b.api("orders API", ["GET /orders/{id}", "POST /orders (NewOrder) → 201 Order", "DELETE /orders/{id}"], server: APIServer(host: "api.shop.dev/v1", auth: "bearer"),
                        at: CGPoint(x: 40, y: 60))
        let frame = try require(b.editor.shapeContext.frame(of: try require(b.editor.document[api])))
        expectEqual(frame.height, APIRowsTest.height(lines: 3))
        for dark in [false, true] {
            let rep = render(b.editor, size: CGSize(width: 700, height: 300), dark: dark)
            expectColor(pixel(rep, at: CGPoint(x: frame.maxX - 6, y: frame.maxY - 6)), paper, "the paper, light in both")
            // The first row's chip: GET's green, dark enough for white text.
            let chip = pixel(rep, at: CGPoint(x: frame.minX + 16, y: frame.minY + 34 + 8 + 12))
            expect(chip[1] > chip[0] + 30 && chip[1] > chip[2], "GET's chip is green: \(chip)")
            let post = pixel(rep, at: CGPoint(x: frame.minX + 16, y: frame.minY + 34 + 8 + 36))
            expect(post[2] > post[0] + 60, "POST's chip is blue: \(post)")
            let delete = pixel(rep, at: CGPoint(x: frame.minX + 16, y: frame.minY + 34 + 8 + 60))
            expect(delete[0] > delete[1] + 60, "DELETE's chip is pink: \(delete)")
        }
        // Zoomed out: its paper and a bar a row, in the canvas's text-bar fill, where the chips are.
        b.editor.camera = Camera(origin: .zero, zoom: 0.3)
        let far = render(b.editor, size: CGSize(width: 700, height: 300))
        let bar = pixel(far, at: CGPoint(x: (frame.minX + 14 + 10) * 0.3, y: (frame.minY + 34 + 8 + 12) * 0.3))
        expect(bar != paper, "a row's bar over the paper: \(bar)")
    },
])

/// The API's height as its look says: its server's band, and its rows as a table's are.
@MainActor enum APIRowsTest {
    static func height(lines: Int) -> CGFloat { KitStyle.rowHeight + 10 + KitStyle.height(rows: lines) }
}

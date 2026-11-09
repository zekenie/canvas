import Adornments
import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
@_spi(Host) import CanvasUI
import Connections
import Engineering
import Find
import Geometry
import LineRows
import Selection
import ShippedTesting
import TestKit
import Titles

// Sixty endpoints, shipped (K17, E8): an orders API of sixty endpoints writing and reading three tables, grouped by prefix and
// folded by the keys (/group-by-prefix, ⌃⌘↑), its closed groups' arrows drawn as one with a count on each pill ("writes · 9"),
// selected whole and deleted with their name; → on /refunds opens its six rows, each with its own pill, fanning into refunds;
// ⌘F refunds stops on the /refunds header once for each of its endpoints and shows the /orders rows whose own path holds it;
// zoomed out, method bars in their colors. And what drew apart beside it: a writes and a reads from one row to one table, two
// keys into one row, a whole-table end clear of the keys at its side, a reads arrow kept inside its database.

/// The sixty endpoints, ungrouped, as E8's API holds them before Group by Prefix: seven prefixes (14, 9, 11, 8, 6, 4, 8).
let sixtyEndpoints: [String] = [
    "GET /orders", "POST /orders", "GET /orders/{id}", "PATCH /orders/{id}", "DELETE /orders/{id}", "POST /orders/{id}/cancel",
    "POST /orders/{id}/approve", "GET /orders/{id}/items", "POST /orders/{id}/items", "DELETE /orders/{id}/items/{itemId}",
    "POST /orders/{id}/refunds", "GET /orders/{id}/refunds", "PUT /orders/{id}/address", "POST /orders/{id}/ship",
    "GET /customers", "POST /customers", "GET /customers/{id}", "PATCH /customers/{id}", "DELETE /customers/{id}",
    "GET /customers/{id}/orders", "GET /customers/{id}/addresses", "POST /customers/{id}/addresses", "DELETE /customers/{id}/addresses/{addressId}",
    "GET /products", "POST /products", "GET /products/{id}", "PATCH /products/{id}", "DELETE /products/{id}", "GET /products/{id}/variants",
    "POST /products/{id}/variants", "GET /products/{id}/images", "POST /products/{id}/images", "DELETE /products/{id}/images/{imageId}", "GET /products/search",
    "GET /payments", "POST /payments", "GET /payments/{id}", "POST /payments/{id}/capture", "POST /payments/{id}/void", "POST /payments/{id}/settle",
    "PATCH /payments/{id}", "GET /payments/{id}/events",
    "GET /refunds", "GET /refunds/{id}", "POST /refunds", "POST /refunds/{id}/approve", "POST /refunds/{id}/cancel", "DELETE /refunds/{id}",
    "GET /webhooks", "POST /webhooks", "DELETE /webhooks/{id}", "POST /webhooks/{id}/test",
    "GET /admin/stats", "GET /admin/users", "POST /admin/users", "DELETE /admin/users/{id}", "GET /admin/audit", "POST /admin/reindex",
    "GET /admin/health", "PATCH /admin/settings",
]

/// What writes and reads which table: nine /orders rows write orders, five /payments rows write payments, four /refunds rows
/// write refunds and two read it.
let sixtyRelations: [(endpoint: String, table: String, channel: String)] =
    ["POST /orders", "PATCH /orders/{id}", "DELETE /orders/{id}", "POST /orders/{id}/cancel", "POST /orders/{id}/approve", "POST /orders/{id}/items",
     "DELETE /orders/{id}/items/{itemId}", "PUT /orders/{id}/address", "POST /orders/{id}/ship"].map { ($0, "orders", "writes") }
    + ["POST /payments", "POST /payments/{id}/capture", "POST /payments/{id}/void", "POST /payments/{id}/settle", "PATCH /payments/{id}"].map { ($0, "payments", "writes") }
    + ["POST /refunds", "POST /refunds/{id}/approve", "POST /refunds/{id}/cancel", "DELETE /refunds/{id}"].map { ($0, "refunds", "writes") }
    + ["GET /refunds", "GET /refunds/{id}"].map { ($0, "refunds", "reads") }

/// E8's board: the API, and orders, payments and refunds right of it, refunds keyed to payments.
let sixtyScript: String = {
    var lines = [
        #"api "orders API" server: "api.shop.dev/v1 bearer" endpoints: "\#(sixtyEndpoints.joined(separator: "\\n"))""#,
        #"table "orders" right of "orders API" (gap: 220) columns: "id uuid pk\ncustomer_id uuid\nstatus text\ntotal_cents int\nplaced_at timestamptz""#,
        #"table "payments" below "orders" (gap: 60) columns: "id uuid pk\norder_id uuid\namount_cents int\nstatus text\nprovider text\ncaptured_at timestamptz""#,
        #"table "refunds" below "payments" (gap: 60) columns: "id uuid pk\npayment_id uuid → payments.id\namount_cents int\nreason text?\ncreated_at timestamptz""#,
    ]
    for (endpoint, table, channel) in sixtyRelations { lines.append(#"edge "orders API"."\#(endpoint)" -> "\#(table)" channel: \#(channel)"#) }
    return lines.joined(separator: "\n")
}()

@MainActor private func sixtyAPI(_ editor: CanvasEditor) -> ShapeRecord<API>? {
    editor.document.shapes.first { $0[TitleProperty.self] == "orders API" }?.typed(as: API.self)
}

@MainActor private func sixtyArrows(_ editor: CanvasEditor) -> [ShapeRecord<Arrow>] { editor.document.shapes.compactMap { $0.typed(as: Arrow.self) } }

/// The pills shown on the board's arrows, by what they say.
@MainActor private func pills(_ editor: CanvasEditor) -> [String] {
    sixtyArrows(editor).flatMap { arrow in editor.adornmentFrames(of: arrow.id).compactMap(\.label.text) }.sorted()
}

extension EmptyBoardWindow {
    /// E8's board drawn, grouped by prefix with /group-by-prefix on the API (by the keys), then ⌃⌘↑ with nothing selected: every
    /// shape written as lines folded.
    func sixtyFolded() throws -> KeyWalk {
        try turnKitOn()
        try draw(sixtyScript)
        let walk = walk()
        editor.selectedShapeIDs = [try require(sixtyAPI(editor)).id]
        walk.press(Chord("/"))
        type("group-by-prefix", with: walk)
        walk.press(.return)
        expectEqual(undoTitle(window), "Undo Group by Prefix")
        editor.selectedShapeIDs = []
        walk.press(Chord(Key.up, [.control, .command]))
        window.settle()
        // The tables beside the folded API, top to bottom from its top, as E8 draws them (draw put them beside it unfolded).
        let api = try require(sixtyAPI(editor)), frame = try require(editor.shapeContext.frame(of: api.id))
        var y = frame.minY
        editor.transact("Move") { tx in
            for title in ["orders", "payments", "refunds"] {
                guard let table = editor.document.shapes.first(where: { $0[TitleProperty.self] == title }) else { continue }
                tx.update(table.id, as: DatabaseTable.self) { $0.props.frame.origin = CGPoint(x: frame.maxX + 220, y: y) }
                y += (table.box?.height ?? 160) + 60
            }
        }
        editor.undoHistory.seal()
        window.settle()
        return walk
    }
}

@MainActor let sixtyEndpointsShippedTests = Suite("Sixty endpoints, shipped", [
    test("E8 panel 1 by the keys: /group-by-prefix makes seven groups, ⌃⌘↑ closes each with its count; each closed group's arrows to a table draw as one, its pill counting them") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        _ = try w.sixtyFolded()
        let editor = w.editor
        let orders = try require(sixtyAPI(editor))
        let headers = orders.props.endpoints.compactMap(\.header)
        expectEqual(headers.map(\.prefix), ["/orders", "/customers", "/products", "/payments", "/refunds", "/webhooks", "/admin"])
        let shown = try require(editor.shapeContext.layoutInput(LineRowsLayout.shown, of: orders))
        expectEqual(shown.count, 7, "seven closed headers, nothing else")
        let hiding = shown.lines.compactMap { if case .header(_, let hiding) = $0 { hiding } else { nil } }
        expectEqual(hiding, [14, 9, 11, 8, 6, 4, 8])
        expectEqual(pills(editor), ["reads · 2", "writes · 4", "writes · 5", "writes · 9"], "one pill a bundle, counting it")
        let arrows = sixtyArrows(editor)
        let hidden = arrows.filter { editor.shapeContext.geometry(of: $0.id)?.isHidden == true }
        expectEqual(hidden.count, 20 - 4, "every arrow but the four leads drawn by its lead")
        let leads = arrows.filter { if case .lead? = editor.connectionBundle(of: $0.id)?.role { true } else { false } }
        expectEqual(leads.count, 4)
        // /refunds' writes and reads share both ends: bowed a slot apart.
        let refundsLeads = leads.filter { editor.connectionBundle(of: $0.id)?.slots == 2 }
        expectEqual(refundsLeads.count, 2, "writes · 4 and reads · 2 drawn apart")
        let said = leads.compactMap { editor.accessibleDescription(of: $0.id)?.label }.sorted()
        expect(said.contains { $0.hasPrefix("9 arrows, from /orders in orders API to orders") }, "the lead speaks for nine: \(said)")
        // A press on a bundle's line selects all nine; Delete takes them and says so.
        let nine = try require(leads.first { editor.connectionBundle(of: $0.id)?.count == 9 })
        let line = try require(editor.shapeContext.geometry(of: nine.id))
        let point = line.outline[1]
        editor.selectedShapeIDs = []
        w.mouseClick(at: point)
        expectEqual(Set(editor.selectedShapeIDs).count, 9, "the bundle whole")
        let walk = w.walk()
        walk.press(.delete)
        expectEqual(undoTitle(w.window), "Undo Delete 9 Arrows")
        expectEqual(sixtyArrows(editor).count, 12, "the other bundles' eleven and refunds' key")
        (w.window as! BoardWindow).undo(nil)
        w.window.settle()
        expectEqual(pills(editor), ["reads · 2", "writes · 4", "writes · 5", "writes · 9"], "back as they were")
    },
    test("E8 panel 2: ↓ to /refunds and → opens its six rows, each with its own pill, fanning into refunds; ← closes it again, its bundles back") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let walk = try w.sixtyFolded()
        let editor = w.editor
        let orders = try require(sixtyAPI(editor))
        let rows = orders.props.endpoints
        let refunds = try require(rows.firstIndex { $0.header?.prefix == "/refunds" })
        // The first header selected as the API's item (a click on a closed header opens it: its face), then ↓ to /refunds.
        editor.selectedShapeIDs = [orders.id]
        editor.selectItems([AnyHashable(rows[0].id)], of: orders.id)
        for _ in 0..<4 { walk.press(.down) }
        expectEqual(editor.selectedItems?.ids, [AnyHashable(rows[refunds].id)], "/refunds")
        walk.press(.right)
        expectEqual(pills(editor), ["reads", "reads", "writes", "writes", "writes", "writes", "writes · 5", "writes · 9"], "six rows, each its own pill")
        let six = sixtyArrows(editor).filter { arrow in rows[(refunds + 1)...(refunds + 6)].contains { $0.id == arrow.props.start.binding?.part } }
        expectEqual(six.count, 6)
        for arrow in six {
            let fan = try require(editor.connectionBundle(of: arrow.id)?.fan(at: .end), "fanned into refunds")
            expectEqual(fan.count, 6)
        }
        let ends = try six.map { try require(editor.arrowGeometry(of: $0.id)?.endHandle) }
        expect(Set(ends.map { "\($0)" }).count == 1, "into one point: \(ends)")
        // Each pill by its row: nearer its start than its end.
        for arrow in six {
            let geometry = try require(editor.arrowGeometry(of: arrow.id)), label = try require(editor.arrowLabelFrame(of: arrow.id))
            let middle = CGPoint(x: label.midX, y: label.midY)
            expect(middle.distance(to: geometry.start) < middle.distance(to: geometry.end), "slid to its start")
        }
        walk.press(.left)
        expectEqual(pills(editor), ["reads · 2", "writes · 4", "writes · 5", "writes · 9"], "closed again, bundled again")
    },
    test("E8 panel 3: ⌘F refunds stops on the /refunds header once for each of its six endpoints, lit there, the group closed; the /orders rows holding it show") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        _ = try w.sixtyFolded()
        let editor = w.editor
        let orders = try require(sixtyAPI(editor))
        let find = try require(editor.find)
        find.open()
        find.query = "refunds"
        var turns = 0
        while find.isIndexing, turns < 10_000 {
            w.window.settle()
            turns += 1
        }
        _ = try awaitResult { await find.settled() }
        w.window.settle()
        let texts = find.texts(of: orders.id)
        expect(texts.contains("POST /orders/{id}/refunds") && texts.contains("GET /refunds/{id}"), "an endpoint's method and full path")
        let ranges = find.rangesHit(of: orders.id)
        expectEqual(ranges.values.reduce(0) { $0 + $1.count }, 8, "two in /orders' own paths, and once for each of /refunds' six")
        let shown = try require(editor.shapeContext.layoutInput(LineRowsLayout.shown, of: orders))
        let rows = orders.props.endpoints
        let peeked = shown.lines.compactMap { line -> String? in
            if case .row(let index) = line, rows[index].header == nil { EndpointGrammar.print(rows[index]) } else { nil }
        }
        expectEqual(peeked, ["POST /{id}/refunds", "GET /{id}/refunds"], "the /orders rows whose own path holds it show")
        let refunds = try require(rows.firstIndex { $0.header?.prefix == "/refunds" })
        expect(shown.lines.contains { if case .header(refunds, _) = $0 { true } else { false } }, "/refunds stays closed")
        // A /refunds hit is drawn on its header.
        let header = try require(editor.shapeContext.geometry(of: orders.id)?.parts.frame(rows[refunds].id)?.rect)
        let members = rows[(refunds + 1)...(refunds + 6)]
        var lit = 0
        for row in members {
            let text = try require(texts.firstIndex(of: APIGroups.fullName(ofRow: row.id, in: rows) ?? ""))
            for range in ranges[row.id.description] ?? [] {
                let rects = find.rects(of: FindHit(text: text, range: range, isExact: true), in: orders.id)
                expect(!rects.isEmpty && rects.allSatisfy { header.insetBy(dx: 0, dy: -1).intersects($0) }, "lit on the header: \(rects) against \(header)")
                lit += 1
            }
        }
        expectEqual(lit, 6, "once for each of /refunds' endpoints")
        find.close()
        w.window.settle()
        expect(editor.shapeContext.layoutInput(LineRowsLayout.shown, of: orders)?.count == 7, "Find closed: folded as it was")
    },
    test("E8 panel 4: zoomed out to 30%, method bars in their chips' colors; under 12%, the paper alone") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        try w.turnKitOn()
        try w.draw(sixtyScript)
        let editor = w.editor
        let orders = try require(sixtyAPI(editor))
        let frame = try require(editor.shapeContext.frame(of: orders.id))
        editor.camera = Camera(origin: CGPoint(x: frame.minX - 40, y: frame.minY - 40), zoom: 0.3)
        let rep = renderBitmap(editor, size: CGSize(width: 600, height: 600))
        // GET's green and POST's blue somewhere on the API's left, where the chips are.
        var colors = Set<String>()
        for y in stride(from: 12.0, through: min(590, (frame.height + 40) * 0.3), by: 1) {
            let p = pixel(rep, at: CGPoint(x: (40 + 14 + 6) * 0.3, y: y))
            if p[1] > p[0] + 40, p[1] > p[2] { colors.insert("green") }
            if p[2] > p[0] + 60, p[2] > p[1] + 20 { colors.insert("blue") }
        }
        expect(colors.contains("green") && colors.contains("blue"), "method bars in their colors: \(colors)")
        editor.camera = Camera(origin: CGPoint(x: frame.minX - 40, y: frame.minY - 40), zoom: 0.1)
        let far = renderBitmap(editor, size: CGSize(width: 600, height: 600))
        var colored = 0
        for y in stride(from: 4.0, through: min(590, (frame.height + 40) * 0.1), by: 1) {
            let p = pixel(far, at: CGPoint(x: (40 + 14 + 6) * 0.1, y: y))
            if abs(p[0] - p[1]) > 30 || abs(p[1] - p[2]) > 30 { colored += 1 }
        }
        expectEqual(colored, 0, "at 10%, no bars: the paper says it")
    },
    test("a writes and a reads from one row to one table bow apart, each its own pill; two keys into one row meet it apart") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        try w.turnKitOn()
        try w.draw(#"""
            api "orders API" endpoints: "POST /orders/{id}/refunds"
            table "refunds" right of "orders API" (gap: 220) columns: "id uuid pk\namount_cents int"
            edge "orders API"."POST /orders/{id}/refunds" -> "refunds" channel: writes
            table "customers" below "orders API" (gap: 80) columns: "id uuid pk\nemail text"
            table "orders" right of "customers" (gap: 220) columns: "id uuid pk\nbilling_customer_id uuid → customers.id\nshipping_customer_id uuid → customers.id"
            """#)
        let editor = w.editor
        // The reads beside it, as a second connection between the same row and table is made: ⌘L's pick.
        let api = try require(sixtyAPI(editor)), table = try require(editor.document.shapes.first { $0[TitleProperty.self] == "refunds" })
        w.canvas.menuPresenter = { _, _, _ in }
        let made = try require(editor.connect(ConnectEnd(api.id, part: api.props.endpoints[0].id), to: ConnectEnd(table.id)))
        expect(editor.setChannel(Reads.id, of: made))
        w.window.settle()
        let arrows = sixtyArrows(editor)
        let relations = arrows.filter { [Writes.id, Reads.id].contains($0[ChannelProperty.self]) }
        expectEqual(relations.count, 2)
        let middles = try relations.map { try require(editor.arrowGeometry(of: $0.id)).middle }
        expect(middles[0].distance(to: middles[1]) > 20, "bowed apart: \(middles)")
        let labels = try relations.map { try require(editor.arrowLabelFrame(of: $0.id)) }
        expect(!labels[0].intersects(labels[1]), "each pill on its own line: \(labels)")
        let keys = arrows.filter { $0[ChannelProperty.self] == ForeignKey.id }
        expectEqual(keys.count, 2)
        let keyEnds = try keys.map { try require(editor.arrowGeometry(of: $0.id)).endHandle }
        expect(abs(keyEnds[0].y - keyEnds[1].y) >= 6, "they meet the row apart: \(keyEnds)")
        let ways = try keys.map { try require(editor.arrowGeometry(of: $0.id)).inward(at: .end) }
        expect(abs(ways[0].y - ways[1].y) > 0.2, "and come in at angles of their own: \(ways)")
    },
    test("a line to a table as a whole comes in at a row clear of the key ending at its side; a reads arrow at a database's left inset stays inside it") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        try w.turnKitOn()
        try w.draw(#"database "shop" size: 1100x800"#)
        try w.draw(#"""
            table "orders" in "shop" columns: "id uuid pk\ntotal_cents int"
            table "refunds" in "shop" right of "orders" (gap: 140) columns: "id uuid pk\norder_id uuid → orders.id\namount_cents int"
            api "orders API" in "shop" below "orders" (gap: 160) endpoints: "/orders\nGET /orders/{id}\nPOST /orders/{id}/refunds"
            edge "orders API"."GET /orders/{id}" -> "orders" channel: reads
            edge "orders API"."POST /orders/{id}/refunds" -> "refunds" channel: writes
            """#)
        let editor = w.editor
        let arrows = sixtyArrows(editor)
        let writes = try require(arrows.first { $0[ChannelProperty.self] == Writes.id })
        let refunds = try require(editor.document.shapes.first { $0[TitleProperty.self] == "refunds" }?.typed(as: DatabaseTable.self))
        let entry = try require(editor.connectionBundle(of: writes.id)?.entries[.end], "a row it comes in at")
        expect(entry != refunds.props.columns[1].id, "not the key's row")
        expect(entry != refunds.props.columns[0].id, "nor the row beside it, where the key's foot is: \(entry)")
        let reads = try require(arrows.first { $0[ChannelProperty.self] == Reads.id })
        let shop = try require(editor.document.shapes.first { $0[TitleProperty.self] == "shop" })
        let database = try require(editor.shapeContext.geometry(of: shop.id)?.bounds)
        let curve = try require(editor.arrowGeometry(of: reads.id)?.levelBody)
        let reach = (0...40).map { curve.point(at: CGFloat($0) / 40).x }.min() ?? 0
        expect(reach > database.minX + 4, "the reads arrow stays inside the database: \(reach) against \(database.minX)")
        let rep = renderBitmap(editor, size: CGSize(width: 900, height: 700))
        _ = rep
    },
])

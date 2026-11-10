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

/// Whether the bitmap has ink (a dark stroke) within two pixels of a world point, as the camera it was drawn through puts it.
@MainActor private func hasInk(_ rep: NSBitmapImageRep, at world: CGPoint, camera: Camera) -> Bool {
    let view = camera.toView(world)
    for dx in -2...2 {
        for dy in -2...2 {
            let p = pixel(rep, at: CGPoint(x: view.x + CGFloat(dx), y: view.y + CGFloat(dy)))
            if p[0] < 100, p[1] < 100, p[2] < 100 { return true }
        }
    }
    return false
}

/// The board drawn at 100% from its shapes' top-left, as a bitmap, with the camera it was drawn through left on the editor.
@MainActor private func renderAll(_ editor: CanvasEditor) -> NSBitmapImageRep {
    let frames = editor.document.shapes.compactMap { $0.box == nil ? nil : editor.shapeContext.frame(of: $0) }
    let box = frames.dropFirst().reduce(frames[0]) { $0.union($1) }
    editor.camera = Camera(origin: CGPoint(x: box.minX - 40, y: box.minY - 40), zoom: 1)
    return renderBitmap(editor, size: CGSize(width: box.width + 80, height: box.height + 80))
}

@MainActor private func sixtyArrows(_ editor: CanvasEditor) -> [ShapeRecord<Arrow>] { editor.document.shapes.compactMap { $0.typed(as: Arrow.self) } }

/// The pills shown on the board's arrows, by what they say.
@MainActor private func pills(_ editor: CanvasEditor) -> [String] {
    sixtyArrows(editor).flatMap { arrow in editor.adornmentFrames(of: arrow.id).compactMap(\.label.text) }.sorted()
}

extension EmptyBoardWindow {
    /// E8's board drawn, grouped by prefix with /group-by-prefix on the API (by the keys), then ⌃⌘↑ with nothing selected: every
    /// shape written as lines folded. `more`: lines drawn with it.
    func sixtyFolded(more: String = "") throws -> KeyWalk {
        try turnKitOn()
        try draw(more.isEmpty ? sixtyScript : sixtyScript + "\n" + more)
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
        // Drawn: each lead's line is inked, near its start and its end.
        editor.selectedShapeIDs = []
        let rep = renderAll(editor)
        for arrow in arrows where editor.connectionBundle(of: arrow.id)?.count ?? 1 > 1 {
            let body = try require(editor.arrowGeometry(of: arrow.id)?.levelBody)
            for t in [0.15, 0.85] as [CGFloat] { expect(hasInk(rep, at: body.point(at: t), camera: editor.camera), "a lead's line is drawn at \(t)") }
        }
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
        // Drawn: each of the six lines is inked and a few points from the others well along it (its pill is by its start).
        let rep = renderAll(editor)
        let bodies = try six.map { try require(editor.arrowGeometry(of: $0.id)?.levelBody) }
        for (index, body) in bodies.enumerated() {
            expect(hasInk(rep, at: body.point(at: 0.6), camera: editor.camera), "fanned line \(index) is drawn")
            let near = body.point(at: 0.1)
            expect(bodies.enumerated().allSatisfy { $0.offset == index || $0.element.distance(to: near) > 5 }, "and apart from the other five leaving its row: \(index)")
        }
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
        // Drawn: Find's orange on the header's line.
        let rep = renderAll(editor)
        let view = editor.camera.toView(header.origin)
        var orange = 0
        for y in stride(from: view.y, through: view.y + header.height * editor.camera.zoom, by: 1) {
            for x in stride(from: view.x, through: view.x + header.width * editor.camera.zoom, by: 1) {
                let p = pixel(rep, at: CGPoint(x: x, y: y))
                if p[0] > 200, p[1] > 100, p[1] < 210, p[2] < 120 { orange += 1 }
            }
        }
        expect(orange > 20, "the hits are orange on the header: \(orange) pixels")
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
        // The title bars stay: a table of usual width is 25 points across at 10%, and has its bar.
        for title in ["orders", "payments", "refunds"] {
            let table = try require(editor.document.shapes.first { $0[TitleProperty.self] == title })
            let at = editor.camera.toView(try require(editor.shapeContext.frame(of: table.id)).origin)
            var dark = 0
            for y in stride(from: at.y - 9, to: at.y, by: 1) {
                for x in stride(from: at.x, to: at.x + 24, by: 1) {
                    let p = pixel(far, at: CGPoint(x: x, y: y))
                    if p[0] < 150, p[1] < 150, p[2] < 150 { dark += 1 }
                }
            }
            expect(dark >= 4, "\(title)'s title bar is drawn at 10%: \(dark) dark pixels above its corner")
        }
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
        // Level where their bars are (UX walk 3 tables-2), and their bars never on each other (UX walk 4 tables-2): a bar's height
        // and a gap apart, or one's marks a stub further out.
        let keyGeometries = try keys.map { try require(editor.arrowGeometry(of: $0.id)) }
        let ways = keyGeometries.map { $0.inward(at: .end) }
        expect(ways.allSatisfy { abs($0.y) < 1e-6 }, "their bars level: \(ways)")
        let bars = keyGeometries.map { geometry in [12, 17.5].map { geometry.point($0 + geometry.markOffset.end, along: .end).point } }
        for p in bars[0] { for q in bars[1] where abs(p.x - q.x) < 4 { expect(abs(p.y - q.y) > 18 + 2.5, "no bars on each other: \(bars)") } }
        // Drawn: each of the four lines is its own stroke of ink, and nothing else is inked a few points beside it.
        let everything = try relations.map { try require(editor.arrowGeometry(of: $0.id)) } + keys.map { try require(editor.arrowGeometry(of: $0.id)) }
        let bounds = try everything.map { try require($0.levelBody).bounds }.reduce(CGRect.null) { $0.union($1) }
        editor.camera = Camera(origin: CGPoint(x: bounds.minX - 60, y: bounds.minY - 60), zoom: 1)
        let rep = renderBitmap(editor, size: CGSize(width: bounds.width + 120, height: bounds.height + 120))
        for (index, geometry) in everything.enumerated() {
            let body = try require(geometry.levelBody)
            let others = everything.enumerated().filter { $0.offset != index }.compactMap { $0.element.levelBody }
            for t in [0.2, 0.8] as [CGFloat] {
                let point = body.point(at: t)
                expect(hasInk(rep, at: point, camera: editor.camera), "line \(index) is drawn at \(t)")
                expect(others.allSatisfy { $0.distance(to: point) > 6 }, "and clear of the others there: line \(index) at \(t)")
            }
        }
    },
    test("a bundle's member never holds the selection alone: picked in the table of contents, or bundled under a selected arrow by a fold, its bundle is selected whole") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        _ = try w.sixtyFolded()
        let editor = w.editor
        let arrows = sixtyArrows(editor)
        let member = try require(arrows.first { editor.connectionBundle(of: $0.id)?.lead != nil && editor.connectionBundle(of: $0.id)?.lead == editor.connectionBundle(of: $0.id)?.lead })
        let leadID = try require(editor.connectionBundle(of: member.id)?.lead)
        let count = try require(editor.connectionBundle(of: leadID)?.count)
        // A pick of a member, as the table of contents makes it, selects what the canvas shows: its lead, and every arrow it draws for.
        editor.selectedShapeIDs = [member.id]
        expectEqual(editor.selectedShapeIDs.count, count, "the bundle whole")
        expect(editor.selectedShapeIDs.contains(leadID), "with its lead")
        expect(editor.accessibleShapes(limit: 500).contains(leadID), "which VoiceOver has an element for")
        editor.selectedShapeIDs = []
        // /refunds opened, one of its writes selected, the header closed again: the arrow is a member now.
        let orders = try require(sixtyAPI(editor))
        let rows = orders.props.endpoints
        let header = try require(rows.first { $0.header?.prefix == "/refunds" })
        let folds = try require(editor.rowFolds)
        folds.setClosed(false, header: header.id, of: orders.id)
        w.window.settle()
        let last = try require(arrows.first { $0.props.start.binding?.part == rows.first { $0.id != header.id && EndpointGrammar.print($0).hasPrefix("DELETE") && APIGroups.fullName(ofRow: $0.id, in: rows) == "DELETE /refunds/{id}" }?.id })
        expectEqual(editor.connectionBundle(of: last.id)?.role, ConnectionBundle.Role.alone, "its own line while its group is open")
        editor.selectedShapeIDs = [last.id]
        expectEqual(editor.selectedShapeIDs, [last.id])
        folds.setClosed(true, header: header.id, of: orders.id)
        w.window.settle()
        expectEqual(editor.selectedShapeIDs.count, 4, "closed over it: selected with the four writes it is bundled with")
        let lead = try require(editor.connectionBundle(of: last.id)?.lead ?? (editor.connectionBundle(of: last.id)?.count != nil ? last.id : nil))
        expect(editor.selectedShapeIDs.contains(lead))
        // Delete says what it takes.
        let walk = w.walk()
        walk.press(.delete)
        expectEqual(undoTitle(w.window), "Undo Delete 4 Arrows")
    },
    test("⌥Tab lists a bundle's lead as the arrows it draws for, from the shape that is folded and from the table: named by the closed header's line") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        _ = try w.sixtyFolded()
        let editor = w.editor
        let orders = try require(sixtyAPI(editor))
        let fromAPI = editor.shapeParts(of: orders.id).filter { $0.role == .connection }.map(\.title)
        expect(fromAPI.contains("9 arrows to orders"), "\(fromAPI)")
        expect(fromAPI.contains("5 arrows to payments") && fromAPI.contains("4 arrows to refunds") && fromAPI.contains("2 arrows to refunds"), "\(fromAPI)")
        let table = try require(editor.document.shapes.first { $0[TitleProperty.self] == "orders" })
        let fromTable = editor.shapeParts(of: table.id).filter { $0.role == .connection }.map(\.title)
        expect(fromTable.contains("9 arrows from /orders in orders API"), "the header's line, not the lead's own hidden row: \(fromTable)")
    },
    test("bending a slotted arrow keeps its bow while the step is open: the line drawn mid-step is the one drawn once it commits, never the unbowed path") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        try w.turnKitOn()
        try w.draw(#"""
            api "orders API" endpoints: "POST /orders/{id}/refunds"
            table "refunds" right of "orders API" (gap: 220) columns: "id uuid pk\namount_cents int"
            edge "orders API"."POST /orders/{id}/refunds" -> "refunds" channel: writes
            """#)
        let editor = w.editor
        let api = try require(sixtyAPI(editor)), table = try require(editor.document.shapes.first { $0[TitleProperty.self] == "refunds" })
        w.canvas.menuPresenter = { _, _, _ in }
        let made = try require(editor.connect(ConnectEnd(api.id, part: api.props.endpoints[0].id), to: ConnectEnd(table.id)))
        expect(editor.setChannel(Reads.id, of: made))
        w.window.settle()
        expectEqual(editor.connectionBundle(of: made)?.slots, 2)
        let before = try require(editor.arrowGeometry(of: made)).middle
        // What a bend's drag writes, one step at a time: the line drawn in the open step.
        var mid: CGPoint?
        editor.transact("Bend Arrow") { tx in
            tx.update(made, as: Arrow.self) { $0.props.bend = 24 }
            mid = tx.shapes.geometry(of: made)?.outline.dropFirst().first
        }
        let after = try require(editor.arrowGeometry(of: made)).middle
        expect(after.distance(to: before) > 10, "the bend moved it: \(before) to \(after)")
        expect((mid ?? .zero).distance(to: after) < 0.5, "drawn in the open step as it is once committed: \(String(describing: mid)) against \(after)")
        // Re-aimed in an open step, its line is drawn as ever until the commit (its answer was for other ends).
        var reaimed: CGPoint?
        editor.transact("Move Arrow End") { tx in
            tx.update(made, as: Arrow.self) { $0.props.end = .free(CGPoint(x: after.x + 300, y: after.y + 300)) }
            reaimed = tx.shapes.geometry(of: made)?.outline.dropFirst().first
        }
        expect(reaimed != nil)
    },
    test("bundles are worked out on a board that isn't shown, and a prefix-only Find hit leaves a closed group closed there") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        try w.turnKitOn()
        try w.draw(#"subboard "sub""#)
        try w.draw(#"""
            api "A" in "sub" endpoints: "POST /orders/a\nPOST /orders/b\nPOST /orders/c\nGET /other"
            table "T" in "sub" right of "A" (gap: 200) columns: "id uuid pk\nn int"
            edge "A"."POST /orders/a" -> "T" channel: writes
            edge "A"."POST /orders/b" -> "T" channel: writes
            edge "A"."POST /orders/c" -> "T" channel: writes
            """#)
        let editor = w.editor
        let sub = BoardID(owner: try require(editor.document.shapes.first { $0[TitleProperty.self] == "sub" }).id)
        expect(editor.showBoard(sub))
        w.window.settle()
        let api = try require(sixtyAPIAny(editor, "A"))
        // Grouped by its prefix (the keys), then folded as far as it goes, on the board shown.
        let walk = w.walk()
        editor.selectedShapeIDs = [api.id]
        walk.press(Chord("/"))
        w.type("group-by-prefix", with: walk)
        walk.press(.return)
        editor.selectedShapeIDs = [api.id]
        walk.press(Chord(Key.up, [.control, .command]))
        w.window.settle()
        let leads = sixtyArrows(editor).filter { if case .lead? = editor.connectionBundle(of: $0.id)?.role { true } else { false } }
        expectEqual(leads.count, 1, "on the board shown: one lead for the three writes")
        // Left for the root: the board it was read on is no longer the one shown.
        expect(editor.showBoard(.root))
        w.window.settle()
        let arrows = editor.file[sub].shapes.compactMap { $0.typed(as: Arrow.self) }
        expectEqual(arrows.count, 3)
        let roles = arrows.map { editor.connectionBundle(of: $0.id)?.role }
        expectEqual(roles.filter { if case .lead(3, _)? = $0 { true } else { false } }.count, 1, "one lead of three, as on its own board: \(roles)")
        expectEqual(roles.filter { if case .member? = $0 { true } else { false } }.count, 2, "and two members")
        // Find from the root, a word only in the group's prefix: the group stays closed.
        let find = try require(editor.find)
        find.open()
        find.query = "orders"
        var turns = 0
        while find.isIndexing, turns < 10_000 {
            w.window.settle()
            turns += 1
        }
        _ = try awaitResult { await find.settled() }
        w.window.settle()
        expect(find.hasHits(api.id), "found in the API on the board under")
        expect(try require(editor.rowFolds).findPeeks(of: api.id).isEmpty, "a hit in the prefix alone leaves the group closed: \(editor.rowFolds?.findPeeks(of: api.id) ?? [])")
        find.close()
    },
    test("a call and its callback between two endpoints draw as two lines, bowed apart, not one line with a head at each end (review R23)") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        try w.turnKitOn()
        try w.draw(#"""
            api "shop API" endpoints: "POST /pay\nPOST /paid"
            api "bank API" right of "shop API" (gap: 260) endpoints: "POST /charge\nPOST /hook"
            edge "shop API"."POST /pay" -> "bank API"."POST /charge" channel: calls
            edge "bank API"."POST /charge" -> "shop API"."POST /pay" channel: calls
            """#)
        let editor = w.editor
        let arrows = sixtyArrows(editor)
        expectEqual(arrows.count, 2)
        let bodies = try arrows.map { try require(editor.arrowGeometry(of: $0.id)?.levelBody) }
        let middles = bodies.map { $0.measured().point(atFraction: 0.5) }
        expect(middles[0].distance(to: middles[1]) >= 20, "bowed apart at their middles: \(middles)")
    },
    test("one row's writes and reads to two tables, each fanned at its table, keep their pills apart rather than stacked at the row (UX walk 3 evolve-5)") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        try w.turnKitOn()
        try w.draw(#"""
            table "orders" columns: "id uuid pk\ntotal_cents int"
            table "payments" below "orders" (gap: 120) columns: "id uuid pk\namount_cents int"
            api "orders API" left of "orders" (gap: 300) endpoints: "POST /a\nPOST /b\nPOST /c"
            edge "orders API"."POST /a" -> "orders" channel: writes
            edge "orders API"."POST /b" -> "orders" channel: writes
            edge "orders API"."POST /a" -> "payments" channel: reads
            edge "orders API"."POST /c" -> "payments" channel: reads
            """#)
        let editor = w.editor
        w.window.settle()
        let api = try require(sixtyAPIAny(editor, "orders API"))
        let fromA = sixtyArrows(editor).filter { $0.props.start.binding?.part == api.props.endpoints[0].id }
        expectEqual(fromA.count, 2)
        let pills = try fromA.map { arrow in try require(editor.shapeContext.geometry(of: arrow.id)?.labelLead, "a pill on \(arrow[ChannelProperty.self] ?? "?")") }
        expect(!pills[0].intersects(pills[1]), "the writes and reads pills apart: \(pills)")
    },
    test("UX walk 4 evolve-1: one row's writes and reads to two tables stack their pills in the row's own band, never beside another row's") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        try w.turnKitOn()
        // Far below, as E8's payments is: a pill moved out along a line that falls to it would land beside the rows below.
        try w.draw(#"""
            table "orders" columns: "id uuid pk\ntotal_cents int"
            table "payments" below "orders" (gap: 400) columns: "id uuid pk\namount_cents int"
            api "orders API" left of "orders" (gap: 300) endpoints: "POST /a\nPOST /b\nPOST /c\nPOST /d"
            edge "orders API"."POST /a" -> "orders" channel: writes
            edge "orders API"."POST /b" -> "orders" channel: writes
            edge "orders API"."POST /c" -> "orders" channel: writes
            edge "orders API"."POST /a" -> "payments" channel: reads
            edge "orders API"."POST /d" -> "payments" channel: reads
            """#)
        let editor = w.editor
        w.window.settle()
        let api = try require(sixtyAPIAny(editor, "orders API"))
        let row = try require(editor.shapeContext.geometry(of: api.id)?.parts.frame(api.props.endpoints[0].id)?.rect)
        let arrows = sixtyArrows(editor)
        let fromA = arrows.filter { $0.props.start.binding?.part == api.props.endpoints[0].id }
        expectEqual(fromA.count, 2)
        let pills = try fromA.map { try require(editor.shapeContext.geometry(of: $0.id)?.labelLead) }
        expect(!pills[0].intersects(pills[1]), "apart: \(pills)")
        for pill in pills { expect(pill.midY > row.minY && pill.midY < row.maxY, "level with POST /a (\(row.minY) to \(row.maxY)): \(pill)") }
        let others = try arrows.filter { !fromA.map(\.id).contains($0.id) }.map { try require(editor.shapeContext.geometry(of: $0.id)?.labelLead) }
        for pill in pills { expect(others.allSatisfy { !$0.intersects(pill) }, "clear of the other rows' pills: \(pill) among \(others)") }
        // The reads, whose table is farther from the row, nearest it; each line leaves the row on its own, top to bottom as they go.
        let reads = try require(fromA.firstIndex { $0[ChannelProperty.self] == Reads.id })
        expect(pills[reads].midX < pills[1 - reads].midX, "the reads nearest the row: \(pills)")
        let starts = try fromA.map { try require(editor.arrowGeometry(of: $0.id)).start.y }
        // As far apart as keeps each pill inside the row (24 tall, its pills 18): 6.
        expect(starts[reads] > starts[1 - reads] + 5, "the reads leaves below the writes: \(starts)")
    },
    test("UX walk 4 evolve-1, folded: a closed header's lone reads keeps its pill at the header's line, clear of the bundles' pills") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        _ = try w.sixtyFolded(more: #"edge "orders API"."POST /orders" -> "payments" channel: reads"#)
        let editor = w.editor
        let api = try require(sixtyAPI(editor))
        let header = try require(api.props.endpoints.first { $0.header?.prefix == "/orders" })
        let line = try require(editor.shapeContext.geometry(of: api.id)?.parts.frame(header.id)?.rect)
        let arrows = sixtyArrows(editor).filter { editor.shapeContext.geometry(of: $0.id)?.isHidden != true }
        let lone = try require(arrows.first { $0[ChannelProperty.self] == Reads.id && editor.connectionBundle(of: $0.id)?.count == 1 })
        let pill = try require(editor.shapeContext.geometry(of: lone.id)?.labelLead)
        expect(pill.midY > line.minY && pill.midY < line.maxY, "level with /orders (\(line.minY) to \(line.maxY)): \(pill)")
        let others = arrows.filter { $0.id != lone.id }.compactMap { editor.shapeContext.geometry(of: $0.id)?.labelLead }
        expect(others.allSatisfy { !$0.intersects(pill.insetBy(dx: -2, dy: -2)) }, "on no bundle's pill: \(pill) among \(others)")
    },
    test("UX walk 3 connect-4: a row's pill laid along its line keeps clear of the other lines leaving the row, its lit ring too") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        try w.turnKitOn()
        try w.draw(#"""
            api "orders API" endpoints: "GET /orders/{id}\nPOST /orders/{id}/refunds"
            table "refunds" right of "orders API" (gap: 300) columns: "id uuid pk\namount_cents int"
            table "payments" below "refunds" (gap: 80) columns: "id uuid pk\namount_cents int"
            api "Stripe API" below "orders API" (gap: 420) endpoints: "POST /v1/refunds"
            edge "orders API"."POST /orders/{id}/refunds" -> "refunds" channel: writes
            edge "orders API"."POST /orders/{id}/refunds" -> "payments" channel: reads
            edge "orders API"."POST /orders/{id}/refunds" -> "Stripe API"."POST /v1/refunds" channel: calls
            """#)
        let editor = w.editor
        w.window.settle()
        let api = try require(sixtyAPIAny(editor, "orders API"))
        let fromRow = sixtyArrows(editor).filter { $0.props.start.binding?.shapeID == api.id && $0.props.start.binding?.part == api.props.endpoints[1].id }
        expectEqual(fromRow.count, 3)
        for arrow in fromRow {
            guard let pill = editor.shapeContext.geometry(of: arrow.id)?.labelLead else { continue }
            for other in fromRow where other.id != arrow.id {
                let line = try require(editor.arrowGeometry(of: other.id))
                expect(!line.crosses(pill.insetBy(dx: -5, dy: -5).polygon), "\(arrow[ChannelProperty.self] ?? "?")'s pill clear of the \(other[ChannelProperty.self] ?? "?") line: \(pill)")
            }
        }
    },
    test("a line to a table as a whole comes in at a row clear of the key ending at its side; a reads arrow at a database's left inset stays inside it") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        try w.turnKitOn()
        try w.draw(#"database "shop" size: 1100x800"#)
        try w.draw(#"""
            table "orders" in "shop" columns: "id uuid pk\ntotal_cents int"
            table "refunds" in "shop" right of "orders" (gap: 240) columns: "id uuid pk\norder_id uuid → orders.id\namount_cents int"
            api "orders API" in "shop" below "orders" (gap: 160) endpoints: "GET /o\nPOST /r"
            edge "orders API"."GET /o" -> "orders" channel: reads
            edge "orders API"."POST /r" -> "refunds" channel: writes
            """#)
        let editor = w.editor
        let arrows = sixtyArrows(editor)
        let writes = try require(arrows.first { $0[ChannelProperty.self] == Writes.id })
        let refunds = try require(editor.document.shapes.first { $0[TitleProperty.self] == "refunds" }?.typed(as: DatabaseTable.self))
        let entry = try require(editor.connectionBundle(of: writes.id)?.entries[.end], "a row it comes in at")
        expect(entry != refunds.props.columns[1].id, "not the key's row")
        expectEqual(entry, refunds.props.columns[2].id, "the row as clear of it, on the side the API is: amount_cents, below the key")
        let reads = try require(arrows.first { $0[ChannelProperty.self] == Reads.id })
        let shop = try require(editor.document.shapes.first { $0[TitleProperty.self] == "shop" })
        let database = try require(editor.shapeContext.geometry(of: shop.id)?.bounds)
        let curve = try require(editor.arrowGeometry(of: reads.id)?.levelBody)
        let reach = (0...40).map { curve.point(at: CGFloat($0) / 40).x }.min() ?? 0
        expect(reach > database.minX + 4, "the reads arrow stays inside the database: \(reach) against \(database.minX)")
        // Drawn: the reads line is inked, and nothing is inked outside the database's left edge beside it (or past its right).
        editor.camera = Camera(origin: CGPoint(x: database.minX - 60, y: database.minY - 60), zoom: 1)
        let rep = renderBitmap(editor, size: CGSize(width: database.width + 120, height: database.height + 120))
        expect(hasInk(rep, at: curve.point(at: 0.5), camera: editor.camera), "the reads line is drawn")
        for y in stride(from: database.minY + 20, through: database.maxY - 20, by: 4) {
            for x in stride(from: database.minX - 40, to: database.minX - 3, by: 3) {
                expect(!hasInk(rep, at: CGPoint(x: x, y: y), camera: editor.camera), "no ink left of the database's edge at \(x), \(y)")
            }
        }
        // And neither of the two lines runs along the card it leaves, the API's right edge, closer than a pill's half: each leaves by a side
        // with room, or reaches less.
        let apiFrame = try require(editor.shapeContext.frame(of: try require(editor.document.shapes.first { $0[TitleProperty.self] == "orders API" }).id))
        let reaches = try [reads, writes].map { try require(editor.arrowGeometry(of: $0.id)?.levelBody) }
        for body in reaches {
            let runAlong = (4...36).map { body.point(at: CGFloat($0) / 40) }.filter { abs($0.x - apiFrame.maxX) < 6 && $0.y > apiFrame.minY && $0.y < apiFrame.maxY }
            expect(runAlong.count <= 3, "no line hugs the API's right edge: \(runAlong.count) of its samples are within 6 of it")
        }
        let readsBody = reaches[0], writesBody = reaches[1]
        expect((0...40).allSatisfy { writesBody.distance(to: readsBody.point(at: CGFloat($0) / 40)) > 0 }, "the lines are two")
    },
])

@MainActor private func sixtyAPIAny(_ editor: CanvasEditor, _ title: String) -> ShapeRecord<API>? {
    editor.document.shapes.first { $0[TitleProperty.self] == title }?.typed(as: API.self)
}

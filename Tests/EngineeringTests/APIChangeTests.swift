import AppKit
@_spi(Host) import Canvas
import CanvasTesting
@_spi(Host) import CanvasUI
import Connections
import Engineering
import LineRows
import Selection
import TestKit
import Titles
import Topology

// Changing and retiring an API (K16): Group by Prefix over E8's sixty endpoints and E1's three; Change Method from the chip's menu,
// the card's method line, Change Method ▸ and Space on a selected row, one step name; Deprecate Endpoint and its look; `/new-version`
// (the names it bumps, the rows' ids, the arrows the rows start copied, those into the old one kept); one endpoint taken out of an
// API, by the selection's menu, by a drag by its chip and by ⌘X then ⌘V, an endpoint of its own with its arrows; an endpoint dropped
// on an API, a row again; and a delete that takes the arrows bound to what it took. Straps (CanvasTesting's) are the connector, as
// an arrow is when the kit ships.

/// The kit with straps as its connections, on a real canvas in an unshown window.
@MainActor
final class APIBench {
    let h: EditorHarness
    var editor: CanvasEditor { h.editor }
    let window: NSWindow
    let canvas: CanvasView
    var menus: [NSMenu] = []

    init() throws {
        h = try EditorHarness(plugins: kitPlugins() + [StrapsPlugin(), strapConnector()])
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        canvas = CanvasView(editor: h.editor)
        window.contentView = canvas
        h.editor.viewportDidResize(to: CGSize(width: 1200, height: 900))
        h.editor.turn(EngineeringKit.self, on: true)
        h.editor.undoHistory.seal()
    }

    var undoName: String? { editor.undoHistory.undoName }

    @discardableResult
    func api(_ name: String?, _ lines: [String], server: APIServer = APIServer(), version: String = "", at origin: CGPoint = CGPoint(x: 100, y: 100)) -> ShapeID {
        let id = h.add(API(frame: CGRect(origin: origin, size: CGSize(width: 480, height: 100)), server: server, version: version,
                           endpoints: lines.compactMap { EndpointGrammar.read($0) }), titled: name)
        editor.undoHistory.seal()
        return id
    }

    func rows(_ id: ShapeID) -> [APIRow] { editor.document[id]?.typed(as: API.self)?.props.endpoints ?? [] }
    func lines(_ id: ShapeID) -> [String] { rows(id).map(EndpointGrammar.print) }
    func fullNames(_ id: ShapeID) -> [String] {
        let rows = rows(id)
        return rows.indices.filter { rows[$0].endpoint != nil }.map { APIGroups.fullName(of: $0, in: rows) }
    }

    /// Row `index`'s rect on shape `id`.
    func rect(ofRow index: Int, in id: ShapeID) -> CGRect {
        let record = editor.document[id]!
        return editor.shapeContext.geometry(of: id)!.parts.frame(editor.registry.parts(of: record)![index].id)!.rect
    }

    /// A point on row `index`'s method chip (a member's is indented past a header's chevron).
    func chip(ofRow index: Int, in id: ShapeID, member: Bool = false) -> CGPoint {
        let rect = rect(ofRow: index, in: id)
        return CGPoint(x: rect.minX + 14 + (member ? 18 : 0) + 16, y: rect.midY)
    }

    /// A strap on `channel` from one end to the other, in a step of its own.
    @discardableResult
    func strap(_ from: PartAddress, _ to: PartAddress, on channel: ChannelID) -> ShapeID {
        var strap = ShapeRecord(Strap(from: from, to: to))
        strap[ChannelProperty.self] = channel
        editor.transact("Add Arrow") { $0.insert(strap) }
        editor.undoHistory.seal()
        return strap.id
    }

    func straps() -> [Strap] { editor.document.shapes.compactMap { $0.typed(as: Strap.self)?.props } }

    func click(at point: CGPoint) {
        h.wait(1000)
        h.click(at: point)
    }

    /// A press at a world point dragged past the threshold, then to `to`, and let go.
    func drag(from: CGPoint, to: CGPoint) {
        h.wait(1000)
        h.press(at: from)
        h.drag(to: CGPoint(x: from.x, y: from.y + 8))
        h.drag(to: to)
        h.release()
    }

    /// The card showing, its menus handed to `menus`.
    var card: LineCardView? {
        let card = canvas.cardView as? LineCardView
        if let card, card.menuPresenter == nil { card.menuPresenter = { [weak self] in self?.menus.append($0) } }
        return card
    }

    func press(_ chord: Chord) {
        window.press(chord)
        window.settle()
    }

    var view: LineRowsView? { canvas.descendants(LineRowsView.self).first }
}

/// E8: sixty endpoints, eight under each of seven first segments, written whole, in a mixed order.
private let sixty: [String] = {
    let segments = ["orders", "customers", "products", "payments", "refunds", "webhooks", "admin"]
    var lines: [String] = []
    for index in 0..<8 { for segment in segments { lines.append("GET /\(segment)/\(index)") } }
    return lines + ["GET /health", "POST /login", "GET /", "GET /status"]
}()

/// E1's three.
private let e1Three = ["GET /customers/{id}/statements", "POST /invoices", "POST /webhooks/stripe"]

/// E5's orders API, grouped.
private let e5Rows = ["/orders", "GET /{id}", "POST /", "POST /{id}/refunds (NewRefund) → 201 Refund", "PATCH /{id}", "POST /{id}/cancel",
                      "DELETE /{id}/items/{itemId}", "/customers", "GET /{id}/orders"]

@MainActor private func gray(_ p: [Int]) -> Int { (p[0] + p[1] + p[2]) / 3 }

@MainActor let apiChangeTests = Suite("Changing and retiring an API", [
    test("Group by Prefix on E8's sixty endpoints: seven headers in the order met, each group's endpoints together in their order, the rest first; every full path kept; one step, one Undo") {
        let b = try APIBench()
        let api = b.api("shop API", sixty)
        let before = b.rows(api), full = Set(b.fullNames(api))
        b.editor.selectedShapeIDs = [api]
        expect(b.h.slash(APIStyleWords.groupByPrefix, ""), "/group-by-prefix runs on the API")
        expectEqual(b.undoName, "Group by Prefix")
        let rows = b.rows(api)
        expectEqual(rows.compactMap(\.header).map(\.prefix), ["/orders", "/customers", "/products", "/payments", "/refunds", "/webhooks", "/admin"])
        expectEqual(Set(b.fullNames(api)), full, "every full path kept")
        expectEqual(b.lines(api).prefix(5), ["GET /health", "POST /login", "GET /", "GET /status", "/orders"], "the endpoints that share no segment first")
        expectEqual(b.lines(api)[5...12], ["GET /0", "GET /1", "GET /2", "GET /3", "GET /4", "GET /5", "GET /6", "GET /7"][...], "a group's endpoints in their order, under it")
        expectEqual(Set(rows.compactMap(\.endpoint).map(\.id)), Set(before.compactMap(\.endpoint).map(\.id)), "the endpoints keep their ids")
        expect(!b.h.slash(APIStyleWords.groupByPrefix, "") || b.undoName == "Group by Prefix")
        expectEqual(b.rows(api), rows, "grouped again: nothing changes")
        b.editor.undo()
        expectEqual(b.rows(api), before, "one Undo")
    },
    test("Group by Prefix on E1's three endpoints: no two share a segment, so nothing changes and no step is made; an API grouped by hand regroups, a header of a prefix it keeps keeping its id; from the selection's menu") {
        let b = try APIBench()
        let three = b.api("billing", e1Three)
        b.editor.selectedShapeIDs = [three]
        let menu = try require(b.h.secondaryClick(at: b.rect(ofRow: 0, in: three).center))
        expect(menu.outline.contains("Group by Prefix"), "\(menu.outline)")
        try menu.choose("Group by Prefix")
        expectEqual(b.lines(three), e1Three)
        expectEqual(b.undoName, nil, "no step")
        let api = b.api("orders API", ["GET /customers/{id}", "GET /customers", "/orders", "GET /{id}", "/orders/{id}", "GET /refunds"], at: CGPoint(x: 100, y: 400))
        let header = b.rows(api)[2].id, deeper = b.rows(api)[4].id
        b.editor.selectedShapeIDs = [api]
        expect(b.editor.groupByPrefix([api]))
        expectEqual(b.lines(api), ["/customers", "GET /{id}", "GET /", "/orders", "GET /{id}", "GET /{id}/refunds"])
        expectEqual(b.rows(api)[3].id, header, "/orders kept its header's id")
        expect(!b.rows(api).contains { $0.id == deeper }, "a header of a prefix no group has goes")
        expectEqual(b.undoName, "Group by Prefix")
    },
    test("E5 panel 2: a click on PATCH pops the method menu, the five chips, PATCH checked and highlighted; PUT picked is Change Method, only the method changed; one Undo") {
        let b = try APIBench()
        let api = b.api("orders API", e5Rows, server: APIServer(host: "api.shop.dev/v1", auth: "bearer"))
        let patch = b.rows(api)[4].id
        b.click(at: b.chip(ofRow: 4, in: api, member: true))
        let (menu, _) = try require(b.editor.menuToPopUp, "the chip's menu")
        expectEqual(menu.outline, ["GET", "POST", "PUT", "✓ PATCH", "DELETE"])
        expect(b.editor.menuItemToHighlight === menu.items[3], "the current one highlighted, so Return keeps it")
        expect(menu.items.allSatisfy { $0.image != nil }, "each a chip")
        b.editor.menuDidPopUp()
        try menu.choose("PUT")
        expectEqual(b.rows(api)[4].endpoint?.method, "PUT")
        expectEqual(b.rows(api)[4].id, patch)
        expectEqual(b.undoName, "Change Method")
        b.editor.undo()
        expectEqual(b.rows(api)[4].endpoint?.method, "PATCH", "one Undo")
    },
    test("Change Method by keys: the card's method line (Space, a choice), Change Method ▸ in the selection's menu for a selected row, and Space on the row selected (its chip's menu); each one step, Change Method; VoiceOver hears the chip as 'Method, PATCH'") {
        let b = try APIBench()
        let api = b.api("orders API", e5Rows)
        let rows = b.rows(api)
        // The card's method line.
        b.editor.selectedShapeIDs = [api]
        b.editor.beginEditing(api)
        b.window.settle()
        b.view?.go(to: .row(rows[4].id))
        b.window.settle()
        b.press(Chord(Key.down, .command))
        let card = try require(b.card, "the card shows")
        card.go(to: "method")
        b.press(.space)
        let choices = try require(b.menus.last)
        expectEqual(choices.outline, ["GET", "POST", "PUT", "✓ PATCH", "DELETE"])
        try choices.choose("PUT")
        b.window.settle()
        expectEqual(b.rows(api)[4].endpoint?.method, "PUT")
        expectEqual(b.undoName, "Change Method")
        b.press(.escape)
        b.press(.escape)
        b.editor.endEditing()
        // Change Method ▸ for a selected row.
        b.editor.selectedShapeIDs = [api]
        b.editor.selectItems([AnyHashable(rows[1].id)], of: api)
        let menu = try require(b.h.secondaryClick(at: b.rect(ofRow: 1, in: api).center))
        expect(menu.outline.contains("Change Method ▸"), "\(menu.outline)")
        expect(menu.outline.contains("  ✓ GET"), "its method checked: \(menu.outline)")
        try menu.choose("Change Method", "DELETE")
        expectEqual(b.rows(api)[1].endpoint?.method, "DELETE")
        expectEqual(b.undoName, "Change Method")
        // Space on the selected row: its chip's menu.
        b.editor.selectItems([AnyHashable(rows[2].id)], of: api)
        expect(b.h.key(" "), "Space is the row's")
        let (popped, _) = try require(b.editor.menuToPopUp)
        expectEqual(popped.outline, ["GET", "✓ POST", "PUT", "PATCH", "DELETE"])
        b.editor.menuDidPopUp()
        try popped.choose("PATCH")
        expectEqual(b.rows(api)[2].endpoint?.method, "PATCH")
        expectEqual(b.undoName, "Change Method")
        // VoiceOver: a button after each endpoint's row, named by its method.
        let parts = b.editor.accessibleParts(of: api)
        let titles = parts.map(\.title)
        expect(titles.contains("Method, PATCH"), "\(titles)")
        let at = try require(titles.firstIndex(of: "Method, PUT"))
        expectEqual(parts[at - 1].role, .row, "after its row")
        expectEqual(parts[at].role, .menuButton)
        expectEqual(titles.filter { $0.hasPrefix("Method") }.count, b.rows(api).filter { $0.endpoint != nil }.count, "an endpoint's each, a header none")
    },
    test("Deprecate Endpoint: the card's deprecated (Space) is one step; the row's chip drawn hollow in its color and its words faint; arrows into it as they were") {
        let b = try APIBench()
        let api = b.api("orders API", ["GET /orders/{id}", "DELETE /orders/{id}/items/{itemId}"], at: CGPoint(x: 40, y: 40))
        let rows = b.rows(api)
        let caller = b.h.add(Box(CGRect(x: 700, y: 40, width: 100, height: 60)), titled: "storefront")
        b.strap(PartAddress(caller), PartAddress(api, part: rows[1].id), on: Calls.id)
        let size = CGSize(width: 600, height: 200)
        let before = render(b.editor, size: size)
        b.editor.selectedShapeIDs = [api]
        b.editor.beginEditing(api)
        b.window.settle()
        b.view?.go(to: .row(rows[0].id))
        b.window.settle()
        b.press(.down)
        b.press(Chord(Key.down, .command))
        let card = try require(b.card)
        card.go(to: "deprecated")
        b.press(.space)
        expectEqual(b.rows(api)[1].endpoint?.deprecated, true)
        expectEqual(b.undoName, "Deprecate Endpoint")
        b.press(.escape)
        b.press(.escape)
        b.editor.endEditing()
        b.editor.selectedShapeIDs = []
        let after = render(b.editor, size: size)
        let chip = b.rect(ofRow: 1, in: api)
        let inside = CGPoint(x: chip.minX + 14 + 24, y: chip.midY - 6)
        expect(gray(pixel(before, at: inside)) < 200, "a filled chip: \(pixel(before, at: inside))")
        expectColor(Array(pixel(after, at: inside).prefix(3)), paper, "hollow: the paper inside it", within: 6)
        let edge = CGPoint(x: chip.minX + 14 + 1, y: chip.midY)
        expect(pixel(after, at: edge)[0] > pixel(after, at: edge)[1] + 10, "its edge in DELETE's pink, faint: \(pixel(after, at: edge))")
        expectEqual(b.straps().count, 1, "the call into it kept")
        b.editor.undo()
        expectEqual(b.rows(api)[1].endpoint?.deprecated, false, "one Undo")
    },
    test("/new-version (E5 panel 4): the old API deprecated, a copy beside it titled orders API v2, served at /v2, version 2.0, the same rows under their ids, the arrows its rows start copied onto its rows, those into the old one left; the copy selected; one step, one Undo") {
        let b = try APIBench()
        let api = b.api("orders API", e5Rows, server: APIServer(host: "api.shop.dev/v1", auth: "bearer"), version: "1.4", at: CGPoint(x: 40, y: 40))
        let rows = b.rows(api)
        let refunds = b.h.add(DatabaseTable(frame: CGRect(x: 900, y: 40, width: 200, height: 44), columns: [Column(name: "id", type: TypeRef("uuid"))]),
                              titled: "refunds")
        let storefront = b.h.add(Box(CGRect(x: 40, y: 600, width: 100, height: 60)), titled: "storefront")
        b.strap(PartAddress(api, part: rows[3].id), PartAddress(refunds), on: Writes.id)
        b.strap(PartAddress(storefront), PartAddress(api, part: rows[3].id), on: Calls.id)
        b.editor.selectedShapeIDs = [api]
        expect(b.h.offered.contains("new-version"), "\(b.h.offered)")
        expect(b.h.slash("new-version", ""))
        expectEqual(b.undoName, "New Version")
        let old = try require(b.editor.document[api]?.typed(as: API.self))
        expect(old.props.deprecated, "the old one deprecated")
        let made = try require(b.editor.selectedShapeIDs.first)
        expectEqual(b.editor.selectedShapeIDs, [made], "the copy selected")
        let copy = try require(b.editor.document[made]?.typed(as: API.self))
        expectEqual(copy[TitleProperty.self], "orders API v2")
        expectEqual(copy.props.server, APIServer(host: "api.shop.dev/v2", auth: "bearer"))
        expectEqual(copy.props.version, "2.0")
        expect(!copy.props.deprecated)
        expectEqual(copy.props.endpoints, rows, "the same rows, under their ids")
        let oldFrame = try require(b.editor.shapeContext.frame(of: api)), newFrame = try require(b.editor.shapeContext.frame(of: made))
        expect(!oldFrame.intersects(newFrame), "beside it, clear of it")
        let straps = b.straps()
        expectEqual(straps.count, 3, "the write copied; the call into the old one not")
        expect(straps.contains { $0.from == PartAddress(made, part: rows[3].id) && $0.to == PartAddress(refunds) }, "the copy's row writes refunds")
        expect(straps.contains { $0.from == PartAddress(storefront) && $0.to == PartAddress(api, part: rows[3].id) }, "the storefront still calls v1")
        expect(!straps.contains { $0.to?.shape == made }, "nothing calls v2 yet")
        b.editor.undo()
        expectEqual(b.straps().count, 2)
        expectEqual(b.editor.document[made], nil)
        expectEqual(b.editor.document[api]?.typed(as: API.self)?.props.deprecated, false, "one Undo")
    },
    test("New Version's names: a trailing vN bumped, else v2 added; a server's trailing /vN bumped, else kept; a version's first number bumped and the rest zeroed") {
        let b = try APIBench()
        let names: [(String?, String)] = [("orders API", "orders API v2"), ("orders API v2", "orders API v3"), ("Stripe v9", "Stripe v10"), (nil, "v2"),
                                          ("envy", "envy v2")]
        for (title, bumped) in names {
            let api = b.api(title, ["GET /a"], server: APIServer(host: "api.shop.dev/v1"))
            let made = try require(b.editor.newVersion(of: [api]).first)
            expectEqual(b.editor.document[made]?[TitleProperty.self], bumped, "\(String(describing: title))")
        }
        for (host, bumped) in [("api.shop.dev/v1", "api.shop.dev/v2"), ("api.shop.dev/v9", "api.shop.dev/v10"), ("api.shop.dev", "api.shop.dev"), ("x/v1/y", "x/v1/y")] {
            let api = b.api("x", ["GET /a"], server: APIServer(host: host))
            let made = try require(b.editor.newVersion(of: [api]).first)
            expectEqual(b.editor.document[made]?.typed(as: API.self)?.props.server.host, bumped)
        }
        for (version, bumped) in [("1.4", "2.0"), ("1.2.3", "2.0.0"), ("v2", "v3"), ("", ""), ("2024-01", "2024-01"), ("3", "4")] {
            let api = b.api("x", ["GET /a"], version: version)
            let made = try require(b.editor.newVersion(of: [api]).first)
            expectEqual(b.editor.document[made]?.typed(as: API.self)?.props.version, bumped)
        }
    },
    test("an old version drawn faint, its paper as ever; a locked API refuses New Version and shakes") {
        let b = try APIBench()
        let api = b.api("orders API", ["GET /orders/{id}"], at: CGPoint(x: 40, y: 40))
        let size = CGSize(width: 600, height: 120)
        let row = b.rect(ofRow: 0, in: api)
        let point = CGPoint(x: row.minX + 14 + 6, y: row.midY)
        let live = pixel(render(b.editor, size: size), at: point)
        b.editor.transact { $0.update(api, as: API.self) { $0.props.deprecated = true } }
        let faded = pixel(render(b.editor, size: size), at: point)
        expect(gray(faded) > gray(live) + 40, "the chip faint: \(live) → \(faded)")
        let paperPoint = CGPoint(x: row.maxX - 6, y: row.midY)
        expectColor(Array(pixel(render(b.editor, size: size), at: paperPoint).prefix(3)), paper, "the paper as ever")
        let refusals = RefusalLog()
        let locked = try kitHarness(refusals)
        let other = locked.add(API(frame: CGRect(x: 0, y: 0, width: 400, height: 80), endpoints: [try require(EndpointGrammar.read("GET /a"))]), titled: "a")
        locked.editor.freeze([other])
        locked.editor.undoHistory.seal()
        let step = locked.editor.undoHistory.undoName
        expectEqual(locked.editor.newVersion(of: [other]), [])
        expectEqual(locked.editor.document.shapes.filter { $0.kind == API.kind }.count, 1, "nothing made")
        expectEqual(refusals.refusals, [[other]], "it shakes")
        expectEqual(locked.editor.undoHistory.undoName, step)
    },
    test("Take Out Endpoint from the selection's menu: one endpoint selected is an endpoint of its own under its row's id, its path whole, the strap bound to the row bound to it now; one step; one Undo") {
        let b = try APIBench()
        let api = b.api("orders API", e5Rows, at: CGPoint(x: 40, y: 40))
        let rows = b.rows(api)
        let refunds = b.h.add(DatabaseTable(frame: CGRect(x: 900, y: 40, width: 200, height: 44), columns: [Column(name: "id", type: TypeRef("uuid"))]),
                              titled: "refunds")
        b.strap(PartAddress(api, part: rows[3].id), PartAddress(refunds), on: Writes.id)
        b.editor.selectedShapeIDs = [api]
        b.editor.selectItems([AnyHashable(rows[3].id)], of: api)
        let menu = try require(b.h.secondaryClick(at: b.rect(ofRow: 3, in: api).center))
        expect(menu.outline.contains("Take Out Endpoint"), "\(menu.outline)")
        expect(!menu.outline.contains("Move Endpoint to New API"))
        try menu.choose("Take Out Endpoint")
        expectEqual(b.undoName, "Take Out Endpoint")
        let alone = try require(b.editor.document.shapes.first { $0.kind == StandaloneEndpoint.kind }?.typed(as: StandaloneEndpoint.self))
        expectEqual(alone.props.endpoint.id, rows[3].id)
        expectEqual(alone.props.endpoint.path, "/orders/{id}/refunds", "its path whole")
        expectEqual(b.editor.selectedShapeIDs, [alone.id], "selected")
        expectEqual(b.editor.editingShapeID, nil, "nothing to name: its title is its endpoint's")
        expectEqual(b.editor.registry.title(of: AnyShapeRecord(alone)), "POST /orders/{id}/refunds", "no name: its method and path")
        expectEqual(b.straps().first?.from, PartAddress(alone.id, part: rows[3].id), "the write follows the row")
        expect(!b.rows(api).contains { $0.id == rows[3].id })
        b.editor.undo()
        expectEqual(b.rows(api), rows)
        expectEqual(b.straps().first?.from, PartAddress(api, part: rows[3].id), "one Undo")
    },
    test("E3 panel 4: an endpoint dragged out by its chip onto the board stands alone where the ghost was (the ghost an endpoint's card), its arrows following; ⌘X then ⌘V on the board does the same") {
        let b = try APIBench()
        let api = b.api("orders API", ["GET /orders/{id}", "POST /orders/{id}/refunds (NewRefund) → 201 Refund", "POST /orders"], at: CGPoint(x: 40, y: 40))
        let rows = b.rows(api)
        b.editor.transact { $0.update(api, as: API.self) { api in
            if case .endpoint(var endpoint) = api.props.endpoints[1] {
                endpoint.name = "createRefund"
                api.props.endpoints[1] = .endpoint(endpoint)
            }
        } }
        b.editor.undoHistory.seal()
        let caller = b.h.add(Box(CGRect(x: 900, y: 40, width: 100, height: 60)), titled: "storefront")
        b.strap(PartAddress(caller), PartAddress(api, part: rows[1].id), on: Calls.id)
        b.editor.selectedShapeIDs = []
        let chip = b.chip(ofRow: 1, in: api)
        b.h.wait(1000)
        b.h.press(at: chip)
        b.h.drag(to: CGPoint(x: chip.x, y: chip.y + 8))
        b.h.drag(to: CGPoint(x: 300, y: 500))
        let ghost = try require(b.editor.session?.ghosts.first)
        expectEqual(ghost.kind, StandaloneEndpoint.kind, "over the board, the ghost is what lands: an endpoint's card")
        b.h.release()
        expectEqual(b.undoName, "Take Out Endpoint")
        let alone = try require(b.editor.document.shapes.first { $0.kind == StandaloneEndpoint.kind })
        expectEqual(b.editor.registry.title(of: alone), "createRefund")
        expect(abs((alone.box?.minX ?? 0) - 300) < 20, "where the ghost was: \(String(describing: alone.box))")
        expectEqual(b.straps().first?.to, PartAddress(alone.id, part: rows[1].id), "the call follows")
        expectEqual(b.editor.accessibleDescription(of: alone.id)?.label, "createRefund, Endpoint")
        expectEqual(b.editor.accessibleDescription(of: alone.id)?.value, "POST /orders/{id}/refunds")
        b.editor.undo()
        expectEqual(b.rows(api).map(\.id), rows.map(\.id), "one Undo")
        // ⌘X then ⌘V with nothing selected: the same, by keys.
        b.editor.selectedShapeIDs = [api]
        b.editor.selectItems([AnyHashable(rows[1].id)], of: api)
        expect(b.editor.cutRows([rows[1].id], of: api))
        expectEqual(b.undoName, "Cut Endpoint and 1 strap")
        b.editor.selectedShapeIDs = []
        let made = try require(b.editor.pasteRows(try require(b.editor.pasteboardRows), to: .beside([])))
        expectEqual(b.editor.document[made]?.kind, StandaloneEndpoint.kind)
        expectEqual(b.undoName, "Take Out Endpoint")
        expectEqual(b.straps().first?.to, PartAddress(made, part: rows[1].id), "its call back, bound to it")
    },
    test("an endpoint standing alone dropped on an API by its chip is its row again, under its longest header, its path relative; the shape gone, its arrows on the row; one Move Endpoint; by keys, ⌘X then ⌘V on a row") {
        let b = try APIBench()
        let api = b.api("orders API", ["/orders", "GET /{id}", "/customers", "GET /{id}"], at: CGPoint(x: 40, y: 40))
        let alone = ShapeRecord(StandaloneEndpoint(frame: CGRect(x: 40, y: 400, width: 420, height: 44),
                                                   endpoint: Endpoint(method: "POST", path: "/orders/{id}/refunds", name: "createRefund")))
        b.editor.transact { $0.insert(alone) }
        let refunds = b.h.add(DatabaseTable(frame: CGRect(x: 900, y: 400, width: 200, height: 44), columns: [Column(name: "id", type: TypeRef("uuid"))]),
                              titled: "refunds")
        b.strap(PartAddress(alone.id, part: alone.props.endpoint.id), PartAddress(refunds), on: Writes.id)
        b.editor.selectedShapeIDs = []
        let chip = b.chip(ofRow: 0, in: alone.id)
        let target = b.rect(ofRow: 1, in: api)
        b.drag(from: chip, to: CGPoint(x: target.midX, y: target.maxY - 2))
        expectEqual(b.undoName, "Move Endpoint")
        expectEqual(b.editor.document[alone.id], nil, "the shape went with its row")
        expectEqual(b.lines(api), ["/orders", "GET /{id}", "POST /{id}/refunds", "/customers", "GET /{id}"])
        expectEqual(b.rows(api)[2].id, alone.props.endpoint.id, "under its id")
        expectEqual(b.straps().first?.from, PartAddress(api, part: alone.props.endpoint.id), "its write on the row")
        b.editor.undo()
        expect(b.editor.document[alone.id] != nil, "one Undo")
        expectEqual(b.straps().first?.from, PartAddress(alone.id, part: alone.props.endpoint.id))
        // By keys: its row selected, ⌘X, then ⌘V on one of the API's rows.
        b.editor.selectedShapeIDs = [alone.id]
        b.editor.selectItems([AnyHashable(alone.props.endpoint.id)], of: alone.id)
        expect(b.editor.cutRows([alone.props.endpoint.id], of: alone.id))
        expectEqual(b.editor.document[alone.id], nil, "cut, it goes")
        expectEqual(b.undoName, "Cut Endpoint and 1 strap")
        b.editor.selectedShapeIDs = [api]
        expect(b.editor.pasteRows(try require(b.editor.pasteboardRows), to: .into(api, before: nil)) != nil)
        expectEqual(b.lines(api), ["/orders", "GET /{id}", "POST /{id}/refunds", "/customers", "GET /{id}"])
        expectEqual(b.straps().first?.from, PartAddress(api, part: alone.props.endpoint.id), "its write back, on the row")
        expectEqual(b.undoName, "Paste Endpoint")
    },
    test("E6 panel 2: ⌫ on an endpoint's row takes the arrows bound to it, Delete Endpoint and 3 straps; deleting the API takes the rest; one Undo each") {
        let b = try APIBench()
        let api = b.api("orders API", ["GET /orders/{id}", "POST /orders/{id}/refunds", "POST /orders"], at: CGPoint(x: 40, y: 40))
        let rows = b.rows(api)
        let refunds = b.h.add(DatabaseTable(frame: CGRect(x: 900, y: 40, width: 200, height: 44), columns: [Column(name: "id", type: TypeRef("uuid"))]),
                              titled: "refunds")
        let storefront = b.h.add(Box(CGRect(x: 40, y: 600, width: 100, height: 60)), titled: "storefront")
        b.strap(PartAddress(storefront), PartAddress(api, part: rows[1].id), on: Calls.id)
        b.strap(PartAddress(api, part: rows[1].id), PartAddress(refunds), on: Writes.id)
        b.strap(PartAddress(api, part: rows[1].id), PartAddress(refunds), on: Reads.id)
        b.strap(PartAddress(api, part: rows[2].id), PartAddress(refunds), on: Writes.id)
        b.editor.selectedShapeIDs = [api]
        b.editor.selectItems([AnyHashable(rows[1].id)], of: api)
        expect(b.h.key("\u{7f}"), "Delete is the row's")
        expectEqual(b.undoName, "Delete Endpoint and 3 straps")
        expectEqual(b.straps().count, 1)
        b.editor.undo()
        expectEqual(b.straps().count, 4)
        b.editor.selectedShapeIDs = []
        b.editor.selectedShapeIDs = [api]
        expectEqual(b.editor.selectedItems, nil, "the API itself selected")
        expect(b.h.key("\u{7f}"))
        expectEqual(b.undoName, "Delete API and 4 straps")
        expectEqual(b.straps().count, 0)
        b.editor.undo()
        expectEqual(b.straps().count, 4)
    },
    test("an endpoint standing alone at rest: the paper, its chip, its path, a hairline, {id} and its type, its body, its responses; deprecated, its chip hollow; zoomed out, bars; the endpoint fixture's members") {
        let b = try APIBench()
        let alone = ShapeRecord(StandaloneEndpoint(frame: CGRect(x: 40, y: 40, width: 420, height: 200),
                                                   endpoint: Endpoint(method: "POST", path: "/orders/{id}/refunds", name: "createRefund", authScope: "orders:write",
                                                                      parameters: [PathParameter(name: "id", type: "uuid")], body: TypeRef("NewRefund"),
                                                                      responses: [EndpointResponse(status: "201", type: TypeRef("Refund")),
                                                                                  EndpointResponse(status: "404"), EndpointResponse(status: "409", type: TypeRef("Problem"))])))
        b.editor.transact { $0.insert(alone) }
        let frame = try require(b.editor.shapeContext.frame(of: alone.id))
        let height: CGFloat = 8 + 24 + 10 + 48 + 10 + 72 + 12
        expectEqual(frame.height, height, "its first line, two details, three responses, two gaps")
        let size = CGSize(width: 600, height: 300)
        let rep = render(b.editor, size: size)
        let header = b.rect(ofRow: 0, in: alone.id)
        let chip = CGPoint(x: header.minX + 14 + 4, y: header.midY)
        expect(pixel(rep, at: chip)[2] > pixel(rep, at: chip)[0] + 60, "POST's blue chip: \(pixel(rep, at: chip))")
        expectColor(Array(pixel(rep, at: CGPoint(x: frame.maxX - 4, y: frame.maxY - 4)).prefix(3)), paper, "on the paper")
        b.editor.transact { $0.update(alone.id, as: StandaloneEndpoint.self) { $0.props.endpoint.deprecated = true } }
        let hollow = render(b.editor, size: size)
        expectColor(Array(pixel(hollow, at: CGPoint(x: chip.x + 6, y: chip.y - 5)).prefix(3)), paper, "hollow", within: 8)
        expectEqual(b.editor.registry.parts(of: try require(b.editor.document[alone.id]))?.map(\.name), ["POST /orders/{id}/refunds"])
        expectEqual(b.editor.registry.parts(of: try require(b.editor.document[alone.id]))?.first?.standsAlone, true)
    },
])

/// The kit's command names, as typed in the command bar.
enum APIStyleWords {
    static let groupByPrefix = "group-by-prefix"
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

import AppKit
import Adornments
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
@_spi(Host) import CanvasUI
import Connections
import Engineering
import Geometry
import LineRows
import Palette
import References
import Selection
import ShippedTesting
import TestKit
import TextEditing
import Titles

// Connect an API, shipped (K14): E4's four panels and E7 panels 4 to 7. An endpoint's card writes its connections a line each
// (`writes refunds`, one step each); a drag from an endpoint's row onto a table draws the arrow plain and the one release list
// offers writes and reads, a pick "Change Relation"; ⌘L on an endpoint reaches an endpoint on another board through a pill for
// it, which draws the method's chip; and rows cut on one board and pasted on another bring their arrows back through pills.

@MainActor private func arrows(_ editor: CanvasEditor) -> [ShapeRecord<Arrow>] { editor.document.shapes.compactMap { $0.typed(as: Arrow.self) } }

@MainActor private func shape(_ editor: CanvasEditor, _ title: String) -> AnyShapeRecord? {
    editor.document.shapes.first { $0[TitleProperty.self] == title }
}

@MainActor private func rows(_ editor: CanvasEditor, _ title: String) -> [APIRow] {
    shape(editor, title)?.typed(as: API.self)?.props.endpoints ?? []
}

/// E4: an orders API, refunds and payments right of it.
private let e4 = #"""
    api "orders API" server: "api.shop.dev/v1 bearer" endpoints: "GET /orders/{id}\nPOST /orders/{id}/refunds\nPOST /orders"
    table "refunds" right of "orders API" (gap: 140) columns: "id uuid pk\namount_cents int"
    table "payments" below "refunds" (gap: 40) columns: "id uuid pk\namount_cents int"
    """#

/// E4 panel 4: and the Stripe API, on a board of its own.
private let stripe = #"""
    subboard "payments service" below "orders API" (gap: 200)
    """#

/// The Stripe API, put in the subboard a script before drew.
private let stripeAPI = #"""
    api "Stripe API" in "payments service" endpoints: "POST /v1/refunds\nGET /v1/charges"
    """#

/// The canvas drawn as `renderBitmap` draws it, in the dark appearance.
@MainActor private func renderDark(_ editor: CanvasEditor, size: CGSize) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let cg = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    cg.translateBy(x: 0, y: size.height)
    cg.scaleBy(x: 1, y: -1)
    NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        let bounds = CGRect(origin: .zero, size: size)
        editor.draw(in: cg, bounds: bounds, dirtyRect: bounds)
        NSGraphicsContext.restoreGraphicsState()
    }
    return rep
}

/// How many pixels of `rect` (view points, at scale 1) are within a few steps of `color`.
@MainActor private func count(_ color: RGB, in rect: CGRect, of rep: NSBitmapImageRep) -> Int {
    let target = [color.red, color.green, color.blue].map { Int(($0 * 255).rounded()) }
    var found = 0
    for y in Int(rect.minY)..<Int(rect.maxY) {
        for x in Int(rect.minX)..<Int(rect.maxX) {
            let p = pixel(rep, at: CGPoint(x: x, y: y))
            if zip(p, target).allSatisfy({ abs($0 - $1) <= 6 }) { found += 1 }
        }
    }
    return found
}

/// connect 24, wave 8: a far pill an arrow from a row reaches lands where the arrow reads clean: below the shape it leaves (the
/// line meeting the pill's top), else level with the row (the pill's middle at the row's middle, the line meeting its near side);
/// the straight line from the row to where it meets the pill crosses no other shape, and the pill is in the clear view.
@MainActor func expectClean(_ arrowID: ShapeID, from near: ShapeID, row: PartID, in editor: CanvasEditor, view: Bool = true,
                                    _ what: String) throws {
    let arrow = try require(editor.document[arrowID]?.typed(as: Arrow.self))
    let pillID = try require(arrow.props.end.binding?.shapeID)
    let pill = try require(editor.shapeContext.geometry(of: pillID)?.bounds), shape = try require(editor.shapeContext.geometry(of: near)?.bounds)
    let line = try require(editor.shapeContext.geometry(of: near)?.parts.frame(row)?.rect)
    let geometry = try require(editor.arrowGeometry(of: arrowID))
    // Where the level curve leaves the row and meets the pill, before its head is trimmed off.
    let level: Cubic? = if case .level(let cubic, _, _) = geometry.path { cubic } else { nil }
    let cubic = try require(level, "a level arrow, from a row: \(what)")
    let start = cubic.start, end = cubic.end
    if pill.minY >= shape.maxY {
        expect(abs(end.y - pill.minY) < 1.5, "\(what): below the shape, the line meets the pill's top: \(end) \(pill)")
    } else {
        expect(abs(pill.midY - line.midY) < 1, "\(what): level with the row: \(pill.midY) \(line.midY)")
        expect(abs(end.x - (pill.minX > shape.maxX ? pill.minX : pill.maxX)) < 1.5, "\(what): the line meets the pill's near side: \(end) \(pill)")
    }
    // The line leaves the shape it starts from by its side: it never cuts across the rows under the one it leaves.
    let rest = CGRect(x: shape.minX, y: line.maxY, width: shape.width, height: max(0, shape.maxY - line.maxY)).insetBy(dx: 1, dy: 1)
    if !rest.isNull, !rest.isEmpty {
        let cuts = (1...64).contains { step in
            let t = CGFloat(step) / 64
            return rest.contains(CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
        }
        expect(!cuts, "\(what): the line from the row cuts across the rows under it")
    }
    for record in editor.document.shapes where ![near, pillID, arrowID].contains(record.id) && record.kind != Arrow.kind {
        guard let bounds = editor.shapeContext.geometry(of: record.id)?.bounds, !bounds.contains(shape) else { continue }
        let inner = bounds.insetBy(dx: 1, dy: 1)
        let crosses = (0...64).contains { step in
            let t = CGFloat(step) / 64
            return inner.contains(CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
        }
        expect(!crosses, "\(what): the line from the row crosses \(record[TitleProperty.self] ?? record.kind.rawValue)")
    }
    if view { expect(editor.cameraTarget.toWorld(editor.unobscuredViewport).contains(pill), "\(what): the pill in the clear view") }
}

@MainActor let apiConnectShippedTests = Suite("Connect an API, shipped", [
    test("E4 panels 2 and 3, by the pointer through the app's canvas view: a drag from an endpoint row's dot onto payments draws the arrow plain from the row, and the list offers writes, reads, a rule, Plain arrow; ↓ reads ↩ is Change Relation; one Undo plain, two none") {
        let w = try KeyDragWindow(e4)
        let editor = w.editor
        let row = try w.row("orders API", 1), payments = try require(shape(editor, "payments"))
        let refundsRow = try require(rows(editor, "orders API").dropFirst().first?.id)
        let start = editor.document
        w.move(to: CGPoint(x: row.midX, y: row.midY))
        w.move(to: CGPoint(x: row.maxX + 12, y: row.midY))
        w.press()
        let target = try require(editor.shapeContext.geometry(of: payments.id)?.bounds)
        w.drag(to: editor.camera.toView(CGPoint(x: target.midX, y: target.midY)))
        expectEqual(editor.hintedShapeID, payments.id, "payments lit as the end")
        w.release()
        let arrow = try require(arrows(editor).last)
        expectEqual(editor.selectedShapeIDs, [arrow.id], "a pointer drag selects the arrow it drew, the list under it")
        expectEqual(arrow.props.start.binding?.part, refundsRow, "from the row")
        expectEqual(arrow.props.end.binding?.shapeID, payments.id)
        expectEqual(arrow.props.end.binding?.part, nil, "to the table as a whole")
        expectEqual(arrow[ChannelProperty.self], nil, "plain until a pick")
        expectEqual(editor.undoHistory.undoName, "Add Arrow")
        let (menu, _) = try require(editor.menuToPopUp)
        expectEqual(menu.items.map { $0.isSeparatorItem ? "" : $0.title }, ["writes", "reads", "", "Plain arrow"])
        expect(editor.menuItemToHighlight === menu.items.first, "writes highlighted")
        // ↓ to reads, then Return: the menu's own keys pick its second row.
        menu.performActionForItem(at: 1)
        expectEqual(editor.document[arrow.id]?[ChannelProperty.self], Reads.id)
        expectEqual(editor.undoHistory.undoName, "Change Relation")
        expectEqual(editor.adornmentFrames(of: arrow.id).map(\.label.text), ["reads"], "its pill on the line, in reads' green")
        expectEqual(editor.adornmentFrames(of: arrow.id).first?.label.tint?.color, NSColor(KitStyle.readsTint))
        editor.undo()
        expectEqual(editor.document[arrow.id]?[ChannelProperty.self], nil, "one Undo: the plain arrow")
        editor.undo()
        expectEqual(editor.document, start, "two: none")
    },
    test("E4 panel 1: the card's relations, a line each: writes ref offers refunds, picked and left it's the arrow (Connect); reads in its place keeps the arrow (Change Relation); emptied it goes (Delete Arrow)") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        // The list the release queues is read off the editor; the window never pops it (its tracking would wait for a person).
        w.canvas.menuPresenter = { _, _, _ in }
        try w.turnKitOn()
        try w.draw(e4)
        let api = try require(shape(editor, "orders API")).id, refunds = try require(shape(editor, "refunds")).id
        let row = try require(rows(editor, "orders API").dropFirst().first?.id)
        let walk = w.walk()
        editor.selectedShapeIDs = [api]
        editor.beginEditing(api)
        w.window.settle()
        w.lineRows?.go(to: .row(row))
        w.window.settle()
        walk.press(Chord(Key.down, .command))
        let card = try require(w.canvas.cardView as? LineCardView)
        card.go(to: "relations 1")
        w.window.settle()
        w.type("writes ref", with: walk)
        let field = try require(card.field(of: "relations 1"))
        expectEqual(field.listedOffers, ["refunds"], "the file's tables after writes (E4 panel 1)")
        walk.press(.tab)
        expectEqual(field.string, "writes refunds")
        walk.press(.return)
        let arrow = try require(arrows(editor).first)
        expectEqual(arrow[ChannelProperty.self], Writes.id)
        expectEqual(arrow.props.start.binding?.part, row)
        expectEqual(arrow.props.end.binding?.shapeID, refunds)
        expectEqual(undoTitle(w.window), "Undo Connect")
        expectEqual(card.value(of: "relations 1"), "writes refunds", "the line reads the arrow")
        // Reads in its place: the same arrow, its relation changed.
        card.go(to: "relations 1")
        w.window.settle()
        let line = try require(card.field(of: "relations 1"))
        line.selectAll(nil)
        w.type("reads refunds", with: walk)
        walk.press(.up)
        expectEqual(arrows(editor).map(\.id), [arrow.id], "the arrow kept")
        expectEqual(editor.document[arrow.id]?[ChannelProperty.self], Reads.id)
        expectEqual(undoTitle(w.window), "Undo Change Relation")
        // Emptied: it goes.
        card.go(to: "relations 1")
        w.window.settle()
        let emptied = try require(card.field(of: "relations 1"))
        emptied.selectAll(nil)
        walk.press(.delete)
        walk.press(.return)
        expectEqual(arrows(editor).count, 0)
        expectEqual(undoTitle(w.window), "Undo Delete Arrow")
        for _ in 0..<3 where editor.editingShapeID != nil { walk.press(.escape) }
        editor.undo()
        expectEqual(editor.document[arrow.id]?[ChannelProperty.self], Reads.id, "one Undo brings it back")
    },
    test("E4 panel 4: ⌘L on an endpoint, stripe ref finds Stripe API's POST /v1/refunds on another board; Return puts a pill for that endpoint beside the API and the calls arrow to it, one step, Connect") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        // The list the release queues is read off the editor; the window never pops it (its tracking would wait for a person).
        w.canvas.menuPresenter = { _, _, _ in }
        try w.turnKitOn()
        try w.draw(e4)
        try w.draw(stripe)
        try w.draw(stripeAPI)
        let api = try require(shape(editor, "orders API")).id
        let row = try require(rows(editor, "orders API").dropFirst().first?.id)
        let board = BoardID(owner: try require(shape(editor, "payments service")).id)
        let far = try require(editor.contents(of: board).shapes.first { $0[TitleProperty.self] == "Stripe API" }?.typed(as: API.self))
        let farRow = try require(far.props.endpoints.first?.id)
        let walk = w.walk()
        editor.undoHistory.seal()
        let start = editor.document
        editor.selectedShapeIDs = [api]
        editor.beginEditing(api)
        w.window.settle()
        w.lineRows?.go(to: .row(row))
        w.window.settle()
        walk.press(Chord("l", .command))
        let picker = try require(editor.connectPicker)
        w.type("stripe ref", with: walk)
        let listed = (picker.picker?.list.rows ?? []).compactMap(\.item)
        expectEqual(listed.first?.title, "POST /v1/refunds", "found by its path through its API: \(listed.map(\.title))")
        walk.press(.return)
        let arrow = try require(arrows(editor).first)
        expectEqual(arrow[ChannelProperty.self], Calls.id, "one relation fits: calls, at once")
        expect(editor.menuToPopUp == nil, "no list")
        expectEqual(arrow.props.start.binding?.part, row)
        let pill = try require(editor.document[try require(arrow.props.end.binding?.shapeID)]?.typed(as: Reference.self))
        expectEqual(pill.props.target?.id, far.id)
        expectEqual(pill.props.target?.row, farRow, "a pill for the endpoint itself")
        expectEqual(arrow.props.end.binding?.part, farRow)
        expectEqual(undoTitle(w.window), "Undo Connect")
        try expectClean(arrow.id, from: api, row: row, in: editor, "⌘L's far pick")
        // connect 19 to 21: the card's calls line, longer than the card, ends in "…" until its stop has the keyboard.
        walk.press(Chord(Key.down, .command))
        let card = try require(w.canvas.cardView as? LineCardView)
        w.window.settle()
        card.layoutSubtreeIfNeeded()
        expectEqual(card.value(of: "relations 1"), "calls Stripe API.POST /v1/refunds", "its words whole")
        expect(card.isCut("relations 1"), "cut at the card's edge, said so")
        expect(!card.isCut("name"), "a line that fits isn't")
        card.go(to: "relations 1")
        w.window.settle()
        card.layoutSubtreeIfNeeded()
        expect(!card.isCut("relations 1"), "with the keyboard, shown whole, slid to its caret")
        walk.press(.escape)
        walk.press(.escape)
        walk.press(.escape)
        // The pill draws the method's chip as the row does, light and dark.
        let frame = editor.camera.toView(pill.props.frame)
        let size = CGSize(width: max(800, frame.maxX + 20), height: max(600, frame.maxY + 20))
        let post = Swatch.reading(RGB(hex: 0x2C72DB), against: [.white], atLeast: Swatch.textContrast)
        expect(count(post, in: frame, of: renderBitmap(editor, size: size)) > 40, "the POST chip in its blue, light")
        expect(count(post, in: frame, of: renderDark(editor, size: size)) > 40, "and dark")
        editor.undo()
        expectEqual(editor.document, start, "one Undo: the arrow and the pill")
    },
    test("a calls line typed in the card to an endpoint on another board puts its pill where the line from the row is clean (connect 24)") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        w.canvas.menuPresenter = { _, _, _ in }
        try w.turnKitOn()
        try w.draw(e4)
        try w.draw(stripe)
        try w.draw(stripeAPI)
        let api = try require(shape(editor, "orders API")).id
        let row = try require(rows(editor, "orders API").dropFirst().first?.id)
        let walk = w.walk()
        editor.selectedShapeIDs = [api]
        editor.beginEditing(api)
        w.window.settle()
        w.lineRows?.go(to: .row(row))
        w.window.settle()
        walk.press(Chord(Key.down, .command))
        let card = try require(w.canvas.cardView as? LineCardView)
        card.go(to: "relations 1")
        w.window.settle()
        w.type("calls Stripe API.POST /v1/refunds", with: walk)
        walk.press(.return)
        let arrow = try require(arrows(editor).first, "the typed line drew its arrow")
        try expectClean(arrow.id, from: api, row: row, in: editor, "a typed calls line")
    },
    test("the card keeps an arrow through what its line can't say: a typo in a line keeps the arrow and the typed words, a line changed to another table re-aims the same arrow (its id and bend kept, Change Connection), two lines alike make one") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        w.canvas.menuPresenter = { _, _, _ in }
        try w.turnKitOn()
        try w.draw(e4)
        try w.draw(#"edge "orders API"."POST /orders/{id}/refunds" -> "refunds" channel: writes"#)
        let api = try require(shape(editor, "orders API")).id, payments = try require(shape(editor, "payments")).id
        let row = try require(rows(editor, "orders API").dropFirst().first?.id)
        let arrow = try require(arrows(editor).first).id
        editor.transact("Bend") { $0.update(arrow, as: Arrow.self) { $0.props.bend = 24 } }
        let walk = w.walk()
        editor.selectedShapeIDs = [api]
        editor.beginEditing(api)
        w.window.settle()
        w.lineRows?.go(to: .row(row))
        w.window.settle()
        walk.press(Chord(Key.down, .command))
        let card = try require(w.canvas.cardView as? LineCardView)
        card.go(to: "relations 1")
        w.window.settle()
        expectEqual(card.value(of: "relations 1"), "writes refunds", "the line reads the arrow")
        // A name mistyped: the arrow stays, and so do the words, for the person to mend.
        let line = try require(card.field(of: "relations 1"))
        line.selectAll(nil)
        w.type("writes refundz", with: walk)
        walk.press(.up)
        expectEqual(arrows(editor).map(\.id), [arrow], "the arrow kept")
        expectEqual(editor.document[arrow]?[ChannelProperty.self], Writes.id)
        expectEqual(card.field(of: "relations 1")?.string, "writes refundz", "what was typed stays")
        // Mended to another table: the same arrow, re-aimed.
        let mended = try require(card.field(of: "relations 1"))
        mended.selectAll(nil)
        w.type("writes payments", with: walk)
        walk.press(.up)
        let moved = try require(arrows(editor).first)
        expectEqual(arrows(editor).map(\.id), [arrow], "the arrow kept, re-aimed")
        expectEqual(moved.props.end.binding?.shapeID, payments)
        expectEqual(moved.props.start.binding?.part, row)
        expectEqual(moved.props.bend, 24, "its bend kept")
        expectEqual(moved[ChannelProperty.self], Writes.id)
        expectEqual(undoTitle(w.window), "Undo Change Connection")
        editor.undo()
        expectEqual(arrows(editor).first?.props.end.binding?.shapeID, try require(shape(editor, "refunds")).id, "one Undo re-aims it back")
    },
    test("the card lists only the arrows it can change: one leaving a pill of the endpoint on another board is not its line, and its words don't take it out") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        w.canvas.menuPresenter = { _, _, _ in }
        try w.turnKitOn()
        try w.draw(e4)
        try w.draw(stripe)
        let api = try require(shape(editor, "orders API")).id
        let row = try require(rows(editor, "orders API").dropFirst().first?.id)
        let board = BoardID(owner: try require(shape(editor, "payments service")).id)
        // A table on the subboard's board, written by the endpoint on the root: the arrow is there, from a pill for the endpoint.
        _ = try drawnInProcess(#"""
            table "audit" in "payments service" columns: "id uuid pk"
            edge "orders API"."POST /orders/{id}/refunds" -> "audit" channel: writes
            """#, on: editor)
        let far = try require(editor.contents(of: board).shapes.compactMap { $0.typed(as: Arrow.self) }.first, "an arrow on the payments service board, from a pill of the endpoint")
        expectEqual(far[ChannelProperty.self], Writes.id)
        let walk = w.walk()
        editor.selectedShapeIDs = [api]
        editor.beginEditing(api)
        w.window.settle()
        w.lineRows?.go(to: .row(row))
        w.window.settle()
        walk.press(Chord(Key.down, .command))
        let card = try require(w.canvas.cardView as? LineCardView)
        card.go(to: "relations 1")
        w.window.settle()
        expectEqual(card.value(of: "relations 1") ?? "", "", "an arrow on another board is that board's")
        // Writing a line here leaves it be.
        w.type("writes refunds", with: walk)
        walk.press(.up)
        expectEqual(arrows(editor).count, 1, "one arrow on this board, the far one still on its own")
        expect(editor.contents(of: board).shapes.contains { $0.id == far.id }, "the far arrow still there")
    },
    test("calls end on an endpoint's row alone: an edge to a subboard, and an edge from or to a path prefix's header, are refused; ⌘L on a header shakes and opens nothing") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        w.canvas.menuPresenter = { _, _, _ in }
        try w.turnKitOn()
        try w.draw(e4)
        try w.draw(#"""
            api "grouped API" below "orders API" (gap: 80) endpoints: "/v1\nGET /v1/orders"
            subboard "web" right of "grouped API" (gap: 80)
            """#)
        _ = try refusedInProcess(#"edge "orders API"."POST /orders" -> "web" channel: calls"#, on: editor)
        _ = try refusedInProcess(#"edge "grouped API"."/v1" -> "refunds" channel: writes"#, on: editor)
        _ = try refusedInProcess(#"edge "grouped API"."GET /v1/orders" -> "orders API"."/orders" channel: calls"#, on: editor)
        // A subboard calls an endpoint, as any shape with dots does; nothing is called at the subboard.
        _ = try drawnInProcess(#"edge "web" -> "grouped API"."GET /v1/orders" channel: calls"#, on: editor)
        expectEqual(arrows(editor).first?[ChannelProperty.self], Calls.id)
        let grouped = try require(shape(editor, "grouped API"))
        let header = try require(rows(editor, "grouped API").first?.id)
        expect(ConnectPicker(editor: editor, source: ConnectEnd(grouped.id, part: header)) == nil, "a header has nothing to pick for")
        let walk = w.walk()
        editor.selectedShapeIDs = [grouped.id]
        editor.selectItems([AnyHashable(header)], of: grouped.id)
        walk.press(Chord("l", .command))
        expect(editor.connectPicker?.isOpen != true, "no picker opens on a header")
        expect(editor.service(RefusalShake.self)?.isShaking == true, "the shape shakes, as one with nothing to pick for does")
    },
    test("wave 8 and connect 24: draw's calls edge to an endpoint on another board puts its pill where the line from the row is clean, below the API or level with the row, never with the arrow under the pill") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        try w.turnKitOn()
        try w.draw(#"""
            database "shop" size: 1400x900
            subboard "payments provider" right of "shop"
            """#)
        try w.draw(#"""
            table "orders" in "shop" columns: "id uuid pk\ntotal_cents int"
            table "refunds" in "shop" right of "orders" top level with "orders" columns: "id uuid pk\norder_id uuid → orders.id\namount_cents int"
            api "orders API" in "shop" below "orders" (gap: wide) server: "api.shop.dev/v1 bearer" endpoints: "/orders\nGET /orders/{id}\nPOST /orders/{id}/refunds → 201"
            """#)
        try w.draw(#"api "Stripe API" in "payments provider" server: "api.stripe.com bearer" endpoints: "POST /v1/refunds → 200""#)
        try w.draw(#"edge "orders API"."POST /orders/{id}/refunds" -> "refunds" channel: writes"#)
        try w.draw(#"edge "orders API"."POST /orders/{id}/refunds" -> "Stripe API"."POST /v1/refunds" channel: calls"#)
        let api = try require(shape(editor, "orders API")).id
        let row = try require(rows(editor, "orders API").last?.id)
        let calls = try require(arrows(editor).first { $0[ChannelProperty.self] == Calls.id })
        try expectClean(calls.id, from: api, row: row, in: editor, view: false, "draw's edge")
        let ids = Set(editor.document.shapes.map(\.id))
        try w.draw(#"edge "orders API"."POST /orders/{id}/refunds" -> "Stripe API"."POST /v1/refunds" channel: calls"#)
        expectEqual(Set(editor.document.shapes.map(\.id)), ids, "drawn again: nothing twice")
    },
    test("E7 panels 4 to 7, by the keys: ↑ to the refunds row, ⌘L, ref, ↩ picks refunds, ↩ takes writes, Escape; one Undo the plain arrow, two none") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        // The list the release queues is read off the editor; the window never pops it (its tracking would wait for a person).
        var popped: [(menu: NSMenu, highlighted: NSMenuItem?)] = []
        w.canvas.menuPresenter = { menu, _, highlighted in popped.append((menu, highlighted)) }
        try w.turnKitOn()
        try w.draw(#"""
            api "orders API" endpoints: "GET /orders/{id}\nPOST /orders\nPOST /orders/{id}/refunds"
            table "refunds" right of "orders API" (gap: 140) columns: "id uuid pk\namount_cents int"
            table "orders" below "refunds" (gap: 40) columns: "id uuid pk"
            """#)
        let api = try require(shape(editor, "orders API")).id, refunds = try require(shape(editor, "refunds")).id
        let last = try require(rows(editor, "orders API").last?.id)
        editor.undoHistory.seal()
        let start = editor.document
        let walk = w.walk()
        editor.selectedShapeIDs = [api]
        editor.beginEditing(api)
        w.window.settle()
        w.lineRows?.go(to: .waiting)
        w.window.settle()
        walk.press(.up)
        expectEqual(w.lineRows?.focus, .row(last), "↑: the refunds row")
        walk.press(Chord("l", .command))
        let picker = try require(editor.connectPicker)
        w.type("ref", with: walk)
        let listed = (picker.picker?.list.rows ?? []).compactMap(\.item).map(\.title)
        expectEqual(listed.first, "refunds", "the table first (E7 panel 3): \(listed)")
        expect(!listed.contains("id"), "never a table's column from an endpoint")
        walk.press(.return)
        let arrow = try require(arrows(editor).first)
        expectEqual(arrow.props.end.binding?.shapeID, refunds)
        expectEqual(arrow[ChannelProperty.self], nil, "plain until a pick")
        w.window.settle()
        // connect 13: the list hangs from the arrow, which isn't selected: the API, edited, stays the one selected.
        expectEqual(editor.selectedShapeIDs, [api], "the API still selected (E7 panel 4)")
        expectEqual(editor.editingShapeID, api)
        expectEqual(w.lineRows?.focus, .row(last), "the caret still in the refunds row")
        let (menu, highlighted) = try require(popped.last, "the list popped at the arrow")
        expectEqual(menu.items.map { $0.isSeparatorItem ? "" : $0.title }, ["writes", "reads", "", "Plain arrow"])
        expectEqual(undoTitle(w.window), "Undo Connect")
        // ↩ in the list: the highlighted row, writes.
        expect(highlighted === menu.items.first, "writes highlighted")
        menu.performActionForItem(at: menu.index(of: try require(highlighted)))
        expectEqual(editor.document[arrow.id]?[ChannelProperty.self], Writes.id)
        expectEqual(undoTitle(w.window), "Undo Change Relation")
        expectEqual(editor.selectedShapeIDs, [api], "a pick leaves the selection on the API")
        for _ in 0..<3 where editor.editingShapeID != nil { walk.press(.escape) }
        expectEqual(editor.editingShapeID, nil, "Escape: out of the API")
        expectEqual(editor.selectedShapeIDs, [api], "connect 15: Escape is back on the API, never the arrow (E7 panel 4)")
        expectEqual(editor.adornmentFrames(of: arrow.id).map(\.label.text), ["writes"], "the writes pill on its line (E7 panel 4)")
        editor.undo()
        expectEqual(editor.document[arrow.id]?[ChannelProperty.self], nil, "one Undo: the plain arrow")
        editor.undo()
        expectEqual(editor.document, start, "two: none")
    },
    test("a column cut on the root and pasted into a table on another board brings its key back through a pill for the table it references, the column on the binding") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        // The list the release queues is read off the editor; the window never pops it (its tracking would wait for a person).
        w.canvas.menuPresenter = { _, _, _ in }
        try w.turnKitOn()
        _ = try drawnInProcess(#"""
            table "customers" columns: "id uuid pk\nemail text unique"
            table "orders" right of "customers" (gap: 140) columns: "id uuid pk\ncustomer_id uuid → customers.id"
            subboard "billing" below "customers" (gap: 200)
            """#, on: editor)
        _ = try drawnInProcess(#"table "invoices" in "billing" columns: "id uuid pk""#, on: editor)
        let customers = try require(shape(editor, "customers")?.typed(as: DatabaseTable.self))
        let orders = try require(shape(editor, "orders")?.typed(as: DatabaseTable.self))
        let billing = BoardID(owner: try require(shape(editor, "billing")).id)
        editor.undoHistory.seal()
        let walk = w.walk()
        editor.selectedShapeIDs = [orders.id]
        editor.selectItems([AnyHashable(orders.props.columns[1].id)], of: orders.id)
        walk.press(Chord("x", .command))
        expectEqual(undoTitle(w.window), "Undo Cut Column and 1 Arrow")
        expect(editor.showBoard(billing))
        w.window.makeFirstResponder(w.canvas)
        let invoices = try require(editor.document.shapes.first { $0[TitleProperty.self] == "invoices" }?.typed(as: DatabaseTable.self))
        editor.selectedShapeIDs = [invoices.id]
        editor.selectItems([AnyHashable(invoices.props.columns[0].id)], of: invoices.id)
        walk.press(Chord("v", .command))
        expectEqual(editor.document[invoices.id]?.typed(as: DatabaseTable.self)?.props.columns.map(\.name), ["id", "customer_id"])
        let key = try require(arrows(editor).first { $0[ChannelProperty.self] == ForeignKey.id }, "the key came back")
        let pill = try require(editor.document[try require(key.props.end.binding?.shapeID)]?.typed(as: Reference.self))
        expectEqual(pill.props.target?.id, customers.id, "through a pill for customers")
        expectEqual(key.props.end.binding?.part, customers.props.columns[0].id, "on customers.id")
        expectEqual(undoTitle(w.window), "Undo Paste Column")
        // The column is new in the step that puts its pill down: the pill is landed by the row as the step leaves it.
        let pasted = try require(editor.document[invoices.id]?.typed(as: DatabaseTable.self)?.props.columns.last?.id)
        try expectClean(key.id, from: invoices.id, row: pasted, in: editor, "rows pasted on another board")
    },
    test("an endpoint cut on the root and pasted into an API on another board brings its calls arrow back through a pill for the endpoint it calls") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        // The list the release queues is read off the editor; the window never pops it (its tracking would wait for a person).
        w.canvas.menuPresenter = { _, _, _ in }
        try w.turnKitOn()
        _ = try drawnInProcess(#"""
            api "orders API" endpoints: "POST /orders"
            api "storefront API" right of "orders API" (gap: 140) endpoints: "GET /checkout\nGET /cart"
            edge "storefront API"."GET /checkout" -> "orders API"."POST /orders" channel: calls
            subboard "web" below "orders API" (gap: 200)
            """#, on: editor)
        _ = try drawnInProcess(#"api "web API" in "web" endpoints: "GET /home""#, on: editor)
        let orders = try require(shape(editor, "orders API")?.typed(as: API.self))
        let storefront = try require(shape(editor, "storefront API")?.typed(as: API.self))
        let web = BoardID(owner: try require(shape(editor, "web")).id)
        expectEqual(arrows(editor).first?[ChannelProperty.self], Calls.id, "drawn on calls")
        editor.undoHistory.seal()
        let walk = w.walk()
        editor.selectedShapeIDs = [storefront.id]
        editor.selectItems([AnyHashable(storefront.props.endpoints[0].id)], of: storefront.id)
        walk.press(Chord("x", .command))
        expect(editor.showBoard(web))
        w.window.makeFirstResponder(w.canvas)
        let target = try require(editor.document.shapes.first { $0[TitleProperty.self] == "web API" }?.typed(as: API.self))
        editor.selectedShapeIDs = [target.id]
        editor.selectItems([AnyHashable(target.props.endpoints[0].id)], of: target.id)
        walk.press(Chord("v", .command))
        let call = try require(arrows(editor).first { $0[ChannelProperty.self] == Calls.id }, "the call came back")
        let pill = try require(editor.document[try require(call.props.end.binding?.shapeID)]?.typed(as: Reference.self))
        expectEqual(pill.props.target?.id, orders.id)
        expectEqual(pill.props.target?.row, orders.props.endpoints[0].id, "a pill for POST /orders itself")
        expect(!undoTitle(w.window).contains("left out"))
        let pasted = try require(editor.document[target.id]?.typed(as: API.self)?.props.endpoints.last?.id)
        try expectClean(call.id, from: target.id, row: pasted, in: editor, "an endpoint pasted on another board")
    },
    test("an endpoint cut on the root and pasted on its own (nothing selected) on another board becomes an API there with its calls arrow through a pill, nothing left out") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        w.canvas.menuPresenter = { _, _, _ in }
        try w.turnKitOn()
        _ = try drawnInProcess(#"""
            api "orders API" endpoints: "POST /orders"
            api "storefront API" right of "orders API" (gap: 140) endpoints: "GET /checkout\nGET /cart"
            edge "storefront API"."GET /checkout" -> "orders API"."POST /orders" channel: calls
            subboard "web" below "orders API" (gap: 200)
            """#, on: editor)
        let orders = try require(shape(editor, "orders API")?.typed(as: API.self))
        let storefront = try require(shape(editor, "storefront API")?.typed(as: API.self))
        let web = BoardID(owner: try require(shape(editor, "web")).id)
        editor.undoHistory.seal()
        let walk = w.walk()
        editor.selectedShapeIDs = [storefront.id]
        editor.selectItems([AnyHashable(storefront.props.endpoints[0].id)], of: storefront.id)
        walk.press(Chord("x", .command))
        expect(editor.showBoard(web))
        w.window.makeFirstResponder(w.canvas)
        editor.selectedShapeIDs = []
        walk.press(Chord("v", .command))
        let made = try require(editor.document.shapes.first { $0.typed(as: API.self) != nil }, "the endpoint landed as an API of its own")
        let call = try require(arrows(editor).first { $0[ChannelProperty.self] == Calls.id }, "the call came back")
        expectEqual(call.props.start.binding?.shapeID, made.id)
        let pill = try require(editor.document[try require(call.props.end.binding?.shapeID)]?.typed(as: Reference.self))
        expectEqual(pill.props.target?.id, orders.id)
        expectEqual(pill.props.target?.row, orders.props.endpoints[0].id, "a pill for POST /orders itself")
        expect(!undoTitle(w.window).contains("left out"), "nothing left out: \(undoTitle(w.window))")
    },
])

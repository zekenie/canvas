import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
@_spi(Host) import CanvasUI
import Connections
import ContextMenus
import Engineering
import Geometry
import LanguageModels
import Selection
import ShippedTesting
import TestKit
import Titles

// Keys look right, as shipped (K4): every key drawn by `canvas draw` is a level curve from its column's row to the row it
// references, 2.5 wide; T3 panel 4's marks (a unique column's key bars at both ends, a nullable one's a bar and a circle at
// the row it references) and a column changed in place redrawing its key's marks with nothing written to the arrow; an arrow
// from a row to a table as a whole meeting it at a row clear of a key's end there; and a key's ends leaving Toggle Arrowhead out.

private let billing = #"""
    table "payments" columns: "id uuid pk\norder_id uuid unique\namount_cents int"
    table "refunds" right of "payments" columns: "id uuid pk\npayment_id uuid null\namount_cents int"
    table "orders" left of "payments" columns: "id uuid pk\ncustomer_id uuid"
    edge "payments".order_id -> "orders".id
    edge "refunds".payment_id -> "payments".id
    """#

@MainActor private func billingEditor() throws -> CanvasEditor {
    let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
    editor.viewportDidResize(to: CGSize(width: 1440, height: 900))
    _ = try drawnInProcess(billing, on: editor)
    return editor
}

@MainActor private func table(_ editor: CanvasEditor, _ title: String) throws -> ShapeRecord<DatabaseTable> {
    try require(editor.document.shapes.first { $0[TitleProperty.self] == title }?.typed(as: DatabaseTable.self))
}

/// The key that starts at `table`'s `column`.
@MainActor private func key(_ editor: CanvasEditor, from title: String, _ column: String) throws -> ShapeRecord<Arrow> {
    let from = try table(editor, title)
    let part = try require(from.props.columns.first { $0.name == column }?.id)
    return try require(editor.document.shapes.compactMap { $0.typed(as: Arrow.self) }.first { $0.props.start.binding?.part == part })
}

@MainActor let keyLookShippedTests = Suite("Keys look right, shipped", [
    test("UX walk 3 tables-1: three keys between tables 75 apart, two fanned into one row, each run one way across with its marks level, drawn in the window") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        try w.turnKitOn()
        try w.draw(#"""
            table "customers" columns: "id uuid pk\nemail text unique\nname text"
            table "orders" right of "customers" (gap: 75) columns: "id uuid pk\ncustomer_id uuid\nbilling_customer_id uuid\nshipping_customer_id uuid null"
            edge "orders".customer_id -> "customers".id
            edge "orders".billing_customer_id -> "customers".id
            edge "orders".shipping_customer_id -> "customers".email
            """#)
        w.window.settle()
        let editor = w.editor
        let keys = editor.document.shapes.compactMap { $0.typed(as: Arrow.self) }
        expectEqual(keys.count, 3)
        let left = try require(editor.shapeContext.geometry(of: try table(editor, "customers").id)?.bounds)
        let right = try require(editor.shapeContext.geometry(of: try table(editor, "orders").id)?.bounds)
        expectClose(right.minX - left.maxX, 75, within: 1)
        var bounds = CGRect.null
        for arrow in keys {
            let geometry = try require(editor.arrowGeometry(of: arrow.id)), body = try require(geometry.levelBody)
            let xs = body.flattened().map(\.x)
            expect(zip(xs, xs.dropFirst()).allSatisfy { $1 <= $0 + 1e-6 }, "one way across, never back behind its start: \(xs.max() ?? 0)…\(xs.min() ?? 0)")
            for distance: CGFloat in [12, 17.5] {
                expectClose(geometry.point(distance, along: .end).inward.y, 0, within: 1e-6)
                expectClose(geometry.point(distance, along: .start).inward.y, 0, within: 1e-6)
            }
            bounds = bounds.union(body.bounds)
        }
        editor.camera = Camera(origin: CGPoint(x: bounds.minX - 40, y: bounds.minY - 40), zoom: 1)
        let rep = renderBitmap(editor, size: CGSize(width: bounds.width + 80, height: bounds.height + 80))
        for arrow in keys {
            let middle = try require(editor.arrowGeometry(of: arrow.id)?.levelBody).measured().point(atFraction: 0.5)
            let p = pixel(rep, at: editor.camera.toView(middle))
            expect(p[0] < 120, "each key drawn in the gap: \(p) at \(middle)")
        }
    },
    test("UX walk 3 and 4 structure-1: a key passing under a table it isn't bound to is drawn faint across the whole of it, joined where it goes under and comes out, in light and dark") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        try w.turnKitOn()
        try w.draw(#"""
            table "customers" columns: "id uuid pk\nemail text"
            table "orders" right of "customers" (gap: 60) columns: "id uuid pk\nstatus text\ntotal_cents int\nplaced_at timestamptz"
            table "payments" right of "orders" (gap: 60) columns: "id uuid pk\namount_cents int\ncustomer_id uuid"
            edge "payments".customer_id -> "customers".id
            """#)
        w.window.settle()
        let editor = w.editor
        let orders = try require(editor.shapeContext.geometry(of: try table(editor, "orders").id)?.bounds)
        let key = try require(editor.document.shapes.compactMap { $0.typed(as: Arrow.self) }.first)
        let body = try require(editor.arrowGeometry(of: key.id)?.levelBody)
        let points = body.flattened(segments: 800)
        let under = try require(points.min { abs($0.x - orders.midX) < abs($1.x - orders.midX) })
        expect(orders.insetBy(dx: 4, dy: 4).contains(under), "the key passes under orders: \(under) in \(orders)")
        // Just inside where it goes under and where it comes out: the faint line joins the line drawn outside.
        let entering = try require(points.first { orders.insetBy(dx: 3, dy: 3).contains($0) })
        let leaving = try require(points.last { orders.insetBy(dx: 3, dy: 3).contains($0) })
        editor.camera = Camera(origin: CGPoint(x: orders.minX - 40, y: orders.minY - 40), zoom: 1)
        for dark in [false, true] {
            var drawn: NSBitmapImageRep?
            try require(NSAppearance(named: dark ? .darkAqua : .aqua)).performAsCurrentDrawingAppearance {
                drawn = renderBitmap(editor, size: CGSize(width: orders.width + 80, height: orders.height + 80))
            }
            let rep = try require(drawn)
            // Beside the line, the paper (light in both appearances); on it, darker than the paper and lighter than a line drawn whole.
            for point in [entering, under, leaving] {
                var paperPoint = point + CGPoint(x: 0, y: 8)
                if !orders.insetBy(dx: 2, dy: 2).contains(paperPoint) { paperPoint = point - CGPoint(x: 0, y: 8) }
                let on = pixel(rep, at: editor.camera.toView(point)), paper = pixel(rep, at: editor.camera.toView(paperPoint))
                expect(on[0] < paper[0] - 15, "\(dark ? "dark" : "light"): drawn across the table at \(point), faint: \(on) on paper \(paper)")
                expect(on[0] > 90, "\(dark ? "dark" : "light"): but faint: \(on)")
            }
        }
    },
    test("UX walk 4 tables-1 and tables-2: in a 75 gap two keys into one row keep their bars apart, and keys between the two tables cross once, where their ends swap") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        try w.turnKitOn()
        try w.draw(#"""
            table "customers" columns: "id uuid pk\nemail text unique\nname text"
            table "orders" right of "customers" (gap: 75) columns: "id uuid pk\ncustomer_id uuid? → customers.id\nbilling_customer_id uuid? → customers.email\nshipping_customer_id uuid → customers.id"
            """#)
        w.window.settle()
        let editor = w.editor
        @MainActor func key(_ column: String) throws -> ArrowGeometry {
            let orders = try table(editor, "orders"), part = try require(orders.props.columns.first { $0.name == column }?.id)
            let arrow = try require(editor.document.shapes.compactMap { $0.typed(as: Arrow.self) }.first { [$0.props.start.binding?.part, $0.props.end.binding?.part].contains(part) })
            return try require(editor.arrowGeometry(of: arrow.id))
        }
        let (customer, billing, shipping) = (try key("customer_id"), try key("billing_customer_id"), try key("shipping_customer_id"))
        // At customers.id, the customer and shipping keys' bars (12 and 17.5 out, 9 either side of the line) are never on each other.
        @MainActor func bars(_ geometry: ArrowGeometry, at end: ArrowEnd) -> [CGPoint] {
            let offset = end == .start ? geometry.markOffset.start : geometry.markOffset.end
            return [12, 17.5].map { geometry.point($0 + offset, along: end).point }
        }
        @MainActor func idEnd(_ geometry: ArrowGeometry) -> ArrowEnd { geometry.start.x < geometry.end.x ? .start : .end }
        let a = bars(customer, at: idEnd(customer)), b = bars(shipping, at: idEnd(shipping))
        for p in a { for q in b where abs(p.x - q.x) < 4 { expect(abs(p.y - q.y) > 18 + 2.5, "no bars on each other at customers.id: \(a) \(b)") } }
        // billing leaves email (below id) for a row above shipping's: they swap, and cross once; customer and billing keep their order.
        @MainActor func crossings(_ g: ArrowGeometry, _ h: ArrowGeometry) throws -> Int {
            let p = try require(g.levelBody).flattened(segments: 160), q = try require(h.levelBody).flattened(segments: 160)
            func cross(_ o: CGPoint, _ u: CGPoint, _ v: CGPoint) -> CGFloat { (u.x - o.x) * (v.y - o.y) - (u.y - o.y) * (v.x - o.x) }
            var count = 0
            for i in 1..<p.count { for j in 1..<q.count {
                let d1 = cross(q[j - 1], q[j], p[i - 1]), d2 = cross(q[j - 1], q[j], p[i]), d3 = cross(p[i - 1], p[i], q[j - 1]), d4 = cross(p[i - 1], p[i], q[j])
                if (d1 > 0) != (d2 > 0), (d3 > 0) != (d4 > 0) { count += 1 }
            } }
            return count
        }
        expectEqual(try crossings(billing, shipping), 1, "swapped: once")
        expectEqual(try crossings(customer, billing), 0, "in order: never")
        // In the gap too narrow to stagger, the two keys' ends spread across customers.id but stay inside it, never on the line
        // between it and the next row (review U12-E3).
        let customers = try table(editor, "customers")
        let idRow = try require(editor.shapeContext.geometry(of: customers.id)?.parts.frame(try require(customers.props.columns.first { $0.name == "id" }?.id))?.rect)
        for geometry in [customer, shipping] {
            let y = geometry.point(0, along: idEnd(geometry)).point.y
            expect(y > idRow.minY + 1 && y < idRow.maxY - 1, "inside customers.id: \(y) in \(idRow.minY)...\(idRow.maxY)")
        }
        // Keys that keep their order run a column apart through the gap, not on top of each other (review U12-E8): the customer and billing
        // keys, where they pass the middle half of it, are at least a stroke and a gap apart.
        let gap = try require(editor.shapeContext.geometry(of: customers.id)?.bounds).maxX
        let (one, other) = (try require(customer.levelBody), try require(billing.levelBody))
        for point in one.flattened(segments: 200) where point.x > gap + 75 * 0.3 && point.x < gap + 75 * 0.7 {
            expect(other.distance(to: point) > 5, "the keys in order apart in the gap's middle: \(point) is \(other.distance(to: point)) from the other")
        }
    },
    test("T3 panel 4: a unique column's key is bars at both ends, a nullable one's a bar and a circle at the row it references; both level, 2.5 wide") {
        let editor = try billingEditor()
        let unique = try key(editor, from: "payments", "order_id"), nullable = try key(editor, from: "refunds", "payment_id")
        expectEqual(editor.arrowLook(of: unique.id), ConnectionLook(start: .one, end: .one, lineWidth: 2.5))
        expectEqual(editor.arrowLook(of: nullable.id), ConnectionLook(start: .many, end: .zeroOrOne, lineWidth: 2.5))
        for id in [unique.id, nullable.id] {
            expect(try require(editor.arrowGeometry(of: id)).isLevel, "a key is a level curve")
            expectEqual(editor.registry.lineWidth(of: try require(editor.document[id]), in: editor.shapeContext), 2.5)
        }
        // payments is right of orders: the key leaves order_id's left side going left and enters orders.id's right side.
        let geometry = try require(editor.arrowGeometry(of: unique.id))
        expectEqual(geometry.partSide(at: .start), .left)
        expectEqual(geometry.partSide(at: .end), .right)
    },
    test("structure new-2: two keys to one row's end lay their bars on each other, level where the bars stop, and never run under the tables between them") {
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
        editor.viewportDidResize(to: CGSize(width: 1440, height: 900))
        _ = try drawnInProcess(#"""
            table "customers" columns: "id uuid pk\nemail text unique"
            table "orders" right of "customers" (gap: 40) columns: "id uuid pk\ncustomer_id uuid"
            table "invoices" below "orders" columns: "id uuid pk\ncustomer_id uuid"
            edge "orders".customer_id -> "customers".id
            edge "invoices".customer_id -> "customers".id
            """#, on: editor)
        let customers = try table(editor, "customers").id, side = try require(editor.shapeContext.geometry(of: customers)?.bounds)
        let keys = [try key(editor, from: "orders", "customer_id"), try key(editor, from: "invoices", "customer_id")]
        var bars: [CGPoint] = []
        for arrow in keys {
            let geometry = try require(editor.arrowGeometry(of: arrow.id))
            expectEqual(geometry.partSide(at: .end), .right, "at customers.id's right side")
            // 17.5 in, a bar's reach (the crow's foot's end is at the other table's row): still level there.
            let (at, inward) = geometry.point(10, along: .end)
            expect(abs(inward.y) <= 0.25 * abs(inward.x) + 1e-6, "level where the bars are: \(inward)")
            bars.append(at)
            // Never to the left of customers' side at the end, nor past the far table's side: the curve stays between the tables.
            if case .level(let cubic, _, _) = geometry.path {
                let xs = cubic.flattened().map(\.x)
                let tables = [try table(editor, "orders").id, try table(editor, "invoices").id].compactMap { editor.shapeContext.geometry(of: $0)?.bounds }
                expect((xs.min() ?? 0) >= side.maxX - 1, "not under customers: \(xs.min() ?? 0) \(side)")
                expect((xs.max() ?? 0) <= (tables.map(\.minX).min() ?? 0) + 1, "not under the tables it joins")
            }
        }
        expect(bars[0].distance(to: bars[1]) < 1.5, "the bars of both keys on each other: \(bars)")
    },
    test("structure new-1: a row's resting dot isn't drawn on the side its key leaves by (the mark is there), and is on the other; hovered it shows") {
        let w = try KeyDragWindow(#"""
            table "orders" columns: "id uuid pk\ncustomer_id uuid"
            table "payments" right of "orders" columns: "id uuid pk\norder_id uuid"
            edge "payments".order_id -> "orders".id
            """#)
        let row = try w.row("payments", 1), size = CGSize(width: 800, height: 600)
        let left = CGPoint(x: row.minX - 12, y: row.midY), right = CGPoint(x: row.maxX + 12, y: row.midY)
        let middle = { (center: CGPoint) in CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4) }
        w.move(to: CGPoint(x: 5, y: 590))
        let away = renderBitmap(w.editor, size: size)
        w.move(to: CGPoint(x: row.midX, y: row.midY))
        let shown = renderBitmap(w.editor, size: size)
        expectEqual(changedPixels(away, shown, in: middle(left)), 0, "none on the left, where the key leaves order_id")
        expect(changedPixels(away, shown, in: middle(right)) > 0, "the right side's, where nothing ends")
        w.move(to: left)
        expect(changedPixels(away, renderBitmap(w.editor, size: size), in: middle(left)) > 0, "hovered, the taken side's shows for another drag")
    },
    test("a column changed in place redraws its key's marks, with nothing written to the key; Undo puts them back") {
        let editor = try billingEditor()
        let id = try key(editor, from: "refunds", "payment_id").id
        let before = try key(editor, from: "refunds", "payment_id")
        let refunds = try table(editor, "refunds")
        editor.transact("Change Column") { tx in
            tx.update(refunds.id, as: DatabaseTable.self) { table in
                guard let index = table.props.columns.firstIndex(where: { $0.name == "payment_id" }) else { return }
                table.props.columns[index].nullable = false
                table.props.columns[index].unique = true
            }
        }
        expectEqual(editor.arrowLook(of: id), ConnectionLook(start: .one, end: .one, lineWidth: 2.5))
        expectEqual(try key(editor, from: "refunds", "payment_id").props, before.props, "the key as it was")
        editor.undo()
        expectEqual(editor.arrowLook(of: id), ConnectionLook(start: .many, end: .zeroOrOne, lineWidth: 2.5))
    },
    test("an arrow from a row to a table as a whole meets the table at the side facing it, at a row clear of the key that ends at its first row there (K17)") {
        let editor = try billingEditor()
        let refunds = try table(editor, "refunds"), payments = try table(editor, "payments")
        var arrow = ShapeRecord(Arrow(start: .bound(ArrowBinding(shapeID: refunds.id, normalizedAnchor: CGPoint(x: 0, y: 0.5), isPrecise: true,
                                                                 isExact: true, part: refunds.props.columns[2].id)),
                                      end: .bound(ArrowBinding(shapeID: payments.id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false,
                                                               isExact: false)), endArrowhead: false))
        arrow[ChannelProperty.self] = ForeignKey.id
        editor.transact("Add Arrow") { $0.insert(AnyShapeRecord(arrow)) }
        let geometry = try require(editor.arrowGeometry(of: arrow.id))
        // refunds' key ends at payments' id, its first row, on the side facing refunds: the arrow comes in at amount_cents, the
        // first row there with no key's end beside it, so the two don't read as one tangle at the corner.
        let clear = try require(editor.shapeContext.geometry(of: payments.id)?.parts.frame(payments.props.columns[2].id)).rect
        let body = try require(geometry.levelBody)
        expectEqual(body.end, CGPoint(x: clear.maxX, y: clear.midY), "payments' amount_cents row's right side, facing refunds")
        expectEqual(geometry.end, body.end, "a marked end: no gap")
    },
    test("inside a database a row's side with no room is the side its key is drawn at, and the bundles pick a line's entry row by that same side; the database resized, they are worked out again (review U9-R5, U9-R6)") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        try w.turnKitOn()
        try w.draw(#"database "shop" size: 700x500"#)
        try w.draw(#"""
            table "customers" in "shop" columns: "id uuid pk\nname text"
            table "orders" in "shop" columns: "id uuid pk\ncustomer_id uuid\ntotal int"
            table "items" in "shop" columns: "id uuid pk\norder_id uuid"
            """#)
        let editor = w.editor
        let shop = try require(editor.document.shapes.first { $0[TitleProperty.self] == "shop" }).id
        let (customers, orders, items) = (try table(editor, "customers"), try table(editor, "orders"), try table(editor, "items"))
        @MainActor func place(_ id: ShapeID, _ frame: CGRect) { editor.transact("Place") { $0.update(id, as: DatabaseTable.self) { $0.props.frame = frame } } }
        place(customers.id, CGRect(x: 100, y: 100, width: 240, height: 116))
        place(orders.id, CGRect(x: 400, y: 100, width: 260, height: 116))
        place(items.id, CGRect(x: 400, y: 300, width: 260, height: 92))
        @MainActor func resize(maxX: CGFloat) {
            editor.transact("Resize") { $0.update(shop, as: Database.self) { $0.props.frame = CGRect(x: 80, y: 60, width: maxX - 80, height: 500) } }
        }
        @MainActor func foreignKey(_ from: (ShapeRecord<DatabaseTable>, Int), _ to: (ShapeRecord<DatabaseTable>, Int?)) -> ShapeID {
            var arrow = ShapeRecord(Arrow(start: .bound(ArrowBinding(shapeID: from.0.id, normalizedAnchor: CGPoint(x: 1, y: 0.5), isPrecise: true, isExact: true,
                                                                       part: from.0.props.columns[from.1].id)),
                                          end: .bound(ArrowBinding(shapeID: to.0.id, normalizedAnchor: CGPoint(x: to.1 == nil ? 0.5 : 0, y: 0.5), isPrecise: to.1 != nil,
                                                                   isExact: to.1 != nil, part: to.1.map { to.0.props.columns[$0].id })), endArrowhead: false))
            arrow[ChannelProperty.self] = ForeignKey.id
            editor.transact("Add Arrow") { $0.insert(AnyShapeRecord(arrow)) }
            return arrow.id
        }
        let (o, i, c) = (try table(editor, "orders"), try table(editor, "items"), try table(editor, "customers"))
        // orders.id to items.id, stacked tables sided together; customers.id to orders as a whole, from the left.
        resize(maxX: 680)
        let key = foreignKey((o, 0), (i, 0)), whole = foreignKey((c, 0), (o, nil))
        // 12 to the right of orders' rows inside the database, 312 to their left of its own edge: both leave the left.
        let narrow = try require(editor.arrowGeometry(of: key))
        expectEqual(narrow.partSide(at: .start), .left, "no room right of orders inside the database: it leaves the left")
        let taken = try require(editor.connectionBundle(of: whole)?.entries[.end], "the line into orders from the left comes in clear of the key's row there")
        expect(taken != o.props.columns[0].id, "not the row the key leaves by")
        // The database widened: the right has room, the key leaves it, and nothing is at the left to come in clear of.
        resize(maxX: 900)
        expectEqual(try require(editor.arrowGeometry(of: key)).partSide(at: .start), .right, "room right: the right")
        expectEqual(editor.connectionBundle(of: whole)?.entries[.end], nil, "worked out again with the database: the first row is clear")
    },
    test("one row's keys to two tables at one height are parted in the board's order, whatever a set's order is (review U9-C6)") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        try w.turnKitOn()
        let editor = w.editor
        for (round, names) in [["alpha", "beta"], ["gamma", "delta"], ["omega", "eta"]].enumerated() {
            try w.draw(#"table "src_\#(names[0])" columns: "id uuid pk\nref_a uuid\nref_b uuid""#)
            try w.draw(#"table "\#(names[0])" columns: "id uuid pk""#)
            try w.draw(#"table "\#(names[1])" columns: "id uuid pk""#)
            let (src, first, second) = (try table(editor, "src_\(names[0])"), try table(editor, names[0]), try table(editor, names[1]))
            // Aligned: one height, so only the board's order tells them apart.
            let top = CGFloat(100 + round * 600)
            editor.transact("Place") {
                $0.update(src.id, as: DatabaseTable.self) { $0.props.frame = CGRect(x: 0, y: top, width: 200, height: 100) }
                $0.update(first.id, as: DatabaseTable.self) { $0.props.frame = CGRect(x: 500, y: top, width: 200, height: 70) }
                $0.update(second.id, as: DatabaseTable.self) { $0.props.frame = CGRect(x: 800, y: top, width: 200, height: 70) }
            }
            // Two rows of src each to both tables: each far end is fanned (two rows into it), each row's keys part for two places.
            var ids: [[ShapeID]] = []
            for row in [1, 2] {
                var made: [ShapeID] = []
                for target in [first, second] {
                    var arrow = ShapeRecord(Arrow(start: .bound(ArrowBinding(shapeID: src.id, normalizedAnchor: CGPoint(x: 1, y: 0.5), isPrecise: true, isExact: true,
                                                                               part: src.props.columns[row].id)),
                                                  end: .bound(ArrowBinding(shapeID: target.id, normalizedAnchor: CGPoint(x: 0, y: 0.5), isPrecise: true, isExact: true,
                                                                           part: target.props.columns[0].id)), endArrowhead: false))
                    arrow[ChannelProperty.self] = ForeignKey.id
                    editor.transact("Add Arrow") { $0.insert(AnyShapeRecord(arrow)) }
                    made.append(arrow.id)
                }
                ids.append(made)
            }
            for made in ids {
                expectEqual(made.map { editor.connectionBundle(of: $0)?.parting?.index }, [0, 1], "in the board's order: \(names)")
            }
        }
    },
    test("a key's ends have no head to toggle: the Shape menu leaves Toggle Arrowhead out, a plain arrow keeps it") {
        let editor = try billingEditor()
        editor.selection = try key(editor, from: "payments", "order_id").id
        let outline = try require(editor.menuForSelection(omitting: [])).outline
        expect(!outline.contains("Toggle Start Arrowhead") && !outline.contains("Toggle End Arrowhead"), "\(outline)")
        let plain = ShapeRecord(Arrow(start: .free(CGPoint(x: 0, y: 900)), end: .free(CGPoint(x: 200, y: 900))))
        editor.transact("Add Arrow") { $0.insert(AnyShapeRecord(plain)) }
        editor.selection = plain.id
        expect(try require(editor.menuForSelection(omitting: [])).outline.contains("Toggle End Arrowhead"))
    },
])

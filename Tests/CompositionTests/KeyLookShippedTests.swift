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
    test("UX walk 3 structure-1: a key passing under a table it isn't bound to is drawn faint across that table, so it doesn't read as ending at its row") {
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
        let under = try require(body.flattened(segments: 400).min { abs($0.x - orders.midX) < abs($1.x - orders.midX) })
        expect(orders.insetBy(dx: 4, dy: 4).contains(under), "the key passes under orders: \(under) in \(orders)")
        editor.camera = Camera(origin: CGPoint(x: orders.minX - 40, y: orders.minY - 40), zoom: 1)
        let rep = renderBitmap(editor, size: CGSize(width: orders.width + 80, height: orders.height + 80))
        // Beside the line, the paper; on it, something darker than the paper and lighter than the line itself.
        var paperPoint = under + CGPoint(x: 0, y: 8)
        if !orders.insetBy(dx: 4, dy: 4).contains(paperPoint) { paperPoint = under - CGPoint(x: 0, y: 8) }
        let on = pixel(rep, at: editor.camera.toView(under)), paper = pixel(rep, at: editor.camera.toView(paperPoint))
        expect(on[0] < paper[0] - 15, "drawn across the table, faint: \(on) on paper \(paper)")
        expect(on[0] > 90, "but faint, under its words: \(on)")
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

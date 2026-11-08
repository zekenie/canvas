import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Connections
import Engineering
import Find
import LineRows
import Selection
import TestKit
import Titles
import Topology

// Folds and Find on the kit's kinds: a table folds to its keys and unique columns, an enum to its first two values, laid
// out at the height of the lines shown with a "+N ›" line last; a key to a hidden row ends at that line; a key drawn to a
// folded table shows its column at once; Find finds a table's rows a text a row, and a folded table shows its hit rows while
// Find is open (T6, panel 4).

/// products: id uuid pk, sku text unique, weight_grams int, then 37 more: T6's.
@MainActor func products(at origin: CGPoint = CGPoint(x: 100, y: 100)) -> DatabaseTable {
    let first = ["id uuid pk", "sku text unique", "weight_grams int"].compactMap { ColumnGrammar.read($0) }
    let more = (1...37).compactMap { ColumnGrammar.read("note_\($0) text") }
    var table = DatabaseTable(frame: CGRect(origin: origin, size: CGSize(width: 300, height: 0)), columns: first + more)
    table.frame.size.height = KitStyle.height(rows: table.columns.count)
    return table
}

@MainActor func laidOut(_ editor: CanvasEditor, _ id: ShapeID) throws -> CGRect {
    try require(editor.shapeContext.frame(of: try require(editor.document[id])))
}

@MainActor func shown(_ editor: CanvasEditor, _ id: ShapeID) throws -> RowsShown? {
    editor.shapeContext.layoutInput(LineRowsLayout.shown, of: try require(editor.document[id]))
}

@MainActor let foldTests = Suite("Folds and Find on the kit", [
    test("T6 panel 4: ⌃⌘↑ folds products to its keys, id and sku, with +38 ›, laid out at four lines; ⌃⌘↓ unfolds") {
        let h = try EditorHarness(plugins: kitPlugins())
        h.editor.viewportDidResize(to: CGSize(width: 1000, height: 800))
        let id = h.add(products(), titled: "products")
        let stored = try laidOut(h.editor, id)
        h.editor.selectedShapeIDs = [id]
        expect(h.editor.perform(.foldRows))
        let folded = try require(try shown(h.editor, id))
        expectEqual(folded.lines, [.row(0), .row(1), .more(38)])
        let frame = try laidOut(h.editor, id)
        expectEqual(frame.height, KitStyle.height(rows: 3))
        expectEqual(frame.width, stored.width)
        expectEqual(h.editor.document[id]?.box?.height, stored.height, "nothing written")
        let geometry = try require(h.editor.shapeContext.geometry(of: id))
        let weight = try require(h.editor.document[id]?.typed(as: DatabaseTable.self)?.props.columns[2].id)
        expectEqual(geometry.parts.frame(weight)?.rect, KitStyle.rowRect(2, in: frame), "a hidden column's rect is the +N line")
        expect(h.editor.perform(.unfoldRows))
        expectEqual(try laidOut(h.editor, id), stored)
    },
    test("an enum folds to its first two values, pending and paid, then +4 ›") {
        let h = try kitHarness()
        let id = h.add(DatabaseEnum(frame: CGRect(x: 100, y: 100, width: 200, height: 0),
                                    values: ["pending", "paid", "shipped", "delivered", "refunded", "void"].map { EnumValue(text: $0) }), titled: "order_status")
        h.editor.rowFolds?.fold([id])
        expectEqual(try shown(h.editor, id)?.lines, [.row(0), .row(1), .more(4)])
        expectEqual(try laidOut(h.editor, id).height, KitStyle.height(rows: 3))
    },
    test("a column that starts a key is kept by a fold; one a key reaches as it's drawn shows at once; a key's end on a hidden row is at the +N line") {
        let k = try KeyBoard()
        let editor = k.editor
        editor.rowFolds?.fold([k.orders, k.customers])
        expectEqual(try shown(editor, k.orders)?.lines, [.row(0), .more(2)], "orders: id")
        k.key(k.orders, "customer_id", to: k.customers, "email")
        expectEqual(try shown(editor, k.orders)?.lines, [.row(0), .row(1), .more(1)], "customer_id starts a key: kept, at once")
        let placed = k.column(k.orders, "placed_at")
        let frame = try laidOut(editor, k.orders)
        expectEqual(editor.shapeContext.geometry(of: k.orders)?.parts.frame(placed)?.rect, KitStyle.rowRect(2, in: frame),
                    "placed_at, hidden, is where +1 is: what an arrow bound to it ends at")
        editor.undo()
        expectEqual(try shown(editor, k.orders)?.lines, [.row(0), .more(2)], "the key undone: hidden again")
    },
    test("a commit to a folded table keeps it folded; editing it shows every column and the fold comes back as editing ends") {
        let b = try KitBench()
        let id = b.h.add(products(), titled: "products")
        b.editor.rowFolds?.fold([id])
        b.editor.transact("Rename") { $0.update(id, as: DatabaseTable.self) { $0.props.columns[5].name = "renamed" } }
        expectEqual(try shown(b.editor, id)?.lines, [.row(0), .row(1), .more(38)], "still folded")
        b.begin(id)
        expectEqual(try shown(b.editor, id), nil, "every row while edited")
        expectEqual(try laidOut(b.editor, id).height, KitStyle.height(rows: 41), "the columns and the waiting line")
        b.press(.escape)
        expectEqual(try laidOut(b.editor, id).height, KitStyle.height(rows: 3), "folded again")
    },
    test("T6 panel 4, ⌘F weight: Find finds a text a column, by its row's id; the folded table shows weight_grams while Find is open, then +37 ›") {
        let h = try EditorHarness(plugins: kitPlugins(find: true))
        h.editor.viewportDidResize(to: CGSize(width: 1000, height: 800))
        h.editor.turn(EngineeringKit.self, on: true)
        let id = h.add(products(), titled: "products")
        h.editor.rowFolds?.fold([id])
        let find = try require(h.editor.find)
        find.open()
        find.query = "weight"
        var turns = 0
        while find.isIndexing, turns < 10_000 {
            h.wait(0)
            turns += 1
        }
        _ = try awaitResult { await find.settled() }
        expect(find.texts(of: id).contains("weight_grams int"), "a column's name and type: \(find.texts(of: id).prefix(5))")
        expectEqual(find.results.map(\.id), [id], "one result a shape")
        let weight = try require(h.editor.document[id]?.typed(as: DatabaseTable.self)?.props.columns[2].id)
        expectEqual(find.fieldsHit(of: id), [weight.description])
        expectEqual(try shown(h.editor, id)?.lines, [.row(0), .row(1), .row(2), .more(37)], "weight_grams peeks")
        let frame = try laidOut(h.editor, id)
        expectEqual(frame.height, KitStyle.height(rows: 4))
        let hit = try require(find.currentHit)
        let rects = find.rects(of: hit.hit, in: id)
        let row = KitStyle.rowRect(2, in: frame)
        expect(rects.count == 1 && rects.allSatisfy { row.insetBy(dx: 0, dy: -1).contains($0) }, "marked on weight_grams' row: \(rects) in \(row)")
        expectEqual(rects.first?.minX, row.minX + KitStyle.nameInset, "from the name's start")
        find.close()
        expectEqual(try shown(h.editor, id)?.lines, [.row(0), .row(1), .more(38)], "let go as Find ends")
    },
    test("Find rings an enum-typed column's pill, by the enum's name now, and finds an enum's values") {
        let h = try EditorHarness(plugins: kitPlugins(find: true))
        h.editor.viewportDidResize(to: CGSize(width: 1000, height: 800))
        let status = h.add(DatabaseEnum(frame: CGRect(x: 500, y: 100, width: 200, height: 0), values: [EnumValue(text: "pending"), EnumValue(text: "paid")]),
                           titled: "order_status")
        let table = h.add(orders(status: status), titled: "orders")
        let find = try require(h.editor.find)
        find.open()
        find.query = "order_status"
        var turns = 0
        while find.isIndexing, turns < 10_000 {
            h.wait(0)
            turns += 1
        }
        _ = try awaitResult { await find.settled() }
        expect(find.texts(of: table).contains("order_status"), "the pill's text: \(find.texts(of: table))")
        expect(find.texts(of: table).contains("status"), "the enum-typed column's own text is its name")
        expect(find.texts(of: status).contains("pending") && find.texts(of: status).contains("paid"))
        h.editor.transact("Rename") { $0.update(status) { $0[TitleProperty.self] = "state" } }
        _ = try awaitResult { await find.settled() }
        expect(find.texts(of: table).contains("state"), "a rename of the enum reads the table's pill again: \(find.texts(of: table))")
    },
    test("T2 panel 3: a line typed wider than products lays it out as wide as the line needs, nothing written; as stored as editing ends") {
        let b = try KitBench()
        let id = b.h.add(DatabaseTable(frame: CGRect(x: 100, y: 100, width: 260, height: 0), columns: [ColumnGrammar.read("id uuid pk")!]), titled: "products")
        let stored = try laidOut(b.editor, id).width
        b.begin(id)
        b.type("updated_at timestamptz default now()")
        let wide = try laidOut(b.editor, id).width
        expect(wide > stored, "wider: \(wide) > \(stored)")
        let text = ("updated_at timestamptz default now()" as NSString).size(withAttributes: [.font: KitStyle.nameFont]).width
        expect(wide >= KitStyle.nameInset + text * 0.8 + KitStyle.trailingInset, "the whole line has room: \(wide)")
        expectEqual(b.editor.document[id]?.box?.width, 260, "nothing written")
        b.press(.escape)
        expectEqual(try laidOut(b.editor, id).width, 260, "as stored again")
    },
])

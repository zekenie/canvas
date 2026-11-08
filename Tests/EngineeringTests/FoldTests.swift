import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Connections
import Engineering
import Find
import Geometry
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
        expectEqual(h.editor.announcements.last, "products folded, 2 of 40 columns shown", "VoiceOver hears the title and the counts")
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
    test("a folded table's hidden columns are not shown parts: they stand at +N; the shown ones, out of order beside them, keep their dots; +N has none") {
        let k = try KeyBoard()
        let people = k.h.add(DatabaseTable(frame: CGRect(x: 100, y: 400, width: 260, height: 0),
                                           columns: ["id uuid pk", "a text", "b text", "email text unique"].compactMap { ColumnGrammar.read($0) }), titled: "people")
        k.editor.rowFolds?.fold([people])
        expectEqual(try shown(k.editor, people)?.lines, [.row(0), .row(3), .more(2)])
        let columns = try require(k.editor.document[people]?.typed(as: DatabaseTable.self)?.props.columns).map(\.id)
        let frame = try laidOut(k.editor, people)
        let parts = try require(k.editor.shapeContext.geometry(of: people)).parts
        expectEqual(parts.map(\.isShown), [true, false, false, true], "a and b are folded away")
        expectEqual(parts.shownFrames.map(\.id), [columns[0], columns[3]], "shown ones, top to bottom")
        let more = KitStyle.rowRect(2, in: frame), email = KitStyle.rowRect(1, in: frame)
        expectEqual(parts.frame(columns[1])?.rect, more, "a hidden column's rect is still +N's")
        expectEqual(parts.frame(nearestY: more.midY)?.id, columns[3], "a drop at +N binds a column that shows, never a hidden one")
        // The pointer on the shown column after a hidden one: its dot is reached.
        k.h.move(to: CGPoint(x: frame.midX, y: email.midY))
        k.h.move(to: CGPoint(x: frame.minX - 12, y: email.midY))
        expectEqual((k.editor.hoveredButton?.base as? PortDot)?.part, columns[3], "email's dot, though a and b stand below it")
        k.h.move(to: CGPoint(x: frame.midX, y: more.midY))
        k.h.move(to: CGPoint(x: frame.minX - 12, y: more.midY))
        expectEqual(k.editor.hoveredButton, nil, "+N offers no dot")
    },
    test("Find follows an enum deleted and brought back: the column's type is plain words without it and a pill with it") {
        let h = try EditorHarness(plugins: kitPlugins(find: true))
        h.editor.viewportDidResize(to: CGSize(width: 1000, height: 800))
        h.editor.turn(EngineeringKit.self, on: true)
        let status = h.add(DatabaseEnum(frame: CGRect(x: 500, y: 100, width: 200, height: 0), values: [EnumValue(text: "pending")]), titled: "order_status")
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
        expect(find.texts(of: table).contains("order_status") && find.texts(of: table).contains("status"), "a pill: \(find.texts(of: table))")
        h.editor.transact("Delete Enum") { $0.delete([status]) }
        _ = try awaitResult { await find.settled() }
        expect(!find.texts(of: table).contains("order_status"), "no pill without the enum: \(find.texts(of: table))")
        expect(find.texts(of: table).contains("status order_status"), "its type is plain words again: \(find.texts(of: table))")
        expectEqual(find.results.map(\.id).contains(table), true, "found by its type words")
        h.editor.undo()
        _ = try awaitResult { await find.settled() }
        expect(find.texts(of: table).contains("order_status") && !find.texts(of: table).contains("status order_status"), "a pill again: \(find.texts(of: table))")
    },
    test("The +38 › line of a real folded table opens with a click; ⌥Tab reaches it among the table's other parts, ⌥⇧Tab undoes each step, Return and Space open it") {
        let b = try KitBench()
        let id = b.h.add(products(), titled: "products")
        b.editor.rowFolds?.fold([id])
        let frame = try laidOut(b.editor, id), more = KitStyle.rowRect(2, in: frame)
        b.editor.selectedShapeIDs = []
        b.h.click(at: b.h.view(CGPoint(x: more.midX, y: more.midY)))
        expect(b.editor.rowFolds?.isFolded(id) != true, "a click on +N shows every column")
        expect(b.editor.editingShapeID == nil, "and starts no editing")
        b.editor.rowFolds?.fold([id])
        b.editor.selectedShapeIDs = [id]
        let titles = b.editor.shapeParts(of: id).map(\.title)
        expect(titles.contains("38 more columns"), "+N is a part with a name: \(titles)")
        let names = [id: "T"]
        let walk = KeyWalk(b.window, editor: b.editor, readers: [.canvas(b.canvas, selection: { [b] in b.editor.selectedShapeIDs.map { names[$0] ?? "?" } },
                                                                          part: { [b] in b.editor.focusedPart?.title },
                                                                          frame: { [b] in
                                                                              guard let rect = b.editor.focusedPart?.rect ?? b.editor.selectionBounds else { return nil }
                                                                              return b.editor.shownFrame(ofWorld: rect, in: b.canvas)
                                                                          })],
                           settle: .both(b.h.scheduler))
        let ids = titles.map { "canvas/T/\($0)" }
        walk.go(ids[0], by: .optionTab)
        let cycle = walk.expectCycle(ids, wraps: .closed, forward: .optionTab, back: .optionBackTab)
        walk.expectShows(cycle.stops, by: .optionTab)
        walk.go("canvas/T/38 more columns", by: .optionTab)
        walk.press(.return)
        expect(b.editor.rowFolds?.isFolded(id) != true, "Return opens it")
        b.editor.rowFolds?.fold([id])
        walk.go("canvas/T/38 more columns", by: .optionTab)
        walk.press(.space)
        expect(b.editor.rowFolds?.isFolded(id) != true, "Space opens it")
        expect(b.editor.editingShapeID == nil, "neither starts editing")
    },
    test("zoomed out at 30%, a folded table draws a bar a shown line, its +N line's short bar, and nothing below; light and dark") {
        let h = try kitHarness()
        let id = h.add(products(at: CGPoint(x: 100, y: 100)), titled: "products")
        h.editor.rowFolds?.fold([id])
        h.editor.camera = Camera(origin: .zero, zoom: 0.3)
        expect(h.editor.drawsSkeleton(of: id))
        let frame = try laidOut(h.editor, id)
        expectEqual(frame.height, KitStyle.height(rows: 3))
        for dark in [false, true] {
            let drawn = render(h.editor, size: CGSize(width: 300, height: 300), dark: dark)
            // In view points: the paper from (30, 30), 90 wide; rows 7.2 apart from 32.4 down.
            @MainActor func row(_ line: Int) -> CGRect { KitStyle.rowRect(line, in: frame).applying(CGAffineTransform(scaleX: 0.3, y: 0.3)) }
            let name = { (r: CGRect) in CGRect(x: r.minX + KitStyle.nameInset * 0.3, y: r.minY + 1, width: 12, height: r.height - 2) }
            expect(some(drawn, in: name(row(0))) { $0[0] < 200 }, "\(dark): id's bar")
            expect(some(drawn, in: name(row(2))) { $0[0] < 200 }, "\(dark): the +N line's bar")
            let below = CGRect(x: 30, y: frame.maxY * 0.3 + 3, width: 90, height: 20)
            // The card ends there: no paper below it (the canvas is white or dark, never the paper's grey).
            expect(!some(drawn, in: below) { abs($0[0] - 235) < 4 && abs($0[2] - 235) < 4 }, "\(dark): no paper below the folded card")
        }
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
        // Drawn: the paper reaches past the stored width, to hold the whole line (T2 panel 3).
        for dark in [false, true] {
            let drawn = render(b.editor, size: CGSize(width: 900, height: 300), dark: dark)
            let rowMiddle = KitStyle.rowRect(0, in: try laidOut(b.editor, id)).midY
            expect(some(drawn, in: CGRect(x: 100 + wide - 6, y: rowMiddle - 1, width: 2, height: 2)) { abs($0[0] - 235) < 4 }, "\(dark): paper under the line's end")
            expect(some(drawn, in: CGRect(x: 100 + 260 + 20, y: rowMiddle - 1, width: 2, height: 2)) { abs($0[0] - 235) < 4 }, "\(dark): and past the stored width")
            expect(!some(drawn, in: CGRect(x: 100 + wide + 8, y: rowMiddle - 1, width: 2, height: 2)) { abs($0[0] - 235) < 4 }, "\(dark): and none past the line")
        }
        b.press(.escape)
        expectEqual(try laidOut(b.editor, id).width, 260, "as stored again")
    },
])

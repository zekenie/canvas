import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CanvasUI
import Draw
import Engineering
import Geometry
import LanguageModels
import Selection
import ShippedTesting
import TestKit
import Titles

// A table that grows makes room below it, as shipped (the core's push, the kit's kinds opting in): the first UX walk's
// structure steps through a board's window (four columns typed into customers push products down, products' pill clear of
// customers' rows, one Undo a column); Paste SQL again with a column more pushing the table below; and `canvas draw`'s report
// saying what its `columns:` pushed (`moved`), a dry run's too.

@MainActor private func tableID(_ editor: CanvasEditor, _ title: String) throws -> ShapeID {
    try require(editor.document.shapes.first { $0[TitleProperty.self] == title && $0.kind == DatabaseTable.kind }?.id, "no table \(title)")
}

@MainActor private func frame(_ editor: CanvasEditor, _ id: ShapeID) throws -> CGRect {
    try require(editor.shapeContext.frame(of: id))
}

private let shopFrame = #"database "shop" size: 1180x1500"#
private let shop = """
    table "customers" in "shop" columns: "id uuid pk\\nemail text unique\\nname text\\ncreated_at timestamptz"
    table "products" in "shop" below "customers" (gap: 90) columns: "id uuid pk\\nsku text unique\\nweight_grams int\\ntitle text"
    """

@MainActor let makingRoomShippedTests = Suite("Making room, shipped", [
    test("the walk's structure steps: four columns typed into customers push products down, products' pill clear of customers' rows; Undo a column at a time") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        try w.turnKitOn()
        try w.draw(shopFrame)
        try w.draw(shop)
        let customers = try tableID(editor, "customers"), products = try tableID(editor, "products")
        let shopID = try require(editor.document.shapes.first { $0.kind == Database.kind }?.id)
        let gap = try frame(editor, products).minY - frame(editor, customers).maxY
        expectEqual(gap, 90)
        editor.camera = Camera(origin: CGPoint(x: try frame(editor, shopID).minX - 40, y: try frame(editor, shopID).minY - 70), zoom: 1)
        w.window.settle()
        let walk = w.walk()
        let top = try frame(editor, customers)
        w.mouseClick(at: CGPoint(x: top.midX, y: top.minY + 8))
        walk.press(.return)
        expectEqual(editor.editingShapeID, customers)
        let initial = try frame(editor, products).minY
        var tops: [CGFloat] = []
        for line in ["street text", "city text", "postcode text", "country char(2)"] {
            w.type(line, with: walk)
            walk.press(.return)
            tops.append(try frame(editor, products).minY)
        }
        walk.press(.return)
        expectEqual(editor.editingShapeID, nil, "Return on the empty row ends editing")
        let grown = try frame(editor, customers), below = try frame(editor, products)
        let line = (grown.height - top.height) / 4
        expect(line > 0)
        // 90, then 90 less a line; nearer than a line and the room a table keeps below it (a waiting line and a pill, UX walk 3
        // apis-1) it's pushed, the gap it has kept.
        expect(90 >= line + max(32, KitStyle.roomKeptBelow) && 90 - line < line + max(32, KitStyle.roomKeptBelow))
        expectEqual(tops[0], initial, "the first: 90 is no nearer than a line and the room kept below")
        expectEqual(tops[1], tops[0] + line, "pushed")
        expectEqual(tops[2], tops[1] + line, "pushed")
        expectEqual(tops[3], tops[2] + line, "pushed")
        expectEqual(below.minY - grown.maxY, 90 - line, "the gap it had when the push began, kept")
        expectEqual(editor.holder(of: products), shopID)
        let pill = try require(editor.adornmentFrames(of: products).first { $0.adornment.placement == .aboveTopLeft }?.rect, "products' pill")
        expect(!pill.intersects(grown), "products' pill clear of customers' rows: \(pill) \(grown)")
        expectEqual(undoTitle(w.window), "Undo Add Column")
        editor.undo()
        expectEqual(try frame(editor, products).minY, tops[2], "one Undo takes a column and its push")
        editor.undo()
        editor.undo()
        editor.undo()
        expectEqual(try frame(editor, products).minY, try frame(editor, customers).maxY + 90, "back as drawn")
    },
    test("tables new-1: a long key typed in orders, the enum put down beside it: orders is painted and hit above the enum while it's wider, nothing moves, and back as the caret leaves") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        try w.turnKitOn()
        try w.draw(#"table "orders" columns: "id uuid pk\ntotal_cents int\ncustomer_id uuid""#)
        try w.draw(#"enum-type "order_status" right of "orders" (gap: 80) values: "pending\npaid\nshipped""#)
        let orders = try tableID(editor, "orders")
        let status = try require(editor.document.shapes.first { $0[TitleProperty.self] == "order_status" }?.id)
        let rest = try frame(editor, orders), beside = try frame(editor, status)
        editor.camera = Camera(origin: CGPoint(x: rest.minX - 60, y: rest.minY - 80), zoom: 1)
        w.window.settle()
        let walk = w.walk()
        w.mouseClick(at: CGPoint(x: rest.midX, y: rest.minY + 8))
        walk.press(.return)
        expectEqual(editor.editingShapeID, orders)
        let overlap = CGRect(x: beside.minX + 4, y: beside.minY + 4, width: 20, height: 20)
        expectEqual(editor.paintOrder(in: overlap).map(\.id).last, status, "at rest the enum is on top where they would meet")
        w.type("billing_customer_id uuid null -> customers.email", with: walk)
        w.window.settle()
        let typed = try frame(editor, orders)
        expect(typed.maxX > beside.minX + 20, "laid out across the enum while the line is typed: \(typed) \(beside)")
        expectEqual(editor.paintOrder(in: overlap).map(\.id).last, orders, "orders painted above the enum it now overlaps")
        expectEqual(editor.shape(at: CGPoint(x: overlap.midX, y: overlap.midY)), orders, "and hit there")
        expectEqual(try frame(editor, status), beside, "the enum not moved")
        walk.press(.escape)
        walk.press(.escape)
        w.window.settle()
        expectEqual(editor.editingShapeID, nil)
        expectEqual(editor.paintOrder(in: overlap).map(\.id).last, status, "back in its place once the caret leaves")
    },
    test("apis new-1: a table laid out taller by its waiting line draws over the pill of the table just under it, which is left out while the caret is in it, and back as it leaves") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        try w.turnKitOn()
        try w.draw(#"table "customers" columns: "id uuid pk\nemail text unique""#)
        try w.draw(#"table "products" below "customers" (gap: 40) columns: "id uuid pk\nsku text unique""#)
        let customers = try tableID(editor, "customers"), products = try tableID(editor, "products")
        let rest = try frame(editor, customers)
        editor.camera = Camera(origin: CGPoint(x: rest.minX - 60, y: rest.minY - 60), zoom: 1)
        w.window.settle()
        let size = w.canvas.bounds.size
        let pill = try require(editor.adornmentFrames(of: products).first { $0.adornment.placement == .aboveTopLeft }?.rect, "products' pill")
        let seen = editor.camera.toView(pill).insetBy(dx: 2, dy: 2)
        // At rest the pill shows: with the title gone, the same pixels are another picture.
        let withPill = renderBitmap(editor, size: size)
        let title = try require(editor.document[products]?[TitleProperty.self])
        editor.transact("Clear title") { $0.update(products) { $0[TitleProperty.self] = nil } }
        let withoutAtRest = renderBitmap(editor, size: size)
        expect(changedPixels(withPill, withoutAtRest, in: seen) > 50, "the pill is drawn at rest")
        editor.undo()
        let walk = w.walk()
        w.mouseClick(at: CGPoint(x: rest.midX, y: rest.minY + 8))
        walk.press(.return)
        expectEqual(editor.editingShapeID, customers)
        w.window.settle()
        let laidOut = try frame(editor, customers), stored = try require(editor.document[customers]?.box)
        expect(laidOut.height > stored.height + 1, "taller by its waiting line: \(laidOut) \(stored)")
        let overflow = try require(editor.editedShapeOverflow)
        expect(overflow.areas.contains { $0.intersects(pill) }, "the waiting line's room reaches the pill: \(overflow.areas) \(pill)")
        let withPillEditing = renderBitmap(editor, size: size)
        editor.transact("Clear title") { $0.update(products) { $0[TitleProperty.self] = nil } }
        let withoutEditing = renderBitmap(editor, size: size)
        expectEqual(changedPixels(withPillEditing, withoutEditing, in: seen), 0, "products' pill not drawn across the waiting line")
        editor.undo()
        expectEqual(editor.document[products]?[TitleProperty.self], title)
        walk.press(.escape)
        w.window.settle()
        expectEqual(editor.editingShapeID, nil)
        expectEqual(editor.editedShapeOverflow == nil, true)
        expect(changedPixels(renderBitmap(editor, size: size), withoutAtRest, in: seen) > 50, "the pill drawn again once the caret leaves")
    },
    test("Paste SQL again with a column more pushes the table below it down, in the step; Undo Paste SQL takes both") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        try w.turnKitOn()
        try w.draw("""
            table "payments" columns: "id uuid pk\\namount_cents int\\nstatus text"
            table "refunds" below "payments" (gap: 30) columns: "id uuid pk\\nreason text"
            """)
        let payments = try tableID(editor, "payments"), refunds = try tableID(editor, "refunds")
        let was = try frame(editor, refunds).minY, bottom = try frame(editor, payments).maxY
        editor.selection = payments
        ShippedPlugins.pasteboard.clearContents()
        ShippedPlugins.pasteboard.setString("CREATE TABLE payments (id uuid PRIMARY KEY, currency char(3), amount_cents int, status text);", forType: .string)
        expect(w.window.performKeyEquivalent(with: w.window.keyEvent("v", code: 9, modifiers: [.command])), "⌘V takes it")
        let growth = try frame(editor, payments).maxY - bottom
        expect(growth > 0, "a column more")
        expectEqual(try frame(editor, refunds).minY, bottom + growth + max(30, KitStyle.roomKeptBelow),
                    "the gap of 30 made up to the room a table keeps below it, for its waiting line and refunds' pill")
        expect(was < bottom + KitStyle.roomKeptBelow)
        expectEqual(undoTitle(w.window), "Undo Paste SQL")
        editor.undo()
        expectEqual(try frame(editor, refunds).minY, was)
    },
    test("draw's columns: says what its growth pushed (moved: kind, title, id, where it is, how far down); a dry run says it and moves nothing") {
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
        editor.viewportDidResize(to: CGSize(width: 1440, height: 900))
        let drawn = try drawnInProcess("""
            table "orders" columns: "id uuid pk\\nstatus text"
            table "items" below "orders" (gap: 20) columns: "id uuid pk"
            """, on: editor)
        expect(drawn["moved"] == nil, "nothing pushed: no moved")
        let items = try tableID(editor, "items")
        let was = try frame(editor, items).minY
        let dry = try drawnInProcess(#"table "orders" columns: "total_cents int\nplaced_at timestamptz""#, on: editor, dryRun: true)
        let said = try require(dry["moved"]?.arrayValue?.first, "a dry run says it too")
        expectEqual(said["title"]?.stringValue, "items")
        expectEqual(try frame(editor, items).minY, was, "and moves nothing")
        let run = try drawnInProcess(#"table "orders" columns: "total_cents int\nplaced_at timestamptz""#, on: editor)
        let moved = try require(run["moved"]?.arrayValue)
        expectEqual(moved.count, 1)
        let now = try frame(editor, items)
        expectEqual(moved.first?["title"]?.stringValue, "items")
        expectEqual(moved.first?["kind"]?.stringValue, DatabaseTable.kind.rawValue)
        expectEqual(moved.first?["id"]?.stringValue, items.description)
        expectEqual(moved.first?["down"]?.numberValue.map { CGFloat($0) }, now.minY - was)
        expectEqual(moved.first?["at"]?.arrayValue?.first?.arrayValue?.compactMap(\.numberValue), [Double(now.minX), Double(now.minY)])
        expect(now.minY > was)
    },
    test("draw's columns: on a table at the bottom of a database grows the database, nothing nudged up over the table above; on a table above a database it pushes the database and what it holds") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        try w.turnKitOn()
        try w.draw(#"database "shop" size: 700x600"#)
        try w.draw("""
            table "a" in "shop" columns: "id uuid pk\\nemail text"
            table "b" in "shop" below "a" (gap: 20) columns: "id uuid pk"
            """)
        let a = try tableID(editor, "a"), b = try tableID(editor, "b")
        let shopID = try require(editor.document.shapes.first { $0.kind == Database.kind }?.id)
        // The database as tight as a person leaves it: the gap inside under its last table.
        let tight = try frame(editor, b).maxY + Settlement.gap
        let shopTop = try frame(editor, shopID).minY
        editor.transact("Resize") { $0.update(shopID) { $0.box?.size.height = tight - shopTop } }
        let aWas = try frame(editor, a), bWas = try frame(editor, b)
        let ran = try drawnInProcess(#"table "b" columns: "name text\nsku text\nweight int""#, on: editor)
        let bNow = try frame(editor, b), shopNow = try frame(editor, shopID)
        expect(bNow.height > bWas.height, "b is taller")
        expectEqual(bNow.minY, bWas.minY, "b stays where it is, never nudged up over a")
        expectEqual(try frame(editor, a), aWas)
        expectEqual(shopNow.maxY, bNow.maxY + Settlement.gap, "the database grew to hold it, the gap inside")
        expect(ran["moved"] == nil, "nothing under b: nothing pushed")
        expect(!bNow.intersects(try frame(editor, a)))
        // And above a database, the database goes down by the growth, and what it holds with it.
        try w.draw("""
            table "x" below "shop" (gap: 20) columns: "id uuid pk"
            """)
        let x = try tableID(editor, "x")
        let xWas = try frame(editor, x)
        let ran2 = try drawnInProcess(#"table "x" columns: "a int\nb int\nc int""#, on: editor)
        let xNow = try frame(editor, x)
        expect(xNow.height > xWas.height)
        expectEqual(xNow.origin, xWas.origin)
        expect(ran2["moved"] == nil, "x is the grown shape here and nothing sits under it")
    },
    test("draw's report says only what the script did: a table it restated unchanged that the push moved is unchanged, and listed in moved") {
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
        editor.viewportDidResize(to: CGSize(width: 1440, height: 900))
        _ = try drawnInProcess("""
            table "orders" columns: "id uuid pk\\nstatus text"
            table "items" below "orders" (gap: 20) columns: "id uuid pk"
            """, on: editor)
        let items = try tableID(editor, "items")
        let was = try frame(editor, items).minY
        let run = try drawnInProcess("""
            table "orders" columns: "total_cents int\\nplaced_at timestamptz"
            table "items"
            """, on: editor)
        expect(try frame(editor, items).minY > was, "pushed")
        let rows = try require(run["changes"]?.arrayValue)
        expectEqual(rows.first { $0["title"]?.stringValue == "items" }?["did"]?.stringValue, "unchanged", "the script moved nothing")
        expect(rows.first { $0["title"]?.stringValue == "orders" }?["did"]?.stringValue != "unchanged", "orders is what the script wrote")
        expectEqual(run["moved"]?.arrayValue?.compactMap { $0["title"]?.stringValue }, ["items"])
    },
    test("Paste SQL again with a column more and a table more: what it pushes and what it puts down don't land on each other") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        try w.turnKitOn()
        try w.draw("""
            table "payments" columns: "id uuid pk\\namount_cents int"
            table "refunds" below "payments" (gap: 30) columns: "id uuid pk\\nreason text"
            """)
        let payments = try tableID(editor, "payments")
        editor.selection = payments
        ShippedPlugins.pasteboard.clearContents()
        ShippedPlugins.pasteboard.setString("""
            CREATE TABLE payments (id uuid PRIMARY KEY, currency char(3), amount_cents int, status text);
            CREATE TABLE ledger (id uuid PRIMARY KEY, memo text);
            """, forType: .string)
        expect(w.window.performKeyEquivalent(with: w.window.keyEvent("v", code: 9, modifiers: [.command])), "⌘V takes it")
        let tables = editor.document.shapes.filter { $0.kind == DatabaseTable.kind }.map(\.id)
        expectEqual(tables.count, 3, "the ledger is made")
        for (index, one) in tables.enumerated() {
            for other in tables.dropFirst(index + 1) {
                expect(!(try frame(editor, one)).intersects(try frame(editor, other)), "no two tables overlap")
            }
        }
    },
    test("Paste OpenAPI again with an endpoint more pushes the notes under the API down by its growth, in the step; Undo Paste OpenAPI takes both") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        try w.turnKitOn()
        w.editor.undoHistory.seal()
        w.window.makeFirstResponder(w.canvas)
        let editor = w.editor
        @MainActor func paste(_ text: String) {
            ShippedPlugins.pasteboard.clearContents()
            ShippedPlugins.pasteboard.setString(text, forType: .string)
            expect(w.window.performKeyEquivalent(with: w.window.keyEvent("v", code: 9, modifiers: [.command])), "⌘V takes it")
        }
        let file = """
            openapi: 3.1.0
            info:
              title: pings
              version: 1.0.0
            paths:
              /ping:
                get:
                  operationId: ping
                  responses:
                    '200':
                      description: pong
                      content:
                        application/json:
                          schema: {$ref: '#/components/schemas/Pong'}
            components:
              schemas:
                Pong:
                  type: object
                  properties:
                    at: {type: string}
            """
        paste(file)
        let api = try require(editor.document.shapes.first { $0.kind == API.kind }?.id)
        let pong = try require(editor.document.shapes.first { $0[TitleProperty.self] == "Pong" }?.id)
        let apiBottom = try frame(editor, api).maxY, pongWas = try frame(editor, pong)
        expect(pongWas.minY > apiBottom - 1, "the type note is under the API: \(pongWas) \(apiBottom)")
        // Three endpoints more: the type note is 80 under the API, which a line's growth leaves out of reach.
        let more = ["pong", "peng", "pung"].map { "  /\($0):\n    get:\n      operationId: \($0)\n      responses:\n        '200':\n          description: ok\n" }.joined()
        paste(file.replacingOccurrences(of: "components:", with: more + "components:"))
        let growth = try frame(editor, api).maxY - apiBottom
        expect(growth > 0, "an endpoint more")
        expectEqual(try frame(editor, pong).minY, pongWas.minY + growth, "pushed by the API's growth, its gap kept")
        expectEqual(undoTitle(w.window), "Undo Paste OpenAPI")
        editor.undo()
        expectEqual(try frame(editor, pong).minY, pongWas.minY)
    },
    test("canvas apply puts every shape where its plan says: a table that gains columns in a drawn again document pushes nothing") {
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
        editor.viewportDidResize(to: CGSize(width: 1440, height: 900))
        func plan(_ columns: String) -> String {
            #"{"drawing":"Shop","nodes":[{"key":"t:a","kind":"table","props":{"title":"a","columns":"\#(columns)"},"place":{"at":[0,0]}},{"key":"t:b","kind":"table","props":{"title":"b","columns":"id uuid pk"},"place":{"at":[0,110]}}]}"#
        }
        _ = try apply(document: plan("id uuid pk"), dryRun: false, on: nil, program: "canvas", in: editor)
        let a = try tableID(editor, "a"), b = try tableID(editor, "b")
        expectEqual(try frame(editor, b).minY, 110)
        _ = try apply(document: plan("id uuid pk\\nemail text\\nname text\\ncity text"), dryRun: false, on: nil, program: "canvas", in: editor)
        expect(try frame(editor, a).maxY > 110, "a grew over b, as its plan has it")
        expectEqual(try frame(editor, b).minY, 110, "and b stays where the plan put it")
    },
])

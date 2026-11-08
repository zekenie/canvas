import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CanvasUI
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
        // 90, then 90 less a line twice; at under a line and the reach it's pushed, the gap it has kept.
        expectEqual(tops[0], below.minY - 2 * line, "the first: 90 - a line is no nearer than a line and the reach")
        expectEqual(tops[1], tops[0])
        expectEqual(tops[2], tops[1] + line, "pushed")
        expectEqual(tops[3], tops[2] + line, "pushed")
        expectEqual(below.minY - grown.maxY, 90 - 2 * line, "the gap it had when the push began, kept")
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
        expectEqual(try frame(editor, refunds).minY, was + growth, "the gap of 30 kept")
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
])

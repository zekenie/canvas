import Adornments
import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Geometry
import CanvasRPC
import Clipboard
import Connections
import Engineering
import LineRows
import Locking
import References
import Selection
import SlashCommands
import ShippedTesting
import TestKit
import Titles

// Pastes, puts and moves across boards, as shipped (U7: the whole-branch review's and the third UX walk's findings), through the
// app's window: a cut's paste on another board while its rows are back is a copy (R3); a put refused after its widening leaves
// nothing (R4); rows pasted keep a key that went through a pill (R10); a draw that grows a table keeps the gap of what it placed
// below it (R11); two OpenAPI files of one title are two APIs (R12); a paste again says only what it changed, not what it pushed
// (R42); a paste's keys to one far table share its pill (R43); a key to a column the same paste adds on another board is drawn
// (R44); a paste reader reads the file's enums again once they change (R45); a key typed into a folded table pushes what's below (R41).

@MainActor private func pasteboardHolds(_ text: String) {
    let pasteboard = ShippedPlugins.pasteboard
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}

/// ⌘V, pressed in the window.
@MainActor private func commandV(_ w: EmptyBoardWindow) -> Bool {
    w.window.performKeyEquivalent(with: w.window.keyEvent("v", code: 9, modifiers: [.command]))
}

/// A new board's window with the kit on, `script` drawn, the canvas with the keys.
@MainActor private func kitWindow(_ script: String = "") throws -> EmptyBoardWindow {
    let w = try EmptyBoardWindow()
    try w.turnKitOn()
    if !script.isEmpty { _ = try drawnInProcess(script, on: w.editor) }
    w.editor.undoHistory.seal()
    w.window.makeFirstResponder(w.canvas)
    return w
}

/// An arrow's line as drawn: the arc through its outline's three points (start, middle, end), sampled.
private func arc(_ outline: [CGPoint]) -> [CGPoint] {
    guard outline.count == 3 else { return outline }
    let (a, b, c) = (outline[0], outline[1], outline[2])
    let d = 2 * (a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y))
    guard abs(d) > 1e-6 else { return outline }
    let aa = a.x * a.x + a.y * a.y, bb = b.x * b.x + b.y * b.y, cc = c.x * c.x + c.y * c.y
    let center = CGPoint(x: (aa * (b.y - c.y) + bb * (c.y - a.y) + cc * (a.y - b.y)) / d, y: (aa * (c.x - b.x) + bb * (a.x - c.x) + cc * (b.x - a.x)) / d)
    let radius = hypot(a.x - center.x, a.y - center.y)
    func angle(_ p: CGPoint) -> CGFloat { atan2(p.y - center.y, p.x - center.x) }
    func sweep(_ from: CGFloat, _ to: CGFloat) -> CGFloat { var s = to - from; while s < 0 { s += 2 * .pi }; return s }
    let start = angle(a)
    let total = sweep(start, angle(b)) <= sweep(start, angle(c)) ? sweep(start, angle(c)) : sweep(start, angle(c)) - 2 * .pi
    return (0...32).map { CGPoint(x: center.x + radius * cos(start + total * CGFloat($0) / 32), y: center.y + radius * sin(start + total * CGFloat($0) / 32)) }
}

private func did(_ result: JSON) -> [String] { result["changes"]?.arrayValue?.compactMap { $0["did"]?.stringValue } ?? [] }

@MainActor private func board(_ editor: CanvasEditor, _ title: String) throws -> BoardID {
    BoardID(owner: try require(editor.document.shapes.first { $0[TitleProperty.self] == title }).id)
}

@MainActor private func pills(_ editor: CanvasEditor, on board: BoardID) -> [ShapeRecord<Reference>] {
    editor.contents(of: board).shapes.compactMap { $0.typed(as: Reference.self) }
}

@MainActor private func table(_ editor: CanvasEditor, _ title: String) -> ShapeRecord<DatabaseTable>? {
    for board in editor.file.everyBoard {
        if let found = editor.contents(of: board).shapes.first(where: { $0[TitleProperty.self] == title })?.typed(as: DatabaseTable.self) { return found }
    }
    return nil
}

/// Each key of the file as `from.column -> to.column` (through a pill, the column on its binding, of the table it stands for).
@MainActor private func keys(_ editor: CanvasEditor) -> [String] {
    keyArrows(editor).compactMap { arrow -> String? in
        guard let start = arrow.props.start.binding, let end = arrow.props.end.binding else { return nil }
        @MainActor func said(_ binding: ArrowBinding) -> String {
            var record = editor.shape(inFile: binding.shapeID)
            if let pill = record?.typed(as: Reference.self), let target = pill.props.target?.id { record = editor.shape(inFile: target) }
            let name = record.flatMap { editor.registry.parts(of: $0)?.first { $0.id == binding.part }?.name } ?? "?"
            return "\(record?[TitleProperty.self] ?? "?").\(name)"
        }
        return "\(said(start)) -> \(said(end))"
    }.sorted()
}

@MainActor private func keyArrows(_ editor: CanvasEditor) -> [ShapeRecord<Arrow>] {
    editor.file.everyBoard.flatMap { editor.contents(of: $0).shapes.compactMap { $0.typed(as: Arrow.self) } }
        .filter { $0[ChannelProperty.self] == ForeignKey.id }
}

@MainActor let putsAcrossBoardsShippedTests = Suite("Pastes and puts across boards, shipped", [
    test("R3: a cut column, undone, then pasted on another board is a copy: the source keeps its column and key, the step is a paste; pasted on a third board, a copy again") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        try w.turnKitOn()
        let editor = w.editor
        _ = try drawnInProcess(#"""
            table "customers" columns: "id uuid pk\nemail text unique"
            table "orders" right of "customers" columns: "id uuid pk\ncustomer_id uuid → customers.id\ntotal_cents int"
            subboard "billing" below "customers"
            subboard "archive" right of "billing"
            """#, on: editor)
        let orders = try require(table(editor, "orders"))
        let column = orders.props.columns[1].id
        let key = try require(keyArrows(editor).first)
        @MainActor func boardOf(_ title: String) throws -> BoardID {
            BoardID(owner: try require(editor.document.shapes.first { $0[TitleProperty.self] == title }).id)
        }
        let billing = try boardOf("billing"), archive = try boardOf("archive")
        w.window.makeFirstResponder(w.canvas)
        editor.undoHistory.seal()
        let walk = w.walk()
        editor.selectedShapeIDs = [orders.id]
        editor.selectItems([AnyHashable(column)], of: orders.id)
        walk.press(Chord("x", .command))
        expectEqual(undoTitle(w.window), "Undo Cut Column and 1 Arrow")
        editor.undo()
        expectEqual(table(editor, "orders")?.props.columns.map(\.id), orders.props.columns.map(\.id), "the cut undone: orders holds the column again")
        for (board, name) in [(billing, "billing"), (archive, "archive")] {
            expect(editor.showBoard(board))
            w.window.makeFirstResponder(w.canvas)
            editor.selectedShapeIDs = []
            walk.press(Chord("v", .command))
            expectEqual(undoTitle(w.window), "Undo Paste Column", "on \(name): a paste, not a move")
            let pasted = editor.document.shapes.compactMap { $0.typed(as: DatabaseTable.self) }
            expectEqual(pasted.count, 1, "on \(name): a table of the column")
            expect(pasted.first?.props.columns.contains { $0.name == "customer_id" } == true, "on \(name): the column in it")
            expectEqual(table(editor, "orders")?.props.columns.map(\.id), orders.props.columns.map(\.id), "orders keeps its column")
            let kept = try require(editor.shape(inFile: key.id)?.typed(as: Arrow.self))
            expectEqual(kept.props.start.binding?.shapeID, orders.id, "the key stays bound to orders")
            expectEqual(kept.props.start.binding?.part, column)
        }
    },
    test("R4: a paste refused after it widened a table it found on another board (a new table it would put in a locked database here) leaves that table, the file and Undo as they were") {
        let w = try kitWindow(#"""
            table "orders" columns: "id uuid pk"
            subboard "billing" below "orders"
            """#)
        defer { w.board.close() }
        let editor = w.editor
        let billing = try board(editor, "billing")
        _ = try drawnInProcess(#"database "shop" in "billing" size: 600x300"#, on: editor)
        _ = try drawnInProcess(#"table "items" in "shop" columns: "id uuid pk""#, on: editor)
        expect(editor.showBoard(billing))
        w.window.makeFirstResponder(w.canvas)
        let shop = try require(editor.document.shapes.first { $0[TitleProperty.self] == "shop" })
        editor.lock([shop.id])
        editor.undoHistory.seal()
        let items = try require(table(editor, "items"))
        editor.selectedShapeIDs = [items.id]
        let before = editor.file, undo = undoTitle(w.window)
        let ordersWas = try require(table(editor, "orders")).props.frame
        pasteboardHolds("""
            CREATE TABLE orders (id uuid PRIMARY KEY, placed_at_in_the_shoppers_own_time_zone timestamp with time zone);
            CREATE TABLE fresh (id int PRIMARY KEY);
            """)
        expect(commandV(w))
        expectEqual(table(editor, "orders")?.props.frame, ordersWas, "orders, on the root, not widened")
        expectEqual(editor.file[.root], before[.root], "the root as it was")
        expectEqual(editor.file[billing], before[billing], "billing as it was: nothing put down")
        expectEqual(undoTitle(w.window), undo, "no step")
        expect(editor.announcements.last?.contains("read-only") == true, "the refusal said: \(editor.announcements.last ?? "")")
    },
    test("R10: a column keyed through a pill, cut and pasted into a table on the far table's board, keeps its key, straight to the table; on a third board, through a pill there") {
        let w = try kitWindow(#"""
            table "customers" columns: "id uuid pk\nemail text unique"
            table "carts" right of "customers" (gap: 200) columns: "id uuid pk"
            subboard "billing" below "customers"
            subboard "archive" right of "billing"
            """#)
        defer { w.board.close() }
        let editor = w.editor
        let billing = try board(editor, "billing"), archive = try board(editor, "archive")
        _ = try drawnInProcess(#"table "statements" in "billing" columns: "id uuid pk\ncustomer_id uuid → customers.id""#, on: editor)
        expectEqual(keys(editor), ["statements.customer_id -> customers.id"], "through a pill on billing")
        for (cuts, lands, name) in [(billing, BoardID.root, "the far table's board"), (billing, archive, "a third board")] {
            expect(editor.showBoard(cuts))
            w.window.makeFirstResponder(w.canvas)
            editor.undoHistory.seal()
            let statements = try require(table(editor, "statements"))
            let column = try require(statements.props.columns.first { $0.name == "customer_id" }).id
            editor.selectedShapeIDs = [statements.id]
            editor.selectItems([AnyHashable(column)], of: statements.id)
            let walk = w.walk()
            walk.press(Chord("x", .command))
            expectEqual(keys(editor), [], "the key went with the column")
            expect(editor.showBoard(lands))
            w.window.makeFirstResponder(w.canvas)
            if lands == .root {
                let carts = try require(table(editor, "carts"))
                editor.selectedShapeIDs = [carts.id]
                editor.selectItems([AnyHashable(carts.props.columns[0].id)], of: carts.id)
            } else {
                editor.selectedShapeIDs = []
            }
            walk.press(Chord("v", .command))
            expect(!(editor.announcements.last ?? "").contains("left out"), "on \(name): nothing left out: \(editor.announcements.last ?? "")")
            let landed = lands == .root ? "carts" : (try require(editor.document.shapes.compactMap { $0.typed(as: DatabaseTable.self) }.first)[TitleProperty.self] ?? "?")
            expect(keys(editor).contains("\(landed).customer_id -> customers.id"), "on \(name): the key kept, \(keys(editor))")
            if lands == .root {
                let key = try require(keyArrows(editor).first { editor.shape(inFile: $0.props.start.binding?.shapeID ?? ShapeID())?[TitleProperty.self] == "carts" })
                expectEqual(key.props.end.binding?.shapeID, try require(table(editor, "customers")).id, "straight to customers, no pill on its own board")
            } else {
                expectEqual(pills(editor, on: archive).count, 1, "a pill for customers on archive")
            }
            editor.undo()
            editor.undo()
        }
    },
    test("R11: a draw that gives a table columns and puts a table below it at a gap of 20 in the same run keeps the 20; the same run again is unchanged") {
        let w = try kitWindow(#"table "orders" columns: "id uuid pk""#)
        defer { w.board.close() }
        let editor = w.editor
        let script = #"""
            table "orders" columns: "id uuid pk\ncustomer_id uuid\ntotal_cents int\nplaced_at timestamptz"
            table "items" below "orders" (gap: 20) columns: "id uuid pk"
            """#
        _ = try drawnInProcess(script, on: editor)
        let orders = try require(editor.shapeContext.frame(of: try require(table(editor, "orders")).id))
        let items = try require(editor.shapeContext.frame(of: try require(table(editor, "items")).id))
        expectEqual(items.minY - orders.maxY, 20, "the gap the run asked for: \(orders) \(items)")
        let again = try drawnInProcess(script, on: editor)
        expectEqual(Set(did(again)), ["unchanged"], "the run again changes nothing")
    },
    test("R12: two OpenAPI files with one title paste as two APIs, the later titled by its version; each with its own endpoints") {
        let w = try kitWindow()
        defer { w.board.close() }
        let editor = w.editor
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("paste-openapi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func spec(_ version: String, _ path: String) -> String {
            """
            openapi: 3.0.0
            info: {title: Billing API, version: '\(version)'}
            paths:
              /\(path):
                get:
                  responses:
                    '200': {description: ok}
            """
        }
        let one = folder.appendingPathComponent("billing-v1.yaml"), two = folder.appendingPathComponent("billing-v2.yaml")
        try spec("1.0", "invoices").write(to: one, atomically: true, encoding: .utf8)
        try spec("2.0", "statements").write(to: two, atomically: true, encoding: .utf8)
        let pasteboard = ShippedPlugins.pasteboard
        pasteboard.clearContents()
        pasteboard.writeObjects([one as NSURL, two as NSURL])
        expect(commandV(w))
        let apis = editor.document.shapes.compactMap { $0.typed(as: API.self) }
        expectEqual(apis.compactMap { $0[TitleProperty.self] }.sorted(), ["Billing API", "Billing API v2"])
        let byTitle = Dictionary(uniqueKeysWithValues: apis.map { ($0[TitleProperty.self] ?? "", $0) })
        expectEqual(byTitle["Billing API"]?.props.endpoints.compactMap { $0.endpoint?.path }, ["/invoices"])
        expectEqual(byTitle["Billing API v2"]?.props.endpoints.compactMap { $0.endpoint?.path }, ["/statements"], "the second's endpoints, never dropped")
        expectEqual(byTitle["Billing API v2"]?.props.version, "2.0")
    },
    test("R42: a schema pasted again with columns added to a table that grows over the one below it: only it is said and selected, never the one it pushed") {
        let w = try kitWindow()
        defer { w.board.close() }
        let editor = w.editor
        var schema = ["CREATE TABLE t1 (id int PRIMARY KEY, a text, b text, c text, d text);"] + (2...5).map { "CREATE TABLE t\($0) (id int PRIMARY KEY);" }
        pasteboardHolds(schema.joined(separator: "\n"))
        expect(commandV(w))
        let t5 = try require(table(editor, "t5")), t1 = try require(table(editor, "t1"))
        expect(t5.props.frame.minY > t1.props.frame.maxY && abs(t5.props.frame.minX - t1.props.frame.minX) < 1, "t5 under t1")
        let t5Was = t5.props.frame.minY
        schema[0] = "CREATE TABLE t1 (id int PRIMARY KEY, a text, b text, c text, d text, e text, f text, g text);"
        pasteboardHolds(schema.joined(separator: "\n"))
        expect(commandV(w))
        expect(try require(table(editor, "t5")).props.frame.minY > t5Was, "t5 pushed below t1's new bottom")
        expectEqual(editor.announcements.last, "Updated Table")
        expectEqual(editor.selectedShapeIDs.compactMap { editor.document[$0]?[TitleProperty.self] }, ["t1"], "the one it changed, not the one it pushed")
    },
    test("R43 and R44: a paste's keys to one table of another board share one pill; a key to a column the same paste adds to that table is drawn the first time") {
        let w = try kitWindow(#"""
            table "customers" columns: "id uuid pk\nemail text unique"
            subboard "billing" below "customers"
            """#)
        defer { w.board.close() }
        let editor = w.editor
        let billing = try board(editor, "billing")
        expect(editor.showBoard(billing))
        w.window.makeFirstResponder(w.canvas)
        pasteboardHolds("""
            CREATE TABLE customers (id uuid PRIMARY KEY, email text UNIQUE, code text UNIQUE);
            CREATE TABLE statements (id uuid PRIMARY KEY, billing_customer_id uuid REFERENCES customers (id), shipping_customer_id uuid REFERENCES customers (id));
            CREATE TABLE invoices (id uuid PRIMARY KEY, customer_code text REFERENCES customers (code));
            """)
        expect(commandV(w))
        expectEqual(table(editor, "customers")?.props.columns.map(\.name), ["id", "email", "code"], "customers restated where it is, a column added")
        expectEqual(pills(editor, on: billing).count, 1, "one pill for customers, shared by the paste's keys: \(pills(editor, on: billing).count)")
        expectEqual(keys(editor), ["invoices.customer_code -> customers.code", "statements.billing_customer_id -> customers.id",
                                   "statements.shipping_customer_id -> customers.id"], "every key drawn, the one to the new column too")
        expectEqual(undoTitle(w.window), "Undo Paste SQL")
        editor.undo()
        expectEqual(table(editor, "customers")?.props.columns.map(\.name), ["id", "email"], "one Undo takes both boards' changes")
        expectEqual(pills(editor, on: billing).count, 0)
    },
    test("R45: the same SQL pasted once the file has an enum one of its columns names is measured with the enum's pill, as a fresh paste is") {
        let sql = "CREATE TABLE moods (id int PRIMARY KEY, feeling the_quite_long_mood_of_the_day);"
        @MainActor func width(_ w: EmptyBoardWindow) -> CGFloat { table(w.editor, "moods")?.props.frame.width ?? 0 }
        let fresh = try kitWindow(#"enum-type "the_quite_long_mood_of_the_day" values: "ok""#)
        defer { fresh.board.close() }
        pasteboardHolds(sql)
        expect(commandV(fresh))
        let measured = width(fresh)
        let w = try kitWindow()
        defer { w.board.close() }
        pasteboardHolds(sql)
        expect(commandV(w))
        let asWords = width(w)
        expect(measured != asWords, "a pill is not as wide as its words: \(measured) \(asWords)")
        w.editor.undo()
        _ = try drawnInProcess(#"enum-type "the_quite_long_mood_of_the_day" values: "ok""#, on: w.editor)
        expect(commandV(w), "the same pasteboard")
        expectEqual(width(w), measured, "read again with the file's enum")
    },
    test("R41: a key typed into a table folded to its marks shows a line more and pushes the table under it, in the row's step") {
        let w = try kitWindow(#"""
            table "customers" columns: "id uuid pk"
            table "orders" right of "customers" (gap: 200) columns: "id uuid pk\nnote text\ntotal int"
            """#)
        defer { w.board.close() }
        let editor = w.editor
        let orders = try require(table(editor, "orders"))
        editor.rowFolds?.fold([orders.id])
        let folded = try require(editor.shapeContext.frame(of: orders.id))
        _ = try drawnInProcess("table \"items\" columns: \"id uuid pk\"", on: editor)
        let items = try require(table(editor, "items")).id
        editor.transact("Place") { $0.update(items) { $0.box?.origin = CGPoint(x: folded.minX, y: folded.maxY + 60) } }
        editor.undoHistory.seal()
        let walk = w.walk()
        try w.edit("orders", row: "total")
        walk.press(.return)
        w.line?.paste(text: "customer_id uuid → customers.id")
        w.window.settle()
        walk.press(.escape)
        walk.press(.escape)
        expectEqual(keys(editor), ["orders.customer_id -> customers.id"])
        let now = try require(editor.shapeContext.frame(of: orders.id)), under = try require(editor.shapeContext.frame(of: items))
        expect(now.maxY > folded.maxY, "the keyed column shows in the fold: \(folded) \(now)")
        expect(under.minY >= now.maxY + 60 - 0.5, "pushed by the line its key shows: \(now) \(under)")
    },
    test("paste-1: a pasted schema laid out by its keys: each table beside, above, below or corner to corner with the tables it keys to, so no key's run passes under a card") {
        let w = try kitWindow()
        defer { w.board.close() }
        let editor = w.editor
        pasteboardHolds("""
            CREATE TABLE customers (id int PRIMARY KEY, email text UNIQUE);
            CREATE TABLE addresses (id int PRIMARY KEY, customer_id int REFERENCES customers (id), city text);
            CREATE TABLE categories (id int PRIMARY KEY, parent_id int REFERENCES categories (id));
            CREATE TABLE products (id int PRIMARY KEY, category_id int REFERENCES categories (id));
            CREATE TABLE orders (id bigint PRIMARY KEY, customer_id int REFERENCES customers (id), shipping_address_id int REFERENCES addresses (id));
            CREATE TABLE order_items (order_id bigint REFERENCES orders (id), product_id int REFERENCES products (id));
            CREATE TABLE payments (id bigint PRIMARY KEY, order_id bigint REFERENCES orders (id));
            CREATE TABLE shipments (id bigint PRIMARY KEY, order_id bigint REFERENCES orders (id));
            """)
        expect(commandV(w))
        let tables = editor.document.shapes.compactMap { $0.typed(as: DatabaseTable.self) }
        expectEqual(tables.count, 8)
        let frames = Dictionary(uniqueKeysWithValues: tables.map { ($0.id, editor.shapeContext.frame(of: $0.id) ?? $0.props.frame) })
        let arrows = keyArrows(editor)
        expectEqual(arrows.count, 9, "every key drawn")
        for arrow in arrows {
            guard let from = arrow.props.start.binding?.shapeID, let to = arrow.props.end.binding?.shapeID, from != to,
                  let a = frames[from], let b = frames[to] else { continue }
            let run = (CGPoint(x: a.midX, y: a.midY), CGPoint(x: b.midX, y: b.midY))
            for (id, card) in frames where id != from && id != to {
                let under = (1..<40).contains { step in
                    let t = CGFloat(step) / 40
                    return card.insetBy(dx: 4, dy: 4).contains(CGPoint(x: run.0.x + (run.1.x - run.0.x) * t, y: run.0.y + (run.1.y - run.0.y) * t))
                }
                expect(!under, "\(editor.document[from]?[TitleProperty.self] ?? "?") → \(editor.document[to]?[TitleProperty.self] ?? "?") passes under \(editor.document[id]?[TitleProperty.self] ?? "?")")
            }
        }
    },
    test("W-evolve-1: /new-version of an API whose tables are on the side out of view and the other side in view puts v2 where its copied arrows run clear of v1") {
        let lines = (["POST /orders"] + (1...22).map { "GET /orders/r\($0)" }).joined(separator: "\\n")
        let w = try kitWindow("""
            api "orders API" endpoints: "\(lines)"
            table "orders" right of "orders API" (gap: 160) columns: "id uuid pk"
            """)
        defer { w.board.close() }
        let editor = w.editor
        w.window.setContentSize(NSSize(width: 1280, height: 800))
        w.window.settle()
        _ = try drawnInProcess(#"edge "orders API"."POST /orders" -> "orders" channel: writes"#, on: editor)
        let api = try require(editor.document.shapes.first { $0[TitleProperty.self] == "orders API" }).id
        // The view as the walk had it: the API at its middle, its tables past the right edge.
        let old = try require(editor.shapeContext.frame(of: api))
        editor.camera = Camera(origin: CGPoint(x: old.minX - 600, y: old.minY - 100), zoom: 1)
        w.window.settle()
        editor.selectedShapeIDs = [api]
        editor.undoHistory.seal()
        let state = try require(editor.slashCommands)
        let command = try require(state.command(named: "new-version", for: .selection([api])))
        expect(state.run(command, with: SlashArguments([])))
        expectEqual(editor.undoHistory.undoName, "New Version")
        let v2 = try require(editor.document.shapes.first { $0[TitleProperty.self] == "orders API v2" }).id
        let copy = try require(editor.shapeContext.frame(of: v2)), table = try require(editor.shapeContext.frame(of: try require(table(editor, "orders")).id))
        expect(copy.maxX > old.minX, "not on v1's far side from the table: \(copy) \(old)")
        let copied = try require(editor.document.shapes.compactMap { $0.typed(as: Arrow.self) }.first { $0.props.start.binding?.shapeID == v2 })
        let row = try require(editor.shapeContext.geometry(of: v2)?.parts.frame(try require(copied.props.start.binding?.part))?.rect)
        let from = CGPoint(x: row.maxX, y: row.midY), to = CGPoint(x: table.midX, y: table.midY)
        let crosses = (1..<60).contains { step in
            let t = CGFloat(step) / 60
            return old.insetBy(dx: 2, dy: 2).contains(CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
        }
        expect(!crosses, "v2's writes line runs clear of v1")
    },
    test("W-apis-1: rows typed into an API above a table push the table so its pill stays clear of the API's waiting line") {
        let w = try kitWindow(#"""
            api "orders API" endpoints: "GET /orders"
            table "orders" below "orders API" (gap: 40) columns: "id uuid pk"
            """#)
        defer { w.board.close() }
        let editor = w.editor
        let api = try require(editor.document.shapes.first { $0[TitleProperty.self] == "orders API" }).id
        let orders = try require(table(editor, "orders")).id
        let walk = w.walk()
        editor.selectedShapeIDs = [api]
        editor.beginEditing(api)
        w.window.settle()
        for line in ["POST /orders", "GET /orders/{id}"] {
            w.type(line, with: walk)
            walk.press(.return)
            w.window.settle()
            let pill = try require(editor.adornmentFrames(of: orders).first { $0.adornment.placement == .aboveTopLeft }?.rect, "orders' pill")
            let overflow = editor.editedShapeOverflow?.areas ?? []
            expect(!overflow.contains { $0.intersects(pill) }, "the waiting line clear of orders' pill after \(line): \(overflow) \(pill)")
        }
        walk.press(.escape)
    },
    test("a pill a move plans for one key is reused by another key of the move only where that one's line to it is clean: beside, a pill of its own; below, the one pill") {
        for beside in [true, false] {
            let place = beside ? #"right of "payments" (gap: 100)"# : #"below "payments" (gap: 60)"#
            let w = try kitWindow(#"""
                table "customers" columns: "id uuid pk\nemail text unique"
                table "payments" right of "customers" (gap: 200) columns: "id uuid pk\ncustomer_id uuid → customers.id\namount int"
                table "refunds" \#(place) columns: "id uuid pk\ncustomer_id uuid → customers.id\nreason text"
                subboard "billing" below "customers" (gap: 300)
                """#)
            defer { w.board.close() }
            let editor = w.editor
            let billing = try board(editor, "billing")
            let payments = try require(table(editor, "payments")), refunds = try require(table(editor, "refunds"))
            let state = try require(editor.slashCommands)
            editor.selectedShapeIDs = [payments.id, refunds.id]
            let command = try require(state.command(named: "move-to", for: .selection(editor.selectedShapeIDs)))
            expect(state.run(command, with: SlashArguments([.shape(try require(billing.owner), label: "billing")])))
            expect(editor.showBoard(billing))
            expectEqual(keys(editor), ["payments.customer_id -> customers.id", "refunds.customer_id -> customers.id"], "both keys kept, through pills")
            if beside {
                // refunds' line to the pill level with payments' row would run across payments: a pill of its own.
                expectEqual(pills(editor, on: billing).count, 2, "the planned pill not reused where the line to it isn't clean")
                for (title, record) in [("payments", payments), ("refunds", refunds)] {
                    let row = try require(record.props.columns.first { $0.name == "customer_id" }).id
                    let key = try require(keyArrows(editor).first { $0.props.start.binding?.shapeID == record.id })
                    try expectClean(key.id, from: record.id, row: row, in: editor, view: false, "\(title)'s key after the move")
                }
            } else {
                expectEqual(pills(editor, on: billing).count, 1, "the planned pill reused: refunds' line to it is clean")
            }
        }
    },
    test("connect new-3 and new-4: after /move-to, the pills for what moved keep their lines and labels off the calls line at the same row, each line showing either side of its label") {
        let w = try kitWindow(#"""
            api "orders API" server: "api.shop.dev/v1 bearer" endpoints: "GET /orders/{id}\nPOST /orders/{id}/refunds"
            table "refunds" right of "orders API" (gap: 160) columns: "id uuid pk\npayment_id uuid\namount_cents int\nreason text null"
            table "payments" below "refunds" (gap: 50) columns: "id uuid pk\ncustomer_id uuid\namount_cents int"
            subboard "providers" below "orders API" (gap: 140)
            subboard "billing" below "providers" (gap: 60)
            """#)
        defer { w.board.close() }
        let editor = w.editor
        _ = try drawnInProcess(#"api "Stripe API" in "providers" endpoints: "POST /v1/refunds\nGET /v1/charges""#, on: editor)
        let drew = try drawnInProcess(#"""
            edge "orders API"."POST /orders/{id}/refunds" -> "refunds" channel: writes
            edge "orders API"."POST /orders/{id}/refunds" -> "payments" channel: reads
            """#, on: editor)
        expectEqual(Set(did(drew)), ["connected"])
        // The calls arrow as ⌘L makes it (the walk's): through a pill for Stripe's row, landed where its line from the row is clean.
        let api = try require(editor.document.shapes.first { $0[TitleProperty.self] == "orders API" }?.typed(as: API.self))
        let stripe = try require(editor.shape(inFile: try require(editor.contents(of: try board(editor, "providers")).shapes.first { $0[TitleProperty.self] == "Stripe API" }).id)?.typed(as: API.self))
        let post = try require(api.props.endpoints.first { $0.endpoint?.method == "POST" }).id
        let stripePost = try require(stripe.props.endpoints.first { $0.endpoint?.method == "POST" }).id
        // The view as the walk had it: the API at its left edge, so the pill lands on the row's right, below.
        editor.camera = Camera(origin: CGPoint(x: api.props.frame.minX - 30, y: api.props.frame.minY - 60), zoom: 1)
        w.window.settle()
        let made = editor.connect(ConnectEnd(api.id, part: post), to: ConnectEnd(stripe.id, part: stripePost))
        expect(made != nil, "connected")
        editor.undoHistory.seal()
        let state = try require(editor.slashCommands)
        let payments = try require(table(editor, "payments")), refunds = try require(table(editor, "refunds"))
        let billing = try board(editor, "billing")
        editor.selectedShapeIDs = [payments.id, refunds.id]
        let command = try require(state.command(named: "move-to", for: .selection(editor.selectedShapeIDs)))
        expect(state.run(command, with: SlashArguments([.shape(try require(billing.owner), label: "billing")])))
        expectEqual(editor.undoHistory.undoName, "Move")
        expect(editor.showBoard(.root))
        w.window.settle()
        let context = editor.shapeContext
        let calls = try require(editor.document.shapes.compactMap { $0.typed(as: Arrow.self) }.first { $0[ChannelProperty.self]?.rawValue == "calls" })
        let callsLine = arc(try require(context.geometry(of: calls.id), "the calls arrow drawn: \(calls)").outline)
        let moved = editor.document.shapes.compactMap { $0.typed(as: Arrow.self) }.filter { ["reads", "writes"].contains($0[ChannelProperty.self]?.rawValue ?? "") }
        expectEqual(moved.count, 2, "the reads and writes arrows kept, through pills")
        for arrow in moved {
            let geometry = try require(context.geometry(of: arrow.id))
            let label = try require(geometry.label, "\(arrow[ChannelProperty.self]?.rawValue ?? "?")'s label")
            let crossed = zip(callsLine, callsLine.dropFirst()).contains { a, b in
                (0...20).contains { step in
                    let t = CGFloat(step) / 20
                    return label.insetBy(dx: -2, dy: -2).contains(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                }
            }
            expect(!crossed, "the calls line runs clear of the \(arrow[ChannelProperty.self]?.rawValue ?? "?") pill: \(label)")
            // Its line shows either side of its label: the label is clear of where it starts and where it ends.
            let ends = [geometry.outline.first, geometry.outline.last].compactMap { $0 }
            for end in ends { expect(!label.insetBy(dx: -8, dy: -8).contains(end), "\(arrow[ChannelProperty.self]?.rawValue ?? "?")'s label clear of its ends: \(label) \(end)") }
        }
    },
])

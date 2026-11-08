import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CanvasUI
import Engineering
import LanguageModels
import LineRows
import Selection
import ShippedTesting
import TestKit
import TextEditing
import Titles

// The engineering kit as shipped: the cold first minute of T1 on a new board's window (the kit turned on, its segment's
// tools, a table put down with the caret in its name, ⇧↩ beside it), and `canvas draw`'s words for its rows (lines in the
// column grammar joined by name, an enum's values, a column's type bound to the enum it names, a run again unchanged).

@MainActor private func tables(_ editor: CanvasEditor) -> [ShapeRecord<DatabaseTable>] {
    editor.document.shapes.compactMap { $0.typed(as: DatabaseTable.self) }
}

@MainActor private func changes(_ json: JSON) -> [JSON?] { json["changes"]?.arrayValue?.map { $0["did"] } ?? [] }

/// Edit › Undo as the board's window validates it now: "Undo Add Column".
@MainActor func undoTitle(_ window: NSWindow) -> String {
    let item = NSMenuItem(title: "", action: NSSelectorFromString("undo:"), keyEquivalent: "")
    _ = window.validateMenuItem(item)
    return item.title
}

extension EmptyBoardWindow {
    /// File ▸ Kits ▸ Engineering, the canvas with the keyboard after.
    func turnKitOn() throws {
        let controller = try require(board.windowControllers.first as? BoardWindowController)
        controller.runCommand(commandItem(.kit(EngineeringKit.id), title: "Engineering"))
        window.makeFirstResponder(canvas)
    }

    /// The table being edited's session, and its focused stop.
    var lineRows: LineRowsView? { canvas.descendants(LineRowsView.self).first }
}

@MainActor let engineeringShippedTests = Suite("The engineering kit, shipped", [
    test("T7, panels 1 to 3, by the keys alone: /table customers ↩, email text unique ↩, name text ↩, ↩ on the empty row, ⇧↩ beside, orders ↩; each step its Undo") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        try w.turnKitOn()
        let walk = w.walk()
        walk.press(Chord("/"))
        w.type("table customers", with: walk)
        walk.press(.return)
        let customers = try require(tables(editor).first)
        expectEqual(customers.props.columns.map(ColumnGrammar.print), ["id uuid pk"])
        expectEqual(editor.editingShapeID, customers.id, "edited")
        expectEqual(w.lineRows?.focus, .waiting, "at its empty row")
        expect(w.window.firstResponder is LineField, "the line has the keys: \(String(describing: w.window.firstResponder))")
        expectEqual(undoTitle(w.window), "Undo Add Table")
        w.type("email text unique", with: walk)
        walk.press(.return)
        expectEqual(undoTitle(w.window), "Undo Add Column")
        w.type("name text", with: walk)
        walk.press(.return)
        expectEqual(undoTitle(w.window), "Undo Add Column")
        expectEqual(tables(editor).first?.props.columns.map(ColumnGrammar.print), ["id uuid pk", "email text unique", "name text"])
        walk.press(.return)
        expectEqual(editor.editingShapeID, nil, "↩ on the empty row ends editing")
        expectEqual(editor.selectedShapeIDs, [customers.id])
        walk.press(Chord(Key.return, .shift))
        let orders = try require(tables(editor).last)
        expect(orders.id != customers.id)
        expectEqual(w.lineRows?.focus, .title, "the new table edited in its name")
        expectEqual(undoTitle(w.window), "Undo Add Table")
        w.type("orders", with: walk)
        walk.press(.return)
        expectEqual(w.lineRows?.focus, .waiting, "↩ in the name: the empty row after id")
        expectEqual(editor.document[orders.id]?[TitleProperty.self], "orders")
        expectEqual(undoTitle(w.window), "Undo Add Table", "named as it was put down: one step")
        w.type("customer_id uuid", with: walk)
        walk.press(.return)
        expectEqual(undoTitle(w.window), "Undo Add Column")
        walk.press(.escape)
        expectEqual(tables(editor).last?.props.columns.map(ColumnGrammar.print), ["id uuid pk", "customer_id uuid"])
    },
    test("Edit ▸ Undo and Redo in a line: the board's step once the line has nothing of its own; an uncommitted draft is not written back by the undo that ends editing") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        try w.turnKitOn()
        let walk = w.walk()
        walk.press(Chord("/"))
        w.type("table customers", with: walk)
        walk.press(.return)
        let id = try require(tables(editor).first).id
        let columns = { @MainActor in tables(editor).first?.props.columns.map(ColumnGrammar.print) }
        let board = try require(w.window as? BoardWindow)
        w.type("email text unique", with: walk)
        walk.press(.return)
        expectEqual(columns(), ["id uuid pk", "email text unique"])
        board.undo(nil)
        expectEqual(columns(), ["id uuid pk"], "the column's step taken back")
        expect(editor.document[id] != nil)
        expectEqual(undoTitle(w.window), "Undo Add Table", "the next step back")
        board.redo(nil)
        expectEqual(columns(), ["id uuid pk", "email text unique"], "and put again")
        // A rename, then Undo: the line shown is not written back as the editing ends.
        editor.endEditing()
        editor.beginEditing(id)
        w.window.settle()
        w.lineRows?.go(to: .row(try require(tables(editor).first?.props.columns.last?.id)))
        w.lineRows?.field.setSelectedRange(NSRange(location: 5, length: 0))
        w.type("2", with: walk)
        walk.press(.down)
        expectEqual(columns(), ["id uuid pk", "email2 text unique"])
        expectEqual(undoTitle(w.window), "Undo Rename Column")
        board.undo(nil)
        expectEqual(columns(), ["id uuid pk", "email text unique"], "the rename taken back, not written again by the line's teardown")
        board.redo(nil)
        expectEqual(columns(), ["id uuid pk", "email2 text unique"], "redo has it")
    },
    test("the first minute by the keys (P12): a table (T1) and its columns (T2) take no more presses than clicks, typing aside") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        try w.turnKitOn()
        let walk = w.walk()
        var said: [String] = []
        @MainActor func task(_ name: String, clicks: Int, _ keys: @MainActor () -> Void) {
            let before = walk.presses.count
            keys()
            let presses = walk.presses.count - before
            said.append("\(name): \(presses) presses, \(clicks) clicks")
            expect(presses <= clicks, "\(name): \(presses) presses to \(clicks) clicks")
        }
        // By the pointer: the Table cell of the kit's strip and a click on the board, then its name typed.
        task("a table", clicks: 2) {
            walk.press(Chord("/"))
            w.type("table orders", with: walk)
            walk.press(.return)
        }
        // By the pointer: a click on the empty row, then each line typed and a click on the next.
        task("its columns", clicks: 3) {
            for line in ["customer_id uuid", "total_cents int", "placed_at timestamptz"] {
                w.type(line, with: walk)
                walk.press(.return)
            }
        }
        expectEqual(tables(editor).first?.props.columns.map(ColumnGrammar.print), ["id uuid pk", "customer_id uuid", "total_cents int", "placed_at timestamptz"],
                    "\(said)")
    },
    test("the first minute (T1): a new board has no table tool; File ▸ Kits ▸ Engineering turns its segment on; Insert ▸ Table puts one down with the caret in its name; ⇧↩ beside it, another") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor, registry = editor.registry
        let walk = w.walk()
        let table = ToolID(placing: DatabaseTable.kind)
        expect(!editor.isOn(EngineeringKit.self) && !editor.isToolEnabled(table), "off in a new file")
        let controller = try require(w.board.windowControllers.first as? BoardWindowController)
        controller.runCommand(commandItem(.kit(EngineeringKit.id), title: "Engineering"))
        expect(editor.isOn(EngineeringKit.self))
        expectEqual(registry.tools.filter { registry.kit(ofTool: $0.id) == EngineeringKit.id && editor.isToolEnabled($0.id) }.map(\.label),
                    ["Table", "Enum", "Database"], "the kit's segment")
        w.window.makeFirstResponder(w.canvas)
        expect(editor.perform(.insert(table)), "Insert ▸ Engineering ▸ Table")
        w.window.settle()
        let orders = try require(tables(editor).first)
        expectEqual(editor.editingShapeID, orders.id, "the caret in its name")
        expect(w.window.firstResponder is EditingTextView, "the title field has the keys: \(String(describing: w.window.firstResponder))")
        expectEqual(orders.props.columns.map(ColumnGrammar.print), ["id uuid pk"])
        w.type("orders", with: walk)
        walk.press(.return)
        expectEqual((w.canvas.descendants(LineRowsView.self).first)?.focus, .waiting, "Return in the name: the caret on its empty row (T1, panel 2)")
        walk.press(.return)
        expectEqual(editor.editingShapeID, nil, "Return on the empty row ends it")
        expectEqual(editor.document[orders.id]?[TitleProperty.self], "orders")
        expectEqual(editor.undoHistory.undoName, "Add Table", "put down and named: one step")
        expectEqual(editor.selectedShapeIDs, [orders.id])
        expectEqual(editor.menuTitle(of: .insertBeside), "New Table Beside")
        walk.press(Chord(Key.return, .shift))
        let beside = try require(tables(editor).last)
        expect(beside.id != orders.id)
        expectEqual(editor.editingShapeID, beside.id, "its name typed at once")
        w.type("payments", with: walk)
        walk.press(.escape)
        expectEqual(editor.document[beside.id]?[TitleProperty.self], "payments")
        let a = try require(editor.shapeContext.geometry(of: orders.id)?.bounds), b = try require(editor.shapeContext.geometry(of: beside.id)?.bounds)
        expect(!a.intersects(b) && b.minX > a.maxX, "beside it, to its right: \(a) \(b)")
        expectEqual(editor.undoHistory.undoName, "Add Table")
    },
    test("columns: takes lines in the column grammar, joined by name: a statement names what it changes, the rest stay, and a run again is unchanged") {
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
        editor.viewportDidResize(to: CGSize(width: 1440, height: 900))
        let first = try drawnInProcess(#"table "orders" columns: "id uuid pk\ncustomer_id uuid\nplaced_at timestamptz?""#, on: editor)
        expectEqual(changes(first), ["created"])
        let made = try require(tables(editor).first)
        expectEqual(made.props.columns.map(ColumnGrammar.print), ["id uuid pk", "customer_id uuid", "placed_at timestamptz null"])
        expectEqual(editor.shapeContext.geometry(of: made.id)?.bounds.height, 92, "as tall as its rows")
        let ids = made.props.columns.map(\.id)
        expectEqual(changes(try drawnInProcess(#"table "orders" columns: "id uuid pk\ncustomer_id uuid\nplaced_at timestamptz?""#, on: editor)), ["unchanged"])
        _ = try drawnInProcess(#"table "orders" columns: "customer_id uuid unique\ntotal_cents int""#, on: editor)
        let changed = try require(tables(editor).first)
        expectEqual(changed.props.columns.map(ColumnGrammar.print), ["id uuid pk", "customer_id uuid unique", "placed_at timestamptz null", "total_cents int"])
        expectEqual(Array(changed.props.columns.map(\.id).prefix(3)), ids, "the columns it had keep their ids")
    },
    test("values: an enum's values a line each; a column whose type is the enum's title is bound to it, and its pill says its name") {
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
        editor.viewportDidResize(to: CGSize(width: 1440, height: 900))
        _ = try drawnInProcess(#"enum-type "order_status" values: "pending\npaid\nrefunded""#, on: editor)
        let status = try require(editor.document.shapes.first { $0.kind == DatabaseEnum.kind })
        expectEqual(status.typed(as: DatabaseEnum.self)?.props.values.map(\.text), ["pending", "paid", "refunded"])
        _ = try drawnInProcess(#"table "orders" right of "order_status" columns: "id uuid pk\nstatus order_status""#, on: editor)
        let orders = try require(tables(editor).first)
        expectEqual(orders.props.columns.last?.type, TypeRef("order_status", shape: status.id))
        expectEqual(orders.props.columns.first?.type, TypeRef("uuid"), "a type of SQL's own names nothing")
        expectEqual(changes(try drawnInProcess(#"enum-type "order_status" values: "paid\nvoid""#, on: editor)), ["moved"],
                    "its box grew a row, as a note's does with its text")
        expectEqual(editor.document[status.id]?.typed(as: DatabaseEnum.self)?.props.values.map(\.text), ["pending", "paid", "refunded", "void"])
    },
    test("a table drawn with no columns: has the starter's one, id uuid pk, as the tool puts one down") {
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
        editor.viewportDidResize(to: CGSize(width: 1440, height: 900))
        _ = try drawnInProcess(#"table "plain""#, on: editor)
        let made = try require(tables(editor).first)
        expectEqual(made.props.columns.map(ColumnGrammar.print), ["id uuid pk"])
        expectEqual(editor.shapeContext.geometry(of: made.id)?.bounds.height, 44)
    },
    test("a database drawn with room holds the tables drawn in it, and the query that names it finds them") {
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
        editor.viewportDidResize(to: CGSize(width: 1440, height: 900))
        _ = try drawnInProcess(#"database "shop" size: 900x400"#, on: editor)
        _ = try drawnInProcess(#"table "products" in "shop" columns: "id uuid pk\nsku text unique""#, on: editor)
        let shop = try require(editor.document.shapes.first { $0.kind == Database.kind })
        expectEqual(tables(editor).first.flatMap { editor.document[$0.id]?.container }, shop.id)
    },
])

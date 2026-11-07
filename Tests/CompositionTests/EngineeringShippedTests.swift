import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CanvasUI
import Engineering
import LanguageModels
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

@MainActor let engineeringShippedTests = Suite("The engineering kit, shipped", [
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
        expectEqual(editor.editingShapeID, nil)
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

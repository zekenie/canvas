import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import ContextMenus
import Engineering
import Keyboard
import LineRows
import Selection
import SlashCommands
import TestKit
import TextEditing
import Titles

// The ways in that aren't a tool: `/table NAME`, `/database NAME` (around the selection, around every shape with none, an
// empty one on an empty board, refused round a locked shape) and Create Database in a table's menu; and ⇧↩ beside a table.

@MainActor let commandTests = Suite("Tables' commands", [
    test("/table orders on an empty board: a new table, id uuid pk, titled orders, in view, selected, edited at its empty line; one step, Add Table") {
        let h = try kitHarness()
        expect(h.offered.contains("table") && h.offered.contains("database"))
        expect(h.slash("table", "orders"))
        let table = try require(h.shapes(DatabaseTable.kind).first)
        expectEqual(table[TitleProperty.self], "orders")
        expectEqual(table.typed(as: DatabaseTable.self)?.props.columns.map(ColumnGrammar.print), ["id uuid pk"])
        expectEqual(h.editor.selectedShapeIDs, [table.id])
        expectEqual(h.editor.editingShapeID, table.id, "the caret on its empty row (T1, panel 2)")
        expectEqual((h.editor.makeEditingView()?.view as? LineRowsView)?.focus, .waiting)
        expectEqual(h.editor.undoHistory.undoName, "Add Table")
        expect(h.editor.unobscuredViewport.contains(try require(h.editor.shapeContext.geometry(of: table.id)?.bounds)), "in view")
        h.editor.undo()
        expect(h.shapes(DatabaseTable.kind).isEmpty)
    },
    test("/table payments with a table selected: beside it, as Insert puts one") {
        let h = try kitHarness()
        let orders = h.add(tableOrders(), titled: "orders")
        h.editor.selectedShapeIDs = [orders]
        expect(h.slash("table", "payments"))
        let payments = try require(h.shapes(DatabaseTable.kind).last)
        expectEqual(payments[TitleProperty.self], "payments")
        let a = try require(h.editor.shapeContext.geometry(of: orders)?.bounds), b = try require(h.editor.shapeContext.geometry(of: payments.id)?.bounds)
        expect(!a.intersects(b), "beside, clear of it")
        expect(abs(b.minX - a.maxX) < 200 || abs(b.minY - a.maxY) < 200, "near it: \(a) \(b)")
        expectEqual(h.editor.selectedShapeIDs, [payments.id])
    },
    test("/database shop round three selected shapes: one database holding them, 32 past them, selected, one step, Create Database") {
        let h = try kitHarness()
        let a = h.add(tableOrders(CGRect(x: 100, y: 100, width: 260, height: 116)), titled: "customers")
        let b = h.add(tableOrders(CGRect(x: 420, y: 100, width: 260, height: 116)), titled: "orders")
        let c = h.add(DatabaseEnum(frame: CGRect(x: 740, y: 100, width: 220, height: 68), values: [EnumValue(text: "pending")]), titled: "order_status")
        h.editor.selectedShapeIDs = [a, b, c]
        expect(h.slash("database", "shop"))
        let database = try require(h.shapes(Database.kind).first)
        expectEqual(database[TitleProperty.self], "shop")
        expectEqual(database.box, CGRect(x: 68, y: 68, width: 924, height: 180))
        expectEqual([a, b, c].map { h.editor.document[$0]?.container }, [database.id, database.id, database.id])
        expectEqual(h.editor.selectedShapeIDs, [database.id])
        expectEqual(h.editor.undoHistory.undoName, "Create Database")
        h.editor.undo()
        expect(h.shapes(Database.kind).isEmpty)
        expectEqual(h.editor.document[a]?.container, nil)
    },
    test("/database goes round a table as it's laid out, whatever height it stores: its rows' bottom and 32 past it") {
        let h = try kitHarness()
        let table = h.add(orders(CGRect(x: 100, y: 100, width: 260, height: 10)), titled: "orders")
        h.editor.selectedShapeIDs = [table]
        expect(h.slash("database", "shop"))
        let database = try require(h.shapes(Database.kind).first)
        expectEqual(database.box, CGRect(x: 68, y: 68, width: 324, height: 180), "100 + 116 + 32 = 248 down")
        expectEqual(h.editor.document[table]?.container, database.id)
    },
    test("/database with nothing selected goes round every shape on the board; on an empty board it's an empty one in view") {
        let h = try kitHarness()
        let a = h.add(tableOrders(), titled: "orders")
        let box = h.add(Box(CGRect(x: 500, y: 400, width: 50, height: 50)))
        h.editor.selectedShapeIDs = []
        expect(h.slash("database", "shop"))
        let database = try require(h.shapes(Database.kind).first)
        expectEqual([a, box].map { h.editor.document[$0]?.container }, [database.id, database.id])
        let empty = try kitHarness()
        expect(empty.slash("database", "archive"))
        let alone = try require(empty.shapes(Database.kind).first)
        expectEqual(alone.box?.size, CGSize(width: 640, height: 400))
        expectEqual(alone[TitleProperty.self], "archive")
        expectEqual(empty.editor.undoHistory.undoName, "Create Database")
        expect(empty.editor.unobscuredViewport.contains(try require(alone.box)))
    },
    test("round a locked shape: nothing done, the locked shape shakes, no step") {
        let refusals = RefusalLog()
        let h = try kitHarness(refusals)
        let a = h.add(tableOrders(), titled: "orders")
        let b = h.add(tableOrders(CGRect(x: 420, y: 100, width: 260, height: 116)), titled: "payments")
        h.editor.freeze([b])
        h.editor.selectedShapeIDs = [a, b]
        let step = h.editor.undoHistory.undoName
        h.slash("database", "shop")
        expect(h.shapes(Database.kind).isEmpty)
        expectEqual(refusals.refusals, [[b]])
        expectEqual(h.editor.undoHistory.undoName, step)
    },
    test("Create Database is in a table's menu and an enum's, not a box's alone; chosen, an untitled database round the selection, one step") {
        let h = try kitHarness()
        let a = h.add(tableOrders(), titled: "orders")
        let box = h.add(Box(CGRect(x: 600, y: 500, width: 50, height: 50)))
        h.editor.selectedShapeIDs = [box]
        expect(!(h.secondaryClick(at: CGPoint(x: 625, y: 525))?.outline ?? []).contains("Create Database"))
        h.editor.selectedShapeIDs = [a]
        let menu = try require(h.secondaryClick(at: CGPoint(x: 200, y: 150)))
        expect(menu.outline.contains("Create Database"), "\(menu.outline)")
        try menu.choose("Create Database")
        let database = try require(h.shapes(Database.kind).first)
        expectEqual(database[TitleProperty.self], nil)
        expectEqual(h.editor.document[a]?.container, database.id)
        expectEqual(h.editor.undoHistory.undoName, "Create Database")
    },
    test("Create Database from an enum's menu: an untitled database round it, one step") {
        let h = try kitHarness()
        let status = h.add(DatabaseEnum(frame: CGRect(x: 100, y: 100, width: 200, height: 68), values: [EnumValue(text: "paid")]), titled: "order_status")
        h.editor.selectedShapeIDs = [status]
        let menu = try require(h.secondaryClick(at: CGPoint(x: 200, y: 140)))
        expect(menu.outline.contains("Create Database"), "\(menu.outline)")
        try menu.choose("Create Database")
        let database = try require(h.shapes(Database.kind).first)
        expectEqual(h.editor.document[status]?.container, database.id)
        expectEqual(h.editor.undoHistory.undoName, "Create Database")
    },
    test("⇧↩ with a table selected: a new table beside it, its name typed at once; the name joins Add Table") {
        let h = try kitHarness()
        let orders = h.add(tableOrders(), titled: "orders")
        h.editor.selectedShapeIDs = [orders]
        expectEqual(h.editor.menuTitle(of: .insertBeside), "New Table Beside")
        expect(h.editor.perform(.insertBeside))
        let made = try require(h.shapes(DatabaseTable.kind).last)
        expect(made.id != orders)
        expectEqual(h.editor.editingShapeID, made.id, "the caret in its name")
        let view = try require(h.editor.makeEditingView()?.view as? LineRowsView)
        expectEqual(view.focus, .title, "an untitled table starts in its name")
        let field = try require(view.titleField)
        field.field.insertText("payments", replacementRange: NSRange(location: 0, length: 0))
        field.field.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        expectEqual(view.focus, .waiting, "Return in the name goes to the empty line")
        view.field.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        expectEqual(h.editor.editingShapeID, nil, "and Return there ends it")
        expectEqual(h.editor.document[made.id]?[TitleProperty.self], "payments")
        expectEqual(h.editor.undoHistory.undoName, "Add Table", "placed and named, one step")
        h.editor.undo()
        expectEqual(h.shapes(DatabaseTable.kind).count, 1)
    },
])

/// `orders` from Support.
func tableOrders(_ frame: CGRect = CGRect(x: 100, y: 100, width: 260, height: 116)) -> DatabaseTable { orders(frame) }

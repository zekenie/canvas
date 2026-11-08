import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Engineering
import Geometry
import LineRows
import Selection
import TestKit
import Titles

// A table's columns as items of the table (K8) on the kit's kinds: a folded table's hidden columns stand at its +N line, so a
// selected one a fold hides shows as that line selected and comes back as itself on unfold; columns taken out are a new table
// of their own, its `id uuid pk` first, its name typed at once, one step; an enum's values are an enum of their own.

@MainActor let rowItemTests = Suite("A table's columns as items", [
    test("a fold hiding a selected column moves the item selection to +38 ›; unfolded, the column is selected again; one Escape goes to the table") {
        let b = try KitBench()
        let id = b.h.add(products(), titled: "products")
        let weight = try require(b.editor.document[id]?.typed(as: DatabaseTable.self)?.props.columns[2].id)
        b.editor.selectItems([AnyHashable(weight)], of: id)
        expectEqual(b.editor.selectedItems?.ids, [AnyHashable(weight)])
        b.editor.selectedShapeIDs = [id]
        expect(b.editor.perform(.foldRows))
        b.window.settle()
        let more = try require(b.editor.shapeItems(of: id).last)
        expectEqual(more.title, "38 more columns")
        expect(more.stands.contains(AnyHashable(weight)), "the +N line stands for the hidden column")
        b.editor.selectItems([AnyHashable(weight)], of: id)
        expectEqual(b.editor.selectedItems?.ids, [more.id], "the line standing for it, selected")
        expect(b.editor.perform(.unfoldRows))
        b.window.settle()
        expectEqual(b.editor.selectedItems?.ids, [AnyHashable(weight)], "given back")
        expect(b.editor.perform(.foldRows))
        b.window.settle()
        b.editor.cancel()
        expectEqual(b.editor.selectedItems, nil)
        expectEqual(b.editor.selectedShapeIDs, [id], "one Escape: the table")
    },
    test("columns taken out are a new table: its own id uuid pk first, as wide as theirs, untitled, its name typed at once; Move Columns to New Table, one step with the name") {
        let b = try KitBench()
        let id = b.h.add(products(), titled: "products")
        let columns = try require(b.editor.document[id]?.typed(as: DatabaseTable.self)?.props.columns)
        b.editor.undoHistory.seal()
        let made = try require(b.editor.moveRows([columns[1].id, columns[2].id], of: id, to: .beside([id])))
        b.window.settle()
        let table = try require(b.editor.document[made]?.typed(as: DatabaseTable.self))
        expectEqual(table.props.columns.map(ColumnGrammar.print), ["id uuid pk", "sku text unique", "weight_grams int"])
        expectEqual(table.props.columns[1].id, columns[1].id, "the columns keep their ids")
        expectEqual(table.props.frame.width, 300)
        expectEqual(b.editor.document[made]?[TitleProperty.self], nil, "untitled")
        expectEqual(b.editor.editingShapeID, made, "its name typed at once")
        expectEqual(b.editor.undoHistory.undoName, "Move Columns to New Table")
        b.editor.endEditing()
        b.editor.undo()
        expectEqual(b.editor.document[made], nil)
        expectEqual(b.editor.document[id]?.typed(as: DatabaseTable.self)?.props.columns.count, 40, "one Undo")
    },
    test("columns taken out that hold the key bring no second id uuid pk: the id column, any primary key, every column") {
        let b = try KitBench()
        let id = b.h.add(products(), titled: "products")
        let columns = try require(b.editor.document[id]?.typed(as: DatabaseTable.self)?.props.columns)
        let first = try require(columns.first)
        expectEqual(first.name, "id")
        let made = try require(b.editor.moveRows([first.id, columns[1].id], of: id, to: .beside([id])))
        let table = try require(b.editor.document[made]?.typed(as: DatabaseTable.self))
        expectEqual(table.props.columns.map(\.name), ["id", columns[1].name], "one id")
        expectEqual(table.props.columns.filter(\.primaryKey).count, 1)
        b.editor.endEditing()
        let other = b.h.add(products(at: CGPoint(x: 600, y: 100)), titled: "again")
        let sku = try require(b.editor.document[other]?.typed(as: DatabaseTable.self)?.props.columns[1])
        let plain = try require(b.editor.moveRows([sku.id], of: other, to: .beside([other])))
        expectEqual(b.editor.document[plain]?.typed(as: DatabaseTable.self)?.props.columns.map(\.name), ["id", "sku"], "none of its own: the starter's")
    },
    test("columns on the pasteboard are not an enum's values: ⌘V in an enum's line is the text's paste, not swallowed; in a table's line the rows land") {
        let b = try KitBench()
        let t = b.table("t", ["id uuid pk", "name text"])
        let e = b.enumType("status", ["a", "b"])
        expect(b.editor.copyRows([b.columns(t)[1].id], of: t))
        b.begin(e)
        expectEqual(b.field.onRows?(.paste), false, "an enum takes no columns: the key goes on as text")
        expectEqual(b.values(e), ["a", "b"])
        b.editor.endEditing()
        b.begin(t)
        expectEqual(b.field.onRows?(.paste), true, "a table takes them")
        expectEqual(b.lines(t), ["id uuid pk", "name text", "name text"])
    },
    test("an enum's values taken out are an enum of their own") {
        let b = try KitBench()
        let type = b.h.add(DatabaseEnum(frame: CGRect(x: 100, y: 100, width: 200, height: 100), values: ["pending", "paid", "refunded"].map { EnumValue(text: $0) }),
                           titled: "order_status")
        let values = try require(b.editor.document[type]?.typed(as: DatabaseEnum.self)?.props.values)
        let made = try require(b.editor.moveRows([values[2].id], of: type, to: .beside([type])))
        expectEqual(b.editor.document[made]?.typed(as: DatabaseEnum.self)?.props.values.map(\.text), ["refunded"])
        expectEqual(b.editor.undoHistory.undoName, "Move Value to New Enum")
    },
])

import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Engineering
import Geometry
import Keyboard
import LineRows
import Selection
import TestKit
import TextEditing
import Titles

// A new table's or enum's name typed in its pill (Titles' title field), the first stop of its editing (LineRows): put down by
// its tool, the caret is in its name and typing joins the step that placed it ("Add Table"), Return going on to its empty
// line; later, ↑ from its first row types its name again, a step of its own ("Rename Table"); Escape ends it; VoiceOver calls
// the field by what it names.

@MainActor private func field(_ h: EditorHarness) throws -> TitleField {
    try require((h.editor.makeEditingView()?.view as? LineRowsView)?.titleField)
}

@MainActor private func type(_ text: String, into field: TitleField) {
    field.field.insertText(text, replacementRange: NSRange(location: field.field.string.utf16.count, length: 0))
}

@MainActor let titleFieldTests = Suite("A table's name typed in its pill", [
    test("the Table tool and a click: a table, id uuid pk, the caret in its name; typed, its title, one step Add Table; Return to its empty line, Return again ends it") {
        let h = try kitHarness()
        h.editor.setTool(ToolID(placing: DatabaseTable.kind))
        h.click(at: CGPoint(x: 400, y: 300))
        let table = try require(h.shapes(DatabaseTable.kind).first)
        expectEqual(h.editor.editingShapeID, table.id, "edited as it lands")
        let editing = try require(h.editor.makeEditingView())
        let view = try require(editing.view as? LineRowsView)
        let typed = try require(view.titleField)
        expect(editing.firstResponder === typed.field, "the caret in the name")
        expectEqual(typed.field.accessibilityLabel(), "Table name")
        expectEqual(typed.placeholder, "Untitled Table", "the pill says what the panel and the contents call it, dimmed, while nothing is typed")
        type("ord", into: typed)
        type("ers", into: typed)
        expectEqual(h.editor.document[table.id]?[TitleProperty.self], "orders")
        typed.field.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        expectEqual(view.focus, .waiting, "Return goes to the empty line")
        view.field.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        expectEqual(h.editor.editingShapeID, nil, "Return on it ends editing")
        expectEqual(h.editor.undoHistory.undoName, "Add Table", "placed and named, one step")
        expectEqual(h.editor.announcements, ["Add Table"], "VoiceOver hears it placed, once: the name typed into that step isn't said again")
        h.editor.undo()
        expect(h.shapes(DatabaseTable.kind).isEmpty)
        h.editor.redo()
        let back = try require(h.shapes(DatabaseTable.kind).first)
        expectEqual(back.id, table.id)
        expectEqual(back[TitleProperty.self], "orders", "redone, placed and named as one step")
        expectEqual(back.typed(as: DatabaseTable.self)?.props.columns.map(ColumnGrammar.print), ["id uuid pk"])
        expectEqual(h.editor.editingShapeID, nil, "redo doesn't open the field again")
    },
    test("a titled table edited, its name is the first stop: typed again, a step of its own, Rename Table; Escape ends it, keeping what was typed; a blank name is none") {
        let h = try kitHarness()
        let table = h.add(orders(), titled: "orders")
        h.editor.selectedShapeIDs = [table]
        h.editor.undoHistory.seal()
        expect(h.key("\r"), "Return edits the selected shape")
        let view = try require(h.editor.makeEditingView()?.view as? LineRowsView)
        expectEqual(view.focus, .waiting, "titled, it starts at its empty line")
        view.go(to: .title)
        let typed = try require(view.titleField)
        expectEqual(typed.field.string, "orders", "its name, the caret after it")
        let heard = h.editor.announcements.count
        type("_v2", into: typed)
        typed.field.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        expectEqual(h.editor.editingShapeID, nil)
        expectEqual(h.editor.document[table]?[TitleProperty.self], "orders_v2")
        expectEqual(Array(h.editor.announcements.dropFirst(heard)), ["Rename Table"], "VoiceOver hears the rename, once")
        expectEqual(h.editor.undoHistory.undoName, "Rename Table")
        h.editor.undo()
        expectEqual(h.editor.document[table]?[TitleProperty.self], "orders")
        h.editor.beginEditing(table)
        let againView = try require(h.editor.makeEditingView()?.view as? LineRowsView)
        againView.go(to: .title)
        let again = try require(againView.titleField)
        again.field.insertText("  ", replacementRange: NSRange(location: 0, length: again.field.string.utf16.count))
        again.field.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        expectEqual(h.editor.document[table]?[TitleProperty.self], nil, "a blank name is none")
    },
    test("an enum put down by its tool is named the same way, its pill saying Untitled Enum dimmed until typed; its field in its pill's purple, Add Enum") {
        let h = try kitHarness()
        h.editor.setTool(ToolID(placing: DatabaseEnum.kind))
        h.click(at: CGPoint(x: 400, y: 300))
        let made = try require(h.shapes(DatabaseEnum.kind).first)
        let typed = try field(h)
        expectEqual(typed.field.accessibilityLabel(), "Enum name")
        expectEqual(typed.placeholder, "Untitled Enum", "as a table's says Untitled Table, never a caret over half the word")
        type("order_status", into: typed)
        typed.field.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        expectEqual(h.editor.document[made.id]?[TitleProperty.self], "order_status")
        expectEqual(h.editor.undoHistory.undoName, "Add Enum")
    },
    test("the Database tool and a click: a database at its default size, selected, one step, Add Database; ⇧↩ beside an enum makes an enum, Add Enum") {
        let h = try kitHarness()
        h.editor.setTool(ToolID(placing: Database.kind))
        h.click(at: CGPoint(x: 400, y: 300))
        let database = try require(h.shapes(Database.kind).first)
        expectEqual(h.editor.document[database.id]?.typed(as: Database.self)?.props.frame.size, CGSize(width: 640, height: 400))
        expectEqual(h.editor.selectedShapeIDs, [database.id])
        expectEqual(h.editor.undoHistory.undoName, "Add Database")
        let status = h.add(DatabaseEnum(frame: CGRect(x: 800, y: 600, width: 200, height: 68), values: [EnumValue(text: "paid")]), titled: "order_status")
        h.editor.selectedShapeIDs = [status]
        expectEqual(h.editor.menuTitle(of: .insertBeside), "New Enum Beside")
        expect(h.editor.perform(.insertBeside))
        let made = try require(h.shapes(DatabaseEnum.kind).last)
        expect(made.id != status)
        expectEqual(h.editor.editingShapeID, made.id, "the caret in its name")
        let field = try require((h.editor.makeEditingView()?.view as? LineRowsView)?.titleField)
        type("shipments", into: field)
        field.field.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        expectEqual(h.editor.undoHistory.undoName, "Add Enum")
    },
    test("the field lies on the pill's row, from the paper's left end, the pill's height at 100% and zoomed in; the rest of its view takes no press") {
        let h = try kitHarness()
        let table = h.add(orders(), titled: "orders")
        for zoom in [1.0, 2.0] as [CGFloat] {
            h.editor.camera = Camera(origin: .zero, zoom: zoom)
            let pill = try require(h.editor.titlePillRect(of: table))
            h.editor.beginEditing(table)
            let frame = try require(h.editor.editingFrame)
            expectEqual(frame.minX, pill.minX, "from the pill's left end at \(zoom)")
            expectEqual(frame.minY, pill.minY, "its top is the pill's at \(zoom)")
            let editing = try require(h.editor.makeEditingView())
            let host = try require(editing.view as? LineRowsView)
            host.frame = CGRect(x: 0, y: 0, width: frame.width * zoom, height: frame.height * zoom)
            host.bounds = CGRect(origin: .zero, size: frame.size)
            host.layoutSubtreeIfNeeded()
            expectEqual(try require(host.titleField).frame.height, pill.height, "as tall as the pill at \(zoom)")
            expectEqual(try require(host.titleField).frame.minY, 0, "on the pill's row at \(zoom)")
            expect(host.hitTest(CGPoint(x: frame.width * zoom - 2, y: pill.height * zoom / 2)) == nil, "the pill's row past the chip isn't the field's")
            h.editor.endEditing()
        }
    },
])

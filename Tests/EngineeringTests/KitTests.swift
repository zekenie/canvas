import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import ContextMenus
import Engineering
import Keyboard
import Selection
import SlashCommands
import TestKit
import Titles

// The kit off in a file: its tools, their Insert items, `/table`, `/database` and Create Database are gone; its shapes stay,
// drawn, moved, renamed and deleted as any shape; ⇧↩ on a table makes a note.

@MainActor let kitTests = Suite("The kit off", [
    test("off, every way in is gone and its shapes stay; on in one step, they're back") {
        let h = try kitHarness(on: false)
        let tools = [DatabaseTable.kind, DatabaseEnum.kind, Database.kind].map(ToolID.init(placing:))
        expect(tools.allSatisfy { !h.editor.isToolEnabled($0) && !h.editor.claims(.insert($0)) })
        let table = h.add(orders(), titled: "orders")
        h.editor.selectedShapeIDs = [table]
        expect(!h.offered.contains("table") && !h.offered.contains("database"))
        expect(!h.editor.claims(.createDatabase))
        expect(!(h.secondaryClick(at: CGPoint(x: 200, y: 150))?.outline ?? []).contains("Create Database"))
        expectEqual(h.editor.toolBeside([table]), nil, "no note tool in this list: nothing to put beside it")
        expect(h.editor.shapeContext.geometry(of: table) != nil, "still drawn")
        h.editor.transact("Move") { $0.update(table, as: DatabaseTable.self) { $0.props.frame.origin.x += 40 } }
        h.editor.beginEditing(table)
        expect(h.editor.editingShapeID == table, "renamed in its pill as ever: the kinds never switch")
        h.editor.endEditing()
        h.editor.turn(EngineeringKit.self, on: true)
        expectEqual(h.editor.undoHistory.undoName, "Turn On Engineering")
        expect(tools.allSatisfy { h.editor.isToolEnabled($0) })
        expect(h.offered.contains("table") && h.offered.contains("database"))
        expect(h.editor.claims(.createDatabase))
    },
])

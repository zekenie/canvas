import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Clipboard
import Connections
import Engineering
import LineRows
import References
import Selection
import ShippedTesting
import TestKit
import Titles

// Pastes, puts and moves across boards, as shipped (U7: the whole-branch review's and the third UX walk's findings), through the
// app's window: a cut's paste on another board while its rows are back is a copy (R3).

@MainActor private func table(_ editor: CanvasEditor, _ title: String) -> ShapeRecord<DatabaseTable>? {
    for board in editor.file.everyBoard {
        if let found = editor.contents(of: board).shapes.first(where: { $0[TitleProperty.self] == title })?.typed(as: DatabaseTable.self) { return found }
    }
    return nil
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
])

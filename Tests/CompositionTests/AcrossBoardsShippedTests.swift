import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CanvasUI
import Connections
import Draw
import Engineering
import LanguageModels
import LineRows
import References
import Selection
import ShippedTesting
import SlashCommands
import Subboards
import TestKit
import TextEditing
import Titles
import Topology

// Keys across boards (K10), as shipped: a key to a column on another board ends at a reference pill for the column's table, the
// column on the arrow's binding (the plan's section 3, "Through a pill"). ⌘L's pick and T6 panel 3's typed `→ customers.id` place
// or reuse that pill in their step; T6 panel 2's `/move-to billing` keeps the keys through pills, the arrow going where its start
// goes; deleting customers.id on the root reaches billing's key through the pill; `canvas draw` names a row on another board
// (drawn, drawn again `unchanged`, `delete edge`). The key reads as the column's (Topology's edge, the line's `→ customers.id`).

@MainActor private func records(_ editor: CanvasEditor, on board: BoardID) -> [AnyShapeRecord] { Array(editor.contents(of: board).shapes) }

@MainActor private func table(_ editor: CanvasEditor, _ title: String) -> ShapeRecord<DatabaseTable>? {
    for board in editor.file.everyBoard {
        if let found = editor.contents(of: board).shapes.first(where: { $0[TitleProperty.self] == title })?.typed(as: DatabaseTable.self) { return found }
    }
    return nil
}

@MainActor private func column(_ editor: CanvasEditor, _ title: String, _ name: String) -> PartID? {
    table(editor, title)?.props.columns.first { $0.name == name }?.id
}

@MainActor private func pills(_ editor: CanvasEditor, on board: BoardID) -> [ShapeRecord<Reference>] {
    records(editor, on: board).compactMap { $0.typed(as: Reference.self) }
}

@MainActor private func arrows(_ editor: CanvasEditor, on board: BoardID) -> [ShapeRecord<Arrow>] {
    records(editor, on: board).compactMap { $0.typed(as: Arrow.self) }
}

/// Each key of the file as Topology reads it, through pills: `from.column -> to.column`, by the tables' titles and columns' names.
@MainActor private func keys(_ editor: CanvasEditor) -> [String] {
    guard let topology = editor.topology else { return [] }
    var said: [String] = []
    for board in editor.file.everyBoard {
        for record in editor.contents(of: board).shapes where record.kind == DatabaseTable.kind {
            for edge in topology.edges(of: record.id, .outgoing, types: .only(EdgeTypeID(rawValue: ForeignKey.id.rawValue))) where edge.isConnection {
                @MainActor func name(_ id: ShapeID, _ part: PartID?) -> String {
                    let shape = editor.shape(inFile: id)
                    let row = shape.flatMap { editor.registry.parts(of: $0)?.first { $0.id == part }?.name } ?? "?"
                    return "\(shape?[TitleProperty.self] ?? "?").\(row)"
                }
                said.append("\(name(edge.source, edge.sourcePart)) -> \(name(edge.target, edge.targetPart))")
            }
        }
    }
    return said.sorted()
}

/// The shop on the root and a billing subboard below it, with statements on billing's board, shown.
private let shop = #"""
    table "customers" columns: "id uuid pk\nemail text unique\nname text"
    table "orders" right of "customers" (gap: 200) columns: "id uuid pk\ncustomer_id uuid\ntotal_cents int"
    table "payments" below "orders" columns: "id uuid pk\norder_id uuid\namount_cents int"
    table "refunds" right of "payments" columns: "id uuid pk\npayment_id uuid\nreason text null"
    subboard "billing" below "customers"
    edge "orders".customer_id -> "customers".id
    edge "payments".order_id -> "orders".id
    edge "refunds".payment_id -> "payments".id
    """#

@MainActor private func shopEditor() throws -> (editor: CanvasEditor, billing: BoardID) {
    let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
    editor.viewportDidResize(to: CGSize(width: 1440, height: 900))
    _ = try drawnInProcess(shop, on: editor)
    let billing = try require(editor.document.shapes.first { $0[TitleProperty.self] == "billing" })
    _ = try drawnInProcess(#"table "statements" in "billing" columns: "id uuid pk\ncustomer_id uuid\naccount_id uuid\nperiod daterange""#, on: editor)
    return (editor, BoardID(owner: billing.id))
}

@MainActor let acrossBoardsShippedTests = Suite("Keys across boards, shipped", [
    test("⌘L from a row to a column of a table on another board: a pill for the table beside the start, the column on the binding; another key reuses the pill; one Connect each") {
        let (editor, billing) = try shopEditor()
        expect(editor.showBoard(billing))
        let statements = try require(table(editor, "statements")), customers = try require(table(editor, "customers"))
        let made = editor.connect(ConnectEnd(statements.id, part: column(editor, "statements", "customer_id")),
                                  to: ConnectEnd(customers.id, part: column(editor, "customers", "id")))
        let arrow = try require(made.flatMap { editor.document[$0]?.typed(as: Arrow.self) })
        expectEqual(editor.undoHistory.undoName, "Connect")
        let pill = try require(pills(editor, on: billing).first)
        expectEqual(pills(editor, on: billing).count, 1)
        expectEqual(pill.props.target?.id, customers.id, "a pill for the table")
        expectEqual(pill.props.target?.row, nil, "a column doesn't stand alone: the pill is the table's")
        expectEqual(arrow.props.end.binding?.shapeID, pill.id)
        expectEqual(arrow.props.end.binding?.part, column(editor, "customers", "id"), "the column on the binding")
        expectEqual(arrow.props.end.binding?.isExact, false, "the arrow meets the pill as a whole")
        expect(try require(pill.frame(in: editor)).minX > statements.props.frame.maxX, "beside the start, right of it")
        expectEqual(keys(editor), ["orders.customer_id -> customers.id", "payments.order_id -> orders.id", "refunds.payment_id -> payments.id",
                                   "statements.customer_id -> customers.id"], "read as a key to the column")
        editor.connect(ConnectEnd(statements.id, part: column(editor, "statements", "account_id")),
                       to: ConnectEnd(customers.id, part: column(editor, "customers", "email")))
        expectEqual(pills(editor, on: billing).count, 1, "the board's pill for the table is reused")
        expect(keys(editor).contains("statements.account_id -> customers.email"))
        editor.undo()
        editor.undo()
        expectEqual(pills(editor, on: billing).count, 0, "undone with its pill")
        expectEqual(arrows(editor, on: billing).count, 0)
    },
    test("a pill for a table takes its rows' keys on its parts: no foreign-key dots, no side a key ends on, a named row through it taken") {
        let (editor, _) = try shopEditor()
        let registry = editor.registry, stands = [DatabaseTable.kind]
        expectEqual(registry.dotChannels(of: Reference.kind, standingFor: stands), [], "no dots of its own")
        expectEqual(registry.partDotChannels(of: Reference.kind, standingFor: stands), [ForeignKey.id], "on its parts, of which it has none")
        expect(!registry.takes(Reference.kind, standingFor: stands, ForeignKey.id, as: .target, side: .left), "no side takes a key")
        expect(registry.takesOnParts(Reference.kind, standingFor: stands, ForeignKey.id, as: .target), "a key to a column through it")
    },
    test("T6, panel 3: on billing, typing customer_id uuid → customers.id in statements places a customers pill with its key, one step") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        try w.turnKitOn()
        _ = try drawnInProcess(shop, on: w.editor)
        let billing = try require(w.editor.document.shapes.first { $0[TitleProperty.self] == "billing" })
        _ = try drawnInProcess(#"table "statements" in "billing" columns: "id uuid pk\nperiod daterange""#, on: w.editor)
        expect(w.editor.showBoard(BoardID(owner: billing.id)))
        w.editor.undoHistory.seal()
        w.window.makeFirstResponder(w.canvas)
        w.window.settle()
        let statements = try require(table(w.editor, "statements"))
        let walk = w.walk()
        w.editor.selectedShapeIDs = [statements.id]
        w.editor.beginEditing(statements.id)
        w.window.settle()
        w.lineRows?.go(to: .row(try require(column(w.editor, "statements", "id"))))
        w.window.settle()
        walk.press(.return)
        w.type("customer_id uuid -> customers.id", with: walk)
        expectEqual(w.lineRows?.field.string, "customer_id uuid → customers.id")
        walk.press(.return)
        let board = BoardID(owner: billing.id)
        let pill = try require(pills(w.editor, on: board).first)
        expectEqual(pill.props.target?.id, table(w.editor, "customers")?.id)
        expect(keys(w.editor).contains("statements.customer_id -> customers.id"), "\(keys(w.editor))")
        expectEqual(w.editor.undoHistory.undoName, "Add Column", "the pill and the key in the row's step")
        w.editor.undo()
        expectEqual(pills(w.editor, on: board).count, 0, "one undo takes the column, its key and the pill")
        expect(!keys(w.editor).contains { $0.hasPrefix("statements.") })
    },
    test("deleting customers.id on the root reaches billing's key through the pill in the same step: Delete Column and 1 Arrow; undone exactly") {
        let (editor, billing) = try shopEditor()
        expect(editor.showBoard(billing))
        let statements = try require(table(editor, "statements")), customers = try require(table(editor, "customers"))
        editor.connect(ConnectEnd(statements.id, part: column(editor, "statements", "customer_id")),
                       to: ConnectEnd(customers.id, part: column(editor, "customers", "id")))
        expect(editor.showBoard(.root))
        editor.undoHistory.seal()
        let before = editor.file
        _ = try drawnInProcess(#"delete "customers".id"#, on: editor)
        expectEqual(arrows(editor, on: billing).count, 0, "billing's key through the pill went with the column")
        expectEqual(pills(editor, on: billing).count, 1, "the pill stays, as a pill a delete empties does")
        expect(!keys(editor).contains { $0.hasSuffix("-> customers.id") })
        editor.undo()
        expectEqual(editor.file[billing], before[billing], "billing as it was")
        expectEqual(editor.file[.root], before[.root], "the root as it was")
    },
    test("T6, panel 2: /move-to billing with payments and refunds selected keeps the keys through a pill for orders, the column on the binding; one Move, undone on both boards") {
        let (editor, billing) = try shopEditor()
        let payments = try require(table(editor, "payments")), refunds = try require(table(editor, "refunds"))
        let owner = try require(billing.owner)
        let before = editor.file
        let state = try require(editor.slashCommands)
        editor.selectedShapeIDs = [payments.id, refunds.id]
        let command = try require(state.command(named: "move-to", for: .selection(editor.selectedShapeIDs)))
        expect(state.run(command, with: SlashArguments([.shape(owner, label: "billing")])))
        expectEqual(editor.undoHistory.undoName, "Move")
        expectEqual(editor.file.board(containing: payments.id), billing)
        let pill = try require(pills(editor, on: billing).first { $0.props.target?.id == table(editor, "orders")?.id })
        expectEqual(pills(editor, on: billing).count, 1, "one pill, for orders")
        let key = try require(arrows(editor, on: billing).first { $0.props.end.binding?.shapeID == pill.id })
        expectEqual(key.props.end.binding?.part, column(editor, "orders", "id"), "the key keeps orders.id on its binding")
        expectEqual(key.props.start.binding?.part, column(editor, "payments", "order_id"))
        expectEqual(keys(editor), ["orders.customer_id -> customers.id", "payments.order_id -> orders.id", "refunds.payment_id -> payments.id"],
                    "every key as it was, read through the pill")
        expectEqual(arrows(editor, on: billing).count, 2, "payments' key went with it, and refunds' rode along")
        editor.undo()
        expectEqual(editor.file[billing], before[billing], "billing as it was")
        expectEqual(editor.file[.root], before[.root], "the root as it was")
    },
    test("a staying table's key reaches the moved one through a pill on its own board, the column kept: orders moved to billing") {
        let (editor, billing) = try shopEditor()
        let orders = try require(table(editor, "orders"))
        let owner = try require(billing.owner)
        expect(editor.slashCommands?.run("move-to", on: orders.id, with: SlashArguments([.shape(owner, label: "billing")])) ?? false)
        expectEqual(editor.file.board(containing: orders.id), billing)
        // orders' own key went with it, to a pill for customers on billing; payments' key stayed, to a pill for orders on the root.
        expectEqual(pills(editor, on: billing).compactMap(\.props.target?.id), [try require(table(editor, "customers")).id])
        expectEqual(pills(editor, on: .root).compactMap(\.props.target?.id), [orders.id])
        let staying = try require(arrows(editor, on: .root).first { $0.props.end.binding?.shapeID == pills(editor, on: .root).first?.id })
        expectEqual(staying.props.end.binding?.part, column(editor, "orders", "id"))
        expectEqual(keys(editor), ["orders.customer_id -> customers.id", "payments.order_id -> orders.id", "refunds.payment_id -> payments.id"])
    },
    test("canvas draw names a row on another board: drawn through a pill for its table, drawn again unchanged, and delete edge takes it") {
        let (editor, billing) = try shopEditor()
        expect(editor.showBoard(billing))
        func did(_ result: JSON) -> [String] { result["changes"]?.arrayValue?.compactMap { $0["did"]?.stringValue } ?? [] }
        let first = try drawnInProcess(#"edge "statements".customer_id -> "customers".id"#, on: editor)
        expect(did(first).contains("connected"), "\(did(first))")
        expectEqual(pills(editor, on: billing).count, 1)
        expect(keys(editor).contains("statements.customer_id -> customers.id"))
        let again = try drawnInProcess(#"edge "statements".customer_id -> "customers".id"#, on: editor)
        expectEqual(Set(did(again)), ["unchanged"])
        expectEqual(pills(editor, on: billing).count, 1, "nothing drawn twice")
        _ = try drawnInProcess(#"delete edge "statements".customer_id -> "customers".id"#, on: editor)
        expect(!keys(editor).contains("statements.customer_id -> customers.id"))
        expectEqual(arrows(editor, on: billing).count, 0)
    },
])

extension ShapeRecord<Reference> {
    /// Its frame as the editor has it laid out.
    @MainActor func frame(in editor: CanvasEditor) -> CGRect? { editor.frame(inFile: id) ?? props.frame }
}

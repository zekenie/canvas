import AppKit
import Boards
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
import Mentions
import Publishing
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


/// The shop on the root, billing's board with statements shown in a window with the engineering kit on: the canvas has the keyboard.
@MainActor private func billingWindow() throws -> (EmptyBoardWindow, BoardID) {
    let w = try EmptyBoardWindow()
    try w.turnKitOn()
    _ = try drawnInProcess(shop, on: w.editor)
    let billing = try require(w.editor.document.shapes.first { $0[TitleProperty.self] == "billing" })
    _ = try drawnInProcess(#"table "statements" in "billing" columns: "id uuid pk\ncustomer_id uuid\naccount_id uuid\nperiod daterange""#, on: w.editor)
    let board = BoardID(owner: billing.id)
    expect(w.editor.showBoard(board))
    w.editor.undoHistory.seal()
    w.window.makeFirstResponder(w.canvas)
    w.window.settle()
    return (w, board)
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
        // Where its line from customer_id is clean (connect 24): below statements, else level with the row beside it.
        try expectClean(arrow.id, from: statements.id, row: try require(column(editor, "statements", "customer_id")), in: editor, view: false, "⌘L's key")
        let frame = try require(pill.frame(in: editor))
        expect(!frame.intersects(statements.props.frame), "clear of the start")
        // A key's pill: level with its row, left of the table (T6 panel 3), so the crow's foot lies on a straight line.
        let keyRow = try require(editor.shapeContext.geometry(of: statements.id)?.parts.frame(try require(column(editor, "statements", "customer_id")))?.rect)
        expect(abs(frame.midY - keyRow.midY) < 1, "level with customer_id: \(frame) \(keyRow)")
        expect(frame.maxX <= statements.props.frame.minX, "left of statements: \(frame)")
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
    test("⌘L's picker from a row lists the columns of a table on another board, and a pick of one reaches it through the table's pill") {
        let (editor, billing) = try shopEditor()
        expect(editor.showBoard(billing))
        let statements = try require(table(editor, "statements")), customers = try require(table(editor, "customers"))
        let picker = try require(ConnectPicker(editor: editor, source: ConnectEnd(statements.id, part: column(editor, "statements", "customer_id"))))
        picker.setQuery("customers id")
        let row = try require(picker.list.rows.indices.first { picker.end(row: $0) == ConnectEnd(customers.id, part: column(editor, "customers", "id")) },
                              "customers.id is listed: \(picker.list.rows.compactMap(\.item).map(\.title))")
        let pick = try require(picker.pickEnd(row: row))
        expect(editor.connect(picker.sourceEnd, to: pick, fulfil: true) != nil)
        expectEqual(pills(editor, on: billing).count, 1)
        expect(keys(editor).contains("statements.customer_id -> customers.id"), "\(keys(editor))")
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
        let before = w.editor.file
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
        // The column and its pill arrive in one step: the pill is landed by the row as the step leaves it (connect 24).
        let key = try require(arrows(w.editor, on: board).first { $0.props.end.binding?.shapeID == pill.id })
        try expectClean(key.id, from: statements.id, row: try require(column(w.editor, "statements", "customer_id")), in: w.editor, lastRow: true, "a typed key")
        // Level with the row, left of statements, as T6 panel 3 draws it: never hooked straight down from the row's side (connect new-1).
        let typedRow = try require(w.editor.shapeContext.geometry(of: statements.id)?.parts.frame(try require(column(w.editor, "statements", "customer_id")))?.rect)
        let pillFrame = try require(pill.frame(in: w.editor))
        expect(abs(pillFrame.midY - typedRow.midY) < 1, "level with customer_id: \(pillFrame) \(typedRow)")
        expect(pillFrame.maxX <= typedRow.minX, "left of the row: \(pillFrame) \(typedRow)")
        w.editor.undo()
        expectEqual(pills(w.editor, on: board).count, 0, "one undo takes the column, its key and the pill")
        expect(!keys(w.editor).contains { $0.hasPrefix("statements.") })
        expectEqual(w.editor.file[board], before[board], "billing as it was: the table without the column, no pill, no arrow")
        expectEqual(w.editor.file[.root], before[.root], "the root as it was")
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
    test("a key moved onto a board with a pill for its table already there reuses it only where its line crosses no table; else a fresh pill, level with the row (connect new-1)") {
        let (editor, billing) = try shopEditor()
        _ = try drawnInProcess(#"table "invoices" below "payments" columns: "id uuid pk\ncustomer_id uuid\ntotal_cents int""#, on: editor)
        _ = try drawnInProcess(#"edge "invoices".customer_id -> "customers".id"#, on: editor)
        expect(editor.showBoard(billing))
        let statements = try require(table(editor, "statements")), customers = try require(table(editor, "customers"))
        editor.connect(ConnectEnd(statements.id, part: column(editor, "statements", "customer_id")),
                       to: ConnectEnd(customers.id, part: column(editor, "customers", "id")))
        expect(editor.showBoard(.root))
        let invoices = try require(table(editor, "invoices")), owner = try require(billing.owner)
        expect(editor.slashCommands?.run("move-to", on: invoices.id, with: SlashArguments([.shape(owner, label: "billing")])) ?? false)
        expectEqual(editor.file.board(containing: invoices.id), billing)
        expect(keys(editor).contains("invoices.customer_id -> customers.id"), "\(keys(editor))")
        expect(editor.showBoard(billing))
        // Every key through a pill on billing runs clean from its row: across no table.
        let tables = editor.document.shapes.filter { $0.kind == DatabaseTable.kind }
        for arrow in arrows(editor, on: billing) {
            guard let start = arrow.props.start.binding, let part = start.part, let end = arrow.props.end.binding,
                  let row = editor.shapeContext.geometry(of: start.shapeID)?.parts.frame(part)?.rect,
                  let pill = editor.shapeContext.geometry(of: end.shapeID)?.bounds else { continue }
            let surroundings = try require(Surroundings(on: billing, moving: pill.size, in: editor))
            expect(surroundings.joinsClean(row, of: start.shapeID, to: pill, standIn: end.shapeID),
                   "a key from \(editor.document[start.shapeID]?[TitleProperty.self] ?? "?") crosses a table: \(row) to \(pill), tables \(tables.compactMap(\.box))")
        }
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
    test("canvas draw: a columns: line's → to a table on another board draws the key through a pill for it, and a run again is unchanged") {
        let (editor, billing) = try shopEditor()
        func did(_ result: JSON) -> [String] { result["changes"]?.arrayValue?.compactMap { $0["did"]?.stringValue } ?? [] }
        let script = #"table "ledger" in "billing" columns: "id uuid pk\norder_id uuid → orders.id""#
        let first = try drawnInProcess(script, on: editor)
        expect(did(first).contains("connected"), "\(did(first))")
        expect(keys(editor).contains("ledger.order_id -> orders.id"), "\(keys(editor))")
        expectEqual(pills(editor, on: billing).compactMap(\.props.target?.id), [try require(table(editor, "orders")).id])
        let again = try drawnInProcess(script, on: editor)
        expectEqual(Set(did(again)), ["unchanged"])
        expectEqual(pills(editor, on: billing).count, 1, "nothing drawn twice")
    },

    test("canvas draw deleting a column from a board that isn't shown, with a key through a pill on the board shown: the run commits, the column goes, the key is left bound as it was") {
        let (editor, billing) = try shopEditor()
        expect(editor.showBoard(billing))
        let statements = try require(table(editor, "statements")), customers = try require(table(editor, "customers"))
        editor.connect(ConnectEnd(statements.id, part: column(editor, "statements", "customer_id")),
                       to: ConnectEnd(customers.id, part: column(editor, "customers", "id")))
        editor.undoHistory.seal()
        let key = try require(arrows(editor, on: billing).first)
        let result = try drawnInProcess(#"delete "customers".id"#, on: editor)
        expect(column(editor, "customers", "id") == nil, "the column went: \(result)")
        expectEqual(arrows(editor, on: billing).map(\.id), [key.id], "billing is shown, so its key is not for the run to write")
        expectEqual(arrows(editor, on: billing).first?.props.end.binding, key.props.end.binding, "bound as it was")
        expect(!keys(editor).contains { $0.hasPrefix("orders.customer_id") }, "the root's own key went with the column")
    },
    test("canvas draw's report says the keys a row delete took on another board, through a pill, with the names of their ends") {
        let (editor, billing) = try shopEditor()
        let statements = try require(table(editor, "statements")), customers = try require(table(editor, "customers"))
        expect(editor.showBoard(billing))
        editor.connect(ConnectEnd(statements.id, part: column(editor, "statements", "customer_id")),
                       to: ConnectEnd(customers.id, part: column(editor, "customers", "id")))
        expect(editor.showBoard(.root))
        let result = try drawnInProcess(#"delete "customers".id"#, on: editor)
        let rows = result["changes"]?.arrayValue ?? []
        let arrowsGone = rows.filter { $0["did"]?.stringValue == "deleted" && $0["kind"]?.stringValue == Arrow.kind.rawValue }
        expectEqual(arrowsGone.count, 2, "orders' key and billing's: \(rows)")
        expect(arrowsGone.contains { $0["from"]?.stringValue == "statements" && $0["to"]?.stringValue == "customers" }, "\(arrowsGone)")
    },
    test("two keys to one table of another board, written in one step (Paste Columns), reuse one pill; keys to two tables put two pills down that don't overlap; one undo") {
        let (w, board) = try billingWindow()
        defer { w.board.close() }
        let editor = w.editor, before = editor.file
        try w.edit("statements", row: "period")
        w.line?.paste(text: "a_id uuid → customers.id\nb_id uuid → customers.id")
        expectEqual(undoTitle(w.window), "Undo Paste Columns")
        expectEqual(pills(editor, on: board).count, 1, "one pill for customers, reused by the second key")
        expect(keys(editor).contains("statements.a_id -> customers.id") && keys(editor).contains("statements.b_id -> customers.id"), "\(keys(editor))")
        editor.undo()
        expectEqual(editor.file[board], before[board], "billing as it was")
        expectEqual(editor.file[.root], before[.root])
        try w.edit("statements", row: "period")
        w.line?.paste(text: "x_id uuid → customers.id\ny_id uuid → orders.id")
        let landed = pills(editor, on: board)
        expectEqual(landed.count, 2, "a pill for each table")
        expectEqual(Set(landed.compactMap(\.props.target?.id)), [try require(table(editor, "customers")).id, try require(table(editor, "orders")).id])
        expect(!landed[0].props.frame.intersects(landed[1].props.frame), "side by side, not stacked: \(landed.map(\.props.frame))")
        expect(keys(editor).contains("statements.x_id -> customers.id") && keys(editor).contains("statements.y_id -> orders.id"))
        editor.undo()
        expectEqual(editor.file[board], before[board], "one undo takes both pills and both keys")
    },
    test("a typed → to a private table of another board stays plain words: the row commits with no key and no pill, nothing shakes and nothing is made public") {
        let (w, board) = try billingWindow()
        defer { w.board.close() }
        let editor = w.editor, walk = w.walk()
        let customers = try require(table(editor, "customers"))
        editor.transact(on: .root, "Make Private") { $0.update(customers.id) { $0[PrivateProperty.self] = true } }
        editor.undoHistory.seal()
        try w.edit("statements", row: "period")
        walk.press(.return)
        w.type("customer_ref uuid -> customers.id", with: walk)
        walk.press(.return)
        let columns = try require(table(editor, "statements")).props.columns
        expect(columns.contains { $0.name == "customer_ref" }, "the column is written: \(columns.map(\.name))")
        expectEqual(columns.first { $0.name == "customer_ref" }?.unread, "→ customers.id", "the words stay, plain")
        expectEqual(pills(editor, on: board).count, 0)
        expect(!keys(editor).contains { $0.hasPrefix("statements.") })
        expectEqual(editor.shape(inFile: customers.id)?[PrivateProperty.self], true, "typing makes nothing public")
        expectEqual(undoTitle(w.window), "Undo Add Column")
        walk.press(.escape)
    },
    test("of two tables called alike on other boards, a typed → reaches the one a pill can stand for, whichever the file lists first") {
        for privateOnRoot in [true, false] {
            let (w, board) = try billingWindow()
            defer { w.board.close() }
            let editor = w.editor, walk = w.walk()
            expect(editor.showBoard(.root))
            _ = try drawnInProcess(#"subboard "archive" below "billing""#, on: editor)
            let archive = BoardID(owner: try require(editor.document.shapes.first { $0[TitleProperty.self] == "archive" }).id)
            var twin = ShapeRecord(DatabaseTable(frame: CGRect(x: 100, y: 100, width: 260, height: 80),
                                                 columns: [Column(name: "id", type: TypeRef("uuid"), primaryKey: true)]))
            twin[TitleProperty.self] = "customers"
            editor.transact(on: archive, "Add Table") { $0.insert(twin) }
            expect(editor.showBoard(board))
            w.window.makeFirstResponder(w.canvas)
            w.window.settle()
            let archived = try require(editor.shape(inFile: twin.id))
            let root = try require(editor.contents(of: .root).shapes.first { $0[TitleProperty.self] == "customers" })
            let hidden = privateOnRoot ? root.id : archived.id, reachable = privateOnRoot ? archived.id : root.id
            let home = try require(editor.file.board(containing: hidden))
            editor.transact(on: home, "Make Private") { $0.update(hidden) { $0[PrivateProperty.self] = true } }
            try w.edit("statements", row: "period")
            walk.press(.return)
            w.type("customer_ref uuid -> customers.id", with: walk)
            walk.press(.return)
            expectEqual(pills(editor, on: board).compactMap(\.props.target?.id), [reachable], "a pill for the public one (the private one on the root: \(privateOnRoot))")
            walk.press(.escape)
        }
    },
    test("the far table gone, the key into its pill stays when its column is edited: the line never showed it, so renaming the column writes nothing to it") {
        let (w, board) = try billingWindow()
        defer { w.board.close() }
        let editor = w.editor, walk = w.walk()
        let statements = try require(table(editor, "statements")), customers = try require(table(editor, "customers"))
        editor.connect(ConnectEnd(statements.id, part: column(editor, "statements", "customer_id")),
                       to: ConnectEnd(customers.id, part: column(editor, "customers", "id")))
        let key = try require(arrows(editor, on: board).first).id
        editor.transact(on: .root, "Delete Table") { $0.delete([customers.id]) }
        editor.undoHistory.seal()
        expectEqual(arrows(editor, on: board).map(\.id), [key], "the key is bound to the pill, which stays")
        try w.edit("statements", row: "customer_id")
        expectEqual(w.line?.string, "customer_id uuid", "no table to say")
        w.retype("cust_id uuid", with: walk)
        walk.press(.down)
        expectEqual(undoTitle(w.window), "Undo Rename Column")
        expectEqual(arrows(editor, on: board).map(\.id), [key], "the arrow into the dashed pill is still there")
        walk.press(.escape)
        editor.undo()
        editor.undo()
        expect(table(editor, "customers") != nil, "the table back")
        expect(keys(editor).contains("statements.customer_id -> customers.id"), "and the key reads through the pill again: \(keys(editor))")
    },
    test("reopening the row of a key through a pill prints → customers.id; the key reads many to one at the pill, VoiceOver says the far column; leaving it as it is keeps the arrow") {
        let (w, board) = try billingWindow()
        defer { w.board.close() }
        let editor = w.editor, walk = w.walk()
        let statements = try require(table(editor, "statements")), customers = try require(table(editor, "customers"))
        let id = column(editor, "customers", "id")
        let made = editor.connect(ConnectEnd(statements.id, part: column(editor, "statements", "customer_id")), to: ConnectEnd(customers.id, part: id))
        let arrow = try require(made)
        let bound = arrows(editor, on: board).first?.props.end.binding
        let said = editor.accessibleDescription(of: try require(editor.document[arrow])).label
        expect(said.contains("id in customers"), "the far end is the column, not the pill: \(said)")
        expect(said.contains("many to one"), "the kit's marks at the pill, from the column: \(said)")
        editor.undoHistory.seal()
        try w.edit("statements", row: "customer_id")
        expectEqual(w.line?.string, "customer_id uuid → customers.id", "the key printed from the far column, through the pill")
        w.retype("customer_id uuid -> customers.id", with: walk)
        walk.press(.down)
        expectEqual(arrows(editor, on: board).map(\.id), [arrow], "as it was: the same arrow")
        expectEqual(arrows(editor, on: board).first?.props.end.binding, bound)
        expectEqual(pills(editor, on: board).count, 1)
        expectEqual(undoTitle(w.window), "Undo Connect", "no step for a line left as it was")
        walk.press(.escape)
    },
    test("a key through a pill re-aimed to a column of its own table keeps the arrow (the stale pill stays); undone, it is bound through the pill again") {
        let (w, board) = try billingWindow()
        defer { w.board.close() }
        let editor = w.editor, walk = w.walk()
        let statements = try require(table(editor, "statements")), customers = try require(table(editor, "customers"))
        let arrow = try require(editor.connect(ConnectEnd(statements.id, part: column(editor, "statements", "customer_id")),
                                               to: ConnectEnd(customers.id, part: column(editor, "customers", "id"))))
        editor.undoHistory.seal()
        let before = editor.file
        try w.edit("statements", row: "customer_id")
        w.retype("customer_id uuid -> statements.account_id", with: walk)
        walk.press(.down)
        expectEqual(undoTitle(w.window), "Undo Change Key")
        let moved = try require(arrows(editor, on: board).first)
        expectEqual(moved.id, arrow, "re-aimed: the same arrow")
        expectEqual(moved.props.end.binding?.shapeID, statements.id)
        expectEqual(moved.props.end.binding?.part, column(editor, "statements", "account_id"))
        expectEqual(pills(editor, on: board).count, 1, "the pill it left stays")
        expect(keys(editor).contains("statements.customer_id -> statements.account_id"), "\(keys(editor))")
        walk.press(.escape)
        editor.undo()
        expectEqual(editor.file[board], before[board], "back, through the pill")
    },
    test("a key to a column of its own table re-aimed to another board's: a pill put down in the same step, the arrow kept; one undo takes both") {
        let (w, board) = try billingWindow()
        defer { w.board.close() }
        let editor = w.editor, walk = w.walk()
        try w.edit("statements", row: "customer_id")
        w.retype("customer_id uuid -> statements.account_id", with: walk)
        walk.press(.down)
        let arrow = try require(arrows(editor, on: board).first).id
        walk.press(.escape)
        editor.undoHistory.seal()
        let before = editor.file
        try w.edit("statements", row: "customer_id")
        w.retype("customer_id uuid -> customers.id", with: walk)
        walk.press(.down)
        expectEqual(undoTitle(w.window), "Undo Change Key")
        expectEqual(arrows(editor, on: board).map(\.id), [arrow], "the same arrow")
        expectEqual(pills(editor, on: board).count, 1, "its pill in the same step")
        expect(keys(editor).contains("statements.customer_id -> customers.id"))
        walk.press(.escape)
        editor.undo()
        expectEqual(editor.file[board], before[board], "one undo takes the pill and puts the local key back")
    },
    test("a key to one far table re-aimed to another: the arrow kept, a pill for the new table, the old pill left; one undo") {
        let (w, board) = try billingWindow()
        defer { w.board.close() }
        let editor = w.editor, walk = w.walk()
        let statements = try require(table(editor, "statements")), customers = try require(table(editor, "customers"))
        let arrow = try require(editor.connect(ConnectEnd(statements.id, part: column(editor, "statements", "customer_id")),
                                               to: ConnectEnd(customers.id, part: column(editor, "customers", "id"))))
        editor.undoHistory.seal()
        let before = editor.file
        try w.edit("statements", row: "customer_id")
        w.retype("customer_id uuid -> orders.id", with: walk)
        walk.press(.down)
        expectEqual(arrows(editor, on: board).map(\.id), [arrow])
        expectEqual(Set(pills(editor, on: board).compactMap(\.props.target?.id)), [customers.id, try require(table(editor, "orders")).id], "the old pill stays")
        expect(keys(editor).contains("statements.customer_id -> orders.id") && !keys(editor).contains("statements.customer_id -> customers.id"), "\(keys(editor))")
        walk.press(.escape)
        editor.undo()
        expectEqual(editor.file[board], before[board])
    },
    test("after →, the caret list offers the key columns of tables on other boards a pill can reach, naming the board of each, and never a private table's") {
        let (w, board) = try billingWindow()
        defer { w.board.close() }
        let editor = w.editor, walk = w.walk()
        expect(editor.showBoard(.root))
        _ = try drawnInProcess(#"table "vault" right of "refunds" columns: "id uuid pk""#, on: editor)
        let vault = try require(table(editor, "vault"))
        editor.transact("Make Private") { $0.update(vault.id) { $0[PrivateProperty.self] = true } }
        expect(editor.showBoard(board))
        w.window.makeFirstResponder(w.canvas)
        w.window.settle()
        try w.edit("statements", row: "period")
        walk.press(.return)
        w.type("ref uuid -> ", with: walk)
        let offers = try require(w.line).listedOffers
        expect(offers.contains("customers.id") && offers.contains("orders.id"), "\(offers)")
        expect(!offers.contains("vault.id"), "a private table is not offered: \(offers)")
        let details = try require(w.line).listedDetails, rootName = editor.name(of: .root)
        let at = try require(offers.firstIndex(of: "customers.id"))
        expectEqual(details[at], "uuid · \(rootName)", "which board it is on")
        walk.press(.escape)
        walk.press(.escape)
    },
    test("⌘L in a row, by the keys alone: customers.em picks a column on another board; Return draws the key through a pill, the line printed again with it") {
        let (w, board) = try billingWindow()
        defer { w.board.close() }
        let editor = w.editor, walk = w.walk()
        try w.edit("statements", row: "customer_id")
        walk.press(Chord("l", .command))
        let picker = try require(editor.connectPicker)
        expect(picker.isOpen)
        w.type("customers.em", with: walk)
        let rows = (picker.picker?.list.rows ?? []).compactMap(\.item)
        expectEqual(rows.first?.title, "email", "\(rows.map(\.title))")
        walk.press(.return)
        expect(!picker.isOpen)
        expect(keys(editor).contains("statements.customer_id -> customers.email"), "\(keys(editor))")
        expectEqual(pills(editor, on: board).count, 1)
        expectEqual(undoTitle(w.window), "Undo Connect")
        expectEqual(w.line?.string, "customer_id uuid → customers.email", "printed again with its key")
        walk.press(.escape)
    },
    test("⌘L's picker lists the columns of a table of another board with no primary key, as it does on the board shown; and a row of a private one says it will be made public") {
        let (editor, billing) = try shopEditor()
        _ = try drawnInProcess(#"table "tags" right of "refunds" columns: "slug text unique\nlabel text""#, on: editor)
        _ = try drawnInProcess(#"table "vault" below "tags" columns: "slug text unique\nnote text""#, on: editor)
        let vault = try require(table(editor, "vault"))
        editor.transact(on: .root, "Make Private") { $0.update(vault.id) { $0[PrivateProperty.self] = true } }
        expect(editor.showBoard(billing))
        let statements = try require(table(editor, "statements")), tags = try require(table(editor, "tags"))
        let picker = try require(ConnectPicker(editor: editor, source: ConnectEnd(statements.id, part: column(editor, "statements", "customer_id"))))
        picker.setQuery("tags slug")
        expect(picker.rows.indices.contains { picker.end(row: $0) == ConnectEnd(tags.id, part: column(editor, "tags", "slug")) },
               "tags.slug is listed: \(picker.list.rows.compactMap(\.item).map(\.title))")
        picker.setQuery("vault slug")
        let row = try require(picker.rows.indices.first { picker.end(row: $0) == ConnectEnd(vault.id, part: column(editor, "vault", "slug")) }, "vault.slug is listed")
        guard case .shape(_, let needs) = picker.rows[row] else { return expect(false) }
        expectEqual(needs, "public", "the row says its table will be made public")
        expect(picker.list.rows[row].item?.detail?.contains("will be made public") == true, "\(String(describing: picker.list.rows[row].item?.detail))")
    },
])

extension ShapeRecord<Reference> {
    /// Its frame as the editor has it laid out.
    @MainActor func frame(in editor: CanvasEditor) -> CGRect? { editor.frame(inFile: id) ?? props.frame }
}

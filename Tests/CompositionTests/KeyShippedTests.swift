import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CanvasUI
import Clipboard
import Connections
import Engineering
import Geometry
import LanguageModels
import LineRows
import References
import Selection
import StickyNotes
import Subboards
import TableOfContents
import ShippedTesting
import TestKit
import Titles
import Topology

// Keys as shipped (K3): `canvas draw`'s rows by name (`"orders".customer_id`), an unknown row refused with the names it's
// like, `delete "orders".x` taking the row and its key; T5 panels 1 and 2 by the keys with their Undo titles; tables copied
// with the key between them; and T3 panel 2 by the pointer through the app's canvas view: a drag from payment_id's dot onto
// payments.id, the tables outlined and not the enum, the row lit, and the key drawn row to row.

@MainActor private func arrows(_ editor: CanvasEditor) -> [ShapeRecord<Arrow>] {
    editor.document.shapes.compactMap { $0.typed(as: Arrow.self) }
}

@MainActor private func table(_ editor: CanvasEditor, _ title: String) -> ShapeRecord<DatabaseTable>? {
    editor.document.shapes.first { $0[TitleProperty.self] == title }?.typed(as: DatabaseTable.self)
}

@MainActor private func column(_ editor: CanvasEditor, _ title: String, _ name: String) -> PartID? {
    table(editor, title)?.props.columns.first { $0.name == name }?.id
}

/// Each key on the board as `from.column -> to.column`, by the tables' titles and the columns' names now.
@MainActor private func keys(_ editor: CanvasEditor) -> [String] {
    arrows(editor).compactMap { arrow -> String? in
        guard let start = arrow.props.start.binding, let end = arrow.props.end.binding else { return nil }
        @MainActor func said(_ binding: ArrowBinding) -> String {
            let record = editor.document[binding.shapeID]
            let name = record.flatMap { editor.registry.parts(of: $0)?.first { $0.id == binding.part }?.name } ?? "?"
            return "\(record?[TitleProperty.self] ?? "?").\(name)"
        }
        return "\(said(start)) -> \(said(end))"
    }.sorted()
}

private let shop = #"""
    table "customers" columns: "id uuid pk\nemail text unique\nname text"
    table "orders" right of "customers" columns: "id uuid pk\ncustomer_id uuid\ntotal_cents int"
    table "order_items" right of "orders" columns: "id uuid pk\norder_id uuid\nqty int"
    table "payments" below "orders" columns: "id uuid pk\norder_id uuid\namount_cents int"
    edge "orders".customer_id -> "customers".id
    edge "order_items".order_id -> "orders".id
    edge "payments".order_id -> "orders".id
    """#

@MainActor private func shopEditor() throws -> CanvasEditor {
    let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
    editor.viewportDidResize(to: CGSize(width: 1440, height: 900))
    _ = try drawnInProcess(shop, on: editor)
    return editor
}

@MainActor let keyShippedTests = Suite("Keys, shipped", [
    test("draw names a row with a dot outside the quotes: an edge between rows is a key on foreign-key, bound to both rows; a run again is unchanged") {
        let editor = try shopEditor()
        expectEqual(keys(editor), ["order_items.order_id -> orders.id", "orders.customer_id -> customers.id", "payments.order_id -> orders.id"])
        expect(arrows(editor).allSatisfy { $0[ChannelProperty.self] == ForeignKey.id }, "each on the kit's channel, picked as a drag picks it")
        let again = try drawnInProcess(#"edge "orders".customer_id -> "customers".id"#, on: editor)
        expectEqual(again["changes"]?.arrayValue?.compactMap { $0["did"]?.stringValue }, ["unchanged"])
        _ = try drawnInProcess(#"edge "orders".total_cents -> "customers".id"#, on: editor)
        expectEqual(arrows(editor).count, 4, "another pair of rows of the same tables is another key")
        let orders = try require(table(editor, "orders"))
        expectEqual(editor.topology?.edges(of: orders.id, part: column(editor, "orders", "customer_id"), .outgoing).count, 1)
    },
    test("a row no shape has is unknown_row, with the rows it's like; a shape with no rows says so") {
        let editor = try shopEditor()
        let error = try drawnError(#"edge "orders".custmer_id -> "customers".id"#, on: editor)
        expectEqual(error?["reason"]?.stringValue, "unknown_row")
        expect(error?["hint"]?.stringValue?.contains(#""orders".customer_id"#) == true, "\(String(describing: error?["hint"]))")
        _ = try drawnInProcess(#"sticky-note "Plan" below "payments""#, on: editor)
        let none = try drawnError(#"delete "Plan".x"#, on: editor)
        expectEqual(none?["reason"]?.stringValue, "unknown_row")
        // Deletes are read before edges: an edge to a row a later line deletes names that line.
        let later = try refusedInProcess("edge \"orders\".total_cents -> \"customers\".email\ndelete \"customers\".email", on: editor)
        expectEqual(later.reason, "unknown_row")
        expect(later.message.contains("is deleted on line 2"), later.message)
    },
    test("delete \"orders\".customer_id takes the row and, by the cascade, its key, said as the table updated and the arrow deleted") {
        let editor = try shopEditor()
        let result = try drawnInProcess(#"delete "orders".customer_id"#, on: editor)
        expectEqual(table(editor, "orders")?.props.columns.map(\.name), ["id", "total_cents"])
        expectEqual(keys(editor), ["order_items.order_id -> orders.id", "payments.order_id -> orders.id"])
        let changes = result["changes"]?.arrayValue ?? []
        expectEqual(changes.compactMap { $0["did"]?.stringValue }, ["updated", "deleted"])
        expectEqual(changes.last?["kind"]?.stringValue, "arrow")
        expectEqual(editor.undoHistory.undoName != nil, true)
    },
    test("a row two columns share is refused as ambiguous, naming where they are, never taken as the first") {
        let editor = try shopEditor()
        let orders = try require(table(editor, "orders"))
        editor.transact("Rename") { $0.update(orders.id, as: DatabaseTable.self) { $0.props.columns[2].name = "customer_id" } }
        let edge = try refusedInProcess(#"edge "orders".customer_id -> "customers".email"#, on: editor)
        expectEqual(edge.reason, "ambiguous_title")
        expect(edge.message.contains("2 rows called") && edge.message.contains("2 and 3"), edge.message)
        let delete = try refusedInProcess(#"delete "orders".customer_id"#, on: editor)
        expectEqual(delete.reason, "ambiguous_title")
        expectEqual(table(editor, "orders")?.props.columns.count, 3, "nothing was taken")
        expectEqual(keys(editor).count, 3)
    },
    test("a row delete and a delete of its table in one script is refused on the later line, either order, not as an internal error") {
        let editor = try shopEditor()
        let rowFirst = try refusedInProcess("delete \"orders\".total_cents\ndelete \"orders\"", on: editor)
        expectEqual(rowFirst.reason, "duplicate")
        expect(rowFirst.message.contains("line 1"), rowFirst.message)
        let tableFirst = try refusedInProcess("delete \"orders\"\ndelete \"orders\".total_cents", on: editor)
        expectEqual(tableFirst.reason, "duplicate")
        expect(tableFirst.message.contains("is deleted, and so its rows are"), tableFirst.message)
        let twice = try refusedInProcess("delete \"orders\".total_cents\ndelete \"orders\".total_cents", on: editor)
        expectEqual(twice.reason, "duplicate")
        expectEqual(table(editor, "orders")?.props.columns.count, 3, "nothing was taken")
    },
    test("two row deletes of one table are said on their own lines, each key on the line of the row it went with") {
        let editor = try shopEditor()
        _ = try drawnInProcess(#"edge "orders".total_cents -> "customers".email"#, on: editor)
        let result = try drawnInProcess("delete \"orders\".customer_id\ndelete \"orders\".total_cents", on: editor)
        expectEqual(table(editor, "orders")?.props.columns.map(\.name), ["id"])
        let changes = result["changes"]?.arrayValue ?? []
        expectEqual(changes.compactMap { $0["did"]?.stringValue }, ["updated", "deleted", "updated", "deleted"])
        expectEqual(changes.compactMap { $0["line"]?.intValue }, [1, 1, 2, 2])
    },
    test("a table moved to another board keeps the keys that cross through a pill for the table that stays, the column on the binding") {
        let editor = try shopEditor()
        _ = try drawnInProcess(#"subboard "Far" below "customers""#, on: editor)
        editor.viewportDidResize(to: CGSize(width: 1440, height: 900))
        let customers = try require(table(editor, "customers")), far = try require(editor.document.shapes.first { $0[TitleProperty.self] == "Far" })
        let id = try require(column(editor, "customers", "id"))
        let contents = try require(editor.tableOfContents)
        expect(contents.beginDrag(from: customers.id) && contents.drop(on: ContentsDropTarget(row: far.id, zone: .on)))
        expectEqual(editor.file.board(containing: customers.id), BoardID(owner: far.id))
        let root = editor.contents(of: .root)
        let loose = root.shapes.compactMap { $0.typed(as: Arrow.self) }
        expectEqual(loose.count, 3, "no arrow was lost, and none rode along")
        let pill = try require(root.shapes.first { $0.kind == Reference.kind }?.typed(as: Reference.self))
        expectEqual(pill.props.target?.id, customers.id, "a pill for customers where orders' key stays")
        let key = try require(loose.first { $0.props.end.binding?.shapeID == pill.id })
        expectEqual(key.props.end.binding?.part, id, "the key keeps customers.id on its binding")
        expectEqual(loose.filter { $0.props.end.binding != nil }.count, 3, "every key still bound at both ends")
        editor.undo()
        expectEqual(editor.file.board(containing: customers.id), .root)
        expectEqual(keys(editor).count, 3)
        expect(editor.document.shapes.allSatisfy { $0.kind != Reference.kind }, "and no pill")
    },
    test("⌘L's picker opens on a table, as it did before its rows had ports: the other tables, enums and databases, and a pick draws a plain arrow") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        try w.turnKitOn()
        _ = try drawnInProcess(shop, on: w.editor)
        let orders = try require(table(w.editor, "orders"))
        expect(w.editor.connectPicker?.canOpen(on: orders.id) == true, "a table with ports only on its rows can still be picked from")
        let picker = try require(ConnectPicker(editor: w.editor, source: orders.id))
        expect(picker.kinds.contains(DatabaseTable.kind) && picker.kinds.contains(DatabaseEnum.kind), "\(picker.kinds)")
        expect(!picker.kinds.contains(StickyNote.kind), "a note has side ports, a table none")
        let target = try require(table(w.editor, "customers"))
        let before = arrows(w.editor).count
        w.editor.connect(ConnectEnd(orders.id), to: ConnectEnd(target.id))
        expectEqual(arrows(w.editor).count, before + 1)
    },
    test("T5, panel 1: in customers, ⌘⌫ then ⌫ on id: the column and its key go in one step, Undo Delete Column and 1 Arrow; orders.customer_id is plain") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        try w.turnKitOn()
        _ = try drawnInProcess(shop, on: w.editor)
        w.editor.undoHistory.seal()
        let customers = try require(table(w.editor, "customers"))
        let walk = w.walk()
        w.editor.selectedShapeIDs = [customers.id]
        w.editor.beginEditing(customers.id)
        w.window.settle()
        let view = try require(w.lineRows)
        let id = try require(customers.props.columns.first?.id)
        // From where editing starts, up to the title and down one: the first row, id.
        for _ in 0..<5 where view.focus != .title { walk.press(.up) }
        if view.focus == .title { walk.press(.down) }
        expectEqual(view.focus, .row(id), "the caret on id")
        walk.press(Chord(Key.delete, .command))
        walk.press(.delete)
        expectEqual(table(w.editor, "customers")?.props.columns.map(\.name), ["email", "name"])
        expectEqual(keys(w.editor), ["order_items.order_id -> orders.id", "payments.order_id -> orders.id"], "its key went with it")
        expectEqual(undoTitle(w.window), "Undo Delete Column and 1 Arrow")
    },
    test("T5, panel 2: ⌫ with orders selected takes its three keys, Undo Delete Table and 3 Arrows; one Undo brings them back") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        try w.turnKitOn()
        _ = try drawnInProcess(shop, on: w.editor)
        w.editor.undoHistory.seal()
        let orders = try require(table(w.editor, "orders"))
        let walk = w.walk()
        w.editor.selectedShapeIDs = [orders.id]
        walk.press(.delete)
        expectEqual(table(w.editor, "orders"), nil)
        expectEqual(arrows(w.editor).count, 0, "every key at orders went, either way")
        expectEqual(undoTitle(w.window), "Undo Delete Table and 3 Arrows")
        w.editor.undo()
        expectEqual(keys(w.editor).count, 3)
    },
    test("tables copied with the key between them keep it, bound to the copies' rows; a key to a table not copied stays behind") {
        let editor = try shopEditor()
        let orders = try require(table(editor, "orders")), items = try require(table(editor, "order_items"))
        editor.selectedShapeIDs = [orders.id, items.id]
        editor.perform(.copy)
        editor.perform(.paste)
        let pasted = editor.selectedShapeIDs.compactMap { editor.document[$0] }.filter { $0.kind == DatabaseTable.kind }
        expectEqual(pasted.count, 2)
        let copies = Set(pasted.map(\.id))
        let copied = arrows(editor).filter { arrow in [arrow.props.start, arrow.props.end].allSatisfy { $0.binding.map { copies.contains($0.shapeID) } ?? false } }
        expectEqual(copied.count, 1, "the key between the two copied tables came along")
        expectEqual(copied.first?.props.start.binding?.part, column(editor, "order_items", "order_id"), "a copy keeps its rows' ids")
        expectEqual(arrows(editor).count, 4, "orders' key to customers stayed behind")
    },
    test("⌥Tab from a table lists its keys by the row at the far end; VoiceOver says an arrow's rows") {
        let editor = try shopEditor()
        let orders = try require(table(editor, "orders"))
        editor.selection = orders.id
        let titles = editor.shapeParts(of: orders.id).map(\.title)
        expect(titles.contains("Arrow to id in customers"), "\(titles)")
        expect(titles.contains("Arrow from order_id in order_items"), "\(titles)")
        let key = try require(arrows(editor).first { $0.props.start.binding?.shapeID == orders.id })
        expect(editor.accessibleDescription(of: key.id)?.label.contains("from customer_id in orders to id in customers") == true)
    },
])

/// What `canvas draw` refused, as JSON: its reason and hint.
@MainActor private func drawnError(_ script: String, on editor: CanvasEditor) throws -> JSON? {
    let error = try refusedInProcess(script, on: editor)
    return JSON.object(["reason": .string(error.reason ?? ""), "hint": .string(error.hint ?? "")])
}

/// The app's canvas view over the shipped kit, driven by the mouse (as `LoopWindowTests` drives a note's): one clock for the
/// events' times and the editor's timers.
@MainActor final class KeyDragWindow {
    let editor: CanvasEditor
    let window: NSWindow
    let canvas: CanvasView
    private let scheduler: ManualScheduler
    private var time: TimeInterval = 1
    private var location = CGPoint.zero

    init(_ script: String) throws {
        let scheduler = ManualScheduler()
        self.scheduler = scheduler
        editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: scheduler, model: ScriptedLanguageModel())
        (window, canvas) = windowed(editor)
        editor.turn(EngineeringKit.self, on: true)
        editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        _ = try drawnInProcess(script, on: editor)
        editor.selectedShapeIDs = []
        editor.undoHistory.seal()
    }

    func wait(_ ms: Int) {
        time += Double(ms) / 1000
        scheduler.advance(by: .milliseconds(ms))
    }

    func move(to point: CGPoint) {
        wait(16)
        location = point
        canvas.mouseMoved(with: window.mouse(.mouseMoved, at: point, clicks: 0, time: time))
    }

    func press() {
        wait(16)
        canvas.mouseDown(with: window.mouse(.leftMouseDown, at: location, clicks: 1, time: time))
    }

    func drag(to point: CGPoint, speed: CGFloat = 3) {
        let start = location
        let steps = max(1, Int((hypot(point.x - start.x, point.y - start.y) / (speed * 16)).rounded(.up)))
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            wait(16)
            location = CGPoint(x: start.x + (point.x - start.x) * t, y: start.y + (point.y - start.y) * t)
            canvas.mouseDragged(with: window.mouse(.leftMouseDragged, at: location, time: time))
        }
    }

    func release() {
        wait(16)
        canvas.mouseUp(with: window.mouse(.leftMouseUp, at: location, clicks: 1, time: time))
    }

    /// Where row `index` of the table titled `title` is on screen (view points: the camera is at the origin, at 100%).
    func row(_ title: String, _ index: Int) throws -> CGRect {
        let id = try require(editor.document.shapes.first { $0[TitleProperty.self] == title }?.id)
        let rect = try require(editor.shapeContext.geometry(of: id)?.parts[index].rect)
        return editor.camera.toView(rect)
    }
}

/// T3, panel 2: refunds and payments side by side, orders below payments, the order_status enum below refunds.
let t3Panel2 = #"""
    table "refunds" columns: "id uuid pk\npayment_id uuid\namount_cents int\nreason text?\ncreated_at timestamptz"
    table "payments" right of "refunds" (gap: 140) columns: "id uuid pk\norder_id uuid\nstripe_charge_id text unique\namount_cents int"
    table "orders" below "payments" columns: "id uuid pk\ncustomer_id uuid"
    enum-type "order_status" below "refunds" values: "pending\npaid"
    edge "payments".order_id -> "orders".id
    """#

@MainActor let keyPointerTests = Suite("A key drawn by the pointer (T3, panel 2)", [
    test("a drag from payment_id's dot onto payments.id: dots on the hovered row only, the tables outlined and not the enum, the row lit, the key drawn row to row in one step") {
        let w = try KeyDragWindow(t3Panel2)
        let paymentID = try w.row("refunds", 1), target = try w.row("payments", 0)
        w.move(to: CGPoint(x: paymentID.midX, y: paymentID.midY))
        w.move(to: CGPoint(x: paymentID.maxX + 12, y: paymentID.midY))
        w.press()
        w.drag(to: CGPoint(x: target.midX + 40, y: target.midY))
        let refunds = try require(table(w.editor, "refunds")), payments = try require(table(w.editor, "payments"))
        expectEqual(w.editor.hintedShapeID, payments.id)
        expectEqual(w.editor.hintedPart, payments.props.columns[0].id, "payments.id lit")
        // The key is drawn with the marks it will have, though it has no channel until the release.
        let drawing = try require(arrows(w.editor).first { $0.props.start.binding?.shapeID == refunds.id })
        expectEqual(drawing[ChannelProperty.self], nil, "no channel yet")
        expectEqual(w.editor.arrowLook(of: drawing.id), ConnectionLook(start: .many, end: .one, lineWidth: 2.5), "its marks as it is drawn")
        w.release()
        let key = try require(arrows(w.editor).first { $0.props.start.binding?.shapeID == refunds.id })
        expectEqual(key.props.start.binding?.part, refunds.props.columns[1].id)
        expectEqual(key.props.end.binding?.part, payments.props.columns[0].id)
        expectEqual(key[ChannelProperty.self], ForeignKey.id)
        expectEqual(w.editor.undoHistory.undoName, "Add Arrow")
        let geometry = try require(w.editor.arrowGeometry(of: key.id))
        expectEqual(geometry.startHandle.x, w.editor.camera.toWorld(CGPoint(x: paymentID.maxX, y: 0)).x, "leaving payment_id's right side")
        expectEqual(geometry.endHandle.x, w.editor.camera.toWorld(CGPoint(x: target.minX, y: 0)).x, "into payments.id's left side")
        expectEqual(w.editor.hintedPart, nil)
    },
    test("a drag from payment_id's dot back over payment_id lights nothing and makes nothing; over another row of its table, that row is lit") {
        let w = try KeyDragWindow(t3Panel2)
        let paymentID = try w.row("refunds", 1), reason = try w.row("refunds", 3)
        w.move(to: CGPoint(x: paymentID.midX, y: paymentID.midY))
        w.move(to: CGPoint(x: paymentID.maxX + 12, y: paymentID.midY))
        w.press()
        w.drag(to: CGPoint(x: paymentID.midX, y: paymentID.midY))
        expectEqual(w.editor.hintedPart, nil, "the row it started from is no place to land")
        w.drag(to: CGPoint(x: reason.midX, y: reason.midY))
        let refunds = try require(table(w.editor, "refunds"))
        expectEqual(w.editor.hintedPart, refunds.props.columns[3].id, "another row of the same table is")
        w.drag(to: CGPoint(x: paymentID.midX, y: paymentID.midY))
        expectEqual(w.editor.hintedPart, nil)
        w.release()
        expectEqual(arrows(w.editor).count, 1, "let go on its own row: no key drawn")
    },
    test("while it's drawn, payments and orders are outlined, the enum isn't; the dots show at the hovered row's ends only") {
        let w = try KeyDragWindow(t3Panel2)
        let paymentID = try w.row("refunds", 1), reason = try w.row("refunds", 3)
        let size = CGSize(width: 800, height: 600)
        let plain = renderBitmap(w.editor, size: size)
        w.move(to: CGPoint(x: paymentID.midX, y: paymentID.midY))
        let hovered = renderBitmap(w.editor, size: size)
        for (rect, shows) in [(paymentID, true), (reason, false)] {
            for x in [rect.minX - 12, rect.maxX + 12] {
                let dot = CGRect(x: x - 2, y: rect.midY - 2, width: 4, height: 4)
                expectEqual(changedPixels(plain, hovered, in: dot) > 0, shows, "a dot at \(x), \(rect.midY)")
            }
        }
        w.move(to: CGPoint(x: paymentID.maxX + 12, y: paymentID.midY))
        w.press()
        w.drag(to: CGPoint(x: 380, y: 250))
        let drawing = renderBitmap(w.editor, size: size)
        @MainActor func top(_ title: String) throws -> CGRect {
            let id = try require(w.editor.document.shapes.first { $0[TitleProperty.self] == title }?.id)
            let bounds = w.editor.camera.toView(try require(w.editor.shapeContext.geometry(of: id)?.bounds))
            return CGRect(x: bounds.minX + 30, y: bounds.minY - 4, width: bounds.width - 60, height: 8)
        }
        expect(changedPixels(plain, drawing, in: try top("payments")) > 0, "payments takes keys: outlined")
        expect(changedPixels(plain, drawing, in: try top("orders")) > 0, "orders too")
        expectEqual(changedPixels(plain, drawing, in: try top("order_status")), 0, "the enum takes none")
        // The row it's drawn from keeps its band while the drag lasts; no other row of refunds has one.
        @MainActor func inside(_ row: CGRect) -> CGRect { CGRect(x: row.minX + 140, y: row.midY - 3, width: 60, height: 6) }
        expect(changedPixels(plain, drawing, in: inside(paymentID)) > 0, "payment_id banded")
        expectEqual(changedPixels(plain, drawing, in: inside(reason)), 0, "reason isn't")
        w.release()
        expectEqual(arrows(w.editor).count, 1, "let go on nothing: no key drawn")
    },
])

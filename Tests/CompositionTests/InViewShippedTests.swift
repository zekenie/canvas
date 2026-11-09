import AppKit
@_spi(Host) import Canvas
import Adornments
import Arrows
import CanvasTesting
import CanvasUI
import Engineering
import Geometry
import Keyboard
import LineRows
import Selection
import ShippedTesting
import TestKit
import Titles

// What the first UX walk of the engineering kit found of the view, through a board's real window, where the inspector the
// selection shows slides in over the canvas: what lands stays in view, the inspector it is about to show counted (a table
// taken out with ⌘V, named at once; ⇧↩ beside a table, tops aligned, the two kept in view by the least pan); Escape to the
// database a table is in moves nothing while any of it shows; and VoiceOver hears each placement and rename once.

@MainActor private func table(_ editor: CanvasEditor, _ title: String) -> ShapeRecord<DatabaseTable>? {
    editor.document.shapes.lazy.compactMap { $0.typed(as: DatabaseTable.self) }.first { $0[TitleProperty.self] == title }
}

extension EmptyBoardWindow {
    /// Until the camera lands where it's headed.
    func waitForCamera() {
        window.spin(until: { self.editor.camera == self.editor.cameraTarget }, timeout: 3)
        window.settle()
    }

    /// Whether `id`'s box, with the row its title's pill is in above it (27 points), is in the part of the view the chrome
    /// will leave clear once it settles (the inspector the selection shows counted), where the camera is headed.
    func showsWhole(_ id: ShapeID) -> Bool {
        guard let box = editor.document[id]?.box else { return false }
        let above = (AdornmentLayout.rowGap + AdornmentLayout.rowHeight) / editor.cameraTarget.zoom
        let shown = CGRect(x: box.minX, y: box.minY - above, width: box.width, height: box.height + above)
        return editor.cameraTarget.toWorld(editor.unobscuredViewport).contains(shown)
    }
}

private let crowded = #"""
    table "customers" columns: "id uuid pk\nemail text unique\nname text\nstreet text\ncity text\npostcode text\ncountry char(2)\ncreated_at timestamptz"
    table "orders" right of "customers" (gap: 90) columns: "id uuid pk\ncustomer_id uuid → customers.id\ntotal_cents int"
    table "payments" right of "orders" (gap: 90) columns: "id uuid pk\norder_id uuid\namount_cents int"
    """#

@MainActor let inViewShippedTests = Suite("What lands stays in view, shipped", [
    test("structure 28 to 30: rows cut, then ⌘V with nothing selected: the new table lands in what the inspector will leave clear, its name typed in view") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        try w.turnKitOn()
        try w.draw(crowded)
        let customers = try require(table(editor, "customers"))
        let walk = w.walk()
        editor.selectedShapeIDs = [customers.id]
        walk.press(.return)
        for _ in 0..<5 { walk.press(.up) }
        for _ in 0..<4 { walk.press(Chord(Key.down, .shift)) }
        walk.press(Chord("x", .command))
        walk.press(.escape)
        walk.press(.escape)
        expectEqual(editor.selectedShapeIDs, [])
        walk.press(Chord("v", .command))
        let made = try require(editor.editingShapeID, "its name typed at once")
        w.waitForCamera()
        expect(editor.unobscuredViewport.maxX < w.canvas.bounds.width, "the inspector's room left out: \(editor.unobscuredViewport)")
        expect(w.showsWhole(made), "the new table and its name's pill in view, clear of the inspector")
        w.type("addresses", with: walk)
        expect(w.showsWhole(made), "and still while it's named")
        expectEqual(undoTitle(w.window), "Undo Move Columns to New Table")
    },
    test("T1 panel 3: ⇧↩ with a table selected: a table beside it, tops aligned, the two in view by the least pan; Add Table heard once") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        try w.turnKitOn()
        try w.draw(#"table "customers" columns: "id uuid pk\nemail text unique\nname text\ncreated_at timestamptz""#)
        let customers = try require(table(editor, "customers"))
        let walk = w.walk()
        editor.selectedShapeIDs = [customers.id]
        w.waitForCamera()
        let zoom = editor.camera.zoom
        let heard = editor.announcements.count
        walk.press(Chord(.return, .shift))
        let made = try require(editor.editingShapeID, "the new table's name typed at once")
        w.waitForCamera()
        let beside = try require(editor.document[customers.id]?.box), box = try require(editor.document[made]?.box)
        expectEqual(box.minY, beside.minY, "tops aligned")
        expect(box.minX > beside.maxX, "right of it")
        expect(w.showsWhole(made) && w.showsWhole(customers.id), "both in view, the inspector's room left out")
        expectEqual(editor.camera.zoom, zoom, "panned, never zoomed")
        expectEqual(Array(editor.announcements.dropFirst(heard)).filter { $0 == "Add Table" }, ["Add Table"], "heard once")
        expectEqual(undoTitle(w.window), "Undo Add Table")
    },
    test("structure 15: Escape from a table to its database leaves the camera where it is while any of the database shows") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        try w.turnKitOn()
        try w.draw(#"database "shop" size: 1180x1500"#)
        try w.draw(#"table "customers" in "shop" columns: "id uuid pk\nemail text""#)
        let customers = try require(table(editor, "customers"))
        let walk = w.walk()
        editor.selectedShapeIDs = [customers.id]
        w.waitForCamera()
        let before = editor.cameraTarget
        walk.press(.escape)
        let shop = try require(editor.document.shapes.first { $0.kind == Database.kind })
        expectEqual(editor.selectedShapeIDs, [shop.id], "the database selected")
        w.waitForCamera()
        expectEqual(editor.camera, before, "not zoomed out to the whole database, nor moved")
    },
    test("tables 4, apis 4: /table and /api through the command bar are heard once, in the bar's step; the new API's pill is in view, clear of the title bar") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        try w.turnKitOn()
        let walk = w.walk()
        var heard = editor.announcements.count
        walk.press(Chord("/"))
        w.type("table orders", with: walk)
        walk.press(.return)
        w.window.settle()
        expectEqual(Array(editor.announcements.dropFirst(heard)), ["Add Table"], "once, not as the tool's words as well")
        walk.press(.escape)
        editor.selectedShapeIDs = []
        heard = editor.announcements.count
        walk.press(Chord("/"))
        w.type("api shop", with: walk)
        walk.press(.return)
        w.window.settle()
        w.waitForCamera()
        expectEqual(Array(editor.announcements.dropFirst(heard)), ["Add API"], "once")
        let api = try require(editor.document.shapes.first { $0.kind == API.kind })
        expect(w.showsWhole(api.id), "the new API and its title's pill are inside the part of the view the chrome leaves clear")
    },
    test("tables 4: a rename is heard once however editing ends: editing ended from outside (⌘L's way), the keyboard going to the canvas (a click's), Escape") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        try w.turnKitOn()
        try w.draw(#"table "orders" columns: "id uuid pk""#)
        let orders = try require(table(editor, "orders"))
        let walk = w.walk()
        @MainActor func rename(_ how: String, _ ending: @MainActor () -> Void) {
            editor.selectedShapeIDs = [orders.id]
            editor.undoHistory.seal()
            walk.press(.return)
            walk.press(.up)
            walk.press(.up)
            expectEqual(w.lineRows?.focus, .title, "the caret in the name")
            let heard = editor.announcements.count
            w.type("x", with: walk)
            ending()
            w.window.settle()
            expectEqual(Array(editor.announcements.dropFirst(heard)), ["Rename Table"], "heard once after \(how)")
        }
        rename("editing ended") { editor.endEditing() }
        rename("Escape") { walk.press(.escape) }
        rename("the keyboard going to the canvas") { w.window.makeFirstResponder(w.canvas) }
        editor.endEditing()
        expectEqual(editor.document[orders.id]?[TitleProperty.self], "ordersxxx")
    },
    test("structure 35 to 41: a key between tables in two databases is painted above both databases, under the tables, so no database hides its end") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let editor = w.editor
        try w.turnKitOn()
        try w.draw(#"""
            database "billing"
            database "accounts" right of "billing" (gap: 120)
            """#)
        try w.draw(#"""
            table "payments" in "billing" columns: "id uuid pk\nuser_id uuid → users.id"
            table "users" in "accounts" columns: "id uuid pk\nemail text"
            """#)
        let order = editor.paintOrder().map(\.id)
        let key = try require(editor.document.shapes.first { $0.kind == Arrow.kind }?.id, "the key is drawn")
        let databases = editor.document.shapes.filter { $0.kind == Database.kind }.map(\.id)
        expectEqual(databases.count, 2)
        let at = try require(order.firstIndex(of: key))
        for database in databases { expect(try require(order.firstIndex(of: database)) < at, "above each database") }
        let users = try require(table(editor, "users")), payments = try require(table(editor, "payments"))
        let higher = max(try require(order.firstIndex(of: users.id)), try require(order.firstIndex(of: payments.id)))
        expect(at < higher, "under the tables")
    },
])

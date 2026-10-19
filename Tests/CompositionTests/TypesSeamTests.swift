import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CanvasUI
import Find
import Foundation
import Geometry
import LanguageModels
import Locking
import Mentions
import Selection
import ShippedTesting
import StickyNotes
import TestKit
import Titles
import Types

// Where the types cut's four tracks meet, as the app has them: the rows of a note (rows, values, typing), the
// card a row with more in it opens (the form in it), the one writer, the check, and the panel's section, all
// in the shipped list. Each case here crosses a seam two tracks built apart against stubs of one another.

/// The shipped list on an editor in a canvas view in an unshown window, 800 by 600, with the fixtures' types
/// as notes far off the view, Employee a Person, and the Order type's note at the top left on request.
@MainActor
private final class Seam {
    let pasteboard = NSPasteboard.withUniqueName()
    let h: EditorHarness
    let editor: CanvasEditor
    let window: NSWindow
    let canvas: CanvasView

    init() throws {
        let pasteboard = self.pasteboard
        h = EditorHarness { ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: $0, pasteboard: pasteboard, model: ScriptedLanguageModel()) }
        editor = h.editor
        (window, canvas) = windowed(editor)
        window.isReleasedWhenClosed = false
        editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        for (place, type) in [FieldFixtures.person, FieldFixtures.address, FieldFixtures.employee, FieldFixtures.order].enumerated() {
            editor.addTypeNote(type.schema, text: MentionText(plain: type.words), title: type.title,
                               frame: CGRect(x: 3000, y: 100 + 300 * CGFloat(place), width: 200, height: 200), id: type.id)
        }
        editor.addTypeLink(FieldFixtures.personID, to: FieldFixtures.employeeID)
    }

    func close() {
        window.close()
        pasteboard.releaseGlobally()
    }

    var rows: RowBook { editor.rowBook! }
    var cards: FieldCards { editor.fieldCards! }

    /// A note that is an Order at the top left of the view, with `values`.
    @discardableResult
    func order(_ values: JSONObject = [:], at origin: CGPoint = CGPoint(x: 40, y: 40)) -> ShapeID {
        var note = ShapeRecord(StickyNote(frame: CGRect(origin: origin, size: CGSize(width: 200, height: 200)), text: MentionText(plain: "An order")))
        note[IsAProperty.self] = [TypeLink(FieldFixtures.orderID)]
        if !values.isEmpty { note[FieldValuesProperty.self] = FieldValues(values) }
        let record = AnyShapeRecord(note)
        editor.transact { $0.insert(record) }
        return record.id
    }

    func row(_ id: ShapeID, _ name: String) throws -> ShownRow {
        try require(rows.rows(of: id).first { $0.name == name }, "a row \(name)")
    }

    /// A click on a row's value, as the person's: the select tool's press and release.
    func click(_ id: ShapeID, _ name: String) throws {
        let row = try row(id, name)
        h.click(at: h.view(CGPoint(x: row.valueRect.minX + 8, y: row.rect.midY)))
    }

    func advance() { h.scheduler.advance(by: .zero) }
    var rowsView: RowsView? { canvas.descendants(RowsView.self).first }
    func value(_ id: ShapeID, _ path: FieldPath) -> JSONValue? { editor.document[id]?[FieldValuesProperty.self]?.value(at: path) }
}

/// A board as the app opens it, in its window (unshown, without the details), with the fixtures' types and
/// an Order on it, driven by keys and clicks: what a seal, a mouse-down and the board's undo do to a card's step.
@MainActor
private final class SeamBoard {
    let board: BoardDocument
    let window: BoardWindow
    let canvas: CanvasView
    let pasteboard = NSPasteboard.withUniqueName()
    let order: ShapeID
    var editor: CanvasEditor { board.editor }
    var cards: FieldCards { editor.fieldCards! }

    init(values: JSONObject = [:]) throws {
        try configureBoards(pasteboard: pasteboard)
        board = BoardDocument()
        board.start(with: CanvasDocument())
        board.viewState.showsDetails = false
        board.makeWindowControllers()
        window = try require(board.windowControllers.first?.window as? BoardWindow)
        window.settle()
        canvas = try require(board.focus.canvas)
        window.makeFirstResponder(canvas)
        for (place, type) in [FieldFixtures.person, FieldFixtures.address, FieldFixtures.employee, FieldFixtures.order].enumerated() {
            board.editor.addTypeNote(type.schema, text: MentionText(plain: type.words), title: type.title,
                               frame: CGRect(x: 3000, y: 100 + 300 * CGFloat(place), width: 200, height: 200), id: type.id)
        }
        board.editor.addTypeLink(FieldFixtures.personID, to: FieldFixtures.employeeID)
        var note = ShapeRecord(StickyNote(frame: CGRect(x: 40, y: 40, width: 200, height: 200), text: MentionText(plain: "An order")))
        note[IsAProperty.self] = [TypeLink(FieldFixtures.orderID)]
        if !values.isEmpty { note[FieldValuesProperty.self] = FieldValues(values) }
        let record = AnyShapeRecord(note)
        board.editor.transact { $0.insert(record) }
        order = record.id
        window.settle()
    }

    func close() {
        board.close()
        pasteboard.releaseGlobally()
    }

    func row(_ name: String) throws -> ShownRow {
        try require(editor.rowBook?.rows(of: order).first { $0.name == name }, "a row \(name)")
    }

    /// A press and release at a world point, as the mouse sends them to the window's canvas.
    func click(_ world: CGPoint) {
        window.makeFirstResponder(canvas)
        let at = canvas.convert(editor.camera.toView(world), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            if type == .leftMouseDown { canvas.mouseDown(with: event) } else { canvas.mouseUp(with: event) }
        }
    }

    func clickRow(_ name: String) throws {
        let row = try row(name)
        click(CGPoint(x: row.valueRect.minX + 8, y: row.rect.midY))
    }

    func value(_ path: FieldPath) -> JSONValue? { editor.document[order]?[FieldValuesProperty.self]?.value(at: path) }
    func tab() { window.press("\t", code: 48) }
}

private let items = FieldPath(field: "lineItems")

@MainActor let typesSeamTests = Suite("Types, where the tracks meet", [
    test("a click on `2 items ›` opens the card under the row, Tab off its last cell goes to the note's next row, Escape leaves its row focused and a second Escape ends editing") {
        let s = try Seam()
        defer { s.close() }
        let id = s.order(["lineItems": [["product": "Mug", "quantity": 1, "price": 4], ["product": "Plate", "quantity": 2, "price": 5]]])
        let other = s.editor.add(StickyNote(frame: CGRect(x: 400, y: 40, width: 100, height: 100), text: "Another"))
        s.editor.selection = other
        expectEqual(try s.row(id, "line items").content, .summary("2 items"))
        try s.click(id, "line items")
        expectEqual(s.editor.editingShapeID, id, "a click on a row acts at once")
        expect(s.cards.openTarget == nil, "the card is asked for on the next turn")
        s.advance()
        expectEqual(s.cards.openTarget?.target, .field(items))
        let row = try s.row(id, "line items")
        expectEqual(s.editor.card?.anchor, row.rect, "hung from the row")
        let form = try require(s.cards.openForm)
        expect(s.window.firstResponder === form.cellEditor, "the card has the keyboard, in its first cell")
        // The caret is in the card's first cell, a path inside the row's field: the row is not the one typed in, so its summary is
        // still drawn behind the card.
        expectEqual(s.editor.fieldChecks?.typing?.path, items.index(0).key("product"))
        let rep = renderBitmap(s.editor, size: CGSize(width: 800, height: 600))
        var ink = 0
        for y in Int(row.rect.minY)..<Int(row.rect.maxY) {
            for x in Int(row.valueRect.minX)..<Int(row.valueRect.maxX) where pixel(rep, at: CGPoint(x: x, y: y)).prefix(3).reduce(0, +) < 300 { ink += 1 }
        }
        expect(ink > 30, "`2 items ›` is drawn in its row while the card is under it (\(ink) dark pixels)")
        // Escape: the card goes and the row is the focus again.
        s.window.pressEscape()
        expect(s.cards.openTarget == nil)
        expectEqual(s.rowsView?.focusedRow, "line items")
        expectEqual(s.editor.editingShapeID, id)
        s.window.pressEscape()
        expectEqual(s.editor.editingShapeID, nil, "a second Escape ends editing")
        // Again from a click; Return opens the card once more, and Tab through every cell goes on to the next row.
        try s.click(id, "line items")
        s.advance()
        s.window.pressEscape()
        expectEqual(s.rowsView?.focusedRow, "line items")
        s.window.pressReturn()
        expectEqual(s.cards.openTarget?.target, .field(items))
        for _ in 0..<40 where s.cards.openTarget != nil { s.window.press("\t", code: 48) }
        expect(s.cards.openTarget == nil, "Tab off the last stop closed the card")
        let names = s.rows.rows(of: id).map(\.name)
        let next = try require(names.firstIndex(of: "line items").flatMap { names.indices.contains($0 + 1) ? names[$0 + 1] : nil })
        expectEqual(s.rowsView?.focusedRow, next, "and the keyboard is on the row after it")
        s.window.pressEscape()
        expectEqual(s.editor.editingShapeID, nil, "Escape on a row with nothing open ends editing")
    },
    test("a type's note and a locked note open read-only cards from their real rows: nothing is written, nothing shakes, and the cards close with a press elsewhere") {
        let s = try Seam()
        defer { s.close() }
        // A type's note: Order's own, in view.
        s.editor.transact("Move") { $0.update(FieldFixtures.orderID, as: StickyNote.self) { $0.props.frame = CGRect(x: 40, y: 40, width: 200, height: 200) } }
        let mine = try require(s.rows.rows(of: FieldFixtures.orderID).first { $0.name == "line items" })
        let undoName = s.editor.undoHistory.undoName
        let shake = try require(s.editor.service(RefusalShake.self))
        s.h.click(at: s.h.view(CGPoint(x: mine.valueRect.minX + 8, y: mine.rect.midY)))
        expectEqual(s.cards.openTarget?.shape, FieldFixtures.orderID)
        expectEqual(s.cards.openTarget?.target, .field(items))
        let typeForm = try require(s.cards.openForm)
        expect(typeForm.isReadOnly, "a type's rows are read")
        expect(!typeForm.sheet.lines.isEmpty, "names and kinds")
        expect(s.editor.editingShapeID == nil, "a type's row begins no editing")
        s.window.type("x")
        expectEqual(s.editor.undoHistory.undoName, undoName, "typing in it writes nothing")
        expect(!shake.isShaking)
        s.cards.close()
        // A locked note that is one.
        let ann = s.order(["lineItems": [["product": "Mug", "quantity": 1]]], at: CGPoint(x: 400, y: 40))
        s.editor.lock([ann])
        let before = s.editor.undoHistory.undoName
        try s.click(ann, "line items")
        s.advance()
        expectEqual(s.cards.openTarget?.shape, ann)
        let lockedForm = try require(s.cards.openForm)
        expect(lockedForm.isReadOnly, "a locked note is read")
        expectEqual(s.editor.card?.stepName, nil, "and holds no step")
        expect(s.editor.editingShapeID == nil, "editing begins on a locked note's value only as a refused try")
        s.window.type("x")
        expectEqual(s.value(ann, items.index(0).key("product")), "Mug")
        expectEqual(s.editor.undoHistory.undoName, before)
        expect(!shake.isShaking, "reading is no try")
        s.cards.close()
    },
    test("a card opened from a real row: its edits across cells, a Remove and a tab are one step named for the field, in a board window where seals and mouse-downs run; a commit from elsewhere in the middle makes it two") {
        let b = try SeamBoard()
        defer { b.close() }
        let start = b.editor.undoHistory.undoName
        try b.clickRow("line items")
        runLoop { b.cards.openTarget != nil }
        expectEqual(b.cards.openTarget?.target, .field(items))
        expectEqual(b.editor.card?.stepName, "Change Line Items")
        let form = try require(b.cards.openForm)
        b.window.type("Mug")
        b.tab()
        b.window.type("2")
        b.tab()
        b.window.type("9.5")
        b.editor.undoHistory.seal()
        // A mouse-down inside the window, in the card, does not end the step.
        b.window.press("\t", code: 48)
        b.window.type("Plate")
        expectEqual(b.value(items.index(0).key("product")), "Mug")
        expectEqual(b.value(items.index(1).key("product")), "Plate")
        // Remove the first line from its menu.
        let remove = try require(form.contextMenu(for: FieldStop(line: 0, column: 0))?.items.first { $0.title == "Remove" })
        _ = remove.target?.perform(remove.action, with: remove)
        expectEqual(b.value(items.index(0).key("product")), "Plate", "the line is gone and the one after it moved up")
        expectEqual(b.editor.undoHistory.undoName, "Change Line Items", "all one step")
        b.editor.undo()
        expect(b.cards.openTarget == nil, "an undo closes the card")
        expectEqual(b.value(items), nil, "one undo took every edit away")
        expectEqual(b.editor.undoHistory.undoName, start, "and there was nothing else")
        // A commit from elsewhere between two edits: two steps by the one name.
        try b.clickRow("line items")
        runLoop { b.cards.openTarget != nil }
        b.window.type("Mug")
        b.editor.transact("Elsewhere") { $0.update(FieldFixtures.personID, as: StickyNote.self) { $0.props.frame.origin.x += 1 } }
        b.window.type("s")
        expectEqual(b.value(items.index(0).key("product")), "Mugs")
        b.editor.undo()
        expectEqual(b.editor.undoHistory.undoName, "Elsewhere", "the typing after it was a step of its own, and it came off first")
    },
    test("a type changed under rows and checks: both read the new field the moment the commit ends, whether or not Find has been opened") {
        for findOpen in [false, true] {
            let s = try Seam()
            defer { s.close() }
            let id = s.order(["lineItems": [["product": "Mug"]]])
            if findOpen { s.editor.find?.open() }
            let before = try require(s.editor.shapeContext.frame(of: id))
            let names = s.rows.rows(of: id).map(\.name)
            expect(!names.contains("phone"))
            let grown = FieldFixtures.order.schema
                .replacingOccurrences(of: #""lineItems": {"#, with: #""phone": { "type": "string" }, "lineItems": {"#)
                .replacingOccurrences(of: #""required": ["customer", "lineItems"]"#, with: #""required": ["customer", "lineItems", "phone"]"#)
            expect(grown != FieldFixtures.order.schema)
            s.editor.transact("Change Schema") { $0.update(FieldFixtures.orderID) { $0[TypeSchemaProperty.self] = SchemaText(grown) } }
            // Nothing has run: no frame drawn, no turn of the scheduler.
            expect(s.rows.rows(of: id).map(\.name).contains("phone"), "the rows read the field (Find open: \(findOpen))")
            let record = try require(s.editor.document[id])
            let check = try require(s.editor.fieldChecks).fullCheck(of: record)
            expect(check.problems(at: FieldPath(field: "phone")).contains { $0.kind == .needed }, "the check reads it too (Find open: \(findOpen))")
            let after = try require(s.editor.shapeContext.frame(of: id))
            expect(after.height > before.height, "the note has the room for the row: \(before.height) to \(after.height)")
            s.advance()
            expect(try require(s.editor.fieldChecks).check(of: record).isIncomplete, "and after the turn")
        }
    },
    test("a gone type's chip is named one way in the rows, the card and the chips above a note: its last title, `Deleted` when never known, `Untitled` while it has none") {
        let s = try Seam()
        defer { s.close() }
        let id = s.order(["shippingAddress": ["street": "12 Main St"]])
        let draft = s.editor.addTypeNote(TypeSchemaProperty.starter, frame: CGRect(x: 3000, y: 2000, width: 200, height: 200))
        let stranger = ShapeID()
        s.editor.transact("Types") { $0.update(id) { $0[IsAProperty.self] = [FieldFixtures.orderID, draft, stranger, FieldFixtures.addressID].map(TypeLink.init) } }
        s.editor.transact("Delete") { $0.delete([FieldFixtures.addressID]) }
        // The chips above the note are the app's one word for each.
        let chips = s.editor.adornmentFrames(of: id).compactMap(\.label.text)
        expect(["Order", "Untitled", "Deleted", "Address"].allSatisfy(chips.contains), "\(chips)")
        // The row that holds the gone type draws the chip of the same function (`TypeChips.label`): Address's.
        let shipping = try s.row(id, "shipping address")
        expectEqual(shipping.content, .gone(FieldFixtures.addressID))
        // The card's chip for each.
        let book = try require(s.editor.fieldBook)
        let record = try require(s.editor.document[id])
        let field = try require(book.fields(of: record).fields.first { $0.field.name == "lineItems" })
        let context = FieldFormContext(editor: s.editor, shape: id, path: items, field: field, kind: book.kind(of: field), mode: .values,
                                       isReadOnly: false, presentation: .card, step: .ownRun)
        let form = FieldFormView(context)
        expect(form.chipName(FieldFixtures.orderID) == ("Order", false))
        expect(form.chipName(draft) == ("Untitled", false))
        expect(form.chipName(stranger) == ("Deleted", true))
        expect(form.chipName(FieldFixtures.addressID) == ("Address", true), "the last title it was known by")
        s.editor.undo()
        expect(form.chipName(FieldFixtures.addressID) == ("Address", false), "back whole when the delete is undone")
    },
])

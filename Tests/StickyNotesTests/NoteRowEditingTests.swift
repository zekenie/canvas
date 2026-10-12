import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Foundation
import Geometry
import LanguageModels
import Mentions
import Selection
import StickyNotes
import TestKit
import TextEditing
import Titles
import Types

// Typing in a row of a note that is one: the note's one editing session has two places for the caret, the
// words and a row. A press on a value begins the session in that row (its field, the caret where it was
// pressed), each keystroke is a commit through the one writer, and Tab, the arrows, Return and Escape walk
// and end it. Headless where a view is not needed; a real `CanvasView` in an unshown window where the keys and
// the first responder are the point.

/// The value that points at a note, as a pointer's field stores it.
private func link(_ id: ShapeID, _ name: String) -> JSONValue { FieldLink(target: id, stored: name).value }

private struct Failure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

@MainActor
private final class Bench {
    let h: EditorHarness
    let editor: CanvasEditor
    let log = RefusalLog()
    let window: NSWindow
    let canvas: CanvasView
    var book: RowBook { editor.rowBook! }

    /// The shared types a row below the visible part of the window, so a note that is one at the top of the
    /// window never pans the camera to be seen.
    init(words: String = "Ann Lee, staff engineer.") throws {
        let registry = try Registry(plugins: notePlugins + [LanguageModelsPlugin(model: ScriptedLanguageModel()), FreezingPlugin(log: log)])
        h = EditorHarness { CanvasEditor(registry: registry, scheduler: $0) }
        editor = h.editor
        let types = [FieldFixtures.person, FieldFixtures.employee, FieldFixtures.address, FieldFixtures.order, FieldFixtures.everyKind.a, FieldFixtures.everyKind.b]
        for (place, type) in types.enumerated() {
            var note = ShapeRecord(id: type.id, StickyNote(frame: CGRect(x: 40 + 400 * Double(place), y: 1500, width: 200, height: 200), text: MentionText(plain: type.words)))
            note[TypeSchemaProperty.self] = SchemaText(type.schema)
            note[TitleProperty.self] = type.title
            let record = AnyShapeRecord(note)
            editor.transact { $0.insert(record) }
        }
        editor.addTypeLink(FieldFixtures.personID, to: FieldFixtures.employeeID)
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        canvas = CanvasView(editor: editor)
        window.contentView = canvas
        editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        self.words = words
    }

    let words: String

    /// A note that is each of the types, at the top left of the window.
    @discardableResult
    func note(of types: [ShapeID], _ values: JSONObject = [:], words: String? = nil, at origin: CGPoint = CGPoint(x: 40, y: 40)) -> ShapeID {
        var note = ShapeRecord(StickyNote(frame: CGRect(origin: origin, size: CGSize(width: 200, height: 200)), text: MentionText(plain: words ?? self.words)))
        note[IsAProperty.self] = types.map(TypeLink.init)
        if !values.isEmpty { note[FieldValuesProperty.self] = FieldValues(values) }
        let record = AnyShapeRecord(note)
        editor.transact { $0.insert(record) }
        return record.id
    }

    /// Ann Lee, Anders Holm and Dana Novak: titled Persons far below the window, a pointer's targets.
    func people() -> (ann: ShapeID, anders: ShapeID, dana: ShapeID) {
        func person(_ name: String, at x: Double) -> ShapeID {
            let id = note(of: [FieldFixtures.personID], words: "", at: CGPoint(x: x, y: 2000))
            editor.transact { $0.update(id) { $0[TitleProperty.self] = name } }
            return id
        }
        return (person("Ann Lee", at: 40), person("Anders Holm", at: 340), person("Dana Novak", at: 640))
    }

    func set(_ id: ShapeID, _ values: JSONObject) {
        editor.transact { $0.update(id) { $0[FieldValuesProperty.self] = FieldValues(values) } }
    }

    func value(_ id: ShapeID, _ key: String) -> JSONValue? {
        editor.document[id]?[FieldValuesProperty.self]?.value(at: FieldPath(field: key))
    }

    func row(_ id: ShapeID, _ name: String) throws -> ShownRow {
        try require(book.rows(of: id).first { $0.name == name }, "a row \(name)")
    }

    /// A point on a row's value, `dx` in.
    func point(_ id: ShapeID, _ name: String, dx: CGFloat = 8) throws -> CGPoint {
        let row = try row(id, name)
        return CGPoint(x: row.valueRect.minX + dx, y: row.rect.midY)
    }

    /// Begins editing the note by a press on a row's value, as the click on it does.
    @discardableResult
    func begin(_ id: ShapeID, on name: String, dx: CGFloat = 8) throws -> Bool {
        editor.beginEditing(id, at: try point(id, name, dx: dx))
    }

    /// A click on the canvas at a world point, as the person's: the select tool's press and release.
    func click(_ point: CGPoint, count: Int = 1) { h.click(at: h.view(point), clickCount: count) }

    var rowsView: RowsView? { canvas.descendants(RowsView.self).first }

    /// The text view with the keyboard, if it is a row's field and not the words.
    var field: NSTextView? {
        guard let text = window.firstResponder as? NSTextView, let rows = rowsView, text.isDescendant(of: rows) else { return nil }
        return text
    }

    var words_: NSTextView? {
        guard let text = window.firstResponder as? NSTextView, field == nil else { return nil }
        return text
    }

    /// The row with the caret or the focus.
    var focused: String? { rowsView?.focusedRow }

    func tab() { editor.undoHistory.seal(); window.press("\t", code: 48) }
    func backtab() { editor.undoHistory.seal(); window.press("\u{19}", code: 48, modifiers: .shift) }
    func down() { window.press(String(UnicodeScalar(NSDownArrowFunctionKey)!), code: 125) }
    func up() { window.press(String(UnicodeScalar(NSUpArrowFunctionKey)!), code: 126) }
    func space() { window.press(" ", code: 49) }

    /// A press delivered to the rows' view under a point, as the window would.
    func press(at point: CGPoint, clicks: Int = 1) throws {
        let hit = try require(canvas.hitTest(canvas.convert(point, to: canvas.superview)), "a view under \(point)")
        guard hit is RowsView else { throw Failure("the rows' view takes the press, not \(type(of: hit))") }
        hit.mouseDown(with: window.mouse(.leftMouseDown, at: point, clicks: clicks, time: 1))
    }
}

/// The darkest red channel in `rect`, and whether any pixel is about `color`.
@MainActor private func has(_ rep: NSBitmapImageRep, _ color: [Int], in rect: CGRect, within tolerance: Int = 40) -> Bool {
    for y in stride(from: rect.minY.rounded(.down), to: rect.maxY.rounded(.up), by: 1) {
        for x in stride(from: rect.minX.rounded(.down), to: rect.maxX.rounded(.up), by: 1)
        where zip(pixel(rep, at: CGPoint(x: x, y: y)), color).prefix(3).allSatisfy({ abs($0 - $1) <= tolerance }) { return true }
    }
    return false
}

@MainActor private func ink(_ rep: NSBitmapImageRep, in rect: CGRect, paper: [Int] = [255, 222, 115, 255], by tolerance: Int = 24) -> Int {
    var count = 0
    for y in stride(from: rect.minY.rounded(.down), to: rect.maxY.rounded(.up), by: 1) {
        for x in stride(from: rect.minX.rounded(.down), to: rect.maxX.rounded(.up), by: 1)
        where zip(pixel(rep, at: CGPoint(x: x, y: y)), paper).prefix(3).contains(where: { abs($0 - $1) > tolerance }) { count += 1 }
    }
    return count
}

@MainActor let noteRowEditingTests = Suite("Typing in a row", [
    test("a press on a value begins editing in that row, the caret at the character pressed; on the words it begins in the words; on a name too") {
        let b = try Bench()
        let id = b.note(of: [FieldFixtures.personID], ["name": "Ann Lee"])
        let name = try b.row(id, "name")
        let text = "Ann Lee" as NSString
        let after3 = text.size(withAttributes: [.font: NSFont.systemFont(ofSize: TypesStyle.rowFontSize)]).width * 3 / 7
        expect(try b.begin(id, on: "name", dx: after3))
        let field = try require(b.field, "the row's field has the keyboard")
        expectEqual(field.string, "Ann Lee")
        expect((2...4).contains(field.selectedRange().location), "the caret near the 3rd character: \(field.selectedRange())")
        expectEqual(b.focused, "name")
        expect(b.editor.editingShapeID == id)
        _ = name
        b.editor.endEditing()
        // The words.
        let words = try require(b.editor.registry.mentionTextPlacements(of: try require(b.editor.document[id]), in: b.editor.shapeContext).first?.box)
        expect(b.editor.beginEditing(id, at: CGPoint(x: words.minX + 6, y: words.minY + 6)))
        expect(b.words_ != nil && b.field == nil, "the words take the press above the rows")
        b.editor.endEditing()
        // A name: nothing of the rows', so the words.
        expect(b.editor.beginEditing(id, at: CGPoint(x: name.nameRect.minX + 4, y: name.rect.midY)))
        expect(b.words_ != nil && b.field == nil, "a press on a name begins in the words")
    },
    test("typing writes `fieldValues` at each keystroke, stored by kind: text as typed, a number only when it reads back, a date as the day, either as its first branch that reads") {
        let b = try Bench()
        let a = b.note(of: [FieldFixtures.kindsAID])
        expect(try b.begin(a, on: "name"))
        b.window.type("Ann")
        expectEqual(b.value(a, "name"), "Ann")
        b.window.type(" L")
        expectEqual(b.value(a, "name"), "Ann L", "each keystroke is stored")
        b.tab()
        expectEqual(b.focused, "price")
        b.window.type("9.50")
        expectEqual(b.value(a, "price"), 9.5, "a number as a number")
        b.tab()
        b.window.type("3/3/26")
        expectEqual(b.value(a, "due"), .string(FieldText.date(from: "3/3/26") ?? "?"), "a date as the day")
        expect(FieldText.date(from: "3/3/26") != nil)
        let c = b.note(of: [FieldFixtures.kindsBID], at: CGPoint(x: 440, y: 40))
        b.editor.endEditing()
        expect(try b.begin(c, on: "size"))
        b.window.type("12")
        expectEqual(b.value(c, "size"), 12, "either: a number when it reads as one")
        b.window.type("x")
        expectEqual(b.value(c, "size"), "12x", "else the text")
        b.editor.endEditing()
        expect(try b.begin(c, on: "count"))
        b.window.type("02134")
        expectEqual(b.value(c, "count"), "02134", "a number that does not read back is kept as typed")
    },
    test("the row shows what was typed while the caret is there (`9.50`) and the stored form once it leaves (`9.5`)") {
        let b = try Bench()
        let a = b.note(of: [FieldFixtures.kindsAID])
        expect(try b.begin(a, on: "price"))
        b.window.type("9.50")
        expectEqual(b.field?.string, "9.50")
        b.tab()
        expectEqual(try b.row(a, "price").content, .text("9.5"), "what the row shows once the caret has left")
        expectEqual(b.field?.string, "", "and the next row's field is its own")
    },
    test("deleting every character clears the field") {
        let b = try Bench()
        let id = b.note(of: [FieldFixtures.personID], ["name": "Ann"])
        expect(try b.begin(id, on: "name", dx: 40))
        b.editor.undoHistory.seal()
        for _ in 0..<3 { b.window.pressDelete() }
        expectEqual(b.value(id, "name"), nil)
        expectEqual(b.editor.document[id]?[FieldValuesProperty.self], nil, "the empty note is not kept")
    },
    test("a line break is kept in the value and the field stays one line; the stand-in is one space; undo takes the paste with it") {
        let b = try Bench()
        let id = b.note(of: [FieldFixtures.personID])
        expect(try b.begin(id, on: "name"))
        let field = try require(b.field)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("a\nb", forType: .string)
        expect(field.readSelection(from: pasteboard, type: .string))
        field.didChangeText()
        expectEqual(b.value(id, "name"), "a\nb", "the break is in the value")
        expectEqual(field.string, "a b", "the field holds a space where it is")
        expect(!field.string.contains("\n"))
        expectEqual(try b.row(id, "name").content, .text("a b"), "and the row shows it as a space")
        b.window.type("c")
        expectEqual(b.value(id, "name"), "a\nbc", "typing after it takes nothing of it")
        b.window.pressDelete()
        b.window.pressDelete()
        expectEqual(b.value(id, "name"), "a\n", "the stand-in is one character: it is deleted whole")
        b.window.pressDelete()
        expectEqual(b.value(id, "name"), "a")
        // The paste is undone as a whole, and so is a deletion of its stand-in: each carries its attributes.
        func turn() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
        turn()
        let manager = try require(field.undoManager)
        field.selectAll(nil)
        pasteboard.setString("p\nq", forType: .string)
        expect(field.readSelection(from: pasteboard, type: .string))
        field.didChangeText()
        expectEqual(b.value(id, "name"), "p\nq")
        turn()
        manager.undo()
        field.didChangeText()
        expectEqual(b.value(id, "name"), "a", "undoing the paste takes its break with it")
        manager.redo()
        field.didChangeText()
        expectEqual(b.value(id, "name"), "p\nq", "and redo puts it back")
        expectEqual(field.string, "p q")
        turn()
        field.setSelectedRange(NSRange(location: 2, length: 0))
        b.window.pressDelete()
        expectEqual(b.value(id, "name"), "pq", "the stand-in deleted")
        turn()
        manager.undo()
        field.didChangeText()
        expectEqual(b.value(id, "name"), "p\nq", "undo of that brings the stand-in back, with its break")
        // A value that holds a break opens with a stand-in and writes nothing until a key is typed.
        b.editor.endEditing()
        b.set(id, ["name": "x\ny"])
        let revision = b.editor.revision
        expect(try b.begin(id, on: "name"))
        expectEqual(b.field?.string, "x y")
        expectEqual(b.editor.revision, revision, "nothing written by opening")
    },
    test("one field typed is one undo step named for it; another field is another; words, a row, words: `Typing`, `Change Email`, `Typing`") {
        let b = try Bench()
        let id = b.note(of: [FieldFixtures.personID])
        expect(try b.begin(id, on: "name"))
        b.window.type("Ann")
        b.tab()
        b.window.type("a@b.c")
        expectEqual(b.editor.undoHistory.undoName, "Change Email")
        b.editor.undoHistory.seal()
        b.editor.endEditing()
        b.editor.undo()
        expectEqual(b.value(id, "email"), nil, "the second field is the first undone")
        expectEqual(b.value(id, "name"), "Ann")
        expectEqual(b.editor.undoHistory.undoName, "Change Name")
        b.editor.undo()
        expectEqual(b.value(id, "name"), nil)
        // Words, a row, words.
        let c = b.note(of: [FieldFixtures.personID], words: "", at: CGPoint(x: 440, y: 40))
        let words = try require(b.editor.registry.mentionTextPlacements(of: try require(b.editor.document[c]), in: b.editor.shapeContext).first?.box)
        expect(b.editor.beginEditing(c, at: CGPoint(x: words.minX + 6, y: words.minY + 6)))
        b.window.type("hi")
        expectEqual(b.editor.undoHistory.undoName, "Typing")
        b.editor.undoHistory.seal()
        b.down()
        expectEqual(b.focused, "name")
        b.window.type("x")
        expectEqual(b.editor.undoHistory.undoName, "Change Name", "a row's commit ends the words' step")
        b.editor.undoHistory.seal()
        b.up()
        b.window.type("!")
        expectEqual(b.editor.undoHistory.undoName, "Typing", "and the next word starts another")
        b.editor.endEditing()
        b.editor.undo()
        expectEqual(b.editor.document[c]?.typed(as: StickyNote.self)?.props.text.stored, "hi", "the last words")
        b.editor.undo()
        expectEqual(b.value(c, "name"), nil)
        b.editor.undo()
        expectEqual(b.editor.document[c]?.typed(as: StickyNote.self)?.props.text.stored, "")
    },
    test("Tab and ⇧Tab walk every row, typed or not; Tab off the last row ends editing; ⇧Tab from the first puts the caret at the end of the words") {
        let b = try Bench()
        let id = b.note(of: [FieldFixtures.kindsAID])
        expect(try b.begin(id, on: "name"))
        var seen = [b.focused ?? ""]
        for _ in 0..<8 { b.tab(); seen.append(b.focused ?? "") }
        expectEqual(seen, ["name", "price", "due", "done", "status", "roles", "tags", "venue", "shipping address"])
        expect(b.window.firstResponder === b.rowsView || b.field != nil)
        b.tab()
        expectEqual(b.editor.editingShapeID, nil, "off the last row, editing ends")
        expect(try b.begin(id, on: "price"))
        for _ in 0..<3 { b.backtab() }
        expectEqual(b.focused, nil, "⇧Tab from the first row goes back to the words")
        let words = try require(b.words_, "the words have the keyboard")
        expectEqual(words.selectedRange().location, words.string.count, "the caret at the end of the words")
    },
    test("↓ from the words' last line focuses the first row; ↓ on an earlier line moves the caret a line; ↑ from the first row goes back; ↓ on the last row does nothing") {
        let b = try Bench(words: "One line\nTwo lines")
        let id = b.note(of: [FieldFixtures.personID], words: "One line\nTwo lines")
        let words = try require(b.editor.registry.mentionTextPlacements(of: try require(b.editor.document[id]), in: b.editor.shapeContext).first?.box)
        expect(b.editor.beginEditing(id, at: CGPoint(x: words.minX + 6, y: words.minY + 6)))
        let text = try require(b.words_)
        text.setSelectedRange(NSRange(location: 2, length: 0))
        b.down()
        expectEqual(b.focused, nil, "the caret moved a line")
        expect(text.selectedRange().location > 8, "to the second line: \(text.selectedRange())")
        expect(b.window.firstResponder === text)
        b.down()
        expectEqual(b.focused, "name", "from the last line, the first row")
        expect(b.field != nil)
        b.down()
        expectEqual(b.focused, "email")
        b.down()
        expectEqual(b.focused, "email", "on the last row nothing")
        b.up()
        expectEqual(b.focused, "name")
        b.up()
        expectEqual(b.focused, nil, "↑ from the first row goes back to the words")
        expect(b.words_ != nil)
        expectEqual(b.words_?.selectedRange().location, text.string.count, "at their end")
    },
    test("Return and Escape in a row end editing; ⌘↩ too") {
        let b = try Bench()
        let id = b.note(of: [FieldFixtures.personID])
        for ending in 0..<3 {
            expect(try b.begin(id, on: "name"))
            expect(b.field != nil)
            switch ending {
            case 0: b.window.pressReturn()
            case 1: b.window.pressEscape()
            default:
                let event = b.window.keyEvent("\r", code: 36, modifiers: .command)
                if !b.window.performKeyEquivalent(with: event) { b.window.sendEvent(event) }
            }
            expectEqual(b.editor.editingShapeID, nil, "ending \(ending)")
        }
    },
    test("Space on a focused box toggles it; on a focused choice queues its menu; Return on a `›` row asks for its card, and the card's `closed` leaves the row focused and `tabbedOut` goes on") {
        let b = try Bench()
        let id = b.note(of: [FieldFixtures.kindsAID])
        expect(try b.begin(id, on: "due"))
        b.tab()
        expectEqual(b.focused, "done")
        expect(b.window.firstResponder === b.rowsView)
        b.space()
        expectEqual(b.value(id, "done"), true)
        b.space()
        expectEqual(b.value(id, "done"), false, "an unticked box that was ticked holds false")
        b.tab()
        expectEqual(b.focused, "status")
        b.space()
        let queued = try require(b.editor.menuToPopUp, "the choice's menu")
        expectEqual(queued.menu.items.map(\.title), ["draft", "paid", "shipped", "", "None"])
        b.editor.menuDidPopUp()
        b.tab(); b.tab()
        expectEqual(b.focused, "tags")
        expect(b.book.opened.isEmpty, "Tab onto a row with more only focuses it")
        b.window.pressReturn()
        expectEqual(b.book.opened.count, 1)
        let request = try require(b.book.opened.last)
        expectEqual(request.target, .field(FieldPath(field: "tags")))
        expectEqual(request.mode, .values)
        expect(!request.isReadOnly)
        expectEqual(b.editor.editingShapeID, id, "Return on a `›` row does not end editing")
        // The card is real now: it is open under the row, holding the keyboard.
        let cards = try require(b.editor.fieldCards)
        expectEqual(cards.openTarget?.target, .field(FieldPath(field: "tags")))
        expect(b.window.firstResponder !== b.rowsView, "the card's form has the keyboard")
        b.window.pressEscape()
        expect(cards.openTarget == nil, "Escape closed the card")
        expectEqual(b.focused, "tags", "and the row is focused again")
        expect(b.window.firstResponder === b.rowsView, "the row focused again")
        expectEqual(b.editor.editingShapeID, id, "still editing")
        b.window.pressReturn()
        expectEqual(b.book.opened.count, 2)
        for _ in 0..<12 where cards.openTarget != nil { b.window.press("\t", code: 48) }
        expect(cards.openTarget == nil, "Tab off the card's last stop closed it")
        expectEqual(b.focused, "venue", "and went to the next row")
        b.space()
        expectEqual(b.book.opened.count, 3, "Space opens it too")
    },
    test("the card stays under its row: the note moved, the card follows a turn later") {
        let b = try Bench()
        let id = b.note(of: [FieldFixtures.kindsAID], ["tags": ["gift"]])
        // A session begun on a `›` row asks for its card on the scheduler's next turn.
        expect(try b.begin(id, on: "tags"))
        (b.editor.scheduler as? ManualScheduler)?.advance(by: .zero)
        let cards = try require(b.editor.fieldCards)
        expectEqual(cards.openTarget?.target, .field(FieldPath(field: "tags")))
        let before = try b.row(id, "tags").rect
        expectEqual(b.editor.card?.anchor, before, "hung from its row")
        b.editor.transact("Move") { $0.update(id, as: StickyNote.self) { $0.props.frame.origin.x += 100 } }
        expect(b.editor.card != nil, "not yet moved: the pass is a turn later")
        (b.editor.scheduler as? ManualScheduler)?.advance(by: .zero)
        let after = try b.row(id, "tags").rect
        expectEqual(after, before.offsetBy(dx: 100, dy: 0))
        expectEqual(b.editor.card?.anchor, after, "the card follows the row the book finds again")
        cards.close()
    },
    test("a card taken down some other way than the row's own keys (its field left the type, the service closed it) leaves the row free: the keyboard leaving it ends its focus") {
        let b = try Bench()
        let id = b.note(of: [FieldFixtures.orderID], ["lineItems": [["product": "Mug"]]])
        expect(try b.begin(id, on: "line items"))
        b.h.scheduler.advance(by: .zero)
        let cards = try require(b.editor.fieldCards)
        expect(cards.openTarget != nil, "the card is open on the row")
        expectEqual(b.focused, "line items")
        // The card goes with nobody's key: the row's `closed` is not told.
        cards.close()
        expect(cards.openTarget == nil)
        expectEqual(b.focused, "line items", "the row is still the focus")
        b.window.makeFirstResponder(b.canvas)
        expectEqual(b.focused, nil, "and the keyboard going elsewhere ends it, as it does with no card ever opened")
        // The same when the type loses the field under the card.
        b.editor.endEditing()
        expect(try b.begin(id, on: "line items"))
        b.h.scheduler.advance(by: .zero)
        expect(cards.openTarget != nil)
        let without = FieldFixtures.order.schema.replacingOccurrences(of: #""lineItems": {"#, with: #""lineItemsGone": {"#)
        expect(without != FieldFixtures.order.schema)
        b.editor.transact("Change Schema") { $0.update(FieldFixtures.orderID) { $0[TypeSchemaProperty.self] = SchemaText(without) } }
        b.h.scheduler.advance(by: .zero)
        expect(cards.openTarget == nil, "the field left its type and the card with it")
        b.editor.endEditing()
    },
    test("a session begun by a press on a `›` row asks for its card on the scheduler's next turn, and not at all if editing ended first") {
        let b = try Bench()
        let id = b.note(of: [FieldFixtures.orderID], ["lineItems": [["product": "Mug"]]])
        expect(try b.begin(id, on: "line items"))
        expectEqual(b.focused, "line items")
        expect(b.book.opened.isEmpty, "not yet: the session is not in its window")
        (b.editor.scheduler as? ManualScheduler)?.advance(by: .zero)
        expectEqual(b.book.opened.map(\.target), [.field(FieldPath(field: "lineItems"))])
        b.editor.endEditing()
        expect(try b.begin(id, on: "line items"))
        b.editor.endEditing()
        (b.editor.scheduler as? ManualScheduler)?.advance(by: .zero)
        expectEqual(b.book.opened.count, 1, "editing ended before the turn")
    },
    test("while a row's field has the caret `fieldChecks.typing` names it; moving to a box, to the words or ending editing clears it") {
        let b = try Bench()
        let id = b.note(of: [FieldFixtures.kindsAID])
        let checks = try require(b.editor.fieldChecks)
        expect(try b.begin(id, on: "name"))
        expect(checks.typing?.shape == id && checks.typing?.path == FieldPath(field: "name"))
        b.tab()
        expect(checks.typing?.path == FieldPath(field: "price"), "the next row's field")
        b.tab(); b.tab()
        expectEqual(b.focused, "done")
        expect(checks.typing == nil, "a box is never half typed")
        b.backtab(); b.backtab()
        expect(checks.typing?.path == FieldPath(field: "price"))
        b.backtab(); b.backtab()
        expect(b.words_ != nil)
        expect(checks.typing == nil, "the words")
        expect(try b.begin(id, on: "name"))
        expect(checks.typing != nil)
        b.editor.endEditing()
        expect(checks.typing == nil, "ending editing")
        // Only whoever set it clears it.
        expect(try b.begin(id, on: "name"))
        checks.typing = (id, FieldPath(field: "other"))
        b.tab()
        expect(checks.typing?.path == FieldPath(field: "price"), "the next field sets it again")
        checks.typing = (FieldFixtures.personID, FieldPath(field: "elsewhere"))
        b.editor.endEditing()
        expect(checks.typing?.path == FieldPath(field: "elsewhere"), "not cleared by a field of another shape")
        expect(try b.begin(id, on: "name"))
        checks.typing = (id, FieldPath(field: "elsewhere"))
        b.editor.endEditing()
        expect(checks.typing == nil, "the check's own net: editing ending clears a caret that was in its shape")
    },
    test("a value the check marks wrong is red while the caret is elsewhere; with the caret in it the render draws no value under the field and nothing is red") {
        let b = try Bench()
        let id = b.note(of: [FieldFixtures.personID], ["name": "Ann", "email": "bob"])
        b.book.checks = { _ in FieldCheck(problems: [FieldProblem(path: FieldPath(field: "email"), kind: .wrong, keyword: "format", place: [], message: "")]) }
        let email = try b.row(id, "email")
        let red = [189, 26, 26]
        expect(has(renderBitmap(b.editor, size: CGSize(width: 800, height: 600)), red, in: email.valueRect, within: 40), "red with the caret elsewhere")
        expect(try b.begin(id, on: "email"))
        let typing = renderBitmap(b.editor, size: CGSize(width: 800, height: 600))
        expectEqual(ink(typing, in: email.valueRect.insetBy(dx: 0, dy: 3)), 0, "the field draws it, the render does not")
        expect(!has(typing, red, in: email.rect, within: 40), "and the row being typed in is not red")
        b.window.type("x")
        b.tab()
        b.backtab()
        b.up()
        expect(has(renderBitmap(b.editor, size: CGSize(width: 800, height: 600)), red, in: email.valueRect, within: 40), "red again once the caret has left")
    },
    test("a value written from outside while the caret is in its row shows in the field") {
        let b = try Bench()
        let id = b.note(of: [FieldFixtures.personID], ["name": "Ann"])
        expect(try b.begin(id, on: "name", dx: 30))
        b.window.type("n")
        expectEqual(b.field?.string, "Annn")
        b.editor.transact { $0.update(id) { $0[FieldValuesProperty.self] = FieldValues(["name": "Zed"]) } }
        expectEqual(b.field?.string, "Zed")
        expectEqual(b.field.map { $0.selectedRange().location }, 3, "the caret as far as the text reaches")
        b.window.type("!")
        expectEqual(b.value(id, "name"), "Zed!")
    },
    test("no autocorrect, smart quotes or dashes, replacement or spelling marks in a field; `@` and `/` are letters and open no list") {
        let b = try Bench()
        let id = b.note(of: [FieldFixtures.personID])
        expect(try b.begin(id, on: "name"))
        let field = try require(b.field)
        expect(!field.isAutomaticSpellingCorrectionEnabled && !field.isAutomaticQuoteSubstitutionEnabled && !field.isAutomaticDashSubstitutionEnabled
               && !field.isAutomaticTextReplacementEnabled && !field.isContinuousSpellCheckingEnabled && !field.isGrammarCheckingEnabled)
        b.window.type("a@b/c \"q\" --")
        expectEqual(b.value(id, "name"), "a@b/c \"q\" --")
        expect(b.window.childWindows?.isEmpty ?? true, "no list opened")
    },
    test("a row's field lies over its render: its ink is where the render's is, to a pixel, and about as much of it, at 1× and 2×, zoomed in and out") {
        // Core Text (the render's kept lines) and TextKit 2 (the field) set a glyph's pixels a little differently, so what is held is where
        // the ink is: its box to a device pixel, and its weight to a quarter (TextKit sets a heavier stem at 1×).
        for (scale, zoom) in [(1, 1), (2, 1), (1, 2), (2, 0.6)] as [(CGFloat, CGFloat)] {
            let b = try Bench()
            b.editor.camera.setZoom(zoom, around: .zero)
            let id = b.note(of: [FieldFixtures.personID], ["name": "Ann Lee, Mugs", "email": "ann@example.com"])
            let size = CGSize(width: 400 * zoom, height: 340 * zoom)
            let plain = renderBitmap(b.editor, size: size, scale: scale)
            // The caret at the text's end, past what is compared: it is the one thing the render does not draw.
            expect(try b.begin(id, on: "name", dx: 200))
            let editing = try require(b.editor.makeEditingView())
            let edited = renderBitmap(b.editor, size: size, scale: scale, editing: editing)
            let row = try b.row(id, "name")
            let outset = TypesStyle.fieldFocusOutset
            let text = b.editor.camera.toView(CGRect(x: row.valueRect.minX, y: row.rect.minY + outset + 2, width: 70, height: row.rect.height - 2 * outset - 4))
            @MainActor func measure(_ rep: NSBitmapImageRep) -> (box: [Int], weight: Int) {
                var minX = 9999, maxX = -1, minY = 9999, maxY = -1, weight = 0
                for y in Int(text.minY * scale)..<Int(text.maxY * scale) {
                    for x in Int(text.minX * scale)..<Int(text.maxX * scale) {
                        let dark = 255 - pixel(rep, at: CGPoint(x: CGFloat(x) / scale, y: CGFloat(y) / scale))[2] * 255 / 115
                        weight += max(0, dark)
                        if dark > 100 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
                    }
                }
                return ([minX, maxX, minY, maxY], weight)
            }
            let (a, b2) = (measure(plain), measure(edited))
            expect(zip(a.box, b2.box).allSatisfy { abs($0 - $1) <= 1 }, "at \(scale)×, zoom \(zoom): the ink is in \(b2.box), the render's in \(a.box)")
            expect(Double(abs(a.weight - b2.weight)) <= Double(a.weight) * 0.25, "at \(scale)×, zoom \(zoom): as much ink: \(b2.weight) against \(a.weight)")
            b.editor.endEditing()
        }
    },
    test("the words' lines still fall on the render's with the rows view in place, and a line typed into the words moves the rows view down") {
        let b = try Bench()
        let id = b.note(of: [FieldFixtures.personID], ["name": "Ann"])
        let words = try require(b.editor.registry.mentionTextPlacements(of: try require(b.editor.document[id]), in: b.editor.shapeContext).first?.box)
        expect(b.editor.beginEditing(id, at: CGPoint(x: words.minX + 6, y: words.minY + 6)))
        let rows = try require(b.rowsView)
        let before = rows.frame
        let text = try require(b.words_)
        text.setSelectedRange(NSRange(location: text.string.count, length: 0))
        b.window.press("\r", code: 36)
        b.window.type("A second line of words, long enough to wrap past the width of the note and take a third line too.")
        expect(rows.frame.minY > before.minY + 18, "the rows view followed the block down: \(before.minY) to \(rows.frame.minY)")
        expectEqual(rows.frame.minY + b.editor.editingFrame!.minY, try b.row(id, "name").rect.minY - TypesStyle.rowsLead, "and sits where the rows are drawn")
    },
    test("a note that becomes read-only ends the session, and the rows view goes with it") {
        let b = try Bench()
        let id = b.note(of: [FieldFixtures.personID])
        expect(try b.begin(id, on: "name"))
        expect(b.rowsView != nil)
        b.editor.freeze([id])
        expectEqual(b.editor.editingShapeID, nil)
        expect(b.rowsView == nil)
        expectEqual(b.editor.fieldChecks?.typing == nil, true)
    },
    test("with a box focused, Backspace, Delete and a letter change nothing: the note is still there, still edited, the tool still Select") {
        let b = try Bench()
        let id = b.note(of: [FieldFixtures.kindsAID])
        b.editor.setTool(.select)
        expect(try b.begin(id, on: "due"))
        b.tab()
        expectEqual(b.focused, "done")
        let before = b.editor.revision
        b.window.pressDelete()
        b.window.press("\u{F728}", code: 117)
        b.window.press("n", code: 45)
        b.window.press("r", code: 15)
        expect(b.editor.document[id] != nil, "the note is still there")
        expectEqual(b.editor.editingShapeID, id)
        expectEqual(b.editor.revision, before, "nothing changed")
        expectEqual(b.editor.currentToolID, .select)
        expect(b.window.firstResponder === b.rowsView)
    },
    test("while the note is edited a press on a typed value moves the caret into that row, on a box toggles it and focuses the row, on a name leaves the caret in the words") {
        let b = try Bench()
        let id = b.note(of: [FieldFixtures.kindsAID], ["name": "Ann"])
        let words = try require(b.editor.registry.mentionTextPlacements(of: try require(b.editor.document[id]), in: b.editor.shapeContext).first?.box)
        expect(b.editor.beginEditing(id, at: CGPoint(x: words.minX + 6, y: words.minY + 6)))
        let text = try require(b.words_)
        text.setSelectedRange(NSRange(location: 3, length: 0))
        try b.press(at: try b.point(id, "name", dx: 5))
        expectEqual(b.focused, "name")
        expect(b.field != nil)
        try b.press(at: try b.point(id, "done", dx: 5))
        expectEqual(b.focused, "done")
        expectEqual(b.value(id, "done"), true, "the box toggled")
        expect(b.window.firstResponder === b.rowsView)
        try b.press(at: try b.point(id, "done", dx: 5))
        expectEqual(b.value(id, "done"), false)
        let name = try b.row(id, "name")
        try b.press(at: CGPoint(x: name.nameRect.minX + 4, y: name.rect.midY))
        expectEqual(b.focused, "done", "a name leaves the focus where it was")
        try b.press(at: try b.point(id, "status", dx: 5))
        expectEqual(b.focused, "status")
        expect(b.editor.menuToPopUp != nil, "a choice pops its menu")
    },
    test("a click on a value of a note that is not selected begins editing in that row at once, the caret where it was clicked; a click on a name begins nothing, a double-click on one edits the words") {
        let b = try Bench()
        let id = b.note(of: [FieldFixtures.personID], ["name": "Ann Lee"])
        let other = b.note(of: [FieldFixtures.personID], at: CGPoint(x: 440, y: 40))
        b.editor.selection = other
        let text = "Ann Lee" as NSString
        let after3 = text.size(withAttributes: [.font: NSFont.systemFont(ofSize: TypesStyle.rowFontSize)]).width * 3 / 7
        b.click(try b.point(id, "name", dx: after3))
        expectEqual(b.editor.selection, id, "selected alone")
        expectEqual(b.editor.editingShapeID, id, "and edited, at once")
        let field = try require(b.field, "the row's field has the keyboard")
        expect((2...4).contains(field.selectedRange().location), "the caret near the 3rd character: \(field.selectedRange())")
        b.editor.endEditing()
        // The note is the only one selected: a click on a name only selects it.
        let name = try b.row(id, "name")
        b.click(CGPoint(x: name.nameRect.minX + 4, y: name.rect.midY))
        expectEqual(b.editor.editingShapeID, nil, "a name edits nothing")
        expectEqual(b.editor.selection, id)
        // The words, on a click of the only selected note, are edited as ever.
        let words = try require(b.editor.registry.mentionTextPlacements(of: try require(b.editor.document[id]), in: b.editor.shapeContext).first?.box)
        b.click(CGPoint(x: words.minX + 6, y: words.minY + 6))
        expectEqual(b.editor.editingShapeID, id)
        expect(b.words_ != nil && b.field == nil)
        b.editor.endEditing()
        // A double-click on a name edits the words.
        b.click(CGPoint(x: name.nameRect.minX + 4, y: name.rect.midY), count: 2)
        expectEqual(b.editor.editingShapeID, id)
        expect(b.words_ != nil && b.field == nil, "the words take it")
    },
    test("a click on a box ticks it and one on a choice pops its menu, on a note that is not selected, and neither begins editing; one on a `›` row begins the session in it and asks for the card a turn later") {
        let b = try Bench()
        let id = b.note(of: [FieldFixtures.kindsAID], ["tags": ["gift"]])
        let done = try b.row(id, "done")
        b.click(CGPoint(x: done.valueRect.minX + 4, y: done.rect.midY))
        expectEqual(b.value(id, "done"), true)
        expectEqual(b.editor.editingShapeID, nil)
        expectEqual(b.editor.undoHistory.undoName, "Change Done")
        b.click(try b.point(id, "status"))
        expect(b.editor.menuToPopUp != nil)
        b.editor.menuDidPopUp()
        expectEqual(b.editor.editingShapeID, nil)
        b.click(try b.point(id, "tags"))
        expectEqual(b.editor.editingShapeID, id)
        expectEqual(b.focused, "tags")
        expect(b.book.opened.isEmpty, "not yet: the session is not in its window")
        b.h.scheduler.advance(by: .zero)
        let request = try require(b.book.opened.last)
        expectEqual(request.target, .field(FieldPath(field: "tags")))
        expect(!request.isReadOnly)
    },
    test("a locked note: a click on a typed value shakes it and edits nothing, a click on a `›` row opens a card to be read and does not shake") {
        let b = try Bench()
        let id = b.note(of: [FieldFixtures.kindsAID], ["tags": ["gift"], "name": "Ann"])
        b.editor.freeze([id])
        b.click(try b.point(id, "name"))
        expectEqual(b.log.refusals, [[id]])
        expectEqual(b.editor.editingShapeID, nil)
        expectEqual(b.value(id, "name"), "Ann")
        b.click(try b.point(id, "tags"))
        expectEqual(b.log.refusals.count, 1, "reading is no try")
        let request = try require(b.book.opened.last)
        expect(request.isReadOnly)
        expectEqual(b.editor.editingShapeID, nil)
    },
    test("a locked note: a click on a link row's value shakes it once, opens no list and writes nothing; a click on its pill still goes to the note") {
        let b = try Bench()
        let people = b.people()
        let id = b.note(of: [FieldFixtures.orderID], ["customer": link(people.ann, "Ann Lee")])
        b.editor.freeze([id])
        let row = try b.row(id, "customer")
        guard case .links(let pills, _) = row.content else { throw Failure("a pill") }
        b.click(CGPoint(x: row.valueRect.minX + pills[0].x + pills[0].width / 2, y: row.rect.midY))
        b.h.scheduler.advance(by: .zero)
        expectEqual(b.editor.selection, people.ann, "going changes nothing, so it goes")
        expectEqual(b.log.refusals, [], "and nothing is refused")
        b.set(id, [:])
        let empty = try b.row(id, "customer")
        b.click(CGPoint(x: empty.valueRect.minX + 8, y: empty.rect.midY))
        expectEqual(b.log.refusals, [[id]], "a click on the rest of the value shakes the note")
        expectEqual(b.editor.editingShapeID, nil)
        expect(b.field == nil && b.book.picking == nil)
    },
    test("the rows change under a focused row: the focus stays with the row of the same field; the field taken out, the caret is back in the words") {
        let b = try Bench()
        let id = b.note(of: [FieldFixtures.personID], ["name": "Ann"])
        expect(try b.begin(id, on: "email"))
        let schema = #"{"type": "object", "properties": {"phone": {"type": "string"}, "name": {"type": "string"}, "email": {"type": "string"}}}"#
        b.editor.transact { $0.update(FieldFixtures.personID) { $0[TypeSchemaProperty.self] = SchemaText(schema) } }
        expectEqual(b.focused, "email", "a field added above: the same row")
        expect(b.field != nil)
        let twoFields = #"{"type": "object", "properties": {"name": {"type": "string"}}}"#
        b.editor.transact { $0.update(FieldFixtures.personID) { $0[TypeSchemaProperty.self] = SchemaText(twoFields) } }
        expectEqual(b.focused, nil, "its field is gone")
        expect(b.words_ != nil, "the caret is back in the words")
        expect(b.editor.fieldChecks?.typing == nil)
    },
    test("a focused choice draws `▾` after its value; an unfocused one does not") {
        let b = try Bench()
        let id = b.note(of: [FieldFixtures.kindsAID], ["status": "paid"])
        expect(try b.begin(id, on: "due"))
        let rows = try require(b.rowsView)
        let status = try b.row(id, "status")
        @MainActor func bitmap() -> NSBitmapImageRep {
            let rep = rows.bitmapImageRepForCachingDisplay(in: rows.bounds)!
            rows.cacheDisplay(in: rows.bounds, to: rep)
            return rep
        }
        let block = try require(b.book.rowsRect(of: id))
        // After the value `paid`: where `▾` goes, inside the outline.
        let local = CGRect(x: status.valueRect.minX - block.minX + 28, y: status.rect.minY - block.minY + 4, width: 30, height: 14)
        let paper = [0, 0, 0, 0]
        let unfocused = ink(bitmap(), in: local, paper: paper, by: 10)
        b.tab(); b.tab()
        expectEqual(b.focused, "status")
        let focused = ink(bitmap(), in: local, paper: paper, by: 10)
        expect(focused > unfocused + 5, "`▾` and the outline's end: \(focused) against \(unfocused)")
    },
    test("Tab onto a link row focuses it; typing opens the list of the type's notes over its value and the render draws no value under the field; nothing is stored until a pick") {
        let b = try Bench()
        let people = b.people()
        let id = b.note(of: [FieldFixtures.orderID], ["customer": link(people.ann, "Ann Lee")])
        expect(b.editor.beginEditing(id))
        b.down()
        expectEqual(b.focused, "customer")
        expect(b.window.firstResponder === b.rowsView, "the row is focused, no field yet")
        expectEqual(b.book.picking?.key, nil)
        b.window.type("an")
        let field = try require(b.field, "a field over the value took the characters")
        expectEqual(field.string, "an")
        let list = try require((field as? EditingTextView)?.caretListWindow?.list, "the list is open")
        expectEqual(list.rows.compactMap(\.item).map(\.title).first, "Ann Lee")
        expect(list.rows.compactMap(\.item).count >= 2, "Ann Lee and Anders Holm at least")
        expectEqual(b.book.picking?.key, "customer", "the render draws nothing under the field")
        expectEqual(b.value(id, "customer"), link(people.ann, "Ann Lee"), "nothing stored")
        expect(b.editor.undoHistory.undoName != "Change Customer")
    },
    test("↓ and Return pick the highlighted line: the token is written, one step `Change Customer`, the row stays focused with the new pill") {
        let b = try Bench()
        let people = b.people()
        let id = b.note(of: [FieldFixtures.orderID])
        expect(b.editor.beginEditing(id))
        b.down()
        b.window.type("an")
        let list = try require((b.field as? EditingTextView)?.caretListWindow?.list)
        let titles = list.rows.compactMap(\.item).map(\.title)
        b.down()
        expectEqual(list.highlighted, 1)
        b.window.pressReturn()
        let picked = try require(b.editor.document[id]?[FieldValuesProperty.self]?["customer"].flatMap(FieldLink.init))
        expectEqual(picked.stored, titles[1])
        expect([people.ann, people.anders, people.dana].contains(picked.target))
        expectEqual(b.editor.undoHistory.undoName, "Change Customer")
        expect(b.field == nil && b.book.picking == nil, "the field and the list are gone")
        expectEqual(b.focused, "customer")
        expect(b.window.firstResponder === b.rowsView)
        guard case .links(let pills, _) = try b.row(id, "customer").content, pills.count == 1 else { throw Failure("one pill") }
        expectEqual(pills[0].link, picked)
        b.editor.undo()
        expectEqual(b.value(id, "customer"), nil, "one undo takes the pick")
    },
    test("Tab while picking, with a line highlighted, picks nothing and goes to the next row; ⇧Tab from the first goes back to the words") {
        let b = try Bench()
        let people = b.people()
        let id = b.note(of: [FieldFixtures.orderID], ["customer": link(people.ann, "Ann Lee")])
        expect(b.editor.beginEditing(id))
        b.down()
        b.window.type("anders")
        expect(try require((b.field as? EditingTextView)?.caretListWindow?.list.highlighted) == 0)
        b.window.press("\t", code: 48)
        expectEqual(b.focused, "shipping address", "the next row")
        expect(b.field == nil || b.focused == "shipping address")
        expectEqual(b.value(id, "customer"), link(people.ann, "Ann Lee"), "the value is as it was")
        b.up()
        expectEqual(b.focused, "customer")
        b.window.type("x")
        b.backtab()
        expectEqual(b.focused, nil, "⇧Tab from the first row")
        expect(b.words_ != nil, "the words have the keyboard")
        expectEqual(b.value(id, "customer"), link(people.ann, "Ann Lee"))
    },
    test("Space on the focused row opens the list with nothing typed; Escape closes it keeping the old value and the focus, a second Escape ends editing; Return with no match stores nothing") {
        let b = try Bench()
        let people = b.people()
        let id = b.note(of: [FieldFixtures.orderID], ["customer": link(people.ann, "Ann Lee")])
        expect(b.editor.beginEditing(id))
        b.down()
        b.space()
        let field = try require(b.field)
        expectEqual(field.string, "")
        let list = try require((field as? EditingTextView)?.caretListWindow?.list)
        expect(list.rows.compactMap(\.item).count >= 3, "the notes of the type, on any board")
        b.window.pressEscape()
        expect(b.field == nil && b.book.picking == nil, "the list and the field are gone")
        expectEqual(b.focused, "customer", "the row is still focused")
        expectEqual(b.editor.editingShapeID, id)
        expectEqual(b.value(id, "customer"), link(people.ann, "Ann Lee"))
        b.window.pressEscape()
        expectEqual(b.editor.editingShapeID, nil, "a second Escape ends editing")
        // Return with nothing that matches.
        expect(b.editor.beginEditing(id))
        b.down()
        b.window.type("zzqx")
        let none = try require((b.field as? EditingTextView)?.caretListWindow?.list)
        expectEqual(none.rows, [.empty("No matches")])
        b.window.pressReturn()
        expect(b.field != nil, "nothing was picked, so the field stays")
        expectEqual(b.value(id, "customer"), link(people.ann, "Ann Lee"), "what is typed is never stored")
    },
    test("Delete on the focused row clears the value, one step, and undo brings it back; a click on the row's value of a note that is not edited begins editing with the list open a turn later") {
        let b = try Bench()
        let people = b.people()
        let id = b.note(of: [FieldFixtures.orderID], ["customer": link(people.ann, "Ann Lee")])
        expect(b.editor.beginEditing(id))
        b.down()
        b.window.press("\u{7F}", code: 51)
        expectEqual(b.value(id, "customer"), nil)
        expectEqual(b.editor.undoHistory.undoName, "Change Customer")
        expectEqual(b.focused, "customer", "the row stays focused")
        b.editor.undo()
        expectEqual(b.value(id, "customer"), link(people.ann, "Ann Lee"))
        b.editor.endEditing()
        b.editor.selection = nil
        let value = try require(b.book.rows(of: id).first { $0.name == "status" }?.valueRect)
        _ = value
        let pill = try b.row(id, "customer")
        guard case .links(let pills, _) = pill.content else { throw Failure("a pill") }
        // Off the pill, on the rest of the value: a link row's value is the pill alone, so click the empty row instead.
        b.set(id, [:])
        let empty = try b.row(id, "customer")
        expect(!pills.isEmpty)
        b.click(CGPoint(x: empty.valueRect.minX + 8, y: empty.rect.midY))
        expectEqual(b.editor.editingShapeID, id, "a click on the value begins editing")
        expectEqual(b.focused, "customer")
        b.h.scheduler.advance(by: .zero)
        expect(b.field != nil, "the list is open a turn later")
        expect(b.book.picking != nil)
    },
    test("a click on a live pill of the note being edited ends editing and shows the note it points at after the scheduler's turn") {
        let b = try Bench()
        let people = b.people()
        let id = b.note(of: [FieldFixtures.orderID], ["customer": link(people.ann, "Ann Lee")])
        expect(b.editor.beginEditing(id))
        b.down()
        let row = try b.row(id, "customer")
        guard case .links(let pills, _) = row.content else { throw Failure("a pill") }
        try b.press(at: CGPoint(x: row.valueRect.minX + pills[0].x + pills[0].width / 2, y: row.rect.midY))
        b.h.scheduler.advance(by: .zero)
        expectEqual(b.editor.editingShapeID, nil, "editing ended")
        expectEqual(b.editor.selection, people.ann, "and the note is shown")
    },
    test("a list of pointers is a row with a card: a click on a pill goes to the note, a click off the pills and Return on the focused row open the card of its lines") {
        let b = try Bench()
        let people = b.people()
        let id = b.note(of: [FieldFixtures.kindsBID], ["guests": [link(people.ann, "Ann Lee"), link(people.anders, "Anders Holm")]])
        let cards = try require(b.editor.fieldCards)
        expect(b.editor.beginEditing(id))
        b.down(); b.down()
        expectEqual(b.focused, "guests")
        b.window.pressReturn()
        expectEqual(cards.openTarget?.target, .field(FieldPath(field: "guests")), "Return on the focused row opens its card")
        expectEqual(cards.openForm?.sheet.lines.map { $0.cells[0].shown }, ["Ann Lee", "Anders Holm", ""])
        b.window.pressEscape()
        expect(cards.openTarget == nil)
        let row = try b.row(id, "guests")
        try b.press(at: CGPoint(x: row.valueRect.maxX - 4, y: row.rect.midY))
        b.h.scheduler.advance(by: .zero)
        expect(cards.openTarget != nil, "a click off the pills opens the card")
        cards.close()
        guard case .links(let pills, _) = row.content else { throw Failure("pills") }
        try b.press(at: CGPoint(x: row.valueRect.minX + pills[1].x + pills[1].width / 2, y: row.rect.midY))
        b.h.scheduler.advance(by: .zero)
        expectEqual(b.editor.selection, people.anders, "a click on a pill goes to its note")
    },
])

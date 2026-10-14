@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import TestKit
import Titles
import Types
import Validation

// The service (`editor.fieldChecks`): what it keeps and when it makes a check again, `typing`, what a type's
// change reaches, and the shapes that are not checked.

private let person = FieldFixtures.personID, order = FieldFixtures.orderID, address = FieldFixtures.addressID

@MainActor private func editor() throws -> CanvasEditor {
    let editor = try fieldEditor()
    editor.addCheckTypes([CheckFixtures.rule, CheckFixtures.shop, CheckFixtures.pricing])
    return editor
}

private func className(_ kind: FieldClass) -> String {
    switch kind {
    case .warning: "warning"
    case .needed: "needed"
    case .wrong: "wrong"
    }
}

private func summary(_ check: FieldCheck) -> [String] {
    check.problems.map { "\(className($0.kind)) \($0.path.isRoot ? "(root)" : $0.path.pointer)" }
}

private func filled(_ quantity: Double = 3) -> JSONObject {
    ["customer": "Ann Lee", "lineItems": [["product": "Mug", "quantity": .number(quantity)]]]
}

/// A type's schema written, in one step.
@MainActor private func write(_ schema: String, to type: ShapeID, in editor: CanvasEditor) {
    editor.transact("Write Schema") { $0.update(type) { $0[TypeSchemaProperty.self] = SchemaText(schema) } }
}

@MainActor let fieldChecksTests = Suite("The check's service", [
    test("one checker for each distinct list, one check for each shape that has values, none asked again") {
        let editor = try editor()
        let checks = try require(editor.fieldChecks)
        let valued = (0..<3).map { editor.addNote(of: [order], filled(Double($0 + 1))) }
        let bare = (0..<50).map { _ in editor.addNote(of: [order]) }
        let checkers = checks.checkersMade, made = checks.checksMade
        for id in valued + bare { _ = editor.fullCheck(of: id) }
        expectEqual(checks.checkersMade - checkers, 1)
        expectEqual(checks.checksMade - made, 3, "the bare ones take the list's one check of no values")
        for id in valued + bare { _ = editor.fullCheck(of: id) }
        expectEqual(checks.checksMade - made, 3, "asking again checks nothing")
        expectEqual(checks.checkersMade - checkers, 1)
        let first = editor.fullCheck(of: bare[0])
        expectEqual(first, editor.fullCheck(of: bare[1]), "an untouched note shares the list's answer")
        expectEqual(summary(first), ["needed /customer", "needed /lineItems"])
        let other = editor.addNote(of: [person])
        _ = editor.fullCheck(of: other)
        expectEqual(checks.checkersMade - checkers, 2, "another list, another checker")
    },
    test("a changed shape is checked once; an undo of a value restores the old problems") {
        let editor = try editor()
        let checks = try require(editor.fieldChecks)
        let id = editor.addNote(of: [order], filled())
        expectEqual(summary(editor.fullCheck(of: id)), [])
        let made = checks.checksMade
        editor.setFieldValues(filled(0), of: id)
        expectEqual(summary(editor.fullCheck(of: id)), ["wrong /lineItems/0/quantity"])
        _ = editor.fullCheck(of: id)
        expectEqual(checks.checksMade - made, 1)
        editor.undo()
        expectEqual(summary(editor.fullCheck(of: id)), [])
        editor.redo()
        expectEqual(summary(editor.fullCheck(of: id)), ["wrong /lineItems/0/quantity"])
    },
    test("an edit to a type that changes a rule changes every instance's answer at its next read, with the checker made once") {
        let editor = try editor()
        let checks = try require(editor.fieldChecks)
        let notes = (0..<5).map { editor.addNote(of: [order], filled(Double($0 + 1))) }
        for id in notes { expectEqual(summary(editor.fullCheck(of: id)), []) }
        let checkers = checks.checkersMade, made = checks.checksMade
        write(FieldFixtures.order.schema.replacingOccurrences(of: #""minimum": 1"#, with: #""minimum": 3"#), to: order, in: editor)
        expectEqual(notes.map { summary(editor.fullCheck(of: $0)).count }, [1, 1, 0, 0, 0])
        expectEqual(checks.checkersMade - checkers, 1)
        expectEqual(checks.checksMade - made, 5)
    },
    test("an edit that changes nothing the check reads keeps the checker and every answer: a root description, whitespace, text broken mid-edit") {
        let editor = try editor()
        let checks = try require(editor.fieldChecks)
        let notes = (0..<5).map { editor.addNote(of: [order], filled(Double($0))) }
        for id in notes { _ = editor.fullCheck(of: id) }
        let checkers = checks.checkersMade, made = checks.checksMade
        let text = FieldFixtures.order.schema
        for edited in [text.replacingOccurrences(of: #""required": ["customer", "lineItems"],"#, with: #""description": "An order", "required": ["customer", "lineItems"],"#),
                       text + "\n\n", String(text.dropLast(40)), text] {
            write(edited, to: order, in: editor)
            for id in notes { _ = editor.fullCheck(of: id) }
        }
        expectEqual(checks.checkersMade - checkers, 0)
        expectEqual(checks.checksMade - made, 0)
    },
    test("a rename of a type makes again only the answers that name it, and no other") {
        let editor = try editor()
        let checks = try require(editor.fieldChecks)
        let rule = CheckFixtures.ruleID
        let clash = editor.addNote(of: [rule], ["a": 3, "b": 4])
        let others = (0..<100).map { editor.addNote(of: [person], ["name": .string("n\($0)"), "email": .string("e\($0)@")]) }
        for id in others + [clash] { _ = editor.fullCheck(of: id) }
        let before = try require(editor.fullCheck(of: clash).problems.first { $0.path.isRoot })
        expect(before.message.hasPrefix("Exclusive rule:"))
        let made = checks.checksMade
        editor.transact("Rename") { $0.update(rule) { $0[TitleProperty.self] = "Either" } }
        for id in others { _ = editor.fullCheck(of: id) }
        expectEqual(checks.checksMade, made, "no other answer is made again")
        let after = try require(editor.fullCheck(of: clash).problems.first { $0.path.isRoot })
        expect(after.message.hasPrefix("Either rule:"), after.message)
        expectEqual(checks.checksMade - made, 1)
    },
    test("a rename reaches a note with no values whose rule across fields names its type") {
        let editor = try editor()
        let rule = CheckFixtures.ruleID
        let empty = editor.addNote(of: [rule])
        let message = { try require(editor.fullCheck(of: empty).problems.first { $0.path.isRoot }).message }
        expect(try message().hasPrefix("Exclusive rule:"), "an empty note fits both forms of the oneOf")
        editor.transact("Rename") { $0.update(rule) { $0[TitleProperty.self] = "Either" } }
        let renamed = try message()
        expect(renamed.hasPrefix("Either rule:"), renamed)
        expect(editor.issues(empty).contains { $0.message.hasPrefix("Either rule:") }, "the Issues line follows")
    },
    test("a type another type refers to reaches its notes: an edit to Address, to what a type builds on, and two refs deep") {
        let editor = try editor()
        let note = editor.addNote(of: [CheckFixtures.shopID], ["address": ["city": "Oslo"], "boss": ["name": "Bo", "email": "bo@acme.com"]])
        expectEqual(summary(editor.fullCheck(of: note)), [])
        write(FieldFixtures.address.schema.replacingOccurrences(of: #""city": { "type": "string" }"#, with: #""city": { "type": "string", "maxLength": 3 }"#), to: address, in: editor)
        expectEqual(summary(editor.fullCheck(of: note)), ["wrong /address/city"])
        write(FieldFixtures.person.schema.replacingOccurrences(of: #""format": "email""#, with: #""format": "email", "maxLength": 5"#), to: person, in: editor)
        expectEqual(summary(editor.fullCheck(of: note)), ["wrong /boss/email", "wrong /address/city"], "Employee builds on Person, which Shop refers to Employee for")
        // Two refs deep: a refers to b refers to c.
        let c = editor.addType(#"{"type": "object", "properties": {"n": {"type": "integer"}}}"#, title: "C")
        let b = editor.addType(#"{"type": "object", "properties": {"c": {"$ref": "\#(FieldFixtures.uri(of: c))"}}}"#, title: "B")
        let a = editor.addType(#"{"type": "object", "properties": {"b": {"$ref": "\#(FieldFixtures.uri(of: b))"}}}"#, title: "A")
        let deep = editor.addNote(of: [a], ["b": ["c": ["n": "x"]]])
        expectEqual(summary(editor.fullCheck(of: deep)), ["wrong /b/c/n"])
        write(#"{"type": "object", "properties": {"n": {"type": "string"}}}"#, to: c, in: editor)
        expectEqual(summary(editor.fullCheck(of: deep)), [])
    },
    test("a type deleted and undone, and a type made that a ref was waiting for, change the answers of the notes that refer") {
        let editor = try editor()
        let waiting = ShapeID()
        let holder = editor.addType(#"{"type": "object", "properties": {"x": {"$ref": "\#(FieldFixtures.uri(of: waiting))"}}}"#, title: "Holder")
        let note = editor.addNote(of: [holder], ["x": ["n": "text"]])
        expectEqual(summary(editor.fullCheck(of: note)), [], "the type it refers to is not there")
        editor.transact("Add") { $0.insert(typeRecord(#"{"type": "object", "properties": {"n": {"type": "integer"}}}"#, title: "Late", id: waiting)) }
        expectEqual(summary(editor.fullCheck(of: note)), ["wrong /x/n"], "made after the ref")
        editor.transact("Delete") { $0.delete([waiting]) }
        expectEqual(summary(editor.fullCheck(of: note)), [])
        editor.undo()
        expectEqual(summary(editor.fullCheck(of: note)), ["wrong /x/n"])
    },
    test("typing leaves its path out of check(of:), and not out of fullCheck(of:); setting it moves the revision, once") {
        let editor = try editor()
        let checks = try require(editor.fieldChecks)
        let id = editor.addNote(of: [person], ["email": "ann@"])
        let record = try require(editor.document[id])
        let email = FieldPath(field: "email")
        expectEqual(summary(checks.check(of: record)), ["needed /name", "wrong /email"])
        let before = checks.revision
        checks.typing = (id, email)
        expect(checks.revision > before)
        expectEqual(summary(checks.check(of: record)), ["needed /name"], "a half-typed value is never red")
        expectEqual(summary(checks.fullCheck(of: record)), ["needed /name", "wrong /email"])
        expectEqual(checks.typing?.path, email)
        let again = checks.revision
        checks.typing = (id, email)
        expectEqual(checks.revision, again, "the same value does nothing")
        checks.typing = nil
        expectEqual(summary(checks.check(of: record)), ["needed /name", "wrong /email"])
        checks.typing = nil
        expectEqual(checks.typing == nil, true)
    },
    test("setting typing redraws, and what clears it: the shape going, its editing ending, a board switch, a file put in place") {
        let editor = try editor()
        let checks = try require(editor.fieldChecks)
        let display = Redraws()
        editor.delegate = display
        let id = editor.addNote(of: [person], ["email": "ann@"])
        let redraws = display.count
        checks.typing = (id, FieldPath(field: "email"))
        expect(display.count > redraws, "the row is redrawn")
        editor.transact("Delete") { $0.delete([id]) }
        expectEqual(checks.typing == nil, true, "its shape went")
        let other = editor.addNote(of: [person], ["email": "ann@"])
        checks.typing = (other, FieldPath(field: "email"))
        checks.editingDidEnd(other, in: editor)
        expectEqual(checks.typing == nil, true, "its editing ended")
        let kept = checks.revision
        checks.editingDidEnd(other, in: editor)
        expectEqual(checks.revision, kept, "a net under the row's own nil")
        checks.typing = (other, FieldPath(field: "email"))
        let file = editor.file
        editor.replaceFile(with: file, showing: .root)
        expectEqual(checks.typing == nil, true, "a file put in place")
    },
    test("a note on a board not shown is answered the same, a switch and back makes no check again, a file put in place drops the answers") {
        let pocket = ShapeID(), note = ShapeID()
        var inside = instanceRecord("", of: [person], id: note)
        inside[FieldValuesProperty.self] = FieldValues(["email": "ann@"])
        let personType = typeRecord(FieldFixtures.person.schema, words: FieldFixtures.person.words, title: "Person", id: person)
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 0, y: 0, width: 100, height: 100)))), personType]),
                              children: [pocket: CanvasDocument(shapes: [inside])])
        let editor = try typeEditor(file: file, more: [PocketsPlugin()])
        let checks = try require(editor.fieldChecks)
        expectEqual(summary(editor.fullCheck(of: note)), ["needed /name", "wrong /email"], "its board was never shown")
        let made = checks.checksMade
        expect(editor.showBoard(BoardID(owner: pocket)))
        expectEqual(summary(editor.fullCheck(of: note)), ["needed /name", "wrong /email"])
        expect(editor.showBoard(.root))
        expectEqual(summary(editor.fullCheck(of: note)), ["needed /name", "wrong /email"])
        expectEqual(checks.checksMade, made, "a switch alone keeps every answer")
        editor.replaceFile(with: file, showing: .root)
        expectEqual(summary(editor.fullCheck(of: note)), ["needed /name", "wrong /email"])
        expect(checks.checksMade > made, "the answers were dropped with the old file")
    },
    test("a board switch with a field being typed in checks its shape again: taken back, the wrong value rings") {
        let pocket = ShapeID(), note = ShapeID()
        var inside = instanceRecord("", of: [person], id: note)
        inside[FieldValuesProperty.self] = FieldValues(["name": "A", "email": "ann@"])
        let personType = typeRecord(FieldFixtures.person.schema, words: FieldFixtures.person.words, title: "Person", id: person)
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 0, y: 0, width: 100, height: 100)))), personType]),
                              children: [pocket: CanvasDocument(shapes: [inside])])
        let editor = try typeEditor(file: file, more: [PocketsPlugin()])
        let checks = try require(editor.fieldChecks)
        expect(editor.showBoard(BoardID(owner: pocket)))
        expectEqual(editor.issues(note).count, 1)
        checks.typing = (note, FieldPath(field: "email"))
        expectEqual(editor.issues(note), [], "the half-typed value is not red")
        expect(editor.showBoard(.root))
        expect(checks.typing == nil, "a switch clears it")
        expect(editor.showBoard(BoardID(owner: pocket)))
        expectEqual(editor.issues(note).count, 1, "the answer kept with the board was made with the path left out")
    },
    test("a commit that only moves shapes reads no record and checks nothing") {
        let editor = try editor()
        let checks = try require(editor.fieldChecks)
        let ids = (0..<20).map { editor.addNote(of: [order], filled(Double($0))) }
        for id in ids { _ = editor.fullCheck(of: id) }
        let made = checks.checksMade, read = try require(editor.types).recordsRead, revision = checks.revision
        editor.transact("Drag") { transaction in
            for (place, id) in ids.enumerated() { transaction.moveBox(id, to: CGPoint(x: 500 + place * 10, y: 900)) }
        }
        for id in ids { _ = editor.fullCheck(of: id) }
        expectEqual(checks.checksMade, made)
        expectEqual(try require(editor.types).recordsRead, read)
        expectEqual(checks.revision, revision, "a move changes no answer")
    },
    test("a change to a note with an answer moves the revision, and one to a note nobody asked of does not") {
        let editor = try editor()
        let checks = try require(editor.fieldChecks)
        let asked = editor.addNote(of: [person], ["name": "A"]), unasked = editor.addNote(of: [person], ["name": "B"])
        _ = editor.fullCheck(of: asked)
        let before = checks.revision
        editor.setFieldValues(["name": "C"], of: unasked)
        expectEqual(checks.revision, before)
        editor.setFieldValues(["name": "D"], of: asked)
        expect(checks.revision > before)
    },
    test("a type edit moves the revision; a rename does too") {
        let editor = try editor()
        let checks = try require(editor.fieldChecks)
        let before = checks.revision
        write(FieldFixtures.address.schema + " ", to: address, in: editor)
        expect(checks.revision > before)
        let again = checks.revision
        editor.transact("Rename") { $0.update(address) { $0[TitleProperty.self] = "Place" } }
        expect(checks.revision > again)
    },
    test("a shape that is a type, an opaque shape, one with no types and an editor without Types ask no checker") {
        let editor = try editor()
        let checks = try require(editor.fieldChecks)
        let made = checks.checkersMade
        _ = checks.fullCheck(of: try require(editor.document[order]))
        let plain = editor.addInstance("plain", of: [])
        _ = checks.fullCheck(of: try require(editor.document[plain]))
        expectEqual(checks.checkersMade, made)
    },
])

private final class Redraws: CanvasEditorDelegate {
    var count = 0
    func editorNeedsDisplay(_ editor: CanvasEditor) { count += 1 }
    func editorCursorDidChange(_ editor: CanvasEditor) {}
    func editorEditingDidChange(_ editor: CanvasEditor) {}
}

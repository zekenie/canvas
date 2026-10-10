@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import SwiftUI
import TableOfContents
import TestKit
import Types
import Validation

// The check as Validation's rules: a wrong value is an error (the ring, the Issues tab, the table of
// contents' dot, `:invalid`), a needed one is none; a type that refers to a gone type carries a warning.

private let person = FieldFixtures.personID, order = FieldFixtures.orderID, address = FieldFixtures.addressID
private let email = FieldPath(field: "email")

/// Counts the shapes the engine asks every rule of.
@MainActor private final class Probe {
    var asked: [ShapeID] = []
}

private struct ProbePlugin: CanvasPlugin {
    let probe: Probe
    var id: PluginID { "probe" }
    func register(into registrar: inout PluginRegistrar) {
        let probe = probe
        registrar.validateEveryShape { shape, _ in
            probe.asked.append(shape.id)
            return []
        }
    }
}

@MainActor private func editor(more: [any CanvasPlugin] = []) throws -> CanvasEditor {
    let editor = try fieldEditor(more: more)
    editor.addCheckTypes([CheckFixtures.rule])
    return editor
}

@MainActor private func messages(_ editor: CanvasEditor, _ id: ShapeID, _ severity: Severity? = nil) -> [String] {
    editor.issues(id).filter { severity == nil || $0.severity == severity }.map(\.message)
}

@MainActor let fieldRuleTests = Suite("The check as rules", [
    test("a wrong value is one error with the problem's words, at its row; a needed one is none, and rings nothing") {
        let editor = try editor()
        let fresh = editor.addNote(of: [order])
        expectEqual(editor.issues(fresh), [], "a fresh Order is needed, not wrong")
        expect(editor.validation?.result(for: fresh) == nil, "no result, so no ring")
        let wrong = editor.addNote(of: [person], ["email": "ann@"])
        let issues = editor.issues(wrong)
        expectEqual(issues.map(\.message), [#"email should be an email address, not "ann@""#])
        expectEqual(issues.map(\.severity), [.error])
        expectEqual(issues.map(\.field), ["email"])
        expectEqual(editor.validation?.result(for: wrong)?.isValid, false)
    },
    test("both: the error is there, and the note is still incomplete") {
        let editor = try editor()
        let id = editor.addNote(of: [person], ["email": "ann@"])
        expectEqual(messages(editor, id).count, 1, "the missing name makes no issue")
        expect(try require(editor.fieldChecks).fullCheck(of: try require(editor.document[id])).isIncomplete)
    },
    test("a rule across fields is an error with no field") {
        let editor = try editor()
        let id = editor.addNote(of: [CheckFixtures.ruleID], ["a": 3, "b": 4])
        let issues = editor.issues(id)
        expect(issues.contains { $0.field == nil && $0.message.hasPrefix("Exclusive rule: the note ") && $0.severity == .error }, "\(issues)")
    },
    test("a value written in the card is checked with the commit, an undo restores the old issues") {
        let editor = try editor()
        let id = editor.addNote(of: [person], ["name": "A"])
        expectEqual(editor.issues(id), [])
        try require(editor.fieldWriter).set("ann@", at: email, of: id)
        expectEqual(messages(editor, id), [#"email should be an email address, not "ann@""#])
        editor.undo()
        expectEqual(editor.issues(id), [])
    },
    test("a drag of typed notes rereads nothing") {
        let editor = try editor()
        let checks = try require(editor.fieldChecks)
        let ids = (0..<10).map { _ in editor.addNote(of: [person], ["email": "ann@"]) }
        _ = editor.validation?.results
        let made = checks.checksMade
        editor.transact("Drag") { transaction in
            for (place, id) in ids.enumerated() { transaction.moveBox(id, to: CGPoint(x: 600 + place * 10, y: 900)) }
        }
        _ = editor.validation?.results
        expectEqual(checks.checksMade, made)
        expectEqual(ids.filter { !messages(editor, $0).isEmpty }.count, 10, "the issues stand")
    },
    test("the field being typed in is no issue until the caret leaves: no commit, the error is there") {
        let editor = try editor()
        let checks = try require(editor.fieldChecks)
        let id = editor.addNote(of: [person], ["name": "A", "email": "bo@"])
        expectEqual(messages(editor, id).count, 1)
        checks.typing = (id, email)
        expectEqual(editor.issues(id), [], "never red while it is typed in")
        let revision = editor.revision
        checks.typing = nil
        expectEqual(editor.revision, revision, "no commit")
        expectEqual(messages(editor, id).count, 1)
        checks.typing = (id, email)
        editor.setFieldValues(["name": "A", "email": "bo@acme.com"], of: id)
        checks.typing = nil
        expectEqual(editor.issues(id), [])
    },
    test("the table of contents' dot follows: red for a wrong value, none for a needed one, none while it is typed, red when the caret leaves") {
        let editor = try editor(more: [ValidationContentsPlugin()])
        let checks = try require(editor.fieldChecks)
        let contents = try require(editor.tableOfContents)
        @MainActor func marks(_ id: ShapeID) throws -> [ContentsMark] {
            let row = try require(contents.entries.first { $0.id == id }, "no row for \(id)")
            return row.marks
        }
        let needed = editor.addNote(of: [person])
        let wrong = editor.addNote(of: [person], ["name": "A", "email": "ann@"])
        expectEqual(try marks(needed), [])
        expectEqual(try marks(wrong).map(\.color), [Color(nsColor: Severity.error.color)])
        checks.typing = (wrong, email)
        expectEqual(try marks(wrong), [], "typing in it")
        checks.typing = nil
        expectEqual(try marks(wrong).map(\.color), [Color(nsColor: Severity.error.color)], "the caret left")
    },
    test("Validation reads what the type edit reaches: the type, its notes, the types that refer to it, and nothing else") {
        let probe = Probe()
        let editor = try editor(more: [ProbePlugin(probe: probe)])
        editor.addCheckTypes([CheckFixtures.shop])
        let ann = editor.addNote(of: [person], ["name": "A"]), place = editor.addNote(of: [address], ["city": "Oslo"])
        let shop = editor.addNote(of: [CheckFixtures.shopID], ["address": ["city": "Oslo"]]), purchase = editor.addNote(of: [order])
        _ = editor.validation?.results
        probe.asked = []
        editor.transact("Write Schema") { $0.update(address) { $0[TypeSchemaProperty.self] = SchemaText(FieldFixtures.address.schema + " ") } }
        _ = editor.validation?.results
        let asked = Set(probe.asked)
        for reached in [address, place, order, purchase, CheckFixtures.shopID, shop] { expect(asked.contains(reached), "\(reached) is asked again") }
        for other in [person, ann] { expect(!asked.contains(other), "\(other) is not") }
    },
    test("a type deleted warns the type that refers to it, by name, and no note; undoing the delete clears it") {
        let editor = try editor()
        let note = editor.addNote(of: [order])
        expectEqual(editor.issues(order), [], "Order, whose shipping Address and customer Person are both there")
        editor.transact("Delete") { $0.delete([address]) }
        expectEqual(messages(editor, order), ["Refers to “Address”, which is gone."])
        expectEqual(editor.issues(order).map(\.severity), [.warning])
        expectEqual(editor.issues(order).map(\.field), ["schema"])
        expectEqual(editor.issues(note), [], "an instance is never warned")
        editor.transact("Delete") { $0.delete([person]) }
        expectEqual(messages(editor, order), ["Refers to “Address”, which is gone.", "Refers to “Person”, which is gone."])
        editor.undo()
        editor.undo()
        expectEqual(editor.issues(order), [])
    },
    test("a type whose JSON names an id that was never a shape reads `a type that is gone`; an Order's instance is never warned") {
        let editor = try editor()
        let ghost = ShapeID()
        let holder = editor.addType(#"{"type": "object", "properties": {"x": {"$ref": "\#(FieldFixtures.uri(of: ghost))"}}}"#, title: "Holder")
        expectEqual(messages(editor, holder), ["Refers to a type that is gone."])
        let note = editor.addNote(of: [holder], ["x": ["n": 1]])
        expectEqual(editor.issues(note), [])
    },
    test("a type made that a type was waiting for clears its warning") {
        let editor = try editor()
        let late = ShapeID()
        let holder = editor.addType(#"{"type": "object", "properties": {"x": {"$ref": "\#(FieldFixtures.uri(of: late))"}}}"#, title: "Holder")
        expectEqual(messages(editor, holder).count, 1)
        editor.transact("Add") { $0.insert(typeRecord(#"{"type": "object"}"#, title: "Late", id: late)) }
        expectEqual(editor.issues(holder), [])
    },
    test("draw's check lends no editor: the rules find no service and say nothing") {
        let editor = try editor()
        let id = editor.addNote(of: [person], ["email": "ann@"])
        let record = try require(editor.document[id])
        expectEqual(editor.registry.validationIssues(of: record, in: editor.shapeContext).filter { $0.field == "email" }, [])
        expectEqual(editor.registry.validationIssues(of: record, in: editor.shapeContext, editor: editor).filter { $0.field == "email" }.count, 1)
    },
])

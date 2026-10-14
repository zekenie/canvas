@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import SwiftUI
import TableOfContents
import TestKit
import Titles
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
    test("a wrong value is one error with the problem's words, at its row; a needed one is an issue of the third level, valid and ringing nothing") {
        let editor = try editor()
        let fresh = editor.addNote(of: [order])
        expectEqual(editor.issues(fresh).map(\.message), ["customer is needed", "line items is needed"], "a fresh Order is needed, not wrong")
        expectEqual(editor.issues(fresh).map(\.severity), [.incomplete, .incomplete])
        expectEqual(editor.issues(fresh).map(\.field), ["customer", "lineItems"])
        expectEqual(editor.validation?.result(for: fresh)?.isValid, true)
        expectEqual(editor.validation?.result(for: fresh)?.worst, nil, "nothing shows, so no ring")
        let wrong = editor.addNote(of: [person], ["email": "ann@"])
        let issues = editor.issues(wrong)
        expectEqual(issues.map(\.message), ["name is needed", #"email should be an email address, not "ann@""#])
        expectEqual(issues.map(\.severity), [.incomplete, .error])
        expectEqual(issues.map(\.field), ["name", "email"])
        expectEqual(editor.validation?.result(for: wrong)?.isValid, false)
        expectEqual(editor.validation?.result(for: wrong)?.worstFirst.map(\.severity), [.error], "and only the error shows")
    },
    test("both: the error is there, and the note is still incomplete, in Validation's words and the check's") {
        let editor = try editor()
        let id = editor.addNote(of: [person], ["email": "ann@"])
        expectEqual(messages(editor, id).count, 2, "the missing name is the third level, beside the error")
        expectEqual(messages(editor, id, .incomplete), ["name is needed"])
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
        editor.transact("Write Schema") { $0.update(address) { $0[TypeSchemaProperty.self] = SchemaText(FieldFixtures.address.schema.replacingOccurrences(of: #""city": { "type": "string" }"#, with: #""city": { "type": "string", "maxLength": 3 }"#)) } }
        _ = editor.validation?.results
        let asked = Set(probe.asked)
        for reached in [address, place, order, purchase, CheckFixtures.shopID, shop] { expect(asked.contains(reached), "\(reached) is asked again") }
        for other in [person, ann] { expect(!asked.contains(other), "\(other) is not") }
    },
    test("an edit that changes nothing the check reads asks the types it reaches and not their notes, and a note whose answer names a type still follows") {
        let probe = Probe()
        let editor = try editor(more: [ProbePlugin(probe: probe)])
        editor.addCheckTypes([CheckFixtures.shop])
        let checks = try require(editor.fieldChecks)
        let place = editor.addNote(of: [address], ["city": "Oslo"]), purchase = editor.addNote(of: [order]), shop = editor.addNote(of: [CheckFixtures.shopID], ["address": ["city": "Oslo"]])
        let clash = editor.addNote(of: [CheckFixtures.ruleID], ["a": 3, "b": 4])
        _ = editor.validation?.results
        let made = checks.checksMade
        probe.asked = []
        editor.transact("Write Schema") { $0.update(address) { $0[TypeSchemaProperty.self] = SchemaText(FieldFixtures.address.schema + " ") } }
        _ = editor.validation?.results
        let asked = Set(probe.asked)
        for reached in [address, order, CheckFixtures.shopID] { expect(asked.contains(reached), "\(reached) is asked again") }
        for kept in [place, purchase, shop, clash] { expect(!asked.contains(kept), "\(kept) keeps its answer") }
        expectEqual(checks.checksMade, made)
        editor.transact("Rename") { $0.update(CheckFixtures.ruleID) { $0[TitleProperty.self] = "Either" } }
        _ = editor.validation?.results
        expect(messages(editor, clash).contains { $0.hasPrefix("Either rule:") }, "\(messages(editor, clash))")
    },
    test("a type deleted warns the type that refers to it, by name, and no note; undoing the delete clears it") {
        let editor = try editor()
        let note = editor.addNote(of: [order])
        expectEqual(editor.issues(order), [], "Order, whose shipping Address is there")
        editor.transact("Delete") { $0.delete([address]) }
        expectEqual(messages(editor, order), ["Refers to “Address”, which is gone."])
        expectEqual(editor.issues(order).map(\.severity), [.warning])
        expectEqual(editor.issues(order).map(\.field), ["schema"])
        expectEqual(editor.issues(note).map(\.severity), [.incomplete, .incomplete], "an instance is never warned: it still needs what it did")
        editor.transact("Delete") { $0.delete([person]) }
        expectEqual(messages(editor, order), ["Refers to “Address”, which is gone."], "Person is not Order's to refer to: its customer is text")
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
    test("draw's check lends no editor: the rules ask the service through the reading their shapes have, and a plain context says nothing") {
        let editor = try editor()
        let id = editor.addNote(of: [person], ["email": "ann@"])
        let record = try require(editor.document[id])
        let plain = ShapeContext(document: editor.document, registry: editor.registry)
        expectEqual(editor.registry.validationIssues(of: record, in: plain).filter { $0.field == "email" }, [], "a context that lays nothing out")
        let read = editor.registry.validationIssues(of: record, in: editor.shapeContext).filter { $0.field == "email" }
        expectEqual(read.map(\.path), ["/email"], "the editor's reading, with where in the value")
        expectEqual(editor.registry.validationIssues(of: record, in: editor.shapeContext, editor: editor).filter { $0.field == "email" }.count, 1)
    },
])

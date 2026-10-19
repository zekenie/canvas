@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Foundation
import TestKit
import Titles
import Types
import Validation

// The check of a run (`FieldChecks.check(of:reading:)`): a shape's values against its types as a
// transaction leaves them, which a draw's script, a paste and a duplicate write together.

private let person = FieldFixtures.personID, order = FieldFixtures.orderID, address = FieldFixtures.addressID

private func summary(_ check: FieldCheck) -> [String] {
    check.problems.map { "\($0.kind.word) \($0.path.isRoot ? "(root)" : $0.path.pointer)" }
}

private func filled(_ quantity: Double = 3) -> JSONObject {
    ["customer": "Ann Lee", "lineItems": [["product": "Mug", "quantity": .number(quantity)]]]
}

/// A note of `types` holding `values`, not in any file.
@MainActor private func note(of types: [ShapeID], _ values: JSONObject = [:], id: ShapeID = ShapeID()) -> AnyShapeRecord {
    var record = instanceRecord(of: types, id: id)
    if !values.isEmpty { record[FieldValuesProperty.self] = FieldValues(values) }
    return record
}

/// What `body` gets of the editor's check, asked of a transaction's reading.
@MainActor private func inTransaction<T>(_ editor: CanvasEditor, _ body: (inout Transaction, FieldChecks, LayoutReading) throws -> T) throws -> T? {
    var result: T?
    var failure: Error?
    editor.transact("Check") { transaction in
        guard let checks = editor.fieldChecks, let reading = transaction.shapes.reading else { return }
        do { result = try body(&transaction, checks, reading) } catch { failure = error }
    }
    if let failure { throw failure }
    return result
}

@MainActor let fieldChecksReadingTests = Suite("The check of a run", [
    test("a note whose values changed, over types the transaction left as they were, is checked by the kept checker, and nothing is kept for it") {
        let editor = try fieldEditor()
        let checks = try require(editor.fieldChecks)
        let id = editor.addNote(of: [order], filled())
        _ = editor.fullCheck(of: id)
        let checkers = checks.checkersMade, scratch = checks.scratchMade, made = checks.checksMade
        var wrong = try require(editor.document[id])
        wrong[FieldValuesProperty.self] = FieldValues(filled(0))
        let seen = try require(inTransaction(editor) { transaction, checks, reading in
            transaction.update(id) { $0[FieldValuesProperty.self] = FieldValues(filled(0)) }
            return (summary(checks.check(of: wrong, reading: transaction.shapes.reading ?? reading)), summary(checks.check(of: wrong, reading: reading)))
        })
        expectEqual(seen.0, ["wrong /lineItems/0/quantity"])
        expectEqual(seen.1, seen.0)
        expectEqual(checks.checkersMade, checkers, "no checker was made")
        expectEqual(checks.scratchMade, scratch, "nor one over the reading")
        expectEqual(checks.checksMade - made, 2, "and nothing was kept: each ask checked the values")
        expectEqual(summary(editor.fullCheck(of: id)), ["wrong /lineItems/0/quantity"], "the commit's own answer is the same")
    },
    test("a type and its instance inserted in one transaction: the instance's needed and wrong are found, as the commit finds them") {
        let editor = try typeEditor()
        let checks = try require(editor.fieldChecks)
        let type = typeRecord(FieldFixtures.person.schema, title: "Person")
        let bare = note(of: [type.id])
        let wrong = note(of: [type.id], ["name": "n", "email": "no"])
        let found = try require(inTransaction(editor) { transaction, checks, _ in
            transaction.insert(type)
            transaction.insert(bare)
            transaction.insert(wrong)
            let reading = try require(transaction.shapes.reading)
            return [summary(checks.check(of: bare, reading: reading)), summary(checks.check(of: wrong, reading: reading))]
        })
        expectEqual(found, [["needed /name"], ["wrong /email"]])
        expectEqual(checks.scratchMade, 1, "one checker for the list")
        expectEqual([bare, wrong].map { summary(editor.fullCheck(of: $0.id)) }, found, "after the commit the same")
    },
    test("a type's schema changed in the transaction is read as it stands: a field made required, and a type it refers to changed") {
        let editor = try fieldEditor()
        let id = editor.addNote(of: [order], filled())
        let ann = editor.addNote(of: [person], ["name": "Ann"])
        let withAddress = editor.addNote(of: [order], filled().merging(["shippingAddress": ["street": "High St"]]) { $1 })
        expectEqual(summary(editor.fullCheck(of: id)), [])
        expectEqual(summary(editor.fullCheck(of: ann)), [])
        let personText = FieldFixtures.person.schema.replacingOccurrences(of: #""required": ["name"]"#, with: #""required": ["name", "email"]"#)
        let addressText = FieldFixtures.address.schema.replacingOccurrences(of: #""street": { "type": "string" }"#, with: #""street": { "type": "string", "minLength": 20 }"#)
        let seen = try require(inTransaction(editor) { transaction, checks, _ in
            transaction.update(person) { $0[TypeSchemaProperty.self] = SchemaText(personText) }
            transaction.update(address) { $0[TypeSchemaProperty.self] = SchemaText(addressText) }
            let reading = try require(transaction.shapes.reading)
            return [summary(checks.check(of: try require(transaction.shapes.shape(ann)), reading: reading)),
                    summary(checks.check(of: try require(transaction.shapes.shape(withAddress)), reading: reading)),
                    summary(checks.check(of: try require(transaction.shapes.shape(id)), reading: reading))]
        })
        expectEqual(seen, [["needed /email"], ["wrong /shippingAddress/street"], []],
                    "the note of the changed type, the one whose Address changed, and an Order that holds neither")
        expectEqual(summary(editor.fullCheck(of: ann)), ["needed /email"], "the commit reads them the same")
    },
    test("a checker over a reading is made once for the instances of one list, and let go by the commit") {
        let editor = try fieldEditor()
        let checks = try require(editor.fieldChecks)
        let notes = (0..<100).map { _ in note(of: [person], ["name": "n"]) }
        let personText = FieldFixtures.person.schema.replacingOccurrences(of: #""required": ["name"]"#, with: #""required": ["name", "email"]"#)
        // Each run writes the type's text a little differently, so each is a change.
        @MainActor func run(_ spaces: Int, _ body: (inout Transaction, FieldChecks, LayoutReading) throws -> Void = { _, _, _ in }) throws {
            _ = try inTransaction(editor) { transaction, checks, reading in
                transaction.update(person) { $0[TypeSchemaProperty.self] = SchemaText(personText + String(repeating: " ", count: spaces)) }
                try body(&transaction, checks, try require(transaction.shapes.reading))
            }
        }
        var found: [[String]] = []
        try run(1) { _, checks, reading in found = notes.map { summary(checks.check(of: $0, reading: reading)) } }
        expectEqual(found, Array(repeating: ["needed /email"], count: 100))
        expectEqual(checks.scratchMade, 1, "one for a hundred")
        try run(2) { _, checks, reading in _ = checks.check(of: notes[0], reading: reading) }
        expectEqual(checks.scratchMade, 2, "the first run's checker went with its commit")
        try run(3) { _, checks, reading in _ = (checks.check(of: notes[0], reading: reading), checks.check(of: notes[1], reading: reading)) }
        expectEqual(checks.scratchMade, 3)
        // A title is part of what a checker is made from: a rule across fields says its type's name.
        try run(4) { transaction, checks, reading in
            _ = checks.check(of: notes[0], reading: reading)
            expectEqual(checks.scratchMade, 4)
            transaction.update(person) { $0[TitleProperty.self] = "Somebody" }
            _ = checks.check(of: notes[0], reading: try require(transaction.shapes.reading))
        }
        expectEqual(checks.scratchMade, 5, "a rename makes it again")
    },
    test("a shape the transaction only moved reads the kept answer, and a restated note under unchanged types too") {
        let editor = try fieldEditor()
        let checks = try require(editor.fieldChecks)
        let id = editor.addNote(of: [order], filled(0))
        _ = editor.fullCheck(of: id)
        let made = checks.checksMade, checkers = checks.checkersMade
        let seen = try require(inTransaction(editor) { transaction, checks, _ in
            transaction.moveBox(id, to: CGPoint(x: 500, y: 500))
            let moved = try require(transaction.shapes.shape(id))
            let reading = try require(transaction.shapes.reading)
            return summary(checks.check(of: moved, reading: reading))
        })
        expectEqual(seen, ["wrong /lineItems/0/quantity"])
        expectEqual(checks.checksMade, made, "nothing was checked: the answer is the kept one")
        expectEqual(checks.checkersMade, checkers)
    },
    test("a type deleted in the transaction leaves its instance's check as a gone type's: nothing, never the committed answer") {
        let editor = try fieldEditor()
        let id = editor.addNote(of: [person])
        expectEqual(summary(editor.fullCheck(of: id)), ["needed /name"])
        let seen = try require(inTransaction(editor) { transaction, checks, _ in
            transaction.delete([person])
            let reading = try require(transaction.shapes.reading)
            return summary(checks.check(of: try require(transaction.shapes.shape(id)), reading: reading))
        })
        expectEqual(seen, [])
        expectEqual(summary(editor.fullCheck(of: id)), [], "after the commit too")
    },
    test("a type's own note is clean, a note of no type is clean, and a plain context has no reading to ask with") {
        let editor = try fieldEditor()
        let seen = try require(inTransaction(editor) { transaction, checks, reading in
            let own = try require(transaction.shapes.shape(person))
            return [checks.check(of: own, reading: reading).problems.count, checks.check(of: note(of: []), reading: reading).problems.count]
        })
        expectEqual(seen, [0, 0])
        expect(ShapeContext(document: editor.document, registry: editor.registry).reading == nil)
    },
    test("Validation's rule says a wrong value of a run without an editor, with the path, and a needed one as the third level") {
        let editor = try fieldEditor()
        let wrong = note(of: [order], filled(0))
        let bare = note(of: [order])
        let seen = try require(inTransaction(editor) { transaction, _, _ in
            transaction.insert(wrong)
            transaction.insert(bare)
            let shapes = transaction.shapes
            return [wrong, bare].map { editor.registry.validationIssues(of: $0, in: shapes).filter { $0.field != nil } }
        })
        expectEqual(seen[0].map(\.field), ["lineItems"])
        expectEqual(seen[0].map(\.path), ["/lineItems/0/quantity"])
        expectEqual(seen[0].map(\.severity), [.error])
        expectEqual(seen[1].map(\.severity), [.incomplete, .incomplete], "needed is the third level, not a warning")
        expectEqual(seen[1].map(\.field), ["customer", "lineItems"])
    },

    test("the members of a written object no field names: a typo at the top, in another type's fields, in a list's item and in a group; none under what a type doesn't say") {
        let editor = try fieldEditor()
        editor.addFieldTypes([FieldFixtures.everyKind.a, FieldFixtures.everyKind.b])
        let book = try require(editor.fieldBook)
        @MainActor func unnamed(_ written: JSONObject, _ types: [ShapeID] = [order]) -> [String] {
            book.unnamed(in: written, types: types).map { "\($0.path.pointer) in \($0.within ?? "-")" }
        }
        expectEqual(unnamed(["emial": "x", "customer": "c"]), ["/emial in -"], "a top-level typo")
        expectEqual(unnamed(["shippingAddress": ["street": "High St", "zip": "LS1"]]), ["/shippingAddress/zip in shipping address"], "another type's fields, by the row's name")
        expectEqual(unnamed(["lineItems": [["product": "Mug", "quantity": 1], ["product": "Pen", "sku": "x", "weight": 2]]]),
                    ["/lineItems/1/sku in line items", "/lineItems/1/weight in line items"], "in a list's item, each")
        expectEqual(unnamed(["venue": ["name": "n", "street": "s"]], [FieldFixtures.kindsAID]), ["/venue/street in venue"], "in a group")
        expectEqual(unnamed(["b": 1, "a": 1, "$title": "x"]), ["/$title in -", "/a in -", "/b in -"].map { $0.replacingOccurrences(of: "/$title", with: "/$title") }, "in key order, and a $-key is no field")
        expectEqual(unnamed(["emial": ["deep": 1]]), ["/emial in -"], "a member under an unnamed one is not listed twice")
        expectEqual(unnamed(["emial": .null, "status": .null]), [], "a member written null clears: never one")
        let kindsB = FieldFixtures.kindsBID
        expectEqual(unnamed(["labels": ["anything": "goes"], "anything": ["any": "thing"], "size": ["x": 1], "customer": ["x": 1], "payment": ["bogus": 1], "count": ["x": 1]], [kindsB]), [],
                    "not into pairs, Other, an either or a plain value")
        // A reference to a type that is gone reads as nothing the book can say.
        let gone = ShapeID()
        let holder = editor.addType(#"{"type": "object", "properties": {"x": {"$ref": "\#(FieldFixtures.uri(of: gone))"}}}"#, title: "Holder")
        expectEqual(unnamed(["x": ["n": 1], "y": 1], [holder]), ["/y in -"], "nothing under a reference to a gone type")
    },
    test("drawn: the check, the members no field names, the types' titles in the list's order; none while a type is gone or for a shape with none") {
        let editor = try fieldEditor()
        let checks = try require(editor.fieldChecks)
        editor.transact("Untitle") { $0.update(address) { $0[TitleProperty.self] = nil } }
        let both = note(of: [order, address], filled(0).merging(["emial": "x"]) { $1 })
        let seen = try require(inTransaction(editor) { transaction, checks, reading in
            transaction.insert(both)
            let drawn = checks.drawn(both, written: ["emial": "x", "lineItems": [["product": "Mug"]]], reading: try require(transaction.shapes.reading))
            return (drawn.typeNames, drawn.unnamed.map(\.path.pointer), summary(drawn.check))
        })
        expectEqual(seen.0, ["Order", "Untitled"], "in the list's order, an untitled type as Untitled")
        expectEqual(seen.1, ["/emial"])
        expect(seen.2.contains("wrong /lineItems/0/quantity"), "\(seen.2)")
        let ann = note(of: [person])
        let gone = note(of: [person, ShapeID()])
        let none = note(of: [])
        let kinds = try require(inTransaction(editor) { transaction, checks, reading in
            [ann, gone, none].forEach { transaction.insert($0) }
            let reading = try require(transaction.shapes.reading)
            return [ann, gone, none].map { checks.drawn($0, written: ["nope": 1], reading: reading) }.map { ($0.unnamed.count, $0.typeNames.count) }
        })
        expectEqual(kinds.map { "\($0.0),\($0.1)" }, ["1,1", "0,2", "0,0"], "a gone type: the values are kept, unchecked, and no key is called unnamed")
        let unchanged = try require(inTransaction(editor) { _, checks, reading in checks.drawn(both, written: nil, reading: reading) })
        expectEqual(unchanged.unnamed.count, 0, "nothing was written, so nothing is warned about")
        _ = checks
    },
])

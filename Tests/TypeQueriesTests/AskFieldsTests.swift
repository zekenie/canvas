import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Foundation
import Queries
import TestKit
import Titles
import Types

// What `--ask` is told of the file's types, under `<fields>` (Types' `TypeQueriesPlugin`, from its
// `FileFields`): the fact a translator is given, for the file of Order, Person and Employee.

private func typeNote(_ text: FieldFixtures.TypeText, at y: Double, buildingOn parents: [ShapeID] = []) -> AnyShapeRecord {
    var record = AnyShapeRecord(ShapeRecord(id: text.id, Memo(frame: CGRect(x: 40, y: y, width: 240, height: 52))))
    record[TitleProperty.self] = text.title
    record[TypeSchemaProperty.self] = SchemaText(text.schema)
    if !parents.isEmpty { record[IsAProperty.self] = parents.map(TypeLink.init) }
    return record
}

@MainActor private func fact(_ editor: CanvasEditor, _ question: String) throws -> String? {
    let facts = editor.registry.contributions(to: QueryAskFacts.self).map(\.value).filter { $0.tag == "fields" }
    return facts.first.map { $0.text(for: editor, question: question) }
}

@MainActor let askFieldsTests = Suite("--ask's fields", [
    test("the fields fact of a file of Order, Person and Employee: a line for each type, the types the question names first") {
        let employee = FieldFixtures.employee
        var bo = memo(3, "Bo")
        bo[IsAProperty.self] = [TypeLink(FieldFixtures.employeeID)]
        let h = try EditorHarness(plugins: typeQueryPlugins(), document: CanvasDocument(shapes: [
            typeNote(FieldFixtures.order, at: 40), typeNote(FieldFixtures.person, at: 140), typeNote(employee, at: 240, buildingOn: [FieldFixtures.personID]),
            typeNote(FieldFixtures.address, at: 340), bo,
        ]))
        let text = try require(try fact(h.editor, "when do people start?"))
        expectEqual(text, """
            Employee builds on Person: role (text), startDate (date)
            Person: name (text), email (text)
            Address: street (text), city (text), postcode (text)
            Order: customer (text), shippingAddress (fields of Address), lineItems (list) {product (text), quantity (whole number), price (number)}, status (draft|paid|shipped), tags (list of text), gift (yes/no), giftNote (text)
            """, "Employee shares a word with the question (start); Person has one note that is one, Bo, through Employee; then by title")
        expectEqual(try fact(h.editor, "orders"), """
            Order: customer (text), shippingAddress (fields of Address), lineItems (list) {product (text), quantity (whole number), price (number)}, status (draft|paid|shipped), tags (list of text), gift (yes/no), giftNote (text)
            Employee builds on Person: role (text), startDate (date)
            Person: name (text), email (text)
            Address: street (text), city (text), postcode (text)
            """, "Employee and Person have one note each, Bo, by title; Employee's own note is no Person")
    },
    test("a file with no types has no fields block, and one that holds no values never says any") {
        let none = try EditorHarness(plugins: typeQueryPlugins(), document: CanvasDocument(shapes: [memo(1, "Plain")]))
        expectEqual(try fact(none.editor, "anything"), "")
        var filled = memo(2, "Order 2")
        filled[IsAProperty.self] = [TypeLink(FieldFixtures.orderID)]
        filled[FieldValuesProperty.self] = FieldValues(["customer": "Secret Customer", "status": "paid"])
        let h = try EditorHarness(plugins: typeQueryPlugins(), document: CanvasDocument(shapes: [typeNote(FieldFixtures.order, at: 40), filled]))
        let text = try require(try fact(h.editor, "paid orders"))
        expect(!text.contains("Secret Customer"), "never a value")
        expect(text.hasPrefix("Order: customer (text)"), text)
    },
    test("without the plugin there is no fact") {
        let h = try EditorHarness(plugins: typeQueryPlugins(typeWords: false), document: CanvasDocument(shapes: [typeNote(FieldFixtures.order, at: 40)]))
        expectEqual(try fact(h.editor, "orders"), nil)
    },
])

import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Foundation
import Queries
import QueryLanguage
import TestKit
import Titles
import Types

// `:is-a(S)` made to hold of a shape (`makes:`, which `QueryState.fit` calls, so a shape made where only shapes of a type are
// accepted comes out one): over the memos of Fixtures.swift. Person 1, Employee card 2 (a Person), Ann 3 (an Employee card),
// Bob 4 (a Person), Cy 5, Dot 6 (no type), Alpha 7 and Beta 8 (each the other's), Eve 9, and Plain 10, a memo that is no type.

/// A memo made to be written on, numbered past the fixtures, with the types it is.
private func newMemo(_ n: Int = 40, title: String? = nil, is types: [Int] = []) -> AnyShapeRecord {
    memo(n, title, is: types)
}

@MainActor private func fitted(_ record: AnyShapeRecord, _ text: String, on h: EditorHarness) throws -> AnyShapeRecord? {
    try require(h.editor.queries).fit(record, toMatch: text)
}

/// The numbers of the types a record is, as fitted by the text; nil when nothing is written.
@MainActor private func isAfter(_ text: String, from record: AnyShapeRecord = newMemo(), on h: EditorHarness,
                                file: StaticString = #fileID, line: UInt = #line) throws -> [Int]? {
    guard let made = try fitted(record, text, on: h) else { return nil }
    expectEqual(made.id, record.id, text, file: file, line: line)
    return (made[IsAProperty.self] ?? []).map { link in (1...10).first { id($0) == link.shape } ?? -1 }
}

@MainActor let isAFitTests = Suite("A shape made to be of a type", [
    test(":is-a(S) adds the type S names, by its title or by #id, and the shape is of it after") {
        let h = try typeHarness()
        expectEqual(try isAfter(#":is-a("Person")"#, on: h), [1])
        expectEqual(try isAfter(#"memo:is-a("Person")"#, on: h), [1])
        expectEqual(try isAfter(#":is-a("  Person ")"#, on: h), [1], "a title is folded as a title is")
        expectEqual(try isAfter(":is-a(#\(uuid(2)))", on: h), [2], "by id")
        expectEqual(try isAfter(#":is-a(memo"Employee card")"#, on: h), [2], "by kind and title")
        // Put down, it is what the query finds.
        let made = try require(try fitted(newMemo(41), #":is-a("Employee card")"#, on: h))
        h.editor.transact("Add") { $0.insert(made) }
        expectMatches([#":is-a("Employee card")"#: [3, 5, 41], #":is-a("Person")"#: [2, 3, 4, 5, 41]], on: h)
    },
    test("it adds at the end of the list the shape has, and writes the rest of the compound beside it") {
        let h = try typeHarness()
        expectEqual(try isAfter(#":is-a("Employee card")"#, from: newMemo(is: [1]), on: h), [1, 2], "Person is above Employee card: not of it yet")
        expectEqual(try isAfter(#":is-a("Alpha")"#, from: newMemo(is: [1]), on: h), [1, 7])
        let both = try require(try fitted(newMemo(), #"memo[title="Zed"]:is-a("Person"):not(:is-a("Employee card"))"#, on: h))
        expectEqual(both[TitleProperty.self], "Zed")
        expectEqual((both[IsAProperty.self] ?? []).map(\.shape), [id(1)], ":not is skipped")
    },
    test("nothing is written for a shape that is already of it, however far, and for a kind that holds no `is`") {
        let h = try typeHarness()
        expectEqual(try isAfter(#":is-a("Person")"#, from: newMemo(is: [1]), on: h), nil, "it is one")
        expectEqual(try isAfter(#":is-a("Person")"#, from: newMemo(is: [2]), on: h), nil, "it is an Employee card, which is a Person")
        expectEqual(try isAfter(#":is-a("Person")"#, from: newMemo(is: [4, 2]), on: h), nil)
        expectEqual(try isAfter(#":is-a("Person", "Alpha")"#, from: newMemo(is: [2]), on: h), nil, "of one alternative: none is added for another")
        let slab = AnyShapeRecord(ShapeRecord(id: id(42), Slab()))
        expect(try fitted(slab, #":is-a("Person")"#, on: h) == nil, "a slab is titled and nothing else")
    },
    test("nothing is written for what is no type, a type that is gone, a title that isn't one, or a kind that isn't the type's") {
        let h = try typeHarness()
        for text in [#":is-a("Plain")"#, #":is-a("Ann")"#, #":is-a("Nobody")"#, ":is-a(#\(uuid(10)))", ":is-a(#\(uuid(99)))", #":is-a(slab"Person")"#,
                     #":is-a("Person" memo)"#, ":is-a(memo)", ":is-a([schema])", #":is-a("Person"[title])"#] {
            expect(try fitted(newMemo(), text, on: h) == nil, "\(text) writes nothing")
        }
    },
    test("of a choice, the first alternative that names a type the shape may be is written") {
        let h = try typeHarness()
        expectEqual(try isAfter(#":is-a("Nobody", "Person")"#, on: h), [1], "a title that names none is passed over")
        expectEqual(try isAfter(#":is-a("Plain", "Employee card", "Person")"#, on: h), [2])
        expectEqual(try isAfter(#":is-a("Person", "Employee card")"#, on: h), [1])
        expectEqual(try isAfter(#":is-a("Alpha", #\#(uuid(1)))"#, on: h), [7])
    },
    test("a type that more than one type is titled so names none, and an id still does") {
        let shapes = [memo(1, "Person", type: true), memo(2, "Person", type: true), memo(3, "Task", type: true)]
        let h = try EditorHarness(plugins: typeQueryPlugins(), document: CanvasDocument(shapes: shapes))
        expectEqual(try isAfter(#":is-a("Person")"#, on: h), nil, "which is meant is no one's to say")
        expectEqual(try isAfter(#":is-a("Person", "Task")"#, on: h), [3], "so another alternative is used")
        expectEqual(try isAfter(":is-a(#\(uuid(2)))", on: h), [2])
        expectEqual(try isAfter(#":is-a("Task")"#, on: h), [3])
    },
    test("a type is not made one of itself, or of a type that is built on it") {
        let h = try typeHarness()
        let person = try require(h.editor.shape(inFile: id(1)))
        expect(try fitted(person, #":is-a("Person")"#, on: h) == nil, "itself")
        expect(try fitted(person, #":is-a("Employee card")"#, on: h) == nil, "a cycle: Employee card is a Person")
        let employee = try require(h.editor.shape(inFile: id(2)))
        let made = try require(try fitted(employee, #":is-a("Alpha")"#, on: h))
        expectEqual((made[IsAProperty.self] ?? []).map(\.shape), [id(1), id(7)], "a type may build on another")
    },
    test("a name in the shape's list that points at no type is kept, and the type is added after it") {
        let h = try typeHarness()
        let gone = newMemo(is: [99])
        expectEqual(try isAfter(#":is-a("Person")"#, from: gone, on: h), [-1, 1], "the name that points nowhere is kept")
    },
    test("a note of a type is titled from its fields once the type is given, as adding a type titles it") {
        let named = FieldFixtures.namedPersonID
        var type = AnyShapeRecord(ShapeRecord(id: named, Memo(frame: CGRect(x: 40, y: 900, width: 240, height: 52))))
        type[TitleProperty.self] = "Named person"
        type[TypeSchemaProperty.self] = SchemaText(#"{"type":"object","properties":{"name":{"type":"string","title":"Name"}}}"#)
        let h = try EditorHarness(plugins: typeQueryPlugins(), document: CanvasDocument(shapes: [type]))
        var record = newMemo()
        record[FieldValuesProperty.self] = FieldValues(["name": "Ann"])
        let made = try require(try fitted(record, #":is-a("Named person")"#, on: h))
        let added = h.editor.shape(inFile: named).map { _ in made[IsAProperty.self]?.map(\.shape) }
        expectEqual(added, [named])
        // The title is what adding the type through the editor gives the same note.
        h.editor.transact("Put") { $0.insert(record) }
        h.editor.addTypeLink(named, to: record.id)
        expectEqual(made[TitleProperty.self], h.editor.shape(inFile: record.id)?[TitleProperty.self], "one rule for both")
    },
])

// What a query says a note's field has, written typed by the field (`FieldFit`, as `registrar.queryPathCheck(makes:)`).

private let orderID = FieldFixtures.orderID, addressID = FieldFixtures.addressID

@MainActor private func orderHarness() throws -> EditorHarness {
    var order = AnyShapeRecord(ShapeRecord(id: orderID, Memo(frame: CGRect(x: 40, y: 900, width: 240, height: 52))))
    order[TitleProperty.self] = "Order"
    order[TypeSchemaProperty.self] = SchemaText(FieldFixtures.order.schema)
    var address = AnyShapeRecord(ShapeRecord(id: addressID, Memo(frame: CGRect(x: 40, y: 1000, width: 240, height: 52))))
    address[TitleProperty.self] = "Address"
    address[TypeSchemaProperty.self] = SchemaText(FieldFixtures.address.schema)
    return try EditorHarness(plugins: typeQueryPlugins(), document: CanvasDocument(shapes: [order, address]))
}

@MainActor private func values(_ text: String, from record: AnyShapeRecord = newMemo(), on h: EditorHarness) throws -> JSONObject? {
    try fitted(record, text, on: h).flatMap { $0[FieldValuesProperty.self]?.values }
}

@MainActor let fieldFitTests = Suite("A note's field written as the field types it", [
    test("a member is typed by the field: a choice as spelled, text kept as text, a yes or no, a member through another type's fields") {
        let h = try orderHarness()
        expectEqual(try values(#":is-a("Order")[fieldValues.status="paid"]"#, on: h), ["status": "paid"])
        expectEqual(try values(#":is-a("Order")[fieldValues.status="PAID" i]"#, on: h), ["status": "paid"], "a choice is written as spelled")
        expectEqual(try values(#":is-a("Order")[fieldValues.customer=02134]"#, on: h), ["customer": "02134"], "a text field keeps its text: no number")
        expectEqual(try values(#":is-a("Order")[fieldValues.customer=true]"#, on: h), ["customer": "true"])
        expectEqual(try values(#":is-a("Order")[fieldValues.gift=true]"#, on: h), ["gift": true])
        expectEqual(try values(#":is-a("Order")[fieldValues.shippingAddress.postcode=02134]"#, on: h), ["shippingAddress": ["postcode": "02134"]])
        // A member beside the ones the note has is added, and the words that make the note one come first, whatever the order.
        var held = newMemo()
        held[FieldValuesProperty.self] = FieldValues(["customer": "Ann"])
        expectEqual(try values(#"[fieldValues.status="draft"]:is-a("Order")"#, from: held, on: h), ["customer": "Ann", "status": "draft"])
    },
    test("nothing is written for a member no field of the note's types names, a value the field doesn't take, a list or a note of no type") {
        let h = try orderHarness()
        for text in [#":is-a("Order")[fieldValues.stauts="x"]"#, #":is-a("Order")[fieldValues.status="blue"]"#,
                     #":is-a("Order")[fieldValues.lineItems.product="Mug"]"#, #":is-a("Order")[fieldValues.lineItems="Mug"]"#,
                     #":is-a("Order")[fieldValues.gift=maybe]"#, #":is-a("Order")[fieldValues.shippingAddress="x"]"#,
                     #"[fieldValues.status="paid"]"#] {
            expectEqual(try values(text, on: h), nil, "\(text) writes no value")
        }
        // The rest of the compound is still written.
        let made = try require(try fitted(newMemo(), #"memo[title="Zed"]:is-a("Order")[fieldValues.stauts="x"]"#, on: h))
        expectEqual(made[TitleProperty.self], "Zed")
        expectEqual(made[FieldValuesProperty.self]?.values, nil)
    },
])

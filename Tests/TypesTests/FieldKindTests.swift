import Canvas
import CanvasTesting
import Foundation
import TestKit
import Types

// The kind of a field's row, from its schema alone: the plan's "Every kind of field", in the order of
// precedence, and the two columns of board 5 panel 7 (which rows end in `›` on a type's note, and which on
// a note that is one).

private let person = FieldFixtures.personID, address = FieldFixtures.addressID
private func ref(_ id: ShapeID) -> String { FieldFixtures.uri(of: id) }
private let personLink = #"{"type": "string", "contentMediaType": "text/x-canvas-link", "contentSchema": {"$ref": "\#(ref(person))"}}"#

/// A field the book can read: `schema` as the one property of a type's root, written as a chain does.
@MainActor private func field(_ schema: String, holdsItself: Bool = false) throws -> Resolved.Field {
    var level = try require(ChainLevel(schema: #"{"type": "object", "properties": {"f": \#(schema)}}"#)).fields[0]
    level.holdsItself = holdsItself
    return Resolved.Field(field: level, source: ShapeID(), introducedBy: ShapeID())
}

@MainActor private func readKind(_ schema: String) throws -> FieldKind {
    try require(try fieldEditor().fieldBook).kind(of: try field(schema))
}

private func choices(_ values: String...) -> [FieldOption] { values.map { FieldOption(value: .string($0), label: $0) } }

/// One row of the table: the schema, its kind, the type's label, and whether the row ends in `›` on a note
/// that is one (`hasMore`) and on a type's note (`opensOnType`).
private struct Row {
    let schema: String
    let kind: FieldKind
    let label: String
    let hasMore: Bool
    let opensOnType: Bool
    var members = 0
}

private let rows: [Row] = [
    Row(schema: #"{"type": "string"}"#, kind: .plain(.text), label: "Text", hasMore: false, opensOnType: false),
    Row(schema: #"{"type": "number"}"#, kind: .plain(.number(integer: false)), label: "Number", hasMore: false, opensOnType: false),
    Row(schema: #"{"type": "integer", "minimum": 1}"#, kind: .plain(.number(integer: true)), label: "Number", hasMore: false, opensOnType: false),
    Row(schema: #"{"type": "string", "format": "date"}"#, kind: .plain(.date), label: "Date", hasMore: false, opensOnType: false),
    Row(schema: #"{"type": "string", "format": "date-time"}"#, kind: .plain(.dateTime), label: "Date", hasMore: false, opensOnType: false),
    Row(schema: #"{"type": "boolean"}"#, kind: .plain(.yesNo), label: "Yes or no", hasMore: false, opensOnType: false),
    Row(schema: #"{"type": "string", "format": "email"}"#, kind: .plain(.text), label: "Text", hasMore: false, opensOnType: false),
    Row(schema: #"{"enum": ["draft", "paid", "shipped"]}"#, kind: .plain(.choice(choices("draft", "paid", "shipped"))), label: "Choice", hasMore: false, opensOnType: false),
    Row(schema: #"{"type": "string", "enum": ["a", "b"]}"#, kind: .plain(.choice(choices("a", "b"))), label: "Choice", hasMore: false, opensOnType: false),
    Row(schema: #"{"const": "only"}"#, kind: .plain(.choice(choices("only"))), label: "Choice", hasMore: false, opensOnType: false),
    Row(schema: #"{"enum": [1, 2.5, true]}"#,
        kind: .plain(.choice([FieldOption(value: .number(1), label: "1"), FieldOption(value: .number(2.5), label: "2.5"), FieldOption(value: .bool(true), label: "true")])),
        label: "Choice", hasMore: false, opensOnType: false),
    Row(schema: #"{"enum": ["a", null]}"#, kind: .plain(.choice(choices("a"))), label: "Choice", hasMore: false, opensOnType: false),
    Row(schema: #"{"type": "array", "items": {"enum": ["engineer", "designer"]}, "uniqueItems": true}"#,
        kind: .choices(choices("engineer", "designer")), label: "Choices", hasMore: true, opensOnType: false),
    Row(schema: #"{"type": "array", "items": {"enum": ["a", "b"]}}"#, kind: .list(of: .choice(choices("a", "b"))), label: "List of Choice", hasMore: true, opensOnType: false),
    Row(schema: #"{"type": "array", "items": {"type": "string"}}"#, kind: .list(of: .text), label: "List of Text", hasMore: true, opensOnType: false),
    Row(schema: #"{"type": "array", "items": {"type": "number"}}"#, kind: .list(of: .number(integer: false)), label: "List of Number", hasMore: true, opensOnType: false),
    Row(schema: #"{"type": "array", "items": {"type": "string", "format": "date"}}"#, kind: .list(of: .date), label: "List of Date", hasMore: true, opensOnType: false),
    Row(schema: #"{"type": "object", "properties": {"name": {"type": "string"}, "city": {"type": "string"}}}"#, kind: .group, label: "2 fields", hasMore: true, opensOnType: true, members: 2),
    Row(schema: #"{"type": "object", "properties": {"name": {"type": "string"}}}"#, kind: .group, label: "1 field", hasMore: true, opensOnType: true, members: 1),
    Row(schema: #"{"$ref": "\#(ref(address))"}"#, kind: .typeFields(address), label: "", hasMore: true, opensOnType: true),
    Row(schema: #"{"$ref": "\#(ref(address))", "properties": {"x": {"type": "string"}}}"#, kind: .typeFields(address), label: "", hasMore: true, opensOnType: true),
    Row(schema: personLink, kind: .pointer(person), label: "→", hasMore: false, opensOnType: false),
    Row(schema: #"{"type": "array", "items": \#(personLink)}"#, kind: .pointers(person), label: "List of →", hasMore: true, opensOnType: false),
    Row(schema: #"{"type": "array", "items": {"type": "object", "properties": {"product": {"type": "string"}}}}"#, kind: .listOfGroups, label: "List", hasMore: true, opensOnType: true),
    Row(schema: #"{"type": "array", "items": {"$ref": "\#(ref(address))"}}"#, kind: .listOfTypeFields(address), label: "List of", hasMore: true, opensOnType: true),
    Row(schema: #"{"anyOf": [{"type": "number"}, {"type": "string"}]}"#, kind: .either(.plain(.number(integer: false)), .plain(.text)), label: "Number or Text", hasMore: false, opensOnType: false),
    Row(schema: #"{"oneOf": [{"type": "string", "format": "date"}, {"type": "boolean"}]}"#, kind: .either(.plain(.date), .plain(.yesNo)), label: "Date or Yes or no", hasMore: false, opensOnType: false),
    Row(schema: #"{"type": ["number", "string"]}"#, kind: .either(.plain(.number(integer: false)), .plain(.text)), label: "Number or Text", hasMore: false, opensOnType: false),
    Row(schema: #"{"type": "object", "additionalProperties": {"type": "string"}}"#, kind: .pairs(value: .text), label: "Pairs", hasMore: true, opensOnType: true),
    Row(schema: #"{}"#, kind: .other, label: "Other", hasMore: true, opensOnType: true),
    Row(schema: #"{"allOf": [{"type": "string"}]}"#, kind: .other, label: "Other", hasMore: true, opensOnType: true),
    Row(schema: #"{"not": {"type": "string"}}"#, kind: .other, label: "Other", hasMore: true, opensOnType: true),
    Row(schema: #"{"type": "object", "patternProperties": {"^x-": {"type": "string"}}}"#, kind: .other, label: "Other", hasMore: true, opensOnType: true),
    Row(schema: #"{"type": "object"}"#, kind: .other, label: "Other", hasMore: true, opensOnType: true),
    Row(schema: #"{"properties": {"a": {"type": "string"}}}"#, kind: .other, label: "Other", hasMore: true, opensOnType: true),
    Row(schema: #"{"type": "object", "additionalProperties": true}"#, kind: .other, label: "Other", hasMore: true, opensOnType: true),
    Row(schema: #"{"type": "object", "additionalProperties": {"type": "object", "properties": {"a": {"type": "string"}}}}"#, kind: .other, label: "Other", hasMore: true, opensOnType: true),
    // May be null: dropped before the kind is read, both ways.
    Row(schema: #"{"type": ["string", "null"]}"#, kind: .plain(.text), label: "Text", hasMore: false, opensOnType: false),
    Row(schema: #"{"anyOf": [{"type": "string"}, {"type": "null"}]}"#, kind: .plain(.text), label: "Text", hasMore: false, opensOnType: false),
    Row(schema: #"{"oneOf": [{"type": "null"}, {"$ref": "\#(ref(address))"}]}"#, kind: .typeFields(address), label: "", hasMore: true, opensOnType: true),
    Row(schema: #"{"type": ["number", "string", "null"]}"#, kind: .either(.plain(.number(integer: false)), .plain(.text)), label: "Number or Text", hasMore: false, opensOnType: false),
    Row(schema: #"{"anyOf": [\#(personLink), {"type": "null"}]}"#, kind: .pointer(person), label: "→", hasMore: false, opensOnType: false),
    Row(schema: #"{"type": "array", "items": {"type": ["string", "null"]}}"#, kind: .list(of: .text), label: "List of Text", hasMore: true, opensOnType: false),
    // An either with a branch that is not plain: a card, and `Either` on the type.
    Row(schema: #"{"anyOf": [{"type": "object", "properties": {"a": {"type": "string"}}}, {"type": "string"}]}"#,
        kind: .either(.group, .plain(.text)), label: "Either", hasMore: true, opensOnType: true),
    Row(schema: #"{"anyOf": [{"type": "array", "items": {"type": "string"}}, {"type": "string"}]}"#,
        kind: .either(.list(of: .text), .plain(.text)), label: "Either", hasMore: true, opensOnType: false),
    // The longest an either of plain kinds reads, 22 characters, still joins.
    Row(schema: #"{"anyOf": [{"type": "boolean"}, {"type": "boolean"}]}"#, kind: .either(.plain(.yesNo), .plain(.yesNo)), label: "Yes or no or Yes or no", hasMore: false, opensOnType: false),
    // What no control suits.
    Row(schema: #"{"anyOf": [{"type": "string"}, {"type": "number"}, {"type": "boolean"}]}"#, kind: .other, label: "Other", hasMore: true, opensOnType: true),
    Row(schema: #"{"type": ["string", "number", "boolean"]}"#, kind: .other, label: "Other", hasMore: true, opensOnType: true),
    Row(schema: #"{"anyOf": [{"type": "string"}, {}]}"#, kind: .other, label: "Other", hasMore: true, opensOnType: true),
    Row(schema: #"{"$ref": "\#(ref(address))#/$defs/x"}"#, kind: .other, label: "Other", hasMore: true, opensOnType: true),
    Row(schema: #"{"$ref": "http://example.com/x"}"#, kind: .other, label: "Other", hasMore: true, opensOnType: true),
    Row(schema: #"{"type": "array", "items": {"$ref": "\#(ref(address))#/x"}}"#, kind: .other, label: "Other", hasMore: true, opensOnType: true),
    Row(schema: #"{"enum": [{"a": 1}]}"#, kind: .other, label: "Other", hasMore: true, opensOnType: true),
    Row(schema: #"{"enum": []}"#, kind: .other, label: "Other", hasMore: true, opensOnType: true),
    Row(schema: #"{"const": {"a": 1}}"#, kind: .other, label: "Other", hasMore: true, opensOnType: true),
    Row(schema: #"{"type": "array"}"#, kind: .other, label: "Other", hasMore: true, opensOnType: true),
    Row(schema: #"{"type": "array", "items": [{"type": "string"}, {"type": "number"}]}"#, kind: .other, label: "Other", hasMore: true, opensOnType: true),
    Row(schema: #"{"type": "array", "prefixItems": [{"type": "string"}], "items": {"type": "string"}}"#, kind: .other, label: "Other", hasMore: true, opensOnType: true),
    Row(schema: #"{"type": "array", "items": {"type": "array", "items": {"type": "string"}}}"#, kind: .other, label: "Other", hasMore: true, opensOnType: true),
    Row(schema: #"{"type": "array", "items": {"type": "object"}}"#, kind: .other, label: "Other", hasMore: true, opensOnType: true),
    Row(schema: #"{"type": "array", "items": {"type": ["string", "number"]}}"#, kind: .other, label: "Other", hasMore: true, opensOnType: true),
    Row(schema: #"{"type": "null"}"#, kind: .other, label: "Other", hasMore: true, opensOnType: true),
    Row(schema: #"true"#, kind: .other, label: "Other", hasMore: true, opensOnType: true),
]

@MainActor let fieldKindTests = Suite("Field kinds", [
    test("every kind of field: its kind, the label on a type's note, and which rows end in ›") {
        for row in rows {
            let read = try readKind(row.schema)
            expectEqual(read, row.kind, row.schema)
            expectEqual(read.typeLabel(memberCount: row.members), row.label, "label of \(row.schema)")
            expectEqual(read.hasMore, row.hasMore, "hasMore of \(row.schema)")
            expectEqual(read.opensOnType, row.opensOnType, "opensOnType of \(row.schema)")
        }
    },
    test("board 5 panel 7, cell for cell: the rows of a type's note that end in ›, and of a note that is one") {
        // (on the type, on a note): Text, Number, Date, Yes or no and Choice have neither; Choices, List of Text and the
        // links have one on the note only; the rest have both.
        let editor = try fieldEditor()
        editor.addFieldTypes([FieldFixtures.everyKind.a, FieldFixtures.everyKind.b])
        let book = try require(editor.fieldBook)
        let expected: [(String, onType: Bool, onNote: Bool)] = [
            ("name", false, false), ("price", false, false), ("due", false, false), ("done", false, false), ("status", false, false),
            ("roles", false, true), ("tags", false, true), ("venue", true, true), ("shippingAddress", true, true),
        ]
        let a = book.fields(types: [FieldFixtures.kindsAID])
        expectEqual(a.fields.count, 9)
        for (name, onType, onNote) in expected {
            let read = book.kind(of: try require(a.field(named: name)))
            expectEqual(read.opensOnType, onType, "\(name) on the type")
            expectEqual(read.hasMore, onNote, "\(name) on a note")
        }
        let b = book.fields(types: [FieldFixtures.kindsBID])
        expectEqual(b.fields.count, 9)
        let more: [(String, FieldKind, onType: Bool, onNote: Bool)] = [
            ("customer", .pointer(person), false, false), ("guests", .pointers(person), false, true), ("lineItems", .listOfGroups, true, true),
            ("rooms", .listOfTypeFields(address), true, true), ("labels", .pairs(value: .text), true, true), ("anything", .other, true, true),
            ("payment", .either(.group, .plain(.text)), true, true),
        ]
        for (name, expectedKind, onType, onNote) in more {
            let read = book.kind(of: try require(b.field(named: name)))
            expectEqual(read, expectedKind, name)
            expectEqual(read.opensOnType, onType, "\(name) on the type")
            expectEqual(read.hasMore, onNote, "\(name) on a note")
        }
        expectEqual(book.kind(of: try require(b.field(named: "size"))), .either(.plain(.number(integer: false)), .plain(.text)))
        expectEqual(book.kind(of: try require(b.field(named: "count"))), .plain(.number(integer: true)))
    },
    test("the shared fixtures read as board 5 draws them: Order's seven rows, Employee on Person, nine and nine, four colors") {
        let editor = try fieldEditor()
        editor.addFieldTypes([FieldFixtures.everyKind.a, FieldFixtures.everyKind.b])
        let book = try require(editor.fieldBook)
        let order = book.fields(types: [FieldFixtures.orderID])
        expectEqual(order.fields.map(\.field.name), ["customer", "shippingAddress", "lineItems", "status", "tags", "gift", "giftNote"])
        expectEqual(order.fields.map { book.kind(of: $0) }, [
            .pointer(person), .typeFields(address), .listOfGroups, .plain(.choice(choices("draft", "paid", "shipped"))), .list(of: .text), .plain(.yesNo), .plain(.text),
        ])
        expectEqual(order.fields.filter(\.field.isRequired).map(\.field.name), ["customer", "lineItems"])
        expectEqual(Set(order.rules.flatMap(\.members).map(\.key)), ["if", "then"], "the gift note, needed while gift is ticked")
        let employee = book.fields(types: [FieldFixtures.employeeID])
        expectEqual(employee.order, [FieldFixtures.employeeID, person])
        expectEqual(employee.fields.map(\.field.name), ["name", "email", "role", "startDate"], "Person's rows first")
        expectEqual(book.kind(of: try require(employee.field(named: "startDate"))), .plain(.date))
        expectEqual(book.fields(types: [FieldFixtures.kindsAID]).fields.count, 9)
        expectEqual(book.fields(types: [FieldFixtures.kindsBID]).fields.count, 9)
        expectEqual(editor.title(FieldFixtures.orderID), "Order")
        let ids = [FieldFixtures.personID, FieldFixtures.addressID, FieldFixtures.employeeID, FieldFixtures.orderID]
        expectEqual(Set(ids.map(TypeColors.index(of:))).count, 4, "four different colors")
        expectEqual(FieldFixtures.uri(of: person), "urn:uuid:0e5b1a01-0000-4000-8000-0000000000a1")
        expectEqual(FieldFixtures.wide(12).schema.components(separatedBy: "\"f").count - 1, 12)
    },
    test("a field that holds itself is Other, whatever else it says; a field's kind reads no other type") {
        expectEqual(try require(try fieldEditor().fieldBook).kind(of: try field(#"{"type": "string"}"#, holdsItself: true)), .other)
        let gone = ShapeID()
        let read = try readKind(#"{"$ref": "\#(ref(gone))"}"#)
        expectEqual(read, .typeFields(gone), "a type that is gone still reads as its fields")
        expectEqual(read.chip, gone)
    },
    test("the chip follows a field of another type's fields, a list of them and a link, and nothing else") {
        expectEqual(FieldKind.typeFields(address).chip, address)
        expectEqual(FieldKind.listOfTypeFields(address).chip, address)
        expectEqual(FieldKind.pointer(person).chip, person)
        expectEqual(FieldKind.pointers(person).chip, person)
        expectEqual(FieldKind.group.chip, nil)
        expectEqual(FieldKind.plain(.text).chip, nil)
        expectEqual(FieldKind.either(.pointer(person), .plain(.text)).chip, nil)
    },
    test("the field a path names: through a group, a type's fields, a list of groups, pairs and an either") {
        let editor = try fieldEditor()
        editor.addFieldTypes([FieldFixtures.everyKind.a, FieldFixtures.everyKind.b])
        let book = try require(editor.fieldBook)
        let order = FieldFixtures.orderID, a = FieldFixtures.kindsAID, b = FieldFixtures.kindsBID
        let items = FieldPath(field: "lineItems")
        @MainActor func kind(_ path: FieldPath, of type: ShapeID) -> FieldKind? { book.field(at: path, types: [type]).map { book.kind(of: $0) } }
        expectEqual(kind(FieldPath(field: "status"), of: order), .plain(.choice(choices("draft", "paid", "shipped"))))
        expectEqual(kind(items, of: order), .listOfGroups)
        expectEqual(kind(items.index(1), of: order), .group, "the item of a list of groups")
        expectEqual(kind(items.index(1).key("quantity"), of: order), .plain(.number(integer: true)))
        expectEqual(book.field(at: items.index(0).key("product"), types: [order])?.field.name, "product")
        expectEqual(kind(FieldPath(field: "shippingAddress").key("city"), of: order), .plain(.text), "through another type's fields")
        expectEqual(kind(FieldPath(field: "venue").key("city"), of: a), .plain(.text), "through a group")
        expectEqual(kind(FieldPath(field: "tags").index(0), of: order), .plain(.text), "an element of a list of plain values")
        expectEqual(kind(FieldPath(field: "rooms").index(0), of: b), .typeFields(address))
        expectEqual(kind(FieldPath(field: "rooms").index(0).key("street"), of: b), .plain(.text))
        expectEqual(kind(FieldPath(field: "guests").index(2), of: b), .pointer(person))
        expectEqual(kind(FieldPath(field: "labels").key("size"), of: b), .plain(.text), "a pair's value, whatever its name")
        expectEqual(kind(FieldPath(field: "payment").key("cardNumber"), of: b), .plain(.text), "an either takes the branch that has the step")
        // Nothing names these.
        expectEqual(kind(FieldPath(), of: order), nil, "the root names no row")
        expectEqual(kind(FieldPath(field: "nope"), of: order), nil)
        expectEqual(kind(FieldPath(field: "status").key("x"), of: order), nil)
        expectEqual(kind(items.key("x"), of: order), nil, "a key into a list")
        expectEqual(kind(FieldPath(field: "shippingAddress").index(0), of: order), nil, "an index into a group")
        expectEqual(kind(items.index(0).key("nope"), of: order), nil)
        expectEqual(kind(FieldPath([.index(0)]), of: order), nil)
        expectEqual(kind(FieldPath(field: "name"), of: order), nil, "a field of another type")
    },
    test("the branches of an either: anyOf or oneOf entries or the types of a type list, null dropped; none for anything else") {
        let book = try require(try fieldEditor().fieldBook)
        let first = try field(#"{"anyOf": [{"type": "number"}, {"type": "string"}, {"type": "null"}]}"#)
        expectEqual(book.branches(of: first).map { book.kind(of: $0) }, [.plain(.number(integer: false)), .plain(.text)])
        let one = try field(#"{"oneOf": [{"type": "boolean"}, {"type": "string"}]}"#)
        expectEqual(book.branches(of: one).map { book.kind(of: $0) }, [.plain(.yesNo), .plain(.text)])
        let types = try field(#"{"type": ["number", "string", "null"], "description": "kept"}"#)
        expectEqual(book.branches(of: types).map { book.kind(of: $0) }, [.plain(.number(integer: false)), .plain(.text)])
        expectEqual(book.branches(of: types).first?.field.schema["description"]?.string, "kept", "a branch keeps what the field says beside the type")
        expectEqual(book.branches(of: try field(#"{"type": "string"}"#)).count, 0)
        expectEqual(book.branches(of: try field(#"{"anyOf": [{"type": "string"}, {"type": "null"}]}"#)).count, 0, "a may-be-null is not an either")
        expectEqual(book.branches(of: try field(#"{"type": "object", "properties": {"a": {"type": "string"}}}"#)).count, 0)
    },
    test("a pairs field's value field: its additionalProperties, named empty") {
        let book = try require(try fieldEditor().fieldBook)
        let pairs = try field(#"{"type": "object", "additionalProperties": {"type": "integer"}}"#)
        let value = try require(book.pairValue(of: pairs))
        expectEqual(value.field.name, "")
        expectEqual(book.kind(of: value), .plain(.number(integer: true)))
        expectEqual(value.source, pairs.source)
        expectEqual(book.pairValue(of: try field(#"{"type": "string"}"#))?.field.name, nil)
        expectEqual(book.pairValue(of: try field(#"{"type": "object", "additionalProperties": false}"#))?.field.name, nil)
    },
    test("a pointer whose contentSchema names a part of a type, or something else, is text; the media type is the literal; pointerSchema reads as a pointer") {
        let fragment = #"{"type": "string", "contentMediaType": "text/x-canvas-link", "contentSchema": {"$ref": "\#(ref(person))#/$defs/x"}}"#
        expectEqual(try readKind(fragment), .plain(.text))
        let elsewhere = ##"{"type": "string", "contentMediaType": "text/x-canvas-link", "contentSchema": {"$ref": "#/$defs/x"}}"##
        expectEqual(try readKind(elsewhere), .plain(.text))
        expectEqual(FieldKind.pointerMediaType, "text/x-canvas-link")
        let json = String(decoding: try JSONEncoder().encode(JSONValue.object(FieldKind.pointerSchema(to: person))), as: UTF8.self)
        expectEqual(try readKind(json), .pointer(person))
        expectEqual(try readKind(#"{"type": "array", "items": \#(json)}"#), .pointers(person))
    },
])

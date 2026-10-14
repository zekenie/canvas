import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Queries
import QueryLanguage
import TestKit
import Titles
import Types
import Validation

// `:incomplete`, Validation's word (`ValidationQueriesPlugin`), over what Types' rule over values says: a shape with a
// field its types need left empty, or a relationship row an end marks Needed, is a shape with an issue of the third level.
// The Order is the shared fixture (`FieldFixtures.order`, board 5's), over this target's own memo kind. Types registers no such
// word of its own.

private let orderID = FieldFixtures.orderID

/// The Order type: a memo holding the fixture's schema, titled Order.
private func orderType() -> AnyShapeRecord {
    var record = AnyShapeRecord(ShapeRecord(id: orderID, Memo(frame: CGRect(x: 40, y: 900, width: 240, height: 52))))
    record[TitleProperty.self] = "Order"
    record[TypeSchemaProperty.self] = SchemaText(FieldFixtures.order.schema)
    return record
}

/// A memo numbered `n`, an Order (or the types given) holding `values`.
private func order(_ n: Int, _ values: JSONObject = [:], is types: [ShapeID] = [orderID]) -> AnyShapeRecord {
    var record = memo(n, "Order \(n)")
    record[IsAProperty.self] = types.map(TypeLink.init)
    if !values.isEmpty { record[FieldValuesProperty.self] = FieldValues(values) }
    return record
}

private let filled: JSONObject = ["customer": "c", "lineItems": [["product": "Mug", "quantity": 1]]]

/// Types' plugins and Validation's words.
@MainActor private func plugins() -> [any CanvasPlugin] { typeQueryPlugins() + [ValidationQueriesPlugin()] }

@MainActor private func harness(_ shapes: [AnyShapeRecord]) throws -> EditorHarness {
    try EditorHarness(plugins: plugins(), document: CanvasDocument(shapes: [orderType()] + shapes))
}

@MainActor let incompleteTests = Suite(":incomplete in canvas query", [
    test("an Order with nothing filled is incomplete, a filled one is not, and neither is a note that is no Order") {
        let h = try harness([order(1), order(2, filled), memo(3, "Plain")])
        expectMatches([":incomplete": [1], "memo:incomplete": [1], ":incomplete:not([schema])": [1]], on: h)
    },
    test("a gift note is needed while gift is ticked, and not unticked or never set") {
        var ticked = filled
        ticked["gift"] = true
        var noted = ticked
        noted["giftNote"] = "Happy birthday"
        var unticked = filled
        unticked["gift"] = false
        let h = try harness([order(1, ticked), order(2, noted), order(3, unticked), order(4, filled)])
        expectMatches([":incomplete": [1]], on: h)
    },
    test("a needed yes or no never counts, and a type with only that is never incomplete") {
        let done = ShapeID()
        var type = AnyShapeRecord(ShapeRecord(id: done, Memo(frame: CGRect(x: 40, y: 1000, width: 240, height: 52))))
        type[TitleProperty.self] = "Chore"
        type[TypeSchemaProperty.self] = SchemaText(#"{"type": "object", "properties": {"done": {"type": "boolean"}}, "required": ["done"]}"#)
        let h = try EditorHarness(plugins: plugins(), document: CanvasDocument(shapes: [type, order(1, [:], is: [done])]))
        expectMatches([":incomplete": []], on: h)
    },
    test("a note that is incomplete and invalid matches both words: needed is no error, and wrong is no more than incomplete") {
        var wrongToo = filled
        wrongToo.removeValue(forKey: "customer")
        wrongToo["lineItems"] = [["product": "Mug", "quantity": 0]]
        let shapes = [order(1, wrongToo), order(2, ["customer": "c", "lineItems": [["product": "Mug", "quantity": 0]]]), order(3)]
        let h = try EditorHarness(plugins: plugins(), document: CanvasDocument(shapes: [orderType()] + shapes))
        expectMatches([":incomplete": [1, 3], ":invalid": [1, 2], ":incomplete:invalid": [1], ":incomplete:not(:invalid)": [3]], on: h)
    },
    test("a row says which fields are needed and where, and only the needed ones: :invalid lists the wrong") {
        let values: JSONObject = ["lineItems": [["product": "Mug", "quantity": 0]], "gift": true]
        let h = try EditorHarness(plugins: plugins(),
                                  document: CanvasDocument(shapes: [orderType(), order(1, values), order(2, filled)]))
        let needed = try answer(":incomplete", on: h, properties: .none).rows
        expectEqual(needed.map(\.id), [1].map(id))
        expectEqual(needed.first?.problems?.map(\.problemClass), ["needed", "needed"], "a wrong value alongside is not listed")
        expectEqual(needed.first?.problems?.map(\.field), ["customer", "giftNote"])
        expectEqual(needed.first?.problems?.map(\.path), ["/customer", "/giftNote"])
        expect(needed.first?.problems?.allSatisfy { !$0.message.isEmpty } == true)
        let wrong = try answer(":invalid", on: h, properties: .none).rows
        expectEqual(wrong.map(\.id), [1].map(id))
        expectEqual(wrong.first?.problems?.map(\.problemClass), ["wrong"])
        expectEqual(wrong.first?.problems?.first?.field, "lineItems")
        expectEqual(wrong.first?.problems?.first?.path, "/lineItems/0/quantity")
        let both = try answer(":incomplete, :invalid", on: h, properties: .none).rows
        expectEqual(both.first?.problems?.map(\.problemClass), ["needed", "needed", "wrong"], "both words: the needed, then the wrong, each once")
        expectEqual(try answer(":is-a(\"Order\"):not(:incomplete)", on: h, properties: .none).rows.map(\.problems), [nil], "a row with none has no member")
    },
    test("it composes: :is-a(\"Order\") finds the Orders, and :incomplete narrows them") {
        let h = try harness([order(1), order(2, filled), memo(3, "Plain")])
        expectMatches([#":is-a("Order"):incomplete"#: [1], #":is-a("Order"):not(:incomplete)"#: [2], #":incomplete:is-a("Order")"#: [1]], on: h)
    },
    test("a note on a board not shown is answered the same; a note of a type that is gone is not incomplete") {
        let pocket = ShapeID(), inside = ShapeID(), ghost = ShapeID()
        var note = AnyShapeRecord(ShapeRecord(id: inside, Memo(frame: CGRect(x: 40, y: 80, width: 240, height: 52))))
        note[IsAProperty.self] = [TypeLink(orderID)]
        var lost = AnyShapeRecord(ShapeRecord(id: ShapeID(), Memo(frame: CGRect(x: 40, y: 300, width: 240, height: 52))))
        lost[IsAProperty.self] = [TypeLink(ghost)]
        let file = CanvasFile(root: CanvasDocument(shapes: [orderType(), AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 0, y: 0, width: 100, height: 100))))]),
                              children: [pocket: CanvasDocument(shapes: [note, lost])])
        let h = try EditorHarness(plugins: plugins() + [PocketsPlugin()], file: file)
        let result = try answer(":incomplete", on: h, properties: .none)
        expectEqual(result.rows.map(\.id), [inside], "the Order on the other board; the note of a gone type is not")
    },
    test("it follows an edit: filling a field, and a type that asks for more") {
        let h = try harness([order(1, filled)])
        expectMatches([":incomplete": []], on: h)
        h.editor.transact { $0.update(id(1)) { $0[FieldValuesProperty.self] = FieldValues(["customer": "c"]) } }
        expectMatches([":incomplete": [1]], on: h)
        h.editor.transact { $0.update(id(1)) { $0[FieldValuesProperty.self] = FieldValues(filled) } }
        expectMatches([":incomplete": []], on: h)
        h.editor.transact { $0.update(orderID) { $0[TypeSchemaProperty.self] = SchemaText(FieldFixtures.order.schema.replacingOccurrences(of: #""required": ["customer", "lineItems"]"#, with: #""required": ["customer", "lineItems", "status"]"#)) } }
        expectMatches([":incomplete": [1]], on: h)
    },
    test("the vocabulary lists the word, which is Validation's and reads the editor; without Validation's words it is an unknown word, Types registering none") {
        let h = try harness([order(1)])
        let queries = try require(h.editor.queries)
        expect(queries.vocabulary.text.contains(":incomplete"), queries.vocabulary.text)
        expect(queries.vocabulary.text.contains("it still needs something"))
        expect(!queries.vocabulary.text.contains("a relationship row that is needed"), "the summary is true of any rule, not Types' alone")
        expectEqual(queries.vocabulary.words.first { $0.word == "incomplete" }?.from, "validation-queries")
        let plan = try queries.check(":incomplete")
        expectEqual(plan.editorWords, [":incomplete"])
        expect(!plan.readsOnlyTheFile)
        let none = try EditorHarness(plugins: typeQueryPlugins(), document: CanvasDocument(shapes: [orderType(), order(1)]))
        expectEqual(try require(try refusal(":incomplete", on: none)).reason, .unknownPseudoClass)
    },
])

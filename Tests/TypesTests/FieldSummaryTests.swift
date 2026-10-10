import Canvas
import CanvasTesting
import Foundation
import TestKit
import Types

// What a row with more in it reads: the plan's "What a row with more in it reads", row for row.

private let us = Locale(identifier: "en_US")

@MainActor private struct Summaries {
    let editor: CanvasEditor
    let book: FieldBook

    init() throws {
        editor = try fieldEditor()
        editor.addFieldTypes([FieldFixtures.everyKind.a, FieldFixtures.everyKind.b])
        book = try require(editor.fieldBook)
    }

    /// A field of one of the shared types.
    func field(_ name: String, of type: ShapeID) throws -> Resolved.Field {
        try require(book.fields(types: [type]).field(named: name), name)
    }

    /// A field written here, a property of a type's root.
    func adHoc(_ schema: String) throws -> Resolved.Field {
        let level = try require(ChainLevel(schema: #"{"type": "object", "properties": {"f": \#(schema)}}"#))
        return Resolved.Field(field: level.fields[0], source: ShapeID(), introducedBy: ShapeID())
    }

    func summary(_ value: JSONValue?, _ field: Resolved.Field, types: [ShapeID] = []) -> FieldSummary {
        FieldSummary.of(value, field: field, in: book, types: types, locale: us)
    }
}

@MainActor let fieldSummaryTests = Suite("Field summaries", [
    test("a list of plain values and several choices read their values, joined by commas") {
        let s = try Summaries()
        expectEqual(s.summary(["gift", "mugs"], try s.field("tags", of: FieldFixtures.orderID)), .items(["gift", "mugs"]))
        expectEqual(s.summary(["engineer", "designer"], try s.field("roles", of: FieldFixtures.kindsAID)), .items(["engineer", "designer"]))
        expectEqual(FieldSummary.items(["gift", "mugs"]).text, "gift, mugs")
        let dates = try s.adHoc(#"{"type": "array", "items": {"type": "string", "format": "date"}}"#)
        expectEqual(s.summary(["2026-03-03", "2026-04-01"], dates), .items(["Mar 3, 2026", "Apr 1, 2026"]))
        let numbers = try s.adHoc(#"{"type": "array", "items": {"type": "number"}}"#)
        expectEqual(s.summary([1, 2.5], numbers), .items(["1", "2.5"]))
    },
    test("a group and another type's fields read their filled values in the members' order") {
        let s = try Summaries()
        let address = try s.field("shippingAddress", of: FieldFixtures.orderID)
        expectEqual(s.summary(["city": "Leeds", "street": "12 Main St"], address), .items(["12 Main St", "Leeds"]), "street, then city, as the type has them")
        expectEqual(FieldSummary.items(["12 Main St", "Leeds"]).text, "12 Main St, Leeds")
        let venue = try s.field("venue", of: FieldFixtures.kindsAID)
        expectEqual(s.summary(["name": "The Loft", "city": "Leeds"], venue), .items(["The Loft", "Leeds"]))
        expectEqual(s.summary(["city": "Leeds"], venue), .items(["Leeds"]), "a member that is empty is left out")
        expectEqual(s.summary(["nobody": "x"], venue), .empty("add venue"), "a value no member names is no summary")
    },
    test("a member with more in it is its own summary as text; a ticked box is its name, an unticked one nothing") {
        let s = try Summaries()
        let group = try s.adHoc(#"""
        {"type": "object", "properties": {
          "name": {"type": "string"},
          "tags": {"type": "array", "items": {"type": "string"}},
          "lines": {"type": "array", "items": {"type": "object", "properties": {"p": {"type": "string"}}}},
          "labels": {"type": "object", "additionalProperties": {"type": "string"}},
          "gift": {"type": "boolean"},
          "extra": {}}}
        """#)
        let value: JSONValue = ["name": "Ann", "tags": ["a", "b"], "lines": [["p": "x"], ["p": "y"]], "labels": ["size": "L", "weight": "heavy"], "gift": true, "extra": ["k": 1]]
        expectEqual(s.summary(value, group), .items(["Ann", "a, b", "2 items", "size: L, +1", "gift", "edited as JSON in the panel"]))
        expectEqual(s.summary(["name": "Ann", "gift": false], group), .items(["Ann"]), "unticked is nothing")
        expectEqual(s.summary(["gift": false], group), .empty("add f"), "and a group of nothing else reads empty")
        expectEqual(s.summary(["gift": true], group), .items(["gift"]))
    },
    test("a list of groups and of type fields read a count") {
        let s = try Summaries()
        expectEqual(s.summary([["product": "Mug", "quantity": 2], ["product": "Plate", "quantity": 1]], try s.field("lineItems", of: FieldFixtures.orderID)), .count(2))
        expectEqual(FieldSummary.count(2).text, "2 items")
        expectEqual(s.summary([["street": "x"]], try s.field("rooms", of: FieldFixtures.kindsBID)), .count(1))
        expectEqual(FieldSummary.count(1).text, "1 item")
    },
    test("named pairs read the first pair, then how many more") {
        let s = try Summaries()
        let labels = try s.field("labels", of: FieldFixtures.kindsBID)
        expectEqual(s.summary(["size": "L", "weight": "heavy"], labels), .pair(first: "size: L", more: 1))
        expectEqual(FieldSummary.pair(first: "size: L", more: 1).text, "size: L, +1")
        expectEqual(s.summary(["size": "L"], labels), .pair(first: "size: L", more: 0))
        expectEqual(FieldSummary.pair(first: "size: L", more: 0).text, "size: L")
    },
    test("a plain value reads as the row shows it; an either reads as whichever branch the value is") {
        let s = try Summaries()
        let date = try s.field("due", of: FieldFixtures.kindsAID)
        expectEqual(s.summary("2026-03-03", date), .value("Mar 3, 2026"))
        expectEqual(s.summary(9.5, try s.field("price", of: FieldFixtures.kindsAID)), .value("9.5"))
        let size = try s.field("size", of: FieldFixtures.kindsBID)
        expectEqual(s.summary(12, size), .value("12"))
        expectEqual(s.summary("L", size), .value("L"))
        let payment = try s.field("payment", of: FieldFixtures.kindsBID)
        expectEqual(s.summary("cash", payment), .value("cash"), "the plain branch")
        expectEqual(s.summary(["cardNumber": "4242"], payment), .items(["4242"]), "the group branch")
        expectEqual(s.summary(true, payment), .value("true"), "a value no branch fits")
    },
    test("what no control suits reads as JSON; a link reads its stored value") {
        let s = try Summaries()
        expectEqual(s.summary(["a": 1], try s.field("anything", of: FieldFixtures.kindsBID)), .json)
        expectEqual(FieldSummary.json.text, "edited as JSON in the panel")
        expectEqual(s.summary("token", try s.field("customer", of: FieldFixtures.kindsBID)), .value("token"))
        expectEqual(s.summary(["a", "b"], try s.field("guests", of: FieldFixtures.kindsBID)), .value("a, b"))
        expectEqual(FieldSummary.pills(targets: ["Ann Lee", "Bo Park"], more: 1).text, "Ann Lee, Bo Park, +1")
    },
    test("nothing filled reads add and the name, faint italic: a missing value, one that is empty, a group of empties") {
        let s = try Summaries()
        let order = FieldFixtures.orderID
        expectEqual(s.summary(nil, try s.field("tags", of: order)), .empty("add tags"))
        expectEqual(s.summary([], try s.field("tags", of: order)), .empty("add tags"))
        expectEqual(s.summary(["", ""], try s.field("tags", of: order)), .empty("add tags"))
        expectEqual(s.summary(["city": ""], try s.field("shippingAddress", of: order)), .empty("add shipping address"))
        expectEqual(s.summary(nil, try s.field("lineItems", of: order)), .empty("add line items"))
        expectEqual(s.summary(nil, try s.field("anything", of: FieldFixtures.kindsBID)), .empty("add anything"), "even a field no control suits")
        expectEqual(s.summary(.null, try s.field("tags", of: order)), .empty("add tags"))
        expectEqual(FieldSummary.empty("add tags").text, "add tags")
        expectEqual(s.summary("", try s.field("giftNote", of: order)), .empty("add gift note"))
    },
    test("a type that is gone has no members: the stored object's string and number leaves, in key order") {
        let s = try Summaries()
        let gone = ShapeID()
        let field = try s.adHoc(#"{"$ref": "\#(FieldFixtures.uri(of: gone))"}"#)
        expectEqual(s.summary(["b": 2, "a": "x", "c": true, "d": ["e": "deep"]], field), .items(["x", "2", "deep"]))
        expectEqual(s.summary(["c": true], field), .empty("add f"))
    },
    test("a value of the wrong shape for its kind reads as JSON text, never fails") {
        let s = try Summaries()
        expectEqual(s.summary("text", try s.field("tags", of: FieldFixtures.orderID)), .value("text"))
        expectEqual(s.summary(["a": 1], try s.field("price", of: FieldFixtures.kindsAID)), .value(#"{"a":1}"#))
        expectEqual(s.summary("x", try s.field("lineItems", of: FieldFixtures.orderID)), .value("x"))
        expectEqual(s.summary(5, try s.field("venue", of: FieldFixtures.kindsAID)), .value("5"))
        expectEqual(s.summary(5, try s.field("labels", of: FieldFixtures.kindsBID)), .value("5"))
    },
])

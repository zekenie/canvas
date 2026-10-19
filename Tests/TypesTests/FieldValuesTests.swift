import Canvas
import CanvasRPC
import CanvasTesting
import Foundation
import TestKit
import Types

// `fieldValues`, what a shape holds for the fields of its types: over a memo, which opts in as a note
// does (`typeable()`). Nothing reads a type here: the value is one JSON object, empties never kept.

private func decoded(_ json: String) throws -> FieldValues {
    try JSONDecoder().decode(FieldValues.self, from: Data(json.utf8))
}

@MainActor let fieldValuesTests = Suite("Field values", [
    test("a kind that opts in holds `fieldValues`, as an object anyone writes, and the report says so; one that doesn't, doesn't") {
        let registry = try Registry(plugins: typePlugins())
        expect(registry.properties(for: Memo.kind).contains(FieldValuesProperty.key))
        expect(registry.isTypeable(Memo.kind))
        let schema = try require(registry.schema(for: Memo.kind))
        let property = try require(try JSONDecoder().decode(JSONValue.self, from: schema.data)["properties"]?["fieldValues"])
        expectEqual(property["x-canvas-owner"], .string("types"))
        expect(property["readOnly"] == nil, "people and agents write it")
        let definition = try require(try JSONDecoder().decode(JSONValue.self, from: schema.data)["$defs"]?["types.field-values"])
        expectEqual(definition["type"], .string("object"))
        let report = registry.report
        expect(report.contains("property fieldValues → memo"), report)
        let plain = try Registry(plugins: typePlugins() + [PocketsPlugin()])
        expect(!plain.properties(for: Pocket.kind).contains(FieldValuesProperty.key), "a kind that isn't typeable() doesn't hold it")
    },
    test("it is saved as the object it is and read back: numbers, a false, a group, a list of groups") {
        let values = FieldValues(["status": "paid", "gift": false, "count": 0, "price": 9.5,
                                  "address": ["city": "Leeds"],
                                  "lineItems": [["product": "Mug", "quantity": 2], ["product": "Plate", "quantity": 1]],
                                  "tags": ["gift", "mugs"]])
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(values)
        let object = try require(try JSONDecoder().decode(JSONValue.self, from: data).objectValue)
        expectEqual(object, values.values, "a bare object, no wrapper")
        expectEqual(try JSONDecoder().decode(FieldValues.self, from: data), values)
        expectEqual(values["gift"], .bool(false))
        expectEqual(values["count"], .number(0))
    },
    test("empty at any depth is not kept: read, made and set") {
        let none = FieldValues()
        let rows: [(String, FieldValues)] = [
            (#"{"a":null}"#, none), (#"{"a":""}"#, none), (#"{"a":[]}"#, none), (#"{"a":{}}"#, none),
            (#"{"a":{"b":{"c":""}}}"#, none), (#"{"a":["", null, {}, []]}"#, none),
            (#"{"a":["x","","y"]}"#, FieldValues(["a": ["x", "y"]])),
            (#"{"a":[{"p":"Mug","q":0},{"p":""}]}"#, FieldValues(["a": [["p": "Mug", "q": 0]]])),
            (#"{"i":false,"j":0,"k":" "}"#, FieldValues(["i": false, "j": 0, "k": " "])),
        ]
        for (json, expected) in rows {
            let object = try require(try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)).objectValue)
            expectEqual(try decoded(json), expected, "read: \(json)")
            expectEqual(FieldValues(object), expected, "made: \(json)")
            var set = FieldValues()
            for (field, value) in object { set[field] = value }
            expectEqual(set, expected, "set: \(json)")
        }
        expect(none.isEmpty)
        expect(!FieldValues(["j": 0]).isEmpty)
        var values = FieldValues(["a": "x"])
        values["a"] = nil
        expect(values.isEmpty, "setting nil removes it")
        values["a"] = "x"
        values["a"] = .null
        expect(values.isEmpty, "setting null removes it")
        values["a"] = "x"
        values["a"] = ""
        expect(values.isEmpty, "setting something empty removes it")
        expect(FieldValues.pruned(.array([.null, "", .object([:])])) == nil)
        expectEqual(FieldValues.pruned(.number(0)), .number(0))
    },
    test("a record with only empties holds no value; one set to none loses the property") {
        var record = ShapeRecord(id: ShapeID(), memo("an order"))
        record[FieldValuesProperty.self] = FieldValues(["a": ""])
        expectEqual(record[FieldValuesProperty.self], nil)
        record[FieldValuesProperty.self] = FieldValues(["status": "paid"])
        expectEqual(record[FieldValuesProperty.self]?["status"], .string("paid"))
        record[FieldValuesProperty.self] = FieldValues()
        expectEqual(record[FieldValuesProperty.self], nil, "the property comes off")
    },
    test("a write is one step, and undo and redo take it off and put it back") {
        let editor = try typeEditor()
        let order = editor.addInstance("Order 12", of: [])
        expectEqual(editor.document[order]?[FieldValuesProperty.self], nil)
        let before = editor.undoHistory.undoName
        editor.transact("Fill") { $0.update(order) { $0[FieldValuesProperty.self] = FieldValues(["status": "paid"]) } }
        expectEqual(editor.document[order]?[FieldValuesProperty.self], FieldValues(["status": "paid"]))
        expectEqual(editor.undoHistory.undoName, "Fill")
        editor.undo()
        expectEqual(editor.document[order]?[FieldValuesProperty.self], nil)
        expectEqual(editor.undoHistory.undoName, before, "one step")
        editor.redo()
        expectEqual(editor.document[order]?[FieldValuesProperty.self], FieldValues(["status": "paid"]))
    },
])

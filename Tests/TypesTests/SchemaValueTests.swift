import Canvas
import CanvasRPC
import TestKit
import Types

// A schema as it was written (`SchemaValue`): objects keep the order of their members.

private func read(_ text: String) throws -> SchemaValue { SchemaValue(try JSONReader.read(text)) }

@MainActor let schemaValueTests = Suite("A schema as it was written", [
    test("an object's members keep the order they were written in, nested ones too") {
        let value = try read(#"{"b": 1, "a": {"z": true, "y": null}, "c": [{"q": "x", "p": 2.5}]}"#)
        expectEqual(value.members?.map(\.key), ["b", "a", "c"])
        expectEqual(value["a"]?.members?.map(\.key), ["z", "y"])
        expectEqual(value["c"]?.elements?.first?.members?.map(\.key), ["q", "p"])
        expectEqual(value["b"]?.number, 1)
        expectEqual(value["a"]?["z"]?.bool, true)
        expectEqual(value["a"]?["y"], SchemaValue.null)
        expectEqual(value["c"]?.elements?.first?["q"]?.string, "x")
        expectEqual(value["missing"], nil)
        expect(value.isObject)
        expect(!(value["b"]?.isObject ?? true))
    },
    test("order is part of equality: the same members in another order are another schema") {
        expect(try read(#"{"a": 1, "b": 2}"#) != read(#"{"b": 2, "a": 1}"#))
        expectEqual(try read(#"{"a": 1, "b": 2}"#), try read(#"{ "a" : 1,"b":2 }"#))
    },
    test("a name written twice is the last value at the first's place") {
        let value = try read(#"{"a": 1, "b": 2, "a": 3}"#)
        expectEqual(value.members, [SchemaMember(key: "a", value: .number(3)), SchemaMember(key: "b", value: .number(2))])
    },
    test("it is the core's JSON without the order, and the core's JSON read back has its keys in order") {
        let value = try read(#"{"b": [1, {"d": null, "c": "x"}], "a": false}"#)
        let json = value.json
        expectEqual(json, .object(["a": .bool(false), "b": .array([.number(1), .object(["c": .string("x"), "d": .null])])]))
        expectEqual(SchemaValue(json).members?.map(\.key), ["a", "b"], "sorted: there is no order to keep")
        expectEqual(SchemaValue(json).json, json)
        expectEqual(SchemaValue(json)["b"]?.elements?[1].members?.map(\.key), ["c", "d"])
    },
    test("the JSON it makes of a duplicate name made by hand is the last, not a crash") {
        let value = SchemaValue.object([SchemaMember(key: "a", value: .number(1)), SchemaMember(key: "a", value: .number(2))])
        expectEqual(value.json, .object(["a": .number(2)]))
    },
])

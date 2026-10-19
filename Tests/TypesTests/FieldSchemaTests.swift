import Canvas
import CanvasRPC
import Foundation
import TestKit
import Types

// The schema the check reads (`FieldSchemas.checkable`): the five rewrites of a composed schema, on
// values, with the core's validator to say what they mean. No editor.

private func json(_ text: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }

/// The violations of `value` against `schema`, as the check reads it.
@MainActor private func violations(_ schema: String, _ value: String, checkable: Bool = true) throws -> [SchemaViolation] {
    var schema = try json(schema)
    if checkable { schema = FieldSchemas.checkable(schema) }
    return SchemaValidator(JSONSchema(try require(schema.objectValue)), formats: .standard).violations(of: try json(value))
}

@MainActor private func keywords(_ schema: String, _ value: String) throws -> [String] {
    try violations(schema, value).map { "\($0.keyword)@\($0.pointer)" }
}

private struct Random {
    var state: UInt64
    mutating func next(_ bound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(bound))
    }
}

@MainActor let fieldSchemaTests = Suite("The schema the check reads", [
    test("T1: a pattern ICU cannot read leaves, a readable one stays, and so does a pattern property's") {
        let broken = #"{"type": "object", "properties": {"code": {"type": "string", "pattern": "([a-z"}}}"#
        expectEqual(FieldSchemas.checkable(try json(broken))["properties"]?["code"]?["pattern"], nil)
        let pairs = FieldSchemas.checkable(try json(#"{"type": "object", "patternProperties": {"([": {"type": "string"}, "^x": {"type": "number"}}}"#))
        expectEqual(pairs["patternProperties"]?["(["], nil)
        expect(pairs["patternProperties"]?["^x"] != nil)
        expectEqual(try keywords(broken, #"{"code": "A1"}"#), [], "the type's fault is not the note's")
        let fine = #"{"type": "object", "properties": {"code": {"type": "string", "pattern": "^[a-z]+$"}}}"#
        expectEqual(FieldSchemas.checkable(try json(fine)), try json(fine))
        expectEqual(try keywords(fine, #"{"code": "A1"}"#), ["pattern@/code"])
        let only = FieldSchemas.checkable(try json(#"{"patternProperties": {"([": {}}}"#))
        expectEqual(only["patternProperties"], nil, "none left, none kept")
    },
    test("T2: a group says nothing of members it does not name; a pairs field keeps what it says of its members") {
        let group = #"{"type": "object", "properties": {"a": {"type": "string"}, "b": {"type": "string"}, "c": {"type": "string"}}, "additionalProperties": false, "maxProperties": 3, "minProperties": 2, "propertyNames": {"maxLength": 2}, "patternProperties": {"^x": {"type": "number"}}}"#
        let made = FieldSchemas.checkable(try json(group))
        for key in ["additionalProperties", "propertyNames", "patternProperties", "maxProperties", "unevaluatedProperties"] { expectEqual(made[key], nil, key) }
        expect(made["minProperties"] != nil, "an unnamed member can only help meet it")
        expectEqual(try keywords(group, #"{"a": "x", "b": "x", "c": "x", "xtra": "y", "xtraLong": 1}"#), [], "a fourth, unnamed member breaks nothing")
        expectEqual(try keywords(group, #"{"a": "x"}"#), ["minProperties@"], "filling 1 of 3 of a group of at least two")
        expectEqual(try keywords(group, #"{"a": "x", "zzz": 1}"#), [], "an unnamed member helps meet it")
        let pairs = #"{"type": "object", "additionalProperties": {"type": "string"}, "propertyNames": {"maxLength": 5}, "minProperties": 1, "maxProperties": 2}"#
        let kept = FieldSchemas.checkable(try json(pairs))
        expect(kept["additionalProperties"] != nil && kept["propertyNames"] != nil && kept["maxProperties"] != nil, "a pairs field's rules")
        expectEqual(try keywords(pairs, #"{"toolong": "x", "b": "y", "c": "z"}"#).sorted(), ["maxProperties@", "propertyNames@/toolong"])
        let strict = FieldSchemas.checkable(try json(#"{"type": "object", "additionalProperties": false}"#))
        expectEqual(strict["additionalProperties"], nil, "T2b: a false goes from anywhere")
    },
    test("T2 reaches the groups inside a group and an item") {
        let nested = #"{"type": "object", "properties": {"items": {"type": "array", "items": {"type": "object", "properties": {"a": {"type": "string"}}, "additionalProperties": false}}, "box": {"type": "object", "properties": {"x": {"type": "number"}}, "maxProperties": 1}}}"#
        expectEqual(try keywords(nested, #"{"items": [{"a": "x", "extra": 1}], "box": {"x": 1, "y": 2}}"#), [])
    },
    test("T3: dependentSchemas becomes an if the validator enforces") {
        let schema = #"{"type": "object", "properties": {"a": {"type": "string"}, "b": {"type": "string"}}, "dependentSchemas": {"a": {"required": ["b"]}}}"#
        let made = FieldSchemas.checkable(try json(schema))
        expectEqual(made["dependentSchemas"], nil)
        expectEqual(try keywords(schema, #"{"a": "x"}"#), ["required@/b"])
        expectEqual(try keywords(schema, #"{"a": "x", "b": "y"}"#), [])
        expectEqual(try keywords(schema, "{}"), [], "without a, nothing is asked")
        expectEqual(try violations(schema, #"{"a": "x"}"#, checkable: false).count, 0, "the core ignores it")
    },
    test("T4: an if on fields asks for its then only once the fields have values; its else is not applied to a note that never said") {
        let gift = #"{"type": "object", "properties": {"gift": {"type": "boolean"}, "giftNote": {"type": "string"}, "plain": {"type": "string"}}, "if": {"properties": {"gift": {"const": true}}}, "then": {"required": ["giftNote"]}, "else": {"required": ["plain"]}}"#
        expectEqual(try keywords(gift, "{}"), [], "an empty object is not asked for a gift note, nor a plain one")
        expectEqual(try keywords(gift, #"{"gift": true}"#), ["required@/giftNote"])
        expectEqual(try keywords(gift, #"{"gift": true, "giftNote": "x"}"#), [])
        expectEqual(try keywords(gift, #"{"gift": false}"#), ["required@/plain"], "an else runs only with the tested field present")
        expectEqual(try keywords(gift, #"{"gift": false, "plain": "x"}"#), [])
        expectEqual(try keywords(gift, #"{"plain": "x"}"#), [], "gift never set")
        // The same rule with the test's own `required`: a test that lists what it tests.
        let listed = #"{"type": "object", "properties": {"gift": {"type": "boolean"}, "giftNote": {"type": "string"}, "plain": {"type": "string"}}, "if": {"properties": {"gift": {"const": true}}, "required": ["gift"]}, "then": {"required": ["giftNote"]}, "else": {"required": ["plain"]}}"#
        expectEqual(try keywords(listed, "{}"), [], "the author's else is not asked of an empty object")
        expectEqual(try keywords(listed, #"{"gift": true}"#), ["required@/giftNote"])
        expectEqual(try keywords(listed, #"{"gift": false}"#), ["required@/plain"])
        expectEqual(try violations(listed, "{}", checkable: false).count, 1, "as the core reads it, the else asks")
        // A test one level down asks for the outer member and the inner.
        let deep = #"{"type": "object", "properties": {"address": {"type": "object", "properties": {"country": {"type": "string"}}}, "state": {"type": "string"}}, "if": {"properties": {"address": {"properties": {"country": {"const": "US"}}}}}, "then": {"required": ["state"]}}"#
        expectEqual(try keywords(deep, "{}"), [])
        expectEqual(try keywords(deep, #"{"address": {"country": "US"}}"#), ["required@/state"])
        expectEqual(try keywords(deep, #"{"address": {"country": "NZ"}}"#), [])
        expectEqual(try keywords(deep, #"{"address": {}}"#), [], "address without a country says nothing")
        // An if with no properties is the author's: presence is its test, and its else applies.
        let presence = #"{"type": "object", "properties": {"email": {"type": "string"}, "phone": {"type": "string"}}, "if": {"required": ["email"]}, "else": {"required": ["phone"]}}"#
        expectEqual(FieldSchemas.checkable(try json(presence)), try json(presence), "untouched")
        expectEqual(try keywords(presence, "{}"), ["required@/phone"])
        expectEqual(try keywords(presence, #"{"email": "a@b.c"}"#), [])
    },
    test("T5: at least one of: none satisfied asks for every field, half a branch asks for what it lacks") {
        let either = #"{"type": "object", "properties": {"phone": {"type": "string"}, "email": {"type": "string"}}, "anyOf": [{"required": ["phone"]}, {"required": ["email"]}]}"#
        expectEqual(try keywords(either, "{}").sorted(), ["required@/email", "required@/phone"])
        expectEqual(try keywords(either, #"{"phone": "1"}"#), [])
        expectEqual(try keywords(either, #"{"phone": "1", "email": "a"}"#), [])
        expectEqual(FieldSchemas.checkable(try json(either))["anyOf"], nil)
        let branches = #"{"type": "object", "properties": {"a": {}, "b": {}, "c": {}}, "anyOf": [{"required": ["a", "b"]}, {"required": ["c"]}]}"#
        expectEqual(try keywords(branches, #"{"a": 1}"#).sorted(), ["required@/b", "required@/c"], "a half-filled branch asks for what it lacks")
        expectEqual(try keywords(branches, #"{"c": 1}"#), [])
        let one = #"{"type": "object", "properties": {"a": {}, "b": {}}, "oneOf": [{"required": ["a"], "title": "A"}, {"required": ["b"]}]}"#
        expectEqual(try keywords(one, "{}").sorted(), ["required@/a", "required@/b"], "no oneOf violation when none is satisfied")
        expectEqual(try keywords(one, #"{"a": 1}"#), [])
        expectEqual(try keywords(one, #"{"a": 1, "b": 2}"#), ["oneOf@"], "two satisfied is the validator's own")
        let union = #"{"type": "object", "properties": {"size": {"anyOf": [{"type": "number"}, {"type": "string"}]}}}"#
        expectEqual(FieldSchemas.checkable(try json(union)), try json(union), "a union of kinds is left alone")
        expectEqual(try keywords(union, #"{"size": true}"#), ["anyOf@/size"])
    },
    test("a schema none of the five touch is returned equal, and the input is left as it was") {
        let plain = try json(#"{"type": "object", "properties": {"a": {"type": "integer", "minimum": 1}, "list": {"type": "array", "items": {"type": "string"}, "minItems": 1}}, "required": ["a"], "allOf": [{"required": ["list"]}]}"#)
        expectEqual(FieldSchemas.checkable(plain), plain)
        let touched = try json(#"{"type": "object", "properties": {"a": {}}, "additionalProperties": false, "dependentSchemas": {"a": {}}}"#)
        let before = touched
        _ = FieldSchemas.checkable(touched)
        expectEqual(touched, before)
    },
    test("for random schemas and values the output breaks wherever the input does, for the keywords the rewrites do not touch") {
        var random = Random(state: 11)
        let touched: Set<String> = ["pattern", "patternProperties", "additionalProperties", "propertyNames", "maxProperties", "minProperties", "required", "anyOf", "oneOf", "if", "then", "else", "dependentSchemas"]
        let leaves = [#"{"type": "string", "maxLength": 3}"#, #"{"type": "integer", "minimum": 2}"#, #"{"enum": ["x", "y"]}"#, #"{"type": "array", "items": {"type": "string"}, "minItems": 2}"#, #"{"type": "string", "format": "email"}"#]
        let values = [#""abcd""#, "1", #""z""#, #"["a"]"#, #""ann@""#, #""ok""#, "3"]
        for _ in 0..<150 {
            let count = 1 + random.next(4)
            let properties = (0..<count).map { "\"f\($0)\": \(leaves[random.next(leaves.count)])" }.joined(separator: ", ")
            let extras = [#", "additionalProperties": false"#, #", "maxProperties": 1"#, #", "propertyNames": {"maxLength": 1}"#, ""][random.next(4)]
            let schema = "{\"type\": \"object\", \"properties\": {\(properties)}\(extras)}"
            let members = (0..<count).filter { _ in random.next(2) == 0 }.map { "\"f\($0)\": \(values[random.next(values.count)])" }.joined(separator: ", ")
            let value = "{" + (members.isEmpty ? "" : members + ", ") + "\"unnamed\": 1}"
            let before = try violations(schema, value, checkable: false).filter { !touched.contains($0.keyword) }
            let after = try violations(schema, value)
            for violation in before { expect(after.contains(violation), "\(schema) \(value): \(violation)") }
            expect(!after.contains { touched.contains($0.keyword) && $0.keyword != "minProperties" }, "\(schema) \(value): \(after)")
        }
    },
])

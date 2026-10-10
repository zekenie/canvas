@_spi(Host) import Canvas
import CanvasTesting
import Foundation
import TestKit

/// Every keyword the validator reports, each with a value that breaks it.
private let breaking: [(schema: JSONObject, value: JSONValue)] = [
    (["type": "string"], 1),
    (["enum": ["a", "b"]], "c"),
    (["const": 3], 4),
    (["minimum": 1], 0),
    (["maximum": 1], 2),
    (["exclusiveMinimum": 1], 1),
    (["exclusiveMaximum": 1], 1),
    (["multipleOf": 3], 4),
    (["minLength": 2], ""),
    (["minLength": 2], "a"),
    (["maxLength": 2], "abc"),
    (["pattern": "^a"], "b"),
    (["items": false, "prefixItems": [["type": "number"]]], [1, 2]),
    (["contains": ["const": 1]], [2]),
    (["contains": ["const": 1], "minContains": 2], [1]),
    (["contains": ["const": 1], "maxContains": 1], [1, 1]),
    (["minItems": 2], [1]),
    (["maxItems": 1], [1, 2]),
    (["uniqueItems": true], [1, 1]),
    (["required": ["a"]], [:]),
    (["dependentRequired": ["a": ["b"]]], ["a": 1]),
    (["propertyNames": ["maxLength": 1]], ["ab": 1]),
    (["properties": ["a": [:]], "additionalProperties": false], ["a": 1, "b": 2]),
    (["minProperties": 2], [:]),
    (["maxProperties": 0], ["a": 1]),
    (["anyOf": [["type": "string"], ["type": "null"]]], 1),
    (["oneOf": [["type": "number"], ["minimum": 0]]], 1),
    (["not": ["type": "number"]], 1),
    (["properties": ["a": false]], ["a": 1]),
]

@MainActor let schemaFormatTests = Suite("Schema formats", [
    test("a violation's message is the place's name and its detail, and the detail never starts with the place") {
        for (schema, value) in breaking {
            let violations = SchemaValidator(JSONSchema(schema)).violations(of: value)
            expect(!violations.isEmpty, "\(schema) found nothing in \(value)")
            for violation in violations {
                expect(violation.message.hasSuffix(" " + violation.detail), "\(violation.message) / \(violation.detail)")
                expect(violation.message.count > violation.detail.count + 1, "\(violation.message) has a name before its detail")
                expect(!violation.detail.hasPrefix("The value"), violation.detail)
            }
        }
    },
    test("details say what is wrong without the place") {
        let schema = JSONSchema(["type": "object", "properties": [
            "email": ["type": "string", "maxLength": 3],
            "age": ["type": "integer", "minimum": 1],
        ], "required": ["name"]])
        let details = SchemaValidator(schema).violations(of: ["email": "abcd", "age": 0]).map(\.detail)
        expectEqual(details, ["is missing.", "is 0, and should be at least 1.", "is 4 characters long, and should be at most 3."])
    },
    test("a violation made by hand, with no detail, equals the validator's and hashes the same") {
        let made = SchemaValidator(JSONSchema(["minimum": 1])).violations(of: 0)[0]
        let byHand = SchemaViolation(path: made.path, keyword: made.keyword, message: made.message)
        expectEqual(byHand, made)
        expectEqual(byHand.hashValue, made.hashValue)
        expectEqual(byHand.detail, byHand.message)
        expectEqual(Set([made, byHand]).count, 1)
    },
])

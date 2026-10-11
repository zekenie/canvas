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

@MainActor private func fits(_ format: String, _ value: JSONValue, with formats: SchemaFormats = .standard) -> Bool {
    SchemaValidator(JSONSchema(["format": .string(format)]), formats: formats).violations(of: value).isEmpty
}

@MainActor private func expectFits(_ format: String, good: [String], bad: [String]) {
    for value in good { expect(fits(format, .string(value)), "\(format) should fit \(value)") }
    for value in bad { expect(!fits(format, .string(value)), "\(format) should not fit \(value)") }
}

@MainActor let schemaFormatCheckTests = Suite("Schema formats checked", [
    test("off by default: the core's own uuid and date-time schemas, and any format, check as before") {
        for (format, value) in [("email", "ann@"), ("date", "Jan 2024"), ("date-time", "x"), ("time", "x"), ("uri", "acme.com"), ("uuid", "x")] {
            expect(fits(format, .string(value), with: .none), "\(format) is an annotation")
            expect(SchemaValidator(JSONSchema(["format": .string(format)])).violations(of: .string(value)).isEmpty, "\(format) is an annotation by default")
        }
    },
    test("date") {
        expectFits("date", good: ["2024-02-29", "2026-03-03", "1999-12-31"], bad: ["2023-02-29", "2026-13-01", "2026-00-10", "2026-04-31", "Jan 2024", "3/3/26", "2026-3-3", "2026-03-03T"])
    },
    test("time") {
        expectFits("time", good: ["09:30:00Z", "09:30:00.123Z", "09:30:00+05:30", "09:30:00-08:00", "23:59:60Z", "09:30:00z"],
                   bad: ["24:00:00Z", "09:30:00", "09:60:00Z", "09:30:00.Z", "09:30:00+5:30", "09:30:00+24:00", "9:30:00Z"])
    },
    test("date-time") {
        expectFits("date-time", good: ["2026-03-03T09:30:00Z", "2026-03-03t09:30:00.5+01:00"],
                   bad: ["2026-03-03", "2026-03-03 09:30:00Z", "2026-02-30T09:30:00Z", "2026-03-03T09:30:00"])
    },
    test("uuid") {
        expectFits("uuid", good: ["123e4567-e89b-12d3-a456-426614174000", "123E4567-E89B-12D3-A456-426614174000"],
                   bad: ["123e4567e89b12d3a456426614174000", "123e4567-e89b-12d3-a456-42661417400g", "123e4567-e89b-12d3-a456-4266141740000"])
    },
    test("email") {
        expectFits("email", good: ["bo@acme.com", "bo@acme", "a.b+c@x-y.org"],
                   bad: ["ann@", "@acme.com", "a..b@x.com", "a@-x.com", "a b@x.com", String(repeating: "a", count: 65) + "@x.com", "a@b@c.com", "ann", ".a@x.com", "a.@x.com", "a@x..com", "a@x-.com"])
    },
    test("uri") {
        expectFits("uri", good: ["https://acme.com/a%20b", "mailto:a@b.c", "urn:uuid:123", "https://a.com/?q=1#top"],
                   bad: ["acme.com", "https://a b", "%zz", "https://a.com/%zz", "https://a.com/<", "a:", "1http://x", "https://a.com/#a#b", "https://é.com"])
    },
    test("only strings are format-checked, and a format the table lacks stays an annotation") {
        expect(fits("email", 3))
        expect(fits("email", .null))
        expect(fits("hostname", "not a host"))
        let validator = SchemaValidator(JSONSchema(["format": "email"]), formats: .standard)
        let violation = try require(validator.violations(of: "ann@").first)
        expectEqual(violation.keyword, "format")
        expectEqual(violation.message, "The value should be an email address, not \"ann@\".")
        expectEqual(violation.detail, "should be an email address, not \"ann@\".")
        let titled = SchemaValidator(JSONSchema(["properties": ["when": ["type": "string", "title": "Due", "format": "date"]]]), formats: .standard)
        expectEqual(titled.violations(of: ["when": "Jan 2024"]).map(\.message), ["Due should be a date like 2026-03-03, not \"Jan 2024\"."])
        expectEqual(titled.violations(of: ["when": "2026-03-03"]).count, 0)
    },
    test("both initializers take the formats, and a resource's format is checked too") {
        let schema = JSONSchema(["properties": ["owner": ["$ref": "urn:uuid:x"]]])
        let validator = SchemaValidator(schema, formats: .standard) { uri in
            uri == "urn:uuid:x" ? JSONSchema(["properties": ["email": ["format": "email"]]]) : nil
        }
        expectEqual(validator.problems, [])
        expectEqual(validator.resources, ["urn:uuid:x"])
        expectEqual(validator.violations(of: ["owner": ["email": "ann@"]]).map(\.keyword), ["format"])
        expectEqual(validator.violations(of: ["owner": ["email": "bo@acme.com"]]).count, 0)
        let plain = SchemaValidator(schema) { _ in JSONSchema(["properties": ["email": ["format": "email"]]]) }
        expectEqual(plain.violations(of: ["owner": ["email": "ann@"]]).count, 0)
    },
])

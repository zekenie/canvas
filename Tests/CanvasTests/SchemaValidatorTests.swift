@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import TestKit

/// Where `value` breaks `schema`, a line each: "pointer keyword: message".
private func check(_ schema: JSONObject, _ value: JSONValue) -> [String] {
    JSONSchema(schema).violations(of: value).map(\.description)
}

/// A motto, at most 10 characters, on the shapes it's given.
enum Motto {}
extension Motto: ShapeProperty {
    static let key: PropertyKey = "motto"
    static var defaultValue: String? { nil }
    static var keywords: PropertyKeywords<String> {
        PropertyKeywords().description("What it lives by.").maxLength(10).examples("Carpe diem")
    }
}

/// When it was stamped: a date, which a board writes in ISO 8601.
enum StampedAt {}
extension StampedAt: ShapeProperty {
    static let key: PropertyKey = "stamp"
    static var defaultValue: Date? { nil }
}

/// Samples (SchemaTests'), with mottos and stamps.
@MainActor private func samples() throws -> Registry {
    try Registry(plugins: [FixturesPlugin(), Contributor(id: "samples") { r in
        r.shape(PlainDefinition<Sample>())
        r.declare(Motto.self)
        r.declare(StampedAt.self)
        r.optIn(Sample.self, to: Motto.self)
        r.optIn(Sample.self, to: StampedAt.self)
    }])
}

/// What a closure run while the registry is built made, for the test to take.
@MainActor private final class Kept<Value> {
    var value: Value?
}

@MainActor let schemaValidatorTests = Suite("Checking against a schema", [
    test("a value that holds up has nothing to say; each keyword finds what breaks it, at its place: listed members in order, then the rest") {
        let schema: JSONObject = [
            "type": "object",
            "properties": [
                "name": ["type": "string", "minLength": 2, "maxLength": 5, "pattern": "^[a-z]+$"],
                "count": ["type": "integer", "minimum": 0, "maximum": 10, "multipleOf": 2],
                "ratio": ["type": "number", "exclusiveMinimum": 0, "exclusiveMaximum": 1],
                "tags": ["type": "array", "items": ["type": "string"], "minItems": 1, "maxItems": 3, "uniqueItems": true],
                "mood": ["enum": ["calm", "busy"]],
                "kind": ["const": "sample"],
            ],
            "required": ["name", "kind"],
            "additionalProperties": false,
        ]
        expectEqual(check(schema, ["name": "kite", "count": 4, "ratio": 0.5, "tags": ["a"], "mood": "calm", "kind": "sample"]), [])
        expectEqual(check(schema, ["name": "Kite and more", "count": 11, "ratio": 1, "tags": ["a", "a", "b", "c"], "mood": "sad",
                                   "extra": true]), [
            "/kind required: Kind is missing.",
            "/count maximum: Count is 11, and should be at most 10.",
            "/count multipleOf: Count is 11, and should be a multiple of 2.",
            "/mood enum: Mood should be \"calm\" or \"busy\".",
            "/name maxLength: Name is 13 characters long, and should be at most 5.",
            "/name pattern: Name should match ^[a-z]+$.",
            "/ratio exclusiveMaximum: Ratio is 1, and should be less than 1.",
            "/tags maxItems: Tags has 4 items, and should have at most 3.",
            "/tags uniqueItems: Tags has the same item more than once.",
            "/extra additionalProperties: Extra isn't one of the value's properties.",
        ])
        expectEqual(check(schema, ["name": "", "kind": "other", "ratio": 0, "count": -2, "tags": []]), [
            "/count minimum: Count is -2, and should be at least 0.",
            "/kind const: Kind should be \"sample\".",
            "/name minLength: Name is empty.",
            "/name pattern: Name should match ^[a-z]+$.",
            "/ratio exclusiveMinimum: Ratio is 0, and should be more than 0.",
            "/tags minItems: Tags has 0 items, and should have at least 1.",
        ])
    },
    test("a value of the wrong type is all that's said of it; a number a board writes as \"nan\" is a string") {
        let schema: JSONObject = ["type": "object", "properties": [
            "estimate": ["type": "number", "minimum": 0], "done": ["type": "boolean"], "when": ["type": ["string", "null"]],
            "steps": ["type": "integer"],
        ]]
        expectEqual(check(schema, ["estimate": "nan", "done": 1, "when": 3, "steps": 2.5]), [
            "/done type: Done should be true or false, not 1.",
            "/estimate type: Estimate should be a number, not \"nan\".",
            "/steps type: Steps should be a whole number, not 2.5.",
            "/when type: When should be a string or null, not 3.",
        ])
        expectEqual(check(schema, ["estimate": 0, "done": false, "when": nil, "steps": 2]), [])
        expectEqual(check(schema, [1, 2]), ["/ type: The value should be an object, not an array."])
    },
    test("lengths are in code points, as JSON Schema counts them, not characters on screen") {
        let schema: JSONObject = ["maxLength": 2]
        expectEqual(check(schema, "é"), [], "one code point, precomposed")
        expectEqual(check(schema, "👍🏽"), [], "a thumbs-up and its skin tone: two")
        expectEqual(check(schema, "👍🏽!"), ["/ maxLength: The value is 3 characters long, and should be at most 2."])
    },
    test("titles name the places they describe, and paths the rest: a member, an element as its item's number") {
        let schema: JSONObject = [
            "title": "Sample", "type": "object", "required": ["frame"],
            "properties": [
                "est": ["title": "Estimate", "minimum": 0],
                "parts": ["items": ["properties": ["label": ["maxLength": 3]]]],
            ],
        ]
        expectEqual(check(schema, ["est": -1, "parts": [["label": "ok"], ["label": "long"]]]), [
            "/frame required: Frame is missing.",
            "/est minimum: Estimate is -1, and should be at least 0.",
            "/parts/1/label maxLength: Parts › item 2 › label is 4 characters long, and should be at most 3.",
        ])
        expectEqual(check(schema, "x"), ["/ type: Sample should be an object, not \"x\"."])
    },
    test("$ref reaches any place in the schema, a type that holds itself included; one to a place it doesn't have says so") {
        let tree: JSONObject = [
            "$defs": ["node": ["type": "object", "properties": [
                "name": ["type": "string", "maxLength": 3],
                "children": ["type": "array", "items": ["$ref": "#/$defs/node"]],
            ]]],
            "$ref": "#/$defs/node",
        ]
        let value: JSONValue = ["name": "root", "children": [["name": "a"], ["name": "b", "children": [["name": "long"]]]]]
        expectEqual(check(tree, value), [
            "/children/1/children/0/name maxLength: Children › item 2 › children › item 1 › name is 4 characters long, and should be at most 3.",
            "/name maxLength: Name is 4 characters long, and should be at most 3.",
        ])
        expectEqual(check(["$defs": ["a/b": ["maxLength": 1]], "$ref": "#/$defs/a~1b"], "xy"),
                    ["/ maxLength: The value is 2 characters long, and should be at most 1."], "a pointer's / and ~, escaped")
        expectEqual(check(["properties": ["a": ["$ref": "#/$defs/missing"]]], ["a": 1]),
                    ["/a $ref: A can't be checked: its schema refers to #/$defs/missing, which isn't in it."])
        expectEqual(check(["properties": ["a": ["$ref": "https://example.com/schema"]]], ["a": 1]).map { $0.hasPrefix("/a $ref:") }, [true],
                    "only local references")
    },
    test("allOf adds its forms' checks; anyOf and oneOf want a form that fits, one for oneOf; not wants none; if picks then or else") {
        let schema: JSONObject = ["properties": [
            "both": ["allOf": [["type": "string"], ["maxLength": 2]]],
            "any": ["anyOf": [["type": "string"], ["type": "number"]]],
            "one": ["oneOf": [["type": "number"], ["type": "integer"]]],
            "none": ["not": ["type": "string"]],
            "cond": ["if": ["type": "string"], "then": ["minLength": 3], "else": ["minimum": 10]],
        ]]
        expectEqual(check(schema, ["both": "abc", "any": true, "one": 2, "none": "x", "cond": "ab"]), [
            "/any anyOf: Any doesn't fit any of its forms.",
            "/both maxLength: Both is 3 characters long, and should be at most 2.",
            "/cond minLength: Cond is 2 characters long, and should be at least 3.",
            "/none not: None fits a form it shouldn't.",
            "/one oneOf: One fits more than one of its forms.",
        ])
        expectEqual(check(schema, ["one": 2.5, "cond": 3]), ["/cond minimum: Cond is 3, and should be at least 10."])
        expectEqual(check(schema, ["one": "x", "cond": "abc", "any": 1, "none": 1]), ["/one oneOf: One doesn't fit any of its forms."])
        expectEqual(check(["properties": ["no": false]], ["no": 1]), ["/no false: No isn't allowed here."])
    },
    test("arrays: prefixItems, then items for the rest, or none past them with items false; contains counts the items that fit") {
        let schema: JSONObject = ["properties": [
            "pair": ["prefixItems": [["type": "number"], ["type": "string"]], "items": false],
            "list": ["prefixItems": [["type": "number"]], "items": ["type": "string"]],
            "some": ["contains": ["type": "number"], "minContains": 2, "maxContains": 3],
            "any": ["contains": ["type": "number"]],
        ]]
        expectEqual(check(schema, ["pair": [1, "a"], "list": [1, "a", "b"], "some": [1, "x", 2], "any": ["x", 1]]), [])
        expectEqual(check(schema, ["pair": [1, "a", true], "list": [1, 2], "some": [1, "x"], "any": ["x"]]), [
            "/any contains: Any has no item that fits.",
            "/list/1 type: List › item 2 should be a string, not 2.",
            "/pair items: Pair has 3 items, and should have at most 2.",
            "/some contains: Some has 1 item that fits, and should have at least 2.",
        ])
        expectEqual(check(schema, ["some": [1, 2, 3, 4]]), ["/some maxContains: Some has 4 items that fit, and should have at most 3."])
    },
    test("objects: patternProperties, then additionalProperties for the rest; propertyNames, dependentRequired, and their count") {
        let schema: JSONObject = [
            "patternProperties": ["^x-": ["type": "string"]],
            "additionalProperties": ["type": "number"],
            "propertyNames": ["maxLength": 6],
            "dependentRequired": ["start": ["end"]],
            "minProperties": 1, "maxProperties": 3,
        ]
        expectEqual(check(schema, ["x-note": "hi", "start": 1, "end": 2]), [])
        expectEqual(check(schema, ["x-note": 1, "start": 1, "overlong": 2, "big": "no"]), [
            "/end dependentRequired: End is missing, which start needs.",
            "/big type: Big should be a number, not \"no\".",
            "/overlong propertyNames: overlong isn't a name the value allows.",
            "/x-note type: X-note should be a string, not 1.",
            "/ maxProperties: The value has 4 properties, and should have at most 3.",
        ])
        expectEqual(check(schema, [:]), ["/ minProperties: The value has 0 properties, and should have at least 1."])
    },
    test("a violation's pointer escapes / and ~; its property is the root's member it's in, if any") {
        let violation = SchemaViolation(path: [.member("a/b~c"), .element(2), .member("d")], keyword: "type", message: "")
        expectEqual(violation.pointer, "/a~1b~0c/2/d")
        expectEqual(violation.property, "a/b~c")
        expectEqual(SchemaViolation(path: [], keyword: "type", message: "").property, nil)
        expectEqual(SchemaViolation(path: [.element(0)], keyword: "type", message: "").property, nil)
    },

    // MARK: Shapes

    test("an added property's keywords are in each kind's schema that opts in, beside its type") {
        let registry = try samples()
        let json = try require(registry.schema(for: Sample.kind)).json
        expectEqual(json["properties"]?["motto"], ["type": "string", "description": "What it lives by.", "maxLength": 10,
                                                   "examples": ["Carpe diem"], "x-canvas-owner": "samples"])
        expectEqual(json["properties"]?["stamp"], ["type": "string", "format": "date-time", "x-canvas-owner": "samples"])
    },
    test("a shape's properties, own and added, are one object, each as its schema describes it: dates, rects, NaN and all") {
        let registry = try samples()
        var sample = ShapeRecord(Sample())
        sample.props.frame = CGRect(x: 1, y: 2, width: 3, height: 4)
        sample.props.due = Date(timeIntervalSince1970: 1_790_000_000)
        sample.props.parts = [Sample.Part(label: "tail")]
        sample.props.target = ShapeID(UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
        sample.props.step = .infinity
        sample[Motto.self] = "Onward"
        sample[StampedAt.self] = Date(timeIntervalSince1970: 1_790_000_000)
        var expected = try require(try JSONDecoder().decode(JSONValue.self, from: BoardCodec(registry: registry).encodeProps(sample.props)).objectValue)
        expectEqual(expected["due"], "2026-09-21T14:13:20Z")
        expectEqual(expected["step"], "inf")
        expected["motto"] = "Onward"
        expected["stamp"] = "2026-09-21T14:13:20Z"
        expectEqual(AnyShapeRecord(sample).propertiesJSON, expected)
    },
    test("a shape is checked against its kind's schema, its own properties and added ones as one object; each bound it breaks is said once") {
        let registry = try samples()
        var sample = ShapeRecord(Sample())
        expectEqual(registry.schemaViolations(of: AnyShapeRecord(sample)), [])
        sample.props.name = String(repeating: "n", count: 41)
        sample.props.count = -1
        sample.props.step = 0.7
        sample[Motto.self] = "Carpe diem, quam minimum"
        let found = registry.schemaViolations(of: AnyShapeRecord(sample))
        expectEqual(found.map(\.description), [
            "/count minimum: Count is -1, and should be at least 0.",
            "/motto maxLength: Motto is 24 characters long, and should be at most 10.",
            "/name maxLength: Name is 41 characters long, and should be at most 40.",
            "/step multipleOf: Step is 0.7, and should be a multiple of 0.5.",
        ])
        expectEqual(found.map(\.property), ["count", "motto", "name", "step"])
        sample.props.step = .nan
        expectEqual(registry.schemaViolations(of: AnyShapeRecord(sample)).last?.description, "/step type: Step should be a number, not \"nan\".")
    },
    test("a shape kept aside, or of a kind no plugin registers, isn't checked") {
        let registry = try samples()
        let board = #"{ "format" : 1, "schema" : {}, "shapes" : [ { "id" : "11111111-1111-1111-1111-111111111111", "index" : "a0", "kind" : "mystery", "props" : { "name" : 12 } } ] }"#
        let kept = try require(try BoardCodec(registry: registry).decode(Data(board.utf8)).document.shapes.first)
        expect(kept.isOpaque)
        expectEqual(kept.propertiesJSON, nil)
        expectEqual(registry.schemaViolations(of: kept), [])
        expectEqual(try Registry(plugins: [FixturesPlugin()]).schemaViolations(of: AnyShapeRecord(ShapeRecord(Sample()))), [])
    },
    test("a placement can set an added property on what it places; a kind that doesn't opt in drops it") {
        let kept = Kept<Placement>(), boxes = Kept<Placement>()
        let registry = try Registry(plugins: [FixturesPlugin(), Contributor(id: "samples") { r in
            r.shape(PlainDefinition<Sample>()) { sample in
                kept.value = sample.placement(size: CGSize(width: 10, height: 10)) { Sample() }.setting(Motto.self, to: "Hi")
            }
            r.shape(PlainDefinition<Unmotivated>()) { plain in
                boxes.value = plain.placement(size: CGSize(width: 10, height: 10)) { Unmotivated() }.setting(Motto.self, to: "Hi")
            }
            r.declare(Motto.self)
            r.optIn(Sample.self, to: Motto.self)
        }])
        let editor = CanvasEditor(registry: registry, scheduler: ManualScheduler())
        editor.place(try require(kept.value), at: CGPoint(x: 50, y: 50))
        editor.place(try require(boxes.value), at: CGPoint(x: 90, y: 50))
        expectEqual(editor.document.shapes.map { $0[Motto.self] }, ["Hi", nil])
        expectEqual(editor.document.shapes.first?.box, CGRect(x: 45, y: 45, width: 10, height: 10))
    },
])

/// A box that opts into nothing.
struct Unmotivated: BoxShapeProps {
    static let kind: ShapeKind = "unmotivated"
    static let properties = Properties<Unmotivated> { Property("frame", \.frame).required() }
    var frame: CGRect = .zero
}

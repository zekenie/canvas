@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import TestKit

/// Where `value` breaks `schema`, a line each: "pointer keyword: message".
private func check(_ schema: JSONObject, _ value: JSONValue) -> [String] {
    JSONSchema(schema).violations(of: value).map(\.description)
}

/// Why the registry refuses `plugin`, or nil if it doesn't.
@MainActor private func refusal(_ plugin: some CanvasPlugin) -> String? {
    do {
        _ = try Registry(plugins: [plugin])
        return nil
    } catch {
        return "\(error)"
    }
}

/// A code, which a pattern that isn't a regular expression is to check.
struct Coded: BoxShapeProps {
    static let kind: ShapeKind = "coded"
    static let properties = Properties<Coded> {
        Property("frame", \.frame).required()
        Property("code", \.code).pattern("[a-z")
    }
    var frame: CGRect = .zero
    var code = ""
}

/// A note whose schema refers to a place it doesn't have.
struct Dangling: BoxShapeProps {
    static let kind: ShapeKind = "dangling"
    static let properties = Properties<Dangling> {
        Property("frame", \.frame).required()
        Property("note", \.note).keywords(["$ref": "#/$defs/nowhere"])
    }
    var frame: CGRect = .zero
    var note = ""
}

/// A type whose hand-written schema is only a reference to itself: checking a value against it
/// would never end.
struct Circular: Codable, Equatable, Sendable, SchemaDescribed {
    var turns = 0
    static func schema(in definitions: inout SchemaDefinitions) -> JSONObject {
        definitions.reference("circular", of: Self.self) { Self.schema(in: &$0) }
    }
}

struct Roundabout: BoxShapeProps {
    static let kind: ShapeKind = "roundabout"
    static let properties = Properties<Roundabout> {
        Property("frame", \.frame).required()
        Property("circle", \.circle)
    }
    var frame: CGRect = .zero
    var circle = Circular()
}

/// An added property whose pattern isn't a regular expression.
enum Sigil {}
extension Sigil: ShapeProperty {
    static let key: PropertyKey = "sigil"
    static var defaultValue: String? { nil }
    static var keywords: PropertyKeywords<String> { PropertyKeywords().pattern("(") }
}

/// A struct shared under a definition name a JSON Pointer has to escape: a `/`, a `~` and a `%`.
struct Slashed: SchemaDefined, Equatable, Sendable {
    static let properties = Properties<Slashed>(definition: "a/b~c%41") { Property("label", \.label).maxLength(3) }
    var label = ""
}

struct Slashing: BoxShapeProps {
    static let kind: ShapeKind = "slashing"
    static let properties = Properties<Slashing> {
        Property("frame", \.frame).required()
        Property("slashed", \.slashed)
    }
    var frame: CGRect = .zero
    var slashed = Slashed()
}

/// A value that codes itself with what the board's encoder writes its own way: a float, a decimal,
/// JSON with numbers that aren't finite, and a member written from two nested containers.
struct Assorted: Codable, Equatable, Sendable, SchemaDescribed {
    static func schema(in _: inout SchemaDefinitions) -> JSONObject { ["type": "object"] }

    enum Keys: String, CodingKey { case ratio, price, json, pair, x, y }

    init() {}
    init(from _: any Decoder) throws {}

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(Float(0.1), forKey: .ratio)
        try container.encode(Decimal(string: "-682.417493")!, forKey: .price)
        try container.encode(JSONValue.object(["nan": .number(.nan), "list": [.number(.infinity)]]), forKey: .json)
        var first = container.nestedContainer(keyedBy: Keys.self, forKey: .pair)
        try first.encode(1, forKey: .x)
        var second = container.nestedContainer(keyedBy: Keys.self, forKey: .pair)
        try second.encode(2, forKey: .y)
    }
}

struct Mixed: BoxShapeProps {
    static let kind: ShapeKind = "mixed"
    static let properties = Properties<Mixed> {
        Property("frame", \.frame).required()
        Property("assorted", \.assorted)
    }
    var frame: CGRect = .zero
    var assorted = Assorted()
}

@MainActor let schemaSoundnessTests = Suite("Schemas that can't be checked, and checks that JSON Schema has its own way", [
    test("a $ref back to itself, before the value is gone into, ends at once: said as a problem, and where a value meets it") {
        let validator = SchemaValidator(JSONSchema(["$ref": "#"]))
        expectEqual(validator.problems, ["# refers back to itself without going into the value, so checking one would never end"])
        expectEqual(validator.violations(of: 1).map(\.description), ["/ $ref: The value can't be checked: its schema refers back to itself without end."])
        let mutual: JSONObject = ["$defs": ["a": ["allOf": [["$ref": "#/$defs/b"]]], "b": ["anyOf": [["$ref": "#/$defs/a"]]]],
                                  "properties": ["x": ["$ref": "#/$defs/a"]]]
        expectEqual(SchemaValidator(JSONSchema(mutual)).problems.count, 1)
        expectEqual(check(mutual, ["x": 1]), ["/x $ref: X can't be checked: its schema refers back to itself without end."])
        // A type that holds itself goes into the value on the way round: it ends with the value.
        let tree: JSONObject = ["$defs": ["node": ["properties": ["children": ["items": ["$ref": "#/$defs/node"]]]]], "$ref": "#/$defs/node"]
        expectEqual(SchemaValidator(JSONSchema(tree)).problems, [])
        expectEqual(check(tree, ["children": [["children": []]]]), [])
        // `then` and `else` without an `if` aren't applied, so they go round nothing.
        expectEqual(SchemaValidator(JSONSchema(["then": ["$ref": "#"], "else": ["$ref": "#"]])).problems, [])
        expectEqual(check(["then": ["$ref": "#"]], 1), [])
    },
    test("the registry refuses a kind whose schema can't be checked: a pattern that isn't a regular expression, a $ref to nowhere, or back to itself") {
        expectEqual(refusal(Contributor(id: "kinds") { $0.shape(PlainDefinition<Coded>()) }),
                    "Shapes: coded (from kinds): its schema is broken: the pattern at #/properties/code, \"[a-z\", isn't a regular expression ICU can read")
        expectEqual(refusal(Contributor(id: "kinds") { $0.shape(PlainDefinition<Dangling>()) }),
                    "Shapes: dangling (from kinds): its schema is broken: the $ref at #/properties/note, #/$defs/nowhere, isn't in the schema")
        expectEqual(refusal(Contributor(id: "kinds") { $0.shape(PlainDefinition<Roundabout>()) }),
                    "Shapes: roundabout (from kinds): its schema is broken: #/$defs/canvastests.circular refers back to itself without going into the value, so checking one would never end")
    },
    test("an added property's broken schema is its declarer's to hear of, before any kind opts in") {
        expectEqual(refusal(Contributor(id: "sigils") { $0.declare(Sigil.self) }),
                    "PropertyDeclarations: property sigil (from sigils): its schema is broken: the pattern at #, \"(\", isn't a regular expression ICU can read")
    },
    test("a definition's name with a /, a ~ or a % is escaped in its $ref, which finds it") {
        let registry = try Registry(plugins: [Contributor(id: "kinds") { $0.shape(PlainDefinition<Slashing>()) }])
        let json = try require(registry.schema(for: Slashing.kind)).json
        expectEqual(json["properties"]?["slashed"]?["$ref"], "#/$defs/canvastests.a~1b~0c%2541")
        expect(json["$defs"]?["canvastests.a/b~c%41"] != nil)
        var shape = ShapeRecord(Slashing())
        shape.props.slashed.label = "long"
        expectEqual(registry.schemaViolations(of: AnyShapeRecord(shape)).map(\.description),
                    ["/slashed/label maxLength: Slashed › label is 4 characters long, and should be at most 3."])
    },
    test("multipleOf holds whatever the size: a remainder, not a quotient that rounds away or overflows") {
        let whole: JSONObject = ["multipleOf": 1], cents: JSONObject = ["multipleOf": 0.01], halves: JSONObject = ["multipleOf": 0.5]
        expectEqual(check(whole, 600_000_000.5), ["/ multipleOf: The value is 600000000.5, and should be a multiple of 1."])
        expectEqual(check(whole, 499_999_999.5).count, 1)
        expectEqual(check(cents, 5_000_000.005).count, 1)
        expectEqual(check(["multipleOf": 0.0001], 50_000.00005).count, 1)
        expectEqual(check(halves, 1e308), [], "an exact multiple, far past any quotient")
        expectEqual(check(cents, 0.3), [], "0.3 isn't quite thirty 0.01s in binary")
        expectEqual(check(["multipleOf": 0.1], .number(0.1 + 0.2)), [])
        expectEqual(check(halves, -1.5), [])
        expectEqual(check(["multipleOf": 0.07], 700_000.07), [], "ten million and one 0.07s, off by more than an ulp in binary")
        expectEqual(check(["multipleOf": 1.1], 33_000_004.4), [])
        expectEqual(check(["multipleOf": 0.17], 1_700_002.38), [])
        expectEqual(check(halves, -1.25).count, 1)
        expectEqual([JSONValue.number(.nan), .number(.infinity)].map { check(whole, $0).count }, [1, 1], "no multiple of anything")
    },
    test("a pattern is ECMA-262's: $ ends the string, \\d and \\w are ASCII, [^] is anything, and a class's [ and & are themselves") {
        let word: JSONObject = ["pattern": "^[a-z]+$"]
        expectEqual(check(word, "abc"), [])
        for trailing in ["abc\n", "abc\r\n", "abc\u{2028}"] {
            expectEqual(check(word, .string(trailing)).map { $0.hasPrefix("/ pattern:") }, [true], "\(trailing.debugDescription)")
        }
        expectEqual(check(["pattern": "^\\d+$"], "123"), [])
        expectEqual(check(["pattern": "^\\d+$"], "١٢٣").count, 1, "Arabic digits aren't \\d")
        expectEqual(check(["pattern": "^\\w+$"], "é").count, 1)
        expectEqual(check(["pattern": "^[^\\d]$"], "a"), [])
        expectEqual(check(["pattern": "^a[^]b$"], "a\nb"), [])
        expectEqual(check(["pattern": "a[]"], "a").count, 1, "[] matches nothing")
        expectEqual(check(["pattern": "^[[]$"], "["), [])
        expectEqual(check(["pattern": "^[a&&b]+$"], "a&b"), [])
        expectEqual(check(["pattern": "^[$]\\$$"], "$$"), [])
        expectEqual(check(["pattern": "^\\\\$"], "\\"), [])
        expectEqual(check(["pattern": "^\\u{1F600}$"], "😀"), [])
        expectEqual(check(["pattern": "a[]?b"], "ab"), [], "[] matches nothing, and may be skipped")
        // A word's boundary is ASCII's, as \w is: an accent is no word character.
        expectEqual(check(["pattern": "^\\w+\\b"], "abé"), [])
        expectEqual(check(["pattern": "^(\\w+\\b\\W*){1,3}$"], "naïve café"), [])
        expectEqual(check(["pattern": "a\\Bb"], "ab"), [])
        expectEqual(check(["pattern": "^.$"], "\u{0B}"), [], ". is anything but a line terminator, as ECMA counts them")
        expectEqual(check(["pattern": "^.$"], "\u{85}"), [])
        expectEqual(check(["pattern": "^.$"], "\n").count, 1)
        expectEqual(check(["pattern": "^\\s$"], "\u{FEFF}"), [], "ECMA's whitespace")
        expectEqual(check(["pattern": "^\\s$"], "\u{85}").count, 1)
        expectEqual(check(["pattern": "^\\S+$"], "a\u{FEFF}b").count, 1)
        expectEqual(check(["pattern": "^[\\s\\d]+$"], "1 2"), [])
        expectEqual(check(["pattern": "^\\0$"], "\u{0}"), [])
        expectEqual(check(["pattern": "^\\v$"], "\u{0B}"), [])
        expectEqual(check(["pattern": "^\\v$"], "\n").count, 1)
        expectEqual(check(["pattern": "^[\\b]$"], "\u{08}"), [], "in a class, a backspace")
        expectEqual(check(["pattern": "^[!--]$"], ","), [], "a range from ! to -")
        expectEqual(check(["pattern": "^[a-z--]+$"], "a-b"), [])
        expectEqual(check(["pattern": "^[:x:]+$"], "x:"), [], "a class of : and x, not a POSIX one")
    },
    test("a pattern ICU can't read at all is no regular expression here: the registry refuses it") {
        expectEqual(SchemaValidator(JSONSchema(["pattern": "(?<=a+)b"])).problems,
                    ["the pattern at #, \"(?<=a+)b\", isn't a regular expression ICU can read"])
    },
    test("patternProperties with a pattern that isn't a regular expression says so once, and holds no member to additionalProperties") {
        let schema: JSONObject = ["patternProperties": ["^x-[^]*$": ["type": "string"], "(": ["type": "number"]], "additionalProperties": false]
        let validator = SchemaValidator(JSONSchema(schema))
        expectEqual(validator.problems, ["the pattern for properties at #, \"(\", isn't a regular expression ICU can read"])
        expectEqual(validator.violations(of: ["x-note": "hi", "other": 1]).map(\.description),
                    ["/ patternProperties: The value can't be checked: its pattern \"(\" for properties isn't a regular expression ICU can read."])
        expectEqual(check(["patternProperties": ["^x-[^]*$": ["type": "string"]], "additionalProperties": false], ["x-note": "hi"]), [])
    },
    test("strings are the same code point for code point, as JSON Schema compares them, not canonically equivalent") {
        let nfc = "caf\u{E9}", nfd = "cafe\u{301}"
        expectEqual(check(["uniqueItems": true], [.string(nfc), .string(nfd)]), [])
        expectEqual(check(["uniqueItems": true], [.string(nfc), .string(nfc)]).count, 1)
        expectEqual(check(["const": .string(nfc)], .string(nfd)).count, 1)
        expectEqual(check(["enum": [.string(nfc)]], .string(nfd)).count, 1)
        expectEqual(check(["required": [.string(nfd)]], .object([nfc: 1])), ["/cafe\u{301} required: Cafe\u{301} is missing."])
        expectEqual(check(["properties": [nfd: ["type": "string"]], "additionalProperties": false], .object([nfc: 1])),
                    ["/caf\u{E9} additionalProperties: Caf\u{E9} isn't one of the value's properties."])
        expectEqual(check(["const": ["a": 1.0]], ["a": 1]), [], "numbers by value")
        expectEqual(check(["uniqueItems": true], [["a": 1, "b": "x"], ["b": "x", "a": 1.0]]).count, 1, "an object whatever its members' order")
        let many = JSONValue.array((0..<2_000).map { .object(["label": .string("item \($0)"), "done": .bool($0 % 2 == 0)]) })
        expectEqual(check(["uniqueItems": true], many), [], "each object hashed by its members, not only their count")
    },
    test("messages quote strings as JSON does, on one line") {
        expectEqual(check(["const": "say \"hi\"\n"], "x"), ["/ const: The value should be \"say \\\"hi\\\"\\n\"."])
        expectEqual(check(["type": "number"], "a\tb"), ["/ type: The value should be a number, not \"a\\tb\"."])
    },
    test("minContains is its own keyword; contains alone wants one") {
        let schema: JSONObject = ["properties": ["some": ["contains": ["type": "number"], "minContains": 2], "any": ["contains": ["type": "number"]]]]
        expectEqual(check(schema, ["some": [1, "x"], "any": ["x"]]), [
            "/any contains: Any has no item that fits.",
            "/some minContains: Some has 1 item that fits, and should have at least 2.",
        ])
    },
    test("a shape's JSON is what the board writes: a float and a decimal by their text, JSON's NaN a string, nested containers merged") {
        let registry = try Registry(plugins: [Contributor(id: "kinds") { $0.shape(PlainDefinition<Mixed>()) }])
        let written = try JSONDecoder().decode(JSONValue.self, from: BoardCodec(registry: registry).encodeProps(Mixed()))
        let assorted = try require(AnyShapeRecord(ShapeRecord(Mixed())).propertiesJSON?["assorted"])
        expectEqual(assorted, written["assorted"])
        expectEqual(assorted, ["ratio": 0.1, "price": .number(-682.417493), "json": ["nan": "nan", "list": ["inf"]], "pair": ["x": 1, "y": 2]])
    },
])

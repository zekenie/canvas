import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import TestKit

/// What `Sample` (SchemaTests') doesn't have: bounds on both sides, a whole number within a range,
/// a switch that's on unless it's turned off, text of a media type, an object whose members share a
/// range, a size and a point, a dictionary, a list of lists, a list of objects with ids, and text
/// that's required.
struct Gauge: BoxShapeProps {
    static let kind: ShapeKind = "gauge"
    static let properties = Properties<Gauge> {
        Property("frame", \.frame).required()
        Property("label", \.label).required()
        Property("level", \.level).minimum(0).maximum(1)
        Property("steps", \.steps).minimum(1).maximum(5)
        Property("on", \.on)
        Property("notes", \.notes).keywords(["contentMediaType": "text/x-gauge"])
        Property("tint", \.tint)
        Property("size", \.size)
        Property("pin", \.pin)
        Property("readings", \.readings)
        Property("grid", \.grid)
        Property("items", \.items)
    }
    struct Tint: SchemaDefined, Equatable {
        static let properties = Properties<Tint> {
            Property("red", \.red).minimum(0).maximum(1)
            Property("green", \.green).minimum(0).maximum(1)
        }
        var red = 0.0, green = 0.0
    }
    struct Item: SchemaDefined, Equatable {
        static let properties = Properties<Item>(definition: "item") {
            Property("id", \.id)
            Property("text", \.text)
            Property("done", \.done)
        }
        var id = UUID()
        var text = ""
        var done = false
    }
    var frame: CGRect = .zero
    var label = ""
    var level = 0.5
    var steps = 2
    var on = true
    var notes = ""
    var tint = Tint()
    var size = CGSize(width: 10, height: 20)
    var pin = CGPoint.zero
    var readings: [String: Double] = [:]
    var grid: [[Int]] = []
    var items: [Item] = []
}

/// Whether a gauge is latched: a switch only the shapes it's set on have.
enum Latch {}
extension Latch: ShapeProperty {
    static let key: PropertyKey = "latch"
    static var defaultValue: Bool? { nil }
}

/// Every kind CanvasTesting's plugins register, samples with mottos and stamps, and gauges that
/// can be latched.
@MainActor private func fixtureKinds() throws -> Registry {
    try Registry(plugins: [FixturesPlugin(), CardsPlugin(), PocketsPlugin(), NamingPlugin(), LinksPlugin(), TilesPlugin(),
                           Contributor(id: "gauges") { r in
        r.shape(PlainDefinition<Sample>())
        r.shape(PlainDefinition<Gauge>())
        r.declare(Motto.self)
        r.declare(StampedAt.self)
        r.declare(Latch.self)
        r.optIn(Sample.self, to: Motto.self)
        r.optIn(Sample.self, to: StampedAt.self)
        r.optIn(Gauge.self, to: Latch.self)
    }])
}

@MainActor private func schema(_ kind: ShapeKind, in registry: Registry) throws -> KindSchema {
    KindSchema(try require(registry.schema(for: kind), "\(kind) has no schema"))
}

/// A value read off the main actor, as a query's evaluation reads one: a kind's schema needs no
/// registry once it's read.
private nonisolated func readOffMain(_ schema: KindSchema, _ literal: String, for property: String) -> Result<JSONValue, KindSchema.Refusal> {
    Result { () throws(KindSchema.Refusal) in try schema.value(ofLiteral: literal, quoted: false, for: property) }
}

/// What a literal reads as, or why not.
private func read(_ schema: KindSchema, _ literal: String, quoted: Bool = false, for property: String) -> Result<JSONValue, KindSchema.Refusal> {
    Result { () throws(KindSchema.Refusal) in try schema.value(ofLiteral: literal, quoted: quoted, for: property) }
}

private func readItem(_ schema: KindSchema, _ literal: String, quoted: Bool = false, of property: String) -> Result<JSONValue, KindSchema.Refusal> {
    Result { () throws(KindSchema.Refusal) in try schema.value(ofLiteral: literal, quoted: quoted, forItemOf: property) }
}

/// A schema written by hand: references to escaped names, beside keywords, a loop, the root, and a
/// property that's any JSON.
private let handWritten = KindSchema(JSONSchema([
    "type": "object",
    "properties": [
        "size": ["$ref": "#/$defs/a~1b", "maximum": 9],
        "spaced": ["$ref": "#/$defs/my%20def"],
        "loop": ["$ref": "#/$defs/x"],
        "whole": ["$ref": "#"],
        "any": [:],
        "counts": ["type": "array", "items": ["type": "integer", "minimum": 0]],
    ],
    "$defs": [
        "a/b": ["type": "integer", "minimum": 0, "maximum": 5],
        "my def": ["type": "boolean", "default": true],
        "x": ["$ref": "#/$defs/y"],
        "y": ["$ref": "#/$defs/x"],
    ],
]))

@MainActor let kindSchemaTests = Suite("A kind's schema, read", [
    test("every fixture kind's properties, each said briefly, as canvas draw and canvas kinds say them") {
        let registry = try fixtureKinds()
        let frame = "JSON [[x, y], [width, height]], in world units"
        let expected: [ShapeKind: [String: String]] = [
            "box": ["frame": frame],
            "card": ["frame": frame, "text": "text"],
            "citing-tag": ["cite": "text", "target": "text"],
            "disc": ["frame": frame],
            "gauge": ["frame": frame, "grid": "JSON [JSON [integer]]", "items": "JSON [{done, text}]", "label": "text",
                      "latch": "true|false", "level": "number 0…1", "notes": "text", "on": "true|false", "pin": "JSON [x, y]",
                      "readings": "JSON {…}", "size": "JSON [width, height]", "steps": "integer 1…5", "tint": "JSON {green, red: 0…1}"],
            "link": ["from": "text", "to": "text"],
            "memo": ["citations": "JSON [text]", "frame": frame, "lead": "text", "notes": "JSON [{cites, text}]",
                     "sources": "JSON {…}", "text": "text"],
            "pocket": ["frame": frame],
            "sample": ["count": "integer ≥ 0", "due": "date (YYYY-MM-DD or date-time)", "frame": frame, "mood": "calm|busy",
                       "motto": "text (≤ 10)", "name": "text (≤ 40)", "parts": "JSON [{label}]",
                       "stamp": "date (YYYY-MM-DD or date-time)", "step": "number", "tags": "JSON [text]", "target": "text"],
            "tag": ["target": "text"],
            "tile": ["finish": "matte|glossy", "frame": frame, "label": "text"],
        ]
        expectEqual(Set(registry.kinds), Set(expected.keys))
        for kind in registry.kinds {
            let schema = try schema(kind, in: registry)
            let types = Dictionary(uniqueKeysWithValues: schema.properties.keys.map { ($0, schema.compactType(of: $0)) })
            expectEqual(types, expected[kind], "\(kind)")
        }
        expectEqual(try schema(Gauge.kind, in: registry).compactType(of: "nope"), "JSON", "a property it hasn't")
    },
    test("where a shape is, a frame or a point, holds a place; nothing else does, a size neither") {
        let registry = try fixtureKinds()
        var holding: [ShapeKind: Set<String>] = [:]
        for kind in registry.kinds {
            let schema = try schema(kind, in: registry)
            holding[kind] = Set(schema.properties.keys.filter(schema.holdsPlace))
        }
        expectEqual(holding, ["box": ["frame"], "card": ["frame"], "citing-tag": [], "disc": ["frame"], "gauge": ["frame", "pin"],
                              "link": [], "memo": ["frame"], "pocket": ["frame"], "sample": ["frame"], "tag": [], "tile": ["frame"]])
        expect(!(try schema(Gauge.kind, in: registry).holdsPlace("nope")))
    },
    test("what each property's values are: text with its format, media type and choices, numbers, switches with their defaults, lists of what, objects, any JSON") {
        let registry = try fixtureKinds()
        let gauge = try schema(Gauge.kind, in: registry), sample = try schema(Sample.kind, in: registry)
        let text = KindSchema.PropertyShape.string(format: nil, mediaType: nil, choices: nil)
        let id = KindSchema.PropertyShape.string(format: "uuid", mediaType: nil, choices: nil)
        expectEqual(sample.shape(of: "name"), text)
        expectEqual(sample.shape(of: "mood"), .string(format: nil, mediaType: nil, choices: ["calm", "busy"]))
        expectEqual(sample.shape(of: "due"), .string(format: KindSchema.dateTime, mediaType: nil, choices: nil))
        expectEqual(sample.shape(of: "stamp"), .string(format: KindSchema.dateTime, mediaType: nil, choices: nil), "an added one")
        expectEqual(sample.shape(of: "target"), id)
        expectEqual(sample.shape(of: "count"), .number(integer: true))
        expectEqual(sample.shape(of: "step"), .number(integer: false))
        expectEqual(sample.shape(of: "tags"), .array(items: text))
        expectEqual(sample.shape(of: "parts"), .array(items: .object))
        expectEqual(gauge.shape(of: "notes"), .string(format: nil, mediaType: "text/x-gauge", choices: nil))
        expectEqual(gauge.shape(of: "on"), .boolean(default: true), "on unless it's turned off")
        expectEqual(gauge.shape(of: "latch"), .boolean(default: false), "an added switch with no default is off")
        expectEqual(gauge.shape(of: "grid"), .array(items: .array(items: .number(integer: true))))
        expectEqual(gauge.shape(of: "tint"), .object)
        expectEqual(gauge.shape(of: "readings"), .object, "a dictionary")
        expectEqual(gauge.shape(of: "size"), .array(items: .json), "a tuple's items are any JSON")
        expectEqual(gauge.shape(of: "nope"), nil)
        expectEqual(handWritten.shape(of: "any"), .json)
        expectEqual(gauge.required, ["frame", "label"])
        expectEqual(sample.required, ["frame"])
    },
    test("a value as written, read as its property is: text, a day as its midnight, a choice, numbers, switches, JSON, and null as the default") {
        let registry = try fixtureKinds()
        let gauge = try schema(Gauge.kind, in: registry), sample = try schema(Sample.kind, in: registry)
        expectEqual(read(sample, "Kite", for: "name"), .success("Kite"))
        expectEqual(read(sample, "a kite", quoted: true, for: "name"), .success("a kite"))
        expectEqual(read(sample, "busy", for: "mood"), .success("busy"))
        expectEqual(read(sample, "busy", quoted: true, for: "mood"), .success("busy"))
        expectEqual(read(sample, "2026-09-28", for: "due"), .success("2026-09-28T00:00:00Z"))
        expectEqual(read(sample, "2026-09-28", quoted: true, for: "stamp"), .success("2026-09-28T00:00:00Z"))
        expectEqual(read(sample, "2026-09-28T10:30:00Z", for: "due"), .success("2026-09-28T10:30:00Z"))
        expectEqual(read(sample, "2026-9-28", for: "due"), .success("2026-9-28"), "not a day: the text as written, which the schema checks")
        expectEqual(read(sample, "3", for: "count"), .success(3))
        expectEqual(read(sample, "-2", for: "count"), .success(-2), "a bound is a guideline, never a refusal")
        expectEqual(read(gauge, "0.25", for: "level"), .success(0.25))
        expectEqual(read(gauge, "false", for: "on"), .success(false))
        expectEqual(read(gauge, "true", for: "latch"), .success(true))
        expectEqual(read(sample, #"["a", "b"]"#, for: "tags"), .success(["a", "b"]))
        expectEqual(read(gauge, #"{"red": 1}"#, for: "tint"), .success(["red": 1]))
        expectEqual(read(handWritten, "3", for: "any"), .success(3), "unquoted, anything else is JSON")
        expectEqual(read(handWritten, "hi", quoted: true, for: "any"), .success("hi"), "quoted, its text")
        expectEqual(read(sample, "null", for: "name"), .success(.null))
        expectEqual(read(sample, "null", quoted: true, for: "name"), .success("null"), "quoted, it's the word")
        expectEqual(try awaitResult { await Task.detached { readOffMain(gauge, "4", for: "steps") }.value }, .success(4), "read on another thread")
    },
    test("each refusal is a structure, in no words: not a property, not a choice, not what it takes, required, not finite, not JSON") {
        let registry = try fixtureKinds()
        let gauge = try schema(Gauge.kind, in: registry), sample = try schema(Sample.kind, in: registry)
        expectEqual(read(sample, "3", for: "nope"), .failure(.notAProperty))
        expectEqual(read(sample, "Calm", for: "mood"), .failure(.notAChoice(choices: ["calm", "busy"])))
        expectEqual(read(sample, "three", for: "count"), .failure(.notA(compactType: "integer ≥ 0")))
        expectEqual(read(sample, "3.5", for: "count"), .failure(.notA(compactType: "integer ≥ 0")), "a fraction, for a whole number")
        expectEqual(read(sample, "3", quoted: true, for: "count"), .failure(.notA(compactType: "integer ≥ 0")), "quoted, it's text")
        expectEqual(read(gauge, "yes", for: "on"), .failure(.notA(compactType: "true|false")))
        expectEqual(read(gauge, "true", quoted: true, for: "on"), .failure(.notA(compactType: "true|false")))
        expectEqual(read(sample, #"["a"]"#, quoted: true, for: "tags"), .failure(.notA(compactType: "JSON [text]")))
        expectEqual(read(gauge, "{}", quoted: true, for: "tint"), .failure(.notA(compactType: "JSON {green, red: 0…1}")))
        expectEqual(read(gauge, "null", for: "label"), .failure(.required))
        for literal in ["inf", "-inf", "nan", "1e999"] {
            expectEqual(read(gauge, literal, for: "level"), .failure(.notFinite), literal)
        }
        expectEqual(read(sample, "[", for: "tags"), .failure(.notJSON))
        expectEqual(read(gauge, "red", for: "tint"), .failure(.notJSON))
        expectEqual(read(handWritten, "hi", for: "any"), .failure(.notJSON))
    },
    test("an item of a list, read as the list's items are") {
        let registry = try fixtureKinds()
        let gauge = try schema(Gauge.kind, in: registry), sample = try schema(Sample.kind, in: registry)
        expectEqual(readItem(sample, "urgent", of: "tags"), .success("urgent"))
        expectEqual(readItem(sample, "null", of: "tags"), .success("null"), "no item is null")
        expectEqual(readItem(handWritten, "3", of: "counts"), .success(3))
        expectEqual(readItem(handWritten, "3.5", of: "counts"), .failure(.notA(compactType: "integer ≥ 0")))
        expectEqual(readItem(gauge, "[1, 2]", of: "grid"), .success([1, 2]))
        expectEqual(readItem(gauge, #"{"text": "a"}"#, of: "items"), .success(["text": "a"]))
        expectEqual(readItem(gauge, "a", quoted: true, of: "items"), .failure(.notA(compactType: "JSON {done, text}")))
        expectEqual(readItem(gauge, "0.5", of: "level"), .failure(.notA(compactType: "number 0…1")), "not a list")
        expectEqual(readItem(gauge, "a", of: "nope"), .failure(.notAProperty))
    },
    test("references are followed within the schema: keywords beside one say more, names are escaped as a pointer's, a loop ends") {
        expectEqual(handWritten.resolved(["$ref": "#/$defs/a~1b", "maximum": 9]), ["type": "integer", "minimum": 0, "maximum": 9])
        expectEqual(handWritten.compactType(of: "size"), "integer 0…9")
        expectEqual(handWritten.shape(of: "spaced"), .boolean(default: true))
        expectEqual(handWritten.shape(of: "loop"), .json)
        expectEqual(handWritten.shape(of: "whole"), .object, "# is the whole schema")
        expectEqual(KindSchema.resolved(["$ref": "#/$defs/missing", "type": "string"], in: [:]), ["$ref": "#/$defs/missing", "type": "string"],
                    "a reference to nowhere stays as it is")
    },
])

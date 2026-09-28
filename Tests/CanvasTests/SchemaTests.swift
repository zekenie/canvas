@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import TestKit

/// A kind with one of everything a property can be.
struct Sample: BoxShapeProps {
    static let kind: ShapeKind = "sample"
    static let properties = Properties<Sample>(title: "Sample", description: "One of everything.") {
        Property("frame", \.frame).required()
        Property("name", \.name).description("What it's called.").maxLength(40)
        Property("count", \.count).minimum(0).examples(1, 2)
        Property("mood", \.mood)
        Property("due", \.due)
        Property("parts", \.parts)
        Property("tags", \.tags)
        Property("target", \.target)
        Property("step", \.step).keywords(["multipleOf": 0.5])
    }
    enum Mood: String, Codable, Sendable, CaseIterable, SchemaCases {
        case calm, busy
        var schemaTitle: String { rawValue.capitalized }
    }
    struct Part: SchemaDefined, Equatable {
        static let properties = Properties<Part>(definition: "part") {
            Property("label", \.label)
        }
        var label = ""
    }
    var frame: CGRect = .zero
    var name = "untitled"
    var count = 3
    var mood = Mood.calm
    var due: Date?
    var parts: [Part] = []
    var tags: Set<String> = []
    var target: ShapeID?
    var step = 1.5
}

/// Lists one of its two members: the other is never written.
struct Forgetful: SchemaDefined, Equatable {
    static let properties = Properties<Forgetful> { Property("kept", \.kept) }
    var kept = 1
    var forgotten = 2
}

/// A kind that forgets a member, one that lists a name it doesn't have, one that lists a name
/// twice, and one whose nested struct forgets a member.
struct Unlisted: BoxShapeProps {
    static let kind: ShapeKind = "unlisted"
    static let properties = Properties<Unlisted> { Property("frame", \.frame).required() }
    var frame: CGRect = .zero
    var note = ""
}

struct Misnamed: BoxShapeProps {
    static let kind: ShapeKind = "misnamed"
    static let properties = Properties<Misnamed> {
        Property("frame", \.frame).required()
        Property("colour", \.color)
    }
    var frame: CGRect = .zero
    var color = ""
}

struct Twice: BoxShapeProps {
    static let kind: ShapeKind = "twice"
    static let properties = Properties<Twice> {
        Property("frame", \.frame).required()
        Property("frame", \.frame)
    }
    var frame: CGRect = .zero
}

struct Nesting: BoxShapeProps {
    static let kind: ShapeKind = "nesting"
    static let properties = Properties<Nesting> {
        Property("frame", \.frame).required()
        Property("inner", \.inner)
    }
    var frame: CGRect = .zero
    var inner: [Forgetful] = []
}

/// Lists that can't round-trip: an optional that's required, an optional with a default, optionals
/// in a list, and two properties writing one member.
struct RequiredOptional: BoxShapeProps {
    static let kind: ShapeKind = "required-optional"
    static let properties = Properties<RequiredOptional> {
        Property("frame", \.frame).required()
        Property("note", \.note).required()
    }
    var frame: CGRect = .zero
    var note: String?
}

struct DefaultedOptional: BoxShapeProps {
    static let kind: ShapeKind = "defaulted-optional"
    static let properties = Properties<DefaultedOptional> {
        Property("frame", \.frame).required()
        Property("count", \.count)
    }
    var frame: CGRect = .zero
    var count: Int? = 3
}

struct OptionalList: BoxShapeProps {
    static let kind: ShapeKind = "optional-list"
    static let properties = Properties<OptionalList> {
        Property("frame", \.frame).required()
        Property("marks", \.marks)
    }
    var frame: CGRect = .zero
    var marks: [Int?] = []
}

struct SameMember: BoxShapeProps {
    static let kind: ShapeKind = "same-member"
    static let properties = Properties<SameMember> {
        Property("frame", \.frame).required()
        Property("start", \.start)
        Property("end", \.start)
    }
    var frame: CGRect = .zero
    var start = false
    var end = false
}

/// A tree: a struct that holds itself, which only a named definition can describe.
struct Branch: SchemaDefined, Equatable {
    static let properties = Properties<Branch>(definition: "branch") {
        Property("label", \.label)
        Property("branches", \.branches)
    }
    var label = ""
    var branches: [Branch] = []
}

struct Tree: BoxShapeProps {
    static let kind: ShapeKind = "tree"
    static let properties = Properties<Tree> {
        Property("frame", \.frame).required()
        Property("root", \.root)
    }
    var frame: CGRect = .zero
    var root = Branch()
}

struct Loop: SchemaDefined, Equatable {
    static let properties = Properties<Loop> { Property("loops", \.loops) }
    var loops: [Loop] = []
}

struct Loops: BoxShapeProps {
    static let kind: ShapeKind = "loops"
    static let properties = Properties<Loops> {
        Property("frame", \.frame).required()
        Property("loop", \.loop)
    }
    var frame: CGRect = .zero
    var loop = Loop()
}

/// Two types that both call their definition "part".
struct PartA: SchemaDefined, Equatable {
    static let properties = Properties<PartA>(definition: "part") { Property("a", \.a) }
    var a = 0
}

struct PartB: SchemaDefined, Equatable {
    static let properties = Properties<PartB>(definition: "part") { Property("b", \.b) }
    var b = ""
}

struct Crate: BoxShapeProps {
    static let kind: ShapeKind = "crate"
    static let properties = Properties<Crate> {
        Property("frame", \.frame).required()
        Property("a", \.a)
        Property("b", \.b)
    }
    var frame: CGRect = .zero
    var a: [PartA] = []
    var b: [PartB] = []
}

/// A type that codes itself by hand, holding a struct: the struct's list is checked through its schema.
enum Wrapped: Codable, Equatable, Sendable, SchemaDescribed {
    case one(Forgetful)
    static func schema(in definitions: inout SchemaDefinitions) -> JSONObject {
        ["type": "object", "properties": ["one": .object(Forgetful.schema(in: &definitions))]]
    }
}

struct Holder: BoxShapeProps {
    static let kind: ShapeKind = "holder"
    static let properties = Properties<Holder> {
        Property("frame", \.frame).required()
        Property("wrapped", \.wrapped)
    }
    var frame: CGRect = .zero
    var wrapped = Wrapped.one(Forgetful())
}

/// Lists whose key paths aren't the member they're named after: a computed view, part of a member.
struct ComputedView: BoxShapeProps {
    static let kind: ShapeKind = "computed-view"
    static let properties = Properties<ComputedView> {
        Property("frame", \.frame).required()
        Property("due", \.dueDate)
    }
    var frame: CGRect = .zero
    var due: Date?
    var dueDate: Date {
        get { due ?? Date(timeIntervalSince1970: 0) }
        set { due = newValue }
    }
}

struct PartOfAMember: BoxShapeProps {
    static let kind: ShapeKind = "part-of-a-member"
    static let properties = Properties<PartOfAMember> {
        Property("frame", \.frame.origin)
    }
    var frame: CGRect = .zero
}

/// An outline: a struct in place, held through a named type that codes itself by hand, which holds
/// the struct again. The named type's definition breaks the loop.
struct Group: SchemaDefined, Equatable {
    static let properties = Properties<Group> {
        Property("title", \.title)
        Property("children", \.children)
    }
    var title = ""
    var children: [Node] = []
}

indirect enum Node: Codable, Equatable, Sendable, SchemaDescribed {
    case item(String)
    case group(Group)
    static func schema(in definitions: inout SchemaDefinitions) -> JSONObject {
        definitions.reference("node", of: Self.self) { definitions in
            ["oneOf": [["type": "string"], .object(Group.schema(in: &definitions))]]
        }
    }
}

struct Outline: BoxShapeProps {
    static let kind: ShapeKind = "outline"
    static let properties = Properties<Outline> {
        Property("frame", \.frame).required()
        Property("root", \.root)
    }
    var frame: CGRect = .zero
    var root = Group()
}

/// Added properties whose values a schema can't say: optionals in a list, an optional.
enum Marks {}
extension Marks: ShapeProperty {
    static let key: PropertyKey = "marks"
    static var defaultValue: [Int?]? { [] }
}

enum Maybe {}
extension Maybe: ShapeProperty {
    static let key: PropertyKey = "maybe"
    static var defaultValue: String?? { .some(nil) }
}

/// An added property whose value doesn't list a member.
enum Forgotten {}
extension Forgotten: ShapeProperty {
    static let key: PropertyKey = "forgotten"
    static var defaultValue: Forgetful? { Forgetful() }
}

struct PlainDefinition<Props: BoxShapeProps> {}
extension PlainDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Props>, in context: RenderContext) {}
}

/// A kind that lists two members twice, one of them three times: the first listed twice is reported.
struct Thrice: BoxShapeProps {
    static let kind: ShapeKind = "thrice"
    static let properties = Properties<Thrice> {
        Property("frame", \.frame).required()
        Property("b", \.b)
        Property("a", \.a)
        Property("b", \.b)
        Property("a", \.a)
        Property("a", \.a)
    }
    var frame: CGRect = .zero
    var a = 0
    var b = 0
}

/// Why the registry refuses a plugin that registers `P`; nil if it doesn't.
@MainActor private func refusal<P: BoxShapeProps>(_: P.Type) -> String? {
    let plugin = Contributor(id: "kinds") { $0.shape(PlainDefinition<P>()) }
    do {
        _ = try Registry(plugins: [plugin])
        return nil
    } catch {
        return "\(error)"
    }
}

@MainActor private func object(_ value: some Encodable) throws -> JSONObject {
    try require(JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)).objectValue)
}

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(T.self, from: Data(json.utf8))
}

@MainActor let schemaTests = Suite("Schemas", [
    test("a type's list is how it's written: each property under its name, a nil optional left out") {
        var sample = Sample()
        sample.name = "Kite"
        sample.parts = [Sample.Part(label: "tail")]
        let written = try object(sample)
        expectEqual(Set(written.keys), ["frame", "name", "count", "mood", "parts", "tags", "step"])
        expectEqual(written["name"], "Kite")
        expectEqual(written["mood"], "calm")
        expectEqual(written["parts"], [["label": "tail"]])
        sample.due = Date(timeIntervalSince1970: 0)
        sample.target = ShapeID()
        expect(try object(sample)["due"] != nil && object(sample)["target"] != nil)
    },
    test("a member missing from what's read reads as its default, and so does null; a required one refuses") {
        let read = try decode(Sample.self, #"{"frame": [[1, 2], [3, 4]], "name": null, "count": 7}"#)
        expectEqual(read.frame, CGRect(x: 1, y: 2, width: 3, height: 4))
        expectEqual(read.name, "untitled")
        expectEqual(read.count, 7)
        expectEqual(read.mood, .calm)
        expectEqual(read.due, nil)
        do {
            _ = try decode(Sample.self, #"{"name": "no frame"}"#)
            expect(false, "a sample without a frame read")
        } catch DecodingError.keyNotFound(let key, _) {
            expectEqual(key.stringValue, "frame")
        }
    },
    test("reading writes back the same: the list round-trips every member") {
        var sample = Sample()
        sample.name = "Kite"
        sample.count = 9
        sample.mood = .busy
        sample.due = Date(timeIntervalSince1970: 1_790_000_000)
        sample.parts = [Sample.Part(label: "tail")]
        sample.tags = ["a"]
        sample.target = ShapeID()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        expectEqual(try decoder.decode(Sample.self, from: encoder.encode(sample)), sample)
    },
    test("a member left off the list is never written: the registry refuses such a kind") {
        expectEqual(try object(Forgetful(kept: 5, forgotten: 6)), ["kept": 5])
    },
    test("the registry refuses a kind whose list misses a member, names no member, lists one twice, or holds a struct that does") {
        expectEqual(refusal(Unlisted.self), "Shapes: unlisted (from kinds): Unlisted.note isn't in Unlisted's properties, so boards wouldn't save it")
        expectEqual(refusal(Misnamed.self), "Shapes: misnamed (from kinds): Misnamed.color isn't in Misnamed's properties, so boards wouldn't save it")
        expectEqual(refusal(Twice.self), "Shapes: twice (from kinds): Twice lists frame twice")
        expectEqual(refusal(Nesting.self), "Shapes: nesting (from kinds): Forgetful.forgotten isn't in Forgetful's properties, so boards wouldn't save it")
        expectEqual(refusal(Sample.self), nil)
    },
    test("the registry refuses an optional that's required or has a default, optionals in a list, and two properties writing one member") {
        expectEqual(refusal(RequiredOptional.self), "Shapes: required-optional (from kinds): RequiredOptional.note is optional and required: a nil one wouldn't save, nor read back")
        expectEqual(refusal(DefaultedOptional.self), "Shapes: defaulted-optional (from kinds): DefaultedOptional.count is optional with a default that isn't nil, so a nil one would read back as the default")
        expectEqual(refusal(OptionalList.self), "Shapes: optional-list (from kinds): OptionalList.marks holds optionals in a collection or an optional, which a schema can't say")
        expectEqual(refusal(SameMember.self), "Shapes: same-member (from kinds): SameMember's properties start and end write the same member")
    },
    test("a struct that holds itself is described with a definition that refers to itself; in place, the registry refuses it") {
        let registry = try Registry(plugins: [Contributor(id: "trees") { $0.shape(PlainDefinition<Tree>()) }])
        let json = try require(registry.schema(for: Tree.kind)).json
        expectEqual(json["properties"]?["root"], ["$ref": "#/$defs/canvastests.branch", "default": ["branches": [], "label": ""]])
        expectEqual(json["$defs"]?["canvastests.branch"]?["properties"]?["branches"]?["items"], ["$ref": "#/$defs/canvastests.branch"])
        expectEqual(danglingReferences(in: json), [])
        expectEqual(refusal(Loops.self), "Shapes: loops (from kinds): Loop holds itself; give it a definition name (Properties(definition:)) so its schema can refer to itself")
    },
    test("a property's key path is the stored member it's named after: not a computed view, nor part of one") {
        expectEqual(refusal(ComputedView.self), "Shapes: computed-view (from kinds): ComputedView's property due doesn't write its member due; a property's key path is the stored member it's named after")
        expectEqual(refusal(PartOfAMember.self), "Shapes: part-of-a-member (from kinds): PartOfAMember's property frame doesn't write its member frame; a property's key path is the stored member it's named after")
    },
    test("a struct in place, held again through a named type that codes itself, is described through that type's definition") {
        let registry = try Registry(plugins: [Contributor(id: "outlines") { $0.shape(PlainDefinition<Outline>()) }])
        let json = try require(registry.schema(for: Outline.kind)).json
        expectEqual(json["properties"]?["root"]?["properties"]?["children"]?["items"], ["$ref": "#/$defs/canvastests.node"])
        expectEqual(danglingReferences(in: json), [])
    },
    test("a list's problems come in list order, so the same one is reported every time") {
        expectEqual(refusal(Thrice.self), "Shapes: thrice (from kinds): Thrice lists b twice")
    },
    test("an added property whose value is an optional, or holds optionals, is refused against its declaration") {
        for (plugin, message) in [
            (Contributor(id: "p") { $0.declare(Marks.self) }, "PropertyDeclarations: property marks (from p): its value is an optional, or holds optionals in a collection, which a schema can't say"),
            (Contributor(id: "p") { $0.declare(Maybe.self) }, "PropertyDeclarations: property maybe (from p): its value is an optional, or holds optionals in a collection, which a schema can't say"),
            // Blamed on the declaration, not on the first kind that opts in.
            (Contributor(id: "p") { $0.declare(Forgotten.self); $0.optIn(Box.self, to: Forgotten.self) },
             "PropertyDeclarations: property forgotten (from p): Forgetful.forgotten isn't in Forgetful's properties, so boards wouldn't save it"),
        ] as [(Contributor, String)] {
            do {
                _ = try Registry(plugins: [FixturesPlugin(), plugin])
                expect(false, "\(message) wasn't refused")
            } catch {
                expectEqual("\(error)", message)
            }
        }
    },
    test("two types under one definition name are refused, not described wrong") {
        expectEqual(refusal(Crate.self), "Shapes: crate (from kinds): two types are defined as canvastests.part (PartB is one); give one another definition name")
    },
    test("the lists of structs a schema reaches are checked: behind a type that codes itself by hand, and an added property's value") {
        expectEqual(refusal(Holder.self), "Shapes: holder (from kinds): Forgetful.forgotten isn't in Forgetful's properties, so boards wouldn't save it")
        do {
            _ = try Registry(plugins: [Contributor(id: "p") { $0.declare(Forgotten.self) }])
            expect(false, "a property whose value doesn't list a member was declared")
        } catch {
            expectEqual("\(error)", "PropertyDeclarations: property forgotten (from p): Forgetful.forgotten isn't in Forgetful's properties, so boards wouldn't save it")
        }
    },
    test("the schema: types from the members, defaults from init(), and only what has no default required") {
        let json = Sample.jsonSchema.json
        expectEqual(json["type"], "object")
        expectEqual(json["title"], "Sample")
        expectEqual(json["description"], "One of everything.")
        expectEqual(json["required"], ["frame"])
        expectEqual(json["additionalProperties"], false)
        let properties = try require(json["properties"]?.objectValue)
        expectEqual(properties["frame"], ["$ref": "#/$defs/core.rect"])
        expectEqual(properties["name"], ["type": "string", "description": "What it's called.", "maxLength": 40, "default": "untitled"])
        expectEqual(properties["count"], ["type": "integer", "minimum": 0, "default": 3, "examples": [1, 2]])
        expectEqual(properties["mood"], ["type": "string", "default": "calm",
                                         "oneOf": [["const": "calm", "title": "Calm"], ["const": "busy", "title": "Busy"]]])
        expectEqual(properties["due"], ["type": "string", "format": "date-time"])
        expectEqual(properties["parts"], ["type": "array", "items": ["$ref": "#/$defs/canvastests.part"], "default": []])
        expectEqual(properties["tags"], ["type": "array", "items": ["type": "string"], "uniqueItems": true, "default": []])
        expectEqual(properties["target"], ["$ref": "#/$defs/core.shape-id"])
        expectEqual(properties["step"], ["type": "number", "multipleOf": 0.5, "default": 1.5])
        let definitions = try require(json["$defs"]?.objectValue)
        expectEqual(Set(definitions.keys), ["core.rect", "core.point", "core.size", "core.shape-id", "canvastests.part"])
        expectEqual(definitions["core.rect"]?["prefixItems"], [["$ref": "#/$defs/core.point"], ["$ref": "#/$defs/core.size"]])
        expectEqual(definitions["canvastests.part"]?["properties"], ["label": ["type": "string", "default": ""]])
        expectEqual(danglingReferences(in: json), [])
    },
    test("a kind's schema from the registry says what it is, and names each definition after the module that declares its type") {
        let registry = try Registry(plugins: [Contributor(id: "samples") { $0.shape(PlainDefinition<Sample>()) }])
        let json = try require(registry.schema(for: Sample.kind)).json
        expectEqual(json["$schema"], "https://json-schema.org/draft/2020-12/schema")
        expectEqual(json["$id"], "tag:infinite-canvas,2026:kinds/sample")
        expectEqual(json["properties"]?["parts"]?["items"], ["$ref": "#/$defs/canvastests.part"])
        expectEqual(Set(try require(json["$defs"]?.objectValue).keys), ["core.rect", "core.point", "core.size", "core.shape-id", "canvastests.part"])
        expectEqual(danglingReferences(in: json), [])
        expectEqual(registry.schema(for: "nope"), nil)
    },
    test("a kind without a title is titled by its kind") {
        let registry = try Registry(plugins: [FixturesPlugin()])
        expectEqual(try require(registry.schema(for: Box.kind)).json["title"], "box")
    },
    test("a kind whose shapes own boards says so in its schema") {
        let registry = try Registry(plugins: [FixturesPlugin(), PocketsPlugin()])
        expectEqual(try require(registry.schema(for: Pocket.kind)).json["x-canvas-board"], true)
        expectEqual(try require(registry.schema(for: Box.kind)).json["x-canvas-board"], nil)
    },
    test("a default that varies from one init() to the next (a new id) isn't stated, though a missing member still reads as one") {
        let properties = try require(Stub.jsonSchema.json["properties"]?.objectValue)
        expectEqual(properties["id"], ["type": "string", "format": "uuid"])
        expectEqual(properties["label"], ["type": "string", "default": "stub"])
        expectEqual(Stub.jsonSchema.json["required"], nil)
        let one = try decode(Stub.self, #"{"label": "a"}"#), another = try decode(Stub.self, #"{"label": "a"}"#)
        expect(one.id != another.id, "each read without one gets its own")
    },
])

/// An item with an id of its own from the moment it's made, as a checklist's are.
struct Stub: SchemaDefined, Equatable {
    static let properties = Properties<Stub> {
        Property("id", \.id)
        Property("label", \.label)
    }
    var id = UUID()
    var label = "stub"
}

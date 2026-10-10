import Canvas
import CanvasTesting
import Foundation
import QueryLanguage
import Queries
import TestKit

// `[a.b.c]`: a test of what's inside an object attribute, typed by the JSON value found at the
// members on each shape. Chores hold `facts`, an object of whatever a test writes (an added
// property), and `meta`, an object with an owner and a size.

/// An object of any JSON: the value of `facts`.
struct Bag: Hashable, Sendable {
    var json: JSONObject
    init(_ json: JSONObject) { self.json = json }
}

extension Bag: Codable {
    init(from decoder: any Decoder) throws { json = try decoder.singleValueContainer().decode(JSONObject.self) }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(json)
    }
}

extension Bag: SchemaDescribed {
    static func schema(in definitions: inout SchemaDefinitions) -> JSONObject { ["type": "object"] }
}

/// Facts a chore holds: an object whose members a test chooses.
enum Facts {}
extension Facts: ShapeProperty {
    static let key: PropertyKey = "facts"
    static var defaultValue: Bag? { nil }
}

let factsPlugin = Contributor(id: "facts") { registrar in
    registrar.declare(Facts.self)
    registrar.optIn(Chore.self, to: Facts.self)
}

private func shape(_ n: Int, _ caption: String, facts: JSONObject? = nil, owner: String = "", size: Int = 0) -> AnyShapeRecord {
    var record = chore(id(n), caption: caption, Chore(unit, meta: Chore.Meta(owner: owner, size: size)))
    record[Facts.self] = facts.map(Bag.init)
    return record
}

/// Chores 1 "Alpha", 2 "Beta", 3 "Gamma" (no facts at all, but an empty object) and 4 "Delta" (none), and
/// pocket 5 "Pantry", which has no `facts` or `meta` to test.
@MainActor private func bagged() throws -> EditorHarness {
    let alpha = shape(1, "Alpha", facts: [
        "owner": ["name": "Ann", "age": 30, "admin": true], "labels": ["red", "blue"], "note": "Hello World", "nothing": nil, "count": 5,
        "empty": "", "ratio": 2.5,
    ], owner: "Ann", size: 3)
    let beta = shape(2, "Beta", facts: ["owner": ["name": "bob", "age": 41, "admin": false], "labels": ["green"], "count": 12, "note": "10"],
                     owner: "Bob", size: 8)
    let gamma = shape(3, "Gamma", facts: [:])
    return try EditorHarness(plugins: queryPlugins(more: [factsPlugin]),
                             file: CanvasFile(root: CanvasDocument(shapes: [alpha, beta, gamma, shape(4, "Delta"), pocket(id(5), caption: "Pantry")])))
}

@MainActor let pathTests = Suite("Paths: members inside an attribute", [
    test("text on a string: equals, with i, the text operators, a word") {
        let h = try bagged()
        expectMatches([
            #"chore[facts.owner.name=Ann]"#: [1],
            #"chore[facts.owner.name="ann"]"#: [],
            #"chore[facts.owner.name="ann" i]"#: [1],
            #"chore[facts.owner.name^=b]"#: [2],
            #"chore[facts.owner.name$=B i]"#: [2],
            #"chore[facts.owner.name*=n]"#: [1],
            #"chore[facts.owner.name|=Ann]"#: [1],
            #"chore[facts.note~=World]"#: [1],
            #"chore[facts.note~=world i]"#: [1],
            #"chore[facts.note*="o W"]"#: [1],
            #"chore[facts.note^=""]"#: [],
        ], on: h)
    },
    test("numbers on a number, when the literal is one; quoted or not") {
        let h = try bagged()
        expectMatches([
            "chore[facts.owner.age=30]": [1],
            #"chore[facts.owner.age="30"]"#: [1],
            "chore[facts.owner.age>35]": [2],
            "chore[facts.owner.age>=30]": [1, 2],
            "chore[facts.owner.age<41]": [1],
            "chore[facts.owner.age<=41]": [1, 2],
            "chore[facts.count>=5]": [1, 2],
            "chore[facts.ratio=2.5]": [1],
            "chore[facts.ratio<3]": [1],
            // A number is not text, and text is not a number.
            "chore[facts.owner.age^=3]": [],
            "chore[facts.owner.name>3]": [],
            "chore[facts.owner.name=30]": [],
            // A string that reads as a number is still a string: it equals the text, and no ordering reads it.
            "chore[facts.note=10]": [2],
            "chore[facts.note>5]": [],
            "chore[facts.owner.age=thirty]": [],
        ], on: h)
    },
    test("booleans, and a list by its items") {
        let h = try bagged()
        expectMatches([
            "chore[facts.owner.admin=true]": [1],
            "chore[facts.owner.admin=false]": [2],
            "chore[facts.owner.admin=yes]": [],
            "chore[facts.owner.admin]": [1],
            "chore[facts.owner.admin!=true]": [2, 3, 4],
            "chore[facts.labels~=red]": [1],
            "chore[facts.labels~=Blue i]": [1],
            "chore[facts.labels~=Blue]": [],
            "chore[facts.labels~=green]": [2],
            "chore[facts.labels]": [1, 2],
            "chore[facts.labels=red]": [],
            "chore[facts.labels^=red]": [],
        ], on: h)
    },
    test("[a.b] is false where there's nothing, [a.b=\"\"] true, and != the other way: missing, null, a step that isn't an object") {
        let h = try bagged()
        expectMatches([
            "chore[facts.owner.name]": [1, 2],
            "chore[facts.owner]": [1, 2],
            "chore[facts.nothing]": [],
            "chore[facts.empty]": [],
            "chore[facts.count.deeper]": [],
            "chore[facts.labels.first]": [],
            #"chore[facts.owner.name=""]"#: [3, 4],
            #"chore[facts.nothing=""]"#: [1, 2, 3, 4],
            #"chore[facts.empty=""]"#: [1, 2, 3, 4],
            #"chore[facts.count=""]"#: [3, 4],
            #"chore[facts.owner.name!=""]"#: [1, 2],
            "chore[facts.owner.name!=Ann]": [2, 3, 4],
            "chore[facts.missing.deeper!=x]": [1, 2, 3, 4],
        ], on: h)
    },
    test("a struct is an object too: the schema's own members, in props") {
        let h = try bagged()
        expectMatches([
            "chore[meta.owner=Ann]": [1],
            "chore[meta.size>=5]": [2],
            "chore[meta.size=0]": [3, 4],
            #"chore[meta.owner=""]"#: [3, 4],
            "chore[meta.owner]": [1, 2],
            "chore[meta.nope]": [],
        ], on: h)
    },
    test("with no kind named, every kind that has the attribute reads it; the others don't match, unless negated") {
        let h = try bagged()
        expectMatches([
            "[facts.owner.name=Ann]": [1],
            "[meta.owner=Bob]": [2],
            #"[facts.owner.name=""]"#: [3, 4],
            "[facts.owner.name!=Ann]": [2, 3, 4, 5],
        ], on: h)
    },
    test("a path is read from the shape as the query took it up, and its canonical form and plan say what it is") {
        let h = try bagged()
        let result = try answer(#"chore[facts.owner.name='Ann' i]"#, on: h)
        expectEqual(result.query, #"chore[facts.owner.name="Ann" i]"#)
        expectEqual(try plan("chore[facts.owner.name=Ann]", on: h).description, """
            all of
              kind chore
              [facts.owner.name] of chore object: at owner.name: = "Ann"
            """)
        expectEqual(try plan("chore[meta.size>=5][facts.labels~=red i]", on: h).description, """
            all of
              kind chore
              [meta.size] of chore object: at size: >= 5
              [facts.labels] of chore object: at labels: has the word or item "red" ignoring case
            """)
        expectEqual(try plan(#"chore[facts.owner.name!=""]"#, on: h).description, """
            all of
              kind chore
              not
                [facts.owner.name] of chore object: at owner.name: absent or empty
            """)
        let planned = try plan("chore[facts.owner.name=Ann]", on: h)
        expect(planned.readsOnlyTheFile, "a path reads only the file")
        expect(!planned.readsEdges)
    },
    test("only an object has members; a number's ordering takes a number, and the i flag only text") {
        let h = try bagged()
        expectRefused([
            Refused("chore[note.x]", .unknownAttribute, "note is text, so it has no members.", hint: "[note] tests it.", at: 5, 8),
            Refused("chore[tags.x=1]", .unknownAttribute, "tags is a list, so it has no members.", hint: "[tags] tests it.", at: 5, 10),
            Refused("chore[estimate.x]", .unknownAttribute, "estimate is a whole number, so it has no members.", hint: "[estimate] tests it.", at: 5, 12),
            Refused("chore[facts.age>old]", .invalidValue, "old isn't a number.",
                    hint: "facts.age is compared by its value, and > takes a number.", at: 5, 15),
            Refused(#"chore[facts.age<"3" i]"#, .unsupportedOperator, "The i flag compares text; < compares numbers.",
                    hint: #"Leave it out: [facts.age<"3"]."#, at: 5, 17),
            Refused("chore[zzz.a]", .unknownAttribute, "chore has no attribute zzz.", hint: "Its attributes: caption, due, estimate, facts, flag, meta, note, ratio, shout, status, tags.",
                    at: 5, 7),
            Refused(#"chore["facts.owner"=x]"#, .unknownAttribute, "No attribute is called facts.owner.",
                    hint: "A member inside an attribute is written without quotes: [facts.owner=x].", at: 5, 17),
            Refused(#"chore["meta.owner"=x]"#, .unknownAttribute, "No attribute is called meta.owner.",
                    hint: "A member inside an attribute is written without quotes: [meta.owner=x].", at: 5, 16),
            Refused("chore[frame.x]", .notBuilt, "frame is where the shape is; where shapes are isn't in the language yet.", at: 5, 9),
        ], on: h)
    },
    test("a path through a title head or a container reads like any attribute") {
        let h = try bagged()
        expectMatches([
            #""Alpha"[facts.owner.admin]"#: [1],
            #":is(chore[facts.owner.age>35], pocket)"#: [2, 5],
        ], on: h)
    },
])

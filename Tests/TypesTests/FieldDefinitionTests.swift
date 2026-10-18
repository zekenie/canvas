import Canvas
import TestKit
import Types

// The edits of a type's field definitions (`SchemaFields`, `DefinedKind`, `SchemaValue.pretty`), on values: no editor.

private func read(_ text: String) throws -> SchemaValue { SchemaValue(try JSONReader.read(text)) }

private let starter = #"{"type": "object", "properties": {}}"#
private let owner = """
{
  "type": "object",
  "properties": {
    "since": { "type": "string", "format": "date" },
    "primary": { "type": "boolean", "title": "Main one" }
  },
  "required": ["since", "primary"]
}
"""

private func keys(_ root: SchemaValue?) -> [String] { root?["properties"]?.members?.map(\.key) ?? [] }

@MainActor let fieldDefinitionTests = Suite("Field definitions", [
    test("the five kinds are written as the app reads them back, with the words a menu shows") {
        expectEqual(DefinedKind.allCases.map(\.label), ["Text", "Number", "Date", "Yes or no", "Choice"])
        var root = try read(starter)
        for kind in DefinedKind.allCases {
            root = try require(SchemaFields.adding("f \(kind.label.lowercased())", kind: kind, to: root)).schema
        }
        let fields = SchemaFields.fields(of: root)
        expectEqual(fields.map(\.kind), DefinedKind.allCases.map { Optional($0) })
        expectEqual(fields.map(\.name), ["f text", "f number", "f date", "f yes or no", "f choice"])
        expectEqual(root["properties"]?["fText"]?.members, [SchemaMember(key: "type", value: .string("string"))])
        expectEqual(root["properties"]?["fNumber"]?.members, [SchemaMember(key: "type", value: .string("number"))])
        expectEqual(root["properties"]?["fDate"]?.members, [SchemaMember(key: "type", value: .string("string")), SchemaMember(key: "format", value: .string("date"))])
        expectEqual(root["properties"]?["fYesOrNo"]?.members, [SchemaMember(key: "type", value: .string("boolean"))])
        expectEqual(root["properties"]?["fChoice"]?["enum"], .array([]), "a choice starts with none")
    },
    test("a kind is read from any schema the app reads as one: an integer is a Number, a date-time a Date, an enum a Choice, a list none") {
        func kind(_ text: String) throws -> DefinedKind? { DefinedKind(reading: try read(text)) }
        expectEqual(try kind(#"{"type": "integer"}"#), .number)
        expectEqual(try kind(#"{"type": "string", "format": "date-time"}"#), .date)
        expectEqual(try kind(#"{"type": "string", "format": "email"}"#), .text)
        expectEqual(try kind(#"{"enum": ["a", "b"]}"#), .choice)
        expectEqual(try kind(#"{"type": "string", "enum": []}"#), .choice)
        expectEqual(try kind(#"{"type": ["string", "null"]}"#), .text)
        expectEqual(try kind(#"{"type": "array", "items": {"type": "string"}}"#), nil)
        expectEqual(try kind(#"{"type": "object", "properties": {"a": {"type": "string"}}}"#), nil)
    },
    test("keys: camelCase from the typed words, accents dropped for a Latin script, a script's own letters otherwise, nothing for no letter") {
        expectEqual(SchemaFields.key(forName: "since"), "since")
        expectEqual(SchemaFields.key(forName: "  Primary   owner "), "primaryOwner")
        expectEqual(SchemaFields.key(forName: "Date of birth!"), "dateOfBirth")
        expectEqual(SchemaFields.key(forName: "URL"), "url")
        expectEqual(SchemaFields.key(forName: "postal URL"), "postalUrl")
        expectEqual(SchemaFields.key(forName: "postalURL"), "postalURL", "capitals inside a word stay")
        expectEqual(SchemaFields.key(forName: "Fecha de nacimiento"), "fechaDeNacimiento")
        expectEqual(SchemaFields.key(forName: "año"), "ano")
        expectEqual(SchemaFields.key(forName: "生年月日 の 日"), "生年月日の日")
        expectEqual(SchemaFields.key(forName: "2nd place"), "2ndPlace")
        expectEqual(SchemaFields.key(forName: "   "), nil)
        expectEqual(SchemaFields.key(forName: "!?"), nil)
        expectEqual(SchemaFields.unique("since", avoiding: ["since", "since2"]), "since3")
        expectEqual(SchemaFields.unique("since", avoiding: ["other"]), "since")
    },
    test("Add Field appends after the last property, with a title only when the key's words don't say the name; a second since is since2") {
        let root = try read(owner)
        let a = try require(SchemaFields.adding("Primary owner", kind: .text, to: root))
        expectEqual(a.key, "primaryOwner")
        expectEqual(keys(a.schema), ["since", "primary", "primaryOwner"])
        expectEqual(a.schema["properties"]?["primaryOwner"]?["title"]?.string, "Primary owner")
        let b = try require(SchemaFields.adding("since", kind: .number, to: a.schema))
        expectEqual(b.key, "since2")
        expectEqual(keys(b.schema), ["since", "primary", "primaryOwner", "since2"])
        expectEqual(b.schema["properties"]?["since2"]?["title"]?.string, "since", "the name typed is the name shown")
        let c = try require(SchemaFields.adding("Note", kind: .text, to: b.schema))
        expectEqual(c.schema["properties"]?["note"]?["title"]?.string, "Note", "a capital the key's words lack is the author's")
        expectEqual(c.schema["required"], root["required"], "required is left as it was")
        expectEqual(SchemaFields.fields(of: c.schema).map(\.name), ["since", "Main one", "Primary owner", "since", "Note"])
    },
    test("Add Field makes `properties` when the schema has none, and refuses an empty name, a schema that is not an object and a `properties` that is not") {
        let bare = try require(SchemaFields.adding("since", kind: .date, to: try read(#"{"type": "object"}"#))).schema
        expectEqual(bare.members?.map(\.key), ["type", "properties"])
        expectEqual(keys(bare), ["since"])
        expect(SchemaFields.adding("   ", kind: .text, to: try read(starter)) == nil)
        expect(SchemaFields.adding("!!", kind: .text, to: try read(starter)) == nil)
        expect(SchemaFields.adding("since", kind: .text, to: try read("[]")) == nil)
        expect(SchemaFields.adding("since", kind: .text, to: try read(#"{"properties": 3}"#)) == nil)
    },
    test("Rename Field keeps the key and sets the title, and takes the title off when the key's words say the name") {
        let root = try read(owner)
        let named = try require(SchemaFields.renaming("since", to: "  Owned   since ", in: root))
        expectEqual(keys(named), ["since", "primary"], "the key and the order stay")
        expectEqual(named["properties"]?["since"]?["title"]?.string, "Owned since")
        expectEqual(named["properties"]?["since"]?.members?.map(\.key), ["type", "format", "title"])
        let back = try require(SchemaFields.renaming("since", to: "since", in: named))
        expectEqual(back, root, "the title is gone again")
        let kept = try require(SchemaFields.renaming("primary", to: "Mine", in: root))
        expectEqual(kept["properties"]?["primary"]?.members?.map(\.key), ["type", "title"], "a title keeps its place")
        expectEqual(try require(SchemaFields.renaming("since", to: "since", in: root)), root, "the same name changes nothing")
        expectEqual(try require(SchemaFields.renaming("primary", to: "Main one", in: root)), root)
        expect(SchemaFields.renaming("since", to: "  ", in: root) == nil)
        expect(SchemaFields.renaming("nothing", to: "x", in: root) == nil)
    },
    test("Change Kind replaces the schema with the kind's, keeps title and description, and a choice loses its options going and has none coming") {
        let root = try read(#"""
        {"type": "object", "properties": {
          "size": {"type": "string", "enum": ["s", "m"], "title": "Size", "description": "How big", "default": "s"},
          "n": {"type": "integer", "minimum": 1, "title": "Count"}
        }}
        """#)
        let number = try require(SchemaFields.changing("size", to: .number, in: root))
        expectEqual(number["properties"]?["size"], try read(#"{"type": "number", "title": "Size", "description": "How big"}"#))
        let choice = try require(SchemaFields.changing("n", to: .choice, in: root))
        expectEqual(choice["properties"]?["n"], try read(#"{"type": "string", "enum": [], "title": "Count"}"#))
        expectEqual(try require(SchemaFields.changing("size", to: .choice, in: root)), root, "a choice stays one, with its options")
        expectEqual(try require(SchemaFields.changing("n", to: .number, in: root)), root, "an integer is a Number")
        let date = try require(SchemaFields.changing("n", to: .date, in: root))
        expectEqual(SchemaFields.fields(of: date).map(\.kind), [.choice, .date])
        expect(SchemaFields.changing("nothing", to: .text, in: root) == nil)
    },
    test("Remove Field takes the property and its name out of required, and required itself when that empties it") {
        let root = try read(owner)
        let one = try require(SchemaFields.removing("since", from: root))
        expectEqual(keys(one), ["primary"])
        expectEqual(one["required"], .array([.string("primary")]))
        let none = try require(SchemaFields.removing("primary", from: one))
        expectEqual(keys(none), [])
        expectEqual(none["required"], nil)
        expectEqual(none.members?.map(\.key), ["type", "properties"])
        let unrequired = try read(#"{"type": "object", "properties": {"a": {"type": "string"}}, "required": ["b"]}"#)
        expectEqual(try require(SchemaFields.removing("a", from: unrequired))["required"], .array([.string("b")]), "a name that is not there is left")
        expect(SchemaFields.removing("a", from: try read(starter)) == nil)
    },
    test("options are added after the last, renamed and removed in the order written; empty and repeated ones change nothing") {
        var root = try require(SchemaFields.changing("kind", to: .choice, in: try require(SchemaFields.adding("kind", kind: .text, to: try read(starter))).schema))
        for option in ["red", "green", "blue"] { root = try require(SchemaFields.addingOption(option, to: "kind", in: root)) }
        expectEqual(SchemaFields.fields(of: root)[0].options, ["red", "green", "blue"])
        expectEqual(root["properties"]?["kind"]?["enum"]?.elements?.compactMap(\.string), ["red", "green", "blue"])
        expectEqual(try require(SchemaFields.addingOption("green", to: "kind", in: root)), root, "an option it has")
        expect(SchemaFields.addingOption("  ", to: "kind", in: root) == nil)
        let renamed = try require(SchemaFields.renamingOption(at: 1, to: " teal ", of: "kind", in: root))
        expectEqual(SchemaFields.fields(of: renamed)[0].options, ["red", "teal", "blue"])
        expectEqual(try require(SchemaFields.renamingOption(at: 1, to: "green", of: "kind", in: root)), root, "its own name")
        expect(SchemaFields.renamingOption(at: 1, to: "blue", of: "kind", in: root) == nil, "another option's name")
        expect(SchemaFields.renamingOption(at: 3, to: "x", of: "kind", in: root) == nil)
        expect(SchemaFields.renamingOption(at: 0, to: "", of: "kind", in: root) == nil)
        let removed = try require(SchemaFields.removingOption(at: 0, of: "kind", in: root))
        expectEqual(SchemaFields.fields(of: removed)[0].options, ["green", "blue"])
        expect(SchemaFields.removingOption(at: 2, of: "kind", in: removed) == nil)
        var empty = removed
        empty = try require(SchemaFields.removingOption(at: 0, of: "kind", in: empty))
        empty = try require(SchemaFields.removingOption(at: 0, of: "kind", in: empty))
        expectEqual(empty["properties"]?["kind"]?["enum"], .array([]))
        expectEqual(SchemaFields.fields(of: empty)[0].kind, .choice, "still a Choice with none")
        let text = try require(SchemaFields.adding("plain", kind: .text, to: root)).schema
        expect(SchemaFields.addingOption("x", to: "plain", in: text) == nil, "a text field has no options")
    },
    test("a null among the options is no option and keeps its place; options are counted without it") {
        let root = try read(#"{"properties": {"c": {"enum": ["a", null, "b"]}}}"#)
        expectEqual(SchemaFields.fields(of: root)[0].options, ["a", "b"])
        let renamed = try require(SchemaFields.renamingOption(at: 1, to: "z", of: "c", in: root))
        expectEqual(renamed["properties"]?["c"]?["enum"], .array([.string("a"), .null, .string("z")]))
        let removed = try require(SchemaFields.removingOption(at: 0, of: "c", in: root))
        expectEqual(removed["properties"]?["c"]?["enum"], .array([.null, .string("b")]))
    },
    test("fields are read in the order written, with their required mark, and a `$` key of properties is no field") {
        let fields = SchemaFields.fields(of: try read(owner))
        expectEqual(fields.map(\.key), ["since", "primary"])
        expectEqual(fields.map(\.isRequired), [true, true])
        expectEqual(fields.map(\.kind), [.date, .yesNo])
        let directive = SchemaFields.fields(of: try read(#"{"properties": {"$title": "x", "a": {"type": "string"}}}"#))
        expectEqual(directive.map(\.key), ["a"])
        expectEqual(SchemaFields.fields(of: try read("[]")), [])
    },
    test("pretty is the starter's layout: two spaces, members in order, scalar arrays on a line, empty ones closed, and it reads back the same") {
        let starterText = """
        {
          "type": "object",
          "properties": {}
        }
        """
        expectEqual(try read(starterText).pretty, starterText)
        let text = try read(owner).pretty
        expectEqual(text, """
        {
          "type": "object",
          "properties": {
            "since": {
              "type": "string",
              "format": "date"
            },
            "primary": {
              "type": "boolean",
              "title": "Main one"
            }
          },
          "required": ["since", "primary"]
        }
        """)
        let odd = try read(#"{"a": [1, 2.5, -3, 1e20, true, null, "q\"\\\n"], "b": [{"x": []}, {}], "c": "é/ü", "d": 0.1}"#)
        expectEqual(try read(odd.pretty), odd)
        expectEqual(odd.pretty, try read(odd.pretty).pretty, "stable")
        expectEqual(SchemaValue.number(.nan).pretty, "null", "JSON cannot say it")
    },
])

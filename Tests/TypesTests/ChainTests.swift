import Canvas
import Foundation
import TestKit
import Types

// The chain: what an instance's types give it, in the one order they are read in. Over catalogs of
// values, with no editor.

/// A catalog of nodes by id.
private struct Shelf: ChainCatalog {
    var nodes: [ShapeID: ChainNode] = [:]
    func node(_ id: ShapeID) -> ChainNode? { nodes[id] }
}

private func id(_ n: Int) -> ShapeID { ShapeID(UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!) }

private func field(_ name: String, _ marker: String, required: Bool = false) -> ChainField {
    ChainField(name: name, schema: .object([SchemaMember(key: "type", value: .string("string")), SchemaMember(key: "title", value: .string(marker))]),
               isRequired: required)
}

private func type(_ n: Int, parents: [Int] = [], fields: [ChainField] = [], rules: [SchemaMember] = [],
                  directives: [SchemaMember] = []) -> (ShapeID, ChainNode) {
    (id(n), ChainNode(level: ChainLevel(fields: fields, rules: rules, directives: directives), parents: parents.map(id)))
}

private func shelf(_ nodes: (ShapeID, ChainNode)...) -> Shelf { Shelf(nodes: Dictionary(nodes, uniquingKeysWith: { $1 })) }

private func marker(_ field: ChainField) -> String? { field.schema["title"]?.string }

@MainActor private func level(_ text: String) throws -> ChainLevel { try require(ChainLevel(schema: text)) }

/// The one field of a type that has only that.
@MainActor private func only(_ text: String) throws -> ChainField { try require(level(text).fields.first) }

private func read(_ text: String) throws -> SchemaValue { SchemaValue(try JSONReader.read(text)) }

private struct Random {
    var state: UInt64
    mutating func next(_ bound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(bound))
    }
}

@MainActor let chainTests = Suite("The chain", [
    test("a type's schema is read as its fields in the order written, `required` from the root, `$` keys as directives, a bare `$` as neither") {
        let level = try level("""
        {"type": "object", "required": ["name", "ghost"], "properties": {
          "name": {"type": "string"}, "age": {"type": "integer"},
          "$title": {"x-canvas-from": "name"}, "$": {"default": 1}, "$odd": 5, "city": {"type": "string"}
        }}
        """)
        expectEqual(level.fields.map(\.name), ["name", "age", "city"])
        expectEqual(level.fields.map(\.isRequired), [true, false, false], "a required name with no property names no field")
        expectEqual(level.directives.map(\.key), ["title", "odd"])
        expectEqual(level.directives.first?.value, try read(#"{"x-canvas-from": "name"}"#), "kept as written")
        expectEqual(level.directives.last?.value, .number(5))
        expect(level.rules.isEmpty)
        expectEqual(ChainLevel(schema: "[1]"), nil, "a root that isn't an object says nothing")
        expectEqual(ChainLevel(schema: "{\"properties\": "), nil, "nor does text that isn't JSON")
        expectEqual(ChainLevel(), ChainLevel(fields: [], rules: [], directives: []))
        expectEqual(try require(ChainLevel(schema: "{}")), ChainLevel())
    },
    test("a property written twice is the last one's schema at the first's place") {
        let level = try level(#"{"properties": {"a": {"type": "string"}, "b": {}, "a": {"type": "integer"}}}"#)
        expectEqual(level.fields.map(\.name), ["a", "b"])
        expectEqual(level.fields.first?.schema["type"]?.string, "integer")
    },
    test("rules are the root's keywords across fields, in the order written; the ones about the whole object are not") {
        let level = try level("""
        {"type": "object", "properties": {"a": {"type": "string"}},
         "allOf": [{"required": ["a"]}], "propertyNames": {"pattern": "^[a-z]+$"}, "anyOf": [{"required": ["a"]}, {"required": ["b"]}],
         "minProperties": 1, "oneOf": [{}], "maxProperties": 9, "not": {"required": ["z"]}, "additionalProperties": false,
         "unevaluatedProperties": false, "if": {"required": ["a"]}, "then": {"required": ["b"]}, "else": {"required": ["c"]},
         "dependentRequired": {"a": ["b"]}, "dependentSchemas": {"a": {"required": ["b"]}},
         "patternProperties": {"^x-": {"type": "string"}}, "$ref": "urn:uuid:00000000-0000-4000-8000-000000000007"}
        """)
        expectEqual(level.rules.map(\.key), ["allOf", "anyOf", "oneOf", "not", "if", "then", "else", "dependentRequired", "dependentSchemas"])
        expectEqual(level.fields.map(\.name), ["a"], "a pattern property is no row, nor a root $ref")
        expectEqual(level.rules.first?.value, try read(#"[{"required": ["a"]}]"#))
    },
    test("a `#` reference is written out, through `#/$defs/x`, with its siblings over it and the target's order kept") {
        let field = try only("""
        {"properties": {"home": {"$ref": "#/$defs/address", "description": "mine", "title": "Home"}},
         "$defs": {"address": {"type": "object", "description": "theirs", "properties": {"city": {"type": "string"}}, "required": ["city"]}}}
        """)
        expectEqual(field.schema.members?.map(\.key), ["type", "description", "properties", "required", "title"], "the target's order, siblings' keys after")
        expectEqual(field.schema["description"]?.string, "mine", "siblings win")
        expectEqual(field.schema["properties"]?["city"]?["type"]?.string, "string")
        expect(!field.holdsItself)
    },
    test("a reference to nowhere is dropped, and the field reads as what its siblings say") {
        let level = try level("""
        {"properties": {"a": {"$ref": "#/$defs/missing", "description": "d"}, "b": {"$ref": "#/nope"}, "c": {"$ref": "#anchor"}}}
        """)
        expectEqual(level.fields.map(\.schema), [.object([SchemaMember(key: "description", value: .string("d"))]), .object([]), .object([])])
        expectEqual(level.fields.map(\.holdsItself), [false, false, false])
    },
    test("a reference that leads back into itself is dropped and the field says so; so is a pair that reach each other") {
        let own = try only("""
        {"properties": {"tree": {"$ref": "#/$defs/node"}},
         "$defs": {"node": {"type": "object", "properties": {"kids": {"type": "array", "items": {"$ref": "#/$defs/node"}}, "name": {"type": "string"}}}}}
        """)
        expect(own.holdsItself)
        expectEqual(own.schema["properties"]?["name"]?["type"]?.string, "string", "what is outside the loop is written out")
        expectEqual(own.schema["properties"]?["kids"]?["items"], .object([]), "and the loop itself is dropped, one level down")
        let pair = try only("""
        {"properties": {"p": {"$ref": "#/$defs/a"}},
         "$defs": {"a": {"properties": {"b": {"$ref": "#/$defs/b"}}}, "b": {"properties": {"a": {"$ref": "#/$defs/a"}}}}}
        """)
        expect(pair.holdsItself)
        let root = try only("{\"properties\": {\"me\": {\"$ref\": \"#\"}}}")
        expect(root.holdsItself, "a reference to the root, which holds the field")
        let plain = try only("{\"properties\": {\"x\": {\"$ref\": \"#/$defs/a\"}}, \"$defs\": {\"a\": {\"type\": \"string\"}}}")
        expect(!plain.holdsItself)
    },
    test("a chain of references more than six deep stops, saying it holds itself; six deep is followed") {
        func chain(_ links: Int) -> String {
            var defs = (0..<links).map { "\"d\($0)\": {\"$ref\": \"#/$defs/d\($0 + 1)\"}" }
            defs.append("\"d\(links)\": {\"type\": \"string\"}")
            return "{\"properties\": {\"f\": {\"$ref\": \"#/$defs/d0\"}}, \"$defs\": {\(defs.joined(separator: ","))}}"
        }
        let short = try only(chain(5)), long = try only(chain(9))
        expectEqual(short.schema["type"]?.string, "string")
        expect(!short.holdsItself)
        expect(long.holdsItself)
        expectEqual(long.schema["type"]?.string, nil, "the end of it was never reached")
    },
    test("`$defs`, `definitions`, `$id`, `$schema` and `$anchor` are left out of what is written, a property of that name is not") {
        let field = try only("""
        {"properties": {"g": {"$id": "x", "$schema": "s", "$anchor": "a", "type": "object", "$defs": {"d": {}}, "definitions": {"e": {}},
                              "properties": {"$defs": {"type": "string"}, "id": {"type": "string"}}}}}
        """)
        expectEqual(field.schema.members?.map(\.key), ["type", "properties"])
        expectEqual(field.schema["properties"]?.members?.map(\.key), ["$defs", "id"], "a property called $defs is a property")
    },
    test("a `urn:uuid:` reference is kept as written, bare or with a fragment, and so is anything that isn't `#`") {
        let other = "urn:uuid:00000000-0000-4000-8000-000000000007"
        let level = try level("""
        {"properties": {"a": {"$ref": "\(other)"}, "b": {"$ref": "\(other)#/$defs/money", "description": "d"}, "c": {"$ref": "https://example.com/x"}}}
        """)
        expectEqual(level.fields[0].schema, try read(#"{"$ref": "\#(other)"}"#))
        expectEqual(level.fields[1].schema, try read(#"{"$ref": "\#(other)#/$defs/money", "description": "d"}"#))
        expectEqual(level.fields[2].schema["$ref"]?.string, "https://example.com/x")
        expect(level.fields.allSatisfy { !$0.holdsItself })
    },
    test("only places that hold a schema are walked: `contentSchema`, `const`, `enum`, `default` and `examples` are copied as written") {
        let level = try level("""
        {"properties": {
           "pointer": {"type": "string", "contentMediaType": "text/x-canvas-link", "contentSchema": {"$ref": "#/$defs/a"}},
           "fixed": {"const": {"$ref": "#/$defs/a"}}, "kind": {"enum": [{"$ref": "#/$defs/a"}]},
           "dflt": {"default": {"$ref": "#/$defs/a"}}, "eg": {"examples": [{"$ref": "#/$defs/a"}]}},
         "$defs": {"a": {"type": "string"}}}
        """)
        expectEqual(level.fields[0].schema["contentSchema"], try read(##"{"$ref": "#/$defs/a"}"##))
        expectEqual(level.fields[1].schema["const"], try read(##"{"$ref": "#/$defs/a"}"##))
        expectEqual(level.fields[2].schema["enum"], try read(##"[{"$ref": "#/$defs/a"}]"##))
        expectEqual(level.fields[3].schema["default"], try read(##"{"$ref": "#/$defs/a"}"##))
        expectEqual(level.fields[4].schema["examples"], try read(##"[{"$ref": "#/$defs/a"}]"##))
    },
    test("a property called `$ref` inside a group is a property; a `#` reference inside a list's items, a union and a rule is written out too") {
        let level = try level("""
        {"properties": {"g": {"type": "object", "properties": {"$ref": {"type": "string"}}},
                        "l": {"type": "array", "items": {"$ref": "#/$defs/s"}}, "u": {"anyOf": [{"$ref": "#/$defs/s"}, {"type": "null"}]}},
         "allOf": [{"properties": {"l": {"$ref": "#/$defs/s"}}}],
         "$defs": {"s": {"type": "string"}}}
        """)
        expectEqual(level.fields[0].schema["properties"]?.members?.map(\.key), ["$ref"])
        expectEqual(level.fields[1].schema["items"], try read(#"{"type": "string"}"#))
        expectEqual(level.fields[2].schema["anyOf"], try read(#"[{"type": "string"}, {"type": "null"}]"#))
        expectEqual(level.rules.first?.value, try read(#"[{"properties": {"l": {"type": "string"}}}]"#))
    },
    test("the type added last is read first; the first to name a field gives all of it, and what it requires") {
        let a = type(1, fields: [field("name", "A name", required: true), field("age", "A age")])
        let b = type(2, fields: [field("name", "B name"), field("city", "B city", required: true)])
        let catalog = shelf(a, b)
        let resolved = Chain.resolve(types: [id(1), id(2)], in: catalog)
        expectEqual(resolved.order, [id(2), id(1)])
        expectEqual(resolved.fields.map(\.field.name), ["name", "age", "city"], "A's rows first: the most general type's, then B's new one")
        expectEqual(resolved.fields.map { marker($0.field) }, ["B name", "A age", "B city"], "B names `name` first, so it's B's whole")
        expectEqual(resolved.field(named: "name")?.field.isRequired, false, "required comes from the winner: A requires it, B doesn't")
        expectEqual(resolved.field(named: "city")?.field.isRequired, true)
        expectEqual(resolved.field(named: "name")?.source, id(2))
        expectEqual(resolved.field(named: "name")?.introducedBy, id(1), "and it stays where A put it")
        expectEqual(resolved.field(named: "city")?.introducedBy, id(2))
        let reversed = Chain.resolve(types: [id(2), id(1)], in: catalog)
        expectEqual(reversed.order, [id(1), id(2)])
        expectEqual(reversed.field(named: "name")?.source, id(1))
        expectEqual(reversed.field(named: "name")?.field.isRequired, true)
    },
    test("Person and Employee, as the board draws them: Person's rows first, then Employee's; a note given Employee then Speaker adds Speaker's") {
        let person = type(1, fields: [field("name", "P"), field("email", "P"), field("birthday", "P")])
        let employee = type(2, parents: [1], fields: [field("start date", "E"), field("remote", "E"), field("role", "E")])
        let speaker = type(3, fields: [field("talk", "S"), field("slot", "S")])
        let catalog = shelf(person, employee, speaker)
        let one = Chain.resolve(types: [id(2)], in: catalog)
        expectEqual(one.order, [id(2), id(1)])
        expectEqual(one.fields.map(\.field.name), ["name", "email", "birthday", "start date", "remote", "role"])
        expectEqual(one.fields.map(\.introducedBy), [id(1), id(1), id(1), id(2), id(2), id(2)])
        let two = Chain.resolve(types: [id(2), id(3)], in: catalog)
        expectEqual(two.order, [id(3), id(2), id(1)])
        expectEqual(two.fields.map(\.field.name), ["name", "email", "birthday", "start date", "remote", "role", "talk", "slot"])
        // A type's own note asks for its own list, and shares the answer an instance of it gets.
        expectEqual(Chain.resolve(types: [id(2)], in: catalog), one)
    },
    test("a restated field keeps its place among the more general type's rows, with the more specific type's whole definition") {
        let person = type(1, fields: [field("name", "P name", required: true), field("email", "P email", required: true), field("birthday", "P")])
        let patterned = ChainField(name: "email", schema: .object([SchemaMember(key: "type", value: .string("string")), SchemaMember(key: "pattern", value: .string("@"))]))
        let employee = type(2, parents: [1], fields: [patterned, field("role", "E")])
        let resolved = Chain.resolve(types: [id(2)], in: shelf(person, employee))
        expectEqual(resolved.fields.map(\.field.name), ["name", "email", "birthday", "role"])
        let email = try require(resolved.field(named: "email"))
        expectEqual(email.field, patterned)
        expectEqual(email.source, id(2))
        expectEqual(email.introducedBy, id(1))
        expect(!email.field.isRequired, "Employee leaves out `required` for it, so it is not required")
    },
    test("a type with no fields: no rows, but the order is not empty; gone types and shapes that are none are skipped; no types is nothing") {
        let catalog = shelf(type(1), type(2, parents: [9, 3]), type(3, fields: [field("x", "3")]))
        let none = Chain.resolve(types: [id(1)], in: catalog)
        expect(none.fields.isEmpty)
        expectEqual(none.order, [id(1)])
        let gone = Chain.resolve(types: [id(2), id(8)], in: catalog)
        expectEqual(gone.order, [id(2), id(3)], "9 and 8 are not in the catalog")
        expectEqual(gone.fields.map(\.field.name), ["x"])
        let empty = Chain.resolve(types: [], in: catalog)
        expectEqual(empty, Resolved())
        expect(empty.order.isEmpty && empty.fields.isEmpty)
        expectEqual(Chain.resolve(types: [id(1), id(1)], in: catalog).order, [id(1)], "a type named twice is one")
    },
    test("a type that is no longer one ends its branch: what it builds on gives nothing through it") {
        let catalog = shelf(type(1, fields: [field("name", "P")]))
        let note = Chain.resolve(types: [id(2)], in: catalog)
        expect(note.order.isEmpty && note.fields.isEmpty, "Employee (2) is not a type, though it lists Person")
        let reached = Chain.resolve(types: [id(2), id(1)], in: catalog)
        expectEqual(reached.order, [id(1)])
    },
    test("a type is before the one it builds on whatever order they were added in; a diamond is read once; a cycle stops where it comes back") {
        let catalog = shelf(type(1, fields: [field("a", "1")]), type(2, parents: [1], fields: [field("a", "2")]))
        expectEqual(Chain.resolve(types: [id(2), id(1)], in: catalog).order, [id(2), id(1)])
        expectEqual(Chain.resolve(types: [id(1), id(2)], in: catalog).order, [id(2), id(1)], "added Employee, then Person: still Employee first")
        expectEqual(Chain.resolve(types: [id(1), id(2)], in: catalog).field(named: "a")?.source, id(2))
        let diamond = shelf(type(1, parents: [2, 3]), type(2, parents: [4]), type(3, parents: [4]), type(4))
        expectEqual(Chain.resolve(types: [id(1)], in: diamond).order, [id(1), id(2), id(3), id(4)], "2 is named first by 1")
        let loop = shelf(type(1, parents: [2]), type(2, parents: [3]), type(3, parents: [1]))
        expectEqual(Chain.resolve(types: [id(1)], in: loop).order, [id(1), id(2), id(3)])
    },
    test("rules are every type's in the chain, none overridden; directives are one a name, the first in the order wins") {
        let person = type(1, rules: [SchemaMember(key: "allOf", value: .array([]))],
                          directives: [SchemaMember(key: "title", value: .string("P")), SchemaMember(key: "rank", value: .number(1))])
        let employee = type(2, parents: [1], rules: [SchemaMember(key: "not", value: .object([])), SchemaMember(key: "allOf", value: .array([.object([])]))],
                            directives: [SchemaMember(key: "rank", value: .number(2))])
        let resolved = Chain.resolve(types: [id(2)], in: shelf(person, employee))
        expectEqual(resolved.rules.map(\.source), [id(1), id(2)], "in row order of their types")
        expectEqual(resolved.rules.map { $0.members.map(\.key) }, [["allOf"], ["not", "allOf"]])
        expectEqual(resolved.directives, [.init(name: "rank", value: .number(2), source: id(2)), .init(name: "title", value: .string("P"), source: id(1))],
                    "Employee gets Person's title, and its own rank beats Person's, in the order of the chain")
    },
    test("the schema for the check: properties, the winners' required, the rules as allOf, nothing empty written") {
        let person = type(1, fields: [field("name", "P", required: true), field("age", "P")],
                          rules: [SchemaMember(key: "dependentRequired", value: try read(#"{"age": ["name"]}"#))])
        let employee = type(2, parents: [1], fields: [field("name", "E"), field("role", "E", required: true)],
                            rules: [SchemaMember(key: "not", value: try read(#"{"required": ["zzz"]}"#))])
        let resolved = Chain.resolve(types: [id(2)], in: shelf(person, employee))
        let schema = resolved.schema
        expectEqual(schema["type"], .string("object"))
        expectEqual(schema["properties"]?.objectValue.map { Set($0.keys) }, ["name", "age", "role"])
        expectEqual(schema["properties"]?["name"], field("name", "E").schema.json, "the winner's")
        expectEqual(schema["required"], .array([.string("role")]), "Employee's `name` is not required, and it won")
        expectEqual(schema["allOf"]?.arrayValue?.count, 2)
        expectEqual(schema["allOf"]?.arrayValue?.first, try read(#"{"dependentRequired": {"age": ["name"]}}"#).json)
        expectEqual(Chain.resolve(types: [], in: shelf()).schema, ["type": .string("object")])
        expectEqual(Chain.resolve(types: [id(1)], in: shelf(type(1))).schema, ["type": .string("object")], "a type with nothing writes nothing")
        // The schema compiles, and checks a value as the two types say.
        let validator = SchemaValidator(JSONSchema(schema))
        expect(validator.problems.isEmpty)
        expect(validator.violations(of: .object(["role": .string("cook"), "name": .string("Ann")])).isEmpty)
        expect(!validator.violations(of: .object(["name": .string("Ann")])).isEmpty, "role is required")
        expect(validator.violations(of: .object(["role": .string("cook"), "age": .string("x")])).contains { $0.keyword == "dependentRequired" }, "a rule across fields")
        expect(validator.violations(of: .object(["role": .string("cook"), "other": .number(1)])).isEmpty, "a value no field names is never wrong")
    },
    test("it agrees with a lookup on random graphs: the winner is the first in the order to name a field, its place is the last") {
        var random = Random(state: 7)
        let names = ["a", "b", "c", "d"]
        for round in 0..<200 {
            let count = 2 + random.next(7)
            var graph: [ShapeID: ChainNode] = [:]
            for n in 0..<count {
                let parents = (0..<random.next(4)).map { _ in id(random.next(count + 1)) }          // one past the end is none
                let fields = names.filter { _ in random.next(3) == 0 }.map { field($0, "\(n)", required: random.next(2) == 0) }
                graph[id(n)] = ChainNode(level: ChainLevel(fields: fields), parents: parents)
            }
            let types = (0..<(1 + random.next(3))).map { _ in id(random.next(count + 1)) }
            let resolved = Chain.resolve(types: types, in: Shelf(nodes: graph))
            var seen: Set<ShapeID> = []
            let heads = types.reversed().filter { seen.insert($0).inserted }
            let order = TypeOrder.linearized(heads, parents: { graph[$0]?.parents ?? [] }).filter { graph[$0] != nil }
            expectEqual(resolved.order, order, "round \(round)")
            for name in names {
                let namers = order.filter { type in graph[type]?.level.fields.contains { $0.name == name } == true }
                let found = resolved.field(named: name)
                expectEqual(found?.source, namers.first, "round \(round): who names \(name)")
                expectEqual(found?.introducedBy, namers.last, "round \(round): where \(name) sits")
                if let owner = namers.first, let found {
                    expectEqual(found.field, graph[owner]?.level.fields.first { $0.name == name }, "round \(round): \(name) whole, required with it")
                }
            }
            expectEqual(Set(resolved.fields.map(\.field.name)).count, resolved.fields.count, "round \(round): each name once")
            expectEqual(Set(resolved.fields.map(\.field.name)), Set(names.filter { resolved.field(named: $0) != nil }))
        }
    },
])

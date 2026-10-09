import Canvas
import TestKit
import Types

// The meta-schema is data, so these hold the data: to the spec (every keyword of every 2020-12
// vocabulary, nothing invented), to the rules its words follow, and to being a meta-schema, one that
// checks schemas as the official one does, compiled by the core's validator.

/// JSON Schema 2020-12's keywords, by vocabulary, as its specifications define them
/// (json-schema.org/draft/2020-12: core §8, §10 and §11; validation §6 to §9).
private let vocabularies: [(name: String, keywords: [String])] = [
    ("core", ["$schema", "$vocabulary", "$id", "$anchor", "$dynamicAnchor", "$ref", "$dynamicRef", "$defs", "$comment"]),
    ("applicator", ["allOf", "anyOf", "oneOf", "not", "if", "then", "else", "dependentSchemas", "prefixItems", "items", "contains",
                    "properties", "patternProperties", "additionalProperties", "propertyNames"]),
    ("unevaluated", ["unevaluatedItems", "unevaluatedProperties"]),
    ("validation", ["type", "enum", "const", "multipleOf", "maximum", "exclusiveMaximum", "minimum", "exclusiveMinimum", "maxLength",
                    "minLength", "pattern", "maxItems", "minItems", "uniqueItems", "maxContains", "minContains", "maxProperties",
                    "minProperties", "required", "dependentRequired"]),
    ("meta-data", ["title", "description", "default", "deprecated", "readOnly", "writeOnly", "examples"]),
    ("format-annotation", ["format"]),
    ("content", ["contentEncoding", "contentMediaType", "contentSchema"]),
]

/// What the 2020-12 meta-schema keeps from earlier drafts, marked deprecated, so no one gives them
/// another meaning.
private let compatibility = ["definitions", "dependencies", "$recursiveAnchor", "$recursiveRef"]

/// The types a keyword matters for, where it isn't every type: the validation keywords for numbers,
/// strings, arrays and objects (validation §6.2 to §6.5), `format` and the content keywords, which
/// apply to strings, and the applicators that go into an array's items or an object's members.
private let relevance: [String: [String]] = [
    "minLength": ["string"], "maxLength": ["string"], "pattern": ["string"], "format": ["string"], "contentEncoding": ["string"],
    "contentMediaType": ["string"], "contentSchema": ["string"],
    "minimum": ["number", "integer"], "maximum": ["number", "integer"], "exclusiveMinimum": ["number", "integer"],
    "exclusiveMaximum": ["number", "integer"], "multipleOf": ["number", "integer"],
    "items": ["array"], "prefixItems": ["array"], "contains": ["array"], "minContains": ["array"], "maxContains": ["array"],
    "minItems": ["array"], "maxItems": ["array"], "uniqueItems": ["array"], "unevaluatedItems": ["array"],
    "properties": ["object"], "required": ["object"], "additionalProperties": ["object"], "patternProperties": ["object"],
    "propertyNames": ["object"], "minProperties": ["object"], "maxProperties": ["object"], "dependentRequired": ["object"],
    "dependentSchemas": ["object"], "unevaluatedProperties": ["object"],
]

private let typeNames = ["string", "number", "integer", "boolean", "object", "array", "null"]

/// The formats validation §7.3 defines, the six the schema model is taught first.
private let formats = ["date-time", "date", "time", "email", "uri", "uuid", "duration", "idn-email", "hostname", "idn-hostname", "ipv4",
                       "ipv6", "uri-reference", "iri", "iri-reference", "uri-template", "json-pointer", "relative-json-pointer", "regex"]

/// The encodings validation §8.3 points to: RFC 4648's, and MIME's quoted-printable (RFC 2045 §6.7;
/// its base64, §6.8, is RFC 4648's). Not MIME's identity encodings (7bit, 8bit, binary), which
/// 2020-12 says by leaving `contentEncoding` out.
private let encodings = ["quoted-printable", "base16", "base32", "base64"]

/// Each keyword and its schema, in the order the meta-schema lists them.
private var keywords: [JSONMember] { MetaSchema.root["properties"]?.members ?? [] }

private func keyword(_ name: String) -> JSONNode? { MetaSchema.root["properties"]?[name] }

/// The schema a local `$ref` names: the root (`#`), or one of its definitions (`#/$defs/stringArray`).
private func target(of schema: JSONNode) -> JSONNode? {
    guard let reference = schema["$ref"]?.string else { return nil }
    if reference == "#" { return MetaSchema.root }
    guard reference.hasPrefix("#/$defs/") else { return nil }
    return MetaSchema.root["$defs"]?[String(reference.dropFirst("#/$defs/".count))]
}

/// A schema's default: its own, or that of a definition its `$ref`s lead to.
private func defaultValue(of schema: JSONNode) -> JSONNode? {
    var schema = schema
    for _ in 0..<8 {
        if let value = schema["default"] { return value }
        guard let next = target(of: schema), next != MetaSchema.root else { return nil }
        schema = next
    }
    return nil
}

/// The values a schema names (its `oneOf` or `anyOf` branches that are a `const`, through a `$ref`),
/// each with its description, in order; and its branches that aren't a `const`.
private func named(_ schema: JSONNode) -> (values: [(value: String, description: String?)], others: [JSONNode]) {
    let schema = target(of: schema) ?? schema
    let branches = (schema["oneOf"] ?? schema["anyOf"])?.elements ?? []
    let values = branches.compactMap { branch in branch["const"]?.string.map { ($0, branch["description"]?.string) } }
    return (values, branches.filter { $0["const"] == nil })
}

/// Read as the core's JSON, which its validator checks: an object's duplicate members as the last.
private func json(_ node: JSONNode) -> JSONValue {
    switch node.value {
    case .object(let members): .object(Dictionary(members.map { ($0.key, json($0.value)) }, uniquingKeysWith: { _, last in last }))
    case .array(let elements): .array(elements.map(json))
    case .string(let string): .string(string)
    case .number(let literal): .number(Double(literal) ?? .nan)
    case .bool(let bool): .bool(bool)
    case .null: .null
    }
}

/// The meta-schema compiled by the core's validator, once.
private let validator: SchemaValidator = {
    guard case .object(let schema) = json(MetaSchema.root) else { preconditionFailure("the meta-schema's root isn't an object") }
    return SchemaValidator(JSONSchema(schema))
}()

/// Where `schema` breaks the meta-schema, each as "pointer keyword" ("/minLength minimum"; the root
/// is "/").
private func violations(_ schema: JSONValue) -> [String] {
    validator.violations(of: schema).map { "\($0.pointer.isEmpty ? "/" : $0.pointer) \($0.keyword)" }
}

private func violations(_ text: String) throws -> [String] { violations(json(try JSONReader.read(text))) }

/// Schemas made up at random, deterministically: each keyword given a value it may hold, nested as
/// deep as asked; and a value each keyword may not hold.
private struct RandomSchemas {
    var seed: UInt64

    mutating func next(_ bound: Int) -> Int {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Int(seed >> 33) % bound
    }

    mutating func pick<T>(_ items: [T]) -> T { items[next(items.count)] }

    /// `true` or `false` now and then, else an object of one to four keywords.
    mutating func schema(depth: Int) -> JSONValue {
        if depth == 0 || next(8) == 0 { return .bool(next(4) != 0) }
        var object: JSONObject = [:]
        for _ in 0...next(4) {
            let name = pick(keywords).key
            object[name] = value(of: name, depth: depth - 1)
        }
        return .object(object)
    }

    mutating func schemas(depth: Int, from least: Int) -> JSONValue {
        .array((0..<least + next(3)).map { _ in schema(depth: depth) })
    }

    mutating func anything() -> JSONValue { pick([.null, true, 3, -0.5, "text", [1, "a"], ["a": 1]]) }

    mutating func names() -> JSONValue { .array(Array(["a", "b", "c", "é"].prefix(next(5))).map { .string($0) }) }

    /// A value `name` may hold; nil for a name that isn't a keyword.
    mutating func value(of name: String, depth: Int) -> JSONValue? {
        switch name {
        case "title", "description", "$comment": pick(["Pet", "", "é 😀", "a \"quoted\" name"])
        case "type":
            next(2) == 0 ? .string(pick(typeNames))
                : .array(Array(typeNames.shuffled(using: &self).prefix(1 + next(3))).map { .string($0) })
        case "properties", "$defs", "dependentSchemas", "definitions":
            .object(Dictionary(uniqueKeysWithValues: ["a", "b"].prefix(next(3)).map { ($0, schema(depth: depth)) }))
        case "patternProperties": ["^x-": schema(depth: depth)]
        case "required": names()
        case "dependentRequired": ["a": names()]
        case "dependencies": ["a": next(2) == 0 ? names() : schema(depth: depth)]
        case "items", "contains", "additionalProperties", "propertyNames", "if", "then", "else", "not", "unevaluatedItems",
             "unevaluatedProperties", "contentSchema":
            schema(depth: depth)
        case "prefixItems", "allOf", "anyOf", "oneOf": schemas(depth: depth, from: 1)
        case "enum", "examples": .array((0..<next(4)).map { _ in anything() })
        case "const", "default": anything()
        case "format": .string(pick(formats + ["int64"]))
        case "contentEncoding": .string(pick(encodings + ["x-custom"]))
        case "contentMediaType": pick(["application/json", "image/png"])
        case "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum": pick([0, -3.5, 1e6, 42])
        case "multipleOf": pick([1, 0.01, 7])
        case "minLength", "maxLength", "minItems", "maxItems", "minContains", "maxContains", "minProperties", "maxProperties":
            pick([0, 1, 80])
        case "pattern": pick(["^[a-z]+$", "\\d{3}", ""])
        case "uniqueItems", "readOnly", "writeOnly", "deprecated": .bool(next(2) == 0)
        case "$id": pick(["https://example.com/pet", "pet.json", "https://example.com/a#"])
        case "$schema": "https://json-schema.org/draft/2020-12/schema"
        case "$ref", "$dynamicRef", "$recursiveRef": pick(["#", "#/$defs/a", "other.json#/x"])
        case "$anchor", "$dynamicAnchor", "$recursiveAnchor": pick(["pet", "_a-1.b"])
        case "$vocabulary": ["https://json-schema.org/draft/2020-12/vocab/core": true]
        default: nil
        }
    }

    /// A value `name` may not hold; nil where anything goes (`const`, `default`).
    static func wrong(for name: String) -> JSONValue? {
        switch name {
        case "title", "description", "$comment", "format", "contentEncoding", "contentMediaType", "$schema", "$ref", "$dynamicRef",
             "$recursiveRef":
            3
        case "type": "strin"
        case "properties", "$defs", "dependentSchemas", "definitions", "patternProperties": []
        case "required": "a"
        case "dependentRequired": ["a": "b"]
        case "dependencies": ["a": 3]
        case "items", "contains", "additionalProperties", "propertyNames", "if", "then", "else", "not", "unevaluatedItems",
             "unevaluatedProperties", "contentSchema":
            42
        case "prefixItems", "allOf", "anyOf", "oneOf": []
        case "enum", "examples": "a"
        case "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum": "1"
        case "multipleOf": 0
        case "minLength", "maxLength", "minItems", "maxItems", "minContains", "maxContains", "minProperties", "maxProperties": -1
        case "pattern": 3
        case "uniqueItems", "readOnly", "writeOnly", "deprecated": "yes"
        case "$id": "https://example.com/pet#name"
        case "$anchor", "$dynamicAnchor", "$recursiveAnchor": "1a"
        case "$vocabulary": ["https://example.com/vocab": 1]
        default: nil
        }
    }
}

extension RandomSchemas: RandomNumberGenerator {
    mutating func next() -> UInt64 {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return seed
    }
}

@MainActor let metaSchemaTests = Suite("Meta-schema", [
    test("its text reads as JSON, once, and the root is a schema of objects or booleans") {
        expectEqual(try JSONReader.read(MetaSchema.text), MetaSchema.root)
        expect(MetaSchema.root.isObject)
        expectEqual(MetaSchema.root["type"]?.elements?.map(\.string), ["object", "boolean"])
        expectEqual(MetaSchema.root["$schema"]?.string, JSONSchema.dialect)
    },
    test("every keyword of every 2020-12 vocabulary is a property, once, and nothing else is but the four kept for compatibility") {
        let names = keywords.map(\.key)
        for (vocabulary, words) in vocabularies {
            for word in words { expect(names.contains(word), "\(vocabulary): \(word)") }
        }
        expectEqual(Set(names), Set(vocabularies.flatMap(\.keywords) + compatibility))
        expectEqual(names.count, Set(names).count, "no keyword twice")
        expectEqual(names.count, 61)
    },
    test("the four kept for compatibility are marked deprecated, as the official meta-schema marks them, and nothing else is") {
        for member in keywords {
            let deprecated = member.value["deprecated"]
            expectEqual(deprecated?.bool, compatibility.contains(member.key) ? true : nil, member.key)
        }
    },
    test("the order is the offering order: the most used first, the identifiers last, then the deprecated") {
        let names = keywords.map(\.key)
        expectEqual(Array(names.prefix(10)), ["title", "description", "type", "properties", "required", "items", "enum", "const", "default",
                                              "format"])
        expectEqual(Array(names.suffix(4)), compatibility)
        expectEqual(Set(names.dropLast(4).suffix(6)), ["$id", "$anchor", "$dynamicRef", "$dynamicAnchor", "$schema", "$vocabulary"])
        let used = names.firstIndex(of: "examples") ?? names.count
        for word in ["minimum", "maxLength", "pattern", "minItems", "additionalProperties", "$defs", "$ref", "anyOf", "oneOf", "allOf",
                     "not", "if", "then", "else"] {
            expect((names.firstIndex(of: word) ?? names.count) < used, "\(word) before the rarer ones")
        }
    },
    test("every keyword says what it's for: a fragment, capitalized, without a period, at most 48 characters, not its own name") {
        for member in keywords {
            guard let description = member.value["description"]?.string else {
                expect(false, "\(member.key) has no description")
                continue
            }
            let bare = member.key.hasPrefix("$") ? String(member.key.dropFirst()) : member.key
            expect(description.first?.isUppercase == true, "\(member.key): \(description)")
            expect(!description.hasSuffix(".") && description.last?.isWhitespace == false, "\(member.key): \(description)")
            expect(description.count <= 48, "\(member.key): \(description) is \(description.count) characters")
            expect(!description.lowercased().hasPrefix(bare.lowercased()), "\(member.key): \(description)")
        }
    },
    test("x-canvas-when names the sibling type and type names only, on the keywords that matter for some types") {
        // Anywhere else in the document it would say nothing: completion reads it on a keyword's schema.
        func find(_ node: JSONNode, at path: [String], into found: inout [[String]]) {
            for member in node.members ?? [] {
                if member.key == "x-canvas-when" { found.append(path) }
                find(member.value, at: path + [member.key], into: &found)
            }
            for (index, element) in (node.elements ?? []).enumerated() { find(element, at: path + ["\(index)"], into: &found) }
        }
        var found: [[String]] = []
        find(MetaSchema.root, at: [], into: &found)
        expectEqual(Set(found.map { $0.joined(separator: "/") }), Set(relevance.keys.map { "properties/\($0)" }))
        expect(keyword("type") != nil, "the sibling it names is a keyword")
        for member in keywords {
            guard let when = member.value["x-canvas-when"] else { continue }
            expectEqual(when.members?.map(\.key), ["type"], member.key)
            let types = when["type"]?.elements?.compactMap(\.string) ?? []
            expectEqual(types, relevance[member.key], member.key)
            expect(types.allSatisfy(typeNames.contains), member.key)
        }
    },
    test("the type names are offered as consts, each described, most used first; type takes one or a list of them") {
        let type = try require(keyword("type"))
        let branches = try require(type["anyOf"]?.elements)
        expectEqual(branches.count, 2)
        let names = named(branches[0])
        expectEqual(names.values.map(\.value), typeNames)
        expectEqual(names.values.map(\.description), ["Text", "Any number", "Whole number", "True or false", "Group of named fields",
                                                      "List of values", "The value null"])
        expectEqual(names.others.count, 0)
        expectEqual(branches[1]["type"]?.string, "array")
        expectEqual(named(try require(branches[1]["items"])).values.map(\.value), typeNames)
    },
    test("the 19 formats are offered as described consts, the six the model is taught first, and any string still goes") {
        let format = named(try require(keyword("format")))
        expectEqual(format.values.map(\.value), formats)
        expectEqual(Set(format.values.map(\.value)).count, 19)
        expectEqual(format.values.prefix(6).map(\.value), ["date-time", "date", "time", "email", "uri", "uuid"])
        expectEqual(format.others.count, 1)
        expectEqual(format.others.first.map(json), ["type": "string"])
        let encoding = named(try require(keyword("contentEncoding")))
        expectEqual(Set(encoding.values.map(\.value)), Set(encodings))
        expectEqual(encoding.values.first?.value, "base64")
        expectEqual(encoding.others.first.map(json), ["type": "string"])
        for (value, description) in format.values + encoding.values {
            let words = description ?? ""
            expect(words.first?.isUppercase == true && !words.hasSuffix(".") && words.count <= 48, "\(value): \(words)")
        }
        let mediaTypes = try require(keyword("contentMediaType")?["examples"]?.elements)
        expectEqual(mediaTypes.first?.string, "application/json")
        expect(mediaTypes.allSatisfy { $0.string?.contains("/") == true })
        expectEqual(keyword("$schema")?["examples"]?.elements?.map(\.string), [JSONSchema.dialect])
    },
    test("the official defaults are kept, and none is added") {
        var defaults: [String: JSONValue] = [:]
        for member in keywords {
            if let value = defaultValue(of: member.value) { defaults[member.key] = json(value) }
        }
        expectEqual(defaults, [
            "minLength": 0, "minItems": 0, "minProperties": 0, "minContains": 1,
            "uniqueItems": false, "readOnly": false, "writeOnly": false, "deprecated": false,
            "properties": [:], "patternProperties": [:], "dependentSchemas": [:], "definitions": [:], "dependencies": [:],
            "required": [],
        ])
    },
    test("the core's validator compiles it whole, and it holds up against itself") {
        expectEqual(validator.problems, [])
        expectEqual(violations(json(MetaSchema.root)), [])
        // What it offers holds up too: each keyword's default, each value it names, each example.
        for member in keywords {
            if let value = defaultValue(of: member.value) {
                expectEqual(violations(.object([member.key: json(value)])), [], "\(member.key)'s default")
            }
            for value in named(member.value).values.map(\.value) {
                expectEqual(violations(.object([member.key: .string(value)])), [], "\(member.key): \(value)")
            }
            for example in member.value["examples"]?.elements ?? [] {
                expectEqual(violations(.object([member.key: json(example)])), [], "\(member.key): \(example.brief)")
            }
        }
        for name in typeNames { expectEqual(violations(["type": .string(name)]), [], name) }
    },
    test("every keyword a type offers written with a number or a boolean to type over holds up against it") {
        // Strings, lists and objects are there to be typed into; a number or a boolean is a value.
        let offered = try require(TypeCompletions.completions(in: "{}", at: 1))
        var written: [String] = []
        for item in offered.items where !item.selection.isEmpty {
            expectEqual(try violations("{" + item.insert + "}"), [], item.insert)
            written.append(item.insert)
        }
        expectEqual(written.count, 17, "\(written)")
        expect(written.contains(#""multipleOf": 1"#), "its exclusive minimum is 0")
    },
    test("every schema these tests are built on holds up against it, and a new type's") {
        for (name, text) in fixtures {
            // The tenth isn't JSON.
            guard let node = try? JSONReader.read(text) else { continue }
            expectEqual(violations(json(node)), [], name)
        }
        expectEqual(try violations(TypeSchemaProperty.starter), [])
        let more = [
            #"{"type": "object", "properties": {"a": {}}}"#,
            ##"{ "$ref": "#/$defs/order", "$defs": { "order": { "properties": { "id": {} }, "required": ["id"] } } }"##,
            #"{"title": "  "}"#,
            #"{ "properties": { "when": { "type": "string", "format": "a-very-long-format-name" } } }"#,
            ##"{ "properties": { "when": { "$ref": "#/$defs/aVeryLongDefinitionName" } } }"##,
            #"{ "properties": { "pay": { "anyOf": [{ "title": "Card" }, { "title": "Cash" }] }, "p": { "allOf": [{ "title": "A" }] } } }"#,
            #"{"properties": {}, "patternProperties": {"^x": {}}, "required": ["xy"]}"#,
            #"{"type":"object","title":"Pet","properties":{"species":{"enum":["dog","cat"]},"name":{"type":"string"},"birthYear":{"type":"integer"}}}"#,
            #"""
            {
              "$defs": {
                "node": { "type": "object", "properties": { "value": { "type": "number" }, "next": { "$ref": "#/$defs/node" } } },
                "a": { "$ref": "#/$defs/b" }, "b": { "$ref": "#/$defs/a" },
                "slash/key": { "properties": { "s": {} } }
              },
              "definitions": { "old": { "properties": { "o": {} } } },
              "properties": {
                "list": { "$ref": "#/$defs/node" },
                "self": { "$ref": "#" },
                "remote": { "$ref": "https://example.com/schemas/address.json" },
                "anchor": { "$ref": "#top" },
                "maybe": { "type": ["string", "null"] },
                "yes": true, "no": false, "open": {},
                "pair": { "type": "array", "prefixItems": [{ "type": "number" }, { "type": "number" }], "items": false }
              },
              "if": { "properties": { "country": { "const": "DE" } } },
              "then": { "required": ["vatNumber"] }
            }
            """#,
            "true", "false", "{}",
        ]
        for text in more { expectEqual(try violations(text), [], text) }
    },
    test("a wrong schema breaks it where it's wrong, as the official meta-schema says") {
        let wrong: [(String, [String])] = [
            (#"{"type": "strin"}"#, ["/type anyOf"]),
            (#"{"minLength": -1}"#, ["/minLength minimum"]),
            (#"{"required": "a"}"#, ["/required type"]),
            (#"{"properties": []}"#, ["/properties type"]),
            ("42", ["/ type"]),
            (#"{"items": [{"type": "number"}]}"#, ["/items type"]),
            (#"{"multipleOf": 0}"#, ["/multipleOf exclusiveMinimum"]),
            (#"{"type": ["string", "string"]}"#, ["/type anyOf"]),
            (#"{"required": ["a", "a"]}"#, ["/required uniqueItems"]),
            (#"{"enum": 3}"#, ["/enum type"]),
            (#"{"allOf": []}"#, ["/allOf minItems"]),
            (#"{"$anchor": "1bad"}"#, ["/$anchor pattern"]),
            (#"{"$id": "https://example.com/pet#name"}"#, ["/$id pattern"]),
            (#"{"$vocabulary": {"https://example.com/vocab": 1}}"#, ["/$vocabulary/https:~1~1example.com~1vocab type"]),
            (#"{"format": 3}"#, ["/format type"]),
            (#"{"minItems": 1.5}"#, ["/minItems type"]),
            (#"{"dependentRequired": {"a": "b"}}"#, ["/dependentRequired/a type"]),
            (#"{"properties": {"a": {"items": {"minLength": -1}}}}"#, ["/properties/a/items/minLength minimum"]),
            // These tests' deliberately odd schemas.
            (#"{"title": 3}"#, ["/title type"]),
            (#"{"properties": {"a": {"type": "ninteger"}}, "required": ["fax"]}"#, ["/properties/a/type anyOf"]),
            (#"{"if": {}, "anyOf": [], "oneOf": [], "dependentSchemas": {}}"#, ["/anyOf minItems", "/oneOf minItems"]),
            (#"{ "properties": { "oldPair": { "type": "array", "items": [{ "type": "number" }] }, "weird": 42 } }"#,
             ["/properties/oldPair/items type", "/properties/weird type"]),
        ]
        for (text, expected) in wrong { expectEqual(try violations(text), expected, text) }
    },
    test("schemas made up at random hold up; given a wrong value for any keyword, one breaks it there and nowhere else") {
        var random = RandomSchemas(seed: 2020_12)
        for member in keywords {
            expect(random.value(of: member.key, depth: 1) != nil, "\(member.key) has values to try")
            expect(RandomSchemas.wrong(for: member.key) != nil || ["const", "default"].contains(member.key), "\(member.key) has a wrong value")
        }
        for _ in 0..<300 {
            let schema = random.schema(depth: 3)
            expectEqual(violations(schema), [], "\(schema)")
        }
        for member in keywords {
            guard let wrong = RandomSchemas.wrong(for: member.key) else { continue }
            var schema = random.schema(depth: 2).objectValue ?? [:]
            schema[member.key] = wrong
            let place = "/properties/a/\(member.key)"
            let found = violations(["properties": ["a": .object(schema)]])
            expect(!found.isEmpty, "\(member.key): \(wrong) holds up")
            for violation in found {
                let pointer = violation.prefix { $0 != " " }
                expect(pointer == place || pointer.hasPrefix(place + "/"), "\(member.key): \(violation)")
            }
        }
    },
])

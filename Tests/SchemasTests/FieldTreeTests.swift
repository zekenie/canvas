import Foundation
import Schemas
import TestKit

/// The fixture numbered `n` (from 1), as the spec numbers them.
func fixture(_ n: Int) -> String { fixtures[n - 1].json }

/// A field as one line: `name*: label`, a pattern between slashes, and its fields in braces, each
/// with `{…}` if it has fields of its own.
func line(_ field: SchemaField) -> String {
    let name = (field.isPattern ? "/\(field.name)/" : field.name) + (field.isRequired ? "*" : "")
    let fields = field.fields.map { ($0.isPattern ? "/\($0.name)/" : $0.name) + ($0.isRequired ? "*" : "") + ($0.hasFields ? " {…}" : "") }
    return "\(name): \(field.type.label)" + (fields.isEmpty ? "" : " { \(fields.joined(separator: ", ")) }")
}

func lines(_ text: String) -> [String] { SchemaDocument(text).fields.map(line) }

@MainActor let fieldTreeTests = Suite("Field tree", [
    test("the ten fixtures' fields, in the order written, with what each holds and what's in it") {
        expectEqual(lines(fixture(1)), [])
        expectEqual(lines(fixture(2)), ["email*: email", "phone*: string", "description: string"])
        expectEqual(lines(fixture(3)), ["name*: string", "species*: enum", "birthYear: integer", "coatColor: string", "vaccinated: boolean"])
        expectEqual(lines(fixture(4)), ["title*: string", "author*: string", "isbn: string", "pages: integer", "publishedOn: date",
                                        "genre: enum", "inPrint: boolean"])
        let customer = lines(fixture(5))
        expectEqual(customer.count, 20)
        expectEqual(Array(customer.prefix(4)), ["id*: uuid", "firstName*: string", "lastName*: string", "email*: email"])
        expectEqual(customer.last, "updatedAt: date-time")
        expectEqual(lines(fixture(6)), [
            "id*: string", "customer*: object { name*, email }", "items*: object[] { sku*, quantity*, price }",
            "shippingAddress: object { street, city, postalCode, country }", "status*: enum", "createdAt: date-time",
        ])
        expectEqual(lines(fixture(7)), ["name*: string", "headquarters: object { address {…}, phone }", "founded: integer", "tags: string[]"])
        expectEqual(lines(fixture(8)).map { $0.split(separator: ":").last.map(String.init) }, [" email", " number", " integer", " enum", " boolean"])
        expectEqual(lines(fixture(9)), ["total*: → money { amount*, currency* }", "method*: oneOf", "country: string", "vatNumber: string",
                                        "/^x-/: string"])
        expectEqual(lines(fixture(10)), [])
    },
    test("fixtures' names, rules and states") {
        let documents = fixtures.map { SchemaDocument($0.json) }
        expectEqual(documents.map(\.title), [nil, "Contact", "Pet", "Book", "Customer", "Order", "Organization",
                                             "Quarterly Enterprise Subscription Renewal Request Form", "Payment", "Invoice"])
        expectEqual(documents.map(\.isObject), Array(repeating: true, count: 9) + [false])
        expectEqual(documents[8].rules, ["if/then"])
        expectEqual(documents.filter { !$0.rules.isEmpty }.count, 1)
        let error = try require(documents[9].error)
        expectEqual([error.line, error.column], [6, 35])
    },
    test("nesting reads a level at a time, as deep as it goes") {
        let organization = SchemaDocument(fixture(7))
        let headquarters = try require(organization.fields.first { $0.name == "headquarters" })
        let address = try require(headquarters.fields.first)
        expectEqual(line(address), "address: object { location {…}, city, country }")
        expectEqual(address.fields.first.map(line), "location: object { lat, lng }")
        expectEqual(address.fields.first?.fields.map(line), ["lat: number", "lng: number"])
        expectEqual(address.fields.first?.fields.first?.hasFields, false)
    },
    test("enum values and choices: strings bare, other values as JSON; options by title, type, $ref or place") {
        let text = #"""
        { "properties": {
            "mixed": { "enum": ["a", 1, 2.50, true, null, {"x": 1}, [1]] },
            "pick": { "anyOf": [ { "title": "Named" }, { "type": "string" }, { "type": ["integer", "null"] },
                                 { "$ref": "#/$defs/thing" }, { "minimum": 3 } ] },
            "all": { "allOf": [ { "$ref": "#/$defs/a" }, { "$ref": "#/$defs/b" } ] },
            "fixed": { "const": "DE" },
            "one": { "oneOf": [] }
        } }
        """#
        let fields = SchemaDocument(text).fields
        expectEqual(fields.map(\.type), [
            .enumeration(["a", "1", "2.50", "true", "null", "{…}", "[…]"]),
            .choice(.anyOf, ["Named", "string", "integer|null", "thing", "option 5"]),
            .choice(.allOf, ["a", "b"]),
            .constant("DE"),
            .choice(.oneOf, []),
        ])
        expectEqual(fields.map(\.type.label), ["enum", "anyOf", "allOf", "= DE", "oneOf"], "JSON Schema's words, as the rules line says them")
    },
    test("types JSON Schema can say: lists, booleans, formats without a type, arrays of anything, tuples, and nothing") {
        let text = #"""
        { "properties": {
            "maybe": { "type": ["string", "null"] },
            "single": { "type": ["integer"] },
            "yes": true, "no": false, "open": {},
            "mail": { "format": "email" },
            "count": { "type": "integer", "format": "int64" },
            "emails": { "type": "array", "items": { "type": "string", "format": "email" } },
            "grid": { "type": "array", "items": { "type": "array", "items": { "type": "number" } } },
            "choices": { "type": "array", "items": { "enum": ["a", "b"] } },
            "refs": { "type": "array", "items": { "$ref": "#/$defs/thing" } },
            "anything": { "type": "array" },
            "pair": { "type": "array", "prefixItems": [{ "type": "number" }, { "type": "number" }] },
            "oldPair": { "type": "array", "items": [{ "type": "number" }] },
            "implied": { "properties": { "a": {} } },
            "list": { "items": { "type": "boolean" } },
            "map": { "type": "object", "additionalProperties": { "type": "string" } },
            "weird": 42,
            "typo": { "type": "ninteger" },
            "typos": { "type": ["nul"] }
        } }
        """#
        expectEqual(SchemaDocument(text).fields.map { "\($0.name) \($0.type.label)" }, [
            "maybe string|null", "single integer", "yes any", "no never", "open any", "mail email", "count integer", "emails email[]",
            "grid number[][]", "choices enum[]", "refs → thing[]", "anything array", "pair array", "oldPair array", "implied object",
            "list boolean[]", "map object", "weird any", "typo ninteger", "typos nul",
        ])
        let types = SchemaDocument(text).fields.map(\.type)
        expectEqual(types.suffix(2), [.unknown("ninteger"), .unknown("nul")], "a type that isn't one, as written: not any")
        expectEqual(types.map(\.baseLabel).compactMap { $0 }, ["string", "array", "array", "array", "array", "array"],
                    "in a word: a format's string (mail's; count's int64 is an integer's), an array's array")
    },
    test("$ref: into $defs, definitions or any pointer in the document; outside it, a name without fields; circles end") {
        let text = #"""
        {
          "$defs": {
            "node": { "type": "object", "properties": { "value": { "type": "number" }, "next": { "$ref": "#/$defs/node" } } },
            "a": { "$ref": "#/$defs/b" }, "b": { "$ref": "#/$defs/a" },
            "loop": { "type": "array", "items": { "$ref": "#/$defs/loop" } },
            "slash/key": { "properties": { "s": {} } },
            "alias": { "$ref": "#/definitions/old" }
          },
          "definitions": { "old": { "properties": { "o": {} } } },
          "properties": {
            "list": { "$ref": "#/$defs/node" },
            "circle": { "$ref": "#/$defs/a" },
            "loop": { "$ref": "#/$defs/loop" },
            "escaped": { "$ref": "#/$defs/slash~1key" },
            "aliased": { "$ref": "#/$defs/alias" },
            "self": { "$ref": "#" },
            "pointer": { "$ref": "#/properties/list" },
            "remote": { "$ref": "https://example.com/schemas/address.json" },
            "anchor": { "$ref": "#top" },
            "missing": { "$ref": "#/$defs/nope" },
            "overridden": { "$ref": "#/$defs/node", "properties": { "own": {} } }
          }
        }
        """#
        let fields = SchemaDocument(text).fields
        expectEqual(fields.map(line), [
            "list: → node { value, next {…} }", "circle: → a", "loop: → loop", "escaped: → slash~1key { s }", "aliased: → alias { o }",
            "self: → # { list {…}, circle, loop, escaped {…}, aliased {…}, self {…}, pointer {…}, remote, anchor, missing, overridden {…} }",
            "pointer: → list { value, next {…} }", "remote: → address.json", "anchor: → top", "missing: → nope", "overridden: → node { own }",
        ])
        // A list of nodes goes on as far as it's followed.
        var node = try require(fields.first)
        for _ in 0..<50 { node = try require(node.fields.last) }
        expectEqual(node.name, "next")
    },
    test("patternProperties follow properties, at the root and nested; required never names a pattern") {
        let text = #"""
        { "required": ["^a"], "patternProperties": { "^a": { "type": "string" } }, "properties": { "b": {
            "type": "object", "patternProperties": { "^x-": {} }, "properties": { "c": {} } } } }
        """#
        expectEqual(lines(text), ["b: object { c, /^x-/ }", "/^a/: string"])
    },
    test("a root with no properties of its own lists its $ref's; any other root, or none, lists nothing") {
        expectEqual(lines(##"{ "$ref": "#/$defs/order", "$defs": { "order": { "properties": { "id": {} }, "required": ["id"] } } }"##), ["id*: any"])
        // An array of objects is no object: its items' fields aren't the root's.
        for text in [#"[1, 2]"#, #""text""#, "true", "{}", #"{"type": "array", "items": {"properties": {"a": {}}}}"#, #"{"properties": 3}"#] {
            expectEqual(SchemaDocument(text).fields.count, 0, text)
        }
        expectEqual(SchemaDocument("[1]").isObject, false)
        expectEqual(SchemaDocument("{}").isObject, true)
    },
    test("rules at the root: if with then and else, and each combinator") {
        expectEqual(SchemaDocument(#"{"if": {}, "then": {}, "else": {}, "not": {}, "allOf": [], "dependentRequired": {}}"#).rules,
                    ["if/then/else", "allOf", "not", "dependentRequired"])
        expectEqual(SchemaDocument(#"{"if": {}, "anyOf": [], "oneOf": [], "dependentSchemas": {}}"#).rules, ["if", "anyOf", "oneOf", "dependentSchemas"])
    },
    test("a blank title is no title; a half-typed schema keeps a title read before the error") {
        expectEqual(SchemaDocument(#"{"title": "  "}"#).title, nil)
        expectEqual(SchemaDocument(#"{"title": 3}"#).title, nil)
        expectEqual(SchemaDocument(#"{"title": "Pet", "properties": {"#).title, "Pet")
        expectEqual(SchemaDocument(#"{"properties": {"title": "Nested"}, "#).title, nil)
        expectEqual(SchemaDocument(#"{"title": "Pet" "properties""#).title, "Pet", "read whole")
        expectEqual(SchemaDocument(#"{"title": "Pe"#).title, nil, "not read whole")
    },
])

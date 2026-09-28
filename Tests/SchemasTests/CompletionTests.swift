import Canvas
import Foundation
import Schemas
import TestKit

// Completion twice over: the generic engine against a schema of these tests' own, so it's held to
// JSON Schema and nothing of the card's; and the card's language, `SchemaCompletions`, against the
// meta-schema, with carets marked `|` in UTF-16, as the code editor counts them.

/// `marked` with its `|` taken out, and the caret's offset in `unit`s (UTF-16 for the card, UTF-8
/// for the engine).
private func unmarked(_ marked: String, utf16: Bool = true) -> (text: String, offset: Int) {
    let parts = marked.split(separator: "|", omittingEmptySubsequences: false)
    return (parts.joined(), utf16 ? parts[0].utf16.count : parts[0].utf8.count)
}

/// What the card offers at the caret marked `|`.
private func complete(_ marked: String) -> JSONCompletions? {
    let (text, offset) = unmarked(marked)
    return SchemaCompletions.completions(in: text, at: offset)
}

private func labels(_ completions: JSONCompletions?) -> [String] { completions?.items.map(\.label) ?? [] }

@MainActor private func item(_ label: String, in completions: JSONCompletions?) throws -> JSONCompletionItem {
    try require(completions?.items.first { $0.label == label }, "no \(label) in \(labels(completions))")
}

/// The text `marked` becomes once `label` is picked (UTF-16 ranges, as `NSString` replaces them),
/// with where the caret goes marked `|`, or what's selected in «».
@MainActor private func picking(_ label: String, at marked: String) throws -> String {
    let completions = try require(complete(marked), "nothing at \(marked)")
    return applied(try item(label, in: completions), completions.range, to: unmarked(marked).text)
}

private func applied(_ item: JSONCompletionItem, _ range: Range<Int>, to text: String) -> String {
    let insert = item.insert as NSString
    let selection = NSRange(location: item.selection.lowerBound, length: item.selection.count)
    let marked = selection.length == 0
        ? insert.replacingCharacters(in: selection, with: "|")
        : insert.replacingCharacters(in: selection, with: "«" + insert.substring(with: selection) + "»")
    return (text as NSString).replacingCharacters(in: NSRange(location: range.lowerBound, length: range.count), with: marked)
}

// MARK: The engine, generically

/// A schema of the tests' own, which has each thing the engine reads: nested objects, additional
/// and pattern properties, prefix items then items, `$ref`s into `$defs` (and around in a circle),
/// `allOf`, an enum and described consts, a deprecated property, defaults, `x-canvas-when`, and
/// `uniqueItems`.
private let shapes = ##"""
{
  "$defs": {
    "size": { "description": "How big", "enum": ["S", "M", "L"] },
    "point": { "type": "object", "properties": { "x": { "type": "number" }, "y": { "type": "number" } } },
    "loop": { "$ref": "#/$defs/pool" },
    "pool": { "$ref": "#/$defs/loop" }
  },
  "type": "object",
  "properties": {
    "name": { "type": "string", "description": "What it's called" },
    "kind": { "description": "Which sort", "oneOf": [{ "const": "circle", "description": "Round" }, { "const": "square", "description": "Four sides" }] },
    "size": { "$ref": "#/$defs/size" },
    "radius": { "type": "number", "description": "Only for circles", "x-canvas-when": { "kind": ["circle"] } },
    "side": { "type": "integer", "default": 3, "x-canvas-when": { "kind": ["square"] } },
    "old": { "type": "string", "deprecated": true },
    "visible": { "type": "boolean", "default": true },
    "origin": { "$ref": "#/$defs/point" },
    "tags": { "type": "array", "items": { "enum": ["red", "green", "blue"] }, "uniqueItems": true },
    "pair": { "type": "array", "prefixItems": [{ "const": "first" }, { "type": "boolean" }], "items": { "type": "null" } },
    "notes": { "type": "object", "additionalProperties": { "type": "object", "properties": { "text": { "type": "string" } } } },
    "labels": { "type": "object", "patternProperties": { "^x-": { "examples": ["extension"] } }, "additionalProperties": { "type": "integer" } },
    "box": { "allOf": [{ "properties": { "width": { "type": "number" } } }, { "properties": { "height": { "type": "number" }, "width": { "type": "string" } } }] },
    "child": { "$ref": "#" },
    "circular": { "$ref": "#/$defs/loop" },
    "anything": true,
    "unsaid": {}
  }
}
"""##

private let shapesEngine = JSONCompleter(schema: try! JSONReader.read(shapes))

/// What the engine offers against `shapes` at the caret marked `|` (UTF-8).
private func shaped(_ marked: String, _ engine: JSONCompleter = shapesEngine) -> JSONCompletions? {
    let (text, offset) = unmarked(marked, utf16: false)
    return engine.completions(in: text, at: offset)
}

/// The item for `label`, written into `marked`'s text (UTF-8 ranges), the caret marked `|` or the
/// selection in «».
@MainActor private func shapedPick(_ label: String, at marked: String, _ engine: JSONCompleter = shapesEngine) throws -> String {
    let completions = try require(shaped(marked, engine), "nothing at \(marked)")
    let item = try item(label, in: completions)
    let insert = Array(item.insert.utf8), text = Array(unmarked(marked, utf16: false).text.utf8)
    let s = item.selection
    let middle = s.isEmpty ? Array("|".utf8) : Array("«".utf8) + insert[s] + Array("»".utf8)
    let written = Array(insert[..<s.lowerBound]) + middle + Array(insert[s.upperBound...])
    return String(decoding: text[..<completions.range.lowerBound] + written + text[completions.range.upperBound...], as: UTF8.self)
}

private let shapeKeys = ["name", "kind", "size", "radius", "side", "visible", "origin", "tags", "pair", "notes", "labels", "box", "child",
                         "circular", "anything", "unsaid"]

@MainActor let completionTests = Suite("JSON completion", [
    test("the engine: an object's keys in its schema's order, with descriptions, but those there already and those deprecated") {
        let c = try require(shaped("{|}"))
        expectEqual(labels(c), shapeKeys, "old is deprecated")
        expectEqual(c.range, 1..<1)
        expectEqual(c.query, "")
        expectEqual(try item("name", in: c).detail, "What it's called")
        expectEqual(try item("size", in: c).detail, "How big", "through its $ref")
        expectEqual(try item("unsaid", in: c).detail, "")
        expect(c.items.allSatisfy(\.isRelevant))
        expectEqual(labels(shaped(#"{"name": "A", "visible": true, |}"#)), shapeKeys.filter { $0 != "name" && $0 != "visible" })
        expect(!labels(shaped(#"{"ol|"#)).contains("old"), "not even typed")
    },
    test("the engine: x-canvas-when leaves out, with nothing typed, the keys that don't matter beside the object's members, and ranks them last once something is") {
        expectEqual(labels(shaped(#"{"kind": "circle", |}"#)), shapeKeys.filter { $0 != "kind" && $0 != "side" })
        expectEqual(labels(shaped(#"{"kind": ["square"], |}"#)), shapeKeys.filter { $0 != "kind" && $0 != "radius" }, "a list of values")
        let typed = try require(shaped(#"{"kind": "circle", "s|"#))
        expectEqual(labels(typed).last, "side")
        expectEqual(typed.items.filter { !$0.isRelevant }.map(\.label), ["side"])
        expectEqual(typed.query, "s")
        // A value its own schema doesn't list (one being typed, a misspelling) says nothing yet.
        expectEqual(labels(shaped(#"{"kind": "", |}"#)), shapeKeys.filter { $0 != "kind" })
        expectEqual(labels(shaped(#"{"kind": "circel", |}"#)), shapeKeys.filter { $0 != "kind" })
        expectEqual(labels(shaped(#"{"kind": ["", "square"], |}"#)), shapeKeys.filter { $0 != "kind" && $0 != "radius" }, "those it lists do")
    },
    test("the engine: a key is written with a value to type into, by what its schema accepts") {
        expectEqual(try shapedPick("name", at: "{|}"), #"{"name": "|"}"#)
        expectEqual(try shapedPick("kind", at: "{|}"), #"{"kind": "|"}"#, "described consts of strings")
        expectEqual(try shapedPick("size", at: "{|}"), #"{"size": "|"}"#, "an enum of strings, through a $ref")
        expectEqual(try shapedPick("radius", at: "{|}"), #"{"radius": «0»}"#)
        expectEqual(try shapedPick("side", at: "{|}"), #"{"side": «3»}"#, "its default")
        expectEqual(try shapedPick("visible", at: "{|}"), #"{"visible": «true»}"#)
        expectEqual(try shapedPick("origin", at: "{|}"), #"{"origin": {|}}"#)
        expectEqual(try shapedPick("tags", at: "{|}"), #"{"tags": [|]}"#)
        expectEqual(try shapedPick("box", at: "{|}"), #"{"box": {|}}"#, "properties, in its branches, make it an object")
        expectEqual(try shapedPick("anything", at: "{|}"), #"{"anything": |}"#)
        expectEqual(try shapedPick("unsaid", at: "{|}"), #"{"unsaid": |}"#)
        // Asked again at once where the value written has candidates of its own.
        let c = try require(shaped("{|}"))
        let reopening = c.items.filter(\.reopens).map(\.label)
        expectEqual(reopening, ["kind", "size", "origin", "tags", "pair", "box", "child"])
    },
    test("the engine: values from const and enum, described consts, examples, the type's, and defaults, once each") {
        let kinds = try require(shaped(#"{"kind": |}"#))
        expectEqual(labels(kinds), ["circle", "square"])
        expectEqual(kinds.items.map(\.detail), ["Round", "Four sides"])
        expectEqual(kinds.items.map(\.insert), [#""circle""#, #""square""#])
        expectEqual(labels(shaped(#"{"size": "M|"}"#)), ["S", "M", "L"], "every one, whatever's typed")
        expectEqual(labels(shaped(#"{"visible": |}"#)), ["true", "false"], "its default once")
        expectEqual(labels(shaped(#"{"origin": |}"#)), ["{}"])
        expectEqual(labels(shaped(#"{"labels": {"x-a": |}}"#)), ["extension"], "a pattern property's")
        expectEqual(shaped(#"{"labels": {"other": |}}"#), nil, "an integer, the additional properties'")
        expectEqual(shaped(#"{"anything": |}"#), nil)
        expectEqual(shaped(#"{"circular": |}"#), nil, "a $ref in a circle ends")
        // In a string being typed, only strings.
        expectEqual(shaped(#"{"visible": "|"}"#), nil)
        expectEqual(labels(shaped(#"{"visible": tr|}"#)), ["true", "false"])
        expectEqual(try require(shaped(#"{"visible": tr|}"#)).range, 12..<14, "the word whole")
    },
    test("the engine: an array's elements, prefixItems then items, and uniqueItems leaves out what it holds") {
        expectEqual(labels(shaped(#"{"tags": [|]}"#)), ["red", "green", "blue"])
        expectEqual(labels(shaped(#"{"tags": ["red", |]}"#)), ["green", "blue"])
        expectEqual(labels(shaped(#"{"tags": ["red", "b|", "green"]}"#)), ["blue"], "the one being typed isn't held")
        expectEqual(labels(shaped(#"{"pair": [|]}"#)), ["first"])
        expectEqual(labels(shaped(#"{"pair": ["first", |]}"#)), ["true", "false"])
        expectEqual(labels(shaped(#"{"pair": ["first", true, |]}"#)), ["null"])
    },
    test("the engine: nested objects' keys, through $refs, additional properties, allOf and the root again") {
        expectEqual(labels(shaped(#"{"origin": {|}}"#)), ["x", "y"])
        expectEqual(labels(shaped(#"{"origin": {"x": 1, |}}"#)), ["y"])
        expectEqual(labels(shaped(#"{"notes": {"monday": {|}}}"#)), ["text"])
        expectEqual(shaped(#"{"notes": {|}}"#), nil, "additional properties name no keys")
        expectEqual(labels(shaped(#"{"box": {|}}"#)), ["width", "height"], "each branch's, once")
        expectEqual(labels(shaped(#"{"child": {"child": {"na|"#)), shapeKeys)
        expectEqual(shaped(#"{"circular": {|}}"#), nil)
    },
    test("the engine: commas where the text needs them, and a rename where the key's colon is there") {
        expectEqual(try shapedPick("name", at: #"{|"visible": true}"#), #"{"name": "|","visible": true}"#)
        expectEqual(try shapedPick("red", at: #"{"tags": [|"blue"]}"#), #"{"tags": ["red"|,"blue"]}"#)
        // A missing comma goes where it's missing, what's between kept: one edit.
        let marked = "{\"visible\": true\n  \"na|"
        let c = try require(shaped(marked))
        expectEqual(c.range, 16..<22)
        expectEqual(try shapedPick("name", at: marked), "{\"visible\": true,\n  \"name\": \"|\"")
        expectEqual(try shapedPick("green", at: #"{"tags": ["red" |]}"#), #"{"tags": ["red", "green"|]}"#)
        expectEqual(try shapedPick("name", at: #"{"ki|": 1}"#), #"{"name"|: 1}"#)
        expect(try require(shaped(#"{"ki|": 1}"#)).items.allSatisfy { !$0.reopens })
    },
    test("the engine: a client offers values where the schema says nothing, told where they go and what they're held to") {
        let schema = try JSONReader.read(shapes)
        let name = try require(schema["properties"]?["name"])
        let engine = JSONCompleter(schema: schema) { place in
            guard case .value(of: "name") = place.caret.position, place.valueSchemas.contains(where: { $0.range == name.range }) else { return [] }
            return [JSONCompletionOffer(string: "Ada", detail: "A name"), JSONCompletionOffer(json: "7", label: "7")]
        }
        let c = try require(shaped(#"{"name": |}"#, engine))
        expectEqual(labels(c), ["Ada", "7"])
        expectEqual(c.items.first?.detail, "A name")
        expectEqual(labels(shaped(#"{"name": "A|"}"#, engine)), ["Ada"], "only strings in a string")
        expect(try item("name", in: shaped("{|}", engine)).reopens, "its value has candidates now")
        expect(try !item("name", in: shaped("{|}")).reopens)
    },
    test("the engine: a member is held to its property and to every pattern property it matches, patterns read as ECMA-262's") {
        let both = JSONCompleter(schema: try JSONReader.read(#"{"properties": {"a": {"properties": {"x": {}}}}, "patternProperties": {"^a$": {"properties": {"y": {}}}}}"#))
        expectEqual(labels(shaped(#"{"a": {|}}"#, both)), ["x", "y"])
        expectEqual(shaped(#"{"b": {|}}"#, both), nil)
        // As the core's validator reads them: \d is ASCII's digits, and $ only the end.
        let patterns = JSONCompleter(schema: try JSONReader.read(#"{"patternProperties": {"^\\d+$": {"enum": ["digit"]}, "^ab$": {"enum": ["ab"]}}}"#))
        expectEqual(labels(shaped(#"{"12": |}"#, patterns)), ["digit"])
        expectEqual(labels(shaped(#"{"ab": |}"#, patterns)), ["ab"])
        expectEqual(shaped(#"{"١": |}"#, patterns), nil, "an Arabic-Indic digit")
        expectEqual(shaped(#"{"ab\n": |}"#, patterns), nil, "a line break before the end")
    },
    test("the engine: what no other keyword holds, unevaluatedProperties and unevaluatedItems do") {
        let closed = JSONCompleter(schema: try JSONReader.read(
            #"{"properties": {"a": {}}, "allOf": [{"properties": {"c": {"type": "boolean"}}}], "unevaluatedProperties": {"enum": ["rest"]}}"#))
        expectEqual(labels(shaped(#"{"b": |}"#, closed)), ["rest"])
        expectEqual(shaped(#"{"a": |}"#, closed), nil, "properties holds it")
        expectEqual(labels(shaped(#"{"c": |}"#, closed)), ["true", "false"], "a branch's properties hold it")
        let tuple = JSONCompleter(schema: try JSONReader.read(#"{"prefixItems": [{}], "unevaluatedItems": {"enum": [1, 2]}}"#))
        expectEqual(shaped("[|]", tuple), nil, "prefixItems holds it")
        expectEqual(labels(shaped("[0, |]", tuple)), ["1", "2"])
    },
    test("the engine: a new object reopens only where its keys would be offered, none deprecated through a $ref") {
        let engine = JSONCompleter(schema: try JSONReader.read(
            ##"{"properties": {"x": {"type": "object", "properties": {"a": {"$ref": "#/$defs/old"}}}}, "$defs": {"old": {"deprecated": true, "type": "string"}}}"##))
        expectEqual(shaped(#"{"x": {|}}"#, engine), nil)
        expect(try !item("x", in: shaped("{|}", engine)).reopens)
    },
    test("the engine: a number is written with its default, else 0, else the whole number nearest 0 its bounds allow") {
        let engine = JSONCompleter(schema: try JSONReader.read(#"""
            {"properties": {
              "a": {"type": "number", "exclusiveMinimum": 0}, "b": {"type": "integer", "minimum": 5}, "c": {"type": "number", "maximum": -2.5},
              "d": {"type": "number", "exclusiveMaximum": 0}, "e": {"type": "number", "minimum": 0.5, "default": 0.75},
              "f": {"type": "number", "minimum": -3, "maximum": 3}, "g": {"type": "number", "minimum": 1e400}
            }}
            """#))
        let written = ["a": "1", "b": "5", "c": "-3", "d": "-1", "e": "0.75", "f": "0", "g": "0"]
        for (key, number) in written { expectEqual(try shapedPick(key, at: "{|}", engine), "{\"\(key)\": «\(number)»}", key) }
    },
    // MARK: The card's
    test("the card: a schema's keys in the meta-schema's order, each with its description; none deprecated, none there already") {
        let keywords = try require(MetaSchema.root["properties"]?.members)
        let offered = keywords.filter { $0.value["deprecated"]?.bool != true }
        let c = try require(complete("{|}"))
        expectEqual(labels(c), offered.map(\.key))
        expectEqual(c.items.map(\.detail), offered.map { $0.value["description"]?.string ?? "?" })
        expectEqual(labels(c).prefix(4), ["title", "description", "type", "properties"])
        for deprecated in ["definitions", "dependencies", "$recursiveAnchor", "$recursiveRef"] {
            expect(!labels(c).contains(deprecated), deprecated)
            expect(!labels(complete("{\"\(deprecated.prefix(5))|")).contains(deprecated), "\(deprecated), typed")
        }
        let there = labels(complete(#"{"title": "Pet", "description": "One", |}"#))
        expectEqual(there, offered.map(\.key).filter { $0 != "title" && $0 != "description" })
    },
    test("the card: a schema's keys inside properties, items, allOf and $defs, but those only a root has; none where the text is data or names") {
        let root = labels(complete("{|}"))
        expectEqual(root.suffix(2), ["$schema", "$vocabulary"])
        // $vocabulary never goes in a subschema, and $schema only in one with an $id (core §8.1.1, §8.1.2).
        let nested = root.filter { $0 != "$schema" && $0 != "$vocabulary" }
        for marked in [#"{"properties": {"a": {|}}}"#, #"{"items": {|}}"#, #"{"allOf": [{|}]}"#, #"{"$defs": {"x": {|}}}"#,
                       #"{"additionalProperties": {|}}"#, #"{"properties": {"a": {"items": {"not": {|}}}}}"#] {
            expectEqual(labels(complete(marked)), nested, marked)
        }
        expectEqual(labels(complete(#"{"$defs": {"x": {"$id": "x.json", |}}}"#)).suffix(1), ["$schema"])
        expect(!labels(complete(#"{"items": {"$voc|"#)).contains("$vocabulary"), "not even typed")
        for marked in [#"{"properties": {|}}"#, #"{"$defs": {|}}"#, #"{"enum": [{|}]}"#, #"{"enum": [|]}"#, #"{"const": {|}}"#,
                       #"{"const": |}"#, #"{"default": {|}}"#, #"{"examples": [{|}]}"#, #"{"title": "|"}"#,
                       #"{"properties": {"a": {"default": {"type": |}}}}"#] {
            expectEqual(complete(marked), nil, marked)
        }
    },
    test("the card: with nothing typed, a number's schema isn't offered minLength but is minimum; typed, both, what matters first") {
        let number = labels(complete(#"{"type": "number", |}"#))
        expect(number.contains("minimum") && number.contains("maximum"))
        expect(!number.contains("minLength") && !number.contains("items") && !number.contains("properties"))
        let typed = try require(complete(#"{"type": "number", "mi|"#))
        let minimum = try require(labels(typed).firstIndex(of: "minimum")), minLength = try require(labels(typed).firstIndex(of: "minLength"))
        expect(minimum < minLength)
        expect(try item("minimum", in: typed).isRelevant && !item("minLength", in: typed).isRelevant)
        expectEqual(typed.query, "mi")
        // A type that lists string makes string's keywords matter.
        expect(labels(complete(#"{"type": ["string", "null"], |}"#)).contains("minLength"))
        // A type left unchosen (a pick of type, its list of names closed) or misspelled says
        // nothing: every keyword is offered. A type that's none of theirs leaves them out.
        for unsaid in [#"{"type": "", |}"#, #"{"type": "strin", |}"#] {
            let offered = labels(complete(unsaid))
            expect(offered.contains("minLength") && offered.contains("minimum") && offered.contains("properties"), unsaid)
        }
        let boolean = labels(complete(#"{"type": "boolean", |}"#))
        expect(!boolean.contains("minLength") && !boolean.contains("minimum") && boolean.contains("enum"))
    },
    test("the card: type's values with their descriptions, and in a type list those not listed") {
        let quoted = try require(complete(#"{"type": "|"}"#))
        expectEqual(labels(quoted), ["string", "number", "integer", "boolean", "object", "array", "null"])
        expectEqual(quoted.items.map(\.detail), ["Text", "Any number", "Whole number", "True or false", "Group of named fields", "List of values",
                                                 "The value null"])
        expectEqual(labels(complete(#"{"type": |}"#)), labels(quoted) + ["[]"], "or a list of them")
        expectEqual(labels(complete(#"{"type": ["string", "null", |]}"#)), ["number", "integer", "boolean", "object", "array"])
        expectEqual(try picking("integer", at: #"{"type": "str|"}"#), #"{"type": "integer"|}"#)
    },
    test("the card: format's values, the six the model is taught first") {
        let c = try require(complete(#"{"type": "string", "format": "|"}"#))
        expectEqual(labels(c).prefix(6), ["date-time", "date", "time", "email", "uri", "uuid"])
        expectEqual(c.items.count, 19)
        expectEqual(try item("email", in: c).detail, "Email address")
        expectEqual(labels(complete(#"{"contentEncoding": "|"}"#)).first, "base64")
        expectEqual(labels(complete(#"{"$schema": |}"#)), ["https://json-schema.org/draft/2020-12/schema"])
    },
    test("the card: a required list offers the object's properties it doesn't hold yet") {
        let marked = #"{"type": "object", "properties": {"name": {"type": "string"}, "age": {"type": "integer"}, "email": {"format": "email"}}, "required": ["name", |]}"#
        let c = try require(complete(marked))
        expectEqual(labels(c), ["age", "email"])
        expectEqual(c.items.map(\.detail), ["integer", "email"])
        expectEqual(labels(complete(#"{"properties": {"a": {}, "b": {}}, "required": [|]}"#)), ["a", "b"])
        expectEqual(complete(#"{"properties": {"a": {}}, "required": ["a", |]}"#), nil, "all of them required")
        // Nested: the names of the object that holds the list.
        expectEqual(labels(complete(#"{"properties": {"a": {"properties": {"x": {}}, "required": [|]}}}"#)), ["x"])
        // A dependentRequired list isn't a required one.
        expectEqual(complete(#"{"properties": {"a": {}}, "dependentRequired": {"required": [|]}}"#), nil)
        // Picking required reopens where there are names to offer.
        expect(try item("required", in: complete(#"{"properties": {"a": {}}, |}"#)).reopens)
        expect(try !item("required", in: complete("{|}")).reopens)
    },
    test("the card: a $ref offers the whole schema and the root's definitions") {
        let marked = ##"{"$defs": {"money": {"type": "number"}, "a/b": {}}, "definitions": {"old": {"type": "string"}}, "properties": {"price": {"$ref": "|"}}}"##
        let c = try require(complete(marked))
        expectEqual(labels(c), ["#", "#/$defs/money", "#/$defs/a~1b", "#/definitions/old"])
        expectEqual(c.items.map(\.detail), ["Whole schema", "number", "any", "string"])
        expectEqual(labels(complete(#"{"$ref": |}"#)), ["#"])
        expect(try item("$ref", in: complete("{|}")).reopens)
    },
    test("the card: booleans, and a schema-or-boolean's {}, true and false") {
        expectEqual(labels(complete(#"{"uniqueItems": |}"#)), ["true", "false"])
        expectEqual(labels(complete(#"{"additionalProperties": |}"#)), ["{}", "true", "false"])
        expectEqual(labels(complete(#"{"items": |}"#)), ["{}", "true", "false"])
        expectEqual(try picking("{}", at: #"{"additionalProperties": |}"#), #"{"additionalProperties": {|}}"#)
        expect(try item("{}", in: complete(#"{"not": |}"#)).reopens)
        expectEqual(labels(complete(#"{"required": |}"#)), ["[]"])
    },
    test("the card: a key is written with a value to type into") {
        expectEqual(try picking("type", at: "{|}"), #"{"type": "|"}"#)
        expect(try item("type", in: complete("{|}")).reopens, "type's names")
        expectEqual(try picking("minLength", at: "{|}"), #"{"minLength": «0»}"#)
        expectEqual(try picking("minContains", at: "{|}"), #"{"minContains": «1»}"#, "its default")
        expectEqual(try picking("properties", at: "{|}"), #"{"properties": {|}}"#)
        expectEqual(try picking("required", at: "{|}"), #"{"required": [|]}"#)
        expectEqual(try picking("uniqueItems", at: "{|}"), #"{"uniqueItems": «true»}"#)
        expectEqual(try picking("const", at: "{|}"), #"{"const": |}"#)
        expectEqual(try picking("format", at: "{\n  \"type\": \"string\",\n  |\n}"), "{\n  \"type\": \"string\",\n  \"format\": \"|\"\n}")
        let c = try require(complete("{|}"))
        expect(try !item("minLength", in: c).reopens && !item("properties", in: c).reopens && !item("title", in: c).reopens)
        expect(try item("items", in: c).reopens && item("format", in: c).reopens && item("anyOf", in: c).reopens)
    },
    test("the card: a comma after where a member follows, before (one edit from the value before) where one is missing") {
        expectEqual(try picking("title", at: #"{|"type": "string"}"#), #"{"title": "|","type": "string"}"#)
        expectEqual(try picking("number", at: #"{"type": [|"string"]}"#), #"{"type": ["number"|,"string"]}"#)
        let marked = "{\"type\": \"string\"\n  \"mi|"
        let c = try require(complete(marked))
        expectEqual(c.range, 17..<23)
        expectEqual(c.query, "mi")
        expectEqual(try picking("minLength", at: marked), "{\"type\": \"string\",\n  \"minLength\": «0»")
        expectEqual(try picking("format", at: "{\"type\": \"string\" |}"), "{\"type\": \"string\", \"format\": \"|\"}")
        expectEqual(try picking("null", at: #"{"type": ["string" |]}"#), #"{"type": ["string", "null"|]}"#)
        // The key being typed before the next line's key.
        expectEqual(try picking("format", at: "{\n  \"fo|\n  \"type\": \"string\"\n}"), "{\n  \"format\": \"|\",\n  \"type\": \"string\"\n}")
    },
    test("the card: a key whose colon is there is renamed, its value kept") {
        expectEqual(try picking("minimum", at: #"{"mi|": 1}"#), #"{"minimum"|: 1}"#)
        expectEqual(try picking("maximum", at: #"{"type": "number", "ma|ximum": 1}"#), #"{"type": "number", "maximum"|: 1}"#)
        // Where a key goes, none typed, before its colon (a key selected and deleted): the pick names it.
        expectEqual(try picking("maximum", at: #"{"type": "number", |: 1}"#), #"{"type": "number", "maximum"|: 1}"#)
        expectEqual(try picking("maximum", at: "{\n  \"type\": \"number\",\n  |: 1\n}"), "{\n  \"type\": \"number\",\n  \"maximum\"|: 1\n}")
        expectEqual(try picking("title", at: "{|: 1}"), #"{"title"|: 1}"#)
        expectEqual(try picking("maximum", at: #"{"minimum": 1 |: 2}"#), #"{"minimum": 1, "maximum"|: 2}"#, "and its comma")
    },
    test("the card: a string being typed before the rest of its line is picked into it, which stays as it was") {
        let picks: [(label: String, marked: String, expected: String)] = [
            // A quoted value selected and its quote typed: the string is left open over the comma.
            ("string", "{\n  \"type\": \"|,\n  \"title\": \"x\"\n}", "{\n  \"type\": \"string\"|,\n  \"title\": \"x\"\n}"),
            ("string", #"{"type": "str|, "title": "x"}"#, #"{"type": "string"|, "title": "x"}"#),
            ("string", #"{"properties": {"a": {"type": "str|}, "b": {}}}"#, #"{"properties": {"a": {"type": "string"|}, "b": {}}}"#),
            ("string", #"{"anyOf":[{"type":"|},{"type":"null"}]}"#, #"{"anyOf":[{"type":"string"|},{"type":"null"}]}"#),
            ("string", #"{"type": ["|, "null"]}"#, #"{"type": ["string"|, "null"]}"#),
            // A key selected with its quotes and renamed: its colon's after it.
            ("maximum", #"{"ma|: 1}"#, #"{"maximum"|: 1}"#),
            ("maximum", "{\n  \"ma|: 1\n}", "{\n  \"maximum\"|: 1\n}"),
            ("format", "{\"properties\": {\"a\": {\"fo|}},\n \"required\": [\"a\"]}", "{\"properties\": {\"a\": {\"format\": \"|\"}},\n \"required\": [\"a\"]}"),
        ]
        for (label, marked, expected) in picks { expectEqual(try picking(label, at: marked), expected, marked) }
        // The next line's members are the root's, not the key's siblings.
        expect(labels(complete("{\"properties\": {\"a\": {\"re|}},\n \"required\": [\"a\"]}")).contains("required"))
    },
    test("the card: a pick in the middle of a closed string replaces all of it") {
        let schema = "https://json-schema.org/draft/2020-12/schema"
        expectEqual(try picking(schema, at: #"{"$schema": "htt|ps://json-schema.org/draft/2020-12/schema"}"#), "{\"$schema\": \"\(schema)\"|}")
        expectEqual(try picking("#/$defs/my%20def", at: ##"{"$defs": {"my def": {}}, "properties": {"a": {"$ref": "#/$defs/my| def"}}}"##),
                    ##"{"$defs": {"my def": {}}, "properties": {"a": {"$ref": "#/$defs/my%20def"|}}}"##)
    },
    test("retyping any string of real schemas, compact or pretty, and picking what it was, gives back the text byte for byte") {
        // Each string typed again from its opening quote to half of it: left open (so it runs on over
        // the rest of its line), closed, and as a bare word where it can be one; and its quote alone.
        func compact(_ text: String) -> String {
            let bytes = Array(text.utf8)
            return JSONReader.tokens(in: text).map { String(decoding: bytes[$0.range], as: UTF8.self) }.joined()
        }
        func pretty(_ text: String) -> String {
            let bytes = Array(text.utf8), tokens = JSONReader.tokens(in: text)
            var out = "", depth = 0
            for (k, token) in tokens.enumerated() {
                let piece = String(decoding: bytes[token.range], as: UTF8.self)
                let closesNext = k + 1 < tokens.count && [JSONToken.Kind.closeBrace, .closeBracket].contains(tokens[k + 1].kind)
                let opened = k > 0 && [JSONToken.Kind.openBrace, .openBracket].contains(tokens[k - 1].kind)
                switch token.kind {
                case .openBrace, .openBracket:
                    depth += 1
                    out += piece + (closesNext ? "" : "\n" + String(repeating: "  ", count: depth))
                case .closeBrace, .closeBracket:
                    depth -= 1
                    out += (opened ? "" : "\n" + String(repeating: "  ", count: depth)) + piece
                case .comma: out += ",\n" + String(repeating: "  ", count: depth)
                case .colon: out += ": "
                default: out += piece
                }
            }
            return out
        }
        func isWord(_ prefix: String) -> Bool {
            guard let first = prefix.unicodeScalars.first, first.properties.isAlphabetic || first == "_" || first == "$" else { return false }
            return prefix.unicodeScalars.allSatisfy { $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || $0 == "_" || $0 == "$") }
        }
        var picked = [0, 0, 0]
        for text in (fixtures.dropLast().map(\.json) + [SchemaCard.starter]).flatMap({ [compact($0), pretty($0)] }) {
            let bytes = Array(text.utf8)
            for token in JSONReader.tokens(in: text) where token.kind == .string {
                let content = String(decoding: bytes[token.range.lowerBound + 1..<token.range.upperBound - 1], as: UTF8.self)
                guard !content.contains("\\") else { continue }
                let before = String(decoding: bytes[..<token.range.lowerBound], as: UTF8.self)
                let after = String(decoding: bytes[token.range.upperBound...], as: UTF8.self)
                for prefix in Set([String(content.prefix(content.count / 2)), ""]) {
                    let typed = ["\"" + prefix, "\"" + prefix, isWord(prefix) ? prefix : nil]
                    for (variant, typed) in typed.enumerated() {
                        guard let typed else { continue }
                        let retyped = before + typed + (variant == 1 ? "\"" : "") + after
                        let caret = (before + typed as NSString).length
                        guard let c = SchemaCompletions.completions(in: retyped, at: caret), let item = c.items.first(where: { $0.label == content }) else {
                            continue
                        }
                        picked[variant] += 1
                        let result = (retyped as NSString).replacingCharacters(in: NSRange(location: c.range.lowerBound, length: c.range.count), with: item.insert)
                        expectEqual(result, text, "\(variant): \(before.suffix(30))\(typed)‸\(after.prefix(30))")
                    }
                }
            }
        }
        expect(picked[0] > 1_000 && picked[1] > 1_000 && picked[2] > 500, "\(picked) picked, left open, closed and as a word")
    },
    test("the card: offsets in UTF-16, after an é and an emoji, in the text and in what's inserted") {
        let marked = #"{"title": "é😀", "ty|"#
        let c = try require(complete(marked))
        expectEqual(c.range, 17..<20, "é is one unit, 😀 two")
        expectEqual(try picking("type", at: marked), #"{"title": "é😀", "type": "|""#)
        expectEqual(try picking("café", at: #"{"properties": {"café": {}, "😀": {}}, "required": [|]}"#),
                    #"{"properties": {"café": {}, "😀": {}}, "required": ["café"|]}"#)
        let emoji = try item("😀", in: complete(#"{"properties": {"café": {}, "😀": {}}, "required": ["café", |]}"#))
        expectEqual(emoji.selection, 4..<4)
        // A caret between an emoji's two halves is at its start.
        let text = #"{"title": "😀", "a": {}}"#
        let inside = (#"{"title": ""# as NSString).length + 1
        expectEqual(SchemaCompletions.completions(in: text, at: inside), nil, "in the title, which offers nothing")
        expectEqual(SchemaCompletions.completions(in: text, at: (text as NSString).length + 1), nil)
        expectEqual(SchemaCompletions.completions(in: "{}", at: -1), nil)
    },
    test("the card: nothing past the length the editor colors") {
        let long = "{\"description\": \"" + String(repeating: "x", count: 200_001) + "\", }"
        expectEqual(SchemaCompletions.completions(in: long, at: (long as NSString).length - 1), nil)
    },
    test("a pick at any caret in real schemas replaces a token whole or nothing, leaves the brackets where they were, and reads as JSON where it completes a member or value") {
        var seed: UInt64 = 7
        func random(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int(seed >> 33) % n
        }
        let schemas = fixtures.dropLast().map(\.json) + [SchemaCard.starter, MetaSchema.text]
        var picked = 0, read = 0
        for text in schemas {
            let length = (text as NSString).length
            let tokens = JSONReader.tokens(in: text), bytes = Array(text.utf8)
            for _ in 0..<400 {
                let caret = random(length + 1)
                guard let c = SchemaCompletions.completions(in: text, at: caret), let first = c.items.first else { continue }
                picked += 1
                let result = (text as NSString).replacingCharacters(in: NSRange(location: c.range.lowerBound, length: c.range.count), with: first.insert)
                let where_ = "\(caret) in \(text.prefix(40))…: \(first.insert)"
                // What's inserted is whole: its strings closed, its brackets paired.
                let inserted = JSONReader.tokens(in: first.insert)
                expect(!inserted.contains { $0.kind == .invalid }, where_)
                var depth = 0
                for token in inserted {
                    if token.kind == .openBrace || token.kind == .openBracket { depth += 1 }
                    if token.kind == .closeBrace || token.kind == .closeBracket { depth -= 1 }
                    expect(depth >= 0, where_)
                }
                expectEqual(depth, 0, where_)
                // What's replaced holds no bracket of the text's.
                func utf8(_ utf16: Int) -> Int { text.utf8.distance(from: text.startIndex, to: String.Index(utf16Offset: utf16, in: text)) }
                let utf8Range = utf8(c.range.lowerBound)..<utf8(c.range.upperBound)
                let brackets: Set<JSONToken.Kind> = [.openBrace, .closeBrace, .openBracket, .closeBracket]
                expect(!tokens.contains { brackets.contains($0.kind) && $0.range.overlaps(utf8Range) }, where_)
                // In a valid schema a pick replaces a token whole, or nothing (after the space from
                // the value before, where it writes a comma); and where it writes a whole member or
                // value, the schema is still JSON.
                let typed = (utf8Range.lowerBound..<utf8Range.upperBound).first { ![0x20, 0x0A, 0x0D, 0x09].contains(bytes[$0]) } ?? utf8Range.upperBound
                expect(typed == utf8Range.upperBound || tokens.contains { $0.range == typed..<utf8Range.upperBound }, "\(where_) replaces \(utf8Range)")
                if !first.insert.hasSuffix(": ") && !first.insert.hasSuffix(": ,") {
                    read += 1
                    do throws(JSONSyntaxError) {
                        _ = try JSONReader.read(result)
                    } catch {
                        expect(false, "\(where_) → \(error)\n\(result)")
                    }
                }
            }
        }
        expect(picked > 2_000, "\(picked) picks")
        expect(read > 2_000, "\(read) read back")
    },
])

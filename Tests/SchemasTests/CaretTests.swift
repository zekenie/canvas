import Canvas
import Schemas
import TestKit

/// `marked` with its `|` taken out, and the UTF-8 offset where it was: the caret.
private func unmarked(_ marked: String) -> (text: String, offset: Int) {
    let parts = marked.split(separator: "|", omittingEmptySubsequences: false)
    return (parts.joined(), parts[0].utf8.count)
}

/// Where the caret marked `|` in `marked` is.
private func caret(_ marked: String) -> JSONCaret? {
    let (text, offset) = unmarked(marked)
    return JSONCaret.at(offset, in: text)
}

/// What `range` holds of `marked`, its `|` taken out.
private func slice(_ marked: String, _ range: Range<Int>) -> String {
    String(decoding: Array(unmarked(marked).text.utf8)[range], as: UTF8.self)
}

/// The UTF-8 offset just after the first `part` in `marked`, its `|` taken out.
private func offset(after part: String, in marked: String) -> Int? {
    let bytes = Array(unmarked(marked).text.utf8), part = Array(part.utf8)
    guard bytes.count >= part.count else { return nil }
    return (0...bytes.count - part.count).first { bytes[$0..<$0 + part.count].elementsEqual(part) }.map { $0 + part.count }
}

private func keys(_ members: [JSONMember]) -> [String] { members.map(\.key) }

/// `c`'s facts that can't be wrong whatever the text: what a pick replaces holds the caret, a
/// missing comma comes before it, the query is what's typed to the caret, and nothing beside the
/// caret holds it. Nil if they hold, else what doesn't.
private func broken(_ c: JSONCaret, at offset: Int, in utf8: [UInt8]) -> String? {
    guard c.replace.lowerBound >= 0, c.replace.upperBound <= utf8.count, c.replace.contains(offset) || c.replace.upperBound == offset else {
        return "replace \(c.replace) doesn't hold the caret"
    }
    if let comma = c.commaBefore, comma < 0 || comma > c.replace.lowerBound { return "commaBefore \(comma) after \(c.replace)" }
    if c.isQuoted, c.replace.isEmpty || utf8[c.replace.lowerBound] != UInt8(ascii: "\"") { return "a quoted query without a quote" }
    let start = c.replace.lowerBound + (c.isQuoted ? 1 : 0), query = Array(c.query.utf8)
    // A caret inside a character's bytes reads a query with U+FFFD in it; elsewhere it's the bytes.
    let onScalar = offset == utf8.count || utf8[offset] & 0xC0 != 0x80
    if onScalar, start + query.count > offset || !utf8[start..<start + query.count].elementsEqual(query) {
        return "query \(c.query) isn't what's typed from \(start) to \(offset)"
    }
    guard c.containers.count == c.path.count + 1 else { return "\(c.containers.count) containers for a path of \(c.path.count)" }
    switch c.position {
    case .key, .value: if !c.container.isObject || !c.elements.isEmpty { return "a key or a value, not in an object" }
    case .element: if c.container.elements == nil || !c.siblings.isEmpty { return "an element, not in an array" }
    }
    // What's beside the caret: a scalar holds a caret inside it or at its end (it would be the one
    // typed), a container one inside it (the caret would be in it).
    func holds(_ node: JSONNode) -> Bool {
        node.range.lowerBound < offset && (offset < node.range.upperBound || (!node.isObject && node.elements == nil && offset == node.range.upperBound))
    }
    for member in c.siblings where holds(member.value) || (member.keyRange.lowerBound < offset && offset <= member.keyRange.upperBound) {
        return "sibling \(member.key) holds the caret"
    }
    if c.elements.contains(where: holds) { return "an element holds the caret" }
    return nil
}

/// A schema of at least `SchemaPrompts.toSchemaMaxLength` bytes, the longest the model writes, with
/// `end` at its end.
private func longSchema(ending end: String) -> String {
    var text = #"{"title": "Everything", "type": "object", "properties": {"#
    var n = 0
    while text.utf8.count < SchemaPrompts.toSchemaMaxLength {
        text += "\n    \"field\(n)\": {\"type\": \"string\", \"description\": \"Field number \(n), kept short\", \"maxLength\": 80},"
        n += 1
    }
    return text + end
}

@MainActor let caretTests = Suite("JSON caret", [
    test("an empty object: a key goes at the root, nothing typed, nothing around it") {
        let c = try require(caret("{|}"))
        expectEqual(c.path, [])
        expectEqual(c.position, .key)
        expectEqual(c.replace, 1..<1)
        expectEqual(c.query, "")
        expect(!c.isQuoted && !c.hasColon && !c.needsCommaAfter)
        expectEqual(c.commaBefore, nil)
        expectEqual(c.siblings, [])
        expectEqual(c.containers.map(\.range), [0..<2])
        expectEqual(c.root.members, [])
    },
    test("a key being typed: its opening quote to the caret, and the word and closing quote after it") {
        // Left open, the string runs to the line's end, "}" and all: a pick replaces only what's typed.
        let open = "{\"ty|}"
        var c = try require(caret(open))
        expectEqual(c.position, .key)
        expectEqual(slice(open, c.replace), "\"ty")
        expectEqual(c.query, "ty")
        expect(c.isQuoted && !c.hasColon)
        let closed = "{\"ty|\"}"
        c = try require(caret(closed))
        expectEqual(slice(closed, c.replace), "\"ty\"", "the closing quote too")
        expectEqual(c.query, "ty")
        let inside = "{\"ty|pe\"}"
        c = try require(caret(inside))
        expectEqual(slice(inside, c.replace), "\"type\"")
        expectEqual(c.query, "ty")
        // On a compact line, a quote left open pairs with the next key's opening quote: a pick
        // replaces what's typed, never that token whole.
        let compact = "{\"mi|, \"type\": \"string\"}"
        c = try require(caret(compact))
        expectEqual(slice(compact, c.replace), "\"mi")
        expectEqual(c.query, "mi")
        // Without quotes, a word whole.
        let word = "{mi|n}"
        c = try require(caret(word))
        expectEqual(slice(word, c.replace), "min")
        expectEqual(c.query, "mi")
        expect(!c.isQuoted)
    },
    test("a string being typed ends where what's typed does, and what follows it on its line reads as it will once it's closed") {
        // Left open, its token runs to the line's end, over the comma after it.
        let open = "{\n  \"type\": \"|,\n  \"title\": \"x\"\n}"
        var c = try require(caret(open))
        expectEqual(c.position, .value(of: "type"))
        expectEqual(slice(open, c.replace), "\"")
        expect(!c.needsCommaAfter, "the comma's there")
        expectEqual(keys(c.siblings), ["title"])
        // Typed before a string on a compact line, its quote pairs with that string's opening quote.
        let compact = #"{"type": "str|, "title": "x"}"#
        c = try require(caret(compact))
        expectEqual(slice(compact, c.replace), "\"str")
        expect(!c.needsCommaAfter)
        expectEqual(keys(c.siblings), ["title"])
        expectEqual(c.siblings.first?.value.string, "x")
        c = try require(caret(#"{"type": ["|, "null"]}"#))
        expectEqual(c.position, .element(0))
        expect(!c.needsCommaAfter)
        expectEqual(c.elements.map(\.string), ["null"])
        // A key's colon after it: a rename.
        for marked in [#"{"ma|: 1}"#, "{\n  \"ma|: 1\n}"] {
            c = try require(caret(marked))
            expectEqual(c.position, .key, marked)
            expect(c.hasColon && !c.needsCommaAfter, marked)
            expectEqual(slice(marked, c.replace), "\"ma", marked)
        }
        // What closes after it on its line closes the containers it's in, not the ones around them.
        c = try require(caret("{\"properties\": {\"a\": {\"fo|}},\n \"required\": [\"a\"]}"))
        expectEqual(c.path, [.member("properties"), .member("a")])
        expectEqual(c.siblings, [])
        expect(!c.needsCommaAfter)
        expectEqual(keys(try require(c.root.members)), ["properties", "required"])
        // A word and a quote after the closing quote: it pairs with the next string's opening one.
        let word = #"{"type": "str| "title": "x"}"#
        c = try require(caret(word))
        expectEqual(slice(word, c.replace), "\"str")
        expect(c.needsCommaAfter, "a key follows")
        expectEqual(keys(c.siblings), ["title"])
    },
    test("a string closed where a value or key ends is whole, whatever it holds after the caret") {
        let uri = #"{"$schema": "htt|ps://json-schema.org/draft/2020-12/schema"}"#
        var c = try require(caret(uri))
        expectEqual(slice(uri, c.replace), "\"https://json-schema.org/draft/2020-12/schema\"")
        expectEqual(c.query, "htt")
        let spaced = ##"{"$ref": "#/$defs/my| def", "type": "string"}"##
        c = try require(caret(spaced))
        expectEqual(slice(spaced, c.replace), "\"#/$defs/my def\"")
        expect(!c.needsCommaAfter)
        let key = "{\n  \"a b|c\" : 1\n}"
        c = try require(caret(key))
        expectEqual(slice(key, c.replace), "\"a bc\"")
        expect(c.hasColon)
        let last = "[\"x, |y\"\n]"
        c = try require(caret(last))
        expectEqual(slice(last, c.replace), "\"x, y\"", "at its line's end")
    },
    test("where a key goes and a colon follows, a pick names the key and writes no value") {
        var c = try require(caret("{|: 1}"))
        expectEqual(c.position, .key)
        expect(c.hasColon && !c.needsCommaAfter)
        c = try require(caret(#"{"type": "number", |: 1}"#))
        expect(c.hasColon)
        expectEqual(keys(c.siblings), ["type"])
        let missing = #"{"a": 1 |: 2}"#
        c = try require(caret(missing))
        expect(c.hasColon)
        expectEqual(c.commaBefore, offset(after: "1", in: missing))
    },
    test("the object's other members, on both sides of the caret, the one being typed left out") {
        var c = try require(caret(#"{"type": "string", "mi|"#))
        expectEqual(c.position, .key)
        expectEqual(keys(c.siblings), ["type"])
        expectEqual(c.siblings.first?.value.string, "string")
        expectEqual(c.commaBefore, nil)
        expect(!c.needsCommaAfter)
        c = try require(caret(#"{"title": "A", |"type": "string"}"#))
        expectEqual(keys(c.siblings), ["title", "type"])
        expect(c.needsCommaAfter, "a key follows the caret")
        c = try require(caret(#"{"title": "A", "mi|": 1, "type": "string"}"#))
        expectEqual(keys(c.siblings), ["title", "type"], "the member being renamed is left out")
        expectEqual(keys(try require(c.root.members)), ["title", "mi", "type"], "though it's read")
    },
    test("a missing comma before: just after the value before, whatever's between") {
        let marked = "{\"type\": \"string\"\n  \"mi|"
        var c = try require(caret(marked))
        expectEqual(c.position, .key)
        expectEqual(c.commaBefore, offset(after: "\"string\"", in: marked))
        expectEqual(slice(marked, c.replace), "\"mi")
        expectEqual(keys(c.siblings), ["type"])
        let spaced = #"{"type": "string" |}"#
        c = try require(caret(spaced))
        expectEqual(c.position, .key)
        expectEqual(c.commaBefore, offset(after: "\"string\"", in: spaced))
        expectEqual(c.replace, unmarked(spaced).offset..<unmarked(spaced).offset)
        expect(!c.needsCommaAfter, "a closing brace follows")
        let array = #"["a" "b|"#
        c = try require(caret(array))
        expectEqual(c.position, .element(1))
        expectEqual(c.commaBefore, offset(after: "\"a\"", in: array))
    },
    test("a key being typed right before the next line's key, with no comma between, needs one after") {
        let marked = "{\n  \"ty|\n  \"format\": \"email\"\n}"
        let c = try require(caret(marked))
        expectEqual(c.position, .key)
        expectEqual(slice(marked, c.replace), "\"ty")
        expect(c.needsCommaAfter)
        expect(!c.hasColon)
        expectEqual(keys(c.siblings), ["format"])
    },
    test("a key with its colon is renamed: the pick replaces the key and writes no value") {
        let marked = #"{"mi|": 1}"#
        let c = try require(caret(marked))
        expectEqual(c.position, .key)
        expect(c.hasColon)
        expect(!c.needsCommaAfter)
        expectEqual(slice(marked, c.replace), "\"mi\"")
        expectEqual(c.query, "mi")
        expectEqual(c.siblings, [])
    },
    test("a member's value: where it's missing, or being typed") {
        var c = try require(caret(#"{"type": |}"#))
        expectEqual(c.position, .value(of: "type"))
        expectEqual(c.query, "")
        expectEqual(c.siblings, [])
        let open = #"{"type": "str|"#
        c = try require(caret(open))
        expectEqual(c.position, .value(of: "type"))
        expectEqual(slice(open, c.replace), "\"str")
        expectEqual(c.query, "str")
        expect(c.isQuoted)
        let inside = #"{"type": "stri|ng"}"#
        c = try require(caret(inside))
        expectEqual(c.position, .value(of: "type"))
        expectEqual(slice(inside, c.replace), "\"string\"")
        expectEqual(c.query, "stri")
        expectEqual(c.siblings, [], "the member being typed is left out")
        // After a closed string's closing quote, the caret is still at it.
        let after = #"{"type": "string"|}"#
        c = try require(caret(after))
        expectEqual(c.position, .value(of: "type"))
        expectEqual(slice(after, c.replace), "\"string\"")
        expectEqual(c.query, "string")
        c = try require(caret(#"{"a": {"b": 1}, "c": |}"#))
        expectEqual(c.path, [])
        expectEqual(c.position, .value(of: "c"))
        expectEqual(keys(c.siblings), ["a"])
        // The next line's key, where the value goes, is the next member's: the value isn't typed yet.
        c = try require(caret("{\n  \"type\": |\n  \"format\": \"email\"\n}"))
        expectEqual(c.position, .value(of: "type"))
        expect(c.needsCommaAfter)
        expectEqual(keys(c.siblings), ["format"])
        expectEqual(keys(try require(c.root.members)), ["format"])
    },
    test("nowhere before a member's value, or after a key without its colon") {
        expectEqual(caret(#"{"type": | "string"}"#), nil)
        expectEqual(caret(#"{"type": |"string"}"#), nil, "at a token's start, the caret is before it")
        expectEqual(caret(#"{"a": |{}}"#), nil)
        expectEqual(caret(#"{"type" |}"#), nil)
    },
    test("numbers are nowhere; a word is typed: tr, tru|e, true") {
        expectEqual(caret(#"{"minLength": 1|}"#), nil)
        expectEqual(caret(#"{"minLength": 1|0}"#), nil)
        expectEqual(caret(#"{"minLength": -|}"#), nil)
        expectEqual(caret("[1|]"), nil)
        let partial = #"{"a": tr|}"#
        var c = try require(caret(partial))
        expectEqual(c.position, .value(of: "a"))
        expectEqual(slice(partial, c.replace), "tr")
        expectEqual(c.query, "tr")
        expect(!c.isQuoted)
        expectEqual(c.root.members, [], "a word that isn't JSON doesn't read")
        let inside = #"{"a": tru|e}"#
        c = try require(caret(inside))
        expectEqual(c.position, .value(of: "a"))
        expectEqual(slice(inside, c.replace), "true", "a literal whole")
        expectEqual(c.query, "tru")
        c = try require(caret(#"{"a": true|}"#))
        expectEqual(c.query, "true")
        expectEqual(c.root["a"]?.bool, true)
        c = try require(caret(#"{"enum": [nu|]}"#))
        expectEqual(c.position, .element(0))
        expectEqual(c.query, "nu")
    },
    test("an array's elements: the index, and the others as read") {
        var c = try require(caret(#"{"type": ["string", |]}"#))
        expectEqual(c.path, [.member("type")])
        expectEqual(c.position, .element(1))
        expectEqual(c.elements.map(\.string), ["string"])
        expectEqual(c.siblings, [])
        let typing = #"{"type": ["string", "nu|", "object"]}"#
        c = try require(caret(typing))
        expectEqual(c.position, .element(1))
        expectEqual(slice(typing, c.replace), "\"nu\"")
        expectEqual(c.elements.map(\.string), ["string", "object"], "the one being typed left out")
        c = try require(caret(#"["a", |"b"]"#))
        expectEqual(c.position, .element(1))
        expect(c.needsCommaAfter)
        expectEqual(c.elements.map(\.string), ["a", "b"])
        c = try require(caret(#"[tr, {"a": 1}, {|}]"#))
        expectEqual(c.path, [.element(2)], "a word that doesn't read still takes its place")
    },
    test("the path to the object or array the caret is in, and each of them as read") {
        var c = try require(caret(#"{"properties": {"a": {|}}}"#))
        expectEqual(c.path, [.member("properties"), .member("a")])
        expectEqual(c.position, .key)
        expectEqual(c.containers.count, 3)
        expectEqual(c.containers[1].members.map(keys), ["a"])
        expectEqual(c.container.members, [])
        c = try require(caret(#"{"properties": {|}}"#))
        expectEqual(c.path, [.member("properties")])
        c = try require(caret(#"{"allOf": [{|}]}"#))
        expectEqual(c.path, [.member("allOf"), .element(0)])
        expectEqual(c.position, .key)
        c = try require(caret(##"{"$defs": {"money": {"type": "number"}}, "properties": {"price": {"$ref": "#/$defs/m|"}}}"##))
        expectEqual(c.path, [.member("properties"), .member("price")])
        expectEqual(c.position, .value(of: "$ref"))
        expectEqual(c.query, "#/$defs/m")
        expectEqual(c.root["$defs"]?.members.map(keys), ["money"], "the root, for what's defined elsewhere")
    },
    test("offsets are UTF-8 bytes: past an é, two of them") {
        let marked = #"{"title": "Hé", "ty|"#
        let c = try require(caret(marked))
        let end = unmarked(marked).text.utf8.count
        expectEqual(end, unmarked(marked).text.count + 1)
        expectEqual(c.replace, end - 3..<end)
        expectEqual(slice(marked, c.replace), "\"ty")
        expectEqual(c.siblings.first?.value.string, "Hé")
        expectEqual(c.siblings.first?.value.range, 10..<15)
    },
    test("nowhere before the root or after it, in an empty text, or in a root that isn't an object or an array") {
        for marked in ["|{}", "{}|", "{} |", " |{}", "|", " | ", "|[]", "[]|", "\"a|\"", "1|", "tru|", "{\"a\": 1}\n|", "{}\n{|}"] {
            expectEqual(caret(marked), nil, marked)
        }
        expectEqual(JSONCaret.at(-1, in: "{}"), nil)
        expectEqual(JSONCaret.at(3, in: "{}"), nil)
        expectEqual(caret("\u{FEFF}{|}")?.position, .key, "past a byte order mark")
    },
    test("nowhere in what's no member or element, or nested past the reader's limit") {
        expectEqual(caret("{ {|} }"), nil)
        expectEqual(caret(#"{"a": 1 {|}}"#), nil)
        let deep = String(repeating: "[", count: JSONReader.maxDepth)
        expectEqual(caret(deep + "{|" + String(repeating: "]", count: JSONReader.maxDepth)), nil)
        expectEqual(caret(String(repeating: "[", count: JSONReader.maxDepth - 1) + "{|")?.path.count, JSONReader.maxDepth - 1,
                    "as deep as allowed")
        let c = try require(caret(#"{"a": |, "deep": "# + deep + "[]" + String(repeating: "]", count: JSONReader.maxDepth) + "}"))
        expectEqual(c.position, .value(of: "a"))
        expectEqual(keys(c.siblings), ["deep"], "read to the limit")
        // Just past a bracket too deep, open to the end, the caret is in it, not in its parent.
        let nested = String(repeating: #"{"not": "#, count: JSONReader.maxDepth)
        for marked in [nested + "{|", nested + "{ |", nested + "{\n|", String(repeating: #"{"not": "#, count: 300) + "{|"] {
            expectEqual(caret(marked), nil, "\(marked.suffix(12))")
        }
        expectEqual(caret(nested + "{}|")?.position, .key, "after it, where the next key goes")
    },
    test("keys and strings read their escapes; members of one name are all kept") {
        let c = try require(caret(#"{"a\"b": "\u00e9\n", "a\"b": 2, |}"#))
        expectEqual(keys(c.siblings), ["a\"b", "a\"b"])
        expectEqual(c.siblings.first?.value.string, "é\n")
        expectEqual(c.root["a\"b"]?.number, 2)
        // An escape that isn't one is kept as written.
        expectEqual(try require(caret(#"{"a\q": 1, |}"#)).siblings.first?.key, #"a\q"#)
    },
    test("what's typed wrong is read past, as jsonc-parser reads it") {
        // A missing colon, a missing comma, stray tokens, a container left open.
        var c = try require(caret(#"{"a" 1, |}"#))
        expectEqual(c.siblings.first?.value.number, 1)
        c = try require(caret(#"{"a": 1 "b": 2, |}"#))
        expectEqual(keys(c.siblings), ["a", "b"])
        c = try require(caret(#"{"a": 1 : @, ] |}"#))
        expectEqual(keys(c.siblings), ["a"])
        expectEqual(c.commaBefore, nil, "a comma came after the value")
        c = try require(caret(#"{"a": {"b": 1, |"#))
        expectEqual(c.path, [.member("a")])
        expectEqual(keys(c.siblings), ["b"])
        expectEqual(c.root.members.map(keys), ["a"])
        // A closing bracket of the other kind closes what's open inside the one it's for.
        c = try require(caret(#"[{"a": 1, "b": |], 2"#))
        expectEqual(c.path, [.element(0)])
        expectEqual(c.position, .value(of: "b"))
        expectEqual(c.root.elements?.count, 1)
        // A value missing, before a comma: no comma after it.
        c = try require(caret(#"{"type": |, "a": 1}"#))
        expect(!c.needsCommaAfter)
        expectEqual(keys(c.siblings), ["a"])
    },
    test("what the schema card's own completions read: the object holding required, and the root's definitions") {
        let c = try require(caret(#"{"$defs": {"money": {}}, "properties": {"name": {}, "age": {}}, "required": ["name", |]}"#))
        expectEqual(c.path, [.member("required")])
        expectEqual(c.position, .element(1))
        expectEqual(c.elements.compactMap(\.string), ["name"])
        expectEqual(c.containers[c.containers.count - 2]["properties"]?.members.map(keys), ["name", "age"])
        expectEqual(c.root["$defs"]?.members.map(keys), ["money"])
    },
    test("an object left open inside an indented text ends where its parent's lines resume") {
        // "a" has no closing brace. Without indentation, it would take "b" (and properties'
        // closing brace, which would leave the root open to take "required" into properties).
        let marked = """
        {
          "properties": {
            "a": {
              "type": "string",
              "mi|
            "b": { "type": "number" }
          },
          "required": ["a"]
        }
        """
        var c = try require(caret(marked))
        expectEqual(c.path, [.member("properties"), .member("a")])
        expectEqual(c.position, .key)
        expectEqual(keys(c.siblings), ["type"])
        expect(!c.needsCommaAfter, "what follows is the parent's")
        expectEqual(keys(try require(c.root.members)), ["properties", "required"])
        expectEqual(c.containers[1].members.map(keys), ["a", "b"])
        // Lines ended the other way read the same.
        let crlf = try require(caret(marked.split(separator: "\n", omittingEmptySubsequences: false).joined(separator: "\r\n")))
        expectEqual(crlf.path, c.path)
        expectEqual(keys(crlf.siblings), ["type"])
        // A closing brace at a line's start closes the container opened on a line as far in.
        c = try require(caret("""
        {
          "properties": {
            "age": {
              "type": "integer",
              |
          },
          "required": []
        }
        """))
        expectEqual(c.path, [.member("properties"), .member("age")])
        expectEqual(keys(c.siblings), ["type"])
        expectEqual(keys(try require(c.root.members)), ["properties", "required"])
        // An object just opened, before its parent's closing brace.
        c = try require(caret("""
        {
          "type": "object",
          "properties": {
            "name": {|
          },
          "required": ["name"]
        }
        """))
        expectEqual(c.path, [.member("properties"), .member("name")])
        expectEqual(c.siblings, [])
        expectEqual(keys(try require(c.root.members)), ["type", "properties", "required"])
        // An array left open, and the next member at its parent's indentation.
        c = try require(caret("""
        {
          "type": [
            "string",
            |
          "format": "email"
        }
        """))
        expectEqual(c.path, [.member("type")])
        expectEqual(c.position, .element(1))
        expectEqual(keys(try require(c.root.members)), ["type", "format"])
    },
    test("in a text whose brackets pair up, indentation says nothing") {
        let c = try require(caret("""
        {
          "a": {
              "x": 1,
          "y": |
          },
          "b": 3
        }
        """))
        expectEqual(c.path, [.member("a")])
        expectEqual(c.position, .value(of: "y"))
        expectEqual(keys(c.siblings), ["x"])
        expectEqual(keys(try require(c.root.members)), ["a", "b"])
        // Nor in a compact text left open: the object closes at the end.
        let compact = try require(caret(#"{"a": {"b": 1, "c": 2}, "d": {"e": |"#))
        expectEqual(compact.path, [.member("d")])
        expectEqual(compact.position, .value(of: "e"))
    },
    test("valid JSON reads as the JSON reader reads it, at every caret, and the caret is nowhere outside its root") {
        for (name, json) in fixtures.dropLast() {
            let root = try JSONReader.read(json)
            let utf8 = Array(json.utf8)
            var nowhere = 0
            for offset in 0...utf8.count {
                guard let c = JSONCaret.at(offset, in: json) else {
                    nowhere += 1
                    continue
                }
                if c.root != root { expect(false, "\(name) at \(offset): the root reads differently"); break }
                if let broken = broken(c, at: offset, in: utf8) { expect(false, "\(name) at \(offset): \(broken)"); break }
            }
            expect(nowhere > 1, name)
            expectEqual(JSONCaret.at(0, in: json), nil, name)
            expectEqual(JSONCaret.at(utf8.count, in: json), nil, name)
        }
    },
    test("any text, any caret: nothing crashes, a pick replaces what holds the caret, and the query is what's typed to it") {
        // The fixtures, each broken by a few bytes deleted, inserted or replaced, deterministically,
        // read at every caret.
        var seed: UInt64 = 42
        func random(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int(seed >> 33) % n
        }
        let alphabet = Array("{}[]:,\"\\ \n\n  0123456789-.etrufalsn$#/éab".utf8)
        var read = 0, found = 0
        for (name, json) in fixtures {
            for _ in 0..<4 {
                var bytes = Array(json.utf8)
                for _ in 0..<1 + random(4) {
                    let at = random(bytes.count + 1), length = min(1 + random(6), bytes.count - at)
                    let inserted = (0..<1 + random(3)).map { _ in alphabet[random(alphabet.count)] }
                    switch random(3) {
                    case 0: bytes.removeSubrange(at..<at + length)
                    case 1: bytes.insert(contentsOf: inserted, at: at)
                    default: bytes.replaceSubrange(at..<at + length, with: inserted)
                    }
                }
                let text = String(decoding: bytes, as: UTF8.self)
                let utf8 = Array(text.utf8)
                for offset in 0...utf8.count {
                    read += 1
                    guard let c = JSONCaret.at(offset, in: text) else { continue }
                    found += 1
                    if let broken = broken(c, at: offset, in: utf8) {
                        expect(false, "\(name), broken, at \(offset): \(broken)\n\(text)")
                        return
                    }
                }
            }
        }
        expect(found > read / 2, "\(found) of \(read) carets found")
        // Short texts of JSON's punctuation, words and the rest.
        let pieces = ["{", "}", "[", "]", ":", ",", "\"", "\"a\"", "\"b", "1", "-", "tr", "true", " ", "\n", "  ", "\\", "é", "@"]
        for _ in 0..<1_000 {
            let text = (0..<random(14)).map { _ in pieces[random(pieces.count)] }.joined()
            let utf8 = Array(text.utf8)
            for offset in 0...utf8.count {
                guard let c = JSONCaret.at(offset, in: text) else { continue }
                if let broken = broken(c, at: offset, in: utf8) {
                    expect(false, "\(text) at \(offset): \(broken)")
                    return
                }
            }
        }
    },
    test("finding the caret is linear: near the end of a schema as long as the model writes, well within a keystroke") {
        // Left open (its last key's quote swallows the closing braces), so indentation is read too.
        let open = longSchema(ending: "\n    \"last\": {\"type\": \"string\", \"mi}}")
        // Whole, and valid.
        let valid = longSchema(ending: "\n    \"last\": {\"type\": \"string\", \"mi\": 1}}}")
        for (text, offset) in [(open, open.utf8.count - 2), (valid, valid.utf8.count - 7)] {
            expect(text.utf8.count >= SchemaPrompts.toSchemaMaxLength)
            // The fastest of a few is what it costs; the rest count the machine's other work too
            // (the other test executables, a slower core). The release benchmark holds a whole
            // completion to a keystroke's 2 ms; here, debug and on any core, 5 ms still catches a
            // reading that isn't linear, which would take hundreds.
            var c: JSONCaret?
            let took = (0..<8).map { _ in threadCPUTime { c = JSONCaret.at(offset, in: text) } }.min() ?? .zero
            expect(took < .milliseconds(5), "\(text.utf8.count) bytes took \(took)")
            expectEqual(c?.path, [.member("properties"), .member("last")])
            expectEqual(c?.query, "mi")
            expectEqual(c.map { keys($0.siblings) }, ["type"])
        }
    },
])

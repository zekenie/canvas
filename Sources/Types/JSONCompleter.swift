import Canvas
import Foundation

// Completing JSON text against a JSON Schema, as VS Code's JSON language service completes it
// (vscode-json-languageservice's jsonCompletion.ts, MIT; THIRD_PARTY_NOTICES.md). Where the caret is
// comes from `JSONCaret`; the schemas that place is held to come from walking the schema along the
// caret's path; and what they offer there is written as it goes into the text: a key with a value
// to type into, a value, a comma where one is needed. What the text means is the schema's to say:
// a key's description, the values it takes, the order they're offered in, whether a key matters
// beside the object's other members. What a client knows that no schema can say, it adds
// (`JSONCompleter.init(schema:offers:)`). Candidates aren't matched against what's typed: whoever
// shows them matches them, and gets every one.

/// What can be written where a caret is in JSON text: every candidate, in the order offered, each
/// as it goes into the text, and what's typed so far. Offsets and ranges are UTF-8 offsets into the
/// text (`SchemaCompletions` gives UTF-16 ones).
public struct JSONCompletions: Equatable, Sendable {
    /// What a pick replaces with its `insert`: what's typed of the key or value at the caret (the
    /// caret alone when nothing is), from where a comma is missing before it, if one is.
    public var range: Range<Int>
    /// What's typed of the key or value, a string's opening quote left out, to the caret: what
    /// candidates are matched against.
    public var query: String
    /// In the order the schema lists them; keys that don't matter beside the object's other
    /// members after those that do.
    public var items: [JSONCompletionItem]

    public init(range: Range<Int>, query: String, items: [JSONCompletionItem]) {
        self.range = range
        self.query = query
        self.items = items
    }
}

/// One candidate: a key, with a value to type into, or a value.
public struct JSONCompletionItem: Equatable, Sendable {
    /// What's shown and matched: a key bare, a string value without its quotes, any other value as
    /// JSON (`{}`, `true`, `0`).
    public var label: String
    /// A line about it, its schema's description; "" when there's none.
    public var detail: String
    /// What replaces the completions' `range`: a key (`"minLength": 0`) or a value, with the commas
    /// around it that the text needs.
    public var insert: String
    /// Within `insert`: where the caret goes (an empty range: in a string's quotes, in braces or
    /// brackets, after the value), or what's selected to be typed over (a number, `true`).
    public var selection: Range<Int>
    /// Where the pick leaves the caret has candidates of its own (a type's names, once `"type": ""`
    /// is in): ask again at once.
    public var reopens: Bool
    /// Whether the key matters beside the object's other members (`minLength` doesn't beside
    /// `"type": "number"`); every value does. With nothing typed, keys that don't aren't offered.
    public var isRelevant: Bool

    public init(label: String, detail: String, insert: String, selection: Range<Int>, reopens: Bool, isRelevant: Bool) {
        self.label = label
        self.detail = detail
        self.insert = insert
        self.selection = selection
        self.reopens = reopens
        self.isRelevant = isRelevant
    }
}

/// A value a client offers where a value goes, beside what the schema offers.
public struct JSONCompletionOffer: Equatable, Sendable {
    /// The value as JSON: `"#/$defs/money"`, `3`.
    public var json: String
    public var label: String
    public var detail: String

    public init(json: String, label: String, detail: String = "") {
        self.json = json
        self.label = label
        self.detail = detail
    }

    /// A string, labeled as it is.
    public init(string: String, detail: String = "") {
        self.init(json: JSONReader.literal(string), label: string, detail: detail)
    }

    var isString: Bool { json.utf8.first == UInt8(ascii: "\"") }
}

/// A key a client adds where a key goes, beside the keys the schema lists, with the JSON its value starts as.
public struct JSONCompletionKeyOffer: Equatable, Sendable {
    public var key: String
    public var detail: String
    /// What is written after `"key": `, and where the caret lands in it (UTF-8 offsets into `value`).
    public var value: String
    public var selection: Range<Int>
    /// Asked again where the caret lands.
    public var reopens: Bool

    public init(key: String, detail: String = "", value: String, selection: Range<Int>, reopens: Bool = false) {
        self.key = key
        self.detail = detail
        self.value = value
        self.selection = selection
        self.reopens = reopens
    }
}

/// Where a value goes, and the schemas held there: what a client's offers are asked of. A schema is
/// known by where it's written in the schema document (`range`): two alike in two places are two.
public struct JSONCompletionPlace: Sendable {
    /// At a member's value or an array's element, where a value goes. Also asked of where a pick
    /// would leave the caret (in the quotes or the brackets of the value a key is written with),
    /// which no text holds yet: its object or array as read, the new array in place.
    public var caret: JSONCaret
    /// The schemas the object or array the caret is in is held to: each one, then what its `$ref`
    /// points to and its `allOf`, `anyOf` and `oneOf` branches, each once.
    public var schemas: [JSONNode]
    /// The schemas the value is held to, likewise.
    public var valueSchemas: [JSONNode]

    public init(caret: JSONCaret, schemas: [JSONNode], valueSchemas: [JSONNode]) {
        self.caret = caret
        self.schemas = schemas
        self.valueSchemas = valueSchemas
    }
}

/// Completes JSON text against a JSON Schema: at a key, the keys of the object's schema not already
/// there, each with its description and written with a value to type into; at a value or an
/// element, the values its schema offers. Pure, and costs the caret's path and what's offered
/// there, not the schema's size. A `$ref` is read against the schema document, as `SchemaResolver`
/// reads the card's: an `$id` inside it isn't a new base.
public struct JSONCompleter: Sendable {
    /// The schema the text is written against: a document whose `$ref`s point within it (`#`, or a
    /// JSON pointer after it).
    public let schema: JSONNode
    /// What a client adds where a value goes.
    private let offers: @Sendable (JSONCompletionPlace) -> [JSONCompletionOffer]
    /// What a client adds where a key goes.
    private let clientKeys: @Sendable (JSONCaret) -> [JSONCompletionKeyOffer]
    /// Each `$ref` in the schema that points somewhere in it, and where: resolved once, as the
    /// completer is made.
    private let targets: [String: JSONNode]
    /// Each `patternProperties` name in the schema that's a regular expression, compiled once, as
    /// the validator reads it (ECMA-262's dialect).
    private let patterns: [String: NSRegularExpression]

    /// How many schemas one place is held to, at most, however the schema branches.
    public static let maxSchemas = 512
    /// The one annotation read that isn't JSON Schema's: `{"<member>": [values]}` on a key's schema
    /// says it matters only in an object whose `<member>` is, or lists, one of the values.
    public static let whenKeyword = "x-canvas-when"

    /// A completer for text written against `schema`, what `offers` adds where a value goes
    /// (asked where the schema offers nothing too) and what `keys` adds where a key goes (those
    /// the object doesn't hold).
    public init(schema: JSONNode, offers: @escaping @Sendable (JSONCompletionPlace) -> [JSONCompletionOffer] = { _ in [] },
                keys: @escaping @Sendable (JSONCaret) -> [JSONCompletionKeyOffer] = { _ in [] }) {
        self.schema = schema
        self.offers = offers
        self.clientKeys = keys
        let resolver = SchemaResolver(root: schema)
        var targets: [String: JSONNode] = [:], patterns: [String: NSRegularExpression] = [:]
        var stack = [schema]
        while let node = stack.popLast() {
            switch node.value {
            case .object(let members):
                for member in members {
                    if member.key == "$ref", let ref = member.value.string, targets[ref] == nil, let target = resolver.resolve(ref) {
                        targets[ref] = target
                    }
                    if member.key == "patternProperties" {
                        for pattern in member.value.members ?? [] where patterns[pattern.key] == nil {
                            patterns[pattern.key] = SchemaValidator.regex(for: pattern.key)
                        }
                    }
                    stack.append(member.value)
                }
            case .array(let elements):
                stack.append(contentsOf: elements)
            default:
                break
            }
        }
        self.targets = targets
        self.patterns = patterns
    }

    /// What can be written at the caret at `offset` (UTF-8) in `text`; nil where nothing can
    /// (`JSONCaret.at`), or nothing is offered.
    public func completions(in text: String, at offset: Int) -> JSONCompletions? {
        guard let caret = JSONCaret.at(offset, in: text) else { return nil }
        return completions(at: caret, in: text)
    }

    /// What can be written at `caret` in `text`; nil where nothing is offered.
    public func completions(at caret: JSONCaret, in text: String) -> JSONCompletions? {
        // The schemas each step of the path leads to.
        var schemas = expanded([schema])
        for step in caret.path where !schemas.isEmpty {
            switch step {
            case .member(let key): schemas = expanded(members(key, of: schemas))
            case .element(let index): schemas = expanded(items(index, of: schemas))
            }
        }
        let writer = Writer(caret: caret, schemas: schemas, text: text)
        let items: [JSONCompletionItem]
        switch caret.position {
        case .key:
            items = keys(of: schemas, writer)
        case .value(let key):
            let place = JSONCompletionPlace(caret: caret, schemas: schemas, valueSchemas: expanded(members(key, of: schemas)))
            items = values(at: place, step: .member(key), writer)
        case .element(let index):
            let place = JSONCompletionPlace(caret: caret, schemas: schemas, valueSchemas: expanded(self.items(index, of: schemas)))
            items = values(at: place, step: .element(index), writer)
        }
        guard !items.isEmpty else { return nil }
        return JSONCompletions(range: (caret.commaBefore ?? caret.replace.lowerBound)..<caret.replace.upperBound, query: caret.query, items: items)
    }
}

// MARK: Walking the schema

private extension JSONCompleter {
    /// `schemas`, each followed by what its `$ref` points to and its `allOf`, `anyOf` and `oneOf`
    /// branches, deep, in that order: every schema a value there is held to, each once (known by
    /// where it's written, so a `$ref` in a circle ends). Only objects: `true` says nothing of a
    /// value, and `false` allows none.
    func expanded(_ schemas: [JSONNode]) -> [JSONNode] {
        var out: [JSONNode] = []
        var seen = Set<Int>()
        var stack = Array(schemas.reversed())
        while out.count < Self.maxSchemas, let schema = stack.popLast() {
            guard let members = schema.members, seen.insert(schema.range.lowerBound).inserted else { continue }
            out.append(schema)
            var ref: JSONNode?, branches: [String: [JSONNode]] = [:]
            for member in members {
                switch member.key {
                case "$ref": ref = member.value.string.flatMap { targets[$0] }
                case "allOf", "anyOf", "oneOf": branches[member.key] = member.value.elements
                default: break
                }
            }
            let next = (ref.map { [$0] } ?? []) + (branches["allOf"] ?? []) + (branches["anyOf"] ?? []) + (branches["oneOf"] ?? [])
            stack.append(contentsOf: next.reversed())
        }
        return out
    }

    /// The schemas a member called `key` is held to, by each of `schemas`: its property and each
    /// pattern property whose pattern it matches, else the additional properties'; and where none
    /// of `schemas` says any of that of it, their unevaluated properties'. (Whether a branch that
    /// says it holds up isn't known here, so every branch counts as evaluating the member.)
    func members(_ key: String, of schemas: [JSONNode]) -> [JSONNode] {
        var out: [JSONNode] = []
        for schema in schemas {
            var matched = false
            if let property = schema["properties"]?[key] {
                out.append(property)
                matched = true
            }
            for pattern in schema["patternProperties"]?.members ?? [] where matches(pattern.key, key) {
                out.append(pattern.value)
                matched = true
            }
            if !matched, let additional = schema["additionalProperties"] { out.append(additional) }
        }
        return out.isEmpty ? schemas.compactMap { $0["unevaluatedProperties"] } : out
    }

    /// The schemas the element at `index` is held to, by each of `schemas`: its `prefixItems`
    /// entry, else `items` (an older draft's `items` list is a prefix too, `additionalItems` after
    /// it); and where none of `schemas` says any of that of it, their unevaluated items'.
    func items(_ index: Int, of schemas: [JSONNode]) -> [JSONNode] {
        var out: [JSONNode] = []
        for schema in schemas {
            if let prefix = schema["prefixItems"]?.elements, index < prefix.count {
                out.append(prefix[index])
            } else if let tuple = schema["items"]?.elements {
                if index < tuple.count { out.append(tuple[index]) } else if let rest = schema["additionalItems"] { out.append(rest) }
            } else if let items = schema["items"] {
                out.append(items)
            }
        }
        return out.isEmpty ? schemas.compactMap { $0["unevaluatedItems"] } : out
    }

    /// Whether `name` matches a pattern property's regular expression; a pattern ICU can't read
    /// matches nothing.
    func matches(_ pattern: String, _ name: String) -> Bool {
        guard let regex = patterns[pattern] else { return false }
        return regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }
}

// MARK: Keys

private extension JSONCompleter {
    /// The keys `schemas` offer for the object, in their order, each with its description, but
    /// those that don't matter beside the object's other members: left out with nothing typed,
    /// else last.
    func keys(of schemas: [JSONNode], _ writer: Writer) -> [JSONCompletionItem] {
        let caret = writer.caret
        var relevant: [JSONCompletionItem] = [], irrelevant: [JSONCompletionItem] = []
        // Each member's listed values, read once a call (only `type`'s, in the meta-schema).
        var listed: [String: [JSONNode]?] = [:]
        func valuesListed(for member: String) -> [JSONNode]? {
            if let known = listed[member] { return known }
            let known = listedValues(of: expanded(members(member, of: schemas)))
            listed[member] = known
            return known
        }
        for (key, schema, said) in offeredKeys(of: schemas, but: Set(caret.siblings.map(\.key))) {
            let matters = Self.matters(said, among: caret.siblings, listed: valuesListed(for:))
            guard matters || !caret.query.isEmpty else { continue }
            let detail = said.lazy.compactMap { $0["description"]?.string }.first ?? ""
            let item = keyItem(key, expanded([schema]), detail: detail, isRelevant: matters, writer)
            if matters { relevant.append(item) } else { irrelevant.append(item) }
        }
        // A client's keys the object doesn't hold, last: a schema that lists none (`properties`) offers only these.
        var present = Set(caret.siblings.map(\.key))
        present.formUnion((relevant + irrelevant).map(\.label))
        let added = clientKeys(caret).filter { present.insert($0.key).inserted }.map { writer.item(of: $0) }
        return relevant + irrelevant + added
    }

    /// The keys `schemas` list for an object, in their order, once each (the first schema to list
    /// one says what it is), but those `present` and those marked `deprecated`: each with its
    /// schema and what says what it is (`refChain`).
    func offeredKeys(of schemas: [JSONNode], but present: Set<String>) -> [(key: String, schema: JSONNode, said: [JSONNode])] {
        var named = Set<String>()
        var out: [(key: String, schema: JSONNode, said: [JSONNode])] = []
        for holder in schemas {
            for (key, schema) in Self.properties(of: holder) where !present.contains(key) && named.insert(key).inserted {
                let said = refChain(schema)
                if !said.contains(where: { $0["deprecated"]?.bool == true }) { out.append((key, schema, said)) }
            }
        }
        return out
    }

    /// A schema's properties in the order written; of two of one name, the last one's schema in
    /// the first one's place, as `JSON.parse` keeps it.
    static func properties(of schema: JSONNode) -> [(key: String, schema: JSONNode)] {
        guard let members = schema["properties"]?.members else { return [] }
        var out: [(key: String, schema: JSONNode)] = []
        var index: [String: Int] = [:]
        out.reserveCapacity(members.count)
        for member in members {
            if let i = index[member.key] { out[i].schema = member.value } else {
                index[member.key] = out.count
                out.append((member.key, member.value))
            }
        }
        return out
    }

    /// A key's schema and what its `$ref`s lead to, one after another: what says what the key is
    /// (its description, whether it's deprecated, when it matters), not what its value may be.
    func refChain(_ schema: JSONNode) -> [JSONNode] {
        var chain = [schema]
        while chain.count <= SchemaResolver.maxSteps, let ref = chain[chain.count - 1]["$ref"]?.string, let next = targets[ref],
              !chain.contains(where: { $0.range == next.range }) {
            chain.append(next)
        }
        return chain
    }

    /// Whether a key its schema says `said` of (`refChain`) matters beside `siblings`: each member
    /// its `x-canvas-when` names that's there must be, or list, one of the values it gives; one
    /// that isn't there says nothing, and neither does a value its own schemas don't list
    /// (`listed`, nil where they list none): one being typed (`"type": ""`), or misspelled.
    static func matters(_ said: [JSONNode], among siblings: [JSONMember], listed: (String) -> [JSONNode]?) -> Bool {
        guard let conditions = said.lazy.compactMap({ $0[whenKeyword]?.members }).first else { return true }
        for condition in conditions {
            guard let sibling = siblings.last(where: { $0.key == condition.key })?.value else { continue }
            let wanted = condition.value.elements ?? [condition.value]
            let known = listed(condition.key)
            let values = (sibling.elements ?? [sibling]).filter { value in known?.contains { JSONValues.equal($0, value) } ?? true }
            if values.isEmpty { continue }
            if !values.contains(where: { value in wanted.contains { JSONValues.equal($0, value) } }) { return false }
        }
        return true
    }

    /// The values `schemas` list, each `const` and `enum` value: nil where they list none, so any
    /// value goes.
    func listedValues(of schemas: [JSONNode]) -> [JSONNode]? {
        var out: [JSONNode] = []
        for schema in schemas {
            if let value = schema["const"] { out.append(value) }
            out += schema["enum"]?.elements ?? []
        }
        return out.isEmpty ? nil : out
    }

    /// The key written with a value to type into (by what its schemas accept), or, where the key's
    /// colon is there already, alone.
    func keyItem(_ key: String, _ own: [JSONNode], detail: String, isRelevant: Bool, _ writer: Writer) -> JSONCompletionItem {
        let name = JSONReader.literal(key)
        guard !writer.caret.hasColon else {
            return writer.item(label: key, detail: detail, text: name, selection: name.utf8.count..<name.utf8.count, reopens: false,
                               isRelevant: isRelevant)
        }
        let start = name.utf8.count + 2   // `"key": `
        let text: String, selection: Range<Int>, reopens: Bool
        switch Placeholder(own) {
        case .object:
            (text, selection) = ("{}", 1..<1)
            reopens = hasKeys(own)
        case .string:
            (text, selection) = ("\"\"", 1..<1)
            reopens = hasValues(at: writer.place(ofValueOf: key, valueSchemas: own, quoted: true), stringsOnly: true)
        case .array:
            (text, selection) = ("[]", 1..<1)
            reopens = hasValues(at: writer.place(inArrayAt: .member(key), arraySchemas: own, itemSchemas: expanded(items(0, of: own))),
                                stringsOnly: false)
        case .number(let literal):
            (text, selection) = (literal, 0..<literal.utf8.count)
            reopens = false
        case .boolean:
            (text, selection) = ("true", 0..<4)
            reopens = false
        case .none:
            (text, selection) = ("", 0..<0)
            reopens = hasValues(at: writer.place(ofValueOf: key, valueSchemas: own, quoted: false), stringsOnly: false)
        }
        return writer.item(label: key, detail: detail, text: name + ": " + text,
                           selection: start + selection.lowerBound..<start + selection.upperBound, reopens: reopens, isRelevant: isRelevant)
    }

    /// Whether a new object held to `schemas` has keys to offer (nothing's in it, so each matters).
    func hasKeys(_ schemas: [JSONNode]) -> Bool { !offeredKeys(of: schemas, but: []).isEmpty }
}

/// What a key is written with, by what its schemas accept, first to last: an object, a string (its
/// type, or string values listed), an array, a number, a boolean; else nothing. A number is its
/// default, else 0, or, where the schemas' bounds leave out 0, the whole number nearest 0 they allow
/// (`multipleOf`'s 1: its exclusive minimum is 0).
private enum Placeholder: Equatable {
    case object, string, array
    case number(String)
    case boolean
    case none

    init(_ schemas: [JSONNode]) {
        var types = Set<String>()
        var number: String?
        // The least and the greatest whole numbers the bounds allow.
        var least = -Double.infinity, greatest = Double.infinity
        for schema in schemas {
            types.formUnion(JSONValues.typeNames(of: schema))
            if let value = schema["const"] { types.insert(JSONValues.type(of: value)) }
            for value in schema["enum"]?.elements ?? [] { types.insert(JSONValues.type(of: value)) }
            if schema["properties"] != nil { types.insert("object") }
            if schema["items"] != nil || schema["prefixItems"] != nil { types.insert("array") }
            if number == nil, case .number(let literal)? = schema["default"]?.value { number = literal }
            if let bound = schema["minimum"]?.number { least = max(least, bound.rounded(.up)) }
            if let bound = schema["exclusiveMinimum"]?.number { least = max(least, bound.rounded(.down) + 1) }
            if let bound = schema["maximum"]?.number { greatest = min(greatest, bound.rounded(.down)) }
            if let bound = schema["exclusiveMaximum"]?.number { greatest = min(greatest, bound.rounded(.up) - 1) }
        }
        let nearest = least > 0 ? least : greatest < 0 ? greatest : 0
        let literal = number ?? (abs(nearest) < 1e15 ? String(Int(nearest)) : "0")
        self = if types.contains("object") { .object }
            else if types.contains("string") { .string }
            else if types.contains("array") { .array }
            else if types.contains("number") || types.contains("integer") { .number(literal) }
            else if types.contains("boolean") { .boolean }
            else { .none }
    }
}

// MARK: Values

/// A value offered, and, where it came from the schema, the value it is.
private struct OfferedValue {
    var offer: JSONCompletionOffer
    var node: JSONNode?
}

private extension JSONCompleter {
    /// The values offered where the place is (`step` from the object or array the caret is in):
    /// its schemas' (`values(of:stringsOnly:)`), then the client's; once each; in an array whose
    /// schema says `uniqueItems`, none it holds already. In a string being typed, only strings.
    func values(at place: JSONCompletionPlace, step: JSONPathComponent, _ writer: Writer) -> [JSONCompletionItem] {
        let caret = place.caret
        var offered = values(of: place.valueSchemas, stringsOnly: caret.isQuoted)
        offered += offers(place).filter { !caret.isQuoted || $0.isString }.map { OfferedValue(offer: $0) }
        var written = Set<String>()
        let held = place.schemas.contains { $0["uniqueItems"]?.bool == true } ? caret.elements : []
        var items: [JSONCompletionItem] = []
        for value in offered where written.insert(value.offer.json).inserted {
            let text = value.offer.json
            if !held.isEmpty, let node = value.node ?? (try? JSONReader.read(text)), held.contains(where: { JSONValues.equal($0, node) }) {
                continue
            }
            let selection: Range<Int>, reopens: Bool
            switch text {
            case "{}":
                selection = 1..<1
                reopens = hasKeys(place.valueSchemas)
            case "[]":
                selection = 1..<1
                let itemSchemas = expanded(self.items(0, of: place.valueSchemas))
                reopens = hasValues(at: writer.place(inArrayAt: step, arraySchemas: place.valueSchemas, itemSchemas: itemSchemas), stringsOnly: false)
            default:
                selection = text.utf8.count..<text.utf8.count
                reopens = false
            }
            items.append(writer.item(label: value.offer.label, detail: value.offer.detail, text: text, selection: selection, reopens: reopens,
                                     isRelevant: true))
        }
        return items
    }

    /// What `schemas` offer, in order: each `const` (with its schema's description: a `oneOf` of
    /// described values) and `enum` value, then `examples`; then, unless only strings are wanted,
    /// what their types give (`{}`, `[]`, `true` and `false`, `null`; not from a schema that lists
    /// its values); then `default`s.
    func values(of schemas: [JSONNode], stringsOnly: Bool) -> [OfferedValue] {
        var out: [OfferedValue] = []
        func add(_ node: JSONNode, detail: String = "") {
            guard !stringsOnly || node.string != nil else { return }
            let json = JSONValues.json(node)
            out.append(OfferedValue(offer: JSONCompletionOffer(json: json, label: node.string ?? json, detail: detail), node: node))
        }
        for schema in schemas {
            if let value = schema["const"] { add(value, detail: schema["description"]?.string ?? "") }
            for value in schema["enum"]?.elements ?? [] { add(value) }
        }
        for schema in schemas {
            for value in schema["examples"]?.elements ?? [] { add(value) }
        }
        if !stringsOnly {
            var types = Set<String>()
            for schema in schemas where schema["const"] == nil && schema["enum"] == nil { types.formUnion(JSONValues.typeNames(of: schema)) }
            for (type, json) in [("object", "{}"), ("array", "[]"), ("boolean", "true"), ("boolean", "false"), ("null", "null")]
            where types.contains(type) {
                out.append(OfferedValue(offer: JSONCompletionOffer(json: json, label: json)))
            }
        }
        for schema in schemas {
            if let value = schema["default"] { add(value) }
        }
        return out
    }

    /// Whether a value goes where `place` is, from its schemas or the client.
    func hasValues(at place: JSONCompletionPlace, stringsOnly: Bool) -> Bool {
        !values(of: place.valueSchemas, stringsOnly: stringsOnly).isEmpty || offers(place).contains { !stringsOnly || $0.isString }
    }
}

// MARK: Writing

/// Writes candidates as they go into the text at the caret: after a comma where one is missing
/// before it (what was between kept as it was), and with one after where a key or a value follows.
private struct Writer {
    let caret: JSONCaret
    /// The schemas the object or array the caret is in is held to.
    let schemas: [JSONNode]
    /// `,` and what's between the value before and what's typed, where the comma is missing.
    let prefix: String
    /// `,` where a key or value follows with none between.
    let suffix: String

    init(caret: JSONCaret, schemas: [JSONNode], text: String) {
        self.caret = caret
        self.schemas = schemas
        if let comma = caret.commaBefore {
            let between = text.utf8.withContiguousStorageIfAvailable { bytes in
                String(decoding: UnsafeBufferPointer(rebasing: bytes[comma..<caret.replace.lowerBound]), as: UTF8.self)
            } ?? String(decoding: Array(text.utf8)[comma..<caret.replace.lowerBound], as: UTF8.self)
            prefix = "," + between
        } else {
            prefix = ""
        }
        suffix = caret.needsCommaAfter ? "," : ""
    }

    /// A client's key, written as `keyItem` writes one: with its value, or alone where the colon is there.
    func item(of offer: JSONCompletionKeyOffer) -> JSONCompletionItem {
        let name = JSONReader.literal(offer.key)
        guard !caret.hasColon else {
            return item(label: offer.key, detail: offer.detail, text: name, selection: name.utf8.count..<name.utf8.count, reopens: false, isRelevant: true)
        }
        let start = name.utf8.count + 2   // `"key": `
        return item(label: offer.key, detail: offer.detail, text: name + ": " + offer.value,
                    selection: start + offer.selection.lowerBound..<start + offer.selection.upperBound, reopens: offer.reopens, isRelevant: true)
    }

    /// A candidate whose value is `text`, `selection` within it.
    func item(label: String, detail: String, text: String, selection: Range<Int>, reopens: Bool, isRelevant: Bool) -> JSONCompletionItem {
        let shift = prefix.utf8.count
        return JSONCompletionItem(label: label, detail: detail, insert: prefix + text + suffix,
                                  selection: shift + selection.lowerBound..<shift + selection.upperBound, reopens: reopens, isRelevant: isRelevant)
    }

    /// Where a pick of `key` leaves the caret: in its value's quotes, or after it, in the same
    /// object, the value held to `valueSchemas`.
    func place(ofValueOf key: String, valueSchemas: [JSONNode], quoted: Bool) -> JSONCompletionPlace {
        let at = caret.replace.lowerBound
        let here = JSONCaret(path: caret.path, position: .value(of: key), replace: at..<at, query: "", isQuoted: quoted, hasColon: false,
                             commaBefore: nil, needsCommaAfter: false, siblings: caret.siblings, elements: [], containers: caret.containers)
        return JSONCompletionPlace(caret: here, schemas: schemas, valueSchemas: valueSchemas)
    }

    /// Where a pick leaves the caret in the empty array it writes (`step` from the caret's object
    /// or array), held to `arraySchemas`, its first element to `itemSchemas`.
    func place(inArrayAt step: JSONPathComponent, arraySchemas: [JSONNode], itemSchemas: [JSONNode]) -> JSONCompletionPlace {
        let at = caret.replace.lowerBound
        let array = JSONNode(.array([]), range: at..<at)
        let here = JSONCaret(path: caret.path + [step], position: .element(0), replace: at..<at, query: "", isQuoted: false, hasColon: false,
                             commaBefore: nil, needsCommaAfter: false, siblings: [], elements: [], containers: caret.containers + [array])
        return JSONCompletionPlace(caret: here, schemas: arraySchemas, valueSchemas: itemSchemas)
    }
}

// MARK: JSON values

/// JSON values as values, whatever text they were read from.
enum JSONValues {
    /// Whether two values are the same JSON: numbers by what they are (`1.0` is `1`), objects by
    /// their members whatever their order, wherever each was written.
    static func equal(_ a: JSONNode, _ b: JSONNode) -> Bool {
        switch (a.value, b.value) {
        case let (.string(x), .string(y)): return x == y
        case let (.number(x), .number(y)): return x == y || (Double(x).map { $0 == Double(y) } ?? false)
        case let (.bool(x), .bool(y)): return x == y
        case (.null, .null): return true
        case let (.array(x), .array(y)): return x.count == y.count && zip(x, y).allSatisfy { equal($0, $1) }
        case let (.object(x), .object(y)):
            guard x.count == y.count else { return false }
            return x.allSatisfy { member in b[member.key].map { equal(member.value, $0) } ?? false }
        default: return false
        }
    }

    /// JSON Schema's name for a value's type.
    static func type(of value: JSONNode) -> String {
        switch value.value {
        case .string: "string"
        case .number: "number"
        case .bool: "boolean"
        case .null: "null"
        case .object: "object"
        case .array: "array"
        }
    }

    /// The type names a schema's `type` gives, one (`"string"`) or a list (`["string", "null"]`);
    /// none without one.
    static func typeNames(of schema: JSONNode) -> [String] {
        guard let type = schema["type"] else { return [] }
        return type.string.map { [$0] } ?? type.elements?.compactMap(\.string) ?? []
    }

    /// A value as JSON, on one line: `{"a": 1, "b": [true]}`; numbers as written.
    static func json(_ value: JSONNode) -> String {
        switch value.value {
        case .string(let string): JSONReader.literal(string)
        case .number(let literal): literal
        case .bool(let bool): bool ? "true" : "false"
        case .null: "null"
        case .array(let elements): "[" + elements.map(json).joined(separator: ", ") + "]"
        case .object(let members): "{" + members.map { JSONReader.literal($0.key) + ": " + json($0.value) }.joined(separator: ", ") + "}"
        }
    }
}

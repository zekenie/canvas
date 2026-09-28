import Canvas
import CoreGraphics
import DrawScript
import Foundation

// A kind as `canvas draw` and `canvas kinds` see it: the attributes a script can write on its
// shapes, read off the kind's schema (its own properties and those added to it), what each takes,
// said briefly (`todo|doing|blocked|done`, `text (≤ 80)`), and a value as written read as the JSON
// the property is.

/// The keys the language keeps on an edge: `from:`, `to:` and `style:` (which an edge can't take).
let languageEdgeKeys: Set<String> = Set(EdgeKey.allCases.map(\.rawValue) + [LanguageKey.style.rawValue])

/// A value a script wrote that its property can't take: what's wrong, and what to write.
struct ValueRefusal: Error {
    let message: String
    let hint: String?
}

/// A kind's attributes, from its schema: every property but those a script can't set, which are
/// the one its titles are written to (a title goes after the kind, in quotes), the ones that say
/// where a shape is (a frame, a point: there are no coordinates in the language), and any named
/// like one of the language's keys.
@MainActor
struct KindVocabulary {
    let kind: ShapeKind
    /// The kind's whole schema, whose `$defs` its properties refer to.
    let root: JSONObject
    /// Each property of the schema, own and added, by name.
    let properties: JSONObject
    /// Those the schema requires (no null for them).
    let required: Set<String>
    /// The property a title is written to; nil if its shapes can't be given one.
    let namingProperty: String?
    /// Properties that hold a place (the core's rect or point, or something that holds one).
    let coordinates: Set<String>
    /// Properties named like a language key (`size`, `title`), which a script can't reach.
    let collisions: Set<String>

    init(_ kind: ShapeKind, in registry: Registry) {
        self.kind = kind
        root = registry.schema(for: kind)?.json ?? [:]
        properties = root["properties"]?.objectValue ?? [:]
        required = Set((root["required"]?.arrayValue ?? []).compactMap(\.stringValue))
        let naming = registry.drawNaming?.namingProperty(kind, registry)
        namingProperty = naming
        let keys = Set(LanguageKey.allCases.map(\.rawValue)), root = root, properties = properties
        coordinates = Set(properties.filter { KindVocabulary.holdsPlace($0.value, in: root) }.keys)
        collisions = Set(properties.keys.filter { keys.contains($0) && $0 != naming })
    }

    /// Whether a script can write it: `priority: high`.
    func isAttribute(_ name: String) -> Bool {
        properties[name] != nil && name != namingProperty && !coordinates.contains(name) && !collisions.contains(name)
    }

    /// What a script can write on the kind's shapes, by name, sorted.
    var attributes: [String] { properties.keys.filter(isAttribute).sorted() }

    /// Everything a script can write on one of its shapes: the language's keys (`title` only if
    /// its shapes can be named), then its attributes.
    var everything: [String] {
        LanguageKey.allCases.filter { $0 != .title || namingProperty != nil }.map(\.rawValue) + attributes
    }

    // MARK: What each takes

    /// What a property takes, said briefly: `todo|doing|blocked|done`, `number ≥ 0`, `text (≤ 80)`,
    /// `true|false`, `date (YYYY-MM-DD or date-time)`, `JSON {blue, green, red: 0…1}`,
    /// `JSON [{isDone, text}]`.
    func compactType(of name: String) -> String {
        properties[name].map { compact($0) } ?? "JSON"
    }

    private func compact(_ schema: JSONValue, depth: Int = 0) -> String {
        let schema = resolved(schema)
        if let choices = choices(schema) { return choices.joined(separator: "|") }
        switch schema["type"]?.stringValue {
        case "string":
            if schema["format"]?.stringValue == Self.dateTime { return "date (YYYY-MM-DD or date-time)" }
            return schema["maxLength"]?.numberValue.map { "text (≤ \(Self.number($0)))" } ?? "text"
        case "number", "integer":
            let base = schema["type"]?.stringValue == "integer" ? "integer" : "number"
            return range(schema).map { "\(base) \($0)" } ?? base
        case "boolean":
            return "true|false"
        case "array" where depth < 2:
            // A tuple (a size) says what it holds: `[width, height]`.
            guard let items = schema["items"], items.objectValue != nil else { return "JSON \(schema["description"]?.stringValue ?? "[…]")" }
            return "JSON [\(inner(items, depth: depth))]"
        case "object" where depth < 2:
            return "JSON \(inner(.object(schema), depth: depth))"
        default:
            return "JSON"
        }
    }

    /// An array's items or an object, inside JSON: `{isDone, text}`, `{blue, green, red: 0…1}`, or
    /// the item's own type.
    private func inner(_ schema: JSONValue, depth: Int) -> String {
        let schema = resolved(schema)
        guard let members = schema["properties"]?.objectValue, !members.isEmpty else {
            return schema["type"]?.stringValue == "object" ? "{…}" : compact(.object(schema), depth: depth + 1)
        }
        let shown = written(schema)
        let ranges = Set(shown.map { name -> String? in
            let member = resolved(members[name]!)
            return ["number", "integer"].contains(member["type"]?.stringValue ?? "") ? range(member) : nil
        })
        let shared = ranges.count == 1 ? ranges.first! : nil
        return "{\(shown.joined(separator: ", "))\(shared.map { ": \($0)" } ?? "")}"
    }

    /// An object's members a script writes, sorted: all but an id no one writes (an item's, in
    /// a list), which is made when it's missing.
    private func written(_ schema: JSONObject) -> [String] {
        let members = schema["properties"]?.objectValue ?? [:]
        let required = Set((schema["required"]?.arrayValue ?? []).compactMap(\.stringValue))
        return members.filter { name, member in
            required.contains(name) || resolved(member)["format"]?.stringValue != Self.uuid
        }.keys.sorted()
    }

    /// The members a script writes of the object at `path` inside a property's value (an element
    /// of a list: its items'); nil where there's no object.
    func members(of name: String, at path: some Collection<JSONPathComponent>) -> [String]? {
        guard var schema = properties[name].map(resolved) else { return nil }
        for step in path {
            switch step {
            case .member(let member):
                guard let next = schema["properties"]?[member] else { return nil }
                schema = resolved(next)
            case .element(let index):
                if let prefix = schema["prefixItems"]?.arrayValue, prefix.indices.contains(index) {
                    schema = resolved(prefix[index])
                } else if let items = schema["items"] {
                    schema = resolved(items)
                } else {
                    return nil
                }
            }
        }
        return schema["properties"]?.objectValue == nil ? nil : written(schema)
    }

    /// A number's bounds: `≥ 0`, `≤ 5`, `0…1`.
    private func range(_ schema: JSONObject) -> String? {
        switch (schema["minimum"]?.numberValue, schema["maximum"]?.numberValue) {
        case let (low?, high?): "\(Self.number(low))…\(Self.number(high))"
        case let (low?, nil): "≥ \(Self.number(low))"
        case let (nil, high?): "≤ \(Self.number(high))"
        case (nil, nil): nil
        }
    }

    static func number(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }

    static let dateTime = "date-time"
    static let uuid = "uuid"

    // MARK: Reading a value

    /// A value as written, read by its property's schema: a word or quoted text for text (and a
    /// date alone for a date-time, midnight UTC); a word among the choices for one of some words; a
    /// bare number; `true` or `false`; JSON for anything else; and `null`, the property's default.
    func value(of attribute: Attribute) throws(ValueRefusal) -> JSONValue {
        let name = attribute.key, written = attribute.value.written
        guard let property = properties[name] else { throw ValueRefusal(message: "\(name): isn't one of \(indefinite(kind))'s attributes", hint: nil) }
        let schema = resolved(property)
        let type = compactType(of: name)
        func refuse(_ why: String? = nil) -> ValueRefusal {
            ValueRefusal(message: "\(name): \(written) \(why ?? "isn't what \(name): takes")", hint: "\(name): takes \(type)")
        }
        if case .word(let word) = attribute.value, word == Self.null {
            guard !required.contains(name) else {
                throw ValueRefusal(message: "\(name): can't be null: \(indefinite(kind)) always has one", hint: "\(name): takes \(type)")
            }
            return .null
        }
        if let choices = choices(schema) {
            let text: String
            switch attribute.value {
            case .word(let word): text = word
            case .quoted(let quoted): text = quoted
            case .json: throw refuse()
            }
            guard choices.contains(text) else {
                let guess = Suggestions.closest(to: text, among: choices, limit: 1).first
                throw ValueRefusal(message: "\(name): \(written) isn't one of \(choices.joined(separator: ", "))",
                                   hint: (guess.map { "did you mean \($0)? " } ?? "") + "\(name): takes \(type)")
            }
            return .string(text)
        }
        switch schema["type"]?.stringValue {
        case "string":
            switch attribute.value {
            case .word(let text), .quoted(let text):
                if schema["format"]?.stringValue == Self.dateTime, Self.isDay(text) { return .string(text + Self.midnight) }
                return .string(text)
            case .json: throw refuse("isn't text: quote it")
            }
        case "number", "integer":
            guard case .word(let word) = attribute.value, let number = Double(word), number.isFinite else { throw refuse("isn't a number") }
            if schema["type"]?.stringValue == "integer", number != number.rounded() { throw refuse("isn't a whole number") }
            return .number(number)
        case "boolean":
            guard case .word(let word) = attribute.value, let flag = Bool(word) else { throw refuse("isn't true or false") }
            return .bool(flag)
        default:
            switch attribute.value {
            case .json(let text), .word(let text):
                guard let json = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else {
                    throw refuse(attribute.value.isJSON ? "isn't JSON" : "isn't JSON: write it as JSON, as \(name): [ … ] or { … }")
                }
                return json
            case .quoted(let text):
                guard ["array", "object"].contains(schema["type"]?.stringValue ?? "") else { return .string(text) }
                throw refuse("is text, and \(name): takes JSON: write it without quotes")
            }
        }
    }

    static let null = "null"
    /// What a date alone becomes: the start of its day, in UTC.
    static let midnight = "T00:00:00Z"

    /// `YYYY-MM-DD`.
    static func isDay(_ text: String) -> Bool {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        return parts.count == 3 && zip(parts, [4, 2, 2]).allSatisfy { part, count in part.count == count && part.allSatisfy(\.isASCIIDigit) }
    }

    // MARK: Schemas

    /// A schema with its `$ref`s followed (to this kind's `$defs`).
    func resolved(_ schema: JSONValue) -> JSONObject {
        Self.resolved(schema, in: root)
    }

    /// A schema with its `$ref`s followed; keywords written beside a reference (a bound, a
    /// description) say more than its target's, as the command line reads a schema
    /// (`JSON.resolvingReference(in:)`).
    static func resolved(_ schema: JSONValue, in root: JSONObject) -> JSONObject {
        var schema = schema.objectValue ?? [:]
        var seen: Set<String> = []
        while let reference = schema["$ref"]?.stringValue, seen.insert(reference).inserted, let target = definition(reference, in: root) {
            var merged = target
            for (key, value) in schema where key != "$ref" { merged[key] = value }
            schema = merged
        }
        return schema
    }

    /// The place a local `$ref` names: `#`, or `#/$defs/<name>`.
    static func definition(_ reference: String, in root: JSONObject) -> JSONObject? {
        if reference == "#" { return root }
        let prefix = "#/$defs/"
        guard reference.hasPrefix(prefix) else { return nil }
        return root["$defs"]?[String(reference.dropFirst(prefix.count))]?.objectValue
    }

    /// The strings a string must be: its `enum`, or the `const` of each of its `oneOf`.
    func choices(_ schema: JSONObject) -> [String]? {
        if let values = schema["enum"]?.arrayValue {
            let strings = values.compactMap(\.stringValue)
            return strings.count == values.count && !strings.isEmpty ? strings : nil
        }
        if let cases = schema["oneOf"]?.arrayValue {
            let strings = cases.compactMap { resolved($0)["const"]?.stringValue }
            return strings.count == cases.count && !strings.isEmpty ? strings : nil
        }
        return nil
    }

    /// The `$ref`s of the core's rect and point, as every kind's schema writes them.
    static let places: Set<String> = {
        var definitions = SchemaDefinitions()
        return Set([CGRect.schema(in: &definitions), CGPoint.schema(in: &definitions)].compactMap { $0["$ref"]?.stringValue })
    }()

    /// Whether a schema is, or holds, the core's rect or point: where a shape is.
    static func holdsPlace(_ schema: JSONValue, in root: JSONObject) -> Bool {
        var seen: Set<String> = []
        func holds(_ value: JSONValue) -> Bool {
            switch value {
            case .object(let object):
                if let reference = object["$ref"]?.stringValue {
                    if places.contains(reference) { return true }
                    guard seen.insert(reference).inserted, let target = definition(reference, in: root) else { return false }
                    if holds(.object(target)) { return true }
                }
                return object.contains { key, member in key != "$ref" && key != "$defs" && holds(member) }
            case .array(let items):
                return items.contains(where: holds)
            default:
                return false
            }
        }
        return holds(schema)
    }
}

extension Attribute.Value {
    var isJSON: Bool {
        if case .json = self { true } else { false }
    }
}

extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

import CanvasRPC
import CoreGraphics
import Foundation

/// One kind's schema (`Registry.schema(for:)`), read for what text says about its shapes: each
/// property's shape (`PropertyShape`: text, a number, true|false, a list, an object, any JSON), what
/// it takes said briefly (`compactType`: `todo|doing|blocked|done`, `number ≥ 0`, `text (≤ 80)`),
/// which properties say where a shape is (`holdsPlace`), and a value as written read as the JSON
/// the property is (`value(ofLiteral:quoted:for:)`), or why not, in no words (`Refusal`): each
/// reader says it in its own (`canvas draw`'s messages; a query's). It holds the schema's JSON and
/// no registry, and reads it anywhere. Its `$ref`s are followed within the schema (`#`,
/// `#/$defs/<name>`).
public struct KindSchema: Sendable {
    /// The whole schema, whose `$defs` its properties refer to.
    public let root: JSONObject
    /// Each property, own and added, by name, as the schema writes it (`resolved(_:)` follows its
    /// `$ref`).
    public let properties: JSONObject
    /// Those the schema requires: no null for them.
    public let required: Set<String>
    /// Those that hold a place (`holdsPlace(_:)`).
    private let placeHolding: Set<String>

    public init(_ schema: JSONSchema) {
        root = schema.json
        properties = root["properties"]?.objectValue ?? [:]
        required = Set((root["required"]?.arrayValue ?? []).compactMap(\.stringValue))
        let root = root
        placeHolding = Set(properties.filter { Self.holdsPlace($0.value, in: root) }.keys)
    }

    /// Whether the property is, or holds, the core's rect or point: where a shape is (a frame, an
    /// arrow's end), which no text writes or tests.
    public func holdsPlace(_ property: String) -> Bool { placeHolding.contains(property) }

    /// Whether the schema marks the property as its plugin's own (`unlisted()`): no language lists,
    /// reads or writes it.
    public func isUnlisted(_ property: String) -> Bool {
        properties[property].map { resolved($0)[Self.unlistedKeyword]?.boolValue == true } ?? false
    }

    /// The keyword that marks a property no language lists (`PropertyModifiers.unlisted()`).
    public static let unlistedKeyword = "x-canvas-unlisted"

    // MARK: What each is

    /// What a property's values are, its `$ref`s followed; nil for a property the kind hasn't.
    public func shape(of property: String) -> PropertyShape? {
        properties[property].map { shape(of: $0, depth: 0) }
    }

    /// What the values a schema describes are. A list's items are read a few lists deep; past that,
    /// and for a list whose items aren't one schema (a tuple), they're any JSON.
    private func shape(of schema: JSONValue, depth: Int) -> PropertyShape {
        let schema = resolved(schema)
        if let choices = choices(schema) {
            return .string(format: schema["format"]?.stringValue, mediaType: schema["contentMediaType"]?.stringValue, choices: choices)
        }
        switch schema["type"]?.stringValue {
        case "string":
            return .string(format: schema["format"]?.stringValue, mediaType: schema["contentMediaType"]?.stringValue, choices: nil)
        case "number": return .number(integer: false)
        case "integer": return .number(integer: true)
        case "boolean": return .boolean(default: schema["default"]?.boolValue ?? false)
        case "array":
            guard depth < Self.listDepth, let items = schema["items"], items.objectValue != nil else { return .array(items: .json) }
            return .array(items: shape(of: items, depth: depth + 1))
        case "object": return .object
        default: return .json
        }
    }

    /// How many lists deep a list's items are read.
    private static let listDepth = 4

    // MARK: What each takes, said briefly

    /// What a property takes, said briefly: `todo|doing|blocked|done`, `number ≥ 0`, `text (≤ 80)`,
    /// `true|false`, `date (YYYY-MM-DD or date-time)`, `JSON {blue, green, red: 0…1}`,
    /// `JSON [{isDone, text}]`; `JSON` for a property the kind hasn't.
    public func compactType(of property: String) -> String {
        properties[property].map { compact($0) } ?? "JSON"
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

    /// An object's members that text writes, sorted: all but an id no one writes (an item's, in a
    /// list), which is made when it's missing.
    private func written(_ schema: JSONObject) -> [String] {
        let members = schema["properties"]?.objectValue ?? [:]
        let required = Set((schema["required"]?.arrayValue ?? []).compactMap(\.stringValue))
        return members.filter { name, member in
            required.contains(name) || resolved(member)["format"]?.stringValue != Self.uuid
        }.keys.sorted()
    }

    /// The members text writes of the object at `path` inside a property's value (an element of a
    /// list: its items'); nil where there's no object.
    public func members(of property: String, at path: some Collection<JSONPathComponent>) -> [String]? {
        guard var schema = properties[property].map(resolved) else { return nil }
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

    // MARK: What an object reads as

    /// The keyword that says which member a value of an object schema reads as where a text compares it as one value
    /// (`Properties(readsAs:)`): a type as written reads as its `words`, an enum's value as its `text`.
    public static let readsAsKeyword = "x-canvas-reads-as"

    /// The member the value at `path` inside a property reads as (`readsAsKeyword`), a list met at any step, or at the end,
    /// read as its items, and each branch of a `oneOf` or `anyOf` looked in for a member; nil where the value is no object, or
    /// its schema says no member. What a query's test of `[columns.type="uuid"]` compares: `columns.type.words`.
    public func readsAs(_ property: String, at path: [String]) -> String? {
        guard let start = properties[property] else { return nil }
        var schemas = items(resolved(start))
        for member in path {
            schemas = schemas.flatMap { schema in branches(of: schema).compactMap { $0["properties"]?[member] }.flatMap { items(resolved($0)) } }
            guard !schemas.isEmpty else { return nil }
        }
        for schema in schemas.flatMap(branches) {
            if let member = schema[Self.readsAsKeyword]?.stringValue, schema["properties"]?[member] != nil { return member }
        }
        return nil
    }

    /// A schema, or the items of the lists it is, however deep, each resolved.
    private func items(_ schema: JSONObject) -> [JSONObject] {
        var schema = schema, depth = 0
        while schema["type"]?.stringValue == "array", let items = schema["items"], depth < Self.listDepth {
            schema = resolved(items)
            depth += 1
        }
        return [schema]
    }

    /// A schema and the branches of its `oneOf` or `anyOf`, each resolved.
    private func branches(of schema: JSONObject) -> [JSONObject] {
        let more = (schema["oneOf"]?.arrayValue ?? []) + (schema["anyOf"]?.arrayValue ?? [])
        return [schema] + more.map(resolved)
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

    /// A number as text says it: a whole one without a fraction (`3`, not `3.0`).
    public static func number(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }

    /// The format of a string that's an instant (`Date`'s).
    public static let dateTime = "date-time"
    static let uuid = "uuid"

    // MARK: Reading a value

    /// A value as written, read by its property's schema: text (quoted or not) for text, and a date
    /// alone (`YYYY-MM-DD`) for an instant, as midnight UTC; one of the choices, for one of some
    /// words; an unquoted number, finite, and whole for an integer; unquoted `true` or `false`;
    /// unquoted JSON for a list or an object, and for anything else (quoted, it's that text); and
    /// unquoted `null`, the property's default, which a required property has none of. As
    /// `canvas draw` reads a value: a reader that takes `"3"` for a number passes it unquoted.
    public func value(ofLiteral literal: String, quoted: Bool, for property: String) throws(Refusal) -> JSONValue {
        guard let schema = properties[property] else { throw .notAProperty }
        if !quoted, literal == Self.null {
            guard !required.contains(property) else { throw .required }
            return .null
        }
        return try value(ofLiteral: literal, quoted: quoted, as: shape(of: schema, depth: 0), takes: compact(schema))
    }

    /// A value as written, read as one item of a list property (`tags`: a word of it), by the list's
    /// items' schema, as `value(ofLiteral:quoted:for:)` reads a property's (`null` is no item's).
    /// `.notA` the property's type for a property that isn't a list.
    public func value(ofLiteral literal: String, quoted: Bool, forItemOf property: String) throws(Refusal) -> JSONValue {
        guard let schema = properties[property] else { throw .notAProperty }
        guard case .array(let items) = shape(of: schema, depth: 0) else { throw .notA(compactType: compact(schema)) }
        let itemSchema = resolved(schema)["items"] ?? .object([:])
        return try value(ofLiteral: literal, quoted: quoted, as: items, takes: compact(itemSchema))
    }

    private func value(ofLiteral literal: String, quoted: Bool, as shape: PropertyShape, takes: String) throws(Refusal) -> JSONValue {
        switch shape {
        case let .string(format, _, choices):
            if let choices {
                guard choices.contains(literal) else { throw .notAChoice(choices: choices) }
                return .string(literal)
            }
            if format == Self.dateTime, Self.isDay(literal) { return .string(literal + Self.midnight) }
            return .string(literal)
        case .number(let integer):
            guard !quoted, let number = Double(literal) else { throw .notA(compactType: takes) }
            guard number.isFinite else { throw .notFinite }
            if integer, number != number.rounded() { throw .notA(compactType: takes) }
            return .number(number)
        case .boolean:
            guard !quoted, let flag = Bool(literal) else { throw .notA(compactType: takes) }
            return .bool(flag)
        case .array, .object:
            guard !quoted else { throw .notA(compactType: takes) }
            return try Self.json(literal)
        case .json:
            return quoted ? .string(literal) : try Self.json(literal)
        }
    }

    private static func json(_ text: String) throws(Refusal) -> JSONValue {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else { throw .notJSON }
        return json
    }

    /// The word that puts a property back to its default.
    public static let null = "null"
    /// What a date alone becomes: the start of its day, in UTC.
    public static let midnight = "T00:00:00Z"

    /// `YYYY-MM-DD`.
    public static func isDay(_ text: String) -> Bool {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        return parts.count == 3 && zip(parts, [4, 2, 2]).allSatisfy { part, count in
            part.count == count && part.allSatisfy { $0.isASCII && $0.isNumber }
        }
    }

    /// Why a value as written isn't one its property can take: a structure, never words, which each
    /// reader says in its own.
    public enum Refusal: Error, Hashable, Sendable {
        /// The kind has no such property.
        case notAProperty
        /// It isn't one of the words the property takes (its `enum`, or its `oneOf`'s consts).
        case notAChoice(choices: [String])
        /// It isn't what the property takes, said briefly (`compactType`): a word for a number or
        /// true|false, a fraction for an integer, quoted text for a list or an object.
        case notA(compactType: String)
        /// `null` for a property that always has a value.
        case required
        /// A number that isn't finite (`inf`, `nan`, `1e999`).
        case notFinite
        /// What should be JSON isn't.
        case notJSON
    }

    // MARK: Schemas

    /// A schema with its `$ref`s followed, within this one.
    public func resolved(_ schema: JSONValue) -> JSONObject {
        Self.resolved(schema, in: root)
    }

    /// A schema with its `$ref`s followed; keywords written beside a reference (a bound, a
    /// description) say more than its target's, as the command line reads a schema
    /// (`JSON.resolvingReference(in:)`).
    public static func resolved(_ schema: JSONValue, in root: JSONObject) -> JSONObject {
        var schema = schema.objectValue ?? [:]
        var seen: Set<String> = []
        while let reference = schema["$ref"]?.stringValue, seen.insert(reference).inserted, let target = definition(reference, in: root) {
            var merged = target
            for (key, value) in schema where key != "$ref" { merged[key] = value }
            schema = merged
        }
        return schema
    }

    /// The place a local `$ref` names: `#`, or `#/$defs/<name>` (its name as a pointer's step, in a
    /// URI fragment, as the registry writes it).
    static func definition(_ reference: String, in root: JSONObject) -> JSONObject? {
        if reference == "#" { return root }
        let prefix = "#/$defs/"
        guard reference.hasPrefix(prefix) else { return nil }
        let step = String(reference.dropFirst(prefix.count))
        let name = JSONPointer.unescaped(step.removingPercentEncoding ?? step)
        return root["$defs"]?[name]?.objectValue
    }

    /// The strings a string must be: its `enum`, or the `const` of each of its `oneOf`.
    private func choices(_ schema: JSONObject) -> [String]? {
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
    private static let places: Set<String> = {
        var definitions = SchemaDefinitions()
        return Set([CGRect.schema(in: &definitions), CGPoint.schema(in: &definitions)].compactMap { $0["$ref"]?.stringValue })
    }()

    /// Whether a schema is, or holds, the core's rect or point: where a shape is.
    public static func holdsPlace(_ schema: JSONValue, in root: JSONObject) -> Bool {
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

    /// What a property's values are, as its schema says, its `$ref`s followed.
    public indirect enum PropertyShape: Hashable, Sendable {
        /// Text: its `format` (`date-time`, `uuid`), what its content is (`contentMediaType`: mention
        /// text's), and the words it must be, if it must (`enum`, `oneOf`'s consts: a `SchemaCases`).
        case string(format: String?, mediaType: String?, choices: [String]?)
        /// A number; `integer` for a whole one.
        case number(integer: Bool)
        /// True or false; `default` is what a shape without one has: the schema's default, else false.
        case boolean(default: Bool)
        /// A list, of what its items are: any JSON for a tuple (`[width, height]`).
        case array(items: PropertyShape)
        /// An object: a struct, or a dictionary.
        case object
        /// Anything else: no type, several, or null.
        case json
    }
}

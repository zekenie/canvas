import Foundation

// A JSON Schema read from its text: its name, its fields in the order they're written, and the
// rules at its root. Nothing here restricts JSON Schema: a keyword this doesn't read is still in the
// text, and still means what it means; this reads what the card, the table of contents and
// validation show.

/// A JSON Schema, read. Its top-level fields are read at once (the card counts them); each field's
/// type and fields are read when asked, a level at a time, so what reading costs is what's looked at.
public struct SchemaDocument: Sendable {
    /// The schema, if the text is JSON.
    public let root: JSONNode?
    /// Why the text isn't JSON.
    public let error: JSONSyntaxError?
    /// The root's `"title"`: the schema's name. Read even from a text that isn't JSON (yet), if the
    /// root's `"title"` came before the error. Nil when there's none, or it's blank.
    public let title: String?
    /// The top-level fields: `properties`, then `patternProperties`, each in the order written (a
    /// root with neither and a `$ref`, its target's; never an array's items').
    public let fields: [SchemaField]
    /// The keywords at the root that constrain the object as a whole rather than name a field:
    /// `if/then` (or `if/then/else`), `allOf`, `anyOf`, `oneOf`, `not`, `dependentRequired`,
    /// `dependentSchemas`.
    public let rules: [String]

    public init(_ text: String) {
        do throws(JSONSyntaxError) {
            let root = try JSONReader.read(text)
            self.root = root
            error = nil
            title = SchemaDocument.name(root["title"]?.string)
            fields = root.isObject ? SchemaResolver(root: root).fields(of: root, throughItems: false) : []
            rules = root.isObject ? SchemaDocument.rules(of: root) : []
        } catch {
            root = nil
            self.error = error
            title = SchemaDocument.name(error.rootMembers.last { $0.key == "title" }?.value.string)
            fields = []
            rules = []
        }
    }

    /// Whether the text is JSON whose root is an object: a schema the card can list.
    public var isObject: Bool { root?.isObject ?? false }

    private static func name(_ title: String?) -> String? {
        guard let title, !title.allSatisfy(\.isWhitespace) else { return nil }
        return title
    }

    private static func rules(of root: JSONNode) -> [String] {
        var rules: [String] = []
        if root["if"] != nil {
            rules.append("if" + (root["then"] != nil ? "/then" : "") + (root["else"] != nil ? "/else" : ""))
        }
        for key in ["allOf", "anyOf", "oneOf", "not", "dependentRequired", "dependentSchemas"] where root[key] != nil {
            rules.append(key)
        }
        return rules
    }
}

/// A field: a property of an object schema (a pattern property's name is its pattern), whether the
/// object requires it, and its schema.
public struct SchemaField: Sendable {
    public let name: String
    public let isRequired: Bool
    /// Named by a pattern (`patternProperties`), not a name.
    public let isPattern: Bool
    /// Its schema, as written.
    public let schema: JSONNode
    /// The document's root, which `$ref`s point into.
    let root: JSONNode

    /// What it holds, as JSON Schema says it.
    public var type: SchemaFieldType { SchemaFieldType(schema) }

    /// The fields in it: an object's properties, an array's items', a `$ref`'s target's. None for
    /// anything else, or a `$ref` that points outside the document or around in a circle.
    public var fields: [SchemaField] { SchemaResolver(root: root).fields(of: schema) }

    /// Whether it has fields of its own, without reading them.
    public var hasFields: Bool { SchemaResolver(root: root).hasFields(schema) }
}

/// What a field holds, in JSON Schema's own words.
public indirect enum SchemaFieldType: Equatable, Sendable {
    /// No constraint: `true`, `{}`, or keywords this doesn't read.
    case any
    /// A `type` that isn't one of JSON Schema's seven (`"ninteger"`), as written: it says something,
    /// just not what the writer meant, so it isn't `any` (Validation warns about it).
    case unknown(String)
    /// Nothing is valid: `false`.
    case never
    case string, number, integer, boolean, null
    /// A string of a `format`: `email`, `date-time`, `uuid`, …
    case format(String)
    /// A list of types: `["string", "null"]`.
    case types([String])
    /// One of these values (`enum`), each as `JSONNode.brief` shows it.
    case enumeration([String])
    /// Exactly this value (`const`).
    case constant(String)
    case object
    /// An array of `items` (nil: no `items`, or a tuple's).
    case array(of: SchemaFieldType?)
    /// A `$ref`, by the last component of where it points: `#/$defs/money` is `money`.
    case ref(String)
    /// `oneOf`, `anyOf` or `allOf`, and each option's name: its `title`, else its type, else its
    /// `$ref`'s name, else `option N`.
    case choice(SchemaCombinator, [String])

    /// Reads a schema's type. The first of these that it has says it: `$ref`, `oneOf` / `anyOf` /
    /// `allOf`, `enum`, `const`, `type` (or, without one, what its keywords imply: `properties` an
    /// object, `items` an array, `format` a string).
    public init(_ schema: JSONNode) { self = SchemaFieldType.read(schema, depth: 0) }

    private static func read(_ schema: JSONNode, depth: Int) -> SchemaFieldType {
        if let bool = schema.bool { return bool ? .any : .never }
        guard schema.isObject, depth < 32 else { return .any }
        if let ref = schema["$ref"]?.string { return .ref(SchemaResolver.name(of: ref)) }
        for combinator in SchemaCombinator.allCases {
            guard let options = schema[combinator.rawValue]?.elements else { continue }
            return .choice(combinator, options.enumerated().map { i, option in
                if let title = option["title"]?.string, !title.allSatisfy(\.isWhitespace) { return title }
                if let type = option["type"], let names = typeNames(type) { return names.joined(separator: "|") }
                if let ref = option["$ref"]?.string { return SchemaResolver.name(of: ref) }
                return "option \(i + 1)"
            })
        }
        if let values = schema["enum"]?.elements { return .enumeration(values.map(\.brief)) }
        if let value = schema["const"] { return .constant(value.brief) }
        var names = schema["type"].flatMap(typeNames) ?? []
        if names.count > 1 { return .types(names) }
        if names.isEmpty {
            if schema["properties"] != nil || schema["patternProperties"] != nil { names = ["object"] }
            else if schema["items"] != nil || schema["prefixItems"] != nil { names = ["array"] }
            else if schema["format"]?.string != nil { names = ["string"] }
        }
        switch names.first {
        case "string": return schema["format"]?.string.map(SchemaFieldType.format) ?? .string
        case "number": return .number
        case "integer": return .integer
        case "boolean": return .boolean
        case "null": return .null
        case "object": return .object
        case "array":
            guard schema["prefixItems"] == nil, let items = schema["items"], items.elements == nil else { return .array(of: nil) }
            return .array(of: read(items, depth: depth + 1))
        case let name?: return .unknown(name)
        case nil: return .any
        }
    }

    /// JSON Schema's seven types: a `type` names one of these, or a list of them.
    public static let jsonTypes: Set<String> = ["string", "number", "integer", "boolean", "null", "object", "array"]

    /// `"string"` or `["string", "null"]`; nil for anything else.
    private static func typeNames(_ type: JSONNode) -> [String]? {
        if let name = type.string { return [name] }
        let names = type.elements?.compactMap(\.string) ?? []
        return names.isEmpty ? nil : names
    }

    /// How the card says it at a row's end: `string`, `email`, `string|null`, `enum`, `= DE`,
    /// `object`, `string[]`, `object[]`, `array`, `→ money`, `oneOf`, `any`, `never`, and a type
    /// that isn't one as it's written (`ninteger`).
    public var label: String {
        switch self {
        case .any: "any"
        case .unknown(let name): name
        case .never: "never"
        case .string: "string"
        case .number: "number"
        case .integer: "integer"
        case .boolean: "boolean"
        case .null: "null"
        case .format(let format): format
        case .types(let names): names.joined(separator: "|")
        case .enumeration: "enum"
        case .constant(let value): "= \(value)"
        case .object: "object"
        case .array(let items): items.map { $0.label + "[]" } ?? "array"
        case .ref(let name): "→ \(name)"
        case .choice(let combinator, _): combinator.label
        }
    }

    /// The type `label` says, in a word, for a row with no room for it: an array's `array`, a
    /// format's `string`; nil where there's no shorter word (the label is one already).
    public var baseLabel: String? {
        switch self {
        case .array(of: .some): "array"
        case .format: "string"
        default: nil
        }
    }
}

public enum SchemaCombinator: String, CaseIterable, Sendable {
    case oneOf, anyOf, allOf

    /// JSON Schema's own word, as the rules line says it: `oneOf`, `anyOf`, `allOf`.
    public var label: String { rawValue }
}

/// Reads fields out of a schema, following `$ref`s within the document (`#`, `#/$defs/x`, any JSON
/// pointer), each step bounded, so a `$ref` in a circle ends.
struct SchemaResolver {
    let root: JSONNode
    /// How many `$ref`s and `items` one read follows before giving up.
    static let maxSteps = 32

    /// The fields of `schema`: its own `properties` and `patternProperties`; without them, those of
    /// what its `$ref` points to, or (`throughItems`) of its `items`.
    func fields(of schema: JSONNode, throughItems: Bool = true) -> [SchemaField] {
        guard let holder = holder(of: schema, throughItems: throughItems) else { return [] }
        let required = Set(holder["required"]?.elements?.compactMap(\.string) ?? [])
        var fields: [SchemaField] = []
        var index: [String: Int] = [:]
        // Two members of one name: the last one's schema, in the first one's place (as JSON.parse).
        func add(_ name: String, _ schema: JSONNode, pattern: Bool) {
            let field = SchemaField(name: name, isRequired: !pattern && required.contains(name), isPattern: pattern, schema: schema, root: root)
            let key = (pattern ? "/" : "") + name
            if let i = index[key] { fields[i] = field } else { index[key] = fields.count; fields.append(field) }
        }
        for member in holder["properties"]?.members ?? [] { add(member.key, member.value, pattern: false) }
        for member in holder["patternProperties"]?.members ?? [] { add(member.key, member.value, pattern: true) }
        return fields
    }

    func hasFields(_ schema: JSONNode) -> Bool {
        guard let holder = holder(of: schema) else { return false }
        return !(holder["properties"]?.members?.isEmpty ?? true) || !(holder["patternProperties"]?.members?.isEmpty ?? true)
    }

    /// The schema whose `properties` are `schema`'s fields: itself, or what its `$ref` or `items`
    /// lead to.
    private func holder(of schema: JSONNode, throughItems: Bool = true) -> JSONNode? {
        var schema = schema
        var visited: Set<String> = []
        for _ in 0..<SchemaResolver.maxSteps {
            guard schema.isObject else { return nil }
            if schema["properties"]?.isObject == true || schema["patternProperties"]?.isObject == true { return schema }
            if let ref = schema["$ref"]?.string {
                guard visited.insert(ref).inserted, let target = resolve(ref) else { return nil }
                schema = target
            } else if throughItems, let items = schema["items"], items.isObject {
                schema = items
            } else {
                return nil
            }
        }
        return nil
    }

    /// What a `$ref` within the document points to: `#`, or a JSON pointer after it
    /// (`#/$defs/money`, `#/properties/a/items`). Nil for one outside the document.
    func resolve(_ ref: String) -> JSONNode? {
        guard ref.hasPrefix("#") else { return nil }
        let pointer = ref.dropFirst()
        guard !pointer.isEmpty else { return root }
        guard pointer.hasPrefix("/") else { return nil }   // an anchor (`#name`): not read
        var node = root
        for raw in pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            let token = (String(raw).removingPercentEncoding ?? String(raw))
                .replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            if let child = node[token] {
                node = child
            } else if let elements = node.elements, let i = Int(token), elements.indices.contains(i) {
                node = elements[i]
            } else {
                return nil
            }
        }
        return node
    }

    /// A `$ref`'s name: the last component of where it points (`#/$defs/money` is `money`,
    /// `https://example.com/address.json` is `address.json`).
    static func name(of ref: String) -> String {
        let last = ref.split(separator: "/").last.map(String.init) ?? ref
        let name = last.hasPrefix("#") ? String(last.dropFirst()) : last
        return name.isEmpty ? ref : name
    }
}

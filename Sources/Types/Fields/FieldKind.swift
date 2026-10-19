import Canvas
import CanvasRPC
import Foundation

// What a field's schema comes to as a row: one kind, read once from the schema as the type wrote it
// (its `#` references written out, `ChainField`), by a fixed order of precedence. Pure: it reads no
// other type, so a type that is gone still reads as its fields, and the card, the panel and the rows
// all agree on what a field is.

/// One choice of a field that is one of a few: the value stored and the words that show it.
public struct FieldOption: Equatable, Sendable {
    public var value: JSONValue
    /// A string as it is, anything else as compact JSON.
    public var label: String

    public init(value: JSONValue, label: String) {
        self.value = value
        self.label = label
    }
}

/// What is filled in the row itself.
public enum PlainKind: Equatable, Sendable {
    case text, date, yesNo
    /// A string of `format: date-time`: a typed full date is stored as UTC midnight.
    case dateTime
    case number(integer: Bool)
    /// An `enum`; a `const` is a choice of one.
    case choice([FieldOption])
}

public indirect enum FieldKind: Equatable, Sendable {
    case plain(PlainKind)
    /// An array of an `enum`, `uniqueItems`.
    case choices([FieldOption])
    /// An array of plain values.
    case list(of: PlainKind)
    /// An array whose `items` is an object with `properties`.
    case listOfGroups
    /// An array whose `items` is a bare `$ref` to a type.
    case listOfTypeFields(ShapeID)
    /// An object with `properties`.
    case group
    /// A bare `$ref` to a type; the type may be gone.
    case typeFields(ShapeID)
    /// An object whose `additionalProperties` is a plain schema.
    case pairs(value: PlainKind)
    /// Two kinds; `hasMore` when a branch has.
    case either(FieldKind, FieldKind)
    case other
}

extension FieldKind {
    /// A row ends in `›` and opens a card: everything but a plain kind and an either of two of those. The rule of a note that is one; a type's note draws its own (`opensOnType`).
    public var hasMore: Bool {
        switch self {
        case .plain: false
        case .either(let first, let second): first.hasMore || second.hasMore
        default: true
        }
    }

    /// Whether the row on a type's note ends in `›` and opens a read-only card, as board 5 panel 7 draws
    /// it: a group, another type's fields, a list of groups or of type fields, pairs and what no control
    /// suits, and an either with a branch that is one. `Choices` and `List of Text` have none: a type's card
    /// has nothing to show for them.
    public var opensOnType: Bool {
        switch self {
        case .group, .typeFields, .listOfGroups, .listOfTypeFields, .pairs, .other: true
        case .either(let first, let second): first.opensOnType || second.opensOnType
        case .plain, .choices, .list: false
        }
    }

    /// The type whose chip follows the label.
    public var chip: ShapeID? {
        switch self {
        case .typeFields(let type), .listOfTypeFields(let type): type
        default: nil
        }
    }

    /// What the type's note shows at the right, before any chip. `memberCount` is a group's fields. An
    /// either's two names are joined, and read `Either` when the joined text runs past 22 characters or
    /// a branch is not plain. A field that is another type's fields has no words, only the chip.
    public func typeLabel(memberCount: Int = 0) -> String {
        switch self {
        case .plain(let kind): kind.label
        case .choices: "Choices"
        case .list(let kind): "List of \(kind.label)"
        case .listOfGroups: "List"
        case .listOfTypeFields: "List of"
        case .group: FieldWords.fields(memberCount)
        case .typeFields: ""
        case .pairs: "Pairs"
        case .either(let first, let second):
            if case .plain(let a) = first, case .plain(let b) = second, case let joined = "\(a.label) or \(b.label)", joined.count <= Self.eitherLimit {
                joined
            } else {
                "Either"
            }
        case .other: FieldWords.other
        }
    }

    private static let eitherLimit = 22
}

extension PlainKind {
    /// The kind's name on a type's note.
    var label: String {
        switch self {
        case .text: "Text"
        case .number: "Number"
        case .date, .dateTime: "Date"
        case .yesNo: "Yes or no"
        case .choice: "Choice"
        }
    }
}

extension FieldBook {
    /// The kind of a field's row: the first of the rules in `FieldKindReader` that fits. A pure function
    /// of the field's schema (it reads no other type); a reader that wants it often keeps it.
    @MainActor
    public func kind(of field: Resolved.Field) -> FieldKind {
        FieldKindReader.kind(of: field.field)
    }

    /// The field a value path names, walking `members(of:)`, `item(of:)`, `pairValue(of:)` and, for an
    /// either, the first branch that has the step; nil for a path no field names (a value no field
    /// names), and for the root.
    @MainActor
    public func field(at path: FieldPath, types: [ShapeID]) -> Resolved.Field? {
        guard case .key(let first)? = path.steps.first, var current = fields(types: types).field(named: first) else { return nil }
        for step in path.steps.dropFirst() {
            guard let next = descend(from: current, by: step) else { return nil }
            current = next
        }
        return current
    }

    /// A pairs field's value field: its `additionalProperties`, as a field named "". Nil when it has none
    /// or does not say a schema.
    @MainActor
    public func pairValue(of field: Resolved.Field) -> Resolved.Field? {
        guard let value = field.field.schema["additionalProperties"], value.isObject else { return nil }
        return Resolved.Field(field: ChainField(name: "", schema: value, holdsItself: field.field.holdsItself),
                              source: field.source, introducedBy: field.introducedBy)
    }

    /// The branches of an either: the entries of `anyOf` or `oneOf`, or the types of a `type` list, null
    /// dropped, each as a field named "". None for a field that is not one of several.
    @MainActor
    public func branches(of field: Resolved.Field) -> [Resolved.Field] {
        FieldKindReader.branches(of: field.field.schema).map {
            Resolved.Field(field: ChainField(name: "", schema: $0, holdsItself: field.field.holdsItself),
                           source: field.source, introducedBy: field.introducedBy)
        }
    }

    @MainActor
    private func descend(from field: Resolved.Field, by step: FieldPath.Step) -> Resolved.Field? {
        switch (kind(of: field), step) {
        case (.group, .key(let key)), (.typeFields, .key(let key)):
            return members(of: field).first { $0.field.name == key }
        case (.pairs, .key):
            return pairValue(of: field)
        case (.list, .index), (.choices, .index), (.listOfGroups, .index), (.listOfTypeFields, .index):
            return item(of: field)
        case (.either, _):
            for branch in branches(of: field) {
                if let found = descend(from: branch, by: step) { return found }
            }
            return nil
        default:
            return nil
        }
    }
}

/// The reading itself, over a schema as the type wrote it.
enum FieldKindReader {
    static func kind(of field: ChainField) -> FieldKind {
        field.holdsItself ? .other : kind(of: field.schema)
    }

    /// The kinds, in order, the first that fits. Before them a "may be null" is dropped: a `type` list's
    /// `"null"`, and an `anyOf`/`oneOf` branch that is `{"type": "null"}`, a single branch left taken as
    /// the schema.
    static func kind(of written: SchemaValue) -> FieldKind {
        let schema = withoutNull(written)
        // Another type's fields: a bare `$ref` to a type. A reference to a part of one, or to anything
        // else, is none that a row can show.
        if let ref = schema["$ref"]?.string {
            guard let target = SchemaReferences.target(of: ref), target.fragment.isEmpty else { return .other }
            return .typeFields(target.shape)
        }
        if let options = options(of: schema) { return options.isEmpty ? (isChoiceOfNone(schema) ? .plain(.choice([])) : .other) : .plain(.choice(options)) }
        switch types(of: schema) {
        case ["array"]: return list(of: schema)
        case ["object"]: return object(schema)
        case let found where found.count == 1: return plain(schema).map(FieldKind.plain) ?? .other
        default: break
        }
        return either(of: schema)
    }

    /// Steps 4 and 7 only: a choice, yes or no, a number, a date or text. What a list's items, a pair's
    /// value and an either's two plain kinds are asked for.
    static func plain(_ written: SchemaValue) -> PlainKind? {
        let schema = withoutNull(written)
        if let options = options(of: schema) { return options.isEmpty ? (isChoiceOfNone(schema) ? .choice([]) : nil) : .choice(options) }
        guard schema["$ref"] == nil else { return nil }
        switch types(of: schema) {
        case ["boolean"]: return .yesNo
        case ["integer"]: return .number(integer: true)
        case ["number"]: return .number(integer: false)
        case ["string"]:
            let format = schema["format"]?.string
            return format == "date" ? .date : format == "date-time" ? .dateTime : .text
        default: return nil
        }
    }

    /// A string with an empty `enum` (what the field writer writes for a Choice before its first option): a choice of none,
    /// which reads as a Choice with no options and not as `Other`.
    private static func isChoiceOfNone(_ schema: SchemaValue) -> Bool {
        schema["enum"]?.elements?.isEmpty == true && types(of: schema) == ["string"]
    }

    /// An `enum` of scalars (a null among them is a "may be null", dropped), or a scalar `const`. Nil when
    /// the schema says neither; empty when it says one that is no choice (a non-scalar `enum` or `const`).
    private static func options(of schema: SchemaValue) -> [FieldOption]? {
        if let list = schema["enum"] {
            guard let elements = list.elements else { return [] }
            let scalars = elements.filter { $0 != .null }
            let options = scalars.compactMap(option)
            return options.count == scalars.count ? options : []
        }
        if let constant = schema["const"] {
            return option(constant).map { [$0] } ?? []
        }
        return nil
    }

    private static func option(_ value: SchemaValue) -> FieldOption? {
        switch value {
        case .string(let string): FieldOption(value: .string(string), label: string)
        case .number(let number): FieldOption(value: .number(number), label: FieldText.shortest(number))
        case .bool(let bool): FieldOption(value: .bool(bool), label: bool ? "true" : "false")
        default: nil
        }
    }

    private static func list(of schema: SchemaValue) -> FieldKind {
        guard schema["prefixItems"] == nil, let written = schema["items"], written.isObject else { return .other }
        let items = withoutNull(written)
        if let ref = items["$ref"]?.string {
            guard let target = SchemaReferences.target(of: ref), target.fragment.isEmpty else { return .other }
            return .listOfTypeFields(target.shape)
        }
        if let options = options(of: items) {
            guard !options.isEmpty else { return .other }
            return items["enum"] != nil && schema["uniqueItems"]?.bool == true ? .choices(options) : .list(of: .choice(options))
        }
        let found = types(of: items)
        if found.isEmpty || found == ["object"], let properties = items["properties"]?.members, !properties.isEmpty {
            return .listOfGroups
        }
        return plain(items).map { .list(of: $0) } ?? .other
    }

    private static func object(_ schema: SchemaValue) -> FieldKind {
        if let properties = schema["properties"]?.members, !properties.isEmpty { return .group }
        guard schema["patternProperties"] == nil, schema["allOf"] == nil, schema["not"] == nil else { return .other }
        if let value = schema["additionalProperties"], value.isObject, let kind = plain(value) { return .pairs(value: kind) }
        return .other
    }

    /// Two branches, each a kind a row can show.
    private static func either(of schema: SchemaValue) -> FieldKind {
        let found = branches(of: schema)
        guard found.count == 2 else { return .other }
        let first = kind(of: found[0]), second = kind(of: found[1])
        return first == .other || second == .other ? .other : .either(first, second)
    }

    /// The entries of `anyOf`/`oneOf`, or the types of a `type` list (null dropped), each a schema: for a
    /// type, the field's own with that one `type`. Empty when the schema is not one of several.
    static func branches(of written: SchemaValue) -> [SchemaValue] {
        let schema = withoutNull(written)
        for key in ["anyOf", "oneOf"] {
            if let entries = schema[key]?.elements {
                let kept = entries.filter { !isNull($0) }
                if kept.count > 1 { return kept }
            }
        }
        let found = types(of: schema)
        guard found.count > 1, let members = schema.members else { return [] }
        return found.map { type in
            .object(members.map { $0.key == "type" ? SchemaMember(key: "type", value: .string(type)) : $0 })
        }
    }

    /// The `type` as a list, `"null"` dropped; empty for none.
    private static func types(of schema: SchemaValue) -> [String] {
        switch schema["type"] {
        case .string(let type)?: type == "null" ? [] : [type]
        case .array(let list)?: list.compactMap(\.string).filter { $0 != "null" }
        default: []
        }
    }

    private static func isNull(_ schema: SchemaValue) -> Bool {
        schema["type"]?.string == "null"
    }

    /// The schema with its "may be null" taken off: an `anyOf` or `oneOf` whose null branch leaves one
    /// is that one.
    private static func withoutNull(_ schema: SchemaValue) -> SchemaValue {
        for key in ["anyOf", "oneOf"] {
            if let entries = schema[key]?.elements, entries.contains(where: isNull) {
                let kept = entries.filter { !isNull($0) }
                if kept.count == 1 { return withoutNull(kept[0]) }
            }
        }
        return schema
    }
}

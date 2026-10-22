import Canvas
import CanvasRPC
import Foundation

// What a shape holds under its types' fields: the values themselves, an added property of the kinds
// that can be instances (`typeable()`), written by people and agents and read by both.

/// A shape's field values: one JSON object, a member for each field it has a value for. A value that
/// is empty is not kept, at any depth: null, text with no characters, a list with no items once its own
/// empties are dropped, a group with no members after the same. `false`, `0` and text of spaces are
/// values. Numbers are Doubles, as every JSON number in a board is, so an integer past 2^53 belongs in
/// a text field of its type.
public struct FieldValues: Codable, Hashable, Sendable {
    /// Never holds an empty: every way in prunes.
    public private(set) var values: JSONObject

    public init(_ values: JSONObject = [:]) {
        self.values = Self.pruned(.object(values))?.objectValue ?? [:]
    }

    public init(from decoder: any Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(JSONObject.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }

    public var isEmpty: Bool { values.isEmpty }

    /// A field's value. Setting nil, null or something empty removes it.
    public subscript(field: String) -> JSONValue? {
        get { values[field] }
        set { values[field] = newValue.flatMap(Self.pruned) }
    }

    /// `value` with its empties dropped, nil when nothing is left. The one rule, used by every way in.
    public static func pruned(_ value: JSONValue) -> JSONValue? {
        // `JSONValue` is `ExpressibleByNilLiteral`, so a bare `nil` beside a value in a ternary would be `.null`: each case says `Optional.none`.
        switch value {
        case .null:
            return Optional.none
        case .string(let text):
            guard !text.isEmpty else { return Optional.none }
            return value
        case .array(let items):
            let kept = items.compactMap(pruned)
            guard !kept.isEmpty else { return Optional.none }
            return .array(kept)
        case .object(let members):
            let kept = members.compactMapValues(pruned)
            guard !kept.isEmpty else { return Optional.none }
            return .object(kept)
        case .bool, .number:
            return value
        }
    }
}

extension FieldValues {
    /// The most characters a note's name by its values keeps.
    public static let nameLength = 60

    /// What a note with no title and no words is called: its filled top-level plain values (text and numbers as they
    /// read, a ticked box as its field's name) in key order, joined by ` · `, cut to `nameLength` characters. Nil
    /// for a type's own note and for a note with none. It reads the record alone (a naming closure sees nothing
    /// else), so the order is the keys', not the rows'.
    public static func name<P: ShapeProps>(of record: ShapeRecord<P>) -> String? {
        guard record[TypeSchemaProperty.self] == nil, let values = record[FieldValuesProperty.self] else { return nil }
        return values.name
    }

    /// The same for values alone.
    public var name: String? {
        var parts: [String] = []
        for key in values.keys.sorted() {
            switch values[key] {
            case .string(let text)?:
                let line = text.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
                if !line.isEmpty { parts.append(line) }
            case .number(let number)?:
                parts.append(number == number.rounded() && abs(number) < 1e15 ? String(Int(number)) : String(number))
            case .bool(true)?:
                parts.append(key)
            default:
                break
            }
        }
        guard !parts.isEmpty else { return nil }
        let joined = parts.joined(separator: " · ")
        return joined.count > Self.nameLength ? String(joined.prefix(Self.nameLength - 1)) + "…" : joined
    }
}

extension FieldValues: SchemaDescribed {
    public static func schema(in definitions: inout SchemaDefinitions) -> JSONObject {
        definitions.reference("field-values", of: Self.self) { _ in
            ["type": "object", "description": "The values of the fields of the shape's types, by field name."]
        }
    }
}

/// A shape's values for its types' fields (`fieldValues`), on the kinds that opt in (`typeable()`).
/// Not `readOnly`: people and agents write it, never the app by itself.
public enum FieldValuesProperty {}

extension FieldValuesProperty: ShapeProperty {
    public static let key: PropertyKey = RelationshipKeys.fieldValues
    public static var defaultValue: FieldValues? { nil }
    public static func isNone(_ value: FieldValues) -> Bool { value.isEmpty }
    public static var keywords: PropertyKeywords<FieldValues> {
        PropertyKeywords()
            .description("The values of the fields of the shape's types, by field name, as JSON. A value that is empty is not kept.")
    }
}

extension ShapeRegistrar {
    /// This kind's shapes can be instances of types: each may hold `is`, the types it is,
    /// `fieldValues`, what it holds for their fields, and `autofill`, whether it fills them from its
    /// words (on a type of a kind that can be one, whether its shapes do). Needs `typeWords`
    /// (`TypeWords.check`): a shape's types are typed on a line of its words (`/is-a`).
    public mutating func typeable() {
        optIn(to: IsAProperty.self)
        optIn(to: FieldValuesProperty.self)
        optIn(to: AutofillProperty.self)
    }
}

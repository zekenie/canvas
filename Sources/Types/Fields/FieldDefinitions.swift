import Canvas
import Foundation

// What a type's field definitions are, edited as a person defines them: a name and one of five kinds. Pure:
// a schema in, a schema out, in the order written, with no editor. `FieldDefiner` is the door that writes
// the result to a type's `schema`; the relationship type's card is its face.

/// The five kinds a field is defined as, in the order a menu lists them. Each is written as the schema
/// `FieldKindReader` reads back as that kind, so rows, the form and the check show what was written.
public enum DefinedKind: CaseIterable, Equatable, Sendable {
    case text, number, date, yesNo, choice

    /// The words a menu and a type's row use for it (`FieldKind.typeLabel`'s): `Text`, `Number`, `Date`,
    /// `Yes or no`, `Choice`.
    public var label: String {
        switch self {
        case .text: PlainKind.text.label
        case .number: PlainKind.number(integer: false).label
        case .date: PlainKind.date.label
        case .yesNo: PlainKind.yesNo.label
        case .choice: PlainKind.choice([]).label
        }
    }

    /// The members of the field's schema that say the kind. A choice starts with an empty `enum`: the
    /// kind is chosen before its options are typed, and `FieldKindReader` reads it as a choice of none.
    var members: [SchemaMember] {
        switch self {
        case .text: [SchemaMember(key: "type", value: .string("string"))]
        case .number: [SchemaMember(key: "type", value: .string("number"))]
        case .date: [SchemaMember(key: "type", value: .string("string")), SchemaMember(key: "format", value: .string("date"))]
        case .yesNo: [SchemaMember(key: "type", value: .string("boolean"))]
        case .choice: [SchemaMember(key: "type", value: .string("string")), SchemaMember(key: "enum", value: .array([]))]
        }
    }

    /// The kind a field's schema is, as the app reads it: a whole number is a Number and a date with a time
    /// a Date; a choice without options a Choice (the reader's). Nil for a kind none of the five is (a list, a group,
    /// another type's fields, an either, a schema no row can show).
    public init?(reading schema: SchemaValue) {
        switch FieldKindReader.kind(of: schema) {
        case .plain(let plain):
            switch plain {
            case .text: self = .text
            case .number: self = .number
            case .date, .dateTime: self = .date
            case .yesNo: self = .yesNo
            case .choice: self = .choice
            }
        default: return nil
        }
    }
}

/// One field of a type as the writer edits it: a property of its root `properties`.
public struct DefinedField: Equatable, Sendable {
    /// The property's name in the schema; never changed by a rename.
    public var key: String
    /// What the rows call it (`FieldName.words`): the field's `title`, else its key in words.
    public var name: String
    /// Nil for a kind none of the five is: the field is shown and removed, not changed or given options.
    public var kind: DefinedKind?
    /// A choice's options, in the order written (labels; a `null` among them is no option). Empty for every other kind.
    public var options: [String]
    public var isRequired: Bool

    public init(key: String, name: String, kind: DefinedKind?, options: [String] = [], isRequired: Bool = false) {
        self.key = key
        self.name = name
        self.kind = kind
        self.options = options
        self.isRequired = isRequired
    }
}

/// The edits of a type's root `properties`, over a schema as written. Each answers the schema after it, the
/// schema itself when nothing would change, and nil when it can't be done (a schema that is not an object,
/// `properties` that is not one, a field that is not there, an empty name). Members and options keep the
/// order they were written in; `required` is kept in step.
public enum SchemaFields {
    // MARK: Reading

    /// The root's fields, in the order written; empty for a schema that is not an object or has no `properties`.
    /// A `$`-key of `properties` is a directive, never a field.
    public static func fields(of root: SchemaValue) -> [DefinedField] {
        guard let properties = root["properties"]?.members else { return [] }
        let required = Set(root["required"]?.elements?.compactMap(\.string) ?? [])
        return properties.filter { SchemaDirectives.isField($0.key) }.map { member in
            DefinedField(key: member.key, name: FieldName.words(of: ChainField(name: member.key, schema: member.value)),
                         kind: DefinedKind(reading: member.value), options: optionLabels(of: member.value),
                         isRequired: required.contains(member.key))
        }
    }

    // MARK: Keys

    /// The key a typed name is written under, in the style the sync is asked to write: camelCase in plain
    /// ASCII letters and digits for a Latin script (accents dropped), a script's own letters otherwise, with no
    /// spaces or punctuation; `since`, `primaryOwner`. A word in capitals is lower case (`URL` is `url`), one
    /// with capitals inside keeps them (`postalURL`). Nil for a name with no letter or digit in it.
    public static func key(forName name: String) -> String? {
        var words: [String] = [], current = ""
        for character in name {
            let plain = String(character).folding(options: .diacriticInsensitive, locale: nil)
            let kept = plain.unicodeScalars.allSatisfy(\.isASCII) ? plain : String(character)
            if kept.allSatisfy({ $0.isLetter || $0.isNumber }) {
                current += kept
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        guard !words.isEmpty else { return nil }
        return words.enumerated().map { place, word in
            let source = word.allSatisfy({ !$0.isLowercase }) ? word.lowercased() : word
            let first = place == 0 ? source.prefix(1).lowercased() : source.prefix(1).uppercased()
            return first + source.dropFirst()
        }.joined()
    }

    /// `key`, or `key2`, `key3`… the first that `taken` doesn't hold.
    public static func unique(_ key: String, avoiding taken: Set<String>) -> String {
        guard taken.contains(key) else { return key }
        var number = 2
        while taken.contains("\(key)\(number)") { number += 1 }
        return "\(key)\(number)"
    }

    /// A typed name as the field's title says it: the words with their spaces collapsed, trimmed.
    static func tidy(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: Fields

    /// Adds a field named `name` of `kind` after the last property, and the key it was written under. The key
    /// comes from the name (`key(forName:)`) and is unique in `properties` (`since2`); the name is the field's
    /// `title` only when the key's own words don't already say it. Nil for a name with nothing to make a key of.
    public static func adding(_ name: String, kind: DefinedKind, to root: SchemaValue) -> (schema: SchemaValue, key: String)? {
        let name = tidy(name)
        guard var members = root.members, let base = key(forName: name) else { return nil }
        var properties: [SchemaMember]
        var place = members.firstIndex { $0.key == "properties" }
        if let at = place {
            guard let held = members[at].value.members else { return nil }
            properties = held
        } else {
            properties = []
        }
        let key = unique(base, avoiding: Set(properties.map(\.key)))
        var field = kind.members
        if name != FieldName.words(of: ChainField(name: key, schema: .null)) {
            field.append(SchemaMember(key: "title", value: .string(name)))
        }
        properties.append(SchemaMember(key: key, value: .object(field)))
        if let at = place {
            members[at].value = .object(properties)
        } else {
            place = members.count
            members.append(SchemaMember(key: "properties", value: .object(properties)))
        }
        return (.object(members), key)
    }

    /// Gives the field `key` the name `name`: the key stays and the field's `title` says the name, or is taken
    /// off when the key's own words already say it. Nil for an empty name and a field that is not there.
    public static func renaming(_ key: String, to name: String, in root: SchemaValue) -> SchemaValue? {
        let name = tidy(name)
        guard !name.isEmpty else { return nil }
        return editing(key, in: root) { field in
            guard var members = field.members else { return nil }
            let own = FieldName.words(of: ChainField(name: key, schema: .null))
            members.removeAll { $0.key == "title" }
            if name != own {
                // The title keeps the place it had, else follows the kind's members.
                let at = field.members?.firstIndex { $0.key == "title" } ?? members.count
                members.insert(SchemaMember(key: "title", value: .string(name)), at: min(at, members.count))
            }
            return .object(members)
        }
    }

    /// Makes the field `key` a `kind`: its schema is the kind's, keeping its `title` and `description`. A
    /// Choice that becomes another kind loses its options, and one that becomes a Choice starts with none. The
    /// schema itself when the field is that kind already.
    public static func changing(_ key: String, to kind: DefinedKind, in root: SchemaValue) -> SchemaValue? {
        editing(key, in: root) { field in
            if DefinedKind(reading: field) == kind { return field }
            let kept = (field.members ?? []).filter { $0.key == "title" || $0.key == "description" }
            return .object(kind.members + kept)
        }
    }

    /// Takes the field `key` out of `properties`, and its name out of `required` (the member goes when that
    /// leaves it empty).
    public static func removing(_ key: String, from root: SchemaValue) -> SchemaValue? {
        guard var members = root.members, let at = members.firstIndex(where: { $0.key == "properties" }),
              var properties = members[at].value.members, properties.contains(where: { $0.key == key }) else { return nil }
        properties.removeAll { $0.key == key }
        members[at].value = .object(properties)
        if let place = members.firstIndex(where: { $0.key == "required" }), var names = members[place].value.elements,
           names.contains(.string(key)) {
            names.removeAll { $0 == .string(key) }
            if names.isEmpty { members.remove(at: place) } else { members[place].value = .array(names) }
        }
        return .object(members)
    }

    // MARK: Options

    /// Adds `option` after the last of the field's options. Nil for an empty option, and a field that has no
    /// `enum` to add to (a Choice has one, and nothing else is given options); the schema itself for an option
    /// the field has.
    public static func addingOption(_ option: String, to key: String, in root: SchemaValue) -> SchemaValue? {
        let option = option.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !option.isEmpty else { return nil }
        return editingOptions(of: key, in: root) { elements in
            if optionLabels(in: elements).contains(option) { return elements }
            return elements + [.string(option)]
        }
    }

    /// Words the option at `place` (counted over the options, in the order written) as `option`. Nil for an
    /// empty option, a place that is none, and an option another place has; the schema itself for the same.
    public static func renamingOption(at place: Int, to option: String, of key: String, in root: SchemaValue) -> SchemaValue? {
        let option = option.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !option.isEmpty else { return nil }
        return editingOptions(of: key, in: root) { elements in
            let places = optionPlaces(in: elements)
            guard places.indices.contains(place) else { return nil }
            var elements = elements
            if optionLabels(in: elements).enumerated().contains(where: { $0.offset != place && $0.element == option }) { return nil }
            elements[places[place]] = .string(option)
            return elements
        }
    }

    /// Takes the option at `place` out. The field stays a Choice when it was its last.
    public static func removingOption(at place: Int, of key: String, in root: SchemaValue) -> SchemaValue? {
        editingOptions(of: key, in: root) { elements in
            let places = optionPlaces(in: elements)
            guard places.indices.contains(place) else { return nil }
            var elements = elements
            elements.remove(at: places[place])
            return elements
        }
    }

    // MARK: Private

    /// The schema with the field `key`'s schema replaced by what `change` makes of it.
    private static func editing(_ key: String, in root: SchemaValue, _ change: (SchemaValue) -> SchemaValue?) -> SchemaValue? {
        guard var members = root.members, let at = members.firstIndex(where: { $0.key == "properties" }),
              var properties = members[at].value.members, let place = properties.firstIndex(where: { $0.key == key }),
              properties[place].value.isObject, let changed = change(properties[place].value) else { return nil }
        properties[place].value = changed
        members[at].value = .object(properties)
        return .object(members)
    }

    /// The same, over the field's `enum` array.
    private static func editingOptions(of key: String, in root: SchemaValue, _ change: ([SchemaValue]) -> [SchemaValue]?) -> SchemaValue? {
        editing(key, in: root) { field in
            guard var members = field.members, let at = members.firstIndex(where: { $0.key == "enum" }),
                  let elements = members[at].value.elements, let changed = change(elements) else { return nil }
            members[at].value = .array(changed)
            return .object(members)
        }
    }

    /// Where the options are in an `enum`: its scalars that are not `null` (a `null` is "may be empty").
    private static func optionPlaces(in elements: [SchemaValue]) -> [Int] {
        elements.indices.filter {
            switch elements[$0] {
            case .null, .object, .array: false
            default: true
            }
        }
    }

    private static func optionLabels(in elements: [SchemaValue]) -> [String] {
        optionPlaces(in: elements).map { place in
            switch elements[place] {
            case .string(let string): string
            case .number(let number): FieldText.shortest(number)
            case .bool(let bool): bool ? "true" : "false"
            default: ""
            }
        }
    }

    private static func optionLabels(of field: SchemaValue) -> [String] {
        field["enum"]?.elements.map(optionLabels(in:)) ?? []
    }
}

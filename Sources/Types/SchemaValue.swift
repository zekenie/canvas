import Canvas

/// A schema as it was written: JSON with an object's members in the order they were written, which
/// `JSONValue`'s dictionaries lose and rows and cards need (the fields of a group are shown in the
/// order its `properties` name them). `JSONNode` keeps the order too, but carries text ranges.
/// Equality is order-sensitive on purpose: a property moved in a type is a change to its rows.
/// Numbers are doubles, as everywhere in `JSONValue`.
public indirect enum SchemaValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([SchemaValue])
    /// The members in the order written, a name once.
    case object([SchemaMember])
}

public struct SchemaMember: Equatable, Sendable {
    public var key: String
    public var value: SchemaValue

    public init(key: String, value: SchemaValue) {
        self.key = key
        self.value = value
    }
}

extension SchemaValue {
    /// A reading's node. A name written twice has the last value at the first's place: what
    /// `SchemaDocument` and `JSON.parse` read.
    public init(_ node: JSONNode) {
        switch node.value {
        case .object(let members):
            var places: [String: Int] = [:], read: [SchemaMember] = []
            for member in members {
                let value = SchemaValue(member.value)
                if let place = places[member.key] {
                    read[place].value = value
                } else {
                    places[member.key] = read.count
                    read.append(SchemaMember(key: member.key, value: value))
                }
            }
            self = .object(read)
        case .array(let elements): self = .array(elements.map(SchemaValue.init))
        case .string(let string): self = .string(string)
        case .number(let literal): self = .number(Double(literal) ?? .nan)
        case .bool(let bool): self = .bool(bool)
        case .null: self = .null
        }
    }

    /// The core's JSON, whose objects have no order: members in the order of their keys.
    public init(_ json: JSONValue) {
        switch json {
        case .object(let object): self = .object(object.sorted { $0.key < $1.key }.map { SchemaMember(key: $0.key, value: SchemaValue($0.value)) })
        case .array(let elements): self = .array(elements.map(SchemaValue.init))
        case .string(let string): self = .string(string)
        case .number(let number): self = .number(number)
        case .bool(let bool): self = .bool(bool)
        case .null: self = .null
        }
    }

    /// The core's JSON, which its validator takes: the order of an object's members is gone.
    public var json: JSONValue {
        switch self {
        case .object(let members): .object(Dictionary(members.map { ($0.key, $0.value.json) }, uniquingKeysWith: { _, last in last }))
        case .array(let elements): .array(elements.map(\.json))
        case .string(let string): .string(string)
        case .number(let number): .number(number)
        case .bool(let bool): .bool(bool)
        case .null: .null
        }
    }

    /// The value of the member called `key`, if this is an object with one.
    public subscript(key: String) -> SchemaValue? {
        members?.first { $0.key == key }?.value
    }

    public var members: [SchemaMember]? { if case .object(let members) = self { members } else { Optional.none } }
    public var elements: [SchemaValue]? { if case .array(let elements) = self { elements } else { Optional.none } }
    public var string: String? { if case .string(let string) = self { string } else { Optional.none } }
    public var bool: Bool? { if case .bool(let bool) = self { bool } else { Optional.none } }
    public var number: Double? { if case .number(let number) = self { number } else { Optional.none } }
    public var isObject: Bool { members != nil }
}

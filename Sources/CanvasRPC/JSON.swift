import Foundation

/// JSON as a value: what requests and responses carry. Numbers are doubles, as they are in
/// JavaScript, so integers beyond 2⁵³ lose precision. (The app's own `JSONValue`, in Canvas, is the
/// same shape; this module knows nothing of the canvas, so it has its own.)
public enum JSON: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])
}

extension JSON {
    /// A member of an object; nil for a missing member or anything but an object. Setting nil
    /// removes the member; setting on anything but an object does nothing.
    public subscript(key: String) -> JSON? {
        get {
            guard case .object(let object) = self else { return nil }
            return object[key]
        }
        set {
            guard case .object(var object) = self else { return }
            object[key] = newValue
            self = .object(object)
        }
    }

    public var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    public var numberValue: Double? { if case .number(let value) = self { value } else { nil } }
    public var boolValue: Bool? { if case .bool(let value) = self { value } else { nil } }
    public var arrayValue: [JSON]? { if case .array(let value) = self { value } else { nil } }
    public var objectValue: [String: JSON]? { if case .object(let value) = self { value } else { nil } }
    /// A number that's a whole one, as an `Int`.
    public var intValue: Int? { numberValue.flatMap { Int(exactly: $0) } }
    public var isNull: Bool { self == .null }
}

extension JSON: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSON].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension JSON {
    /// Reads JSON text.
    public init(data: Data) throws {
        self = try JSONDecoder().decode(JSON.self, from: data)
    }

    public init(text: String) throws {
        try self.init(data: Data(text.utf8))
    }

    /// Any encodable value, as JSON.
    public init(encoding value: some Encodable) throws {
        self = try JSON(data: JSON.encoder().encode(value))
    }

    /// Decodes a value from this JSON.
    public func decode<T: Decodable>(_: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: JSON.encoder().encode(self))
    }

    /// On one line, with sorted keys: what goes on the wire, a line a message. A string's newlines
    /// are escaped, so the text never holds one.
    public var compactText: String {
        // Only a number that isn't finite fails, and nothing here makes one.
        (try? JSON.encoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    /// Indented, with sorted keys, and a list of values (a point, a rect, some names) on one line:
    /// what the command line prints, which agents read, so a rect takes a line, not ten.
    public var prettyText: String { pretty(indent: "") }

    private func pretty(indent: String) -> String {
        let inner = indent + "  "
        switch self {
        case .object(let object) where !object.isEmpty:
            let members = object.keys.sorted().map { "\(inner)\(JSON.string($0).compactText): \(object[$0]!.pretty(indent: inner))" }
            return "{\n" + members.joined(separator: ",\n") + "\n\(indent)}"
        case .array(let items) where !items.isEmpty && !isFlat:
            return "[\n" + items.map { inner + $0.pretty(indent: inner) }.joined(separator: ",\n") + "\n\(indent)]"
        case .array(let items):
            return "[" + items.map { $0.pretty(indent: inner) }.joined(separator: ", ") + "]"
        default:
            return compactText
        }
    }

    /// Values, or lists of them, and no objects: it goes on one line.
    private var isFlat: Bool {
        switch self {
        case .object: false
        case .array(let items): items.allSatisfy { if case .array(let nested) = $0 { nested.allSatisfy(\.isScalar) } else { $0.isScalar } }
        default: true
        }
    }

    private var isScalar: Bool {
        switch self {
        case .object, .array: false
        default: true
        }
    }

    /// Keys sorted, slashes as they are: a message written twice is written the same.
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

extension JSON: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
                ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

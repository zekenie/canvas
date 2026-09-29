import Canvas
import CanvasRPC

// The core's JSON and the wire's are the same six cases; commands cross from one to the other.

extension JSON {
    /// The core's JSON as the wire's, member for member: how a command that builds its output from
    /// what the core writes (a shape's properties, `record.propertiesJSON`) puts it on the wire
    /// without writing it as text and reading it back.
    public init(_ value: JSONValue) {
        switch value {
        case .null: self = .null
        case .bool(let bool): self = .bool(bool)
        case .number(let number): self = .number(number)
        case .string(let string): self = .string(string)
        case .array(let items): self = .array(items.map(JSON.init))
        case .object(let object): self = .object(object.mapValues(JSON.init))
        }
    }

    init(_ object: JSONObject) {
        self = .object(object.mapValues(JSON.init))
    }
}

extension JSONValue {
    init(_ json: JSON) {
        switch json {
        case .null: self = .null
        case .bool(let bool): self = .bool(bool)
        case .number(let number): self = .number(number)
        case .string(let string): self = .string(string)
        case .array(let items): self = .array(items.map(JSONValue.init))
        case .object(let object): self = .object(object.mapValues(JSONValue.init))
        }
    }
}

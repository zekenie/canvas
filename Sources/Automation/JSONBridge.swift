import Canvas
import CanvasRPC

// The core's JSON and the wire's are the same six cases; commands cross from one to the other.

extension JSON {
    init(_ value: JSONValue) {
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

/// Any JSON object, as a command's param: `--props '{"text": "Hello"}'`.
struct JSONObjectParam: Codable, Equatable, Sendable, SchemaDescribed {
    var members: JSONObject

    init(_ members: JSONObject) { self.members = members }

    init(from decoder: any Decoder) throws {
        members = try JSONObject(from: decoder)
    }

    func encode(to encoder: any Encoder) throws {
        try members.encode(to: encoder)
    }

    static func schema(in _: inout SchemaDefinitions) -> JSONObject { ["type": "object"] }
}

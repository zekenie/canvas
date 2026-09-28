import Foundation

// JSON-RPC 2.0 (jsonrpc.org/specification), one message a line: a request's `method` is a
// command's name ("draw"), or `describe`; its `params`, an object of the command's params.

/// A request's id: a number or a string, as JSON-RPC allows. A request without one is a
/// notification, which gets no response.
public enum RequestID: Hashable, Sendable, CustomStringConvertible {
    case number(Int)
    case string(String)

    public var description: String {
        switch self {
        case .number(let number): "\(number)"
        case .string(let string): string
        }
    }
}

extension RequestID: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int.self) {
            self = .number(number)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let number): try container.encode(number)
        case .string(let string): try container.encode(string)
        }
    }
}

public struct RPCRequest: Equatable, Sendable {
    public var id: RequestID?
    public var method: String
    /// An object, by name; nil for none.
    public var params: JSON?

    public init(id: RequestID?, method: String, params: JSON? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }
}

extension RPCRequest: Codable {
    private enum Keys: String, CodingKey { case jsonrpc, id, method, params }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        guard try container.decode(String.self, forKey: .jsonrpc) == "2.0" else {
            throw DecodingError.dataCorruptedError(forKey: .jsonrpc, in: container, debugDescription: "jsonrpc must be \"2.0\"")
        }
        id = try container.decodeIfPresent(RequestID.self, forKey: .id)
        method = try container.decode(String.self, forKey: .method)
        params = try container.decodeIfPresent(JSON.self, forKey: .params)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode("2.0", forKey: .jsonrpc)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encode(method, forKey: .method)
        try container.encodeIfPresent(params, forKey: .params)
    }
}

public struct RPCResponse: Equatable, Sendable {
    /// The request's; nil when the request couldn't be read far enough to have one.
    public var id: RequestID?
    public var outcome: Result<JSON, RPCError>

    public init(id: RequestID?, outcome: Result<JSON, RPCError>) {
        self.id = id
        self.outcome = outcome
    }
}

extension RPCResponse: Codable {
    private enum Keys: String, CodingKey { case jsonrpc, id, result, error }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        id = try container.decodeIfPresent(RequestID.self, forKey: .id)
        if let error = try container.decodeIfPresent(RPCError.self, forKey: .error) {
            outcome = .failure(error)
        } else {
            outcome = .success(try container.decodeIfPresent(JSON.self, forKey: .result) ?? .null)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode("2.0", forKey: .jsonrpc)
        if let id { try container.encode(id, forKey: .id) } else { try container.encodeNil(forKey: .id) }
        switch outcome {
        case .success(let result): try container.encode(result, forKey: .result)
        case .failure(let error): try container.encode(error, forKey: .error)
        }
    }
}

/// What went wrong, as JSON-RPC says it: a code, a message, and `data`. Here `data` carries
/// `reason`, one word an agent can branch on ("unknown_kind"), and a `hint`: what to do about it,
/// often the command to run.
public struct RPCError: Error, Hashable, Sendable, Codable, CustomStringConvertible {
    public var code: Int
    public var message: String
    public var data: JSON?

    public init(code: Int, message: String, data: JSON? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    /// An error with its reason and hint in `data`, and anything else `details` says.
    public init(_ code: Int, reason: String, _ message: String, hint: String? = nil, details: [String: JSON] = [:]) {
        var data = details
        data["reason"] = .string(reason)
        if let hint { data["hint"] = .string(hint) }
        self.init(code: code, message: message, data: .object(data))
    }

    public var reason: String? { data?["reason"]?.stringValue }
    public var hint: String? { data?["hint"]?.stringValue }
    public var description: String { message }

    // The codes JSON-RPC defines, and the one it leaves to servers that this one uses.
    public static let parseError = -32700
    public static let invalidRequest = -32600
    public static let methodNotFound = -32601
    public static let invalidParams = -32602
    public static let internalError = -32603
    /// The request was fine, and the command couldn't do it: no such board, a shape it can't make.
    public static let failed = -32000

    /// A command's params that don't say something it can do.
    public static func invalidParams(_ message: String, reason: String = "invalid_params", hint: String? = nil) -> RPCError {
        RPCError(invalidParams, reason: reason, message, hint: hint)
    }

    /// A command that couldn't do what it was asked.
    public static func failed(_ message: String, reason: String, hint: String? = nil) -> RPCError {
        RPCError(failed, reason: reason, message, hint: hint)
    }
}

import Canvas
import CanvasRPC
import CoreGraphics
import Foundation

// A REST API as it's kept: its server (where it's served and how a client signs in), its version, whether it's retired, and
// its rows, one flat list of path-prefix headers and endpoints. A group is a header and the endpoints after it, up to the next
// header, so no row stores its group: an endpoint stores its path under the header above it ("/{id}" under "/orders"), and
// retyping the header is one write that every member's full path follows. Complete at version 0: every member a later landing
// reads is here now (an endpoint's deprecated, its responses, the API's version), so those landings change no encoding.

/// A REST API: where it's served, its version, and its rows (path-prefix headers and endpoints), in order. Its name is
/// Titles' (`title`); only its frame's width is its own, its height laid out from its rows, as a table's is.
public struct API: BoxShapeProps {
    public static let kind: ShapeKind = "api"
    public static let properties = Properties<API>(title: "API") {
        Property("frame", \.frame).required()
        Property("server", \.server).description("Where it's served and how a client signs in: its first line, `host[/path] [bearer | basic | apikey NAME | oauth2]`.")
        Property("version", \.version).description("Its version, as written (OpenAPI's info.version).")
        Property("deprecated", \.deprecated).description("Retired: an old version, drawn faded.")
        Property("endpoints", \.endpoints).description("Its rows, in order: path-prefix headers and the endpoints under each, up to the next.")
    }
    public var frame: CGRect
    public var server: APIServer
    public var version: String
    public var deprecated: Bool
    public var endpoints: [APIRow]

    public init(frame: CGRect = .zero, server: APIServer = APIServer(), version: String = "", deprecated: Bool = false, endpoints: [APIRow] = []) {
        self.frame = frame
        self.server = server
        self.version = version
        self.deprecated = deprecated
        self.endpoints = endpoints
    }

    public init() { self.init(frame: .zero) }
}

/// Where an API is served and how a client signs in: its first line, `api.shop.dev/v1 bearer`.
public struct APIServer: SchemaDefined, Hashable, Sendable {
    public static let properties = Properties<APIServer>(definition: "api-server") {
        Property("host", \.host).description("Its host and base path, as written: api.shop.dev/v1.")
        Property("auth", \.auth).description("How a client signs in, as written: bearer, basic, apikey NAME, oauth2; and any words after.")
    }
    public var host: String
    public var auth: String

    public init(host: String = "", auth: String = "") {
        self.host = host
        self.auth = auth
    }

    public init() { self.init(host: "") }

    /// Nothing written.
    public var isEmpty: Bool { host.isEmpty && auth.isEmpty }
}

/// One row of an API: a path-prefix header, or an endpoint. Coded flat, a header as `{"id", "header": "/orders"}` and an
/// endpoint as its members.
public enum APIRow: Hashable, Sendable {
    case header(PathHeader)
    case endpoint(Endpoint)

    /// Its id, the API's own, which a copy keeps.
    public var id: PartID {
        switch self {
        case .header(let header): header.id
        case .endpoint(let endpoint): endpoint.id
        }
    }

    public var endpoint: Endpoint? {
        if case .endpoint(let endpoint) = self { return endpoint }
        return nil
    }

    public var header: PathHeader? {
        if case .header(let header) = self { return header }
        return nil
    }
}

extension APIRow: Codable {
    private enum Keys: String, CodingKey { case header }

    public init(from decoder: any Decoder) throws {
        let keyed = try decoder.container(keyedBy: Keys.self)
        if keyed.contains(.header) {
            self = .header(try PathHeader(from: decoder))
        } else {
            self = .endpoint(try Endpoint(from: decoder))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .header(let header): try header.encode(to: encoder)
        case .endpoint(let endpoint): try endpoint.encode(to: encoder)
        }
    }
}

extension APIRow: SchemaDescribed {
    public static func schema(in definitions: inout SchemaDefinitions) -> JSONObject {
        definitions.reference("api-row", of: Self.self) { definitions in
            ["oneOf": [.object(PathHeader.schema(in: &definitions)), .object(Endpoint.schema(in: &definitions))],
             "description": "A path-prefix header ({\"header\": \"/orders\"}), or an endpoint."]
        }
    }
}

/// Its endpoints' bodies and responses name type notes, which a copy renames.
extension APIRow: ShapeNaming {
    public func forEachNamedShape(_ body: (ShapeID) -> Void) { endpoint?.forEachNamedShape(body) }

    public func renamingShapes(_ rename: (ShapeID) -> ShapeID?) -> APIRow {
        switch self {
        case .header: self
        case .endpoint(let endpoint): .endpoint(endpoint.renamingShapes(rename))
        }
    }
}

/// A path prefix that heads the endpoints after it, up to the next header: `/orders`.
public struct PathHeader: SchemaDefined, Hashable, Sendable {
    public static let properties = Properties<PathHeader>(definition: "path-header") {
        Property("id", \.id).required()
        Property("header", \.header).required().description("The path its endpoints' paths are under: /orders.")
    }
    public var id: PartID
    /// The prefix: the path its endpoints' paths are under.
    public var header: String

    public init(id: PartID = PartID(), prefix: String) {
        self.id = id
        header = prefix
    }

    public init() { self.init(prefix: "") }

    /// The path its endpoints' paths are under: /orders.
    public var prefix: String {
        get { header }
        set { header = newValue }
    }
}

/// One endpoint of an API: a row, its id the API's own. What its line says (method, path, body, its first response, words no
/// part reads), and what only its card shows (name, summary, auth scope, path parameters' types, more responses, deprecated).
public struct Endpoint: SchemaDefined, Hashable, Sendable {
    public static let properties = Properties<Endpoint>(definition: "api-endpoint") {
        Property("id", \.id).required()
        Property("method", \.method).description("Its HTTP method, as written: GET, POST, PUT, PATCH, DELETE.")
        Property("path", \.path).description("Its path under the header above it (whole where there's none): /{id}/refunds.")
        Property("name", \.name).description("What it's called (OpenAPI's operationId): createRefund.")
        Property("summary", \.summary).description("What it does, in a line.")
        Property("authScope", \.authScope).description("The scope a client needs: orders:write.")
        Property("parameters", \.parameters).description("Its path parameters' types, by name.")
        Property("body", \.body).description("The type note its request's body is, by name.")
        Property("responses", \.responses).description("What it answers, by status, each with the type note its body is.")
        Property("deprecated", \.deprecated).description("Retired: still served, about to go.")
        Property("unread", \.unread).description("Words its line held that no part of an endpoint reads, kept as written.")
    }
    public var id: PartID
    public var method: String
    public var path: String
    public var name: String
    public var summary: String
    public var authScope: String
    public var parameters: [PathParameter]
    public var body: TypeRef?
    public var responses: [EndpointResponse]
    public var deprecated: Bool
    public var unread: String

    public init(id: PartID = PartID(), method: String, path: String, name: String = "", summary: String = "", authScope: String = "",
                parameters: [PathParameter] = [], body: TypeRef? = nil, responses: [EndpointResponse] = [], deprecated: Bool = false,
                unread: String = "") {
        self.id = id
        self.method = method
        self.path = path
        self.name = name
        self.summary = summary
        self.authScope = authScope
        self.parameters = parameters
        self.body = body
        self.responses = responses
        self.deprecated = deprecated
        self.unread = unread
    }

    public init() { self.init(method: "", path: "") }
}

/// Its body's and responses' types may name type notes, which a copy renames.
extension Endpoint: ShapeNaming {}

/// A path parameter's type: `{id}` is a uuid.
public struct PathParameter: SchemaDefined, Hashable, Sendable {
    public static let properties = Properties<PathParameter>(definition: "path-parameter") {
        Property("name", \.name).description("As the path writes it, without its braces: id.")
        Property("type", \.type).description("Its type, as written: uuid.")
    }
    public var name: String
    public var type: String

    public init(name: String, type: String) {
        self.name = name
        self.type = type
    }

    public init() { self.init(name: "", type: "") }
}

/// What an endpoint answers: a status, and the type note its body is.
public struct EndpointResponse: SchemaDefined, Hashable, Sendable {
    public static let properties = Properties<EndpointResponse>(definition: "endpoint-response") {
        Property("status", \.status).description("Its status, as written: 201, 404, 2XX, default.")
        Property("type", \.type).description("The type note its body is, by name; none for no body.")
    }
    public var status: String
    public var type: TypeRef?

    public init(status: String, type: TypeRef? = nil) {
        self.status = status
        self.type = type
    }

    public init() { self.init(status: "") }
}

extension EndpointResponse: ShapeNaming {}

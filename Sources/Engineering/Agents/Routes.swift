import Canvas
import Foundation

// What `:route("POST /orders/{id}/refunds")` asks of an API: an endpoint of that method and whole path. A path's parameters are
// told apart from its words, not by their names (`{id}` finds `{order_id}`), and a route with no method finds any method; an
// endpoint's whole path is its header's prefix and its own (`APIGroups.fullPath`), so a route never depends on how the API groups
// its rows. Pure, read off the main actor as a query is answered.

/// A route a query asks for: an HTTP method, or none for any, and a path's segments, each a word or a parameter.
public struct RoutePattern: Hashable, Sendable {
    /// A segment of a path: a word as written, or a parameter (`{id}`), whatever its name.
    public enum Segment: Hashable, Sendable {
        case word(String)
        case parameter
    }

    /// Upper case; nil for any method.
    public let method: String?
    public let segments: [Segment]

    /// The route `text` says: `POST /orders/{id}/refunds`, `/orders/{id}` (any method), `get orders` (a method in any case, a path
    /// with or without its leading slash). A query string or a trailing slash is no part of a route. Nil for no path at all.
    public init?(_ text: String) {
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        if let first = words.first, let method = EndpointGrammar.method(first) {
            self.method = method.uppercased()
            words.removeFirst()
        } else {
            method = nil
        }
        guard words.count == 1 else { return nil }
        let path = words[0].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        segments = Self.segments(of: path)
        guard !path.isEmpty else { return nil }
    }

    /// A path's segments, the slashes between them left out.
    static func segments(of path: String) -> [Segment] {
        path.split(separator: "/").map { segment in
            segment.hasPrefix("{") && segment.hasSuffix("}") && segment.count > 1 ? .parameter : .word(String(segment))
        }
    }

    /// Whether an endpoint of `method` at the whole path `path` is this route.
    public func matches(method other: String, path: String) -> Bool {
        if let method, method != other.uppercased() { return false }
        return Self.segments(of: path) == segments
    }

    /// The endpoints of `api` that are this route, by their whole names (`POST /orders/{id}/refunds`), in the API's order.
    public func routes(in api: API) -> [String] {
        var found: [String] = []
        for (index, row) in api.endpoints.enumerated() {
            guard let endpoint = row.endpoint else { continue }
            let path = APIGroups.fullPath(of: index, in: api.endpoints)
            if matches(method: endpoint.method, path: path) { found.append(APIGroups.fullName(method: endpoint.method, path: path)) }
        }
        return found
    }
}

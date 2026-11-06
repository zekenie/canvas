import Canvas
import CanvasRPC
import CoreGraphics
import DrawScript
import Foundation
import FuzzyMatching

// A program's document: the graph a producer writes (canvas-digest's `reference/graph.md`), every node with a key of the
// producer's own, the node that holds it (`in`), its kind and its properties as `canvas draw` takes them (`props`), and what
// the render layer reads (`layout`, which nothing here reads); every edge between two keys. With places (`place`: where each
// node's room goes, and an edge's pill) it is what `canvas apply` draws (`DocumentApply.swift`), and without them what
// `canvas measure` sizes (`DocumentMeasure.swift`). A value that names another shape (a type in `is`, a mention in a text)
// may name a node by its key. Read here, with nothing about kinds but what the registry says a kind holds.

/// A graph document, read.
struct DrawDocument {
    /// A node: its place in the list, its key, the key of the node that holds it, its kind and properties, and its place.
    struct Node {
        let index: Int
        let key: String
        let container: String?
        let kind: ShapeKind
        let props: JSONObject
        let place: Place?
    }

    /// Where a node goes: its room's top-left, from its frame's top-left or its board's origin, and its size.
    struct Place {
        let at: CGPoint?
        let size: CGSize?
    }

    /// An edge: its place in the list, its ends' keys, its own key if it has one, its properties and its pill.
    struct Edge {
        let index: Int
        let from: String
        let to: String
        let key: String?
        let props: JSONObject
        let pill: Pill?
    }

    /// The pill an edge goes through: one it makes, standing for `standsFor` (the end at `to` unless it says), at `at` from
    /// the top-left of the frame `container` names, else from its board's origin (or where the app puts one); or the one the
    /// edge of the node `share` names goes into, for the same end.
    struct Pill {
        let standsFor: String?
        let at: CGPoint?
        let container: String?
        let share: String?
    }

    let drawing: String?
    let nodes: [Node]
    let edges: [Edge]
    let byKey: [String: Int]

    func node(_ key: String) -> Node? { byKey[key].map { nodes[$0] } }
}

// MARK: Errors and answers

/// Why a document wasn't drawn or measured: said for a person, naming the producer's keys (or an edge by its place in the
/// list), the first problem as the error and every one in `refusals`. Nothing changed.
public struct DocumentError: Error, Equatable, CustomStringConvertible {
    /// One problem: what it's about (a node's key, or an edge by its place from 0), why, and what to do.
    public struct Refusal: Equatable, Encodable, Sendable {
        public let key: String?
        public let edge: Int?
        public let reason: String
        public let message: String
        public let hint: String?

        public init(key: String? = nil, edge: Int? = nil, reason: String, message: String, hint: String? = nil) {
            self.key = key
            self.edge = edge
            self.reason = reason
            self.message = message
            self.hint = hint
        }
    }

    public let refusals: [Refusal]

    public init(_ refusals: [Refusal]) {
        precondition(!refusals.isEmpty, "a document's error says what was wrong")
        self.refusals = Array(refusals.prefix(ScriptErrors.limit))
    }

    public init(key: String? = nil, edge: Int? = nil, reason: String, message: String, hint: String? = nil) {
        self.init([Refusal(key: key, edge: edge, reason: reason, message: message, hint: hint)])
    }

    public var first: Refusal { refusals[0] }
    public var reason: String { first.reason }
    public var message: String { first.message }
    public var hint: String? { first.hint }
    public var description: String { message }
}

/// What `apply` did (or, on a dry run, would do): a verdict for each node by its key, for each edge by its place, the
/// drawing's shapes it deleted, and what it should say.
public struct DocumentResult: Encodable, Sendable {
    public struct NodeVerdict: Encodable, Sendable {
        let key: String
        /// `created`, `updated` or `unchanged`.
        let did: String
        /// The shape's id; none on a dry run's `created`.
        let id: String?
        /// Where it is, `[[x, y], [width, height]]`, its room, world units, as a draw's row says.
        let at: CGRect?
        /// What a person had changed since the drawing last wrote it that this changed again: `moved`, `resized`, `frame`,
        /// or an attribute's name.
        let overrode: [String]?
        let problems: [JSONValue]?
    }

    public struct EdgeVerdict: Encodable, Sendable {
        let edge: Int
        let from: String
        let to: String
        let did: String
        let id: String?
        let via: String?
    }

    public struct Deleted: Encodable, Sendable {
        let key: String
        let id: String
    }

    public struct Warning: Encodable, Sendable {
        let key: String?
        let edge: Int?
        let message: String
        let severity: String
        let attribute: String?
    }

    let drawing: String
    let dryRun: Bool?
    var on: DrawBoardSaid?
    let nodes: [NodeVerdict]
    let edges: [EdgeVerdict]
    let deleted: [Deleted]
    let warnings: [Warning]

    enum CodingKeys: String, CodingKey { case drawing, dryRun, on, nodes, edges, deleted, warnings }
}

/// The board a document's top went on, as a draw's result says its board.
public struct DrawBoardSaid: Encodable, Sendable {
    let board: String
    let title: String?
}

// MARK: Reading

extension DrawDocument {
    /// Reads a document: JSON with `nodes` (each a `key`, a `kind` the registry draws, and, if it has them, `in`, `props`,
    /// `layout`, `place`) and `edges` (each a `from` and a `to`, and, if it has them, `key`, `props`, `layout`, `place`).
    /// Refuses, with every problem found, a document that isn't one: a key twice or blank, an `in` or an end that names no
    /// node, a node in one that holds nothing, a ring of `in`, a kind it doesn't know or can't draw, a place that isn't one.
    @MainActor
    init(parsing text: String, registry: Registry) throws(DocumentError) {
        let json: JSONValue
        do {
            json = try JSONValue(text: text)
        } catch {
            throw DocumentError(reason: "invalid_document", message: "the document isn't JSON: \(error.localizedDescription)",
                                hint: "a document is a JSON object with nodes and edges")
        }
        guard case .object(let root) = json else {
            throw DocumentError(reason: "invalid_document", message: "the document isn't a JSON object", hint: "a document is a JSON object with nodes and edges")
        }
        var refusals: [DocumentError.Refusal] = []
        func refuse(key: String? = nil, edge: Int? = nil, _ reason: String, _ message: String, hint: String? = nil) {
            refusals.append(DocumentError.Refusal(key: key, edge: edge, reason: reason, message: message, hint: hint))
        }
        var drawing: String?
        if let value = root["drawing"] {
            if let name = value.stringValue, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                drawing = name
            } else if value != .null {
                refuse("invalid_document", "drawing is the drawing's name, and \(value.compactText) isn't one", hint: "write \"drawing\": \"<name>\"")
            }
        }
        let drawable = Set(registry.kinds.filter { registry.placement(for: $0) != nil })
        let edgeKind = registry.drawEdging.flatMap { $0.kind(registry) }

        var nodes: [Node] = [], byKey: [String: Int] = [:]
        for (index, value) in (root["nodes"]?.arrayValue ?? []).enumerated() {
            guard case .object(let object) = value else {
                refuse("invalid_document", "nodes[\(index)] isn't an object", hint: "a node is {\"key\", \"kind\", \"in\", \"props\", \"layout\", \"place\"}")
                continue
            }
            guard let key = object["key"]?.stringValue, !key.isEmpty else {
                refuse("invalid_document", "nodes[\(index)] has no key", hint: "every node has a key of its own, a string, the same from run to run")
                continue
            }
            if let earlier = byKey[key] {
                refuse(key: key, "duplicate", "the key \(quoted(key)) is on two nodes (nodes[\(nodes[earlier].index)] and nodes[\(index)])",
                       hint: "a key names one node")
                continue
            }
            guard let word = object["kind"]?.stringValue else {
                refuse(key: key, "invalid_document", "\(quoted(key)) says no kind", hint: "every node has a kind canvas kinds lists")
                continue
            }
            let kind = ShapeKind(rawValue: word)
            if !registry.kinds.contains(kind) {
                let guesses = Suggestions.closest(to: word, among: drawable.map(\.rawValue).sorted(), limit: 1)
                refuse(key: key, ScriptError.Reason.unknownKind.rawValue, "\(quoted(key)): there's no kind of shape called \(word)",
                       hint: guesses.first.map { "did you mean \($0)? canvas kinds lists them" } ?? "canvas kinds lists the kinds")
                continue
            }
            if !drawable.contains(kind) || kind == edgeKind {
                refuse(key: key, ScriptError.Reason.unknownKind.rawValue, "\(quoted(key)): a document can't draw \(indefinite(kind))",
                       hint: "canvas kinds says which kinds can be drawn")
                continue
            }
            var container: String?
            if let inValue = object["in"], inValue != .null {
                guard let name = inValue.stringValue, !name.isEmpty else {
                    refuse(key: key, "invalid_document", "\(quoted(key)): in is the key of the node that holds it, and \(inValue.compactText) isn't one")
                    continue
                }
                container = name
            }
            var props: JSONObject = [:]
            if let value = object["props"], value != .null {
                guard case .object(let given) = value else {
                    refuse(key: key, "invalid_document", "\(quoted(key)): props is an object of attributes, as canvas kinds lists them")
                    continue
                }
                props = given
            }
            var place: Place?
            if let value = object["place"], value != .null {
                guard case .object(let given) = value else {
                    refuse(key: key, "invalid_document", "\(quoted(key)): place is {\"at\": [x, y], \"size\": [width, height]}")
                    continue
                }
                let at = Self.point(given["at"]), size = Self.size(given["size"])
                if given["at"] != nil, given["at"] != .null, at == nil {
                    refuse(key: key, "invalid_document", "\(quoted(key)): place's at is [x, y], two numbers")
                    continue
                }
                if given["size"] != nil, given["size"] != .null, size == nil {
                    refuse(key: key, "invalid_document", "\(quoted(key)): place's size is [width, height], two numbers over 0")
                    continue
                }
                place = Place(at: at, size: size)
            }
            byKey[key] = nodes.count
            nodes.append(Node(index: index, key: key, container: container, kind: kind, props: props, place: place))
        }
        if root["nodes"] != nil, root["nodes"]?.arrayValue == nil {
            refuse("invalid_document", "nodes is a list of nodes")
        }

        // What holds each node: a node whose kind holds shapes or a board, with no ring.
        let holders = registry.containingKinds.union(registry.boardOwningKinds)
        for node in nodes {
            guard let container = node.container else { continue }
            guard let holder = byKey[container].map({ nodes[$0] }) else {
                refuse(key: node.key, "unknown_key", "\(quoted(node.key)) is in \(quoted(container)), and no node has that key",
                       hint: "in is the key of a node of the document")
                continue
            }
            if !holders.contains(holder.kind) {
                refuse(key: node.key, ScriptError.Reason.cannotContain.rawValue,
                       "\(quoted(node.key)) is in \(quoted(container)), \(indefinite(holder.kind)), which holds no shapes",
                       hint: "in names a node whose kind holds shapes or a board (canvas kinds: holds)")
            }
        }
        for node in nodes {
            var seen: Set<String> = [node.key], at = node.container
            while let key = at, let next = byKey[key] {
                if seen.contains(key) {
                    // Only a node of the ring is in itself: one below it is in a node that is, and is said there.
                    if key == node.key {
                        refuse(key: node.key, ScriptError.Reason.circular.rawValue,
                               "\(quoted(node.key)) is in itself, through \(quoted(node.container ?? key))",
                               hint: "what holds a node can't be in it")
                    }
                    break
                }
                seen.insert(key)
                at = nodes[next].container
            }
        }

        var edges: [Edge] = []
        for (index, value) in (root["edges"]?.arrayValue ?? []).enumerated() {
            guard case .object(let object) = value else {
                refuse(edge: index, "invalid_document", "edges[\(index)] isn't an object")
                continue
            }
            guard let from = object["from"]?.stringValue, let to = object["to"]?.stringValue else {
                refuse(edge: index, "invalid_document", "edges[\(index)] has no from or to", hint: "an edge runs from one node's key to another's")
                continue
            }
            var missing = false
            for end in [from, to] where byKey[end] == nil {
                refuse(edge: index, "unknown_key", "edges[\(index)] runs \(end == from ? "from" : "to") \(quoted(end)), and no node has that key",
                       hint: "an edge's ends are keys of the document's nodes")
                missing = true
            }
            if missing { continue }
            var props: JSONObject = [:]
            if let value = object["props"], value != .null {
                guard case .object(let given) = value else {
                    refuse(edge: index, "invalid_document", "edges[\(index)]: props is an object of the arrow's attributes")
                    continue
                }
                props = given
            }
            var pill: Pill?
            if case .object(let place)? = object["place"], case .object(let given)? = place["pill"] {
                let standsFor = given["for"]?.stringValue, share = given["share"]?.stringValue
                if let standsFor, standsFor != from, standsFor != to {
                    refuse(edge: index, "invalid_document", "edges[\(index)]: a pill stands for one of its edge's ends, and \(quoted(standsFor)) is neither")
                    continue
                }
                if let share, byKey[share] == nil {
                    refuse(edge: index, "unknown_key", "edges[\(index)] shares the pill of \(quoted(share)), and no node has that key")
                    continue
                }
                let container = given["in"]?.stringValue
                if let container, byKey[container] == nil {
                    refuse(edge: index, "unknown_key", "edges[\(index)]'s pill is in \(quoted(container)), and no node has that key")
                    continue
                }
                if given["at"] != nil, given["at"] != .null, Self.point(given["at"]) == nil {
                    refuse(edge: index, "invalid_document", "edges[\(index)]: a pill's at is [x, y], two numbers")
                    continue
                }
                pill = Pill(standsFor: standsFor, at: Self.point(given["at"]), container: container, share: share)
            }
            edges.append(Edge(index: index, from: from, to: to, key: object["key"]?.stringValue, props: props, pill: pill))
        }
        guard refusals.isEmpty else { throw DocumentError(refusals) }
        self.drawing = drawing
        self.nodes = nodes
        self.edges = edges
        self.byKey = byKey
    }

    private static func point(_ value: JSONValue?) -> CGPoint? {
        guard let list = value?.arrayValue, list.count == 2, let x = list[0].numberValue, let y = list[1].numberValue, x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: x, y: y)
    }

    private static func size(_ value: JSONValue?) -> CGSize? {
        guard let list = value?.arrayValue, list.count == 2, let w = list[0].numberValue, let h = list[1].numberValue, w > 0, h > 0, w.isFinite, h.isFinite else { return nil }
        return CGSize(width: w, height: h)
    }
}

// MARK: Writing a statement

extension DrawDocument {
    /// A value as a script writes it after an attribute's key: a text quoted (only `\"`, `\\`, `\n` and `\t` escaped, a
    /// control character a space), a number, `true`, `false` or `null` as they are, a list or an object as JSON on one line;
    /// and, for an attribute whose type is text, a list or an object as its JSON text.
    static func literal(_ value: JSONValue, takesText: Bool) -> String {
        switch value {
        case .string(let text): return quotedLiteral(text)
        case .number, .bool, .null: return value.compactText
        case .array, .object:
            let json = jsonOnOneLine(value.compactText)
            return takesText ? quotedLiteral(json) : json
        }
    }

    /// A script is read a line a statement, and a line ends at any character Swift calls a newline: a text's line and
    /// paragraph separators (U+0085, U+2028, U+2029) are written as `\n`, a line break as it reads, and a control character as
    /// a space.
    static func quotedLiteral(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n", "\u{85}", "\u{2028}", "\u{2029}": out += "\\n"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(scalar.value < 32 ? " " : scalar)
            }
        }
        return out + "\""
    }

    /// JSON text with the separators JSON lets stand in a string (U+0085, U+2028, U+2029) as its escapes, so it is one line of a script.
    static func jsonOnOneLine(_ json: String) -> String {
        guard json.unicodeScalars.contains(where: { $0 == "\u{85}" || $0 == "\u{2028}" || $0 == "\u{2029}" }) else { return json }
        var out = ""
        for scalar in json.unicodeScalars {
            switch scalar {
            case "\u{85}": out += "\\u0085"
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}

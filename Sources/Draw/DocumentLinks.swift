import Canvas
import CanvasRPC
import DrawScript
import Foundation

// The links of a document between its notes, as `canvas measure --tightness` asks about them: every pair of nodes a link
// joins on one board, and what each node says (its title and its words), read from the document as written. Draw reads
// them and knows no embedding model: Automation asks one (`documentTightness`).

/// The pairs of nodes a document's links join, each on one board, and the nodes on those boards.
public struct DocumentLinks: Sendable {
    /// A node that isn't a container (a frame holds shapes; a subboard's card does not), on a board that has a pair.
    public struct Node: Sendable {
        public let key: String
        public let kind: ShapeKind
        /// The key of the node that owns its board; nil for the drawing's own.
        public let board: String?
        /// The title as the document wrote it: not folded, with no other property standing in for it. Nil without one.
        public let title: String?
        /// Its words: the first non-empty string among the properties its kind's schema says hold mention text (`text`
        /// first, then the others in code-unit order); empty with none.
        public let words: String
        public let props: JSONObject
    }

    /// Two distinct nodes a link joins, either way and however many, on one board: `a` before `b` in UTF-16 code-unit order.
    public struct Pair: Sendable {
        public let a: String
        public let b: String
        /// The key of the node that owns the board they are on; nil for the drawing's own.
        public let board: String?
    }

    /// Every node on a board that has at least one pair, by key in UTF-16 code-unit order.
    public let nodes: [Node]
    /// By `(a, b)` in UTF-16 code-unit order.
    public let pairs: [Pair]

    /// Reads `document`, a graph document, over `registry`'s kinds; refused as `canvas measure` refuses one it can't read.
    @MainActor
    public init(document text: String, registry: Registry) throws(DocumentError) {
        let document = try DrawDocument(parsing: text, registry: registry)
        let containers = registry.containingKinds
        let boards = Dictionary(uniqueKeysWithValues: document.nodes.map { ($0.key, document.board($0.key, in: registry)) })

        // The pairs: one for each two nodes joined, whichever way and however many edges; texts are told apart by their
        // UTF-8, as the rest of the engine tells them, and ordered by UTF-16 (Swift's `<` is neither).
        var seen: Set<[UInt8]> = []
        var found: [Pair] = []
        for edge in document.edges where edge.from != edge.to {
            guard let from = document.node(edge.from), let to = document.node(edge.to),
                  !containers.contains(from.kind), !containers.contains(to.kind), boards[edge.from] == boards[edge.to] else { continue }
            let (a, b) = Self.precedes(edge.from, edge.to) ? (edge.from, edge.to) : (edge.to, edge.from)
            guard seen.insert(Array((a + "\u{0}" + b).utf8)).inserted else { continue }
            found.append(Pair(a: a, b: b, board: boards[a] ?? nil))
        }
        found.sort { Self.precedes($0.a, $1.a) || (!Self.precedes($1.a, $0.a) && Self.precedes($0.b, $1.b)) }
        pairs = found

        let withPairs = Set<String?>(found.map(\.board))
        var vocabularies: [ShapeKind: [String]] = [:]
        var made: [Node] = []
        for node in document.nodes where !containers.contains(node.kind) {
            let board = boards[node.key] ?? nil
            guard withPairs.contains(board) else { continue }
            let keys = vocabularies[node.kind] ?? KindVocabulary(node.kind, in: registry).wordsKeys
            vocabularies[node.kind] = keys
            let words = keys.lazy.compactMap { node.props[$0]?.stringValue }.first { !$0.isEmpty } ?? ""
            made.append(Node(key: node.key, kind: node.kind, board: board, title: node.props[LanguageKey.title.rawValue]?.stringValue,
                             words: words, props: node.props))
        }
        made.sort { Self.precedes($0.key, $1.key) }
        nodes = made
    }

    /// `a` before `b` in UTF-16 code-unit order, the order a JavaScript string compares in (the digest tool's).
    public static func precedes(_ a: String, _ b: String) -> Bool { a.utf16.lexicographicallyPrecedes(b.utf16) }
}

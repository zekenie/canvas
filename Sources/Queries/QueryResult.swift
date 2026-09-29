import Canvas
import QueryLanguage
import Topology

// What a query is asked with, and what it answers: the shapes that match, in file order, as rows,
// with how many there are, what's worth saying about the answer, and what it cost. Rows are values,
// made off the main actor and read anywhere; the command line writes them as JSON.

/// A query to run (`QueryState.run(_:)`): its text, how many rows to list, whether to list any, and
/// which of each row's attributes to show.
public struct QueryRequest: Sendable, Equatable {
    /// Which attributes a row shows.
    public enum Properties: Sendable, Equatable {
        /// Every attribute the shape has, text cut at `QueryBudget.cut` characters (`cut` names those).
        case all
        /// None: `id`, `kind`, `title`, `board` and `inside` alone.
        case none
        /// Only these, whole.
        case only([String])
    }

    public var text: String
    /// The most rows listed, 1 to `QueryBudget.maxRows`; `count` is always of all.
    public var limit: Int
    /// Only how many match: no rows.
    public var countOnly: Bool
    public var properties: Properties

    public init(_ text: String, limit: Int = QueryBudget.rows, countOnly: Bool = false, properties: Properties = .all) {
        self.text = text
        self.limit = limit
        self.countOnly = countOnly
        self.properties = properties
    }
}

/// A query's answer: the query as the language writes it, how many shapes match, the first of them
/// as rows in file order, what's worth saying about it, and the board shown as it took up the file.
public struct QueryResult: Sendable {
    /// What ran, as the language writes it (`QueryPlan.canonical`).
    public var query: String
    /// How many shapes match, listed or not.
    public var count: Int
    /// The first `limit` of them, in file order; none when only counting.
    public var rows: [QueryRow]
    public var warnings: [QueryWarning]
    /// The board the window showed as the query took up the file (`:current-board`'s), and the
    /// boards from the root down to it: where it ran, which may not be where its request found the
    /// window, since a query may wait its turn, or for a model to write it.
    public var shown: BoardID
    public var shownPath: [BoardID]
    /// What it cost, on the main actor and off it.
    public var timings: QueryTimings

    public init(query: String, count: Int, rows: [QueryRow], warnings: [QueryWarning], shown: BoardID = .root, shownPath: [BoardID] = [.root],
                timings: QueryTimings = QueryTimings()) {
        self.query = query
        self.count = count
        self.rows = rows
        self.warnings = warnings
        self.shown = shown
        self.shownPath = shownPath
        self.timings = timings
    }
}

/// A shape that matched: its id (what a follow-up names it by, `#…`), kind, name, the board it's on
/// ("root" or its owner's id) and the names of the boards it's inside, outermost first, as the path
/// names them; its attributes as they read (own properties as encoded, added ones when set, text
/// through its format; none that says where it is, and not its name); which of them were cut; where
/// it runs, if it's a connection; and whether it's being typed into.
public struct QueryRow: Sendable, Equatable {
    public var id: ShapeID
    public var kind: ShapeKind
    /// Nil for an untitled shape.
    public var title: String?
    public var board: BoardID
    /// Empty on the top board.
    public var inside: [String]
    /// Nil when the request lists none.
    public var properties: JSONObject?
    /// The attributes cut at `QueryBudget.cut` characters, by name; nil for none.
    public var cut: [String]?
    public var connection: QueryConnection?
    /// True while it's being typed into; nil otherwise.
    public var editing: Bool?

    public init(id: ShapeID, kind: ShapeKind, title: String? = nil, board: BoardID = .root, inside: [String] = [],
                properties: JSONObject? = nil, cut: [String]? = nil, connection: QueryConnection? = nil, editing: Bool? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.board = board
        self.inside = inside
        self.properties = properties
        self.cut = cut
        self.connection = connection
        self.editing = editing
    }
}

/// Written as the command line shows it: what's absent (no title, inside nothing, no properties,
/// nothing cut, not a connection, not being typed into) is left out.
extension QueryRow: Encodable {
    private enum Key: String, CodingKey {
        case id, kind, title, board, inside, properties, cut, connection, editing
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encode(board, forKey: .board)
        if !inside.isEmpty { try container.encode(inside, forKey: .inside) }
        try container.encodeIfPresent(properties, forKey: .properties)
        try container.encodeIfPresent(cut, forKey: .cut)
        try container.encodeIfPresent(connection, forKey: .connection)
        try container.encodeIfPresent(editing, forKey: .editing)
    }
}

/// Where a connection (a shape that carries an edge itself, in slot `""`: an arrow) runs: its edge's
/// type, from the shape it starts on to the shape it ends on.
public struct QueryConnection: Sendable, Equatable, Encodable {
    public var type: EdgeTypeID
    public var from: QueryEnd
    public var to: QueryEnd

    public init(type: EdgeTypeID, from: QueryEnd, to: QueryEnd) {
        self.type = type
        self.from = from
        self.to = to
    }
}

/// An end of a connection: its shape's id, and its name if it has one.
public struct QueryEnd: Sendable, Equatable, Encodable {
    public var id: ShapeID
    public var title: String?

    public init(id: ShapeID, title: String? = nil) {
        self.id = id
        self.title = title
    }
}

/// Something worth saying about an answer that doesn't stop it: a reason to branch on, and a
/// message.
public struct QueryWarning: Sendable, Equatable, Encodable {
    /// Why: `limited`, `editing`, `no_title_match`; the command line adds its own (`--ask`'s).
    public struct Reason: RawRepresentable, Hashable, Sendable, Encodable, CustomStringConvertible {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public var description: String { rawValue }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }

        /// More shapes match than are listed.
        public static let limited = Reason(rawValue: "limited")
        /// A shape listed, or one whose text the query read, is being typed into: it's read as the
        /// board has it (a note's text as of its last keystroke), and may still change.
        public static let editing = Reason(rawValue: "editing")
        /// A name tested for with `=` (`[title="…"]`) is no shape's.
        public static let noTitleMatch = Reason(rawValue: "no_title_match")
    }

    public var reason: Reason
    public var message: String

    public init(_ reason: Reason, _ message: String) {
        self.reason = reason
        self.message = message
    }
}

/// What a query cost: thread CPU on the main actor (reading and resolving it, taking up the file,
/// and each slice) and off it (the evaluation's stretches between slices, summed), how many slices it
/// took, the longest, and the most one record a slice asked could have cost (the longest stretch
/// between two reads of a slice's clock: one record, or a few cheap ones).
public struct QueryTimings: Sendable, Equatable {
    public var main: Duration
    public var offMain: Duration
    public var slices: Int
    public var longestSlice: Duration
    public var costliestRecord: Duration

    public init(main: Duration = .zero, offMain: Duration = .zero, slices: Int = 0, longestSlice: Duration = .zero,
                costliestRecord: Duration = .zero) {
        self.main = main
        self.offMain = offMain
        self.slices = slices
        self.longestSlice = longestSlice
        self.costliestRecord = costliestRecord
    }
}

/// A named shape, for `--ask`'s titles: its name, id, kind, board, and the names of the boards it's
/// inside, outermost first.
public struct QueryTitle: Sendable, Equatable {
    public var title: String
    public var id: ShapeID
    public var kind: ShapeKind
    public var board: BoardID
    public var inside: [String]

    public init(title: String, id: ShapeID, kind: ShapeKind, board: BoardID, inside: [String]) {
        self.title = title
        self.id = id
        self.kind = kind
        self.board = board
        self.inside = inside
    }
}

/// Where the person is, for `--ask`: the board shown, the names of the boards on the way to it from
/// the top (none at the top), and what they have selected there, up to a limit, with how many that
/// is in all.
public struct QueryWhere: Sendable, Equatable {
    public var board: BoardID
    public var path: [String]
    public var selected: [QuerySelected]
    public var selectedCount: Int

    public init(board: BoardID, path: [String], selected: [QuerySelected], selectedCount: Int) {
        self.board = board
        self.path = path
        self.selected = selected
        self.selectedCount = selectedCount
    }
}

/// A selected shape: its id, kind and name, if it has one.
public struct QuerySelected: Sendable, Equatable {
    public var id: ShapeID
    public var kind: ShapeKind
    public var title: String?

    public init(id: ShapeID, kind: ShapeKind, title: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
    }
}

// MARK: Refusals the answer makes

extension QueryError {
    /// The query's task was cancelled (the command line gave up waiting, say).
    static var cancelledQuery: QueryError { QueryError(.cancelled, "The query was cancelled.") }
    /// Past `QueryBudget.deadline`.
    static var tooSlow: QueryError {
        QueryError(.tooSlow, "The query took more than 8 seconds.",
                   hint: "Start from a kind, a title or an id, or give transitive words a type.")
    }
    /// The editor went while the query ran.
    static var boardClosed: QueryError { QueryError(.boardClosed, "The board was closed before the command finished.") }
    /// No Topology: nothing says what a query ranges over.
    static var noTopology: QueryError {
        QueryError(.noTopology, "Nothing in this app knows what's on which board, or what's inside or connected to what.")
    }
}

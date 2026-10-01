/// Why a script can't be drawn: the line it's about, a message naming the statement in its own
/// words (its title, or "the card on line 3"; placements quoted back as written), and a hint when
/// there's a fix. The message is the problem; the hint, what to write instead.
public struct ScriptError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Every reason a draw can fail, as the command line reports it. This module gives some of
    /// them (parsing and placing); the caller the rest (kinds, titles, attributes, edges).
    public enum Reason: String, Sendable, CaseIterable {
        case syntax
        case unknownKind = "unknown_kind"
        case notPlaceable = "not_placeable"
        case unknownAttribute = "unknown_attribute"
        case invalidValue = "invalid_value"
        case duplicate
        case unknownTitle = "unknown_title"
        case ambiguousTitle = "ambiguous_title"
        case ambiguousEdge = "ambiguous_edge"
        case untitlable
        case renames
        case wrongKind = "wrong_kind"
        case readOnly = "read_only"
        case unplaced
        case unanchored
        case noRoom = "no_room"
        case circular
        case unordered
        case noChannel = "no_channel"
        case cannotConnect = "cannot_connect"
        case noEdges = "no_edges"
        case noNames = "no_names"
        case noView = "no_view"
        case unsupported
        case nothingToDelete = "nothing_to_delete"
        case busy
        case boardShown = "board_shown"
        case severalBoards = "several_boards"
        case cannotContain = "cannot_contain"
        case emptyScript = "empty_script"
        case `internal`
    }

    /// The line it's about, from 1; for two statements, the later.
    public var line: Int
    public var reason: Reason
    public var message: String
    public var hint: String?
    /// The line as written, comment stripped and trimmed, when the parser knew it (the solver
    /// knows lines only; the caller finds their text in `Script.statements`).
    public var statement: String?

    public init(line: Int, reason: Reason, _ message: String, hint: String? = nil, statement: String? = nil) {
        self.line = line
        self.reason = reason
        self.message = message
        self.hint = hint
        self.statement = statement
    }

    public var description: String {
        "line \(line): \(message)" + (hint.map { " (\($0))" } ?? "")
    }
}

/// What's wrong with a script's text: every line that couldn't be read, each once, in order, up to
/// `limit` of them. Errors that don't depend on one another are all worth fixing in one go.
public struct ScriptErrors: Error, Sendable, Equatable, CustomStringConvertible {
    /// At most this many are collected.
    public static let limit = 20

    /// In line order; never empty.
    public var errors: [ScriptError]

    public init(_ errors: [ScriptError]) {
        self.errors = errors
    }

    /// The one to lead with.
    public var first: ScriptError { errors[0] }

    public var description: String { errors.map(\.description).joined(separator: "\n") }
}

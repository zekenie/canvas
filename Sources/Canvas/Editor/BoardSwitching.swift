import Geometry

/// What showing another board changed (`editor.showBoard`), as services hear it
/// (`EditorService.boardDidChange`).
@MainActor
public struct BoardChange {
    /// The board shown before, and the one shown now.
    public let from: BoardID
    public let to: BoardID
    /// Where the camera was on the board left (where it was headed, if it was gliding): what a step
    /// back to that board returns to.
    public let leftCamera: Camera
    /// Whether a whole other file was put in place as it went (`replaceFile`: opening, reverting,
    /// reading it again after a change on disk). What a service keeps of each board by its revision
    /// is no longer taken back (every board that changed has a new one), but what it keeps across
    /// the file by shape id (a sync's state) it takes afresh.
    public let isFileReplaced: Bool
    private let cache: Cache

    init(from: BoardID, to: BoardID, leftCamera: Camera, left: CanvasDocument, shown: CanvasDocument, isFileReplaced: Bool = false) {
        self.from = from
        self.to = to
        self.leftCamera = leftCamera
        self.isFileReplaced = isFileReplaced
        cache = Cache(left: left, shown: shown)
    }

    /// The shown board's change as a commit's: every shape of the board left removed, every shape of
    /// the board shown added, and the stack changed. No two boards of a file share a shape, so
    /// nothing is compared; but a file put in place (`replaceFile`) may have a shape of the board left
    /// on the board it shows, and such a shape is changed, never both removed and added. Worked out
    /// the first time it's read, which costs both boards' shapes: a service that follows a switch
    /// per board never pays it.
    public var changes: ChangeSet { cache.changes }

    #if DEBUG
    /// Whether `changes` has been worked out (debug builds): what tests hold the switch's cost to.
    public var hasWorkedOutChanges: Bool { cache.worked != nil }
    #endif

    private final class Cache {
        let left: CanvasDocument
        let shown: CanvasDocument
        var worked: ChangeSet?

        init(left: CanvasDocument, shown: CanvasDocument) {
            self.left = left
            self.shown = shown
        }

        var changes: ChangeSet {
            if let worked { return worked }
            var changes = ChangeSet()
            changes.removed = Set(left.shapes.lazy.map(\.id))
            changes.added = Set(shown.shapes.lazy.map(\.id))
            let both = changes.removed.intersection(changes.added)
            if !both.isEmpty {
                changes.removed.subtract(both)
                changes.added.subtract(both)
                changes.changed = both
            }
            changes.reordered = true
            worked = changes
            return changes
        }
    }
}

/// A service's state for boards that aren't shown, kept for when they are again: what makes going
/// back to a board cost nothing. State is kept with the board's revision (`file.revision(of:)`) and
/// taken back only if the board hasn't changed since, so whatever changes a board while it's hidden,
/// nothing stale comes back. At most `limit` boards are kept; past that, the one kept longest ago
/// goes first, but boards on the path to the one shown (`editor.boardPath`) go last, since ⌘↑ and
/// the path go back to them.
///
/// Keep a board's state in `boardWillChange`, while it's still shown, and take the shown board's in
/// `boardDidChange`:
///
///     func boardWillChange(from old: BoardID, to new: BoardID, in editor: CanvasEditor) {
///         stash.keep(rows, for: old, in: editor)
///     }
///     func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
///         rows = stash.take(for: change.to, in: editor) ?? [:]
///     }
@MainActor
public struct BoardStash<State> {
    public let limit: Int
    private var kept: [BoardID: (state: State, revision: Int)] = [:]
    /// The boards kept, the one kept longest ago first.
    private var order: [BoardID] = []

    public init(limit: Int = 8) {
        precondition(limit > 0, "a stash keeps a board at least")
        self.limit = limit
    }

    /// The boards kept now.
    public var boards: Set<BoardID> { Set(order) }

    /// Keeps `state` for `board`, as the board is now, in place of what was kept for it.
    public mutating func keep(_ state: State, for board: BoardID, in editor: CanvasEditor) {
        kept[board] = (state, editor.file.revision(of: board))
        order.removeAll { $0 == board }
        order.append(board)
        evict(sparing: Set(editor.boardPath).union([board]))
    }

    /// What was kept for `board`, if the board hasn't changed since; either way it's no longer kept
    /// (keep it again when the board is left).
    public mutating func take(for board: BoardID, in editor: CanvasEditor) -> State? {
        defer { evict(sparing: Set(editor.boardPath)) }
        guard let entry = kept.removeValue(forKey: board) else { return nil }
        order.removeAll { $0 == board }
        return entry.revision == editor.file.revision(of: board) ? entry.state : nil
    }

    /// Changes what's kept for `board`, if anything is, as of the revision it was kept at: for what
    /// the state should do once it's taken back (check a shape again).
    public mutating func modify(_ board: BoardID, _ body: (inout State) -> Void) {
        guard kept[board] != nil else { return }
        body(&kept[board]!.state)
    }

    /// Changes what's kept for every board.
    public mutating func modifyAll(_ body: (inout State) -> Void) {
        for board in kept.keys { body(&kept[board]!.state) }
    }

    /// Forgets what's kept for these boards.
    public mutating func forget(_ boards: some Sequence<BoardID>) {
        for board in boards where kept.removeValue(forKey: board) != nil { order.removeAll { $0 == board } }
    }

    /// Forgets everything.
    public mutating func removeAll() {
        kept = [:]
        order = []
    }

    /// Down to `limit`: the board kept longest ago that isn't spared first, then the spared ones.
    private mutating func evict(sparing spared: Set<BoardID>) {
        while order.count > limit {
            let index = order.firstIndex { !spared.contains($0) } ?? 0
            kept[order.remove(at: index)] = nil
        }
    }
}

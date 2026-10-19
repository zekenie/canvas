import CanvasRPC
import CoreGraphics

/// What a step did to a file: on the board it was made on (`board`), shape by shape, each touched
/// shape's whole record before and after (nil: it wasn't there), its stacking key, metadata, added
/// and kept values included, opaque (kept aside) or not; and every other board it reached, whole
/// (`boards`: those a deletion took with the shapes that owned them, those a paste brought, those a
/// move took shapes onto, the root among them, those Delete Hidden Shapes deleted from), with the
/// entries of the file it couldn't read as boards that it took or replaced (`unreadableBoards`), and
/// the file's own values it changed (`fileValues`: `FileProperty`).
/// Undo puts the `before` side back (`inverted`), and redo the `after` one: `CanvasDocument.apply`
/// for the board's shapes, `CanvasFile.apply` for all of it.
///
/// It's the one type that holds a change's before and after, so what builds on them (an agent's
/// change, a change from another copy of the board) grows here.
public struct DocumentDelta: Equatable, Sendable {
    /// One shape's record before and after. Never both nil, and never equal.
    public struct Change: Equatable, Sendable {
        public let before: AnyShapeRecord?
        public let after: AnyShapeRecord?

        public init(before: AnyShapeRecord?, after: AnyShapeRecord?) {
            self.before = before
            self.after = after
        }
    }

    /// A board's shapes before and after, whole: empty where the file had no such board (a board
    /// with no shapes isn't kept). Never equal.
    public struct WholeBoard: Equatable, Sendable {
        public let before: CanvasDocument
        public let after: CanvasDocument

        public init(before: CanvasDocument, after: CanvasDocument) {
            self.before = before
            self.after = after
        }
    }

    /// An entry of the file's `unreadableBoards` before and after (nil: not there). Never equal.
    public struct UnreadableBoard: Equatable, Sendable {
        public let before: JSONValue?
        public let after: JSONValue?

        public init(before: JSONValue?, after: JSONValue?) {
            self.before = before
            self.after = after
        }
    }

    /// One of the file's values (`FileProperty`) before and after: nil where the file held none, so
    /// read the default. Never equal.
    public struct FileValue: Equatable, Sendable {
        let before: (any AddedValue)?
        let after: (any AddedValue)?

        init(before: (any AddedValue)?, after: (any AddedValue)?) {
            self.before = before
            self.after = after
        }

        /// A property's value before and after (a default is a value the file doesn't hold).
        public init<P: FileProperty>(_: P.Type, before: P.Value, after: P.Value) {
            self.init(before: before == P.defaultValue ? nil : Boxed(value: before), after: after == P.defaultValue ? nil : Boxed(value: after))
        }

        /// The property's value before the change: the default if the file held none, or if this isn't
        /// that property's change.
        public func before<P: FileProperty>(_: P.Type) -> P.Value { (before as? Boxed<P.Value>)?.value ?? P.defaultValue }
        /// The property's value after the change.
        public func after<P: FileProperty>(_: P.Type) -> P.Value { (after as? Boxed<P.Value>)?.value ?? P.defaultValue }

        public static func == (a: Self, b: Self) -> Bool { FileValues.same(a.before, b.before) && FileValues.same(a.after, b.after) }
    }

    /// The board the step was made on, whose shapes `changes` are: the one it's undone and redone on.
    public let board: BoardID
    public private(set) var changes: [ShapeID: Change]
    /// Every other board the step reached, whole, by its id: never `board`.
    public private(set) var boards: [BoardID: WholeBoard]
    /// The entries that didn't read as boards it took or replaced, by key.
    public private(set) var unreadableBoards: [String: UnreadableBoard]
    /// The file's values it changed (`FileProperty`), by key: the file's, whatever board the step
    /// was made on.
    public private(set) var fileValues: [PropertyKey: FileValue]

    /// Changes whose sides are equal are left out.
    public init(_ changes: [ShapeID: Change] = [:], on board: BoardID = .root, boards: [BoardID: WholeBoard] = [:],
                unreadableBoards: [String: UnreadableBoard] = [:], fileValues: [PropertyKey: FileValue] = [:]) {
        precondition(boards[board] == nil, "a delta's own board is changed shape by shape")
        self.board = board
        self.changes = changes.filter { $0.value.before != $0.value.after }
        self.boards = boards.filter { $0.value.before != $0.value.after }
        self.unreadableBoards = unreadableBoards.filter { $0.value.before != $0.value.after }
        self.fileValues = fileValues.filter { !FileValues.same($0.value.before, $0.value.after) }
    }

    public var isEmpty: Bool { changes.isEmpty && boards.isEmpty && unreadableBoards.isEmpty && fileValues.isEmpty }
    /// The shapes it changed on its board.
    public var shapeIDs: Set<ShapeID> { Set(changes.keys) }

    /// The same change the other way: each shape's `after` back to its `before`, each board's too.
    public var inverted: DocumentDelta {
        DocumentDelta(changes.mapValues { Change(before: $0.after, after: $0.before) }, on: board,
                      boards: boards.mapValues { WholeBoard(before: $0.after, after: $0.before) },
                      unreadableBoards: unreadableBoards.mapValues { UnreadableBoard(before: $0.after, after: $0.before) },
                      fileValues: fileValues.mapValues { FileValue(before: $0.after, after: $0.before) })
    }

    /// Collects a step as its commits happen: each shape's record from before the first commit that
    /// touched it (constant time per shape a commit names), and each other board as it was before
    /// the first commit that reached it (a copy that costs nothing: a board is a value); then, once
    /// the step is over, each one as it ends (`delta(now:)`), leaving out those that end where they
    /// began. A shape added and changed is added; added and deleted, not there; changed and changed
    /// back, not there; changed and deleted, deleted from what it first was. Boards likewise, and each
    /// of the file's values a commit names, from before the first that did.
    public struct Builder: Sendable {
        /// The board the step is made on.
        public let board: BoardID
        /// Each touched shape's first record before, nil if it wasn't there.
        private var before: [ShapeID: AnyShapeRecord?] = [:]
        /// Each other board reached, as it was before the first commit that reached it.
        private var boardsBefore: [BoardID: CanvasDocument] = [:]
        /// The file's entries that didn't read as boards, before the step's first commit.
        private var unreadableBefore: [String: JSONValue]?
        /// Each of the file's values a commit named, as the file held it before the first that did
        /// (`held` nil: it held none).
        private var fileValuesBefore: [PropertyKey: Held] = [:]

        private struct Held: Sendable {
            let held: (any AddedValue)?
        }

        public init(board: BoardID = .root) { self.board = board }

        /// A commit on the builder's board is about to take the file from `old` to what `changes`
        /// says: notes the record of each shape it names on the board, and each other board it names
        /// (`boardsAdded`, `boardsRemoved`, `boardsChanged`), and each of the file's values it names
        /// (`fileValues`), as no earlier commit did. (It takes the file, never the board alone, so no
        /// step can leave out the boards it reached.)
        public mutating func willCommit(_ changes: ChangeSet, from old: CanvasFile) {
            let document = old[board]
            for id in changes.shapeIDs where before.index(forKey: id) == nil { before[id] = .some(document[id]) }
            for other in changes.boardsReached where boardsBefore.index(forKey: other) == nil {
                precondition(other != board, "a commit reaches boards other than its own")
                boardsBefore[other] = old[other]
            }
            if unreadableBefore == nil { unreadableBefore = old.unreadableBoards }
            for key in changes.fileValues where fileValuesBefore.index(forKey: key) == nil {
                fileValuesBefore[key] = Held(held: old.fileValues[key])
            }
        }

        /// Whether a commit has reached `other` (noted it whole): a step that holds a board takes in
        /// whatever happens to it until it closes.
        public func holds(_ other: BoardID) -> Bool { boardsBefore.index(forKey: other) != nil }

        /// Whether any commit has touched a shape, reached a board or named one of the file's values.
        public var isHolding: Bool { !before.isEmpty || !boardsBefore.isEmpty || !fileValuesBefore.isEmpty }

        /// Whether `delta(now:)` would have a change: a touched shape's record, another board reached
        /// the entries that didn't read as boards or one of the file's values differ from their first.
        /// Stops at the first.
        public func hasChanges(now: CanvasFile) -> Bool {
            let document = now[board]
            return before.contains { id, first in first != document[id] }
                || boardsBefore.contains { other, first in first != now[other] }
                || unreadableBefore.map { $0 != now.unreadableBoards } == true
                || fileValuesBefore.contains { key, first in !FileValues.same(first.held, now.fileValues[key]) }
        }

        /// Every touched shape's first record and its record in `now`, those that differ, with each
        /// other board reached, the entries that didn't read as boards, and the file's values, that
        /// changed.
        public func delta(now: CanvasFile) -> DocumentDelta {
            var boards: [BoardID: WholeBoard] = [:]
            for (other, first) in boardsBefore { boards[other] = WholeBoard(before: first, after: now[other]) }
            var unreadable: [String: UnreadableBoard] = [:]
            if let unreadableBefore, unreadableBefore != now.unreadableBoards {
                for key in Set(unreadableBefore.keys).union(now.unreadableBoards.keys) {
                    unreadable[key] = UnreadableBoard(before: unreadableBefore[key], after: now.unreadableBoards[key])
                }
            }
            var values: [PropertyKey: FileValue] = [:]
            for (key, first) in fileValuesBefore { values[key] = FileValue(before: first.held, after: now.fileValues[key]) }
            return DocumentDelta(shapeChanges(now: now[board]), on: board, boards: boards, unreadableBoards: unreadable, fileValues: values)
        }

        private func shapeChanges(now: CanvasDocument) -> [ShapeID: Change] {
            var changes: [ShapeID: Change] = [:]
            for (id, first) in before {
                let last = now[id]
                if first != last { changes[id] = Change(before: first, after: last) }
            }
            return changes
        }
    }
}

extension ChangeSet {
    /// What applying `delta` does: shapes that come are added, those that go removed, the rest
    /// changed (props, metadata, added values or stacking key); the stack changed if a shape came,
    /// went or changed its key. A changed shape whose box moved, and nothing else, is `moved`, as a
    /// drag's commits say, so undoing or redoing a drag costs services what the drag did. A board
    /// that comes whole is added, one that goes removed, the rest changed, and the shapes that differ
    /// on them are `elsewhere`. The file's values it changes are `fileValues`.
    public init(_ delta: DocumentDelta) {
        self.init()
        fileValues = Set(delta.fileValues.keys)
        for (id, change) in delta.changes {
            switch (change.before, change.after) {
            case (nil, _?):
                added.insert(id)
                reordered = true
            case (_?, nil):
                removed.insert(id)
                reordered = true
            case (let before?, let after?):
                changed.insert(id)
                if before.stackingKey != after.stackingKey {
                    reordered = true
                } else if let from = before.box, let to = after.box, from.size == to.size, from.origin != to.origin {
                    var only = before
                    only.box?.origin = to.origin
                    if only == after { moved.insert(id) }
                }
            case (nil, nil):
                break
            }
        }
        for (board, change) in delta.boards {
            for record in change.after.shapes where change.before[record.id] != record { elsewhere.insert(record.id) }
            for record in change.before.shapes where change.after[record.id] == nil { elsewhere.insert(record.id) }
            if change.before.shapes.isEmpty {
                boardsAdded.insert(board)
            } else if change.after.shapes.isEmpty {
                boardsRemoved.insert(board)
            } else {
                boardsChanged.insert(board)
            }
        }
    }
}

/// What one commit did to the document, record by record: the shapes it added, changed (props,
/// or place in the stack) and removed. Services get it with `documentDidChange`, so what they keep
/// per shape can follow the few shapes a commit touched rather than go through every shape. What a
/// shape was before it is `before(_:)`, so a service that acts on a change of one value (a lock opened)
/// keeps no copy of it. The records before and after are a `DocumentDelta`'s (what undo keeps, other
/// boards whole). Who made the change is only whether an agent did (`byAgent`).
public struct ChangeSet: Equatable, Sendable {
    /// Shapes that weren't in the document before.
    public internal(set) var added: Set<ShapeID> = []
    /// Shapes that were there before and still are, with other props or another stacking key.
    public internal(set) var changed: Set<ShapeID> = []
    /// Those of `changed` that only moved: their box moved (`Transaction.moveBox`, which a drag and
    /// `translate` use), and nothing else in the commit changed them (their props but the box,
    /// their added values, their metadata or their place in the stack). What a service keeps of
    /// each shape that isn't about where it is (its schema checked, as Validation keeps it) still
    /// holds for these: a drag moves every shape it drags, on every event. Undoing or redoing a step
    /// names those whose box it only moves back or again (a drag's, undone).
    public internal(set) var moved: Set<ShapeID> = []
    /// Shapes that were there before and aren't now.
    public internal(set) var removed: Set<ShapeID> = []
    /// Whether the stack changed: a shape came, went, or moved in it.
    public internal(set) var reordered = false
    /// Whether the whole document was replaced (`replaceDocument`: a board read again, a revert, a
    /// reload after the file changed on disk) rather than edited: its shapes are as they were saved,
    /// not as anyone changed them, so a service that acts on edits (a sync) takes them as it takes
    /// shapes it sees for the first time.
    public internal(set) var replacedDocument = false
    /// Whether the commit put an undo step's records back (`editor.undo()` or `redo()`) rather than
    /// anyone changing them: its shapes are as they were before or after the step, so a service that
    /// acts on edits (a sync) follows none, and puts back what it kept of them as they were then (as
    /// an `UndoParticipant`).
    public internal(set) var restoredStep = false
    /// Whether an agent made the change (`Transaction.byAgent`: the command line's `draw`) rather
    /// than a person at the app: a service that acts on a person's edits (a sync that asks a
    /// language model) takes the shapes it changed as it takes shapes it sees for the first time.
    public internal(set) var byAgent = false
    /// Boards it brought into the file with the shapes that own them (`insert(_:contents:)`: a
    /// paste), or made for shapes it moved onto a board the file held none on
    /// (`Transaction.move(_:to:)`), and boards it took out of the file with theirs (every board under
    /// a deleted shape). Neither is the board the commit was on, whose shapes are the ones named above.
    public internal(set) var boardsAdded: Set<BoardID> = []
    public internal(set) var boardsRemoved: Set<BoardID> = []
    /// Boards it changed the shapes of while another was shown, keeping them in the file: Delete
    /// Hidden Shapes deleting what's kept aside on them, undo putting that back, a transaction on a
    /// board that isn't shown (`transact(on:)`), and the boards a transaction moved shapes onto that
    /// held shapes already (the root always), or settled shapes on (`Transaction.move(_:to:)`,
    /// `settle(_:on:)`).
    public internal(set) var boardsChanged: Set<BoardID> = []

    /// Every board it reached but its own: added, removed or changed.
    public var boardsReached: Set<BoardID> { boardsAdded.union(boardsRemoved).union(boardsChanged) }
    /// The shapes it touched on the boards it reached: every shape of a board it brought
    /// (`boardsAdded`) or took (`boardsRemoved`), and those it added, changed or removed on a board
    /// it changed (`boardsChanged`); for a whole file put in place over the board shown, those its
    /// other boards don't have as they were. None is a shape that stays on the board the commit was
    /// on (what moved off it is `removed` there, and here), so what a service keeps of that board's
    /// shapes needn't follow them, but what reads shapes anywhere in the file does: a row showing the
    /// name of a shape on another board, which went with the board its owner took.
    public internal(set) var elsewhere: Set<ShapeID> = []

    /// The file's values it changed (`FileProperty`, by key): a transaction's `setFileValue`, an undo
    /// or redo of one, and a file put in place (`replaceFile`) whose values differ. They are no
    /// shape's and no board's: a commit that changed nothing else names no shape and no board, and
    /// what reads a file value follows it here.
    public internal(set) var fileValues: Set<PropertyKey> = []

    /// Every shape the commit touched.
    public var shapeIDs: Set<ShapeID> { added.union(changed).union(removed) }

    /// The boards it changed as they were before it (the one it was on first), or the file before it, for `before(_:)`:
    /// none for a change set that isn't a commit's.
    var priors = Priors.none

    /// A shape's record as the commit found it, wherever in the file it was: a shape moved onto the board from
    /// another is found as it was there. Nil for a shape the commit brought into the file (one drawn or pasted, a
    /// board pasted), and for every shape of a change set that isn't a commit's (`init(elsewhere:)`). A service that
    /// keeps what follows from one value of a shape (whether it is locked) compares the record now with this, rather
    /// than keep a copy; one that keeps it per board passes over the shapes `added` there.
    public func before(_ id: ShapeID) -> AnyShapeRecord? { priors.record(id) }

    /// What a commit's shapes were before it: the boards it changed, as they were, or a file it replaced. No part of
    /// what a change set says, so any two are equal: a change set is compared by what it did.
    final class Priors: Sendable, Equatable {
        /// What a change set that isn't a commit's holds: nothing.
        static let none = Priors(boards: [])
        static func == (a: Priors, b: Priors) -> Bool { true }

        private let boards: [CanvasDocument]
        private let file: CanvasFile?

        /// Whether it holds what a commit found.
        var holdsRecords: Bool { file != nil || !boards.isEmpty }

        init(boards: [CanvasDocument]) {
            self.boards = boards
            file = nil
        }

        init(file: CanvasFile) {
            boards = []
            self.file = file
        }

        func record(_ id: ShapeID) -> AnyShapeRecord? {
            if let file { return file.record(id) }
            for board in boards { if let record = board[id] { return record } }
            return nil
        }
    }

    /// The shapes it added, or changed other than by moving them (`moved`, a part of `changed`, never added ones):
    /// those whose records say something they didn't. Nothing is worked out for a commit that only moved shapes
    /// (a drag's every event).
    public var edited: Set<ShapeID> {
        if added.isEmpty, changed.count == moved.count { return [] }
        return added.union(changed.subtracting(moved))
    }

    /// Whether it did nothing to shapes but move them on its board (a drag's every event, its undo): it added,
    /// removed and changed nothing else, reached no other board and put no document in place, so what follows
    /// from what shapes are, never where, is as it was. True of a commit that touched no shape (the file's values
    /// alone).
    public var onlyMoves: Bool {
        added.isEmpty && removed.isEmpty && changed == moved && elsewhere.isEmpty && boardsReached.isEmpty && !replacedDocument
    }

    /// From one document to another, compared record by record (`replaceDocument`).
    init(from old: CanvasDocument, to new: CanvasDocument) {
        for record in new.shapes {
            if let before = old[record.id] {
                if before != record { changed.insert(record.id) }
            } else {
                added.insert(record.id)
            }
        }
        for record in old.shapes where new[record.id] == nil { removed.insert(record.id) }
        reordered = old.shapes.map(\.id) != new.shapes.map(\.id)
        replacedDocument = true
        priors = Priors(boards: [old])
    }

    init() {}

    /// The part of it that is about `ids`: those of the shapes it added, changed, moved, removed and reached
    /// elsewhere that are among them, and nothing else of it. For asking of a few of a transaction's writes what is
    /// asked of them all (which statement of a run reached a shape: `Transaction.pending`).
    public func restricted(to ids: Set<ShapeID>) -> ChangeSet {
        var part = ChangeSet()
        part.added = added.intersection(ids)
        part.changed = changed.intersection(ids)
        part.moved = moved.intersection(ids)
        part.removed = removed.intersection(ids)
        part.elsewhere = elsewhere.intersection(ids)
        part.byAgent = byAgent
        part.priors = priors
        return part
    }

    /// Only shapes elsewhere: what changed on other boards while a board wasn't shown, which a
    /// service that kept what it knew of that board hands, on going back to it, to what reads other
    /// shapes (the table of contents' rows, through their `affected`).
    public init(elsewhere: Set<ShapeID>) {
        self.elsewhere = elsewhere
    }
}

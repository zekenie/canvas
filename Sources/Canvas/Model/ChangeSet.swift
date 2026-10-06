/// What one commit did to the document, record by record: the shapes it added, changed (props,
/// or place in the stack) and removed. Services get it with `documentDidChange`, so what they keep
/// per shape can follow the few shapes a commit touched rather than go through every shape. The
/// records before and after are a `DocumentDelta`'s (what undo keeps, other boards whole). Who made
/// the change is only whether an agent did (`byAgent`).
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

    /// Every shape the commit touched.
    public var shapeIDs: Set<ShapeID> { added.union(changed).union(removed) }

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
    }

    init() {}

    /// Only shapes elsewhere: what changed on other boards while a board wasn't shown, which a
    /// service that kept what it knew of that board hands, on going back to it, to what reads other
    /// shapes (the table of contents' rows, through their `affected`).
    public init(elsewhere: Set<ShapeID>) {
        self.elsewhere = elsewhere
    }
}

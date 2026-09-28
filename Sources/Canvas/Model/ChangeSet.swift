/// What one commit did to the document, record by record: the shapes it added, changed (props,
/// or place in the stack) and removed. Services get it with `documentDidChange`, so what they keep
/// per shape can follow the few shapes a commit touched rather than go through every shape. The
/// records before and after are a `DocumentDelta`'s (what undo keeps); who made the change comes
/// with agents.
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
}

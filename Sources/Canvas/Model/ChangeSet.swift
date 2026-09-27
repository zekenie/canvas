/// What one commit did to the document, record by record: the shapes it added, changed (props,
/// or place in the stack) and removed. Services get it with `documentDidChange`, so what they keep
/// per shape can follow the few shapes a commit touched rather than go through every shape. (Who
/// made the change, and the records before and after, come with undo and agents.)
public struct ChangeSet: Equatable, Sendable {
    /// Shapes that weren't in the document before.
    public internal(set) var added: Set<ShapeID> = []
    /// Shapes that were there before and still are, with other props or another stacking key.
    public internal(set) var changed: Set<ShapeID> = []
    /// Shapes that were there before and aren't now.
    public internal(set) var removed: Set<ShapeID> = []
    /// Whether the stack changed: a shape came, went, or moved in it.
    public internal(set) var reordered = false

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
    }

    init() {}
}

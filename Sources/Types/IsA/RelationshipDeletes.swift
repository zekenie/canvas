import Canvas

// What deleting a relationship type takes with it: its end arrows, in the delete's own step, except a locked one.
//
// A relationship type is a note that says what an arrow between two types means, and its end arrows are the arrows drawn
// between it and the types it relates; once it is gone they run from a type to nothing and say nothing, so they go with it
// (a deviation from tldraw, where an arrow outlives the shape it is bound to; `arrows.md`). A `willDelete` handler runs
// inside the delete's cascade, where the core's refusal checks are off, so the handler itself leaves a locked end arrow:
// it stays, freed from the relationship type where it was drawn, and the check calls it a loose end. The delete of the type
// is never refused. The rows, the pills and everything else a type's delete changes are the index's to follow.

@MainActor
enum RelationshipDeletes {
    /// Deletes the end arrows of each relationship type in `ids`, wherever they are, but a locked one. The cheapest test
    /// first: a delete of shapes that are no relationship type costs one added-value lookup an id, and reads no service.
    /// The arrows are the index's and those on the type's own board, as the transaction leaves them
    /// (`endArrows(of:reading:)`), so an end freed earlier goes too and one drawn in this transaction does.
    static func run(_ ids: Set<ShapeID>, _ transaction: inout Transaction) {
        var types: [ShapeID] = []
        for id in ids where transaction.document[id]?[RelationshipProperty.self] == true { types.append(id) }
        guard !types.isEmpty, let index = transaction.shapes.service(RelationshipIndex.self) else { return }
        #if DEBUG
        RelationshipIndex.endDeletes += 1
        #endif
        var arrows: Set<ShapeID> = []
        for type in types {
            for arrow in index.endArrows(of: type, reading: transaction) where !ids.contains(arrow) && !index.isLocked(arrow) { arrows.insert(arrow) }
        }
        guard !arrows.isEmpty else { return }
        // On whichever boards they are: the deepest first, as the core orders it.
        transaction.delete(inFile: arrows)
    }
}

/// Registers the handler: Types' `register` calls it.
@MainActor
func registerRelationshipDeletes(into registrar: inout PluginRegistrar) {
    registrar.willDelete { ids, transaction in RelationshipDeletes.run(ids, &transaction) }
}

extension RelationshipIndex {
    /// Whether the arrow can't change as the file stands (a lock on it, on a frame that holds it, or on the board it is
    /// on): what a delete's cascade, which refuses nothing, must ask for itself.
    func isLocked(_ arrow: ShapeID) -> Bool { editor?.isReadOnly(inFile: arrow) ?? false }
}

import Canvas

/// What an arrow is by its two end records alone: one statement of "an end joins a marked type and an
/// unmarked type". It needs no graph, so the release reads it and so does a run of `canvas draw` that has
/// written types the file does not hold yet.
///
/// A type here is a shape that holds `schema` (its kind can be one), a relationship type one that holds the
/// mark too. A pill is no type, whatever it stands for: reading through one is the index's
/// (`RelationshipIndex.reading(ofEnd:)`).
public enum ArrowRole: Sendable, Hashable {
    /// A relationship type at one end, an unmarked type at the other: an end of that relationship type on
    /// that side (a type to a relationship type is `from`, a relationship type to a type is `to`).
    case end(type: ShapeID, side: RelationshipSide)
    /// Two unmarked types: a plain arrow.
    case betweenTypes
    /// Two relationship types: a plain arrow.
    case betweenRelationshipTypes
    /// A relationship type at one end and no type at the other: a plain arrow, nothing is judged.
    case endAtNonType(type: ShapeID)
    /// Neither end is a relationship type, and not both are types: notes, or a type and a note.
    case notes

    @MainActor
    public static func of(from: AnyShapeRecord?, to: AnyShapeRecord?, registry: Registry) -> ArrowRole {
        func isType(_ record: AnyShapeRecord?) -> Bool {
            guard let record else { return false }
            return registry.canBeType(record.kind) && record[TypeSchemaProperty.self] != nil
        }
        func isMarked(_ record: AnyShapeRecord?) -> Bool {
            guard let record, isType(record) else { return false }
            return registry.canBeRelationshipType(record.kind) && record[RelationshipProperty.self] == true
        }
        // An end that is not bound says nothing of what the arrow is.
        guard let from, let to else { return .notes }
        let start = (isType(from), isMarked(from)), end = (isType(to), isMarked(to))
        switch (start, end) {
        case ((true, false), (true, false)): return .betweenTypes
        case ((true, true), (true, true)): return .betweenRelationshipTypes
        case ((true, false), (true, true)): return .end(type: to.id, side: .from)
        case ((true, true), (true, false)): return .end(type: from.id, side: .to)
        case ((true, true), (false, _)): return .endAtNonType(type: from.id)
        case ((false, _), (true, true)): return .endAtNonType(type: to.id)
        default: break
        }
        return .notes
    }
}

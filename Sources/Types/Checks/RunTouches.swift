import Canvas
import Titles
import Topology

// What a run's writes reach, in Types: the shapes whose values' or relationships' issues writes that have not
// committed may change though they do not change them, for Validation's rule (`touches`, asked by a run that warns
// of what it breaks on shapes it did not write). The committed fan-out is `TypeIndex.onChange` and
// `RelationshipIndex`'s "what the change names", told after a commit; this is the same reach before one, read from the
// committed index, the reading's records and the run's own graph. It may name a shape whose issues stay as they were
// (whoever asks compares the check before and after) and must never miss one. It costs what the run wrote and what
// that reaches: an arrow that is no relationship and no end before or after costs its record and names nothing.

@MainActor
enum RunTouches {
    static func touched(by changes: ChangeSet, reading: LayoutReading) -> Set<ShapeID> {
        guard !reading.isCommitted, let index = reading.service(TypeIndex.self), let relationships = reading.service(RelationshipIndex.self),
              let checks = reading.service(FieldChecks.self), let editor = relationships.editor else { return [] }
        let registry = reading.registry
        let before = relationships.graph, after = relationships.graph(in: reading)
        // Whether a relationship type is committed or written: without one no arrow is a relationship or an end.
        let live = !before.types.relationshipTypes.isEmpty || !after.types.relationshipTypes.isEmpty
        let standIns = relationships.standIns, pillKinds = relationships.standInKinds
        var found: Set<ShapeID> = []
        // Types whose text, name, own list, mark or being a type moved; and of them, those whose notes read their
        // rows and their fit from another place now (a lineage or a membership change).
        var types: Set<ShapeID> = [], chains: Set<ShapeID> = []
        // Whether the writes asked of are any that a relationship type is compiled from (a type, or an arrow at one): only then
        // can a type the run compiled again be theirs. A statement that writes neither reaches nothing through it, so asked
        // of each statement alone, as a run finds the line of a warning, the whole run's compiling is not walked for each.
        var compiles = false

        func isType(_ record: AnyShapeRecord?) -> Bool {
            guard let record else { return false }
            return registry.canBeType(record.kind) && record[TypeSchemaProperty.self] != nil
        }
        func list(_ record: AnyShapeRecord?) -> [ShapeID] { record?[IsAProperty.self]?.map(\.shape) ?? [] }
        // A pill counts as the type it names at an end.
        func isTypeNow(_ id: ShapeID) -> Bool {
            if index.isType(id) { return true }
            guard let record = reading.shape(inFile: id) else { return false }
            return isType(record) || pillKinds.contains(record.kind)
        }
        func runsToType(_ record: AnyShapeRecord?) -> Bool {
            guard let record else { return false }
            return registry.edges(of: record).contains { $0.isConnection && (isTypeNow($0.source) || isTypeNow($0.target)) }
        }
        // What each end names if it is a pill, read once: a run of many relationships between a few notes asks of the
        // same ends over and over.
        var namedNow: [ShapeID: [ShapeID]] = [:], namedBefore: [ShapeID: [ShapeID]] = [:]
        func atEnds(of connection: AnyShapeRecord, committed: Bool) -> Set<ShapeID> {
            relationships.shapesAtEnds(of: connection) { end in
                if committed {
                    if let kept = namedBefore[end] { return kept }
                    let named = relationships.shapesNamed(by: editor.shape(inFile: end))
                    namedBefore[end] = named
                    return named
                }
                if let kept = namedNow[end] { return kept }
                let named = relationships.shapesNamed(by: reading.shape(inFile: end))
                namedNow[end] = named
                return named
            }
        }

        func look(_ id: ShapeID, isNew: Bool) {
            let now = reading.shape(inFile: id)
            if let now, registry.relates(now.kind), !live, !registry.canBeType(now.kind) { return }
            let was = isNew ? nil : editor.shape(inFile: id)
            guard let kind = (now ?? was)?.kind else { return }

            if registry.relates(kind) {
                guard live else { return }
                if !compiles, runsToType(was) || runsToType(now) { compiles = true }
                // A relationship drawn, deleted, re-aimed or retyped: the notes at its ends, as they were and as they are.
                // An end's own change is the run's graph's (below).
                if let was, list(was).contains(where: before.types.relationshipTypes.contains) {
                    found.formUnion(atEnds(of: was, committed: true))
                }
                if let now, list(now).contains(where: after.types.relationshipTypes.contains) {
                    found.formUnion(atEnds(of: now, committed: false))
                }
                if !registry.canBeType(kind) { return }
            }

            // A type that came, went or changed: its instances and the types that refer to it check their values again.
            let wasType = index.isType(id), nowType = isType(now)
            if wasType || nowType { compiles = true }
            var reads = false
            if wasType || nowType {
                let marked = now?[RelationshipProperty.self] == true, wasMarked = was?[RelationshipProperty.self] == true
                let parents = list(was) != list(now)
                if wasType != nowType || parents || marked != wasMarked || was?[TypeSchemaProperty.self]?.text != now?[TypeSchemaProperty.self]?.text
                    || was.flatMap({ registry.title(of: $0) }) != now.flatMap({ registry.title(of: $0) }) {
                    types.insert(id)
                }
                if wasType != nowType || parents { chains.insert(id) }
                reads = wasType != nowType || marked != wasMarked
            } else if list(was) != list(now) {
                // A shape that is no type and that notes still list (a type taken away): the chain runs through it.
                if index.hasInstances(id) { chains.insert(id) }
                reads = true
            }
            // What the arrows drawn at the shape run to, or are, is another thing now: it came or went, as a shape or as a
            // type, its own types changed, a pill names it or it is one, or a pill may or may not stand for it any more.
            let isPill = pillKinds.contains(kind)
            if isPill { compiles = true }
            if !reads { reads = now == nil || was == nil || isPill }
            if !reads, !pillKinds.isEmpty, let was, let now {
                reads = pillKinds.contains { standIns.admits($0, was) != standIns.admits($0, now) }
            }
            if reads {
                let arrows = relationships.arrows(at: id, in: reading)
                found.formUnion(arrows)
                if isPill {
                    // And the notes it stood for and stands for: a relationship into the pill is theirs.
                    found.formUnion(relationships.shapesNamed(by: was))
                    found.formUnion(relationships.shapesNamed(by: now))
                    for arrow in arrows {
                        if let record = reading.shape(inFile: arrow) { found.formUnion(atEnds(of: record, committed: false)) }
                    }
                }
            }
            // A sentence that quotes the shape by its label says another now.
            found.formUnion(checks.arrowsQuoting(id))
        }

        for id in changes.added { look(id, isNew: true) }
        for id in changes.changed where !changes.moved.contains(id) { look(id, isNew: false) }
        for id in changes.removed { look(id, isNew: false) }
        for id in changes.elsewhere { look(id, isNew: false) }

        if !types.isEmpty {
            found.formUnion(checks.reached(byTypes: types))
            found.formUnion(checks.shapesNamingATitle)
        }
        if !chains.isEmpty {
            // Their instances, near and far, read rows from another place, and the arrows at each fit by another lineage.
            let reached = index.affected(by: chains)
            found.formUnion(reached)
            if live {
                for note in reached where !index.isType(note) {
                    found.formUnion(relationships.arrows(at: note, in: reading))
                    // An arrow of a relationship type whose lineage moved: the notes at its ends count it in other rows.
                    if let record = reading.shape(inFile: note), registry.relates(record.kind) { found.formUnion(atEnds(of: record, committed: false)) }
                }
            }
        }

        // The relationship types the run compiled again: where the ruled rows of an end type's notes differ, its notes,
        // near and far; where the types at its ends or its mark differ, its arrows, and for the mark the notes at their ends
        // (a relationship is an arrow of a marked type).
        if live && compiles {
            for type in relationships.relationshipTypesCompiled(in: reading) {
                let old = before.ends.sides[type], new = after.ends.sides[type]
                let ends = Set((old?.from ?? []).map(\.type) + (old?.to ?? []).map(\.type) + (new?.from ?? []).map(\.type) + (new?.to ?? []).map(\.type))
                for end in ends where before.ends.rows[end] != after.ends.rows[end] {
                    for note in index.affected(by: [end]) where !index.isType(note) { found.insert(note) }
                }
                let flipped = before.types.relationshipTypes.contains(type) != after.types.relationshipTypes.contains(type)
                guard flipped || places(old) != places(new) else { continue }
                // Its arrows, and those of the relationship types built on it that read a side from it.
                for arrow in index.allInstances(of: type) {
                    found.insert(arrow)
                    guard flipped, let record = reading.shape(inFile: arrow) else { continue }
                    found.formUnion(atEnds(of: record, committed: false))
                }
                if flipped { found.formUnion(relationships.arrows(at: type, in: reading)) }
            }
        }
        return found
    }

    /// The types at a relationship type's ends, by side and arrow: what the fit of its arrows is judged against.
    private static func places(_ sides: RelationshipSides?) -> [[ShapeID]] {
        guard let sides else { return [] }
        return RelationshipSide.allCases.flatMap { side in sides[side].map { [$0.type, $0.carrier] } }
    }
}

extension FieldChecks {
    /// The shapes, on any board of the file, whose issues the rule over values and relationships may find differently
    /// once `changes` (writes that have not committed: a transaction's `pending`) are in, though they are not among the
    /// shapes written: Validation's `touches` for Types' rules. `reading` is the file as the writer has it.
    public static func touched(by changes: ChangeSet, reading: LayoutReading) -> Set<ShapeID> {
        RunTouches.touched(by: changes, reading: reading)
    }
}

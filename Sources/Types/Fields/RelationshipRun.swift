import Canvas
import Foundation
import Mentions
import Titles
import Topology

// A run's own graph: what a script that has not committed yet says of relationships. A transaction's end
// arrows and types are in its records, not in `RelationshipIndex` (which keeps the committed file), so a
// run that draws a relationship type, its ends and the notes together would be judged against a graph that
// has none of them. `RunGraph` is the committed graph with what the run wrote put back, kept up as the run
// goes on: it applies the entries of the reading's log (`LayoutReading.changes`) since it last read, so a run
// of n shapes written one at a time costs n applications. With no relationship type committed, and none
// written, it applies nothing and the committed graph is the answer.

/// What an arrow is an end of: the relationship type, the side, and the type at its other end.
struct EndClassification: Equatable {
    var type: ShapeID
    var side: RelationshipSide
    var other: ShapeID
}

@MainActor
final class RunGraph {
    /// Unowned: the editor owns the index that keeps this, which must not keep the editor alive.
    private unowned let editor: CanvasEditor
    private let registry: Registry
    private let committed: RelationshipGraph
    private let relatingKinds: Set<ShapeKind>
    private let standInKinds: Set<ShapeKind>

    /// The reading's log this follows (`LayoutReading.runID`) and the commit it was made over.
    let runID: Int
    let revision: Int
    private(set) var cursor = 0
    /// Whether a relationship type is committed or written: until it is, nothing here is kept.
    private(set) var isLive: Bool

    private var types: TypeGraph
    private var ends: RelationshipEnds
    /// What each arrow the run has read is an end of now (`nil`: none), as against the committed index's.
    private var examined: [ShapeID: EndClassification?] = [:]
    /// The arrows examined, in the order they were first.
    private var examinedOrder: [ShapeID] = []
    /// The relating arrows the run wrote, by the shapes they run between (each end as the arrow names it).
    private var written: [ShapeID: Set<ShapeID>] = [:]
    private var endsOf: [ShapeID: [ShapeID]] = [:]
    /// The pills the run wrote, by the shapes they name, and the other way.
    private var pillsNaming: [ShapeID: Set<ShapeID>] = [:]
    private var pillTargets: [ShapeID: [ShapeID]] = [:]
    private var dirty: Set<ShapeID> = []
    private var dirtyEndTypes: Set<ShapeID> = []
    /// The rows each relationship type compiled again in the run gives the types at its ends, kept for the run.
    private var contributions: [ShapeID: [ShapeID: [RelationshipRow]]] = [:]
    /// Every relationship type the run has compiled again so far (it, its mark or one of its ends was written, or a
    /// type at one of its ends came or went): what a run's writes may have changed the ends of (`RunTouches`).
    private(set) var recompiled: Set<ShapeID> = []

    init(editor: CanvasEditor, runID: Int) {
        let registry = editor.registry
        self.editor = editor
        self.registry = registry
        committed = editor.relationships?.graph ?? RelationshipGraph(types: TypeGraph(), ends: RelationshipEnds())
        relatingKinds = Set(registry.kinds.filter { registry.relates($0) })
        standInKinds = registry.standIns.kinds
        self.runID = runID
        revision = editor.revision
        types = committed.types
        ends = committed.ends
        isLive = !committed.types.relationshipTypes.isEmpty
    }

    /// The graph with the entries of `reading`'s log read, from where this stopped.
    func graph(for reading: LayoutReading) -> RelationshipGraph {
        let log = reading.changes
        while cursor < log.count {
            if isLive {
                apply(log[cursor], in: reading)
                cursor += 1
            } else if wouldMakeLive(log[cursor], in: reading) {
                // Everything before it was passed over: read it all, now that it matters.
                isLive = true
                cursor = 0
            } else {
                cursor += 1
            }
        }
        guard isLive else { return committed }
        recompile(in: reading)
        return RelationshipGraph(types: types, ends: ends)
    }

    /// Whether an entry makes a relationship type: one written that holds the mark on a type, or one that was.
    private func wouldMakeLive(_ id: ShapeID, in reading: LayoutReading) -> Bool {
        guard let record = reading.shape(inFile: id) else { return committed.types.relationshipTypes.contains(id) }
        return record[RelationshipProperty.self] == true && registry.canBeType(record.kind) && record[TypeSchemaProperty.self] != nil
    }

    // MARK: Applying an entry

    private func apply(_ id: ShapeID, in reading: LayoutReading) {
        #if DEBUG
        editor.relationships?.runApplications += 1
        #endif
        let record = reading.shape(inFile: id)
        let wasType = types.types.contains(id), wasMarked = types.relationshipTypes.contains(id)
        var isMarked = false, isType = false
        if let record, registry.canBeType(record.kind), record[TypeSchemaProperty.self] != nil {
            isType = true
            types.types.insert(id)
            types.names[id] = registry.title(of: record)
            isMarked = record[RelationshipProperty.self] == true
            if isMarked { types.relationshipTypes.insert(id) } else { types.relationshipTypes.remove(id) }
        } else {
            types.types.remove(id)
            types.names[id] = nil
            types.relationshipTypes.remove(id)
        }
        if let record, registry.isTypeable(record.kind) {
            let list = TypeIndex.links(of: record)
            types.links[id] = list.isEmpty ? nil : list
        } else if record == nil {
            types.links[id] = nil
        }
        if isMarked || wasMarked { dirty.insert(id) }
        // A relationship type, or a type, that came or went: the arrows at it are ends, or are not.
        if isMarked != wasMarked || isType != wasType { examineArrows(at: id, in: reading) }
        // The arrow itself.
        if let record, relatingKinds.contains(record.kind) {
            setEnds(of: id, record)
            examine(id, in: reading)
        } else if endsOf[id] != nil || examined[id] != nil || editor.relationships?.end(id) != nil {
            setEnds(of: id, nil)
            examine(id, in: reading)
        }
        // A pill, or a shape gone: the arrows at it read it again.
        let isPill = record.map { standInKinds.contains($0.kind) } ?? false
        if isPill { setNamed(by: id, record) } else if pillTargets[id] != nil { setNamed(by: id, nil) }
        if record == nil || isPill { examineArrows(at: id, in: reading) }
    }

    /// The shape a pill the run wrote names, so the arrows at the pill are found from the shape.
    private func setNamed(by pill: ShapeID, _ record: AnyShapeRecord?) {
        for target in pillTargets[pill] ?? [] {
            pillsNaming[target]?.remove(pill)
            if pillsNaming[target]?.isEmpty == true { pillsNaming[target] = nil }
        }
        var targets: [ShapeID] = []
        if let record, case .shapes(let named)? = registry.standIns.forwarding(of: record) { targets = Array(Set(named)) }
        pillTargets[pill] = targets.isEmpty ? nil : targets
        for target in targets { pillsNaming[target, default: []].insert(pill) }
    }

    private func setEnds(of arrow: ShapeID, _ record: AnyShapeRecord?) {
        for end in endsOf[arrow] ?? [] {
            written[end]?.remove(arrow)
            if written[end]?.isEmpty == true { written[end] = nil }
        }
        guard let record, let edge = registry.edges(of: record).first(where: \.isConnection) else {
            endsOf[arrow] = nil
            return
        }
        let ends = [edge.source, edge.target]
        endsOf[arrow] = ends
        for end in ends { written[end, default: []].insert(arrow) }
    }

    /// The connections of relating kinds at a shape, committed or written by the run, and at a pill that names it.
    func arrows(at id: ShapeID) -> [ShapeID] {
        var found: [ShapeID] = [], seen: Set<ShapeID> = []
        func add(_ shape: ShapeID) {
            // Literally: an arrow drawn at a pill is found at the pill, whatever the committed pill forwards it to
            // (the run may have pointed the pill elsewhere).
            if let topology = editor.topology {
                for edge in topology.edges(of: shape, .either, types: .all, view: .literal) where edge.isConnection && seen.insert(edge.carrier).inserted {
                    found.append(edge.carrier)
                }
            }
            for arrow in written[shape] ?? [] where seen.insert(arrow).inserted { found.append(arrow) }
        }
        add(id)
        if !standInKinds.isEmpty {
            if let topology = editor.topology { for pill in topology.standIns(naming: id) { add(pill) } }
            for pill in pillsNaming[id] ?? [] { add(pill) }
        }
        return found
    }

    private func examineArrows(at id: ShapeID, in reading: LayoutReading) {
        for arrow in arrows(at: id) { examine(arrow, in: reading) }
    }

    /// What an arrow is an end of now, against what it was; the relationship types either names are dirty.
    private func examine(_ arrow: ShapeID, in reading: LayoutReading) {
        let old: EndClassification?
        if let known = examined[arrow] {
            old = known
        } else if let end = editor.relationships?.end(arrow) {
            old = EndClassification(type: end.type, side: end.side, other: end.type)
        } else {
            old = nil
        }
        let now = classify(arrow, in: reading)
        if examined[arrow] == nil { examinedOrder.append(arrow) }
        examined[arrow] = .some(now)
        if let old { dirty.insert(old.type) }
        if let now { dirty.insert(now.type) }
    }

    private func classify(_ arrow: ShapeID, in reading: LayoutReading) -> EndClassification? {
        guard let record = reading.shape(inFile: arrow), relatingKinds.contains(record.kind),
              let edge = registry.edges(of: record).first(where: \.isConnection),
              let first = typeAt(edge.source, in: reading), let second = typeAt(edge.target, in: reading) else { return nil }
        let marked = types.relationshipTypes
        switch (marked.contains(first), marked.contains(second)) {
        case (false, true): return EndClassification(type: second, side: .from, other: first)
        case (true, false): return EndClassification(type: first, side: .to, other: second)
        default: return nil
        }
    }

    /// The type an end stands at, as the index reads it, over the run's own records and types.
    private func typeAt(_ end: ShapeID, in reading: LayoutReading) -> ShapeID? {
        guard let record = reading.shape(inFile: end) else { return nil }
        guard standInKinds.contains(record.kind) else { return types.types.contains(end) ? end : nil }
        guard let target = registry.standIns.directTarget(of: record), types.types.contains(target) else { return nil }
        return target
    }

    // MARK: The ends

    /// Compiles again each relationship type the entries named, from the committed ends with the run's arrows
    /// put in their place.
    private func recompile(in reading: LayoutReading) {
        guard !dirty.isEmpty else { return }
        let marked = types.relationshipTypes
        recompiled.formUnion(dirty)
        for type in dirty {
            let before = ends.sides[type]
            var sides = RelationshipSides()
            if marked.contains(type) {
                var placed: Set<ShapeID> = []
                for side in RelationshipSide.allCases {
                    for end in committed.ends.sides[type]?[side] ?? [] {
                        if let known = examined[end.carrier] {
                            // Read again: in place if it is still an end of this type on this side.
                            guard let now = known, now.type == type, now.side == side, let made = makeEnd(of: end.carrier, now, in: reading) else { continue }
                            sides[side].append(made)
                        } else {
                            sides[side].append(end)
                        }
                        placed.insert(end.carrier)
                    }
                }
                for carrier in examinedOrder where !placed.contains(carrier) {
                    guard let now = examined[carrier] ?? nil, now.type == type, let made = makeEnd(of: carrier, now, in: reading) else { continue }
                    sides[now.side].append(made)
                }
                // In the file's order, as a compile of the file puts them: the arrows the file has by their place,
                // those the run drew after, in the order it drew them.
                for side in RelationshipSide.allCases { sides[side] = ranked(sides[side]) { $0.carrier } }
            }
            let new: RelationshipSides? = sides.isEmpty ? nil : sides
            ends.sides[type] = new
            contributions[type] = new.map { RelationshipEnds.rows(of: type, sides: $0) } ?? [:]
            let wasAt = Set(before.map { Set($0.from.map(\.type) + $0.to.map(\.type)) } ?? [])
            dirtyEndTypes.formUnion(wasAt)
            dirtyEndTypes.formUnion(Set((new?.from ?? []).map(\.type) + (new?.to ?? []).map(\.type)))
        }
        assembleRows()
        dirty = []
        dirtyEndTypes = []
    }

    /// `items` in the file's order of their arrows (`carrier`): those the file has by `fileOrderKey`, those the run
    /// drew after them in the order the run met them.
    private func ranked<T>(_ items: [T], _ carrier: (T) -> ShapeID) -> [T] {
        guard items.count > 1 else { return items }
        let snapshot = editor.topology?.snapshot(.recorded)
        var met: [ShapeID: Int] = [:]
        for (offset, id) in examinedOrder.enumerated() where met[id] == nil { met[id] = offset }
        let keyed = items.enumerated().map { offset, item in
            (item: item, key: snapshot?.fileOrderKey(of: carrier(item)), met: met[carrier(item)] ?? Int.max, offset: offset)
        }
        return keyed.sorted { a, b in
            switch (a.key, b.key) {
            case (nil, nil): a.met == b.met ? a.offset < b.offset : a.met < b.met
            case (nil, _): false
            case (_, nil): true
            case (let x?, let y?): x == y ? (a.met == b.met ? a.offset < b.offset : a.met < b.met) : x.lexicographicallyPrecedes(y)
            }
        }.map(\.item)
    }

    private func makeEnd(of carrier: ShapeID, _ now: EndClassification, in reading: LayoutReading) -> RelationshipEnd? {
        guard let record = reading.shape(inFile: carrier) else { return nil }
        let name = registry.typeWords(of: record.kind)?.words(record)?.firstLine
        return RelationshipEnd(type: now.other, carrier: carrier, name: name, rule: record[RelationshipEndProperty.self] ?? EndRule())
    }

    /// What the end types' notes get: the rows of each relationship type with an end there, those the run compiled
    /// again as it did and the committed rows of the others, the types in the file order of their first end.
    private func assembleRows() {
        for end in dirtyEndTypes {
            let holders = ends.sides.filter { $0.value.from.contains { $0.type == end } || $0.value.to.contains { $0.type == end } }.keys
            func rows(of holder: ShapeID) -> [RelationshipRow] {
                if let kept = contributions[holder] { return kept[end] ?? [] }
                return (committed.ends.rows[end] ?? []).filter { $0.key.type == holder }
            }
            let firsts = holders.compactMap { holder in rows(of: holder).first?.carriers.first.map { (holder: holder, carrier: $0) } }
            var found: [RelationshipRow] = []
            for first in ranked(firsts, { $0.carrier }) { found += rows(of: first.holder) }
            ends.rows[end] = found.isEmpty ? nil : found
        }
    }
}

// MARK: The index

extension RelationshipIndex {
    /// The graph a transaction's reading sees: the committed graph with what the run has written put back (the
    /// relationship types and types it made, marked or took the mark from, the arrows it drew as ends, and the
    /// lists of types it wrote), kept up as the run goes on from the reading's log. The committed graph for the
    /// editor's own reading, and for a run while no relationship type is committed or written.
    public func graph(in reading: LayoutReading) -> RelationshipGraph {
        guard !reading.isCommitted, let editor else { return graph }
        guard let run = runGraph(for: reading, editor: editor) else { return graph }
        return run.graph(for: reading)
    }

    /// The run's graph for a reading, one a run: made again for another run or another commit, and when the
    /// reading is older than what it has read.
    private func runGraph(for reading: LayoutReading, editor: CanvasEditor) -> RunGraph? {
        if let kept = runKept, kept.runID == reading.runID, kept.revision == editor.revision, kept.cursor <= reading.writeCount { return kept }
        let made = RunGraph(editor: editor, runID: reading.runID)
        runKept = made
        return made
    }

    /// The relationship types whose ends a run's writes may have changed, as far as the reading's log has been
    /// read (`graph(in:)` reads it): those it marked, unmarked or deleted, those an end arrow of which it drew,
    /// changed or deleted, and those with an end at a type that came or went. None for the committed reading, or
    /// while no relationship type is committed or written.
    func relationshipTypesCompiled(in reading: LayoutReading) -> Set<ShapeID> {
        guard !reading.isCommitted, let editor else { return [] }
        _ = graph(in: reading)
        return runGraph(for: reading, editor: editor)?.recompiled ?? []
    }

    /// The connections of relating kinds at a shape as a run's reading has the file, and at the pills that name
    /// it: the committed ones (which the run may have changed or deleted: read each from the reading), those the
    /// run drew, and the arrows the last commit left bound to it or to such a pill at one end alone (a loose
    /// end's candidates).
    func arrows(at id: ShapeID, in reading: LayoutReading) -> Set<ShapeID> {
        guard !reading.isCommitted, let editor else { return [] }
        var found = halves(at: id)
        if !standInKinds.isEmpty, let topology = editor.topology {
            for pill in topology.standIns(naming: id) { found.formUnion(halves(at: pill)) }
        }
        _ = graph(in: reading)
        if let run = runGraph(for: reading, editor: editor) { found.formUnion(run.arrows(at: id)) }
        return found
    }

    /// The shapes at the ends of a connection of a relating kind, by its record: each end as the record names it,
    /// and, for an end that is a pill, every shape the pill names (admitted or not: a note is at the end of an arrow
    /// into a pill for it). `named` says what an end names if it is a pill (`shapesNamed(by:)` of the end as the
    /// file is read, committed or as a run has it; the asker keeps the answers). The notes whose relations a
    /// change to the connection may change.
    func shapesAtEnds(of connection: AnyShapeRecord, named: (ShapeID) -> [ShapeID]) -> Set<ShapeID> {
        guard let editor, editor.registry.relates(connection.kind) else { return [] }
        var found: Set<ShapeID> = []
        for edge in editor.registry.edges(of: connection) where edge.isConnection {
            for end in [edge.source, edge.target] {
                found.insert(end)
                if !standInKinds.isEmpty { found.formUnion(named(end)) }
            }
        }
        return found
    }

    /// The shapes a pill names, by its record; none for a shape that is no pill, or one that finds shapes.
    func shapesNamed(by pill: AnyShapeRecord?) -> [ShapeID] {
        guard let pill, standInKinds.contains(pill.kind), case .shapes(let named)? = standIns.forwarding(of: pill) else { return [] }
        return named
    }

    /// What one end is, as the reading has the file: a shape or a pill that stands for one.
    public func reading(ofEnd literal: ShapeID, in reading: LayoutReading) -> EndReading {
        guard !reading.isCommitted, let editor else { return self.reading(ofEnd: literal) }
        guard let record = reading.shape(inFile: literal) else { return .free }
        let standIns = self.standIns
        guard standInKinds.contains(record.kind) else { return .note(literal) }
        let called = standIns.calls(record)
        guard let forwarding = standIns.forwarding(of: record) else { return .empty }
        guard case .shapes(let named) = forwarding else { return .query(called: called) }
        guard let target = forwarding.onlyShape else { return named.isEmpty ? .empty : .query(called: called) }
        if let shape = reading.shape(inFile: target) {
            return standIns.admits(record.kind, shape) ? .note(target) : .notAdmitted(target, needs: standIns.needs(record.kind) ?? "")
        }
        if case .unavailable? = editor.topology?.end(target) { return .unavailable(called: called) }
        return .gone(called: called)
    }

    /// A connection's two ends, read as the reading has the file; nil when it is not of a kind that relates or
    /// not bound at both ends.
    public func subjects(of connection: AnyShapeRecord, in reading: LayoutReading) -> ConnectionReading? {
        guard let editor, editor.registry.relates(connection.kind),
              let edge = editor.registry.edges(of: connection).first(where: \.isConnection) else { return nil }
        return ConnectionReading(from: ReadEnd(literal: edge.source, reading: self.reading(ofEnd: edge.source, in: reading)),
                                 to: ReadEnd(literal: edge.target, reading: self.reading(ofEnd: edge.target, in: reading)))
    }

    /// Whether `note` is what the end stands at in the recorded edges: the shape itself, or one of the shapes a pill
    /// there stands for that the pill admits (an arrow into a pill for two notes runs to each).
    private func names(_ note: ShapeID, atEnd literal: ShapeID, in reading: LayoutReading) -> Bool {
        guard let record = reading.shape(inFile: literal) else { return false }
        let standIns = self.standIns
        guard standInKinds.contains(record.kind) else { return literal == note }
        guard case .shapes(let named)? = standIns.forwarding(of: record), named.contains(note), let shape = reading.shape(inFile: note) else { return false }
        return standIns.admits(record.kind, shape)
    }

    /// The relationships a note has as the reading has the file: the committed ones, less those the run changed,
    /// and the run's own, each as `relations(of:)` says it. Kept by the reading's `writeCount` (a note asked
    /// twice between two writes is answered once).
    public func relations(of note: ShapeID, in reading: LayoutReading) -> [Relation] {
        guard !reading.isCommitted, let editor else { return relations(of: note) }
        let graph = graph(in: reading)
        let marked = graph.types.relationshipTypes
        guard !marked.isEmpty else { return [] }
        let key = RunRelationsKey(run: reading.runID, writes: reading.writeCount, revision: editor.revision)
        if runRelations.key != key { runRelations = (key, [:]) }
        if let kept = runRelations.answers[note] { return kept }
        let carriers = runGraph(for: reading, editor: editor)?.arrows(at: note) ?? []
        #if DEBUG
        runRelationsMade += 1
        #endif
        var found: [Relation] = []
        for carrier in carriers {
            guard let record = reading.shape(inFile: carrier), editor.registry.relates(record.kind), let list = record[IsAProperty.self],
                  let edge = editor.registry.edges(of: record).first(where: \.isConnection) else { continue }
            let kinds = list.map(\.shape).filter(marked.contains)
            guard !kinds.isEmpty else { continue }
            let start = ReadEnd(literal: edge.source, reading: self.reading(ofEnd: edge.source, in: reading))
            let end = ReadEnd(literal: edge.target, reading: self.reading(ofEnd: edge.target, in: reading))
            // The note is an end as the recorded edges have it: a shape, or one a pill that reads through names; at both ends
            // (a loop, or the note and a pill for it), on both sides, as `relations(of:)` has it.
            let starts = names(note, atEnd: edge.source, in: reading), ends = names(note, atEnd: edge.target, in: reading)
            let sides: [(side: RelationshipSide, far: ReadEnd)]
            if starts && ends {
                sides = [(.from, end), (.to, start)]
            } else if starts {
                sides = [(.from, end)]
            } else if ends {
                sides = [(.to, start)]
            } else {
                continue
            }
            for (side, far) in sides {
                for type in kinds { found.append(Relation(arrow: carrier, type: type, side: side, far: far)) }
            }
        }
        runRelations.answers[note] = found
        return found
    }
}

struct RunRelationsKey: Equatable {
    var run: Int
    var writes: Int
    var revision: Int
}

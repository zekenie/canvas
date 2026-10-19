import Canvas
import Foundation
import Mentions
import Topology

/// A relationship a note has: the arrow, the relationship type it is of, the side of that type the note is
/// on (an arrow from the note is `from`), and the far end, read.
public struct Relation: Sendable, Hashable {
    public let arrow: ShapeID
    public let type: ShapeID
    public let side: RelationshipSide
    public let far: ReadEnd

    public init(arrow: ShapeID, type: ShapeID, side: RelationshipSide, far: ReadEnd) {
        self.arrow = arrow
        self.type = type
        self.side = side
        self.far = far
    }
}

/// What a commit changed in relationships, told to `RelationshipIndex.onChange`.
public struct RelationshipChange: Sendable {
    /// Connections whose fit, or whether they are relationships or ends, may have changed.
    public let arrows: Set<ShapeID>
    /// Relationships whose own words, values or look changed and nothing else: their ends, types and fit are as they were, so
    /// no note's row is made again for them (a keystroke in an arrow's card names the arrow here alone).
    public let values: Set<ShapeID>
    /// Shapes whose relations may have changed.
    public let notes: Set<ShapeID>
    /// End types whose notes gained or lost a row.
    public let layout: Set<ShapeID>
    /// Some row's name or others changed with no change of count.
    public let rows: Bool
    /// Everything was compiled again: read everything again.
    public let everything: Bool

    public init(arrows: Set<ShapeID> = [], values: Set<ShapeID> = [], notes: Set<ShapeID> = [], layout: Set<ShapeID> = [], rows: Bool = false, everything: Bool = false) {
        self.arrows = arrows
        self.values = values
        self.notes = notes
        self.layout = layout
        self.rows = rows
        self.everything = everything
    }

    public var isEmpty: Bool { arrows.isEmpty && values.isEmpty && notes.isEmpty && layout.isEmpty && !rows && !everything }
}

/// What the file's relationships are, kept by each commit: the ends of every relationship type (compiled
/// from the arrows between it and other types, never stored), the rows they give, and what moved. All
/// the meaning is in `RelationshipGraph`; this keeps its input and says what changed. It never transacts,
/// never calls `topology.provide` and never calls Validation.
///
/// A relating kind (one that holds `endRule`) has connections: an arrow bound at both ends, an edge in the
/// empty slot (`Edge.isConnection`). A connection with a relationship type at one end and an unmarked type
/// at the other is an end of that type; the end's arrow names the row (its words' first line) and may hold
/// a rule. The service finds the kinds by the property they hold: it names none.
///
/// Registered right after `TypeIndex`, which it hears after, and before `FieldBook` and what reads it.
@MainActor
public final class RelationshipIndex {
    weak var editor: CanvasEditor?
    private let types: TypeIndex
    private let topology: TopologyIndex
    /// The kinds that relate (hold `endRule`).
    private let relatingKinds: Set<ShapeKind>
    /// The kinds that stand in for other shapes (pills).
    let standInKinds: Set<ShapeKind>
    /// The registry's stand-ins, made once (`registry.standIns` works them out on each call, and every note's row reads
    /// its relationships' ends through them).
    let standIns: StandIns

    /// The ends of every relationship type and the rows they give its end types.
    private var ends = RelationshipEnds()
    /// By end arrow: the relationship type it is an end of and the side.
    private var endOf: [ShapeID: (type: ShapeID, side: RelationshipSide)] = [:]
    /// By relationship type: its end arrows.
    private var carriersOf: [ShapeID: Set<ShapeID>] = [:]
    /// By relationship type: the rows its ends give, by end type.
    private var contributions: [ShapeID: [ShapeID: [RelationshipRow]]] = [:]
    /// By shape: the relating shapes bound to it and to nothing else (an arrow with a free end), whichever the shape is
    /// today: the loose end's candidates, so a note that comes or goes as a type names them without a pass over a board.
    private var halvesAt: [ShapeID: Set<ShapeID>] = [:]
    /// By such an arrow: the one shape it is bound to.
    private var halfOf: [ShapeID: ShapeID] = [:]
    /// By end type: the relationship types with an end at it.
    private var endsHolding: [ShapeID: Set<ShapeID>] = [:]

    /// Moves for any end, mark, lineage or membership change, an end's label included.
    public private(set) var revision = 0
    private var counter = 0
    private var floor = 0
    private var stamps: [ShapeID: Int] = [:]
    private var observers: [@MainActor (RelationshipChange) -> Void] = []
    private var heardRevision: Int
    private var following: TopologyFollowing?

    // What was collected while others heard the commit, until this service does.
    private var pendingTypes = TypeChange()
    private var pendingTouched: [EdgeTypeID: Set<ShapeID>] = [:]
    private var pendingRebuild = false

    /// Connections a drag session was still changing when a commit named them (`Session.touching`): read as they were
    /// before the drag until it is released (`release(_:)`), since a port's drag binds and unbinds an arrow at every
    /// hover and counted as ends, a pass over a relationship type would make an end and unmake it each time.
    private var held: Set<ShapeID> = []
    /// By connection: the notes at its ends when it was last counted, for the ends a re-aim leaves.
    private var noteEndsOf: [ShapeID: Set<ShapeID>] = [:]
    /// The connection being released: counted, though the session that was changing it still names it.
    private var exempt: ShapeID?

    /// The types that have types of their own, while a reconcile runs (`typesBuilding`).
    private var listed: [(type: ShapeID, ancestors: Set<ShapeID>)]?
    private var rowsMemo: [RowsKey: [RelationshipRow]] = [:]
    private var rowsMemoRevision = -1

    /// A run's own graph, and the relations it answered (`graph(in:)`, `relations(of:in:)`; RelationshipRun.swift).
    var runKept: RunGraph?
    var runRelations: (key: RunRelationsKey?, answers: [ShapeID: [Relation]]) = (nil, [:])
    #if DEBUG
    /// How many log entries a run's graph has applied, and how many times a note's relations were worked out in a run
    /// (debug builds only): tests hold them to one for each write and one for each note between two writes.
    public internal(set) var runApplications = 0
    public internal(set) var runRelationsMade = 0
    /// How many times a delete of a relationship type read its end arrows (debug builds only): a delete of shapes
    /// that are none reads none.
    public internal(set) static var endDeletes = 0
    #endif

    private struct RowsKey: Hashable {
        let list: [ShapeID]
        let isType: Bool
    }

    init(editor: CanvasEditor) {
        self.editor = editor
        guard let types = editor.types, let topology = editor.topology else {
            preconditionFailure("RelationshipIndex needs TypeIndex and TopologyIndex: TypesPlugin declares the first and Topology is its owner's")
        }
        self.types = types
        self.topology = topology
        let registry = editor.registry
        relatingKinds = Set(registry.kinds.filter { registry.relates($0) })
        standIns = registry.standIns
        standInKinds = standIns.kinds
        heardRevision = editor.revision
        // Both only collect: the commit is worked out when this service hears it.
        types.onChange { [weak self] change in self?.collect(change) }
        following = topology.follow { [weak self] change in self?.collect(change) }
        compileEverything()
    }

    // MARK: What it says

    /// Whether a relationship type exists now: the first test of every path. A kept answer is current while
    /// this is false only if its relation part is empty.
    public var isActive: Bool { !relatingKinds.isEmpty && !types.graph.relationshipTypes.isEmpty }

    /// The types and the ends, as the last commit left them. O(1).
    public var graph: RelationshipGraph { RelationshipGraph(types: types.graph, ends: ends) }

    /// Moves when what is said of this one shape may have changed: a stamp never restarts, and an entry is
    /// dropped only with its shape or when everything is compiled again.
    public func stamp(of shape: ShapeID) -> Int { stamps[shape] ?? floor }

    /// The relationship type an end arrow is an end of, and the side; nil for any other shape.
    public func end(_ connection: ShapeID) -> (type: ShapeID, side: RelationshipSide)? { endOf[connection] }

    /// The end arrows of a relationship type, as the last commit left them, on whichever boards they are: the arrows
    /// between it and the types it relates, both ends read (a pill that names a type counts as the type). Empty for a
    /// shape that is no relationship type. O(1) to ask.
    public func endArrows(of type: ShapeID) -> Set<ShapeID> { carriersOf[type] ?? [] }

    /// Every arrow that is an end of a relationship type, as the last commit left them.
    var endCarriers: Set<ShapeID> { Set(endOf.keys) }

    /// The end arrows of a relationship type as a transaction leaves them, for the delete that takes them
    /// (`RelationshipDeletes`): the arrows the index knows (`endArrows(of:)`) and every relating shape on the type's own
    /// board bound to it, one end free or not, each read again from the transaction's own record (`boundShapes(in:)`), so an
    /// end the transaction drew counts and one it re-aimed at a note that is no type does not. An arrow is an end when it is
    /// bound to the type (or to a pill that names it) and every other end it is bound to is a type's note or a pill that names
    /// one, and it has no other relationship type at an end; a free end is nothing. One pass over the type's board, for the
    /// delete of a relationship type alone (the core's own letting go makes one for every delete). A transaction on a board
    /// that is not shown cannot reach the board shown (its commit would be dropped), so the arrows there are left out.
    func endArrows(of type: ShapeID, reading transaction: Transaction) -> Set<ShapeID> {
        guard let editor else { return [] }
        let marked = types.graph.relationshipTypes
        let skipsShown = !transaction.mayReachBoardShown
        let context = transaction.shapes
        var documents: [BoardID: CanvasDocument] = [:]
        func document(_ board: BoardID) -> CanvasDocument {
            if let known = documents[board] { return known }
            let made = transaction.contents(of: board)
            documents[board] = made
            return made
        }
        func isEnd(_ record: AnyShapeRecord) -> Bool {
            var atType = false
            for end in record.boundShapes(in: context) {
                guard let at = typeAt(end) else { return false }
                if at == type { atType = true } else if marked.contains(at) { return false }
            }
            return atType
        }
        var found: Set<ShapeID> = []
        var seen: Set<ShapeID> = []
        func consider(_ record: AnyShapeRecord, on board: BoardID) {
            guard relatingKinds.contains(record.kind), seen.insert(record.id).inserted, !(skipsShown && board == editor.board), isEnd(record) else { return }
            found.insert(record.id)
        }
        for arrow in carriersOf[type] ?? [] {
            guard let board = transaction.board(containing: arrow), let record = document(board)[arrow] else { continue }
            consider(record, on: board)
        }
        if let home = transaction.board(containing: type) {
            for record in document(home).shapes { consider(record, on: home) }
        }
        return found
    }

    /// The relating shapes bound to a shape and to nothing else, as the last commit left them (an arrow with a free
    /// end drawn at it): a loose end's candidates.
    func halves(at id: ShapeID) -> Set<ShapeID> { halvesAt[id] ?? [] }

    /// Whether a drag session is still changing the connection: not counted as it is until the release.
    private func isHeld(_ id: ShapeID) -> Bool {
        guard id != exempt else { return false }
        return editor?.session?.touching.contains(id) ?? false
    }

    #if DEBUG
    /// The connections a commit named while a session was changing them and the release has not counted yet (debug
    /// builds, for tests).
    public var heldConnections: Set<ShapeID> { held }
    #endif

    /// The rows a shape with this `is` list gets, memoised by the list while the revision stands.
    public func rows(for list: [ShapeID], isType: Bool) -> [RelationshipRow] {
        guard !ends.rows.isEmpty else { return [] }
        if rowsMemoRevision != revision {
            rowsMemo = [:]
            rowsMemoRevision = revision
        }
        let key = RowsKey(list: list, isType: isType)
        if let kept = rowsMemo[key] { return kept }
        let made = graph.rows(for: list, isType: isType)
        rowsMemo[key] = made
        return made
    }

    /// The rows of `rows(for:isType:)` that carry a rule (Needed or Only one) for a note of this `is` list: the rows its check
    /// is made of.
    public func ruledRows(for list: [ShapeID]) -> [RelationshipRow] {
        rows(for: list, isType: false).filter { !$0.rule.isNone }
    }

    /// The fit of a connection against each relationship type in its `is` list; empty for one that is
    /// not bound at both ends, or is not a relating kind's.
    public func fits(of connection: ShapeID) -> [(type: ShapeID, fit: Fit)] {
        guard isActive, let reading = subjects(of: connection), let list = editor?.shape(inFile: connection)?[IsAProperty.self] else { return [] }
        let graph = graph
        return list.compactMap { link in
            graph.fit(of: link.shape, from: reading.from.reading, to: reading.to.reading).map { (link.shape, $0) }
        }
    }

    /// The relationships a note has, in the arrows' order as Topology gives them: read from the recorded
    /// edges of the note (O(degree)) and filtered at the read by the marks, so a mark that comes or goes
    /// changes the answer with nothing kept to drop. A free-ended arrow is in none.
    public func relations(of note: ShapeID) -> [Relation] {
        guard isActive, let editor else { return [] }
        let marked = types.graph.relationshipTypes
        var found: [Relation] = []
        for edge in topology.edges(of: note, .either, types: .all, view: .recorded) where edge.isConnection {
            guard let carrier = editor.shape(inFile: edge.carrier), relatingKinds.contains(carrier.kind), let list = carrier[IsAProperty.self] else { continue }
            let kinds = list.map(\.shape).filter(marked.contains)
            guard !kinds.isEmpty else { continue }
            // The note is the start of its own arrow's relationship, the end of the far one.
            let side: RelationshipSide = edge.source == note ? .from : .to
            let far = side == .from ? edge.literalTarget : edge.literalSource
            let end = ReadEnd(literal: far, reading: reading(ofEnd: far))
            for type in kinds { found.append(Relation(arrow: edge.carrier, type: type, side: side, far: end)) }
        }
        return found
    }

    /// Those of a note's relations that are of the row's type on the row's side or sides, each arrow once.
    public func relations(of note: ShapeID, in row: RelationshipRow) -> [Relation] {
        var seen: Set<ShapeID> = []
        return relations(of: note).filter { $0.type == row.key.type && row.sides.contains($0.side) && seen.insert($0.arrow).inserted }
    }

    /// The notes that fit the other end of a row, file-wide, whoever asks: any of the other types' instances (through
    /// the chain), near and far, that are no type. Nil when the row's other side has no type.
    public func instances(for row: RelationshipRow) -> Set<ShapeID>? {
        guard !row.others.isEmpty else { return nil }
        let graph = graph
        return types.affected(by: Set(row.others)).filter { !graph.types.types.contains($0) && graph.fits($0, otherEndOf: row) }
    }

    /// The notes that may sit at the other end of a row, file-wide: any of the other types' instances, near
    /// and far, that are no type, are not the note and are not at its row already. Nil when the row's other
    /// side has no type: any shape of a kind that draws rows.
    public func candidates(for row: RelationshipRow, of note: ShapeID) -> Set<ShapeID>? {
        guard var found = instances(for: row) else { return nil }
        found.remove(note)
        for relation in relations(of: note, in: row) { if let far = relation.far.reading.offeredNoMore(replacing: row.rule.onlyOne) { found.remove(far) } }
        return found
    }

    /// Calls `body` after each commit that changed relationships.
    public func onChange(_ body: @escaping @MainActor (RelationshipChange) -> Void) {
        observers.append(body)
    }

    // MARK: Collecting

    private func collect(_ change: TypeChange) {
        pendingTypes = TypeChange(types: pendingTypes.types.union(change.types), marks: pendingTypes.marks.union(change.marks),
                                  membership: pendingTypes.membership.union(change.membership), lineage: pendingTypes.lineage.union(change.lineage),
                                  lists: pendingTypes.lists.union(change.lists), everything: pendingTypes.everything || change.everything)
    }

    private func collect(_ change: TopologyChange) {
        switch change.cause {
        case .provide: return
        case .rebuild: pendingRebuild = true
        case .commit:
            // Only a connection's ends are of interest, and a type's own edge to the types it is is not one.
            guard isActive else { return }
            for (type, ends) in change.touchedByType where type != IsAEdge.id && type != MentionEdge.id { pendingTouched[type, default: []].formUnion(ends) }
        }
    }

    private func clearPending() {
        pendingTypes = TypeChange()
        pendingTouched = [:]
        pendingRebuild = false
    }

    // MARK: Keeping it

    private struct Announce {
        var arrows: Set<ShapeID> = [], values: Set<ShapeID> = [], notes: Set<ShapeID> = [], layout: Set<ShapeID> = []
        var rows = false, everything = false, ended = false

        var change: RelationshipChange { RelationshipChange(arrows: arrows, values: values.subtracting(arrows), notes: notes, layout: layout, rows: rows, everything: everything) }
        var isEmpty: Bool { change.isEmpty && !ended }
    }

    /// Everything compiled from the file as it is: a file put in place, or a commit heard out of turn.
    private func compileEverything() {
        ends = RelationshipEnds()
        endOf = [:]
        carriersOf = [:]
        contributions = [:]
        endsHolding = [:]
        halvesAt = [:]
        halfOf = [:]
        if let editor, !relatingKinds.isEmpty {
            let context = editor.shapeContext
            for document in [editor.file.root] + Array(editor.file.children.values) {
                for record in document.shapes where relatingKinds.contains(record.kind) { trackHalf(record, context) }
            }
        }
        rowsMemo = [:]
        counter &+= 1
        floor = counter
        stamps = [:]
        noteEndsOf = [:]
        revision &+= 1
        var out = Announce()
        reconcile(carriers: [], scanning: types.graph.relationshipTypes, recompiling: [], &out)
        // The notes at the ends of each relationship, for a re-aim to leave one of them.
        if let editor {
            for marked in types.graph.relationshipTypes {
                for arrow in types.instances(of: marked) {
                    guard let kind = editor.shape(inFile: arrow)?.kind, relatingKinds.contains(kind) else { continue }
                    let ends = currentNoteEnds(of: arrow)
                    if !ends.isEmpty { noteEndsOf[arrow] = ends }
                }
            }
        }
    }

    /// Keeps `halvesAt` for one relating shape as it is now (gone or bound at both ends: none).
    private func trackHalf(_ record: AnyShapeRecord?, _ context: ShapeContext, gone id: ShapeID? = nil) {
        if let id = record?.id ?? id, let old = halfOf.removeValue(forKey: id) {
            halvesAt[old]?.remove(id)
            if halvesAt[old]?.isEmpty == true { halvesAt[old] = nil }
        }
        guard let record, relatingKinds.contains(record.kind) else { return }
        // A connection is bound at both ends: asked first, since it is a lookup and the shapes bound are read from the
        // record (a file opens with one ask for each arrow).
        guard topology.edges(carriedBy: record.id, view: .literal).contains(where: \.isConnection) == false else { return }
        let bound = record.boundShapes(in: context)
        guard bound.count == 1 else { return }
        halfOf[record.id] = bound[0]
        halvesAt[bound[0], default: []].insert(record.id)
    }

    private func bump(_ id: ShapeID) {
        counter &+= 1
        stamps[id] = counter
    }

    /// The connections at a shape (the edges in the empty slot, read in the recorded view), by their
    /// carriers, of the kinds that relate; and those at a pill whose record names it, which the recorded
    /// view keeps at the pill while the kind may not stand for it yet (a direct pill names its shape either
    /// way, `typeAt`), so the same arrow is found drawn, opened, or after the shape becomes a type.
    private func connectionCarriers(at id: ShapeID) -> [ShapeID] {
        guard let editor else { return [] }
        var found: [ShapeID] = [], seen: Set<ShapeID> = []
        func collect(_ shape: ShapeID) {
            for edge in topology.edges(of: shape, .either, types: .all, view: .recorded) where edge.isConnection && seen.insert(edge.carrier).inserted {
                if let kind = editor.shape(inFile: edge.carrier)?.kind, relatingKinds.contains(kind), !isHeld(edge.carrier) { found.append(edge.carrier) }
            }
        }
        collect(id)
        if !standInKinds.isEmpty { for pill in topology.standIns(naming: id) { collect(pill) } }
        return found
    }

    /// What a connection is an end of: the relationship type it joins to an unmarked type, which side it is
    /// on, and the type at its other end. An end is read through a pill that names one shape (a direct
    /// pill), whether or not the pill reads through, while that shape is still a type.
    private func classify(_ carrier: ShapeID) -> (type: ShapeID, side: RelationshipSide, other: ShapeID)? {
        guard let editor, let record = editor.shape(inFile: carrier), relatingKinds.contains(record.kind),
              let edge = topology.edges(carriedBy: carrier, view: .literal).first(where: \.isConnection),
              let first = typeAt(edge.source), let second = typeAt(edge.target) else { return nil }
        let marked = types.graph.relationshipTypes
        switch (marked.contains(first), marked.contains(second)) {
        case (false, true): return (second, .from, first)
        case (true, false): return (first, .to, second)
        default: return nil
        }
    }

    /// The type an end stands at: the shape if it is a type, what a direct pill's record names if that is
    /// one type and still a type, else nil (a pill that finds shapes, that stands for nothing, for a shape
    /// that is no type, a shape that is none).
    func typeAt(_ end: ShapeID) -> ShapeID? {
        guard let editor, let record = editor.shape(inFile: end) else { return nil }
        guard standInKinds.contains(record.kind) else { return types.isType(end) ? end : nil }
        guard let target = standIns.directTarget(of: record), types.isType(target) else { return nil }
        return target
    }

    /// The ids in the order they are in the file, those it cannot place last.
    private func ordered(_ ids: [ShapeID]) -> [ShapeID] {
        guard ids.count > 1 else { return ids }
        let snapshot = topology.snapshot(.recorded)
        let keyed = ids.map { (id: $0, key: snapshot.fileOrderKey(of: $0), uuid: $0.rawValue.uuidString) }
        return keyed.sorted { a, b in
            switch (a.key, b.key) {
            case (nil, nil): a.uuid < b.uuid
            case (nil, _): false
            case (_, nil): true
            case (let x?, let y?): x == y ? a.uuid < b.uuid : x.lexicographicallyPrecedes(y)
            }
        }.map(\.id)
    }

    /// Finds what changed in the ends and recompiles each relationship type it touches: `carriers` are
    /// connections to read again, `scanning` shapes whose connections are all read again (a type that was
    /// marked or unmarked, one that came or went as a type), `recompiling` relationship types to build again
    /// from their end arrows as they are.
    private func reconcile(carriers dirtyCarriers: Set<ShapeID>, scanning scans: Set<ShapeID>, recompiling extra: Set<ShapeID>, _ out: inout Announce) {
        listed = nil
        defer { listed = nil }
        var carriers = dirtyCarriers
        for id in scans { carriers.formUnion(connectionCarriers(at: id)) }
        var queue = extra
        for carrier in carriers {
            let old = endOf[carrier]
            let now = classify(carrier)
            if let old, old.type != now?.type {
                carriersOf[old.type]?.remove(carrier)
                queue.insert(old.type)
            }
            if let now {
                endOf[carrier] = (now.type, now.side)
                carriersOf[now.type, default: []].insert(carrier)
                queue.insert(now.type)
            } else {
                endOf[carrier] = nil
            }
            if old != nil || now != nil { out.arrows.insert(carrier) }
            bump(carrier)
        }
        var done: Set<ShapeID> = []
        while let type = queue.first {
            queue.remove(type)
            guard done.insert(type).inserted else { continue }
            recompile(type, queue: &queue, &out)
        }
    }

    private func recompile(_ type: ShapeID, queue: inout Set<ShapeID>, _ out: inout Announce) {
        guard let editor else { return }
        let old = ends.sides[type]
        var found: [RelationshipSide: [ShapeID: ShapeID]] = [.from: [:], .to: [:]]   // side: carrier -> end type
        for carrier in carriersOf[type] ?? [] {
            // A connection a session is changing is what it was before the drag.
            if isHeld(carrier) {
                for side in RelationshipSide.allCases {
                    if let kept = old?[side].first(where: { $0.carrier == carrier }) { found[side]?[carrier] = kept.type }
                }
                continue
            }
            guard let now = classify(carrier), now.type == type else {
                // No longer an end of this type: maybe of another.
                carriersOf[type]?.remove(carrier)
                if endOf[carrier]?.type == type { endOf[carrier] = nil }
                if let now = classify(carrier) {
                    endOf[carrier] = (now.type, now.side)
                    carriersOf[now.type, default: []].insert(carrier)
                    queue.insert(now.type)
                }
                out.arrows.insert(carrier)
                bump(carrier)
                continue
            }
            endOf[carrier] = (type, now.side)
            found[now.side]?[carrier] = now.other
        }
        var sides = RelationshipSides()
        let registry = editor.registry
        for side in RelationshipSide.allCases {
            for carrier in ordered(Array((found[side] ?? [:]).keys)) {
                guard let other = found[side]?[carrier], let record = editor.shape(inFile: carrier) else { continue }
                let name = registry.typeWords(of: record.kind)?.words(record)?.firstLine
                sides[side].append(RelationshipEnd(type: other, carrier: carrier, name: name, rule: record[RelationshipEndProperty.self] ?? EndRule()))
            }
        }
        let new: RelationshipSides? = sides.isEmpty ? nil : sides
        let before = Fingerprint(old), after = Fingerprint(new)
        guard before != after || (old == nil) != (new == nil) else { return }
        // What it looked like to the types at its ends, before and after.
        let oldTypes = Set((old?.from ?? []).map(\.type) + (old?.to ?? []).map(\.type))
        let newTypes = Set(sides.from.map(\.type) + sides.to.map(\.type))
        // The types that build on an end type read its rows with their own: the graph as it was, for those.
        let builders = typesBuilding(onAny: oldTypes.union(newTypes))
        let oldEnds: RelationshipEnds? = builders.isEmpty ? nil : ends
        ends.sides[type] = new
        contributions[type] = new.map { RelationshipEnds.rows(of: type, sides: $0) }
        for end in oldTypes.subtracting(newTypes) { endsHolding[end]?.remove(type) }
        for end in newTypes { endsHolding[end, default: []].insert(type) }
        revision &+= 1
        out.ended = true
        bump(type)
        for end in (old?.from ?? []) + (old?.to ?? []) + sides.from + sides.to {
            out.arrows.insert(end.carrier)
            bump(end.carrier)
        }
        if before.types != after.types { out.arrows.formUnion(types.instances(of: type)) }
        // Every end type's rows are made first: a note reads its type's rows with the ones it builds on and its other types', so
        // the compare of one end's rows is made against the rows of all the others as they are after.
        var rowsBefore: [ShapeID: [RelationshipRow]?] = [:]
        var rowsAfter: [ShapeID: [RelationshipRow]?] = [:]
        for end in oldTypes.union(newTypes) {
            rowsBefore[end] = ends.rows[end]
            assemble(rowsAt: end)
            rowsAfter[end] = ends.rows[end]
        }
        for end in oldTypes.union(newTypes) {
            let before = rowsBefore[end] ?? nil, after = rowsAfter[end] ?? nil
            // A ruled row's verdict is a function of which carriers are in it, on which sides, with what rule; a note's
            // check is made again when that changed, and for a rename that changed none of it nobody is named. A row
            // that another block's row of the same key replaces (or stops replacing) in the lists of some notes is the
            // same: their verdict moved with the row that came, went or changed.
            if Self.partition(of: before) != Self.partition(of: after) || changesMerge(at: end, before: before, after: after) {
                for note in types.affected(by: [end]) where !types.isType(note) {
                    out.notes.insert(note)
                    bump(note)
                }
            }
            if before?.count != after?.count { out.layout.insert(end) }
            if before != after {
                out.rows = true
                // Rows of one key from two blocks are one row, so a rename that makes an end's row the
                // same as one it builds on gives the types that build on it one row fewer: they lay out.
                if before?.count == after?.count, let oldEnds, let built = builders[end] {
                    let was = RelationshipGraph(types: types.graph, ends: oldEnds), now = graph
                    for type in built where was.rows(for: [type], isType: false).count != now.rows(for: [type], isType: false).count { out.layout.insert(type) }
                }
            }
        }
    }

    /// Whether a row of `end`'s that came, went or changed shares its key with a row at another end type of which one is
    /// ruled: the notes that read both read the one of them that is later in their order, so the verdict may move though
    /// the ruled rows of `end` alone are as they were.
    private func changesMerge(at end: ShapeID, before: [RelationshipRow]?, after: [RelationshipRow]?) -> Bool {
        let was = Dictionary((before ?? []).map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let now = Dictionary((after ?? []).map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        for key in Set(was.keys).union(now.keys) where was[key] != now[key] {
            let mine = [was[key], now[key]].compactMap { $0 }
            for (other, rows) in ends.rows where other != end {
                guard let row = rows.first(where: { $0.key == key }) else { continue }
                if !row.rule.isNone || mine.contains(where: { !$0.rule.isNone }) { return true }
            }
        }
        return false
    }

    /// What a ruled row's verdict is a function of: the carriers it merges, the sides and the rule. Its label is not (a
    /// rename that merges nothing and splits nothing leaves it equal), and a row with no rule has none.
    private struct RuledPart: Hashable {
        let carriers: Set<ShapeID>
        let sides: Set<RelationshipSide>
        let rule: EndRule
    }

    /// The ruled rows of an end type as parts: compared before and after a recompile.
    private static func partition(of rows: [RelationshipRow]?) -> Set<RuledPart> {
        Set((rows ?? []).filter { !$0.rule.isNone }.map { RuledPart(carriers: Set($0.carriers), sides: $0.sides, rule: $0.rule) })
    }

    /// By each of `ends`, the types whose notes read its rows with others' (it, if it builds on any, and the
    /// types that build on it, near or far).
    private func typesBuilding(onAny ends: Set<ShapeID>) -> [ShapeID: [ShapeID]] {
        let links = types.graph.links
        guard !links.isEmpty else { return [:] }
        // The types that have types of their own, and what each leads to, found once for the reconcile (the type graph does
        // not change in one): each recompile asked every type of the file, and a file opens with one recompile for each
        // relationship type.
        let listing = listed ?? types.types.compactMap { type in
            (links[type] ?? []).isEmpty ? nil : (type: type, ancestors: types.graph.ancestors(of: type))
        }
        listed = listing
        var found: [ShapeID: [ShapeID]] = [:]
        for (type, ancestors) in listing {
            for end in ends where end == type || ancestors.contains(end) { found[end, default: []].append(type) }
        }
        return found
    }

    /// What an end type's notes get from the relationship types with an end at it: each one's rows, the
    /// types in the file order of their first end.
    private func assemble(rowsAt end: ShapeID) {
        let holders = Array(endsHolding[end] ?? [])
        guard !holders.isEmpty else {
            ends.rows[end] = nil
            return
        }
        let firsts: [ShapeID: ShapeID] = Dictionary(uniqueKeysWithValues: holders.compactMap { holder in
            (contributions[holder]?[end]?.first?.carriers.first).map { (holder, $0) }
        })
        let ranked = ordered(Array(firsts.values))
        let byCarrier = Dictionary(firsts.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        var rows: [RelationshipRow] = []
        for carrier in ranked { if let holder = byCarrier[carrier] { rows += contributions[holder]?[end] ?? [] } }
        ends.rows[end] = rows.isEmpty ? nil : rows
    }

    /// What of a relationship type's ends decides which shapes are affected (the types and carriers) and what
    /// only changes how rows read (the names and rules).
    private struct Fingerprint: Equatable {
        struct Place: Equatable { let side: RelationshipSide, type: ShapeID, carrier: ShapeID }
        struct Words: Equatable { let carrier: ShapeID, name: String?, rule: EndRule }
        var types: [Place] = []
        var words: [Words] = []

        init(_ sides: RelationshipSides?) {
            guard let sides else { return }
            for side in RelationshipSide.allCases {
                for end in sides[side] {
                    types.append(Place(side: side, type: end.type, carrier: end.carrier))
                    words.append(Words(carrier: end.carrier, name: end.name, rule: end.rule))
                }
            }
        }
    }

    // MARK: Hearing

    private func deliver(_ announce: Announce) {
        guard !announce.isEmpty else { return }
        let change = announce.change
        guard !change.isEmpty else { return }
        for observer in observers { observer(change) }
    }

    func hear(_ changes: ChangeSet, in editor: CanvasEditor) {
        // Up to date already: this service heard the commit earlier, as a reader that came ahead of its turn
        // had it do.
        guard heardRevision != editor.revision else { return }
        // A run's own graph was of the file before this commit.
        runKept = nil
        runRelations = (nil, [:])
        let outOfTurn = heardRevision < editor.revision - 1
        heardRevision = editor.revision
        topology.catchUp(changes)
        editor.types?.documentDidChange(changes, in: editor)
        defer { clearPending() }
        if changes.replacedDocument || outOfTurn || pendingTypes.everything || pendingRebuild {
            compileEverything()
            deliver(Announce(everything: true))
            return
        }
        // `editor.shape(inFile:)`, for the many shapes a commit can name on boards that are not shown (the boards under a
        // subboard deleted or brought back): whether a board can be shown is asked once for each board, not for each shape
        // (it works out the board's path from the root each time).
        let shown = editor.document
        var showable: [BoardID: Bool] = [:]
        func lookup(_ id: ShapeID) -> AnyShapeRecord? {
            if let record = shown[id] { return record }
            guard let board = editor.file.board(containing: id) else { return nil }
            let can: Bool
            if let known = showable[board] {
                can = known
            } else {
                can = editor.canShow(board)
                showable[board] = can
            }
            return can ? editor.file[board][id] : nil
        }
        // A drag moves shapes and nothing else: nothing here, and nothing was collected. Asked first, by counts alone: a
        // drag of a whole board is a commit a pointer event, and a move binds and frees nothing.
        let nothingNamed = changes.added.isEmpty && changes.removed.isEmpty && changes.elsewhere.isEmpty && changes.changed.count == changes.moved.count
        if nothingNamed, pendingTypes.isEmpty, pendingTouched.isEmpty { return }
        // The arrows with a free end, kept as they are now; and those drawn at a pill the commit changed, or at one for a
        // shape it changed (a pill reads through when its shape is open, say): a loose end reads a pill that names a type as
        // the type, so they are read again.
        var pilled: Set<ShapeID> = []
        if !relatingKinds.isEmpty, !nothingNamed {
            let context = editor.shapeContext
            // Four sets, one after the other: a union of them is a set of every shape a board's deletion names, made to be read twice.
            let named = [changes.added, changes.changed.subtracting(changes.moved), changes.elsewhere, changes.removed]
            for ids in named { for id in ids { trackHalf(lookup(id), context, gone: id) } }
            if !halvesAt.isEmpty, !standInKinds.isEmpty {
                for ids in named {
                    for id in ids {
                        if let kind = lookup(id)?.kind, standInKinds.contains(kind) { pilled.formUnion(halvesAt[id] ?? []) }
                        for pill in topology.standIns(naming: id) { pilled.formUnion(halvesAt[pill] ?? []) }
                    }
                }
            }
        }
        // A drag's hover: the only shapes the commit changed are connections a session is still changing. Nothing is
        // read and nothing is named; the release counts them.
        if holdsOnly(changes) { return }
        // With no relationship type before or after, nothing is an end and nothing can be (an arrow its relationship type
        // was taken from is a loose end at a type's note, though, and a note that comes or goes as a type moves that).
        if !isActive, pendingTypes.marks.isEmpty, pendingTypes.membership.isEmpty, endOf.isEmpty, pilled.isEmpty { return }
        var out = Announce()
        for arrow in pilled { out.arrows.insert(arrow); bump(arrow) }
        var carriers: Set<ShapeID> = [], scans: Set<ShapeID> = [], recompile: Set<ShapeID> = [], gone: [ShapeID] = []
        let marked = types.graph.relationshipTypes
        // A held connection nobody is changing any more (its release was not told) is counted now.
        for id in held where !isHeld(id) {
            held.remove(id)
            if lookup(id) != nil { carriers.insert(id) }
        }

        // The commit's own shapes, the kind first: a connection is read again, and any other relating shape
        // is its own stamp's.
        func named(_ id: ShapeID) {
            guard let kind = lookup(id)?.kind else {
                // Gone from a board that is not shown: the commit's `removed` is the board shown's.
                if endOf[id] != nil { carriers.insert(id) }
                gone.append(id)
                return
            }
            // A pill a commit changed is read again where it is an end, though no edge changed: a direct pill
            // names the type behind it whether or not it reads through. The arrows drawn at it run to something
            // else now.
            if standInKinds.contains(kind) {
                scans.insert(id)
                arrowsAt(pill: id, &out)
            }
            guard relatingKinds.contains(kind) else { return }
            // A connection a session is still changing is counted at its release.
            if isHeld(id) {
                held.insert(id)
                return
            }
            carriers.insert(id)
            bump(id)
        }
        for id in changes.added where !changes.moved.contains(id) { named(id) }
        for id in changes.changed where !changes.moved.contains(id) { named(id) }
        for id in changes.elsewhere { named(id) }
        for id in changes.removed where lookup(id) == nil {
            if endOf[id] != nil { carriers.insert(id) }
            gone.append(id)
        }

        // What the followers collected: a type touched by an edge of the connections' kinds was read through
        // a pill, or has an end arrow that the commit does not name.
        var touched: Set<ShapeID> = []
        for ids in pendingTouched.values { touched.formUnion(ids) }
        for id in touched {
            if marked.contains(id) {
                scans.insert(id)
            } else if !types.isType(id) {
                out.notes.insert(id)
                bump(id)
                // A pill whose shape was made private or open, or deleted, runs the arrows at it elsewhere.
                if let kind = lookup(id)?.kind, standInKinds.contains(kind) { arrowsAt(pill: id, &out) }
            }
        }

        // The marks, in both directions.
        for id in pendingTypes.marks {
            scans.insert(id)
            out.arrows.formUnion(types.instances(of: id))
            revision &+= 1
            out.ended = true
        }
        if !pendingTypes.marks.isEmpty { out.arrows.formUnion(relatingShapes(boundToAny: pendingTypes.marks)) }
        // A note that comes or goes as a type changes what its connections are.
        for id in pendingTypes.membership {
            scans.insert(id)
            recompile.formUnion(endsHolding[id] ?? [])
            for carrier in connectionCarriers(at: id) { out.arrows.insert(carrier); bump(carrier) }
        }
        // The arrows left bound to such a note at one end (a loose end whose relationship type is gone, which is one
        // only while the note is a type), or to a pill that names it: checked again, from the arrows kept for each shape
        // (`halvesAt`), never a pass over a board.
        for id in pendingTypes.membership {
            out.arrows.formUnion(halvesAt[id] ?? [])
            if !standInKinds.isEmpty { for pill in topology.standIns(naming: id) { out.arrows.formUnion(halvesAt[pill] ?? []) } }
        }
        // And what a list names resolves to something else: the rows kept for a list go, and the notes that name the shape
        // (a type deleted that they still name) are laid out again with the rows they have now.
        if !pendingTypes.membership.isEmpty, !ends.rows.isEmpty {
            revision &+= 1
            out.ended = true
            let reached = types.affected(by: pendingTypes.membership)
            out.notes.formUnion(reached)
            out.layout.formUnion(reached)
        }
        // A type's own list changed: its instances, near and far, read their rows from another place.
        // So does a list that is no type's (a type taken away that its instances still name): the chain runs
        // through it.
        var chains = pendingTypes.lineage
        for id in pendingTypes.lists where !types.isType(id) && types.hasInstances(id) { chains.insert(id) }
        if !chains.isEmpty {
            revision &+= 1
            out.ended = true
            let reached = types.affected(by: chains)
            out.notes.formUnion(reached)
            for type in marked { out.arrows.formUnion(types.instances(of: type)) }
            out.layout.formUnion(chains)
            out.layout.formUnion(reached.filter(types.isType))
        }
        // A shape's `is` list: its own stamp, and the connections at it (a relationship's two ends, a note's
        // connections).
        for id in pendingTypes.lists {
            // A shape that left the file keeps no stamp.
            guard let record = lookup(id) else { continue }
            if isHeld(id) {
                held.insert(id)
                continue
            }
            bump(id)
            if relatingKinds.contains(record.kind) {
                carriers.insert(id)
                out.arrows.insert(id)
                for edge in topology.edges(carriedBy: id, view: .recorded) where edge.isConnection { bump(edge.source); bump(edge.target) }
            } else {
                for carrier in connectionCarriers(at: id) { out.arrows.insert(carrier); bump(carrier) }
            }
        }
        // A rename of a relationship type or of a type at an end: a row's name, and no row's identity.
        if !pendingTypes.types.isEmpty {
            let named = Set(ends.rows.keys).union(ends.sides.keys)
            if !pendingTypes.types.isDisjoint(with: named) { out.rows = true }
        }

        // An arrow the commit only changed (a value typed on it, its words, its look), with its list and its place among the
        // ends as they were, changes nothing a note at its ends reads: it is named alone, no end rechecked and no row let go.
        // That is a commit that changed shapes in place and nothing else: no shape came, went or changed boards, no type or list
        // moved, and no edge the followers heard of (a re-aim is one).
        var valueOnly: Set<ShapeID> = []
        if changes.added.isEmpty, changes.removed.isEmpty, changes.elsewhere.isEmpty, pendingTypes.isEmpty, touched.isEmpty {
            for id in changes.changed where !changes.moved.contains(id) && !isHeld(id) && !held.contains(id)
                && lookup(id).map({ relatingKinds.contains($0.kind) }) == true {
                valueOnly.insert(id)
            }
        }
        let placed = valueOnly.reduce(into: [ShapeID: (type: ShapeID, side: RelationshipSide)?]()) { $0[$1] = endOf[$1] }
        reconcile(carriers: carriers, scanning: scans, recompiling: recompile, &out)
        // A relating arrow the commit names that is a relationship (its list names a marked type) is
        // re-read by whoever checks it.
        for id in carriers where endOf[id] == nil {
            if let list = lookup(id)?[IsAProperty.self], list.contains(where: { marked.contains($0.shape) }) {
                if valueOnly.contains(id) { out.values.insert(id) } else { out.arrows.insert(id) }
            }
        }
        // The ends of every connection named are notes whose relations may have changed. So are the ends of the
        // arrows of a type whose mark flipped: a relationship is an arrow of a marked type.
        for id in carriers {
            if let was = placed[id] {
                let now = endOf[id]
                if was?.type == now?.type, was?.side == now?.side { continue }
            }
            noteEnds(of: id, &out)
        }
        for id in pendingTypes.marks { for arrow in types.instances(of: id) { noteEnds(of: arrow, &out) } }
        // A shape that left the file keeps no stamp, whatever read it again on the way.
        if !stamps.isEmpty || !noteEndsOf.isEmpty {
            for id in gone {
                stamps[id] = nil
                noteEndsOf[id] = nil
            }
        }
        deliver(out)
    }

    /// Whether the commit changed nothing but connections a drag session is still changing (a hover of a port's drag or
    /// of a re-aim): they are held, and nothing the followers collected for them is read.
    private func holdsOnly(_ changes: ChangeSet) -> Bool {
        guard let editor, let touching = editor.session?.touching, !touching.isEmpty,
              changes.added.isEmpty, changes.removed.isEmpty, changes.elsewhere.isEmpty, !changes.replacedDocument,
              pendingTypes.types.isEmpty, pendingTypes.marks.isEmpty, pendingTypes.membership.isEmpty, pendingTypes.lineage.isEmpty,
              !pendingTypes.everything, pendingTypes.lists.isSubset(of: touching) else { return false }
        let named = changes.changed.subtracting(changes.moved)
        guard !named.isEmpty, named.isSubset(of: touching),
              named.allSatisfy({ id in editor.shape(inFile: id).map { relatingKinds.contains($0.kind) } ?? false }) else { return false }
        held.formUnion(named)
        return true
    }

    /// A drag session is done with `connection` (a port's drag released, a re-aim let go, Escape pressed): it is counted
    /// as it is now, as a commit that named it would have, in the same press and so the same undo step. The session
    /// still names it (`editor.session` is cleared when the press ends), so it is counted though it does. Nothing for
    /// a connection no session was changing.
    public func release(_ connection: ShapeID) {
        let wasHeld = held.remove(connection) != nil
        guard let editor, wasHeld || isHeld(connection) else { return }
        exempt = connection
        defer { exempt = nil }
        guard editor.shape(inFile: connection) != nil else {
            // Deleted: the commit that deleted it has been heard.
            stamps[connection] = nil
            return
        }
        guard isActive || endOf[connection] != nil else { return }
        var out = Announce()
        let marked = types.graph.relationshipTypes
        bump(connection)
        reconcile(carriers: [connection], scanning: [], recompiling: [], &out)
        // The relationship it is, or its type changed in the press: checked again, with the notes at its ends.
        if let list = editor.shape(inFile: connection)?[IsAProperty.self], list.contains(where: { marked.contains($0.shape) }) { out.arrows.insert(connection) }
        for edge in topology.edges(carriedBy: connection, view: .recorded) where edge.isConnection {
            bump(edge.source)
            bump(edge.target)
        }
        noteEnds(of: connection, &out)
        deliver(out)
    }

    /// The notes at the ends of a connection, as they are and as they were when it was last counted: their relations may
    /// have changed (a re-aim leaves a note as well as reaches one).
    private func noteEnds(of connection: ShapeID, _ out: inout Announce) {
        let now = currentNoteEnds(of: connection)
        // Types are in what is kept, for a type that stops being one while its arrow is held still has the arrow.
        for end in now.union(noteEndsOf[connection] ?? []) where !types.isType(end) && editor?.shape(inFile: end) != nil {
            out.notes.insert(end)
            bump(end)
        }
        noteEndsOf[connection] = now.isEmpty ? nil : now
    }

    private func currentNoteEnds(of connection: ShapeID) -> Set<ShapeID> {
        var now: Set<ShapeID> = []
        for edge in topology.edges(carriedBy: connection, view: .recorded) where edge.isConnection {
            for end in [edge.source, edge.target] { now.insert(end) }
        }
        return now
    }

    /// The connections of relating kinds drawn at a pill, as the arrows literally are: what they run to changes with
    /// the pill (re-pointed, its shape made private or public), though no end and no type moved, so whoever checks
    /// them reads them again.
    private func arrowsAt(pill: ShapeID, _ out: inout Announce) {
        guard let editor else { return }
        // And the arrows with a free end drawn at it: a loose end reads a pill that names a type as the type.
        for arrow in halvesAt[pill] ?? [] { out.arrows.insert(arrow); bump(arrow) }
        for edge in topology.edges(of: pill, .either, types: .all, view: .literal) where edge.isConnection {
            guard let kind = editor.shape(inFile: edge.carrier)?.kind, relatingKinds.contains(kind) else { continue }
            out.arrows.insert(edge.carrier)
            bump(edge.carrier)
            noteEnds(of: edge.carrier, &out)
        }
    }

    /// The relating shapes on the boards the marked types are on that are bound to one of them
    /// (`boundShapes(in:)`), one end free or not: when the mark is lost or comes back, what a loose end is
    /// changes with it. One pass over each board's records, whatever the number of marks.
    private func relatingShapes(boundToAny ids: Set<ShapeID>) -> Set<ShapeID> {
        guard let editor else { return [] }
        var byBoard: [BoardID: Set<ShapeID>] = [:]
        for id in ids { if let board = editor.file.board(containing: id) { byBoard[board, default: []].insert(id) } }
        var found: Set<ShapeID> = []
        let context = editor.shapeContext
        for (board, wanted) in byBoard {
            for record in editor.file[board].shapes where relatingKinds.contains(record.kind) && record.boundShapes(in: context).contains(where: wanted.contains) {
                found.insert(record.id)
            }
        }
        return found
    }
}

extension RelationshipIndex: EditorService {
    public func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        hear(changes, in: editor)
    }

    /// For a reader that may run before this service's turn (Find's): the type index hears first, then this.
    public func catchUp(_ changes: ChangeSet) {
        guard let editor else { return }
        hear(changes, in: editor)
    }

    /// A switch of board changes no relationship (the index is the file's), and works out no change set; a
    /// file put in place compiles again.
    public func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        heardRevision = editor.revision
        guard change.isFileReplaced else { return }
        clearPending()
        compileEverything()
        deliver(Announce(everything: true))
    }
}

extension CanvasEditor {
    /// The file's relationships (`RelationshipIndex`); nil without TypesPlugin.
    public var relationships: RelationshipIndex? { service(RelationshipIndex.self) }

    /// A drag session is done with the connection it was drawing or re-aiming (released, let go, cancelled): the
    /// relationships count it as it is. Called by whatever ends such a drag, on every way it ends; nothing for a
    /// connection no session was changing. In the press, so what it lays out is the press's step.
    public func connectionReleased(_ connection: ShapeID) {
        relationships?.release(connection)
    }
}

extension EndReading {
    /// The shape a reading judges, if it is one.
    var noteID: ShapeID? {
        if case .note(let id) = self { id } else { nil }
    }

    /// The note a row names, live or not yet admitted: the one a row shows a pill for.
    var namedNote: ShapeID? {
        switch self {
        case .note(let id), .notAdmitted(let id, _): id
        default: nil
        }
    }

    /// The note a row does not offer again: one it names, live or not yet admitted, since a pick of it would add a second
    /// relationship to it. Where a pick replaces what the row holds (`replacing`: its rule allows one) a note not yet admitted
    /// is offered, to be made so by the pick.
    func offeredNoMore(replacing: Bool) -> ShapeID? { replacing ? noteID : namedNote }
}

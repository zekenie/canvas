import Canvas
import Queries
import QueryLanguage
import Titles
import Topology

// The answers Constraints gives the core's two points. A place refuses a shape moved into a constraint's reach from
// outside it that doesn't match (`registrar.admission`), as a locked frame refuses a drop; a shape made there always
// goes in. And a shape a person places in a constrained place is written to fit first (`registrar.placementFit`):
// whatever each constraint's query says a shape is, written onto it.

extension ConstraintIndex {
    // MARK: Refusing

    /// What the places the arrivals come into say of them: each shape moved (not made here) into a constraint's reach
    /// from outside it, and, for a constraint that reaches anywhere inside, what it carries, judged by the
    /// constraint's standing query. A shape breaks it only on an answer of no: a shape the query is asking again (an
    /// edit does) by the last answer it had, so typing in a note never makes a place that refuses it take it; with none
    /// ever (new to the file or the query, words not interpreted, a query refused) it goes in, as does one the
    /// transaction wrote beyond where it is, whose answer is of what it was. Leaving a place is never refused, and a shape that stays under the same holder (a frame turned into a subboard puts what it held on its board) isn't coming in to a place that is its holder's. The refusal names the place's frame or subboard (the root's:
    /// none, so the arrivals shake) and says the first constraint broken. As cheap as a drag's hint needs: each
    /// arrival's places, and its carried shapes only under a constraint that reaches them.
    func judge(_ admission: Admission) -> Admission.Verdict {
        guard hasPlaces, let editor, let reading = admission.context.reading else { return .admits }
        let places = ReadingPlaces(reading: reading, registry: editor.registry)
        let committed = editor.withoutObservingDocument { editor.file }
        for arrival in admission.arrivals where !arrival.isNew {
            let chain = places.chain(from: arrival.to)
            let left = arrival.from.map { committedHolders(of: $0) } ?? []
            for (depth, holder) in chain.enumerated() {
                let keys = constraints(at: holder, in: places)
                guard !keys.isEmpty else { continue }
                // Directly in: it wasn't directly in this holder's place before (a frame turned into a subboard keeps
                // the holder and changes the place, so what it held isn't coming in). Anywhere inside: it wasn't under it.
                let entersDeep = !left.contains(holder)
                let staysUnderHolder = arrival.from.map(ConstraintTarget.init) == holder
                for key in keys {
                    switch key.constraint.reach {
                    case .children: guard depth == 0, !staysUnderHolder else { continue }
                    case .descendants: guard entersDeep else { continue }
                    }
                    var judged = [arrival.record]
                    if key.constraint.reach == .descendants { judged += carried(by: arrival, in: places) }
                    for record in judged where breaks(record, key, committed: committed) {
                        let shaking: Set<ShapeID> = holder.shape.map { [$0] } ?? []
                        return .refuses(shaking: shaking, saying: ConstraintsStyle.accepts(name(of: holder, in: places), key.constraint.says))
                    }
                }
            }
        }
        return .admits
    }

    /// A place's constraints, its own list as the reading has it.
    func constraints(at holder: ConstraintTarget, in places: ReadingPlaces) -> [PlacedConstraint] {
        switch holder {
        case .root:
            return constraints(of: .root, own: places.reading.fileValue(RootConstraintsProperty.self).constraints)
        case .shape(let id):
            guard let record = places.record(id), editor?.registry.isConstrainable(record.kind) == true else { return [] }
            return constraints(of: holder, own: record.ownConstraints)
        }
    }

    /// The holders of the places a shape in `place` was under in the file as committed: where an arrival leaves from.
    private func committedHolders(of place: ShapePlace) -> Set<ConstraintTarget> {
        guard let topology = editor?.topology else { return [.root] }
        var found: Set<ConstraintTarget> = [.root]
        let holder = ConstraintTarget(place)
        guard let id = holder.shape else { return found }
        found.insert(holder)
        for above in editor?.withoutObservingDocument({ topology.ancestors(of: id) }) ?? [] { found.insert(.shape(above)) }
        return found
    }

    /// What comes in with an arrival: what it holds on its board, as the transaction has it, and what the boards it
    /// and they own hold, as committed (a move takes a board's shapes along unchanged).
    private func carried(by arrival: Admission.Arrival, in places: ReadingPlaces) -> [AnyShapeRecord] {
        var ids = arrival.carried
        if let editor, let topology = editor.topology {
            let kinds = editor.registry.boardOwningKinds
            if !kinds.isEmpty {
                let owners = ([arrival.record] + arrival.carried.compactMap(places.record)).filter { kinds.contains($0.kind) }
                let known = Set(ids)
                for owner in owners {
                    for inside in editor.withoutObservingDocument({ topology.descendants(of: owner.id) }) where !known.contains(inside) {
                        ids.append(inside)
                    }
                }
            }
        }
        return ids.compactMap { places.record($0) }.filter { $0.box != nil && !$0.isOpaque }
    }

    /// Whether a shape coming in breaks a constraint: its standing query answered no (as it last did, while it asks
    /// again), and the transaction hasn't written it beyond where it is. One that comes back to the file (a cut's,
    /// pasted) by what was last answered of it as it left. The same in a try and in a commit.
    private func breaks(_ record: AnyShapeRecord, _ key: PlacedConstraint, committed: CanvasFile) -> Bool {
        guard let before = committed.record(record.id) else { return lastAnswer(record.id, of: record, for: key.constraint) == false }
        guard before.isSame(asIgnoringPlace: record) else { return false }
        return (standingAnswer(record.id, for: key.constraint) ?? sourceAnswer(record.id, of: before, for: key.constraint)) == false
    }

    // MARK: Naming

    /// What a place is called where a constraint is said of it: its holder's title; else, for a container, "This" and
    /// its kind ("This frame"), for a board's top level and the root (unnamed), "This board".
    func name(of holder: ConstraintTarget, in places: ReadingPlaces) -> String {
        name(of: holder) { places.record($0) }
    }

    /// The same, of the file as committed.
    public func name(of holder: ConstraintTarget) -> String {
        guard let editor else { return ConstraintsStyle.thisBoard }
        return name(of: holder) { id in editor.withoutObservingDocument { editor.file.record(id) } }
    }

    private func name(of holder: ConstraintTarget, record: (ShapeID) -> AnyShapeRecord?) -> String {
        guard let editor else { return ConstraintsStyle.thisBoard }
        switch holder {
        case .root:
            return editor.rootName.isEmpty ? ConstraintsStyle.thisBoard : editor.rootName
        case .shape(let id):
            guard let found = record(id) else { return ConstraintsStyle.thisBoard }
            if let title = editor.registry.title(of: found) { return title }
            if editor.registry.containingKinds.contains(found.kind) { return ConstraintsStyle.this(editor.registry.label(of: found.kind).name) }
            return ConstraintsStyle.thisBoard
        }
    }

    // MARK: Fitting

    /// A shape a person placed, written to fit where it landed: for each constraint that reaches its place (from the
    /// place directly; from any place at or above it, for one that reaches anywhere inside), the outermost place
    /// first and each place's lists from elsewhere before its own, what the constraint's query says a shape is
    /// (`queries.fit`), each over what the one before wrote. An open kind is spent by the first constraint that names
    /// the kind the shape is once it's written, whether it turned the shape into that kind or the shape was of it
    /// already: so a later one never turns it out of a kind an earlier one asked for. Words not interpreted and refused
    /// queries are passed over. Nil when nothing was written.
    func fit(_ fit: PlacementFit) -> AnyShapeRecord? {
        guard hasPlaces, let editor, let queries = editor.queries, let reading = fit.context.reading else { return nil }
        let places = ReadingPlaces(reading: reading, registry: editor.registry)
        let chain = places.chain(from: fit.place)
        var record = fit.record, isOpen = fit.kindIsOpen, wrote = false
        for (depth, holder) in chain.enumerated().reversed() {
            for key in constraints(at: holder, in: places) where key.reaches(depth: depth) {
                guard let text = text(of: key.constraint), stands(key.constraint) else { continue }
                if let made = queries.fit(record, toMatch: text, kindIsOpen: isOpen) {
                    record = made
                    wrote = true
                }
                if isOpen, Self.kinds(namedBy: text).contains(record.kind) { isOpen = false }
            }
        }
        return wrote && record != fit.record ? record : nil
    }

    /// The kinds a query's alternatives say their subject is (`tile, card`: both), through `:is` and `:where` as fitting
    /// reads them; none for one that names no kind (`:urgent`, `[finish="glossy"]`, `:not(tile)`).
    static func kinds(namedBy text: String) -> Set<ShapeKind> {
        guard let list = try? SelectorList(parsing: text) else { return [] }
        return kinds(namedBy: list)
    }

    private static func kinds(namedBy list: SelectorList) -> Set<ShapeKind> {
        var found: Set<ShapeKind> = []
        for selector in list.selectors {
            guard let subject = selector.compounds.last else { continue }
            if case .kind(let name, _)? = subject.head { found.insert(ShapeKind(rawValue: name)) }
            for case .pseudo(let pseudo) in subject.filters {
                guard pseudo.word == .is || pseudo.word == .where, case .selectors(let inner) = pseudo.argument else { continue }
                found.formUnion(kinds(namedBy: inner))
            }
        }
        return found
    }
}

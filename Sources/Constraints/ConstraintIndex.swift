import Adornments
import Canvas
import Foundation
import Queries
import QueryLanguage
import Topology
import Validation

/// Where a constraint's query stands: words not interpreted yet, a query the engine refused (it checks nothing and
/// refuses nothing), or one kept answered over the whole file.
public enum ConstraintQueryState: Equatable, Sendable {
    case notInterpreted
    case refused(QueryError)
    case standing
}

/// Every constrained place of the file and the shapes within its reach that break one of its constraints, kept by
/// each commit and by the answers of the standing queries it holds, one for each distinct query among the file's
/// constraints (a place's own, the root's, and what places have from elsewhere). What a commit costs it is what the
/// commit wrote and what that reaches: a shape that came into another place, its places (O(its depth)) and, under a
/// constraint that reaches anywhere inside, what it carries; a list that changed, the shapes within its reach. Never
/// the board. A shape whose answer is still to come keeps the verdict it had (none, for one new to a place), so a ring
/// doesn't blink while a standing query asks again, and takes its new one when the answer lands. While a standing
/// query it holds is asking, Topology is kept settling (`keepsSettling(edges: false)`), so `:invalid` and what waits
/// for verdicts waits for these.
@MainActor
@Observable
public final class ConstraintIndex {
    @ObservationIgnored weak var editor: CanvasEditor?

    /// A constrained place: its own list (the root's, for the root), the lists it has from elsewhere, the two as one
    /// (`placed`: the sources' in order, then its own, each once), those judged (`judged`: each constraint once, where
    /// it first comes, so one a place has from elsewhere and as its own, or from two types, says one issue), and who
    /// breaks each.
    private struct Place {
        var own: [Constraint] = []
        var sources: [ConstraintSource] = []
        var placed: [PlacedConstraint] = []
        var judged: [PlacedConstraint] = []
        var breakers: [PlacedConstraint: Set<ShapeID>] = [:]

        var isEmpty: Bool { placed.isEmpty }
    }

    /// A standing query the index holds, and the places' constraints that use it.
    private final class Held {
        let query: StandingQuery?
        var refusal: QueryError?
        /// For a refusal a shape's edge type can undo: the file's edge types when it was last asked, so it's asked again when they change.
        var edgeTypes: Set<EdgeTypeID>?
        /// For a refusal that names shapes by id (a container of a kind that holds none, `cannot_contain`): those shapes, since a
        /// commit that adds, removes or rewrites one can undo it. Read from the refusal as data, never its message.
        var named: Set<ShapeID> = []
        var users = 0
        /// Shapes judged by it while their answer was still to come: judged again as it next says anything.
        var awaiting: Set<ShapeID> = []

        init(query: StandingQuery?, refusal: QueryError?) {
            self.query = query
            self.refusal = refusal
        }

        /// What can undo a refusal: the file's edge types, for one that reads them; the shapes it names by id.
        func record(_ error: QueryError, presentEdgeTypes: @autoclosure () -> Set<EdgeTypeID>) {
            refusal = error
            edgeTypes = error.readsEdgeTypes ? presentEdgeTypes() : nil
            named = Set(error.shapesNamed.map(ShapeID.init))
        }

        /// Whether a commit wrote, brought or took a shape the refusal names.
        func isReached(by changes: ChangeSet) -> Bool {
            named.contains { changes.edited.contains($0) || changes.removed.contains($0) || changes.elsewhere.contains($0) }
        }
    }

    @ObservationIgnored private var places: [ConstraintTarget: Place] = [:]
    /// The constraints each shape breaks.
    @ObservationIgnored private var broken: [ShapeID: Set<PlacedConstraint>] = [:]
    @ObservationIgnored private var held: [String: Held] = [:]
    /// A constraint that holds names, as it is judged: the text it stands (its query with each title head a bound shape
    /// names written as that shape's id, while the shape is in the file), who has it, and the shapes it names. Only those
    /// with names; one with none is judged by its query as it is.
    private struct Judging {
        var text: String
        var users = 0
        let ids: Set<ShapeID>
        /// Which of `ids` were on a board the app can show when the text was worked out: a shape that moves between boards
        /// (an edit on another board) reads the text again only when this changes.
        var shown: Set<ShapeID> = []
        /// How many of each place's judged constraints it is.
        var places: [ConstraintTarget: Int] = [:]
    }
    @ObservationIgnored private var judging: [Constraint: Judging] = [:]
    /// The constraints in `judging` that name each shape: a commit that brings a shape into the file or takes it out looks
    /// these up and nothing else.
    @ObservationIgnored private var binders: [ShapeID: Set<Constraint>] = [:]
    /// The shapes a view shows the titles of (`observeNames`).
    @ObservationIgnored private var watched: Set<ShapeID> = []
    /// The holders (shapes that are no place) `sources(of:)` was asked of: what a file put in place tells, since no commit
    /// does. Let go of when the file has none of one.
    @ObservationIgnored private var asked: Set<ShapeID> = []
    /// For a rehearsal (`rehearsalDidBegin`): the index of the editor it was made of, whose answers stand in for the ones
    /// this one's queries never give (its clock is stopped). Read, for a shape the rehearsal hasn't written, never kept.
    @ObservationIgnored weak var source: ConstraintIndex?
    /// How many of the places' constraints reach anywhere inside: none, and a container moved costs only itself.
    @ObservationIgnored private var deep = 0
    /// The commit being heard, until the standing queries have heard it too: what it wrote has answers of the file
    /// before it.
    @ObservationIgnored private var unheard: ChangeSet?
    /// The shapes `unheard` wrote beyond where they are: `edited` and `elsewhere`, worked out once, the first time a shape is judged
    /// while the commit is heard (a shape is asked about each time): a commit that judges nothing builds none.
    @ObservationIgnored private var unheardWritten: Set<ShapeID>?
    @ObservationIgnored private var unheardRevision = -1
    /// Whether a commit is being heard: what changes then is told through the rule's `affected`, else `recheck`.
    @ObservationIgnored private var hearing = false
    /// The shapes whose verdicts the commit of `changedRevision` changed.
    @ObservationIgnored private var changedByCommit: Set<ShapeID> = []
    @ObservationIgnored private var changedRevision = -1
    /// Inherited lists said to have changed, read again once the change being delivered has settled.
    @ObservationIgnored private var inheritedDirty: Set<ShapeID>?
    /// The places whose breakers changed since what observes them was last told.
    @ObservationIgnored private var touchedPlaces: Set<ConstraintTarget> = []
    /// The containers whose funnel chip may have changed since Adornments was last told: a list read again, a breaker gained or
    /// lost.
    @ObservationIgnored private var chipsChanged: Set<ShapeID> = []
    @ObservationIgnored private var settling: SettleSource?
    /// Shapes gone from the file, with what the standing queries last answered of them, the oldest first: a cut's
    /// shapes pasted back are judged by these as long as they come back as they went, since the queries let go of a
    /// shape as it leaves. At most `goneLimit`.
    @ObservationIgnored private var gone: [ShapeID: (record: AnyShapeRecord, answers: [String: Bool])] = [:]
    @ObservationIgnored private var goneOrder: [ShapeID] = []
    #if DEBUG
    /// At most how many shapes gone from the file it remembers: lowered by a test that fills it.
    @ObservationIgnored public var goneLimit = 4096
    #else
    let goneLimit = 4096
    #endif
    /// The rename of the root being looked at, a turn after it's told: its breakers' issues say its name.
    @ObservationIgnored private var renaming: ScheduledTask?
    #if DEBUG
    /// How many shapes it has judged, and how many places' members it has gone through (a list read again): debug
    /// builds, for tests that hold what a commit costs.
    @ObservationIgnored public private(set) var shapesJudged = 0
    @ObservationIgnored public private(set) var placesWalked = 0
    /// How many constraints have been read again, for a shape they name that came or went (the text came out different).
    @ObservationIgnored public private(set) var constraintsRebound = 0
    /// How many times a constraint's query has been worked out against the file (parsed and each title looked up): by a list
    /// put in place, a name a write bound, or a shape it names coming or going. A commit that names no bound shape adds none.
    @ObservationIgnored public private(set) var constraintsRead = 0
    /// How many sets of what a commit wrote it has built (`edited` and `elsewhere` together): a commit builds at most one, and
    /// none while no place judges.
    @ObservationIgnored public private(set) var writtenSetsBuilt = 0
    #endif

    init(editor: CanvasEditor) {
        self.editor = editor
        settling = editor.topology?.keepsSettling(edges: false, feedsChecks: true) { [weak self] in self?.isBusy ?? false }
        rebuild()
        watchRootName()
    }

    isolated deinit {
        settling?.cancel()
        renaming?.cancel()
        for entry in held.values { entry.query?.stop() }
    }

    // MARK: What's known

    /// Whether a standing query it holds is still asking: verdicts are still to come.
    public var isBusy: Bool { held.values.contains { $0.query.map { !$0.isSettled && !$0.isStopped } ?? false } }

    /// Whether nothing it holds is still asking.
    public var isSettled: Bool { !isBusy }

    /// The constraints a place has (a frame or a subboard by its shape, or the root), the lists from elsewhere first,
    /// each in its order, then its own; none for a place with none. A constraint two of its lists have is listed from
    /// each, and judged once, from the first. Observed by the place.
    public func constraints(of place: ConstraintTarget) -> [PlacedConstraint] {
        access(keyPath: \.[observedPlace: place])
        return places[place]?.placed ?? []
    }

    /// The lists a place has from elsewhere, in order: as kept for a place, as `InheritedConstraints` gives them now for a shape that
    /// is none (a holder: a type note, the types it is built on), so one way in reaches containers and holders alike. Observed by the
    /// place (a holder's own key too, which what gives it lists tells: `inheritedConstraintsDidChange(of:)`), and by no commit else.
    public func sources(of place: ConstraintTarget) -> [ConstraintSource] {
        access(keyPath: \.[observedPlace: place])
        if let kept = places[place] { return kept.sources }
        guard case .shape(let id) = place else { return [] }
        asked.insert(id)
        return quietly { inheritedSources(of: id) }
    }

    /// The shapes within a place's reach that break any of its constraints. Observed by the place.
    public func breakers(of place: ConstraintTarget) -> Set<ShapeID> {
        access(keyPath: \.[observedPlace: place])
        guard let found = places[place] else { return [] }
        return found.breakers.values.reduce(into: Set()) { $0.formUnion($1) }
    }

    /// The shapes that break one constraint of a place. Observed by its place.
    public func breakers(of constraint: PlacedConstraint) -> Set<ShapeID> {
        access(keyPath: \.[observedPlace: constraint.place])
        return places[constraint.place]?.breakers[constraint] ?? []
    }

    /// Whether a place has the constraint now.
    public func has(_ constraint: PlacedConstraint) -> Bool {
        places[constraint.place]?.placed.contains(constraint) ?? false
    }

    /// The constraints a shape breaks, the place it's directly in first, then each above it, the root's last, each
    /// place's in its order. Observed by the shape.
    public func breaches(of id: ShapeID) -> [PlacedConstraint] {
        access(keyPath: \.[observedShape: id])
        guard let found = broken[id], !found.isEmpty else { return [] }
        var order: [ConstraintTarget] = quietly { committedChain(of: id) } ?? []
        for place in Set(found.map(\.place)) where !order.contains(place) { order.append(place) }
        return order.flatMap { place in (places[place]?.placed ?? []).filter { found.contains($0) } }
    }

    /// Where a constraint's query stands.
    public func state(of constraint: Constraint) -> ConstraintQueryState {
        guard let text = text(of: constraint) else { return .notInterpreted }
        if let refusal = held[text]?.refusal { return .refused(refusal) }
        if held[text]?.query != nil { return .standing }
        guard let queries = editor?.queries else { return .refused(ConstraintsStyle.noQueries) }
        do throws(QueryError) {
            _ = try queries.checkStored(text)
            return .standing
        } catch {
            return .refused(error)
        }
    }

    /// The standing query a constraint's query is kept answered by, if the index holds one.
    public func standingQuery(of constraint: Constraint) -> StandingQuery? { text(of: constraint).flatMap { held[$0]?.query } }

    /// The query a constraint is judged by (and fitted by): its own as written while it names no shape; with names, each
    /// title head a bound shape names written as that shape's id while it is in the file, else as it was written, so a shape
    /// renamed is the shape still. Nil for words not interpreted. It changes only when a shape it names comes or goes.
    public func text(of constraint: Constraint) -> String? {
        guard let query = constraint.query else { return nil }
        guard !constraint.names.isEmpty else { return query }
        return judging[constraint]?.text ?? resolved(constraint)
    }

    /// A constraint's query with its names as the file is now.
    private func resolved(_ constraint: Constraint) -> String {
        guard let query = constraint.query else { return "" }
        #if DEBUG
        constraintsRead += 1
        #endif
        return editor?.queries?.named(query, by: constraint.names, as: .ids) ?? query
    }

    /// The constraints a place is judged by, each once (`constraints(of:)` lists a repeat too, for its row).
    public func judged(of place: ConstraintTarget) -> [PlacedConstraint] { places[place]?.judged ?? [] }

    /// Whether any place has a constraint: with none, nothing is judged or fitted.
    var hasPlaces: Bool { !places.isEmpty }

    /// The lists a place has from elsewhere as kept, else as given now (a place the file doesn't hold yet).
    func keptSources(of place: ConstraintTarget) -> [ConstraintSource]? { places[place]?.sources }

    /// The constraints a place is judged by as a transaction has its own list (`own`), with what it has from elsewhere
    /// as the file holds it: each constraint once, where it first comes.
    func constraints(of place: ConstraintTarget, own: [Constraint]) -> [PlacedConstraint] {
        let sources: [ConstraintSource] = switch place {
        case .root: []
        case .shape(let id): places[place]?.sources ?? inheritedSources(of: id)
        }
        return distinct(placed(place, own: own, sources: sources))
    }

    /// Whether a shape matches a constraint's query, as its standing query last answered: nil while that's to come,
    /// for words not interpreted, and for a query the engine refused or the index doesn't hold.
    func answer(_ id: ShapeID, for constraint: Constraint) -> Bool? {
        guard let text = text(of: constraint), let query = held[text]?.query else { return nil }
        return query.answer(for: id)
    }

    /// The answer a shape is judged by where a refusal is decided: its standing query's, else, while the query asks it again (an
    /// edit does, at every keystroke), the last it had for it. Nil for one the query never answered (new to the file, or to the
    /// query), for words not interpreted and for a query the engine refused.
    func standingAnswer(_ id: ShapeID, for constraint: Constraint) -> Bool? {
        guard let text = text(of: constraint), let query = held[text]?.query else { return nil }
        return query.answer(for: id) ?? query.lastAnswer(for: id)
    }

    /// What the editor this one is a rehearsal of answers of a shape, when the rehearsal's file holds it (`record`) as the source's does
    /// (place aside): its answers are of that shape, and nothing the rehearsal wrote changes it. Nil for any other shape (the
    /// rehearsal's own, or one it rewrote), as for an editor that is no rehearsal.
    func sourceAnswer(_ id: ShapeID, of record: AnyShapeRecord, for constraint: Constraint) -> Bool? {
        guard let source, let held = source.editor,
              let there = held.withoutObservingDocument({ held.file.record(id) }), there.isSame(asIgnoringPlace: record) else { return nil }
        return source.standingAnswer(id, for: constraint)
    }

    /// The members of the places that read through a holder (their lists from it): the places that keep it among their sources, and
    /// the containers the contributions to `InheritedConstraints` say read through it (a place with no list yet is kept in no table).
    /// A place's directly inside, and what is anywhere inside it if `deeper` (the holder's list reaches so) or a list it has does.
    func membersReading(through holder: ShapeID, deeper: Bool, topology: TopologyIndex) -> Set<ShapeID> {
        guard let editor else { return [] }
        var readers = Set(places.compactMap { place, kept in kept.sources.contains { $0.holder == holder } ? place.shape : nil })
        for contribution in editor.registry.contributions(to: InheritedConstraints.self) {
            readers.formUnion(contribution.value.readers?(holder, editor) ?? [])
        }
        var found: Set<ShapeID> = []
        for place in readers {
            let reaches = deeper || (places[.shape(place)]?.placed.contains { $0.constraint.reach == .descendants } ?? false)
            found.formUnion(reaches ? topology.descendants(of: place) : topology.children(of: place))
        }
        return found
    }

    /// Whether the index holds a standing query for a constraint's query (not refused).
    func stands(_ constraint: Constraint) -> Bool { text(of: constraint).flatMap { held[$0]?.query } != nil }

    private subscript(observedPlace place: ConstraintTarget) -> Int { 0 }
    private subscript(observedShape id: ShapeID) -> Int { 0 }
    private subscript(observedName id: ShapeID) -> Int { 0 }

    /// Says that a view shows the titles of the shapes a constraint names: it is told when one of them is edited (a rename),
    /// and by no other commit.
    public func observeNames(of constraint: Constraint) {
        for id in constraint.names.values {
            watched.insert(id)
            access(keyPath: \.[observedName: id])
        }
    }

    /// Whether a shape is on a board the app can show.
    private func isShown(_ id: ShapeID) -> Bool {
        guard let editor, let board = editor.file.board(containing: id) else { return false }
        return editor.canShow(board)
    }

    // MARK: Lists given from elsewhere

    /// Says that what `InheritedConstraints` gives these shapes changed with no commit to them (a type's list
    /// written): they're asked again once the change being delivered has settled (at once outside one). A shape that is no place (a
    /// holder: a type note) is told to what observes its sources (`sources(of:)`) and read no more.
    public func inheritedConstraintsDidChange(of ids: some Sequence<ShapeID>) {
        inheritedDirty = (inheritedDirty ?? []).union(ids)
        editor?.onceSettled { [weak self] in self?.readInherited() }
    }

    private func readInherited() {
        guard let ids = inheritedDirty, let editor else { return }
        inheritedDirty = nil
        var changed: Set<ShapeID> = [], holders: [ShapeID] = []
        quietly {
            for id in ids {
                guard let record = editor.file.record(id) else { continue }
                guard editor.registry.isConstrainable(record.kind) else {
                    holders.append(id)
                    continue
                }
                read(.shape(id), own: record.ownConstraints, sources: inheritedSources(of: id), into: &changed)
            }
        }
        for id in holders { withMutation(keyPath: \.[observedPlace: .shape(id)]) {} }
        tell(changed)
    }

    /// Tells every holder `sources(of:)` was asked of, that the file still has, that what gives it lists may have changed: a
    /// file put in place changes them with no commit to them. The ones the file has none of are let go of.
    private func tellHolders() {
        guard let editor, !asked.isEmpty else { return }
        let file = editor.withoutObservingDocument { editor.file }
        let held = asked.filter { file.record($0) != nil }
        asked = held
        for id in held { withMutation(keyPath: \.[observedPlace: .shape(id)]) {} }
    }

    /// What every contribution to `InheritedConstraints` that reaches a shape's kind gives it, in plugin order.
    private func inheritedSources(of id: ShapeID) -> [ConstraintSource] {
        guard let editor, let kind = editor.file.record(id)?.kind else { return [] }
        return editor.registry.contributions(to: InheritedConstraints.self, for: kind).flatMap { $0.sources(id, editor) }
    }

    /// A place's constraints, as a place has them: each source's (once), then its own.
    private func placed(_ place: ConstraintTarget, own: [Constraint], sources: [ConstraintSource]) -> [PlacedConstraint] {
        var seen: Set<PlacedConstraint> = [], made: [PlacedConstraint] = []
        for source in sources {
            for constraint in source.constraints {
                let each = PlacedConstraint(place: place, origin: .inherited(source.holder), constraint: constraint)
                if seen.insert(each).inserted { made.append(each) }
            }
        }
        for constraint in own {
            let each = PlacedConstraint(place: place, origin: .own, constraint: constraint)
            if seen.insert(each).inserted { made.append(each) }
        }
        return made
    }

    /// Of a place's constraints, those judged: each constraint once, where it first comes (a list from elsewhere before
    /// its own), so the same words from two lists are one issue, from the first.
    private func distinct(_ placed: [PlacedConstraint]) -> [PlacedConstraint] {
        // By its words, the query it is judged by and its reach: two that name different shapes judge differently and are
        // both kept; the same constraint bound at two times is judged by the same text, and is one. A rebind (a shape it
        // names came or went) changes a text, so the places that have it read again (`rebind`).
        struct Value: Hashable {
            let says: String, text: String?, reach: ConstraintReach
        }
        var seen: Set<Value> = []
        return placed.filter { seen.insert(Value(says: $0.constraint.says, text: text(of: $0.constraint), reach: $0.constraint.reach)).inserted }
    }

    // MARK: Hearing the file

    /// Every place read again, and every shape within reach of one judged: as it's made, and when a document or a
    /// file is put in place.
    private func rebuild() {
        guard let editor else { return }
        var changed: Set<ShapeID> = []
        for place in Array(places.keys) { drop(place, into: &changed) }
        for (id, _) in broken { forget(id, into: &changed) }
        quietly {
            let file = editor.file, registry = editor.registry
            for board in file.showableBoards(boardOwningKinds: registry.boardOwningKinds) {
                for record in file[board].shapes where registry.isConstrainable(record.kind) {
                    read(.shape(record.id), own: record.ownConstraints, sources: inheritedSources(of: record.id), into: &changed)
                }
            }
            read(.root, own: file[RootConstraintsProperty.self].constraints, sources: [], into: &changed)
        }
        tell(changed)
        // The holders: what gives a holder its lists (Types, from its schemas) hears the file in a round after this one, so they
        // are told once every service has settled it, as `inheritedConstraintsDidChange` waits.
        if !asked.isEmpty { editor.onceSettled { [weak self] in self?.tellHolders() } }
    }

    /// A commit: the places whose lists it wrote read again, and the shapes that came into another place judged
    /// again where they are now.
    private func hear(_ changes: ChangeSet) {
        guard let editor else { return }
        if changes.replacedDocument {
            rebuild()
            return
        }
        guard !changes.onlyMoves || !changes.fileValues.isEmpty else { return }
        unheard = changes
        unheardWritten = nil
        unheardRevision = editor.revision
        hearing = true
        defer { hearing = false }
        var changed: Set<ShapeID> = []
        quietly {
            let file = editor.file, registry = editor.registry
            // Lists: a place's own, or what it has from elsewhere (its type changed); a place gone; the root's. Every shape the
            // commit wrote or took, gone through where it is, with no set of them built (a commit of 50,000 shapes in a file
            // with no places costs a pass over them): one named twice (a shape taken from this board and put on another) reads
            // again as kept, and costs nothing.
            forEachWritten(by: changes, includingRemoved: true) { id in
                guard let record = file.record(id) else {
                    if places[.shape(id)] != nil { drop(.shape(id), into: &changed) }
                    return
                }
                guard registry.isConstrainable(record.kind) else {
                    // Turned into a kind that holds no constraints: its place goes.
                    if places[.shape(id)] != nil { drop(.shape(id), into: &changed) }
                    return
                }
                read(.shape(id), own: record.ownConstraints, sources: inheritedSources(of: id), into: &changed)
                // What it's called may be in its breakers' issues.
                if let found = places[.shape(id)] { for each in found.breakers.values { changed.formUnion(each) } }
            }
            if changes.fileValues.contains(RootConstraintsProperty.key) {
                read(.root, own: file[RootConstraintsProperty.self].constraints, sources: [], into: &changed)
            }
            // What a view that shows the titles of named shapes shows: the shapes edited, come or gone.
            for id in watched where changes.added.contains(id) || changes.removed.contains(id) || changes.elsewhere.contains(id)
                || (changes.changed.contains(id) && !changes.moved.contains(id)) {
                withMutation(keyPath: \.[observedName: id]) {}
            }
            guard !places.isEmpty || !broken.isEmpty else { return }
            // Shapes that came into another place, or left the file.
            var moved: Set<ShapeID> = changes.added.union(changes.elsewhere).union(changes.removed)
            for id in changes.changed where !changes.moved.contains(id) {
                if changes.before(id)?.container != file.record(id)?.container { moved.insert(id) }
            }
            for id in moved {
                guard file.record(id) != nil else {
                    remember(id, as: changes.before(id))
                    forget(id, into: &changed)
                    continue
                }
                if gone[id] != nil { gone[id] = nil }
                judge(id, into: &changed)
                // What it carries comes into whatever it comes into: judged again under what reaches anywhere inside.
                if deep > 0, registry.containerKinds.contains(file.record(id)?.kind ?? "") {
                    for inside in editor.topology?.descendants(of: id) ?? [] where !moved.contains(inside) { judge(inside, into: &changed) }
                }
            }
            // A query the engine refused may read now that the file has changed (an edge type a shape brings in, a type).
            if !changes.edited.isEmpty || !changes.removed.isEmpty || !changes.elsewhere.isEmpty { retryRefused(after: changes, into: &changed) }
            // A shape a constraint names that came or went: that constraint is read again, and no other.
            if !judging.isEmpty {
                var named: Set<Constraint> = []
                for id in changes.added.union(changes.removed) { if let found = binders[id] { named.formUnion(found) } }
                // An edit on another board (a rename, a move): the text is read again only when the shape came on to, or went
                // off, the boards the app can show.
                for id in changes.elsewhere where !changes.added.contains(id) && !changes.removed.contains(id) {
                    for constraint in binders[id] ?? [] where judging[constraint]?.shown.contains(id) != isShown(id) { named.insert(constraint) }
                }
                for constraint in named { rebind(constraint, into: &changed) }
            }
        }
        tell(changed)
    }

    /// Calls `body` for each shape a commit wrote beyond where it is or reached on another board, and, if asked, each it took out
    /// of the file: no set built, so one named twice is called twice.
    private func forEachWritten(by changes: ChangeSet, includingRemoved: Bool = false, _ body: (ShapeID) -> Void) {
        for id in changes.added { body(id) }
        for id in changes.changed where !changes.moved.contains(id) { body(id) }
        for id in changes.elsewhere { body(id) }
        if includingRemoved { for id in changes.removed { body(id) } }
    }

    // MARK: Places

    /// A place's lists read again: what it gained is judged over the shapes within its reach, what it lost lets them
    /// go. Nothing when they are as kept. What it gained is held before what it lost is let go of, so a constraint
    /// changed but for its query (its reach, its words) keeps the query standing, and its answers: the members are
    /// judged by them at once, with no whole file asked again.
    private func read(_ place: ConstraintTarget, own: [Constraint], sources: [ConstraintSource], force: Bool = false, into changed: inout Set<ShapeID>) {
        let made = placed(place, own: own, sources: sources)
        let old = places[place]
        guard old != nil || !made.isEmpty, force || old?.placed != made || old?.sources != sources || old?.own != own else { return }
        let judged = distinct(made)
        let before = Set(old?.judged ?? []), after = Set(judged)
        let gained = after.subtracting(before)
        for each in gained { hold(each) }
        var kept = old ?? Place()
        for gone in before.subtracting(after) {
            for id in kept.breakers[gone] ?? [] {
                broken[id]?.remove(gone)
                if broken[id]?.isEmpty == true { broken[id] = nil }
                changed.insert(id)
            }
            kept.breakers[gone] = nil
            release(gone)
        }
        kept.own = own
        kept.sources = sources
        kept.placed = made
        kept.judged = judged
        places[place] = made.isEmpty ? nil : kept
        withMutation(keyPath: \.[observedPlace: place]) {}
        if let holder = place.shape { chipsChanged.insert(holder) }
        guard !gained.isEmpty else { return }
        judgeMembers(of: place, for: gained, into: &changed)
    }

    /// A place gone: its constraints let go of, and the shapes that broke them.
    private func drop(_ place: ConstraintTarget, into changed: inout Set<ShapeID>) {
        read(place, own: [], sources: [], into: &changed)
    }

    /// The shapes within reach of a place's constraints `keys`, each judged by those: its members, in the place
    /// directly or anywhere under it as each reaches.
    private func judgeMembers(of place: ConstraintTarget, for keys: Set<PlacedConstraint>, into changed: inout Set<ShapeID>) {
        guard let editor, let topology = editor.topology else { return }
        #if DEBUG
        placesWalked += 1
        #endif
        let reachesDeep = keys.contains { $0.constraint.reach == .descendants }
        let file = editor.file, registry = editor.registry
        var direct: [ShapeID] = [], under: [ShapeID] = []
        switch place {
        case .shape(let id):
            direct = topology.children(of: id)
            if reachesDeep { under = topology.descendants(of: id) }
        case .root:
            for record in file.root.shapes where topology.parent(of: record.id) == nil { direct.append(record.id) }
            if reachesDeep {
                for board in file.showableBoards(boardOwningKinds: registry.boardOwningKinds) { under += file[board].shapes.map(\.id) }
            }
        }
        let directSet = Set(direct)
        for id in Set(direct).union(under) {
            guard let record = file.record(id), record.box != nil, !record.isOpaque else { continue }
            let depth = directSet.contains(id) ? 0 : 1
            #if DEBUG
            shapesJudged += 1
            #endif
            for key in keys where key.reaches(depth: depth) {
                set(key, on: id, breaks: breaks(id, key), into: &changed)
            }
        }
    }

    // MARK: Shapes

    /// A shape judged again by every constraint whose reach it's in now, where it is now: what reaches it comes and
    /// goes with where it is.
    private func judge(_ id: ShapeID, only text: String? = nil, into changed: inout Set<ShapeID>) {
        guard let editor, let record = editor.file.record(id), record.box != nil, !record.isOpaque else {
            forget(id, into: &changed)
            return
        }
        #if DEBUG
        shapesJudged += 1
        #endif
        let reaching = reachingConstraints(of: id)
        let old = broken[id] ?? []
        for key in old where !reaching.contains(key) && (text == nil || self.text(of: key.constraint) == text) {
            set(key, on: id, breaks: false, into: &changed)
        }
        for key in reaching where text == nil || self.text(of: key.constraint) == text {
            set(key, on: id, breaks: breaks(id, key), into: &changed)
        }
    }

    /// Every constraint whose reach a shape is in, by where it is in the file as committed.
    private func reachingConstraints(of id: ShapeID) -> Set<PlacedConstraint> {
        guard let chain = committedChain(of: id) else { return [] }
        var found: Set<PlacedConstraint> = []
        for (depth, holder) in chain.enumerated() {
            guard let place = places[holder] else { continue }
            for key in place.judged where key.reaches(depth: depth) { found.insert(key) }
        }
        return found
    }

    /// The holders of the places a shape is in, as committed, nearest first, the root last; nil for a shape on no
    /// board the app can show.
    private func committedChain(of id: ShapeID) -> [ConstraintTarget]? {
        guard let editor, let topology = editor.topology, let board = editor.file.board(containing: id) else { return nil }
        let above = topology.ancestors(of: id)
        guard !above.isEmpty || board == .root else { return nil }
        return above.map(ConstraintTarget.shape) + [.root]
    }

    /// Whether a shape breaks a constraint now: its query's answer; while that's to come (or the commit being heard
    /// wrote the shape, and the query hasn't heard it), what it was, and the shape waits for its answer. A constraint
    /// not interpreted, or whose query the engine refused, is broken by nothing.
    private func breaks(_ id: ShapeID, _ key: PlacedConstraint) -> Bool {
        guard let text = text(of: key.constraint), let entry = held[text], let query = entry.query else { return false }
        let was = broken[id]?.contains(key) ?? false
        if isUnheard(id) || query.isPending(id) {
            entry.awaiting.insert(id)
            return was
        }
        return !query.matches.contains(id)
    }

    /// Whether the commit being heard wrote the shape beyond where it is, and its standing queries haven't heard it.
    private func isUnheard(_ id: ShapeID) -> Bool {
        guard let changes = unheard, unheardRevision == editor?.revision else { return false }
        if unheardWritten == nil {
            unheardWritten = changes.edited.union(changes.elsewhere)
            #if DEBUG
            writtenSetsBuilt += 1
            #endif
        }
        guard unheardWritten?.contains(id) == true else { return false }
        guard let before = changes.before(id), let now = editor?.file.record(id) else { return true }
        return !before.isSame(asIgnoringPlace: now)
    }

    /// Records whether a shape breaks a constraint.
    private func set(_ key: PlacedConstraint, on id: ShapeID, breaks: Bool, into changed: inout Set<ShapeID>) {
        let had = broken[id]?.contains(key) ?? false
        guard had != breaks, places[key.place] != nil else { return }
        if breaks {
            broken[id, default: []].insert(key)
            places[key.place]?.breakers[key, default: []].insert(id)
        } else {
            broken[id]?.remove(key)
            if broken[id]?.isEmpty == true { broken[id] = nil }
            places[key.place]?.breakers[key]?.remove(id)
            if places[key.place]?.breakers[key]?.isEmpty == true { places[key.place]?.breakers[key] = nil }
        }
        changed.insert(id)
        touchedPlaces.insert(key.place)
    }

    /// A shape that left the file, as it was, with its standing queries' last answers (a query asking it again: the one it had),
    /// before they let it go.
    private func remember(_ id: ShapeID, as record: AnyShapeRecord?) {
        guard let record, record.box != nil else { return }
        var answers: [String: Bool] = [:]
        for (text, entry) in held { if let answer = entry.query?.answer(for: id) ?? entry.query?.lastAnswer(for: id) { answers[text] = answer } }
        guard !answers.isEmpty else { return }
        if gone.updateValue((record, answers), forKey: id) == nil { goneOrder.append(id) }
        guard goneOrder.count > goneLimit else { return }
        let dropped = goneOrder.prefix(goneOrder.count / 2)
        for each in dropped { gone[each] = nil }
        goneOrder.removeFirst(dropped.count)
    }

    /// What a shape gone from the file was last answered by a query, if it comes back as it went.
    func lastAnswer(_ id: ShapeID, of record: AnyShapeRecord, for constraint: Constraint) -> Bool? {
        guard let text = text(of: constraint), let kept = gone[id], kept.record.isSame(asIgnoringPlace: record) else { return nil }
        return kept.answers[text]
    }

    /// A shape gone from the file, or with no box: it breaks nothing.
    private func forget(_ id: ShapeID, into changed: inout Set<ShapeID>) {
        for key in broken[id] ?? [] { set(key, on: id, breaks: false, into: &changed) }
        for entry in held.values { entry.awaiting.remove(id) }
    }

    // MARK: Standing queries

    /// A constraint's query held for one more user: stood the first time (a query `stand` refuses is kept refused).
    private func hold(_ key: PlacedConstraint) {
        if key.constraint.reach == .descendants { deep += 1 }
        guard let text = register(key) else { return }
        if let entry = held[text] {
            entry.users += 1
            return
        }
        let entry = stand(text)
        entry.users = 1
        held[text] = entry
    }

    private func stand(_ text: String) -> Held {
        guard let queries = editor?.queries else { return Held(query: nil, refusal: ConstraintsStyle.noQueries) }
        do throws(QueryError) {
            let query = try queries.stand(text)
            query.onChange = { [weak self] change in self?.heard(change, of: text) }
            return Held(query: query, refusal: nil)
        } catch {
            let refused = Held(query: nil, refusal: error)
            refused.record(error, presentEdgeTypes: queries.presentEdgeTypes)
            return refused
        }
    }

    /// A constraint's query let go of by one user: stopped with the last.
    private func release(_ key: PlacedConstraint) {
        if key.constraint.reach == .descendants { deep -= 1 }
        guard let text = unregister(key), let entry = held[text] else { return }
        entry.users -= 1
        guard entry.users <= 0 else { return }
        entry.query?.stop()
        held[text] = nil
        if entry.query != nil { editor?.topology?.settleSourceChanged() }
    }

    /// A judged constraint counted for its place: the text it stands, nil for words not interpreted. One that names shapes is
    /// kept in `judging` (its text resolved once, and the shapes it names looked up by `binders`).
    private func register(_ key: PlacedConstraint) -> String? {
        guard let query = key.constraint.query else { return nil }
        guard !key.constraint.names.isEmpty else { return query }
        if var entry = judging[key.constraint] {
            entry.users += 1
            entry.places[key.place, default: 0] += 1
            judging[key.constraint] = entry
            return entry.text
        }
        let ids = Set(key.constraint.names.values)
        var entry = Judging(text: resolved(key.constraint), users: 1, ids: ids, places: [key.place: 1])
        entry.shown = ids.filter { isShown($0) }
        judging[key.constraint] = entry
        for id in ids { binders[id, default: []].insert(key.constraint) }
        return entry.text
    }

    /// The reverse of `register`: the text the constraint was standing.
    private func unregister(_ key: PlacedConstraint) -> String? {
        guard let query = key.constraint.query else { return nil }
        guard !key.constraint.names.isEmpty else { return query }
        guard var entry = judging[key.constraint] else { return resolved(key.constraint) }
        entry.users -= 1
        entry.places[key.place, default: 1] -= 1
        if entry.places[key.place] ?? 0 <= 0 { entry.places[key.place] = nil }
        if entry.users <= 0 {
            judging[key.constraint] = nil
            for id in entry.ids {
                binders[id]?.remove(key.constraint)
                if binders[id]?.isEmpty == true { binders[id] = nil }
            }
        } else {
            judging[key.constraint] = entry
        }
        return entry.text
    }

    /// A shape a constraint names came into the file or left it: the constraint's text is read again, and when it differs
    /// (the id was written while the shape was there, and the title as written when it isn't) its places move to the query
    /// that is the text now: held before the old one is let go of, the members of the places that have it judged by it. A
    /// rename comes here never: the id is the same text.
    private func rebind(_ constraint: Constraint, into changed: inout Set<ShapeID>) {
        guard var entry = judging[constraint] else { return }
        let text = resolved(constraint)
        entry.shown = entry.ids.filter { isShown($0) }
        judging[constraint] = entry
        guard text != entry.text else { return }
        #if DEBUG
        constraintsRebound += 1
        #endif
        let old = entry.text, users = entry.users
        entry.text = text
        judging[constraint] = entry
        if let known = held[text] {
            known.users += users
        } else {
            let fresh = stand(text)
            fresh.users = users
            held[text] = fresh
        }
        if let gone = held[old] {
            gone.users -= users
            if gone.users <= 0 {
                gone.query?.stop()
                held[old] = nil
                if gone.query != nil { editor?.topology?.settleSourceChanged() }
            }
        }
        for place in entry.places.keys {
            // The text changed, so which of the place's constraints judge alike may have: its list is read again.
            if let kept = places[place] { read(place, own: kept.own, sources: kept.sources, force: true, into: &changed) }
            let keys = Set((places[place]?.judged ?? []).filter { $0.constraint == constraint })
            if !keys.isEmpty { judgeMembers(of: place, for: keys, into: &changed) }
        }
    }

    /// Queries the engine refused that a commit can undo, asked again on the commits that could: one for an edge type no plugin
    /// declares, when the file's edge types are not what they were (a commit on any board that brings one); one that names a
    /// shape by id as a container of a kind that holds none, when a commit adds, removes or rewrites that shape (its kind is
    /// read from the file when the query is checked). One that reads now is stood, and the shapes within reach of the
    /// constraints that use it judged by it. Every other refusal stands as it is (the registry's words, which no commit
    /// changes), so a commit costs no refused query a parse unless it reaches what the refusal read.
    private func retryRefused(after changes: ChangeSet, into changed: inout Set<ShapeID>) {
        guard let queries = editor?.queries else { return }
        var present: Set<EdgeTypeID>?
        for (text, entry) in held where entry.refusal != nil {
            var undoable = entry.isReached(by: changes)
            if let tried = entry.edgeTypes {
                let now = present ?? queries.presentEdgeTypes
                present = now
                if now != tried { undoable = true }
            }
            guard undoable else { continue }
            do throws(QueryError) {
                _ = try queries.checkStored(text)
            } catch {
                entry.record(error, presentEdgeTypes: present ?? queries.presentEdgeTypes)
                continue
            }
            let fresh = stand(text)
            fresh.users = entry.users
            held[text] = fresh
            for (place, found) in places {
                let keys = Set(found.judged.filter { self.text(of: $0.constraint) == text })
                if !keys.isEmpty { judgeMembers(of: place, for: keys, into: &changed) }
            }
        }
    }

    /// A standing query said something: the shapes that flipped, and those waiting for an answer, judged by it again.
    private func heard(_ change: StandingQueryChange, of text: String) {
        guard let entry = held[text] else { return }
        let waiting = entry.awaiting
        entry.awaiting = []
        var changed: Set<ShapeID> = []
        quietly {
            for id in judgeable(change.flipped, by: text).union(waiting) { judge(id, only: text, into: &changed) }
        }
        tell(changed)
        if change.isSettled || !change.flipped.isEmpty { editor?.topology?.settleSourceChanged() }
    }

    /// At most how many flips of one answer are each judged as they come: more (a whole file answered) are narrowed to
    /// the shapes within reach first.
    private static let flipsJudgedAlone = 32

    /// Of the shapes a query's answer flipped, those whose verdicts it may change: few (what a commit wrote), each;
    /// many (the whole file answered), only those within reach of a place whose constraints use the query and those
    /// that break one now, so a first answer of `:not(tile)` over a board of 5,000 shapes costs the places' members,
    /// never the board. The root's anywhere-inside reach is the file: then every flip.
    private func judgeable(_ flipped: Set<ShapeID>, by text: String) -> Set<ShapeID> {
        guard flipped.count > Self.flipsJudgedAlone, let editor, let topology = editor.topology else { return flipped }
        var within: Set<ShapeID> = []
        for (target, place) in places {
            let keys = place.judged.filter { self.text(of: $0.constraint) == text }
            guard !keys.isEmpty else { continue }
            for key in keys { within.formUnion(place.breakers[key] ?? []) }
            let reachesDeep = keys.contains { $0.constraint.reach == .descendants }
            switch target {
            case .shape(let id):
                within.formUnion(reachesDeep ? topology.descendants(of: id) : topology.children(of: id))
            case .root:
                guard !reachesDeep else { return flipped }
                for record in editor.file.root.shapes where topology.parent(of: record.id) == nil { within.insert(record.id) }
            }
        }
        return flipped.intersection(within)
    }

    // MARK: The root's name

    /// What the root is called, watched: its breakers' issues say it, and a rename is no commit. Observation tells as it's
    /// about to change, so they're checked again then (Validation checks them when next read, by the new name) and the
    /// watch is armed again a turn later, when it has.
    private func watchRootName() {
        guard let editor else { return }
        _ = withObservationTracking { editor.rootName } onChange: { [weak self] in
            MainActor.assumeIsolated { self?.rootNameWillChange() }
        }
    }

    private func rootNameWillChange() {
        guard let editor else { return }
        recheckRootBreakers()
        guard renaming == nil else { return }
        renaming = editor.scheduler.schedule(after: .zero) { [weak self] in
            guard let self else { return }
            renaming = nil
            watchRootName()
            // Again, for a second rename in the turn the first was told in, which no watch heard.
            recheckRootBreakers()
        }
    }

    private func recheckRootBreakers() {
        guard let root = places[.root] else { return }
        editor?.validation?.recheck(root.breakers.values.reduce(into: Set()) { $0.formUnion($1) })
    }

    // MARK: Telling

    /// The shapes whose verdicts changed: what observes them is told, and Validation checks them again, through the
    /// rule's `affected` for the commit being heard, else at once (`recheck`).
    private func tell(_ changed: Set<ShapeID>) {
        let touched = touchedPlaces
        touchedPlaces = []
        for place in touched { withMutation(keyPath: \.[observedPlace: place]) {} }
        chipsChanged.formUnion(touched.compactMap(\.shape))
        if !chipsChanged.isEmpty {
            let chips = chipsChanged
            chipsChanged = []
            editor?.adornmentsDidChange(for: chips)
        }
        guard !changed.isEmpty, let editor else { return }
        for id in changed { withMutation(keyPath: \.[observedShape: id]) {} }
        if hearing {
            if changedRevision != editor.revision {
                changedRevision = editor.revision
                changedByCommit = []
            }
            changedByCommit.formUnion(changed)
        } else {
            editor.validation?.recheck(changed)
        }
    }

    /// The shapes whose verdicts a commit changed (the rule's `affected`): asked once services have heard it.
    func changed(by changes: ChangeSet) -> Set<ShapeID> {
        guard let editor, changedRevision == editor.revision else { return [] }
        return changedByCommit
    }

    private func quietly<T>(_ body: () -> T) -> T {
        guard let editor else { return body() }
        return editor.withoutObservingDocument(body)
    }
}

extension ConstraintIndex: EditorService {
    public func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        hear(changes)
    }

    /// Once the standing queries have heard the commit (they hear it as it settles), what it wrote has their answers.
    public func documentDidSettle(_ changes: ChangeSet, in editor: CanvasEditor) {
        editor.onceSettled { [weak self] in
            self?.unheard = nil
            self?.unheardWritten = nil
        }
    }

    public func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        guard change.isFileReplaced else { return }
        rebuild()
    }

    public func rehearsalDidBegin(from source: CanvasEditor, in editor: CanvasEditor) {
        self.source = source.constraintIndex
    }
}

extension CanvasEditor {
    /// The file's constrained places and what breaks them: nil without `ConstraintsPlugin`.
    public var constraintIndex: ConstraintIndex? { service(ConstraintIndex.self) }
}

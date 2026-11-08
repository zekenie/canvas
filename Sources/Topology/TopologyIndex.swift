import Canvas
import Observation

/// The file's edges, one per editor (`editor.topology`): every edge the shapes on the boards the
/// editor can show carry, by carrier, by each end and by type, derived from the records and never
/// saved. It never transacts: it follows the file.
///
/// It's read whole as the editor opens (every board it can show: the root, then down through each
/// owner of a board it can show, as `canShow` has it), and again for a board or file put in place.
/// Each commit then costs what it changed: the records it added or changed (not those it only moved:
/// `ChangeSet.moved`), removed, or touched on other boards (`elsewhere`: the boards a deletion took
/// or a paste brought, a write to a board that isn't shown) are read again, a kind with no source
/// costing a lookup. Undo and redo are commits like any other. Showing another board reads nothing:
/// the index is the file's. A carrier on a board the editor can't show carries nothing.
///
/// Queries cost what they return: a shape's edges read its own, a type's its own, never a board's.
/// A service that reads it as services take a commit in has it take the commit in first (looking it up
/// does), and its followers hear once it has (`editor.onceHeard`).
///
/// Stand-ins (`EdgeForwarding`) forward: every read gives the edges as they resolve through them
/// unless it asks for another view (`EdgeView`), each read from the same tables, which keep what
/// carriers emitted and what each stand-in stands for, and no copies (`EdgeTables`). A commit
/// re-reads, beside the carriers it changed, the stand-ins it changed, and looks again at only the
/// shapes it changed among those a stand-in's record names (or its answer holds): still what it
/// changed, however many shapes a stand-in stands for, and a move reads nothing. Answers for
/// stand-ins that stand for what's provided come with no commit (`provide`), worked out on another
/// thread first if the provider likes (`preparer()`), so the main actor takes in only what came and
/// went.
///
/// Every change to the edges, a commit's or a provide's, is told once to each follower (`follow`):
/// the one way to hear one. Whoever provides answers says while it has work (`keepsSettling`), so a
/// reader can wait for the edges to settle (`settled(timeout:)`).
/// What's asked of it is asked of its tables (`EdgeTables`) and of the file's containment
/// (`Containment`), which a snapshot for another thread holds as they are (`snapshot()`), so the
/// two answer alike.
@MainActor
@Observable
public final class TopologyIndex {
    @ObservationIgnored private unowned let editor: CanvasEditor
    /// The editor's registry, kept: what every record read is read with, passed along uncopied.
    @ObservationIgnored private let registry: Registry
    /// The edge types, as a tree: worked out once, as the registry never changes.
    public let types: EdgeTypeTree

    /// The kinds whose shapes stand in for others (`EdgeForwarding`): worked out once.
    public let standInKinds: Set<ShapeKind>

    /// What each kind that has sources or stands in has the index read: one lookup a record.
    @ObservationIgnored private var upkeep: [ShapeKind: KindUpkeep] = [:]
    /// Each stand-in kind's rule.
    @ObservationIgnored private let standInRules: [ShapeKind: StandIn]
    /// Each stand-in kind's admission, made once from the registry: safe on any thread.
    @ObservationIgnored private let admissions: [ShapeKind: ForwardAdmission]
    /// Each stand-in on a board the editor can show (not kept aside): its kind, and what its record
    /// says it stands for.
    @ObservationIgnored private var standing: [ShapeID: Declared] = [:]
    /// The stand-ins whose record names each shape (`Forwarding.shapes`): those to look at again
    /// when a commit changes it.
    @ObservationIgnored private var declaredBy: [ShapeID: Set<ShapeID>] = [:]
    /// The stand-ins declared again with another part of their shape (`Forwarding.row`), until `apply` notes their edges.
    @ObservationIgnored private var partChanged: Set<ShapeID> = []
    /// The answer provided for each stand-in that stands for what's provided, for the key its
    /// record holds now (`provide`): never saved, never undone, dropped with the key.
    @ObservationIgnored private var provided: [ShapeID: ProvidedForwarding] = [:]
    /// The stand-ins whose answer names each shape: those to look at again when a commit changes it.
    @ObservationIgnored private var providedBy: [ShapeID: Set<ShapeID>] = [:]
    /// The stand-ins that stand for what's provided and have no answer for the key their record
    /// holds now: asked, not answered, so standing for nothing yet.
    @ObservationIgnored public private(set) var pendingStandIns: Set<ShapeID> = []
    /// Who hears each change to the edges (`follow`), by when they began.
    @ObservationIgnored private var followers: [Int: @MainActor (TopologyChange) -> Void] = [:]
    @ObservationIgnored private var nextFollower = 0
    /// Whether a change is being told: a follower never provides.
    @ObservationIgnored private var delivering = false
    /// Those that provide answers, each saying whether it still has work (`keepsSettling`).
    @ObservationIgnored private var settleSources: [Int: (edges: Bool, busy: @MainActor () -> Bool)] = [:]
    @ObservationIgnored private var nextSettleSource = 0
    /// Those waiting for the edges to settle (`settled(timeout:)`).
    @ObservationIgnored private let waiters = SettleWaiters()
    /// The file's edges: by carrier, by each end and by type.
    @ObservationIgnored private(set) var tables = EdgeTables()
    /// +1 for a shape each time its edges change, observed a shape at a time: only the shapes whose
    /// revision has been read (`watched`), so a commit that changes many shapes' edges (a board
    /// deleted) tells only the shapes someone may be watching.
    @ObservationIgnored private var revisions: [ShapeID: Int] = [:]
    @ObservationIgnored private var watched: Set<ShapeID> = []

    /// The shapes whose edges (at either end, and at either literal end) the last change to the
    /// edges changed: a commit's (none for one that changed none, as a move), or a provide's that
    /// changed any (one that changed none leaves it); none after a switch of board. Each change is
    /// told to followers as it comes (`follow`), which is how to hear one: a service reading this
    /// as it hears a commit misses every provide. `touched(types:)` is those whose edges of some
    /// types it changed.
    @ObservationIgnored public private(set) var touched: Set<ShapeID> = []
    /// `touched`, by the type of each edge that changed.
    @ObservationIgnored private var touchedByType: [EdgeTypeID: Set<ShapeID>] = [:]
    /// +1 for each change to what the index holds (a commit that read a shape again, a provide that
    /// took an answer, the file read afresh): when a preparer was taken (`preparer()`).
    @ObservationIgnored private var generation = 0
    /// What each recent change read again, answered or changed what it stands for (nil: everything,
    /// the file read afresh), oldest first: what `provide(_:prepared:)` asks of what was worked out
    /// before it.
    @ObservationIgnored private var changeLog: [(generation: Int, ids: Set<ShapeID>?)] = []
    /// Whether a preparer has been taken: only then is the log kept.
    @ObservationIgnored private var logs = false

    #if DEBUG
    /// How many records sources and stand-ins' forwarding rules have read (debug builds), so tests
    /// can hold a commit to what it changed.
    @ObservationIgnored public private(set) var recordsRead = 0
    /// How many edges sources emitted that were dropped for being Topology's own (debug builds): an
    /// edge in the slot `stands-for`, or of that type (`StandingEdge`).
    @ObservationIgnored public private(set) var reservedEdgesDropped = 0
    /// How many edges the tables keep (debug builds): what carriers emitted, whatever stands for
    /// what, so tests can hold forwarding to keeping no copies.
    public var storedEdgeCount: Int { tables.byCarrier.values.reduce(0) { $0 + $1.count } }
    /// How many answers prepared on another thread were taken as prepared, and how many were worked
    /// out again here (debug builds): a commit to what one names came after it was prepared.
    @ObservationIgnored public private(set) var preparedTaken = 0
    @ObservationIgnored public private(set) var preparedRedone = 0
    /// How many shapes a stand-in names have been looked at, to say whether it may stand for them
    /// (debug builds): a commit to one of a thousand looks at one.
    @ObservationIgnored public private(set) var targetsRead = 0
    #endif

    init(editor: CanvasEditor) {
        self.editor = editor
        registry = editor.registry
        types = editor.registry.edgeTypes
        standInRules = editor.registry.standInRules()
        standInKinds = Set(standInRules.keys)
        admissions = editor.registry.standInAdmissions
        for kind in editor.registry.kinds {
            let found = editor.registry.edgeEmitters(for: kind)
            if !found.isEmpty || standInRules[kind] != nil { upkeep[kind] = KindUpkeep(emitters: found, rule: standInRules[kind]) }
        }
        rebuild()
        clearTouched()
    }

    // MARK: Edges

    /// Every edge touching `id`, anywhere in the file, as `direction` asks, of the types `types`
    /// admits: by carrier, in the order the carriers came to it (those read as the editor opened in
    /// the file's order, root first; those one commit brings, in no order among themselves), each
    /// carrier's in the order it emits them. An edge from `id` to `id` is there once.
    public func edges(of id: ShapeID, _ direction: EdgeDirection = .either, types filter: EdgeTypeFilter = .all) -> [Edge] {
        tables.edges(of: id, direction, types: filter, in: types)
    }

    /// Whether `id` has any edge `edges(of:_:types:)` would find that `predicate` takes (any, by
    /// default): it stops at the first, and makes nothing, so it's cheap enough for what's asked on
    /// every commit.
    public func hasEdges(of id: ShapeID, _ direction: EdgeDirection = .either, types filter: EdgeTypeFilter = .all,
                         where predicate: (Edge) -> Bool = { _ in true }) -> Bool {
        tables.hasEdges(of: id, direction, types: filter, in: types, where: predicate)
    }

    /// The shapes at the other end of `id`'s edges (as `edges(of:_:types:)` finds them), by each
    /// edge's type, each once per type, in the order its first edge comes: what's connected to it,
    /// and how. `id` itself, for an edge from `id` to `id`.
    public func neighbors(of id: ShapeID, _ direction: EdgeDirection = .either, types filter: EdgeTypeFilter = .all) -> [EdgeTypeID: [ShapeID]] {
        tables.neighbors(of: id, direction, types: filter, in: types)
    }

    /// Every edge in the file of the types `filter` admits: type by type (declared ones in plugin
    /// order, then the rest by name), each type's by carrier, in the order they came.
    public func edges(ofType filter: EdgeTypeFilter) -> [Edge] { tables.edges(ofType: filter, in: types) }

    /// What `carrier` carries, in the order it emits them; none for a shape on a board the editor
    /// can't show, or in no board of the file.
    public func edges(carriedBy carrier: ShapeID) -> [Edge] { tables.edges(carriedBy: carrier) }

    // MARK: Edges, in a view

    /// `edges(of:_:types:)`, as `view` reads them: copies of one edge forwarded into several shapes
    /// that the view reads back as one are one.
    public func edges(of id: ShapeID, _ direction: EdgeDirection = .either, types filter: EdgeTypeFilter = .all, view: EdgeView) -> [Edge] {
        tables.edges(of: id, direction, types: filter, in: types, view: view)
    }

    /// Calls `body` with each edge `edges(of:_:types:view:)` returns, in its order, making no array: for a walk
    /// over many shapes' edges, where most have none of the kind asked for (a type's instances, and theirs).
    public func forEachEdge(of id: ShapeID, _ direction: EdgeDirection = .either, types filter: EdgeTypeFilter = .all, view: EdgeView,
                            _ body: (Edge) -> Void) {
        tables.forEachEdge(of: id, direction, types: filter, in: types, view: view, body)
    }

    /// `id`'s edges at one of its parts (`part`; nil: those at the shape as a whole), as `direction` asks, of the types
    /// `filter` admits, as `view` reads them: a row's (a key leaving a column), filtered from the shape's, in their order.
    public func edges(of id: ShapeID, part: PartID?, _ direction: EdgeDirection = .either, types filter: EdgeTypeFilter = .all,
                      view: EdgeView = .resolved) -> [Edge] {
        var found: [Edge] = []
        tables.forEachEdge(of: id, direction, types: filter, in: types, view: view) { edge in
            if edge.touches(id, part: part, direction) { found.append(edge) }
        }
        return found
    }

    /// `hasEdges(of:_:types:where:)`, as `view` reads them.
    public func hasEdges(of id: ShapeID, _ direction: EdgeDirection = .either, types filter: EdgeTypeFilter = .all, view: EdgeView,
                         where predicate: (Edge) -> Bool = { _ in true }) -> Bool {
        tables.hasEdges(of: id, direction, types: filter, in: types, view: view, where: predicate)
    }

    /// `neighbors(of:_:types:)`, as `view` reads the edges.
    public func neighbors(of id: ShapeID, _ direction: EdgeDirection = .either, types filter: EdgeTypeFilter = .all,
                          view: EdgeView) -> [EdgeTypeID: [ShapeID]] {
        tables.neighbors(of: id, direction, types: filter, in: types, view: view)
    }

    /// `edges(ofType:)`, as `view` reads them.
    public func edges(ofType filter: EdgeTypeFilter, view: EdgeView) -> [Edge] { tables.edges(ofType: filter, in: types, view: view) }

    /// `edges(carriedBy:)`, as `view` reads them: in the literal view, what it emitted.
    public func edges(carriedBy carrier: ShapeID, view: EdgeView) -> [Edge] { tables.edges(carriedBy: carrier, view: view) }

    // MARK: Stand-ins

    /// The shapes `standIn` stands for now, in order: those its record names (or that were provided
    /// for it) that it may stand for (`EdgeForwarding`). None for a shape that isn't a stand-in, or
    /// stands for nothing.
    public func forwards(of standIn: ShapeID) -> [ShapeID] { tables.forwards(of: standIn) }

    /// The stand-ins that stand for `target` now, in the order they came to: what stands for it.
    public func standIns(for target: ShapeID) -> [ShapeID] { tables.standIns(for: target) }

    /// The kinds of the shapes `standIn` stands for now, each once: the first shape's kind first,
    /// then the rest by name. None for a shape that stands for nothing. O(those kinds), however many
    /// shapes it stands for: what a reader of a stand-in's kinds (its ports, what an edge into it may
    /// be) reads instead of its shapes.
    public func standingKinds(of standIn: ShapeID) -> [ShapeKind] { tables.standingKinds(of: standIn) }

    /// The stand-ins whose record names `target`, whether or not they stand for it now (an admission they
    /// don't meet, a target on a board the editor can't show, or one that is gone): who points at it, for a
    /// reader that treats a direct stand-in as the shape it names. Provided ones are not here. No order.
    public func standIns(naming target: ShapeID) -> [ShapeID] { Array(declaredBy[target] ?? []) }

    /// The one shape a direct stand-in's record names (`Forwarding.onlyShape`), whether or not it stands
    /// for it now: the other way round from `standIns(naming:)`. Nil for one that stands for what's
    /// provided or names none or several, and for a shape that isn't a stand-in on a board the editor can
    /// show. O(1): the rule as the index read it.
    public func directTarget(of standIn: ShapeID) -> ShapeID? {
        guard !standing.isEmpty else { return nil }
        return standing[standIn]?.forwarding?.onlyShape
    }

    /// The part of its shape a stand-in for a row reaches (`Forwarding.row`: a pill for an endpoint), whether or not it stands
    /// for it now; nil for any other. O(1).
    public func directPart(of standIn: ShapeID) -> PartID? {
        guard !standing.isEmpty else { return nil }
        return standing[standIn]?.forwarding?.part
    }

    /// The kind of a stand-in on a board the editor can show (whatever it stands for now), nil for any
    /// other shape: what a plugin that keeps its own kind's stand-ins asks of a commit's shapes, once the
    /// index has heard it. O(1).
    public func standInKind(of id: ShapeID) -> ShapeKind? {
        guard !standing.isEmpty else { return nil }
        return standing[id]?.kind
    }

    /// Whether any shape on a board the editor can show is a stand-in (of a kind that stands in,
    /// whatever it stands for now): a follower that looks for stand-ins among a change's shapes
    /// looks at none when there are none. O(1).
    public var hasStandIns: Bool { !standing.isEmpty }

    /// How `id` stands for its shapes now: not at all, as its record names them, as provided, or
    /// waiting for what's provided.
    public func forwarding(of id: ShapeID) -> ForwardingState {
        guard !standing.isEmpty, let forwarding = standing[id]?.forwarding else { return .none }
        switch forwarding {
        case .shapes, .row: return .record(tables.forwards(of: id))
        case .provided(let key): return provided[id]?.key == key ? .provided(tables.forwards(of: id)) : .pending
        }
    }

    /// The resolved edges forwarded through `standIn` (whose `origin` names it): one for each shape
    /// it stands for, for each edge another shape carries into it or out of it.
    public func edges(through standIn: ShapeID) -> [Edge] { tables.edges(through: standIn) }

    /// How a shape at an end of an edge is now: live on a board the editor can show, unavailable on
    /// one it can't, missing from the file.
    public func end(_ id: ShapeID) -> EdgeEnd { containment().end(id) }

    /// A shape's revision: +1 each time its edges (at either end) change, from the first time it's
    /// read. Reading it observes only that shape, so a SwiftUI view of one shape's connections
    /// redraws when they change.
    public func revision(of id: ShapeID) -> Int {
        access(keyPath: \.[revision: id])
        watched.insert(id)
        return revisions[id] ?? 0
    }

    /// Only a key: one key path per shape, under which Observation keeps each shape's observers.
    private subscript(revision id: ShapeID) -> Int { revisions[id] ?? 0 }

    /// The shapes whose edges of the types `filter` admits (at either end) the last change changed:
    /// `touched`, for a reader of one type (Mentions: an arrow bound to a mentioned shape changes
    /// none of what mentions it). O(the types the change changed edges of).
    public func touched(types filter: EdgeTypeFilter) -> Set<ShapeID> {
        guard !filter.isAll else { return touched }
        var found: Set<ShapeID> = []
        for (type, ends) in touchedByType where filter.admits(type, in: types) { found.formUnion(ends) }
        return found
    }

    // MARK: Provided answers, and following the edges

    /// Answers for stand-ins whose record says they stand for what's provided
    /// (`Forwarding.provided`): what each stands for now. Not a commit: never saved, never undone.
    /// An answer for another key than the one the stand-in's record holds now, for a shape that
    /// isn't such a stand-in (on a board the editor can show), or older (`revision`) than the one
    /// held for that key, is dropped; one that names what the one held names is taken as newer and
    /// changes nothing else. What each stand-in stands for is worked out again, the revisions of the
    /// ends of the edges that changed bumped, and, if any edge changed, the change told to followers
    /// (`.provide`); `touched` is then its ends.
    ///
    /// `prepared` is what a preparer worked out of these answers on another thread
    /// (`preparer()`, `ForwardingPreparer.prepare`): each answer it holds as given is taken as it was
    /// worked out, what came and went alone, unless a change since it was taken read a shape the
    /// answer names, or its stand-in, again; any other answer is worked out here.
    ///
    /// Never call it while a service hears a commit or a switch (`documentDidChange`,
    /// `boardDidChange`), nor from a follower: from a scheduled callback or a task's continuation on
    /// the main actor, so that each commit is told with one consistent table.
    public func provide(_ answers: [ShapeID: ProvidedForwarding], prepared: PreparedForwarding? = nil) {
        assert(!delivering, "a follower never provides")
        let since = prepared.flatMap { changes(since: $0.generation) }
        var work = Upkeep(), answered: Set<ShapeID> = [], taken: [(id: ShapeID, answer: PreparedAnswer)] = []
        for (id, answer) in answers {
            if let since, let entry = prepared?.answers[id], entry.answer == answer, !since.contains(id), entry.holds(since) {
                taken.append((id, entry))
                continue
            }
            #if DEBUG
            if prepared?.answers[id] != nil { preparedRedone += 1 }
            #endif
            guard case .provided(let key)? = standing[id]?.forwarding, key == answer.key else { continue }
            answered.insert(id)
            switch answer.taken(over: provided[id]) {
            case .dropped:
                continue
            case .newer:
                // What it names, and so what it stands for, is as it was.
                provided[id] = answer
                continue
            case .anew:
                break
            }
            setAnswer(id, answer)
            pendingStandIns.remove(id)
            work.standIn(id)
        }
        let before = (touched, touchedByType)
        clearTouched()
        var moved: Set<ShapeID> = []
        for (id, entry) in taken {
            #if DEBUG
            preparedTaken += 1
            #endif
            switch entry.outcome {
            case .dropped:
                continue
            case .newer:
                provided[id] = entry.answer
            case .stands(let targets, let change, let came, let went):
                setAnswer(id, entry.answer, came: came, went: went)
                pendingStandIns.remove(id)
                tables.setForwards(id, targets, kind: .provided, change: change)
                if change.moved {
                    touchForwards(id, change)
                    moved.insert(id)
                }
            }
            answered.insert(id)
        }
        if !work.standIns.isEmpty {
            var lookup = Lookup(editor)
            moved.formUnion(apply(&work, in: &lookup))
        }
        if !answered.isEmpty { log(answered.union(moved)) }
        if touched.isEmpty {
            (touched, touchedByType) = before
        } else {
            bump(touched)
            deliver(.provide)
        }
        wakeWaiters()
    }

    /// What answers worked out on another thread start from (`ForwardingPreparer.prepare`): the index
    /// as it is now, shared, not copied (O(1)), reading no record and observing nothing. Take it on
    /// the main actor just before preparing, and hand what it prepares, with the answers, to
    /// `provide(_:prepared:)`; hold it no longer than that, as a snapshot.
    public func preparer() -> ForwardingPreparer {
        logs = true
        return ForwardingPreparer(generation: generation, tables: tables, containment: containment(observing: false), standing: standing,
                                  provided: provided, admissions: admissions)
    }

    /// Calls `follower` once after every change to the edges, whatever its cause: a commit (undo,
    /// redo), a provide, or the file read afresh. At the call, the index (`touched` among it) is as
    /// the change left it. The one way to keep state off edges: a provide changes edges with no
    /// commit. A follower reads only Topology and the file, never writes a document and never
    /// provides. It lasts as long as the token returned is held (`TopologyFollowing`), or until it's
    /// cancelled; followers are called in the order they began.
    public func follow(_ follower: @escaping @MainActor (TopologyChange) -> Void) -> TopologyFollowing {
        let key = nextFollower
        nextFollower += 1
        followers[key] = follower
        return TopologyFollowing(index: self, key: key)
    }

    func stopFollowing(_ key: Int) { followers[key] = nil }

    /// Tells followers the change just made, if it changed any edge, then wakes those waiting to
    /// settle that may stop. A commit's or a file's, once the index has taken it in (`editor.onceHeard`:
    /// as its hook returns, so a follower may read it); a provide's at once.
    private func deliver(_ cause: TopologyChange.Cause) {
        guard !touched.isEmpty, !followers.isEmpty else { return wakeWaiters() }
        let change = TopologyChange(touched: touched, touchedByType: touchedByType, cause: cause)
        editor.onceHeard { [weak self] in
            guard let self else { return }
            delivering = true
            for key in followers.keys.sorted() {
                // One that a follower before it cancelled isn't called.
                followers[key]?(change)
            }
            delivering = false
            wakeWaiters()
        }
    }

    // MARK: Settling

    /// Says, for whatever provides answers, whether it still has work (`busy`: a wait armed, a batch
    /// out, a stand-in asked and not answered), so the edges aren't settled while it does. It counts
    /// as long as the token returned is held (`SettleSource`), or until it's cancelled. `busy` is
    /// asked whenever the index looks; when it goes idle with no provide or commit to say so, say
    /// `settleSourceChanged()`. A source whose answers are no edges (`edges: false`: a rule's
    /// verdicts, which Validation's words read) keeps only the waits for everything settling, never
    /// one for edges alone (`settled(timeout:edgesOnly:)`), so a query of edges never waits for it.
    public func keepsSettling(edges: Bool = true, while busy: @escaping @MainActor () -> Bool) -> SettleSource {
        let key = nextSettleSource
        nextSettleSource += 1
        settleSources[key] = (edges, busy)
        return SettleSource(index: self, key: key)
    }

    func stopSettling(_ key: Int) {
        settleSources[key] = nil
        wakeWaiters()
    }

    /// Tells those waiting to look again: a source went idle with no provide or commit to say so.
    public func settleSourceChanged() { wakeWaiters() }

    /// Whether answers are still on their way: whether any source says it has work.
    public var isSettling: Bool { settleSources.values.contains { $0.busy() } }

    /// Whether answers about edges are still on their way: whether a source of edges says it has work.
    public var isSettlingEdges: Bool { settleSources.values.contains { $0.edges && $0.busy() } }

    /// Waits until every source has settled (`edgesOnly`: every source of edges): true then, false
    /// if `timeout` (on the editor's scheduler) runs out first, or the task is cancelled. At once if
    /// settled now. Woken by every change told and every provide, and by `settleSourceChanged()`.
    public func settled(timeout: Duration, edgesOnly: Bool = false) async -> Bool {
        guard edgesOnly ? isSettlingEdges : isSettling else { return true }
        let waiters = waiters, scheduler = editor.scheduler, key = waiters.reserve()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { return continuation.resume(returning: false) }
                let timeout = scheduler.schedule(after: timeout) { waiters.finish(key, settled: false) }
                waiters.wait(key, continuation, timeout: timeout, edgesOnly: edgesOnly)
            }
        } onCancel: {
            Task { @MainActor in waiters.finish(key, settled: false) }
        }
    }

    /// Ends the waits that have settled: those for edges alone once no source of edges has work, and
    /// the rest once no source has.
    private func wakeWaiters() {
        guard !waiters.isEmpty else { return }
        let edges = isSettlingEdges, any = isSettling
        guard !edges || !any else { return }
        waiters.finishAll { edgesOnly in edgesOnly ? !edges : !any }
    }

    // MARK: Containment

    /// The kinds whose shapes can contain others (`registry.containerKinds`): those that own boards
    /// (a subboard) and those that hold shapes on the board they're on (a frame).
    public var containerKinds: Set<ShapeKind> { editor.registry.containerKinds }

    /// The shape `id` is directly inside: the container it's in on its board (a frame), else the
    /// owner of its board; nil on the root in no container, and for a shape on a board the editor
    /// can't show (or in no board of the file).
    public func parent(of id: ShapeID) -> ShapeID? { containment().parent(of: id) }

    /// The shapes directly inside `id`: what it holds (a frame's shapes), back to front, then, for a
    /// shape that owns a board the editor can show, that board's shapes in no container, back to
    /// front. None for any other shape.
    public func children(of id: ShapeID) -> [ShapeID] { containment().children(of: id) }

    /// The shapes `id` is inside, the nearest first (its parent, its parent's, up to one on the root
    /// in no container): none on the root in no container, and for a shape on a board the editor
    /// can't show.
    public func ancestors(of id: ShapeID) -> [ShapeID] { containment().ancestors(of: id) }

    /// Every shape inside `id`, at any depth, in file order: what it holds and its board's shapes,
    /// each followed at once by what's inside it. None for a shape that holds nothing and owns no
    /// board the editor can show. O(what's inside it).
    public func descendants(of id: ShapeID) -> [ShapeID] { containment().descendants(of: id) }

    /// Whether `a` is inside `b`, at any depth (in it, on its board, or below either); never inside
    /// itself. O(`a`'s depth).
    public func isInside(_ a: ShapeID, _ b: ShapeID) -> Bool { containment().isInside(a, b) }

    /// The file's containment as it is now, observed through `document` as the file is (unless
    /// `observing` is false): made for the one question, never kept, since a copy of the file kept
    /// past a commit would make that commit copy the file's tables.
    func containment(observing: Bool = true) -> Containment {
        let file = observing ? editor.file : editor.withoutObservingDocument { editor.file }
        return Containment(file: file, boardOwningKinds: editor.registry.boardOwningKinds, containingKinds: editor.registry.containingKinds)
    }

    // MARK: Following the file

    /// What a commit changed, applied: the records it touched read again (each carrier's edges set
    /// as emitted), what stand-ins stand for worked out again where that may have changed (whole for
    /// a stand-in read again, for the shapes it changed alone for one that names them), then the
    /// revisions of the shapes whose edges changed bumped, and the change told to followers.
    private func hear(_ changes: ChangeSet) {
        clearTouched()
        if changes.replacedDocument {
            rebuild()
            log(nil)
        } else {
            var lookup = Lookup(editor), work = Upkeep()
            // Removed first: one commit can take a shape off one board and put it on another.
            for id in changes.removed { refresh(id, in: &lookup, &work) }
            for id in changes.elsewhere { refresh(id, in: &lookup, &work) }
            for id in changes.added { refresh(id, in: &lookup, &work) }
            for id in changes.changed where !changes.moved.contains(id) { refresh(id, in: &lookup, &work) }
            let moved = apply(&work, in: &lookup)
            if logs, work.read > 0 {
                var read = moved.union(changes.removed).union(changes.elsewhere).union(changes.added)
                for id in changes.changed where !changes.moved.contains(id) { read.insert(id) }
                log(read)
            }
        }
        bump(touched)
        deliver(changes.replacedDocument ? .rebuild : .commit)
    }

    /// Reads a shape again, wherever it is now (on no board the editor can show, it carries nothing
    /// and stands for nothing): what it emits, what it says it stands for if it's a stand-in, and,
    /// as a shape a stand-in's record may name, which stand-ins to look at again for it. Its kind is
    /// looked up once, and the stand-in tables only while they hold something: a file with no
    /// stand-ins reads a shape as it did before there were any.
    private func refresh(_ id: ShapeID, in lookup: inout Lookup, _ work: inout Upkeep) {
        // The record bound once, and no closures: each would check, at every shape, that it runs
        // on the main actor.
        var emitted: [Edge] = [], declares = false
        work.read += 1
        let record = lookup.shape(id)
        if let record, let kind = upkeep[record.kind] {
            // Whether it's a stand-in first: a stand-in's own edges are never forwarded.
            if let rule = kind.rule, !record.isOpaque {
                declares = true
                let forwarding = forward(record, rule)
                if standing[id] == nil || standing[id]?.forwarding != forwarding {
                    declare(id, Declared(kind: record.kind, forwarding: forwarding))
                    work.standIn(id)
                }
            }
            emitted = derive(record, kind.emitters)
        }
        if !declares, !standing.isEmpty, standing[id] != nil {
            declare(id, nil)
            work.standIn(id)
        }
        set(id, emitted: emitted)
        // A shape stood for, turned into another kind: what stands for it counts it as that now, and its
        // edge to it is noted, so a reader of its kinds (its ports, kept by its revision) hears of it.
        if let record, !tables.forwardedKinds.isEmpty, let kept = tables.forwardedKinds[id], kept != record.kind {
            for standIn in tables.setKind(record.kind, of: id) {
                touched.insert(standIn)
                touched.insert(id)
                touchedByType[StandingEdge.id, default: []].formUnion([standIn, id])
            }
        }
        // A shape a stand-in names, or an answer holds: whether it's there, and may be stood for,
        // may have changed.
        if !declaredBy.isEmpty { for standIn in declaredBy[id] ?? [] { work.recheck(standIn, id) } }
        if !providedBy.isEmpty { for standIn in providedBy[id] ?? [] { work.recheck(standIn, id) } }
    }

    /// What the records read change for stand-ins: what each stand-in read again stands for, worked
    /// out whole, and, for each that only names shapes the commit changed, those shapes looked at
    /// again; then, for each whose shapes changed, the ends of the edges that changed noted. The
    /// stand-ins whose shapes changed.
    @discardableResult
    private func apply(_ work: inout Upkeep, in lookup: inout Lookup) -> Set<ShapeID> {
        var moved: Set<ShapeID> = []
        for standIn in work.standIns {
            let (targets, kinds, kind) = effective(standIn, in: &lookup)
            let change = ForwardsChange.between(tables.forwards(of: standIn), targets, kinds: kinds)
            tables.setForwards(standIn, targets, kind: kind, change: change)
            // The same shape, another of its parts: the edges forwarded through it reach another row.
            if partChanged.remove(standIn) != nil, !change.moved, !targets.isEmpty {
                touchForwards(standIn, ForwardsChange(went: targets))
                moved.insert(standIn)
            }
            guard change.moved else { continue }
            touchForwards(standIn, change)
            moved.insert(standIn)
        }
        for standIn in work.rechecked where !work.isWhole(standIn) {
            let change = recheck(standIn, work.named(by: standIn), in: &lookup)
            guard change.moved else { continue }
            touchForwards(standIn, change)
            moved.insert(standIn)
        }
        partChanged.removeAll()
        return moved
    }

    /// Reads every board the editor can show afresh, and lets go of carriers and stand-ins it no
    /// longer finds. Carriers whose edges didn't change touch nothing. Each carrier is set as it's
    /// read; then what every stand-in, there before or now, stands for is worked out: a file with no
    /// stand-ins costs what it did before there were any. Answers provided are let go of: they were
    /// for the file as it was, and are asked again.
    private func rebuild() {
        var seen: Set<ShapeID> = []
        let before = Array(tables.forwards.keys)
        for id in Array(standing.keys) { declare(id, nil) }
        var found: [ShapeID] = []
        for board in editor.showableBoards {
            for record in editor.contents(of: board).shapes {
                if let kind = upkeep[record.kind] {
                    if let rule = kind.rule, !record.isOpaque {
                        declare(record.id, Declared(kind: record.kind, forwarding: forward(record, rule)))
                        seen.insert(record.id)
                        found.append(record.id)
                    }
                    if !kind.emitters.isEmpty {
                        seen.insert(record.id)
                        set(record.id, emitted: derive(record, kind.emitters))
                    }
                }
            }
        }
        for carrier in Array(tables.byCarrier.keys) where !seen.contains(carrier) {
            set(carrier, emitted: [])
        }
        guard !before.isEmpty || !found.isEmpty else { return }
        var lookup = Lookup(editor), work = Upkeep()
        for id in before + found { work.standIn(id) }
        apply(&work, in: &lookup)
    }

    /// What a record carries, as its kind's sources (`emitters`) say.
    private func derive(_ record: AnyShapeRecord, _ emitters: [EdgeEmitter]) -> [Edge] {
        guard !emitters.isEmpty, !record.isOpaque else { return [] }
        var reserved = 0
        let edges = Registry.edges(of: record, emitters: emitters, in: registry, reserved: &reserved)
        #if DEBUG
        recordsRead += 1
        reservedEdgesDropped += reserved
        #endif
        return edges
    }

    /// What a stand-in's record says it stands for, as its kind's rule reads it.
    private func forward(_ record: AnyShapeRecord, _ rule: StandIn) -> Forwarding? {
        #if DEBUG
        recordsRead += 1
        #endif
        return rule.forward(record, registry)
    }

    /// Keeps what a stand-in declares (nil: it's no longer one), which stand-ins name each shape, its
    /// answer (only for the key it holds now) and whether it waits for one, in step.
    private func declare(_ id: ShapeID, _ declared: Declared?) {
        if let old = standing[id]?.forwarding?.named {
            for target in old {
                guard let index = declaredBy.index(forKey: target) else { continue }
                declaredBy.values[index].remove(id)
                if declaredBy.values[index].isEmpty { declaredBy.remove(at: index) }
            }
        }
        if (standing[id] == nil) != (declared == nil) { tables.setStandIn(id, declared != nil) }
        standing[id] = declared
        if let new = declared?.forwarding?.named {
            for target in new { declaredBy[target, default: []].insert(id) }
        }
        // A pill for a row: what an edge forwarded through it reaches. A change with the same shape is a change to those edges.
        if tables.setForwardPart(id, declared?.forwarding?.part) { partChanged.insert(id) }
        if let held = provided[id], declared?.forwarding != .provided(held.key) { setAnswer(id, nil) }
        if case .provided(let key)? = declared?.forwarding, provided[id]?.key != key {
            pendingStandIns.insert(id)
        } else {
            pendingStandIns.remove(id)
        }
    }

    /// Keeps a stand-in's answer (nil: none), and which stand-ins' answers name each shape, in step.
    private func setAnswer(_ id: ShapeID, _ answer: ProvidedForwarding?) {
        let old = provided[id]?.shapes ?? []
        setAnswer(id, answer, came: answer?.shapes ?? [], went: old)
    }

    /// `setAnswer(_:_:)` where what the answer names that the one before didn't (`came`) and what it
    /// no longer names (`went`) are known: only those are filed again.
    private func setAnswer(_ id: ShapeID, _ answer: ProvidedForwarding?, came: [ShapeID], went: [ShapeID]) {
        for target in went {
            guard let index = providedBy.index(forKey: target) else { continue }
            providedBy.values[index].remove(id)
            if providedBy.values[index].isEmpty { providedBy.remove(at: index) }
        }
        provided[id] = answer
        for target in came { providedBy[target, default: []].insert(id) }
    }

    /// What a stand-in names as it stands now: the shapes its record names, or those of the answer
    /// held for the key its record holds (none while there's none), and which.
    private func named(by standIn: ShapeID, _ forwarding: Forwarding) -> ([ShapeID], ForwardKind) {
        switch forwarding {
        case .shapes(let ids): (ids, .record)
        case .row(let id, _): ([id], .record)
        case .provided(let key): (provided[standIn].flatMap { $0.key == key ? $0.shapes : nil } ?? [], .provided)
        }
    }

    /// For a stand-in for a row (`Forwarding.row`): whether a shape still lists that row, which it must for the pill to stand for it; nil for any
    /// other stand-in. A row that is gone leaves the pill standing for nothing, as it is drawn (missing).
    private func holdsRow(_ forwarding: Forwarding) -> ((AnyShapeRecord) -> Bool)? {
        guard case .row(_, let part) = forwarding else { return nil }
        let registry = registry
        return { registry.parts(of: $0)?.contains { $0.id == part } == true }
    }

    /// What a stand-in stands for now: the shapes it names, in order, each once, that are on a board
    /// the editor can show, not kept aside, not stand-ins (one hop), not itself, and that its rule
    /// admits, with their kinds; and whether its record names them or they were provided.
    private func effective(_ standIn: ShapeID, in lookup: inout Lookup) -> (targets: [ShapeID], kinds: [ShapeKind], kind: ForwardKind) {
        guard let declared = standing[standIn], let forwarding = declared.forwarding, let admits = admissions[declared.kind] else {
            return ([], [], .record)
        }
        let (named, kind) = named(by: standIn, forwarding)
        let taken = Effective.taking(named, for: standIn, isStandIn: { standInRules[$0] != nil }, admits: admits, alsoNeeds: holdsRow(forwarding)) { target in
            #if DEBUG
            targetsRead += 1
            #endif
            return lookup.shape(target)
        }
        return (taken.targets, taken.kinds, kind)
    }

    /// What a commit to `ids`, among the shapes `standIn` names, changes of what it stands for, those
    /// alone: each it may stand for now and didn't comes, in its place among what it names, and each
    /// it can't and did goes. O(those shapes, and a pass along what it names): a commit to one of a
    /// thousand shapes looks at one. The change, as applied.
    private func recheck(_ standIn: ShapeID, _ ids: [ShapeID], in lookup: inout Lookup) -> ForwardsChange {
        guard let declared = standing[standIn], let forwarding = declared.forwarding, let admits = admissions[declared.kind] else {
            return .none
        }
        let (named, kind) = named(by: standIn, forwarding)
        var change = ForwardsChange()
        for id in ids where id != standIn {
            #if DEBUG
            targetsRead += 1
            #endif
            let standsFor = tables.standIns(for: id).contains(standIn)
            let record = lookup.shape(id)
            let needsRow = holdsRow(forwarding)
            let may = record.map { !$0.isOpaque && standInRules[$0.kind] == nil && admits($0) && (needsRow?($0) ?? true) } ?? false
            if may, !standsFor, let record, let index = Self.place(of: id, in: named, among: tables.forwards(of: standIn)) {
                tables.insertForward(standIn, id, at: index, record.kind, as: kind)
                change.came.append((id, record.kind))
                change.moved = true
            } else if !may, standsFor {
                tables.removeForward(standIn, id)
                change.went.append(id)
                change.moved = true
            }
        }
        return change
    }

    /// Where `id` goes among `taken`, the shapes of `named` stood for, in its order: after each one
    /// that comes before its first place in `named`. One pass, comparing ids; nil for one `named`
    /// doesn't hold.
    private static func place(of id: ShapeID, in named: [ShapeID], among taken: [ShapeID]) -> Int? {
        var index = 0
        for shape in named {
            if shape == id { return index }
            if index < taken.count, shape == taken[index] { index += 1 }
        }
        return nil
    }

    /// Makes `emitted` what `carrier` emitted, and notes the ends of the edges that changed in
    /// `touched`.
    private func set(_ carrier: ShapeID, emitted: [Edge]) {
        touch(tables.set(carrier, emitted: emitted))
    }

    /// Notes each edge's ends in `touched`, under its type, and, for an end that's a stand-in that
    /// stands for something (of an edge its carrier, not a stand-in, carries), each shape it stands
    /// for: the ends of the edge's copies. A run of edges of one type (a carrier's, mostly) looks its
    /// type up once, and an end the edge before of that type had (the source of every mention in a
    /// text) is noted once.
    private func touch(_ edges: [Edge]) {
        guard var type = edges.first?.type else { return }
        var ofType = touchedByType.removeValue(forKey: type) ?? []
        let forwarding = !tables.forwards.isEmpty
        func noteForwards(of end: ShapeID) {
            for target in tables.forwards[end] ?? [] {
                touched.insert(target)
                ofType.insert(target)
            }
        }
        // By index, with no arrays made: the edge before, if of this type, is in this run.
        for index in edges.indices {
            let edge = edges[index], first = index == edges.startIndex
            if !first, edge.type != type {
                touchedByType[type] = ofType
                type = edge.type
                ofType = touchedByType.removeValue(forKey: type) ?? []
            }
            let sameRun = !first && edges[index - 1].type == type
            edge.forEachNode { node in
                guard !sameRun || (edges[index - 1].source != node && edges[index - 1].target != node) else { return }
                touched.insert(node)
                ofType.insert(node)
            }
            guard forwarding, !tables.standInCarriers.contains(edge.carrier) else { continue }
            noteForwards(of: edge.source)
            if edge.target != edge.source { noteForwards(of: edge.target) }
        }
        touchedByType[type] = ofType
    }

    /// Notes in `touched` the ends of the edges a change to what `standIn` stands for changed (applied
    /// to the tables already): its own edges to what came and went, and, for each edge another shape
    /// carries at it, its copies' ends: the two it was emitted with, what came and went at this end,
    /// and, at the other, what that end reads as (each shape it stands for, if it's a stand-in that
    /// stands for something; for an edge from `standIn` to itself, every shape it stood for or stands
    /// for now, each of which is an end of a copy that came or went).
    private func touchForwards(_ standIn: ShapeID, _ change: ForwardsChange) {
        func note(_ id: ShapeID, _ type: EdgeTypeID) {
            touched.insert(id)
            touchedByType[type, default: []].insert(id)
        }
        note(standIn, StandingEdge.id)
        for (target, _) in change.came { note(target, StandingEdge.id) }
        for target in change.went { note(target, StandingEdge.id) }
        tables.forEachEmitted(at: standIn) { edge in
            guard !tables.standInCarriers.contains(edge.carrier) else { return }
            let other = edge.source == standIn ? edge.target : edge.source
            note(standIn, edge.type)
            note(other, edge.type)
            if other == standIn {
                for target in tables.forwards(of: standIn) { note(target, edge.type) }
                for target in change.went { note(target, edge.type) }
                return
            }
            for (target, _) in change.came { note(target, edge.type) }
            for target in change.went { note(target, edge.type) }
            for target in tables.forwards[other] ?? [] { note(target, edge.type) }
        }
    }

    /// Notes that a change read `ids` again, answered them or changed what they stand for (nil:
    /// everything, the file read afresh), for what was prepared before it (`changes(since:)`). Only
    /// once a preparer has been taken: an index nothing prepares for keeps no log.
    private func log(_ ids: Set<ShapeID>?) {
        guard logs else { return }
        generation += 1
        changeLog.append((generation, ids.flatMap { $0.count > Self.loggedMost ? nil : $0 }))
        if changeLog.count > Self.changesKept { changeLog.removeFirst(changeLog.count - Self.changesKept) }
    }

    /// What changed since `then` (a preparer's generation): nil when the log can't say (the file read
    /// afresh, a change too large to keep, or one older than the log keeps).
    private func changes(since then: Int) -> Set<ShapeID>? {
        guard then <= generation else { return nil }
        guard then < generation else { return [] }
        guard let oldest = changeLog.first, oldest.generation <= then + 1 else { return nil }
        var found: Set<ShapeID> = []
        for entry in changeLog where entry.generation > then {
            guard let ids = entry.ids else { return nil }
            found.formUnion(ids)
        }
        return found
    }

    /// How many changes the log keeps, and the most shapes one may name and still be kept by name.
    private static let changesKept = 64
    private static let loggedMost = 4_096

    private func clearTouched() {
        touched = []
        touchedByType = [:]
    }

    /// Bumps the revisions of those of these shapes whose revision has been read, telling their
    /// observers.
    private func bump(_ ids: Set<ShapeID>) {
        let (fewer, more) = ids.count < watched.count ? (ids, watched) : (watched, ids)
        for id in fewer where more.contains(id) {
            withMutation(keyPath: \.[revision: id]) { revisions[id, default: 0] += 1 }
        }
    }
}

extension TopologyIndex: EditorService {
    /// Follows the commit.
    public func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        hear(changes)
    }

    /// Nothing: the index is the file's, and showing another board changes no record. A file put in
    /// place with the switch is read afresh, and the change told to followers.
    public func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        clearTouched()
        guard change.isFileReplaced else { return }
        rebuild()
        log(nil)
        bump(touched)
        deliver(.rebuild)
    }
}

/// What the index reads of a kind's shapes: its sources (none for a stand-in kind with none), and
/// its rule if its shapes stand in. A class, so a lookup retains one object.
private final class KindUpkeep {
    let emitters: [EdgeEmitter]
    let rule: StandIn?

    init(emitters: [EdgeEmitter], rule: StandIn?) {
        self.emitters = emitters
        self.rule = rule
    }
}

/// What a stand-in declares: its kind (whose rule it goes by), and what its record says it stands for.
struct Declared: Equatable, Sendable {
    let kind: ShapeKind
    let forwarding: Forwarding?
}

/// What one commit has the index do about stand-ins: the stand-ins to work out whole again (read
/// again themselves), and, for those that only name shapes it changed, which; each once, in the order
/// they came; and how many records it read.
private struct Upkeep {
    private(set) var standIns: [ShapeID] = []
    /// The stand-ins whose named shapes changed, in the order they came.
    private(set) var rechecked: [ShapeID] = []
    var read = 0
    private var whole: Set<ShapeID> = []
    private var changedNamed: [ShapeID: [ShapeID]] = [:]

    mutating func standIn(_ id: ShapeID) {
        if whole.insert(id).inserted { standIns.append(id) }
    }

    /// `named`, a shape `standIn` names, changed.
    mutating func recheck(_ standIn: ShapeID, _ named: ShapeID) {
        if let index = changedNamed.index(forKey: standIn) {
            changedNamed.values[index].append(named)
        } else {
            changedNamed[standIn] = [named]
            rechecked.append(standIn)
        }
    }

    func isWhole(_ standIn: ShapeID) -> Bool { whole.contains(standIn) }

    /// The shapes `standIn` names that changed.
    func named(by standIn: ShapeID) -> [ShapeID] { changedNamed[standIn] ?? [] }
}

extension CanvasEditor {
    /// Topology's index of the file's edges; nil without TopologyPlugin.
    public var topology: TopologyIndex? { service(TopologyIndex.self) }

    /// `accessibleName(of:)`, but a part named on a stand-in (a key to a column on another board: the pill for its table, the column
    /// on the binding) is read as the part of the shape it stands for ("id in customers"), as a part named on the shape itself is.
    /// Nil for what neither names.
    public func accessibleName(readingThrough address: PartAddress) -> String? {
        if let name = accessibleName(of: address) { return name }
        guard address.part != nil, let shape = topology?.directTarget(of: address.shape) else { return nil }
        return accessibleName(of: PartAddress(shape, part: address.part))
    }
}

/// `editor.shape(inFile:)` for many shapes at once (a board deleted or pasted, thousands of them):
/// the file read once, and whether each board can be shown asked once.
@MainActor
private struct Lookup {
    let editor: CanvasEditor
    let shown: BoardID
    let document: CanvasDocument
    let file: CanvasFile
    let boardOwningKinds: Set<ShapeKind>
    var showable = ShowableBoards()

    init(_ editor: CanvasEditor) {
        self.editor = editor
        shown = editor.board
        document = editor.document
        file = editor.file
        boardOwningKinds = editor.registry.boardOwningKinds
    }

    mutating func shape(_ id: ShapeID) -> AnyShapeRecord? {
        guard let board = file.board(containing: id) else { return nil }
        if board == shown { return document[id] }
        return showable.canShow(board, in: file, boardOwningKinds: boardOwningKinds) ? file[board][id] : nil
    }
}

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
/// Services that read it as they hear a commit may hear it first: `catchUp` brings it up to date.
///
/// Stand-ins (`EdgeForwarding`) forward: every read gives the edges as they resolve through them
/// unless it asks for another view (`EdgeView`), each a mapping of the same tables. A commit
/// re-reads, beside the carriers it changed, the stand-ins it changed and those whose record names
/// (or whose answer holds) a shape it changed, and sets again only the carriers with an edge at a
/// stand-in whose shapes changed: still what it changed, and a move reads nothing. Answers for
/// stand-ins that stand for what's provided come with no commit (`provide`).
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
    /// Each stand-in on a board the editor can show (not kept aside): its kind, and what its record
    /// says it stands for.
    @ObservationIgnored private var standing: [ShapeID: Declared] = [:]
    /// The stand-ins whose record names each shape (`Forwarding.shapes`): those to look at again
    /// when a commit changes it.
    @ObservationIgnored private var declaredBy: [ShapeID: Set<ShapeID>] = [:]
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
    @ObservationIgnored private var settleSources: [Int: @MainActor () -> Bool] = [:]
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
    /// The revision the index is up to date with.
    @ObservationIgnored private var heardRevision: Int

    /// The shapes whose edges (at either end, and at either literal end) the last change to the
    /// edges changed: a commit's (none for one that changed none, as a move), or a provide's that
    /// changed any (one that changed none leaves it); none after a switch of board. Each change is
    /// told to followers as it comes (`follow`), which is how to hear one: a service reading this
    /// as it hears a commit misses every provide. `touched(types:)` is those whose edges of some
    /// types it changed.
    @ObservationIgnored public private(set) var touched: Set<ShapeID> = []
    /// `touched`, by the type of each edge that changed.
    @ObservationIgnored private var touchedByType: [EdgeTypeID: Set<ShapeID>] = [:]

    #if DEBUG
    /// How many records sources and stand-ins' forwarding rules have read (debug builds), so tests
    /// can hold a commit to what it changed.
    @ObservationIgnored public private(set) var recordsRead = 0
    /// How many edges sources emitted that were dropped for being Topology's own (debug builds): an
    /// edge in the slot `stands-for`, or of that type (`StandingEdge`).
    @ObservationIgnored public private(set) var reservedEdgesDropped = 0
    /// How many carriers' resolved edges are kept apart from what they emitted (debug builds): none
    /// in a file with no stand-ins, so tests can hold the tables to being sparse.
    public var resolvedCarrierCount: Int { tables.resolvedByCarrier.count }
    #endif

    init(editor: CanvasEditor) {
        self.editor = editor
        registry = editor.registry
        types = editor.registry.edgeTypes
        standInRules = editor.registry.standInRules()
        standInKinds = Set(standInRules.keys)
        heardRevision = editor.revision
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

    /// Whether any shape on a board the editor can show is a stand-in (of a kind that stands in,
    /// whatever it stands for now): a follower that looks for stand-ins among a change's shapes
    /// looks at none when there are none. O(1).
    public var hasStandIns: Bool { !standing.isEmpty }

    /// How `id` stands for its shapes now: not at all, as its record names them, as provided, or
    /// waiting for what's provided.
    public func forwarding(of id: ShapeID) -> ForwardingState {
        guard !standing.isEmpty, let forwarding = standing[id]?.forwarding else { return .none }
        switch forwarding {
        case .shapes: return .record(tables.forwards(of: id))
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

    /// Brings the index up to date with a commit it hasn't heard yet, which `changes` must be (the
    /// one a service is hearing): for a service that reads the index as it hears a commit, and may
    /// hear it before this one does. Nothing if it has heard it already.
    public func catchUp(_ changes: ChangeSet) {
        guard heardRevision != editor.revision else { return }
        hear(changes)
    }

    // MARK: Provided answers, and following the edges

    /// Answers for stand-ins whose record says they stand for what's provided
    /// (`Forwarding.provided`): what each stands for now. Not a commit: never saved, never undone.
    /// An answer for another key than the one the stand-in's record holds now, for a shape that
    /// isn't such a stand-in (on a board the editor can show), or older (`revision`) than the one
    /// held for that key, is dropped. The carriers at the stand-ins whose shapes changed are set
    /// again, the revisions of the ends that changed bumped, and, if any edge changed, the change
    /// told to followers (`.provide`); `touched` is then its ends.
    ///
    /// Never call it while a service hears a commit or a switch (`documentDidChange`,
    /// `boardDidChange`), nor from a follower: from a scheduled callback or a task's continuation on
    /// the main actor, so that each commit is told with one consistent table.
    public func provide(_ answers: [ShapeID: ProvidedForwarding]) {
        assert(!delivering, "a follower never provides")
        var work = Upkeep()
        for (id, answer) in answers {
            guard case .provided(let key)? = standing[id]?.forwarding, key == answer.key else { continue }
            if let held = provided[id] {
                guard answer.revision >= held.revision, answer != held else { continue }
            }
            setAnswer(id, answer)
            pendingStandIns.remove(id)
            work.standIn(id)
        }
        if !work.standIns.isEmpty {
            let before = (touched, touchedByType)
            clearTouched()
            var lookup = Lookup(editor)
            apply(&work, in: &lookup)
            if touched.isEmpty {
                (touched, touchedByType) = before
            } else {
                bump(touched)
                deliver(.provide)
            }
        }
        wakeWaiters()
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
    /// settle that may stop.
    private func deliver(_ cause: TopologyChange.Cause) {
        if !touched.isEmpty, !followers.isEmpty {
            let change = TopologyChange(touched: touched, touchedByType: touchedByType, cause: cause)
            delivering = true
            defer { delivering = false }
            for key in followers.keys.sorted() {
                // One that a follower before it cancelled isn't called.
                followers[key]?(change)
            }
        }
        wakeWaiters()
    }

    // MARK: Settling

    /// Says, for whatever provides answers, whether it still has work (`busy`: a wait armed, a batch
    /// out, a stand-in asked and not answered), so the edges aren't settled while it does. It counts
    /// as long as the token returned is held (`SettleSource`), or until it's cancelled. `busy` is
    /// asked whenever the index looks; when it goes idle with no provide or commit to say so, say
    /// `settleSourceChanged()`.
    public func keepsSettling(while busy: @escaping @MainActor () -> Bool) -> SettleSource {
        let key = nextSettleSource
        nextSettleSource += 1
        settleSources[key] = busy
        return SettleSource(index: self, key: key)
    }

    func stopSettling(_ key: Int) {
        settleSources[key] = nil
        wakeWaiters()
    }

    /// Tells those waiting to look again: a source went idle with no provide or commit to say so.
    public func settleSourceChanged() { wakeWaiters() }

    /// Whether answers are still on their way: whether any source says it has work.
    public var isSettling: Bool { settleSources.values.contains { $0() } }

    /// Waits until the edges have settled (no source has work): true then, false if `timeout` (on
    /// the editor's scheduler) runs out first, or the task is cancelled. At once if settled now.
    /// Woken by every change told and every provide, and by `settleSourceChanged()`.
    public func settled(timeout: Duration) async -> Bool {
        guard isSettling else { return true }
        let waiters = waiters, scheduler = editor.scheduler, key = waiters.reserve()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { return continuation.resume(returning: false) }
                let timeout = scheduler.schedule(after: timeout) { waiters.finish(key, settled: false) }
                waiters.wait(key, continuation, timeout: timeout)
            }
        } onCancel: {
            Task { @MainActor in waiters.finish(key, settled: false) }
        }
    }

    /// Ends the waits, settled, if no source has work.
    private func wakeWaiters() {
        guard !waiters.isEmpty, !isSettling else { return }
        waiters.finishAll()
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
    /// through the stand-ins as they stood), what stand-ins stand for worked out again where that may
    /// have changed and the carriers at those whose shapes changed set again, then the revisions of
    /// the shapes whose edges changed bumped, and the change told to followers.
    private func hear(_ changes: ChangeSet) {
        heardRevision = editor.revision
        clearTouched()
        if changes.replacedDocument {
            rebuild()
        } else {
            var lookup = Lookup(editor), work = Upkeep()
            // Removed first: one commit can take a shape off one board and put it on another.
            for id in changes.removed { refresh(id, in: &lookup, &work) }
            for id in changes.elsewhere { refresh(id, in: &lookup, &work) }
            for id in changes.added { refresh(id, in: &lookup, &work) }
            for id in changes.changed where !changes.moved.contains(id) { refresh(id, in: &lookup, &work) }
            apply(&work, in: &lookup)
        }
        bump(touched)
        deliver(changes.replacedDocument ? .rebuild : .commit)
    }

    /// Reads a shape again, wherever it is now (on no board the editor can show, it carries nothing
    /// and stands for nothing): what it emits, what it says it stands for if it's a stand-in, and,
    /// as a shape a stand-in's record may name, which stand-ins to look at again. Its kind is looked
    /// up once, and the stand-in tables only while they hold something: a file with no stand-ins
    /// reads a shape as it did before there were any.
    private func refresh(_ id: ShapeID, in lookup: inout Lookup, _ work: inout Upkeep) {
        // The record bound once, and no closures: each would check, at every shape, that it runs
        // on the main actor.
        var emitted: [Edge] = [], declares = false
        if let record = lookup.shape(id), let kind = upkeep[record.kind] {
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
        // A shape a stand-in names, or an answer holds: whether it's there, and may be stood for,
        // may have changed.
        if !declaredBy.isEmpty { for standIn in declaredBy[id] ?? [] { work.standIn(standIn) } }
        if !providedBy.isEmpty { for standIn in providedBy[id] ?? [] { work.standIn(standIn) } }
    }

    /// What the records read change for stand-ins: what each stand-in looked at again stands for,
    /// then, for each whose shapes changed, the carriers with an edge at it (as set, so those read
    /// this commit too) and itself set again. A carrier set twice in one commit may leave in `touched`
    /// a shape its edges reached only in between: one a stand-in it was just pointed at stood for
    /// until this commit.
    private func apply(_ work: inout Upkeep, in lookup: inout Lookup) {
        for standIn in work.standIns {
            let (targets, kind) = effective(standIn, in: &lookup)
            guard tables.setForwards(standIn, targets, kind: kind) else { continue }
            for carrier in tables.carriers(at: standIn) { work.carrier(carrier) }
            work.carrier(standIn)
        }
        for carrier in work.carriers { set(carrier, emitted: tables.byCarrier[carrier] ?? []) }
    }

    /// Reads every board the editor can show afresh, and lets go of carriers and stand-ins it no
    /// longer finds. Carriers whose edges didn't change touch nothing. Each carrier is set as it's
    /// read, through the stand-ins as they stood; then what every stand-in, there before or now,
    /// stands for is worked out, and the carriers at those whose shapes changed are set again: a
    /// file with no stand-ins costs what it did before there were any. Answers provided are let go
    /// of: they were for the file as it was, and are asked again.
    private func rebuild() {
        var seen: Set<ShapeID> = []
        let before = Array(tables.forwards.keys)
        for id in Array(standing.keys) { declare(id, nil) }
        let children = editor.file.children
        var boards: [BoardID] = [.root], met: Set<BoardID> = [.root], next = 0, found: [ShapeID] = []
        while next < boards.count {
            let board = boards[next]
            next += 1
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
                let owned = BoardID(owner: record.id)
                if children[record.id] != nil, registry.ownsShowableBoard(record), met.insert(owned).inserted { boards.append(owned) }
            }
        }
        for carrier in Set(tables.byCarrier.keys).union(tables.resolvedByCarrier.keys) where !seen.contains(carrier) {
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
        if case .shapes(let old)? = standing[id]?.forwarding {
            for target in old {
                guard let index = declaredBy.index(forKey: target) else { continue }
                declaredBy.values[index].remove(id)
                if declaredBy.values[index].isEmpty { declaredBy.remove(at: index) }
            }
        }
        standing[id] = declared
        if case .shapes(let new)? = declared?.forwarding {
            for target in new { declaredBy[target, default: []].insert(id) }
        }
        if let held = provided[id], declared?.forwarding != .provided(held.key) { setAnswer(id, nil) }
        if case .provided(let key)? = declared?.forwarding, provided[id]?.key != key {
            pendingStandIns.insert(id)
        } else {
            pendingStandIns.remove(id)
        }
    }

    /// Keeps a stand-in's answer (nil: none), and which stand-ins' answers name each shape, in step.
    private func setAnswer(_ id: ShapeID, _ answer: ProvidedForwarding?) {
        for target in provided[id]?.shapes ?? [] {
            guard let index = providedBy.index(forKey: target) else { continue }
            providedBy.values[index].remove(id)
            if providedBy.values[index].isEmpty { providedBy.remove(at: index) }
        }
        provided[id] = answer
        for target in answer?.shapes ?? [] { providedBy[target, default: []].insert(id) }
    }

    /// What a stand-in stands for now: the shapes it declares, in order, each once, that are on a
    /// board the editor can show, not kept aside, not stand-ins (one hop), not itself, and that its
    /// rule admits, up to its rule's most; and whether its record names them or they were provided.
    private func effective(_ standIn: ShapeID, in lookup: inout Lookup) -> ([ShapeID], ForwardKind) {
        guard let declared = standing[standIn], let forwarding = declared.forwarding, let rule = standInRules[declared.kind] else {
            return ([], .record)
        }
        let named: [ShapeID], kind: ForwardKind
        switch forwarding {
        case .shapes(let ids): (named, kind) = (ids, .record)
        // Nothing provided for the key it holds now: it stands for nothing yet.
        case .provided(let key): (named, kind) = (provided[standIn].flatMap { $0.key == key ? $0.shapes : nil } ?? [], .provided)
        }
        var taken: [ShapeID] = [], met: Set<ShapeID> = []
        for target in named where taken.count < rule.maxTargets && met.insert(target).inserted && target != standIn {
            guard let record = lookup.shape(target), !record.isOpaque, standInRules[record.kind] == nil,
                  rule.admitting(record, registry) else { continue }
            taken.append(target)
        }
        return (taken, kind)
    }

    /// What a carrier carries as stand-ins forward it: a stand-in's own edges as emitted, then one to
    /// each shape it stands for; any other's with each end that's a stand-in for something replaced
    /// by each shape it stands for, at most `EdgeForwarding.maxPairsPerCarrier` (every edge keeping
    /// one). Nil when that's what it emitted.
    private func resolve(_ carrier: ShapeID, _ emitted: [Edge]) -> [Edge]? {
        guard !tables.forwards.isEmpty else { return nil }
        if standing[carrier] != nil {
            let targets = tables.forwards(of: carrier)
            guard !targets.isEmpty else { return nil }
            return emitted + targets.map {
                Edge(type: StandingEdge.id, source: carrier, target: $0, carrier: carrier, slot: StandingEdge.slot, origin: .standing)
            }
        }
        var resolved: [Edge] = [], forwarded = false
        for edge in emitted {
            let sources = tables.forwards[edge.source], targets = tables.forwards[edge.target]
            guard sources != nil || targets != nil else {
                resolved.append(edge)
                continue
            }
            forwarded = true
            let origin = EdgeOrigin.forwarded(source: sources == nil ? nil : edge.source, target: targets == nil ? nil : edge.target)
            var first = true
            pairs: for source in sources ?? [edge.source] {
                for target in targets ?? [edge.target] {
                    guard first || resolved.count < EdgeForwarding.maxPairsPerCarrier else { break pairs }
                    resolved.append(Edge(type: edge.type, source: source, target: target, carrier: carrier, slot: edge.slot,
                                         count: edge.count, origin: origin))
                    first = false
                }
            }
        }
        return forwarded ? resolved : nil
    }

    /// Makes `emitted` what `carrier` emitted, resolved through the stand-ins as they stand now, and
    /// notes the ends of the edges that changed in `touched`.
    private func set(_ carrier: ShapeID, emitted: [Edge]) {
        touch(tables.set(carrier, emitted: emitted, resolved: resolve(carrier, emitted)))
    }

    /// Notes each edge's ends, and its literal ends, in `touched`, under its type: a run of edges of
    /// one type (a carrier's, mostly) looks its type up once, and an end the edge before of that type
    /// had (the source of every copy of an arrow fanned out, the stand-in it went through) is noted
    /// once.
    private func touch(_ edges: [Edge]) {
        guard var type = edges.first?.type else { return }
        var ofType = touchedByType.removeValue(forKey: type) ?? []
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
                guard !sameRun || !edges[index - 1].isFiled(under: node) else { return }
                touched.insert(node)
                ofType.insert(node)
            }
        }
        touchedByType[type] = ofType
    }

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
    /// Follows the commit, unless a service that reads the index brought it up to date first
    /// (`catchUp`).
    public func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        guard heardRevision != editor.revision else { return }
        hear(changes)
    }

    /// Nothing: the index is the file's, and showing another board changes no record. A file put in
    /// place with the switch is read afresh, and the change told to followers.
    public func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        heardRevision = editor.revision
        clearTouched()
        guard change.isFileReplaced else { return }
        rebuild()
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
private struct Declared: Equatable {
    let kind: ShapeKind
    let forwarding: Forwarding?
}

/// What one commit has the index do about stand-ins: the stand-ins to look at again, and the carriers
/// to set again, each once, in the order they came.
private struct Upkeep {
    private(set) var carriers: [ShapeID] = []
    private(set) var standIns: [ShapeID] = []
    private var dirtyCarriers: Set<ShapeID> = []
    private var dirtyStandIns: Set<ShapeID> = []

    mutating func carrier(_ id: ShapeID) {
        if dirtyCarriers.insert(id).inserted { carriers.append(id) }
    }

    mutating func standIn(_ id: ShapeID) {
        if dirtyStandIns.insert(id).inserted { standIns.append(id) }
    }
}

extension CanvasEditor {
    /// Topology's index of the file's edges; nil without TopologyPlugin.
    public var topology: TopologyIndex? { service(TopologyIndex.self) }
}

/// `editor.shape(inFile:)` for many shapes at once (a board deleted or pasted, thousands of them):
/// the file read once, and whether each board can be shown asked once.
@MainActor
private struct Lookup {
    let editor: CanvasEditor
    let shown: BoardID
    let document: CanvasDocument
    let file: CanvasFile
    var showable: [BoardID: Bool] = [:]

    init(_ editor: CanvasEditor) {
        self.editor = editor
        shown = editor.board
        document = editor.document
        file = editor.file
    }

    mutating func shape(_ id: ShapeID) -> AnyShapeRecord? {
        guard let board = file.board(containing: id) else { return nil }
        if board == shown { return document[id] }
        let canShow: Bool
        if let known = showable[board] {
            canShow = known
        } else {
            canShow = editor.canShow(board)
            showable[board] = canShow
        }
        return canShow ? file[board][id] : nil
    }
}

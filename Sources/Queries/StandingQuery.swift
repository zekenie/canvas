import Canvas
import QueryLanguage
import Topology

// Standing queries: one stored query's matches over the whole file, kept current after every commit
// at the cost of what the commit changed (`QueryState.stand`). A plugin that judges shapes by a query
// it keeps (a container's constraints) holds one and reads `matches` and `isPending` on the main
// actor whenever it must, from a drag's hint or a rule.
//
// What a commit costs one: a commit that only moved shapes on their board, nothing; else an ask of
// the shapes it added or changed (and those that came from or went to another board; and for a plan
// with `:has`, which reads what's inside a shape, the shapes one that changed container was inside
// before and is inside now, or the whole file when it changed board), each answered
// alone, the evaluation seeded from them so it walks no other shape. A shape's answer depends on its
// own record, where it is, its edges, the facts the query's words take, and what the plan's anchors
// match among every shape (`StandingAnchor`): the ask first checks that its shapes leave every anchor
// as the last whole answer had it, and asks the whole file instead when they don't. The whole file is
// asked again, one request off the main actor, when the commit changed what the plan reads beyond a
// shape: a fact a word took (`QueryFileFact.revision(in:)` moved, or can't say), Topology's edges of a
// type the plan reads (a stand-in's answer, which is no commit, too), containment for a plan that
// reads it (a container or a board's owner put in another container, moved across boards or gone;
// a board come or gone with its owner), a shape gone that an anchor matched or that `:dangling` may
// have pointed at, or a document or file put in place.

/// What a standing query says after answers land: the shapes that flipped (match now, or no longer)
/// and whether it is settled (no ask out).
public struct StandingQueryChange: Sendable, Equatable {
    public let flipped: Set<ShapeID>
    public let isSettled: Bool

    public init(flipped: Set<ShapeID>, isSettled: Bool) {
        self.flipped = flipped
        self.isSettled = isSettled
    }
}

/// One stored query's matches over the whole file, kept current (`QueryState.stand`): its identity is
/// the subscription, which stops on `stop()` and when let go of, and when the editor goes.
@MainActor
public final class StandingQuery {
    /// The query as the language writes it.
    public let canonical: String
    /// The shapes it matches, as of its last answers: a shape a commit named keeps the answer it had
    /// until its new one lands (`isPending`), and a shape gone from the file leaves at once.
    public private(set) var matches: Set<ShapeID> = []
    /// Whether the first answer about the whole file has landed.
    public private(set) var isAnswered = false
    /// Why the last ask failed (`too_slow`, `board_closed`, …), until an answer lands; its shapes stay
    /// pending, and the next commit, whatever it is (a drag's event too), asks them again with what it
    /// names (the whole file, for a whole file's ask).
    public private(set) var failure: QueryError?
    /// Whether it has stopped: `stop()`, or the editor gone. It asks nothing more and says nothing more.
    public private(set) var isStopped = false
    /// Told on the main actor after answers apply, a shape gone leaves, or the query goes from settled to
    /// not or back: the shapes that flipped and whether it is settled now. Never with an answer older
    /// than one asked later about the same shape. Nothing may change the file here: it may be told while
    /// a commit is delivered (`editor.onceSettled`).
    public var onChange: (@MainActor (StandingQueryChange) -> Void)?

    private weak var state: QueryState?
    private let plan: QueryPlan
    private let places: [StandingAnchor]
    let reads: StandingReads

    /// What each anchor matched among every shape, as of the whole answer numbered `anchorsAt`.
    private var anchors: [PlanNodeID: Set<ShapeID>] = [:]
    private var anchorsAt = -1
    /// The facts the last ask's words took, with their revisions then.
    private var factsRead = FactsRead()
    private var nextAsk = 0
    /// The whole file's ask out, if one is.
    private var whole: Ask?
    /// The asks of a commit's shapes out, by number.
    private var asks: [Int: Ask] = [:]
    /// For each shape asked and not answered, the newest ask out about it.
    private var latest: [ShapeID: Int] = [:]
    /// Shapes commits named while the whole file's ask was out, which it took up before they changed:
    /// asked once it lands.
    private var owed: Set<ShapeID> = []
    /// Shapes whose ask failed, by the ask's number: pending until a later ask answers them.
    private var unanswered: [ShapeID: Int] = [:]
    private var wholeFailed = false
    /// Shapes new to the file that no answer has landed for: `matches` doesn't hold them for want of an answer, not for a no.
    private var unseen: Set<ShapeID> = []
    /// Whether a document was put in place since the last whole answer: `matches` is of the file before it.
    private var answersAreStale = false
    /// Shapes gone from the file while an ask was out, which an answer taken up before then still holds.
    private var goneWhileOut: Set<ShapeID> = []
    /// A change to edges the plan reads, heard while a commit is delivered: the whole file, once it settles.
    private var edgesMoved = false
    private var toldSettled = true

    init(plan: QueryPlan, state: QueryState) {
        canonical = plan.canonical
        self.plan = plan
        self.state = state
        places = plan.standingAnchors
        reads = plan.standingReads
    }

    isolated deinit {
        cancelAsks()
        state?.standing.remove(self)
    }

    /// One ask out: its number, the shapes it asked (nil: the whole file), the anchors it checked
    /// against (`anchorsAt` then), and its evaluation.
    private final class Ask {
        let number: Int
        let shapes: Set<ShapeID>?
        let generation: Int
        var handle: StandingAskHandle?

        init(number: Int, shapes: Set<ShapeID>?, generation: Int) {
            self.number = number
            self.shapes = shapes
            self.generation = generation
        }
    }

    // MARK: Reading it

    /// The shapes commits named whose new answer hasn't landed (and those whose ask failed). While the
    /// whole file is asked (`isAskingWholeFile`, the first answer among those), every shape is pending
    /// too: `isPending(_:)` says so of each.
    public var pending: Set<ShapeID> { Set(latest.keys).union(owed).union(unanswered.keys) }

    /// Whether the whole file is being asked: every shape is pending until it lands.
    public var isAskingWholeFile: Bool { whole != nil }

    /// Whether the shape's answer is still to come: a commit named it, or the whole file is being asked,
    /// or its ask failed and nothing has asked it since.
    public func isPending(_ id: ShapeID) -> Bool {
        whole != nil || wholeFailed || !isAnswered || latest[id] != nil || owed.contains(id) || unanswered[id] != nil
    }

    /// Whether the shape matches, as of the last answer: nil while unanswered or pending.
    public func answer(for id: ShapeID) -> Bool? {
        isPending(id) ? nil : matches.contains(id)
    }

    /// The last answer it had for a shape, kept while it asks again (`answer(for:)` is nil then): what a plugin that judges
    /// a shape by this query goes by for a shape whose answer is coming (an edit asks it again at every keystroke). Nil for a
    /// shape it never answered (new to the file, its ask not landed yet), for every shape before its first whole answer lands,
    /// and for every shape after a document is put in place until the whole file is answered again.
    public func lastAnswer(for id: ShapeID) -> Bool? {
        guard isAnswered, !answersAreStale, !unseen.contains(id) else { return nil }
        return matches.contains(id)
    }

    /// Whether nothing asked is out: false from the moment it stands until its first answer (or the
    /// failure of its first ask) lands.
    public var isSettled: Bool { whole == nil && asks.isEmpty && (isAnswered || wholeFailed || isStopped) }

    /// Stops it: nothing more is asked or told, and what's out is cancelled.
    public func stop() {
        guard !isStopped else { return }
        isStopped = true
        cancelAsks()
        state?.standing.remove(self)
    }

    // MARK: Hearing the file

    /// Asks the whole file for the first time.
    func start() {
        askWholeFile()
        tell([])
    }

    /// A commit, once every service has settled it.
    func heard(_ changes: ChangeSet, in editor: CanvasEditor) {
        guard !isStopped else { return }
        let edges = edgesMoved
        edgesMoved = false
        // What failed is asked again by the next commit, whatever it is.
        let retry = wholeFailed || !unanswered.isEmpty
        // A drag's every event: nothing a query reads but where shapes are, which only a plugin's word may.
        if !retry, changes.onlyMoves, changes.fileValues.isEmpty, !edges, !reads.box || changes.moved.isEmpty { return }
        let file = editor.withoutObservingDocument { editor.file }
        var named = changes.edited.union(changes.elsewhere).union(changes.removed)
        if reads.box { named.formUnion(changes.moved) }
        let touched = named
        named.formUnion(unanswered.keys)
        // A shape the commit brought into the file has no answer to keep while its first is asked.
        for id in changes.added { unseen.insert(id) }
        for id in changes.elsewhere where changes.before(id) == nil { unseen.insert(id) }
        if changes.replacedDocument { answersAreStale = true }
        var gone: Set<ShapeID> = []
        for id in named where file.record(id) == nil { gone.insert(id) }
        named.subtract(gone)
        let flipped = matches.intersection(gone)
        matches.subtract(gone)
        for id in gone {
            latest[id] = nil
            owed.remove(id)
            unanswered[id] = nil
            unseen.remove(id)
        }
        if !isSettled { goneWhileOut.formUnion(gone) }
        goneWhileOut.subtract(named)
        var wholeFile = edges || wholeFailed || changes.replacedDocument || factsRead.moved(in: editor)
        if !wholeFile, reads.containment { wholeFile = Self.containmentMoved(changes, file: file, registry: editor.registry) }
        if !wholeFile, reads.descendants {
            if let holders = Self.holdersReached(changes, touched: touched.subtracting(gone), file: file, editor: editor) {
                named.formUnion(holders)
            } else {
                wholeFile = true
            }
        }
        if !wholeFile, reads.presence { wholeFile = !changes.removed.isEmpty || !changes.elsewhere.isEmpty || !changes.boardsReached.isEmpty }
        if !wholeFile, !gone.isEmpty { wholeFile = anchors.values.contains { !$0.isDisjoint(with: gone) } }
        if wholeFile {
            askWholeFile()
        } else if whole != nil || !isAnswered {
            owed.formUnion(named)
        } else if !named.isEmpty {
            ask(named)
        }
        tell(flipped)
    }

    /// A whole file put in place.
    func fileReplaced() {
        guard !isStopped else { return }
        answersAreStale = true
        askWholeFile()
        tell([])
    }

    /// A change to Topology's edges: one a commit made is taken with the commit; a stand-in's answer,
    /// which no commit carries, asks the whole file when it reaches the plan (or moved a fact it reads).
    func edgesChanged(_ change: TopologyChange) {
        guard !isStopped else { return }
        let reaches = reads.reads(change.touchedByType)
        guard change.cause == .provide else {
            if reaches { edgesMoved = true }
            return
        }
        // Out of the follower's call: the whole file is taken up as any query takes it up.
        Task { @MainActor [weak self] in
            guard let self, !self.isStopped, let editor = self.state?.editor else { return }
            guard reaches || self.factsRead.moved(in: editor) else { return }
            self.askWholeFile()
            self.tell([])
        }
    }

    /// Whether a commit changed where shapes are in the tree for shapes it doesn't name: a container or
    /// a board's owner (whose shapes are inside it) put in another container, moved to another board or
    /// gone, or any shape of one on another board; a board come or gone with its owner; a document put
    /// in place. A shape that holds nothing changing place is named, and asked, itself.
    static func containmentMoved(_ changes: ChangeSet, file: CanvasFile, registry: Registry) -> Bool {
        if changes.replacedDocument || !changes.boardsAdded.isEmpty || !changes.boardsRemoved.isEmpty { return true }
        func holds(_ kind: ShapeKind) -> Bool { registry.containingKinds.contains(kind) || registry.boardOwningKinds.contains(kind) }
        for id in changes.removed {
            if let before = changes.before(id), holds(before.kind) { return true }
        }
        for id in changes.changed where !changes.moved.contains(id) {
            guard let before = changes.before(id), holds(before.kind) else { continue }
            if file.record(id)?.container != before.container { return true }
        }
        for id in changes.elsewhere {
            if let kind = (file.record(id) ?? changes.before(id))?.kind, holds(kind) { return true }
        }
        return false
    }

    /// For a plan whose answer for a shape reads what's inside it (`:has`): the shapes a commit's
    /// shapes that changed container were inside before it and are inside now, whose answers that
    /// changed, to be asked with them. O(their depth). Nil, the whole file, for a shape the commit took
    /// to or brought from another board or touched on one, where it was before isn't said. A shape new
    /// to the file, or gone from it, needs none: it moves an anchor (`:has`'s items) if it matters, and
    /// the check of the anchors finds it. A container put in another one is `containmentMoved`'s.
    static func holdersReached(_ changes: ChangeSet, touched: Set<ShapeID>, file: CanvasFile, editor: CanvasEditor) -> Set<ShapeID>? {
        guard let topology = editor.topology else { return [] }
        var found: Set<ShapeID> = []
        func inside(_ id: ShapeID) { found.formUnion(editor.withoutObservingDocument { topology.ancestors(of: id) }) }
        for id in touched {
            guard let before = changes.before(id), let now = file.record(id) else { continue }
            if changes.removed.contains(id) || changes.added.contains(id) || changes.elsewhere.contains(id) { return nil }
            guard before.container != now.container else { continue }
            // Its old containers are where they were (one that moved is `containmentMoved`'s): the nearest, and what it's in.
            if let old = before.container, file.record(old) != nil {
                found.insert(old)
                inside(old)
            }
            inside(id)
        }
        return found.subtracting(touched)
    }

    // MARK: Asking

    /// Asks the whole file: every ask out is cancelled, since this one covers what each asked.
    private func askWholeFile() {
        cancelAsks()
        latest = [:]
        owed = []
        unanswered = [:]
        wholeFailed = false
        launch(nil)
    }

    /// Asks a commit's shapes; checked against the anchors with the shapes of the asks still out, whose
    /// answers haven't confirmed the anchors yet.
    private func ask(_ shapes: Set<ShapeID>) {
        launch(shapes)
    }

    private func launch(_ shapes: Set<ShapeID>?) {
        guard let state else { return stop() }
        let number = nextAsk
        nextAsk += 1
        var checked: Set<ShapeID> = []
        if let shapes {
            checked = shapes
            for out in asks.values { checked.formUnion(out.shapes ?? []) }
        }
        let out = Ask(number: number, shapes: shapes, generation: anchorsAt)
        if let shapes {
            asks[number] = out
            for id in shapes {
                latest[id] = number
                unanswered[id] = nil
            }
        } else {
            whole = out
        }
        let read = FactsRead()
        factsRead = read
        let question = StandingAsk(plan: plan, anchorPlaces: places, shapes: shapes, checked: checked, anchors: shapes == nil ? [:] : anchors)
        out.handle = state.ask(standing: question, noting: read) { [weak self] result in self?.land(number, result) }
    }

    private func cancelAsks() {
        whole?.handle?.cancel()
        whole = nil
        for out in asks.values { out.handle?.cancel() }
        asks = [:]
    }

    // MARK: Answers

    private func land(_ number: Int, _ result: Result<StandingAnswer, QueryError>) {
        guard !isStopped else { return }
        let out: Ask
        if let current = whole, current.number == number {
            out = current
            whole = nil
        } else if let current = asks.removeValue(forKey: number) {
            out = current
        } else {
            return
        }
        guard state?.editor != nil else { return stop() }
        switch result {
        case .failure(let error):
            if error.reason == .boardClosed { return stop() }
            failure = error
            if let shapes = out.shapes {
                for id in shapes where latest[id] == number {
                    latest[id] = nil
                    unanswered[id] = number
                }
            } else {
                wholeFailed = true
            }
            tell([])
        case .success(.whole(let found, let kept, _)):
            tell(applyWhole(number, found, anchors: kept))
        case .success(.shapes(let found)):
            guard let shapes = out.shapes else { return }
            let current = shapes.filter { latest[$0] == number }
            for id in current { latest[id] = nil }
            // Checked against anchors a whole answer has since replaced: asked again against these.
            if out.generation != anchorsAt {
                if whole != nil { owed.formUnion(current) } else if !current.isEmpty { ask(current) }
                return tell([])
            }
            failure = nil
            unseen.subtract(current)
            var flipped: Set<ShapeID> = []
            for id in current where !goneWhileOut.contains(id) {
                let matched = found.contains(id)
                if matched != matches.contains(id) {
                    flipped.insert(id)
                    if matched { matches.insert(id) } else { matches.remove(id) }
                }
            }
            tell(flipped)
        }
    }

    /// The whole file's answer, numbered `number`: every shape takes it but those asked since (whose
    /// answers are newer) and those gone since; the asks out from before it are covered, and cancelled.
    private func applyWhole(_ number: Int, _ found: Set<ShapeID>, anchors kept: [PlanNodeID: Set<ShapeID>]) -> Set<ShapeID> {
        for (key, out) in asks where key < number {
            out.handle?.cancel()
            asks[key] = nil
        }
        latest = latest.filter { $0.value > number }
        unanswered = unanswered.filter { $0.value > number }
        let newer = Set(latest.keys).union(owed).union(unanswered.keys)
        unseen.formIntersection(newer)
        answersAreStale = false
        var now = found.subtracting(goneWhileOut)
        if !newer.isEmpty { now = now.subtracting(newer).union(matches.intersection(newer)) }
        let flipped = now.symmetricDifference(matches)
        matches = now
        anchors = kept
        anchorsAt = number
        isAnswered = true
        failure = nil
        wholeFailed = false
        if whole == nil, !owed.isEmpty {
            let shapes = owed
            owed = []
            ask(shapes)
        }
        return flipped
    }

    /// Tells `onChange` what flipped, and whether it is settled now, when either is news.
    private func tell(_ flipped: Set<ShapeID>) {
        if isSettled { goneWhileOut = [] }
        let settled = isSettled
        guard !flipped.isEmpty || settled != toldSettled else { return }
        toldSettled = settled
        onChange?(StandingQueryChange(flipped: flipped, isSettled: settled))
    }
}

/// The standing queries an editor's queries hold, weakly, and the one following of Topology they
/// share while any is held: none held, none kept.
@MainActor
final class StandingQueries {
    private final class Held {
        weak var query: StandingQuery?
        init(_ query: StandingQuery) { self.query = query }
    }

    private var held: [ObjectIdentifier: Held] = [:]
    private var following: TopologyFollowing?

    var isEmpty: Bool { held.isEmpty }

    /// Those held, in no order.
    var all: [StandingQuery] { held.values.compactMap(\.query) }

    func add(_ query: StandingQuery, following topology: TopologyIndex?) {
        held[ObjectIdentifier(query)] = Held(query)
        if following == nil {
            following = topology?.follow { [weak self] change in
                for query in self?.all ?? [] { query.edgesChanged(change) }
            }
        }
    }

    func remove(_ query: StandingQuery) {
        held[ObjectIdentifier(query)] = nil
        held = held.filter { $0.value.query != nil }
        if held.isEmpty {
            following?.cancel()
            following = nil
        }
    }

    /// The editor is going: every standing query stops.
    func stopAll() {
        for query in all { query.stop() }
        held = [:]
        following?.cancel()
        following = nil
    }
}

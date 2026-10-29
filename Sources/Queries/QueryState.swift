import Canvas
import FuzzyMatching
import QueryLanguage
import Topology

/// An editor's queries (`editor.queries`): the vocabulary, made on first use and kept (the registry
/// never changes); checking a query against it; and answering one about the whole file.
///
/// A query costs the main actor its reading and resolving and one turn that takes up the file, O(1)
/// (`QuerySnapshot`: the file, Topology's snapshot, the board shown, what the words it uses take);
/// everything else runs off the main actor over that snapshot (`Evaluation`), but for what only the
/// main actor can say (derived names, some words' verdicts), asked in slices of 2 ms each, a query
/// asking one at a time (`MainFacts`). Queries on one editor run at once: each takes up the file as
/// soon as it's asked and is answered alongside the others, over a snapshot of its own, and their
/// slices take their places in the main queue among each other's and the run loop's sources. A query
/// stops when its caller's task is cancelled (`cancelled`) or when its deadline has passed since it
/// was asked or last had a slice answered (`QueryBudget.deadline(forShapes:)`, longer for a larger
/// file), or the time its request allows in all (`QueryRequest.deadline`): scheduled actions on
/// `editor.scheduler` cancel it (`too_slow`), each stopping that query alone; and every query on an
/// editor stops when it goes (`board_closed`).
///
/// It keeps nothing per shape or per board, and hears no commit: a commit costs it nothing, ever,
/// and no snapshot outlives its query. Snapshots share the file's tables and Topology's until a
/// commit changes one, which copies it once however many snapshots hold it, so queries at once cost
/// a commit no more than one does.
@MainActor
public final class QueryState {
    /// Weak: a query in flight never keeps a closed file's editor alive.
    private weak var editor: CanvasEditor?
    private let registry: Registry
    /// The snapshots alive.
    private let live = LiveCount()

    init(editor: CanvasEditor) {
        self.editor = editor
        registry = editor.registry
    }

    /// What this app's queries can name: made on the first query, and kept.
    public private(set) lazy var vocabulary = QueryVocabulary(registry: registry)

    /// The word that says what the person has selected (`registrar.querySelection`), if a plugin
    /// adds one.
    private lazy var selectionWord: String? = vocabulary.contributedWords.values.first(where: \.isSelection)?.word

    #if DEBUG
    /// How many snapshots are alive (debug builds): 0 whenever no query is running.
    public var liveSnapshots: Int { live.value }
    /// How many times a query has taken up the file.
    public private(set) var captures = 0
    /// How many times a query's text has been read and resolved: a batch checks each text once,
    /// whatever the views its requests ask it in.
    public private(set) var checks = 0
    /// How many main slices queries have run.
    public private(set) var mainSlices = 0
    /// How many records' properties queries have written as JSON.
    public private(set) var recordsEncoded = 0
    /// How many derived names, and words' verdicts, queries have asked the main actor.
    public private(set) var derivedTitlesAsked = 0
    public private(set) var verdictsAsked = 0
    /// How many shapes' problems queries have asked the main actor (a row's `problems`).
    public private(set) var problemsAsked = 0
    /// How many times a query has walked every shape it ranges over.
    public private(set) var universeWalks = 0
    /// How many compounds started from their anchors' edges.
    public private(set) var seededFromAnchors = 0
    #endif

    // MARK: Checking

    /// Reads and resolves a query, and answers nothing. Refused `no_topology` without Topology,
    /// whatever the query. A hint that waits on what the kinds or the shapes by id say is settled
    /// (`HintPremise`); one that waits on titles is left for `run`, which reads them.
    public func check(_ text: String) throws(QueryError) -> QueryPlan {
        guard let editor else { throw .boardClosed }
        guard let topology = editor.topology else { throw .noTopology }
        return try check(text, presentEdgeTypes: topology.snapshot().presentTypes)
    }

    /// `check` for a query stored to be run later (a reference's, a property that holds one,
    /// `x-canvas-query`): refused too for a word that reads the editor (`QueryPlan.editorWords`: who
    /// is looking, what is selected), the first named, since a stored query reads only the file.
    /// The one gate every stored query goes through: the translator's `.reference` answers, a
    /// reference's answers, draft and warning, and `canvas draw`'s check of a query it writes.
    public func checkStored(_ text: String) throws(QueryError) -> QueryPlan {
        let plan = try check(text)
        if let word = plan.editorWords.first { throw .readsTheEditor(word) }
        return plan
    }

    /// `check` over the edge types the file has, which the caller took (a batch takes them once).
    private func check(_ text: String, presentEdgeTypes present: Set<EdgeTypeID>) throws(QueryError) -> QueryPlan {
        #if DEBUG
        checks += 1
        #endif
        do throws(QueryError) {
            let list = try SelectorList(parsing: text)
            return try QueryPlan(resolving: list, text: text, vocabulary: vocabulary, presentEdgeTypes: present, kindOf: kind(of:))
        } catch {
            throw vocabulary.settled(error, kindOf: kind(of:), titled: nil, typed: nil)
        }
    }

    /// `check` for a batch, as a result: the edge types the file has are read once, into `present`,
    /// however many texts are checked.
    private func checked(_ text: String, present: inout Set<EdgeTypeID>?) -> Result<QueryPlan, QueryError> {
        do throws(QueryError) {
            guard let editor else { throw .boardClosed }
            guard let topology = editor.topology else { throw .noTopology }
            let types = present ?? topology.snapshot().presentTypes
            present = types
            return .success(try check(text, presentEdgeTypes: types))
        } catch {
            return .failure(error)
        }
    }

    /// The kind of a shape the app has now, by id: nil for none, and for one the query can't see
    /// (kept aside, on a board the app can't show), which is the answer's to refuse.
    private func kind(of id: ShapeID) -> ShapeKind? {
        guard let editor else { return nil }
        return editor.withoutObservingDocument {
            let file = editor.file
            guard let board = file.board(containing: id), editor.canShow(board), let record = file.record(id), !record.isOpaque else { return nil }
            return record.kind
        }
    }

    // MARK: Answering

    /// Answers a query about the whole file as it is when the query takes it up: the shapes that
    /// match, in file order, the first `request.limit` as rows, with its warnings and what it cost.
    /// Refused as `check` refuses it, and for a title or an id no shape it ranges over has
    /// (`unknown_title`, `unknown_id`), a title standing for a container whose shapes hold nothing
    /// (`cannot_contain`), and `cancelled`, `too_slow` and `board_closed`. A refusal's hint that
    /// waits on titles is settled by reading them, as an answer reads them.
    public func run(_ request: QueryRequest) async throws(QueryError) -> QueryResult {
        let start = threadCPU()
        let plan: QueryPlan
        do throws(QueryError) {
            plan = try check(request.text)
        } catch {
            throw await settledByTitles(error)
        }
        let checked = threadCPU() - start
        // The deadline runs from here, so a wait for answers is time the query has spent: the
        // evaluation gets what's left, and a slow one is refused `too_slow` inside `canvas`'s 10 s.
        let clock = try startClock(cappedAt: request.deadline)
        defer { clock.stop() }
        // Before the file is taken up, so a query that waits holds no snapshot.
        let settling = request.settle != nil && plan.readsEdges
        if let settle = request.settle, settling { await waitForSettled(min(settle, clock.allowed)) }
        let limit = max(request.limit, 1)
        let countOnly = request.countOnly, properties = request.properties
        // Rows that list attributes read text through every format; else only those the query tests.
        let lists = !countOnly && properties != .none
        let formats = lists ? Set(vocabulary.textFormats.keys) : plan.uses.textFormats
        var (result, timings, pending) = try await perform(words: plan.uses.pseudoClasses, formats: formats, edges: [request.edges],
                                                           settling: settling, clock: clock) { (evaluation: Evaluation) async throws(QueryError) -> QueryResult in
            try await evaluation.answer(plan, limit: limit, countOnly: countOnly, properties: properties)
        }
        timings.main += .cpu(checked)
        result.timings = timings
        result.warnings += unknownFields(in: plan)
        if let pending { result.warnings.append(.pending(pending)) }
        return result
    }

    /// What the plugins that know an attribute's members say of the paths the plan tests into it: a path
    /// naming one no shape of the file can hold is `unknown_field`, with the member the nearest of those
    /// that could be there when one is near. Asked of the main actor (the plugin reads the file's types) once a
    /// path, and only for a query that has one.
    private func unknownFields(in plan: QueryPlan) -> [QueryWarning] {
        guard let editor, !plan.paths.isEmpty else { return [] }
        let checks = Dictionary(registry.contributions(to: QueryPathChecks.self).map { ($0.value.attribute, $0.value) },
                                uniquingKeysWith: { first, _ in first })
        var warnings: [QueryWarning] = []
        for path in plan.paths {
            guard let unknown = checks[path.attribute]?.check(path.members, editor), path.members.indices.contains(unknown.index) else { continue }
            let before = ([path.attribute] + path.members.prefix(unknown.index)).joined(separator: ".")
            var message = "No type in the file has \(before).\(path.members[unknown.index])."
            if let near = Suggestions.closest(to: path.members[unknown.index], among: unknown.known, limit: 1).first {
                message += " Did you mean \(before).\(near)?"
            }
            warnings.append(QueryWarning(.unknownField, message))
        }
        return warnings
    }

    /// Answers many queries about one file, ids only: what a plugin that keeps answers asks. The
    /// file is taken up once (one main-actor turn, one snapshot of Topology in each view the
    /// requests ask for), and every request is answered over it in one evaluation, which shares what
    /// it reads between them: the names of the shapes, derived ones asked of the main actor in
    /// slices, are read once for the whole batch however many requests name titles. No rows are
    /// built. Each answer is a request's matches, `admitting` asked off the main actor of each
    /// before `limit`, or its refusal (as `check` and `run`'s names refuse it); when the batch itself
    /// fails (`cancelled`, `too_slow`, `board_closed`, `no_topology`), every request that wasn't
    /// refused already fails so. A refusal's hint that waits on titles is left as it is. Each text is
    /// checked once, however many requests carry it (a query asked in two views), over the edge types
    /// the file has, read once for the batch.
    public func matches(_ requests: [QueryMatchRequest]) async -> [Result<QueryMatches, QueryError>] {
        var results = [Result<QueryMatches, QueryError>?](repeating: nil, count: requests.count)
        var asked: [BatchedQuery] = []
        var plans: [String: Result<QueryPlan, QueryError>] = [:]
        var present: Set<EdgeTypeID>?
        for (index, request) in requests.enumerated() {
            let plan: Result<QueryPlan, QueryError>
            if let known = plans[request.text] {
                plan = known
            } else {
                plan = checked(request.text, present: &present)
                plans[request.text] = plan
            }
            switch plan {
            case .success(let plan): asked.append(BatchedQuery(index: index, plan: plan, request: request))
            case .failure(let error): results[index] = .failure(error)
            }
        }
        if !asked.isEmpty {
            var words: Set<String> = [], formats: Set<String> = [], views: [EdgeView] = []
            for query in asked {
                words.formUnion(query.plan.uses.pseudoClasses)
                formats.formUnion(query.plan.uses.textFormats)
                if !views.contains(query.request.edges) { views.append(query.request.edges) }
            }
            let batch = asked
            do throws(QueryError) {
                let performed = try await perform(words: words, formats: formats, edges: views) { (evaluation: Evaluation) async throws(QueryError) -> [Result<QueryMatches, QueryError>] in
                    try await evaluation.admitted(batch)
                }
                for (query, answer) in zip(asked, performed.answer) { results[query.index] = answer }
            } catch {
                for query in asked { results[query.index] = .failure(error) }
            }
        }
        return results.map { $0 ?? .failure(.boardClosed) }
    }

    /// The refusal `run` would make for the titles and ids in a plan that `check` let through
    /// (`unknown_title`, `unknown_id`, `cannot_contain`), and nothing else: nothing is evaluated and
    /// no rows are built. Nil when the names are all right, and for a plan with none (which never
    /// takes up the file); a refusal of the query itself (`cancelled`, `too_slow`, `board_closed`)
    /// is returned as well. What translating English to a query checks, beside `check`.
    public func checkNames(_ plan: QueryPlan) async -> QueryError? {
        guard plan.namesShapes else { return nil }
        do throws(QueryError) {
            _ = try await perform(words: [], formats: [], edges: [.resolved]) { (evaluation: Evaluation) async throws(QueryError) -> Bool in
                try await evaluation.checkNames(of: plan)
                return true
            }
            return nil
        } catch {
            return error
        }
    }

    /// Waits, at most `timeout`, while answers the edges depend on are still arriving
    /// (`TopologyIndex.isSettling`): before the query takes up the file, so it holds no snapshot.
    private func waitForSettled(_ timeout: Duration) async {
        guard let topology = editor?.topology, topology.isSettling else { return }
        _ = await topology.settled(timeout: timeout)
    }

    /// For `--ask`'s titles: named shapes the query would range over, up to `limit`, each name, kind
    /// and place once; first those whose names share a word of 3 letters or more with the question,
    /// then those on the board shown, then the rest, each in file order. Run as a query is.
    public func titles(for question: String, limit: Int) async throws(QueryError) -> [QueryTitle] {
        try await perform(words: [], formats: []) { (evaluation: Evaluation) async throws(QueryError) -> [QueryTitle] in
            try await evaluation.titles(for: question, limit: limit)
        }.answer
    }

    /// For `--ask`'s board: the board shown, the names of the boards on the way to it from the top
    /// (as the path names them), and what's selected (by the plugin that says so,
    /// `registrar.querySelection`), up to `selectedLimit`. Run as a query is.
    public func whereThePersonIs(selectedLimit: Int) async throws(QueryError) -> QueryWhere {
        let word = selectionWord
        return try await perform(words: word.map { [$0] } ?? [], formats: []) { (evaluation: Evaluation) async throws(QueryError) -> QueryWhere in
            try await evaluation.whereThePersonIs(selectionWord: word, limit: selectedLimit)
        }.answer
    }

    /// A refusal whose hints wait on titles (a stray space after one, a word that may be one without
    /// its quotes), settled by the shapes they name, read as a query reads them; as it was when none
    /// waits, or when they can't be read (the file closed, the deadline passed).
    private func settledByTitles(_ error: QueryError) async -> QueryError {
        let titles = vocabulary.titlesAwaited(by: error)
        guard !titles.isEmpty else { return error }
        do throws(QueryError) {
            let (titled, typed) = try await perform(words: vocabulary.typeWord.map { [$0] } ?? [], formats: []) { (evaluation: Evaluation) async throws(QueryError) -> ([String: Set<ShapeKind>], [String: Set<ShapeKind>]) in
                (try await evaluation.kinds(named: titles), try await evaluation.kinds(namedAsTypes: titles))
            }.answer
            return vocabulary.settled(error, kindOf: kind(of:), titled: titled, typed: typed)
        } catch {
            return error
        }
    }

    // MARK: Running one

    /// Starts a query's clock (`QueryRun`): the file's allowance, for its shapes in every board as the
    /// query is run, and `cap`, the most it may take in all, if the caller has someone waiting. Nothing
    /// here holds the editor across a wait: a closed file's editor goes as it closes.
    private func startClock(cappedAt cap: Duration? = nil) throws(QueryError) -> QueryRun {
        guard let editor else { throw .boardClosed }
        guard editor.topology != nil else { throw .noTopology }
        let shapes = editor.withoutObservingDocument { editor.file.shapeCount }
        return QueryRun(scheduler: editor.scheduler, allowed: QueryBudget.deadline(forShapes: shapes), cap: cap)
    }

    /// Takes up the file as soon as it's asked, and runs `work` over it off the main actor, bounded by
    /// the deadline and the caller's cancellation, whatever other queries are running; returns what
    /// it answered, and what it cost. The deadline runs from `clock`, started by a caller that spent
    /// time before this (a wait for answers), else from here. `edges` are the views of Topology the
    /// evaluation reads, the first for what the words prepare; `settling` asks, as the file is taken
    /// up, whether answers are still arriving (`pending`: how many stand-ins are asked and
    /// unanswered, nil if none are).
    private func perform<Answer: Sendable>(words: Set<String>, formats: Set<String>, edges: [EdgeView] = [.resolved], settling: Bool = false,
                                           clock started: QueryRun? = nil,
                                           _ work: @escaping @Sendable (Evaluation) async throws(QueryError) -> Answer)
        async throws(QueryError) -> (answer: Answer, timings: QueryTimings, pending: Int?) {
        let run: QueryRun
        if let started { run = started } else { run = try startClock() }
        defer { run.stop() }
        guard !run.timedOut else { throw .tooSlow(after: run.expired) }
        guard !Task.isCancelled else { throw .cancelledQuery }
        let (handover, facts, captured, pending) = try takeUp(words: words, formats: formats, edges: edges, settling: settling)
        // A slice the main actor answers is a sign the query is alive: its time to the deadline starts over.
        facts.onSlice = { [run] in run.answered() }
        let vocabulary = vocabulary
        let task = Task.detached(priority: Task.currentPriority) {
            await Evaluation.perform(handover, vocabulary: vocabulary, facts: facts, work)
        }
        run.cancel = { task.cancel() }
        let performed = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        run.cancel = nil

        #if DEBUG
        mainSlices += facts.slices
        recordsEncoded += performed.stats.recordsEncoded
        derivedTitlesAsked += facts.titlesAsked
        verdictsAsked += facts.verdictsAsked
        problemsAsked += facts.problemsAsked
        universeWalks += performed.stats.universeWalks
        seededFromAnchors += performed.stats.seeded
        #endif
        let timings = QueryTimings(main: .cpu(captured + facts.total), offMain: .cpu(performed.stats.offMain), slices: facts.slices,
                                   longestSlice: .cpu(facts.longest), costliestRecord: .cpu(facts.costliest))
        switch performed.outcome {
        case .success(let answer): return (answer, timings, pending)
        case .failure(let error): throw error.reason == .cancelled && run.timedOut ? .tooSlow(after: run.expired) : error
        }
    }

    /// Takes up the file (`capture`), and what that cost the main actor.
    private func takeUp(words: Set<String>, formats: Set<String>, edges: [EdgeView],
                        settling: Bool) throws(QueryError) -> (Handover<QuerySnapshot>, MainFacts, UInt64, Int?) {
        guard let editor, let topology = editor.topology else { throw .boardClosed }
        let start = threadCPU()
        let pending = settling && topology.isSettling ? topology.pendingStandIns.count : nil
        let (handover, facts) = capture(editor, topology: topology, words: words, formats: formats, edges: edges)
        return (handover, facts, threadCPU() - start, pending)
    }

    /// The file as the query takes it up, in this one turn: the file and Topology's snapshot, read
    /// without observing them, the board shown and the path to it, the revision, the shape being
    /// typed into, and then what each word and text format the query uses takes (`prepare`, in
    /// word order); and what asks the main actor, holding the editor weakly.
    private func capture(_ editor: CanvasEditor, topology: TopologyIndex, words: Set<String>, formats: Set<String>,
                         edges: [EdgeView]) -> (Handover<QuerySnapshot>, MainFacts) {
        let file = editor.withoutObservingDocument { editor.file }
        // One snapshot in each view asked for (each O(1), sharing the tables); the first is what the words prepare over.
        var views: [EdgeView: TopologySnapshot] = [:]
        for view in edges where views[view] == nil { views[view] = topology.snapshot(view) }
        let graph = views[edges.first ?? .resolved] ?? topology.snapshot()
        let shown = editor.board, path = editor.boardPath, revision = editor.revision, editing = editor.editingShapeID
        let preparation = QueryPreparation(editor: editor, file: QueryFilePreparation(snapshot: graph, registry: registry, editor: editor))
        var prepared: [String: any Sendable] = [:], verdicts: [String: MainFacts.Verdict] = [:], problemers: [String: MainFacts.Problemer] = [:]
        for word in words.sorted() {
            switch vocabulary.contributedWords[word]?.meaning {
            case .pseudoClass(let behavior)?:
                let value = behavior.prepare(preparation)
                prepared[word] = value
                if let onMain = behavior.onMain { verdicts[word] = MainFacts.Verdict(ask: onMain, prepared: value) }
                if let problems = behavior.problems { problemers[word] = MainFacts.Problemer(ask: problems, prepared: value) }
            case .fileRelation(let relation)?:
                prepared[word] = relation.prepare(preparation.file)
            case .relation?, nil:
                continue
            }
        }
        var read: [String: any Sendable] = [:]
        for mediaType in formats.sorted() {
            if let format = vocabulary.textFormats[mediaType] { read[mediaType] = format.prepare(preparation) }
        }
        #if DEBUG
        captures += 1
        #endif
        let snapshot = QuerySnapshot(file: file, topology: graph, topologies: views, shown: shown, shownPath: path, revision: revision, editing: editing,
                                     words: prepared, formats: read, token: live.token())
        let facts = MainFacts(editor: editor, revision: revision, derived: vocabulary.naming?.derived, verdicts: verdicts, problemers: problemers)
        return (Handover(snapshot), facts)
    }
}

/// A query of a batch, checked: its place in the batch, its plan and its request.
struct BatchedQuery: Sendable {
    let index: Int
    let plan: QueryPlan
    let request: QueryMatchRequest
}

/// One query in flight, and its clock. A query is refused `too_slow` (its evaluation cancelled) when
/// `allowed` passes with nothing to show for it: it neither finished nor had the main actor answer a
/// slice it asked for (`answered()`, which starts that time again), or, if the caller has someone
/// waiting, when `cap` has passed in all. So a query that is only slow because the main actor is
/// busy, between the frames of a drag, is not refused while the main actor serves it; one that runs
/// on without a sign of life, or whose main actor is gone, is. Both are actions scheduled on the
/// editor's scheduler (tests advance a `ManualScheduler`).
@MainActor
private final class QueryRun {
    /// How long it may go without a slice answered (`QueryBudget.deadline(forShapes:)`).
    let allowed: Duration
    /// The most it may take in all, if the caller has someone waiting (`QueryRequest.deadline`).
    private let cap: Duration?
    /// The time that ran out, once one has: what the refusal says.
    private(set) var expired: Duration
    private(set) var timedOut = false
    var cancel: (@Sendable () -> Void)?
    private let scheduler: any Scheduler
    private var stall: ScheduledTask?
    private var total: ScheduledTask?

    init(scheduler: any Scheduler, allowed: Duration, cap: Duration?) {
        self.scheduler = scheduler
        self.allowed = allowed
        self.cap = cap
        expired = allowed
        arm()
        if let cap = self.cap { total = scheduler.schedule(after: cap) { [weak self] in self?.expire(after: cap) } }
    }

    /// The main actor answered a slice: the time to the deadline starts over.
    func answered() {
        guard !timedOut else { return }
        arm()
    }

    private func arm() {
        stall?.cancel()
        let allowed = allowed
        stall = scheduler.schedule(after: allowed) { [weak self] in self?.expire(after: allowed) }
    }

    private func expire(after time: Duration) {
        guard !timedOut else { return }
        timedOut = true
        expired = time
        cancel?()
    }

    /// The query is over: nothing is left armed.
    func stop() {
        stall?.cancel()
        total?.cancel()
        stall = nil
        total = nil
    }
}

extension QueryState: EditorService {}

extension CanvasEditor {
    /// The editor's queries; nil without `QueriesPlugin`.
    public var queries: QueryState? { service(QueryState.self) }
}

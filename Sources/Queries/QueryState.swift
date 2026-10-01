import Canvas
import QueryLanguage
import Topology

/// An editor's queries (`editor.queries`): the vocabulary, made on first use and kept (the registry
/// never changes); checking a query against it; and answering one about the whole file.
///
/// A query costs the main actor its reading and resolving and one turn that takes up the file, O(1)
/// (`QuerySnapshot`: the file, Topology's snapshot, the board shown, what the words it uses take);
/// everything else runs off the main actor over that snapshot (`Evaluation`), but for what only the
/// main actor can say (derived names, some words' verdicts), asked in slices of 2 ms each, one at a
/// time (`MainFacts`). Queries on one editor run one at a time, each taking up the file once the
/// one before it is done. A query stops when its caller's task is cancelled (`cancelled`), when
/// `QueryBudget.deadline` has passed since it was asked (a scheduled action on `editor.scheduler`
/// cancels it: `too_slow`), and when its editor goes (`board_closed`).
///
/// It keeps nothing per shape or per board, and hears no commit: a commit costs it nothing, ever,
/// and no snapshot outlives its query.
@MainActor
public final class QueryState {
    /// Weak: a query in flight never keeps a closed file's editor alive.
    private weak var editor: CanvasEditor?
    private let registry: Registry
    /// Whether a query holds the turn, and those waiting for it, in the order they came.
    private var busy = false
    private var line: [(place: Int, resume: CheckedContinuation<Bool, Never>)] = []
    private var places = 0
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
    /// How many main slices queries have run.
    public private(set) var mainSlices = 0
    /// How many records' properties queries have written as JSON.
    public private(set) var recordsEncoded = 0
    /// How many derived names, and words' verdicts, queries have asked the main actor.
    public private(set) var derivedTitlesAsked = 0
    public private(set) var verdictsAsked = 0
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
        do throws(QueryError) {
            let list = try SelectorList(parsing: text)
            let present = topology.snapshot().presentTypes
            return try QueryPlan(resolving: list, text: text, vocabulary: vocabulary, presentEdgeTypes: present, kindOf: kind(of:))
        } catch {
            throw vocabulary.settled(error, kindOf: kind(of:), titled: nil)
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
        let limit = min(max(request.limit, 1), QueryBudget.maxRows)
        let countOnly = request.countOnly, properties = request.properties
        // Rows that list attributes read text through every format; else only those the query tests.
        let lists = !countOnly && properties != .none
        let formats = lists ? Set(vocabulary.textFormats.keys) : plan.uses.textFormats
        var (result, timings) = try await perform(words: plan.uses.pseudoClasses, formats: formats) { (evaluation: Evaluation) async throws(QueryError) -> QueryResult in
            try await evaluation.answer(plan, limit: limit, countOnly: countOnly, properties: properties)
        }
        timings.main += .cpu(checked)
        result.timings = timings
        return result
    }

    /// For `--ask`'s titles: named shapes the query would range over, up to `limit`, each name, kind
    /// and place once; first those whose names share a word of 3 letters or more with the question,
    /// then those on the board shown, then the rest, each in file order. Run as a query is, after
    /// any before it.
    public func titles(for question: String, limit: Int) async throws(QueryError) -> [QueryTitle] {
        try await perform(words: [], formats: []) { (evaluation: Evaluation) async throws(QueryError) -> [QueryTitle] in
            try await evaluation.titles(for: question, limit: limit)
        }.answer
    }

    /// For `--ask`'s board: the board shown, the names of the boards on the way to it from the top
    /// (as the path names them), and what's selected (by the plugin that says so,
    /// `registrar.querySelection`), up to `selectedLimit`. Run as a query is, after any before it.
    public func whereThePersonIs(selectedLimit: Int) async throws(QueryError) -> QueryWhere {
        let word = selectionWord
        return try await perform(words: word.map { [$0] } ?? [], formats: []) { (evaluation: Evaluation) async throws(QueryError) -> QueryWhere in
            try await evaluation.whereThePersonIs(selectionWord: word, limit: selectedLimit)
        }.answer
    }

    /// A refusal whose hints wait on titles (a stray space after one, a word that may be one without
    /// its quotes), settled by the shapes they name, read as a query reads them, after any query
    /// before it; as it was when none waits, or when they can't be read (the file closed, the
    /// deadline passed).
    private func settledByTitles(_ error: QueryError) async -> QueryError {
        let titles = vocabulary.titlesAwaited(by: error)
        guard !titles.isEmpty else { return error }
        do throws(QueryError) {
            let titled = try await perform(words: [], formats: []) { (evaluation: Evaluation) async throws(QueryError) -> [String: Set<ShapeKind>] in
                try await evaluation.kinds(named: titles)
            }.answer
            return vocabulary.settled(error, kindOf: kind(of:), titled: titled)
        } catch {
            return error
        }
    }

    // MARK: Running one

    /// Waits for the turn, takes up the file, and runs `work` over it off the main actor, bounded by
    /// the deadline and the caller's cancellation; returns what it answered, and what it cost.
    private func perform<Answer: Sendable>(words: Set<String>, formats: Set<String>,
                                           _ work: @escaping @Sendable (Evaluation) async throws(QueryError) -> Answer)
        async throws(QueryError) -> (answer: Answer, timings: QueryTimings) {
        // Nothing here holds the editor across a wait: a closed file's editor goes as it closes.
        guard let scheduler = editor?.scheduler else { throw .boardClosed }
        guard editor?.topology != nil else { throw .noTopology }
        let run = QueryRun()
        let deadline = scheduler.schedule(after: QueryBudget.deadline) { [weak self] in
            run.timedOut = true
            run.cancel?()
            if let place = run.place { self?.leaveLine(place) }
        }
        defer { deadline.cancel() }
        do throws(QueryError) {
            try await takeTurn(run)
        } catch {
            throw run.timedOut ? .tooSlow : error
        }
        defer { endTurn() }
        guard !run.timedOut else { throw .tooSlow }
        guard !Task.isCancelled else { throw .cancelledQuery }
        let (handover, facts, captured) = try takeUp(words: words, formats: formats)
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
        universeWalks += performed.stats.universeWalks
        seededFromAnchors += performed.stats.seeded
        #endif
        let timings = QueryTimings(main: .cpu(captured + facts.total), offMain: .cpu(performed.stats.offMain), slices: facts.slices,
                                   longestSlice: .cpu(facts.longest), costliestRecord: .cpu(facts.costliest))
        switch performed.outcome {
        case .success(let answer): return (answer, timings)
        case .failure(let error): throw error.reason == .cancelled && run.timedOut ? .tooSlow : error
        }
    }

    /// Takes up the file (`capture`), and what that cost the main actor.
    private func takeUp(words: Set<String>, formats: Set<String>) throws(QueryError) -> (Handover<QuerySnapshot>, MainFacts, UInt64) {
        guard let editor, let topology = editor.topology else { throw .boardClosed }
        let start = threadCPU()
        let (handover, facts) = capture(editor, topology: topology, words: words, formats: formats)
        return (handover, facts, threadCPU() - start)
    }

    /// The file as the query takes it up, in this one turn: the file and Topology's snapshot, read
    /// without observing them, the board shown and the path to it, the revision, the shape being
    /// typed into, and then what each word and text format the query uses takes (`prepare`, in
    /// word order); and what asks the main actor, holding the editor weakly.
    private func capture(_ editor: CanvasEditor, topology: TopologyIndex, words: Set<String>,
                         formats: Set<String>) -> (Handover<QuerySnapshot>, MainFacts) {
        let file = editor.withoutObservingDocument { editor.file }
        let graph = topology.snapshot()
        let shown = editor.board, path = editor.boardPath, revision = editor.revision, editing = editor.editingShapeID
        let preparation = QueryPreparation(editor: editor)
        var prepared: [String: any Sendable] = [:], verdicts: [String: MainFacts.Verdict] = [:]
        for word in words.sorted() {
            guard case .pseudoClass(let behavior)? = vocabulary.contributedWords[word]?.meaning else { continue }
            let value = behavior.prepare(preparation)
            prepared[word] = value
            if let onMain = behavior.onMain { verdicts[word] = MainFacts.Verdict(ask: onMain, prepared: value) }
        }
        var read: [String: any Sendable] = [:]
        for mediaType in formats.sorted() {
            if let format = vocabulary.textFormats[mediaType] { read[mediaType] = format.prepare(preparation) }
        }
        #if DEBUG
        captures += 1
        #endif
        let snapshot = QuerySnapshot(file: file, topology: graph, shown: shown, shownPath: path, revision: revision, editing: editing,
                                     words: prepared, formats: read, token: live.token())
        let facts = MainFacts(editor: editor, revision: revision, derived: vocabulary.naming?.derived, verdicts: verdicts)
        return (Handover(snapshot), facts)
    }

    // MARK: One at a time

    /// Waits until no other query holds the turn, then holds it; refused `cancelled` if its task is
    /// cancelled, or its deadline passes, while it waits.
    private func takeTurn(_ run: QueryRun) async throws(QueryError) {
        guard busy else {
            busy = true
            return
        }
        let place = places
        places += 1
        run.place = place
        let admitted = await withTaskCancellationHandler {
            await withCheckedContinuation { line.append((place, $0)) }
        } onCancel: {
            Task { @MainActor [weak self] in self?.leaveLine(place) }
        }
        run.place = nil
        guard admitted else { throw .cancelledQuery }
    }

    /// A query stops waiting for its turn.
    private func leaveLine(_ place: Int) {
        guard let index = line.firstIndex(where: { $0.place == place }) else { return }
        line.remove(at: index).resume.resume(returning: false)
    }

    /// A query is done with the turn: the next waiting takes it.
    private func endTurn() {
        if line.isEmpty {
            busy = false
        } else {
            line.removeFirst().resume.resume(returning: true)
        }
    }
}

/// One query in flight: whether its deadline has passed, where it waits in line, and how to cancel
/// its evaluation.
@MainActor
private final class QueryRun {
    var timedOut = false
    var place: Int?
    var cancel: (@Sendable () -> Void)?
}

extension QueryState: EditorService {
    /// Nothing: it keeps nothing per board (the default would work out the switch's change set).
    public func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {}
}

extension CanvasEditor {
    /// The editor's queries; nil without `QueriesPlugin`.
    public var queries: QueryState? { service(QueryState.self) }
}

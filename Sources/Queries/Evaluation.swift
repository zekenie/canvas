import Canvas
import DrawScript
import Foundation
import QueryLanguage
import Topology

// Evaluation: a plan answered over a snapshot, off the main actor, a set at a time. Each node is
// worked out once into the set of shapes it matches among the candidates its compound has narrowed
// to so far (what it matches among every shape is kept, by node, for the query); nothing recurses
// per candidate. A compound's nodes run in the plan's order, cheapest first, and one that starts
// from nothing of its own but has a one-step edge word with few anchors starts from their edges.
// Every construct costs what it touches: the shapes it tests, an anchor's degree, a traversal's
// reach. What only the main actor can say (a derived name, a word's `onMain`) is asked in slices
// (`MainFacts`), one at a time; everything else, the rows and their order too, is worked out here,
// and freed here.

/// One query's answer, worked out off the main actor over a snapshot handed to it whole: made, run
/// and let go of in the evaluation's task, so the snapshot, and everything read from it, is freed
/// there. Not `Sendable`: it lives in that one task.
final class Evaluation {
    /// A shape the query ranges over, the board it's on, and what queries know of its kind.
    struct Entry {
        let record: AnyShapeRecord
        let board: BoardID
        let kind: KindFacts
    }

    /// The shapes a node is tested on: every shape the query ranges over, or some of them.
    enum Candidates {
        case all
        case only(Set<ShapeID>)
    }

    /// What an evaluation cost and did, for `QueryState`'s timings and debug counters.
    struct Stats: Sendable {
        /// Thread CPU off the main actor, in nanoseconds: every stretch between slices.
        var offMain: UInt64 = 0
        /// Records whose properties were written as JSON (`propertiesJSON`), once each per query.
        var recordsEncoded = 0
        /// Walks of every shape the query ranges over (at most one per query).
        var universeWalks = 0
        /// Compounds that started from their anchors' edges.
        var seeded = 0
    }

    /// What queries know of a kind, looked up once per kind.
    final class KindFacts {
        let names: QueryNameSource
        let label: String
        /// What an untitled one's board is called; nil for a kind that holds none (an untitled
        /// container is called by its label).
        let boardName: String?
        /// Its attributes but its name: what a row lists and `:contains` reads.
        let readable: [QueryVocabulary.AttributeEntry]

        init(_ entry: QueryVocabulary.KindEntry) {
            names = entry.names
            label = entry.label
            boardName = entry.boardName
            readable = entry.attributes.filter { !$0.isName }
        }
    }

    /// Every shape the query ranges over, in file order: its id and its entry by place in that
    /// order, and each id's place.
    private struct Universe {
        var order: [ShapeID] = []
        var entries: [Entry] = []
        var position: [ShapeID: Int] = [:]

        func entry(_ id: ShapeID) -> Entry? { position[id].map { entries[$0] } }
    }

    /// Every name in the query's range: each name's shapes in file order, and each name once, in
    /// file order (for "did you mean").
    private struct TitleIndex {
        /// A name's shapes: most names are one shape's, which is kept without a list.
        enum Shapes {
            case none
            case one(ShapeID)
            case many([ShapeID])

            mutating func add(_ id: ShapeID) {
                switch self {
                case .none: self = .one(id)
                case .one(let first): self = .many([first, id])
                case .many(var ids):
                    self = .none
                    ids.append(id)
                    self = .many(ids)
                }
            }

            var ids: [ShapeID] {
                switch self {
                case .none: []
                case .one(let id): [id]
                case .many(let ids): ids
                }
            }
        }

        private(set) var byName: [String: Shapes] = [:]
        private(set) var names: [String] = []

        /// The shapes named `name`, in file order; nil for a name no shape has.
        func shapes(named name: String) -> [ShapeID]? { byName[name]?.ids }

        /// Whether more than one shape has the name.
        func isShared(_ name: String) -> Bool {
            if case .many? = byName[name] { true } else { false }
        }

        mutating func add(_ name: String, _ id: ShapeID) {
            let known = byName.count
            byName[name, default: .none].add(id)
            if byName.count > known { names.append(name) }
        }
    }

    /// A name tested for with `=` that matched nothing: warned about if it's no shape's.
    private struct EmptyNameTest: Hashable {
        let name: String
        let ignoringCase: Bool
    }

    private(set) var snapshot: QuerySnapshot
    let vocabulary: QueryVocabulary
    let facts: MainFacts
    private(set) var stats = Stats()

    private let kinds: [ShapeKind: KindFacts]
    /// Every shape the query ranges over, once walked.
    private var walked: Universe?
    private var everyShape: Set<ShapeID>?
    /// Shapes looked up without the universe: nil for one outside it.
    private var looked: [ShapeID: Entry?] = [:]
    /// What each node and list matched among every shape.
    private var sets: [PlanNodeID: Set<ShapeID>] = [:]
    /// Each file relation's shapes by those they're related to (`reversed`), by word.
    private var reversedRelations: [String: [ShapeID: [ShapeID]]] = [:]
    /// Names read, named or derived: nil for none.
    private var names: [ShapeID: String?] = [:]
    /// Every name in the query's range, once read all at once, by place in file order.
    private var everyName: [String?]?
    private var named: TitleIndex?
    /// Each shape's properties as JSON, once.
    private var encoded: [ShapeID: JSONObject] = [:]
    /// The shapes whose attributes or text the query read.
    private var read: Set<ShapeID> = []
    /// The shapes each board is inside (its owner, the containers that one is in, and so on up), the
    /// nearest first.
    private var ancestry: [BoardID: [ShapeID]] = [:]
    /// The shapes a shape each container holds is inside, the nearest first: the container, the
    /// containers it's in, its board's owner, and so on up.
    private var holding: [ShapeID: [ShapeID]] = [:]
    private var emptyNameTests: [EmptyNameTest] = []
    private var ticks = 0
    private var stretchStart: UInt64

    init(snapshot: QuerySnapshot, vocabulary: QueryVocabulary, facts: MainFacts) {
        self.snapshot = snapshot
        self.vocabulary = vocabulary
        self.facts = facts
        kinds = Dictionary(vocabulary.kinds.map { ($0.kind, KindFacts($0)) }, uniquingKeysWith: { first, _ in first })
        stretchStart = threadCPU()
    }

    /// Runs `work` over a snapshot handed over whole, off the main actor: the snapshot is taken out
    /// of `handover`, so the evaluation is its last holder, and it's freed, with all the evaluation
    /// read, before this returns.
    @concurrent
    nonisolated static func perform<Answer: Sendable>(_ handover: Handover<QuerySnapshot>, vocabulary: QueryVocabulary, facts: MainFacts,
                                                      _ work: @Sendable (Evaluation) async throws(QueryError) -> Answer) async -> Performed<Answer> {
        guard let snapshot = handover.take() else { return Performed(outcome: .failure(.cancelledQuery), stats: Stats()) }
        let evaluation = Evaluation(snapshot: snapshot, vocabulary: vocabulary, facts: facts)
        let outcome: Result<Answer, QueryError>
        do throws(QueryError) {
            outcome = .success(try await work(evaluation))
        } catch {
            outcome = .failure(error)
        }
        return Performed(outcome: outcome, stats: evaluation.finish())
    }

    /// What it cost, its last stretch counted.
    private func finish() -> Stats {
        pause()
        return stats
    }

    // MARK: Time and cancellation

    /// Every so many shapes, whether the query's been cancelled.
    private func tick() throws(QueryError) {
        ticks &+= 1
        if ticks % QueryBudget.cancellationStride == 0 { try checkCancelled() }
    }

    private func checkCancelled() throws(QueryError) {
        if Task.isCancelled { throw .cancelledQuery }
    }

    /// Ends a stretch off the main actor, before a slice.
    private func pause() {
        stats.offMain += threadCPU() - stretchStart
    }

    /// Starts one, after a slice (on whatever thread the evaluation goes on on).
    private func resume() {
        stretchStart = threadCPU()
    }

    // MARK: Answers

    /// The plan's answer: its titles and ids checked, what it matches in file order, the first
    /// `limit` as rows (none when only counting), and the warnings.
    func answer(_ plan: QueryPlan, limit: Int, countOnly: Bool, properties: QueryRequest.Properties) async throws(QueryError) -> QueryResult {
        try await checkNames(in: plan)
        let found = try await matches(plan.root, among: .all)
        // Only rows need the file's order: a count is the set's.
        let matched = countOnly ? [] : try inFileOrder(found)
        let rows = countOnly ? [] : try await self.rows(matched.prefix(limit), properties: properties)
        var warnings: [QueryWarning] = []
        if !countOnly, found.count > rows.count {
            let more = min(QueryBudget.maxRows, limit * 10)
            warnings.append(QueryWarning(.limited, rows.count < more
                ? "\(rows.count) of \(found.count) listed. --limit \(more) lists more; --count only counts."
                : "\(rows.count) of \(found.count) listed; --count only counts."))
        }
        if let editing = snapshot.editing, read.contains(editing) || rows.contains(where: { $0.id == editing }) {
            try await readNames([editing])
            let who = name(editing).map { "“\($0)”" } ?? entry(editing).map { indefinite($0.kind.label).capitalizedFirst } ?? "A shape"
            warnings.append(QueryWarning(.editing, "\(who) is being typed into; its text may still change."))
        }
        warnings += try await titleWarnings()
        return QueryResult(query: plan.canonical, count: found.count, rows: rows, warnings: warnings, shown: snapshot.shown,
                           shownPath: snapshot.shownPath)
    }

    /// What each request of a batch matches (`QueryState.matches(_:)`), in order, all over this one
    /// snapshot: its names checked, what it matches among every shape, those `admitting` takes (asked
    /// here, off the main actor, of each, before `limit`), the first `limit` in file order and how
    /// many in all. What the requests read is shared: the shapes walked, the names read (named and
    /// derived, once for all) and the title index; what each node matched is not, as a plan's nodes
    /// are its own. A request refused (`unknown_title`) is one answer, not the batch's; a cancellation
    /// is the batch's.
    func admitted(_ batch: [BatchedQuery]) async throws(QueryError) -> [Result<QueryMatches, QueryError>] {
        var answers: [Result<QueryMatches, QueryError>] = []
        answers.reserveCapacity(batch.count)
        for query in batch {
            try checkCancelled()
            snapshot = snapshot.reading(query.request.edges)
            sets.removeAll(keepingCapacity: true)
            emptyNameTests.removeAll()
            read.removeAll()
            do throws(QueryError) {
                try await checkNames(in: query.plan)
                let found = try await matches(query.plan.root, among: .all)
                var kept: Set<ShapeID> = []
                kept.reserveCapacity(found.count)
                for id in found {
                    try tick()
                    if let entry = entry(id), query.request.admitting(entry.record) { kept.insert(id) }
                }
                let ids = Array(try inFileOrder(kept).prefix(min(max(query.request.limit, 1), QueryBudget.maxRows)))
                answers.append(.success(QueryMatches(canonical: query.plan.canonical, ids: ids, count: kept.count, revision: snapshot.revision)))
            } catch {
                switch error.reason {
                case .cancelled, .tooSlow, .boardClosed: throw error
                default: answers.append(.failure(error))
                }
            }
        }
        return answers
    }

    /// Refuses the titles and ids in the plan as `answer` does, and answers nothing else.
    func checkNames(of plan: QueryPlan) async throws(QueryError) {
        try await checkNames(in: plan)
    }

    /// Named shapes for `--ask`'s titles, up to `limit`, each name, kind and place once: first those
    /// whose names share a word of 3 letters or more with the question (any case), then those on the
    /// board shown, then the rest, each in file order.
    func titles(for question: String, limit: Int) async throws(QueryError) -> [QueryTitle] {
        let limit = max(limit, 0)
        let index = try await titleIndex()
        let universe = try universe()
        guard limit > 0, let every = everyName else { return [] }
        let asked = Self.words(question)
        var tiers: [[QueryTitle]] = [[], [], []]
        var seen: Set<TitlePlace> = []
        for (place, title) in every.enumerated() {
            guard let title else { continue }
            try tick()
            let id = universe.order[place], entry = universe.entries[place]
            // Only a name some other shape has too can be listed twice.
            var inside: [String]?
            if index.isShared(title) {
                let names = ancestors(id).reversed().map(containerName)
                guard seen.insert(TitlePlace(title: title, kind: entry.record.kind, inside: names)).inserted else { continue }
                inside = names
            }
            let tier = Self.sharesWord(title, with: asked) ? 0 : entry.board == snapshot.shown ? 1 : 2
            // No more of a tier than are listed; and once the first has as many, nothing after it is.
            guard tiers[tier].count < limit else { continue }
            tiers[tier].append(QueryTitle(title: title, id: id, kind: entry.record.kind, board: entry.board,
                                          inside: inside ?? ancestors(id).reversed().map(containerName)))
            if tiers[0].count == limit { break }
        }
        return Array(tiers.joined().prefix(limit))
    }

    /// A name, its kind and the names of the boards it's inside: what `--ask`'s titles list once.
    private struct TitlePlace: Hashable {
        let title: String
        let kind: ShapeKind
        let inside: [String]
    }

    /// Words of 3 letters or more, lowercased.
    private static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.filter { $0.count >= 3 }.map(String.init))
    }

    /// Whether `text` has one of `words` (`words(_:)`'s) among its own, without collecting them: an
    /// ASCII text a byte at a time (its letters and digits are the words' characters), any other as
    /// `words(_:)` reads it.
    private static func sharesWord(_ text: String, with words: Set<String>) -> Bool {
        guard !words.isEmpty else { return false }
        var ascii = true
        let found = text.utf8.withContiguousStorageIfAvailable { bytes -> Bool in
            var start = 0
            for end in 0...bytes.count {
                let byte = end < bytes.count ? bytes[end] : 0x20
                if byte >= 0x80 {
                    ascii = false
                    return false
                }
                let isWordByte = (byte >= 0x30 && byte <= 0x39) || ((byte | 0x20) >= 0x61 && (byte | 0x20) <= 0x7A)
                if isWordByte { continue }
                if end - start >= 3,
                   words.contains(String(decoding: bytes[start..<end].lazy.map { $0 >= 0x41 && $0 <= 0x5A ? $0 | 0x20 : $0 }, as: UTF8.self)) {
                    return true
                }
                start = end + 1
            }
            return false
        }
        guard let found, ascii else { return !words.isDisjoint(with: Self.words(text)) }
        return found
    }

    /// The board shown and the names of the boards on the way to it, and the shapes the selection
    /// word (`querySelection`) took, up to `limit`, with how many it took in all.
    func whereThePersonIs(selectionWord: String?, limit: Int) async throws(QueryError) -> QueryWhere {
        let owners = snapshot.shownPath.compactMap(\.owner)
        var selected: [ShapeID] = []
        if let selectionWord, let taken = snapshot.words[selectionWord] as? SelectedShapes {
            for id in taken.ids where entry(id) != nil { selected.append(id) }
        }
        let listed = Array(selected.prefix(max(limit, 0)))
        try await readNames(owners + listed)
        let shapes = listed.compactMap { id in entry(id).map { QuerySelected(id: id, kind: $0.record.kind, title: name(id)) } }
        return QueryWhere(board: snapshot.shown, path: owners.map(containerName), selected: shapes, selectedCount: selected.count)
    }

    // MARK: Names and ids

    /// Refuses, before anything is answered, every id no shape the query ranges over has, every name
    /// none has, and every name standing where a container goes whose shapes are all of kinds that
    /// hold no shapes: the problems in the order they're in the query. A name no shape has that
    /// stands for an edge word's or a relation's anchor may be one a shape that's gone had: when an
    /// edge it follows points at a shape that isn't there, the hint says how to find what carries it.
    private func checkNames(in plan: QueryPlan) async throws(QueryError) {
        var titles: [PlanNode] = [], ids: [PlanNode] = []
        var anchoring: [PlanNodeID: [(types: PlanEdgeTypes, end: AnchorEnd)]] = [:]
        plan.root.forEachNode { node in
            switch node.op {
            case .title: titles.append(node)
            case .id: ids.append(node)
            case .edges(let word, let anchor, let second, let types):
                if let end = AnchorEnd(word) {
                    for title in anchor.subjectTitles { anchoring[title, default: []].append((types, end)) }
                }
                for title in second?.subjectTitles ?? [] { anchoring[title, default: []].append((types, .either)) }
            case .relation(_, let anchor, let types, let direction):
                for title in anchor.subjectTitles { anchoring[title, default: []].append((types, AnchorEnd(direction))) }
            default: break
            }
        }
        var problems: [QueryError] = []
        for node in ids {
            guard case .id(let id) = node.op, entry(id) == nil else { continue }
            problems.append(unknownID(id, span: node.span))
        }
        if !titles.isEmpty {
            let index = try await titleIndex()
            for node in titles {
                guard case .title(let folded, let written) = node.op else { continue }
                guard let named = index.shapes(named: folded) else {
                    let guesses = Suggestions.closest(to: written, among: index.names, limit: 3).map(quoted)
                    let gone = try anchoring[node.id].flatMap(danglingHint)
                    problems.append(QueryError(.unknownTitle, "No shape is titled \(written).", hint: sentences(didYouMean(guesses), gone),
                                               span: node.span))
                    continue
                }
                if plan.containerTitles.contains(node.id), let refusal = holdsNothing(written, named, span: node.span) { problems.append(refusal) }
            }
        }
        guard !problems.isEmpty else { return }
        var unique: [QueryError] = []
        for problem in problems where !unique.contains(problem) { unique.append(problem) }
        let ordered = unique.enumerated().sorted { a, b in
            (a.element.span?.offset ?? Int.max, a.offset) < (b.element.span?.offset ?? Int.max, b.offset)
        }.map(\.element)
        throw QueryError(collecting: ordered)
    }

    /// Why an id names no shape the query ranges over: gone from the file, on a board the app can't
    /// show, or kept aside.
    private func unknownID(_ id: ShapeID, span: QuerySpan?) -> QueryError {
        switch snapshot.topology.end(id) {
        case .missing:
            QueryError(.unknownID, "No shape the app can show has that id: it may have been deleted.",
                       hint: "Run the query that gave it again.", span: span)
        case .unavailable:
            QueryError(.unknownID, "That shape is on a board the app can't show.", span: span)
        case .live:
            QueryError(.unknownID, "That shape is kept aside: the app can't read it.", span: span)
        }
    }

    /// Which end of an edge an anchor is, as the word that has it reads edges: the target of
    /// `:edge-to`'s, the source of `:edge-from`'s, either of `:connected-to`'s; none, for the
    /// anchor of `:start-of` and `:end-of`, which is the connection that carries the edge.
    enum AnchorEnd {
        case source, target, either

        init?(_ word: Word) {
            switch word {
            case .edgeTo, .upstreamOf, .endsAt: self = .target
            case .edgeFrom, .downstreamOf, .startsAt: self = .source
            case .startOf, .endOf: return nil
            default: self = .either
            }
        }

        init(_ direction: EdgeDirection) {
            switch direction {
            case .outgoing: self = .target
            case .incoming: self = .source
            case .either: self = .either
            }
        }
    }

    /// For a name no shape has, standing for anchors: when an edge of the types one follows has, at
    /// the anchor's end, a shape the query can't see (gone, kept aside, or on a board the app can't
    /// show) and a carrier it can, the words that find such carriers (`:dangling`), the first such
    /// anchor's; nil for none.
    private func danglingHint(_ anchors: [(types: PlanEdgeTypes, end: AnchorEnd)]) throws(QueryError) -> String? {
        for (types, end) in anchors {
            for edge in snapshot.topology.edges(ofType: types.filter) {
                try tick()
                let source = edge.source != edge.carrier && entry(edge.source) == nil
                let target = edge.target != edge.carrier && entry(edge.target) == nil
                let dangles = switch end {
                case .source: source
                case .target: target
                case .either: source || target
                }
                guard dangles, entry(edge.carrier) != nil else { continue }
                let written = types.types.map(vocabulary.written)
                let word = written.map { ":\(Word.dangling.rawValue)(\($0.map(\.term).joined(separator: "|")))" } ?? ":\(Word.dangling.rawValue)"
                let named = written.map { Queries.listed($0.map(\.type.rawValue)) + " " } ?? ""
                return "Some \(named)edges point at shapes that aren't there: \(word) finds what carries them."
            }
        }
        return nil
    }

    /// The kinds of the shapes each name (folded) names, for a refusal's hints that wait on what a
    /// title names (`HintPremise`): none for a name no shape has.
    func kinds(named names: Set<String>) async throws(QueryError) -> [String: Set<ShapeKind>] {
        let index = try await titleIndex()
        var kinds: [String: Set<ShapeKind>] = [:]
        for name in names {
            kinds[name] = Set((index.shapes(named: name) ?? []).compactMap { entry($0)?.record.kind })
        }
        return kinds
    }

    /// A name standing where a container goes, refused when none of its shapes is of a kind that
    /// holds shapes (a board of them, or shapes on its own).
    private func holdsNothing(_ written: String, _ ids: [ShapeID], span: QuerySpan?) -> QueryError? {
        var found: [ShapeKind] = []
        for id in ids {
            guard let kind = entry(id)?.record.kind else { continue }
            if snapshot.topology.containerKinds.contains(kind) { return nil }
            if !found.contains(kind) { found.append(kind) }
        }
        let message = found.count == 1
            ? "\(written) is \(indefinite(found[0].rawValue)), which holds no shapes: nothing is inside it. \(notDrawnWithin)"
            : "No shape titled \(written) holds shapes: nothing is inside it. \(notDrawnWithin)"
        return QueryError(.cannotContain, message, hint: vocabulary.containersListed, span: span)
    }

    /// A shape's name, once read (`readNames`, `readEveryName`): nil for none.
    private func name(_ id: ShapeID) -> String? {
        if everyName != nil, let place = walked?.position[id] { return everyName?[place] ?? nil }
        return names[id] ?? nil
    }

    /// Reads the names of those of `ids` not read yet: named ones here, derived ones on the main
    /// actor, in slices, in file order. A shape outside the query's range has none. Nothing once
    /// every name has been read.
    private func readNames(_ ids: [ShapeID]) async throws(QueryError) {
        guard let naming = vocabulary.naming, everyName == nil else { return }
        var derived: [ShapeID] = []
        for id in ids where names[id] == nil {
            try tick()
            guard let entry = entry(id) else {
                names.updateValue(nil, forKey: id)
                continue
            }
            switch entry.kind.names {
            case .named: names.updateValue(naming.named(entry.record), forKey: id)
            case .derived: if names.updateValue(nil, forKey: id) == nil { derived.append(id) }
            case .none: names.updateValue(nil, forKey: id)
            }
        }
        try await askDerivedNames(inFileOrder(derived))
    }

    /// Every name in the query's range, by place in file order, read once: named ones here, in one
    /// pass over the shapes, and derived ones on the main actor, in slices, in file order (but those
    /// read already).
    private func readEveryName() async throws(QueryError) -> [String?] {
        if let everyName { return everyName }
        let universe = try universe()
        var every = [String?](repeating: nil, count: universe.order.count)
        if let naming = vocabulary.naming {
            var derived: [ShapeID] = [], places: [Int] = []
            for (place, entry) in universe.entries.enumerated() {
                try tick()
                switch entry.kind.names {
                case .named:
                    every[place] = naming.named(entry.record)
                case .derived:
                    let id = universe.order[place]
                    if let known = names[id] {
                        every[place] = known
                    } else {
                        derived.append(id)
                        places.append(place)
                    }
                case .none:
                    break
                }
            }
            try await askDerivedNames(derived)
            for (id, place) in zip(derived, places) { every[place] = names[id] ?? nil }
        }
        everyName = every
        return every
    }

    /// Asks the main actor the derived names of `ids`, in that order, in slices, and keeps them.
    private func askDerivedNames(_ ids: [ShapeID]) async throws(QueryError) {
        var rest = ids[...]
        while !rest.isEmpty {
            try checkCancelled()
            pause()
            let asked: (answers: [ShapeID: String?], done: Int)
            do throws(QueryError) {
                asked = try await facts.titles(of: rest)
            } catch {
                resume()
                throw error
            }
            resume()
            for (id, title) in asked.answers { names.updateValue(title, forKey: id) }
            rest = rest.dropFirst(asked.done)
        }
    }

    /// Every name in the query's range, read once.
    private func titleIndex() async throws(QueryError) -> TitleIndex {
        if let named { return named }
        let every = try await readEveryName()
        let order = try universe().order
        var index = TitleIndex()
        for (place, title) in every.enumerated() {
            guard let title else { continue }
            index.add(title, order[place])
        }
        named = index
        return index
    }

    /// `no_title_match`: each name tested for with `=` that matched nothing and is no shape's, with
    /// up to 3 names it may have meant.
    private func titleWarnings() async throws(QueryError) -> [QueryWarning] {
        guard !emptyNameTests.isEmpty else { return [] }
        let index = try await titleIndex()
        var warnings: [QueryWarning] = [], said: Set<EmptyNameTest> = []
        for test in emptyNameTests where said.insert(test).inserted {
            let exists = test.ignoringCase
                ? index.names.contains { TypedTest.same($0, test.name, ignoringCase: true) }
                : index.shapes(named: test.name) != nil
            guard !exists else { continue }
            let guesses = Suggestions.closest(to: test.name, among: index.names, limit: 3).map(quoted)
            warnings.append(QueryWarning(.noTitleMatch, sentences("No shape is titled \(test.name).", didYouMean(guesses))!))
        }
        return warnings
    }

    // MARK: The shapes a query ranges over

    /// Every shape on a board the app can show, none kept aside, in file order: walked once, when
    /// something needs them all.
    private func universe() throws(QueryError) -> Universe {
        if let walked { return walked }
        stats.universeWalks += 1
        var built = Universe()
        let count = snapshot.file.shapeCount
        built.order.reserveCapacity(count)
        built.entries.reserveCapacity(count)
        built.position.reserveCapacity(count)
        try snapshot.topology.forEachShape(inFileOrder: { (record, board) throws(QueryError) in
            try tick()
            guard !record.isOpaque, let kind = kinds[record.kind] else { return }
            built.position[record.id] = built.order.count
            built.order.append(record.id)
            built.entries.append(Entry(record: record, board: board, kind: kind))
        })
        walked = built
        return built
    }

    /// A shape the query ranges over, and its board; nil for one it doesn't (gone, kept aside, on a
    /// board the app can't show). O(1) once every shape's been walked, else O(its depth), once.
    private func entry(_ id: ShapeID) -> Entry? {
        if walked != nil { return walked?.entry(id) }
        if let known = looked[id] { return known }
        var found: Entry?
        if let record = snapshot.topology.shape(id), !record.isOpaque, let kind = kinds[record.kind],
           let board = snapshot.file.board(containing: id) {
            found = Entry(record: record, board: board, kind: kind)
        }
        looked.updateValue(found, forKey: id)
        return found
    }

    private func members(_ candidates: Candidates) throws(QueryError) -> Set<ShapeID> {
        switch candidates {
        case .only(let ids): return ids
        case .all:
            if let everyShape { return everyShape }
            let all = Set(try universe().order)
            everyShape = all
            return all
        }
    }

    /// The candidates as a list: every shape in file order, or some in no order.
    private func pool(_ candidates: Candidates) throws(QueryError) -> [ShapeID] {
        switch candidates {
        case .all: try universe().order
        case .only(let ids): Array(ids)
        }
    }

    private func restrict(_ found: Set<ShapeID>, to candidates: Candidates) -> Set<ShapeID> {
        switch candidates {
        case .all: found
        case .only(let ids): found.count <= ids.count ? found.intersection(ids) : ids.intersection(found)
        }
    }

    private func admits(_ id: ShapeID, _ candidates: Candidates) -> Bool {
        switch candidates {
        case .all: true
        case .only(let ids): ids.contains(id)
        }
    }

    /// Shapes in file order: by where the walk met them, else by their places on the boards above.
    func inFileOrder(_ ids: Set<ShapeID>) throws(QueryError) -> [ShapeID] {
        if let walked, ids.count * 8 > walked.order.count { return walked.order.filter(ids.contains) }
        return try inFileOrder(Array(ids))
    }

    private func inFileOrder(_ ids: [ShapeID]) throws(QueryError) -> [ShapeID] {
        guard ids.count > 1 else { return ids }
        if let walked {
            return ids.sorted { walked.position[$0, default: .max] < walked.position[$1, default: .max] }
        }
        var keyed: [(id: ShapeID, key: [Int])] = []
        keyed.reserveCapacity(ids.count)
        for id in ids {
            try tick()
            keyed.append((id, snapshot.topology.fileOrderKey(of: id) ?? [.max]))
        }
        keyed.sort { $0.key.lexicographicallyPrecedes($1.key) }
        return keyed.map(\.id)
    }

    // MARK: Nodes

    /// What a list matches among the candidates: what any of its items does.
    private func matches(_ list: PlanList, among candidates: Candidates) async throws(QueryError) -> Set<ShapeID> {
        if case .all = candidates, let known = sets[list.id] { return known }
        var found: Set<ShapeID> = []
        for item in list.items { found.formUnion(try await matches(item, among: candidates)) }
        if case .all = candidates { sets[list.id] = found }
        return found
    }

    /// What a node matches among the candidates: among every shape, worked out once per query.
    private func matches(_ node: PlanNode, among candidates: Candidates) async throws(QueryError) -> Set<ShapeID> {
        if case .all = candidates, let known = sets[node.id] { return known }
        let found = try await evaluate(node, among: candidates)
        if case .all = candidates { sets[node.id] = found }
        return found
    }

    private func evaluate(_ node: PlanNode, among candidates: Candidates) async throws(QueryError) -> Set<ShapeID> {
        switch node.op {
        case .all:
            return try members(candidates)
        case .kinds(let wanted):
            return try ofKinds(wanted, among: candidates)
        case .title(let folded, _):
            return restrict(Set(try await titleIndex().shapes(named: folded) ?? []), to: candidates)
        case .id(let id):
            return entry(id) == nil ? [] : restrict([id], to: candidates)
        case .attribute(_, let readers):
            return try await attribute(node, readers: readers, among: candidates)
        case .contains(let text):
            return try await contains(text, among: candidates)
        case .not(let list):
            let pool = try members(candidates)
            return pool.subtracting(try await matches(list, among: candidates))
        case .is(let list):
            return try await matches(list, among: candidates)
        case .inside(let list), .ancestorIn(let list):
            let containers = try await matches(list, among: .all)
            return try inside(containers, among: candidates)
        case .parentIn(let list):
            let containers = try await matches(list, among: .all)
            return try directlyOn(containers, among: candidates)
        case .has(let items):
            return try await has(items, among: candidates)
        case .topLevel:
            return topLevel(among: candidates)
        case .currentBoard:
            return onBoard(snapshot.shown, among: candidates)
        case .edges(let word, let anchor, let second, let types):
            let anchors = try await matches(anchor, among: .all)
            switch word {
            case .edgeTo: return try adjacent(.outgoing, to: anchors, types: types, among: candidates)
            case .edgeFrom: return try adjacent(.incoming, to: anchors, types: types, among: candidates)
            case .connectedTo: return try adjacent(.either, to: anchors, types: types, among: candidates)
            case .downstreamOf: return restrict(try reached(.outgoing, from: anchors, types: types), to: candidates)
            case .upstreamOf: return restrict(try reached(.incoming, from: anchors, types: types), to: candidates)
            case .componentOf: return restrict(try component(of: anchors, types: types), to: candidates)
            case .startsAt:
                return try connections(from: anchors, .outgoing, types: types, among: candidates) { anchors.contains($0.source) }
            case .endsAt:
                return try connections(from: anchors, .incoming, types: types, among: candidates) { anchors.contains($0.target) }
            case .startOf: return try ends(of: anchors, .outgoing, types: types, among: candidates)
            case .endOf: return try ends(of: anchors, .incoming, types: types, among: candidates)
            case .between:
                guard let second else { return [] }
                let others = try await matches(second, among: .all)
                return try connections(from: anchors, .either, types: types, among: candidates) { edge in
                    (anchors.contains(edge.source) && others.contains(edge.target)) || (others.contains(edge.source) && anchors.contains(edge.target))
                }
            default:
                return []
            }
        case .relation(_, let anchor, let types, let direction):
            let anchors = try await matches(anchor, among: .all)
            return try adjacent(direction, to: anchors, types: types, among: candidates)
        case .fileRelation(let word, let anchor):
            let anchors = try await matches(anchor, among: .all)
            return try related(word, to: anchors, among: candidates)
        case .dangling(let types):
            return try dangling(types, among: candidates)
        case .pseudo(let word):
            return try await pseudo(word, among: candidates)
        case .and(let nodes):
            return try await allOf(nodes, among: candidates)
        }
    }

    /// A compound: each node among what the ones before it matched, cheapest first. One whose first
    /// node finds nothing of its own (no id, name or seeded word) and that has a one-step edge word
    /// with fewer anchors than `QueryBudget.seedFromAnchors` starts from that word, found from the
    /// anchors' edges, so its shapes are those edges' far ends, never a walk of every shape.
    private func allOf(_ nodes: [PlanNode], among candidates: Candidates) async throws(QueryError) -> Set<ShapeID> {
        var current = candidates, rest = nodes
        if case .all = candidates, let first = rest.first, !finds(first), let seeded = try await seed(&rest) {
            current = .only(seeded)
        }
        var last: Set<ShapeID>?
        for node in rest {
            let found = try await matches(node, among: current)
            last = found
            current = .only(found)
            if found.isEmpty { break }
        }
        if let last { return last }
        return try members(current)
    }

    /// Whether a node finds its shapes directly: an id, a name, a word with seeds.
    private func finds(_ node: PlanNode) -> Bool {
        switch node.op {
        case .id, .title: true
        case .pseudo(let word):
            if case .pseudoClass(let behavior)? = vocabulary.contributedWords[word]?.meaning { behavior.seeds != nil } else { false }
        default: false
        }
    }

    /// The first one-step edge word's matches among every shape, found from its anchors, taken out of
    /// `rest`; nil (and `rest` as it was) when there's none, or it has too many anchors.
    private func seed(_ rest: inout [PlanNode]) async throws(QueryError) -> Set<ShapeID>? {
        for (index, node) in rest.enumerated() {
            let anchor: PlanList
            switch node.op {
            case .edges(let word, let list, _, _) where Self.oneStep.contains(word): anchor = list
            case .relation(_, let list, _, _), .fileRelation(_, let list): anchor = list
            default: continue
            }
            let anchors = try await matches(anchor, among: .all)
            guard anchors.count < QueryBudget.seedFromAnchors else { return nil }
            let found = try await matches(node, among: .all)
            rest.remove(at: index)
            stats.seeded += 1
            return found
        }
        return nil
    }

    private static let oneStep: Set<Word> = [.edgeTo, .edgeFrom, .connectedTo, .startsAt, .endsAt, .startOf, .endOf, .between]

    // MARK: Kinds, attributes, text, words

    private func ofKinds(_ wanted: Set<ShapeKind>, among candidates: Candidates) throws(QueryError) -> Set<ShapeID> {
        var found: Set<ShapeID> = []
        for id in try pool(candidates) {
            try tick()
            if let kind = entry(id)?.record.kind, wanted.contains(kind) { found.insert(id) }
        }
        return found
    }

    /// `[name op value]`: the reader for each candidate's kind, if it has one, reading the property
    /// (its text through its format) or the name, and testing it.
    private func attribute(_ node: PlanNode, readers: [AttributeReader], among candidates: Candidates) async throws(QueryError) -> Set<ShapeID> {
        guard case .attribute(let attribute, _) = node.op else { return [] }
        var readerOf: [ShapeKind: Int] = [:]
        for (index, reader) in readers.enumerated() {
            for kind in reader.kinds { readerOf[kind] = index }
        }
        let pool = try self.pool(candidates)
        if readers.contains(where: { $0.source == .names }) {
            var named: [ShapeID] = []
            for id in pool {
                if let kind = entry(id)?.record.kind, let index = readerOf[kind], readers[index].source == .names { named.append(id) }
            }
            try await readNames(named)
        }
        var found: Set<ShapeID> = []
        for id in pool {
            try tick()
            guard let entry = entry(id), let index = readerOf[entry.record.kind] else { continue }
            let reader = readers[index]
            switch reader.source {
            case .names:
                if reader.test.holds(name: name(id)) { found.insert(id) }
            case .property(let shape):
                read.insert(id)
                if reader.test.holds(value(attribute, of: entry, shape: shape), shape: shape) { found.insert(id) }
            }
        }
        if found.isEmpty {
            for reader in readers where reader.source == .names {
                if case .equals(.text(let wanted)) = reader.test.comparison {
                    emptyNameTests.append(EmptyNameTest(name: wanted, ignoringCase: reader.test.ignoringCase))
                }
            }
        }
        return found
    }

    /// `:contains("…")`: the name, or any string in the attributes, holds the text, ignoring case.
    /// Derived names are asked only of the shapes nothing else matched.
    private func contains(_ text: String, among candidates: Candidates) async throws(QueryError) -> Set<ShapeID> {
        func holds(_ string: String) -> Bool { string.range(of: text, options: .caseInsensitive) != nil }
        let naming = vocabulary.naming
        var found: Set<ShapeID> = [], later: [ShapeID] = []
        for id in try pool(candidates) {
            try tick()
            guard let entry = entry(id) else { continue }
            let kind = entry.kind
            read.insert(id)
            if kind.names == .named, let name = naming?.named(entry.record), holds(name) {
                found.insert(id)
                continue
            }
            let json = properties(of: entry)
            if kind.readable.contains(where: { attribute in
                json[attribute.name].map { formatted($0, shape: attribute.shape).containsString(where: holds) } ?? false
            }) {
                found.insert(id)
                continue
            }
            if kind.names == .derived { later.append(id) }
        }
        try await readNames(later)
        for id in later where name(id).map(holds) ?? false { found.insert(id) }
        return found
    }

    /// A contributed pseudo-class: its seeds, if it has them, else the candidates, each asked
    /// `matches`; those it leaves to the main actor asked `onMain`, in slices, in file order.
    private func pseudo(_ word: String, among candidates: Candidates) async throws(QueryError) -> Set<ShapeID> {
        guard case .pseudoClass(let behavior)? = vocabulary.contributedWords[word]?.meaning, let prepared = snapshot.words[word] else { return [] }
        var pool: [ShapeID] = []
        if let seeds = behavior.seeds {
            for id in seeds(prepared) where admits(id, candidates) { pool.append(id) }
        } else {
            pool = try self.pool(candidates)
        }
        var found: Set<ShapeID> = [], ask: [ShapeID] = []
        for id in pool {
            try tick()
            guard let entry = entry(id) else { continue }
            switch behavior.matches(QueryShape(record: entry.record, board: entry.board, topology: snapshot.topology), prepared) {
            case .yes: found.insert(id)
            case .no: break
            case .onMain: ask.append(id)
            }
        }
        guard behavior.onMain != nil else { return found }
        var rest = try inFileOrder(ask)[...]
        while !rest.isEmpty {
            try checkCancelled()
            pause()
            let asked: (answers: [ShapeID: Bool], done: Int)
            do throws(QueryError) {
                asked = try await facts.verdicts(word, of: rest)
            } catch {
                resume()
                throw error
            }
            resume()
            for (id, holds) in asked.answers where holds { found.insert(id) }
            rest = rest.dropFirst(asked.done)
        }
        return found
    }

    /// A shape's properties as JSON (`propertiesJSON`), written once per query.
    private func properties(of entry: Entry) -> JSONObject {
        let id = entry.record.id
        if let known = encoded[id] { return known }
        stats.recordsEncoded += 1
        let json = entry.record.propertiesJSON ?? [:]
        encoded[id] = json
        return json
    }

    /// A property's value as it reads, its text (or its items') through its media type's format.
    private func value(_ attribute: String, of entry: Entry, shape: KindSchema.PropertyShape) -> JSONValue? {
        properties(of: entry)[attribute].map { formatted($0, shape: shape) }
    }

    private func formatted(_ value: JSONValue, shape: KindSchema.PropertyShape) -> JSONValue {
        switch shape {
        case .string(_, let mediaType?, _):
            guard let text = value.stringValue, let read = reader(mediaType) else { return value }
            return .string(read(text))
        case .array(.string(_, let mediaType?, _)):
            guard case .array(let items) = value, let read = reader(mediaType) else { return value }
            return .array(items.map { item in item.stringValue.map { .string(read($0)) } ?? item })
        default:
            return value
        }
    }

    /// How text of a media type reads, with what its format took; nil for text read as stored.
    private func reader(_ mediaType: String) -> ((String) -> String)? {
        guard let format = vocabulary.textFormats[mediaType], let prepared = snapshot.formats[mediaType] else { return nil }
        return { format.read($0, prepared) }
    }

    // MARK: Containment

    /// The shapes `id` is inside, the nearest first, as Topology has them: the containers it's in on
    /// its board (frames), then its board's owner, the containers that one is in, and so on up. A
    /// container's and a board's are worked out once, so a shape's cost a lookup.
    private func ancestors(_ id: ShapeID) -> [ShapeID] {
        guard let entry = entry(id) else { return snapshot.topology.ancestors(of: id) }
        guard let container = snapshot.topology.container(of: entry.record, on: entry.board) else { return ancestors(of: entry.board) }
        return ancestors(heldBy: container, on: entry.board)
    }

    /// The shapes a shape `container` holds is inside, the nearest first: the container, the
    /// containers it's in on `board`, then the board's: worked out once per container, going up only
    /// as far as a container worked out already. Containers on a board never go round (reading breaks
    /// a loop), but the walk up stops after as many as the board holds all the same.
    private func ancestors(heldBy container: ShapeID, on board: BoardID) -> [ShapeID] {
        if let known = holding[container] { return known }
        var unknown: [ShapeID] = [], current: ShapeID? = container, above: [ShapeID]?
        let most = snapshot.file[board].shapes.count
        while let next = current {
            if let known = holding[next] {
                above = known
                break
            }
            unknown.append(next)
            guard unknown.count <= most, let record = entry(next)?.record else { break }
            current = snapshot.topology.container(of: record, on: board)
        }
        var chain = above ?? ancestors(of: board)
        for holder in unknown.reversed() {
            chain = [holder] + chain
            holding[holder] = chain
        }
        return chain
    }

    /// The shapes a board of the query's range is inside, the nearest first: its owner, the
    /// containers that one is in on its board, and so on up; worked out once per board, going up only
    /// as far as a board worked out already. Every owner on the way up is in the range, since a board
    /// the app can show has every owner above it.
    private func ancestors(of board: BoardID) -> [ShapeID] {
        if let known = ancestry[board] { return known }
        var unknown: [BoardID] = [], current = board, above: [ShapeID] = []
        while let owner = current.owner {
            if let known = ancestry[current] {
                above = known
                break
            }
            unknown.append(current)
            // A board no shape of the range owns is Topology's to answer (nothing, for the query).
            guard let next = entry(owner)?.board, unknown.count <= snapshot.file.children.count else {
                above = snapshot.topology.ancestors(of: owner)
                break
            }
            current = next
        }
        for board in unknown.reversed() {
            guard let owner = board.owner else { continue }
            // Its owner, then what the owner is inside: its containers and its own board's.
            if let place = entry(owner), let container = snapshot.topology.container(of: place.record, on: place.board) {
                above = [owner] + ancestors(heldBy: container, on: place.board)
            } else {
                above = [owner] + above
            }
            ancestry[board] = above
        }
        return ancestry[board] ?? []
    }

    /// Those of `containers` whose kinds can hold shapes: the rest have nothing inside them, and
    /// asking Topology about each would cost its depth.
    private func holders(among containers: Set<ShapeID>) -> Set<ShapeID> {
        let kinds = snapshot.topology.containerKinds
        return containers.filter { entry($0).map { kinds.contains($0.record.kind) } ?? false }
    }

    /// Inside some container, at any depth: from the containers' insides for every shape, else from
    /// each candidate's ancestors.
    private func inside(_ containers: Set<ShapeID>, among candidates: Candidates) throws(QueryError) -> Set<ShapeID> {
        let holders = holders(among: containers)
        guard !holders.isEmpty else { return [] }
        var found: Set<ShapeID> = []
        switch candidates {
        case .all:
            // A container inside another is walked with it.
            for holder in holders where !ancestors(holder).contains(where: holders.contains) {
                for id in snapshot.topology.descendants(of: holder) {
                    try tick()
                    if entry(id) != nil { found.insert(id) }
                }
            }
        case .only(let ids):
            for id in ids {
                try tick()
                if ancestors(id).contains(where: holders.contains) { found.insert(id) }
            }
        }
        return found
    }

    /// Directly inside a container (what it holds; for one that owns a board, that board's shapes in
    /// no container): from what's directly inside each container for every shape, else from each
    /// candidate's parent.
    private func directlyOn(_ containers: Set<ShapeID>, among candidates: Candidates) throws(QueryError) -> Set<ShapeID> {
        var found: Set<ShapeID> = []
        switch candidates {
        case .all:
            for container in holders(among: containers) {
                for id in snapshot.topology.children(of: container) {
                    try tick()
                    if entry(id) != nil { found.insert(id) }
                }
            }
        case .only(let ids):
            for id in ids {
                try tick()
                if let parent = ancestors(id).first, containers.contains(parent) { found.insert(id) }
            }
        }
        return found
    }

    /// `:has(…)`: what each item matches, anywhere, and the shapes it's inside (or directly inside,
    /// after `>`).
    private func has(_ items: [PlanHasItem], among candidates: Candidates) async throws(QueryError) -> Set<ShapeID> {
        var found: Set<ShapeID> = []
        for item in items {
            for id in try await matches(item.node, among: .all) {
                try tick()
                if item.child {
                    if let parent = ancestors(id).first { found.insert(parent) }
                } else {
                    found.formUnion(ancestors(id))
                }
            }
        }
        return restrict(found, to: candidates)
    }

    /// Inside nothing: on the top board, in no container.
    private func topLevel(among candidates: Candidates) -> Set<ShapeID> {
        let topology = snapshot.topology
        switch candidates {
        case .all:
            return Set(snapshot.file.root.shapes.lazy.filter {
                !$0.isOpaque && self.kinds[$0.kind] != nil && topology.container(of: $0, on: .root) == nil
            }.map(\.id))
        case .only(let ids):
            return ids.filter(topology.isTopLevel)
        }
    }

    /// On one board (the one shown), in a container or not.
    private func onBoard(_ board: BoardID, among candidates: Candidates) -> Set<ShapeID> {
        switch candidates {
        case .all:
            return Set(snapshot.file[board].shapes.lazy.filter { !$0.isOpaque && self.kinds[$0.kind] != nil }.map(\.id))
        case .only(let ids):
            return ids.filter { snapshot.file.board(containing: $0) == board }
        }
    }

    // MARK: Edges

    /// The end of an edge that isn't `id`, as `direction` reads it from `id`: the target of one going
    /// out, the source of one coming in; `id` itself for an edge from `id` to `id`.
    private static func far(_ edge: Edge, from id: ShapeID, _ direction: EdgeDirection) -> ShapeID {
        switch direction {
        case .outgoing: edge.target
        case .incoming: edge.source
        case .either: edge.source == id ? edge.target : edge.source
        }
    }

    /// Shapes with an edge, as `direction` reads it from them, to an anchor (`.outgoing`: the shape
    /// → the anchor; `.incoming`: the anchor → the shape): from the candidates' own edges when they're
    /// fewer than the anchors, else from the anchors'.
    private func adjacent(_ direction: EdgeDirection, to anchors: Set<ShapeID>, types: PlanEdgeTypes,
                          among candidates: Candidates) throws(QueryError) -> Set<ShapeID> {
        let topology = snapshot.topology, filter = types.filter
        var found: Set<ShapeID> = []
        if case .only(let ids) = candidates, ids.count <= anchors.count {
            for id in ids {
                try tick()
                if topology.hasEdges(of: id, direction, types: filter, where: { anchors.contains(Self.far($0, from: id, direction)) }) {
                    found.insert(id)
                }
            }
            return found
        }
        let reverse: EdgeDirection = switch direction {
        case .outgoing: .incoming
        case .incoming: .outgoing
        case .either: .either
        }
        for anchor in anchors {
            try tick()
            for edge in topology.edges(of: anchor, reverse, types: filter) {
                let shape = Self.far(edge, from: anchor, reverse)
                if admits(shape, candidates), entry(shape) != nil { found.insert(shape) }
            }
        }
        return found
    }

    /// The shapes related to an anchor by a relation answered from a fact of the file (`:is-a(S)`):
    /// those the plugin's `related` lists the anchor among, and, when the relation is transitive,
    /// those related to any of those, however far. Worked backward from the anchors over the
    /// relation read forward once, breadth first, each shape once: a cycle ends where it began,
    /// and a shape in one is related to itself.
    private func related(_ word: String, to anchors: Set<ShapeID>, among candidates: Candidates) throws(QueryError) -> Set<ShapeID> {
        guard case .fileRelation(let relation)? = vocabulary.contributedWords[word]?.meaning, let prepared = snapshot.words[word] else { return [] }
        let back = try reversed(word, relation, prepared)
        var found: Set<ShapeID> = []
        var level = Array(anchors)
        while !level.isEmpty {
            var next: [ShapeID] = []
            for shape in level {
                try tick()
                for before in back[shape] ?? [] where found.insert(before).inserted { next.append(before) }
            }
            level = relation.transitive ? next : []
        }
        return restrict(found.filter { entry($0) != nil }, to: candidates)
    }

    /// A file relation read forward for every shape that has any, as each shape's relatives
    /// reversed: for a shape, those related to it directly. Once per query and word.
    private func reversed(_ word: String, _ relation: ContributedFileRelation, _ prepared: any Sendable) throws(QueryError) -> [ShapeID: [ShapeID]] {
        if let known = reversedRelations[word] { return known }
        var back: [ShapeID: [ShapeID]] = [:]
        for shape in relation.seeds(prepared) {
            try tick()
            for other in relation.related(shape, prepared) { back[other, default: []].append(shape) }
        }
        reversedRelations[word] = back
        return back
    }

    /// What a path of one edge or more, each followed as `direction` says, reaches from the
    /// anchors: an anchor only if such a path leads back to it. Breadth first, each shape once.
    private func reached(_ direction: EdgeDirection, from anchors: Set<ShapeID>, types: PlanEdgeTypes) throws(QueryError) -> Set<ShapeID> {
        let topology = snapshot.topology, filter = types.filter
        var reached: Set<ShapeID> = [], expanded = anchors, queue = Array(anchors), next = 0
        while next < queue.count {
            let shape = queue[next]
            next += 1
            try tick()
            for edge in topology.edges(of: shape, direction, types: filter) {
                let other = Self.far(edge, from: shape, direction)
                guard entry(other) != nil else { continue }
                reached.insert(other)
                if expanded.insert(other).inserted { queue.append(other) }
            }
        }
        return reached
    }

    /// `:component-of`: what a path of one edge or more, either way, joins to an anchor other than
    /// itself: every shape in an anchor's component but that anchor, and an anchor only if another
    /// is in its component.
    private func component(of anchors: Set<ShapeID>, types: PlanEdgeTypes) throws(QueryError) -> Set<ShapeID> {
        let topology = snapshot.topology, filter = types.filter
        var component: [ShapeID: Int] = [:], anchorsIn: [Int] = []
        for start in anchors where component[start] == nil {
            let number = anchorsIn.count
            anchorsIn.append(0)
            component[start] = number
            var queue = [start], next = 0
            while next < queue.count {
                let shape = queue[next]
                next += 1
                try tick()
                if anchors.contains(shape) { anchorsIn[number] += 1 }
                for edge in topology.edges(of: shape, .either, types: filter) {
                    let other = Self.far(edge, from: shape, .either)
                    guard other != shape, component[other] == nil, entry(other) != nil else { continue }
                    component[other] = number
                    queue.append(other)
                }
            }
        }
        var found: Set<ShapeID> = []
        for (shape, number) in component where !anchors.contains(shape) || anchorsIn[number] > 1 { found.insert(shape) }
        return found
    }

    /// Connections (shapes that carry an edge in slot `""`: an arrow) whose own edge `runs` says
    /// yes to: from the candidates' carried edges when they're fewer than the anchors, else from the
    /// anchors' edges (`direction` from the anchor), their carriers.
    private func connections(from anchors: Set<ShapeID>, _ direction: EdgeDirection, types: PlanEdgeTypes, among candidates: Candidates,
                             where runs: (Edge) -> Bool) throws(QueryError) -> Set<ShapeID> {
        let topology = snapshot.topology
        func counts(_ edge: Edge) -> Bool { types.admitsConnection(edge) && runs(edge) }
        var found: Set<ShapeID> = []
        if case .only(let ids) = candidates, ids.count <= anchors.count {
            for id in ids {
                try tick()
                if topology.edges(carriedBy: id).contains(where: counts) { found.insert(id) }
            }
            return found
        }
        for anchor in anchors {
            try tick()
            for edge in topology.edges(of: anchor, direction, types: types.filter) where counts(edge) {
                if admits(edge.carrier, candidates), entry(edge.carrier) != nil { found.insert(edge.carrier) }
            }
        }
        return found
    }

    /// The shapes the anchors, connections (shapes that carry an edge in slot `""`: an arrow), run
    /// from (`.outgoing`: the source of each such edge they carry) or to (`.incoming`: its target):
    /// from the candidates' own edges when they're fewer than the anchors, else from the anchors'.
    /// A shape with no edge in slot `""` is no connection and has no ends: an arrow with a free end
    /// (it carries none), a note whose text mentions (its edges are in the text's slot).
    private func ends(of anchors: Set<ShapeID>, _ direction: EdgeDirection, types: PlanEdgeTypes,
                      among candidates: Candidates) throws(QueryError) -> Set<ShapeID> {
        let topology = snapshot.topology
        var found: Set<ShapeID> = []
        if case .only(let ids) = candidates, ids.count <= anchors.count {
            for id in ids {
                try tick()
                if topology.hasEdges(of: id, direction, types: types.filter, where: { types.admitsConnection($0) && anchors.contains($0.carrier) }) {
                    found.insert(id)
                }
            }
            return found
        }
        for anchor in anchors {
            try tick()
            for edge in topology.edges(carriedBy: anchor) where types.admitsConnection(edge) {
                let end = direction == .incoming ? edge.target : edge.source
                if admits(end, candidates), entry(end) != nil { found.insert(end) }
            }
        }
        return found
    }

    /// Shapes that carry an edge whose far end (an end that isn't the carrier) isn't a shape the
    /// query ranges over: gone, kept aside, or on a board the app can't show.
    private func dangling(_ types: PlanEdgeTypes, among candidates: Candidates) throws(QueryError) -> Set<ShapeID> {
        func dangles(_ edge: Edge) -> Bool {
            types.admits(edge.type)
                && ((edge.source != edge.carrier && entry(edge.source) == nil) || (edge.target != edge.carrier && entry(edge.target) == nil))
        }
        var found: Set<ShapeID> = []
        switch candidates {
        case .all:
            for edge in snapshot.topology.edges(ofType: types.filter) {
                try tick()
                if !found.contains(edge.carrier), dangles(edge), entry(edge.carrier) != nil { found.insert(edge.carrier) }
            }
        case .only(let ids):
            for id in ids {
                try tick()
                if snapshot.topology.edges(carriedBy: id).contains(where: dangles) { found.insert(id) }
            }
        }
        return found
    }

    // MARK: Rows

    /// Rows for the shapes, in the order given: names read first, the shapes', those of the shapes
    /// they're inside and their connections' ends', derived ones together on the main actor.
    private func rows(_ ids: ArraySlice<ShapeID>, properties wanted: QueryRequest.Properties) async throws(QueryError) -> [QueryRow] {
        var runs: [ShapeID: [Edge]] = [:], named: [ShapeID] = []
        for id in ids {
            try tick()
            named.append(id)
            named += ancestors(id)
            if let edges = try connection(of: id) {
                runs[id] = edges
                for edge in edges {
                    named += [edge.source, edge.target]
                    if case .forwarded(let source, let target) = edge.origin { named += [source, target].compactMap { $0 } }
                }
            }
        }
        try await readNames(named)
        var rows: [QueryRow] = []
        rows.reserveCapacity(ids.count)
        for id in ids {
            try tick()
            guard let entry = entry(id) else { continue }
            let kind = entry.kind
            var row = QueryRow(id: id, kind: entry.record.kind, title: name(id), board: entry.board,
                               inside: ancestors(id).reversed().map(containerName))
            (row.properties, row.cut) = listed(entry, kind: kind, wanted)
            if let edges = runs[id], let first = edges.first {
                row.connection = QueryConnection(type: first.type, from: end(first.source), to: end(first.target))
                if case .forwarded(let source, let target) = first.origin {
                    row.connection?.via = QueryVia(from: source.map(end), to: target.map(end))
                    if edges.count > 1 { row.connection?.more = edges.dropFirst().map { QueryPair(from: end($0.source), to: end($0.target)) } }
                }
            }
            if id == snapshot.editing { row.editing = true }
            rows.append(row)
        }
        return rows
    }

    /// An end of a connection, with its name if it has one (read already).
    private func end(_ id: ShapeID) -> QueryEnd { QueryEnd(id: id, title: name(id)) }

    /// What a shape carries in slot `""` as a connection, in the view the query reads: its first
    /// edge as emitted, or, when that was forwarded through a stand-in at an end, every copy of it
    /// (a stand-in for several shapes makes several) in file order, by where they start, then where
    /// they end. Nil for a shape that carries none.
    private func connection(of id: ShapeID) throws(QueryError) -> [Edge]? {
        let carried = snapshot.topology.edges(carriedBy: id)
        guard let first = carried.first(where: { $0.slot.isEmpty }) else { return nil }
        guard case .forwarded = first.origin else { return [first] }
        let drawn = first.literal
        var copies = carried.filter { $0.slot.isEmpty && $0.literal == drawn }
        guard copies.count > 1 else { return copies }
        var keyed: [(edge: Edge, key: [Int])] = []
        keyed.reserveCapacity(copies.count)
        for edge in copies {
            try tick()
            keyed.append((edge, (snapshot.topology.fileOrderKey(of: edge.source) ?? [.max]) + [-1] + (snapshot.topology.fileOrderKey(of: edge.target) ?? [.max])))
        }
        keyed.sort { $0.key.lexicographicallyPrecedes($1.key) }
        copies = keyed.map(\.edge)
        return copies
    }

    /// What a shape another is inside is called, in a row's `inside`: its name, else, for one that
    /// owns a board, what its kind calls an untitled one's board (the board names point's
    /// placeholder; Boards' own rule, as the path names it), else its kind's label (an untitled
    /// frame's).
    private func containerName(_ holder: ShapeID) -> String {
        if let title = name(holder) { return title }
        guard let kind = entry(holder)?.kind else { return holder.description }
        return kind.boardName ?? kind.label
    }

    /// A row's attributes as they read, and those cut: every one the shape has, text cut at
    /// `QueryBudget.cut` characters; only those named, whole; or none.
    private func listed(_ entry: Entry, kind: KindFacts, _ wanted: QueryRequest.Properties) -> (JSONObject?, [String]?) {
        if case .none = wanted { return (nil, nil) }
        let json = properties(of: entry)
        var listed: JSONObject = [:], cut: [String] = []
        for attribute in kind.readable {
            if case .only(let fields) = wanted, !fields.contains(attribute.name) { continue }
            guard let raw = json[attribute.name] else { continue }
            var value = formatted(raw, shape: attribute.shape)
            if case .all = wanted {
                let shortened = value.cut(at: QueryBudget.cut)
                value = shortened.value
                if shortened.cut { cut.append(attribute.name) }
            }
            listed[attribute.name] = value
        }
        return (listed, cut.isEmpty ? nil : cut)
    }
}

/// An evaluation's outcome, and what it cost.
struct Performed<Answer: Sendable>: Sendable {
    let outcome: Result<Answer, QueryError>
    let stats: Evaluation.Stats
}

extension PlanEdgeTypes {
    /// Whether an edge of `type` is one the word follows.
    func admits(_ type: EdgeTypeID) -> Bool { types?.contains(type) ?? true }

    /// Whether the edge is a connection the word follows: one its carrier has in slot "" (an arrow's
    /// own, not a mention in a text's slot) of a type it admits.
    func admitsConnection(_ edge: Edge) -> Bool { edge.slot.isEmpty && admits(edge.type) }
}

// MARK: Walking a plan

extension PlanList {
    /// Every node in it, each before those inside it.
    func forEachNode(_ body: (PlanNode) -> Void) {
        for item in items { item.forEachNode(body) }
    }

    /// The titles that name what its items match themselves (`"A"`, `"A"[x]`, `:is("A", "B")`), not
    /// what those are inside of or connected to.
    var subjectTitles: [PlanNodeID] {
        items.flatMap(\.subjectTitles)
    }
}

extension PlanNode {
    /// The titles that name what it matches itself: it, a title; the title of an `and` of one; an
    /// `:is`'s items'.
    var subjectTitles: [PlanNodeID] {
        switch op {
        case .title: [id]
        case .and(let nodes): nodes.flatMap { node -> [PlanNodeID] in
            switch node.op {
            case .title, .is: node.subjectTitles
            default: []
            }
        }
        case .is(let list): list.subjectTitles
        default: []
        }
    }
}

extension PlanNode {
    /// It, then every node inside it.
    func forEachNode(_ body: (PlanNode) -> Void) {
        body(self)
        switch op {
        case .not(let list), .is(let list), .inside(let list), .parentIn(let list), .ancestorIn(let list):
            list.forEachNode(body)
        case .has(let items):
            for item in items { item.node.forEachNode(body) }
        case .edges(_, let anchor, let second, _):
            anchor.forEachNode(body)
            second?.forEachNode(body)
        case .relation(_, let anchor, _, _), .fileRelation(_, let anchor):
            anchor.forEachNode(body)
        case .and(let nodes):
            for node in nodes { node.forEachNode(body) }
        case .all, .kinds, .title, .id, .attribute, .contains, .topLevel, .currentBoard, .dangling, .pseudo:
            break
        }
    }
}

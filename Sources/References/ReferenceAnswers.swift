import Canvas
import Observation
import Publishing
import Queries
import QueryLanguage
import TableOfContents
import Topology

// What a dynamic reference stands for: what its query finds, asked of the engine on the main
// actor's behalf and answered off it, and handed to Topology (`provide`), which forwards arrows into
// the pill to each shape it stands for. The answer is a function of the records alone (the query
// runs on the recorded view, with a plan that reads only the file), so the order references are
// answered in never matters and nothing is asked twice for one change.

/// How a query's answer went for a dynamic reference, as far as its last answer for the question
/// its record asks now says.
public enum ReferenceStatus: Equatable, Sendable {
    /// No engine to ask (`QueriesPlugin` isn't installed): it never finds anything.
    case unavailable
    /// Its words are being turned into a query (waiting for the person to stop typing, then the
    /// model's call): it stands for nothing yet.
    case interpreting
    /// Asked, or about to be, and not answered yet; `slow` once the answer has been out longer than
    /// `ReferenceStyle.findingDelay`, so a quick one never shows as being looked for.
    case finding(slow: Bool)
    /// What it found: the matches it was given, in file order, and how many there were in all.
    case answered(QueryMatches)
    /// The query was refused (a title no shape has, a word that reads what the person is doing):
    /// it stands for nothing, and this says why, in the engine's words.
    case refused(String)
    /// The answer didn't come: it can be asked again (`retry`).
    case failed(ReferenceFailure)
}

/// Why a dynamic reference's answer didn't come: the query ran too long, or its words weren't turned
/// into a query.
public enum ReferenceFailure: Equatable, Sendable {
    /// The query ran past the engine's deadline.
    case tooSlow
    /// There is no API key to ask the model with, or the one there was refused: Settings is where
    /// that's mended.
    case noKey
    case keyRejected
    /// The model failed in a way asking again may mend, in its own words ("Rate limited", "Can’t
    /// reach Anthropic", "Timed out").
    case model(String)
    /// The model declined, or said no query can ask that.
    case noQuery
    /// The model's query, and its second, were refused.
    case unusable

    /// What the Query section says of it.
    @MainActor public var message: String {
        switch self {
        case .tooSlow: ReferenceStyle.tooSlow
        case .noKey: ReferenceStyle.noKey
        case .keyRejected: ReferenceStyle.keyRejected
        case .model(let message): message
        case .noQuery: ReferenceStyle.noQuery
        case .unusable: ReferenceStyle.unusable
        }
    }

    /// What a person can do about it: Settings where a key is missing, else ask again.
    public var action: ReferenceStatusLine.Action { self == .noKey || self == .keyRejected ? .openSettings : .retry }
}

/// What ReferenceState keeps for each dynamic reference (one whose record holds a query), on any
/// board of the file.
struct Finding {
    /// The question its record asks now: its query and whether it wants every match.
    var key: ForwardingKey
    var all: Bool
    /// How the last answer to `key` went; nil while none has come (or after the key changed with no
    /// answer kept for the new one).
    var outcome: ReferenceStatus?
    /// The revision of the latest answer that landed, per key: one older than it is stale. Per key, so
    /// an older answer to the other question (an All toggled back) isn't taken for a stale one.
    var applied: [ForwardingKey: Int] = [:]
    /// The question a batch out asked for it, and the revision it was asked at.
    var asked: ForwardingKey?
    /// Whether its answer may be out of date: asked at the next batch.
    var dirty = true
}

/// What came back for one reference of a batch.
enum Landed {
    case matches(QueryMatches)
    /// Refused, in the engine's words (or the gate's): no matches.
    case refused(String)
    case failed(ReferenceFailure)
    /// Cancelled, or the file closing: asked again at the next batch, if there is one.
    case askAgain

    init(_ result: Result<QueryMatches, QueryError>) {
        switch result {
        case .success(let matches): self = .matches(matches)
        case .failure(let error):
            switch error.reason {
            case .tooSlow: self = .failed(.tooSlow)
            case .cancelled, .boardClosed: self = .askAgain
            default: self = .refused(error.message)
            }
        }
    }
}

/// One answer kept, per reference and key: what undo, redo and an All toggled back show at once.
struct RememberedAnswer {
    let key: ForwardingKey
    let matches: QueryMatches
}

/// What a reference's kept answers are: the last `ReferenceStyle.answersKept`, newest last, and when
/// the reference was last landed or used (`ReferenceState.memoClock`).
struct Memo {
    var answers: [RememberedAnswer] = []
    var used = 0
}

/// Which references' answers changed, for SwiftUI: reading a reference's revision observes it alone,
/// as Topology's per-shape revisions are observed.
@Observable
@MainActor
final class AnswerRevisions {
    @ObservationIgnored private var revisions: [ShapeID: Int] = [:]

    func read(_ id: ShapeID) -> Int {
        access(keyPath: \.[revision: id])
        return revisions[id] ?? 0
    }

    func bump(_ id: ShapeID) {
        withMutation(keyPath: \.[revision: id]) { revisions[id, default: 0] += 1 }
    }

    /// Only a key: one key path per reference.
    private subscript(revision id: ShapeID) -> Int { revisions[id] ?? 0 }
}

extension ReferenceState {
    /// The key Topology forwards a reference's provided answer under: its query and its flag, so
    /// either changing asks again (`standsIn`'s forwarding uses the same).
    public nonisolated static func key(query: String, all: Bool) -> ForwardingKey { ForwardingKey("\(query)\u{1F}\(all)") }

    // MARK: What a dynamic reference found

    /// How the query of the reference `id` was answered for the question its record asks now, observed
    /// (a SwiftUI view reading it draws again when it changes); nil for a reference with no query.
    public func status(of id: ShapeID) -> ReferenceStatus? {
        _ = answered.read(id)
        return answer(of: id)
    }

    /// The same, without observing it: what a render reads, for every dynamic pill in view.
    func answer(of id: ShapeID) -> ReferenceStatus? {
        guard let finding = dynamic[id] else { return interpretationStatus(of: id) }
        guard editor.queries != nil else { return .unavailable }
        return finding.outcome ?? .finding(slow: isSlow && finding.asked != nil)
    }

    /// The references with a query, on every board of the file.
    public var dynamicReferences: Set<ShapeID> { Set(dynamic.keys) }

    /// Whether answers are still on their way: a wait armed, a hop to answer at once, or a batch out.
    /// What Topology's settling asks (`keepsSettling`).
    public var isFinding: Bool { debounce != nil || hop != nil || batch != nil }

    /// Asks again (Retry, after the query ran too long, or the words weren't turned into a query).
    public func retry(_ id: ShapeID) {
        guard dynamic[id] != nil else { return retryInterpretation(id) }
        dynamic[id]?.dirty = true
        dynamic[id]?.outcome = nil
        answered.bump(id)
        answerSoon()
    }

    // MARK: Hearing commits

    /// Keeps the file's dynamic references from a commit, and says when to ask: a reference whose
    /// own question changed (its query or its flag, a gesture or an undo) at once, showing an answer
    /// kept for it first; any other change but moves after `ReferenceStyle.settle` of quiet, every
    /// dynamic reference. A commit that only moved shapes costs one test.
    /// (The test for a commit that only moved shapes is `documentDidChange`'s, before this.)
    /// `touched` is the references the commit touched, each once, as they are now
    /// (`referencesTouched(by:)`): any other shape it touched asks nothing of its own, and is one of
    /// the others.
    func hearDynamic(_ changes: ChangeSet, touched: [ShapeID: AnyShapeRecord?]) {
        if changes.replacedDocument { return rebuildDynamic() }
        var own: Set<ShapeID> = []
        for (id, record) in touched where noteDynamic(id, record) { own.insert(id) }
        // Each shape the commit names, as often as it names it, that isn't a reference whose own
        // question changed: a reference named twice is one of the others the second time.
        let named = changes.added.count + changes.changed.count - changes.moved.count + changes.removed.count + changes.elsewhere.count
        let others = changes.reordered || !changes.boardsAdded.isEmpty || !changes.boardsRemoved.isEmpty || named > own.count
        if !own.isEmpty { answerSoon() }
        if others, !dynamic.isEmpty {
            // Every one may be out of date: said once, so the commit costs O(1) however many there are.
            everyDirty = true
            armDebounce()
        }
    }

    /// Reads the reference `id` again (on any board): whether its own question changed (it has a
    /// query whose key isn't the one kept, or it came or went). A shape that isn't a reference with a
    /// query, and wasn't one, changed nothing of its own.
    private func noteDynamic(_ id: ShapeID, _ record: AnyShapeRecord?) -> Bool {
        let props = record?.typed(as: Reference.self)?.props
        guard let props, props.target == nil, let query = props.query else {
            guard dynamic.removeValue(forKey: id) != nil else { return false }
            answered.bump(id)
            return true
        }
        let key = Self.key(query: query, all: props.all)
        if dynamic[id]?.key == key { return false }
        var finding = dynamic[id] ?? Finding(key: key, all: props.all)
        finding.key = key
        finding.all = props.all
        finding.dirty = true
        finding.outcome = remembered(key, for: id).map { .answered($0.matches) }
        dynamic[id] = finding
        answered.bump(id)
        return true
    }

    /// Every dynamic reference of the file, read afresh (a file or board put in place), asked at once.
    func rebuildDynamic() {
        let before = Set(dynamic.keys)
        dynamic = [:]
        memo = [:]
        let file = editor.file
        func scan(_ document: CanvasDocument) {
            for record in document.shapes where record.kind == Reference.kind {
                guard let props = record.typed(as: Reference.self)?.props, props.target == nil, let query = props.query else { continue }
                dynamic[record.id] = Finding(key: Self.key(query: query, all: props.all), all: props.all)
            }
        }
        scan(file.root)
        for document in file.children.values { scan(document) }
        for id in before.union(dynamic.keys) { answered.bump(id) }
        if !dynamic.isEmpty { answerSoon() }
    }

    /// Editing ended: a reference held back while it was typed into is asked now.
    func editingEnded(_ id: ShapeID) {
        if dynamic[id]?.dirty == true { answerSoon() }
    }

    // MARK: When to ask

    /// Waits `ReferenceStyle.settle` of quiet (each commit waits again), then asks.
    private func armDebounce() {
        debounce?.cancel()
        debounce = editor.scheduler.schedule(after: ReferenceStyle.settle) { [weak self] in
            guard let self else { return }
            debounce = nil
            ask()
        }
    }

    /// A hop of the scheduler, then asks: never while a commit is being heard (Topology takes no
    /// answer then). Kept answers are shown first, in the hop.
    private func answerSoon() {
        guard hop == nil else { return }
        hop = editor.scheduler.schedule(after: .zero) { [weak self] in
            guard let self else { return }
            hop = nil
            provideRemembered()
            ask()
        }
    }

    /// Gives Topology the answers kept for the questions references ask now that it doesn't hold
    /// (an undo, a redo, an All toggled back): exempt from the stale rule, since each is what was
    /// answered for that very question, and asked again by the batch that follows.
    private func provideRemembered() {
        guard let topology = editor.topology else { return }
        var answers: [ShapeID: ProvidedForwarding] = [:]
        for (id, finding) in dynamic {
            guard case .answered(let matches)? = finding.outcome, topology.forwarding(of: id) == .pending else { continue }
            answers[id] = ProvidedForwarding(key: finding.key, shapes: stoodFor(matches, all: finding.all), revision: matches.revision)
        }
        if !answers.isEmpty { deliver(answers, changed: Set(answers.keys)) }
    }

    // MARK: Asking

    /// One batch for every dirty dynamic reference not being typed into, on one snapshot of the file:
    /// each asked on the recorded view (what direct references forward, never another's answer),
    /// admitting public shapes alone, first-match ones for eight (what All would add, for the panel),
    /// all-match ones for fifty. A query that can't be read, or reads what the person is doing,
    /// isn't asked: it's refused at once. A batch already out is let go of, and what it asked asked again.
    func ask() {
        debounce?.cancel()
        debounce = nil
        if let batch {
            batch.cancel()
            self.batch = nil
            for (id, finding) in dynamic where finding.asked != nil {
                dynamic[id]?.asked = nil
                dynamic[id]?.dirty = true
            }
        }
        guard let queries = editor.queries else {
            for id in dynamic.keys { dynamic[id]?.dirty = false }
            everyDirty = false
            settled()
            return
        }
        let editing = editor.editingShapeID
        let admitting = admission
        var asked: [(id: ShapeID, key: ForwardingKey)] = [], requests: [QueryMatchRequest] = []
        var refusals: [ShapeID: Landed] = [:]
        let every = everyDirty
        everyDirty = false
        if every, let editing, dynamic[editing] != nil { dynamic[editing]?.dirty = true }
        for (id, finding) in dynamic where (finding.dirty || every) && id != editing {
            dynamic[id]?.dirty = false
            // Topology takes no answer for a reference on a board the app can't show.
            guard let props = editor.shape(inFile: id)?.typed(as: Reference.self)?.props, let query = props.query else { continue }
            do throws(QueryError) {
                let plan = try queries.check(query)
                if let word = plan.editorWords.first {
                    refusals[id] = .refused(ReferenceStyle.cantBeUsed(word))
                    continue
                }
            } catch {
                refusals[id] = .refused(error.message)
                continue
            }
            asked.append((id, finding.key))
            dynamic[id]?.asked = finding.key
            requests.append(QueryMatchRequest(query, edges: .recorded, limit: finding.all ? ReferenceStyle.maxTargets : ReferenceStyle.firstFetched,
                                              admitting: admitting))
        }
        if !refusals.isEmpty { land(refusals.compactMap { id, refusal in dynamic[id].map { (id, $0.key, refusal) } }, revision: editor.revision) }
        guard !requests.isEmpty else { return settled() }
        let revision = editor.revision
        isSlow = false
        slowTimer?.cancel()
        slowTimer = editor.scheduler.schedule(after: ReferenceStyle.findingDelay) { [weak self] in
            guard let self, batch != nil else { return }
            slowTimer = nil
            isSlow = true
            for (id, finding) in dynamic where finding.asked != nil && finding.outcome == nil { answered.bump(id) }
        }
        batch = Task { [weak self, queries] in
            let results = await queries.matches(requests)
            guard !Task.isCancelled, let self else { return }
            batch = nil
            land(zip(asked, results).map { ($0.id, $0.key, Landed($1)) }, revision: revision)
            #if DEBUG
            batchesLanded += 1
            #endif
        }
        #if DEBUG
        batchesAsked += 1
        #endif
    }

    /// Whether a match may be stood for: a public shape (Publishing's, worked out once); none without it.
    var admission: @Sendable (AnyShapeRecord) -> Bool {
        if let publishing = editor.publishing { return publishing.admitting }
        return { _ in false }
    }

    /// No batch is out any more: waiters on Topology look again, as nothing may be provided to say so.
    private func settled() {
        slowTimer?.cancel()
        slowTimer = nil
        isSlow = false
        editor.topology?.settleSourceChanged()
    }

    // MARK: Landing

    /// Takes what a batch answered (or refused before asking, at `revision`): for each reference
    /// still asking the question it was asked (another key's answer is dropped), an answer no older
    /// than the latest that landed for that question (an older one is dropped), handed to Topology
    /// in one provide, kept as one of the last four answers of the reference, and told to the pill,
    /// the panel and the row. A refusal (a title or an id no shape has, a container that can't hold
    /// shapes, a query that can't be read or reads what the person is doing) is no matches, saying
    /// why; the deadline passing is a failure that can be retried; a query cancelled is asked again.
    private func land(_ results: [(id: ShapeID, key: ForwardingKey, landed: Landed)], revision: Int) {
        var answers: [ShapeID: ProvidedForwarding] = [:], changed: Set<ShapeID> = []
        for (id, key, landed) in results {
            guard var finding = dynamic[id], finding.key == key else { continue }
            if finding.asked == key { finding.asked = nil }
            let status: ReferenceStatus, found: QueryMatches
            switch landed {
            case .matches(let matches):
                (status, found) = (.answered(matches), matches)
            case .refused(let message):
                (status, found) = (.refused(message), QueryMatches(canonical: "", ids: [], count: 0, revision: revision))
            case .failed(let failure):
                finding.outcome = .failed(failure)
                dynamic[id] = finding
                changed.insert(id)
                continue
            case .askAgain:
                finding.dirty = true
                dynamic[id] = finding
                continue
            }
            if let applied = finding.applied[key], found.revision < applied {
                dynamic[id] = finding
                continue
            }
            finding.applied[key] = found.revision
            let before = finding.outcome
            finding.outcome = status
            dynamic[id] = finding
            if case .answered(let matches) = status { remember(RememberedAnswer(key: key, matches: matches), for: id) }
            answers[id] = ProvidedForwarding(key: key, shapes: stoodFor(found, all: finding.all), revision: found.revision)
            // Every commit asks every reference again: only an answer that says something new is told.
            if !Self.says(status, theSameAs: before) { changed.insert(id) }
        }
        if batch == nil {
            isSlow = false
            slowTimer?.cancel()
            slowTimer = nil
        }
        deliver(answers, changed: changed)
        if batch == nil { editor.topology?.settleSourceChanged() }
    }

    #if DEBUG
    /// Lands `matches` for the reference as a batch's answer to `key` would land (debug builds): for
    /// tests of what landing drops, which a batch alone can't be made to show.
    public func land(_ matches: QueryMatches, for id: ShapeID, key: ForwardingKey) {
        land([(id, key, .matches(matches))], revision: matches.revision)
    }
    #endif

    /// Whether two answers to one question say the same: the same matches and count (the revision
    /// they were taken at is no part of what a pill, a panel or a row shows).
    private static func says(_ status: ReferenceStatus, theSameAs other: ReferenceStatus?) -> Bool {
        guard let other else { return false }
        if case .answered(let now) = status, case .answered(let then) = other { return now.ids == then.ids && now.count == then.count }
        return status == other
    }

    /// What a reference stands for of what it found: the first match, or every one (up to fifty).
    private func stoodFor(_ matches: QueryMatches, all: Bool) -> [ShapeID] {
        all ? Array(matches.ids.prefix(ReferenceStyle.maxTargets)) : Array(matches.ids.prefix(1))
    }

    /// Hands answers to Topology, and tells the pills (drawn again), the panels (observed) and the
    /// table of contents' rows of `changed`.
    private func deliver(_ answers: [ShapeID: ProvidedForwarding], changed: Set<ShapeID>) {
        if !answers.isEmpty { editor.topology?.provide(answers) }
        guard !changed.isEmpty else { return }
        for id in changed { answered.bump(id) }
        editor.setNeedsDisplay()
        editor.contentsDidChange(for: changed)
    }

    // MARK: Kept answers

    private func remembered(_ key: ForwardingKey, for id: ShapeID) -> RememberedAnswer? {
        guard let answer = memo[id]?.answers.last(where: { $0.key == key }) else { return nil }
        memoClock += 1
        memo[id]?.used = memoClock
        return answer
    }

    /// Keeps `answer` as one of the last `ReferenceStyle.answersKept` of the reference, which is
    /// kept past its deletion (for its undo) but only among the `ReferenceStyle.memosKept` most
    /// recently landed or used: a reference made past that lets go of the least recent one's, so
    /// the memo never grows with every dynamic reference a session has made. A frame and a commit
    /// cost nothing of it; the scan is only when a reference is first remembered past the bound.
    private func remember(_ answer: RememberedAnswer, for id: ShapeID) {
        memoClock += 1
        let isNew = memo[id] == nil
        memo[id, default: Memo()].answers.removeAll { $0.key == answer.key }
        memo[id]?.answers.append(answer)
        if let count = memo[id]?.answers.count, count > ReferenceStyle.answersKept { memo[id]?.answers.removeFirst(count - ReferenceStyle.answersKept) }
        memo[id]?.used = memoClock
        if isNew, memo.count > ReferenceStyle.memosKept, let oldest = memo.min(by: { $0.value.used < $1.value.used })?.key { memo[oldest] = nil }
    }
}

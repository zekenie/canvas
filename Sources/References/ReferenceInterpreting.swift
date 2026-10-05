import AppKit
import Canvas
import LanguageModels
import Queries
import QueryLanguage
import QueryTranslation
import TableOfContents
import Topology

// What typed words become: a query, by the model, while the person types and after (design 7.3).
//
// Nothing here is in the document until the person's step has it. While a pill is typed into and the
// list over it holds only the words row, the words rest (`ReferenceStyle.interpretDelay` of quiet on
// `editor.scheduler`, every keystroke starting the wait again) and then `editor.queryTranslator` is
// asked to write a query for them (`.reference` context: a stored query, which reads only the file).
// Its answer is the reference's draft, which the panel shows (the query, its status and the matches
// it finds, by one extra `matches` request that provides nothing, so nothing is forwarded) and which
// the pill's editor writes into the editing step when the words are committed unchanged. A call still
// out when editing ends lands later as a step of its own, "Interpret", if the reference is still
// there with the same words and no query, and isn't read-only. Nothing translates on undo, redo,
// paste, `canvas draw` or open: only typing, a commit, the Interpret button and a retry ask.

/// What typing has made of one reference's words, kept apart from the document.
@MainActor
struct Interpretation {
    enum Stage {
        /// Words typed that the list still has shapes for: nothing's asked unless they're committed.
        case typed
        /// Only the words row is left: waiting for the text to rest.
        case resting
        /// The model's call is out.
        case translating
        /// A query for the words came while the pill was typed into: the draft.
        case drafted
        /// It didn't come (or there's nothing to ask).
        case failed(ReferenceStatus)
    }

    /// The query a draft holds, and how it was answered (nil until the one extra request lands).
    struct Draft {
        var query: String
        var outcome: ReferenceStatus?
    }

    /// The words, with the white space at their ends taken off: what's asked, and what the record's
    /// words must still be for an answer to land.
    var words: String
    var stage: Stage
    /// Which asking this is: an answer, or a wait ending, for another is dropped.
    var generation: Int
    var timer: ScheduledTask?
    var task: Task<Void, Never>?
    var evaluation: Task<Void, Never>?
    var draft: Draft?

    init(words: String, stage: Stage, generation: Int) {
        self.words = words
        self.stage = stage
        self.generation = generation
    }

    @MainActor func cancelWork() {
        timer?.cancel()
        task?.cancel()
        evaluation?.cancel()
    }
}

extension ReferenceState {
    // MARK: What it shows

    /// The status of words with no query: interpreting while they rest and while the model is asked,
    /// what the draft's query found while there is one, or what went wrong; nil for words nobody
    /// asked about.
    func interpretationStatus(of id: ShapeID) -> ReferenceStatus? {
        guard let entry = interpretations[id] else { return nil }
        if let draft = entry.draft { return draft.outcome ?? .finding(slow: false) }
        switch entry.stage {
        case .typed, .drafted: return nil
        case .resting, .translating: return .interpreting
        case .failed(let status): return status
        }
    }

    /// The reference as its panel, row and header read it: its props, and, while its words have a
    /// draft, the draft's query, which the document doesn't have.
    func shown(_ props: Reference, id: ShapeID?) -> Reference {
        guard let id, props.target == nil, props.query == nil, let entry = interpretations[id], let draft = entry.draft,
              entry.words == props.words.trimmingCharacters(in: .whitespacesAndNewlines) else { return props }
        var shown = props
        shown.query = draft.query
        return shown
    }

    /// The query the draft of the reference holds for exactly these words, if it has landed: what
    /// committing them writes in the editing step, with no second call.
    func draftQuery(for id: ShapeID, words: String) -> String? {
        guard let entry = interpretations[id], let draft = entry.draft,
              entry.words == words.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return draft.query
    }

    /// Whether the words are being interpreted, so the Query section says so rather than offering to.
    func isInterpreting(_ id: ShapeID) -> Bool {
        if case .interpreting? = interpretationStatus(of: id) { return true }
        return false
    }

    // MARK: Typing

    /// The field of the reference `id` was opened: what was asked of its words before is let go of.
    func editingBegan(_ id: ShapeID) {
        drop(id)
        answered.bump(id)
    }

    /// The text of the field changed (after the editing step wrote it). Whatever was asked of the
    /// words before is let go of, the draft with it. `interprets` is whether the list holds only the
    /// words row and the text isn't what the field opened with: text that reads as a query is that
    /// query at once (a draft, with no model asked); else the text rests, and the model is asked
    /// when it has rested. Text the list still has shapes for is kept, to be interpreted if it's
    /// committed.
    func typed(_ text: String, in id: ShapeID, interprets: Bool) {
        let before = interpretationStatus(of: id), hadDraft = interpretations[id]?.draft != nil
        drop(id)
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else {
            if before != nil || hadDraft { tell(id) }
            return
        }
        interpretations[id] = Interpretation(words: words, stage: .typed, generation: nextGeneration())
        if interprets, let queries = editor.queries {
            if let plan = try? queries.check(words) {
                interpretations[id]?.stage = .drafted
                interpretations[id]?.draft = Interpretation.Draft(query: plan.canonical, outcome: nil)
                evaluateDraft(of: id)
            } else if editor.queryTranslator != nil {
                let generation = interpretations[id]?.generation ?? 0
                interpretations[id]?.stage = .resting
                interpretations[id]?.timer = editor.scheduler.schedule(after: ReferenceStyle.interpretDelay) { [weak self] in
                    self?.hasRested(id, generation: generation)
                }
            }
        }
        if before != interpretationStatus(of: id) || hadDraft || interpretations[id]?.draft != nil { tell(id) }
    }

    /// Words committed with ⌥Return or the words row, though the list still had shapes for them: they
    /// are to be interpreted when editing ends.
    func committed(words: String, of id: ShapeID) {
        let words = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, interpretations[id]?.words != words, isWordsWithNoQuery(id, words: words) else { return }
        drop(id)
        interpretations[id] = Interpretation(words: words, stage: .typed, generation: nextGeneration())
    }

    private func hasRested(_ id: ShapeID, generation: Int) {
        guard interpretations[id]?.generation == generation, case .resting? = interpretations[id]?.stage else { return }
        interpretations[id]?.timer = nil
        startTranslation(of: id)
    }

    // MARK: Asking

    private func nextGeneration() -> Int {
        lastGeneration += 1
        return lastGeneration
    }

    /// Asks the model for a query for the words of `id`: the call is out, `.interpreting`.
    private func startTranslation(of id: ShapeID) {
        guard var entry = interpretations[id] else { return }
        // Nothing to ask with: the words stay words (no translator is installed).
        guard let translator = editor.queryTranslator else { return drop(id) }
        entry.cancelWork()
        entry.timer = nil
        entry.draft = nil
        entry.stage = .translating
        entry.generation = nextGeneration()
        let generation = entry.generation, words = entry.words
        entry.task = Task { @MainActor [weak self] in
            let result: Result<TranslatedQuery, QueryTranslationError>
            do throws(QueryTranslationError) {
                result = .success(try await translator.translate(words, about: .reference))
            } catch {
                result = .failure(error)
            }
            self?.translationEnded(id, generation: generation, result)
        }
        interpretations[id] = entry
        tell(id)
    }

    /// What the model's call came to, if it's still the one asked for (the words unchanged, not
    /// cancelled by a keystroke, a new edit or a deletion).
    private func translationEnded(_ id: ShapeID, generation: Int, _ result: Result<TranslatedQuery, QueryTranslationError>) {
        guard var entry = interpretations[id], entry.generation == generation else { return }
        entry.task = nil
        switch result {
        case .failure(let error):
            guard let status = Self.status(of: error) else {
                interpretations[id] = nil
                tell(id)
                return
            }
            entry.stage = .failed(status)
            interpretations[id] = entry
            tell(id)
        case .success(let translated):
            if editor.editingShapeID == id {
                entry.stage = .drafted
                entry.draft = Interpretation.Draft(query: translated.query, outcome: nil)
                interpretations[id] = entry
                evaluateDraft(of: id)
                tell(id)
            } else {
                land(translated.query, for: id, words: entry.words)
            }
        }
    }

    /// How a translation failed, as the reference shows it; nil for a cancellation, which says nothing.
    static func status(of error: QueryTranslationError) -> ReferenceStatus? {
        switch error {
        case .cancelled: nil
        case .noQueries, .noModel: .unavailable
        case .model(.noKey, _): .failed(.noKey)
        case .model(.unauthorized, _): .failed(.keyRejected)
        case .model(let error, _): .failed(.model(error.message))
        case .declined, .unanswerable: .failed(.noQuery)
        case .unusable, .refused: .failed(.unusable)
        case .tooSlow: .failed(.model(LanguageModelError.timedOut.message))
        }
    }

    // MARK: The draft's matches

    /// One request for the draft's query, `matches` that forwards nothing: what the panel lists.
    private func evaluateDraft(of id: ShapeID) {
        guard var entry = interpretations[id], let draft = entry.draft, let queries = editor.queries else { return }
        entry.evaluation?.cancel()
        do throws(QueryError) {
            let plan = try queries.check(draft.query)
            if let word = plan.editorWords.first { throw QueryTranslator.refusal(forEditorWord: word) }
        } catch {
            entry.draft?.outcome = .refused(error.message)
            interpretations[id] = entry
            return
        }
        let all = editor.shape(inFile: id)?.typed(as: Reference.self)?.props.all ?? false
        let request = QueryMatchRequest(draft.query, edges: .recorded, limit: all ? ReferenceStyle.maxTargets : ReferenceStyle.firstFetched,
                                        admitting: admission)
        let generation = entry.generation, query = draft.query
        entry.evaluation = Task { @MainActor [weak self] in
            let results = await queries.matches([request])
            guard !Task.isCancelled, let result = results.first else { return }
            self?.draftEvaluated(id, generation: generation, query: query, result)
        }
        interpretations[id] = entry
    }

    private func draftEvaluated(_ id: ShapeID, generation: Int, query: String, _ result: Result<QueryMatches, QueryError>) {
        guard interpretations[id]?.generation == generation, interpretations[id]?.draft?.query == query else { return }
        interpretations[id]?.evaluation = nil
        switch Landed(result) {
        case .matches(let matches): interpretations[id]?.draft?.outcome = .answered(matches)
        case .refused(let message): interpretations[id]?.draft?.outcome = .refused(message)
        case .failed(let failure): interpretations[id]?.draft?.outcome = .failed(failure)
        case .askAgain: return
        }
        tell(id)
    }

    // MARK: Landing

    /// Writes the query of words the model made after editing ended, as a step of its own, on the
    /// reference's board: if the reference is still there with these words and no query, and can be
    /// changed. A locked one (itself, or by its frame) is let be, with no step and no shake; its
    /// words are not interpreted, and Interpret is offered once it's unlocked.
    private func land(_ query: String, for id: ShapeID, words: String) {
        drop(id)
        defer { tell(id) }
        let file = editor.file
        guard let record = file.record(id), let props = record.typed(as: Reference.self)?.props, props.target == nil, props.query == nil,
              props.words.trimmingCharacters(in: .whitespacesAndNewlines) == words, let board = file.board(containing: id),
              !editor.registry.isReadOnly(record, in: editor.contents(of: board)) else { return }
        editor.transact(on: board, ReferenceStyle.interpretStep) { transaction in
            transaction.update(id, as: Reference.self) { ReferenceEdits.find(&$0.props, words: props.words, query: query) }
        }
    }

    // MARK: Editing ends

    /// Editing the field ended: what the document has now is the words (or a pick, or nothing). On
    /// the next turn of the scheduler (not inside the end of editing, which an undo can be the cause
    /// of, before the words it ended on are gone): words typed or committed are asked about, a call
    /// still out is let be, and a draft that wasn't written is.
    func interpretationEditingEnded(_ id: ShapeID) {
        // Every shape's editing ends here; only a reference's has anything to say.
        guard editor.file.record(id)?.kind == Reference.kind else { return }
        answered.bump(id)
        guard let entry = interpretations[id] else { return }
        let generation = entry.generation
        _ = editor.scheduler.schedule(after: .zero) { [weak self] in self?.finishAfterEditing(id, generation: generation) }
    }

    /// Whether the reference is words with no query, and these.
    private func isWordsWithNoQuery(_ id: ShapeID, words: String) -> Bool {
        guard let props = editor.file.record(id)?.typed(as: Reference.self)?.props else { return false }
        return props.target == nil && props.query == nil && props.words.trimmingCharacters(in: .whitespacesAndNewlines) == words
    }

    private func finishAfterEditing(_ id: ShapeID, generation: Int) {
        guard let entry = interpretations[id], entry.generation == generation, editor.editingShapeID != id,
              isWordsWithNoQuery(id, words: entry.words) else { return }
        switch entry.stage {
        case .typed, .resting:
            startTranslation(of: id)
        case .drafted:
            if let draft = entry.draft { land(draft.query, for: id, words: entry.words) }
        case .translating, .failed:
            break
        }
    }

    // MARK: Interpret and Retry

    /// Whether Interpret may be performed on `ids`: the one reference with words and no query, nobody
    /// asking about them, something to ask with, nothing being typed, and nothing locked.
    func canInterpret(_ ids: Set<ShapeID>) -> Bool {
        guard ids.count == 1, let id = ids.first else { return false }
        return canInterpret(id)
    }

    func canInterpret(_ id: ShapeID) -> Bool {
        guard offersInterpret(id), let record = editor.file.record(id), let board = editor.file.board(containing: id) else { return false }
        return !editor.registry.isReadOnly(record, in: editor.contents(of: board))
    }

    /// Whether the panel shows its Interpret row (dimmed while the reference is locked): words and no
    /// query that nobody is asking about, with something to ask with, and not being typed into.
    func offersInterpret(_ id: ShapeID) -> Bool {
        guard editor.queryTranslator != nil, editor.editingShapeID != id, !isInterpreting(id),
              let props = editor.file.record(id)?.typed(as: Reference.self)?.props, props.mode == .dynamic, props.target == nil,
              props.query == nil, !props.words.allSatisfy(\.isWhitespace) else { return false }
        return true
    }

    /// Asks the model to turn the reference's words into a query (the panel's Interpret): it lands as
    /// the step "Interpret" if the words are still the same.
    public func interpret(_ id: ShapeID) {
        guard canInterpret(id), let props = editor.file.record(id)?.typed(as: Reference.self)?.props else { return }
        drop(id)
        interpretations[id] = Interpretation(words: props.words.trimmingCharacters(in: .whitespacesAndNewlines), stage: .typed,
                                             generation: nextGeneration())
        startTranslation(of: id)
    }

    func interpret(only ids: Set<ShapeID>) {
        guard ids.count == 1, let id = ids.first else { return }
        interpret(id)
    }

    /// Asks again after a failure: live while the pill is typed into, else as Interpret does.
    func retryInterpretation(_ id: ShapeID) {
        guard case .failed? = interpretations[id]?.stage else { return }
        if editor.editingShapeID == id {
            startTranslation(of: id)
        } else {
            interpret(id)
        }
    }

    /// A key was saved or removed in Settings: the words that failed for want of one try again.
    func keyDidChange() {
        let waiting = interpretations.compactMap { id, entry -> ShapeID? in
            if case .failed(.failed(let failure)) = entry.stage, failure == .noKey || failure == .keyRejected { return id }
            return nil
        }
        for id in waiting { retryInterpretation(id) }
    }

    // MARK: Hearing commits

    /// What a commit did to the words being interpreted: asked about no longer when the reference is
    /// gone, stands for a shape, has a query, or has other words (an undo, a keystroke, a pick), whose
    /// call is cancelled and draft let go of. Nothing is asked here, and nothing transacts.
    func hearInterpretations(_ changes: ChangeSet) {
        if changes.replacedDocument { return dropInterpretations() }
        guard !interpretations.isEmpty else { return }
        func hear(_ id: ShapeID) {
            guard let entry = interpretations[id] else { return }
            if let props = editor.file.record(id)?.typed(as: Reference.self)?.props, props.target == nil, props.query == nil,
               props.words.trimmingCharacters(in: .whitespacesAndNewlines) == entry.words { return }
            drop(id)
            answered.bump(id)
        }
        for id in changes.added { hear(id) }
        for id in changes.changed where !changes.moved.contains(id) { hear(id) }
        for id in changes.removed { hear(id) }
        for id in changes.elsewhere { hear(id) }
    }

    /// A file put in place: nothing asked about is still there.
    func dropInterpretations() {
        for entry in interpretations.values { entry.cancelWork() }
        interpretations = [:]
    }

    /// Lets go of everything asked about `id`: its wait, its call and its draft's request.
    func drop(_ id: ShapeID) {
        interpretations.removeValue(forKey: id)?.cancelWork()
    }

    /// The pill, the panel and the table of contents' row show what's asked of the words now.
    private func tell(_ id: ShapeID) {
        answered.bump(id)
        editor.setNeedsDisplay()
        editor.contentsDidChange(for: [id])
    }
}

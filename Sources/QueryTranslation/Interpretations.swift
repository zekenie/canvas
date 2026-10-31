import Canvas
import Foundation
import LanguageModels
import Queries
import QueryLanguage

// What typed words become: a query, by the model, while a person types them and after, one piece for every host of
// words that find shapes (a reference's pill, a rule's chips: `editor.interpretations`).
//
// Nothing here is in the document until the host's step has it. While the words are typed and the host says nothing
// else they could be is left (a reference's list holds only its words row), they rest (`restDelay` of quiet on
// `editor.scheduler`, every keystroke starting the wait again) and then `editor.queryTranslator` is asked to write a
// query for them, in the context the host says. Its answer is a draft, which the host shows (the query, and what it
// finds by one extra `matches` request of the host's, which provides nothing) and writes into its own step when the
// words are committed unchanged. A call still out when editing ends lands later as a step of the host's, if the words
// are still there and still words. Nothing is asked on undo, redo, paste, `canvas draw` or open: only typing, a
// commit, the host's Interpret and a retry ask; a sign-in in Settings asks again what wanted one.

/// Which words, on which shape: a shape may hold several (a rule's chips, slot by slot).
public struct InterpretationKey: Hashable, Sendable {
    public let shape: ShapeID
    /// Which of the shape's words: the host's own name for them.
    public let slot: String

    public init(shape: ShapeID, slot: String) {
        self.shape = shape
        self.slot = slot
    }
}

/// What a host of words that become a query decides, the rest being the lifecycle's own.
@MainActor
public protocol InterpretationHost: AnyObject {
    /// The context its words are translated in: a reference's is a stored query.
    func context(of key: InterpretationKey) -> TranslationContext
    /// Whether the shape still holds these words, with no query: what an answer needs to land.
    func holdsWords(_ words: String, at key: InterpretationKey) -> Bool
    /// The request a draft's query is asked to find with, what the host lists of a draft; nil asks nothing.
    func request(for query: String, at key: InterpretationKey) -> QueryMatchRequest?
    /// Writes the query that came for these words after editing ended, as a step of its own (or not at all: a shape
    /// that can't change is let be).
    func land(_ query: String, words: String, at key: InterpretationKey)
    /// Asks afresh, as the host's Interpret does: a retry while the shape isn't being edited.
    func interpretAgain(at key: InterpretationKey)
    /// What's asked of the words, or what came of it, changed: the host shows it.
    func interpretationDidChange(at key: InterpretationKey)
    /// Whether the words are being typed into, so an answer is a draft and lands only once editing ends: nil asks the
    /// editor (the shape of the key is the one edited on the canvas), what a host whose words are typed elsewhere (a
    /// rule's box in the panel) says itself.
    func isEditing(at key: InterpretationKey) -> Bool?
}

extension InterpretationHost {
    public func isEditing(at _: InterpretationKey) -> Bool? { nil }
}

/// What's asked of a host's words now.
public enum InterpretationState {
    /// Words kept, nothing asked: they're asked about if they're committed, or once editing ends.
    case waiting
    /// Resting before the model is asked, or the model's call is out.
    case interpreting
    /// A query for the words, and what it found once asked (nil until then; a query the gate for stored queries
    /// refuses is a failure with its refusal).
    case drafted(query: String, found: Result<QueryMatches, QueryError>?)
    /// It didn't come: why, in the one set of words every host says.
    case failed(InterpretationStatus)
}

/// The words being turned into queries, and what's come of them: `editor.interpretations`.
@MainActor
public final class Interpretations {
    /// How long typed words rest before the model is asked.
    public static let restDelay: Duration = .milliseconds(600)

    private struct Entry {
        enum Stage {
            /// Words the host still has something else for: nothing's asked unless they're committed.
            case typed
            /// Waiting for the text to rest.
            case resting
            /// The model's call is out.
            case translating
            /// A query for the words came while the shape was edited: the draft.
            case drafted
            /// It didn't come.
            case failed(InterpretationStatus)
        }

        struct Draft {
            var query: String
            var found: Result<QueryMatches, QueryError>?
        }

        /// The words, with the white space at their ends taken off: what's asked, and what the host's words must
        /// still be for an answer to land.
        var words: String
        var stage: Stage
        /// Which asking this is: an answer, or a wait ending, for another is dropped.
        var generation: Int
        weak var host: (any InterpretationHost)?
        var timer: ScheduledTask?
        var task: Task<Void, Never>?
        var evaluation: Task<Void, Never>?
        var draft: Draft?

        @MainActor func cancelWork() {
            timer?.cancel()
            task?.cancel()
            evaluation?.cancel()
        }
    }

    private weak var editor: CanvasEditor?
    private var entries: [InterpretationKey: Entry] = [:]
    private var lastGeneration = 0
    nonisolated(unsafe) private var keyObserver: (any NSObjectProtocol)?

    init(editor: CanvasEditor) {
        self.editor = editor
        keyObserver = NotificationCenter.default.addObserver(forName: .languageModelSignInDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keyDidChange() }
        }
    }

    /// The editor going (a file closed) cancels everything out for it: each wait, call and draft request.
    isolated deinit {
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        for entry in entries.values { entry.cancelWork() }
    }

    // MARK: What's asked

    /// What's asked of the words at `key` now; nil for words nobody asked about.
    public func state(at key: InterpretationKey) -> InterpretationState? {
        guard let entry = entries[key] else { return nil }
        if let draft = entry.draft { return .drafted(query: draft.query, found: draft.found) }
        switch entry.stage {
        case .typed, .drafted: return .waiting
        case .resting, .translating: return .interpreting
        case .failed(let status): return .failed(status)
        }
    }

    /// The words asked about at `key`, as asked (trimmed).
    public func words(at key: InterpretationKey) -> String? { entries[key]?.words }

    /// The draft's query for exactly these words, if it has landed: what committing them writes, with no second call.
    public func draftQuery(at key: InterpretationKey, words: String) -> String? {
        guard let entry = entries[key], let draft = entry.draft, entry.words == Self.trimmed(words) else { return nil }
        return draft.query
    }

    /// Whether the model is being asked, or the words rest before it is.
    public func isInterpreting(_ key: InterpretationKey) -> Bool {
        if case .interpreting? = state(at: key) { return true }
        return false
    }

    /// Whether nothing is asked of any words.
    public var isEmpty: Bool { entries.isEmpty }

    // MARK: Typing

    /// The words at `key` changed (after the host's step wrote them). Whatever was asked before is let go of, the
    /// draft with it. `interprets` is whether the host has nothing else for them (a reference's list holds only its
    /// words row): words that read as a query are that query at once (a draft, no model asked); else they rest, and
    /// the model is asked when they have. Words the host still has something else for are kept, to be asked about if
    /// they're committed.
    public func typed(_ text: String, at key: InterpretationKey, interprets: Bool, host: any InterpretationHost) {
        let before = phase(at: key), hadDraft = entries[key]?.draft != nil
        drop(key)
        let words = Self.trimmed(text)
        guard !words.isEmpty else {
            if before != .quiet || hadDraft { host.interpretationDidChange(at: key) }
            return
        }
        var entry = Entry(words: words, stage: .typed, generation: nextGeneration())
        entry.host = host
        entries[key] = entry
        if interprets, let editor, let queries = editor.queries {
            if let plan = try? queries.check(words) {
                entries[key]?.stage = .drafted
                entries[key]?.draft = Entry.Draft(query: plan.canonical, found: nil)
                evaluateDraft(at: key)
            } else if editor.queryTranslator != nil {
                let generation = entry.generation
                entries[key]?.stage = .resting
                entries[key]?.timer = editor.scheduler.schedule(after: Self.restDelay) { [weak self] in
                    self?.hasRested(key, generation: generation)
                }
            }
        }
        if before != phase(at: key) || hadDraft || entries[key]?.draft != nil { host.interpretationDidChange(at: key) }
    }

    /// Words committed though the host still had something else for them: asked about when editing ends.
    public func committed(words: String, at key: InterpretationKey, host: any InterpretationHost) {
        let words = Self.trimmed(words)
        guard !words.isEmpty, entries[key]?.words != words, host.holdsWords(words, at: key) else { return }
        drop(key)
        var entry = Entry(words: words, stage: .typed, generation: nextGeneration())
        entry.host = host
        entries[key] = entry
    }

    /// Asks the model for a query for `words` now (the host's Interpret): it lands as the host's step, if the words
    /// are still the same.
    public func interpret(_ words: String, at key: InterpretationKey, host: any InterpretationHost) {
        drop(key)
        var entry = Entry(words: Self.trimmed(words), stage: .typed, generation: nextGeneration())
        entry.host = host
        entries[key] = entry
        startTranslation(at: key)
    }

    private func hasRested(_ key: InterpretationKey, generation: Int) {
        guard entries[key]?.generation == generation, case .resting? = entries[key]?.stage else { return }
        entries[key]?.timer = nil
        startTranslation(at: key)
    }

    // MARK: Asking

    private func nextGeneration() -> Int {
        lastGeneration += 1
        return lastGeneration
    }

    /// Asks the model for a query for the words at `key`: the call is out, interpreting.
    private func startTranslation(at key: InterpretationKey) {
        guard var entry = entries[key], let host = entry.host else { return }
        // Nothing to ask with: the words stay words (no translator is installed).
        guard let translator = editor?.queryTranslator else { return drop(key) }
        entry.cancelWork()
        entry.timer = nil
        entry.draft = nil
        entry.stage = .translating
        entry.generation = nextGeneration()
        let generation = entry.generation, words = entry.words, context = host.context(of: key)
        entry.task = Task { @MainActor [weak self] in
            let result: Result<TranslatedQuery, QueryTranslationError>
            do throws(QueryTranslationError) {
                result = .success(try await translator.translate(words, about: context))
            } catch {
                result = .failure(error)
            }
            self?.translationEnded(key, generation: generation, result)
        }
        entries[key] = entry
        host.interpretationDidChange(at: key)
    }

    /// What the model's call came to, if it's still the one asked for (the words unchanged, not cancelled by a
    /// keystroke, a new edit or a deletion).
    private func translationEnded(_ key: InterpretationKey, generation: Int, _ result: Result<TranslatedQuery, QueryTranslationError>) {
        guard var entry = entries[key], entry.generation == generation, let host = entry.host else { return }
        entry.task = nil
        switch result {
        case .failure(let error):
            guard let status = InterpretationStatus(error) else {
                entries[key] = nil
                host.interpretationDidChange(at: key)
                return
            }
            entry.stage = .failed(status)
            entries[key] = entry
            host.interpretationDidChange(at: key)
        case .success(let translated):
            if isEditing(key, host: host) {
                entry.stage = .drafted
                entry.draft = Entry.Draft(query: translated.query, found: nil)
                entries[key] = entry
                evaluateDraft(at: key)
                host.interpretationDidChange(at: key)
            } else {
                land(translated.query, at: key, words: entry.words)
            }
        }
    }

    // MARK: The draft's matches

    /// One request for the draft's query, the host's, which provides nothing: what the host lists of a draft. A query
    /// the gate for stored queries refuses is answered with its refusal, and asks nothing.
    private func evaluateDraft(at key: InterpretationKey) {
        guard var entry = entries[key], let draft = entry.draft, let queries = editor?.queries, let host = entry.host else { return }
        entry.evaluation?.cancel()
        do throws(QueryError) {
            _ = try queries.checkStored(draft.query)
        } catch {
            entry.draft?.found = .failure(error)
            entries[key] = entry
            return
        }
        guard let request = host.request(for: draft.query, at: key) else {
            entries[key] = entry
            return
        }
        let generation = entry.generation, query = draft.query
        entry.evaluation = Task { @MainActor [weak self] in
            let results = await queries.matches([request])
            guard !Task.isCancelled, let result = results.first else { return }
            self?.draftEvaluated(key, generation: generation, query: query, result)
        }
        entries[key] = entry
    }

    private func draftEvaluated(_ key: InterpretationKey, generation: Int, query: String, _ result: Result<QueryMatches, QueryError>) {
        guard entries[key]?.generation == generation, entries[key]?.draft?.query == query else { return }
        entries[key]?.evaluation = nil
        // Cancelled, or the file closing: nothing to say, as a batch that would ask again says nothing.
        if case .failure(let error) = result, error.reason == .cancelled || error.reason == .boardClosed { return }
        entries[key]?.draft?.found = result
        entries[key]?.host?.interpretationDidChange(at: key)
    }

    // MARK: Landing

    /// Hands the host the query of words the model made after editing ended, to write as a step of its own.
    private func land(_ query: String, at key: InterpretationKey, words: String) {
        let host = entries[key]?.host
        drop(key)
        defer { host?.interpretationDidChange(at: key) }
        host?.land(query, words: words, at: key)
    }

    // MARK: Editing ends

    /// Editing the shape of `key` ended: on the next turn of the scheduler (not inside the end of editing, which an
    /// undo can be the cause of, before the words it ended on are gone), words typed or committed are asked about, a
    /// call still out is let be, and a draft that wasn't written lands.
    public func editingEnded(at key: InterpretationKey) {
        guard let editor, let entry = entries[key] else { return }
        let generation = entry.generation
        _ = editor.scheduler.schedule(after: .zero) { [weak self] in self?.finishAfterEditing(key, generation: generation) }
    }

    private func finishAfterEditing(_ key: InterpretationKey, generation: Int) {
        guard let entry = entries[key], entry.generation == generation, let host = entry.host, !isEditing(key, host: host),
              host.holdsWords(entry.words, at: key) else { return }
        switch entry.stage {
        case .typed, .resting:
            startTranslation(at: key)
        case .drafted:
            if let draft = entry.draft { land(draft.query, at: key, words: entry.words) }
        case .translating, .failed:
            break
        }
    }

    // MARK: Retry

    /// Asks again after a failure: live while the shape is edited, else as the host's Interpret does.
    public func retry(at key: InterpretationKey) {
        guard let entry = entries[key], case .failed = entry.stage else { return }
        if let host = entry.host, isEditing(key, host: host) {
            startTranslation(at: key)
        } else {
            entry.host?.interpretAgain(at: key)
        }
    }

    /// A key was saved or removed in Settings: the words that failed for want of one try again.
    private func keyDidChange() {
        let waiting = entries.compactMap { key, entry -> InterpretationKey? in
            if case .failed(let status) = entry.stage, status == .notSignedIn || status == .keyRejected { return key }
            return nil
        }
        for key in waiting { retry(at: key) }
    }

    /// Whether the words at `key` are being typed into: as their host says, else whether the editor edits their shape.
    private func isEditing(_ key: InterpretationKey, host: any InterpretationHost) -> Bool {
        host.isEditing(at: key) ?? (editor?.editingShapeID == key.shape)
    }

    // MARK: Letting go

    /// Lets go of everything asked of the words at `key`: its wait, its call and its draft's request.
    public func drop(_ key: InterpretationKey) {
        entries.removeValue(forKey: key)?.cancelWork()
    }

    /// Lets go of what's asked of every key `where` says.
    public func dropAll(where shouldDrop: (InterpretationKey) -> Bool = { _ in true }) {
        for key in entries.keys where shouldDrop(key) { drop(key) }
    }

    // MARK: Phases

    /// How what's asked reads from outside, roughly: what typing compares to say whether anything changed.
    private enum Phase: Equatable {
        case quiet, interpreting, drafted, failed(InterpretationStatus)
    }

    private func phase(at key: InterpretationKey) -> Phase {
        switch state(at: key) {
        case nil, .waiting?: .quiet
        case .interpreting?: .interpreting
        case .drafted?: .drafted
        case .failed(let status)?: .failed(status)
        }
    }

    private static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension Interpretations: EditorService {
    /// A file put in place: nothing asked about is still there.
    public func documentDidChange(_ changes: ChangeSet, in _: CanvasEditor) {
        if changes.replacedDocument { dropAll() }
    }

    public func boardDidChange(_ change: BoardChange, in _: CanvasEditor) {
        if change.isFileReplaced { dropAll() }
    }
}

extension CanvasEditor {
    /// The words being turned into queries: nil without QueryTranslationPlugin.
    public var interpretations: Interpretations? { service(Interpretations.self) }
}

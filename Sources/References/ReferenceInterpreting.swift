import AppKit
import Canvas
import LanguageModels
import Queries
import QueryLanguage
import QueryTranslation
import TableOfContents
import Topology

// What typed words become: a query, by the model, while the person types and after (design 7.3), through the one
// piece every host of words shares (`editor.interpretations`, QueryTranslation's). A reference is its host: its
// words are the pill's (`InterpretationKey(shape:slot:)`, slot `reference`), translated as a stored query (which reads
// only the file), a draft's matches asked as the pill's are, and what comes after editing ends landed as a step of its
// own, "Interpret", if the reference is still there with the same words and no query, and isn't read-only. Nothing
// translates on undo, redo, paste, `canvas draw` or open: only typing, a commit, the Interpret button and a retry ask.

extension ReferenceState {
    /// The slot a reference's words are kept under.
    static let interpretationSlot = "reference"

    /// The key of a reference's words.
    func interpretationKey(_ id: ShapeID) -> InterpretationKey { InterpretationKey(shape: id, slot: Self.interpretationSlot) }

    // MARK: What it shows

    /// The status of words with no query: interpreting while they rest and while the model is asked,
    /// what the draft's query found while there is one, or what went wrong; nil for words nobody
    /// asked about.
    func interpretationStatus(of id: ShapeID) -> ReferenceStatus? {
        switch editor.interpretations?.state(at: interpretationKey(id)) {
        case nil, .waiting?: return nil
        case .interpreting?: return .interpreting
        case .drafted(_, let found)?:
            guard let found else { return .finding(slow: false) }
            switch Landed(found) {
            case .matches(let matches): return .answered(matches)
            case .refused(let message): return .refused(message)
            case .failed(let failure): return .failed(failure)
            case .askAgain: return .finding(slow: false)
            }
        case .failed(let status)?: return ReferenceStatus(status)
        }
    }

    /// The reference as its panel, row and header read it: its props, and, while its words have a
    /// draft, the draft's query, which the document doesn't have.
    func shown(_ props: Reference, id: ShapeID?) -> Reference {
        guard let id, props.target == nil, props.query == nil,
              let query = editor.interpretations?.draftQuery(at: interpretationKey(id), words: props.words) else { return props }
        var shown = props
        shown.query = query
        return shown
    }

    /// The query the draft of the reference holds for exactly these words, if it has landed: what
    /// committing them writes in the editing step, with no second call.
    func draftQuery(for id: ShapeID, words: String) -> String? {
        editor.interpretations?.draftQuery(at: interpretationKey(id), words: words)
    }

    /// Whether the words are being interpreted, so the Query section says so rather than offering to.
    func isInterpreting(_ id: ShapeID) -> Bool {
        if case .interpreting? = interpretationStatus(of: id) { return true }
        return false
    }

    // MARK: Typing

    /// The field of the reference `id` was opened: what was asked of its words before is let go of.
    func editingBegan(_ id: ShapeID) {
        editor.interpretations?.drop(interpretationKey(id))
        answered.bump(id)
    }

    /// The text of the field changed (after the editing step wrote it). Whatever was asked of the
    /// words before is let go of, the draft with it. `interprets` is whether the list holds only the
    /// words row and the text isn't what the field opened with: text that reads as a query is that
    /// query at once (a draft, with no model asked); else the text rests, and the model is asked
    /// when it has rested. Text the list still has shapes for is kept, to be interpreted if it's
    /// committed.
    func typed(_ text: String, in id: ShapeID, interprets: Bool) {
        editor.interpretations?.typed(text, at: interpretationKey(id), interprets: interprets, host: interpreter)
    }

    /// Words committed with ⌥Return or the words row, though the list still had shapes for them: they
    /// are to be interpreted when editing ends.
    func committed(words: String, of id: ShapeID) {
        editor.interpretations?.committed(words: words, at: interpretationKey(id), host: interpreter)
    }

    // MARK: Editing ends

    /// Editing the field ended: what the document has now is the words (or a pick, or nothing). On
    /// the next turn of the scheduler words typed or committed are asked about, a call still out is
    /// let be, and a draft that wasn't written lands (`Interpretations.editingEnded`).
    func interpretationEditingEnded(_ id: ShapeID) {
        // Every shape's editing ends here; only a reference's has anything to say.
        guard editor.file.record(id)?.kind == Reference.kind else { return }
        answered.bump(id)
        editor.interpretations?.editingEnded(at: interpretationKey(id))
    }

    /// Whether the reference is words with no query, and these.
    func isWordsWithNoQuery(_ id: ShapeID, words: String) -> Bool {
        guard let props = editor.file.record(id)?.typed(as: Reference.self)?.props else { return false }
        return props.target == nil && props.query == nil && props.words.trimmingCharacters(in: .whitespacesAndNewlines) == words
    }

    // MARK: Interpret and Retry

    /// Whether Interpret may be performed on `ids`: the one reference with words and no query, nobody
    /// asking about them, something to ask with, nothing being typed, and nothing locked.
    func canInterpret(_ ids: Set<ShapeID>) -> Bool {
        guard ids.count == 1, let id = ids.first else { return false }
        return canInterpret(id)
    }

    func canInterpret(_ id: ShapeID) -> Bool {
        guard offersInterpret(id), editor.file.record(id) != nil else { return false }
        return !editor.isReadOnly(inFile: id)
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
        editor.interpretations?.interpret(props.words, at: interpretationKey(id), host: interpreter)
    }

    func interpret(only ids: Set<ShapeID>) {
        guard ids.count == 1, let id = ids.first else { return }
        interpret(id)
    }

    /// Asks again after a failure: live while the pill is typed into, else as Interpret does.
    func retryInterpretation(_ id: ShapeID) {
        editor.interpretations?.retry(at: interpretationKey(id))
    }

    // MARK: Hearing commits

    /// What a commit did to the words being interpreted: asked about no longer when the reference is
    /// gone, stands for a shape, has a query, or has other words (an undo, a keystroke, a pick), whose
    /// call is cancelled and draft let go of. Nothing is asked here, and nothing transacts; a file put
    /// in place is the lifecycle's to let go of.
    func hearInterpretations(_ changes: ChangeSet) {
        guard !changes.replacedDocument, let interpretations = editor.interpretations, !interpretations.isEmpty else { return }
        func hear(_ id: ShapeID) {
            let key = interpretationKey(id)
            guard let words = interpretations.words(at: key) else { return }
            if isWordsWithNoQuery(id, words: words) { return }
            interpretations.drop(key)
            answered.bump(id)
        }
        for id in changes.added { hear(id) }
        for id in changes.changed where !changes.moved.contains(id) { hear(id) }
        for id in changes.removed { hear(id) }
        for id in changes.elsewhere { hear(id) }
    }

    /// The pill, the panel and the table of contents' row show what's asked of the words now.
    func tell(_ id: ShapeID) {
        answered.bump(id)
        editor.setNeedsDisplay()
        editor.contentsDidChange(for: [id])
    }
}

/// A reference, as the host of its words: what the lifecycle asks of it. Held by `ReferenceState` (the lifecycle
/// holds its hosts weakly), it holds the state unowned, which outlives it.
@MainActor
final class ReferenceInterpreter: InterpretationHost {
    unowned let state: ReferenceState

    init(state: ReferenceState) { self.state = state }

    /// A stored query, which reads only the file.
    func context(of _: InterpretationKey) -> TranslationContext { .stored() }

    func holdsWords(_ words: String, at key: InterpretationKey) -> Bool { state.isWordsWithNoQuery(key.shape, words: words) }

    /// As the pill asks its own query: the recorded view, public matches alone, first or every one.
    func request(for query: String, at key: InterpretationKey) -> QueryMatchRequest? {
        let all = state.editor.shape(inFile: key.shape)?.typed(as: Reference.self)?.props.all ?? false
        return state.request(query, all: all)
    }

    /// Writes the query of words the model made after editing ended, as a step of its own, on the
    /// reference's board: if the reference is still there with these words and no query, and can be
    /// changed. A locked one (itself, or by its frame) is let be, with no step and no shake; its
    /// words are not interpreted, and Interpret is offered once it's unlocked.
    func land(_ query: String, words: String, at key: InterpretationKey) {
        let editor = state.editor, id = key.shape, file = editor.file
        guard let record = file.record(id), let props = record.typed(as: Reference.self)?.props, props.target == nil, props.query == nil,
              props.words.trimmingCharacters(in: .whitespacesAndNewlines) == words, let board = file.board(containing: id),
              !editor.isReadOnly(inFile: id) else { return }
        editor.transact(on: board, ReferenceStyle.interpretStep) { transaction in
            transaction.update(id, as: Reference.self) { ReferenceEdits.find(&$0.props, words: props.words, query: query) }
        }
    }

    func interpretAgain(at key: InterpretationKey) { state.interpret(key.shape) }

    func interpretationDidChange(at key: InterpretationKey) { state.tell(key.shape) }
}

extension ReferenceStatus {
    /// What a reference says of words being interpreted, in the words every host says.
    init(_ status: InterpretationStatus) {
        switch status {
        case .interpreting: self = .interpreting
        case .unavailable: self = .unavailable
        case .notSignedIn: self = .failed(.notSignedIn)
        case .keyRejected: self = .failed(.keyRejected)
        case .model(let message): self = .failed(.model(message))
        case .noQuery: self = .failed(.noQuery)
        case .unusable: self = .failed(.unusable)
        }
    }
}

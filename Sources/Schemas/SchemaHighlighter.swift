import Canvas
import Foundation
import LanguageModels
import Observation

/// Asks the model which words of each card's description say which parts of its schema
/// (`SchemaPrompts.toHighlights`), and keeps what it says (`SchemaHighlightAnswers`). The sync
/// makes one per editor (`SchemaSync.highlighter`). It asks for a card:
///
/// - once the canvas has drawn it in full, its pair of texts with no answer (`want`, from the end of
///   each frame, `SchemaHighlightFrames`): not a card out of view, nor one drawn as a skeleton;
/// - once its description and schema are in step (`SchemaSync.isInStep`: synced, nothing waiting
///   or out), so what's linked is what both say: a card wanted before that is asked for as the
///   sync says it is (`inStep`);
/// - with a description that isn't blank, a schema that's a JSON object, and a model; on the
///   board shown;
/// - for a pair nothing has been said of this session (by its text, whatever card: undo, a copy
///   and a file opened twice ask nothing again), not being asked already, and not failed;
/// - at most `concurrentCalls` at once, the rest waiting their turn in the order they came; another
///   board shown drops the ones waiting for the board left.
///
/// An answer is kept for its pair whatever the card says by the time it lands, and is the card's
/// last unless one asked after it landed first; the canvas redraws, and `revision(of:)` changes for
/// the card, which its editor observes. A failure keeps nothing, and its pair isn't asked about
/// again this session, but after a key is saved in Settings (`keyDidChange`). Nothing is written
/// to the document.
@MainActor
@Observable
public final class SchemaHighlighter {
    /// The most calls out at once.
    public static let concurrentCalls = 4

    @ObservationIgnored private weak var editor: CanvasEditor?
    /// The pairs being asked about. A call isn't cancelled: whatever the card says by the time it
    /// lands, its answer is kept for its pair.
    @ObservationIgnored private var asking: Set<SchemaHighlightAnswers.Pair> = []
    @ObservationIgnored private var waiting: [(id: ShapeID, pair: SchemaHighlightAnswers.Pair)] = []
    /// Cards drawn with no answer, waiting to be in step.
    @ObservationIgnored private var wanted: Set<ShapeID> = []
    @ObservationIgnored private var failed: Set<SchemaHighlightAnswers.Pair> = []
    @ObservationIgnored private var revisions: [ShapeID: Int] = [:]
    @ObservationIgnored private var asked = 0

    init(editor: CanvasEditor) {
        self.editor = editor
    }

    /// Changes as the card's highlights do. Observing it hears only this card's.
    public func revision(of id: ShapeID) -> Int {
        access(keyPath: \.[revision: id])
        return revisions[id] ?? 0
    }

    /// Only a key: one key path per card, under which Observation keeps the observers of that card's
    /// highlights apart from every other card's.
    private subscript(revision id: ShapeID) -> Int { revisions[id] ?? 0 }

    /// How many calls are out, and how many wait their turn.
    public var callsOut: Int { asking.count }
    public var callsWaiting: Int { waiting.count }

    // MARK: What it hears

    /// Cards the canvas drew in full whose pairs have no answer.
    func want(_ ids: Set<ShapeID>) {
        wanted.formUnion(ids)
        for id in ids { ask(id) }
    }

    /// The sync says the card's description and schema are in step: asked for, if it's wanted.
    func inStep(_ id: ShapeID) {
        if wanted.contains(id) { ask(id) }
    }

    /// A key was saved or removed: what failed may not now.
    func keyDidChange() {
        failed = []
        for id in wanted { ask(id) }
    }

    /// The card went: nothing waits for it, and nothing kept of it stays but its answers, by text.
    func forget(_ id: ShapeID) {
        wanted.remove(id)
        waiting.removeAll { $0.id == id }
        SchemaHighlightAnswers.forget(id)
    }

    /// Another board is shown: nothing waits for the board left.
    func boardChanged() {
        guard let editor else { return }
        wanted = wanted.filter { editor.document[$0] != nil }
        waiting.removeAll { editor.document[$0.id] == nil }
    }

    // MARK: Asking

    /// Asks for the card if it may now; it stays wanted until it's asked for or has nothing to ask.
    private func ask(_ id: ShapeID) {
        guard let editor, let card = editor.document[id]?.typed(as: SchemaCard.self) else {
            wanted.remove(id)
            return
        }
        let pair = SchemaHighlightAnswers.Pair(prompt: card.props.prompt, schema: card.props.schema)
        guard !pair.prompt.isEmpty, SchemaHighlightAnswers.answer(for: pair) == nil, !failed.contains(pair), editor.languageModel != nil else {
            wanted.remove(id)
            return
        }
        guard !asking.contains(pair), !waiting.contains(where: { $0.pair == pair }),
              editor.schemaSync?.isInStep(id) == true, SchemaReadings.reading(of: pair.schema, for: id).document.isObject else { return }
        wanted.remove(id)
        waiting.append((id, pair))
        askNext()
    }

    private func askNext() {
        guard let model = editor?.languageModel else { return }
        while asking.count < Self.concurrentCalls, !waiting.isEmpty {
            let (id, pair) = waiting.removeFirst()
            asked += 1
            let number = asked
            let request = SchemaPrompts.toHighlights(prompt: pair.prompt, schema: pair.schema)
            asking.insert(pair)
            Task { [weak self] in
                let result: Result<ModelResponse, LanguageModelError>
                do throws(LanguageModelError) {
                    result = .success(try await model.respond(to: request))
                } catch {
                    result = .failure(error)
                }
                self?.land(pair, card: id, asked: number, result)
            }
        }
    }

    private func land(_ pair: SchemaHighlightAnswers.Pair, card id: ShapeID, asked number: Int, _ result: Result<ModelResponse, LanguageModelError>) {
        asking.remove(pair)
        if case .success(let response) = result, let highlights = SchemaPrompts.parseHighlights(response) {
            SchemaHighlightAnswers.remember(highlights, for: pair, card: id, asked: number)
            withMutation(keyPath: \.[revision: id]) { revisions[id, default: 0] += 1 }
            editor?.setNeedsDisplay()
        } else if case .failure(.cancelled) = result {
            // Nothing said: asked again when it's next wanted.
        } else {
            failed.insert(pair)
        }
        askNext()
    }
}

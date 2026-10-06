import Canvas
import Foundation
import LanguageModels
import Mentions
import Observation

/// One of a schema card's two sides: its prompt (what it holds, in words: the card's description,
/// typed on it) or its schema (its panel's JSON).
public enum SchemaSide: Sendable {
    case prompt, schema
}

/// Where a card's sync is, as its panel shows it, under its JSON.
public enum SchemaSyncStatus: Equatable, Sendable {
    /// In step, or waiting for the person to finish.
    case idle
    /// A call is out, writing this side (the schema from the prompt, or the prompt from the schema).
    case updating(SchemaSide)
    /// The last sync didn't write, and why.
    case failed(SchemaSyncFailure)
}

/// Why a card's last sync didn't write, in a line for a person, and what can be done about it.
public struct SchemaSyncFailure: Equatable, Sendable {
    /// What the panel offers under the line.
    public enum Remedy: Equatable, Sendable {
        /// Retry: the next try may go (the service was busy, the answer was unusable).
        case retry
        /// Open Settings…, for a key none is saved or one refused: saving a key there tries again
        /// by itself, so there's no Retry.
        case key
        /// Nothing to try again: asked again, the model would answer the same. The schema is too
        /// long for the model to write whole, so the person edits it by hand (and the description
        /// follows); or Claude declined, as it would again, so the person rewords what they wrote,
        /// and that edit syncs.
        case editByHand
    }

    /// The side the sync was to write, from the other, the side the person edited.
    public var writing: SchemaSide
    public var message: String
    public var remedy: Remedy

    public init(writing: SchemaSide, _ message: String, remedy: Remedy = .retry) {
        self.writing = writing
        self.message = message
        self.remedy = remedy
    }
}

/// Keeps each schema card's prompt and schema saying the same thing, through the editor's language
/// model: the person edits one side, and the model rewrites the other. Per card it keeps the pair as
/// it was at the last sync, what it last heard the card say, the idle timer and the call in flight.
///
/// - Only the person's edits start a sync, never the sync's own write, nor a board read again (a
///   revert, a reload after the file changed on disk: `ChangeSet.replacedDocument`), nor a change
///   to anything but the two sides (a move, a lock), nor an agent's write (`ChangeSet.byAgent`: the
///   command line's `draw`), whose sides are taken as in step, as a card seen for the first time
///   is (a call out, or an edit waiting, stops). An edit syncs when it's committed (`commit`: the
///   card's description done, editing it ended however it ended, Return, Escape and the keyboard
///   going to the panel among them, `editingDidEnd`, which commits only an edit still waiting; ⌘↩
///   in the panel's JSON, or the keyboard leaving it), else `idleDelay` after
///   the last one (`editor.scheduler`), but not while the person is choosing from the list at the
///   caret in its JSON (`completing`): a pick that opens it again leaves a whole schema waiting
///   for its value (`"type": ""`), so the idle wait starts once the list closes.
/// - The prompt changed (and isn't empty): the model edits the schema, told the prompt at the last
///   sync. Else the schema changed in meaning (not only its layout): the model edits the prompt, told
///   the schema at the last sync. Both changed: the schema, from the edited one. A schema too long
///   for the model to write whole (`SchemaPrompts.toSchemaMaxLength`) is never asked for: the
///   status says it's too long to rewrite (no Retry), and once the person edits it by hand, the
///   prompt follows it.
/// - Never while the schema isn't a JSON object (the person is halfway through it), for a read-only
///   card (locked, or in a locked frame), for a new card with neither fields nor a prompt, or without
///   a model.
/// - A card seen for the first time (on a board opened or read again, pasted, placed) is taken as in
///   step: that pair is its last sync, and the model is told it (`previous_prompt`,
///   `previous_schema`) as it would be one this session's, so a field taken out of an opened card's
///   prompt is taken out of its schema too. All but a prompt over a schema with no fields, which was
///   never answered (it failed, or the board closed first): its prompt is ahead, and the next
///   commit asks for the schema.
/// - While a call is out, the side it writes is read-only where it's edited (the panel's JSON, the
///   card's description while it's typed into); if it changes anyway, the answer is dropped. Edits
///   to the other side wait, and sync once it lands. A card deleted meanwhile drops it, and so does
///   every card when a file is put in place (read again from disk), those it left as they were too.
/// - The cards the two sides name (a mention in the description, a `$ref` in the schema) are shown
///   to the model as `@` and a word of their names, never their ids, and what it writes names them
///   back (`SchemaReferenceNames`): a mention it writes is a `$ref` to the card's schema, and a
///   `$ref` a mention, each card called as it is now, else as its mention holds.
/// - A failure leaves both sides as they are and says why; Retry (or the next commit) tries again,
///   and a key saved in Settings (`Notification.Name.languageModelKeyDidChange`) does for a card
///   that failed for want of one. A cancelled call says nothing. `NO_CHANGE` writes nothing. A
///   schema is written as the model wrote it (never laid out again: its order is the person's); a
///   description with `setPrompt`, so the card's height follows.
/// - It keeps every card of the file, on whatever board (ids are unique across it), so a card's
///   sync goes on while another board is shown: a commit made as its board was left, its timer and
///   its call. An answer for a card on a board that isn't shown is written there, without showing
///   it (`transact(on:)`), as an undo step made on that board, so undoing it shows the card's
///   board. A card whose board goes with its owner is dropped, with its call; one brought with a
///   board (a paste, an undo) is seen. A whole file put in place takes every card afresh.
/// - Its write is one undo step ("Update Schema", "Update Description"). Undo and redo are no edit
///   (`ChangeSet.restoredStep`): they start no sync, and a card whose sides they change drops its
///   call and its wait, since what was asked is no longer what the card says. The pair at the last
///   sync goes back and forth with the steps (`UndoParticipant`), for the cards a step brings back
///   or changes the sides of: undoing the sync's write leaves the card as it was before the
///   answer, the prompt ahead of its schema, and it syncs again only once the person edits or
///   commits; redoing it leaves it in step. A card the step doesn't touch keeps its pair.
@MainActor
@Observable
public final class SchemaSync {
    /// How long after the last keystroke an edit syncs by itself.
    public static let idleDelay: Duration = .seconds(3)
    /// What a card whose schema is too long to write whole says when its prompt changes, or when
    /// the model's schema was cut off: no Retry (it would be again), so the person edits the JSON.
    public nonisolated static let tooLongMessage = "Schema too long to rewrite"

    private struct Sides: Equatable, Sendable {
        var prompt: SchemaPromptText
        var schema: String

        /// A side's text, as stored.
        subscript(side: SchemaSide) -> String {
            switch side {
            case .prompt: prompt.stored
            case .schema: schema
            }
        }
    }

    private struct Call {
        /// The side the answer writes.
        let writes: SchemaSide
        /// Both sides as they were sent.
        let sent: Sides
        /// The words the model was shown for the cards the sides name, which its answer names them by.
        let names: SchemaReferenceNames
        let number: Int
        let task: Task<Void, Never>

        var direction: SchemaPrompts.Direction { writes == .schema ? .toSchema : .toPrompt }
    }

    private struct Card {
        /// Both sides as the document last said them, to tell a change to either from one to
        /// something else about the card (its frame, a lock).
        var seen: Sides
        /// An edit is waiting to sync: on `timer`, or for the list at the caret to close.
        var isWaiting = false
        var timer: ScheduledTask?
        var call: Call?
        /// A sync was asked for while the call was out: it runs once the call lands.
        var wantsSync = false
    }

    // Weak: a panel's text view may commit after its window, and the editor, went.
    @ObservationIgnored private weak var editor: CanvasEditor?
    @ObservationIgnored private var cards: [ShapeID: Card] = [:]
    /// Each card's sides at its last sync: what each says of the other. Apart from `cards`, so an
    /// undo step keeps it as it was (`UndoParticipant`) for the cost of a copy on write.
    @ObservationIgnored private var synced: [ShapeID: Sides] = [:]
    /// Observed a card at a time (`status(of:)`); a card with none is idle.
    @ObservationIgnored private var statuses: [ShapeID: SchemaSyncStatus] = [:]
    /// The cards whose JSON has a list open at the caret (`completing`): apart from `cards`, since
    /// the list outlasts what a card's entry does (an agent's write takes the card afresh).
    @ObservationIgnored private var completingCards: Set<ShapeID> = []
    /// The cards an undo or redo just brought back or changed the sides of: the only ones whose
    /// pair at the last sync its participant's restore puts back.
    @ObservationIgnored private var restoring: Set<ShapeID> = []
    /// The card this is writing, whose commit isn't the person's edit, and the pair its write
    /// leaves in step, which it syncs as services hear the write (inside the write's undo step).
    @ObservationIgnored private var writing: (id: ShapeID, pair: Sides)?
    @ObservationIgnored private var calls = 0
    @ObservationIgnored nonisolated(unsafe) private var keyObserver: (any NSObjectProtocol)?

    init(editor: CanvasEditor) {
        self.editor = editor
        seeEveryCard(in: editor.file)
        keyObserver = NotificationCenter.default.addObserver(forName: .languageModelKeyDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keyDidChange() }
        }
    }

    deinit {
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
    }

    // MARK: What the panel asks

    /// A shape on a board of the file the editor can show: a card another's `$ref` points to.
    func shape(inFile id: ShapeID) -> AnyShapeRecord? { editor?.shape(inFile: id) }

    /// The cards a `$ref` in the card `id`'s schema can point to, as its JSON's completions offer
    /// them: every other titled card on a board of the file the editor can show, by its title
    /// (the name its mentions show), its fields counted, in the order of their titles.
    public func referenceTargets(from id: ShapeID) -> [JSONCompletionOffer] {
        guard let editor else { return [] }
        var found: [(name: String, card: ShapeID, detail: String)] = []
        for card in cards.keys where card != id {
            guard let record = editor.shape(inFile: card)?.typed(as: SchemaCard.self) else { continue }
            let shown = SchemaReadings.reading(of: record).shown
            guard let title = shown.title else { continue }
            found.append((title, card, SchemaPanelText.subtitle(shown) ?? ""))
        }
        found.sort { a, b in
            let order = a.name.localizedStandardCompare(b.name)
            return order == .orderedSame ? a.card.description < b.card.description : order == .orderedAscending
        }
        return found.map { SchemaCompletions.card($0.card, named: $0.name, detail: $0.detail) }
    }

    /// Where the card's sync is. Observing it hears only this card's changes.
    public func status(of id: ShapeID) -> SchemaSyncStatus {
        access(keyPath: \.[status: id])
        return statuses[id] ?? .idle
    }

    /// The person is done with an edit (the card's description no longer edited; ⌘↩ or the
    /// keyboard leaving in its panel's JSON): sync now, rather than after `idleDelay`. Nothing
    /// happens if neither side changed.
    public func commit(_ id: ShapeID) { sync(id) }

    /// Tries the failed sync again.
    public func retry(_ id: ShapeID) { sync(id) }

    /// Whether the card's description and schema say what each said of the other at its last
    /// sync, with no edit waiting and no call out: in step, so what links them is what both say.
    public func isInStep(_ id: ShapeID) -> Bool {
        guard let card = cards[id], card.call == nil, !card.isWaiting, !card.wantsSync, let last = synced[id] else { return false }
        return Self.trimmed(card.seen.prompt) == Self.trimmed(last.prompt) && card.seen.schema == last.schema
    }

    /// The card may be in step now, though nothing it shows changed (an answer of `NO_CHANGE`, a
    /// schema laid out anew, an undo's pairs put back): the canvas draws again, so a card drawn in
    /// full with no highlights for its texts asks for them (`SchemaHighlightsShown`).
    private func inStep(_ id: ShapeID) {
        editor?.setNeedsDisplay()
    }

    /// The person is choosing from the list at the caret in the card's JSON (true), or has stopped
    /// (false): meanwhile an edit waits for them, and once they stop, `idleDelay` more. A commit
    /// syncs at once either way.
    func completing(_ id: ShapeID, _ isCompleting: Bool) {
        guard completingCards.contains(id) != isCompleting else { return }
        if isCompleting { completingCards.insert(id) } else { completingCards.remove(id) }
        wait(id)
    }

    // MARK: Syncing

    /// Takes a card seen for the first time (or read again from disk) as its last sync: in step,
    /// unless its prompt was never answered (a prompt over a schema that's JSON with no fields),
    /// which makes the prompt ahead.
    private func see(_ record: AnyShapeRecord) {
        guard let sides = Self.sides(of: record) else { return }
        let document = SchemaReadings.reading(of: sides.schema, for: record.id).document
        var pair = sides
        if document.error == nil, document.fields.isEmpty, !Self.trimmed(sides.prompt).isEmpty { pair.prompt = "" }
        cards[record.id] = Card(seen: sides)
        synced[record.id] = pair
        inStep(record.id)
    }

    private func edited(_ id: ShapeID) {
        cards[id]?.isWaiting = true
        wait(id)
    }

    /// Waits `idleDelay` from now for an edit waiting to sync, unless the person is choosing from
    /// the list in the card's JSON.
    private func wait(_ id: ShapeID) {
        guard let editor, var card = cards[id] else { return }
        card.timer?.cancel()
        card.timer = card.isWaiting && !completingCards.contains(id)
            ? editor.scheduler.schedule(after: Self.idleDelay) { [weak self] in self?.sync(id) } : nil
        cards[id] = card
    }

    private func sync(_ id: ShapeID) {
        guard var card = cards[id] else { return }
        card.timer?.cancel()
        card.timer = nil
        card.isWaiting = false
        card.wantsSync = card.call != nil
        cards[id] = card
        if card.call == nil { start(id) }
    }

    /// A key was saved or removed in Settings: the cards that failed for want of one try again.
    private func keyDidChange() {
        let waiting = statuses.compactMap { id, status -> ShapeID? in
            guard case let .failed(failure) = status, failure.remedy == .key else { return nil }
            return id
        }
        for id in waiting { sync(id) }
    }

    /// Asks the model for whichever side is behind, if one is and it may.
    private func start(_ id: ShapeID) {
        guard let editor, cards[id] != nil, let last = synced[id], let record = editor.file.record(id), let now = Self.sides(of: record) else { return }
        // A new try: an old failure no longer says where things are.
        setStatus(.idle, of: id)
        guard let model = editor.languageModel, !Self.isReadOnly(record, in: editor) else { return }
        let document = SchemaReadings.reading(of: now.schema, for: id).document
        guard document.error == nil, let root = document.root, root.isObject else { return }
        let prompt = Self.trimmed(now.prompt)
        let promptAhead = !prompt.isEmpty && prompt != Self.trimmed(last.prompt)
        let tooLong = now.schema.utf8.count > SchemaPrompts.toSchemaMaxLength
        let names = referenceNames(now, last, in: editor)
        let request: ModelRequest, writes: SchemaSide
        if promptAhead, !tooLong {
            request = SchemaPrompts.toSchema(previousPrompt: names.modelText(of: last.prompt).text, prompt: names.modelText(of: now.prompt).text,
                                             schema: names.modelSchema(now.schema), schemas: names.list)
            writes = .schema
        } else if !Self.means(root, last.schema) {
            guard !(document.fields.isEmpty && prompt.isEmpty) else { return }
            request = SchemaPrompts.toPrompt(prompt: names.modelText(of: now.prompt).text, previousSchema: names.modelSchema(last.schema),
                                             schema: names.modelSchema(now.schema), schemas: names.list)
            writes = .prompt
        } else if promptAhead {
            // Too long to write whole: the person edits it, and the prompt follows that edit.
            setStatus(.failed(SchemaSyncFailure(writing: .schema, Self.tooLongMessage, remedy: .editByHand)), of: id)
            return
        } else {
            // In step: a schema laid out anew says what it said.
            if now.schema != last.schema, prompt == Self.trimmed(last.prompt) { synced[id]?.schema = now.schema }
            inStep(id)
            return
        }
        calls += 1
        let number = calls
        let task = Task { [weak self] in
            let result: Result<ModelResponse, LanguageModelError>
            do throws(LanguageModelError) {
                result = .success(try await model.respond(to: request))
            } catch {
                result = .failure(error)
            }
            self?.land(id, call: number, result)
        }
        cards[id]?.call = Call(writes: writes, sent: now, names: names, number: number, task: task)
        setStatus(.updating(writes), of: id)
    }

    /// The words the model is shown for the cards a card's sides name, now and at its last sync: each
    /// schema card called by its title, as a mention of it shows it now; a card that isn't in the
    /// file (deleted, or in another file) by the name its mention holds, and a `$ref` to one no
    /// mention holds a name for as written. A mention of another kind's shape (pasted: the picker
    /// offers only schema cards) is no schema, and stays words.
    private func referenceNames(_ now: Sides, _ last: Sides, in editor: CanvasEditor) -> SchemaReferenceNames {
        SchemaReferenceNames(prompts: [now.prompt, last.prompt], schemas: [now.schema, last.schema], name: { id in
            guard let record = editor.shape(inFile: id), record.kind == SchemaCard.kind,
                  let appearance = editor.registry.mentionAppearance(of: record), !appearance.isPlaceholder else { return nil }
            return appearance.label
        }, isSchema: { id in editor.shape(inFile: id).map { $0.kind == SchemaCard.kind } ?? true })
    }

    private func land(_ id: ShapeID, call number: Int, _ result: Result<ModelResponse, LanguageModelError>) {
        // A card deleted (or read again) since has no entry, or a new one; its call was cancelled.
        guard var card = cards[id], let call = card.call, call.number == number else { return }
        let again = card.wantsSync
        card.call = nil
        card.wantsSync = false
        cards[id] = card
        setStatus(apply(result, of: call, to: id), of: id)
        if again { sync(id) }
    }

    /// Writes what the answer says, if it still may; returns the card's status after.
    private func apply(_ result: Result<ModelResponse, LanguageModelError>, of call: Call, to id: ShapeID) -> SchemaSyncStatus {
        let response: ModelResponse
        switch result {
        case let .success(answer): response = answer
        case .failure(.cancelled): return .idle
        case let .failure(error):
            let needsKey = error == .noKey || error == .unauthorized
            return .failed(SchemaSyncFailure(writing: call.writes, error.message, remedy: needsKey ? .key : .retry))
        }
        // Locked while it was out (or put in a frame that's locked, or its frame locked): nothing is
        // written, nothing is refused (no shake), and the pair stays as it was, so what the person
        // changed still syncs once it's unlocked.
        guard let editor, let record = editor.file.record(id), let now = Self.sides(of: record), !Self.isReadOnly(record, in: editor) else { return .idle }
        // The side it writes changed while it was out: the answer is to a question no longer asked.
        guard now[call.writes] == call.sent[call.writes] else { return .idle }
        switch SchemaPrompts.parse(response, call.direction) {
        case let .failure(reason):
            // A schema cut off would be cut off again, and a refusal, at temperature 0, refused
            // again: the person edits instead (rewording the description, say), and the next
            // commit syncs. Only an unusable answer is worth asking again.
            let cutOff = response.stopReason == .maxTokens && call.writes == .schema
            let wouldRepeat = cutOff || response.stopReason == .refusal
            return .failed(SchemaSyncFailure(writing: call.writes, reason, remedy: wouldRepeat ? .editByHand : .retry))
        case .noChange:
            synced[id] = call.sent
            inStep(id)
        case let .text(text):
            // The cards it names by their words, named by their ids again.
            switch call.writes {
            case .schema:
                let schema = call.names.schema(fromModel: text)
                write(id, .schema, inStep: Sides(prompt: call.sent.prompt, schema: schema)) { if schema != now.schema { $0.schema = SchemaText(schema) } }
            case .prompt:
                let prompt = call.names.prompt(fromModel: text)
                write(id, .prompt, inStep: Sides(prompt: prompt, schema: call.sent.schema)) { if prompt != now.prompt { $0.setPrompt(prompt) } }
            }
        }
        return .idle
    }

    /// The sync's own write, which no sync follows, and the pair it leaves in step: one undo step,
    /// named for the side it writes, from before the pair changed to after, so undoing it puts back
    /// the pair from before the answer and redoing it leaves the card in step. It's written on the
    /// card's board, shown or not (`transact(on:)`): a step made there, which undo shows the board
    /// for. A write of what the side already says commits nothing, and is no step.
    private func write(_ id: ShapeID, _ side: SchemaSide, inStep pair: Sides, _ change: (inout SchemaCard) -> Void) {
        guard let editor, let board = editor.file.board(containing: id) else { return }
        writing = (id, pair)
        defer { writing = nil }
        let written: Void? = editor.transact(on: board, side == .schema ? "Update Schema" : "Update Description") {
            $0.update(id, as: SchemaCard.self) { change(&$0.props) }
        }
        guard written != nil else { return }
        synced[id] = pair
        // In step, though a write of what the side already said commits nothing for services to hear.
        inStep(id)
    }

    /// Drops what's kept of a card, with its timer and its call.
    private func forget(_ id: ShapeID) {
        synced.removeValue(forKey: id)
        guard let card = cards.removeValue(forKey: id) else { return }
        card.timer?.cancel()
        card.call?.task.cancel()
        setStatus(.idle, of: id)
    }

    /// Undo or redo changed the card's sides: no edit to follow, and no answer to write, since
    /// what the call asked about is no longer what the card says. It stays as undo left it until
    /// the person edits or commits.
    private func stop(_ id: ShapeID) {
        guard var card = cards[id] else { return }
        card.timer?.cancel()
        card.timer = nil
        card.isWaiting = false
        card.call?.task.cancel()
        card.call = nil
        card.wantsSync = false
        cards[id] = card
        setStatus(.idle, of: id)
    }

    // MARK: Status, observed a card at a time

    private func setStatus(_ status: SchemaSyncStatus, of id: ShapeID) {
        guard (statuses[id] ?? .idle) != status else { return }
        withMutation(keyPath: \.[status: id]) { statuses[id] = status == .idle ? nil : status }
    }

    /// Only a key: one key path per card, under which Observation keeps the observers of that card's
    /// status apart from every other card's.
    private subscript(status id: ShapeID) -> SchemaSyncStatus { statuses[id] ?? .idle }

    // MARK: Reading cards

    /// Whether a card can't change, whichever board of the file it's on: locked, in a locked frame, or
    /// on a locked subboard's board, at any depth (`editor.isReadOnly(inFile:)`).
    private static func isReadOnly(_ record: AnyShapeRecord, in editor: CanvasEditor) -> Bool {
        editor.isReadOnly(inFile: record.id)
    }

    private static func sides(of record: AnyShapeRecord) -> Sides? {
        guard record.kind == SchemaCard.kind, let card = record.typed(as: SchemaCard.self)?.props else { return nil }
        return Sides(prompt: card.prompt, schema: card.schema.text)
    }

    fileprivate nonisolated static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// A description as stored, trimmed.
    fileprivate nonisolated static func trimmed(_ text: SchemaPromptText) -> String { trimmed(text.stored) }

    /// Whether `text` is JSON that says what `root` does: objects member for member in any order,
    /// arrays in order, numbers by value.
    private static func means(_ root: JSONNode, _ text: String) -> Bool {
        guard let other = try? JSONReader.read(text) else { return false }
        return same(root, other)
    }

    private static func same(_ a: JSONNode, _ b: JSONNode) -> Bool {
        switch (a.value, b.value) {
        case let (.object(x), .object(y)):
            let left = Dictionary(x.map { ($0.key, $0.value) }, uniquingKeysWith: { $1 })
            let right = Dictionary(y.map { ($0.key, $0.value) }, uniquingKeysWith: { $1 })
            return left.count == right.count && left.allSatisfy { key, value in right[key].map { same(value, $0) } ?? false }
        case let (.array(x), .array(y)): return x.count == y.count && zip(x, y).allSatisfy { same($0, $1) }
        case let (.number(x), .number(y)): return x == y || (Double(x).map { $0 == Double(y) } ?? false)
        case let (.string(x), .string(y)): return x == y
        case let (.bool(x), .bool(y)): return x == y
        case (.null, .null): return true
        default: return false
        }
    }
}

extension SchemaSync: EditorService {
    /// Cards that came are seen for the first time; cards that left the file are dropped, with their
    /// call, but one moved to another board (a frame turned into a subboard takes what it held onto
    /// its board) keeps its wait and its call, since `write` finds its board as it writes, and is the
    /// same card there; a card whose prompt or schema the person changed waits `idleDelay` for more; one whose sides
    /// undo or redo changed stops (`stop`). The same for the cards on other boards a commit reached
    /// (`ChangeSet.elsewhere`: a board taken with its owner, brought by a paste or an undo, a card
    /// written where it isn't shown). A file put in place over the board shown (a revert, a board
    /// read again from disk) takes every card afresh, those it left as they were too, with their
    /// waits and calls: each shows what the file holds, so its last reading that was a JSON object,
    /// from before, is in no version of it, and goes (`SchemaReadings.forget`), as a deleted card's
    /// does.
    public func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        if changes.replacedDocument {
            takeEveryCardAfresh(in: editor)
            return
        }
        // Off the board shown, but still in the file (moved onto another board): the same card.
        if !changes.removed.isEmpty {
            let file = editor.file
            for id in changes.removed where file.record(id) == nil { forgetCard(id) }
        }
        for id in changes.added {
            guard let record = editor.document[id] else { continue }
            came(record, changes)
        }
        for id in changes.changed {
            guard let record = editor.document[id] else { continue }
            changed(record, changes)
        }
        // Every shape of a board taken or brought back is here (10,000, say), and few are cards:
        // what isn't a card, and wasn't one, is passed over before anything else.
        guard !changes.elsewhere.isEmpty else { return }
        let file = editor.file
        for id in changes.elsewhere {
            guard let record = file.record(id) else {
                if cards[id] != nil || synced[id] != nil { forgetCard(id) }
                continue
            }
            guard record.kind == SchemaCard.kind else { continue }
            if cards[id] == nil { came(record, changes) } else { changed(record, changes) }
        }
    }

    /// A card came into the file: seen for the first time.
    private func came(_ record: AnyShapeRecord, _ changes: ChangeSet) {
        see(record)
        if changes.restoredStep, cards[record.id] != nil { restoring.insert(record.id) }
    }

    /// A card changed: if its sides did, an edit to follow, unless it's the sync's own write, or
    /// undo or redo; and a schema that changed is read now, whichever it was.
    private func changed(_ record: AnyShapeRecord, _ changes: ChangeSet) {
        let id = record.id
        guard let now = Self.sides(of: record) else { return }
        guard cards[id] != nil else {
            forget(id)
            see(record)
            return
        }
        guard let seen = cards[id]?.seen, seen != now else { return }
        // Read as it changes, whoever wrote it (the person, undo or redo, an agent, the sync's own
        // write, a write to a board not shown), so what the card shows of a text that isn't a JSON
        // object (its name, its row) is the last text it had that was one, every text it had read.
        if seen.schema != now.schema { _ = SchemaReadings.reading(of: now.schema, for: id) }
        cards[id]?.seen = now
        if changes.restoredStep {
            stop(id)
            restoring.insert(id)
        } else if changes.byAgent {
            // An agent's write is none of the person's: what it says is taken as in step.
            stop(id)
            see(record)
        } else if let writing, writing.id == id {
            synced[id] = writing.pair
            inStep(id)
        } else {
            edited(id)
        }
    }

    private func forgetCard(_ id: ShapeID) {
        forget(id)
        SchemaReadings.forget(id)
        SchemaHighlightsShown.forget(id)
    }

    /// A card's description is done: typing on it ended (Return, Escape, a click elsewhere, the
    /// keyboard gone to the panel, another board shown), so an edit waiting to sync syncs now, as the
    /// panel's ⌘↩ has it, on the scheduler's next turn: after what ended it (an undo, which stops the
    /// card; a draw; a file put in place, which takes it afresh), so what's committed is what the
    /// card says then. Editing that typed nothing, or whose edit already went, commits nothing: no
    /// failure is asked again but by Retry or an edit.
    public func editingDidEnd(_ id: ShapeID, in editor: CanvasEditor) {
        guard cards[id]?.isWaiting == true else { return }
        _ = editor.scheduler.schedule(after: .zero) { [weak self] in
            guard let self, cards[id]?.isWaiting == true else { return }
            commit(id)
        }
    }

    /// Another board is shown: every card of the file is still kept, its timer and call going on,
    /// so nothing changes; but a whole file put in place with the switch takes every card afresh,
    /// as a board read again does.
    public func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        guard change.isFileReplaced else { return }
        takeEveryCardAfresh(in: editor)
    }

    private func takeEveryCardAfresh(in editor: CanvasEditor) {
        for id in Set(cards.keys).union(synced.keys) { forgetCard(id) }
        seeEveryCard(in: editor.file)
    }

    /// Sees every card on every board of the file.
    private func seeEveryCard(in file: CanvasFile) {
        for record in file.root.shapes { see(record) }
        for board in file.children.values {
            for record in board.shapes { see(record) }
        }
    }
}

/// The pairs at the last sync go back and forth with undo: a step puts back what each card it
/// brought back, or whose sides it changed, said of the other as the step began (undone) or ended
/// (redone), after the change, whose cards stopped. The other cards keep theirs: what a card's sync
/// learned since without a step of its own (an answer of `NO_CHANGE` that landed while another
/// step was made) still holds of its sides, which the step didn't touch.
extension SchemaSync: UndoParticipant {
    public func undoSnapshot(in editor: CanvasEditor) -> any Sendable { synced }

    public func restoreUndoSnapshot(_ snapshot: any Sendable, in editor: CanvasEditor) {
        defer { restoring = [] }
        guard let pairs = snapshot as? [ShapeID: Sides] else { return }
        for id in restoring {
            if let pair = pairs[id] { synced[id] = pair }
            inStep(id)
        }
    }
}

extension CanvasEditor {
    /// Schema cards' sync between prompt and schema; nil without SchemasPlugin.
    public var schemaSync: SchemaSync? { service(SchemaSync.self) }
}

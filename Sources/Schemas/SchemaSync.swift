import Canvas
import Foundation
import LanguageModels
import Observation

/// One of a schema card's two sides: its prompt (what it holds, in words) or its schema.
public enum SchemaSide: Sendable {
    case prompt, schema

    /// The side a sync writing this one reads from: the one the person edited.
    public var other: SchemaSide { self == .prompt ? .schema : .prompt }
}

/// Where a card's sync is, as its panel shows it.
public enum SchemaSyncStatus: Equatable, Sendable {
    /// In step, or waiting for the person to finish.
    case idle
    /// A call is out, writing this side (the schema from the prompt, or the prompt from the schema).
    case updating(SchemaSide)
    /// The last sync didn't write, and why.
    case failed(SchemaSyncFailure)

    /// The side the person edited, which the status is about (the panel shows it there, so it's
    /// in view whatever else is collapsed); nil while idle.
    public var source: SchemaSide? {
        switch self {
        case .idle: nil
        case let .updating(side): side.other
        case let .failed(failure): failure.writing.other
        }
    }
}

/// Why a card's last sync didn't write, in a line for a person, and what can be done about it.
public struct SchemaSyncFailure: Equatable, Sendable {
    /// What the panel offers under the line.
    public enum Remedy: Equatable, Sendable {
        /// Retry: the next try may go (the service was busy, the answer was unusable).
        case retry
        /// Open Settings…, for a key none is saved or one refused, and Retry. Saving a key in
        /// Settings tries again by itself.
        case key
        /// Nothing to try again: the schema is too long for the model to write whole, so the person
        /// edits it by hand (and the description follows).
        case editByHand
    }

    /// The side the sync was to write; the line shows under the other, the side the person edited.
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
///   to anything but the two sides (a move, a lock). An edit syncs when it's committed (`commit`:
///   Return in the prompt, ⌘↩ in the schema, the keyboard leaving either), else `idleDelay` after
///   the last one (`editor.scheduler`).
/// - The prompt changed (and isn't empty): the model edits the schema, told the prompt at the last
///   sync. Else the schema changed in meaning (not only its layout): the model edits the prompt, told
///   the schema at the last sync. Both changed: the schema, from the edited one. A schema too long
///   for the model to write whole (`SchemaPrompts.toSchemaMaxLength`) is never asked for: the
///   status says to edit it by hand, and once the person has, the prompt follows it.
/// - Never while the schema isn't a JSON object (the person is halfway through it), for a read-only
///   (locked) card, for a new card with neither fields nor a prompt, or without a model.
/// - A card seen for the first time (on a board opened or read again, pasted, placed) is taken as in
///   step: that pair is its last sync, and the model is told it (`previous_prompt`,
///   `previous_schema`) as it would be one this session's, so a field taken out of an opened card's
///   prompt is taken out of its schema too. All but a prompt over a schema with no fields, which was
///   never answered (it failed, or the board closed first): its prompt is ahead, and the next
///   commit asks for the schema.
/// - While a call is out, the side it writes is read-only in the panel; if it changes anyway, the
///   answer is dropped. Edits to the other side wait, and sync once it lands. A card deleted, or
///   read again from disk, meanwhile drops it.
/// - A failure leaves both sides as they are and says why; Retry (or the next commit) tries again,
///   and so does a key saved in Settings (`Notification.Name.languageModelKeyDidChange`) for a card
///   that failed for want of one. A cancelled call says nothing. `NO_CHANGE` writes nothing. A
///   schema is written as the model wrote it (never laid out again: its order is the person's),
///   with `setSchema`, so the card's height follows.
@MainActor
@Observable
public final class SchemaSync {
    /// How long after the last keystroke an edit syncs by itself.
    public static let idleDelay: Duration = .seconds(3)
    /// What a card whose schema is too long to write whole says when its prompt changes.
    public static let tooLongMessage = "The schema is too long for Claude to write again from the description. Edit the JSON Schema by hand, and the description follows."

    private struct Sides: Equatable {
        var prompt: String
        var schema: String

        subscript(side: SchemaSide) -> String {
            switch side {
            case .prompt: prompt
            case .schema: schema
            }
        }
    }

    private struct Call {
        /// The side the answer writes.
        let writes: SchemaSide
        /// Both sides as they were sent.
        let sent: Sides
        let number: Int
        let task: Task<Void, Never>

        var direction: SchemaPrompts.Direction { writes == .schema ? .toSchema : .toPrompt }
    }

    private struct Card {
        /// Both sides at the last sync: what each says of the other.
        var synced: Sides
        /// Both sides as the document last said them, to tell a change to either from one to
        /// something else about the card (its frame, a lock).
        var seen: Sides
        var timer: ScheduledTask?
        var call: Call?
        /// A sync was asked for while the call was out: it runs once the call lands.
        var wantsSync = false

        /// A card seen for the first time: in step, unless its prompt was never answered (a prompt
        /// over a schema that's JSON with no fields), which makes the prompt ahead.
        init(firstSeen sides: Sides, document: SchemaDocument) {
            synced = sides
            seen = sides
            if document.error == nil, document.fields.isEmpty, !SchemaSync.trimmed(sides.prompt).isEmpty { synced.prompt = "" }
        }
    }

    // Weak: a panel's text view may commit after its window, and the editor, went.
    @ObservationIgnored private weak var editor: CanvasEditor?
    @ObservationIgnored private var cards: [ShapeID: Card] = [:]
    /// Observed a card at a time (`status(of:)`); a card with none is idle.
    @ObservationIgnored private var statuses: [ShapeID: SchemaSyncStatus] = [:]
    /// The card this is writing, whose commit isn't the person's edit.
    @ObservationIgnored private var writing: ShapeID?
    @ObservationIgnored private var calls = 0
    @ObservationIgnored nonisolated(unsafe) private var keyObserver: (any NSObjectProtocol)?

    init(editor: CanvasEditor) {
        self.editor = editor
        for record in editor.document.shapes { see(record) }
        keyObserver = NotificationCenter.default.addObserver(forName: .languageModelKeyDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keyDidChange() }
        }
    }

    deinit {
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
    }

    // MARK: What the panel asks

    /// Where the card's sync is. Observing it hears only this card's changes.
    public func status(of id: ShapeID) -> SchemaSyncStatus {
        access(keyPath: \.[status: id])
        return statuses[id] ?? .idle
    }

    /// The person is done with an edit (Return, ⌘↩, the keyboard leaving the side): sync now,
    /// rather than after `idleDelay`. Nothing happens if neither side changed.
    public func commit(_ id: ShapeID) { sync(id) }

    /// Tries the failed sync again.
    public func retry(_ id: ShapeID) { sync(id) }

    // MARK: Syncing

    /// Takes a card seen for the first time (or read again from disk) as its last sync.
    private func see(_ record: AnyShapeRecord) {
        guard let sides = Self.sides(of: record) else { return }
        cards[record.id] = Card(firstSeen: sides, document: SchemaReadings.reading(of: sides.schema, for: record.id).document)
    }

    private func edited(_ id: ShapeID) {
        guard let editor else { return }
        cards[id]?.timer?.cancel()
        cards[id]?.timer = editor.scheduler.schedule(after: Self.idleDelay) { [weak self] in self?.sync(id) }
    }

    private func sync(_ id: ShapeID) {
        guard var card = cards[id] else { return }
        card.timer?.cancel()
        card.timer = nil
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
        guard let editor, let card = cards[id], let record = editor.document[id], let now = Self.sides(of: record) else { return }
        // A new try: an old failure no longer says where things are.
        setStatus(.idle, of: id)
        guard let model = editor.languageModel, !editor.registry.isReadOnly(record) else { return }
        let document = SchemaReadings.reading(of: now.schema, for: id).document
        guard document.error == nil, let root = document.root, root.isObject else { return }
        let prompt = Self.trimmed(now.prompt)
        let promptAhead = !prompt.isEmpty && prompt != Self.trimmed(card.synced.prompt)
        let tooLong = now.schema.utf8.count > SchemaPrompts.toSchemaMaxLength
        let request: ModelRequest, writes: SchemaSide
        if promptAhead, !tooLong {
            request = SchemaPrompts.toSchema(previousPrompt: card.synced.prompt, prompt: now.prompt, schema: now.schema)
            writes = .schema
        } else if !Self.means(root, card.synced.schema) {
            guard !(document.fields.isEmpty && prompt.isEmpty) else { return }
            request = SchemaPrompts.toPrompt(prompt: now.prompt, previousSchema: card.synced.schema, schema: now.schema)
            writes = .prompt
        } else if promptAhead {
            // Too long to write whole: the person edits it, and the prompt follows that edit.
            setStatus(.failed(SchemaSyncFailure(writing: .schema, Self.tooLongMessage, remedy: .editByHand)), of: id)
            return
        } else {
            // In step: a schema laid out anew says what it said.
            if now.schema != card.synced.schema, prompt == Self.trimmed(card.synced.prompt) { cards[id]?.synced.schema = now.schema }
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
        cards[id]?.call = Call(writes: writes, sent: now, number: number, task: task)
        setStatus(.updating(writes), of: id)
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
        // Locked while it was out: nothing is written, nothing is refused (no shake), and the pair
        // stays as it was, so what the person changed still syncs once it's unlocked.
        guard let editor, let record = editor.document[id], let now = Self.sides(of: record), !editor.registry.isReadOnly(record) else { return .idle }
        // The side it writes changed while it was out: the answer is to a question no longer asked.
        guard now[call.writes] == call.sent[call.writes] else { return .idle }
        switch SchemaPrompts.parse(response, call.direction) {
        case let .failure(reason):
            // A schema cut off would be cut off again: the person edits it instead.
            let cutOff = response.stopReason == .maxTokens && call.writes == .schema
            return .failed(SchemaSyncFailure(writing: call.writes, reason, remedy: cutOff ? .editByHand : .retry))
        case .noChange:
            cards[id]?.synced = call.sent
        case let .text(text):
            switch call.writes {
            case .schema:
                if text != now.schema { write(id) { $0.setSchema(text) } }
                cards[id]?.synced = Sides(prompt: call.sent.prompt, schema: text)
            case .prompt:
                if text != now.prompt { write(id) { $0.prompt = text } }
                cards[id]?.synced = Sides(prompt: text, schema: call.sent.schema)
            }
        }
        return .idle
    }

    /// The sync's own write, which no sync follows.
    private func write(_ id: ShapeID, _ change: (inout SchemaCard) -> Void) {
        guard let editor else { return }
        writing = id
        defer { writing = nil }
        editor.transact { $0.update(id, as: SchemaCard.self) { change(&$0.props) } }
    }

    /// Drops what's kept of a card, with its timer and its call.
    private func forget(_ id: ShapeID) {
        guard let card = cards.removeValue(forKey: id) else { return }
        card.timer?.cancel()
        card.call?.task.cancel()
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

    private static func sides(of record: AnyShapeRecord) -> Sides? {
        guard record.kind == SchemaCard.kind, let card = record.typed(as: SchemaCard.self)?.props else { return nil }
        return Sides(prompt: card.prompt, schema: card.schema)
    }

    fileprivate nonisolated static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

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
    /// Cards that came, or were read again from disk, are seen for the first time; cards that went
    /// are dropped, with their call; a card whose prompt or schema the person changed waits
    /// `idleDelay` for more.
    public func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        for id in changes.removed {
            forget(id)
            SchemaReadings.forget(id)
        }
        for id in changes.added {
            if let record = editor.document[id] { see(record) }
        }
        for id in changes.changed {
            guard let record = editor.document[id], let now = Self.sides(of: record) else { continue }
            guard cards[id] != nil, !changes.replacedDocument else {
                forget(id)
                see(record)
                continue
            }
            guard cards[id]?.seen != now else { continue }
            cards[id]?.seen = now
            if writing != id { edited(id) }
        }
    }
}

extension CanvasEditor {
    /// Schema cards' sync between prompt and schema; nil without SchemasPlugin.
    public var schemaSync: SchemaSync? { service(SchemaSync.self) }
}

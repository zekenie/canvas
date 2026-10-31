import Canvas
import Foundation
import LanguageModels
import Mentions
import Observation
import Titles

/// One of a type's two sides: its words (what it holds, said in its shape's text: `TypeWords`) or
/// its schema (its panel's JSON).
public enum TypeSide: Sendable {
    case words, schema
}

/// Where a type's sync is, as its panel shows it, under its JSON.
public enum TypeSyncStatus: Equatable, Sendable {
    /// In step, or waiting for the person to finish.
    case idle
    /// A call is out, writing this side (the schema from the words, or the words from the schema).
    case updating(TypeSide)
    /// The last sync didn't write, and why.
    case failed(TypeSyncFailure)
}

/// Why a type's last sync didn't write, in a line for a person, and what can be done about it.
public struct TypeSyncFailure: Equatable, Sendable {
    /// What the panel offers under the line.
    public enum Remedy: Equatable, Sendable {
        /// Retry: the next try may go (the service was busy, the answer was unusable).
        case retry
        /// Open Settings…, for a sign-in: none, or one refused (a key or Claude Code's). Signing in
        /// there tries again by itself, so there's no Retry.
        case signIn
        /// Nothing to try again: asked again, the model would answer the same. The schema is too
        /// long for the model to write whole, so the person edits it by hand (and the words follow);
        /// or Claude declined, as it would again, so the person rewords what they wrote, and that
        /// edit syncs.
        case editByHand
    }

    /// What a type whose schema is too long to write whole says when its words change, or when the
    /// model's schema was cut off: no Retry (it would be again), so the person edits the JSON.
    public static let tooLongMessage = "Schema too long to rewrite"

    /// What a type says when it has words to be read and the editor has no language model at all (a
    /// list of plugins without one): no Retry, nothing to try again.
    public static let noModelMessage = "No language model"

    /// The side the sync was to write, from the other, the side the person edited.
    public var writing: TypeSide
    public var message: String
    public var remedy: Remedy

    public init(writing: TypeSide, _ message: String, remedy: Remedy = .retry) {
        self.writing = writing
        self.message = message
        self.remedy = remedy
    }
}

/// What a sync asks the model, both ways: the schema from the words, and the words from the schema.
/// A type's are `SchemaPrompts`' two (`types`); another schema kept in step with a shape's words
/// says its own.
public struct SchemaSyncPrompts: Sendable {
    /// The schema that says `words`, `previousWords` the words at the last sync, `schemas` the other
    /// types named (`SchemaReferenceNames.list`), `relationship` whether the shape is a relationship type.
    public let toSchema: @Sendable (_ previousWords: String?, _ words: String, _ schema: String, _ schemas: String?, _ relationship: Bool) -> ModelRequest
    /// The words that say `schema`, `previousSchema` the schema at the last sync.
    public let toWords: @Sendable (_ words: String, _ previousSchema: String?, _ schema: String, _ schemas: String?) -> ModelRequest
    /// A schema longer than this (UTF-8 bytes) is never sent to be written again from its words.
    public let maxSchemaLength: Int

    public init(toSchema: @escaping @Sendable (_ previousWords: String?, _ words: String, _ schema: String, _ schemas: String?, _ relationship: Bool) -> ModelRequest,
                toWords: @escaping @Sendable (_ words: String, _ previousSchema: String?, _ schema: String, _ schemas: String?) -> ModelRequest,
                maxSchemaLength: Int) {
        self.toSchema = toSchema
        self.toWords = toWords
        self.maxSchemaLength = maxSchemaLength
    }

    /// A type's: `SchemaPrompts.toSchema` and `toPrompt`, which the evals test.
    public static let types = SchemaSyncPrompts(
        toSchema: { SchemaPrompts.toSchema(previousPrompt: $0, prompt: $1, schema: $2, schemas: $3, relationship: $4) },
        toWords: { SchemaPrompts.toPrompt(prompt: $0, previousSchema: $1, schema: $2, schemas: $3) },
        maxSchemaLength: SchemaPrompts.toSchemaMaxLength)
}

/// A JSON Schema, as an added property, that a sync keeps in step with its shape's words
/// (`TypeWords`): the property it writes, and the prompts it sends. A type's (`TypeSchemaProperty`)
/// is one; the sync is the same for any.
public protocol SyncedSchema: ShapeProperty where Value == SchemaText {
    /// What's asked of the model.
    static var prompts: SchemaSyncPrompts { get }
    /// The step a write of the schema is ("Update Schema").
    static var updateStep: String { get }
    /// Whether the shape's name is the schema's: sent as its root `"title"` (one the person typed in
    /// the JSON is kept as typed instead), the model's root `"title"` taken out of what's written
    /// back, and an untitled shape named by it (a type's: its name is its title).
    static var namesTheShape: Bool { get }
}

extension TypeSchemaProperty: SyncedSchema {
    public static var prompts: SchemaSyncPrompts { .types }
    public static var updateStep: String { "Update Schema" }
    public static var namesTheShape: Bool { true }
}

/// Both sides as the document says them, or as they were at a sync.
struct TypeSyncSides: Equatable, Sendable {
    var words: MentionText
    var schema: String

    /// A side's text, as stored.
    subscript(side: TypeSide) -> String {
        switch side {
        case .words: words.stored
        case .schema: schema
        }
    }
}

/// Keeps each shape's words and its schema (`Schema`, an added property: a type's, `TypeSchemaProperty`)
/// saying the same thing, through the editor's language model: the person edits one side, and the
/// model rewrites the other. Per shape it keeps the pair as it was at the last sync, what it last
/// heard the shape say, the idle timer and the call in flight. It reads and writes the words through
/// `TypeWords` alone, so it knows no kind.
///
/// - Only the person's edits start a sync, never the sync's own write, nor a board read again (a
///   revert, a reload after the file changed on disk: `ChangeSet.replacedDocument`), nor a change
///   to anything but the two sides (a move, a lock, a rename), nor an agent's write
///   (`ChangeSet.byAgent`: the command line's `draw`), whose sides are taken as in step, as a shape
///   seen for the first time is (a call out, or an edit waiting, stops). A shape that becomes a type
///   by the person's edit (`/is-a type`) waits as an edit does: its words are ahead of its new schema, and
///   it syncs on the scheduler's next turn, with no wait (the note shows at once what it is doing). An
///   edit syncs when it's committed (`commit`: the words done, editing them ended however it ended,
///   Return, Escape and the keyboard going to the panel among them, `editingDidEnd`, which commits
///   only an edit still waiting; ⌘↩ in the panel's JSON, or the keyboard leaving it), else
///   `idleDelay` after the last one (`editor.scheduler`), but not while the person is choosing from
///   the list at the caret in its JSON (`completing`): a pick that opens it again leaves a whole
///   schema waiting for its value (`"type": ""`), so the idle wait starts once the list closes.
/// - The words changed (and aren't empty): the model edits the schema, told the words at the last
///   sync. Else the schema changed in meaning (not only its layout): the model edits the words, told
///   the schema at the last sync. Both changed: the schema, from the edited words. A schema too long
///   for the model to write whole (`SchemaSyncPrompts.maxSchemaLength`) is never asked for: the
///   status says it's too long to rewrite (no Retry), and once the person edits it by hand, the
///   words follow it.
/// - The shape's name is its title (`namesTheShape`): the schema it keeps has no root `"title"`, and
///   the sync puts the name in as one for the model (unless the person typed one in the JSON, which
///   is kept as typed), takes the model's out of what it writes back, and names an untitled shape by
///   it, in the same step.
/// - Never while the schema isn't a JSON object (the person is halfway through it), for a read-only
///   shape (locked, or in a locked frame), or for one with neither fields nor words. Without a model
///   (a list of plugins with none) a side to write fails, saying so (`TypeSyncFailure.noModelMessage`).
/// - A shape seen for the first time (on a board opened or read again, pasted, placed) is taken as
///   in step: that pair is its last sync, and the model is told it (`previous_prompt`,
///   `previous_schema`) as it would be one this session's, so a field taken out of an opened type's
///   words is taken out of its schema too. All but words over a schema with no fields, which were
///   never answered (it failed, or the board closed first, or the shape just became a type): its
///   words are ahead, and the next commit asks for the schema.
/// - While a call is out, the side it writes is read-only where it's edited (the panel's JSON, the
///   words while they're typed into); if it changes anyway, the answer is dropped. Edits to the
///   other side wait, and sync once it lands. A shape deleted meanwhile, or no longer a type, drops
///   it, and so does every shape when a file is put in place (read again from disk), those it left
///   as they were too.
/// - The types the two sides name (a mention in the words, a `$ref` in the schema) are shown to the
///   model as `@` and a word of their names, never their ids, and what it writes names them back
///   (`SchemaReferenceNames`): a mention it writes is a `$ref` to the type's schema, and a `$ref` a
///   mention, each type called as it is now, else as its mention holds. A mention of a shape that
///   isn't a type is words.
/// - A failure leaves both sides as they are and says why; Retry (or the next commit) tries again,
///   and a sign-in in Settings (`Notification.Name.languageModelSignInDidChange`) does for a shape
///   that failed for want of one. A cancelled call says nothing. `NO_CHANGE` writes nothing. A
///   schema is written as the model wrote it (never laid out again: its order is the person's); the
///   words through the kind's `TypeWords`, so the shape fits them as typing fits it.
/// - It keeps every type of the file, on whatever board (ids are unique across it), so a type's
///   sync goes on while another board is shown: a commit made as its board was left, its timer and
///   its call. An answer for a shape on a board that isn't shown is written there, without showing
///   it (`transact(on:)`), as an undo step made on that board, so undoing it shows the shape's
///   board. A shape whose board goes with its owner is dropped, with its call; one brought with a
///   board (a paste, an undo) is seen. A whole file put in place takes every shape afresh.
/// - Its write is one undo step (`Schema.updateStep`, "Update Text"). Undo and redo are no edit
///   (`ChangeSet.restoredStep`): they start no sync, and a shape whose sides they change drops its
///   call and its wait, since what was asked is no longer what the shape says. The pair at the last
///   sync goes back and forth with the steps (`UndoParticipant`), for the shapes a step brings back
///   or changes the sides of: undoing the sync's write leaves the shape as it was before the
///   answer, the words ahead of its schema, and it syncs again only once the person edits or
///   commits; redoing it leaves it in step. A shape the step doesn't touch keeps its pair.
@MainActor
@Observable
public final class TypeSync<Schema: SyncedSchema> {
    /// How long after the last keystroke an edit syncs by itself.
    public static var idleDelay: Duration { .seconds(3) }

    // Weak: a panel's text view may commit after its window, and the editor, went.
    @ObservationIgnored private weak var editor: CanvasEditor?
    @ObservationIgnored private let shapes = SyncShapes()
    /// Each shape's sides at its last sync: what each says of the other. Apart from `shapes`, so an
    /// undo step keeps it as it was (`UndoParticipant`) for the cost of a copy on write.
    @ObservationIgnored private var synced: [ShapeID: TypeSyncSides] = [:]
    /// Observed a shape at a time (`status(of:)`); a shape with none is idle.
    @ObservationIgnored private var statuses: [ShapeID: TypeSyncStatus] = [:]
    /// The shapes whose JSON has a list open at the caret (`completing`): apart from `shapes`, since
    /// the list outlasts what a shape's entry does (an agent's write takes the shape afresh).
    @ObservationIgnored private var completingShapes: Set<ShapeID> = []
    /// The shapes an undo or redo just brought back or changed the sides of: the only ones whose
    /// pair at the last sync its participant's restore puts back.
    @ObservationIgnored private var restoring: Set<ShapeID> = []
    /// The shape this is writing, whose commit isn't the person's edit, and the pair its write
    /// leaves in step, which it syncs as services hear the write (inside the write's undo step).
    @ObservationIgnored private var writing: (id: ShapeID, pair: TypeSyncSides)?
    @ObservationIgnored private var calls = 0
    /// Told a shape's id when something a rows' spot reads of it changes (`onSpotChange`).
    @ObservationIgnored private var spotObservers: [@MainActor (ShapeID) -> Void] = []
    /// The kinds that hold `Schema` and have words: every other shape is passed over at once.
    @ObservationIgnored private let kinds: Set<ShapeKind>
    /// The directives the model is never sent and a change to which alone is no change: `$color`, `$autofill`
    /// and what other plugins hold in a schema.
    @ObservationIgnored private let held: HeldDirectives
    @ObservationIgnored nonisolated(unsafe) private var keyObserver: (any NSObjectProtocol)?

    init(editor: CanvasEditor) {
        self.editor = editor
        let registry = editor.registry
        held = registry.heldDirectives
        kinds = Set(registry.kinds.filter { registry.properties(for: $0).contains(Schema.key) && registry.typeWords(of: $0) != nil })
        seeEveryShape(in: editor.file)
        keyObserver = NotificationCenter.default.addObserver(forName: .languageModelSignInDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keyDidChange() }
        }
    }

    /// The file closed and the editor went: what each shape has out stops as `shapes` goes.
    deinit {
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
    }

    // MARK: What the panel asks

    /// A shape on a board of the file the editor can show: a type another's `$ref` points to.
    func shape(inFile id: ShapeID) -> AnyShapeRecord? { editor?.shape(inFile: id) }

    /// Where the shape's sync is. Observing it hears only this shape's changes.
    public func status(of id: ShapeID) -> TypeSyncStatus {
        access(keyPath: \.[status: id])
        return statuses[id] ?? .idle
    }

    /// Where the shape's sync is, read without observing it: a layout asks of every type's note, is told of a change by
    /// `onSpotChange`, and an observed read makes a key path each time.
    func statusUnobserved(of id: ShapeID) -> TypeSyncStatus { statuses[id] ?? .idle }

    /// The failure the shape's sync ended in, read without observing it: a type's rows ask each frame they are
    /// drawn (the reason at their foot) and are told of a change by `onSpotChange`, and an observed read makes a
    /// key path each time. Nothing but a compare while no shape is syncing or failed.
    func failure(of id: ShapeID) -> TypeSyncFailure? {
        guard !statuses.isEmpty, case .failed(let failure)? = statuses[id] else { return nil }
        return failure
    }

    /// Told a shape's id whenever something a rows' spot reads of it changes with no commit of its own
    /// to show it: its status, and whether an edit is waiting (`isWaiting`).
    public func onSpotChange(_ body: @escaping @MainActor (ShapeID) -> Void) { spotObservers.append(body) }

    /// An edit of the shape's is waiting to sync: on the idle timer, for the list at the caret to
    /// close, or for the next turn.
    public func isWaiting(_ id: ShapeID) -> Bool { shapes[id]?.isWaiting == true }

    /// A read has answered for the shape: its words at the last sync are not empty (`see` blanks them
    /// for words never answered).
    public func hasAnswered(_ id: ShapeID) -> Bool { synced[id].map { !Self.trimmed($0.words).isEmpty } ?? false }

    /// Tells the spot's readers, once this has taken the change being delivered in, if it's taking one in
    /// (`onceHeard`): they read it back.
    private func spotChanged(_ id: ShapeID) {
        let observers = spotObservers
        guard let editor else { return }
        editor.onceHeard { for body in observers { body(id) } }
    }

    /// The person is done with an edit (the words no longer edited; ⌘↩ or the keyboard leaving in
    /// its panel's JSON): sync now, rather than after `idleDelay`. Nothing happens if neither side
    /// changed.
    public func commit(_ id: ShapeID) { sync(id) }

    /// Tries the failed sync again.
    public func retry(_ id: ShapeID) { sync(id) }

    /// Whether the shape's words and schema say what each said of the other at its last sync, with
    /// no edit waiting and no call out: in step, so what links them is what both say.
    public func isInStep(_ id: ShapeID) -> Bool {
        guard let shape = shapes[id], shape.call == nil, !shape.isWaiting, !shape.wantsSync, let last = synced[id] else { return false }
        return Self.trimmed(shape.seen.words) == Self.trimmed(last.words) && shape.seen.schema == last.schema
    }

    /// The shape may be in step now, though nothing it shows changed (an answer of `NO_CHANGE`, a
    /// schema laid out anew, an undo's pairs put back): the canvas draws again, so a shape drawn in
    /// full with no highlights for its texts asks for them (`ProseHighlights`).
    private func inStep(_ id: ShapeID) {
        editor?.setNeedsDisplay()
    }

    /// The person is choosing from the list at the caret in the shape's JSON (true), or has stopped
    /// (false): meanwhile an edit waits for them, and once they stop, `idleDelay` more. A commit
    /// syncs at once either way.
    public func completing(_ id: ShapeID, _ isCompleting: Bool) {
        guard completingShapes.contains(id) != isCompleting else { return }
        if isCompleting { completingShapes.insert(id) } else { completingShapes.remove(id) }
        wait(id)
    }

    // MARK: Syncing

    /// Takes a shape seen for the first time (or read again from disk) as its last sync: in step,
    /// unless its words were never answered (words over a schema that's JSON with no fields), which
    /// makes the words ahead.
    private func see(_ record: AnyShapeRecord) {
        guard let sides = sides(of: record) else { return }
        let document = SchemaReadings.reading(of: sides.schema, for: record.id).document
        var pair = sides
        if document.error == nil, document.fields.isEmpty, !Self.trimmed(sides.words).isEmpty { pair.words = "" }
        shapes[record.id] = SyncShape(seen: sides)
        synced[record.id] = pair
        inStep(record.id)
    }

    private func edited(_ id: ShapeID) {
        guard shapes[id] != nil else { return }
        let flipped = shapes[id]?.isWaiting != true
        shapes[id]?.isWaiting = true
        wait(id)
        if flipped { spotChanged(id) }
    }

    /// Waits `idleDelay` from now for an edit waiting to sync, unless the person is choosing from
    /// the list in the shape's JSON.
    private func wait(_ id: ShapeID) {
        guard let editor, var shape = shapes[id] else { return }
        shape.timer?.cancel()
        shape.timer = shape.isWaiting && !completingShapes.contains(id)
            ? editor.scheduler.schedule(after: Self.idleDelay) { [weak self] in self?.sync(id) } : nil
        shapes[id] = shape
    }

    private func sync(_ id: ShapeID) {
        guard var shape = shapes[id] else { return }
        let wasWaiting = shape.isWaiting
        shape.timer?.cancel()
        shape.timer = nil
        shape.isWaiting = false
        shape.wantsSync = shape.call != nil
        shapes[id] = shape
        if wasWaiting { spotChanged(id) }
        if shape.call == nil { start(id) }
    }

    /// The sign-in changed in Settings: the shapes that failed for want of one try again.
    private func keyDidChange() {
        let waiting = statuses.compactMap { id, status -> ShapeID? in
            guard case let .failed(failure) = status, failure.remedy == .signIn else { return nil }
            return id
        }
        for id in waiting { sync(id) }
    }

    /// Asks the model for whichever side is behind, if one is and it may.
    private func start(_ id: ShapeID) {
        guard let editor, shapes[id] != nil, let last = synced[id], let record = editor.file.record(id), let now = sides(of: record) else { return }
        // A new try: an old failure no longer says where things are.
        setStatus(.idle, of: id)
        guard !editor.isReadOnly(inFile: id) else { return }
        // Words that are a JSON object are the schema, never a prompt (ruling M1), so a schema left
        // broken in the panel is mended by them too; JSON still being typed ({"a": …) asks nothing.
        if Self.trimmed(now.words) != Self.trimmed(last.words) {
            if let text = TypeWordsSchema.schema(fromWords: now.words) {
                adopt(id, text, words: now.words, schema: now.schema)
                return
            }
            if now.words.mentioned.isEmpty, Self.looksLikeJSON(Self.trimmed(now.words)) { return }
        }
        let document = SchemaReadings.reading(of: now.schema, for: id).document
        guard document.error == nil, let root = document.root, root.isObject else { return }
        let words = Self.trimmed(now.words)
        let wordsAhead = !words.isEmpty && words != Self.trimmed(last.words)
        let tooLong = now.schema.utf8.count > Schema.prompts.maxSchemaLength
        let names = referenceNames(now, last, in: editor)
        // The shape's name goes in as each schema's root "title", unless the person typed one there;
        // and the answer's comes out, unless the person typed one in the schema now.
        let name = Schema.namesTheShape ? editor.registry.title(of: record) : nil
        let named = Schema.namesTheShape && TypeNaming.title(of: now.schema) == nil
        // And never its `$color` or `$autofill`: what the shape holds is no business of the words'.
        func sent(_ schema: String) -> String {
            let schema = held.stripped(schema)
            return names.modelSchema(name.flatMap { TypeNaming.titled(schema, $0) } ?? schema)
        }
        let request: ModelRequest, writes: TypeSide
        if wordsAhead, !tooLong {
            request = Schema.prompts.toSchema(names.modelText(of: last.words).text, names.modelText(of: now.words).text, sent(now.schema), names.list,
                                              record[RelationshipProperty.self] == true)
            writes = .schema
        } else if !Self.means(root, last.schema, ignoringTitle: Schema.namesTheShape, held: held) {
            guard !(document.fields.isEmpty && words.isEmpty) else { return }
            // Words that are JSON are the schema, and never go as the prompt: the model writes the words from the schema.
            let prompt = TypeWordsSchema.schema(fromWords: now.words) == nil ? names.modelText(of: now.words).text : ""
            request = Schema.prompts.toWords(prompt, sent(last.schema), sent(now.schema), names.list)
            writes = .words
        } else if wordsAhead {
            // Too long to write whole: the person edits it, and the words follow that edit.
            setStatus(.failed(TypeSyncFailure(writing: .schema, TypeSyncFailure.tooLongMessage, remedy: .editByHand)), of: id)
            return
        } else {
            // In step: a schema laid out anew says what it said.
            if now.schema != last.schema, words == Self.trimmed(last.words) { synced[id]?.schema = now.schema }
            inStep(id)
            return
        }
        // A side to write and no model at all: said, where it would have been asked.
        guard let model = editor.languageModel else {
            setStatus(.failed(TypeSyncFailure(writing: writes, TypeSyncFailure.noModelMessage, remedy: .editByHand)), of: id)
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
        shapes[id]?.call = SyncCall(writes: writes, sent: now, names: names, named: named, number: number, task: task)
        setStatus(.updating(writes), of: id)
    }

    /// Words that are a JSON object become the schema as written (with the type's `$color` and `$autofill`,
    /// unless they say them), and the words are then written from it, as when a note becomes a type: the pair is
    /// said to have been these words over an empty schema, so the schema is ahead and `start` asks for
    /// the words (nothing, if the schema says nothing). One undo step ("Update Schema"), none if the
    /// schema already is these words.
    private func adopt(_ id: ShapeID, _ text: String, words: MentionText, schema: String) {
        let text = held.carried(from: schema, into: text)
        let pair = TypeSyncSides(words: words, schema: "{}")
        if text != schema {
            write(id, .schema, inStep: pair) { $0.update(id) { $0[Schema.self] = SchemaText(text) } }
        } else {
            synced[id] = pair
        }
        start(id)
    }

    /// Whether `text` starts a JSON object a person is still typing: `{`, then `"` or `}` (or nothing yet).
    /// Words written in braces for another reason (`{name, age} for each guest`) are a prompt.
    private nonisolated static func looksLikeJSON(_ text: String) -> Bool {
        guard text.hasPrefix("{") else { return false }
        guard let next = text.dropFirst().first(where: { !$0.isWhitespace }) else { return true }
        return next == "\"" || next == "}"
    }

    /// The words the model is shown for the types a shape's sides name, now and at its last sync:
    /// each type called by its name, as a mention of it shows it now; a type that isn't in the file
    /// (deleted, or in another file) by the name its mention holds, and a `$ref` to one no mention
    /// holds a name for as written. A mention of a shape that isn't a type stays words, and so does one of a
    /// relationship type, whose fields belong to its arrows (`TypeIndex.canBeEmbedded`); a `$ref` to one written by
    /// hand is still read as its word.
    private func referenceNames(_ now: TypeSyncSides, _ last: TypeSyncSides, in editor: CanvasEditor) -> SchemaReferenceNames {
        SchemaReferenceNames(words: [now.words, last.words], schemas: [now.schema, last.schema], name: { id in
            guard let record = editor.shape(inFile: id), record[TypeSchemaProperty.self] != nil,
                  let appearance = editor.registry.mentionAppearance(of: record), !appearance.isPlaceholder else { return nil }
            return appearance.label
        }, isType: { id in editor.shape(inFile: id).map { _ in editor.types?.canBeEmbedded(id) ?? true } ?? true })
    }

    private func land(_ id: ShapeID, call number: Int, _ result: Result<ModelResponse, LanguageModelError>) {
        // A shape deleted (or read again) since has no entry, or a new one; its call was cancelled.
        guard var shape = shapes[id], let call = shape.call, call.number == number else { return }
        let again = shape.wantsSync
        shape.call = nil
        shape.wantsSync = false
        shapes[id] = shape
        setStatus(apply(result, of: call, to: id), of: id)
        if again { sync(id) }
    }

    /// Writes what the answer says, if it still may; returns the shape's status after.
    private func apply(_ result: Result<ModelResponse, LanguageModelError>, of call: SyncCall, to id: ShapeID) -> TypeSyncStatus {
        let response: ModelResponse
        switch result {
        case let .success(answer): response = answer
        case .failure(.cancelled): return .idle
        case let .failure(error):
            let needsSignIn = error == .notSignedIn || error == .unauthorized
            return .failed(TypeSyncFailure(writing: call.writes, error.message, remedy: needsSignIn ? .signIn : .retry))
        }
        // Locked while it was out (or put in a frame that's locked, or its frame locked): nothing is
        // written, nothing is refused (no shake), and the pair stays as it was, so what the person
        // changed still syncs once it's unlocked.
        guard let editor, let record = editor.file.record(id), let now = sides(of: record), !editor.isReadOnly(inFile: id) else { return .idle }
        // The side it writes changed while it was out: the answer is to a question no longer asked. A
        // type given another color meanwhile (or told whether its notes fill) says what it said.
        guard call.writes == .schema ? held.sameButHeld(now.schema, call.sent.schema) : now.words == call.sent.words
        else { return .idle }
        // The words a rewrite replaces, as a prompt: none for JSON, which was never sent as one.
        let replaced = call.direction == .toPrompt && TypeWordsSchema.schema(fromWords: call.sent.words) == nil ? call.names.modelText(of: call.sent.words).text : ""
        switch SchemaPrompts.parse(response, call.direction, words: replaced) {
        case let .failure(reason):
            // A schema cut off would be cut off again, and a refusal refused again: the person edits
            // instead (rewording the words, say), and the next commit syncs. Only an unusable answer
            // is worth asking again.
            let cutOff = response.stopReason == .maxTokens && call.writes == .schema
            let wouldRepeat = cutOff || response.stopReason == .refusal
            return .failed(TypeSyncFailure(writing: call.writes, reason, remedy: wouldRepeat ? .editByHand : .retry))
        case .noChange:
            synced[id] = call.sent
            inStep(id)
        case let .text(text):
            // The types it names by their words, named by their ids again.
            switch call.writes {
            case .schema:
                // With the type's `$color` and `$autofill`, which the model is never sent.
                var schema = held.carried(from: now.schema, into: call.names.schema(fromModel: text))
                // The name went in as the root "title": it comes out, and names a shape that has none.
                var title: String?
                if call.named, let untitled = TypeNaming.untitled(schema) {
                    title = untitled.title
                    schema = untitled.text
                }
                let names = title.flatMap { title in editor.registry.title(of: record) == nil && editor.registry.properties(for: record.kind).contains(TitleProperty.key) ? title : nil }
                write(id, .schema, inStep: TypeSyncSides(words: call.sent.words, schema: schema)) { transaction in
                    if schema != now.schema { transaction.update(id) { $0[Schema.self] = SchemaText(schema) } }
                    if let names { transaction.update(id) { $0[TitleProperty.self] = names } }
                }
            case .words:
                let words = call.names.words(fromModel: text)
                guard let typeWords = editor.registry.typeWords(of: record.kind) else { return .idle }
                let answered = held.sameButHeld(now.schema, call.sent.schema) ? now.schema : call.sent.schema
                write(id, .words, inStep: TypeSyncSides(words: words, schema: answered)) { transaction in
                    if words != now.words { typeWords.write(&transaction, id, words) }
                }
            }
        }
        return .idle
    }

    /// The sync's own write, which no sync follows, and the pair it leaves in step: one undo step,
    /// named for the side it writes, from before the pair changed to after, so undoing it puts back
    /// the pair from before the answer and redoing it leaves the shape in step. It's written on the
    /// shape's board, shown or not (`transact(on:)`): a step made there, which undo shows the board
    /// for. A write of what the side already says commits nothing, and is no step.
    private func write(_ id: ShapeID, _ side: TypeSide, inStep pair: TypeSyncSides, _ change: (inout Transaction) -> Void) {
        guard let editor, let board = editor.file.board(containing: id) else { return }
        writing = (id, pair)
        defer { writing = nil }
        let written: Void? = editor.transact(on: board, side == .schema ? Schema.updateStep : TypeSyncText.updateWords) { change(&$0) }
        guard written != nil else { return }
        synced[id] = pair
        // In step, though a write of what the side already said commits nothing for services to hear.
        inStep(id)
    }

    /// Drops what's kept of a shape, with its timer and its call.
    private func forget(_ id: ShapeID) {
        synced.removeValue(forKey: id)
        guard let shape = shapes.removeValue(forKey: id) else { return }
        shape.timer?.cancel()
        shape.call?.task.cancel()
        setStatus(.idle, of: id)
    }

    /// Undo or redo changed the shape's sides: no edit to follow, and no answer to write, since
    /// what the call asked about is no longer what the shape says. It stays as undo left it until
    /// the person edits or commits.
    private func stop(_ id: ShapeID) {
        guard var shape = shapes[id] else { return }
        let wasWaiting = shape.isWaiting
        shape.timer?.cancel()
        shape.timer = nil
        shape.isWaiting = false
        shape.call?.task.cancel()
        shape.call = nil
        shape.wantsSync = false
        shapes[id] = shape
        setStatus(.idle, of: id)
        if wasWaiting { spotChanged(id) }
    }

    // MARK: Status, observed a shape at a time

    private func setStatus(_ status: TypeSyncStatus, of id: ShapeID) {
        guard (statuses[id] ?? .idle) != status else { return }
        withMutation(keyPath: \.[status: id]) { statuses[id] = status == .idle ? nil : status }
        spotChanged(id)
    }

    /// Only a key: one key path per shape, under which Observation keeps the observers of that
    /// shape's status apart from every other shape's.
    private subscript(status id: ShapeID) -> TypeSyncStatus { statuses[id] ?? .idle }

    // MARK: Reading shapes

    /// A shape's two sides: its words (`TypeWords`) and its schema; nil for a shape that doesn't
    /// hold `Schema`, or whose kind has no words, or that is a relationship type with no words: its fields
    /// are written to its schema straight (the card's list) and its words are not drawn, so it is never
    /// synced, either way, until it has words.
    private func sides(of record: AnyShapeRecord) -> TypeSyncSides? {
        guard kinds.contains(record.kind), let schema = record[Schema.self],
              let words = editor?.registry.typeWords(of: record.kind)?.words(record) else { return nil }
        if record[RelationshipProperty.self] == true, Self.trimmed(words).isEmpty { return nil }
        return TypeSyncSides(words: words, schema: schema.text)
    }

    fileprivate nonisolated static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Words as stored, trimmed.
    fileprivate nonisolated static func trimmed(_ text: MentionText) -> String { trimmed(text.stored) }

    /// Whether `text` is JSON that says what `root` does: objects member for member in any order,
    /// arrays in order, numbers by value; whatever either's `$color` and `$autofill` say (what its shape
    /// holds, nothing its words say), a root `properties` left empty being none; and,
    /// `ignoringTitle`, whatever either's root `"title"` says (a type's name is its shape's, so a title
    /// typed in the JSON changes nothing the words say).
    private static func means(_ root: JSONNode, _ text: String, ignoringTitle: Bool, held: HeldDirectives) -> Bool {
        guard let other = try? JSONReader.read(text) else { return false }
        return same(said(root, ignoringTitle: ignoringTitle, held: held), said(other, ignoringTitle: ignoringTitle, held: held))
    }

    /// What a schema's root says to the words: without the directives held aside (`$color`, `$autofill`, what other
    /// plugins keep there), a `properties` left with nothing, or, `ignoringTitle`, its `"title"`.
    private static func said(_ root: JSONNode, ignoringTitle: Bool, held: HeldDirectives) -> JSONNode {
        guard case let .object(members) = root.value else { return root }
        let kept = members.compactMap { member -> JSONMember? in
            if ignoringTitle, member.key == "title" { return nil }
            guard member.key == "properties", case let .object(properties) = member.value.value else { return member }
            let fields = properties.filter { !held.isHeld($0.key) }
            guard !fields.isEmpty else { return nil }
            return JSONMember(key: member.key, keyRange: member.keyRange, value: JSONNode(.object(fields), range: member.value.range))
        }
        return JSONNode(.object(kept), range: root.range)
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

extension TypeSync: EditorService {
    /// Shapes that came are seen for the first time; shapes that left the file are dropped, with
    /// their call, but one moved to another board (a frame turned into a subboard takes what it held
    /// onto its board) keeps its wait and its call, since `write` finds its board as it writes, and
    /// is the same shape there; a shape whose words or schema the person changed waits `idleDelay`
    /// for more, and one that became a type by the person's edit waits as one; one whose sides undo
    /// or redo changed stops (`stop`); one no longer a type is dropped. The same for the shapes on
    /// other boards a commit reached (`ChangeSet.elsewhere`: a board taken with its owner, brought
    /// by a paste or an undo, a shape written where it isn't shown). A file put in place over the
    /// board shown (a revert, a board read again from disk) takes every shape afresh, those it left
    /// as they were too, with their waits and calls: each shows what the file holds, so its last
    /// reading that was a JSON object, from before, is in no version of it, and goes
    /// (`SchemaReadings.forget`), as a deleted shape's does.
    public func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        if changes.replacedDocument {
            takeEveryShapeAfresh(in: editor)
            return
        }
        // Off the board shown, but still in the file (moved onto another board): the same shape.
        if !changes.removed.isEmpty {
            let file = editor.file
            for id in changes.removed where file.record(id) == nil { forgetShape(id) }
        }
        for id in changes.added {
            guard let record = editor.document[id], kinds.contains(record.kind) else { continue }
            came(record, changes)
        }
        // A shape that only moved (a drag of thousands of notes) has the words and the schema it had.
        for id in changes.changed where !changes.moved.contains(id) {
            guard let record = editor.document[id], kinds.contains(record.kind) else { continue }
            changed(record, changes)
        }
        // Every shape of a board taken or brought back is here (10,000, say), and few are types:
        // what isn't of a kind that can be, and wasn't one, is passed over before anything else.
        guard !changes.elsewhere.isEmpty else { return }
        let file = editor.file
        for id in changes.elsewhere {
            guard let record = file.record(id) else {
                if shapes[id] != nil || synced[id] != nil { forgetShape(id) }
                continue
            }
            guard kinds.contains(record.kind) else { continue }
            if shapes[id] == nil { came(record, changes) } else { changed(record, changes) }
        }
    }

    /// A shape came into the file: seen for the first time.
    private func came(_ record: AnyShapeRecord, _ changes: ChangeSet) {
        see(record)
        if changes.restoredStep, shapes[record.id] != nil { restoring.insert(record.id) }
    }

    /// A shape changed: if its sides did, an edit to follow, unless it's the sync's own write, or
    /// undo or redo; and a schema that changed is read now, whichever it was. A shape that became a
    /// type is seen, and waits if the person made it one; one that stopped being one is dropped.
    private func changed(_ record: AnyShapeRecord, _ changes: ChangeSet) {
        let id = record.id
        guard let now = sides(of: record) else {
            if shapes[id] != nil || synced[id] != nil { forgetShape(id) }
            return
        }
        guard shapes[id] != nil else {
            forget(id)
            see(record)
            if changes.restoredStep {
                restoring.insert(id)
            } else if !changes.byAgent, writing?.id != id {
                // Made a type by the person (`/is-a type`): its words are ahead, an edit waiting.
                edited(id)
                // Unless the words are the schema (JSON words taken whole): then the schema is ahead,
                // and the sync takes the words from it. The last sync is said to have had the words
                // and an empty schema, which also undoes `see`'s blanking of an empty one's words.
                if held.carried(from: now.schema, into: Self.trimmed(now.words)) == Self.trimmed(now.schema) {
                    synced[id] = TypeSyncSides(words: now.words, schema: "{}")
                } else if record[RelationshipProperty.self] == true {
                    // A relationship type that has words for the first time (it was not synced while it had none, and its
                    // schema was written by the card's list): its words are ahead of the schema it has, and they are being
                    // typed (its panel's box writes each keystroke), so they wait as an edit does: read once typing pauses,
                    // or at once on the box's commit, never after the first letter.
                    synced[id]?.words = MentionText(plain: "")
                    return
                }
                // And read at once, on the next turn: a draw or an undo that follows lands first.
                commitOnNextTurn(id)
            }
            return
        }
        guard let seen = shapes[id]?.seen, seen != now else { return }
        // Read as it changes, whoever wrote it (the person, undo or redo, an agent, the sync's own
        // write, a write to a board not shown), so what's shown of a text that isn't a JSON object
        // (its highlights) is the last text it had that was one, every text it had read.
        if seen.schema != now.schema { _ = SchemaReadings.reading(of: now.schema, for: id) }
        shapes[id]?.seen = now
        if changes.restoredStep {
            stop(id)
            restoring.insert(id)
        } else if seen.words == now.words, held.sameButHeld(seen.schema, now.schema) {
            // A type given another color (its `$color`, written with its shape's color), or told whether its
            // notes fill (its `$autofill`), says what it said: nothing to follow, and the pair in step holds
            // the text as it is now.
            if synced[id]?.schema == seen.schema { synced[id]?.schema = now.schema }
            inStep(id)
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

    private func forgetShape(_ id: ShapeID) {
        forget(id)
        SchemaReadings.forget(id)
        ProseHighlights.forget(id)
    }

    /// A shape's words are done: typing them ended (Return, Escape, a click elsewhere, the keyboard
    /// gone to the panel, another board shown), so an edit waiting to sync syncs now, as the panel's
    /// ⌘↩ has it, on the scheduler's next turn: after what ended it (an undo, which stops the shape;
    /// a draw; a file put in place, which takes it afresh), so what's committed is what the shape
    /// says then. Editing that typed nothing, or whose edit already went, commits nothing: no failure
    /// is asked again but by Retry or an edit.
    public func editingDidEnd(_ id: ShapeID, in editor: CanvasEditor) {
        guard shapes[id]?.isWaiting == true else { return }
        commitOnNextTurn(id)
    }

    /// Commits an edit still waiting on the scheduler's next turn, and nothing if it isn't then (an
    /// undo stopped the shape, a draw took it afresh).
    private func commitOnNextTurn(_ id: ShapeID) {
        guard let editor else { return }
        _ = editor.scheduler.schedule(after: .zero) { [weak self] in
            guard let self, shapes[id]?.isWaiting == true else { return }
            commit(id)
        }
    }

    /// Another board is shown: every type of the file is still kept, its timer and call going on,
    /// so nothing changes; but a whole file put in place with the switch takes every shape afresh,
    /// as a board read again does.
    public func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        guard change.isFileReplaced else { return }
        takeEveryShapeAfresh(in: editor)
    }

    private func takeEveryShapeAfresh(in editor: CanvasEditor) {
        for id in Set(shapes.keys).union(synced.keys) { forgetShape(id) }
        seeEveryShape(in: editor.file)
    }

    /// Sees every type on every board of the file.
    private func seeEveryShape(in file: CanvasFile) {
        for board in file.everyBoard {
            for record in file[board].shapes where kinds.contains(record.kind) { see(record) }
        }
    }
}

/// A model call out for a shape.
private struct SyncCall {
    /// The side the answer writes.
    let writes: TypeSide
    /// Both sides as they were sent.
    let sent: TypeSyncSides
    /// The words the model was shown for the types the sides name, which its answer names them by.
    let names: SchemaReferenceNames
    /// Whether the answer's root `"title"` comes out (the shape's name went in as it).
    let named: Bool
    let number: Int
    let task: Task<Void, Never>

    var direction: SchemaPrompts.Direction { writes == .schema ? .toSchema : .toPrompt }
}

/// Where a shape's sync is.
private struct SyncShape {
    /// Both sides as the document last said them, to tell a change to either from one to
    /// something else about the shape (its frame, a lock).
    var seen: TypeSyncSides
    /// An edit is waiting to sync: on `timer`, or for the list at the caret to close.
    var isWaiting = false
    var timer: ScheduledTask?
    var call: SyncCall?
    /// A sync was asked for while the call was out: it runs once the call lands.
    var wantsSync = false
}

/// Each shape's sync, by id. A class of its own and not generic, so that its deinit can be isolated
/// to the main actor: Swift's optimizer crashes on an isolated deinit of a generic class built for a
/// macOS before 15.4 (`./build.sh` builds for 14), and `TypeSync` is generic.
@MainActor
private final class SyncShapes {
    private var byID: [ShapeID: SyncShape] = [:]

    subscript(id: ShapeID) -> SyncShape? {
        get { byID[id] }
        set { byID[id] = newValue }
    }

    var keys: Dictionary<ShapeID, SyncShape>.Keys { byID.keys }

    func removeValue(forKey id: ShapeID) -> SyncShape? { byID.removeValue(forKey: id) }

    /// The file closed and the editor went, and the sync with it: whatever is out for a shape stops.
    /// A model call in flight is cancelled, so it doesn't run on (a minute at most) spending the
    /// person's tokens on an answer nothing lands; so is each edit's wait. Isolated, so each is the
    /// main actor's to cancel, as it is while the editor lives.
    isolated deinit {
        for shape in byID.values {
            shape.timer?.cancel()
            shape.call?.task.cancel()
        }
    }
}

/// The pairs at the last sync go back and forth with undo: a step puts back what each shape it
/// brought back, or whose sides it changed, said of the other as the step began (undone) or ended
/// (redone), after the change, whose shapes stopped. The other shapes keep theirs: what a shape's
/// sync learned since without a step of its own (an answer of `NO_CHANGE` that landed while another
/// step was made) still holds of its sides, which the step didn't touch.
extension TypeSync: UndoParticipant {
    public func undoSnapshot(in editor: CanvasEditor) -> any Sendable { synced }

    public func restoreUndoSnapshot(_ snapshot: any Sendable, in editor: CanvasEditor) {
        defer { restoring = [] }
        guard let pairs = snapshot as? [ShapeID: TypeSyncSides] else { return }
        for id in restoring {
            if let pair = pairs[id] { synced[id] = pair }
            inStep(id)
        }
    }
}

/// What the sync says, beside the schema's own step name.
enum TypeSyncText {
    /// A write of the words.
    static let updateWords = "Update Text"
}

extension CanvasEditor {
    /// Types' sync between a type's words and its schema; nil without TypesPlugin.
    public var typeSync: TypeSync<TypeSchemaProperty>? { service(TypeSync<TypeSchemaProperty>.self) }
}

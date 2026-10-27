import Canvas
import CanvasRPC
import Foundation
import LanguageModels
import Mentions
import Observation

/// Where a shape's fill is, as its panel shows it.
public enum FieldFillStatus: Equatable, Sendable {
    /// Filled from its words, waiting for the person to finish, or nothing to fill.
    case idle
    /// A call is out, reading the words for the values.
    case filling
    /// The last fill didn't write, and why.
    case failed(FieldFillFailure)
}

/// Why a shape's last fill didn't write, in a fragment for a person, and what the panel offers under it: Retry,
/// Open Settings… for a key none is saved or one refused (saving one tries again by itself), or nothing
/// (`editByHand`: Claude declined, as it would again; the person rewords the words, and that edit fills).
public struct FieldFillFailure: Equatable, Sendable {
    public var message: String
    public var remedy: TypeSyncFailure.Remedy

    public init(_ message: String, remedy: TypeSyncFailure.Remedy = .retry) {
        self.message = message
        self.remedy = remedy
    }
}

/// Fills the fields of each shape of a type from its words, through the editor's language model (`FillPrompts`),
/// where the shape autofills (`TypeIndex.autofills`: its own say, else its types', else on). The words are the
/// person's and the values follow them, one way: a value changed by hand never writes the words. It reads the words
/// through `TypeWords` and writes the values through the one writer (`FieldWriter.fill`), so it knows no kind.
///
/// - What starts a fill is the person's edit of the shape itself: its words changed (filled once editing them ends,
///   `editingDidEnd`, else `idleDelay` after the last change), a type given to it (`is` gains one) or its own say turned
///   on, both read at once, on the scheduler's next turn, from the words whole; and editing it ending with words that
///   were never read, over fields none of which holds a value (a note written before its type had fields). Never an
///   agent's write (`ChangeSet.byAgent`), undo or redo, a board read again or opened, or a change to a type (which
///   would ask once for each of its shapes), nor a shape that is a type (its words are its schema's: `TypeSync`), is
///   read-only, has no words, or whose types give no fields. Without a model (a list of plugins with none) a fill fails,
///   saying so.
/// - The model is told the fields (a JSON Schema in the order of the rows, another type's fields written out in
///   place of its reference), what they hold now, today, and the words, with the words they were last filled from:
///   what changed between the two is what it is asked for, so a value typed by hand that the edit didn't touch stays.
///   A shape seen for the first time is taken as filled from the words it has, so the first edit is read against
///   them; a fill from the words whole (a type given, the say turned on, words never read) is told no words before,
///   and takes nothing away.
/// - Its answer is the changes, field by field (`FieldValuesMerge`: a group set member by member, a list whole, `null`
///   taking a value away), and only to the shape's fields: a key no field names is passed over, and so is a field the
///   person changed while the call was out (theirs stands). It is one undo step, "Fill Fields", on the shape's board,
///   shown or not, never joined to another; a shape deleted, made read-only, made a type or turned off meanwhile
///   takes nothing. Edits to the words while a call is out wait, and fill once it lands.
/// - The words each shape was filled from go back and forth with undo (`UndoParticipant`): undoing a fill leaves the
///   words ahead of the values, and nothing reads them again until the person edits them.
/// - A failure leaves the values as they are and says why; Retry, or the next edit, tries again, and a sign-in in
///   Settings does for a shape that failed for want of one. A cancelled call says nothing. The file closing cancels
///   every call out and every wait (`FillShapes`).
@MainActor
@Observable
public final class FieldFill {
    /// How long after the last keystroke an edit of the words fills by itself.
    public static var idleDelay: Duration { .seconds(3) }
    /// The undo step a fill is.
    public static let step = "Fill Fields"
    /// The undo step of saying whether a shape fills (`setAutofill`).
    public static let switchStep = "Change Autofill"
    /// What a request says today is (`FillPrompts.day(of:)`): the clock, which a test sets.
    public static var now: () -> Date = { Date() }

    // Weak: a panel's view may ask after its window, and the editor, went.
    @ObservationIgnored private weak var editor: CanvasEditor?
    @ObservationIgnored private let shapes = FillShapes()
    /// The words each shape's values were last filled from, or taken as filled from (those it had when the person
    /// first edited them); empty for words to be read whole. Apart from `shapes`, so an undo step keeps it.
    @ObservationIgnored private var filled: [ShapeID: MentionText] = [:]
    /// Observed a shape at a time (`status(of:)`); a shape with none is idle.
    @ObservationIgnored private var statuses: [ShapeID: FieldFillStatus] = [:]
    /// The shapes an undo or redo just changed: the only ones whose words its participant's restore puts back.
    @ObservationIgnored private var restoring: Set<ShapeID> = []
    /// The shape this is writing, whose commit isn't the person's edit, and the words it was filled from, which it
    /// keeps as services hear the write (inside the write's undo step, so redoing it puts them back).
    @ObservationIgnored private var writing: (id: ShapeID, words: MentionText)?
    @ObservationIgnored private var calls = 0
    /// The words of each kind that can be of a type and has them: every other shape is passed over at once.
    @ObservationIgnored private let words: [ShapeKind: TypeWordsContribution]
    @ObservationIgnored nonisolated(unsafe) private var keyObserver: (any NSObjectProtocol)?

    init(editor: CanvasEditor) {
        self.editor = editor
        let registry = editor.registry
        words = Dictionary(uniqueKeysWithValues: registry.kinds.compactMap { kind in
            registry.isTypeable(kind) ? registry.typeWords(of: kind).map { (kind, $0) } : nil
        })
        keyObserver = NotificationCenter.default.addObserver(forName: .languageModelSignInDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keyDidChange() }
        }
    }

    /// The file closed and the editor went: what each shape has out stops as `shapes` goes.
    deinit {
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
    }

    // MARK: What the panel and the rows ask

    /// Where the shape's fill is. Observing it hears only this shape's changes.
    public func status(of id: ShapeID) -> FieldFillStatus {
        access(keyPath: \.[status: id])
        return statuses[id] ?? .idle
    }

    /// Whether a call is out for the shape, read without observing it: its rows ask as they are drawn, and are drawn
    /// again as it changes. Nothing but a compare while no shape is filling or failed.
    public func isFilling(_ id: ShapeID) -> Bool {
        !statuses.isEmpty && statuses[id] == .filling
    }

    /// Tries the failed fill again.
    public func retry(_ id: ShapeID) { fill(id) }

    /// Whether the shape's kind holds a say of its own (`typeable()`): a type of one that doesn't keeps its `$autofill`
    /// in its JSON alone.
    public func holdsAutofill(_ record: AnyShapeRecord) -> Bool {
        editor?.registry.properties(for: record.kind).contains(AutofillProperty.key) == true
    }

    /// Says whether a shape fills its fields from its words (on a type, whether its shapes do), as the panel's box
    /// does: the shape holds its own say only where it differs from what its types say (`TypeIndex.autofillInherited`),
    /// so one that agrees follows them as they change; a type's is written in its schema too (`TypeAutofillDirective`).
    /// One step, "Change Autofill", on the shape's board; nothing for a shape that already says it, or of a kind that
    /// holds no say. One that can't change is refused (the core shakes it). A shape of a type turned on is read at once.
    public func setAutofill(_ on: Bool, of id: ShapeID) {
        guard let editor, let index = editor.types, let record = editor.shape(inFile: id), let board = editor.file.board(containing: id),
              editor.registry.properties(for: record.kind).contains(AutofillProperty.key) else { return }
        let own: Bool? = on == index.autofillInherited(by: id) ? nil : on
        guard own != record[AutofillProperty.self] else { return }
        if editor.isReadOnly(inFile: id) {
            editor.refuseChanges(to: [id])
            return
        }
        editor.transact(on: board, Self.switchStep) { $0.update(id) { $0[AutofillProperty.self] = own } }
    }

    // MARK: Filling

    /// The person edited the shape: a fill waits `idleDelay` for more, or, `now`, is read on the scheduler's next turn.
    private func edited(_ id: ShapeID, now: Bool = false) {
        guard let editor else { return }
        var shape = shapes[id] ?? FillShape()
        shape.isWaiting = true
        shape.timer?.cancel()
        shape.timer = now ? nil : editor.scheduler.schedule(after: Self.idleDelay) { [weak self] in self?.fill(id) }
        shapes[id] = shape
        if now { commitOnNextTurn(id) }
    }

    /// Fills now what is waiting, or once the call out lands.
    private func fill(_ id: ShapeID) {
        var shape = shapes[id] ?? FillShape()
        shape.timer?.cancel()
        shape.timer = nil
        shape.isWaiting = false
        shape.wantsFill = shape.call != nil
        shapes[id] = shape
        if shape.call == nil { start(id) }
    }

    /// Fills an edit still waiting on the scheduler's next turn (after what ended it: an undo, which stops the shape;
    /// a draw), and nothing if it isn't then.
    private func commitOnNextTurn(_ id: ShapeID) {
        guard let editor else { return }
        _ = editor.scheduler.schedule(after: .zero) { [weak self] in
            guard let self, shapes[id]?.isWaiting == true else { return }
            fill(id)
        }
    }

    /// The sign-in changed in Settings: the shapes that failed for want of one try again.
    private func keyDidChange() {
        let waiting = statuses.compactMap { id, status -> ShapeID? in
            guard case let .failed(failure) = status, failure.remedy == .signIn else { return nil }
            return id
        }
        for id in waiting { fill(id) }
    }

    /// Asks the model for the changes the words say, if they say anything new and the shape may be filled.
    private func start(_ id: ShapeID) {
        guard let editor, let record = editor.file.record(id), let kindWords = self.words[record.kind], record[TypeSchemaProperty.self] == nil else { return }
        // A new try: an old failure no longer says where things are.
        setStatus(.idle, of: id)
        guard !editor.isReadOnly(inFile: id), let index = editor.types, index.autofills(record), let book = editor.fieldBook,
              let words = kindWords.words(record), !Self.trimmed(words).isEmpty else { return }
        let previous = filled[id] ?? words
        guard Self.trimmed(previous) != Self.trimmed(words) else { return }
        let resolved = book.fields(of: record)
        guard !resolved.fields.isEmpty else { return }
        guard let model = editor.languageModel else {
            setStatus(.failed(FieldFillFailure(TypeSyncFailure.noModelMessage, remedy: .editByHand)), of: id)
            return
        }
        let keys = resolved.fields.map(\.field.name)
        let held = record[FieldValuesProperty.self] ?? FieldValues()
        var values: JSONObject = [:]
        for key in keys { values[key] = held[key] }
        // A mention reads as its name, as the note shows it.
        let label = { (shape: ShapeID) in editor.shape(inFile: shape).flatMap { editor.registry.mentionAppearance(of: $0)?.label } }
        let request = FillPrompts.request(fields: Self.fields(resolved, book: book).pretty, values: SchemaValue(.object(values)).pretty,
                                          today: FillPrompts.day(of: Self.now()), previousWords: previous.plainText(label: label),
                                          words: words.plainText(label: label))
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
        shapes[id]?.call = FillCall(words: words, values: values, keys: Set(keys), number: number, task: task)
        setStatus(.filling, of: id)
    }

    private func land(_ id: ShapeID, call number: Int, _ result: Result<ModelResponse, LanguageModelError>) {
        // A shape deleted (or read again) since has no entry, or a new one; its call was cancelled.
        guard var shape = shapes[id], let call = shape.call, call.number == number else { return }
        let again = shape.wantsFill
        shape.call = nil
        shape.wantsFill = false
        shapes[id] = shape
        setStatus(apply(result, of: call, to: id), of: id)
        if again { fill(id) }
    }

    /// Writes what the answer says, if it still may; returns the shape's status after.
    private func apply(_ result: Result<ModelResponse, LanguageModelError>, of call: FillCall, to id: ShapeID) -> FieldFillStatus {
        let response: ModelResponse
        switch result {
        case let .success(answer): response = answer
        case .failure(.cancelled): return .idle
        case let .failure(error):
            let needsSignIn = error == .notSignedIn || error == .unauthorized
            return .failed(FieldFillFailure(error.message, remedy: needsSignIn ? .signIn : .retry))
        }
        // Locked, made a type or turned off while it was out: nothing is written, nothing is refused (no shake), and
        // what the words were last filled from stays, so the next edit's fill reads this one's too.
        guard let editor, let record = editor.file.record(id), record[TypeSchemaProperty.self] == nil, !editor.isReadOnly(inFile: id),
              editor.types?.autofills(record) == true else { return .idle }
        switch FillPrompts.parse(response) {
        case let .failure(reason):
            // A refusal would be refused again: the person rewords, and that edit fills.
            return .failed(FieldFillFailure(reason, remedy: response.stopReason == .refusal ? .editByHand : .retry))
        case let .changes(changes):
            let held = record[FieldValuesProperty.self] ?? FieldValues()
            var writes: [(key: String, value: JSONValue?)] = []
            // The shape's fields alone, and of those only what the person left as it was sent.
            for (key, change) in changes.sorted(by: { $0.key < $1.key }) where call.keys.contains(key) && held[key] == call.values[key] {
                let value = change == .null ? Optional<JSONValue>.none : FieldValues.pruned(FieldValuesMerge.merged(change, into: held[key]))
                if value != held[key] { writes.append((key, value)) }
            }
            // The words it was filled from are kept as services hear the write, so the step it is holds the words before
            // as it begins and these as it ends; and here, for an answer that writes nothing.
            writing = (id, call.words)
            defer { writing = nil }
            if !writes.isEmpty { editor.fieldWriter?.fill(writes, of: id, step: Self.step) }
            filled[id] = call.words
            return .idle
        }
    }

    /// Drops what's kept of a shape, with its timer and its call.
    private func forget(_ id: ShapeID) {
        filled.removeValue(forKey: id)
        guard let shape = shapes.removeValue(forKey: id) else {
            setStatus(.idle, of: id)
            return
        }
        shape.timer?.cancel()
        shape.call?.task.cancel()
        setStatus(.idle, of: id)
    }

    /// Undo, redo or an agent changed the shape: no edit to follow, and no answer to write, since what the call asked
    /// about is no longer what the shape says.
    private func stop(_ id: ShapeID) {
        guard var shape = shapes[id] else { return }
        shape.timer?.cancel()
        shape.timer = nil
        shape.isWaiting = false
        shape.call?.task.cancel()
        shape.call = nil
        shape.wantsFill = false
        shapes[id] = shape
        setStatus(.idle, of: id)
    }

    // MARK: Status, observed a shape at a time

    private func setStatus(_ status: FieldFillStatus, of id: ShapeID) {
        guard (statuses[id] ?? .idle) != status else { return }
        withMutation(keyPath: \.[status: id]) { statuses[id] = status == .idle ? nil : status }
        // The rows draw a fill out (`isFilling`): nothing moves, so a redraw is the whole of it.
        editor?.setNeedsDisplay()
    }

    /// Only a key: one key path per shape, under which Observation keeps the observers of that shape's status apart
    /// from every other shape's.
    private subscript(status id: ShapeID) -> FieldFillStatus { statuses[id] ?? .idle }

    // MARK: Reading shapes

    /// Whether a shape's words were never read: it has some, over fields of which none holds a value.
    private func neverRead(_ record: AnyShapeRecord) -> Bool {
        guard let editor, let words = self.words[record.kind]?.words(record), !Self.trimmed(words).isEmpty,
              let fields = editor.fieldBook?.fields(of: record).fields, !fields.isEmpty else { return false }
        let held = record[FieldValuesProperty.self] ?? FieldValues()
        return fields.allSatisfy { held[$0.field.name] == nil }
    }

    /// The fields as the model is told them: a JSON Schema object whose `properties` are the fields in the order of
    /// the rows, each as its type writes it, with another type's fields written out in place of a reference to it
    /// (`urn:uuid:`, two deep at most; one to a part of a type, or to one that is gone, says nothing).
    static func fields(_ resolved: Resolved, book: FieldBook) -> SchemaValue {
        func writtenOut(_ schema: SchemaValue, depth: Int) -> SchemaValue {
            switch schema {
            case .object(let members):
                var kept: [SchemaMember] = []
                var referred: SchemaValue?
                for member in members {
                    if member.key == "$ref", case .string(let ref) = member.value, let target = SchemaReferences.target(of: ref) {
                        if target.fragment.isEmpty, depth < 2 {
                            let fields = book.fields(types: [target.shape])
                            if !fields.fields.isEmpty { referred = object(of: fields, depth: depth + 1) }
                        }
                        continue
                    }
                    kept.append(SchemaMember(key: member.key, value: writtenOut(member.value, depth: depth)))
                }
                guard case .object(let fields)? = referred else { return .object(kept) }
                // The reference's siblings (a title, a description) over the type's fields.
                return .object(kept + fields.filter { field in !kept.contains { $0.key == field.key } })
            case .array(let elements):
                return .array(elements.map { writtenOut($0, depth: depth) })
            default:
                return schema
            }
        }
        func object(of resolved: Resolved, depth: Int) -> SchemaValue {
            .object([SchemaMember(key: "type", value: .string("object")),
                     SchemaMember(key: "properties", value: .object(resolved.fields.map {
                         SchemaMember(key: $0.field.name, value: writtenOut($0.field.schema, depth: depth))
                     }))])
        }
        return object(of: resolved, depth: 0)
    }

    fileprivate nonisolated static func trimmed(_ text: MentionText) -> String { text.stored.trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension FieldFill: EditorService {
    /// What the person changed of a shape of a type: its words wait to be read, a type given to it or its say
    /// turned on is read at once from the words whole. Undo, redo and an agent's write stop the shape, the last
    /// taken as filled from what it says; a shape gone, or made a type, is dropped. The same for the shapes on other
    /// boards a commit reached (`ChangeSet.elsewhere`). A file put in place takes every shape afresh: each is
    /// seen as it is, filled from what it says.
    public func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        if changes.replacedDocument {
            forgetEveryShape()
            return
        }
        let file = editor.file
        if !changes.removed.isEmpty {
            for id in changes.removed where file.record(id) == nil { forget(id) }
        }
        // A shape that only moved has the words it had.
        for id in changes.changed where !changes.moved.contains(id) {
            guard let record = editor.document[id], words[record.kind] != nil else { continue }
            changed(record, changes, in: editor)
        }
        guard !changes.elsewhere.isEmpty else { return }
        for id in changes.elsewhere {
            guard let record = file.record(id) else {
                forget(id)
                continue
            }
            guard words[record.kind] != nil else { continue }
            changed(record, changes, in: editor)
        }
    }

    private func changed(_ record: AnyShapeRecord, _ changes: ChangeSet, in editor: CanvasEditor) {
        let id = record.id
        guard let before = changes.before(id), let typeWords = self.words[record.kind] else { return }
        guard record[TypeSchemaProperty.self] == nil else {
            if shapes[id] != nil || filled[id] != nil { forget(id) }
            return
        }
        let words = typeWords.words(record)
        if let writing, writing.id == id {
            filled[id] = writing.words
            return
        }
        if changes.restoredStep {
            stop(id)
            restoring.insert(id)
            return
        }
        if changes.byAgent {
            // An agent's write is none of the person's: what it says is taken as filled, so neither its words nor a
            // later end of editing that types nothing reads them.
            stop(id)
            filled[id] = words
            return
        }
        // Given a type, or its own say turned on: read at once, from the words whole.
        let types = Set((record[IsAProperty.self] ?? []).map(\.shape)), typesBefore = Set((before[IsAProperty.self] ?? []).map(\.shape))
        let own = record[AutofillProperty.self], ownBefore = before[AutofillProperty.self]
        let turnedOn = own != ownBefore && (own ?? editor.types?.autofillInherited(by: id) ?? true)
            && !(ownBefore ?? editor.types?.autofillInherited(by: id) ?? true)
        if !types.isSubset(of: typesBefore) || turnedOn {
            filled[id] = ""
            edited(id, now: true)
            return
        }
        let wordsBefore = typeWords.words(before)
        guard words != wordsBefore, !types.isEmpty else { return }
        // Seen for the first time: filled from what it said before this edit.
        if filled[id] == nil { filled[id] = wordsBefore }
        edited(id)
    }

    /// A shape's words are done: typing them ended, so an edit waiting fills now, on the scheduler's next turn; and
    /// words that were never read (over fields none of which holds a value) are read whole.
    public func editingDidEnd(_ id: ShapeID, in editor: CanvasEditor) {
        if shapes[id]?.isWaiting == true {
            commitOnNextTurn(id)
            return
        }
        guard filled[id] == nil, let record = editor.file.record(id), words[record.kind] != nil, record[TypeSchemaProperty.self] == nil,
              shapes[id]?.call == nil, neverRead(record) else { return }
        filled[id] = ""
        edited(id, now: true)
    }

    /// Another board is shown: every shape of the file is still kept, its wait and its call going on; but a whole file
    /// put in place with the switch takes every shape afresh.
    public func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        guard change.isFileReplaced else { return }
        forgetEveryShape()
    }

    private func forgetEveryShape() {
        for id in Set(shapes.keys).union(filled.keys).union(statuses.keys) { forget(id) }
    }
}

/// The words each shape was filled from go back and forth with undo: a step puts back what each shape it changed was
/// filled from as the step began (undone) or ended (redone). The other shapes keep theirs.
extension FieldFill: UndoParticipant {
    public func undoSnapshot(in editor: CanvasEditor) -> any Sendable { filled }

    public func restoreUndoSnapshot(_ snapshot: any Sendable, in editor: CanvasEditor) {
        defer { restoring = [] }
        guard let words = snapshot as? [ShapeID: MentionText] else { return }
        for id in restoring {
            filled[id] = words[id]
        }
    }
}

/// A model call out for a shape.
private struct FillCall {
    /// The words as they were sent.
    let words: MentionText
    /// The values of the shape's fields as they were sent, by key.
    let values: JSONObject
    /// The shape's fields' keys: the only members of an answer written.
    let keys: Set<String>
    let number: Int
    let task: Task<Void, Never>
}

/// Where a shape's fill is.
private struct FillShape {
    /// An edit is waiting to fill: on `timer`, or for the scheduler's next turn.
    var isWaiting = false
    var timer: ScheduledTask?
    var call: FillCall?
    /// A fill was asked for while the call was out: it runs once the call lands.
    var wantsFill = false
}

/// Each shape's fill, by id: a class of its own so that its deinit can be isolated to the main actor, as the sync's
/// is (`SyncShapes`).
@MainActor
private final class FillShapes {
    private var byID: [ShapeID: FillShape] = [:]

    subscript(id: ShapeID) -> FillShape? {
        get { byID[id] }
        set { byID[id] = newValue }
    }

    var keys: Dictionary<ShapeID, FillShape>.Keys { byID.keys }

    func removeValue(forKey id: ShapeID) -> FillShape? { byID.removeValue(forKey: id) }

    /// The file closed and the editor went, and the fill with it: whatever is out for a shape stops, so a call in
    /// flight spends nothing on an answer nothing lands.
    isolated deinit {
        for shape in byID.values {
            shape.timer?.cancel()
            shape.call?.task.cancel()
        }
    }
}

extension CanvasEditor {
    /// Types' filling of a shape's fields from its words; nil without TypesPlugin.
    public var fieldFill: FieldFill? { service(FieldFill.self) }
}

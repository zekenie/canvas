import Canvas
import Foundation
import Observation
import Queries
import QueryLanguage
import QueryTranslation
import Selection
import Titles

// The words of a constraint, typed in the Rules tab: a row's box (its words, which a change asks the model to turn into a
// new query) and the box that adds one. Constraints is the host of those words (`InterpretationHost`) for the one
// lifecycle every host of words shares (`editor.interpretations`): words that already read as a stored query are that
// query at once, others rest and are asked of the model, in the accepts context for the place's name, and what comes
// lands as the step the change is ("Change Constraint", "Add Constraint"), if the words are still there.

/// A box of the Rules tab, or of the board's funnel (its popover holds the same rows): the words of one constraint of a list
/// (`constraint` as stored), or the box that adds one.
public struct ConstraintBox: Hashable, Sendable {
    /// Whose list it is: a container, what keeps a list its own way (a type), or the root.
    public let place: ConstraintTarget
    /// The constraint the box edits, as stored; nil for the box that adds one.
    public let constraint: Constraint?

    public init(place: ConstraintTarget, constraint: Constraint?) {
        self.place = place
        self.constraint = constraint
    }

    /// A shape's list: a container's, or a holder's.
    public init(holder: ShapeID, constraint: Constraint?) {
        self.init(place: .shape(holder), constraint: constraint)
    }

    var target: ConstraintTarget { place }

    /// A box is its place's and its words: a write that changes the constraint's reach or query (the pop-up, the query box, an
    /// agent) leaves its draft and what's asked of it where they are.
    public static func == (a: Self, b: Self) -> Bool { a.place == b.place && a.constraint?.says == b.constraint?.says }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(place)
        hasher.combine(constraint?.says)
    }
}

extension ConstraintTarget {
    /// The shape an interpretation of a place's words is kept under (`InterpretationKey`): the shape's own; the root has no shape,
    /// so its words are kept under an id no shape has.
    var interpretationShape: ShapeID {
        switch self {
        case .shape(let id): id
        case .root: Self.rootInterpretation
        }
    }

    /// The place an interpretation is kept under.
    init(interpretationShape id: ShapeID) {
        self = id == Self.rootInterpretation ? .root : .shape(id)
    }

    private static let rootInterpretation = ShapeID(UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)))

    /// Whether the list can't change just now: a shape that is read-only, or the root of a board that is.
    @MainActor
    func isFrozen(in editor: CanvasEditor) -> Bool {
        switch self {
        case .shape(let id): editor.isReadOnly(inFile: id)
        case .root: editor.isBoardReadOnly
        }
    }
}

/// What's asked of a box's words now, as its row says it.
public enum ConstraintBoxStatus: Equatable {
    /// Nothing: the words are the constraint's, or there are none.
    case none
    /// Resting before the model is asked, or the model's call is out.
    case interpreting
    /// A query for the words, which committing them writes.
    case drafted(String)
    /// It didn't come, and why, in the words every host says.
    case failed(InterpretationStatus)
    /// The words are the list's already (for the box that adds one): said, with nothing asked and nothing written.
    case held(String)
    /// The words' query came and the holder wouldn't take it (a type whose schema isn't JSON yet), and why: the words wait in the box.
    case refused(String)
}

/// The boxes of the Rules tab: the words typed in each (a draft, until it lands or is let go), what's asked of them, and the
/// writes they make. `editor.constraintBoxes`; the panel reads it observed, by its revision.
@MainActor
@Observable
public final class ConstraintBoxes {
    @ObservationIgnored private weak var editor: CanvasEditor?
    /// The words typed in a box that aren't its constraint's: what it shows until they land.
    @ObservationIgnored private var drafts: [ConstraintBox: String] = [:]
    /// The boxes being typed into: an answer that comes meanwhile is a draft and lands once the keyboard has left.
    @ObservationIgnored private var typing: Set<ConstraintBox> = []
    @ObservationIgnored private var boxes: [InterpretationKey: ConstraintBox] = [:]
    /// The query that came for a box's words and that its holder wouldn't take, or that landed on a list that turned read-only
    /// meanwhile: written again if the words are committed again unchanged, let go of with the words.
    @ObservationIgnored private var refusedLandings: [ConstraintBox: String] = [:]
    /// Bumped by anything a box shows: what a row of the panel reads, to be drawn again.
    public private(set) var revision = 0

    init(editor: CanvasEditor) { self.editor = editor }

    /// The editor, for the views that go to shapes, light them and complete a query.
    var editorLent: CanvasEditor? { editor }

    private func changed() { revision += 1 }

    // MARK: What a box shows

    /// The words in a box: what was typed and has not landed, else the constraint's.
    public func text(of box: ConstraintBox) -> String { drafts[box] ?? box.constraint?.says ?? "" }

    /// What's asked of a box's words.
    public func status(of box: ConstraintBox) -> ConstraintBoxStatus {
        guard drafts[box] != nil else { return .none }
        if let line = alreadyHeld(box) { return .held(line) }
        // The line under the box goes when its holder can take a list again: the words wait, and nothing is asked until Return.
        if refusedLandings[box] != nil, let writer = editor?.constraintWriter, let id = box.place.shape, writer.stillRefuses(id) { return .refused(writer.refusal(of: id, adding: box.constraint == nil)) }
        switch editor?.interpretations?.state(at: key(of: box)) {
        case .interpreting?: return .interpreting
        case .drafted(let query, _)?: return .drafted(query)
        case .failed(let status)?: return .failed(status)
        case .waiting?, nil:
            // Words that are no query, with nothing to ask the model with.
            return editor?.queryTranslator == nil ? .failed(.unavailable) : .none
        }
    }

    /// What is said of the words typed in the box that adds one when its list has them already (folded as a list compares them):
    /// nothing is asked of the model for them; nil for other words, and for a row's box.
    func alreadyHeld(_ box: ConstraintBox) -> String? {
        guard box.constraint == nil, let text = drafts[box], let editor, let writer = editor.constraintWriter else { return nil }
        let words = Constraint.folded(text)
        guard !words.isEmpty, (writer.constraints(of: box.target) ?? []).contains(where: { $0.says == words }) else { return nil }
        return ConstraintsStyle.alreadyAccepts(editor.constraintIndex?.name(of: box.target) ?? ConstraintsStyle.thisBoard, words)
    }

    /// Whether words are waiting in a box for their query to land.
    public func hasDraft(_ box: ConstraintBox) -> Bool { drafts[box] != nil }

    func key(of box: ConstraintBox) -> InterpretationKey {
        guard let constraint = box.constraint else { return InterpretationKey(shape: box.place.interpretationShape, slot: "add") }
        return InterpretationKey(shape: box.place.interpretationShape, slot: ["row", constraint.says].joined(separator: "\u{1F}"))
    }

    // MARK: Typing

    /// A box's text changed: words that are the constraint's are no draft; else they are one, and the lifecycle takes them
    /// (a query at once, else the model after they rest).
    public func typed(_ text: String, in box: ConstraintBox) {
        let key = key(of: box)
        typing.insert(box)
        boxes[key] = box
        refusedLandings[box] = nil
        if let base = box.constraint, Constraint.folded(text) == base.says {
            drafts[box] = nil
            editor?.interpretations?.drop(key)
        } else {
            drafts[box] = text
            if alreadyHeld(box) != nil {
                editor?.interpretations?.drop(key)
            } else {
                editor?.interpretations?.typed(text, at: key, interprets: true, host: self)
            }
        }
        changed()
    }

    /// Return, or the keyboard leaving a box: words typed are asked about (or land, if their query has come); a row emptied
    /// goes, as a rule does.
    public func commit(_ box: ConstraintBox) {
        typing.remove(box)
        let key = key(of: box)
        guard let text = drafts[box] else { return }
        if Constraint.folded(text).isEmpty {
            drafts[box] = nil
            refusedLandings[box] = nil
            editor?.interpretations?.drop(key)
            if let constraint = box.constraint { editor?.constraintWriter?.remove(constraint, from: box.target) }
        } else if alreadyHeld(box) != nil {
            // The list has the words: they stay in the box with what is said of them, and nothing is asked.
        } else if let query = refusedLandings[box] {
            // Its query came, and its holder wouldn't take it: tried again, as the words are committed again.
            land(query, words: Constraint.folded(text), at: key)
        } else {
            editor?.interpretations?.editingEnded(at: key)
        }
        changed()
    }

    /// Lets go of what a box was asked, and its words: Escape in a box with words typed that haven't landed (a row's shows its
    /// constraint's again).
    public func discard(_ box: ConstraintBox) {
        guard drafts[box] != nil else { return }
        typing.remove(box)
        drafts[box] = nil
        refusedLandings[box] = nil
        editor?.interpretations?.drop(key(of: box))
        changed()
    }

    // MARK: Interpreting

    /// Asks the model for a query for words that have none (an interpretation that never came, a list an agent wrote): it lands
    /// as "Change Constraint".
    public func interpret(_ box: ConstraintBox) {
        guard let constraint = box.constraint, !hasDraft(box), let interpretations = editor?.interpretations, editor?.queryTranslator != nil,
              !(editor.map { box.place.isFrozen(in: $0) } ?? true) else { return }
        let key = key(of: box)
        boxes[key] = box
        drafts[box] = constraint.says
        interpretations.interpret(constraint.says, at: key, host: self)
        changed()
    }

    /// Whether Interpret is offered for a row: words with no query that nobody is asking about, something to ask with, and a
    /// list that can change.
    public func offersInterpret(_ box: ConstraintBox) -> Bool {
        guard let constraint = box.constraint, !constraint.isInterpreted, !hasDraft(box), let editor, editor.queryTranslator != nil else { return false }
        return !box.place.isFrozen(in: editor)
    }

    /// Asks again what failed.
    public func retry(_ box: ConstraintBox) {
        editor?.interpretations?.retry(at: key(of: box))
    }

    // MARK: Writing

    /// A query written by hand for a row: nil once written, else the engine's refusal in its words. It reads only the file
    /// (no word that reads the editor, no `:scope`), as every stored query does.
    public func write(_ query: String, of constraint: Constraint, in place: ConstraintTarget) -> String? {
        guard let editor, let queries = editor.queries else { return ConstraintsStyle.noQueries.message }
        do throws(QueryError) {
            let plan = try queries.checkStored(query)
            // Against what the box showed (the titles the shapes have now), so leaving it unchanged writes nothing; what is
            // written is bound again, as written.
            if shown(constraint) != plan.canonical { editor.constraintWriter?.setQuery(plan.canonical, of: constraint, in: place, rebinding: true) }
            return nil
        } catch {
            return error.message
        }
    }

    /// `write`, for a shape's list.
    public func write(_ query: String, of constraint: Constraint, in holder: ShapeID) -> String? {
        write(query, of: constraint, in: .shape(holder))
    }

    /// A constraint's query as a person reads it: with each title a shape it names has now (a type renamed shows its new
    /// name), canonical. Its own as stored while it names no shape. Observes an edit to the shapes it names, and no other commit.
    public func shown(_ constraint: Constraint) -> String? {
        guard let query = constraint.query else { return nil }
        guard !constraint.names.isEmpty, let queries = editor?.queries else { return query }
        editor?.constraintIndex?.observeNames(of: constraint)
        return queries.named(query, by: constraint.names, as: .titles)
    }

    /// A row's reach changed (its pop-up).
    public func setReach(_ reach: ConstraintReach, of constraint: Constraint, in place: ConstraintTarget) {
        editor?.constraintWriter?.setReach(reach, of: constraint, in: place)
    }

    /// `setReach`, for a shape's list.
    public func setReach(_ reach: ConstraintReach, of constraint: Constraint, in holder: ShapeID) {
        setReach(reach, of: constraint, in: .shape(holder))
    }

    /// Removes a row (its ×).
    public func remove(_ constraint: Constraint, from place: ConstraintTarget) {
        editor?.constraintWriter?.remove(constraint, from: place)
    }

    /// `remove`, for a shape's list.
    public func remove(_ constraint: Constraint, from holder: ShapeID) {
        remove(constraint, from: .shape(holder))
    }

    /// Goes to shapes on the next turn, one step back: the click's view goes with the panel it's in.
    func go(to ids: [ShapeID]) {
        guard let editor, !ids.isEmpty else { return }
        _ = editor.scheduler.schedule(after: .zero) { [weak editor] in editor?.goTo(ids) }
    }
}

// MARK: The host

extension ConstraintBoxes: InterpretationHost {
    /// What a place accepts: the place's name, as the rule names it.
    public func context(of key: InterpretationKey) -> TranslationContext {
        .accepting(holder: editor?.constraintIndex?.holderName(of: ConstraintTarget(interpretationShape: key.shape)) ?? ConstraintsStyle.thisBoard.lowercased())
    }

    public func holdsWords(_ words: String, at key: InterpretationKey) -> Bool {
        guard let box = boxes[key], let draft = drafts[box] else { return false }
        return draft.trimmingCharacters(in: .whitespacesAndNewlines) == words
    }

    /// A draft asks nothing of the file: the query is what a row shows.
    public func request(for _: String, at _: InterpretationKey) -> QueryMatchRequest? { nil }

    /// Writes what came for words after the keyboard left: a constraint with them replaces the one the box edited (as the list has
    /// it now, its reach as it is now), or is added. One step, if the words are still there and the list can change; one that can't (a holder that won't take a list, a read-only list) shakes, and the words stay with their query, to be committed again.
    public func land(_ query: String, words: String, at key: InterpretationKey) {
        guard holdsWords(words, at: key), let box = boxes[key], let writer = editor?.constraintWriter else { return }
        var edit = ConstraintEdit.unchanged
        if let edited = box.constraint {
            // The row as the list has it now: its reach or query may have changed while the model was out.
            if let current = (writer.constraints(of: box.target) ?? []).first(where: { $0.says == edited.says }) {
                edit = writer.tryReplace(current, with: Constraint(says: words, query: query, reach: current.reach), in: box.target)
            }
        } else {
            edit = writer.tryAdd(Constraint(says: words, query: query, reach: .children), to: box.target)
        }
        if edit == .refused {
            // The holder shook (and said so, if it has words for it: the writer): the words stay in the box, with their query, to be committed again.
            refusedLandings[box] = query
            changed()
            return
        }
        drafts[box] = nil
        boxes[key] = nil
        typing.remove(box)
        refusedLandings[box] = nil
        changed()
    }

    public func interpretAgain(at key: InterpretationKey) {
        guard let box = boxes[key], let words = drafts[box] else { return }
        editor?.interpretations?.interpret(words, at: key, host: self)
    }

    public func interpretationDidChange(at _: InterpretationKey) { changed() }

    /// The keyboard is in the box until it commits.
    public func isEditing(at key: InterpretationKey) -> Bool? {
        boxes[key].map { typing.contains($0) } ?? false
    }
}

extension ConstraintBoxes: EditorService {
    /// A draft of a row whose words are gone from its list (an undo, a removal) is let go of; a file put in place lets go of every one.
    public func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        guard !drafts.isEmpty else { return }
        for box in Array(drafts.keys) {
            let stale = changes.replacedDocument || box.constraint.map { edited in !(editor.constraintWriter?.constraints(of: box.target)?.contains { $0.says == edited.says } ?? false) } ?? false
            guard stale else { continue }
            drafts[box] = nil
            typing.remove(box)
            editor.interpretations?.drop(key(of: box))
        }
        changed()
    }
}

extension CanvasEditor {
    /// The boxes of the Rules tab's constraints: nil without `ConstraintFacesPlugin`.
    public var constraintBoxes: ConstraintBoxes? { service(ConstraintBoxes.self) }
}

extension ConstraintIndex {
    /// What a place is called to the model that writes its query: a container or the root as the rule names it ("Backlog"); a
    /// holder as it names its places ("each sprint").
    func holderName(of target: ConstraintTarget) -> String {
        if case .shape(let id) = target, let places = editor?.constraintPlaces(of: id) { return places }
        // An untitled place is named as a sentence starts ("This frame"); the model is told it in the middle of one.
        let named = name(of: target)
        var titled = false
        switch target {
        case .root: titled = !(editor?.rootName.isEmpty ?? true)
        case .shape(let id): titled = editor?.shape(inFile: id).flatMap { editor?.registry.title(of: $0) } != nil
        }
        if !titled { return named.prefix(1).lowercased() + named.dropFirst() }
        return named
    }
}

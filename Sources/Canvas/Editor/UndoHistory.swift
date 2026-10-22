/// A service whose state goes back and forth with the steps (the selection). Its snapshot is taken
/// as a step opens (before services hear the step's first commit) and as it closes; undoing a step
/// restores the snapshot from before it, and redoing it the one from after, once services have heard
/// the change.
@MainActor
public protocol UndoParticipant: EditorService {
    func undoSnapshot(in editor: CanvasEditor) -> any Sendable
    func restoreUndoSnapshot(_ snapshot: any Sendable, in editor: CanvasEditor)
}

/// What happened to a board's history, for the host that counts the board's changes: a step
/// `began` (the board is edited), was `discarded` (it came to nothing: as it was), `closed` (it's on
/// the stack, to undo), was undone (`undid`) or redone (`redid`); or the history was `cleared` (a
/// new document).
@_spi(Host)
public enum UndoEvent: Sendable, Equatable {
    case began, discarded, closed, undid, redid, cleared
}

/// A file's undo and redo: one per editor, so one per board file, whatever board of it is shown.
/// Every commit is recorded into the step that's open, and a step is what someone thinks of as one
/// action:
///
/// - an action: a press (from the press to the release, its whole drag), a key stroke on the
///   canvas, a command (`editor.perform`), or `group`; actions nest, and the outermost is the step;
/// - an editing session (typing into a note): its view's commits, and those of the action that
///   began it (placing a note and typing into it are one step);
/// - a run of commits under one coalescing key at no action's depth (`transact(coalescing:)`: a
///   panel field typed into), until another commit, an action or `seal()`;
/// - a card's commits (`transact(coalescing: card.id)` while a card with a step name shows,
///   `CanvasEditor.showCard`), from the moment it shows until it closes, which `seal()` does not end
///   and any other commit does;
/// - otherwise, each commit.
///
/// A step that comes to nothing (a drag put back with Escape) is dropped. Opening a step clears
/// what there was to redo. Undo and redo put records back exactly, as ordinary commits services hear
/// (`editor.undo()`), below the rules transactions keep (nothing is read-only to them), and restore
/// what `UndoParticipant`s kept (the selection). A step's name is its outermost named group's, else
/// its first named transaction's (`transact("Move")`), else "Typing" for an editing step.
///
/// A step is made on one board, the one shown as it opens (`DocumentDelta.board`): showing another
/// closes it, and isn't a step itself. Undoing or redoing a step made on another board shows that
/// board first (`editor.undo()`).
@MainActor
public final class UndoHistory {
    struct Step {
        let name: String?
        /// On the board it was made on (`delta.board`).
        let delta: DocumentDelta
        let before: [ObjectIdentifier: any Sendable]
        let after: [ObjectIdentifier: any Sendable]
    }

    /// What holds the open step open.
    private enum Holder: Equatable {
        /// An action, or a press: until the outermost ends.
        case action
        /// An editing session, until it ends.
        case editing
        /// A run of commits under one key.
        case run(AnyHashable)
        /// One commit at no action's depth: closes once services have heard it.
        case single
        /// A key's action committed it, and the key may be held: its repeats are part of it, until
        /// it's let go or anything else happens.
        case held(KeyStroke)
        /// A card's commits, under its id: from the card showing until it closes.
        case kept(AnyHashable)
    }

    private struct OpenStep {
        var holder: Holder
        var builder: DocumentDelta.Builder
        var groupName: String?
        var firstName: String?
        /// What an editing session's step is called when nothing else names it (`Editable.editingStepName`).
        var editingName: String?
        /// What runs as it closes, its last commits (`finishing`), in the order first asked, one a key.
        var finishes: [(key: AnyHashable, body: @MainActor () -> Void)] = []
        let before: [ObjectIdentifier: any Sendable]
        var name: String? { groupName ?? firstName ?? (holder == .editing ? editingName ?? "Typing" : nil) }
    }

    /// Where a commit comes from: an editing view's (`EditContext`), or anything else.
    enum Origin { case ordinary, editing }

    weak var editor: CanvasEditor?
    /// The editor's undo participants, found once its services are made.
    var participants: [any UndoParticipant] = []
    private(set) var undos: [Step] = []
    private(set) var redos: [Step] = []
    private var open: OpenStep?
    /// How deep in actions: 0 at none. Only the outermost counts.
    private var depth = 0
    /// The names of the groups under way, outermost first (nil for an unnamed action).
    private var groupNames: [String?] = []
    /// A press is under way (`pressBegan` to `pressEnded`).
    private var isInPress = false
    /// An editing session is under way.
    private var isEditing = false
    /// Editing began inside the action under way: when it ends, its step goes on as the editing one.
    private var editingBeganInAction = false
    /// What the editing session's step is called (`Editable.editingStepName`); nil: "Typing".
    private var editingName: String?
    /// The key the canvas last had a stroke of, until it's let go (`keyReleased`).
    private var keyDown: KeyStroke?
    /// The card showing that holds a step: its id and the name of its step (`keep`).
    private var keptRun: (key: AnyHashable, name: String)?
    /// The card was shown inside an action and takes its step on (`CanvasCard.adoptsPress`): when the
    /// action ends, its open step stays open as the card's, to close with the card.
    private var adoptsAction = false
    /// A commit is under way (`willCommit`): what a step closing then would finish with is dropped.
    private var isCommitting = false

    init() {}

    /// Called with each event, for the host (`BoardDocument` counts the board's changes with them).
    @_spi(Host) public var didChange: (@MainActor (UndoEvent) -> Void)?

    // MARK: Reading

    /// Whether there's a step to undo: the open one, with changes, or one on the stack whose board
    /// can be shown.
    var hasUndo: Bool { openHasChanges || canApply(undos.last) }

    /// Whether there's a step to redo whose board can be shown.
    var hasRedo: Bool { canApply(redos.last) }

    /// The board the newest step to undo was made on (once the open one is closed, as undo closes it).
    var undoBoard: BoardID? { undos.last?.delta.board }

    /// The board the newest step to redo was made on.
    var redoBoard: BoardID? { redos.last?.delta.board }

    /// A step is undone and redone on the board it was made on, which is shown first if it isn't.
    /// That board can always be shown, since steps come back last in, first out, and every change
    /// to the file is one: the file is as the step left it. Were it ever not (`canShow`), the step
    /// isn't undone or redone, and stays where it is.
    private func canApply(_ step: Step?) -> Bool {
        guard let step, let editor else { return false }
        return CanvasEditor.canShow(step.delta.board, in: editor.storedFile, registry: editor.registry)
    }

    /// Whether the open step has changed the board: it touched a shape that isn't as it was. (A
    /// run typed and typed back has touched shapes, but changed nothing: closing it drops it, and
    /// Undo would undo the step before it.) Costs the shapes it touched, at most.
    private var openHasChanges: Bool {
        guard let open, open.builder.isHolding, let editor else { return false }
        return open.builder.hasChanges(now: editor.storedFile)
    }

    /// See `CanvasEditor.canUndo`, which also waits for a press's session and a transaction.
    public var canUndo: Bool { editor?.canUndo ?? false }
    /// See `CanvasEditor.canRedo`.
    public var canRedo: Bool { editor?.canRedo ?? false }

    /// The name of the step undo would undo: nil for a plain "Undo".
    public var undoName: String? {
        if openHasChanges { return open?.name }
        return canApply(undos.last) ? undos.last?.name : nil
    }

    /// The name of the step redo would redo: nil for a plain "Redo".
    public var redoName: String? { canApply(redos.last) ? redos.last?.name : nil }

    /// A press is under way and its step has changes: an autosave that can wait, waits, so it
    /// doesn't split the press.
    @_spi(Host) public var isPressing: Bool { isInPress && open?.builder.isHolding == true }

    /// A key is held down whose step is open for its repeats, with changes (a held arrow key's
    /// nudges): an autosave that can wait, waits, as for a press, so it doesn't split them. The step
    /// closes as the key is let go, and the autosave runs then.
    @_spi(Host) public var isKeyHolding: Bool {
        guard let keyDown, let open, case .held(let key) = open.holder, open.builder.isHolding else { return false }
        return Self.isSameKey(keyDown, key)
    }

    /// A press is held, changes or not: from the press to its release, whatever commits is part of
    /// its step, whoever commits it. What changes the board for someone else (the command line's
    /// `draw`) waits for the release, so that its change is a step of its own.
    public var isPressHeld: Bool { isInPress }

    /// An action is under way (a press, a key, a command, a group): it owns the open step.
    var isInAction: Bool { depth > 0 }

    // MARK: Grouping

    /// Everything `body` commits is one step, named `name` (unless a group it's in has a name); in
    /// any action (a press, a key, a command, another group), part of that one's step.
    @discardableResult
    public func group<T>(_ name: String? = nil, _ body: () throws -> T) rethrows -> T {
        actionBegan(name)
        defer { actionEnded() }
        return try body()
    }

    /// A new gesture began where the editor can't see it (a click in a panel, the keyboard moving to
    /// another field): ends a run of commits under one coalescing key, or a held key's, so the next
    /// is a step of its own. Never ends a press's, an action's or an editing session's step.
    public func seal() {
        switch open?.holder {
        case .run?, .held?: if depth == 0 { close() }
        default: break
        }
    }

    /// `body` runs as the step open now closes, whatever closes it (a held key let go, another action, Undo, another
    /// board shown), and what it commits is that step's last: a held arrow key's nudges settle into or out of a
    /// container once, as the key is let go, not at every repeat. One a `key` a step: asked again under the same key,
    /// the later body runs in its place. With no step open, nothing runs. A body the step closes where nothing may
    /// commit (inside a commit) is dropped. Whether a step was open to take it.
    @discardableResult
    public func finishing(_ key: AnyHashable, _ body: @escaping @MainActor () -> Void) -> Bool {
        guard open != nil else { return false }
        if let index = open?.finishes.firstIndex(where: { $0.key == key }) {
            open?.finishes[index].body = body
        } else {
            open?.finishes.append((key, body))
        }
        return true
    }

    /// Whether the step open now finishes with something under `key` (`finishing`): false once it has closed.
    public func willFinish(_ key: AnyHashable) -> Bool { open?.finishes.contains { $0.key == key } ?? false }

    /// A card with a step name shows: commits under `key` are one step called `name` until `letGo`. A
    /// step kept under another key or name closes. Opens nothing, so the press a card is shown in keeps
    /// its own step, unless the card `adopts` it and is shown inside an action: that action's step is
    /// then the card's when the action ends, and keeps its name.
    func keep(_ key: AnyHashable, named name: String, adopting adopts: Bool = false) {
        if case .kept(let kept)? = open?.holder, kept != key || keptRun?.name != name { close() }
        keptRun = (key, name)
        adoptsAction = adopts && depth > 0
    }

    /// The card holds no step now (it closed, or its step name went): the step it held closes. Never
    /// another holder's, since this runs inside the commit that deleted the card's shape, when the open
    /// step may be that commit's.
    func letGo() {
        if case .kept? = open?.holder { close() }
        keptRun = nil
        adoptsAction = false
    }

    /// A save point: closes the open step, whatever holds it. Later commits of the same press, run or
    /// editing session make a step of their own, so a board saved mid-step can undo to exactly what
    /// was saved.
    @_spi(Host) public func breakStep() { close() }

    /// Forgets every step (a new document is in place): nothing to undo or redo.
    @_spi(Host) public func clear() {
        open = nil
        undos = []
        redos = []
        didChange?(.cleared)
    }

    // MARK: What the editor tells it

    func actionBegan(_ name: String? = nil) {
        // An editing session's step stays open through an action that commits nothing of its own
        // (Undo, which ends editing: the view's closing save is still the session's).
        if depth == 0, !isEditingStepOpen { close() }
        depth += 1
        groupNames.append(name)
    }

    /// A key pressed on the canvas: an action, whose step, if it commits something, stays open for
    /// the key's repeats (a held arrow key's nudges are one step), which go on in it; its release
    /// (`keyReleased`), or anything else, closes it.
    func key<T>(_ stroke: KeyStroke, _ body: () throws -> T) rethrows -> T {
        let key = KeyStroke(stroke.characters, modifiers: stroke.modifiers, numberRowKey: stroke.numberRowKey)
        keyDown = key
        if stroke.isRepeat, depth == 0, open?.holder == .held(key) {
            open?.holder = .action
            depth += 1
            groupNames.append(nil)
        } else {
            actionBegan()
        }
        defer { actionEnded(holding: key) }
        return try body()
    }

    /// A key let go on the canvas (nil: every key, as the canvas lost the keyboard): the step its
    /// strokes held open for their repeats closes. Keys are matched by what they type, whatever the
    /// modifiers (⇧ may come up before the arrow it was held with).
    func keyReleased(_ stroke: KeyStroke?) {
        if let keyDown, stroke.map({ Self.isSameKey($0, keyDown) }) ?? true { self.keyDown = nil }
        guard depth == 0, case .held(let key)? = open?.holder, stroke.map({ Self.isSameKey($0, key) }) ?? true else { return }
        close()
    }

    private static func isSameKey(_ a: KeyStroke, _ b: KeyStroke) -> Bool { a.characters.lowercased() == b.characters.lowercased() }

    func actionEnded(holding key: KeyStroke? = nil) {
        precondition(depth > 0, "an action ended that didn't begin")
        depth -= 1
        groupNames.removeLast()
        guard depth == 0 else { return }
        if editingBeganInAction, isEditing {
            open?.holder = .editing
            open?.editingName = editingName
        } else if adoptsAction, let run = keptRun, open?.holder == .action {
            open?.holder = .kept(run.key)
        } else if let key, open?.holder == .action {
            open?.holder = .held(key)
        } else if !isEditingStepOpen {
            close()
        }
        editingBeganInAction = false
        adoptsAction = false
    }

    /// A press began. One whose release never came (a lost mouse-up) ends first.
    func pressBegan() {
        if isInPress { pressEnded() }
        isInPress = true
        actionBegan()
    }

    func pressEnded() {
        guard isInPress else { return }
        isInPress = false
        actionEnded()
    }

    func editingBegan(stepName: String? = nil) {
        isEditing = true
        editingName = stepName
        if depth == 0 { close() } else { editingBeganInAction = true }
    }

    /// After the editing view's teardown, so what it saves as it closes is part of its step.
    func editingEnded() {
        isEditing = false
        editingBeganInAction = false
        if depth == 0 { close() }
    }

    /// A commit is about to take the document from `old`, as `changes` says: it goes into the step
    /// it's part of, which opens (and clears what there was to redo) if none is.
    func willCommit(_ changes: ChangeSet, from old: CanvasFile, name: String?, coalescing key: AnyHashable?, origin: Origin) {
        if let holder = opening(coalescing: key, origin: origin) {
            // Inside a commit: the transaction has built its document, and what the step closing would
            // finish with would be written over (`willTransact` closed it first, if it could).
            isCommitting = true
            close()
            isCommitting = false
            openStep(holder)
            if holder == .editing { open?.editingName = editingName }
            if case .kept = holder { open?.firstName = keptRun?.name }
        }
        guard var step = open else { return }
        step.builder.willCommit(changes, from: old)
        if step.groupName == nil { step.groupName = groupNames.lazy.compactMap { $0 }.first }
        if step.firstName == nil { step.firstName = name }
        open = step
    }

    /// The step a commit under `key`, from `origin`, opens, the one open closing first; nil when it goes
    /// into the one open. An editing view's commit joins its session's step; anything else an action
    /// commits ends that step and is the action's own.
    private func opening(coalescing key: AnyHashable?, origin: Origin) -> Holder? {
        if depth > 0 {
            return open == nil || (open?.holder == .editing && origin != .editing) ? .action : nil
        } else if origin == .editing, isEditing {
            return open?.holder != .editing ? .editing : nil
        } else if let key, let kept = keptRun, kept.key == key {
            return open?.holder != .kept(key) ? .kept(key) : nil
        } else if let key {
            return open?.holder != .run(key) ? .run(key) : nil
        }
        return .single
    }

    /// A transaction on the board shown is about to read the document, its commit under `key`, from
    /// `origin`. If that commit would close the open step and the step finishes with something
    /// (`finishing`: a held key's nudges settling), it closes now, so what it finishes with commits
    /// before the transaction reads the document, never inside its commit, which would write over
    /// it. A transaction that then commits nothing has closed it all the same, as anything else that
    /// happens does.
    func willTransact(coalescing key: AnyHashable?, origin: Origin) {
        guard open?.finishes.isEmpty == false, opening(coalescing: key, origin: origin) != nil else { return }
        close()
    }

    /// A commit on a board that isn't shown (`transact(on:)`), about to take the file from `old` as
    /// `changes` (that board's) says: a step of its own, made on that board and named `name`, which
    /// opens and closes around `commit` (the participants' snapshots before it and after services
    /// hear it). It goes on the stack at once, under the step open on the board shown, if there's
    /// one, which stays open and comes after it: the two are on different boards.
    func recordStep(on board: BoardID, name: String?, changes: ChangeSet, from old: CanvasFile, _ commit: () -> Void) {
        guard let editor else { return commit() }
        // A step that holds a board this one reaches whole (a card's, that reached it), its own or any it
        // adds, removes or changes, would take this one in, in its after and its before alike: it closes
        // first, so each undoes and redoes exactly.
        if let open, open.builder.holds(board) || changes.boardsReached.contains(where: open.builder.holds) { close() }
        var builder = DocumentDelta.Builder(board: board)
        builder.willCommit(changes, from: old)
        let before = snapshots()
        redos = []
        didChange?(.began)
        commit()
        let delta = builder.delta(now: editor.storedFile)
        guard !delta.isEmpty else {
            didChange?(.discarded)
            return
        }
        undos.append(Step(name: name, delta: delta, before: before, after: snapshots()))
        didChange?(.closed)
    }

    /// Services have heard the commit: a step of one commit closes.
    func didCommit() {
        if open?.holder == .single { close() }
    }

    /// An editing session's step is open, and the session is under way.
    private var isEditingStepOpen: Bool { isEditing && open?.holder == .editing }

    private func openStep(_ holder: Holder) {
        guard let editor else { return }
        redos = []
        open = OpenStep(holder: holder, builder: DocumentDelta.Builder(board: editor.board), before: snapshots())
        didChange?(.began)
    }

    /// Closes the open step: onto the stack, or, if it came to nothing, dropped. What it was to finish with
    /// (`finishing`) runs first, as an action of the step's, so its commits are the step's.
    func close() {
        if let finishes = open?.finishes, !finishes.isEmpty {
            open?.finishes = []
            if !isCommitting, editor?.canTransact == true {
                open?.holder = .action
                depth += 1
                groupNames.append(nil)
                for finish in finishes { finish.body() }
                depth -= 1
                groupNames.removeLast()
            }
        }
        guard let step = open, let editor else { return }
        open = nil
        let delta = step.builder.delta(now: editor.storedFile)
        guard !delta.isEmpty else {
            didChange?(.discarded)
            return
        }
        undos.append(Step(name: step.name, delta: delta, before: step.before, after: snapshots()))
        didChange?(.closed)
    }

    func popUndo() -> Step? { undos.popLast() }
    func popRedo() -> Step? { redos.popLast() }

    func pushUndone(_ step: Step) {
        redos.append(step)
        didChange?(.undid)
    }

    /// Puts back what `snapshots()` took, as undoing a step does: for a press whose step comes to
    /// nothing, though it changed what the participants keep (a shape placed and taken away again
    /// with Escape, which selected it meanwhile).
    func restore(_ snapshots: [ObjectIdentifier: any Sendable]) {
        guard let editor else { return }
        for participant in participants {
            if let snapshot = snapshots[ObjectIdentifier(participant)] { participant.restoreUndoSnapshot(snapshot, in: editor) }
        }
    }

    func pushRedone(_ step: Step) {
        undos.append(step)
        didChange?(.redid)
    }

    /// What each participant keeps now (the selection), by participant: what undoing a step that
    /// opened now would restore.
    func snapshots() -> [ObjectIdentifier: any Sendable] {
        guard let editor, !participants.isEmpty else { return [:] }
        var snapshots: [ObjectIdentifier: any Sendable] = [:]
        for participant in participants { snapshots[ObjectIdentifier(participant)] = participant.undoSnapshot(in: editor) }
        return snapshots
    }
}

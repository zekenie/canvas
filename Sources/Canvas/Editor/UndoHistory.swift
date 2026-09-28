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
    }

    private struct OpenStep {
        var holder: Holder
        var builder: DocumentDelta.Builder
        var groupName: String?
        var firstName: String?
        let before: [ObjectIdentifier: any Sendable]
        var name: String? { groupName ?? firstName ?? (holder == .editing ? "Typing" : nil) }
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
    /// another field): ends a run of commits under one coalescing key, so the next is a step of its
    /// own. Never ends a press's, an action's or an editing session's step.
    public func seal() {
        guard depth == 0, case .run? = open?.holder else { return }
        close()
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

    func actionEnded() {
        precondition(depth > 0, "an action ended that didn't begin")
        depth -= 1
        groupNames.removeLast()
        guard depth == 0 else { return }
        if editingBeganInAction, isEditing {
            open?.holder = .editing
        } else if !isEditingStepOpen {
            close()
        }
        editingBeganInAction = false
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

    func editingBegan() {
        isEditing = true
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
        if depth > 0 {
            // An editing view's commit joins its session's step; anything else the action commits
            // ends that step and is the action's own.
            if open == nil || (open?.holder == .editing && origin != .editing) {
                close()
                openStep(.action)
            }
        } else if origin == .editing, isEditing {
            if open?.holder != .editing {
                close()
                openStep(.editing)
            }
        } else if let key {
            if open?.holder != .run(key) {
                close()
                openStep(.run(key))
            }
        } else {
            close()
            openStep(.single)
        }
        guard var step = open else { return }
        step.builder.willCommit(changes, from: old)
        if step.groupName == nil { step.groupName = groupNames.lazy.compactMap { $0 }.first }
        if step.firstName == nil { step.firstName = name }
        open = step
    }

    /// A commit on a board that isn't shown (`transact(on:)`), about to take the file from `old` as
    /// `changes` (that board's) says: a step of its own, made on that board and named `name`, which
    /// opens and closes around `commit` (the participants' snapshots before it and after services
    /// hear it). It goes on the stack at once, under the step open on the board shown, if there's
    /// one, which stays open and comes after it: the two are on different boards.
    func recordStep(on board: BoardID, name: String?, changes: ChangeSet, from old: CanvasFile, _ commit: () -> Void) {
        guard let editor else { return commit() }
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

    /// Closes the open step: onto the stack, or, if it came to nothing, dropped.
    func close() {
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

    func pushRedone(_ step: Step) {
        undos.append(step)
        didChange?(.redid)
    }

    private func snapshots() -> [ObjectIdentifier: any Sendable] {
        guard let editor, !participants.isEmpty else { return [:] }
        var snapshots: [ObjectIdentifier: any Sendable] = [:]
        for participant in participants { snapshots[ObjectIdentifier(participant)] = participant.undoSnapshot(in: editor) }
        return snapshots
    }
}

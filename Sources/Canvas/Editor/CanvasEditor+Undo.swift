// Undo and redo (the steps are UndoHistory's). The core claims the `.undo` and `.redo` commands
// (CorePoints.swift), so a menu item or a key (Keyboard gives them ⌘Z and ⇧⌘Z) runs them with
// `perform`, like any other command.
extension CanvasEditor {
    /// Whether there's a step to undo (closed, or open with changes), on whichever board of the file
    /// it was made on, with no press's session running and no transaction under way.
    public var canUndo: Bool { session == nil && !isTransacting && !isApplying && undoHistory.hasUndo }

    /// Whether there's a step to redo, on whichever board it was made on, with no press's session
    /// running and no transaction under way.
    public var canRedo: Bool { session == nil && !isTransacting && !isApplying && undoHistory.hasRedo }

    /// Ends editing (its step closes) and closes any open step; shows the board the newest step was
    /// made on, if another is shown (`showBoard`: not a step itself); then puts back the step's
    /// records from before it, and what its participants kept (the selection, there). Services hear
    /// it as a commit. Nothing is refused: a read-only shape goes back as it was too. The camera stays
    /// where it is, or, on the board shown for it, where that board was left.
    public func undo() {
        guard canUndo else { return }
        endEditing()
        undoHistory.close()
        guard showBoard(ofStep: { $0.undoBoard }), let step = undoHistory.popUndo() else { return }
        apply(step.delta.inverted, restoring: step.before)
        undoHistory.pushUndone(step)
    }

    /// Puts back the records of the step last undone from after it, and what its participants kept,
    /// on the board it was made on, shown first if it isn't.
    public func redo() {
        guard canRedo else { return }
        endEditing()
        undoHistory.close()
        guard showBoard(ofStep: { $0.redoBoard }), let step = undoHistory.popRedo() else { return }
        apply(step.delta, restoring: step.after)
        undoHistory.pushRedone(step)
    }

    /// Shows the board the step to undo or redo was made on (`step` reads which), and says whether
    /// that step can be applied now: its board is shown, and it's still the one to undo or redo.
    /// (What a service commits as a board is left, a number being typed, is a step of its own on the
    /// board left, which comes first: the undo then stops at showing the board; so does a redo, since
    /// that edit, as any, leaves nothing to redo.)
    private func showBoard(ofStep step: (UndoHistory) -> BoardID?) -> Bool {
        guard let target = step(undoHistory), showBoard(target) else { return false }
        return step(undoHistory) == target && target == board
    }

    /// The one place a step is applied, on the board shown, which is the one it was made on: the
    /// document takes the delta exactly, services hear it as a commit (the index, the minimap's
    /// damage, the table of contents, validation, the selection), then participants get back what
    /// they kept.
    private func apply(_ delta: DocumentDelta, restoring snapshots: [ObjectIdentifier: any Sendable]) {
        precondition(delta.board == board, "a step is applied on the board it was made on")
        isApplying = true
        defer { isApplying = false }
        var document = storedDocument
        document.apply(delta)
        var changes = ChangeSet(delta)
        changes.restoredStep = true
        commit(document, changes: changes, applying: delta)
        for participant in undoHistory.participants {
            if let snapshot = snapshots[ObjectIdentifier(participant)] { participant.restoreUndoSnapshot(snapshot, in: self) }
        }
    }
}

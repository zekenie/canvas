// Undo and redo (the steps are UndoHistory's). The core claims the `.undo` and `.redo` commands
// (CorePoints.swift), so a menu item or a key (Keyboard gives them ⌘Z and ⇧⌘Z) runs them with
// `perform`, like any other command.
extension CanvasEditor {
    /// Whether there's a step to undo (closed, or open with changes), with no press's session
    /// running and no transaction under way.
    public var canUndo: Bool { session == nil && !isTransacting && !isApplying && undoHistory.hasUndo }

    /// Whether there's a step to redo, with no press's session running and no transaction under way.
    public var canRedo: Bool { session == nil && !isTransacting && !isApplying && !undoHistory.redos.isEmpty }

    /// Ends editing (its step closes) and closes any open step, then puts back the records of the
    /// newest step from before it, and what its participants kept (the selection). Services hear it
    /// as a commit. Nothing is refused: a read-only shape goes back as it was too. The camera stays.
    public func undo() {
        guard canUndo else { return }
        endEditing()
        undoHistory.close()
        guard let step = undoHistory.popUndo() else { return }
        apply(step.delta.inverted, restoring: step.before)
        undoHistory.pushUndone(step)
    }

    /// Puts back the records of the step last undone from after it, and what its participants kept.
    public func redo() {
        guard canRedo else { return }
        endEditing()
        undoHistory.close()
        guard let step = undoHistory.popRedo() else { return }
        apply(step.delta, restoring: step.after)
        undoHistory.pushRedone(step)
    }

    /// The one place a step is applied: the document takes the delta exactly, services hear it as a
    /// commit (the index, the minimap's damage, the table of contents, validation, the selection),
    /// then participants get back what they kept. (Once a file holds several boards, showing the
    /// step's board first goes here.)
    private func apply(_ delta: DocumentDelta, restoring snapshots: [ObjectIdentifier: any Sendable]) {
        isApplying = true
        defer { isApplying = false }
        var document = storedDocument
        document.apply(delta)
        var changes = ChangeSet(delta)
        changes.restoredStep = true
        commit(document, changes: changes)
        for participant in undoHistory.participants {
            if let snapshot = snapshots[ObjectIdentifier(participant)] { participant.restoreUndoSnapshot(snapshot, in: self) }
        }
    }
}

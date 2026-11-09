import CoreGraphics

// A copy of an editor to work changes out on before making them: its file, the board it shows and its view, with
// nothing it commits reaching the editor it was copied from. Draw's `rehearse` draws a plan's scripts on one, in turn,
// so a tool that draws in several runs knows each would land before it draws the first; Drawings' `apply` draws a
// whole document on one, board by board, and the editor then takes what it did in as one step (`adopt`).

extension CanvasEditor {
    /// A new editor of this one's file as it is now, showing the same board through the same view (its size, what the
    /// host covers of it, where the camera is headed) and calling the root what this one calls it, so a change worked
    /// out on it lands where it would land here. What it commits reaches nothing of this one, and its clock stands
    /// still (`StoppedScheduler`), so nothing its services would do later ever happens. Its boards are this file's,
    /// sharing what neither writes, as any copy of a board does.
    public func rehearsal() -> CanvasEditor {
        let copy = CanvasEditor(registry: registry, file: file, showing: board, scheduler: StoppedScheduler())
        copy.nameRoot(rootName)
        copy.coveredTop = coveredTop
        copy.coveredEdges = coveredEdgesAhead?() ?? coveredEdges
        copy.viewportDidResize(to: viewportSize)
        copy.camera = cameraTarget
        copy.rehearsed = (ObjectIdentifier(self), storedFile)
        return copy
    }

    /// Takes everything a rehearsal of this editor committed into the file, as one commit and one undo step named
    /// `name` (`byAgent`, as an agent's change): the board shown shape by shape, every other board it changed, made
    /// or took whole, and the file's values, exactly as the rehearsal left them. Services hear it as any commit, and
    /// what waits on the clock here (a rule check, a field fill) then runs, as it never does on the rehearsal. False,
    /// changing nothing, when the file here isn't the one the rehearsal was made from (anything committed since, or
    /// another file put in place), when `rehearsal` isn't one of this editor, or when nothing may commit now (a
    /// transaction or a change under way); true when it took it in, or there was nothing to take. A rehearsal is
    /// below the read-only rule's reach here: it was held to it as it committed.
    @discardableResult
    public func adopt(_ rehearsal: CanvasEditor, named name: String, byAgent: Bool = true) -> Bool {
        guard let from = rehearsal.rehearsed, from.of == ObjectIdentifier(self), canTransact else { return false }
        // A step that finishes with something (a held key's nudges) closes, and commits it, first.
        undoHistory.willTransact(coalescing: nil, origin: .ordinary)
        guard canTransact, storedFile == from.file else { return false }
        let delta = DocumentDelta(from: storedFile, to: rehearsal.storedFile, on: board)
        guard !delta.isEmpty else { return true }
        var document = storedDocument
        document.apply(delta)
        var changes = ChangeSet(delta)
        changes.byAgent = byAgent
        changes.priors = ChangeSet.Priors(boards: [storedDocument] + delta.boards.keys.map { storedFile[$0] })
        undoHistory.willCommit(changes, from: storedFile, name: name, coalescing: nil, origin: .ordinary)
        commit(document, changes: changes, applying: delta)
        undoHistory.didCommit()
        return true
    }
}

extension DocumentDelta {
    /// What takes `old` to `new`, made on `board`: each shape of that board that differs, every other board that
    /// differs whole, the entries that didn't read as boards, and the file's values that differ.
    init(from old: CanvasFile, to new: CanvasFile, on board: BoardID) {
        var changes: [ShapeID: Change] = [:]
        let here = new[board].shapes.differences(from: old[board].shapes)
        for id in here.added.union(here.changed).union(here.removed) {
            changes[id] = Change(before: old[board][id], after: new[board][id])
        }
        var boards: [BoardID: WholeBoard] = [:]
        for other in Set(old.everyBoard).union(new.everyBoard) where other != board && old[other] != new[other] {
            boards[other] = WholeBoard(before: old[other], after: new[other])
        }
        var unreadable: [String: UnreadableBoard] = [:]
        if old.unreadableBoards != new.unreadableBoards {
            for key in Set(old.unreadableBoards.keys).union(new.unreadableBoards.keys) {
                unreadable[key] = UnreadableBoard(before: old.unreadableBoards[key], after: new.unreadableBoards[key])
            }
        }
        var values: [PropertyKey: FileValue] = [:]
        for key in new.fileValues.keysDiffering(from: old.fileValues) {
            values[key] = FileValue(before: old.fileValues[key], after: new.fileValues[key])
        }
        self.init(changes, on: board, boards: boards, unreadableBoards: unreadable, fileValues: values)
    }
}

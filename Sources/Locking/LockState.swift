import Adornments
import Canvas
import CoreGraphics
import Foundation

/// Per editor: which shapes are locked, kept as commits change shapes, and the chips showing their
/// lock open a moment after their shape was unlocked (a `ChipFade`; the shake a refused try gives
/// is Selection's `RefusalShake`).
@MainActor
final class LockState {
    private unowned let editor: CanvasEditor
    private(set) var lockedIDs: Set<ShapeID> = []
    /// The locked shapes of boards shown lately, for going back to them without looking through
    /// their shapes again.
    private var kept = BoardStash<Set<ShapeID>>()
    #if DEBUG
    /// How many times a whole board has been looked through for its locked shapes (debug builds).
    private(set) var boardsScanned = 0
    #endif

    init(editor: CanvasEditor) {
        self.editor = editor
        lockedIDs = locked(in: editor.document)
    }

    private func locked(in document: CanvasDocument) -> Set<ShapeID> {
        #if DEBUG
        boardsScanned += 1
        #endif
        return Set(document.shapes.lazy.filter(\.isLocked).map(\.id))
    }

    /// Adornments' fades, found once: a commit asks about every shape it deletes, and a frame about
    /// every shape in view.
    private lazy var fade: ChipFade? = editor.service(ChipFade.self)

    /// How opaque a just-unlocked shape's open lock is: fully until it starts to fade, then less
    /// each frame. Nil for any other shape.
    func openLockOpacity(of id: ShapeID) -> CGFloat? { fade?.opacity(of: LockChip.self, on: id) }

    /// A click on a shape's chip: a locked shape's unlocks it, and a just-unlocked one's locks it again.
    func click(_ id: ShapeID) {
        if lockedIDs.contains(id) {
            editor.unlock([id])
        } else if fade?.isShowing(LockChip.self, on: id) == true {
            editor.lock([id])
        }
    }
}

extension LockState: EditorService {
    /// Keeps which shapes are locked, and opens the lock of each shape the commit unlocks. The locks
    /// it opens or closes are told to Adornments once, at the end, since each tell has the select
    /// tool look again for a button under the pointer: unlocking many shapes costs one look, not one
    /// a shape.
    func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        var chipsChanged = Set<ShapeID>()
        for id in changes.removed {
            lockedIDs.remove(id)
            if fade?.hide(LockChip.self, on: id) == true { chipsChanged.insert(id) }
        }
        for id in changes.added.union(changes.changed) {
            if editor.document[id]?.isLocked == true {
                lockedIDs.insert(id)
                if fade?.hide(LockChip.self, on: id) == true { chipsChanged.insert(id) }
            } else if lockedIDs.remove(id) != nil {
                fade?.show(LockChip.self, on: id)
                chipsChanged.insert(id)
            }
        }
        if !chipsChanged.isEmpty { editor.adornmentsDidChange(for: chipsChanged) }
    }

    /// The board left's locked shapes are kept for when it's shown again.
    func boardWillChange(from old: BoardID, to new: BoardID, in editor: CanvasEditor) {
        guard old != new else { return }
        kept.keep(lockedIDs, for: old, in: editor)
    }

    /// Another board is shown: its locked shapes are the ones with chips (as they were kept, if the
    /// board hasn't changed since it was left, else looked for). The locks showing open on the board
    /// left stop there (`ChipFade` drops them).
    func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        lockedIDs = kept.take(for: change.to, in: editor) ?? locked(in: editor.document)
    }
}

#if DEBUG
extension CanvasEditor {
    /// How many times Locking has looked through a whole board for its locked shapes (debug builds
    /// only), so tests can hold going back to a board to taking back what was kept of it.
    public var boardsScannedForLocks: Int { service(LockState.self)?.boardsScanned ?? 0 }
}
#endif

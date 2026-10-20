import Adornments
import Canvas
import CoreGraphics
import Foundation

/// Per editor: the chips showing a lock open a moment after their shape was unlocked (a `ChipFade`;
/// the shake a refused try gives is Selection's `RefusalShake`). Which shapes are locked is the
/// records' (`isLocked`), and what a commit unlocked it tells from what the shape was before it
/// (`ChangeSet.before`), so it keeps no copy of them.
@MainActor
final class LockState {
    private unowned let editor: CanvasEditor

    /// Adornments' fades, found once, as this is made, so they take each change in first: a commit asks about every
    /// shape it deletes, and a frame about every shape in view.
    private let fade: ChipFade?

    init(editor: CanvasEditor) {
        self.editor = editor
        fade = editor.service(ChipFade.self)
    }

    /// How opaque a just-unlocked shape's open lock is: fully until it starts to fade, then less
    /// each frame. Nil for any other shape.
    func openLockOpacity(of id: ShapeID) -> CGFloat? { fade?.opacity(of: LockChip.self, on: id) }

    /// A click on a shape's chip, a try of the command its face shows (`attempt`): a locked shape's
    /// Unlock, and a just-unlocked one's Lock. One its board or container holds locked is refused, and
    /// shakes.
    func click(_ id: ShapeID) {
        if editor.document[id]?.isLocked == true {
            editor.attempt(.unlock, on: [id])
        } else if fade?.isShowing(LockChip.self, on: id) == true {
            editor.attempt(.lock, on: [id])
        }
    }
}

extension LockState: EditorService {
    /// Opens the lock of each shape the commit unlocks (locked before it, and not now), and lets go of the open
    /// lock of each it locks or deletes. The locks it opens or closes are told to Adornments once, at the end,
    /// since each tell has the select tool look again for a button under the pointer: unlocking many shapes costs
    /// one look, not one a shape. A shape that only moved kept its lock, so a drag reads nothing.
    func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        var chipsChanged = Set<ShapeID>()
        for id in changes.removed where fade?.hide(LockChip.self, on: id) == true { chipsChanged.insert(id) }
        for id in changes.edited {
            if editor.document[id]?.isLocked == true {
                if fade?.hide(LockChip.self, on: id) == true { chipsChanged.insert(id) }
            } else if !changes.added.contains(id), changes.before(id)?.isLocked == true {
                fade?.show(LockChip.self, on: id)
                chipsChanged.insert(id)
            }
        }
        if !chipsChanged.isEmpty { editor.adornmentsDidChange(for: chipsChanged) }
    }
}

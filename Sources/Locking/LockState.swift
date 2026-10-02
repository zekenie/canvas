import Adornments
import Canvas
import CoreGraphics
import Foundation
import Selection

@MainActor
enum LockStyle {
    // Once a shape is unlocked (its chip clicked, or from the menu), its lock shows open this long, so
    // that a click by mistake can be taken back by another; longer while the pointer's on it; then it
    // fades.
    static let openLinger: Duration = .milliseconds(1500)
    static let openFade: Duration = .milliseconds(300)
    /// While the pointer's on an open lock that's had its time, how often to see if it's gone.
    static let openHoverRecheck: Duration = .milliseconds(500)

    // The shake a locked shape gives when something tries to change it, like a password field's.
    /// The farthest it goes to either side, in view points.
    static let shakeAmplitude: CGFloat = 5
    /// How many times it goes right and left.
    static let shakeCycles: Double = 3
    static let shakeDuration: Duration = .milliseconds(360)
    /// A frame of a shake or a fade.
    static let frame: Duration = .milliseconds(16)
}

/// Per editor: which shapes are locked, kept as commits change shapes, the chips showing their
/// lock open a moment after their shape was unlocked, and the shakes under way.
@MainActor
final class LockState {
    private unowned let editor: CanvasEditor
    private(set) var lockedIDs: Set<ShapeID> = []
    /// Shapes just unlocked, whose chip shows its lock open, where a click locks the shape again.
    private var opened: [ShapeID: OpenLock] = [:]
    /// Each shaking shape, and how many frames of its shake have played.
    private var shakes: [ShapeID: Int] = [:]
    private var nextFrame: ScheduledTask?
    /// The locked shapes of boards shown lately, for going back to them without looking through
    /// their shapes again.
    private var kept = BoardStash<Set<ShapeID>>()
    #if DEBUG
    /// How many times a whole board has been looked through for its locked shapes (debug builds).
    private(set) var boardsScanned = 0
    #endif

    /// A chip showing its lock open: for `openLinger`, and on while the pointer's on it; then it
    /// fades away over `openFade`.
    enum OpenLock {
        /// Shown in full, until the task starts its fade.
        case waiting(ScheduledTask)
        /// Fading: this many frames of its fade played.
        case fading(Int)
    }

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

    /// How opaque a just-unlocked shape's open lock is: fully until it starts to fade, then less
    /// each frame. Nil for any other shape.
    func openLockOpacity(of id: ShapeID) -> CGFloat? {
        switch opened[id] {
        case nil: nil
        case .waiting: 1
        case .fading(let frames): max(0, 1 - CGFloat((LockStyle.frame * frames) / LockStyle.openFade))
        }
    }

    /// A click on a shape's chip: a locked shape's unlocks it, and a just-unlocked one's locks it again.
    func click(_ id: ShapeID) {
        if lockedIDs.contains(id) {
            editor.unlock([id])
        } else if opened[id] != nil {
            editor.lock([id])
        }
    }

    // MARK: A lock opening

    /// A shape was just unlocked: its chip shows the lock open for a moment, so a click by mistake
    /// can be taken back by another. The caller tells Adornments, once for all the chips it changes.
    private func open(_ id: ShapeID) {
        if case .waiting(let task) = opened[id] { task.cancel() }
        opened[id] = .waiting(waitToFade(id, after: LockStyle.openLinger))
    }

    /// The open lock goes, if the shape has one: whether it had one. The caller tells Adornments,
    /// once for all the chips it changes.
    private func close(_ id: ShapeID) -> Bool {
        guard let lock = opened.removeValue(forKey: id) else { return false }
        if case .waiting(let task) = lock { task.cancel() }
        return true
    }

    private func waitToFade(_ id: ShapeID, after delay: Duration) -> ScheduledTask {
        editor.scheduler.schedule(after: delay) { [weak self] in self?.fade(id) }
    }

    /// Starts the chip's fade, unless the pointer's on it: it may be about to click it.
    private func fade(_ id: ShapeID) {
        guard opened[id] != nil else { return }
        guard editor.hoveredButton != AnyHashable(AdornmentButton(LockChip.self, on: id)) else {
            opened[id] = .waiting(waitToFade(id, after: LockStyle.openHoverRecheck))
            return
        }
        opened[id] = .fading(0)
        if nextFrame == nil { scheduleFrame() }
    }

    // MARK: Shaking

    /// Shakes each shape of `ids` on the board shown, unless it's shaking already: a try that comes
    /// while one plays (Delete pressed again) doesn't start it over. Locked or not: a shape
    /// whose board (or a board under it) holds a locked shape isn't deleted either, and it's the one
    /// tried, so it's the one that shakes. A container shakes with what it holds, at any depth, as it
    /// moves with it (a locked frame, under the notes in it).
    func shake(_ ids: Set<ShapeID>) {
        let document = editor.document, kinds = editor.registry.containingKinds
        var tried = ids
        if !kinds.isEmpty, document.namesContainers {
            for id in ids { tried.formUnion(document.descendants(of: id, containingKinds: kinds)) }
        }
        let starting = tried.filter { shakes[$0] == nil && document[$0] != nil }
        guard !starting.isEmpty else { return }
        for id in starting { shakes[id] = 0 }
        if nextFrame == nil { scheduleFrame() }
    }

    var isShaking: Bool { !shakes.isEmpty }

    /// How far a shaking shape is drawn from where it is, `elapsed` into its shake, in view points:
    /// side to side, `shakeCycles` times over `shakeDuration`, dying away. Nothing at either end.
    static func shakeOffset(at elapsed: Duration) -> CGFloat {
        let t = elapsed / LockStyle.shakeDuration
        guard t > 0, t < 1 else { return 0 }
        return LockStyle.shakeAmplitude * CGFloat(sin(2 * .pi * LockStyle.shakeCycles * t) * (1 - t))
    }

    // MARK: Frames

    private var isFading: Bool {
        opened.values.contains {
            if case .fading = $0 { return true }
            return false
        }
    }

    private func scheduleFrame() {
        nextFrame = editor.scheduler.schedule(after: LockStyle.frame) { [weak self] in self?.playFrame() }
    }

    /// One frame of every shake and fade under way. A shake that's played out puts its shape back
    /// where it's drawn; a fade, its chip away.
    private func playFrame() {
        nextFrame = nil
        for (id, frame) in shakes {
            let elapsed = LockStyle.frame * (frame + 1)
            if elapsed >= LockStyle.shakeDuration {
                shakes[id] = nil
                editor.setDrawingOffset(.zero, for: id)
            } else {
                shakes[id] = frame + 1
                editor.setDrawingOffset(CGPoint(x: Self.shakeOffset(at: elapsed), y: 0), for: id)
            }
        }
        // The open locks fading, and those faded away.
        var fading = Set<ShapeID>()
        for (id, lock) in opened {
            guard case .fading(let frames) = lock else { continue }
            fading.insert(id)
            opened[id] = LockStyle.frame * (frames + 1) >= LockStyle.openFade ? nil : .fading(frames + 1)
        }
        if !fading.isEmpty { editor.adornmentsDidChange(for: fading) }
        if !shakes.isEmpty || isFading { scheduleFrame() }
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
            shakes[id] = nil
            lockedIDs.remove(id)
            if close(id) { chipsChanged.insert(id) }
        }
        for id in changes.added.union(changes.changed) {
            if editor.document[id]?.isLocked == true {
                lockedIDs.insert(id)
                if close(id) { chipsChanged.insert(id) }
            } else if lockedIDs.remove(id) != nil {
                open(id)
                chipsChanged.insert(id)
            }
        }
        if !chipsChanged.isEmpty { editor.adornmentsDidChange(for: chipsChanged) }
    }

    /// A try to change locked shapes: they shake.
    func didRefuseChanges(to ids: Set<ShapeID>, in editor: CanvasEditor) { shake(ids) }

    /// The board left's locked shapes are kept for when it's shown again.
    func boardWillChange(from old: BoardID, to new: BoardID, in editor: CanvasEditor) {
        guard old != new else { return }
        kept.keep(lockedIDs, for: old, in: editor)
    }

    /// Another board is shown: its locked shapes are the ones with chips (as they were kept, if the
    /// board hasn't changed since it was left, else looked for), and what was under way on the
    /// board left (shakes, locks showing open, their frames) stops there.
    func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        lockedIDs = kept.take(for: change.to, in: editor) ?? locked(in: editor.document)
        shakes = [:]
        for id in Array(opened.keys) { _ = close(id) }
        opened = [:]
        nextFrame?.cancel()
        nextFrame = nil
    }
}

#if DEBUG
extension CanvasEditor {
    /// How many times Locking has looked through a whole board for its locked shapes (debug builds
    /// only), so tests can hold going back to a board to taking back what was kept of it.
    public var boardsScannedForLocks: Int { service(LockState.self)?.boardsScanned ?? 0 }
}
#endif

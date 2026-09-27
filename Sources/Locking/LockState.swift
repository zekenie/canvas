import Canvas
import CoreGraphics
import Foundation
import Geometry
import Selection

/// Per editor: which shapes are locked, kept as commits change shapes (what the chip overlay draws
/// for, so a board with none costs it nothing), the chips showing their lock open a moment after
/// their shape was unlocked, and the shakes under way.
@MainActor
final class LockState {
    private unowned let editor: CanvasEditor
    private(set) var lockedIDs: Set<ShapeID>
    /// Shapes just unlocked, whose chip shows its lock open, where a click locks the shape again.
    private(set) var opened: [ShapeID: OpenLock] = [:]
    /// Each shaking shape, and how many frames of its shake have played.
    private var shakes: [ShapeID: Int] = [:]
    private var nextFrame: ScheduledTask?

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
        lockedIDs = Set(editor.document.shapes.lazy.filter(\.isLocked).map(\.id))
    }

    var hasChips: Bool { !lockedIDs.isEmpty || !opened.isEmpty }

    /// How opaque a shape's chip is: fully, but for an open lock fading away.
    func opacity(of id: ShapeID) -> CGFloat {
        guard case .fading(let frames) = opened[id] else { return 1 }
        return max(0, 1 - CGFloat((LockStyle.frame * frames) / LockStyle.openFade))
    }

    // MARK: The chip, as a button

    /// The chip under a view point, a locked shape's or a just-unlocked one's, the front-most if
    /// several: what the select tool clicks there (`CanvasButtons`).
    func chip(atViewPoint point: CGPoint) -> LockChip? {
        guard hasChips else { return nil }
        let camera = editor.camera, scale = LockStyle.scale(zoom: camera.zoom)
        let world = camera.toWorld(point), margin = LockStyle.hitMargin * scale
        let size = LockStyle.size * scale, gap = LockStyle.gap * scale
        // A chip ends at its shape's right edge, above its top: a shape whose top-right corner is
        // within a chip (and the margin) below and right of the point may have one here.
        let area = CGRect(x: world.x - margin, y: world.y + gap - margin, width: size + 2 * margin, height: size + 2 * margin)
        let shapes = editor.shapeContext
        for record in editor.paintOrder(in: area).reversed() where lockedIDs.contains(record.id) || opened[record.id] != nil {
            guard let bounds = shapes.geometry(of: record.id)?.bounds, !bounds.isNull else { continue }
            let chip = LockStyle.chip(above: bounds, scale: scale)
            if hypot(world.x - chip.midX, world.y - chip.midY) <= chip.width / 2 + margin { return LockChip(shape: record.id) }
        }
        return nil
    }

    /// A click on a chip: a locked shape's unlocks it, and a just-unlocked one's locks it again.
    func click(_ chip: LockChip) {
        if lockedIDs.contains(chip.shape) {
            editor.unlock([chip.shape])
        } else if opened[chip.shape] != nil {
            editor.lock([chip.shape])
        }
    }

    // MARK: A lock opening

    /// A shape was just unlocked: its chip shows the lock open for a moment, so a click by mistake
    /// can be taken back by another.
    private func open(_ id: ShapeID) {
        close(id)
        opened[id] = .waiting(waitToFade(id, after: LockStyle.openLinger))
    }

    private func close(_ id: ShapeID) {
        if case .waiting(let task) = opened.removeValue(forKey: id) { task.cancel() }
    }

    private func waitToFade(_ id: ShapeID, after delay: Duration) -> ScheduledTask {
        editor.scheduler.schedule(after: delay) { [weak self] in self?.fade(id) }
    }

    /// Starts the chip's fade, unless the pointer's on it: it may be about to click it.
    private func fade(_ id: ShapeID) {
        guard opened[id] != nil else { return }
        guard editor.hoveredButton != AnyHashable(LockChip(shape: id)) else {
            opened[id] = .waiting(waitToFade(id, after: LockStyle.openHoverRecheck))
            return
        }
        opened[id] = .fading(0)
        if nextFrame == nil { scheduleFrame() }
    }

    // MARK: Shaking

    /// Shakes each locked shape of `ids`, unless it's shaking already: a try that comes while one
    /// plays (the eraser dragged across it) doesn't start it over.
    func shake(_ ids: Set<ShapeID>) {
        let starting = ids.filter { lockedIDs.contains($0) && shakes[$0] == nil }
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
        var faded = false
        for (id, lock) in opened {
            guard case .fading(let frames) = lock else { continue }
            if LockStyle.frame * (frames + 1) >= LockStyle.openFade {
                opened[id] = nil
                faded = true
            } else {
                opened[id] = .fading(frames + 1)
            }
        }
        if faded || isFading { editor.setNeedsDisplay() }
        if faded { editor.canvasButtonsDidChange() }
        if !shakes.isEmpty || isFading { scheduleFrame() }
    }
}

extension LockState: EditorService {
    func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        // Whether a chip came or went: a shape locked, or one with a chip gone. (A shape unlocked
        // keeps its chip, open.)
        var chipsChanged = false
        for id in changes.removed {
            shakes[id] = nil
            if lockedIDs.remove(id) != nil || opened[id] != nil { chipsChanged = true }
            close(id)
        }
        for id in changes.added.union(changes.changed) {
            if editor.document[id]?.isLocked == true {
                if lockedIDs.insert(id).inserted { chipsChanged = true }
                close(id)
            } else if lockedIDs.remove(id) != nil {
                open(id)
            }
        }
        // Selection heard of the commit first, and looked under the pointer for a button before
        // these chips followed it.
        if chipsChanged { editor.canvasButtonsDidChange() }
    }

    /// A try to change locked shapes: they shake.
    func didRefuseChanges(to ids: Set<ShapeID>, in editor: CanvasEditor) { shake(ids) }
}

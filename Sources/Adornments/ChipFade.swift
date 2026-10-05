import Canvas
import CoreGraphics
import Selection

/// A chip that shows a moment, then fades: Locking's open lock after an unlock, Publishing's "Private"
/// after a click. One machine for every such chip, so two plugins' chips fade alike. A plugin shows
/// a chip on a shape (`show`), asks its opacity from its label (`opacity(of:on:)`, nil when it
/// isn't showing), and takes it back at once when something else says so (`hide`); the fade does
/// the rest: the chip shows in full for `AdornmentStyle.lingerDuration`, longer, re-looked at every
/// `hoverRecheck`, while the pointer's on it (it may be about to be clicked), then fades over
/// `fadeDuration` in `fadeFrame` frames, telling Adornments each frame (`adornmentsDidChange`), and
/// is gone. What a plugin's label reads from here follows Adornments' rule for a service: this tells
/// Adornments when the opacity changes by itself. The caller tells it for what it does itself (`show`
/// and `hide`), once for all the chips it changes, as each tell has the select tool look again for
/// a button under the pointer.
///
/// Per editor, made by `AdornmentsPlugin`; found with `editor.service(ChipFade.self)`. What's
/// under way on a board stops with the board; a shape that's deleted takes its chips with it.
///
/// Asking costs a dictionary hit, or nothing while no chip shows: a commit that deletes or brings
/// back thousands of shapes asks about each of them, and a frame asks about every shape in view
/// that could show one.
@MainActor
public final class ChipFade {
    private unowned let editor: CanvasEditor
    private var chips: [Key: Phase] = [:]
    private var nextFrame: ScheduledTask?

    /// A chip by its type's identity, never its `AdornmentID` (whose names are made from the type,
    /// a cost on every ask), and the shape it's on.
    private struct Key: Hashable {
        let chip: ObjectIdentifier
        let shape: ShapeID

        init<A: Adornment>(_: A.Type, on shape: ShapeID) {
            chip = ObjectIdentifier(A.self)
            self.shape = shape
        }
    }

    private enum Phase {
        /// Shown in full, until the task starts its fade (the chip, to look for the pointer on).
        case waiting(ScheduledTask, AdornmentID)
        /// Fading: this many frames of its fade played.
        case fading(Int)
    }

    init(editor: CanvasEditor) { self.editor = editor }

    /// The chip shows on the shape, in full, for its linger and then its fade: starting over if it
    /// was showing, in either. The caller tells Adornments.
    public func show<A: Adornment>(_: A.Type, on shape: ShapeID) {
        let key = Key(A.self, on: shape), chip = AdornmentID.of(A.self)
        cancelTask(of: key)
        chips[key] = .waiting(wait(key, chip, after: AdornmentStyle.lingerDuration), chip)
    }

    /// The chip goes at once, if it was showing: whether it was. The caller tells Adornments.
    @discardableResult
    public func hide<A: Adornment>(_: A.Type, on shape: ShapeID) -> Bool {
        guard !chips.isEmpty else { return false }
        let key = Key(A.self, on: shape)
        guard chips[key] != nil else { return false }
        cancelTask(of: key)
        chips[key] = nil
        return true
    }

    /// Whether the chip is showing on the shape, fading or not.
    public func isShowing<A: Adornment>(_: A.Type, on shape: ShapeID) -> Bool { !chips.isEmpty && chips[Key(A.self, on: shape)] != nil }

    /// How opaque the chip is on the shape: fully until it starts to fade, then less each frame. Nil
    /// when it isn't showing.
    public func opacity<A: Adornment>(of _: A.Type, on shape: ShapeID) -> CGFloat? {
        guard !chips.isEmpty else { return nil }
        switch chips[Key(A.self, on: shape)] {
        case nil: return nil
        case .waiting: return 1
        case .fading(let frames): return max(0, 1 - CGFloat((AdornmentStyle.fadeFrame * frames) / AdornmentStyle.fadeDuration))
        }
    }

    // MARK: Waiting and fading

    private func cancelTask(of key: Key) {
        if case .waiting(let task, _) = chips[key] { task.cancel() }
    }

    private func wait(_ key: Key, _ chip: AdornmentID, after delay: Duration) -> ScheduledTask {
        editor.scheduler.schedule(after: delay) { [weak self] in self?.fade(key, chip) }
    }

    /// Starts the chip's fade, unless the pointer's on it.
    private func fade(_ key: Key, _ chip: AdornmentID) {
        guard chips[key] != nil else { return }
        guard editor.hoveredButton != AnyHashable(AdornmentButton(chip, on: key.shape)) else {
            chips[key] = .waiting(wait(key, chip, after: AdornmentStyle.hoverRecheck), chip)
            return
        }
        chips[key] = .fading(0)
        if nextFrame == nil { scheduleFrame() }
    }

    private var isFading: Bool {
        chips.values.contains {
            if case .fading = $0 { return true }
            return false
        }
    }

    private func scheduleFrame() {
        nextFrame = editor.scheduler.schedule(after: AdornmentStyle.fadeFrame) { [weak self] in self?.playFrame() }
    }

    /// One frame of every fade under way: a chip whose fade is played out is gone.
    private func playFrame() {
        nextFrame = nil
        var fading = Set<ShapeID>()
        for (key, phase) in chips {
            guard case .fading(let frames) = phase else { continue }
            fading.insert(key.shape)
            chips[key] = AdornmentStyle.fadeFrame * (frames + 1) >= AdornmentStyle.fadeDuration ? nil : .fading(frames + 1)
        }
        if !fading.isEmpty { editor.adornmentsDidChange(for: fading) }
        if isFading { scheduleFrame() }
    }

    private func reset() {
        for key in Array(chips.keys) { cancelTask(of: key) }
        chips = [:]
        nextFrame?.cancel()
        nextFrame = nil
    }
}

extension ChipFade: EditorService {
    /// A shape that's gone takes its chips with it, which Adornments is told once for all of them
    /// (a button under the pointer may have gone).
    public func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        guard !chips.isEmpty, !changes.removed.isEmpty else { return }
        var gone = Set<ShapeID>()
        for key in Array(chips.keys) where changes.removed.contains(key.shape) {
            cancelTask(of: key)
            chips[key] = nil
            gone.insert(key.shape)
        }
        if !gone.isEmpty { editor.adornmentsDidChange(for: gone) }
    }

    /// What was under way on the board left stops there.
    public func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) { reset() }
}

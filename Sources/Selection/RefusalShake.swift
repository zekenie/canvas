import Canvas
import CoreGraphics
import Foundation

/// The shake a shape gives when something tries to change it and it can't be, like a password
/// field's. It answers the core's one refusal signal (`editor.refuseChanges(to:)`, which a
/// transaction, a drag and editing each send for a read-only shape), whoever's rule made the shape
/// read-only (Locking's lock, Publishing's hold), so none of them plays it. Every refused shape on
/// the board shown shakes through `editor.setDrawingOffset`: `shakeAmplitude` view points side to side,
/// `shakeCycles` times over `shakeDuration`, dying away, a frame every `shakeFrame`. A try while a
/// shape shakes doesn't start it over. A container shakes with what it holds, at any depth, as it
/// moves with it (a locked frame, under the notes in it); a shape whose board holds a refused
/// shape is the one tried, so it's the one that shakes. What's under way stops with the board.
///
/// Per editor, made by `SelectionPlugin`.
@MainActor
public final class RefusalShake {
    private unowned let editor: CanvasEditor
    /// Each shaking shape, and how many frames of its shake have played.
    private var shakes: [ShapeID: Int] = [:]
    private var nextFrame: ScheduledTask?

    init(editor: CanvasEditor) { self.editor = editor }

    /// Shakes each shape of `ids` on the board shown, with what they hold, unless it's shaking
    /// already.
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

    /// Whether any shape is shaking.
    public var isShaking: Bool { !shakes.isEmpty }

    /// How far a shaking shape is drawn from where it is, `elapsed` into its shake, in view points:
    /// side to side, `shakeCycles` times over `shakeDuration`, dying away. Nothing at either end.
    public static func offset(at elapsed: Duration) -> CGFloat {
        let t = elapsed / SelectionStyle.shakeDuration
        guard t > 0, t < 1 else { return 0 }
        return SelectionStyle.shakeAmplitude * CGFloat(sin(2 * .pi * SelectionStyle.shakeCycles * t) * (1 - t))
    }

    private func scheduleFrame() {
        nextFrame = editor.scheduler.schedule(after: SelectionStyle.shakeFrame) { [weak self] in self?.playFrame() }
    }

    /// One frame of every shake under way. A shake that's played out puts its shape back where it's
    /// drawn.
    private func playFrame() {
        nextFrame = nil
        for (id, frame) in shakes {
            let elapsed = SelectionStyle.shakeFrame * (frame + 1)
            if elapsed >= SelectionStyle.shakeDuration {
                shakes[id] = nil
                editor.setDrawingOffset(.zero, for: id)
            } else {
                shakes[id] = frame + 1
                editor.setDrawingOffset(CGPoint(x: Self.offset(at: elapsed), y: 0), for: id)
            }
        }
        if !shakes.isEmpty { scheduleFrame() }
    }
}

extension RefusalShake: EditorService {
    public func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        for id in changes.removed { shakes[id] = nil }
    }

    /// A try to change read-only shapes: they shake.
    public func didRefuseChanges(to ids: Set<ShapeID>, in editor: CanvasEditor) { shake(ids) }

    public func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        shakes = [:]
        nextFrame?.cancel()
        nextFrame = nil
    }
}

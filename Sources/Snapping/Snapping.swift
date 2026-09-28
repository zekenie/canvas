import Canvas
import CoreGraphics
import Geometry

/// Snapping, as a plugin: what a drag moves (the selection, a shape just placed) snaps to the
/// shapes in view, by their frames. Along each axis, its edges and its middle snap to theirs, and it
/// snaps to spaces between them: centered between two neighbors, or as far from one as the space
/// beside it (tldraw's bounds snapping, `SnapTargets`), within 8 view points, while guides show what
/// lines up. It's on whenever shapes are dragged, as Keynote's alignment guides are (tldraw's snap
/// only while ⌘ is held); ⌘ or ⌃ held once the drag is under way lets them follow the pointer
/// exactly, as ⌘ lets an arrow's end bind to nothing (at the press, ⌘ on a shape starts a marquee and
/// ⌃ is the secondary click). Kinds with a frame snap and are snapped to; those without one (arrows,
/// lines) neither. The core only lends the hook (`registrar.translationAdjuster`), which this plugin
/// claims.
extension PluginID {
    public static let snapping: PluginID = "snapping"
}

public struct SnappingPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { .snapping }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.service { _ in SnapState() }
        registrar.translationAdjuster { editor, start in SnapDrag(start, in: editor) }
    }
}

extension CanvasEditor {
    /// What the drag under way shows of how what it moves lines up, in world units: nothing while
    /// nothing lines up, or no drag is under way.
    public var snapGuides: [SnapGuide] { service(SnapState.self)?.drag?.guides ?? [] }
}

/// The drag under way, while one snaps: told when a shape it doesn't move changes (a plugin's write,
/// an agent's), so it reads what's in view again, and when one it moves changes other than by moving
/// (resized by a plugin's write), so it takes its frames together again.
@MainActor
final class SnapState {
    weak var drag: SnapDrag?
}

extension SnapState: EditorService {
    func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        guard let drag else { return }
        if drag.hasTargets, !changes.added.isEmpty || !changes.removed.isEmpty || !changes.changed.isSubset(of: drag.moving) {
            drag.dropTargets()
        }
        // The drag's own commits only move its frames (arrows moving with them change, but they
        // have none).
        if changes.changed.contains(where: { drag.movesFrame($0) && !changes.moved.contains($0) }) || changes.removed.contains(where: drag.movesFrame) {
            drag.framesChanged(in: editor)
        }
    }

    /// Nothing is kept of a board: no drag outlasts one.
    func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {}
}

/// One drag's snapping: what it moves, as one rect (the frames it moves, together, where they were
/// when it began), snapped on each event to the frames in view but its own, once the pointer has gone
/// past the drag threshold, so a click moves nothing more than the pointer does (a lone box follows
/// it from the press). What's in view is read at the first event that snaps, and again once the
/// camera moves or shapes it doesn't move change.
@MainActor
final class SnapDrag {
    /// Everything the drag moves, frame or not.
    let moving: Set<ShapeID>
    private let origin: CGPoint
    /// Where each frame it moves began: the session moves each from there, whatever its size.
    private let starts: [ShapeID: CGPoint]
    /// Its frames together, where they began, as big as they are now.
    private var bounds: CGRect
    private var isPastThreshold = false
    private var targets: SnapTargets?
    /// What `targets` were read in: the camera, and the view's size.
    private var view: (camera: Camera, size: CGSize)?
    private(set) var guides: [SnapGuide] = []

    /// Nil for a drag that moves no frame: nothing to snap.
    init?(_ start: TranslationStart, in editor: CanvasEditor) {
        var starts: [ShapeID: CGPoint] = [:], bounds = CGRect.null
        for id in start.ids {
            guard let box = editor.document[id]?.box else { continue }
            starts[id] = box.origin
            bounds = bounds.union(box)
        }
        guard !starts.isEmpty else { return nil }
        moving = Set(start.ids)
        origin = start.origin
        self.starts = starts
        self.bounds = bounds
        editor.service(SnapState.self)?.drag = self
    }

    var hasTargets: Bool { targets != nil }
    func dropTargets() { targets = nil }
    func movesFrame(_ id: ShapeID) -> Bool { starts[id] != nil }

    /// A frame it moves changed size (a plugin's write): its frames together again, from where they
    /// began, as big as they are now.
    func framesChanged(in editor: CanvasEditor) {
        bounds = starts.reduce(CGRect.null) { bounds, start in
            editor.document[start.key]?.box.map { bounds.union(CGRect(origin: start.value, size: $0.size)) } ?? bounds
        }
    }

    /// The frames in view, but those it moves, as the camera shows them now: none without a view.
    private func targets(in editor: CanvasEditor) -> SnapTargets {
        let camera = editor.camera, size = editor.viewportSize
        if let targets, let view, view.camera == camera, view.size == size { return targets }
        var frames: [CGRect] = []
        if size.width > 0, size.height > 0 {
            let visible = camera.toWorld(CGRect(origin: .zero, size: size))
            for record in editor.paintOrder(in: visible) where !moving.contains(record.id) {
                if let box = record.box, box.touches(visible) { frames.append(box) }
            }
        }
        let targets = SnapTargets(frames)
        self.targets = targets
        view = (camera, size)
        return targets
    }
}

extension SnapDrag: TranslationAdjuster {
    func adjust(_ delta: CGPoint, for pointer: Pointer, in editor: CanvasEditor) -> CGPoint {
        let shown = guides
        defer { if guides != shown { editor.setNeedsDisplay() } }
        guides = []
        if !isPastThreshold { isPastThreshold = pointer.view.distance(to: editor.camera.toView(origin)) > Style.dragThreshold }
        // Its frames all gone (deleted mid-drag): nothing to snap.
        guard isPastThreshold, !bounds.isNull, pointer.modifiers.isDisjoint(with: SnappingStyle.freeMoveModifiers) else { return delta }
        let snap = targets(in: editor).snap(bounds, movedBy: delta, within: SnappingStyle.threshold / editor.camera.zoom)
        guides = snap.guides
        return snap.delta
    }

    func draw(in context: OverlayContext) { SnappingStyle.draw(guides, in: context) }
}

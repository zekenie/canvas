import Canvas
import CoreGraphics
import Geometry

/// Arrow behavior, modeled closely on tldraw's: targeting, binding and the one shared precise timer.
///
/// An arrow end binds to the front-most connectable shape under the pointer; arrows know nothing
/// else about the shapes they connect. How an end binds depends on how the user got there:
/// arriving quickly aims at the shape's center ("imprecise"), while arriving slowly or pausing
/// aims at the exact spot under the pointer ("precise"). Holding ⌥ runs the arrow all the way to
/// that spot ("exact"), and holding ⌘ keeps it from binding at all.
///
/// One per editor. The precise timer is a single slot shared by the hover (600 ms), press (320 ms)
/// and drag (320 ms) timers, so a press replaces the hover timer, as in the POC.
@MainActor
final class ArrowTargeting {
    unowned let editor: CanvasEditor
    /// Set by dwelling with the arrow tool (hovering one shape, or holding still after pressing).
    /// Makes a new arrow's start bind precisely where it was pressed.
    var arrowToolIsPrecise = false
    private var preciseTimer: ScheduledTask?

    init(editor: CanvasEditor) { self.editor = editor }

    var connectables: Connectables { Connectables(shapes: editor.shapeContext) }

    func geometry(of arrow: Arrow) -> ArrowGeometry {
        let connectables = connectables
        return ArrowGeometry(arrow: arrow, strokeWidth: ArrowStyle.strokeWidth) { connectables[$0] }
    }

    func arrow(_ id: ShapeID) -> Arrow? { editor.document[id]?.typed(as: Arrow.self)?.props }

    func updateArrow(_ id: ShapeID, _ change: (inout Arrow) -> Void) {
        editor.transact { $0.update(id, as: Arrow.self) { change(&$0.props) } }
    }

    // MARK: - Targeting

    /// The front-most shape under `point` that arrows can bind to.
    func connectable(at point: CGPoint) -> ConnectableShape? {
        connectables.shape(at: point)
    }

    /// The shape an arrow end at `point` would bind to. Holding ⌘ (or ⌃) binds to nothing.
    func arrowTarget(at point: CGPoint, modifiers: Modifiers) -> ConnectableShape? {
        guard modifiers.isDisjoint(with: [.command, .control]) else { return nil }
        return connectable(at: point)
    }

    /// Before pressing, the arrow tool outlines the shape it would start from. Hovering one shape
    /// long enough means the user is aiming, so the arrow will start precisely where they press.
    func updateArrowToolTarget(at point: CGPoint, modifiers: Modifiers) {
        let target = arrowTarget(at: point, modifiers: modifiers)?.id
        guard target != editor.hintedShapeID else { return }
        editor.hintedShapeID = target
        arrowToolIsPrecise = false
        if target != nil {
            startPreciseTimer(after: ArrowStyle.hoverPreciseDelay) { $0.arrowToolIsPrecise = true }
        } else {
            cancelPreciseTimer()
        }
    }

    func resetArrowToolTargeting() {
        cancelPreciseTimer()
        arrowToolIsPrecise = false
        editor.hintedShapeID = nil
    }

    func restartArrowToolTargeting() {
        resetArrowToolTargeting()
        updateArrowToolTarget(at: editor.pointerWorldLocation, modifiers: editor.effectiveModifiers)
    }

    /// Binds one end of an arrow to the shape at `point`, or frees it if there's none. This is
    /// tldraw's `updateArrowTargetState` and `onTerminalHandleDrag`.
    func bindTerminal(of arrowID: ShapeID, _ end: ArrowEnd, to point: CGPoint, isPrecise: Bool, modifiers: Modifiers) {
        guard let arrow = arrow(arrowID) else { return }
        let current = arrow[end].binding
        let opposite = arrow[end.opposite].binding
        guard let target = arrowTarget(at: point, modifiers: modifiers) else {
            updateArrow(arrowID) { $0[end] = .free(point) }
            editor.hintedShapeID = nil
            return
        }

        var precise = isPrecise
        if !precise, current?.shapeID != target.id {
            // Arriving at a shape slowly means the user is aiming at a spot in it.
            precise = editor.pointerSpeed < ArrowStyle.slowPointerSpeed
        }
        if !isPrecise, let opposite, opposite.shapeID == target.id, opposite.isPrecise {
            // Otherwise both ends could land on the same point.
            precise = true
        }
        let isExact = modifiers.contains(.option)
        if isExact {
            precise = true
        }

        let bounds = target.bounds
        var anchor = point
        if !precise {
            anchor = bounds.center
        } else if !isExact {
            // Snap to the center when close to it.
            let snapDistance = min(max(min(bounds.width, bounds.height) * 0.15, 4), 16) / editor.camera.zoom
            if point.distance(to: bounds.center) < snapDistance {
                anchor = bounds.center
            }
        }
        var normalized = normalizedAnchor(anchor, in: bounds)
        if let opposite, opposite.shapeID == target.id, opposite.normalizedAnchor == normalized {
            normalized.x += 0.05
        }
        updateArrow(arrowID) {
            $0[end] = .bound(ArrowBinding(shapeID: target.id, normalizedAnchor: normalized, isPrecise: precise, isExact: isExact))
        }
        editor.hintedShapeID = target.id
    }

    func startPreciseTimer(after delay: Duration, _ fire: @escaping @MainActor (ArrowTargeting) -> Void) {
        preciseTimer?.cancel()
        preciseTimer = editor.scheduler.schedule(after: delay) { [weak self] in
            guard let self else { return }
            fire(self)
        }
    }

    func cancelPreciseTimer() {
        preciseTimer?.cancel()
        preciseTimer = nil
    }
}

extension ArrowTargeting: EditorService {
    /// Every tool switch resets targeting, even mid-drag (the POC's `tool.didSet`).
    func toolDidChange(from old: ToolID, to new: ToolID, in editor: CanvasEditor) {
        resetArrowToolTargeting()
    }
}

/// Where `point` lies in `bounds`, as a binding's anchor: (0, 0) at its min corner, (1, 1) at its max.
func normalizedAnchor(_ point: CGPoint, in bounds: CGRect) -> CGPoint {
    CGPoint(x: (point.x - bounds.minX) / bounds.width, y: (point.y - bounds.minY) / bounds.height)
}

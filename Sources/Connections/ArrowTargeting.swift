import Canvas
import CoreGraphics
import Geometry
import Topology

/// Arrow behavior, modeled closely on tldraw's: targeting, binding and the one shared precise timer.
///
/// An arrow end binds to the front-most connectable shape under the pointer; arrows know nothing
/// else about the shapes they connect. How an end binds depends on how the user got there:
/// arriving quickly aims at the shape's center ("imprecise"), while arriving slowly or pausing
/// aims at the exact spot under the pointer ("precise"). Holding ⌥ runs the arrow all the way to
/// that spot ("exact"), and holding ⌘ keeps it from binding at all.
///
/// One per editor, with one precise timer (320 ms): holding still over a shape while dragging an
/// end, as in the POC.
@MainActor
final class ArrowTargeting {
    unowned let editor: CanvasEditor
    private var preciseTimer: ScheduledTask?
    /// Every plugin's rules for what an end may bind to (`ArrowBindingRules`), found once.
    let rules: [ArrowBindingRules.Contribution]

    init(editor: CanvasEditor) {
        self.editor = editor
        rules = editor.registry.contributions(to: ArrowBindingRules.self).map(\.value)
    }

    var connectables: Connectables { Connectables(shapes: editor.shapeContext) }

    func geometry(of arrow: Arrow) -> ArrowGeometry {
        let connectables = connectables
        return ArrowGeometry(arrow: arrow, strokeWidth: ArrowStyle.strokeWidth) { connectables[$0] }
    }

    func arrow(_ id: ShapeID) -> Arrow? { editor.document[id]?.typed(as: Arrow.self)?.props }

    /// `name` names the undo step, unless the press has already (drawing a new arrow is "Add Arrow").
    func updateArrow(_ id: ShapeID, named name: String = "Move Arrow End", _ change: (inout Arrow) -> Void) {
        editor.transact(name) { $0.update(id, as: Arrow.self) { change(&$0.props) } }
    }

    // MARK: - Targeting

    /// The front-most shape under `point` that arrows can bind to, of those `accepts` lets it.
    func connectable(at point: CGPoint, accepting accepts: ((AnyShapeRecord) -> Bool)? = nil) -> ConnectableShape? {
        connectables.shape(at: point, accepting: accepts)
    }

    /// The shape an arrow end at `point` would bind to. Holding ⌘ (or ⌃) binds to nothing.
    func arrowTarget(at point: CGPoint, modifiers: Modifiers, accepting accepts: ((AnyShapeRecord) -> Bool)? = nil) -> ConnectableShape? {
        guard modifiers.isDisjoint(with: [.command, .control]) else { return nil }
        return connectable(at: point, accepting: accepts)
    }

    /// What an end of an arrow may bind to, by the plugins' rules (`ArrowBindingRules`), `also`, and,
    /// for a shape that stands for others (a reference), what it stands for now (`PortState.allows`),
    /// the same judgement a port's drag ends by (`editor.channel(of:endingAt:)`): the static rule
    /// lets an arrow on any channel end at one, since its kind has ports on every channel, so an end
    /// re-aimed onto one that stands for nothing, or for what doesn't take the arrow's channel,
    /// would bind. Nil, anything, when there is no rule, `also` or stand-in.
    func filter(for arrowID: ShapeID, _ end: ArrowEnd, also: ((AnyShapeRecord) -> Bool)? = nil) -> ((AnyShapeRecord) -> Bool)? {
        guard let arrow = editor.document[arrowID] else { return also }
        let standIns = editor.service(PortState.self)
        guard !rules.isEmpty || standIns != nil else { return also }
        let rules = rules, registry = editor.registry
        return { shape in
            ArrowBindingQuery(arrow: arrow, end: end, shape: shape, registry: registry).isAllowed(by: rules) && (also?(shape) ?? true)
                && (standIns?.allows(end, of: arrow, at: shape) ?? true)
        }
    }

    /// Stops the precise timer and lets go of the shape an end was aiming at.
    func resetTargeting() {
        cancelPreciseTimer()
        editor.hintedShapeID = nil
    }

    /// Binds one end of an arrow to the shape at `point`, or frees it if there's none. This is
    /// tldraw's `updateArrowTargetState` and `onTerminalHandleDrag`. It binds only to a shape the
    /// plugins' rules let it (`ArrowBindingRules`), and `also` (a drag from a port's), looking
    /// through the rest.
    func bindTerminal(of arrowID: ShapeID, _ end: ArrowEnd, to point: CGPoint, isPrecise: Bool, modifiers: Modifiers,
                      accepting also: ((AnyShapeRecord) -> Bool)? = nil) {
        guard let arrow = arrow(arrowID) else { return }
        let current = arrow[end].binding
        let opposite = arrow[end.opposite].binding
        guard let target = arrowTarget(at: point, modifiers: modifiers, accepting: filter(for: arrowID, end, also: also)) else {
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
        resetTargeting()
    }

    /// Showing another board resets targeting too, whatever the tool: nothing aimed at on this
    /// board is there on the next.
    func boardWillChange(from old: BoardID, to new: BoardID, in editor: CanvasEditor) {
        resetTargeting()
    }

    /// Nothing kept per shape: `boardWillChange` reset it all.
    func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {}
}

/// Where `point` lies in `bounds`, as a binding's anchor: (0, 0) at its min corner, (1, 1) at its max.
func normalizedAnchor(_ point: CGPoint, in bounds: CGRect) -> CGPoint {
    CGPoint(x: (point.x - bounds.minX) / bounds.width, y: (point.y - bounds.minY) / bounds.height)
}

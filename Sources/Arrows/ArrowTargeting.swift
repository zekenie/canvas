import Canvas
import Connections
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
    /// The channel each arrow being drawn for a port's drag will be released on, by the shape its end is on: not stored on the arrow
    /// (a channel restricts what an end binds to), only read as its look is asked, so the marks it will have show as it is drawn.
    private(set) var provisionalChannels: [ShapeID: ChannelID] = [:]
    /// Every plugin's rules for what an end may bind to (`ArrowBindingRules`), found once.
    let rules: [ArrowBindingRules.Contribution]

    init(editor: CanvasEditor) {
        self.editor = editor
        rules = editor.registry.contributions(to: ArrowBindingRules.self).map(\.value)
    }

    var connectables: Connectables { Connectables(shapes: editor.shapeContext) }

    /// `arrow` (a value that may not be written yet) as the arrow `id` is laid out, but for its heads and width: a level curve
    /// reaches as far as its kept marks need, so the bend handle is where it is drawn.
    func geometry(of arrow: Arrow, id: ShapeID) -> ArrowGeometry {
        let connectables = connectables
        // As the arrow is drawn among others sharing its path (its slot's bow, its fans), so what a drag or a key turns into stored
        // values (a bend, an end's place) starts from the line the person sees.
        let detail = editor.shapeContext.geometry(of: id)?.arrowDetail
        return ArrowGeometry(arrow: arrow, strokeWidth: ArrowStyle.strokeWidth, markReach: detail?.markReach ?? (0, 0),
                             spread: detail?.spread ?? ArrowSpread()) { connectables[$0] }
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
    /// for a shape that stands for others (a reference), what it stands for now (`editor.portsAllow`),
    /// the same judgement a port's drag ends by (`editor.channel(of:endingAt:)`): the static rule
    /// lets an arrow on any channel end at one, since its kind has ports on every channel, so an end
    /// re-aimed onto one that stands for nothing, or for what doesn't take the arrow's channel,
    /// would bind. Its start is the connection's source, its end the target.
    func filter(for arrowID: ShapeID, _ end: ArrowEnd, also: ((AnyShapeRecord) -> Bool)? = nil) -> ((AnyShapeRecord) -> Bool)? {
        guard let arrow = editor.document[arrowID] else { return also }
        let rules = rules, registry = editor.registry, shapes = editor.shapeContext, editor = editor
        let role: PortRole = end == .start ? .source : .target
        return { shape in
            ArrowBindingQuery(arrow: arrow, end: end, shape: shape, registry: registry, shapes: shapes).isAllowed(by: rules) && (also?(shape) ?? true)
                && editor.portsAllow(arrow, as: role, at: shape)
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
    /// through the rest. `onto` is a shape a key picked (⌥⌘ and an arrow on a focused end: `ArrowParts`),
    /// bound to in place of the one at `point`, as an end that arrived quickly is: no pointer aimed.
    /// `reshape` changes the arrow further in the same commit, once the end is bound or free (a port's
    /// arrow bound back to the shape it starts from is made a loop). An end onto a shape whose rows it binds (`bindsPart`,
    /// a port's drag's; else the plugins' `ArrowPartRules`) binds the row nearest `point` across, at its side facing the
    /// other end, lit as the hint's part (`editor.hintedPart`).
    func bindTerminal(of arrowID: ShapeID, _ end: ArrowEnd, to point: CGPoint, isPrecise: Bool, modifiers: Modifiers,
                      accepting also: ((AnyShapeRecord) -> Bool)? = nil, onto picked: ConnectableShape? = nil,
                      bindsPart: ((AnyShapeRecord) -> Bool)? = nil, then reshape: ((inout Arrow) -> Void)? = nil) {
        guard let arrow = arrow(arrowID) else { return }
        let current = arrow[end].binding
        let opposite = arrow[end.opposite].binding
        guard let target = picked ?? arrowTarget(at: point, modifiers: modifiers, accepting: filter(for: arrowID, end, also: also)) else {
            updateArrow(arrowID) {
                $0[end] = .free(point)
                reshape?(&$0)
            }
            editor.hintedShapeID = nil
            return
        }
        if let record = editor.document[target.id], let arrowRecord = editor.document[arrowID],
           bindsPart?(record) ?? editor.registry.arrowBindsPart(arrowRecord, end, of: record, in: editor.shapeContext) {
            bindPart(of: arrowID, end, on: target, near: point, arrow: arrow, then: reshape)
            return
        }

        var precise = isPrecise
        if !precise, picked == nil, current?.shapeID != target.id {
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
        // A pill for a row (an endpoint's) is the row: the binding names it, as one made by name does.
        let row = editor.topology?.directPart(of: target.id)
        updateArrow(arrowID) {
            $0[end] = .bound(ArrowBinding(shapeID: target.id, normalizedAnchor: normalized, isPrecise: precise, isExact: isExact, part: row))
            reshape?(&$0)
        }
        editor.hintedShapeID = target.id
    }

    /// Binds `end` to the row of `target` nearest `point` across, at its side facing the other end (the stored anchor, where
    /// it's drawn while the row is gone), and lights it; with no row shown, or the row the other end is at, the end is free at `point`.
    private func bindPart(of arrowID: ShapeID, _ end: ArrowEnd, on target: ConnectableShape, near point: CGPoint, arrow: Arrow,
                          then reshape: ((inout Arrow) -> Void)?) {
        guard let frame = target.parts.frame(nearestY: point.y) else {
            updateArrow(arrowID) {
                $0[end] = .free(point)
                reshape?(&$0)
            }
            editor.hintedShapeID = nil
            return
        }
        // Not the row the other end is at: a key from a row to itself joins nothing, so nothing is lit where a release would make it.
        if arrow[end.opposite].binding?.address == PartAddress(target.id, part: frame.id) {
            updateArrow(arrowID) {
                $0[end] = .free(point)
                reshape?(&$0)
            }
            editor.hintedShapeID = nil
            return
        }
        let far = geometry(of: arrow, id: arrowID).handlePoint(at: end.opposite).x
        let binding = ArrowConnections.binding(to: target.id, part: frame.id, side: PartSide(facing: far, from: frame.rect), in: editor.shapeContext)
            ?? ArrowBinding(shapeID: target.id, normalizedAnchor: CGPoint(x: 1, y: 0.5), isPrecise: true, isExact: true, part: frame.id)
        updateArrow(arrowID) {
            $0[end] = .bound(binding)
            reshape?(&$0)
        }
        editor.hintedShapeID = target.id
        editor.hintedPart = frame.id
    }

    func startPreciseTimer(after delay: Duration, _ fire: @escaping @MainActor (ArrowTargeting) -> Void) {
        preciseTimer?.cancel()
        preciseTimer = editor.scheduler.schedule(after: delay) { [weak self] in
            guard let self else { return }
            fire(self)
        }
    }

    /// Sets, or with nil clears, the channel the arrow being drawn will be released on (in the transaction that binds its end).
    func setProvisionalChannel(_ channel: ChannelID?, for id: ShapeID) {
        provisionalChannels[id] = channel
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
}

/// Where `point` lies in `bounds`, as a binding's anchor: (0, 0) at its min corner, (1, 1) at its max.
func normalizedAnchor(_ point: CGPoint, in bounds: CGRect) -> CGPoint {
    CGPoint(x: (point.x - bounds.minX) / bounds.width, y: (point.y - bounds.minY) / bounds.height)
}

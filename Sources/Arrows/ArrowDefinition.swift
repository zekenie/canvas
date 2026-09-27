import AppKit
import Canvas
import Geometry

/// Arrows as a shape kind: no box; handles; their own translation; painted just above the
/// highest shape they're bound to. Each capability is its own extension.
@MainActor
struct ArrowDefinition {
    func arrowGeometry(_ arrow: Arrow, in context: ShapeContext) -> ArrowGeometry {
        let connectables = Connectables(shapes: context)
        return ArrowGeometry(arrow: arrow, strokeWidth: ArrowStyle.strokeWidth) { connectables[$0] }
    }
}

extension ArrowDefinition: ShapeDefinition {
    /// Draws in world coordinates; the caller has already applied the camera transform.
    func render(_ shape: ShapeRecord<Arrow>, in context: RenderContext) {
        let geometry = arrowGeometry(shape.props, in: context.shapes)
        let cg = context.cg
        cg.saveGState()
        cg.addPath(geometry.bodyPath)
        cg.addPath(geometry.arrowheadsPath(strokeWidth: ArrowStyle.strokeWidth))
        cg.setStrokeColor(ArrowStyle.color.cgColor)
        cg.setLineWidth(ArrowStyle.strokeWidth)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        cg.strokePath()
        cg.restoreGState()
    }

    /// Open: arrows never bind to arrows.
    func geometry(of shape: ShapeRecord<Arrow>, in context: ShapeContext) -> ShapeGeometry {
        let geometry = arrowGeometry(shape.props, in: context)
        return ShapeGeometry(outline: [geometry.start, geometry.middle, geometry.end], bounds: geometry.bodyPath.boundingBoxOfPath, isClosed: false)
    }

    func hitTest(_ point: CGPoint, on shape: ShapeRecord<Arrow>, in context: ShapeContext) -> Bool {
        let margin = ArrowStyle.hitMargin / context.zoom + ArrowStyle.strokeWidth / 2
        return arrowGeometry(shape.props, in: context).distance(to: point) <= margin
    }

    /// Exact, against the visible body: a brush in the hollow of a bent arrow's bounds doesn't
    /// select it (arrows are open, as in tldraw), nor does one over only the hidden stub inside a
    /// bound shape.
    func brushHitTest(_ brush: CGRect, on shape: ShapeRecord<Arrow>, in context: ShapeContext) -> Bool {
        arrowGeometry(shape.props, in: context).crosses(brush.polygon)
    }

    func indicatorPath(of shape: ShapeRecord<Arrow>, in context: ShapeContext) -> CGPath {
        let geometry = arrowGeometry(shape.props, in: context)
        let path = CGMutablePath()
        path.addPath(geometry.bodyPath)
        path.addPath(geometry.arrowheadsPath(strokeWidth: ArrowStyle.strokeWidth))
        return path
    }
}

extension ArrowDefinition: HandleProviding {
    /// The bend handle hides when it would crowd an end.
    func handles(of shape: ShapeRecord<Arrow>, in context: ShapeContext) -> [HandleLocation<ArrowHandle>] {
        let geometry = arrowGeometry(shape.props, in: context)
        let camera = context.camera
        let middle = camera.toView(geometry.middle)
        let isMiddleClear = [geometry.startHandle, geometry.endHandle].allSatisfy {
            camera.toView($0).distance(to: middle) >= ArrowStyle.middleHandleMinDistance
        }
        let visible: [ArrowHandle] = [.terminal(.start), .terminal(.end)] + (isMiddleClear ? [.middle] : [])
        return visible.map { HandleLocation($0, at: geometry.point(for: $0)) }
    }

    func pressHandle(_ handle: ArrowHandle, of shape: ShapeRecord<Arrow>, at pointer: Pointer, in editor: CanvasEditor) -> HandlePress {
        if pointer.clickCount == 2, case .terminal(let end) = handle {
            editor.transact { $0.update(shape.id, as: Arrow.self) { $0.props.toggleArrowhead(at: end) } }
            return .consumed
        }
        // Pressing a bound end outlines the shape it's bound to.
        if case .terminal(let end) = handle, let binding = shape.props[end].binding {
            editor.hintedShapeID = binding.shapeID
        }
        return .drag
    }

    func dragSession(for handle: ArrowHandle, of shape: ShapeRecord<Arrow>, from origin: CGPoint, in editor: CanvasEditor) -> any Session {
        let targeting = editor.service(ArrowTargeting.self)!
        let arrow = shape.props
        var isPrecise = false
        if case .terminal(let end) = handle, let binding = arrow[end].binding {
            isPrecise = binding.isPrecise
        }
        let drag = ArrowHandleDragSession(arrowID: shape.id, handle: handle, isCreating: false,
                                          handleOffset: targeting.geometry(of: arrow).point(for: handle) - origin,
                                          isPrecise: isPrecise, targeting: targeting)
        if case .terminal(let end) = handle, arrow[end].binding != nil, !isPrecise {
            drag.startDragPreciseTimer()
        }
        return drag
    }
}

extension ArrowDefinition: CustomTranslation {
    /// tldraw's arrow onTranslateStart and onTranslate:
    /// - Moving with a shape it's bound to, every binding stays (an end bound to a shape left
    ///   behind stretches) and free ends move by the delta.
    /// - Moving without any of its shapes (alone, or with unrelated shapes), bound ends are made
    ///   precise where they are, committed before the first move. Each end stays bound, its anchor
    ///   sliding with the pointer, while that point is on its shape; off it, the end lets go, and
    ///   it binds again if the point comes back.
    /// Deliberate, pre-existing deviation: the ends probe at the full delta (tldraw: delta × 0.5),
    /// as the POC's transcript pins.
    func beginTranslation(of shape: ShapeRecord<Arrow>, movingWith moving: Set<ShapeID>,
                          in transaction: inout Transaction) -> ShapeTranslation<Arrow> {
        let ends = [ArrowEnd.start, .end]
        var arrow = shape.props
        let movesWithItsShapes = ends.contains { end in arrow[end].binding.map { moving.contains($0.shapeID) } ?? false }
        if movesWithItsShapes {
            let start = arrow
            return ShapeTranslation { delta, shape, _ in
                for end in ends {
                    if case .free(let point) = start[end] { shape.props[end] = .free(point + delta) }
                }
            }
        }
        let connectables = Connectables(shapes: transaction.shapes)
        let geometry = ArrowGeometry(arrow: arrow, strokeWidth: ArrowStyle.strokeWidth) { connectables[$0] }
        var bindings: [ArrowEnd: ArrowBinding] = [:]
        for end in ends {
            guard var binding = arrow[end].binding, let bounds = connectables[binding.shapeID]?.bounds else { continue }
            binding.normalizedAnchor = normalizedAnchor(geometry.handlePoint(at: end), in: bounds)
            binding.isPrecise = true
            arrow[end] = .bound(binding)
            bindings[end] = binding
        }
        transaction.update(shape.id, as: Arrow.self) { $0.props = arrow }
        let startHandle = geometry.startHandle, endHandle = geometry.endHandle
        return ShapeTranslation { delta, shape, shapes in
            let connectables = Connectables(shapes: shapes)
            for (end, handle, binding) in [(ArrowEnd.start, startHandle, bindings[.start]), (.end, endHandle, bindings[.end])] {
                let point = handle + delta
                if var binding, let target = connectables.shape(at: point), target.id == binding.shapeID {
                    binding.normalizedAnchor = normalizedAnchor(point, in: target.bounds)
                    shape.props[end] = .bound(binding)
                } else {
                    shape.props[end] = .free(point)
                }
            }
        }
    }
}

extension ArrowDefinition: PaintOrderAnchored {
    /// Just above the highest shape it's bound to, so it's never hidden behind its own shapes.
    func paintAnchor(of shape: ShapeRecord<Arrow>, in document: CanvasDocument) -> ShapeID? {
        let indices = [shape.props.start, shape.props.end].compactMap { $0.binding.flatMap { document.index(of: $0.shapeID) } }
        return indices.max().map { document.shapes[$0].id }
    }
}

/// Lets go of shapes that are about to be deleted: bound ends stay where they visibly are and the
/// arrow keeps its curve. Runs inside the deleting transaction, while the shapes still exist.
@MainActor
func releaseArrows(boundTo ids: Set<ShapeID>, in transaction: inout Transaction) {
    let connectables = Connectables(shapes: transaction.shapes)
    for record in transaction.document.shapes {
        guard let arrow = record.typed(as: Arrow.self)?.props else { continue }
        let ends = Set([ArrowEnd.start, .end].filter { arrow[$0].binding.map { ids.contains($0.shapeID) } ?? false })
        guard !ends.isEmpty else { continue }
        let geometry = ArrowGeometry(arrow: arrow, strokeWidth: ArrowStyle.strokeWidth) { connectables[$0] }
        transaction.update(record.id, as: Arrow.self) { shape in
            if let bend = geometry.bendKeepingCurve(movingHandlesToVisibleEndsAt: ends) {
                shape.props.bend = bend
            }
            for end in ends {
                shape.props[end] = .free(geometry.visiblePoint(at: end))
            }
        }
    }
}

/// For a selected arrow bound to shapes: a faint dashed stub from each anchor to where the arrow
/// visibly ends, with a dot at an imprecise anchor (the shape's center) or a cross at a precise
/// one. Exact ends get neither, since the arrow runs right up to the anchor.
struct BindingHintsOverlay: CanvasOverlay {
    var space: OverlaySpace { .world }

    func draw(in overlay: OverlayContext) {
        let editor = overlay.editor
        guard editor.currentToolID == .select || editor.session is ArrowHandleDragSession,
              let id = editor.selection,
              let arrow = editor.document[id]?.typed(as: Arrow.self)?.props else { return }
        let connectables = Connectables(shapes: overlay.shapes)
        let geometry = ArrowGeometry(arrow: arrow, strokeWidth: ArrowStyle.strokeWidth) { connectables[$0] }
        let zoom = overlay.zoom
        let lineWidth = ArrowStyle.bindingHintWidth / zoom
        let context = overlay.cg

        context.saveGState()
        context.setAlpha(ArrowStyle.bindingHintOpacity)
        context.setStrokeColor(ArrowStyle.bindingHintColor.cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for end in [ArrowEnd.start, .end] {
            guard let binding = arrow[end].binding, !binding.isExact else { continue }
            let handle = geometry.handlePoint(at: end)
            let markerRadius = (binding.isPrecise ? ArrowStyle.bindingCrossSize / 2 : ArrowStyle.bindingDotRadius) / zoom

            if let stub = geometry.bindingStub(at: end, inset: markerRadius) {
                context.saveGState()
                // Dashes get too small to read when zoomed far out.
                if zoom >= 0.2 {
                    context.setLineDash(phase: 0, lengths: [2 * lineWidth, 2 * lineWidth])
                }
                context.addPath(stub)
                context.strokePath()
                context.restoreGState()
            }

            if binding.isPrecise {
                // A cross, turned to line up with the arrow's path.
                let direction = geometry.directionFromHandle(at: end)
                let half = ArrowStyle.bindingCrossSize / 2 / zoom
                let a = direction.rotated(around: .zero, by: .pi / 4) * half
                let b = direction.rotated(around: .zero, by: -.pi / 4) * half
                context.move(to: handle - a)
                context.addLine(to: handle + a)
                context.move(to: handle - b)
                context.addLine(to: handle + b)
            } else {
                context.addEllipse(in: CGRect(
                    x: handle.x - markerRadius, y: handle.y - markerRadius,
                    width: markerRadius * 2, height: markerRadius * 2
                ))
            }
            context.strokePath()
        }
        context.restoreGState()
    }
}

public struct ArrowsPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { .arrows }
    public func register(into registrar: inout PluginRegistrar) {
        registrar.shape(ArrowDefinition())
        registrar.service { ArrowTargeting(editor: $0) }
        registrar.tool(ToolDescriptor(id: .arrow, label: "Arrow", systemImage: "arrow.up.right", shortcut: "a")) { editor in
            ArrowTool(targeting: editor.service(ArrowTargeting.self)!)
        }
        registrar.overlay(BindingHintsOverlay())
        registrar.willDelete { ids, transaction in releaseArrows(boundTo: ids, in: &transaction) }
    }
}

extension CanvasEditor {
    /// An arrow's resolved geometry, for tests and tools.
    public func arrowGeometry(of id: ShapeID) -> ArrowGeometry? {
        guard let arrow = document[id]?.typed(as: Arrow.self)?.props else { return nil }
        return ArrowDefinition().arrowGeometry(arrow, in: shapeContext)
    }
}

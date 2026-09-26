import AppKit

enum ArrowHandle: Equatable {
    case terminal(ArrowEnd)
    /// Bends the arrow.
    case middle
}

/// Arrow behavior, modeled closely on tldraw's.
///
/// An arrow end binds to the front-most `Connectable` shape under the pointer; arrows know
/// nothing else about the shapes they connect. How an end binds depends on how the user got
/// there: arriving quickly aims at the shape's center ("imprecise"), while arriving slowly or
/// pausing aims at the exact spot under the pointer ("precise"). Holding ⌥ runs the arrow all
/// the way to that spot ("exact"), and holding ⌘ keeps it from binding at all.
extension CanvasView {
    struct HandleDrag {
        var arrowID: Arrow.ID
        var handle: ArrowHandle
        /// This drag is drawing a new arrow with the arrow tool.
        var isCreating: Bool
        /// The handle keeps its offset from the pointer, so grabbing it off-center doesn't make it jump.
        var handleOffset: CGPoint
        /// Whether the dragged end aims precisely: after pausing on a shape, or arriving slowly.
        var isPrecise: Bool
    }

    struct ArrowTranslation {
        var arrowID: Arrow.ID
        var origin: CGPoint
        /// Each end's handle and binding when the move started.
        var startHandle: CGPoint
        var endHandle: CGPoint
        var startBinding: ArrowBinding?
        var endBinding: ArrowBinding?
    }

    /// Pass `connectables` (from `connectablesByID()`) when resolving several arrows at once.
    func geometry(of arrow: Arrow, connectables: [ShapeID: any Connectable]? = nil) -> ArrowGeometry {
        let connectables = connectables ?? connectablesByID()
        return ArrowGeometry(arrow: arrow, strokeWidth: Style.arrowStrokeWidth) { connectables[$0] }
    }

    // MARK: - Targeting

    /// The front-most shape under `point` that arrows can bind to.
    func connectable(at point: CGPoint) -> (any Connectable)? {
        connectables.last { $0.contains(point) }
    }

    /// The shape an arrow end at `point` would bind to. Holding ⌘ (or ⌃) binds to nothing.
    func arrowTarget(at point: CGPoint, modifiers: NSEvent.ModifierFlags) -> (any Connectable)? {
        guard modifiers.isDisjoint(with: [.command, .control]) else { return nil }
        return connectable(at: point)
    }

    /// Before pressing, the arrow tool outlines the shape it would start from. Hovering one shape
    /// long enough means the user is aiming, so the arrow will start precisely where they press.
    func updateArrowToolTarget(at point: CGPoint, modifiers: NSEvent.ModifierFlags) {
        let target = arrowTarget(at: point, modifiers: modifiers)?.id
        guard target != targetShapeID else { return }
        targetShapeID = target
        arrowToolIsPrecise = false
        if target != nil {
            startPreciseTimer(after: Style.hoverPreciseDelay) { $0.arrowToolIsPrecise = true }
        } else {
            cancelPreciseTimer()
        }
    }

    func resetArrowToolTargeting() {
        cancelPreciseTimer()
        arrowToolIsPrecise = false
        targetShapeID = nil
    }

    func restartArrowToolTargeting() {
        resetArrowToolTargeting()
        updateArrowToolTarget(at: camera.toWorld(pointerLocation), modifiers: effectiveModifiers(NSEvent.modifierFlags))
    }

    /// Binds one end of an arrow to the shape at `point`, or frees it if there's none. This is
    /// tldraw's `updateArrowTargetState` and `onTerminalHandleDrag`.
    func bindTerminal(of index: Int, _ end: ArrowEnd, to point: CGPoint, isPrecise: Bool, modifiers: NSEvent.ModifierFlags) {
        let current = arrows[index][end].binding
        let opposite = arrows[index][end.opposite].binding
        needsDisplay = true
        guard let target = arrowTarget(at: point, modifiers: modifiers) else {
            arrows[index][end] = .free(point)
            targetShapeID = nil
            return
        }

        var precise = isPrecise
        if !precise, current?.shapeID != target.id {
            // Arriving at a shape slowly means the user is aiming at a spot in it.
            precise = pointerSpeed < Style.slowPointerSpeed
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
            let snapDistance = min(max(min(bounds.width, bounds.height) * 0.15, 4), 16) / camera.zoom
            if point.distance(to: bounds.center) < snapDistance {
                anchor = bounds.center
            }
        }
        var normalizedAnchor = normalized(anchor, in: bounds)
        if let opposite, opposite.shapeID == target.id, opposite.normalizedAnchor == normalizedAnchor {
            normalizedAnchor.x += 0.05
        }
        arrows[index][end] = .bound(ArrowBinding(
            shapeID: target.id,
            normalizedAnchor: normalizedAnchor,
            isPrecise: precise,
            isExact: isExact
        ))
        targetShapeID = target.id
    }

    func startPreciseTimer(after delay: Duration, _ fire: @escaping @MainActor (CanvasView) -> Void) {
        preciseTimer?.cancel()
        preciseTimer = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            fire(self)
        }
    }

    func cancelPreciseTimer() {
        preciseTimer?.cancel()
        preciseTimer = nil
    }

    // MARK: - Drawing a new arrow

    func pressWithArrowTool(at viewPoint: CGPoint, modifiers: NSEvent.ModifierFlags) {
        updateArrowToolTarget(at: camera.toWorld(viewPoint), modifiers: modifiers)
        interaction = .pointingWithArrowTool(origin: viewPoint)
        // Holding still before dragging also means the user is aiming.
        startPreciseTimer(after: Style.pressPreciseDelay) { $0.arrowToolIsPrecise = true }
    }

    func createArrow(from origin: CGPoint, to pointer: CGPoint, modifiers: NSEvent.ModifierFlags) {
        cancelPreciseTimer()
        let arrow = Arrow(start: .free(origin), end: .free(origin))
        arrows.append(arrow)
        let index = arrows.count - 1
        selection = .arrow(arrow.id)

        // The start binds where the press happened: to the shape's center, unless the user dwelt
        // first. (Binding precisely first means the second pass keeps the same shape without
        // re-checking pointer speed, as tldraw does.)
        bindTerminal(of: index, .start, to: origin, isPrecise: true, modifiers: modifiers)
        bindTerminal(of: index, .start, to: origin, isPrecise: arrowToolIsPrecise || modifiers.contains(.option), modifiers: modifiers)
        arrowToolIsPrecise = false

        interaction = .draggingHandle(HandleDrag(
            arrowID: arrow.id,
            handle: .terminal(.end),
            isCreating: true,
            handleOffset: .zero,
            isPrecise: false
        ))
        updateHandleDrag(to: pointer, modifiers: modifiers)
        updateCursor()
    }

    func cancelArrowCreation(_ drag: HandleDrag) {
        cancelPreciseTimer()
        arrows.removeAll { $0.id == drag.arrowID }
        selection = nil
        targetShapeID = nil
        interaction = nil
        // Stay in the arrow tool, ready for another try.
    }

    // MARK: - Handles

    /// The handles a selected arrow shows. The bend handle hides when it would crowd an end.
    func visibleHandles(of geometry: ArrowGeometry) -> [ArrowHandle] {
        let middle = camera.toView(geometry.middle)
        let isMiddleClear = [geometry.startHandle, geometry.endHandle].allSatisfy {
            camera.toView($0).distance(to: middle) >= Style.middleHandleMinDistance
        }
        return [.terminal(.start), .terminal(.end)] + (isMiddleClear ? [.middle] : [])
    }

    func arrowHandle(of id: Arrow.ID, at viewPoint: CGPoint) -> ArrowHandle? {
        guard let arrow = arrows.first(where: { $0.id == id }) else { return nil }
        let geometry = geometry(of: arrow)
        return visibleHandles(of: geometry)
            .map { handle in (handle, camera.toView(geometry.point(for: handle)).distance(to: viewPoint)) }
            .filter { $0.1 <= Style.handleHitRadius }
            .min { $0.1 < $1.1 }?
            .0
    }

    func pressHandle(_ handle: ArrowHandle, of id: Arrow.ID, at viewPoint: CGPoint, clickCount: Int) {
        guard let index = arrows.firstIndex(where: { $0.id == id }) else { return }
        if clickCount == 2, case .terminal(let end) = handle {
            arrows[index].toggleArrowhead(at: end)
            needsDisplay = true
            return
        }
        interaction = .pointingHandle(arrowID: id, handle: handle, origin: viewPoint)
        // Pressing a bound end outlines the shape it's bound to.
        if case .terminal(let end) = handle, let binding = arrows[index][end].binding {
            targetShapeID = binding.shapeID
        }
        updateCursor()
    }

    func beginDraggingHandle(_ handle: ArrowHandle, of id: Arrow.ID, from origin: CGPoint) {
        guard let arrow = arrows.first(where: { $0.id == id }) else { return }
        var isPrecise = false
        if case .terminal(let end) = handle, let binding = arrow[end].binding {
            isPrecise = binding.isPrecise
        }
        hoveredHandle = nil
        interaction = .draggingHandle(HandleDrag(
            arrowID: id,
            handle: handle,
            isCreating: false,
            handleOffset: geometry(of: arrow).point(for: handle) - origin,
            isPrecise: isPrecise
        ))
        if case .terminal(let end) = handle, arrow[end].binding != nil, !isPrecise {
            startDragPreciseTimer()
        }
        updateCursor()
    }

    func updateHandleDrag(to pointer: CGPoint, modifiers: NSEvent.ModifierFlags) {
        guard case .draggingHandle(var drag) = interaction,
              let index = arrows.firstIndex(where: { $0.id == drag.arrowID }) else { return }
        var point = pointer + drag.handleOffset

        switch drag.handle {
        case .middle:
            // The curve passes through the pointer's projection onto the perpendicular bisector
            // of the ends; sideways motion does nothing.
            let geometry = geometry(of: arrows[index])
            let midpoint = (geometry.startHandle + geometry.endHandle) / 2
            arrows[index].bend = (point - midpoint).dot(geometry.bendAxis)
            needsDisplay = true

        case .terminal(let end):
            if modifiers.contains(.shift) {
                let pivot = geometry(of: arrows[index]).handlePoint(at: end.opposite)
                point = snapAngle(of: point, around: pivot, steps: 24)
            }
            let before = arrows[index][end].binding
            bindTerminal(of: index, end, to: point, isPrecise: drag.isPrecise || modifiers.contains(.option), modifiers: modifiers)
            let after = arrows[index][end].binding
            // Each new shape starts over: precise only if arrived at slowly or after a pause there.
            if let after {
                if before?.shapeID != after.shapeID {
                    drag.isPrecise = pointerSpeed < Style.slowPointerSpeed || modifiers.contains(.option)
                    startDragPreciseTimer()
                }
            } else if before != nil {
                drag.isPrecise = false
                startDragPreciseTimer()
            }
        }
        interaction = .draggingHandle(drag)
    }

    private func startDragPreciseTimer() {
        startPreciseTimer(after: Style.pressPreciseDelay) { canvas in
            guard case .draggingHandle(var drag) = canvas.interaction, !drag.isPrecise else { return }
            drag.isPrecise = true
            canvas.interaction = .draggingHandle(drag)
            canvas.updateHandleDrag(
                to: canvas.camera.toWorld(canvas.pointerLocation),
                modifiers: canvas.effectiveModifiers(NSEvent.modifierFlags)
            )
        }
    }

    func finishHandleDrag(_ drag: HandleDrag) {
        cancelPreciseTimer()
        targetShapeID = nil
        selection = .arrow(drag.arrowID)
        if drag.isCreating {
            switchTool(to: .select)
        }
    }

    // MARK: - Moving arrows

    /// Moving an arrow on its own keeps each binding, made precise, for as long as that end's
    /// anchor stays on its shape. An end moved off its shape lets go.
    func beginTranslatingArrow(_ id: Arrow.ID, from origin: CGPoint) {
        guard let index = arrows.firstIndex(where: { $0.id == id }) else { return }
        let connectables = connectablesByID()
        let geometry = geometry(of: arrows[index], connectables: connectables)
        var bindings: [ArrowEnd: ArrowBinding] = [:]
        for end in [ArrowEnd.start, .end] {
            guard var binding = arrows[index][end].binding,
                  let bounds = connectables[binding.shapeID]?.bounds else { continue }
            binding.normalizedAnchor = normalized(geometry.handlePoint(at: end), in: bounds)
            binding.isPrecise = true
            arrows[index][end] = .bound(binding)
            bindings[end] = binding
        }
        interaction = .translatingArrow(ArrowTranslation(
            arrowID: id,
            origin: origin,
            startHandle: geometry.startHandle,
            endHandle: geometry.endHandle,
            startBinding: bindings[.start],
            endBinding: bindings[.end]
        ))
    }

    func updateArrowTranslation(to pointer: CGPoint) {
        guard case .translatingArrow(let move) = interaction,
              let index = arrows.firstIndex(where: { $0.id == move.arrowID }) else { return }
        let delta = pointer - move.origin
        for (end, handle, binding) in [(ArrowEnd.start, move.startHandle, move.startBinding), (.end, move.endHandle, move.endBinding)] {
            let point = handle + delta
            if var binding, let shape = connectable(at: point), shape.id == binding.shapeID {
                binding.normalizedAnchor = normalized(point, in: shape.bounds)
                arrows[index][end] = .bound(binding)
            } else {
                arrows[index][end] = .free(point)
            }
        }
        needsDisplay = true
    }

    /// Lets go of a shape that's about to be deleted: bound ends stay where they visibly are and
    /// the arrow keeps its curve.
    func releaseArrows(from shapeID: ShapeID) {
        let connectables = connectablesByID()
        for index in arrows.indices {
            let ends = Set([ArrowEnd.start, .end].filter { arrows[index][$0].binding?.shapeID == shapeID })
            guard !ends.isEmpty else { continue }
            let geometry = geometry(of: arrows[index], connectables: connectables)
            if let bend = geometry.bendKeepingCurve(movingHandlesToVisibleEndsAt: ends) {
                arrows[index].bend = bend
            }
            for end in ends {
                arrows[index][end] = .free(geometry.visiblePoint(at: end))
            }
        }
    }

    private func normalized(_ point: CGPoint, in bounds: CGRect) -> CGPoint {
        CGPoint(x: (point.x - bounds.minX) / bounds.width, y: (point.y - bounds.minY) / bounds.height)
    }

    // MARK: - Drawing

    /// Draws in world coordinates; the caller has already applied the camera transform.
    func drawArrow(_ geometry: ArrowGeometry, in context: CGContext) {
        context.saveGState()
        context.addPath(geometry.bodyPath)
        context.addPath(geometry.arrowheadsPath(strokeWidth: Style.arrowStrokeWidth))
        context.setStrokeColor(Style.arrowColor.cgColor)
        context.setLineWidth(Style.arrowStrokeWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.strokePath()
        context.restoreGState()
    }

    /// For a selected arrow bound to shapes: a faint dashed stub from each anchor to where the
    /// arrow visibly ends, with a dot at an imprecise anchor (the shape's center) or a cross at a
    /// precise one. Exact ends get neither, since the arrow runs right up to the anchor.
    func drawBindingHints(in context: CGContext, connectables: [ShapeID: any Connectable]) {
        let isDraggingHandle = if case .draggingHandle = interaction { true } else { false }
        guard tool == .select || isDraggingHandle,
              case .arrow(let id)? = selection,
              let arrow = arrows.first(where: { $0.id == id }) else { return }
        let geometry = geometry(of: arrow, connectables: connectables)
        let zoom = camera.zoom
        let lineWidth = Style.bindingHintWidth / zoom

        context.saveGState()
        context.setAlpha(Style.bindingHintOpacity)
        context.setStrokeColor(Style.bindingHintColor.cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for end in [ArrowEnd.start, .end] {
            guard let binding = arrow[end].binding, !binding.isExact else { continue }
            let handle = geometry.handlePoint(at: end)
            let markerRadius = (binding.isPrecise ? Style.bindingCrossSize / 2 : Style.bindingDotRadius) / zoom

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
                let half = Style.bindingCrossSize / 2 / zoom
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

    /// Handles for the selected arrow, in view coordinates. They hide while anything is dragged.
    func drawArrowHandles(in context: CGContext, connectables: [ShapeID: any Connectable]) {
        var pressedHandle: ArrowHandle?
        switch interaction {
        case nil: break
        case .pointingHandle(_, let handle, _): pressedHandle = handle
        default: return
        }
        guard tool == .select,
              case .arrow(let id)? = selection,
              let arrow = arrows.first(where: { $0.id == id }) else { return }
        let geometry = geometry(of: arrow, connectables: connectables)
        // Handles shrink once zoomed out past 25%.
        let radius = Style.handleRadius * min(1, camera.zoom / 0.25)

        for handle in visibleHandles(of: geometry) {
            let center = camera.toView(geometry.point(for: handle))
            func circle(_ radius: CGFloat) -> CGRect {
                CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            }
            if handle == hoveredHandle || handle == pressedHandle {
                context.setFillColor(Style.accentFill.cgColor)
                context.fillEllipse(in: circle(Style.handleHitRadius))
            }
            context.setFillColor(NSColor.white.cgColor)
            context.fillEllipse(in: circle(radius))
            context.setStrokeColor(Style.accent.cgColor)
            context.setLineWidth(Style.indicatorWidth)
            context.strokeEllipse(in: circle(radius))
        }
    }
}

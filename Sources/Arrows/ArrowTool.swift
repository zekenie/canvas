import Canvas
import CoreGraphics
import Geometry
import Selection

/// Draws arrows. Hovering outlines the shape an arrow would start from; pressing starts a
/// pointing session, which past the drag threshold creates the arrow and drags its end.
@MainActor
final class ArrowTool {
    let targeting: ArrowTargeting
    init(targeting: ArrowTargeting) { self.targeting = targeting }
}

extension ArrowTool: Tool {
    func pointerDown(_ pointer: Pointer, in editor: CanvasEditor) {
        targeting.updateArrowToolTarget(at: pointer.world, modifiers: pointer.modifiers)
        editor.session = PointingWithArrowToolSession(origin: pointer.view, targeting: targeting)
        // Holding still before dragging also means the user is aiming.
        targeting.startPreciseTimer(after: ArrowStyle.pressPreciseDelay) { $0.arrowToolIsPrecise = true }
    }

    func pointerMoved(_ pointer: Pointer, in editor: CanvasEditor) {
        targeting.updateArrowToolTarget(at: pointer.world, modifiers: pointer.modifiers)
    }

    func modifiersChanged(_ modifiers: Modifiers, in editor: CanvasEditor) {
        targeting.updateArrowToolTarget(at: editor.pointerWorldLocation, modifiers: modifiers)
    }

    func pointerExited(in editor: CanvasEditor) {
        targeting.resetArrowToolTargeting()
    }
}

/// Pressed with the arrow tool; draws an arrow once the pointer passes the drag threshold.
@MainActor
final class PointingWithArrowToolSession {
    let origin: CGPoint
    let targeting: ArrowTargeting
    init(origin: CGPoint, targeting: ArrowTargeting) {
        self.origin = origin
        self.targeting = targeting
    }
}

extension PointingWithArrowToolSession: Session {
    func drag(_ pointer: Pointer, in editor: CanvasEditor) {
        guard pointer.view.distance(to: origin) > Style.dragThreshold else { return }
        createArrow(from: editor.camera.toWorld(origin), to: pointer.world, modifiers: pointer.modifiers, in: editor)
    }

    /// A click without a drag makes no arrow.
    func end(_ pointer: Pointer, in editor: CanvasEditor) {
        targeting.restartArrowToolTargeting()
    }
}

extension PointingWithArrowToolSession {
    private func createArrow(from origin: CGPoint, to pointer: CGPoint, modifiers: Modifiers, in editor: CanvasEditor) {
        targeting.cancelPreciseTimer()
        let arrow = ShapeRecord(Arrow(start: .free(origin), end: .free(origin)))
        editor.transact { $0.insert(arrow) }
        editor.selection = arrow.id

        // The start binds where the press happened: to the shape's center, unless the user dwelt
        // first. (Binding precisely first means the second pass keeps the same shape without
        // re-checking pointer speed, as tldraw does.)
        targeting.bindTerminal(of: arrow.id, .start, to: origin, isPrecise: true, modifiers: modifiers)
        targeting.bindTerminal(of: arrow.id, .start, to: origin, isPrecise: targeting.arrowToolIsPrecise || modifiers.contains(.option), modifiers: modifiers)
        targeting.arrowToolIsPrecise = false

        let drag = ArrowHandleDragSession(arrowID: arrow.id, handle: .terminal(.end), isCreating: true,
                                          handleOffset: .zero, isPrecise: false, targeting: targeting)
        editor.session = drag
        drag.update(to: pointer, modifiers: modifiers)
    }
}

/// Dragging an arrow's handle: an end (binding as it goes) or the bend handle.
@MainActor
final class ArrowHandleDragSession {
    let arrowID: ShapeID
    let handle: ArrowHandle
    /// This drag is drawing a new arrow, with the arrow tool or for another plugin (`connecting`).
    let isCreating: Bool
    /// The handle keeps its offset from the pointer, so grabbing it off-center doesn't make it jump.
    let handleOffset: CGPoint
    /// Whether the dragged end aims precisely: after pausing on a shape, or arriving slowly.
    private(set) var isPrecise: Bool
    let targeting: ArrowTargeting
    /// This drag is drawing an arrow for another plugin's gesture (`CanvasEditor.beginArrow`).
    let connecting: ArrowConnecting?

    init(arrowID: ShapeID, handle: ArrowHandle, isCreating: Bool, handleOffset: CGPoint, isPrecise: Bool, targeting: ArrowTargeting,
         connecting: ArrowConnecting? = nil) {
        self.arrowID = arrowID
        self.handle = handle
        self.isCreating = isCreating
        self.handleOffset = handleOffset
        self.isPrecise = isPrecise
        self.targeting = targeting
        self.connecting = connecting
    }
}

extension ArrowHandleDragSession: Session {
    func cursor(in editor: CanvasEditor) -> CanvasCursor? { .closedHand }
    var hidesOutlines: Bool { true }

    func drag(_ pointer: Pointer, in editor: CanvasEditor) {
        update(to: pointer.world, modifiers: pointer.modifiers)
    }

    /// Modifiers change how arrow ends bind, so re-evaluate without waiting for the pointer to move.
    func modifiersChanged(_ modifiers: Modifiers, in editor: CanvasEditor) {
        update(to: editor.pointerWorldLocation, modifiers: modifiers)
    }

    func end(_ pointer: Pointer, in editor: CanvasEditor) {
        targeting.cancelPreciseTimer()
        editor.hintedShapeID = nil
        if let connecting {
            finish(connecting, in: editor)
            return
        }
        editor.selection = arrowID
        if isCreating {
            editor.setTool(editor.registry.defaultTool)       // Select, with the selection installed
        }
    }

    /// An arrow drawn for another plugin's gesture: bound, it's finished by that plugin; free, it's
    /// deleted, so nothing is drawn. The selection is left as it was.
    private func finish(_ connecting: ArrowConnecting, in editor: CanvasEditor) {
        guard case .terminal(let end) = handle, let target = targeting.arrow(arrowID)?[end].binding?.shapeID else {
            editor.transact { $0.delete([arrowID]) }
            return
        }
        editor.transact { $0.update(arrowID) { connecting.complete(&$0, target) } }
    }

    /// Escape while drawing a new arrow deletes it: with the arrow tool, staying in the tool, ready
    /// for another try; for another plugin's gesture, leaving the selection as it was. Escape while
    /// re-aiming an existing end does nothing.
    func cancel(in editor: CanvasEditor) -> Bool {
        if connecting != nil {
            targeting.cancelPreciseTimer()
            editor.transact { $0.delete([arrowID]) }
            editor.hintedShapeID = nil
            return true
        }
        guard isCreating else { return false }
        targeting.cancelPreciseTimer()
        editor.transact { $0.delete([arrowID]) }
        editor.selection = nil
        editor.hintedShapeID = nil
        return true
    }
}

extension ArrowHandleDragSession {
    func update(to pointer: CGPoint, modifiers: Modifiers) {
        guard let arrow = targeting.arrow(arrowID) else { return }
        var point = pointer + handleOffset

        switch handle {
        case .middle:
            // The curve passes through the pointer's projection onto the perpendicular bisector
            // of the ends; sideways motion does nothing.
            let geometry = targeting.geometry(of: arrow)
            let midpoint = (geometry.startHandle + geometry.endHandle) / 2
            targeting.updateArrow(arrowID) { $0.bend = (point - midpoint).dot(geometry.bendAxis) }

        case .terminal(let end):
            if modifiers.contains(.shift) {
                let pivot = targeting.geometry(of: arrow).handlePoint(at: end.opposite)
                point = snapAngle(of: point, around: pivot, steps: 24)
            }
            let before = arrow[end].binding
            targeting.bindTerminal(of: arrowID, end, to: point, isPrecise: isPrecise || modifiers.contains(.option), modifiers: modifiers,
                                   accepting: connecting?.canBind)
            let after = targeting.arrow(arrowID)?[end].binding
            // Each new shape starts over: precise only if arrived at slowly or after a pause there.
            if let after {
                if before?.shapeID != after.shapeID {
                    isPrecise = targeting.editor.pointerSpeed < ArrowStyle.slowPointerSpeed || modifiers.contains(.option)
                    startDragPreciseTimer()
                }
            } else if before != nil {
                isPrecise = false
                startDragPreciseTimer()
            }
        }
    }

    func startDragPreciseTimer() {
        targeting.startPreciseTimer(after: ArrowStyle.pressPreciseDelay) { [weak self] targeting in
            guard let self, targeting.editor.session === self, !isPrecise else { return }
            isPrecise = true
            update(to: targeting.editor.pointerWorldLocation, modifiers: targeting.editor.effectiveModifiers)
        }
    }
}

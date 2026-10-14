import Canvas
import CoreGraphics
import Geometry
import Selection
import Types

/// Dragging an arrow's handle: an end (binding as it goes) or the bend handle; or the end of an
/// arrow drawn for a port's drag (`connecting`).
@MainActor
final class ArrowHandleDragSession {
    let arrowID: ShapeID
    let handle: ArrowHandle
    /// The handle keeps its offset from the pointer, so grabbing it off-center doesn't make it jump.
    let handleOffset: CGPoint
    /// Whether the dragged end aims precisely: after pausing on a shape, or arriving slowly.
    private(set) var isPrecise: Bool
    let targeting: ArrowTargeting
    /// This drag is drawing an arrow for a port's drag (`CanvasEditor.beginArrow`).
    let connecting: ArrowConnecting?

    init(arrowID: ShapeID, handle: ArrowHandle, handleOffset: CGPoint, isPrecise: Bool, targeting: ArrowTargeting,
         connecting: ArrowConnecting? = nil) {
        self.arrowID = arrowID
        self.handle = handle
        self.handleOffset = handleOffset
        self.isPrecise = isPrecise
        self.targeting = targeting
        self.connecting = connecting
    }
}

extension ArrowHandleDragSession: Session {
    func cursor(in editor: CanvasEditor) -> CanvasCursor? { .closedHand }
    var hidesOutlines: Bool { true }
    /// A connection drawn for a port's drag scrolls the canvas at its edges, so
    /// it can reach a shape off screen; a handle's drag doesn't, as tldraw's doesn't.
    var scrollsAtEdges: Bool { connecting != nil }

    /// The arrow whose end or bend it moves, from the press to the release: bound and unbound at each
    /// hover, it is no relationship yet, and a service that reads arrows leaves it alone until then.
    var touching: Set<ShapeID> { [arrowID] }

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
        // A re-aim bound and unbound it at every hover: the relationships count it as it is now.
        editor.connectionReleased(arrowID)
    }

    /// An arrow drawn for a port's drag: bound, it's finished by `ArrowPortsPlugin` and told (`finished`, still in
    /// the press, so what it does is the press's step); free, it's deleted, so nothing is drawn. The selection is
    /// left as it was. However it ends, the relationships are told the drag is over (`connectionReleased`): the
    /// arrow was bound and unbound at every hover and counted only now.
    private func finish(_ connecting: ArrowConnecting, in editor: CanvasEditor) {
        guard case .terminal(let end) = handle, let target = targeting.arrow(arrowID)?[end].binding?.shapeID else {
            editor.transact { $0.delete([arrowID]) }
            editor.connectionReleased(arrowID)
            return
        }
        editor.transact { $0.update(arrowID) { connecting.complete(&$0, target) } }
        if let finished = connecting.finished { finished(arrowID) } else { editor.connectionReleased(arrowID) }
    }

    /// Escape while drawing an arrow for a port's drag deletes it, leaving the selection
    /// as it was. Escape while re-aiming an existing end does nothing.
    func cancel(in editor: CanvasEditor) -> Bool {
        guard connecting != nil else { return false }
        targeting.cancelPreciseTimer()
        editor.transact { $0.delete([arrowID]) }
        editor.connectionReleased(arrowID)
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
            targeting.updateArrow(arrowID, named: "Bend Arrow") { $0.bend = (point - midpoint).dot(geometry.bendAxis) }

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

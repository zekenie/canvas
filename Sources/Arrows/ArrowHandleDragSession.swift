import Canvas
import CoreGraphics
import Geometry
import Selection
import Topology
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
    /// The loops already on the shape a port's drag starts from, read once, as its end first comes back onto it.
    private var loopsBeside: [ShapeID]?

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
        targeting.setProvisionalChannel(nil, for: arrowID)
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
    /// the press, so what it does is the press's step); free, it's deleted, so nothing is drawn. One bound back to the
    /// shape it starts from is the loop the drag showed (`loopBack`). The selection is left as it was. However it ends,
    /// the relationships are told the drag is over (`connectionReleased`): the arrow was bound and unbound at every hover
    /// and counted only now.
    private func finish(_ connecting: ArrowConnecting, in editor: CanvasEditor) {
        let bound = { () -> ArrowBinding? in
            guard case .terminal(let end) = self.handle else { return nil }
            return self.targeting.arrow(self.arrowID)?[end].binding
        }()
        // Let go on the row it started from, it joins nothing.
        let onItsOwnRow = connecting.start.part != nil && bound?.address == connecting.start.address
        guard let target = bound?.shapeID, !onItsOwnRow else {
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
        targeting.setProvisionalChannel(nil, for: arrowID)
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
            // of the ends; sideways motion does nothing. A level arrow's middle is the pointer's projection onto the line
            // across its chord through the middle of its curve unbent (`bendOrigin`).
            let geometry = targeting.geometry(of: arrow, id: arrowID)
            targeting.updateArrow(arrowID, named: "Bend Arrow") { $0.bend = (point - geometry.bendOrigin).dot(geometry.bendAxis) }

        case .terminal(let end):
            if modifiers.contains(.shift) {
                // A port's arrow pivots on the middle of the shape it starts from, looped back on it or not, so the loop
                // moving its start never moves where the pointer snaps to.
                let pivot = connecting.flatMap { targeting.connectables[$0.start.shapeID]?.bounds.center }
                    ?? targeting.geometry(of: arrow, id: arrowID).handlePoint(at: end.opposite)
                point = snapAngle(of: point, around: pivot, steps: 24)
            }
            let before = arrow[end].binding
            let reshape: ((inout Arrow) -> Void)? = connecting.map { connecting in {
                [self] in
                loopBack(&$0, connecting)
                // The channel it will be released on at the shape its end is on, so its look (a key's marks) is the one it will have.
                let shape = $0.end.binding.flatMap { targeting.editor.document[$0.shapeID] }
                targeting.setProvisionalChannel(shape.flatMap(connecting.channelAt), for: arrowID)
            } }
            targeting.bindTerminal(of: arrowID, end, to: point, isPrecise: isPrecise || modifiers.contains(.option), modifiers: modifiers,
                                   accepting: connecting?.canBind, bindsPart: connecting?.bindsPart, then: reshape)
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

    /// A port's arrow whose end is bound back to the shape it starts from is the loop it is let go as, on the side of the
    /// dot it was pulled from (`ArrowConnections.loop`), so the drag shows what a release makes; bound to any other shape, or
    /// free, it starts from the shape's middle, straight, as it began.
    private func loopBack(_ arrow: inout Arrow, _ connecting: ArrowConnecting) {
        let id = connecting.start.shapeID
        // From a row: back on its shape, the end is on a row of it (a key to a column of its own table), never a loop.
        guard connecting.start.part == nil, arrow.end.binding?.shapeID == id, let shape = targeting.connectables[id] else {
            arrow.start = .bound(connecting.start)
            arrow.bend = 0
            return
        }
        if loopsBeside == nil {
            loopsBeside = targeting.editor.topology.map { ArrowConnections.parallels(of: id, id, except: arrowID, in: $0) } ?? []
        }
        let loop = ArrowConnections.loop(on: shape, side: connecting.side, beside: loopsBeside ?? [], in: targeting.editor.document)
        arrow.start = .bound(loop.start)
        arrow.end = .bound(loop.end)
        arrow.bend = loop.bend
    }

    func startDragPreciseTimer() {
        targeting.startPreciseTimer(after: ArrowStyle.pressPreciseDelay) { [weak self] targeting in
            guard let self, targeting.editor.session === self, !isPrecise else { return }
            isPrecise = true
            update(to: targeting.editor.pointerWorldLocation, modifiers: targeting.editor.effectiveModifiers)
        }
    }
}

import AppKit
import Canvas
import Geometry
import Selection

@MainActor
enum PortStyle {
    // View points.
    /// From a side to its dot's center.
    static let offset: CGFloat = 12
    static let radius: CGFloat = 4
    /// Hovered or pressed.
    static let litRadius: CGFloat = 5
    /// How near a press or the pointer must be to a dot's center; also the radius of the halo a
    /// hovered or pressed one gets, as a handle's is.
    static let hitRadius: CGFloat = 12
    static let ringWidth: CGFloat = 1.5
    /// A dot at rest is its channel's color at this opacity, and at full opacity when it's hovered or
    /// pressed, as data-canvas's are.
    static let restingOpacity: CGFloat = 0.6
    static let haloOpacity: CGFloat = 0.24
    /// Below this zoom there are no ports, as the other chips shrink from here: a shape is too small
    /// on screen for its dots to be told from its neighbors'.
    static let minZoom: CGFloat = 0.25
    /// Around each dot, so it reads over any shape.
    static let ring = NSColor.white
    /// A dot whose channel no installed plugin declares (a kind can't have one; kept for safety).
    static let fallback = NSColor.systemGray
    /// While a connection is drawn from a port, the shapes it could end on are outlined faintly, as a
    /// hovered shape is (the one it would end on now gets the full outline, the hint).
    static let takerOutlineWidth: CGFloat = 2.5
    static let takerOutlineOpacity: CGFloat = 0.6
}

/// The dots of the shape whose ports show (`PortState.host`), in the select tool while the pointer's
/// on the canvas within reach of them and nothing is under way but a dot's press, where no shape
/// above theirs covers them; and,
/// while a connection is drawn from one, a faint outline on each shape in view it could end on.
/// Constant on screen; they go where the shape is drawn, so they shake with a locked shape.
struct PortOverlay: CanvasOverlay {
    var space: OverlaySpace { .world }

    func draw(in context: OverlayContext) {
        let editor = context.editor
        guard let state = editor.service(PortState.self), state.isShowing else { return }
        if let connection = state.activeConnection {
            outlineTakers(of: connection, state: state, in: context)
            return
        }
        // The pointer's where it is now (a press held after Escape, the camera moved under it), not
        // where the select tool last saw it move.
        let pressed = editor.pressedButton?.base as? PortDot
        guard let host = state.host, editor.session == nil || pressed != nil,
              pressed != nil || (editor.pointerOverCanvas != nil && state.isNear(host, editor.camera.toView(editor.pointerWorldLocation)))
        else { return }
        let hovered = editor.hoveredButton?.base as? PortDot
        let zoom = context.zoom
        let offset = context.worldDrawingOffset(of: host)
        let cg = context.cg
        // Only the dots in view are looked at, and drawn.
        let view = context.visibleRect.insetBy(dx: -PortStyle.hitRadius / zoom, dy: -PortStyle.hitRadius / zoom)
        let inView = Set(state.dots(of: host).filter { view.contains($0.center) }.map(\.dot.side))
        for (dot, center) in state.liveDots(of: host, on: inView) {
            let point = CGPoint(x: center.x + offset.x, y: center.y + offset.y)
            let isLit = dot == hovered || dot == pressed
            let color = state.color(of: dot)
            func circle(_ radius: CGFloat) -> CGRect {
                CGRect(x: point.x - radius / zoom, y: point.y - radius / zoom, width: radius * 2 / zoom, height: radius * 2 / zoom)
            }
            if isLit {
                cg.setFillColor(color.withAlphaComponent(PortStyle.haloOpacity).cgColor)
                cg.fillEllipse(in: circle(PortStyle.hitRadius))
            }
            let radius = isLit ? PortStyle.litRadius : PortStyle.radius
            cg.setFillColor(color.withAlphaComponent(isLit ? 1 : PortStyle.restingOpacity).cgColor)
            cg.fillEllipse(in: circle(radius))
            cg.setStrokeColor(PortStyle.ring.cgColor)
            cg.setLineWidth(PortStyle.ringWidth / zoom)
            cg.strokeEllipse(in: circle(radius))
        }
    }

    /// Each shape in view the connection could end on, but the one it would end on now (hinted),
    /// outlined as a hover is.
    private func outlineTakers(of connection: Connection, state: PortState, in context: OverlayContext) {
        let editor = context.editor
        guard let connector = state.connector else { return }
        // One path, stroked once, as the core strokes outlines: where two cross, no darker overlap.
        let outlines = CGMutablePath()
        for record in editor.paintOrder(in: context.visibleRect)
        where record.id != editor.hintedShapeID && state.kinds[record.kind] != nil
            && editor.channel(of: connection, endingAt: record) != nil && connector.canConnect(record.id, context.shapes) {
            guard let path = editor.outlinePath(of: record) else { continue }
            let offset = context.worldDrawingOffset(of: record.id)
            outlines.addPath(path, transform: CGAffineTransform(translationX: offset.x, y: offset.y))
        }
        let cg = context.cg
        cg.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(PortStyle.takerOutlineOpacity).cgColor)
        cg.setLineWidth(PortStyle.takerOutlineWidth / context.zoom)
        cg.setLineJoin(.round)
        cg.addPath(outlines)
        cg.strokePath()
    }
}

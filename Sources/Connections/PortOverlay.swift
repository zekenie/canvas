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
    /// How near (world units) a connection's end must be to a row's end for that side to count as taken: its resting dot isn't drawn.
    static let endSlack: CGFloat = 1.5
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
    /// The row whose dots show, and the row a drag from one of them starts at (T3's payment_id): a band in the accent,
    /// this faint, its rect this far inside and rounded this much, as the row a connection would end on is lit (without
    /// that one's stroke).
    static let rowBandOpacity: CGFloat = 0.16
    static let rowBandInset: CGFloat = 2
    static let rowBandRadius: CGFloat = 5
}

/// The dots of the shape whose ports show (`PortState.host`), in the select tool while the pointer's
/// on the canvas within reach of them and nothing is under way but a dot's press, where no shape
/// above theirs covers them, with a faint band on the row whose dots they are (`partPorts`); and,
/// while a connection is drawn from one, a faint outline on each shape in view it could end on, and
/// the band on the row it starts at.
/// Constant on screen; they go where the shape is drawn, so they shake with a locked shape.
struct PortOverlay: CanvasOverlay {
    var space: OverlaySpace { .world }

    func draw(in context: OverlayContext) {
        let editor = context.editor
        guard let state = editor.service(PortState.self), state.isShowing else { return }
        if let connection = state.activeConnection {
            outlineTakers(of: connection, state: state, in: context)
            if let part = connection.part { band(part, of: connection.shape, in: context) }
            return
        }
        // The pointer's where it is now (a press held after Escape, the camera moved under it), not
        // where the select tool last saw it move.
        let pressed = editor.pressedButton?.base as? PortDot
        guard let host = state.host, editor.session == nil || pressed != nil,
              pressed != nil || (editor.pointerOverCanvas != nil && state.isNear(host, editor.camera.toView(editor.pointerWorldLocation)))
        else { return }
        if let part = state.hostPart { band(part, of: host, in: context) }
        let hovered = editor.hoveredButton?.base as? PortDot
        let zoom = context.zoom
        let offset = context.worldDrawingOffset(of: host)
        let cg = context.cg
        // Only the dots in view are looked at, and drawn.
        let view = context.visibleRect.insetBy(dx: -PortStyle.hitRadius / zoom, dy: -PortStyle.hitRadius / zoom)
        let inView = Set(state.dots(of: host, part: state.hostPart).filter { view.contains($0.center) }.map(\.dot))
        for placed in state.liveDots(of: host, part: state.hostPart, on: inView) {
            let dot = placed.dot, center = placed.center
            let point = CGPoint(x: center.x + offset.x, y: center.y + offset.y)
            let isLit = dot == hovered || dot == pressed
            // A row's dot at rest isn't drawn on a side where a connection ends at that row already (a key, whose mark is drawn
            // there): it would sit on the mark and read as one. Hovered or pressed, it shows, for a drag of another.
            if !isLit, let part = dot.part, Self.isTaken(placed, of: PartAddress(host, part: part), in: editor) { continue }
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

    /// Whether a connection bound to `row` ends on the side `placed` stands out from (its row's end on that side): one of the
    /// shapes painted there (arrows at rows paint beneath the cards they join, so the search is of that side's stretch of the
    /// row) bound to the row, its outline starting or ending on that stretch, anywhere along the row's height, so an end a fan or
    /// a slot moved along the side counts as one at its middle (review R21).
    static func isTaken(_ placed: PlacedDot, of row: PartAddress, in editor: CanvasEditor) -> Bool {
        let registry = editor.registry, shapes = editor.shapeContext, edge = placed.edge, slack = PortStyle.endSlack
        let band = row.part.flatMap { shapes.geometry(of: row.shape)?.parts.frame($0)?.rect }
        let (low, high) = band.map { (min($0.minY, edge.y), max($0.maxY, edge.y)) } ?? (edge.y, edge.y)
        let spot = CGRect(x: edge.x - slack, y: low - slack, width: slack * 2, height: high - low + slack * 2)
        func on(_ point: CGPoint) -> Bool { abs(point.x - edge.x) <= slack && point.y >= low - slack && point.y <= high + slack }
        return editor.paintOrder(in: spot).contains { record in
            guard record.id != row.shape, registry.connectionEnds(of: record) != nil, record.boundParts(in: registry).contains(row),
                  let outline = shapes.geometry(of: record.id)?.outline, let first = outline.first, let last = outline.last else { return false }
            return on(first) || on(last)
        }
    }

    /// The band on `part` of `id` (the row whose dots show, or the row a drag started at), where its kept geometry has it and
    /// it shows; nothing for a row out of view.
    private func band(_ part: PartID, of id: ShapeID, in context: OverlayContext) {
        guard let frame = context.shapes.geometry(of: id)?.parts.frame(part), frame.isShown,
              frame.rect.intersects(context.visibleRect) else { return }
        let zoom = context.zoom, offset = context.worldDrawingOffset(of: id), inset = PortStyle.rowBandInset / zoom
        let rect = frame.rect.offsetBy(dx: offset.x, dy: offset.y).insetBy(dx: inset, dy: inset)
        guard rect.width > 0, rect.height > 0 else { return }
        let radius = min(PortStyle.rowBandRadius / zoom, rect.width / 2, rect.height / 2)
        let cg = context.cg
        cg.setFillColor(NSColor.controlAccentColor.withAlphaComponent(PortStyle.rowBandOpacity).cgColor)
        cg.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        cg.fillPath()
    }

    /// Each shape in view the connection could end on, but the one it would end on now (hinted),
    /// outlined as a hover is.
    private func outlineTakers(of connection: Connection, state: PortState, in context: OverlayContext) {
        let editor = context.editor
        guard let connector = state.connector else { return }
        // One path, stroked once, as the core strokes outlines: where two cross, no darker overlap.
        let outlines = CGMutablePath()
        for record in editor.paintOrder(in: context.visibleRect)
        where record.id != editor.hintedShapeID && state.ports(of: record) != nil
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

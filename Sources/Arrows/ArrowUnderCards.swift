import AppKit
import Canvas
import Colors
import Geometry

/// An arrow with an end at a row is painted beneath the cards (`paintsBelowAnchor`), so a card it passes between its ends covers
/// it: drawn whole, the line would strike through the card's words (UX walk 2 structure 35 to 37), and hidden, its ends left
/// showing read as a key that ends at whatever row it disappears beside (UX walk 3 structure-1, paste-1: "customers.id → orders.id",
/// a key there is not). So the stretch a card covers is drawn again over it, faint, as a line that passes through: the card's
/// words read over it, and the line can be followed. Only the stretches under closed shapes painted above it that it isn't bound
/// to, at its own width and in its own color; its marks and heads are at its ends, outside the cards. Asked of the arrows in
/// view alone, each against the shapes painted above it there (the index's search, a few however large the board).
///
/// A departure of the kit's level curves from tldraw (whose arrows paint on top, checked at v5.0.1); a plain arrow is above its
/// shapes and is never drawn here, so the parity goldens never see it. Rejected: routing the middle through the gap between
/// cards, which would make an arrow's geometry read every shape between its ends, laid out again whenever any of them moved.
struct ArrowUnderCardsOverlay: CanvasOverlay {
    var space: OverlaySpace { .world }

    func draw(in overlay: OverlayContext) {
        let editor = overlay.editor, shapes = overlay.shapes, cg = overlay.cg
        let arrowKind = Arrow.kind
        let inView = editor.paintOrder(in: overlay.visibleRect)
        guard inView.contains(where: { $0.kind == arrowKind }) else { return }
        for record in inView where record.kind == arrowKind {
            guard let arrow = record.typed(as: Arrow.self), arrow.props.start.binding?.part != nil || arrow.props.end.binding?.part != nil,
                  let geometry = shapes.geometry(of: record.id), !geometry.isHidden, let drawing = geometry.arrowDetail?.drawing else { continue }
            // The closed shapes painted above it that its line's bounds meet, but the ones it's bound to: what covers it.
            let ends = Set([arrow.props.start.binding?.shapeID, arrow.props.end.binding?.shapeID].compactMap { $0 })
            let bounds = drawing.whole.boundingBoxOfPath
            let covers = CGMutablePath()
            var above = false
            for card in editor.paintOrder(in: bounds) {
                if card.id == record.id { above = true; continue }
                guard above, !ends.contains(card.id), card.kind != arrowKind,
                      let shape = shapes.geometry(of: card.id), shape.isClosed, !shape.isHidden, shape.outline.count > 2,
                      shape.bounds.intersects(bounds) else { continue }
                let offset = overlay.worldDrawingOffset(of: card.id)
                covers.addLines(between: shape.outline, transform: CGAffineTransform(translationX: offset.x, y: offset.y))
                covers.closeSubpath()
            }
            guard !covers.isEmpty else { continue }
            let skeleton = overlay.drawsSkeleton(of: record.id)
            let width = skeleton ? max(geometry.arrowDetail?.width ?? ArrowStyle.strokeWidth, ArrowStyle.skeletonLineWidth / overlay.zoom)
                                 : geometry.arrowDetail?.width ?? ArrowStyle.strokeWidth
            let body = skeleton ? ArrowDefinition.skeletonBody(of: drawing, atZoom: overlay.zoom) : drawing.body
            let offset = overlay.worldDrawingOffset(of: record.id)
            cg.saveGState()
            cg.addPath(covers)
            cg.clip()
            // Its label's cut, as the render leaves it.
            if !skeleton, let label = geometry.label {
                cg.addRect(bounds.union(label).insetBy(dx: -width * 4, dy: -width * 4))
                cg.addPath(ArrowLabels.cut(label))
                cg.clip(using: .evenOdd)
            }
            cg.translateBy(x: offset.x, y: offset.y)
            cg.setAlpha(ArrowStyle.underCardOpacity)
            cg.addPath(body)
            cg.setStrokeColor(editor.service(ColorBook.self)?.colors(of: arrow)?.solid ?? ArrowStyle.color.cgColor)
            cg.setLineWidth(width)
            cg.setLineCap(.butt)
            cg.setLineJoin(.round)
            cg.strokePath()
            cg.restoreGState()
        }
    }
}

extension ArrowStyle {
    /// How strongly the stretch of a key a card covers is drawn over the card: a line that passes through, under its words.
    static let underCardOpacity: CGFloat = 0.28
}

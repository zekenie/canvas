import AppKit
import Canvas
import Colors
import Geometry

/// An arrow with an end at a row is painted beneath the cards (`paintsBelowAnchor`), so a card it passes between its ends covers
/// it: drawn whole, the line would strike through the card's words (UX walk 2 structure 35 to 37), and hidden, its ends left
/// showing read as a key that ends at whatever row it disappears beside (UX walk 3 structure-1, paste-1: "customers.id → orders.id",
/// a key there is not). So the stretch a card covers is drawn again over it, faint, as a line that passes through. Over a card
/// written as rows it is left out of each row's two ends, where its name and its type are written, so the line shows in the
/// middle of the row and in the gaps and never through a word (review U9-E3); over another card the whole stretch shows. Only the
/// stretches under closed shapes painted above it that it isn't bound to, at its own width and in its own color; its marks and
/// heads are at its ends, outside the cards. Asked of the keys in view alone (`shapesPaintedBelowAnchor`: none, at no cost, on a
/// board with none), each against the shapes painted above it in its bounds (the index's search).
///
/// A departure of the kit's level curves from tldraw (whose arrows paint on top, checked at v5.0.1); a plain arrow is above its
/// shapes and is never drawn here, so the parity goldens never see it. Rejected: routing the middle through the gap between
/// cards, which would make an arrow's geometry read every shape between its ends, laid out again whenever any of them moved.
struct ArrowUnderCardsOverlay: CanvasOverlay {
    var space: OverlaySpace { .world }

    func draw(in overlay: OverlayContext) {
        let editor = overlay.editor, shapes = overlay.shapes, cg = overlay.cg
        let arrowKind = Arrow.kind
        for record in editor.shapesPaintedBelowAnchor(in: overlay.visibleRect) where record.kind == arrowKind {
            guard let arrow = record.typed(as: Arrow.self), arrow.props.start.binding?.part != nil || arrow.props.end.binding?.part != nil,
                  let geometry = shapes.geometry(of: record.id), !geometry.isHidden, let drawing = geometry.arrowDetail?.drawing else { continue }
            // The closed shapes painted above it that its line's bounds meet, but the ones it's bound to: what covers it.
            let ends = Set([arrow.props.start.binding?.shapeID, arrow.props.end.binding?.shapeID].compactMap { $0 })
            let bounds = drawing.whole.boundingBoxOfPath
            let covers = CGMutablePath(), words = CGMutablePath()
            var above = false
            for card in editor.paintOrder(in: bounds) {
                if card.id == record.id { above = true; continue }
                guard above, !ends.contains(card.id), card.kind != arrowKind,
                      let shape = shapes.geometry(of: card.id), shape.isClosed, !shape.isHidden, shape.outline.count > 2,
                      shape.bounds.intersects(bounds) else { continue }
                let offset = overlay.worldDrawingOffset(of: card.id)
                let move = CGAffineTransform(translationX: offset.x, y: offset.y)
                covers.addLines(between: shape.outline, transform: move)
                covers.closeSubpath()
                // Where its rows' words are written: each row's two ends, the stretch between them left to the line.
                for part in shape.parts.shownFrames where part.rect.intersects(bounds) {
                    let rect = part.rect, left = rect.width * ArrowStyle.underCardWordsLeft, right = rect.width * ArrowStyle.underCardWordsRight
                    words.addRect(CGRect(x: rect.minX, y: rect.minY, width: left, height: rect.height).applying(move))
                    words.addRect(CGRect(x: rect.maxX - right, y: rect.minY, width: right, height: rect.height).applying(move))
                }
            }
            guard !covers.isEmpty else { continue }
            let skeleton = overlay.drawsSkeleton(of: record.id)
            let width = skeleton ? max(geometry.arrowDetail?.width ?? ArrowStyle.strokeWidth, ArrowStyle.skeletonLineWidth / overlay.zoom)
                                 : geometry.arrowDetail?.width ?? ArrowStyle.strokeWidth
            let body = skeleton ? ArrowDefinition.skeletonBody(of: drawing, atZoom: overlay.zoom) : drawing.body
            let offset = overlay.worldDrawingOffset(of: record.id)
            cg.saveGState()
            // What covers it and what is written, in the world, where those shapes are drawn.
            cg.addPath(covers)
            cg.clip()
            if !words.isEmpty {
                cg.addRect(bounds.insetBy(dx: -width * 4 - abs(offset.x), dy: -width * 4 - abs(offset.y)).union(covers.boundingBoxOfPath))
                cg.addPath(words)
                cg.clip(using: .evenOdd)
            }
            // Then the line as it is drawn, moved by its own offset (while it glides or shakes), and its label's cut as the render
            // leaves it, in the same space (review U9-C7).
            cg.translateBy(x: offset.x, y: offset.y)
            if !skeleton, let label = geometry.label {
                cg.addRect(bounds.union(label).insetBy(dx: -width * 4, dy: -width * 4))
                cg.addPath(ArrowLabels.cut(label))
                cg.clip(using: .evenOdd)
            }
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
    /// The shares of a row, from its left and from its right, where its words are written (a name and a type): the stretch drawn
    /// over a card written as rows is left out of them.
    static let underCardWordsLeft: CGFloat = 0.4
    static let underCardWordsRight: CGFloat = 0.4
}

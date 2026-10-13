import AppKit
import Canvas
import Colors

/// On the main actor as a whole, so its drawing helpers share the protocol's isolation.
@MainActor
struct SubboardDefinition {}

/// A card, the whole frame, so its outline is its edge: a body that shows what its board holds, its
/// preview, the core's rough picture of it, fitted; until that's ready, how many shapes ("12
/// shapes"); and with nothing to show, the kind's symbol over "Empty"; in an indigo border. Its title is
/// Titles' pill above it, after the symbol, as every titled shape's is. Everything is clipped to
/// the card.
extension SubboardDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Subboard>, in context: RenderContext) {
        let card = shape.frame, cg = context.cg, path = SubboardStyle.path(card)
        let colors = context.colors(of: shape)
        context.fillWithShadow(path, colors.map { NSColor(cgColor: $0.surface) ?? SubboardStyle.cardFill } ?? SubboardStyle.cardFill)
        cg.saveGState()
        cg.addPath(path)
        cg.clip()
        if !context.drawBoardPreview(ofBoardOwnedBy: shape.id, in: SubboardStyle.preview(in: card), maxScale: SubboardStyle.previewMaxScale) {
            drawCaption(context.shapeCount(inBoardOwnedBy: shape.id), in: card, solid: colors?.solid)
        }
        cg.restoreGState()
        stroke(card, colors?.solid ?? SubboardStyle.border.cgColor, width: SubboardStyle.borderWidth, cg: cg)
    }

    func indicatorPath(of shape: ShapeRecord<Subboard>, in context: ShapeContext) -> CGPath {
        SubboardStyle.path(shape.frame)
    }

    /// "1 shape", "12 shapes" in the middle of the card, while its preview is built; for an empty
    /// board, the symbol over "Empty", the caption alone where there's no room for both; nothing
    /// where there's none for a line. The symbol isn't drawn for a count, so a card that's about
    /// to show its preview doesn't flash it.
    private func drawCaption(_ count: Int, in card: CGRect, solid: CGColor?) {
        let height = SubboardStyle.captionLineHeight
        guard card.height >= height, card.width > SubboardStyle.padding * 2 else { return }
        var top = card.midY - height / 2
        if count == 0, let glyph = SubboardStyle.glyph(in: solid) {
            let size = glyph.size, total = size.height + SubboardStyle.captionSpacing + height
            if total <= card.height - SubboardStyle.padding * 2, size.width <= card.width - SubboardStyle.padding * 2 {
                let y = card.midY - total / 2
                glyph.draw(in: CGRect(x: card.midX - size.width / 2, y: y, width: size.width, height: size.height),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                top = y + size.height + SubboardStyle.captionSpacing
            }
        }
        let text = NSAttributedString(string: SubboardStyle.caption(of: count), attributes: SubboardStyle.caption)
        text.draw(with: CGRect(x: card.minX + SubboardStyle.padding, y: top, width: card.width - SubboardStyle.padding * 2, height: height),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// A line just inside `rect`'s rounded edge, so nothing is drawn outside the frame.
    private func stroke(_ rect: CGRect, _ color: CGColor, width: CGFloat, cg: CGContext) {
        let inset = rect.insetBy(dx: width / 2, dy: width / 2)
        guard inset.width > 0, inset.height > 0 else { return }
        cg.addPath(SubboardStyle.path(inset, radius: SubboardStyle.cornerRadius - width / 2))
        cg.setStrokeColor(color)
        cg.setLineWidth(width)
        cg.strokePath()
    }
}

extension SubboardDefinition: BoardOwning {}

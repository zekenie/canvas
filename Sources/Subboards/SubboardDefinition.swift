import AppKit
import Canvas
import Titles

/// On the main actor as a whole, so its drawing helpers share the protocol's isolation.
@MainActor
struct SubboardDefinition {}

/// A card on a stack of two thin plates, all inside the frame, so the shape's extent is its box: a
/// header band with the symbol and the title ("Untitled Subboard", dimmed, while it has none), over
/// a body that shows what the board holds: its preview, the core's rough picture of it, fitted; until
/// that's ready, or with nothing to show, how many shapes ("Empty", "12 shapes"). Everything is
/// clipped to the card.
extension SubboardDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Subboard>, in context: RenderContext) {
        let frame = shape.frame, cg = context.cg
        for plate in SubboardStyle.plates(of: frame) {
            cg.addPath(SubboardStyle.path(plate))
            cg.setFillColor(SubboardStyle.plate.cgColor)
            cg.fillPath()
            stroke(plate, SubboardStyle.plateBorder, width: SubboardStyle.plateBorderWidth, cg: cg)
        }
        let card = SubboardStyle.card(of: frame), path = SubboardStyle.path(card)
        context.fillWithShadow(path, SubboardStyle.cardFill)
        cg.saveGState()
        cg.addPath(path)
        cg.clip()
        let header = SubboardStyle.header(of: card)
        cg.setFillColor(SubboardStyle.headerFill.cgColor)
        cg.fill(header)
        cg.setFillColor(SubboardStyle.border.withAlphaComponent(SubboardStyle.ruleAlpha).cgColor)
        cg.fill(CGRect(x: header.minX, y: header.maxY - SubboardStyle.ruleWidth, width: header.width, height: SubboardStyle.ruleWidth))
        drawHeader(title: context.shapes.registry.title(of: AnyShapeRecord(shape)), in: header)
        let body = SubboardStyle.body(of: card, below: header)
        if !context.drawBoardPreview(ofBoardOwnedBy: shape.id, in: SubboardStyle.preview(in: body), maxScale: SubboardStyle.previewMaxScale) {
            drawCaption(context.shapeCount(inBoardOwnedBy: shape.id), in: body)
        }
        cg.restoreGState()
        stroke(card, SubboardStyle.border, width: SubboardStyle.borderWidth, cg: cg)
    }

    func indicatorPath(of shape: ShapeRecord<Subboard>, in context: ShapeContext) -> CGPath {
        SubboardStyle.path(shape.frame)
    }

    /// The symbol, then the title on one line, truncated, both centered in the band's height.
    private func drawHeader(title: String?, in header: CGRect) {
        var x = header.minX + SubboardStyle.padding
        if let glyph = SubboardStyle.glyph {
            let size = glyph.size
            glyph.draw(in: CGRect(x: x, y: header.midY - size.height / 2, width: size.width, height: size.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += size.width + SubboardStyle.spacing
        }
        let text = NSAttributedString(string: title ?? Subboard.placeholder,
                                      attributes: title == nil ? SubboardStyle.placeholderTitle : SubboardStyle.title)
        let width = header.maxX - SubboardStyle.padding - x
        guard width > 0 else { return }
        let height = SubboardStyle.titleLineHeight
        text.draw(with: CGRect(x: x, y: header.midY - height / 2, width: width, height: height),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// "Empty", "1 shape", "12 shapes", in the middle of the body, if there's room for a line.
    private func drawCaption(_ count: Int, in body: CGRect) {
        let height = SubboardStyle.captionLineHeight
        guard body.height >= height, body.width > SubboardStyle.padding * 2 else { return }
        let text = NSAttributedString(string: SubboardStyle.caption(of: count), attributes: SubboardStyle.caption)
        text.draw(with: CGRect(x: body.minX + SubboardStyle.padding, y: body.midY - height / 2,
                               width: body.width - SubboardStyle.padding * 2, height: height),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// A line just inside `rect`'s rounded edge, so nothing is drawn outside the frame.
    private func stroke(_ rect: CGRect, _ color: NSColor, width: CGFloat, cg: CGContext) {
        let inset = rect.insetBy(dx: width / 2, dy: width / 2)
        guard inset.width > 0, inset.height > 0 else { return }
        cg.addPath(SubboardStyle.path(inset, radius: SubboardStyle.cornerRadius - width / 2))
        cg.setStrokeColor(color.cgColor)
        cg.setLineWidth(width)
        cg.strokePath()
    }
}

extension SubboardDefinition: BoardOwning {}

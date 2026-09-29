import AppKit
import Canvas
import Titles

/// A card zoomed out (`CustomSkeleton`): fills alone, square (its 10-point corners are 3.5 points
/// on screen at most here, and its outline is its frame's, as the core draws it), with no shadow,
/// symbol or text. The plates below it in what they show from afar; the card in its border's
/// indigo, under its header band and its white body; a bar where its title is (the placeholder's,
/// dimmed, as its text is); and its board's preview, the one picture it draws, as the card asks
/// for it: drawn once it's built and while it's big enough on screen, else nothing, never the
/// count. Five fills and the preview.
extension SubboardDefinition: CustomSkeleton {
    func renderSkeleton(_ shape: ShapeRecord<Subboard>, in context: RenderContext) {
        let frame = shape.frame, cg = context.cg
        let card = SubboardStyle.card(of: frame)
        if SubboardStyle.hasPlates(frame) {
            cg.addRect(SubboardStyle.plate(2, behind: card))
            cg.addRect(SubboardStyle.plate(1, behind: card))
            cg.setFillColor(SubboardStyle.skeletonPlate)
            cg.fillPath()
        }
        cg.setFillColor(SubboardStyle.skeletonBorder)
        cg.fill(card)
        let border = max(SubboardStyle.borderWidth, SubboardStyle.skeletonBorderWidth / context.zoom)
        let inside = card.insetBy(dx: border, dy: border)
        guard !inside.isEmpty else { return }
        let header = SubboardStyle.header(of: card), band = header.intersection(inside)
        if !band.isEmpty {
            cg.setFillColor(SubboardStyle.skeletonHeader)
            cg.fill(band)
        }
        let top = max(inside.minY, header.maxY)
        if inside.maxY > top {
            cg.setFillColor(SubboardStyle.skeletonCard)
            cg.fill(CGRect(x: inside.minX, y: top, width: inside.width, height: inside.maxY - top))
        }
        _ = context.drawBoardPreview(ofBoardOwnedBy: shape.id, in: SubboardStyle.preview(in: SubboardStyle.body(of: card, below: header)),
                                     maxScale: SubboardStyle.previewMaxScale)
        drawTitleBar(shape[TitleProperty.self], in: band, header: header, context: context)
    }

    /// Where the title is, after the symbol's place, as long as its columns (`SkeletonText`: a CJK
    /// character or an emoji two), no longer than the header leaves it.
    private func drawTitleBar(_ title: String?, in band: CGRect, header: CGRect, context: RenderContext) {
        let x = header.minX + SubboardStyle.titleInset, room = header.maxX - SubboardStyle.padding - x
        guard room > 0 else { return }
        let columns = SkeletonText.columns(of: title ?? Subboard.placeholder)
        let bar = CGRect(x: x, y: header.midY + SubboardStyle.skeletonTitleTop,
                         width: min(room, CGFloat(columns) * SubboardStyle.skeletonTitleAdvance),
                         height: SubboardStyle.skeletonTitleHeight).intersection(band)
        guard !bar.isEmpty else { return }
        context.cg.saveGState()
        if title == nil { context.cg.setAlpha(SubboardStyle.skeletonPlaceholderAlpha) }
        context.fillSkeletonText(CollectionOfOne(bar))
        context.cg.restoreGState()
    }
}

extension SubboardStyle {
    /// A plate as it shows from afar, below the card: its fill, with its border's indigo taking a
    /// quarter of it, as its edge takes one of the four units that show.
    static let skeletonPlate = NSColor(srgbRed: 0.90, green: 0.90, blue: 0.955, alpha: 1).cgColor
    static let skeletonBorder = border.cgColor
    static let skeletonHeader = headerFill.cgColor
    static let skeletonCard = cardFill.cgColor
    /// The border is never thinner than this on screen, in view points: a device pixel on a
    /// Retina screen, so it still shows far out. Just under 35% the card's own 1.5 is about that,
    /// so nothing jumps there.
    static let skeletonBorderWidth: CGFloat = 0.5
    /// Where the title starts in the header: past the padding, the symbol and the gap after it.
    static let titleInset = padding + (glyph.map { $0.size.width + spacing } ?? 0)
    /// The title's bar: where string drawing inks a lowercase x of the title's font in the header,
    /// 2.75 points above its middle to 5.75 below; and a column's share of its width, 0.52 em, as
    /// a dozen titles measure in it (15 points, semibold), so a character set a full em wide, two
    /// columns, counts 1.04.
    static let skeletonTitleTop: CGFloat = -2.75
    static let skeletonTitleHeight: CGFloat = 8.5
    static let skeletonTitleAdvance: CGFloat = 0.52 * 15
    /// The placeholder's bar is dimmed, as its text is.
    static let skeletonPlaceholderAlpha: CGFloat = 0.5
}

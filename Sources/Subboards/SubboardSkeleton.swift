import AppKit
import Canvas

/// A card zoomed out (`CustomSkeleton`): fills alone, square (its 10-point corners are 3.5 points
/// on screen at most here, and its outline is its frame's, as the core draws it), with no shadow,
/// symbol or count: its border's indigo, the card inside it, and its board's preview, the one
/// picture it draws, as the card asks for it: drawn once it's built and while it's big enough on
/// screen, else nothing. Two fills and the preview; its title is Titles' cover, drawn over it.
extension SubboardDefinition: CustomSkeleton {
    func renderSkeleton(_ shape: ShapeRecord<Subboard>, in context: RenderContext) {
        let card = shape.frame, cg = context.cg
        cg.setFillColor(SubboardStyle.border.cgColor)
        cg.fill(card)
        let border = max(SubboardStyle.borderWidth, SubboardStyle.skeletonBorderWidth / context.zoom)
        let inside = card.insetBy(dx: border, dy: border)
        guard !inside.isEmpty else { return }
        cg.setFillColor(SubboardStyle.cardFill.cgColor)
        cg.fill(inside)
        _ = context.drawBoardPreview(ofBoardOwnedBy: shape.id, in: SubboardStyle.preview(in: card), maxScale: SubboardStyle.previewMaxScale)
    }
}

extension SubboardStyle {
    /// The border is never thinner than this on screen, in view points: a device pixel on a
    /// Retina screen, so it still shows far out. Just under 35% the card's own 1.5 is about that,
    /// so nothing jumps there.
    static let skeletonBorderWidth: CGFloat = 0.5
}

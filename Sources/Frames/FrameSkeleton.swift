import AppKit
import Canvas

/// A frame zoomed out (`CustomSkeleton`): two fills, square (its corners are under 4 points on
/// screen here, and its outline is its frame's, as the core draws it): its surface, and over it its
/// border, a ring just inside its edge as wide on screen as in full (`FrameStyle.borderWidth`), so
/// both are the colors they are in full; a frame too small on screen for a ring is its border's
/// color over its surface. Its title is Titles' cover (there's no pill zoomed out), drawn over it
/// and over the skeletons of what it holds.
extension FrameDefinition: CustomSkeleton {
    func renderSkeleton(_ shape: ShapeRecord<Frame>, in context: RenderContext) {
        let box = shape.frame, cg = context.cg, width = FrameStyle.borderWidth / context.zoom
        cg.setFillColor(FrameStyle.fill.cgColor)
        cg.fill(box)
        let inside = box.insetBy(dx: width, dy: width)
        if !inside.isEmpty { cg.addRect(inside) }
        cg.addRect(box)
        cg.setFillColor(FrameStyle.border.cgColor)
        cg.fillPath(using: .evenOdd)
    }
}

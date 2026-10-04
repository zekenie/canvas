import AppKit
import Canvas
import Mentions

/// The card zoomed out, where its text no longer reads (`CustomSkeleton`, below the editor's
/// `skeletonZoom`): the card, white, with no shadow but a light gray edge inside its frame, where
/// the shadow's edge showed (`SchemaStyle.skeletonEdge`), so a white card on the light canvas still
/// has one; and its description greeked as a note's text is (`SkeletonTextBars`, counted from its
/// characters, never laid out, each mention as wide as its pill by the name it holds). Its name is
/// Titles' cover, drawn over it.
/// Three fills, whatever it says: the edge, the card inside it, and every bar in one
/// (`RenderContext.fillSkeletonText`). Square (its corners are rounded by under 2 points here, and a
/// rounded card costs a third more), so its outline is the default, its frame's, exactly.
extension SchemaCardDefinition: CustomSkeleton {
    func renderSkeleton(_ shape: ShapeRecord<SchemaCard>, in context: RenderContext) {
        let cg = context.cg, frame = shape.frame
        cg.setFillColor(SchemaStyle.skeletonEdgeColor)
        cg.fill(frame)
        let edge = SchemaStyle.skeletonEdgeWidth / context.zoom
        let inside = frame.insetBy(dx: edge, dy: edge)
        guard !inside.isEmpty else { return }
        cg.setFillColor(SchemaStyle.skeletonCard)
        cg.fill(inside)
        context.fillSkeletonText(SkeletonTextBars(shape.props.prompt.runs, in: SchemaStyle.textBox(of: frame), metrics: SchemaStyle.skeletonText))
    }
}

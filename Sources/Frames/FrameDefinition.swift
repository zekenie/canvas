import Canvas
import CoreGraphics
import Selection

/// On the main actor as a whole, so its drawing helpers share the protocol's isolation.
@MainActor
struct FrameDefinition {}

/// The region is the whole frame, rounded, so its outline (the selection's, a hover's, the hint a drag
/// into it shows) is its edge: its surface, and its border just inside its edge. What it holds paints
/// above it; its title is Titles' pill above it.
extension FrameDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Frame>, in context: RenderContext) {
        FrameStyle.draw(shape.frame, zoom: context.zoom, in: context.cg)
    }

    func indicatorPath(of shape: ShapeRecord<Frame>, in context: ShapeContext) -> CGPath {
        FrameStyle.path(shape.frame)
    }

    /// Hollow: a frame that holds shapes is pressed, and hovered, only on its border, a few view
    /// points either side of its edge (`FrameStyle.borderReach`), and its inside is the canvas, where
    /// a drag is a marquee; one that holds nothing is pressed anywhere inside too. Its title's pill
    /// grabs it as well (Titles', through Selection's `DecorationHits`).
    func hitTest(_ point: CGPoint, on shape: ShapeRecord<Frame>, in context: ShapeContext) -> Bool {
        let box = shape.frame, reach = FrameStyle.borderReach / context.zoom
        guard box.insetBy(dx: -reach, dy: -reach).contains(point) else { return false }
        guard context.hasContents(shape.id) else { return true }
        let inside = box.insetBy(dx: reach, dy: reach)
        return inside.isEmpty || !inside.contains(point)
    }

    /// Its border is pressed this far outside its edge.
    var hitMargin: HitMargin { HitMargin(view: FrameStyle.borderReach) }
}

/// Each frame holds the shapes on its board that name it: the core moves them with it, paints them
/// above it, holds them read-only while it's locked, and keeps what's put down from sitting across
/// its edge.
extension FrameDefinition: ShapeContaining {}

/// The marquee selects a frame when it reaches its edge, or holds it whole (which it decides before
/// asking), never when it's drawn wholly inside it: there it selects what the frame holds.
extension FrameDefinition: BrushHitTesting {
    func brushHitTest(_ brush: CGRect, on shape: ShapeRecord<Frame>, in context: ShapeContext) -> Bool {
        let box = shape.frame
        return !(brush.minX > box.minX && brush.maxX < box.maxX && brush.minY > box.minY && brush.maxY < box.maxY)
    }
}

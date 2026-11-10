import AppKit
import Canvas
import Geometry
import Selection

/// A database: a region of its board that holds tables and enums, as a frame does (the core's containment: what's in it
/// moves with it, paints above it, takes its lock, and nothing sits across its edge). A surface a step up from the canvas
/// in a hairline border, no shadow; its name in a tab on its top edge, after a cylinder. Pressed hollow, as a frame is:
/// holding shapes, only its border and its tab grab it.
@MainActor
struct DatabaseDefinition {}

extension DatabaseDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Database>, in context: RenderContext) {
        let cg = context.cg, rect = shape.frame
        cg.saveGState()
        cg.addPath(DatabaseStyle.path(rect))
        cg.setFillColor(DatabaseStyle.fill.cgColor)
        cg.fillPath()
        let width = DatabaseStyle.borderWidth / context.zoom, inset = rect.insetBy(dx: width / 2, dy: width / 2)
        if inset.width > 0, inset.height > 0 {
            cg.addPath(DatabaseStyle.path(inset, radius: DatabaseStyle.cornerRadius - width / 2))
            cg.setStrokeColor(DatabaseStyle.border.cgColor)
            cg.setLineWidth(width)
            cg.strokePath()
        }
        cg.restoreGState()
    }

    func indicatorPath(of shape: ShapeRecord<Database>, in context: ShapeContext) -> CGPath {
        DatabaseStyle.path(shape.frame)
    }

    /// Hollow: holding shapes, pressed only on its border, a few view points either side of its edge; holding nothing,
    /// anywhere inside too.
    func hitTest(_ point: CGPoint, on shape: ShapeRecord<Database>, in context: ShapeContext) -> Bool {
        let box = shape.frame, reach = DatabaseStyle.borderReach / context.zoom
        guard box.insetBy(dx: -reach, dy: -reach).contains(point) else { return false }
        guard context.hasContents(shape.id) else { return true }
        let inside = box.insetBy(dx: reach, dy: reach)
        return inside.isEmpty || !inside.contains(point)
    }

    var hitMargin: HitMargin { HitMargin(view: DatabaseStyle.borderReach) }
}

extension DatabaseDefinition: ShapeContaining {}

/// The marquee selects it when it reaches its edge or holds it whole, never drawn wholly inside it.
extension DatabaseDefinition: BrushHitTesting {
    func brushHitTest(_ brush: CGRect, on shape: ShapeRecord<Database>, in context: ShapeContext) -> Bool {
        let box = shape.frame
        return !(brush.minX > box.minX && brush.maxX < box.maxX && brush.minY > box.minY && brush.maxY < box.maxY)
    }
}

/// Zoomed out: its surface and its border's ring, two fills; its tab is over it as in full.
extension DatabaseDefinition: CustomSkeleton {
    func renderSkeleton(_ shape: ShapeRecord<Database>, in context: RenderContext) {
        let box = shape.frame, cg = context.cg, width = DatabaseStyle.borderWidth / context.zoom
        cg.setFillColor(DatabaseStyle.fill.cgColor)
        cg.fill(box)
        let inside = box.insetBy(dx: width, dy: width)
        if !inside.isEmpty { cg.addRect(inside) }
        cg.addRect(box)
        cg.setFillColor(DatabaseStyle.border.cgColor)
        cg.fillPath(using: .evenOdd)
    }
}

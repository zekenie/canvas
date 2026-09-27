import Canvas
import CoreGraphics
import Geometry

/// Decides for itself whether the marquee selects it, instead of the default from its geometry
/// (an edge of the outline crosses or touches the brush, or, for a closed shape, the brush lies
/// inside the outline).
public protocol BrushHitTesting: ShapeDefinition {
    /// Whether a marquee (a world rect) selects the shape. Asked only when the brush overlaps or
    /// touches the shape's `geometry.bounds` without strictly containing them: bounds strictly
    /// inside always select, and with ⌘ nothing else does, so a kind never deals with containment.
    func brushHitTest(_ brush: CGRect, on shape: ShapeRecord<Props>, in context: ShapeContext) -> Bool
}

extension BrushHitTesting {
    func erasedBrushHitTest(_ brush: CGRect, on record: AnyShapeRecord, in context: ShapeContext) -> Bool {
        record.typed(as: Props.self).map { brushHitTest(brush, on: $0, in: context) } ?? false
    }
}

extension ShapeGeometry {
    /// The marquee's default test, for a brush (a world rect) that overlaps or touches the bounds:
    /// an edge of the outline crosses or touches it, or, for a closed shape, it lies inside the
    /// outline. A `BrushHitTesting` kind can fall back on it.
    public func isHit(byBrush brush: CGRect) -> Bool {
        guard !outline.isEmpty else { return false }
        let edges = isClosed ? outline.closedEdges : Array(zip(outline, outline.dropFirst()))
        let box = brush.polygon
        if edges.contains(where: { !intersections(ofSegmentFrom: $0.0, to: $0.1, withPolygon: box).isEmpty }) { return true }
        // No edge meets the brush, so the brush is wholly inside the shape or wholly outside it.
        // Geometric, not `hitTest`: a hit margin mustn't select a brush just outside the shape.
        return isClosed && polygonContains(outline, brush.origin)
    }
}

extension CanvasEditor {
    /// The selectable shapes a brush (a world rect) selects, back to front. Bounds strictly inside
    /// the brush always count; with `mustContain` (⌘) nothing else does; otherwise a shape whose
    /// bounds the brush overlaps or touches counts if its definition's `brushHitTest` (or the
    /// default) says so. Shapes with no outline never count.
    func shapes(inBrush brush: CGRect, mustContain: Bool) -> [ShapeID] {
        guard let state = selectionState else { return [] }
        let context = shapeContext
        return paintOrder().filter { record in
            guard state.isSelectable(record),
                  let geometry = context.geometry(of: record.id),
                  !geometry.outline.isEmpty, !geometry.bounds.isNull else { return false }
            if brush.containsStrictly(geometry.bounds) { return true }
            guard !mustContain, brush.touches(geometry.bounds) else { return false }
            if let custom = registry.definition(for: record.kind) as? any BrushHitTesting {
                return custom.erasedBrushHitTest(brush, on: record, in: context)
            }
            return geometry.isHit(byBrush: brush)
        }.map(\.id)
    }
}

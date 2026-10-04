import AppKit
import Canvas
import Geometry

/// An arrow zoomed out (`CustomSkeleton`): its body as its kept geometry has it, never worked out
/// again (`render` looks up the shapes it joins and clips its ends every frame): the arc through
/// its start, the middle of its body and its end (`ArrowSkeleton`), stroked in its color as wide
/// as its own but never under a view point, as the core's open skeletons are, with butt ends; and
/// each of its heads a filled triangle, as long as its own and swung the same way, along the arc.
/// A stroke and a fill. Its outline, selected or hovered, is that arc, not its kept geometry's two
/// straight segments. With a label, both are cut where the label is, as its kept geometry has it
/// (`ShapeGeometry.label`: nothing measured here), and its text is greeked there, each line's bar
/// centered, as the text is.
extension ArrowDefinition: CustomSkeleton {
    func renderSkeleton(_ shape: ShapeRecord<Arrow>, in context: RenderContext) {
        guard let geometry = context.shapes.geometry(of: shape.id), let body = ArrowSkeleton(geometry, zoom: context.zoom) else { return }
        let cg = context.cg, color = ArrowStyle.color.cgColor, arrow = shape.props
        let label = arrow.hasText ? geometry.label : nil
        if let label {
            cg.saveGState()
            cg.addRect(geometry.bounds.insetBy(dx: -ArrowStyle.strokeWidth * 4, dy: -ArrowStyle.strokeWidth * 4))
            cg.addRect(label)
            cg.clip(using: .evenOdd)
        }
        body.add(to: cg)
        cg.setStrokeColor(color)
        cg.setLineWidth(max(ArrowStyle.strokeWidth, ArrowStyle.skeletonLineWidth / context.zoom))
        cg.strokePath()
        if arrow.startArrowhead || arrow.endArrowhead {
            if arrow.startArrowhead { body.addHead(at: .start, strokeWidth: ArrowStyle.strokeWidth, to: cg) }
            if arrow.endArrowhead { body.addHead(at: .end, strokeWidth: ArrowStyle.strokeWidth, to: cg) }
            cg.setFillColor(color)
            cg.fillPath()
        }
        guard let label else { return }
        cg.restoreGState()
        let box = label.insetBy(dx: ArrowStyle.labelPadding, dy: ArrowStyle.labelPadding)
        let bars = SkeletonTextBars(CollectionOfOne(SkeletonTextRun.text(arrow.text)), in: box, metrics: ArrowStyle.skeletonText)
        context.fillSkeletonText(bars.lazy.map { $0.offsetBy(dx: (box.width - $0.width) / 2, dy: 0) })
    }
}

extension ArrowDefinition: CustomSkeletonOutline {
    func skeletonIndicatorPath(of shape: ShapeRecord<Arrow>, in context: ShapeContext) -> CGPath? {
        guard let geometry = context.geometry(of: shape.id), let body = ArrowSkeleton(geometry, zoom: context.zoom) else { return nil }
        guard shape.props.hasText, let label = geometry.label else { return body.path }
        let path = CGMutablePath()
        path.addPath(body.path.lineSubtracting(CGPath(rect: label, transform: nil)))
        path.addRect(label)
        return path
    }
}

extension ArrowStyle {
    /// The narrowest a skeleton's body is, in view points: the core's open skeletons' line.
    static let skeletonLineWidth: CGFloat = 1
    /// The label's 15-point text greeked as a note's 16-point text is: 0.52 em a column, its
    /// 18-point lines, and each line's bar over the x-height.
    static let skeletonText = SkeletonTextMetrics(advance: SkeletonTextMetrics.systemFontColumn * labelFont.pointSize,
                                                  lineHeight: labelLineHeight, barTop: 6, barHeight: 8)
}

/// An arrow's visible body as its kept geometry has it (`ShapeGeometry.outline`: where it starts,
/// the middle of its body, where it ends; all on the arc `ArrowGeometry` works out, or its line):
/// the circle through the three, or the line from its start to its end where the middle is as
/// good as on it, less than `straightness` view points off, where an arc would draw the same and
/// its circle is too big to work out well. Nothing but arithmetic on the three points.
struct ArrowSkeleton {
    /// How far off the line from the start to the end the middle may be for a straight body, in
    /// view points.
    static let straightness: CGFloat = 0.25

    let start: CGPoint
    let end: CGPoint
    /// Nil for a straight body.
    let arc: Arc?

    /// Nil for a geometry that isn't an arrow's three points.
    init?(_ geometry: ShapeGeometry, zoom: CGFloat) {
        let points = geometry.outline
        guard points.count == 3 else { return nil }
        start = points[0]
        end = points[2]
        let middle = points[1], chord = end - start, length = chord.length
        let off = length > 0 ? abs(chord.cross(middle - start)) / length : middle.distance(to: start)
        arc = off * zoom < Self.straightness ? nil : Arc(from: start, through: middle, to: end)
    }

    /// The body's length, along the arc.
    var length: CGFloat { arc?.length ?? start.distance(to: end) }

    /// The body, added to the context's path.
    func add(to cg: CGContext) {
        cg.move(to: start)
        if let arc {
            // An arc's sweep turns the angle up when it's positive, as the context's
            // counterclockwise does, in its own coordinates, flipped or not.
            cg.addArc(center: arc.center, radius: arc.radius, startAngle: arc.startAngle, endAngle: arc.startAngle + arc.sweep,
                      clockwise: arc.sweep < 0)
        } else {
            cg.addLine(to: end)
        }
    }

    /// The body as a path: the arrow's outline while skeletons are drawn.
    var path: CGPath {
        let path = CGMutablePath()
        path.move(to: start)
        if let arc {
            path.addRelativeArc(center: arc.center, radius: arc.radius, startAngle: arc.startAngle, delta: arc.sweep)
        } else {
            path.addLine(to: end)
        }
        return path
    }

    /// A head at `end`, added to the context's path, closed: a triangle from the tip, where the
    /// body ends, to the render's wings (`ArrowGeometry.arrowheadsPath`), each swung 30° off the
    /// body from the point a head's length back along it, measured as a chord on an arc. A head
    /// is a fifth of the body, between one and three stroke widths.
    func addHead(at end: ArrowEnd, strokeWidth: CGFloat, to cg: CGContext) {
        let tip = end == .start ? start : self.end
        let length = min(max(self.length / 5, strokeWidth), strokeWidth * 3)
        let base: CGPoint
        if let arc {
            let step = 2 * asin(min(1, length / (2 * arc.radius))) / abs(arc.sweep)
            base = arc.point(at: end == .start ? step : 1 - step)
        } else {
            base = tip.moved(toward: end == .start ? self.end : start, by: length)
        }
        cg.move(to: base.rotated(around: tip, by: .pi / 6))
        cg.addLine(to: tip)
        cg.addLine(to: base.rotated(around: tip, by: -.pi / 6))
        cg.closePath()
    }
}

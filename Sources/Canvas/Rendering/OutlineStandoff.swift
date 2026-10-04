import CoreGraphics
import Geometry

// What the core strokes for a closed shape's outline: its kind's `indicatorPath` grown outward by
// `CanvasEditor.outlineStandoff` view points, so every kind's selection, hover and hint stand off
// their shape alike. A rect or a rounded rect, which is every box kind there is, is grown directly
// (a rounded rect of the same box, its corners concentric: the radius grows by the gap, a plain
// rect gets corners of the gap's radius), and costs what the plain outline did; any other closed
// outline is grown by path arithmetic, as Validation's ring is. An open outline has no inside to
// stand off from, and is stroked on its own path.

extension CGPath {
    /// This path grown outward by `distance`: everything within `distance` of it, and for a closed
    /// one its inside too, so the edge of the result is the path's outline moved out that far, its
    /// corners round; for an open one, a band around it. Path arithmetic, so it costs far more than
    /// building a rect: callers keep what they grow (Validation's rings), or grow a rect or a rounded
    /// rect directly, as the core does for the outline of a box.
    public func grownOutward(by distance: CGFloat, isClosed: Bool) -> CGPath {
        let band = copy(strokingWithWidth: distance * 2, lineCap: .round, lineJoin: .round, miterLimit: 10)
        return isClosed ? union(band) : band.normalized()
    }
}

/// A closed outline that is a rectangle's edge, its corners rounded by one radius or not at all:
/// what every box kind's `indicatorPath` is (a note's, a frame's, a schema card's, a subboard's, and
/// the default's, the frame itself).
struct RoundedBox: Equatable {
    var rect: CGRect
    /// Zero for a plain rect.
    var radius: CGFloat

    /// The box with its edge moved `distance` outward all the way round: its rect grown by that,
    /// its corners with it (concentric, so the gap between the two edges is the same at a corner
    /// as along a side), never past a pill's radius.
    func grown(by distance: CGFloat) -> RoundedBox {
        let outer = rect.insetBy(dx: -distance, dy: -distance)
        return RoundedBox(rect: outer, radius: min(radius + distance, outer.width / 2, outer.height / 2))
    }

    /// Whether `path` is the edge of the rectangle `bounds`, and if it is, that box and its corner
    /// radius. A rect is four straight edges; a rounded rect, whatever its corners' curves are made
    /// of, is four straight edges (a pill's short sides, none) each inset from its corners by the
    /// same radius, and curves between them. The straight edges alone say so: they lie on the sides
    /// of the box and leave the same room at both ends. Anything else (a polygon, an ellipse,
    /// elliptical corners, a path that isn't `bounds`) is nil, and is grown by path arithmetic.
    /// Reads the path twice and makes nothing: it runs for every outlined shape in view.
    static func of(_ path: CGPath, matching bounds: CGRect) -> RoundedBox? {
        // The extent of the path's end points, and whether it is one subpath of lines and cubic
        // curves, which is what a rect and a rounded rect are.
        var minX = CGFloat.infinity, minY = CGFloat.infinity, maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        var subpaths = 0
        var simple = true
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            let end: CGPoint
            switch element.type {
            case .moveToPoint:
                subpaths += 1
                end = element.points[0]
            case .addLineToPoint:
                end = element.points[0]
            case .addCurveToPoint:
                end = element.points[2]
            case .closeSubpath:
                return
            default:
                simple = false
                return
            }
            minX = min(minX, end.x)
            maxX = max(maxX, end.x)
            minY = min(minY, end.y)
            maxY = max(maxY, end.y)
        }
        let width = maxX - minX, height = maxY - minY
        guard simple, subpaths == 1, width >= 0, height >= 0, width.isFinite, height.isFinite else { return nil }
        let tolerance = 1e-6 * max(1, width, height)
        guard abs(minX - bounds.minX) <= tolerance, abs(minY - bounds.minY) <= tolerance,
              abs(width - bounds.width) <= tolerance, abs(height - bounds.height) <= tolerance else { return nil }

        // Each straight segment must run along a side of the box (closing the subpath is one too,
        // back to where it began), and what lies along a side, wherever the path began, leaves the
        // same room at either end: the corner's radius.
        var curves = 0
        var isBox = true
        var current = CGPoint.zero, start = CGPoint.zero
        // The span of what lies along each side, along it: the top and the bottom in x, the left and
        // the right in y.
        var top = (lo: CGFloat.infinity, hi: -CGFloat.infinity), bottom = top, left = top, right = top
        func straight(from a: CGPoint, to b: CGPoint) {
            if abs(a.x - b.x) <= tolerance, abs(a.y - b.y) <= tolerance { return }
            if abs(a.y - b.y) <= tolerance {
                let span = (lo: min(a.x, b.x), hi: max(a.x, b.x))
                if abs(a.y - minY) <= tolerance {
                    top = (min(top.lo, span.lo), max(top.hi, span.hi))
                } else if abs(a.y - maxY) <= tolerance {
                    bottom = (min(bottom.lo, span.lo), max(bottom.hi, span.hi))
                } else {
                    isBox = false
                }
            } else if abs(a.x - b.x) <= tolerance {
                let span = (lo: min(a.y, b.y), hi: max(a.y, b.y))
                if abs(a.x - minX) <= tolerance {
                    left = (min(left.lo, span.lo), max(left.hi, span.hi))
                } else if abs(a.x - maxX) <= tolerance {
                    right = (min(right.lo, span.lo), max(right.hi, span.hi))
                } else {
                    isBox = false
                }
            } else {
                isBox = false
            }
        }
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            switch element.type {
            case .moveToPoint:
                start = element.points[0]
                current = start
            case .addLineToPoint:
                straight(from: current, to: element.points[0])
                current = element.points[0]
            case .addCurveToPoint:
                curves += 1
                current = element.points[2]
            case .closeSubpath:
                straight(from: current, to: start)
                current = start
            default:
                isBox = false
            }
        }
        // The room each side leaves at its ends. No straight edge says nothing of the corners (an
        // ellipse is four curves); curves with square corners, or square corners with a curve, aren't
        // a box; and a corner is a curve or two, a few at most, which leaves a notch cut in a side out.
        var found: CGFloat?
        var agrees = true
        func leaves(_ room: CGFloat) {
            if let known = found { if abs(room - known) > tolerance { agrees = false } } else { found = room }
        }
        if top.hi >= top.lo { leaves(top.lo - minX); leaves(maxX - top.hi) }
        if bottom.hi >= bottom.lo { leaves(bottom.lo - minX); leaves(maxX - bottom.hi) }
        if left.hi >= left.lo { leaves(left.lo - minY); leaves(maxY - left.hi) }
        if right.hi >= right.lo { leaves(right.lo - minY); leaves(maxY - right.hi) }
        guard isBox, agrees, let radius = found, radius >= -tolerance, radius * 2 <= min(width, height) + tolerance,
              (radius > tolerance) == (curves > 0), curves % 4 == 0, curves <= 16 else { return nil }
        return RoundedBox(rect: CGRect(x: minX, y: minY, width: width, height: height), radius: radius > tolerance ? radius : 0)
    }
}

extension CanvasEditor {
    /// How far, in view points, the canvas stands the outline of a closed shape off its edge:
    /// `Style.outlineStandoff` (4) unless the host says otherwise. For a plugin that draws along an
    /// outline and wants to stay clear of it, or outside it (Validation's ring, which is that and
    /// its own padding out); an open shape (an arrow) isn't stood off.
    public var outlineGap: CGFloat { outlineStandoff }

    /// The outline the canvas strokes for a shape (the selection's, a hover's, the hint), in world
    /// units, where the shape is (not where a drawing offset draws it): its kind's `indicatorPath`,
    /// grown outward by `outlineGap` view points if the shape is closed. Nil for a shape kept aside
    /// or of a kind no plugin defines. For an overlay that outlines shapes the way a hover is
    /// outlined (Ports' targets), so its line lies where the core's would.
    public func outlinePath(of shape: AnyShapeRecord) -> CGPath? {
        let shapes = shapeContext
        guard let indicator = registry.indicatorPath(of: shape, in: shapes) else { return nil }
        let path = CGMutablePath()
        addOutline(of: indicator, geometry: shapes.geometry(of: shape.id), standingOff: outlineStandoff / camera.zoom,
                   to: path, transform: .identity)
        return path
    }

    /// Adds to `path` a shape's outline, `indicator` (its kind's `indicatorPath`), stood off its edge
    /// by `gap` (world units) if the shape's kept `geometry` is closed, else as it is: a rect or a
    /// rounded rect is added grown, directly, any other closed outline grown by path arithmetic. A
    /// `gap` of zero is the outline as it is.
    func addOutline(of indicator: CGPath, geometry: ShapeGeometry?, standingOff gap: CGFloat,
                    to path: CGMutablePath, transform: CGAffineTransform) {
        guard gap > 0, let geometry, geometry.isClosed else {
            path.addPath(indicator, transform: transform)
            return
        }
        if let box = RoundedBox.of(indicator, matching: geometry.bounds) {
            let grown = box.grown(by: gap)
            path.addRoundedRect(in: grown.rect, cornerWidth: grown.radius, cornerHeight: grown.radius, transform: transform)
        } else {
            path.addPath(indicator.grownOutward(by: gap, isClosed: true), transform: transform)
            #if DEBUG
            outlinesGrownByArithmetic += 1
            #endif
        }
    }
}

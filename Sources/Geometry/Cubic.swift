import CoreGraphics
import Foundation

// MARK: - Cubic Bézier curves

/// A cubic Bézier curve from `start` to `end`, pulled toward `control1` and `control2`, parameterized 0...1. Pure arithmetic:
/// what a line that leaves one side and enters another is drawn as (an arrow with an end at a row).
public struct Cubic: Sendable, Hashable {
    public var start: CGPoint
    public var control1: CGPoint
    public var control2: CGPoint
    public var end: CGPoint

    /// How many straight pieces a curve is measured and searched as: plenty for a line a few hundred units long, whose
    /// pieces then bow off the curve by well under a hundredth of a unit.
    public static let segments = 64

    public init(_ start: CGPoint, _ control1: CGPoint, _ control2: CGPoint, _ end: CGPoint) {
        self.start = start
        self.control1 = control1
        self.control2 = control2
        self.end = end
    }

    /// The point at `t`.
    public func point(at t: CGFloat) -> CGPoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return CGPoint(x: a * start.x + b * control1.x + c * control2.x + d * end.x,
                       y: a * start.y + b * control1.y + c * control2.y + d * end.y)
    }

    /// The curve's velocity at `t`: its tangent, unscaled.
    public func derivative(at t: CGFloat) -> CGPoint {
        let u = 1 - t
        let a = (control1 - start) * (3 * u * u), b = (control2 - control1) * (6 * u * t), c = (end - control2) * (3 * t * t)
        return a + b + c
    }

    /// The unit tangent at `t`, in the direction of travel. Where the velocity vanishes (a control on its end), the way the
    /// curve goes from there: toward the next point that differs; zero for a curve that is a single point.
    public func tangent(at t: CGFloat) -> CGPoint {
        let velocity = derivative(at: t)
        if velocity.length > 1e-9 { return velocity.normalized }
        // A control on its end: the curve sets off toward the other control, or failing that the far end.
        let ahead = t < 0.5
        for target in ahead ? [control2, end] : [control1, start] {
            let from = point(at: t)
            let direction = ahead ? target - from : from - target
            if direction.length > 1e-9 { return direction.normalized }
        }
        return .zero
    }

    /// The two curves either side of `t`, the first from `start` to the point at `t`, the second from there to `end`
    /// (de Casteljau).
    public func split(at t: CGFloat) -> (Cubic, Cubic) {
        let ab = start + (control1 - start) * t, bc = control1 + (control2 - control1) * t, cd = control2 + (end - control2) * t
        let abc = ab + (bc - ab) * t, bcd = bc + (cd - bc) * t
        let middle = abc + (bcd - abc) * t
        return (Cubic(start, ab, abc, middle), Cubic(middle, bcd, cd, end))
    }

    /// The part of the curve between `t0` and `t1`, as a curve of its own, parameterized 0...1.
    public func trimmed(from t0: CGFloat, to t1: CGFloat) -> Cubic {
        guard t0 > 0 || t1 < 1 else { return self }
        let tail = t0 > 0 ? split(at: t0).1 : self
        guard t1 < 1 else { return tail }
        // Where `t1` falls on what is left after `t0`.
        let local = t0 < 1 ? (t1 - t0) / (1 - t0) : 1
        return tail.split(at: min(max(local, 0), 1)).0
    }

    /// `segments + 1` points along it, evenly spaced in `t`, its ends included.
    public func flattened(segments: Int = Cubic.segments) -> [CGPoint] {
        let count = max(segments, 1)
        return (0...count).map { point(at: CGFloat($0) / CGFloat(count)) }
    }

    /// Its length, along the curve.
    public var length: CGFloat { measured().length }

    /// How far `point` is from the nearest point of the curve.
    public func distance(to point: CGPoint) -> CGFloat {
        let points = flattened()
        var nearest = CGFloat.infinity
        for index in 1..<points.count {
            nearest = min(nearest, distanceToSegment(from: point, points[index - 1], points[index]))
        }
        return nearest
    }

    /// The parameters in 0...1 where the curve crosses the closed polygon's edges, in order along it: found on its pieces,
    /// then refined on the curve itself.
    public func intersections(withPolygon polygon: [CGPoint]) -> [CGFloat] {
        guard polygon.count >= 2 else { return [] }
        let count = Cubic.segments
        let points = flattened(segments: count)
        var result: [CGFloat] = []
        for (p, q) in polygon.closedEdges {
            let edge = q - p
            guard edge.length > 1e-12 else { continue }
            var found: [CGFloat] = []
            defer {
                // A crossing on the end two pieces share is found by both: once.
                for t in found where !result.contains(where: { abs($0 - t) < 1e-6 }) { result.append(t) }
            }
            // Which side of the edge's line a point is on.
            func side(_ point: CGPoint) -> CGFloat { edge.cross(point - p) }
            for index in 1..<points.count {
                let a = points[index - 1], b = points[index]
                guard !Geometry.intersections(ofSegmentFrom: a, to: b, withPolygon: [p, q]).isEmpty else { continue }
                // Refined by halving between the piece's ends, against the edge's line.
                var low = CGFloat(index - 1) / CGFloat(count), high = CGFloat(index) / CGFloat(count)
                let lowSide = side(a)
                if lowSide != 0, side(b) != 0, (lowSide > 0) != (side(b) > 0) {
                    for _ in 0..<24 {
                        let mid = (low + high) / 2
                        if (side(point(at: mid)) > 0) == (lowSide > 0) { low = mid } else { high = mid }
                    }
                    found.append((low + high) / 2)
                } else {
                    found.append(lowSide == 0 ? low : high)
                }
            }
        }
        return result.sorted()
    }

    /// The smallest rectangle holding the curve (not its controls): its ends and wherever it turns back in x or y.
    public var bounds: CGRect {
        var points = [start, end]
        for axis in [\CGPoint.x, \CGPoint.y] {
            // The velocity along the axis is a quadratic in t: a t² + b t + c, its roots where the curve turns back.
            let p0 = start[keyPath: axis], p1 = control1[keyPath: axis], p2 = control2[keyPath: axis], p3 = end[keyPath: axis]
            let a = -p0 + 3 * p1 - 3 * p2 + p3, b = 2 * (p0 - 2 * p1 + p2), c = p1 - p0
            var roots: [CGFloat] = []
            if abs(a) < 1e-12 {
                if abs(b) > 1e-12 { roots.append(-c / b) }
            } else {
                let discriminant = b * b - 4 * a * c
                if discriminant >= 0 {
                    let root = discriminant.squareRoot()
                    roots += [(-b + root) / (2 * a), (-b - root) / (2 * a)]
                }
            }
            points += roots.filter { $0 > 0 && $0 < 1 }.map { point(at: $0) }
        }
        return CGRect(enclosing: points)
    }

    /// Its points by length along it (`CubicMeasure`), measured on `segments` pieces.
    public func measured(segments: Int = Cubic.segments) -> CubicMeasure { CubicMeasure(self, segments: segments) }

    /// The curve, added to `path` from where `path` is (a `move` first, unless `continuing`).
    public func add(to path: CGMutablePath, continuing: Bool = false) {
        if !continuing { path.move(to: start) }
        path.addCurve(to: end, control1: control1, control2: control2)
    }

    /// The curve as a path of its own.
    public var cgPath: CGPath {
        let path = CGMutablePath()
        add(to: path)
        return path
    }
}

/// A curve measured along its length: how far along it each parameter is, and back, for what is placed by length on it (a
/// label, an arrowhead's base, a gap at an end). Worked out once from its pieces, then looked up by halving.
public struct CubicMeasure: Sendable {
    public let cubic: Cubic
    /// The length along the curve at each piece's end, from 0 at its start: `segments + 1` of them.
    private let lengths: [CGFloat]

    public init(_ cubic: Cubic, segments: Int = Cubic.segments) {
        self.cubic = cubic
        let points = cubic.flattened(segments: segments)
        var lengths: [CGFloat] = [0]
        lengths.reserveCapacity(points.count)
        for index in 1..<points.count { lengths.append(lengths[index - 1] + points[index - 1].distance(to: points[index])) }
        self.lengths = lengths
    }

    private var segments: Int { lengths.count - 1 }

    /// Its whole length.
    public var length: CGFloat { lengths.last ?? 0 }

    /// How far along the curve the point at `t` is.
    public func length(at t: CGFloat) -> CGFloat {
        let scaled = min(max(t, 0), 1) * CGFloat(segments)
        let index = min(Int(scaled), segments - 1)
        return lengths[index] + (lengths[index + 1] - lengths[index]) * (scaled - CGFloat(index))
    }

    /// The parameter of the point `distance` along the curve, clamped to its ends.
    public func parameter(atLength distance: CGFloat) -> CGFloat {
        guard length > 0 else { return 0 }
        let wanted = min(max(distance, 0), length)
        var low = 0, high = segments
        while high - low > 1 {
            let middle = (low + high) / 2
            if lengths[middle] <= wanted { low = middle } else { high = middle }
        }
        let span = lengths[high] - lengths[low]
        let within = span > 0 ? (wanted - lengths[low]) / span : 0
        return (CGFloat(low) + within) / CGFloat(segments)
    }

    /// The point `fraction` of the way along it by length.
    public func point(atFraction fraction: CGFloat) -> CGPoint { cubic.point(at: parameter(atLength: fraction * length)) }

    /// How far along it by length, as a fraction, the point of it nearest `point` is: 0 at its start, 1 at its end.
    public func fraction(nearest point: CGPoint) -> CGFloat {
        guard length > 0 else { return 0 }
        let points = cubic.flattened(segments: segments)
        var best = (distance: CGFloat.infinity, along: CGFloat(0))
        for index in 1..<points.count {
            let a = points[index - 1], b = points[index]
            let near = nearestPointOnSegment(to: point, a, b)
            let distance = near.distance(to: point)
            if distance < best.distance { best = (distance, lengths[index - 1] + a.distance(to: near)) }
        }
        return min(max(best.along / length, 0), 1)
    }
}

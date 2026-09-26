import Foundation

// MARK: - Vector math

extension CGPoint {
    static func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint { CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y) }
    static func - (lhs: CGPoint, rhs: CGPoint) -> CGPoint { CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y) }
    static func * (lhs: CGPoint, rhs: CGFloat) -> CGPoint { CGPoint(x: lhs.x * rhs, y: lhs.y * rhs) }
    static func / (lhs: CGPoint, rhs: CGFloat) -> CGPoint { CGPoint(x: lhs.x / rhs, y: lhs.y / rhs) }

    /// A unit vector (or one of `length`) pointing at `angle` radians.
    init(angle: CGFloat, length: CGFloat = 1) {
        self.init(x: cos(angle) * length, y: sin(angle) * length)
    }

    var length: CGFloat { hypot(x, y) }
    var angle: CGFloat { atan2(y, x) }
    var normalized: CGPoint {
        let length = length
        return length > 0 ? self / length : .zero
    }
    /// This vector rotated a quarter turn, toward +y from +x.
    var perpendicular: CGPoint { CGPoint(x: -y, y: x) }

    func distance(to other: CGPoint) -> CGFloat { (self - other).length }
    func dot(_ other: CGPoint) -> CGFloat { x * other.x + y * other.y }
    func cross(_ other: CGPoint) -> CGFloat { x * other.y - y * other.x }

    func moved(toward target: CGPoint, by distance: CGFloat) -> CGPoint {
        self + (target - self).normalized * distance
    }

    func rotated(around center: CGPoint, by angle: CGFloat) -> CGPoint {
        let offset = self - center
        let (sine, cosine) = (sin(angle), cos(angle))
        return center + CGPoint(x: offset.x * cosine - offset.y * sine, y: offset.x * sine + offset.y * cosine)
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }

    /// The corners in order, as a closed polygon.
    var polygon: [CGPoint] {
        [CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: minY), CGPoint(x: maxX, y: maxY), CGPoint(x: minX, y: maxY)]
    }
}

/// `angle` wrapped into 0..<2π.
func normalizedAngle(_ angle: CGFloat) -> CGFloat {
    let wrapped = angle.truncatingRemainder(dividingBy: 2 * .pi)
    return wrapped < 0 ? wrapped + 2 * .pi : wrapped
}

func nearestPointOnSegment(to point: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGPoint {
    let ab = b - a
    let lengthSquared = ab.dot(ab)
    guard lengthSquared > 0 else { return a }
    let t = min(max((point - a).dot(ab) / lengthSquared, 0), 1)
    return a + ab * t
}

func distanceToSegment(from point: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
    point.distance(to: nearestPointOnSegment(to: point, a, b))
}

func nearestPointOnPolygon(_ polygon: [CGPoint], to point: CGPoint) -> CGPoint {
    polygon.closedEdges
        .map { nearestPointOnSegment(to: point, $0.0, $0.1) }
        .min { $0.distance(to: point) < $1.distance(to: point) } ?? point
}

/// Rotates `point` around `center` so its angle snaps to the nearest of `steps` equal divisions
/// of a full turn.
func snapAngle(of point: CGPoint, around center: CGPoint, steps: Int) -> CGPoint {
    let angle = (point - center).angle
    let increment = 2 * .pi / CGFloat(steps)
    return point.rotated(around: center, by: (angle / increment).rounded() * increment - angle)
}

// MARK: - Arcs

/// A circular arc starting at `startAngle` and turning through `sweep` radians. A positive sweep
/// runs in the direction of increasing angle.
struct Arc {
    var center: CGPoint
    var radius: CGFloat
    var startAngle: CGFloat
    var sweep: CGFloat

    /// The arc from `a` to `b` that passes through `c`, or nil if the points are (nearly) collinear.
    init?(from a: CGPoint, through c: CGPoint, to b: CGPoint) {
        let d = 2 * (a.x * (c.y - b.y) + c.x * (b.y - a.y) + b.x * (a.y - c.y))
        guard abs(d) > 1e-9 else { return nil }
        let (a2, b2, c2) = (a.dot(a), b.dot(b), c.dot(c))
        let center = CGPoint(
            x: (a2 * (c.y - b.y) + c2 * (b.y - a.y) + b2 * (a.y - c.y)) / d,
            y: (a2 * (b.x - c.x) + c2 * (a.x - b.x) + b2 * (c.x - a.x)) / d
        )
        let startAngle = (a - center).angle
        let toEnd = normalizedAngle((b - center).angle - startAngle)
        let toMiddle = normalizedAngle((c - center).angle - startAngle)

        self.center = center
        self.radius = a.distance(to: center)
        self.startAngle = startAngle
        self.sweep = toMiddle <= toEnd ? toEnd : toEnd - 2 * .pi
    }

    var length: CGFloat { abs(sweep) * radius }

    func point(at t: CGFloat) -> CGPoint {
        center + CGPoint(angle: startAngle + sweep * t, length: radius)
    }

    /// Unit tangent in the direction of travel.
    func tangent(at t: CGFloat) -> CGPoint {
        CGPoint(angle: startAngle + sweep * t).perpendicular * (sweep >= 0 ? 1 : -1)
    }

    /// Where the ray from the center through `point` crosses the arc, as a parameter in 0...1, or
    /// nil if it misses.
    func parameter(of point: CGPoint) -> CGFloat? {
        let delta = normalizedAngle((point - center).angle - startAngle)
        let along = sweep >= 0 ? delta : normalizedAngle(-delta)
        let tolerance: CGFloat = 1e-9
        if along <= abs(sweep) + tolerance {
            return min(along / abs(sweep), 1)
        }
        // Just before the start, within rounding error.
        return along >= 2 * .pi - tolerance ? 0 : nil
    }

    func distance(to point: CGPoint) -> CGFloat {
        if parameter(of: point) != nil {
            return abs(point.distance(to: center) - radius)
        }
        return min(point.distance(to: self.point(at: 0)), point.distance(to: self.point(at: 1)))
    }

    /// The part of this arc between parameters `t0` and `t1`, reparameterized to 0...1.
    func trimmed(from t0: CGFloat, to t1: CGFloat) -> Arc {
        Arc(center: center, radius: radius, startAngle: startAngle + sweep * t0, sweep: sweep * (t1 - t0))
    }

    private init(center: CGPoint, radius: CGFloat, startAngle: CGFloat, sweep: CGFloat) {
        self.center = center
        self.radius = radius
        self.startAngle = startAngle
        self.sweep = sweep
    }
}

// MARK: - Intersections

/// Parameters in 0...1 along the segment `a`→`b` where it crosses the closed polygon's edges.
func intersections(ofSegmentFrom a: CGPoint, to b: CGPoint, withPolygon polygon: [CGPoint]) -> [CGFloat] {
    let r = b - a
    var result: [CGFloat] = []
    for (p, q) in polygon.closedEdges {
        let s = q - p
        let denominator = r.cross(s)
        guard abs(denominator) > 1e-12 else { continue }
        let t = (p - a).cross(s) / denominator
        let u = (p - a).cross(r) / denominator
        if (0...1).contains(t), (0...1).contains(u) {
            result.append(t)
        }
    }
    return result
}

/// Arc parameters in 0...1 where the arc crosses the closed polygon's edges.
func intersections(of arc: Arc, withPolygon polygon: [CGPoint]) -> [CGFloat] {
    var result: [CGFloat] = []
    for (p, q) in polygon.closedEdges {
        let d = q - p
        let f = p - arc.center
        let a = d.dot(d)
        let b = 2 * f.dot(d)
        let c = f.dot(f) - arc.radius * arc.radius
        let discriminant = b * b - 4 * a * c
        guard a > 0, discriminant >= 0 else { continue }
        let root = discriminant.squareRoot()
        for u in [(-b - root) / (2 * a), (-b + root) / (2 * a)] where (0...1).contains(u) {
            if let t = arc.parameter(of: p + d * u) {
                result.append(t)
            }
        }
    }
    return result
}

extension Array where Element == CGPoint {
    /// Consecutive pairs of points, including the edge from the last point back to the first.
    var closedEdges: [(CGPoint, CGPoint)] {
        indices.map { (self[$0], self[($0 + 1) % count]) }
    }
}

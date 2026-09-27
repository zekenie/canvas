import CoreGraphics
import Foundation

// MARK: - Vector math

extension CGPoint {
    public static func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint { CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y) }
    public static func - (lhs: CGPoint, rhs: CGPoint) -> CGPoint { CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y) }
    public static func * (lhs: CGPoint, rhs: CGFloat) -> CGPoint { CGPoint(x: lhs.x * rhs, y: lhs.y * rhs) }
    public static func / (lhs: CGPoint, rhs: CGFloat) -> CGPoint { CGPoint(x: lhs.x / rhs, y: lhs.y / rhs) }

    /// A unit vector (or one of `length`) pointing at `angle` radians.
    public init(angle: CGFloat, length: CGFloat = 1) {
        self.init(x: cos(angle) * length, y: sin(angle) * length)
    }

    public var length: CGFloat { hypot(x, y) }
    public var angle: CGFloat { atan2(y, x) }
    public var normalized: CGPoint {
        let length = length
        return length > 0 ? self / length : .zero
    }
    /// This vector rotated a quarter turn, toward +y from +x.
    public var perpendicular: CGPoint { CGPoint(x: -y, y: x) }

    public func distance(to other: CGPoint) -> CGFloat { (self - other).length }
    public func dot(_ other: CGPoint) -> CGFloat { x * other.x + y * other.y }
    public func cross(_ other: CGPoint) -> CGFloat { x * other.y - y * other.x }

    public func moved(toward target: CGPoint, by distance: CGFloat) -> CGPoint {
        self + (target - self).normalized * distance
    }

    public func rotated(around center: CGPoint, by angle: CGFloat) -> CGPoint {
        let offset = self - center
        let (sine, cosine) = (sin(angle), cos(angle))
        return center + CGPoint(x: offset.x * cosine - offset.y * sine, y: offset.x * sine + offset.y * cosine)
    }
}

extension CGRect {
    /// The smallest rectangle containing all of `points`.
    public init(enclosing points: [CGPoint]) {
        guard let first = points.first else {
            self = .null
            return
        }
        var (minX, minY, maxX, maxY) = (first.x, first.y, first.x, first.y)
        for point in points.dropFirst() {
            minX = Swift.min(minX, point.x)
            minY = Swift.min(minY, point.y)
            maxX = Swift.max(maxX, point.x)
            maxY = Swift.max(maxY, point.y)
        }
        self.init(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    public init(center: CGPoint, size: CGSize) {
        self.init(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }

    public var center: CGPoint { CGPoint(x: midX, y: midY) }

    /// Whether its origin and size are all finite: no NaN, no infinity.
    public var isFinite: Bool { origin.x.isFinite && origin.y.isFinite && size.width.isFinite && size.height.isFinite }

    /// Whether `rect` is strictly inside this one, on every side (tldraw's Box.Contains).
    public func containsStrictly(_ rect: CGRect) -> Bool {
        minX < rect.minX && minY < rect.minY && maxX > rect.maxX && maxY > rect.maxY
    }

    /// Whether the two overlap or share an edge or corner (tldraw's Box.Collides). Unlike
    /// `intersects`, touching counts.
    public func touches(_ rect: CGRect) -> Bool {
        !(maxX < rect.minX || minX > rect.maxX || maxY < rect.minY || minY > rect.maxY)
    }

    /// The corners in order, as a closed polygon.
    public var polygon: [CGPoint] {
        [CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: minY), CGPoint(x: maxX, y: maxY), CGPoint(x: minX, y: maxY)]
    }
}

/// `angle` wrapped into 0..<2π.
public func normalizedAngle(_ angle: CGFloat) -> CGFloat {
    let wrapped = angle.truncatingRemainder(dividingBy: 2 * .pi)
    return wrapped < 0 ? wrapped + 2 * .pi : wrapped
}

public func nearestPointOnSegment(to point: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGPoint {
    let ab = b - a
    let lengthSquared = ab.dot(ab)
    guard lengthSquared > 0 else { return a }
    let t = min(max((point - a).dot(ab) / lengthSquared, 0), 1)
    return a + ab * t
}

public func distanceToSegment(from point: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
    point.distance(to: nearestPointOnSegment(to: point, a, b))
}

/// Whether `point` is inside the closed polygon, by the even-odd rule.
public func polygonContains(_ polygon: [CGPoint], _ point: CGPoint) -> Bool {
    var inside = false
    for (a, b) in polygon.closedEdges where (a.y > point.y) != (b.y > point.y) {
        let crossingX = a.x + (point.y - a.y) / (b.y - a.y) * (b.x - a.x)
        if point.x < crossingX {
            inside.toggle()
        }
    }
    return inside
}

public func nearestPointOnPolygon(_ polygon: [CGPoint], to point: CGPoint) -> CGPoint {
    polygon.closedEdges
        .map { nearestPointOnSegment(to: point, $0.0, $0.1) }
        .min { $0.distance(to: point) < $1.distance(to: point) } ?? point
}

/// Rotates `point` around `center` so its angle snaps to the nearest of `steps` equal divisions
/// of a full turn.
public func snapAngle(of point: CGPoint, around center: CGPoint, steps: Int) -> CGPoint {
    let angle = (point - center).angle
    let increment = 2 * .pi / CGFloat(steps)
    return point.rotated(around: center, by: (angle / increment).rounded() * increment - angle)
}

// MARK: - Arcs

/// A circular arc starting at `startAngle` and turning through `sweep` radians. A positive sweep
/// runs in the direction of increasing angle.
public struct Arc: Sendable {
    public var center: CGPoint
    public var radius: CGFloat
    public var startAngle: CGFloat
    public var sweep: CGFloat

    /// The arc from `a` to `b` that passes through `c`, or nil if the points are (nearly) collinear.
    public init?(from a: CGPoint, through c: CGPoint, to b: CGPoint) {
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

    public var length: CGFloat { abs(sweep) * radius }

    public func point(at t: CGFloat) -> CGPoint {
        center + CGPoint(angle: startAngle + sweep * t, length: radius)
    }

    /// Unit tangent in the direction of travel.
    public func tangent(at t: CGFloat) -> CGPoint {
        CGPoint(angle: startAngle + sweep * t).perpendicular * (sweep >= 0 ? 1 : -1)
    }

    /// Where the ray from the center through `point` crosses the arc, as a parameter in 0...1, or
    /// nil if it misses.
    public func parameter(of point: CGPoint) -> CGFloat? {
        let delta = normalizedAngle((point - center).angle - startAngle)
        let along = sweep >= 0 ? delta : normalizedAngle(-delta)
        let tolerance: CGFloat = 1e-9
        if along <= abs(sweep) + tolerance {
            return min(along / abs(sweep), 1)
        }
        // Just before the start, within rounding error.
        return along >= 2 * .pi - tolerance ? 0 : nil
    }

    public func distance(to point: CGPoint) -> CGFloat {
        if parameter(of: point) != nil {
            return abs(point.distance(to: center) - radius)
        }
        return min(point.distance(to: self.point(at: 0)), point.distance(to: self.point(at: 1)))
    }

    /// The part of this arc between parameters `t0` and `t1`, reparameterized to 0...1.
    public func trimmed(from t0: CGFloat, to t1: CGFloat) -> Arc {
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
public func intersections(ofSegmentFrom a: CGPoint, to b: CGPoint, withPolygon polygon: [CGPoint]) -> [CGFloat] {
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
public func intersections(of arc: Arc, withPolygon polygon: [CGPoint]) -> [CGFloat] {
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
    public var closedEdges: [(CGPoint, CGPoint)] {
        indices.map { (self[$0], self[($0 + 1) % count]) }
    }
}

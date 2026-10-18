import CoreGraphics
import Geometry

/// A line through a point, as two arrows: the halves of the line car ——[owner]——> person each take their part of the circle through
/// the far end of the first, the point (a relationship type's pill) and the far end of the second, so the two read as one smooth
/// arc, as a bent tldraw arrow does when something is dragged off its line. Pure: an arrow takes the arc as its `bend`, which
/// tldraw's own geometry (`ArrowGeometry`) then clips and draws as it does any bent arrow's.
public enum ArrowThrough {
    /// How far the point may be off the straight line between the two far ends, in world units, for the line to be straight.
    public static let straightness: CGFloat = 0.25

    /// Whether `hub` is as good as on the line from `first` to `last`: less than `straightness` off it, or the two far ends are one point.
    public static func isStraight(_ first: CGPoint, hub: CGPoint, _ last: CGPoint) -> Bool {
        let chord = last - first, length = chord.length
        guard length > 0 else { return true }
        return abs(chord.cross(hub - first)) / length < straightness
    }

    /// The bend of an arrow that runs from `start` to `end`, in the terms of `Arrow.bend` (how far the middle of its stretch is pushed
    /// off the straight line, along the perpendicular of the chord), so that it is the part of the circle through `start`, `end` and
    /// `third` that lies between `start` and `end`, on the side of the chord away from `third`. Zero where the three are on a line (or
    /// `start` and `end` are one point).
    public static func bend(from start: CGPoint, to end: CGPoint, awayFrom third: CGPoint) -> CGFloat {
        let chord = end - start
        guard chord.length > 0, let circle = Arc(from: start, through: third, to: end) else { return 0 }
        let middle = (start + end) / 2
        let axis = chord.normalized.perpendicular
        // The circle's points on the chord's perpendicular bisector are the middles of its two arcs between `start` and `end`.
        let toMiddle = middle - circle.center
        let direction = toMiddle.length > 1e-9 ? toMiddle.normalized : axis
        let candidate = circle.center + direction * circle.radius
        let other = circle.center - direction * circle.radius
        // The one on the other side of the chord from `third`.
        let thirdSide = chord.cross(third - start)
        let point = chord.cross(candidate - start) * thirdSide < 0 ? candidate : other
        return (point - middle).dot(axis)
    }
}

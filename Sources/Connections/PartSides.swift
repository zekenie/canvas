import CoreGraphics

// Which side of a row a connection's end leaves by: one rule, the connector's, which the connector draws by (Arrows'
// `ArrowGeometry`) and the bundles read where they pick a row clear of the others on a side (LineRows' `RowBundles`), so the two
// never disagree (review R40: the bundles sided a row end by a rule of their own, which differed from what was drawn beside a
// shape whose span overlaps, and inside a database). Pure.

/// The side of a part (a row) a connection's end is at: its left or right edge, at its middle.
public enum PartSide: Hashable, Sendable {
    case left, right

    /// A level curve's end keeps this far inside the container both its ends are in (a database's edge), where it can; and it
    /// leaves the side of its row with at least `containerSideRoom` inside it (its turn and half a pill on it), else the other.
    public static let containerClearance: CGFloat = 8
    public static let containerSideRoom: CGFloat = 60

    /// The side of `rect` facing `x`: the right at or past its middle (a tie, as a key from a row to another of its table, is
    /// on the right, so both ends leave one side).
    public init(facing x: CGFloat, from rect: CGRect) {
        self = x >= rect.midX ? .right : .left
    }

    /// The sides of two parts a connection joins, chosen together from the boxes of the shapes they are parts of at rest (never
    /// from a row's laid-out line, which is wider while it is typed): shapes whose spans across overlap (one above the other,
    /// as stacked tables are, or one shape's own rows) both leave the right, wherever their middles are, so a row made wider
    /// keeps both ends where they were (a departure from facing each other, which an overlap would cross a table to); shapes
    /// side by side each face the other.
    public static func sides(_ start: CGRect, _ end: CGRect) -> (start: PartSide, end: PartSide) {
        if overlap(start, end) { return (.right, .right) }
        return (PartSide(facing: end.midX, from: start), PartSide(facing: start.midX, from: end))
    }

    /// Whether two boxes' spans across overlap (one above the other).
    public static func overlap(_ a: CGRect, _ b: CGRect) -> Bool { a.minX < b.maxX && b.minX < a.maxX }

    /// The sides a connection's ends at rows are drawn at: each end at a row (`row`, its laid-out rect; `rest`, its shape's box at
    /// rest; `x`, where the end is aimed across: a row's middle, else its anchor) sided together with the other where both are
    /// at rows (`sides`), else facing the other end; and inside a container both ends are in (`container`), an end whose side has
    /// too little room inside it takes the other where that has room (both together, for ends sided together).
    public static func drawn(start: (row: CGRect?, rest: CGRect?, x: CGFloat), end: (row: CGRect?, rest: CGRect?, x: CGFloat),
                             container: CGRect?) -> (start: PartSide?, end: PartSide?) {
        let together = start.row != nil && end.row != nil ? start.rest.flatMap { a in end.rest.map { sides(a, $0) } } : nil
        var result = (start: start.row.map { together?.start ?? PartSide(facing: end.x, from: $0) },
                      end: end.row.map { together?.end ?? PartSide(facing: start.x, from: $0) })
        if let container { result = keptInside(container, sides: result, startRow: start.row, endRow: end.row) }
        return result
    }

    /// The side an end at a shape as a whole (`box`, at rest) comes in at, joined to a row of a shape (`far`, at rest) that leaves
    /// by `farSide`: where their spans across overlap (one above the other), the side that row leaves by, so the line runs round
    /// the shapes' one side rather than back along the row's own shape; nil where they don't (it faces the other end).
    public static func entered(_ box: CGRect, joinedTo far: CGRect, leavingBy farSide: PartSide?) -> PartSide? {
        guard let farSide, overlap(box, far) else { return nil }
        return farSide
    }

    /// How far from `point` the way `normal` stays inside `container` less its clearance; nil for none, or a way that isn't across.
    public static func room(along normal: CGPoint, from point: CGPoint, inside container: CGRect?) -> CGFloat? {
        guard let container, abs(normal.x) > abs(normal.y) else { return nil }
        let edge = normal.x > 0 ? container.maxX - containerClearance : container.minX + containerClearance
        return max(0, (edge - point.x) * (normal.x > 0 ? 1 : -1))
    }

    /// The sides of two ends' rows, an end whose curve would run past its container's edge taking the other side where that is
    /// clear (both together, for ends sided together): the side with room inside it.
    static func keptInside(_ container: CGRect, sides: (start: PartSide?, end: PartSide?), startRow: CGRect?, endRow: CGRect?) -> (start: PartSide?, end: PartSide?) {
        func fits(_ side: PartSide, of rect: CGRect) -> Bool {
            guard let room = room(along: side.normal, from: side.point(of: rect), inside: container) else { return true }
            return room >= containerSideRoom
        }
        var result = sides
        var startOut = false, endOut = false
        if let side = sides.start, let rect = startRow { startOut = !fits(side, of: rect) }
        if let side = sides.end, let rect = endRow { endOut = !fits(side, of: rect) }
        guard startOut || endOut else { return sides }
        if let start = sides.start, let end = sides.end, let a = startRow, let b = endRow, start == end {
            // Sided together: both take the other side, where both fit there.
            if fits(start.flipped, of: a), fits(end.flipped, of: b) { result = (start.flipped, end.flipped) }
            return result
        }
        if startOut, let start = sides.start, let rect = startRow, fits(start.flipped, of: rect) { result.start = start.flipped }
        if endOut, let end = sides.end, let rect = endRow, fits(end.flipped, of: rect) { result.end = end.flipped }
        return result
    }

    /// The other side.
    public var flipped: PartSide { self == .left ? .right : .left }

    /// Its point on `rect`: the middle of that edge.
    public func point(of rect: CGRect) -> CGPoint {
        CGPoint(x: self == .right ? rect.maxX : rect.minX, y: rect.midY)
    }

    /// The way out of the part from it, a unit vector: where a curve leaves and a mark points.
    public var normal: CGPoint { CGPoint(x: self == .right ? 1 : -1, y: 0) }
}

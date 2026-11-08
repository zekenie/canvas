import CoreGraphics
import Canvas
import Foundation
import Geometry

/// An arrow's drawable geometry, resolved against where its bound shapes currently are.
///
/// Each terminal has a *handle*: a free point, or the anchor inside a bound shape (the center of
/// its bounds unless the binding is precise). The arrow follows the line or arc through the
/// handles, is clipped where it crosses a bound shape's outline, and backs off by a small gap
/// wherever there's an arrowhead. This is a port of tldraw's `getStraightArrowInfo` and
/// `getCurvedArrowInfo`, including how they handle overlapping and nested shapes.
public struct ArrowGeometry: Sendable {
    public enum Path: Sendable {
        case straight
        /// `handleArc` runs through both terminal handles and the bend point. The visible body is
        /// the stretch of it between `startT` and `endT` (0 is the start handle, 1 the end handle).
        case curved(handleArc: Arc, startT: CGFloat, endT: CGFloat)
        /// An arrow with an end at a row (a part its shape lists): a cubic leaving each end along the way out of its side (a
        /// departure from tldraw's arc, the frames' level curve). The visible body is the stretch between `startT` and `endT`,
        /// short of the curve's ends only by a head's gap at an end bound to a shape as a whole.
        case level(Cubic, startT: CGFloat, endT: CGFloat)
    }

    public private(set) var startHandle: CGPoint
    public private(set) var endHandle: CGPoint
    /// Where the visible arrow begins and ends.
    public private(set) var start: CGPoint
    public private(set) var end: CGPoint
    /// Where the bend handle sits: halfway along the visible body.
    public private(set) var middle: CGPoint
    public private(set) var path: Path
    /// Unit vector perpendicular to the line between the terminal handles; `bend` is measured along it.
    public private(set) var bendAxis: CGPoint
    /// Where the bend is measured from, along `bendAxis`: the middle of the line between the handles, or of a level arrow's
    /// curve as it is with no bend, so the bend handle's drag puts the middle where the pointer is.
    public private(set) var bendOrigin: CGPoint
    public private(set) var startArrowhead: Bool
    public private(set) var endArrowhead: Bool
    /// The side of its part each end is at, for an end bound to a part its shape lists (a row): nil for any other end.
    public private(set) var startSide: PartSide?
    public private(set) var endSide: PartSide?

    /// Gap between a bound shape's outline and an arrowhead, on top of half the stroke width.
    public static let boundGap: CGFloat = 10
    public static let minLength: CGFloat = 10
    /// Bends smaller than this draw as a straight line (the stored bend is kept).
    public static let minBend: CGFloat = 8

    /// `shape` looks up the shapes the arrow is bound to. An end bound to a shape it can't find is
    /// drawn at the origin. A bend under `minBend` draws straight: a line through a pill (`ArrowThrough`) asks for any,
    /// since its bend is worked out from the pill's place, never a person's.
    /// `markReach` is how far out along the line each end's mark reaches (`ArrowMarks.reach(of:)`): a level curve between
    /// ends too near to make a way for the marks reaches out far enough to turn clear of them.
    public init(arrow: Arrow, strokeWidth: CGFloat, minBend: CGFloat = ArrowGeometry.minBend,
                markReach: (start: CGFloat, end: CGFloat) = (0, 0), shape: (ShapeID) -> ConnectableShape?) {
        // A part named on a binding to a shape that lists none (a pill standing for the table the part is a column of): the end
        // meets that shape as a whole, at its middle, whatever anchor the binding kept; the part is Topology's and the key index's.
        var arrow = arrow
        for end in [ArrowEnd.start, .end] {
            guard var binding = arrow[end].binding, binding.part != nil, let bound = shape(binding.shapeID), bound.parts.isEmpty else { continue }
            binding.normalizedAnchor = CGPoint(x: 0.5, y: 0.5)
            binding.isPrecise = false
            binding.isExact = false
            arrow[end] = .bound(binding)
        }
        var startShape = arrow.start.binding.flatMap { binding in
            shape(binding.shapeID).map { BoundShape($0, isExact: binding.isExact) }
        }
        var endShape = arrow.end.binding.flatMap { binding in
            shape(binding.shapeID).map { BoundShape($0, isExact: binding.isExact) }
        }
        let relationship = Relationship(start: startShape, end: endShape)

        startHandle = Self.handle(
            for: arrow.start, shape: startShape,
            forcePrecise: relationship == .sameShape || relationship == .startContainsEnd
        )
        endHandle = Self.handle(
            for: arrow.end, shape: endShape,
            forcePrecise: relationship == .sameShape || relationship == .endContainsStart
        )
        startArrowhead = arrow.startArrowhead
        endArrowhead = arrow.endArrowhead
        // An end bound to a part its shape lists is at that part's side facing the other end, unclipped (a departure from
        // tldraw's: rows are met at their side). An end with no part is left exactly as above.
        let startPart = Self.part(of: arrow.start, in: startShape), endPart = Self.part(of: arrow.end, in: endShape)
        if startPart != nil || endPart != nil {
            // What each end faces: the other's part's middle (never its side, so two part ends don't hang on each other), else
            // its handle. Two parts are sided together (`PartSide.sides`): rows one above the other (stacked tables, or one
            // table's) leave one side, so a row's line widening as it is typed never flips an end across a table.
            let startX = startPart?.midX ?? startHandle.x, endX = endPart?.midX ?? endHandle.x
            let together = startPart.flatMap { start in endPart.map { PartSide.sides(start, $0) } }
            if let rect = startPart {
                let side = together?.start ?? PartSide(facing: endX, from: rect)
                (startSide, startHandle) = (side, side.point(of: rect))
                startShape?.isExact = true
            }
            if let rect = endPart {
                let side = together?.end ?? PartSide(facing: startX, from: rect)
                (endSide, endHandle) = (side, side.point(of: rect))
                endShape?.isExact = true
            }
        }

        if startPart != nil || endPart != nil {
            // A level curve: each end leaves along the way out of its side, rows' sides worked out above.
            let (startPoint, endPoint) = (startHandle, endHandle)
            let partStart = startSide.map { (point: startPoint, normal: Optional($0.normal)) }
            let partEnd = endSide.map { (point: endPoint, normal: Optional($0.normal)) }
            let s = partStart ?? Self.levelAnchor(of: arrow.start, in: startShape, handle: startPoint, toward: partEnd?.point ?? endPoint)
            let e = partEnd ?? Self.levelAnchor(of: arrow.end, in: endShape, handle: endPoint, toward: s.point)
            let chord = e.point - s.point
            bendAxis = chord.length > 0 ? chord.normalized.perpendicular : CGPoint(x: 0, y: -1)
            let clear = ArrowStyle.levelClearReach(ofMark: max(markReach.start, markReach.end))
            let reachStart = s.normal.map { Self.reach($0, from: s.point, to: e.point, clearing: clear) } ?? 0
            let reachEnd = e.normal.map { Self.reach($0, from: e.point, to: s.point, clearing: clear) } ?? 0
            let plain = Cubic(s.point, s.point + (s.normal ?? .zero) * reachStart, e.point + (e.normal ?? .zero) * reachEnd, e.point)
            bendOrigin = plain.point(at: 0.5)
            // tldraw's bend: both controls move by 4/3 of it across the chord, so the middle moves exactly by it.
            let shift = bendAxis * (arrow.bend * 4 / 3)
            let cubic = Cubic(plain.start, plain.control1 + shift, plain.control2 + shift, plain.end)
            // Only an end bound to a shape as a whole, short of an exact binding, stands a head's gap off it, along the curve.
            func gap(_ end: ArrowEnd, _ shape: BoundShape?) -> CGFloat {
                guard let shape, !shape.isExact, end == .start ? arrow.startArrowhead : arrow.endArrowhead else { return 0 }
                return ArrowGeometry.boundGap + strokeWidth / 2
            }
            let measure = cubic.measured()
            let gaps = (gap(.start, startShape), gap(.end, endShape))
            var (startT, endT): (CGFloat, CGFloat) = (0, 1)
            if gaps.0 + gaps.1 + ArrowGeometry.minLength < measure.length {
                startT = measure.parameter(atLength: gaps.0)
                endT = measure.parameter(atLength: measure.length - gaps.1)
            }
            path = .level(cubic, startT: startT, endT: endT)
            start = cubic.point(at: startT)
            end = cubic.point(at: endT)
            middle = cubic.point(at: 0.5)
            return
        }

        let chord = endHandle - startHandle
        bendAxis = chord.length > 0 ? chord.normalized.perpendicular : CGPoint(x: 0, y: -1)
        bendOrigin = (startHandle + endHandle) / 2
        let bendPoint = (startHandle + endHandle) / 2 + bendAxis * arrow.bend

        let clipping = Clipping(
            strokeWidth: strokeWidth,
            relationship: relationship,
            startArrowhead: arrow.startArrowhead,
            endArrowhead: arrow.endArrowhead
        )
        if abs(arrow.bend) >= minBend,
           let handleArc = Arc(from: startHandle, through: bendPoint, to: endHandle),
           handleArc.length.isFinite, handleArc.length > 0 {
            let (startT, endT, middle) = clipping.curved(handleArc, bendPoint: bendPoint, startShape: &startShape, endShape: &endShape)
            path = .curved(handleArc: handleArc, startT: startT, endT: endT)
            start = handleArc.point(at: startT)
            end = handleArc.point(at: endT)
            self.middle = middle
        } else {
            path = .straight
            (start, end, middle) = clipping.straight(from: startHandle, to: endHandle, startShape: &startShape, endShape: &endShape)
        }
    }

    /// Where the part an end is bound to is, when its shape lists it (shown or folded: a folded one's rect is what's shown
    /// in its place); nil for an end bound to no part, or to one its shape doesn't list, which is drawn at its stored anchor.
    private static func part(of terminal: ArrowTerminal, in shape: BoundShape?) -> CGRect? {
        guard let part = terminal.binding?.part, let shape else { return nil }
        return shape.parts.frame(part)?.rect
    }

    /// The side of its part an end is at (nil for an end bound to no part its shape lists): where a curve leaves it and a
    /// mark is drawn.
    public func partSide(at end: ArrowEnd) -> PartSide? { end == .start ? startSide : endSide }

    /// Whether it is drawn as a level curve (an end at a row its shape lists).
    public var isLevel: Bool { if case .level = path { true } else { false } }

    /// How far a level curve's end reaches out along the way out of its side before it turns, from where it is to the other
    /// end's: half the way when the other end is ahead, far less when it is behind (a C rather than an S), never under
    /// `ArrowStyle.levelMinReach`; and, with marks, when the other end is not yet `clearing` ahead (a C, or rows too near for an
    /// S), at least `clearing`, the reach that turns the curve beyond the longer mark (`ArrowStyle.levelClearReach`).
    static func reach(_ normal: CGPoint, from point: CGPoint, to other: CGPoint, clearing: CGFloat = 0) -> CGFloat {
        let along = normal.dot(other - point)
        let reach = along >= 0 ? along * ArrowStyle.levelAheadShare : ArrowStyle.levelBackReach * (-along).squareRoot()
        return max(ArrowStyle.levelMinReach, reach, along < clearing ? clearing : 0)
    }

    /// Where a level curve meets an end that isn't at a row, and the way out of the shape there: a free end its point, with no
    /// way (the curve comes straight at it); an end bound to a shape as a whole the entry facing `other` its kind gives (a
    /// table's first row), else the side of its bounds a line from its anchor to `other` leaves by, at that side's middle (on
    /// the outline, for a shape that isn't a box), or for a precise or exact binding where that line leaves the outline.
    private static func levelAnchor(of terminal: ArrowTerminal, in shape: BoundShape?, handle: CGPoint,
                                    toward other: CGPoint) -> (point: CGPoint, normal: CGPoint?) {
        guard let shape, let binding = terminal.binding else { return (handle, nil) }
        let isAimed = binding.isPrecise || binding.isExact
        if !isAimed, let entry = shape.entries.max(by: { $0.normal.dot(other - $0.point) < $1.normal.dot(other - $1.point) }) {
            return (entry.point, entry.normal)
        }
        let bounds = shape.bounds
        var direction = other - handle
        if direction.length == 0 { direction = CGPoint(x: 1, y: 0) }
        // The side the line from the anchor leaves the bounds by: across, when it runs flatter than the box's diagonal.
        let isAcross = abs(direction.x) * bounds.height >= abs(direction.y) * bounds.width
        let normal = isAcross ? CGPoint(x: direction.x >= 0 ? 1 : -1, y: 0) : CGPoint(x: 0, y: direction.y >= 0 ? 1 : -1)
        if binding.isExact { return (handle, normal) }
        if binding.isPrecise {
            let far = handle + direction.normalized * (bounds.width + bounds.height + 1)
            if let t = intersections(ofSegmentFrom: handle, to: far, withPolygon: shape.outline).min() {
                return (handle + (far - handle) * t, normal)
            }
        }
        let middle = CGPoint(x: isAcross ? (normal.x > 0 ? bounds.maxX : bounds.minX) : bounds.midX,
                             y: isAcross ? bounds.midY : (normal.y > 0 ? bounds.maxY : bounds.minY))
        return (shape.outline.count > 2 ? nearestPointOnPolygon(shape.outline, to: middle) : middle, normal)
    }

    /// Where an end is aimed, with no other end to read it against: a free end's point, a bound one's anchor in its shape (the
    /// middle of its bounds unless precise); nil for one bound to a shape that isn't there.
    public static func anchor(of terminal: ArrowTerminal, in shape: ConnectableShape?) -> CGPoint? {
        if case .bound = terminal, shape == nil { return nil }
        return handle(for: terminal, shape: shape.map { BoundShape($0, isExact: terminal.binding?.isExact ?? false) }, forcePrecise: false)
    }

    private static func handle(for terminal: ArrowTerminal, shape: BoundShape?, forcePrecise: Bool) -> CGPoint {
        switch terminal {
        case .free(let point):
            return point
        case .bound(let binding):
            guard let bounds = shape?.bounds else { return .zero }
            // Keep anchors off the exact edges so intersections stay well defined.
            let clamp = { (value: CGFloat) in min(max(value, 0.001), 0.999) }
            let anchor = binding.isPrecise || forcePrecise
                ? CGPoint(x: clamp(binding.normalizedAnchor.x), y: clamp(binding.normalizedAnchor.y))
                : CGPoint(x: 0.5, y: 0.5)
            return CGPoint(x: bounds.minX + anchor.x * bounds.width, y: bounds.minY + anchor.y * bounds.height)
        }
    }

    // MARK: - Measuring

    public func point(for handle: ArrowHandle) -> CGPoint {
        switch handle {
        case .terminal(.start): startHandle
        case .terminal(.end): endHandle
        case .middle: middle
        }
    }

    public func handlePoint(at end: ArrowEnd) -> CGPoint { end == .start ? startHandle : endHandle }
    public func visiblePoint(at end: ArrowEnd) -> CGPoint { end == .start ? start : self.end }

    public var bodyLength: CGFloat {
        switch path {
        case .straight: start.distance(to: end)
        case .curved(let arc, let startT, let endT): arc.length * abs(endT - startT)
        case .level(let cubic, let startT, let endT): cubic.trimmed(from: startT, to: endT).length
        }
    }

    /// A level arrow's visible body, between its ends; nil for any other.
    public var levelBody: Cubic? {
        guard case .level(let cubic, let startT, let endT) = path else { return nil }
        return cubic.trimmed(from: startT, to: endT)
    }

    public func distance(to point: CGPoint) -> CGFloat {
        switch path {
        case .straight: distanceToSegment(from: point, start, end)
        case .curved(let arc, let startT, let endT): arc.trimmed(from: startT, to: endT).distance(to: point)
        case .level(let cubic, let startT, let endT): cubic.trimmed(from: startT, to: endT).distance(to: point)
        }
    }

    /// The point `distance` along the visible body from its end at `end` (clamped to the body), and the way on into the arrow
    /// there, a unit vector: where a mark at that end puts its bars and circle, so they sit on the line as it curves. Placing
    /// several (`placing()`) measures a level curve once.
    public func point(_ distance: CGFloat, along end: ArrowEnd) -> (point: CGPoint, inward: CGPoint) {
        placing()(distance, end)
    }

    /// `point(_:along:)` for several points, the curve measured once.
    public func placing() -> (_ distance: CGFloat, _ end: ArrowEnd) -> (point: CGPoint, inward: CGPoint) {
        let level = levelBody?.measured()
        let length = level?.length ?? bodyLength
        return { [self] distance, end in
            guard length > 0, length.isFinite else { return (visiblePoint(at: end), inward(at: end)) }
            let d = min(max(distance, 0), length)
            let sign: CGFloat = end == .start ? 1 : -1
            switch path {
            case .straight:
                let way = inward(at: end)
                return (visiblePoint(at: end) + way * d, way)
            case .curved(let arc, let startT, let endT):
                let body = arc.trimmed(from: startT, to: endT), f = end == .start ? d / length : 1 - d / length
                return (body.point(at: f), body.tangent(at: f) * sign)
            case .level:
                guard let measure = level else { return (visiblePoint(at: end), inward(at: end)) }
                let t = measure.parameter(atLength: end == .start ? d : measure.length - d)
                return (measure.cubic.point(at: t), measure.cubic.tangent(at: t) * sign)
            }
        }
    }

    /// The visible body less the stretches of it `cuts` name, each as distances along it from its start (where a circle is
    /// drawn on the line, which the line does not run through): the body in the pieces between them.
    public func bodyPath(cuttingOut cuts: [ClosedRange<CGFloat>]) -> CGPath {
        let length = bodyLength
        guard length > 0, length.isFinite, !cuts.isEmpty else { return bodyPath }
        // The pieces kept, as distances from the start.
        var kept: [ClosedRange<CGFloat>] = []
        var from: CGFloat = 0
        for cut in cuts.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if cut.lowerBound > from { kept.append(from...cut.lowerBound) }
            from = max(from, cut.upperBound)
        }
        if from < length { kept.append(from...length) }
        let path = CGMutablePath()
        switch self.path {
        case .straight:
            for piece in kept {
                path.move(to: start.moved(toward: end, by: piece.lowerBound))
                path.addLine(to: start.moved(toward: end, by: piece.upperBound))
            }
        case .curved(let arc, let startT, let endT):
            for piece in kept {
                let t0 = startT + (endT - startT) * piece.lowerBound / length, t1 = startT + (endT - startT) * piece.upperBound / length
                path.addPath(arc.trimmed(from: min(t0, t1), to: max(t0, t1)).cgPath)
            }
        case .level:
            guard let body = levelBody else { return bodyPath }
            let measure = body.measured()
            for piece in kept {
                path.addPath(body.trimmed(from: measure.parameter(atLength: piece.lowerBound), to: measure.parameter(atLength: piece.upperBound)).cgPath)
            }
        }
        return path
    }

    /// The way along the body from its visible end at `end`, into the arrow, a unit vector: where a mark at that end points
    /// from.
    public func inward(at end: ArrowEnd) -> CGPoint {
        switch path {
        case .straight:
            return (visiblePoint(at: end.opposite) - visiblePoint(at: end)).normalized
        case .curved(let arc, let startT, let endT):
            let body = arc.trimmed(from: startT, to: endT)
            return end == .start ? body.tangent(at: 0) : body.tangent(at: 1) * -1
        case .level(let cubic, let startT, let endT):
            let body = cubic.trimmed(from: startT, to: endT)
            return end == .start ? body.tangent(at: 0) : body.tangent(at: 1) * -1
        }
    }

    /// Whether the visible body (between the clipped ends, arrowheads left out) crosses or
    /// touches the closed polygon's edges.
    public func crosses(_ polygon: [CGPoint]) -> Bool {
        switch path {
        case .straight: !intersections(ofSegmentFrom: start, to: end, withPolygon: polygon).isEmpty
        case .curved(let arc, let startT, let endT): !intersections(of: arc.trimmed(from: startT, to: endT), withPolygon: polygon).isEmpty
        case .level(let cubic, let startT, let endT): !cubic.trimmed(from: startT, to: endT).intersections(withPolygon: polygon).isEmpty
        }
    }

    /// The bend that keeps this exact curve if the terminal handles move to the visible ends
    /// named in `ends`, e.g. when the arrow is detached from its shapes.
    public func bendKeepingCurve(movingHandlesToVisibleEndsAt ends: Set<ArrowEnd>) -> CGFloat? {
        guard case .curved(let arc, let startT, let endT) = path else { return nil }
        let t0 = ends.contains(.start) ? startT : 0
        let t1 = ends.contains(.end) ? endT : 1
        let (a, b) = (arc.point(at: t0), arc.point(at: t1))
        let axis = (b - a).normalized.perpendicular
        return (arc.point(at: (t0 + t1) / 2) - (a + b) / 2).dot(axis)
    }

    // MARK: - Drawing paths

    public var bodyPath: CGPath {
        switch path {
        case .straight:
            let path = CGMutablePath()
            path.move(to: start)
            path.addLine(to: end)
            return path
        case .curved(let arc, let startT, let endT):
            return arc.trimmed(from: startT, to: endT).cgPath
        case .level(let cubic, let startT, let endT):
            return cubic.trimmed(from: startT, to: endT).cgPath
        }
    }

    /// Open chevrons at whichever ends have arrowheads.
    public func arrowheadsPath(strokeWidth: CGFloat) -> CGPath {
        let path = CGMutablePath()
        for head in arrowheads(strokeWidth: strokeWidth) {
            path.move(to: head.wing)
            path.addLine(to: head.tip)
            path.addLine(to: head.otherWing)
        }
        return path
    }

    /// Each head it has, as the three points of its chevron, in the order it is drawn: a wing, the tip, the other wing.
    public func arrowheads(strokeWidth: CGFloat) -> [(wing: CGPoint, tip: CGPoint, otherWing: CGPoint)] {
        [ArrowEnd.start, .end].filter { $0 == .start ? startArrowhead : endArrowhead }.map { end in
            let tip = visiblePoint(at: end)
            let base = arrowheadBase(at: end, strokeWidth: strokeWidth)
            return (base.rotated(around: tip, by: .pi / 6), tip, base.rotated(around: tip, by: -.pi / 6))
        }
    }

    /// The point the arrowhead's wings are swung from: back along the body from the tip by the
    /// head's length. On a curve it's measured as a chord, so the head follows the curve in.
    private func arrowheadBase(at end: ArrowEnd, strokeWidth: CGFloat) -> CGPoint {
        let length = min(max(bodyLength / 5, strokeWidth), strokeWidth * 3)
        let tip = visiblePoint(at: end)
        switch path {
        case .straight:
            return tip.moved(toward: visiblePoint(at: end.opposite), by: length)
        case .curved(let arc, let startT, let endT):
            let chordAngle = 2 * asin(min(1, length / (2 * arc.radius)))
            let step = chordAngle / abs(arc.sweep)
            return end == .start ? arc.point(at: startT + step) : arc.point(at: endT - step)
        case .level(let cubic, let startT, let endT):
            // Along the curve by its length.
            let measure = cubic.trimmed(from: startT, to: endT).measured()
            return measure.cubic.point(at: measure.parameter(atLength: end == .start ? length : measure.length - length))
        }
    }

    /// The hidden stretch of path between a terminal's handle and the visible arrow, shown as a
    /// dashed stub while the arrow is selected. `inset` keeps it clear of the handle's marker.
    public func bindingStub(at end: ArrowEnd, inset: CGFloat) -> CGPath? {
        let handle = handlePoint(at: end)
        let visible = visiblePoint(at: end)
        switch path {
        case .straight, .level:
            // A level arrow's end on a shape as a whole leaves from its side, not on the line from the anchor: the stub is
            // that line.
            let length = handle.distance(to: visible)
            guard length > inset else { return nil }
            let path = CGMutablePath()
            path.move(to: handle.moved(toward: visible, by: inset))
            path.addLine(to: visible)
            return path
        case .curved(let arc, let startT, let endT):
            let (from, to) = end == .start ? (CGFloat(0), startT) : (CGFloat(1), endT)
            let length = abs(to - from) * arc.length
            guard length > inset else { return nil }
            let trimmedFrom = from + (to - from) * (inset / length)
            return arc.trimmed(from: trimmedFrom, to: to).cgPath
        }
    }

    /// Direction of travel from a terminal's handle toward the arrow's body, for orienting markers.
    public func directionFromHandle(at end: ArrowEnd) -> CGPoint {
        switch path {
        case .straight:
            return (visiblePoint(at: end) - handlePoint(at: end)).normalized
        case .curved(let arc, _, _):
            return end == .start ? arc.tangent(at: 0) : arc.tangent(at: 1) * -1
        case .level(let cubic, _, _):
            let visible = visiblePoint(at: end), handle = handlePoint(at: end)
            if visible.distance(to: handle) > 1e-6 { return (visible - handle).normalized }
            return end == .start ? cubic.tangent(at: 0) : cubic.tangent(at: 1) * -1
        }
    }
}

// MARK: - Clipping

/// What clipping needs from a bound shape, read from it once.
private struct BoundShape {
    var id: ShapeID
    var bounds: CGRect
    var outline: [CGPoint]
    var parts: PartFrames
    var entries: [ShapeEntry]
    var isExact: Bool
    var didIntersect = false

    init(_ shape: ConnectableShape, isExact: Bool) {
        id = shape.id
        bounds = shape.bounds
        outline = shape.outline
        parts = shape.parts
        entries = shape.entries
        self.isExact = isExact
    }
}

/// The side of a part (a row) an arrow's end is at: its left or right edge, at its middle.
public enum PartSide: Hashable, Sendable {
    case left, right

    /// The side of `rect` facing `x`: the right at or past its middle (a tie, as a key from a row to another of its table, is
    /// on the right, so both ends leave one side).
    init(facing x: CGFloat, from rect: CGRect) {
        self = x >= rect.midX ? .right : .left
    }

    /// The sides of two parts an arrow joins, chosen together: rows whose spans across overlap (one above the other, as
    /// stacked tables' are, or two of one table) both leave the right, wherever their middles are, so a row made wider
    /// while it is typed keeps both ends where they were (a departure from facing each other, which an overlap would cross
    /// a table to); rows side by side each face the other.
    static func sides(_ start: CGRect, _ end: CGRect) -> (start: PartSide, end: PartSide) {
        if start.minX < end.maxX && end.minX < start.maxX { return (.right, .right) }
        return (PartSide(facing: end.midX, from: start), PartSide(facing: start.midX, from: end))
    }

    /// Its point on `rect`: the middle of that edge.
    public func point(of rect: CGRect) -> CGPoint {
        CGPoint(x: self == .right ? rect.maxX : rect.minX, y: rect.midY)
    }

    /// The way out of the part from it, a unit vector: where a curve leaves and a mark points.
    public var normal: CGPoint { CGPoint(x: self == .right ? 1 : -1, y: 0) }
}

private enum Relationship {
    case safe, sameShape, startContainsEnd, endContainsStart

    init(start: BoundShape?, end: BoundShape?) {
        guard let start, let end else {
            self = .safe
            return
        }
        if start.id == end.id {
            self = .sameShape
        } else if start.bounds.contains(end.bounds) {
            self = .startContainsEnd
        } else if end.bounds.contains(start.bounds) {
            self = .endContainsStart
        } else {
            self = .safe
        }
    }
}

private struct Clipping {
    var strokeWidth: CGFloat
    var relationship: Relationship
    var startArrowhead: Bool
    var endArrowhead: Bool

    private var minArrowLength: CGFloat { ArrowGeometry.minLength }

    /// The gap between a shape's outline and an arrowhead, or 0 where there's no gap.
    private func gap(at end: ArrowEnd, shape: BoundShape?) -> CGFloat {
        guard let shape, !shape.isExact, end == .start ? startArrowhead : endArrowhead else { return 0 }
        switch (relationship, end) {
        case (.sameShape, _), (.startContainsEnd, .start), (.endContainsStart, .end): return 0
        default: return ArrowGeometry.boundGap + strokeWidth / 2
        }
    }

    // MARK: Straight

    func straight(from a0: CGPoint, to b0: CGPoint, startShape: inout BoundShape?, endShape: inout BoundShape?) -> (CGPoint, CGPoint, CGPoint) {
        guard a0 != b0 else { return (a0, b0, a0) }
        let uAB = (b0 - a0).normalized
        var a = a0
        var b = b0

        // Each end stops where the line from the opposite handle first crosses its shape's outline.
        if let hit = clip(b0, from: a0, shape: &endShape) { b = hit }
        if let hit = clip(a0, from: b0, shape: &startShape) { a = hit }

        // Overlapping shapes: if a crossing is missing, fall back to a short stub.
        if relationship == .safe, let startShape, let endShape, !startShape.isExact, !endShape.isExact {
            if endShape.didIntersect && !startShape.didIntersect {
                a = b + uAB * minArrowLength
            } else if !endShape.didIntersect {
                b = a - uAB * minArrowLength
            }
        }

        let delta = b - a
        let u = delta.length > 0 ? delta.normalized : delta
        let didFlip = abs(u.x - uAB.x) >= 1e-4 || abs(u.y - uAB.y) >= 1e-4
        let direction: CGFloat = didFlip ? -1 : 1

        var offsetA = gap(at: .start, shape: startShape)
        var offsetB = gap(at: .end, shape: endShape)
        var minLength = minArrowLength
        if offsetA != 0 { minLength += strokeWidth / 2 }
        if offsetB != 0 { minLength += strokeWidth / 2 }

        // Too short to fit the gaps: flip them so the arrow pokes into the shapes instead.
        let trialA = a + u * (offsetA * direction)
        let trialB = b - u * (offsetB * direction)
        if trialA.distance(to: trialB) < minLength {
            if offsetA != 0 && offsetB != 0 {
                offsetA *= -1.5
                offsetB *= -1.5
            } else if offsetA != 0 {
                offsetA *= -1
            } else if offsetB != 0 {
                offsetB *= -1
            }
        }
        a = a + u * (offsetA * direction)
        b = b - u * (offsetB * direction)

        let middle: CGPoint
        if didFlip {
            if startShape != nil && endShape != nil {
                b = a + u * -minArrowLength
            }
            middle = (a0 + b0) / 2
        } else {
            middle = (a + b) / 2
        }
        return (a, b, middle)
    }

    /// Where the segment from `opposite` to `handle` crosses the shape's outline, nearest `opposite`.
    private func clip(_ handle: CGPoint, from opposite: CGPoint, shape: inout BoundShape?) -> CGPoint? {
        guard var bound = shape, !bound.isExact else { return nil }
        var hit = intersections(ofSegmentFrom: opposite, to: handle, withPolygon: bound.outline)
            .min()
            .map { opposite + (handle - opposite) * $0 }
        if hit == nil {
            // If the handle is practically on the edge, treat that as the crossing.
            let nearest = nearestPointOnPolygon(bound.outline, to: handle)
            if nearest.distance(to: handle) < 1 { hit = nearest }
        }
        guard let hit else { return nil }
        bound.didIntersect = true
        shape = bound
        return hit
    }

    // MARK: Curved

    func curved(_ arc: Arc, bendPoint: CGPoint, startShape: inout BoundShape?, endShape: inout BoundShape?) -> (CGFloat, CGFloat, CGPoint) {
        let length = arc.length
        var clippedStart: CGFloat = 0
        var clippedEnd: CGFloat = 1
        var offsetA: CGFloat = 0
        var offsetB: CGFloat = 0
        var minLength = minArrowLength

        // A curve can cross a shape's outline more than once. The start takes the crossing nearest
        // a quarter of the way along, the end the one nearest three quarters of the way from the
        // clipped start, which picks the crossings that read as leaving and entering the shapes.
        if var shape = startShape, !shape.isExact {
            let hits = intersections(of: arc, withPolygon: shape.outline)
            var t = hits.min { abs($0 - 0.25) < abs($1 - 0.25) }
            if t == nil, nearestPointOnPolygon(shape.outline, to: arc.point(at: 0)).distance(to: arc.point(at: 0)) < 1 {
                t = 0
            }
            if let t {
                clippedStart = t
                shape.didIntersect = true
                offsetA = gap(at: .start, shape: shape)
                if offsetA != 0 { minLength += strokeWidth / 2 }
            }
            startShape = shape
        }
        if var shape = endShape, !shape.isExact {
            let target = clippedStart + (1 - clippedStart) * 0.75
            let hits = intersections(of: arc, withPolygon: shape.outline).filter { $0 >= clippedStart }
            var t = hits.min { abs($0 - target) < abs($1 - target) }
            if t == nil, nearestPointOnPolygon(shape.outline, to: arc.point(at: 1)).distance(to: arc.point(at: 1)) < 1 {
                t = 1
            }
            if let t {
                clippedEnd = t
                shape.didIntersect = true
                offsetB = gap(at: .end, shape: shape)
                if offsetB != 0 { minLength += strokeWidth / 2 }
            }
            endShape = shape
        }

        // Too short to fit the gaps: flip them so the arrow pokes into the shapes instead, but
        // never past the handles.
        let trialA = arc.point(at: clippedStart + offsetA / length)
        let trialB = arc.point(at: clippedEnd - offsetB / length)
        if trialA.distance(to: trialB) < minLength {
            if offsetA != 0 && offsetB != 0 {
                offsetA *= -1.5
                offsetB *= -1.5
            } else if offsetA != 0 {
                offsetA *= -2
            } else if offsetB != 0 {
                offsetB *= -2
            }
            offsetA = max(offsetA, 0.1 - clippedStart * length)
            offsetB = max(offsetB, 0.1 - (1 - clippedEnd) * length)
        }
        var startT = clippedStart + offsetA / length
        var endT = clippedEnd - offsetB / length
        var middle: CGPoint?

        // Overlapping shapes.
        if let startShape, let endShape, !startShape.isExact, !endShape.isExact {
            if relationship == .sameShape, (endT - startT) * length < 30 {
                (startT, endT) = (0, 1)
                middle = bendPoint
            } else if relationship == .safe {
                if !startShape.didIntersect {
                    startT = 0
                }
                if !endShape.didIntersect || startT > endT {
                    // A short stub heading off the start, at most 90% of the way to the end.
                    let forwardSpan = endT > startT ? endT - startT : 2 * .pi / abs(arc.sweep) - (startT - endT)
                    endT = startT + min(0.9 * forwardSpan, minArrowLength / length)
                }
            }
        }

        if startT > endT {
            (startT, endT) = (endT, startT)
        }
        return (startT, endT, middle ?? arc.point(at: (startT + endT) / 2))
    }
}

extension Arc {
    var cgPath: CGPath {
        let path = CGMutablePath()
        path.move(to: point(at: 0))
        path.addRelativeArc(center: center, radius: radius, startAngle: startAngle, delta: sweep)
        return path
    }
}

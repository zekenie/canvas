import CoreGraphics
import Foundation

/// An arrow's drawable geometry, resolved against where its bound notes currently are.
///
/// Each terminal has a *handle*: a free point, or the anchor inside a bound note (the note's
/// center unless the binding is precise). The arrow follows the line or arc through the handles,
/// is clipped where it crosses a bound note's edge, and backs off by a small gap wherever there's
/// an arrowhead. This is a port of tldraw's `getStraightArrowInfo` and `getCurvedArrowInfo`,
/// including how they handle overlapping and nested shapes.
struct ArrowGeometry {
    enum Path {
        case straight
        /// `handleArc` runs through both terminal handles and the bend point. The visible body is
        /// the stretch of it between `startT` and `endT` (0 is the start handle, 1 the end handle).
        case curved(handleArc: Arc, startT: CGFloat, endT: CGFloat)
    }

    var startHandle: CGPoint
    var endHandle: CGPoint
    /// Where the visible arrow begins and ends.
    var start: CGPoint
    var end: CGPoint
    /// Where the bend handle sits: halfway along the visible body.
    var middle: CGPoint
    var path: Path
    /// Unit vector perpendicular to the line between the terminal handles; `bend` is measured along it.
    var bendAxis: CGPoint
    var startArrowhead: Bool
    var endArrowhead: Bool

    /// Gap between a bound note's edge and an arrowhead, on top of half the stroke width.
    static let boundGap: CGFloat = 10
    static let minLength: CGFloat = 10
    /// Bends smaller than this draw as a straight line (the stored bend is kept).
    static let minBend: CGFloat = 8

    init(arrow: Arrow, strokeWidth: CGFloat, noteFrame: (StickyNote.ID) -> CGRect?) {
        var startNote = arrow.start.binding.flatMap { binding in
            noteFrame(binding.noteID).map { BoundNote(id: binding.noteID, frame: $0, isExact: binding.isExact) }
        }
        var endNote = arrow.end.binding.flatMap { binding in
            noteFrame(binding.noteID).map { BoundNote(id: binding.noteID, frame: $0, isExact: binding.isExact) }
        }
        let relationship = Relationship(start: startNote, end: endNote)

        startHandle = Self.handle(
            for: arrow.start, note: startNote,
            forcePrecise: relationship == .sameNote || relationship == .startContainsEnd
        )
        endHandle = Self.handle(
            for: arrow.end, note: endNote,
            forcePrecise: relationship == .sameNote || relationship == .endContainsStart
        )
        startArrowhead = arrow.startArrowhead
        endArrowhead = arrow.endArrowhead

        let chord = endHandle - startHandle
        bendAxis = chord.length > 0 ? chord.normalized.perpendicular : CGPoint(x: 0, y: -1)
        let bendPoint = (startHandle + endHandle) / 2 + bendAxis * arrow.bend

        let clipping = Clipping(
            strokeWidth: strokeWidth,
            relationship: relationship,
            startArrowhead: arrow.startArrowhead,
            endArrowhead: arrow.endArrowhead
        )
        if abs(arrow.bend) >= Self.minBend,
           let handleArc = Arc(from: startHandle, through: bendPoint, to: endHandle),
           handleArc.length.isFinite, handleArc.length > 0 {
            let (startT, endT, middle) = clipping.curved(handleArc, bendPoint: bendPoint, startNote: &startNote, endNote: &endNote)
            path = .curved(handleArc: handleArc, startT: startT, endT: endT)
            start = handleArc.point(at: startT)
            end = handleArc.point(at: endT)
            self.middle = middle
        } else {
            path = .straight
            (start, end, middle) = clipping.straight(from: startHandle, to: endHandle, startNote: &startNote, endNote: &endNote)
        }
    }

    private static func handle(for terminal: ArrowTerminal, note: BoundNote?, forcePrecise: Bool) -> CGPoint {
        switch terminal {
        case .free(let point):
            return point
        case .bound(let binding):
            guard let frame = note?.frame else { return .zero }
            // Keep anchors off the exact edges so intersections stay well defined.
            let clamp = { (value: CGFloat) in min(max(value, 0.001), 0.999) }
            let anchor = binding.isPrecise || forcePrecise
                ? CGPoint(x: clamp(binding.normalizedAnchor.x), y: clamp(binding.normalizedAnchor.y))
                : CGPoint(x: 0.5, y: 0.5)
            return CGPoint(x: frame.minX + anchor.x * frame.width, y: frame.minY + anchor.y * frame.height)
        }
    }

    // MARK: - Measuring

    func point(for handle: ArrowHandle) -> CGPoint {
        switch handle {
        case .terminal(.start): startHandle
        case .terminal(.end): endHandle
        case .middle: middle
        }
    }

    func handlePoint(at end: ArrowEnd) -> CGPoint { end == .start ? startHandle : endHandle }
    func visiblePoint(at end: ArrowEnd) -> CGPoint { end == .start ? start : self.end }

    var bodyLength: CGFloat {
        switch path {
        case .straight: start.distance(to: end)
        case .curved(let arc, let startT, let endT): arc.length * abs(endT - startT)
        }
    }

    func distance(to point: CGPoint) -> CGFloat {
        switch path {
        case .straight: distanceToSegment(from: point, start, end)
        case .curved(let arc, let startT, let endT): arc.trimmed(from: startT, to: endT).distance(to: point)
        }
    }

    /// The bend that keeps this exact curve if the terminal handles move to the visible ends
    /// named in `ends`, e.g. when the arrow is detached from its notes.
    func bendKeepingCurve(movingHandlesToVisibleEndsAt ends: Set<ArrowEnd>) -> CGFloat? {
        guard case .curved(let arc, let startT, let endT) = path else { return nil }
        let t0 = ends.contains(.start) ? startT : 0
        let t1 = ends.contains(.end) ? endT : 1
        let (a, b) = (arc.point(at: t0), arc.point(at: t1))
        let axis = (b - a).normalized.perpendicular
        return (arc.point(at: (t0 + t1) / 2) - (a + b) / 2).dot(axis)
    }

    // MARK: - Drawing paths

    var bodyPath: CGPath {
        switch path {
        case .straight:
            let path = CGMutablePath()
            path.move(to: start)
            path.addLine(to: end)
            return path
        case .curved(let arc, let startT, let endT):
            return arc.trimmed(from: startT, to: endT).cgPath
        }
    }

    /// Open chevrons at whichever ends have arrowheads.
    func arrowheadsPath(strokeWidth: CGFloat) -> CGPath {
        let path = CGMutablePath()
        for end in [ArrowEnd.start, .end] where end == .start ? startArrowhead : endArrowhead {
            let tip = visiblePoint(at: end)
            let base = arrowheadBase(at: end, strokeWidth: strokeWidth)
            path.move(to: base.rotated(around: tip, by: .pi / 6))
            path.addLine(to: tip)
            path.addLine(to: base.rotated(around: tip, by: -.pi / 6))
        }
        return path
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
        }
    }

    /// The hidden stretch of path between a terminal's handle and the visible arrow, shown as a
    /// dashed stub while the arrow is selected. `inset` keeps it clear of the handle's marker.
    func bindingStub(at end: ArrowEnd, inset: CGFloat) -> CGPath? {
        let handle = handlePoint(at: end)
        let visible = visiblePoint(at: end)
        switch path {
        case .straight:
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
    func directionFromHandle(at end: ArrowEnd) -> CGPoint {
        switch path {
        case .straight:
            return (visiblePoint(at: end) - handlePoint(at: end)).normalized
        case .curved(let arc, _, _):
            return end == .start ? arc.tangent(at: 0) : arc.tangent(at: 1) * -1
        }
    }
}

// MARK: - Clipping

private struct BoundNote {
    var id: StickyNote.ID
    var frame: CGRect
    var isExact: Bool
    var didIntersect = false

    var polygon: [CGPoint] { frame.polygon }
}

private enum Relationship {
    case safe, sameNote, startContainsEnd, endContainsStart

    init(start: BoundNote?, end: BoundNote?) {
        guard let start, let end else {
            self = .safe
            return
        }
        if start.id == end.id {
            self = .sameNote
        } else if start.frame.contains(end.frame) {
            self = .startContainsEnd
        } else if end.frame.contains(start.frame) {
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

    /// The gap between a note's edge and an arrowhead, or 0 where there's no gap.
    private func gap(at end: ArrowEnd, note: BoundNote?) -> CGFloat {
        guard let note, !note.isExact, end == .start ? startArrowhead : endArrowhead else { return 0 }
        switch (relationship, end) {
        case (.sameNote, _), (.startContainsEnd, .start), (.endContainsStart, .end): return 0
        default: return ArrowGeometry.boundGap + strokeWidth / 2
        }
    }

    // MARK: Straight

    func straight(from a0: CGPoint, to b0: CGPoint, startNote: inout BoundNote?, endNote: inout BoundNote?) -> (CGPoint, CGPoint, CGPoint) {
        guard a0 != b0 else { return (a0, b0, a0) }
        let uAB = (b0 - a0).normalized
        var a = a0
        var b = b0

        // Each end stops where the line from the opposite handle first crosses its note's edge.
        if let hit = clip(b0, from: a0, note: &endNote) { b = hit }
        if let hit = clip(a0, from: b0, note: &startNote) { a = hit }

        // Overlapping notes: if a crossing is missing, fall back to a short stub.
        if relationship == .safe, let startNote, let endNote, !startNote.isExact, !endNote.isExact {
            if endNote.didIntersect && !startNote.didIntersect {
                a = b + uAB * minArrowLength
            } else if !endNote.didIntersect {
                b = a - uAB * minArrowLength
            }
        }

        let delta = b - a
        let u = delta.length > 0 ? delta.normalized : delta
        let didFlip = abs(u.x - uAB.x) >= 1e-4 || abs(u.y - uAB.y) >= 1e-4
        let direction: CGFloat = didFlip ? -1 : 1

        var offsetA = gap(at: .start, note: startNote)
        var offsetB = gap(at: .end, note: endNote)
        var minLength = minArrowLength
        if offsetA != 0 { minLength += strokeWidth / 2 }
        if offsetB != 0 { minLength += strokeWidth / 2 }

        // Too short to fit the gaps: flip them so the arrow pokes into the notes instead.
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
            if startNote != nil && endNote != nil {
                b = a + u * -minArrowLength
            }
            middle = (a0 + b0) / 2
        } else {
            middle = (a + b) / 2
        }
        return (a, b, middle)
    }

    /// Where the segment from `opposite` to `handle` crosses the note's edge, nearest `opposite`.
    private func clip(_ handle: CGPoint, from opposite: CGPoint, note: inout BoundNote?) -> CGPoint? {
        guard var bound = note, !bound.isExact else { return nil }
        var hit = intersections(ofSegmentFrom: opposite, to: handle, withPolygon: bound.polygon)
            .min()
            .map { opposite + (handle - opposite) * $0 }
        if hit == nil {
            // If the handle is practically on the edge, treat that as the crossing.
            let nearest = nearestPointOnPolygon(bound.polygon, to: handle)
            if nearest.distance(to: handle) < 1 { hit = nearest }
        }
        guard let hit else { return nil }
        bound.didIntersect = true
        note = bound
        return hit
    }

    // MARK: Curved

    func curved(_ arc: Arc, bendPoint: CGPoint, startNote: inout BoundNote?, endNote: inout BoundNote?) -> (CGFloat, CGFloat, CGPoint) {
        let length = arc.length
        var clippedStart: CGFloat = 0
        var clippedEnd: CGFloat = 1
        var offsetA: CGFloat = 0
        var offsetB: CGFloat = 0
        var minLength = minArrowLength

        // A curve can cross a note's edge more than once. The start takes the crossing nearest a
        // quarter of the way along, the end the one nearest three quarters of the way from the
        // clipped start, which picks the crossings that read as leaving and entering the notes.
        if var note = startNote, !note.isExact {
            let hits = intersections(of: arc, withPolygon: note.polygon)
            var t = hits.min { abs($0 - 0.25) < abs($1 - 0.25) }
            if t == nil, nearestPointOnPolygon(note.polygon, to: arc.point(at: 0)).distance(to: arc.point(at: 0)) < 1 {
                t = 0
            }
            if let t {
                clippedStart = t
                note.didIntersect = true
                offsetA = gap(at: .start, note: note)
                if offsetA != 0 { minLength += strokeWidth / 2 }
            }
            startNote = note
        }
        if var note = endNote, !note.isExact {
            let target = clippedStart + (1 - clippedStart) * 0.75
            let hits = intersections(of: arc, withPolygon: note.polygon).filter { $0 >= clippedStart }
            var t = hits.min { abs($0 - target) < abs($1 - target) }
            if t == nil, nearestPointOnPolygon(note.polygon, to: arc.point(at: 1)).distance(to: arc.point(at: 1)) < 1 {
                t = 1
            }
            if let t {
                clippedEnd = t
                note.didIntersect = true
                offsetB = gap(at: .end, note: note)
                if offsetB != 0 { minLength += strokeWidth / 2 }
            }
            endNote = note
        }

        // Too short to fit the gaps: flip them so the arrow pokes into the notes instead, but
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

        // Overlapping notes.
        if let startNote, let endNote, !startNote.isExact, !endNote.isExact {
            if relationship == .sameNote, (endT - startT) * length < 30 {
                (startT, endT) = (0, 1)
                middle = bendPoint
            } else if relationship == .safe {
                if !startNote.didIntersect {
                    startT = 0
                }
                if !endNote.didIntersect || startT > endT {
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

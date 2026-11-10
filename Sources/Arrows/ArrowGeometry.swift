import CoreGraphics
import Canvas
import Connections
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
    /// A level arrow's visible line: a marked end's straight stub, the curve, the other's stub (nil for any other arrow).
    public private(set) var levelLine: CubicChain?
    /// How much further out along the line than its own place each end's mark is drawn: a marked end fanned into a row too short
    /// to hold its neighbors' bars apart stands its marks past theirs (`ArrowStyle.fanMarkStagger`); 0 for any other.
    public private(set) var markOffset: (start: CGFloat, end: CGFloat) = (0, 0)
    /// How long each end's straight stub is, as drawn (after the container's and a narrow gap's cuts); 0 for any other arrow.
    public private(set) var stubLengths: (start: CGFloat, end: CGFloat) = (0, 0)

    /// Gap between a bound shape's outline and an arrowhead, on top of half the stroke width.
    public static let boundGap: CGFloat = 10
    public static let minLength: CGFloat = 10
    /// Bends smaller than this draw as a straight line (the stored bend is kept).
    public static let minBend: CGFloat = 8

    /// `shape` looks up the shapes the arrow is bound to. An end bound to a shape it can't find is
    /// drawn at the origin. A bend under `minBend` draws straight: a line through a pill (`ArrowThrough`) asks for any,
    /// since its bend is worked out from the pill's place, never a person's.
    /// `markReach` is how far out along the line each end's mark reaches (`ArrowMarks.reach(of:)`): a level curve's marked end
    /// leaves straight for that and a clearance (`ArrowStyle.levelStub`), so its mark lies level, and curves after.
    /// `spread` is how the arrow is drawn among others sharing its path (`ArrowSpread`): bowed by a slot, fanned at an end, come
    /// in at a row of a shape it is bound to as a whole.
    public init(arrow: Arrow, strokeWidth: CGFloat, minBend: CGFloat = ArrowGeometry.minBend,
                markReach: (start: CGFloat, end: CGFloat) = (0, 0), spread: ArrowSpread = ArrowSpread(), shape: (ShapeID) -> ConnectableShape?) {
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
        // An end bound to a shape as a whole that the spread brings in at a row: that row's sides are its entries.
        for (end, entry) in [(ArrowEnd.start, spread.startEntry), (.end, spread.endEntry)] {
            guard let entry else { continue }
            if end == .start, let rect = startShape?.parts.frame(entry)?.rect { startShape?.entries = ShapeEntry.sides(of: rect) }
            if end == .end, let rect = endShape?.parts.frame(entry)?.rect { endShape?.entries = ShapeEntry.sides(of: rect) }
        }
        let bend = arrow.bend + spread.bend

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
            // its handle. Two parts are sided together (`PartSide.sides`), by their shapes' boxes at rest: tables one above the
            // other (or one table's rows) leave one side, so a row's line widening as it is typed never flips an end across a
            // table, in a stack or side by side.
            // One rule, Connections' `PartSide.drawn`, which the bundles side a row end by too.
            let sides = PartSide.drawn(start: (startPart, startShape?.restBounds, startPart?.midX ?? startHandle.x),
                                       end: (endPart, endShape?.restBounds, endPart?.midX ?? endHandle.x),
                                       container: Self.sharedContainer(startShape, endShape))
            if let rect = startPart, let side = sides.start {
                (startSide, startHandle) = (side, side.point(of: rect))
                startShape?.isExact = true
            }
            if let rect = endPart, let side = sides.end {
                (endSide, endHandle) = (side, side.point(of: rect))
                endShape?.isExact = true
            }
        }

        if startPart != nil || endPart != nil {
            // A level curve: each end leaves along the way out of its side, rows' sides worked out above.
            let (startPoint, endPoint) = (startHandle, endHandle)
            let partStart = startSide.map { (point: startPoint, normal: Optional($0.normal)) }
            let partEnd = endSide.map { (point: endPoint, normal: Optional($0.normal)) }
            // An end at a shape as a whole, joined to a row of a shape whose span across overlaps its own (one above the other), comes
            // in at the side that row leaves by, as two rows are sided together: the line runs round the shapes' one side, not back
            // along the row's own shape.
            func together(with side: PartSide?, _ other: BoundShape?, _ shape: BoundShape?) -> CGPoint? {
                guard let other, let shape else { return nil }
                return PartSide.entered(shape.restBounds, joinedTo: other.restBounds, leavingBy: side)?.normal
            }
            var s = partStart ?? Self.levelAnchor(of: arrow.start, in: startShape, handle: startPoint, toward: partEnd?.point ?? endPoint,
                                                  preferring: together(with: endSide, endShape, startShape))
            var e = partEnd ?? Self.levelAnchor(of: arrow.end, in: endShape, handle: endPoint, toward: s.point,
                                                preferring: together(with: startSide, startShape, endShape))
            // A marked end leaves straight along its way out for as far as its mark reaches and its clearance (`levelStub`), so the
            // mark lies level whatever the curve does after (a fan's turn, a C's, rows far across): the curve starts at the stub's end.
            var stubs = (start: s.normal == nil ? 0 : ArrowStyle.levelStub(ofMark: markReach.start),
                         end: e.normal == nil ? 0 : ArrowStyle.levelStub(ofMark: markReach.end))
            // Fanned ends: each comes in at an angle of its own; a marked one comes in level and apart along its side, and turns
            // after its stub.
            var turns = (start: s.normal, end: e.normal)
            // Marks staggered along a stub only where the line has the room for the longer stub, a curve and the other end's stub
            // (else the stub is cut short and the marks land on the turn): ends facing each other across a narrow gap spread across
            // the row instead.
            let staggers: Bool = {
                guard let a = s.normal, let b = e.normal, a.dot(b) < -0.5 else { return true }
                let gap = a.dot(e.point - s.point)
                let levels = CGFloat(min(ArrowStyle.fanMarkStaggerLevels, max(spread.startFanCount, spread.endFanCount) - 1))
                return gap >= stubs.start + stubs.end + levels * ArrowStyle.fanMarkStagger + ArrowStyle.levelMinReach * 2
            }()
            let faraway = (start: e.point, end: s.point)
            // A nudge: how far out a fanned mark stands with no room to stagger, so two keys' bars into one row never stand end to end.
            var nudges: (start: CGFloat, end: CGFloat) = (0, 0)
            if let fan = spread.startFan {
                let fanned = Self.fanned(s, by: fan, count: spread.startFanCount, marked: stubs.start > 0, staggers: staggers, toward: faraway.start, part: startPart)
                (s, turns.start) = (fanned.anchor, fanned.turn)
                stubs.start += fanned.stagger + fanned.nudge
                markOffset.start = fanned.stagger + fanned.nudge
                nudges.start = fanned.nudge
            }
            if let fan = spread.endFan {
                let fanned = Self.fanned(e, by: fan, count: spread.endFanCount, marked: stubs.end > 0, staggers: staggers, toward: faraway.end, part: endPart)
                (e, turns.end) = (fanned.anchor, fanned.turn)
                stubs.end += fanned.stagger + fanned.nudge
                markOffset.end = fanned.stagger + fanned.nudge
                nudges.end = fanned.nudge
            }
            // A parted end (a row's connections to different places, their pills stacked out from the row): moved along its side within
            // its row's band, and straight for as far as its pill sits (`ArrowSpread.startStub`), so the pill stays level with its row.
            if spread.startShift != 0 { s = Self.moved(s, by: spread.startShift, steps: spread.startSteps, keeping: spread.startKeep, part: startPart) }
            if spread.endShift != 0 { e = Self.moved(e, by: spread.endShift, steps: spread.endSteps, keeping: spread.endKeep, part: endPart) }
            if s.normal != nil { stubs.start = max(stubs.start, spread.startStub) }
            if e.normal != nil { stubs.end = max(stubs.end, spread.endStub) }
            let chord = e.point - s.point
            bendAxis = chord.length > 0 ? chord.normalized.perpendicular : CGPoint(x: 0, y: -1)
            // A slot's arrows leave and meet their ends a little apart along the side too, each the way its bow takes the line
            // near that end, so they nest rather than cross (an S: across the chord; a C: in toward the other end, or out).
            if spread.slotShift != 0 {
                let (start, end) = (s.point, e.point)
                s = Self.shifted(s, by: spread.slotShift, toward: end, bowing: bendAxis, part: startPart)
                e = Self.shifted(e, by: spread.slotShift, toward: start, bowing: bendAxis, part: endPart)
                let chord = e.point - s.point
                if chord.length > 0 { bendAxis = chord.normalized.perpendicular }
            }
            if startPart != nil { startHandle = s.point }
            if endPart != nil { endHandle = e.point }
            // Inside a container both ends are in, a stub no further than leaves the least curve after it room inside (the mark's
            // reach folded in before the container's cut: in a database too tight for both, the line stays in and the mark may lie
            // partly on the turn, as a best effort).
            let container = Self.sharedContainer(startShape, endShape)
            func inside(_ stub: CGFloat, _ anchor: (point: CGPoint, normal: CGPoint?)) -> CGFloat {
                guard let normal = anchor.normal, let room = Self.room(along: normal, from: anchor.point, inside: container) else { return stub }
                return min(stub, max(0, room - ArrowStyle.levelMinReach / 2 * 0.75))
            }
            (stubs.start, stubs.end) = (inside(stubs.start, s), inside(stubs.end, e))
            // Ends facing each other with too narrow a gap for both stubs and a middle: the stubs are shortened, together, to leave
            // the middle `levelMinReach` (or nothing, rows nearer than that), never past each other.
            // What is cut first is the room past each one's own mark (its reach, how far out it stands and its clearance), so the marks
            // stay on their stubs where the gap holds them (UX walk 5 tables-1: a circle cut short at 25.5 lay on the turn); a gap too
            // narrow even for that shortens what is left of them together.
            if let a = s.normal, let b = e.normal, a.dot(b) < -0.5, stubs.start + stubs.end > 0 {
                let gap = a.dot(e.point - s.point), wanted = stubs.start + stubs.end
                let room = max(0, gap - min(ArrowStyle.levelMinReach, max(gap, 0) / 2))
                if wanted > room {
                    func least(_ stub: CGFloat, _ reach: CGFloat, _ offset: CGFloat) -> CGFloat {
                        reach > 0 ? min(stub, reach + offset + ArrowStyle.levelMarkClearance) : 0
                    }
                    let leasts = (least(stubs.start, markReach.start, markOffset.start), least(stubs.end, markReach.end, markOffset.end))
                    let held = leasts.0 + leasts.1
                    if held < room {
                        let share = (room - held) / (wanted - held)
                        stubs = (leasts.0 + (stubs.start - leasts.0) * share, leasts.1 + (stubs.end - leasts.1) * share)
                    } else {
                        stubs = held > 0 ? (leasts.0 * room / held, leasts.1 * room / held) : (0, 0)
                    }
                }
            }
            // A staggered mark stands no further out than its stub holds it, its own reach and its clearance included: where a database's
            // edge or a narrow gap cut the stub, it would lie on the turn (review U12-C6). A nudge is a few points, and may stand to the
            // stub's very end (the curve after it leaves level).
            func offset(_ offset: CGFloat, nudge: CGFloat, stub: CGFloat, reach: CGFloat) -> CGFloat {
                max(0, min(offset, max(stub - reach - ArrowStyle.levelMarkClearance, min(nudge, stub - reach))))
            }
            markOffset.start = offset(markOffset.start, nudge: nudges.start, stub: stubs.start, reach: markReach.start)
            markOffset.end = offset(markOffset.end, nudge: nudges.end, stub: stubs.end, reach: markReach.end)
            stubLengths = stubs
            let from = s.point + (s.normal ?? .zero) * stubs.start, to = e.point + (e.normal ?? .zero) * stubs.end
            // Each end's curve reaches out along its way from its stub's end; inside a container both ends are in, no further than
            // keeps the curve inside it, as a best effort.
            var reachStart = turns.start.map { Self.reach($0, from: from, to: to, inside: container) } ?? 0
            var reachEnd = turns.end.map { Self.reach($0, from: to, to: from, inside: container) } ?? 0
            // Never behind its own start: where the ends face each other, neither reach goes past the way between them, so the
            // middle runs one way across (the reaches together no more than the gap and a little, a cubic's x monotone).
            if let a = turns.start, let b = turns.end, a.dot(b) < 0 {
                let gap = max(0, a.dot(to - from))
                (reachStart, reachEnd) = (min(reachStart, gap), min(reachEnd, gap))
            }
            // In a narrow gap between rows facing each other across it, every line's middle is near upright, and lines between the same
            // two shapes would run on top of each other there (UX walk 4 tables-1): each turns at a place of its own across the gap,
            // by where it meets the shape on the right, so lines whose ends keep their order never cross and those that swap cross once.
            if let a = turns.start, let b = turns.end, a.dot(b) < -0.99, abs(a.x) > 0.99, let startShape, let endShape {
                let gap = a.dot(to - from)
                if gap > 0, gap < ArrowStyle.narrowGap {
                    let rightIsEnd = a.x > 0
                    let (left, right) = rightIsEnd ? (from, to) : (to, from)
                    let bounds = (rightIsEnd ? endShape : startShape).restBounds
                    // By its place among the lines between the same two shapes where it is known (their middles a column apart at
                    // least, whatever the shape's size), else by where it meets the shape (review U12-E8).
                    var rank = bounds.height > 0 ? min(max((right.y - bounds.minY) / bounds.height, 0), 1) : 0.5
                    if let run = spread.run, run.count > 1, run.end == (rightIsEnd ? .end : .start) { rank = CGFloat(run.index) / CGFloat(run.count - 1) }
                    // Going down, the line to the lower row turns first; going up, the one to the higher row.
                    let share = right.y >= left.y ? 1 - rank : rank
                    // The columns: `narrowTurnMargin` of the gap in from either side, and past the farthest mark of every line between the
                    // two shapes at either side and its clearance (UX walk 5 tables-1: turned at a column inside another key's circle, a line
                    // ran through it), measured from the left side; spread in what is left, or, with no room, past the left side's marks.
                    let sides = a.dot(e.point - s.point)
                    let own = (start: markReach.start > 0 ? markReach.start + markOffset.start : 0, end: markReach.end > 0 ? markReach.end + markOffset.end : 0)
                    let marks = (start: max(own.start, spread.startRunReach), end: max(own.end, spread.endRunReach))
                    let (leftMarks, rightMarks) = rightIsEnd ? (marks.start, marks.end) : (marks.end, marks.start)
                    let leftStub = rightIsEnd ? stubs.start : stubs.end
                    let clear = ArrowStyle.levelMarkClearance
                    var low = gap * ArrowStyle.narrowTurnMargin, high = gap * (1 - ArrowStyle.narrowTurnMargin)
                    if leftMarks > 0 { low = max(low, leftMarks + clear - leftStub) }
                    if rightMarks > 0 { high = min(high, sides - rightMarks - clear - leftStub) }
                    // Never one column for the run, nor columns under a stroke and a gap apart: where what is left can't hold them, the range
                    // widens toward the side with more room, and where not even the gap can, it is the margins' (UX walk 5 review E1: a 50
                    // gap put three lines on one column, on the crow's feet).
                    let count = spread.run.flatMap { $0.count > 1 && $0.end == (rightIsEnd ? .end : .start) ? $0.count : nil } ?? 1
                    let needed = CGFloat(count - 1) * ArrowStyle.narrowTurnSeparation
                    if count > 1, high - low < needed {
                        let margins = (gap * ArrowStyle.narrowTurnMargin, gap * (1 - ArrowStyle.narrowTurnMargin))
                        let (roomRight, roomLeft) = (margins.1 - max(low, margins.0), min(high, margins.1) - margins.0)
                        if roomRight >= needed, roomRight >= roomLeft || roomLeft < needed { (low, high) = (max(low, margins.0), max(low, margins.0) + needed) }
                        else if roomLeft >= needed { (low, high) = (min(high, margins.1) - needed, min(high, margins.1)) }
                        else { (low, high) = margins }
                    }
                    let turn = high >= low ? low + (high - low) * share : min(low, gap)
                    (reachStart, reachEnd) = rightIsEnd ? (turn, gap - turn) : (gap - turn, turn)
                }
            }
            let plain = Cubic(from, from + (turns.start ?? .zero) * reachStart, to + (turns.end ?? .zero) * reachEnd, to)
            // A slot's bow moves where the bend is measured from with it, so the bend handle's drag still puts the middle where
            // the pointer is.
            bendOrigin = plain.point(at: 0.5) + bendAxis * spread.bend
            // tldraw's bend: both controls move by 4/3 of it across the chord, so the middle moves exactly by it.
            let shift = bendAxis * (bend * 4 / 3)
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
            // The line drawn: the stubs, and the curve between them less a head's gap (only at an end with no stub).
            let line = CubicChain([stubs.start > 0 ? [CubicChain.line(from: s.point, to: from)] : [], [cubic.trimmed(from: startT, to: endT)],
                                   stubs.end > 0 ? [CubicChain.line(from: to, to: e.point)] : []].flatMap { $0 })
            levelLine = line
            start = line.start
            end = line.end
            self.middle = cubic.point(at: 0.5)
            return
        }

        let chord = endHandle - startHandle
        bendAxis = chord.length > 0 ? chord.normalized.perpendicular : CGPoint(x: 0, y: -1)
        bendOrigin = (startHandle + endHandle) / 2 + bendAxis * spread.bend
        let bendPoint = (startHandle + endHandle) / 2 + bendAxis * bend

        let clipping = Clipping(
            strokeWidth: strokeWidth,
            relationship: relationship,
            startArrowhead: arrow.startArrowhead,
            endArrowhead: arrow.endArrowhead
        )
        if abs(bend) >= minBend,
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
    /// `ArrowStyle.levelMinReach`; inside a container both ends are in, no further than keeps the curve inside its edge (a
    /// cubic bows out by at most 3/4 of its control's reach), as a best effort, never under half the least reach.
    static func reach(_ normal: CGPoint, from point: CGPoint, to other: CGPoint, inside container: CGRect? = nil) -> CGFloat {
        let along = normal.dot(other - point)
        let reach = along >= 0 ? along * ArrowStyle.levelAheadShare : ArrowStyle.levelBackReach * (-along).squareRoot()
        let wanted = max(ArrowStyle.levelMinReach, reach)
        guard let room = room(along: normal, from: point, inside: container) else { return wanted }
        return min(wanted, max(ArrowStyle.levelMinReach / 2, room / 0.75))
    }

    /// How far from `point` the way `normal` stays inside `container` less its clearance (Connections' `PartSide.room`).
    static func room(along normal: CGPoint, from point: CGPoint, inside container: CGRect?) -> CGFloat? {
        PartSide.room(along: normal, from: point, inside: container)
    }

    /// The container both ends' shapes are in, when it's one: its bounds.
    private static func sharedContainer(_ start: BoundShape?, _ end: BoundShape?) -> CGRect? {
        guard let a = start?.container, let b = end?.container, a == b else { return nil }
        return a
    }

    /// An end moved `shift` along its side within its part's band where it has one, the way the arrow's bow (`bowing`, times
    /// the sign of `shift`) takes the line near that end: across the chord, for an end the bow moves sideways (an S), so two
    /// slots' ends keep the order of their middles whichever way they run; else (a C, the chord along the side) toward the other
    /// end for a bow back against the way out (the loop drawn in) and away for one out along it, so slots nest.
    private static func shifted(_ anchor: (point: CGPoint, normal: CGPoint?), by shift: CGFloat, toward other: CGPoint, bowing axis: CGPoint,
                                part: CGRect?) -> (point: CGPoint, normal: CGPoint?) {
        guard let normal = anchor.normal else { return anchor }
        let across = abs(normal.x) >= abs(normal.y) ? CGPoint(x: 0, y: 1) : CGPoint(x: 1, y: 0)
        let sideways = across.dot(axis), outward = axis.dot(normal)
        let sign: CGFloat
        if abs(sideways) >= abs(outward) {
            sign = sideways >= 0 ? 1 : -1
        } else {
            let way = across.dot(other - anchor.point)
            sign = (outward < 0 ? 1 : -1) * (way >= 0 ? 1 : -1)
        }
        let band = part.map { (abs(across.y) > 0 ? $0.height : $0.width) * 0.4 } ?? abs(shift)
        return (anchor.point + across * (sign * max(-band, min(band, shift))), normal)
    }

    /// A level curve's end fanned among `count` that come into one place, and the way its curve leaves: turned by `spread` (-1
    /// the first, 1 the last) of the fan's angle, the first coming in from above (or the left). A marked end keeps its way out
    /// level, its curve too (a turn after its stub made two keys' middles different shapes, and they crossed), and is moved along
    /// its side instead, `fanMarkSpacing` from the next (a bar's height and a gap), each in a slice of the row of its own at most
    /// (`part`); where the row is too short for that, each one's stub is `fanMarkStagger` longer than its neighbor's on one side
    /// (`stagger`), its marks with it, so they stand past it: the upper of two whose lines run on down to the far end (`toward`)
    /// below is the longer, the lower of two that run up, so the one that turns first never crosses the longer stub (review U12-C2),
    /// in at most `fanMarkStaggerLevels` steps. Where the line
    /// has no room for that (`staggers` false), they spread across the row instead, the outermost `fanMarkEdge` in from its edges, and
    /// each place's marks stand `fanMarkNudge` further out than the one before, three columns round (`nudge`), so their bars never line up end to end.
    private static func fanned(_ anchor: (point: CGPoint, normal: CGPoint?), by spread: CGFloat, count: Int, marked: Bool, staggers: Bool = true,
                               toward far: CGPoint? = nil, part: CGRect?) -> (anchor: (point: CGPoint, normal: CGPoint?), turn: CGPoint?, stagger: CGFloat, nudge: CGFloat) {
        guard let normal = anchor.normal else { return (anchor, nil, 0, 0) }
        let across = abs(normal.x) >= abs(normal.y) ? CGPoint(x: 0, y: 1) : CGPoint(x: 1, y: 0)
        let half = min(ArrowStyle.fanSpread, CGFloat(max(count - 1, 0)) * ArrowStyle.fanStep) / 2
        let turned = (normal + across * tan(spread * half)).normalized
        guard marked else { return ((anchor.point, turned), turned, 0, 0) }
        // Each in a slice of the row of its own, at the slice's middle: the outermost a half slice in from the row's edges, never on
        // the line between two rows.
        let gaps = CGFloat(max(count - 1, 1)), wanted = gaps * ArrowStyle.fanMarkSpacing
        let size = part.map { abs(across.y) > 0 ? $0.height : $0.width }
        let room = size.map { staggers ? $0 * gaps / CGFloat(max(count, 2)) : max(0, $0 - 2 * ArrowStyle.fanMarkEdge) } ?? wanted
        let span = min(wanted, room)
        // Its place among them, 0 the first.
        let place = Int(((spread + 1) / 2 * gaps).rounded())
        let down = far.map { ($0 - anchor.point).dot(across) > 0 } ?? false
        let depth = min(down ? Int(gaps) - place : place, ArrowStyle.fanMarkStaggerLevels)
        let crowded = span < wanted - 0.5
        let stagger = staggers && crowded ? CGFloat(depth) * ArrowStyle.fanMarkStagger : 0
        // Spread across a row too short to hold their bars apart, with no room to stagger: every other one's marks a nudge out, so no
        // two bars stand end to end in one column (UX walk 5 tables-4-2: 3 apart, they read as one long stroke).
        let nudge = !staggers && crowded ? CGFloat(place % ConnectionBundle.RunMarks.nudgeColumns) * ArrowStyle.fanMarkNudge : 0
        return ((anchor.point + across * (spread * span / 2), normal), normal, stagger, nudge)
    }

    /// An end moved along its side to its place among `steps` + 1 (`place`, steps from the middle one, down or right positive),
    /// `partingLineSpacing` a step or as many as its part's inner band holds (`ArrowStyle.partingBand` of it either way, and no
    /// further than keeps something `keep` tall on the line inside it: a pill), so four lines leave a short row on four points, not
    /// two, and the outermost well inside the row, never on the line between two rows (UX walk 5 connect-1: at 0.4 of a 24 row,
    /// three lines put the outer ones 2.4 from its edges, where they read as the row above's).
    private static func moved(_ anchor: (point: CGPoint, normal: CGPoint?), by place: CGFloat, steps: CGFloat, keeping keep: CGFloat,
                              part: CGRect?) -> (point: CGPoint, normal: CGPoint?) {
        guard let normal = anchor.normal else { return anchor }
        let across = abs(normal.x) >= abs(normal.y) ? CGPoint(x: 0, y: 1) : CGPoint(x: 1, y: 0)
        var spacing = ArrowStyle.partingLineSpacing
        var band = abs(place) * spacing
        if let rect = part {
            let size = abs(across.y) > 0 ? rect.height : rect.width
            band = min(size * ArrowStyle.partingBand, keep > 0 ? max(0, (size - keep) / 2) : .infinity)
            if steps > 0 { spacing = min(spacing, 2 * band / steps) }
        }
        return (anchor.point + across * max(-band, min(band, place * spacing)), normal)
    }

    /// Where a level curve meets an end that isn't at a row, and the way out of the shape there: a free end its point, with no
    /// way (the curve comes straight at it); an end bound to a shape as a whole the entry facing `other` its kind gives (a
    /// table's first row), else the side of its bounds a line from its anchor to `other` leaves by, at that side's middle (on
    /// the outline, for a shape that isn't a box), or for a precise or exact binding where that line leaves the outline.
    /// `preferring`: the way out an entry takes when the other end's row is sided with it (`ArrowGeometry.init`), if it has one.
    private static func levelAnchor(of terminal: ArrowTerminal, in shape: BoundShape?, handle: CGPoint,
                                    toward other: CGPoint, preferring: CGPoint? = nil) -> (point: CGPoint, normal: CGPoint?) {
        guard let shape, let binding = terminal.binding else { return (handle, nil) }
        let isAimed = binding.isPrecise || binding.isExact
        if !isAimed, let entry = preferring.flatMap({ way in shape.entries.first { $0.normal == way } })
            ?? shape.entries.max(by: { $0.normal.dot(other - $0.point) < $1.normal.dot(other - $1.point) }) {
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
        case .level: levelLine?.length ?? 0
        }
    }

    /// A level arrow's visible body, between its ends (its stubs and its curve); nil for any other.
    public var levelBody: CubicChain? { levelLine }

    public func distance(to point: CGPoint) -> CGFloat {
        switch path {
        case .straight: distanceToSegment(from: point, start, end)
        case .curved(let arc, let startT, let endT): arc.trimmed(from: startT, to: endT).distance(to: point)
        case .level: levelLine?.distance(to: point) ?? .infinity
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
                return (measure.chain.point(at: t), measure.chain.tangent(at: t) * sign)
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
        case .level:
            guard let body = levelLine else { return (visiblePoint(at: end.opposite) - visiblePoint(at: end)).normalized }
            return end == .start ? body.tangent(at: 0) : body.tangent(at: 1) * -1
        }
    }

    /// Whether the visible body (between the clipped ends, arrowheads left out) crosses or
    /// touches the closed polygon's edges.
    public func crosses(_ polygon: [CGPoint]) -> Bool {
        switch path {
        case .straight: !intersections(ofSegmentFrom: start, to: end, withPolygon: polygon).isEmpty
        case .curved(let arc, let startT, let endT): !intersections(of: arc.trimmed(from: startT, to: endT), withPolygon: polygon).isEmpty
        case .level: !(levelLine?.intersections(withPolygon: polygon).isEmpty ?? true)
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
        case .level:
            return levelLine?.cgPath ?? CGMutablePath()
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
        case .level:
            // Along the curve by its length.
            guard let measure = levelLine?.measured() else { return tip }
            return measure.chain.point(at: measure.parameter(atLength: end == .start ? length : measure.length - length))
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
        case .level:
            let visible = visiblePoint(at: end), handle = handlePoint(at: end)
            if visible.distance(to: handle) > 1e-6 { return (visible - handle).normalized }
            return inward(at: end)
        }
    }
}

// MARK: - Clipping

/// What clipping needs from a bound shape, read from it once.
private struct BoundShape {
    var id: ShapeID
    var bounds: CGRect
    var restBounds: CGRect
    var outline: [CGPoint]
    var parts: PartFrames
    var entries: [ShapeEntry]
    var container: CGRect?
    var isExact: Bool
    var didIntersect = false

    init(_ shape: ConnectableShape, isExact: Bool) {
        id = shape.id
        bounds = shape.bounds
        restBounds = shape.restBounds
        outline = shape.outline
        parts = shape.parts
        entries = shape.entries
        container = shape.container
        self.isExact = isExact
    }
}

/// How an arrow is drawn among others sharing its path (Connections' `ConnectionBundle`, as Arrows reads it): bowed by a slot
/// (`bend`, added to its own), fanned at an end (`startFan`, `endFan`: -1 the first of the fan to 1 the last, of a count), come in
/// at a row of a shape it's bound to as a whole (`startEntry`, `endEntry`). Pure; nothing is stored.
public struct ArrowSpread: Hashable, Sendable {
    public var bend: CGFloat = 0
    /// How far a slot's ends move along their sides, world units (0 for none).
    public var slotShift: CGFloat = 0
    public var startFan: CGFloat?
    public var startFanCount = 1
    public var endFan: CGFloat?
    public var endFanCount = 1
    public var startEntry: PartID?
    public var endEntry: PartID?
    /// A parted end's place among its row's connections to different places (steps from the middle one, down or right positive,
    /// `startSteps` from the first to the last) and the least straight stub it leaves on: what keeps them apart as they leave it,
    /// each pill on its own line in the row's band, `partingLineSpacing` a step or as many as the band holds.
    public var startShift: CGFloat = 0
    public var endShift: CGFloat = 0
    public var startSteps: CGFloat = 0
    public var endSteps: CGFloat = 0
    /// How tall what sits on that end's line by its row is (its pill), kept inside the row as the end moves: 0 for nothing.
    public var startKeep: CGFloat = 0
    public var endKeep: CGFloat = 0
    public var startStub: CGFloat = 0
    public var endStub: CGFloat = 0
    /// Its place among the connections between its two shapes (Connections' `ConnectionBundle.run`), what a narrow gap turns it at.
    public var run: ConnectionBundle.Fan?
    /// How far out from each end's shape the marks of those connections reach at that shape's side (the farthest, a nudge included):
    /// what a narrow gap's turns keep clear of. 0 for none.
    public var startRunReach: CGFloat = 0
    public var endRunReach: CGFloat = 0

    public init() {}
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

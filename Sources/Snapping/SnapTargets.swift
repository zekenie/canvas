import CoreGraphics
import Geometry

/// One of the canvas's two axes. A guide's axis is the one whose coordinate lines things up (`.x`:
/// the same x, a vertical line), or along which spaces are equal (`.x`: side by side).
public enum SnapAxis: Sendable, Hashable, CaseIterable {
    case x, y

    var across: SnapAxis { self == .x ? .y : .x }
}

/// What a drag shows of how what it moves lines up with the shapes around it, in world units.
public enum SnapGuide: Equatable, Sendable {
    /// Edges or middles at `position` along `axis` (the same x, for `.x`): a line through `points`,
    /// the corners and centers on it (tldraw's snap points), with a ✕ at each.
    case alignment(SnapAxis, at: CGFloat, points: [CGPoint])
    /// Spaces of one length one after another along `axis` (side by side, for `.x`).
    case spacing(SnapAxis, gaps: [SnapGap])
}

/// One of the spaces a spacing guide shows: from an edge at `start` along its axis to the next at
/// `end`, each reaching across the axis as far as its shape does.
public struct SnapGap: Equatable, Sendable {
    public var start: CGFloat
    public var startSpan: ClosedRange<CGFloat>
    public var end: CGFloat
    public var endSpan: ClosedRange<CGFloat>

    public init(start: CGFloat, startSpan: ClosedRange<CGFloat>, end: CGFloat, endSpan: ClosedRange<CGFloat>) {
        self.start = start
        self.startSpan = startSpan
        self.end = end
        self.endSpan = endSpan
    }
}

/// A moved rect, snapped (`SnapTargets.snap`).
public struct Snap: Equatable, Sendable {
    /// How far to move it: the delta asked about, but on an axis where it snapped.
    public var delta: CGPoint
    /// Everything that lines up exactly once it's there.
    public var guides: [SnapGuide]
}

/// The frames a drag may snap to, kept so that snapping a rect to them costs about as much however
/// many there are: each frame's edges and middle along either axis, in order, and the spaces between
/// frames next to each other along either axis (tldraw's gaps, but only between neighbors, so there
/// are at most two for each frame, not one for every pair). Pure: world units in and out.
///
/// A rect snaps along an axis to the nearest, within the threshold, of (tldraw's bounds snapping):
/// one of its edges or its middle to one of a frame's; its middle to the middle of the space between
/// two neighbors, when it fits there (centering it); and its far edge to where a space as long as the
/// one between two neighbors would begin before them, or its near edge to where it would end after
/// them (repeating the space). A space counts while the rect shares the stretch across the axis that
/// the two share by more than the threshold (tldraw's asks for any of it), so snapping along the other
/// axis never takes it out of that stretch, where its guide wouldn't show.
public struct SnapTargets: Sendable {
    public let frames: [CGRect]
    private let lines: [SnapAxis: [Line]]
    private let neighbors: [SnapAxis: Neighbors]

    /// Coordinates this close are the same: what floating point leaves of a shape snapped exactly.
    public static let tolerance: CGFloat = 1e-6
    /// How many frames along an axis past a frame's edge its nearest neighbor is looked for among: a
    /// frame whose nearest one is further (a staircase of frames that don't overlap across) has none,
    /// so a board zoomed out over thousands of them costs a bounded search.
    static let neighborReach = 64

    /// Frames that aren't finite are left out.
    public init(_ frames: [CGRect]) {
        let frames = frames.filter(\.isFinite)
        self.frames = frames
        var lines: [SnapAxis: [Line]] = [:], neighbors: [SnapAxis: Neighbors] = [:]
        for axis in SnapAxis.allCases {
            let axisLines = Self.lines(of: frames, along: axis)
            lines[axis] = axisLines
            neighbors[axis] = Neighbors(frames, along: axis, lines: axisLines)
        }
        self.lines = lines
        self.neighbors = neighbors
    }

    /// `rect` moved by `delta`, snapped along each axis to the nearest line or spacing within
    /// `threshold` (ties go to what's asked first: lines before spaces, and a rect's near edge before
    /// its middle before its far edge), with the guides for everything that lines up exactly where it
    /// ends up. Along an axis where nothing is near enough, the delta is `delta`'s, untouched. Where
    /// it snaps, it's what puts the rect's edge (or middle) there from where `rect` is: `rect` moved
    /// by it lands on the line.
    public func snap(_ rect: CGRect, movedBy delta: CGPoint, within threshold: CGFloat) -> Snap {
        let moved = rect.offsetBy(dx: delta.x, dy: delta.y)
        var snapped = delta
        for axis in SnapAxis.allCases {
            if let along = nearest(along: axis, to: moved, from: rect, within: threshold) { snapped[axis] = along }
        }
        let placed = rect.offsetBy(dx: snapped.x, dy: snapped.y)
        return Snap(delta: snapped, guides: guides(for: placed))
    }

    /// Everything `rect` lines up with exactly, as guides: equal spacing first, then alignments
    /// (tldraw's order), each axis's `x` first.
    public func guides(for rect: CGRect) -> [SnapGuide] {
        SnapAxis.allCases.flatMap { spacings(along: $0, of: rect) } + SnapAxis.allCases.flatMap { alignments(along: $0, of: rect) }
    }

    // MARK: Snapping

    /// The delta along `axis` that puts `moved` on the nearest line or spacing within `threshold`,
    /// from `rect` (where it began); nil with none near enough.
    private func nearest(along axis: SnapAxis, to moved: CGRect, from rect: CGRect, within threshold: CGFloat) -> CGFloat? {
        var best: CGFloat?, closest = threshold
        func consider(_ target: CGFloat, for current: CGFloat, from start: CGFloat) {
            let distance = abs(target - current)
            guard best == nil ? distance <= closest + Self.tolerance : distance < closest - Self.tolerance else { return }
            closest = distance
            best = target - start
        }
        let lines = self.lines[axis] ?? []
        for part in FramePart.allCases {
            let current = moved.line(part, axis), start = rect.line(part, axis)
            let i = lines.partitioningIndex { $0.value >= current }
            if i > 0 { consider(lines[i - 1].value, for: current, from: start) }
            if i < lines.count { consider(lines[i].value, for: current, from: start) }
        }
        // A space counts while what moves shares its stretch across by more than a snap across could
        // take away, so however the other axis snaps, it still does, and the space's guide shows.
        let across = axis.across, length = moved.length(axis), reach = threshold + Self.tolerance
        for pair in neighbors[axis]?.pairs ?? [] where pair.breadth.overlaps(moved.low(across) + reach, moved.high(across) - reach) {
            let before = frames[Int(pair.before)], after = frames[Int(pair.after)]
            // Centered in the space between them, if it fits there.
            if pair.length > length { consider(before.high(axis) + pair.length / 2, for: moved.middle(axis), from: rect.middle(axis)) }
            // The space again, before the first and after the second.
            consider(before.low(axis) - pair.length, for: moved.high(axis), from: rect.high(axis))
            consider(after.high(axis) + pair.length, for: moved.low(axis), from: rect.low(axis))
        }
        return best
    }

    // MARK: Guides

    /// A guide for each line along `axis` that one of `rect`'s edges or its middle is on, through
    /// every frame's corners or center on it too.
    private func alignments(along axis: SnapAxis, of rect: CGRect) -> [SnapGuide] {
        let lines = self.lines[axis] ?? []
        var found: [(position: CGFloat, points: [CGPoint])] = []
        for part in FramePart.allCases {
            let position = rect.line(part, axis)
            var points: [CGPoint] = []
            var j = lines.partitioningIndex { $0.value >= position - Self.tolerance }
            while j < lines.count, lines[j].value <= position + Self.tolerance {
                points += frames[Int(lines[j].frame)].points(on: lines[j].part, along: axis)
                j += 1
            }
            guard !points.isEmpty else { continue }
            points += rect.points(on: part, along: axis)
            // A rect with no size along the axis has its edges and middle on one line.
            if let same = found.firstIndex(where: { abs($0.position - position) <= Self.tolerance }) {
                found[same].points += points
            } else {
                found.append((position, points))
            }
        }
        return found.map { .alignment(axis, at: $0.position, points: Self.distinct($0.points, along: axis)) }
    }

    /// Where `rect` makes spaces as long as those between neighbors along `axis` (tldraw's gap
    /// snaps, exactly): centered between two, or one before or after two, each shown with the spaces
    /// of that length it lines up with, one after another.
    private func spacings(along axis: SnapAxis, of rect: CGRect) -> [SnapGuide] {
        guard let neighbors = neighbors[axis] else { return [] }
        let pairs = neighbors.pairs, across = axis.across, length = rect.length(axis), span = rect.span(across)
        enum Found {
            case centered(Int), before(Int), after(Int)
            var isCentered: Bool { if case .centered = self { true } else { false } }
        }
        var found: [Found] = []
        for (index, pair) in pairs.enumerated() where pair.breadth.overlaps(rect.low(across), rect.high(across)) {
            let before = frames[Int(pair.before)], after = frames[Int(pair.after)]
            if pair.length > length, abs(before.high(axis) + pair.length / 2 - rect.middle(axis)) <= Self.tolerance {
                // Lots of neighbors spaced evenly would show a centering in each space around it: of
                // those whose spans across overlap, only the smallest shows (tldraw's).
                if let other = found.firstIndex(where: \.isCentered), case .centered(let o) = found[other],
                   pairs[o].breadth.meets(pair.breadth) {
                    if pairs[o].length > pair.length { found[other] = .centered(index) }
                } else {
                    found.append(.centered(index))
                }
            }
            if abs(before.low(axis) - pair.length - rect.high(axis)) <= Self.tolerance { found.append(.before(index)) }
            if abs(after.high(axis) + pair.length - rect.low(axis)) <= Self.tolerance { found.append(.after(index)) }
        }
        var guides: [[SnapGap]] = found.map { found in
            switch found {
            case .centered(let index):
                let pair = pairs[index], before = frames[Int(pair.before)], after = frames[Int(pair.after)]
                let space = (pair.length - length) / 2, breadth = pair.breadth.clamped(to: span)
                return neighbors.chain(from: pair.before, forward: false, length: space, within: breadth, in: frames)
                    + [SnapGap(start: before.high(axis), startSpan: before.span(across), end: rect.low(axis), endSpan: span),
                       SnapGap(start: rect.high(axis), startSpan: span, end: after.low(axis), endSpan: after.span(across))]
                    + neighbors.chain(from: pair.after, forward: true, length: space, within: breadth, in: frames)
            case .before(let index):
                let pair = pairs[index], before = frames[Int(pair.before)], breadth = pair.breadth.clamped(to: span)
                return [SnapGap(start: rect.high(axis), startSpan: span, end: before.low(axis), endSpan: before.span(across)),
                        neighbors.gap(of: pair, in: frames)]
                    + neighbors.chain(from: pair.after, forward: true, length: pair.length, within: breadth, in: frames)
            case .after(let index):
                let pair = pairs[index], after = frames[Int(pair.after)], breadth = pair.breadth.clamped(to: span)
                return neighbors.chain(from: pair.before, forward: false, length: pair.length, within: breadth, in: frames)
                    + [neighbors.gap(of: pair, in: frames),
                       SnapGap(start: after.high(axis), startSpan: after.span(across), end: rect.low(axis), endSpan: span)]
            }
        }
        // A guide whose every space another one shows too, with its start and its end, is left out
        // (tldraw's): the one with the most spaces shows them.
        let order = guides.indices.sorted { (-guides[$0].count, $0) < (-guides[$1].count, $1) }
        guides = order.map { guides[$0] }
        var i = guides.count - 1
        while i > 0 {
            let gaps = guides[i]
            if guides[..<i].contains(where: { other in
                gaps.allSatisfy { gap in
                    other.contains { $0.start.isClose(to: gap.start) && $0.startSpan.isClose(to: gap.startSpan) }
                        && other.contains { $0.end.isClose(to: gap.end) && $0.endSpan.isClose(to: gap.endSpan) }
                }
            }) {
                guides.remove(at: i)
            }
            i -= 1
        }
        return guides.map { .spacing(axis, gaps: $0) }
    }

    /// The points in order across the axis, each once.
    private static func distinct(_ points: [CGPoint], along axis: SnapAxis) -> [CGPoint] {
        let across = axis.across
        var distinct: [CGPoint] = []
        for point in points.sorted(by: { ($0[across], $0[axis]) < ($1[across], $1[axis]) }) {
            if let last = distinct.last, last[axis].isClose(to: point[axis]), last[across].isClose(to: point[across]) { continue }
            distinct.append(point)
        }
        return distinct
    }

    // MARK: Building

    /// Each frame's edges and middle along the axis, in order.
    private static func lines(of frames: [CGRect], along axis: SnapAxis) -> [Line] {
        var lines: [Line] = []
        lines.reserveCapacity(frames.count * 3)
        for (i, frame) in frames.enumerated() {
            for part in FramePart.allCases { lines.append(Line(value: frame.line(part, axis), frame: Int32(i), part: part)) }
        }
        lines.sort { $0.value < $1.value }
        return lines
    }
}

// MARK: - Lines and neighbors

/// Which of a frame's lines along an axis: its near edge, its middle, its far edge.
enum FramePart: CaseIterable, Sendable {
    case low, middle, high
}

/// A frame's edge or middle along an axis: where it is, and which frame's it is.
struct Line: Sendable {
    let value: CGFloat
    let frame: Int32
    let part: FramePart
}

/// Two frames next to each other along an axis, with a space between them: the one before, the one
/// after, how long the space is, and the stretch across the axis they share (tldraw's gap breadth).
struct NeighborPair: Sendable {
    let before: Int32
    let after: Int32
    let length: CGFloat
    let breadth: ClosedRange<CGFloat>
}

/// The frames next to each other along an axis: for each frame, the nearest one past its far edge
/// that overlaps it across the axis, and the nearest one short of its near edge that does. So a
/// frame's neighbors are at most two, and what lies between two frames that aren't neighbors (a
/// third frame) keeps the space between them from counting. Kept by the frame each pair begins and
/// ends with, to follow spaces one after another.
struct Neighbors: Sendable {
    let axis: SnapAxis
    let pairs: [NeighborPair]
    /// Indices into `pairs`, grouped by their frame before, and where each frame's group begins;
    /// the same by their frame after.
    private let byBefore: [Int32], beforeStarts: [Int32]
    private let byAfter: [Int32], afterStarts: [Int32]

    /// `lines` are the frames' lines along the axis in order (`SnapTargets`'): their near and far
    /// edges are the frames in order of each, with no sorting again.
    init(_ frames: [CGRect], along axis: SnapAxis, lines: [Line]) {
        let count = frames.count, across = axis.across
        var pairs: [NeighborPair] = []
        if count > 1 {
            var byLow: [Int] = [], lows: [CGFloat] = [], byHigh: [Int] = [], highs: [CGFloat] = []
            byLow.reserveCapacity(count)
            lows.reserveCapacity(count)
            byHigh.reserveCapacity(count)
            highs.reserveCapacity(count)
            for line in lines {
                switch line.part {
                case .low:
                    byLow.append(Int(line.frame))
                    lows.append(line.value)
                case .high:
                    byHigh.append(Int(line.frame))
                    highs.append(line.value)
                case .middle: break
                }
            }
            // Each frame's edges, along the axis and across it, side by side for the searches.
            let near = frames.map { $0.low(axis) }, far = frames.map { $0.high(axis) }
            let acrossLow = frames.map { $0.low(across) }, acrossHigh = frames.map { $0.high(across) }
            func overlapAcross(_ a: Int, _ b: Int) -> Bool { acrossLow[a] < acrossHigh[b] && acrossLow[b] < acrossHigh[a] }
            func pair(_ before: Int, _ after: Int) {
                pairs.append(NeighborPair(before: Int32(before), after: Int32(after), length: near[after] - far[before],
                                          breadth: max(acrossLow[before], acrossLow[after])...min(acrossHigh[before], acrossHigh[after])))
            }
            var next = [Int](repeating: -1, count: count)
            for i in 0..<count {
                // The first to begin past its far edge that it overlaps across.
                var j = lows.partitioningIndex { $0 > far[i] }
                let reach = min(count, j + SnapTargets.neighborReach)
                while j < reach {
                    if overlapAcross(i, byLow[j]) {
                        next[i] = byLow[j]
                        pair(i, byLow[j])
                        break
                    }
                    j += 1
                }
            }
            for i in 0..<count {
                // The last to end short of its near edge that it overlaps across, unless that one's
                // nearest after is this one already.
                var k = highs.partitioningIndex { $0 >= near[i] } - 1
                let reach = max(-1, k - SnapTargets.neighborReach)
                while k > reach {
                    if overlapAcross(i, byHigh[k]) {
                        if next[byHigh[k]] != i { pair(byHigh[k], i) }
                        break
                    }
                    k -= 1
                }
            }
        }
        self.axis = axis
        self.pairs = pairs
        let before = Self.grouped(pairs, by: \.before, count: count), after = Self.grouped(pairs, by: \.after, count: count)
        byBefore = before.order
        beforeStarts = before.starts
        byAfter = after.order
        afterStarts = after.starts
    }

    /// The pairs' indices in order of `key`, and where each frame's run of them begins (a counting
    /// sort).
    private static func grouped(_ pairs: [NeighborPair], by key: KeyPath<NeighborPair, Int32>, count: Int) -> (order: [Int32], starts: [Int32]) {
        var starts = [Int32](repeating: 0, count: count + 1)
        for pair in pairs { starts[Int(pair[keyPath: key]) + 1] += 1 }
        for i in stride(from: 1, through: count, by: 1) { starts[i] += starts[i - 1] }
        var order = [Int32](repeating: 0, count: pairs.count), fill = starts
        for (index, pair) in pairs.enumerated() {
            let frame = Int(pair[keyPath: key])
            order[Int(fill[frame])] = Int32(index)
            fill[frame] += 1
        }
        return (order, starts)
    }

    /// The space between a pair, as a spacing guide shows it.
    func gap(of pair: NeighborPair, in frames: [CGRect]) -> SnapGap {
        let before = frames[Int(pair.before)], after = frames[Int(pair.after)]
        return SnapGap(start: before.high(axis), startSpan: before.span(axis.across), end: after.low(axis), endSpan: after.span(axis.across))
    }

    /// Spaces `length` long one after another from `frame`, forward (to the pairs it's before) or
    /// back, while they share some of `breadth` across (tldraw's findAdjacentGaps).
    func chain(from frame: Int32, forward: Bool, length: CGFloat, within breadth: ClosedRange<CGFloat>, in frames: [CGRect]) -> [SnapGap] {
        let order = forward ? byBefore : byAfter, starts = forward ? beforeStarts : afterStarts
        var gaps: [SnapGap] = []
        var followed: Set<Int32> = []
        for slot in Int(starts[Int(frame)])..<Int(starts[Int(frame) + 1]) {
            let pair = pairs[Int(order[slot])]
            guard pair.length.isClose(to: length), let shared = pair.breadth.intersection(breadth) else { continue }
            gaps.append(gap(of: pair, in: frames))
            let next = forward ? pair.after : pair.before
            if followed.insert(next).inserted {
                gaps += chain(from: next, forward: forward, length: length, within: shared, in: frames)
            }
        }
        return gaps
    }
}

// MARK: - Geometry along an axis

extension CGRect {
    func low(_ axis: SnapAxis) -> CGFloat { axis == .x ? minX : minY }
    func middle(_ axis: SnapAxis) -> CGFloat { axis == .x ? midX : midY }
    func high(_ axis: SnapAxis) -> CGFloat { axis == .x ? maxX : maxY }
    func length(_ axis: SnapAxis) -> CGFloat { axis == .x ? width : height }
    func span(_ axis: SnapAxis) -> ClosedRange<CGFloat> { low(axis)...high(axis) }

    func line(_ part: FramePart, _ axis: SnapAxis) -> CGFloat {
        switch part {
        case .low: low(axis)
        case .middle: middle(axis)
        case .high: high(axis)
        }
    }

    /// Its snap points on a line along `axis` (tldraw's: the corners and the center): an edge's two
    /// corners, or the center.
    func points(on part: FramePart, along axis: SnapAxis) -> [CGPoint] {
        let across = axis.across
        switch part {
        case .middle: return [CGPoint(middle(axis), middle(across), on: axis)]
        case .low, .high: return [CGPoint(line(part, axis), low(across), on: axis), CGPoint(line(part, axis), high(across), on: axis)]
        }
    }
}

extension CGPoint {
    /// `along` on `axis`, `across` on the other.
    init(_ along: CGFloat, _ across: CGFloat, on axis: SnapAxis) {
        self = axis == .x ? CGPoint(x: along, y: across) : CGPoint(x: across, y: along)
    }

    subscript(axis: SnapAxis) -> CGFloat {
        get { axis == .x ? x : y }
        set { if axis == .x { x = newValue } else { y = newValue } }
    }
}

extension ClosedRange<CGFloat> {
    /// Whether it overlaps `low...high` by more than a point (tldraw's rangesOverlap).
    func overlaps(_ low: CGFloat, _ high: CGFloat) -> Bool { lowerBound < high && low < upperBound }
    /// Whether they meet, if only at a point (tldraw's rangeIntersection isn't null).
    func meets(_ other: ClosedRange<CGFloat>) -> Bool { intersection(other) != nil }
    /// Where they meet, a point if they only touch; nil if they don't (tldraw's rangeIntersection).
    func intersection(_ other: ClosedRange<CGFloat>) -> ClosedRange<CGFloat>? {
        let low = Swift.max(lowerBound, other.lowerBound), high = Swift.min(upperBound, other.upperBound)
        return low <= high ? low...high : nil
    }
    func isClose(to other: ClosedRange<CGFloat>) -> Bool {
        lowerBound.isClose(to: other.lowerBound) && upperBound.isClose(to: other.upperBound)
    }
}

extension CGFloat {
    func isClose(to other: CGFloat) -> Bool { abs(self - other) <= SnapTargets.tolerance }
}

extension Array {
    /// The first index whose element `isPast` holds for, in an array where it holds for none before
    /// that one and every one after (a binary search): `count` if none.
    func partitioningIndex(where isPast: (Element) -> Bool) -> Int {
        var low = 0, high = count
        while low < high {
            let middle = (low + high) / 2
            if isPast(self[middle]) { high = middle } else { low = middle + 1 }
        }
        return low
    }
}

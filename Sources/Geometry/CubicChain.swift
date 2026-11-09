import CoreGraphics

/// Cubic pieces joined end to end, each starting where the one before ends: a line that is straight for a stretch and then
/// curves (a straight piece is a cubic with its controls on it, `line(from:to:)`). Parameterized 0...1 over the whole, each
/// piece an equal share of it in order; what is placed by length goes through `measured()`. One piece is the cubic itself.
public struct CubicChain: Sendable, Hashable {
    /// Never empty.
    public let pieces: [Cubic]

    public init(_ pieces: [Cubic]) {
        precondition(!pieces.isEmpty, "a chain has a piece")
        self.pieces = pieces
    }

    public init(_ cubic: Cubic) { pieces = [cubic] }

    /// A straight piece from `a` to `b`, as a cubic whose controls are a third of the way from each end: even speed along it.
    public static func line(from a: CGPoint, to b: CGPoint) -> Cubic {
        Cubic(a, a + (b - a) / 3, a + (b - a) * (2.0 / 3), b)
    }

    public var start: CGPoint { pieces[0].start }
    public var end: CGPoint { pieces[pieces.count - 1].end }

    /// The piece `t` falls on, and where on it.
    private func locate(_ t: CGFloat) -> (index: Int, local: CGFloat) {
        let scaled = min(max(t, 0), 1) * CGFloat(pieces.count)
        let index = min(Int(scaled), pieces.count - 1)
        return (index, scaled - CGFloat(index))
    }

    /// The parameter of the whole at `local` on piece `index`.
    private func global(_ index: Int, _ local: CGFloat) -> CGFloat { (CGFloat(index) + local) / CGFloat(pieces.count) }

    public func point(at t: CGFloat) -> CGPoint {
        let (index, local) = locate(t)
        return pieces[index].point(at: local)
    }

    /// The unit tangent at `t`, in the direction of travel.
    public func tangent(at t: CGFloat) -> CGPoint {
        let (index, local) = locate(t)
        return pieces[index].tangent(at: local)
    }

    /// The part of it between `t0` and `t1`, as a chain of its own, parameterized 0...1.
    public func trimmed(from t0: CGFloat, to t1: CGFloat) -> CubicChain {
        guard t0 > 0 || t1 < 1 else { return self }
        guard pieces.count > 1 else { return CubicChain(pieces[0].trimmed(from: t0, to: t1)) }
        let (first, from) = locate(t0), (last, to) = locate(t1)
        if first == last { return CubicChain(pieces[first].trimmed(from: from, to: to)) }
        var kept = [pieces[first].trimmed(from: from, to: 1)]
        if last > first + 1 { kept += pieces[(first + 1)..<last] }
        kept.append(pieces[last].trimmed(from: 0, to: to))
        return CubicChain(kept)
    }

    /// Points along it, `segments` to each piece (one to a straight piece), its ends included, with the parameter of each.
    private func samples(segments: Int) -> [(t: CGFloat, point: CGPoint)] {
        var result: [(t: CGFloat, point: CGPoint)] = [(0, start)]
        for (index, piece) in pieces.enumerated() {
            let count = piece.isEvenLine ? 1 : max(segments, 1)
            for step in 1...count {
                let local = CGFloat(step) / CGFloat(count)
                result.append((global(index, local), piece.point(at: local)))
            }
        }
        return result
    }

    /// Points along it, `segments` to each piece, its ends included, evenly spaced in `t`.
    public func flattened(segments: Int = Cubic.segments) -> [CGPoint] {
        let count = max(segments, 1) * pieces.count
        return (0...count).map { point(at: CGFloat($0) / CGFloat(count)) }
    }

    /// Its length, along it.
    public var length: CGFloat { pieces.reduce(0) { $0 + $1.length } }

    /// How far `point` is from the nearest point of it.
    public func distance(to point: CGPoint) -> CGFloat {
        pieces.map { $0.distance(to: point) }.min() ?? .infinity
    }

    /// The parameters in 0...1 where it crosses the closed polygon's edges, in order along it.
    public func intersections(withPolygon polygon: [CGPoint]) -> [CGFloat] {
        var result: [CGFloat] = []
        for (index, piece) in pieces.enumerated() {
            for local in piece.intersections(withPolygon: polygon) {
                let t = global(index, local)
                if !result.contains(where: { abs($0 - t) < 1e-6 }) { result.append(t) }
            }
        }
        return result.sorted()
    }

    /// The smallest rectangle holding it.
    public var bounds: CGRect { pieces.dropFirst().reduce(pieces[0].bounds) { $0.union($1.bounds) } }

    /// Its points by length along it.
    public func measured(segments: Int = Cubic.segments) -> ChainMeasure { ChainMeasure(self, samples: samples(segments: segments)) }

    /// The line, added to `path` from where `path` is (a `move` first, unless `continuing`).
    public func add(to path: CGMutablePath, continuing: Bool = false) {
        for (index, piece) in pieces.enumerated() {
            if piece.isStraight {
                if index == 0, !continuing { path.move(to: piece.start) }
                path.addLine(to: piece.end)
            } else {
                piece.add(to: path, continuing: continuing || index > 0)
            }
        }
    }

    public var cgPath: CGPath {
        let path = CGMutablePath()
        add(to: path)
        return path
    }
}

extension Cubic {
    /// Whether it is `CubicChain.line(from:to:)`'s: controls a third of the way from each end, so even speed along it (a
    /// collinear cubic with its controls elsewhere eases, and is measured as a curve is).
    var isEvenLine: Bool {
        let chord = end - start
        let scale = max(chord.length, 1)
        return control1.distance(to: start + chord / 3) < 1e-6 * scale && control2.distance(to: start + chord * (2.0 / 3)) < 1e-6 * scale
    }

    /// Whether its controls lie on the line between its ends (`CubicChain.line(from:to:)`'s, or one that draws as straight).
    public var isStraight: Bool {
        let chord = end - start, length = chord.length
        guard length > 1e-9 else { return control1.distance(to: start) < 1e-9 && control2.distance(to: end) < 1e-9 }
        let cross = { (point: CGPoint) in abs(chord.cross(point - self.start)) / length }
        let along = { (point: CGPoint) in chord.dot(point - self.start) / (length * length) }
        return cross(control1) < 1e-6 && cross(control2) < 1e-6 && (0...1).contains(along(control1)) && (0...1).contains(along(control2))
    }
}

/// A chain measured along its length (`CubicMeasure`'s, over its pieces): how far along it each parameter is, and back.
public struct ChainMeasure: Sendable {
    public let chain: CubicChain
    private let ts: [CGFloat]
    private let lengths: [CGFloat]
    private let points: [CGPoint]

    init(_ chain: CubicChain, samples: [(t: CGFloat, point: CGPoint)]) {
        self.chain = chain
        ts = samples.map(\.t)
        points = samples.map(\.point)
        var lengths: [CGFloat] = [0]
        lengths.reserveCapacity(samples.count)
        for index in 1..<max(samples.count, 1) { lengths.append(lengths[index - 1] + points[index - 1].distance(to: points[index])) }
        self.lengths = lengths
    }

    public var length: CGFloat { lengths.last ?? 0 }

    /// How far along it the point at `t` is.
    public func length(at t: CGFloat) -> CGFloat {
        guard ts.count > 1 else { return 0 }
        let wanted = min(max(t, 0), 1)
        var low = 0, high = ts.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if ts[middle] <= wanted { low = middle } else { high = middle }
        }
        let span = ts[high] - ts[low]
        return lengths[low] + (lengths[high] - lengths[low]) * (span > 0 ? (wanted - ts[low]) / span : 0)
    }

    /// The parameter of the point `distance` along it, clamped to its ends.
    public func parameter(atLength distance: CGFloat) -> CGFloat {
        guard length > 0, ts.count > 1 else { return 0 }
        let wanted = min(max(distance, 0), length)
        var low = 0, high = lengths.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if lengths[middle] <= wanted { low = middle } else { high = middle }
        }
        let span = lengths[high] - lengths[low]
        return ts[low] + (ts[high] - ts[low]) * (span > 0 ? (wanted - lengths[low]) / span : 0)
    }

    /// The point `fraction` of the way along it by length.
    public func point(atFraction fraction: CGFloat) -> CGPoint { chain.point(at: parameter(atLength: fraction * length)) }

    /// How far along it by length, as a fraction, the point of it nearest `point` is.
    public func fraction(nearest point: CGPoint) -> CGFloat {
        guard length > 0 else { return 0 }
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

import CoreGraphics
import Geometry
import TestKit

@MainActor let geometryTests = Suite("Geometry", [
    test("an arc through three points") {
        let arc = try require(Arc(from: CGPoint(x: -1, y: 0), through: CGPoint(x: 0, y: 1), to: CGPoint(x: 1, y: 0)))
        expectClose(arc.center, .zero)
        expectClose(arc.radius, 1)
        expectClose(arc.point(at: 0.5), CGPoint(x: 0, y: 1))
    },
    test("collinear points make no arc") {
        expect(Arc(from: .zero, through: CGPoint(x: 1, y: 0), to: CGPoint(x: 2, y: 0)) == nil)
    },
    test("the camera keeps the anchor fixed when zooming") {
        var camera = Camera()
        let anchor = CGPoint(x: 300, y: 200), world = camera.toWorld(anchor)
        camera.setZoom(2.5, around: anchor)
        expectClose(camera.toView(world), anchor)
        camera.setZoom(100, around: anchor)
        expectEqual(camera.zoom, Camera.zoomRange.upperBound)
    },
    test("a camera fitting bounds centers them, with the inset shared by both sides, within zoomRange and maxZoom") {
        let view = CGSize(width: 1000, height: 700)
        let wide = Camera(fitting: CGRect(x: 0, y: 0, width: 2000, height: 600), in: view, inset: 100)
        expectClose(wide.zoom, 0.45)                                    // (1000 - 100) / 2000 across beats (700 - 100) / 600 down
        expectClose(wide.toView(CGPoint(x: 1000, y: 300)), CGPoint(x: 500, y: 350))
        expectClose(wide.toView(CGPoint(x: 0, y: 300)), CGPoint(x: 50, y: 350), within: 1e-9)
        let small = CGRect(x: 10, y: 10, width: 20, height: 20)
        expectEqual(Camera(fitting: small, in: view, inset: 100).zoom, Camera.zoomRange.upperBound)
        expectEqual(Camera(fitting: small, in: view, inset: 100, maxZoom: 1.2).zoom, 1.2)
        expectEqual(Camera(fitting: CGRect(x: 0, y: 0, width: 1_000_000, height: 10), in: view, inset: 100).zoom, Camera.zoomRange.lowerBound)
        let line = Camera(fitting: CGRect(x: 0, y: 50, width: 900, height: 0), in: view, inset: 100)
        expectClose(line.zoom, 1, within: 1e-9)                        // a flat side doesn't limit the zoom
        expectClose(line.toView(CGPoint(x: 450, y: 50)), CGPoint(x: 500, y: 350), within: 1e-9)
    },
    test("polygon containment and segment intersections") {
        let square = CGRect(x: 0, y: 0, width: 10, height: 10).polygon
        expect(polygonContains(square, CGPoint(x: 5, y: 5)))
        expect(!polygonContains(square, CGPoint(x: 15, y: 5)))
        expectEqual(intersections(ofSegmentFrom: CGPoint(x: -5, y: 5), to: CGPoint(x: 15, y: 5), withPolygon: square).count, 2)
    },
    test("containsStrictly is strict on every side") {
        let outer = CGRect(x: 0, y: 0, width: 10, height: 10)
        expect(outer.containsStrictly(CGRect(x: 1, y: 1, width: 8, height: 8)))
        expect(outer.containsStrictly(CGRect(x: 5, y: 5, width: 0, height: 0)))
        for inner in [CGRect(x: 0, y: 1, width: 8, height: 8), CGRect(x: 1, y: 0, width: 8, height: 8),
                      CGRect(x: 1, y: 1, width: 9, height: 8), CGRect(x: 1, y: 1, width: 8, height: 9), outer] {
            expect(!outer.containsStrictly(inner), "\(inner) shares an edge")
        }
    },
    test("touches includes shared edges and zero-width and zero-height rects") {
        let rect = CGRect(x: 0, y: 0, width: 10, height: 10)
        expect(rect.touches(CGRect(x: 10, y: 0, width: 5, height: 5)), "a shared edge")
        expect(!rect.intersects(CGRect(x: 10, y: 0, width: 5, height: 5)), "which intersects misses")
        expect(rect.touches(CGRect(x: 10, y: 10, width: 5, height: 5)), "a shared corner")
        expect(!rect.touches(CGRect(x: 10.5, y: 0, width: 5, height: 5)))
        expect(!rect.touches(CGRect(x: 0, y: -5.5, width: 5, height: 5)))
        let level = CGRect(x: -5, y: 5, width: 20, height: 0)
        expect(rect.touches(level) && level.touches(rect), "zero height")
        expect(rect.touches(CGRect(x: 5, y: -5, width: 0, height: 20)), "zero width")
        expect(!rect.touches(CGRect(x: 5, y: 11, width: 0, height: 20)))
    },
])

/// A curve that leaves (0, 0) going right and arrives at (300, 100) going right: an S, a level arrow's between two rows.
private let sCurve = Cubic(CGPoint(x: 0, y: 0), CGPoint(x: 150, y: 0), CGPoint(x: 150, y: 100), CGPoint(x: 300, y: 100))

/// Its points every `1 / count` of `t`, worked out by the polynomial written out, not by the type's own arithmetic.
private func sampled(_ cubic: Cubic, _ t: CGFloat) -> CGPoint {
    let (p0, p1, p2, p3) = (cubic.start, cubic.control1, cubic.control2, cubic.end)
    func axis(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
        pow(1 - t, 3) * a + 3 * pow(1 - t, 2) * t * b + 3 * (1 - t) * t * t * c + t * t * t * d
    }
    return CGPoint(x: axis(p0.x, p1.x, p2.x, p3.x), y: axis(p0.y, p1.y, p2.y, p3.y))
}

/// Its length summed over `count` chords of evenly spaced `t`: as near the true length as `count` is large.
private func chordLength(_ cubic: Cubic, count: Int) -> CGFloat {
    (1...count).reduce(0) { sum, index in
        sum + sampled(cubic, CGFloat(index - 1) / CGFloat(count)).distance(to: sampled(cubic, CGFloat(index) / CGFloat(count)))
    }
}

@MainActor let cubicTests = Suite("Cubic curves", [
    test("its points and tangents are the polynomial's, its ends where it starts and ends") {
        for step in 0...20 {
            let t = CGFloat(step) / 20
            expectClose(sCurve.point(at: t), sampled(sCurve, t), within: 1e-9)
        }
        expectEqual(sCurve.point(at: 0), sCurve.start)
        expectEqual(sCurve.point(at: 1), sCurve.end)
        expectClose(sCurve.tangent(at: 0), CGPoint(x: 1, y: 0), within: 1e-9)
        expectClose(sCurve.tangent(at: 1), CGPoint(x: 1, y: 0), within: 1e-9)
        expectClose(sCurve.point(at: 0.5), CGPoint(x: 150, y: 50), within: 1e-9)
        // A control on its end: the curve still sets off toward the next point.
        let pinned = Cubic(.zero, .zero, CGPoint(x: 0, y: 10), CGPoint(x: 10, y: 10))
        expectClose(pinned.tangent(at: 0), CGPoint(x: 0, y: 1), within: 1e-9)
        expectEqual(Cubic(.zero, .zero, .zero, .zero).tangent(at: 0.5), .zero)
    },
    test("split and trimmed are the same curve, reparameterized") {
        let (left, right) = sCurve.split(at: 0.3)
        expectClose(left.end, sCurve.point(at: 0.3), within: 1e-9)
        expectClose(right.start, sCurve.point(at: 0.3), within: 1e-9)
        for step in 0...10 {
            let u = CGFloat(step) / 10
            expectClose(left.point(at: u), sCurve.point(at: 0.3 * u), within: 1e-9)
            expectClose(right.point(at: u), sCurve.point(at: 0.3 + 0.7 * u), within: 1e-9)
        }
        let middle = sCurve.trimmed(from: 0.2, to: 0.7)
        for step in 0...10 {
            let u = CGFloat(step) / 10
            expectClose(middle.point(at: u), sCurve.point(at: 0.2 + 0.5 * u), within: 1e-9)
        }
        expectEqual(sCurve.trimmed(from: 0, to: 1), sCurve)
        expectEqual(sCurve.flattened(segments: 4).count, 5)
    },
    test("its length is the arc length, and a measure finds points by length both ways") {
        let truth = chordLength(sCurve, count: 20_000)
        expectClose(sCurve.length, truth, within: 0.05)
        let line = Cubic(.zero, CGPoint(x: 10, y: 0), CGPoint(x: 20, y: 0), CGPoint(x: 30, y: 0))
        expectClose(line.length, 30, within: 1e-9)
        let measure = sCurve.measured()
        expectClose(measure.length, sCurve.length, within: 1e-9)
        for fraction in [0.0, 0.1, 0.25, 0.5, 0.8, 1.0] as [CGFloat] {
            let t = measure.parameter(atLength: fraction * measure.length)
            expectClose(measure.length(at: t), fraction * measure.length, within: 0.01)
            // By length, not by t: a quarter of the length along is a quarter of the chords' sum along.
            expectClose(chordLength(sCurve.trimmed(from: 0, to: t), count: 4_000), fraction * truth, within: 0.1)
            expectClose(measure.fraction(nearest: measure.point(atFraction: fraction)), fraction, within: 0.001)
        }
        expectEqual(measure.parameter(atLength: -5), 0)
        expectEqual(measure.parameter(atLength: measure.length + 5), 1)
    },
    test("distance to it, bounds round it, and where it crosses a polygon") {
        expectClose(sCurve.distance(to: CGPoint(x: 150, y: 50)), 0, within: 0.01)
        expectClose(sCurve.distance(to: CGPoint(x: -10, y: 0)), 10, within: 1e-6)
        expectClose(sCurve.distance(to: CGPoint(x: 0, y: 30)), 30, within: 0.5)
        let bounds = sCurve.bounds
        expectClose(bounds.minX, 0, within: 1e-9)
        expectClose(bounds.maxX, 300, within: 1e-9)
        expectClose(bounds.minY, 0, within: 1e-9)
        expectClose(bounds.maxY, 100, within: 1e-9)
        // A curve that bows past its ends: its bounds hold the bow, not its controls.
        let bow = Cubic(.zero, CGPoint(x: 0, y: -100), CGPoint(x: 100, y: -100), CGPoint(x: 100, y: 0))
        expectClose(bow.bounds.minY, -75, within: 1e-6)
        expect(bow.bounds.minY > -100, "the controls aren't in its bounds")
        // A box round its middle: entered and left once each, where the polygon's sides are.
        let box = CGRect(x: 100, y: 20, width: 100, height: 60).polygon
        let crossings = sCurve.intersections(withPolygon: box)
        expectEqual(crossings.count, 2)
        for t in crossings {
            let point = sCurve.point(at: t)
            expect(abs(point.x - 100) < 1e-4 || abs(point.x - 200) < 1e-4 || abs(point.y - 20) < 1e-4 || abs(point.y - 80) < 1e-4,
                   "\(point) is on the box's edge")
        }
        expect(sCurve.intersections(withPolygon: CGRect(x: 400, y: 0, width: 10, height: 10).polygon).isEmpty)
    },
])

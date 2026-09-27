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

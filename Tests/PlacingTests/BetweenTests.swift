@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Draw
import TestKit

// Where `Surroundings.between(_:_:growing:room:)` lands a box between two shapes.

@MainActor private func harness(_ records: AnyShapeRecord...) throws -> EditorHarness {
    try EditorHarness(plugins: [FixturesPlugin(), CorralsPlugin()], file: CanvasFile(root: CanvasDocument(shapes: records)))
}

@MainActor private func box(_ id: ShapeID, _ x: CGFloat, _ y: CGFloat, size: CGFloat = 100, in container: ShapeID? = nil) -> AnyShapeRecord {
    AnyShapeRecord(ShapeRecord(id: id, Box(CGRect(x: x, y: y, width: size, height: size)))).copy(as: id, container: container)
}

@MainActor private func corral(_ id: ShapeID, _ frame: CGRect, in container: ShapeID? = nil) -> AnyShapeRecord {
    AnyShapeRecord(ShapeRecord(id: id, Corral(frame))).copy(as: id, container: container)
}

private func at(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat = 100, _ height: CGFloat = 100) -> CGRect { CGRect(x: x, y: y, width: width, height: height) }

private let hundred = CGSize(width: 100, height: 100)

@MainActor let betweenTests = Suite("Between two shapes", [
    test("two shapes in a frame with room between them: the landing is in the gap, as it is for the same two outside a frame") {
        let k = ShapeID(), a = ShapeID(), b = ShapeID()
        let h = try harness(corral(k, at(-200, -200, 1200, 600)), box(a, 0, 0, in: k), box(b, 600, 0, in: k))
        let landing = try require(Surroundings(on: .root, moving: hundred, in: h.editor)?.between(a, b))
        expectEqual(landing.rect, at(300, 0), "between them, in the gap")
    },
    test("two shapes in a frame, one above the other") {
        let k = ShapeID(), a = ShapeID(), b = ShapeID()
        let h = try harness(corral(k, at(-200, -200, 600, 1200)), box(a, 0, 0, in: k), box(b, 0, 600, in: k))
        let landing = try require(Surroundings(on: .root, moving: hundred, in: h.editor)?.between(a, b))
        expectEqual(landing.rect, at(0, 300), "between them, in the gap")
    },
    test("the two on a board with a frame elsewhere that the gap is not in: unaffected") {
        let k = ShapeID(), a = ShapeID(), b = ShapeID()
        let h = try harness(corral(k, at(2000, 2000, 400, 400)), box(a, 0, 0), box(b, 600, 0))
        expectEqual(Surroundings(on: .root, moving: hundred, in: h.editor)?.between(a, b)?.rect, at(300, 0))
    },
    test("overlapping shapes: the landing is clear of both") {
        let a = ShapeID(), b = ShapeID()
        let h = try harness(box(a, 0, 0), box(b, 50, 50))
        let rect = try require(Surroundings(on: .root, moving: hundred, in: h.editor)?.between(a, b)?.rect)
        for other in [at(0, 0), at(50, 50)] { expect(!rect.intersects(other), "clear of \(other): \(rect)") }
    },
    test("one shape inside the other's bounds (same place): clear of both") {
        let a = ShapeID(), b = ShapeID()
        let h = try harness(box(a, 0, 0), box(b, 0, 0))
        let rect = try require(Surroundings(on: .root, moving: hundred, in: h.editor)?.between(a, b)?.rect)
        expect(!rect.intersects(at(0, 0)), "clear: \(rect)")
    },
    test("too close, with both sides across the line taken: still clear of everything") {
        let a = ShapeID(), b = ShapeID(), below = ShapeID(), above = ShapeID()
        let h = try harness(box(a, 0, 0), box(b, 250, 0), box(below, 125, 170), box(above, 125, -170))
        let rect = try require(Surroundings(on: .root, moving: hundred, in: h.editor)?.between(a, b)?.rect)
        for other in [at(0, 0), at(250, 0), at(125, 170), at(125, -170)] { expect(!rect.intersects(other), "clear of \(other): \(rect)") }
    },
    test("the gap holds the box, with a third shape on the line between them: clear of all three") {
        let a = ShapeID(), b = ShapeID(), c = ShapeID()
        let h = try harness(box(a, 0, 0), box(b, 1000, 0), box(c, 500, 0))
        let rect = try require(Surroundings(on: .root, moving: hundred, in: h.editor)?.between(a, b)?.rect)
        for other in [at(0, 0), at(1000, 0), at(500, 0)] { expect(!rect.intersects(other), "clear of \(other): \(rect)") }
    },
    test("diagonal, apart on both axes by the same, lands clear of both and between") {
        let a = ShapeID(), b = ShapeID()
        let h = try harness(box(a, 0, 0), box(b, 500, 500))
        let rect = try require(Surroundings(on: .root, moving: hundred, in: h.editor)?.between(a, b)?.rect)
        for other in [at(0, 0), at(500, 500)] { expect(!rect.intersects(other), "clear of \(other): \(rect)") }
    },
    test("growing with a side-by-side pair leaves the row's room: the landing is clear of both as grown") {
        let a = ShapeID(), b = ShapeID()
        let h = try harness(box(a, 0, 0), box(b, 600, 0))
        let rect = try require(Surroundings(on: .root, moving: hundred, in: h.editor)?.between(a, b, growing: 60)?.rect)
        for other in [at(0, 0, 100, 160), at(600, 0, 100, 160)] { expect(!rect.intersects(other), "clear of \(other): \(rect)") }
    },
    test("stacked pair, growing: the second's growth below it is not in the gap, the first's is") {
        let a = ShapeID(), b = ShapeID()
        // b above a: gap from b.maxY (100) to a.minY (500) = 400; b grows 60 down into it: 340 >= 260.
        let h = try harness(box(a, 0, 500), box(b, 0, 0))
        let rect = try require(Surroundings(on: .root, moving: hundred, in: h.editor)?.between(a, b, growing: 60)?.rect)
        expectEqual(rect, at(0, 280), "the gap runs 160 to 500, its middle holds the box at 280")
    },
    test("a moving box wider than the gap less its rooms is not put in it") {
        let a = ShapeID(), b = ShapeID()
        let h = try harness(box(a, 0, 0), box(b, 400, 0))
        let rect = try require(Surroundings(on: .root, moving: CGSize(width: 160, height: 34), in: h.editor)?.between(a, b)?.rect)
        for other in [at(0, 0), at(400, 0)] { expect(!rect.intersects(other), "clear of \(other): \(rect)") }
    },
    test("a caller that asks for more room keeps it on each side: a gap that holds the box with the default room does not with more") {
        let a = ShapeID(), b = ShapeID()
        let h = try harness(box(a, 0, 0), box(b, 400, 0))     // a 300 gap: 100 and 2 x 80 fit, 100 and 2 x 120 do not
        let surroundings = try require(Surroundings(on: .root, moving: hundred, in: h.editor))
        expectEqual(surroundings.between(a, b)?.rect, at(200, 0))
        let rect = try require(surroundings.between(a, b, room: 120)?.rect)
        for other in [at(0, 0), at(400, 0)] { expect(!rect.intersects(other), "clear of \(other): \(rect)") }
        expect(rect.minY != 0, "beside the middle, across the line: \(rect)")
    },
])

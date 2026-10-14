@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Draw
import TestKit

// Placing: where a box of shapes lands, worked out as `canvas draw` places a shape (80 from what it's beside,
// centered on it the other way; 40 in from a frame's corner), on a board as it is now. Fixtures only:
// CanvasTesting's boxes and corrals (they hold shapes, as a frame does). Moving's command tests hold the
// commits; these hold the answers.

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

@MainActor let surroundingsTests = Suite("Placing", [
    test("beside a shape: right of it when that's free, 80 away and centered on it") {
        let x = ShapeID()
        let h = try harness(box(x, 400, 400))
        let landing = Surroundings(on: .root, moving: hundred, in: h.editor)?.near(x)
        expectEqual(landing?.rect, at(580, 400))
        expectEqual(landing?.board, .root)
        expectEqual(landing?.above, [])
    },

    test("beside a shape with its right taken: below it, the next side") {
        let x = ShapeID(), y = ShapeID()
        let h = try harness(box(x, 400, 400), box(y, 580, 400))
        expectEqual(Surroundings(on: .root, moving: hundred, in: h.editor)?.near(x)?.rect, at(400, 580))
    },

    test("beside a box that is not on the board: where a shape there would be landed beside, 80 away and centered on it") {
        let h = try harness(box(ShapeID(), 0, 0))
        let landing = Surroundings(on: .root, moving: hundred, in: h.editor)?.near(at(400, 400))
        expectEqual(landing?.rect, at(580, 400))
        expectEqual(landing?.board, .root)
    },

    test("avoiding: boxes planned and not put down are obstacles like shapes, and the same as a shape there") {
        let planned = at(580, 400)
        let h = try harness(box(ShapeID(), 0, 0))
        let avoided = Surroundings(on: .root, moving: hundred, in: h.editor)?.near(at(400, 400), avoiding: [planned])
        expectEqual(avoided?.rect, at(400, 580), "its right taken, below it")
        let x = ShapeID(), taken = try harness(box(x, 400, 400), box(ShapeID(), 580, 400))
        expectEqual(avoided?.rect, Surroundings(on: .root, moving: hundred, in: taken.editor)?.near(x)?.rect)
        expectEqual(Surroundings(on: .root, moving: hundred, in: h.editor)?.near(at(400, 400), avoiding: [])?.rect, at(580, 400))
    },

    test("beside a shape that isn't there: nil") {
        let h = try harness(box(ShapeID(), 0, 0))
        expectEqual(Surroundings(on: .root, moving: hundred, in: h.editor)?.near(ShapeID()), nil)
    },

    test("the shapes carried are no obstacle on their own board, and without them they are") {
        let x = ShapeID(), s = ShapeID()
        let h = try harness(box(x, 400, 400), box(s, 580, 400))
        expectEqual(Surroundings(on: .root, moving: hundred, carrying: [s], in: h.editor)?.near(x)?.rect, at(580, 400))
        expectEqual(Surroundings(on: .root, moving: hundred, in: h.editor)?.near(x)?.rect, at(400, 580))
    },

    test("what the carried shapes hold goes with them: never in their way, and without `held` it is") {
        let x = ShapeID(), k = ShapeID(), b = ShapeID()
        let h = try harness(box(x, 400, 400), corral(k, at(580, 400)), box(b, 600, 420, size: 40, in: k))
        expectEqual(Surroundings(on: .root, moving: hundred, carrying: [k], held: [b], in: h.editor)?.near(x)?.rect, at(580, 400))
        expectEqual(Surroundings(on: .root, moving: hundred, carrying: [k], in: h.editor)?.near(x)?.rect, at(400, 580))
    },

    test("beside a shape within a corral: kept in it, and raised above it") {
        let k = ShapeID(), x = ShapeID()
        let h = try harness(corral(k, at(0, 0, 800, 600)), box(x, 100, 100, in: k))
        let landing = Surroundings(on: .root, moving: hundred, in: h.editor)?.near(x, within: k)
        expectEqual(landing?.rect, at(280, 100))
        expect(landing?.above.contains(k) ?? false, "above the corral")
    },

    test("inside a corral: 40 in from its top-left, pushed clear of what it holds, and raised above it") {
        let k = ShapeID(), b = ShapeID()
        let h = try harness(corral(k, at(100, 100, 600, 400)), box(b, 140, 140, in: k))
        let landing = Surroundings(on: .root, moving: hundred, in: h.editor)?.inside(k)
        expectEqual(landing?.rect, at(280, 140))
        expect(landing?.above.contains(k) ?? false)
    },

    test("anywhere on a board with something at the middle of its view: the nearest spot clear of it") {
        let h = try harness()
        let empty = Surroundings(on: .root, moving: hundred, in: h.editor)?.anywhere().rect
        let blocker = ShapeID()
        let busy = try harness(AnyShapeRecord(ShapeRecord(id: blocker, Box(empty ?? .zero))))
        let moved = Surroundings(on: .root, moving: hundred, in: busy.editor)?.anywhere().rect
        expect(empty != nil && moved != nil)
        expect(!(moved ?? .zero).intersects(empty ?? .zero), "clear of what's at the middle")
    },

    test("a board the editor can't show, or a size that isn't one: no surroundings") {
        let h = try harness(box(ShapeID(), 0, 0))
        expect(Surroundings(on: BoardID(owner: ShapeID()), moving: hundred, in: h.editor) == nil)
        expect(Surroundings(on: .root, moving: CGSize(width: CGFloat.nan, height: 1), in: h.editor) == nil)
    },

    test("between two shapes: in the gap, centered in it along the axis they are apart on and on their middle across, with an arrow's room (80) kept clear on each side") {
        let a = ShapeID(), b = ShapeID(), c = ShapeID(), d = ShapeID()
        let h = try harness(box(a, 0, 0), box(b, 600, 0), box(c, 0, 1000), box(d, 0, 1600), box(ShapeID(), 2000, 2000))
        let surroundings = try require(Surroundings(on: .root, moving: hundred, in: h.editor))
        let across = surroundings.between(a, b)
        expectEqual(across?.rect, at(300, 0), "side by side")
        expectEqual(across?.board, .root)
        expectEqual(across?.above, [])
        let rect = try require(across?.rect)
        expect(rect.minX - 100 >= PlacingStyle.arrowRoom && 600 - rect.maxX >= PlacingStyle.arrowRoom, "each arrow has its room")
        expectEqual(surroundings.between(c, d)?.rect, at(0, 1300), "one above the other")
        expectEqual(surroundings.between(b, a)?.rect, at(300, 0), "whichever is named first")
        // Apart on both axes: the wider gap, centered on the middle of the two.
        let e = ShapeID(), f = ShapeID()
        let offset = try harness(box(e, 0, 0), box(f, 600, 200))
        expectEqual(Surroundings(on: .root, moving: hundred, in: offset.editor)?.between(e, f)?.rect, at(300, 100))
    },

    test("between: both are read taller by what they are about to grow, and a gap that holds the box only without it is passed over") {
        let a = ShapeID(), b = ShapeID()
        let h = try harness(box(a, 0, 0), box(b, 0, 400))
        let surroundings = try require(Surroundings(on: .root, moving: hundred, in: h.editor))
        expectEqual(surroundings.between(a, b)?.rect, at(0, 200), "a gap of 300 holds 100 and two rooms of 80")
        let grown = try require(surroundings.between(a, b, growing: 60)?.rect)
        expect(grown.minX >= 100 || grown.maxX <= 0, "the gap is 240 once the first is 60 taller, and holds nothing: beside the middle, across the line: \(grown)")
        expect(!grown.intersects(at(0, 0, 100, 160)) && !grown.intersects(at(0, 400, 100, 160)), "clear of both as they will be")
        // The first is read taller below its bottom: a gap that still holds the box is narrower, and centered in what's left.
        let wide = ShapeID(), far = ShapeID()
        let roomy = try harness(box(wide, 0, 0), box(far, 0, 600))
        expectEqual(Surroundings(on: .root, moving: hundred, in: roomy.editor)?.between(wide, far, growing: 60)?.rect, at(0, 330),
                    "the gap runs from 160 to 600, so its middle holds the box at 330")
    },

    test("between: a spot something else is in, or a gap too small, is beside the middle of the two instead, clear of both and of what's there, on the side across the line") {
        let a = ShapeID(), b = ShapeID(), blocker = ShapeID()
        let h = try harness(box(a, 0, 0), box(b, 600, 0), box(blocker, 310, 10, size: 80))
        let taken = try require(Surroundings(on: .root, moving: hundred, in: h.editor)?.between(a, b)?.rect)
        for other in [at(0, 0), at(600, 0), at(310, 10, 80, 80)] { expect(!taken.intersects(other), "clear of \(other): \(taken)") }
        expectEqual(taken.midX, 350, "across the line between them, centered on its middle")
        expect(taken.minY >= 100 || taken.maxY <= 0, "above or below both")
        // Too narrow to hold it.
        let near = ShapeID(), nearer = ShapeID()
        let tight = try harness(box(near, 0, 0), box(nearer, 250, 0))
        let beside = try require(Surroundings(on: .root, moving: hundred, in: tight.editor)?.between(near, nearer)?.rect)
        for other in [at(0, 0), at(250, 0)] { expect(!beside.intersects(other), "clear of \(other): \(beside)") }
        expectEqual(beside.midX, 175, "across the line between them, at its middle")
        expect(beside.minY >= 100 || beside.maxY <= 0, "above or below both")
    },

    test("between: a shape that fills the gap, in the middle of it and over the point the two are beside, is in the way like any other: the box lands clear of it and of both, across the line") {
        let a = ShapeID(), b = ShapeID(), wall = ShapeID(), planks = (0..<3).map { _ in ShapeID() }
        let h = try harness(box(a, 0, 0), box(b, 1000, 0), box(wall, 250, -150, size: 500))
        let surroundings = try require(Surroundings(on: .root, moving: hundred, in: h.editor))
        let landed = try require(surroundings.between(a, b)?.rect)
        for other in [at(0, 0), at(1000, 0), at(250, -150, 500, 500)] { expect(!landed.intersects(other), "clear of \(other): \(landed)") }
        // The same with several shapes across it, none of them holding the point alone.
        let slats = try harness(box(a, 0, 0), box(b, 1000, 0), box(planks[0], 250, -150, size: 200), box(planks[1], 450, -150, size: 200), box(planks[2], 650, -150, size: 200))
        let beside = try require(Surroundings(on: .root, moving: hundred, in: slats.editor)?.between(a, b)?.rect)
        for other in [at(0, 0), at(1000, 0), at(250, -150, 200, 200), at(450, -150, 200, 200), at(650, -150, 200, 200)] { expect(!beside.intersects(other), "clear of \(other): \(beside)") }
    },

    test("between: one of the two not drawn is beside the other; neither is nothing; the board they are on can't be shown is no surroundings") {
        let a = ShapeID()
        let h = try harness(box(a, 400, 400))
        let surroundings = try require(Surroundings(on: .root, moving: hundred, in: h.editor))
        expectEqual(surroundings.between(a, ShapeID())?.rect, surroundings.near(a)?.rect)
        expectEqual(surroundings.between(ShapeID(), a)?.rect, surroundings.near(a)?.rect)
        expect(surroundings.between(ShapeID(), ShapeID()) == nil)
    },
])

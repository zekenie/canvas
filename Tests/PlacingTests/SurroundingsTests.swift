@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Placing
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
])

@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Draw
import TestKit

// Where Insert puts a shape down with Draw installed (its plugin claims the core's insertion spot): beside the
// selection as `Surroundings.near` lands a box beside a shape, or with none `anywhere`, in the middle of the view
// or the nearest spot round it clear of what's there. Tiles (120 × 80) are what's inserted; the view is 800 × 600
// at the origin at 100%, so its middle is (400, 300).

@MainActor private func harness(view: Bool = true, _ records: AnyShapeRecord...) throws -> EditorHarness {
    let h = try EditorHarness(plugins: [DrawPlugin(), FixturesPlugin(), CorralsPlugin(), TilesPlugin()],
                              file: CanvasFile(root: CanvasDocument(shapes: records)))
    if view { h.editor.viewportDidResize(to: CGSize(width: 800, height: 600)) }
    return h
}

@MainActor private func box(_ id: ShapeID, _ x: CGFloat, _ y: CGFloat, size: CGFloat = 100, in container: ShapeID? = nil) -> AnyShapeRecord {
    AnyShapeRecord(ShapeRecord(id: id, Box(CGRect(x: x, y: y, width: size, height: size)))).copy(as: id, container: container)
}

@MainActor private func corral(_ id: ShapeID, _ frame: CGRect) -> AnyShapeRecord {
    AnyShapeRecord(ShapeRecord(id: id, Corral(frame)))
}

private let tile = ToolID(placing: Tile.kind)

/// The tile Insert put down last.
@MainActor private func inserted(_ h: EditorHarness) throws -> AnyShapeRecord {
    try require(h.editor.document.shapes.last { $0.kind == Tile.kind })
}

@MainActor let insertingTests = Suite("Inserting", [
    test("beside one shape: where Placing puts the box beside it, right of it when that's free") {
        let a = ShapeID()
        let h = try harness(box(a, 0, 0))
        let expected = try require(Surroundings(on: .root, moving: TilesPlugin.size, in: h.editor)?.near(a)?.rect)
        expect(h.editor.insert(tile, beside: [a]))
        expectEqual(try inserted(h).box, expected)
        expectEqual(expected.minX, 180, "80 right of it")
        expectEqual(expected.midY, 50, "centered on it")
    },
    test("beside a shape in a frame, within the frame, and held by it once put down") {
        let k = ShapeID(), a = ShapeID()
        let h = try harness(corral(k, CGRect(x: -100, y: -100, width: 600, height: 400)), box(a, 0, 0, in: k))
        let expected = try require(Surroundings(on: .root, moving: TilesPlugin.size, in: h.editor)?.near(a, within: k)?.rect)
        expect(h.editor.insert(tile, beside: [a]))
        let placed = try inserted(h)
        expectEqual(placed.box, expected)
        expect(CGRect(x: -100, y: -100, width: 600, height: 400).contains(expected), "inside the frame")
        expectEqual(placed.container, k)
    },
    test("beside several shapes: beside the box around them") {
        let a = ShapeID(), b = ShapeID()
        let h = try harness(box(a, 0, 0), box(b, 0, 200))
        let expected = try require(Surroundings(on: .root, moving: TilesPlugin.size, in: h.editor)?
            .near(CGRect(x: 0, y: 0, width: 100, height: 300))?.rect)
        expect(h.editor.insert(tile, beside: [a, b]))
        expectEqual(try inserted(h).box, expected)
        expectEqual(expected.midY, 150, "centered on the two")
    },
    test("with nothing beside, in the middle of the view, or the nearest spot round it clear of what's there") {
        let h = try harness()
        expect(h.editor.insert(tile, beside: []))
        expectEqual(try inserted(h).box, CGRect(x: 340, y: 260, width: 120, height: 80), "the middle of the view")
        let a = ShapeID()
        let crowded = try harness(box(a, 350, 250))
        let expected = try require(Surroundings(on: .root, moving: TilesPlugin.size, in: crowded.editor)?.anywhere().rect)
        expect(crowded.editor.insert(tile, beside: []))
        let placed = try inserted(crowded)
        expectEqual(placed.box, expected)
        expect(!(placed.box ?? .null).intersects(CGRect(x: 350, y: 250, width: 100, height: 100)), "clear of the box in the middle")
    },
    test("with no view and nothing beside, nowhere to put it: nothing") {
        let h = try harness(view: false)
        expect(!h.editor.insert(tile, beside: []))
        expect(h.editor.document.shapes.isEmpty)
    },
])

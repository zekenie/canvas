import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import TestKit

// The outline of a closed shape (the selection's, a hover's, the hint) stands off its edge by
// `Style.outlineStandoff` view points, the same for every kind; an open shape's is on its own path;
// zoomed out it's the skeleton's ring on the frame. EditorHarness draws with no standoff (the pixel
// tests written before it read outlines on the edge), so these set it to what ships.

/// A box kind whose outline is its frame with corners rounded 12 points, as a note's is, a frame's,
/// a card's and a subboard's, each by its own radius. It draws nothing, so its outline is the only
/// thing drawn over the canvas.
struct Plaque: BoxShapeProps {
    static let kind: ShapeKind = "plaque"
    static let properties = Properties<Plaque> {
        Property("frame", \.frame).required()
    }
    var frame: CGRect
    init(_ frame: CGRect) { self.frame = frame }
}

extension Plaque {
    init() { self.init(.zero) }
}

struct PlaqueDefinition {}

extension PlaqueDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Plaque>, in context: RenderContext) {}
    func indicatorPath(of shape: ShapeRecord<Plaque>, in context: ShapeContext) -> CGPath {
        CGPath(roundedRect: shape.frame, cornerWidth: 12, cornerHeight: 12, transform: nil)
    }
}

/// Boxes, links, diamonds (a closed outline that isn't a rect) and plaques (rounded rects), with a
/// plugin that outlines what `outlined` says (PictureTests'), and the standoff the app ships (or
/// `standoff`).
@MainActor func outlineHarness(_ outlined: Outlined, standoff: CGFloat = Style.outlineStandoff) throws -> EditorHarness {
    let h = try EditorHarness(plugins: [FixturesPlugin(), LinksPlugin(), Contributor(id: "outliner") { r in
        r.shape(DiamondDefinition())
        r.shape(PlaqueDefinition())
        r.outlines { _ in Outlines(shapes: outlined.shapes, rects: outlined.rects, faintShapes: outlined.faint) }
    }])
    h.editor.outlineStandoff = standoff
    return h
}

@MainActor private func expectBox(_ box: CGRect, _ expected: CGRect, _ message: String) {
    for (actual, wanted) in [(box.minX, expected.minX), (box.minY, expected.minY), (box.width, expected.width), (box.height, expected.height)] {
        expect(abs(actual - wanted) < 0.01, "\(message): \(box), not \(expected)")
    }
}

private let outlineCanvas = CGSize(width: 320, height: 240)

@MainActor let outlineTests = Suite("Outlines", [
    test("a closed shape's outline stands off its edge 4 view points on every side, at 100% and 200% alike, and never over the shape") {
        requireShippedStandoff()
        for zoom: CGFloat in [1, 2] {
            let outlined = Outlined()
            let h = try outlineHarness(outlined)
            h.editor.camera = Camera(origin: .zero, zoom: zoom)
            let box = h.add(Box(CGRect(x: 40, y: 40, width: 80, height: 40)))
            let plain = renderBitmap(h.editor, size: outlineCanvas)
            outlined.shapes = [box]
            let drawn = renderBitmap(h.editor, size: outlineCanvas)
            // The box on screen, from (left, top) to (right, bottom); each side's line is 1.5 points
            // wide, centered 4 out, so it covers two columns or rows, 3 and 4 out, a quarter short.
            let left = 40 * zoom, top = 40 * zoom, right = 120 * zoom, bottom = 80 * zoom
            let middle = CGPoint(x: 80 * zoom, y: 60 * zoom)
            let sides = [("left", CGRect(x: left - 5, y: middle.y - 10, width: 2, height: 20)),
                         ("right", CGRect(x: right + 3, y: middle.y - 10, width: 2, height: 20)),
                         ("top", CGRect(x: middle.x - 10, y: top - 5, width: 20, height: 2)),
                         ("bottom", CGRect(x: middle.x - 10, y: bottom + 3, width: 20, height: 2))]
            for (side, line) in sides {
                expect(changedPixels(plain, drawn, in: line) > 20, "the \(side) line, 4 points out, at \(zoom * 100)%")
            }
            // The shape itself and 2 points past its edge, clear of the line, and the gap between.
            let shape = CGRect(x: left, y: top, width: right - left, height: bottom - top)
            expectEqual(changedPixels(plain, drawn, in: shape.insetBy(dx: -2, dy: -2)), 0, "the shape and the gap as they were, at \(zoom * 100)%")
            #if DEBUG
            expectEqual(h.editor.outlinesGrownByArithmetic, 0, "a rect is grown directly, not by path arithmetic")
            #endif
        }
    },
    test("its corners are concentric with the shape's: a rounded rect's grow by the gap, a plain rect's are the gap's radius") {
        requireShippedStandoff()
        // A plaque, corners of 12 about (52, 52): its outline's, 16 about the same center, passes
        // through the pixel (40, 40) on the diagonal and not (39, 39) or (36, 36), where a rect grown by 4
        // with the shape's own 12 (centered (48, 48)) or with square corners would.
        let round = Outlined()
        let h = try outlineHarness(round)
        let plaque = h.add(Plaque(CGRect(x: 40, y: 40, width: 80, height: 40)))
        let plain = renderBitmap(h.editor, size: outlineCanvas)
        round.shapes = [plaque]
        let drawn = renderBitmap(h.editor, size: outlineCanvas)
        @MainActor func changed(_ x: CGFloat, _ y: CGFloat) -> Int { changedPixels(plain, drawn, in: CGRect(x: x, y: y, width: 1, height: 1)) }
        expectEqual(changed(40, 40), 1, "on the rounded corner, 16 from its center")
        expectEqual(changed(39, 39), 0, "not where a rect grown 4 with the shape's own radius would be")
        expectEqual(changed(36, 36), 0, "nor at a square corner")
        expect(changedPixels(plain, drawn, in: CGRect(x: 70, y: 35, width: 20, height: 2)) > 20, "and along the side, 4 out")
        #if DEBUG
        expectEqual(h.editor.outlinesGrownByArithmetic, 0, "a rounded rect is recognized, and grown directly")
        #endif

        // A box has square corners; its outline's are round, radius 4 about its corner (40, 40).
        let square = Outlined()
        let b = try outlineHarness(square)
        let box = b.add(Box(CGRect(x: 40, y: 40, width: 80, height: 40)))
        let boxPlain = renderBitmap(b.editor, size: outlineCanvas)
        square.shapes = [box]
        let boxDrawn = renderBitmap(b.editor, size: outlineCanvas)
        expect(changedPixels(boxPlain, boxDrawn, in: CGRect(x: 37, y: 37, width: 1, height: 1)) > 0, "round, 4 from the corner")
        expectEqual(changedPixels(boxPlain, boxDrawn, in: CGRect(x: 35, y: 35, width: 1, height: 1)), 0, "not square")
    },
    test("a hover's faint outline is where the selection's is, and the hint is the same line as the selection's") {
        requireShippedStandoff()
        let outlined = Outlined()
        let h = try outlineHarness(outlined)
        let box = h.add(Box(CGRect(x: 40, y: 40, width: 80, height: 40)))
        let plain = renderBitmap(h.editor, size: outlineCanvas)
        outlined.faint = [box]
        let hovered = renderBitmap(h.editor, size: outlineCanvas)
        // The faint line is 2.5 wide centered 4 out: 2.75 to 5.25, so columns 123 and 124 whole.
        expect(changedPixels(plain, hovered, in: CGRect(x: 123, y: 50, width: 2, height: 20)) > 20, "the hover's line, 4 points out")
        expectEqual(changedPixels(plain, hovered, in: CGRect(x: 100, y: 50, width: 22, height: 20)), 0, "the edge and the gap, as they were")
        outlined.faint = []
        outlined.shapes = [box]
        let selected = renderBitmap(h.editor, size: outlineCanvas)
        outlined.shapes = []
        h.editor.hintedShapeID = box
        let hinted = renderBitmap(h.editor, size: outlineCanvas)
        expect(changedPixels(plain, selected, in: CGRect(x: 123, y: 50, width: 2, height: 20)) > 20, "the selection's line")
        expectEqual(changedPixels(selected, hinted, in: CGRect(origin: .zero, size: outlineCanvas)), 0, "the hint, the same")
    },
    test("an outline that isn't a rect is grown by path arithmetic: a diamond's stands 4 off each of its edges") {
        requireShippedStandoff()
        let outlined = Outlined()
        let h = try outlineHarness(outlined)
        let diamond = h.add(Diamond(CGRect(x: 40, y: 40, width: 80, height: 40)))
        let plain = renderBitmap(h.editor, size: outlineCanvas)
        outlined.shapes = [diamond]
        let drawn = renderBitmap(h.editor, size: outlineCanvas)
        // Its upper right edge runs from (80, 40) to (120, 60), its middle at (100, 50), and outward
        // is (0.447, -0.894): 4 out is (101.8, 46.4), where the pixel (101, 46) is; the edge itself is clear.
        expect(changedPixels(plain, drawn, in: CGRect(x: 101, y: 46, width: 1, height: 1)) > 0, "4 points off the edge")
        expectEqual(changedPixels(plain, drawn, in: CGRect(x: 100, y: 50, width: 1, height: 1)), 0, "not on it")
        expectEqual(changedPixels(plain, drawn, in: CGRect(x: 118, y: 38, width: 8, height: 8)), 0, "nor at the bounds' corner")
        #if DEBUG
        expectEqual(h.editor.outlinesGrownByArithmetic, 1, "a diamond isn't a rect: grown by path arithmetic, once for the frame")
        #endif
    },
    test("an open shape has no inside to stand off from: its outline is stroked on its own path") {
        requireShippedStandoff()
        let outlined = Outlined()
        let h = try outlineHarness(outlined)
        let a = h.add(Box(CGRect(x: 20, y: 20, width: 40, height: 40)))
        let b = h.add(Box(CGRect(x: 100, y: 20, width: 40, height: 40)))
        let link = h.add(Link(from: a, to: b))             // the segment from (40, 40) to (120, 40)
        let plain = renderBitmap(h.editor, size: outlineCanvas)
        h.editor.hintedShapeID = link
        let drawn = renderBitmap(h.editor, size: outlineCanvas)
        expect(changedPixels(plain, drawn, in: CGRect(x: 65, y: 39, width: 30, height: 2)) > 50, "the line, on the segment")
        expectEqual(changedPixels(plain, drawn, in: CGRect(x: 65, y: 30, width: 30, height: 8)), 0, "not 4 points above it")
        expectEqual(changedPixels(plain, drawn, in: CGRect(x: 65, y: 43, width: 30, height: 8)), 0, "nor below")
    },
    test("with no standoff every outline is on its shape's edge, as the proof of concept drew it") {
        let outlined = Outlined()
        let h = try outlineHarness(outlined, standoff: 0)
        let box = h.add(Box(CGRect(x: 40, y: 40, width: 80, height: 40)))
        let plain = renderBitmap(h.editor, size: outlineCanvas)
        outlined.shapes = [box]
        let drawn = renderBitmap(h.editor, size: outlineCanvas)
        expect(changedPixels(plain, drawn, in: CGRect(x: 119, y: 50, width: 2, height: 20)) > 20, "the line, on the right edge")
        expectEqual(changedPixels(plain, drawn, in: CGRect(x: 122, y: 50, width: 6, height: 20)), 0, "and nowhere 4 out")
        expect(changedPixels(plain, drawn, in: CGRect(x: 39, y: 50, width: 2, height: 20)) > 20, "on the left edge")
        // The same box as a hint, and with the standoff set back: the line moves out again.
        h.editor.outlineStandoff = Style.outlineStandoff
        let stoodOff = renderBitmap(h.editor, size: outlineCanvas)
        expect(changedPixels(drawn, stoodOff, in: CGRect(x: 123, y: 50, width: 2, height: 20)) > 20, "setting it redraws the outline off the edge")
    },
    test("zoomed out, where shapes are skeletons, an outline is the skeleton's ring on its frame, the standoff or none") {
        let outlined = Outlined()
        let h = try outlineHarness(outlined)
        let box = h.add(Box(CGRect(x: 200, y: 200, width: 500, height: 300)))
        h.editor.camera = Camera(origin: .zero, zoom: 0.2)             // (40, 40) to (140, 100) on screen
        expect(h.editor.drawsSkeletons)
        let plain = renderBitmap(h.editor, size: outlineCanvas)
        outlined.shapes = [box]
        let drawn = renderBitmap(h.editor, size: outlineCanvas)
        h.editor.outlineStandoff = 0
        let bare = renderBitmap(h.editor, size: outlineCanvas)
        expectEqual(changedPixels(drawn, bare, in: CGRect(origin: .zero, size: outlineCanvas)), 0, "the same with and without a standoff")
        expect(changedPixels(plain, drawn, in: CGRect(x: 139, y: 60, width: 2, height: 20)) > 20, "the ring, on the right edge")
        expectEqual(changedPixels(plain, drawn, in: CGRect(x: 143, y: 60, width: 6, height: 20)), 0, "nothing 4 out")
    },
    test("the box around several shapes stands off the same, past each of theirs where it runs between them") {
        requireShippedStandoff()
        let outlined = Outlined()
        let h = try outlineHarness(outlined)
        let a = h.add(Box(CGRect(x: 20, y: 60, width: 40, height: 40)))
        let b = h.add(Box(CGRect(x: 100, y: 120, width: 40, height: 40)))
        let plain = renderBitmap(h.editor, size: outlineCanvas)
        outlined.shapes = [a, b]
        let shapes = renderBitmap(h.editor, size: outlineCanvas)
        outlined.rects = [CGRect(x: 20, y: 60, width: 120, height: 100)]
        let boxed = renderBitmap(h.editor, size: outlineCanvas)
        // Its top edge, 4 above the first box's top, runs on over the second, whose own is at 116;
        // its bottom edge runs below the first box, whose own bottom is 100 and its outline 104.
        expect(changedPixels(shapes, boxed, in: CGRect(x: 100, y: 55, width: 40, height: 2)) > 40, "its top edge, 4 out, over the second box")
        expectEqual(changedPixels(shapes, boxed, in: CGRect(x: 100, y: 59, width: 40, height: 2)), 0, "not on the edge")
        expect(changedPixels(shapes, boxed, in: CGRect(x: 20, y: 163, width: 40, height: 2)) > 40, "its bottom edge, 4 out, under the first box")
        expect(changedPixels(plain, shapes, in: CGRect(x: 16, y: 56, width: 5, height: 5)) > 0, "the shapes' own are there too")
    },
    test("a shape drawn away from where it is has its outline there, standing off it") {
        let outlined = Outlined()
        let h = try outlineHarness(outlined)
        let box = h.add(Box(CGRect(x: 40, y: 40, width: 80, height: 40)))
        h.editor.setDrawingOffset(CGPoint(x: 10, y: 0), for: box)
        let plain = renderBitmap(h.editor, size: outlineCanvas)
        outlined.shapes = [box]
        let drawn = renderBitmap(h.editor, size: outlineCanvas)
        expect(changedPixels(plain, drawn, in: CGRect(x: 133, y: 50, width: 2, height: 20)) > 20, "10 points right, 4 off the edge")
        expectEqual(changedPixels(plain, drawn, in: CGRect(x: 123, y: 50, width: 2, height: 20)), 0, "not where the shape is")
    },
    test("`outlinePath(of:)` is what the canvas strokes: a closed shape's outline grown by the gap in world units, an open one's as it is") {
        let h = try outlineHarness(Outlined())
        let frame = CGRect(x: 40, y: 40, width: 80, height: 40)
        // The document is a value: read it after the shape is added, not before (as an argument's
        // base `h.editor.document[h.add(…)]` would, copying it first).
        @MainActor func record(_ id: ShapeID) throws -> AnyShapeRecord { try require(h.editor.document[id]) }
        let box = try record(h.add(Box(frame)))
        let plaque = try record(h.add(Plaque(frame.offsetBy(dx: 0, dy: 100))))
        let diamond = try record(h.add(Diamond(frame.offsetBy(dx: 120, dy: 0))))
        let line = try record(h.add(Link(from: box.id, to: plaque.id)))
        expectEqual(h.editor.outlineGap, 4)
        expectBox(try require(h.editor.outlinePath(of: box)).boundingBoxOfPath, frame.insetBy(dx: -4, dy: -4), "a box, 4 out")
        expectBox(try require(h.editor.outlinePath(of: plaque)).boundingBoxOfPath, frame.offsetBy(dx: 0, dy: 100).insetBy(dx: -4, dy: -4), "a plaque")
        // The plaque's is a rounded rect of radius 16, the box's of radius 4: (37, 37) is outside a
        // 4-radius corner about (40, 40), and (39.99, 39.99) outside a 16-radius one about (52, 152).
        let boxRing = try require(h.editor.outlinePath(of: box)), plaqueRing = try require(h.editor.outlinePath(of: plaque))
        expect(!boxRing.contains(CGPoint(x: 37, y: 37)) && boxRing.contains(CGPoint(x: 38, y: 38)), "the box's corners are round")
        expect(!plaqueRing.contains(CGPoint(x: 40, y: 140)) && plaqueRing.contains(CGPoint(x: 41.4, y: 141.4)), "the plaque's are concentric")
        // A diamond's, 3 off the middle of an edge is in it, and 5 is out.
        let diamondRing = try require(h.editor.outlinePath(of: diamond))
        expect(diamondRing.contains(CGPoint(x: 221.3, y: 47.3)) && !diamondRing.contains(CGPoint(x: 222.3, y: 45.5)), "a diamond's is 4 off its edges")
        expectBox(try require(h.editor.outlinePath(of: line)).boundingBoxOfPath, CGRect(x: 80, y: 60, width: 0, height: 100), "an open one's as it is")
        // At 200% the gap is 2 world units, still 4 view points.
        h.editor.camera = Camera(origin: .zero, zoom: 2)
        expectBox(try require(h.editor.outlinePath(of: box)).boundingBoxOfPath, frame.insetBy(dx: -2, dy: -2), "a box, 4 view points out at 200%")
        // And none stands off with no standoff.
        h.editor.outlineStandoff = 0
        expectEqual(h.editor.outlineGap, 0)
        expectBox(try require(h.editor.outlinePath(of: box)).boundingBoxOfPath, frame, "a box, on its edge")
    },
])

/// The tests above set the standoff the app ships, so a change to `Style.outlineStandoff` moves
/// their pixels: they're written for 4.
@MainActor private func requireShippedStandoff() {
    expectEqual(Style.outlineStandoff, 4, "these tests' pixels are for a standoff of 4")
}

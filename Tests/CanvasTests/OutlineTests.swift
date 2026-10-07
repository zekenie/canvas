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

/// What an overlay reads of the tinted rings (`OverlayContext.tintedOutset(of:)`), as a frame draws.
@MainActor final class OutsetProbe {
    /// The shapes it's asked about each frame.
    var shapes: [ShapeID] = []
    var outsets: [ShapeID: CGFloat] = [:]
    var greatest: CGFloat = -1
}

struct OutsetProbeOverlay: CanvasOverlay {
    let probe: OutsetProbe
    var space: OverlaySpace { .world }
    func draw(in context: OverlayContext) {
        probe.greatest = context.greatestTintedOutset
        for id in probe.shapes { probe.outsets[id] = context.tintedOutset(of: id) }
    }
}

/// Boxes, links, cables (lines drawn 6 wide), diamonds (a closed outline that isn't a rect) and
/// plaques (rounded rects), with a plugin that outlines what `outlined` says (PictureTests'), and the
/// standoff the app ships (or `standoff`).
@MainActor func outlineHarness(_ outlined: Outlined, standoff: CGFloat = Style.outlineStandoff, probe: OutsetProbe? = nil) throws -> EditorHarness {
    let h = try EditorHarness(plugins: [FixturesPlugin(), LinksPlugin(), CablesPlugin(), Contributor(id: "outliner") { r in
        r.shape(DiamondDefinition())
        r.shape(PlaqueDefinition())
        r.outlines { _ in Outlines(shapes: outlined.shapes, rects: outlined.rects, faintShapes: outlined.faint, tinted: outlined.tinted) }
        if let probe { r.overlay(OutsetProbeOverlay(probe: probe)) }
    }])
    h.editor.outlineStandoff = standoff
    return h
}

/// Pure colors for tinted outlines, so a pixel says which of them drew it whatever the bitmap's
/// color space makes of the rest.
private let tintRed = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
private let tintGreen = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
private func isRed(_ p: [Int]) -> Bool { p[0] > 200 && p[1] < 80 && p[2] < 80 }
private func isGreen(_ p: [Int]) -> Bool { p[1] > 200 && p[0] < 80 && p[2] < 80 }
private func isDark(_ p: [Int]) -> Bool { p[0] < 100 && p[1] < 100 && p[2] < 100 }

/// How many view points of `tintRed` lie across a column of `rep`, rows `rows` of it: each pixel's
/// share of it, from how far its red is past its green (the canvas and black have none, pure red
/// all 255, and a blend of red over either is that much of it).
@MainActor private func redThickness(_ rep: NSBitmapImageRep, column x: CGFloat, rows: ClosedRange<Int>) -> CGFloat {
    rows.reduce(0) { total, y in
        let p = pixel(rep, at: CGPoint(x: x, y: CGFloat(y)))
        return total + CGFloat(p[0] - p[1]) / 255
    }
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
    test("a tinted shape's outline is in its color, 2 view points wide, 4 off the edge on every side at 100% and 200% alike, never over the shape") {
        requireShippedStandoff()
        for zoom: CGFloat in [1, 2] {
            let outlined = Outlined()
            let h = try outlineHarness(outlined)
            h.editor.camera = Camera(origin: .zero, zoom: zoom)
            let box = h.add(Box(CGRect(x: 40, y: 40, width: 80, height: 40)))
            let plain = renderBitmap(h.editor, size: outlineCanvas)
            outlined.tinted = [TintedOutlines(color: tintRed, shapes: [box])]
            let drawn = renderBitmap(h.editor, size: outlineCanvas)
            // The box on screen, from (left, top) to (right, bottom). Each side's line, 2 points wide and centered
            // 4 out, covers the two pixels 3 and 4 out, and nothing of those either side of them.
            let left = 40 * zoom, top = 40 * zoom, right = 120 * zoom, bottom = 80 * zoom
            let middle = CGPoint(x: 80 * zoom, y: 60 * zoom)
            for (side, probes) in [("left", [CGPoint(x: left - 5, y: middle.y), CGPoint(x: left - 4, y: middle.y)]),
                                   ("right", [CGPoint(x: right + 3, y: middle.y), CGPoint(x: right + 4, y: middle.y)]),
                                   ("top", [CGPoint(x: middle.x, y: top - 5), CGPoint(x: middle.x, y: top - 4)]),
                                   ("bottom", [CGPoint(x: middle.x, y: bottom + 3), CGPoint(x: middle.x, y: bottom + 4)])] {
                for probe in probes { expect(isRed(pixel(drawn, at: probe)), "the \(side) line, in its color, 4 points out at \(zoom * 100)%: \(pixel(drawn, at: probe))") }
            }
            let shape = CGRect(x: left, y: top, width: right - left, height: bottom - top)
            // The line's inner edge is 3 out (a corner's, 3 from the shape's corner), so the shape and the first
            // two points of the gap are as they were.
            expectEqual(changedPixels(plain, drawn, in: shape.insetBy(dx: -2, dy: -2)), 0, "the shape and the gap as they were, at \(zoom * 100)%")
            expectEqual(pixel(drawn, at: CGPoint(x: right + 2, y: middle.y)), pixel(plain, at: CGPoint(x: right + 2, y: middle.y)), "the gap, up to the line")
            expect(!isRed(pixel(drawn, at: CGPoint(x: right + 5, y: middle.y))), "nothing further out")
            #if DEBUG
            expectEqual(h.editor.outlinesGrownByArithmetic, 0, "a rect is grown directly, not by path arithmetic")
            #endif
        }
    },
    test("a second ring stands a line and a gap further out, 4 view points more at every zoom, so a shape in two groups shows both") {
        requireShippedStandoff()
        for zoom: CGFloat in [1, 2] {
            let outlined = Outlined()
            let h = try outlineHarness(outlined)
            h.editor.camera = Camera(origin: .zero, zoom: zoom)
            let box = h.add(Box(CGRect(x: 40, y: 40, width: 80, height: 40)))
            let right = 120 * zoom, bottom = 80 * zoom, middle = CGPoint(x: 80 * zoom, y: 60 * zoom)
            let plain = renderBitmap(h.editor, size: outlineCanvas)
            outlined.tinted = [TintedOutlines(color: tintRed, shapes: [box]), TintedOutlines(color: tintGreen, shapes: [box], ring: 1)]
            let drawn = renderBitmap(h.editor, size: outlineCanvas)
            for x in [right + 3, right + 4] { expect(isRed(pixel(drawn, at: CGPoint(x: x, y: middle.y))), "the first ring, 4 out, at \(zoom * 100)%") }
            for x in [right + 7, right + 8] { expect(isGreen(pixel(drawn, at: CGPoint(x: x, y: middle.y))), "the second, 8 out, at \(zoom * 100)%") }
            // The gap between them is 2 points: two pixels of the canvas, whole; and nothing is past the second.
            for x in [right + 5, right + 6, right + 9] {
                expectEqual(pixel(drawn, at: CGPoint(x: x, y: middle.y)), pixel(plain, at: CGPoint(x: x, y: middle.y)), "the canvas, \(x - right) out, at \(zoom * 100)%")
            }
            for y in [bottom + 7, bottom + 8] { expect(isGreen(pixel(drawn, at: CGPoint(x: middle.x, y: y))), "the second ring runs round the bottom too") }
            // Concentric corners: the second ring is a rounded rect of radius 8 about the box's corner, so the
            // diagonal pixel 5 out each way is in its line (radii 7.1 to 8.5 from the corner) and 7 out isn't.
            expect(isGreen(pixel(drawn, at: CGPoint(x: right + 5, y: bottom + 5))), "its corner is round, concentric with the shape's")
            expect(!isGreen(pixel(drawn, at: CGPoint(x: right + 7, y: bottom + 7))), "not square")
            #if DEBUG
            expectEqual(h.editor.outlinesGrownByArithmetic, 0)
            #endif
        }
    },
    test("tinted outlines are stroked under every other: a selected shape's line shows over its tint, and so does a hover's") {
        requireShippedStandoff()
        let outlined = Outlined()
        let h = try outlineHarness(outlined)
        let box = h.add(Box(CGRect(x: 40, y: 40, width: 80, height: 40)))
        outlined.tinted = [TintedOutlines(color: tintRed, shapes: [box])]
        let tinted = renderBitmap(h.editor, size: outlineCanvas)
        let line = CGRect(x: 123, y: 50, width: 2, height: 20)
        expect(isRed(pixel(tinted, at: CGPoint(x: 123, y: 60))) && isRed(pixel(tinted, at: CGPoint(x: 124, y: 60))), "the tint alone")
        outlined.shapes = [box]
        let selected = renderBitmap(h.editor, size: outlineCanvas)
        expect(largestDifference(tinted, selected, in: line) > 60, "the selection's 1.5-point line, the same place, over it")
        expect(!isRed(pixel(selected, at: CGPoint(x: 123, y: 60))) && !isRed(pixel(selected, at: CGPoint(x: 124, y: 60))), "which the tint doesn't cover")
        outlined.shapes = []
        outlined.faint = [box]
        let hovered = renderBitmap(h.editor, size: outlineCanvas)
        expect(largestDifference(tinted, hovered, in: line) > 30, "a hover's faint line, over it too")
        expect(!isRed(pixel(hovered, at: CGPoint(x: 123, y: 60))), "the tint isn't over it")
        // The hint is the selection's line.
        outlined.faint = []
        h.editor.hintedShapeID = box
        expectEqual(largestDifference(selected, renderBitmap(h.editor, size: outlineCanvas), in: CGRect(origin: .zero, size: outlineCanvas)), 0,
                    "hinted, the same as selected")
    },
    test("zoomed out, where shapes are skeletons, a tinted outline is a ring on the shape's frame, and a second one is grown by a line and a gap") {
        let outlined = Outlined()
        let h = try outlineHarness(outlined)
        let box = h.add(Box(CGRect(x: 200, y: 200, width: 500, height: 300)))
        h.editor.camera = Camera(origin: .zero, zoom: 0.2)             // (40, 40) to (140, 100) on screen
        expect(h.editor.drawsSkeletons)
        let plain = renderBitmap(h.editor, size: outlineCanvas)
        outlined.tinted = [TintedOutlines(color: tintRed, shapes: [box])]
        let first = renderBitmap(h.editor, size: outlineCanvas)
        // A ring 2 points wide on the edge: the two pixels either side of x = 140.
        for x in [139, 140] as [CGFloat] { expect(isRed(pixel(first, at: CGPoint(x: x, y: 70))), "the ring, on the right edge: \(pixel(first, at: CGPoint(x: x, y: 70)))") }
        expectEqual(changedPixels(plain, first, in: CGRect(x: 143, y: 60, width: 6, height: 20)), 0, "nothing 4 out")
        outlined.tinted = [TintedOutlines(color: tintRed, shapes: [box]), TintedOutlines(color: tintGreen, shapes: [box], ring: 1)]
        let second = renderBitmap(h.editor, size: outlineCanvas)
        for x in [143, 144] as [CGFloat] { expect(isGreen(pixel(second, at: CGPoint(x: x, y: 70))), "the second ring, 4 points further out") }
        for y in [103, 104] as [CGFloat] { expect(isGreen(pixel(second, at: CGPoint(x: 90, y: y))), "and below") }
        expect(isRed(pixel(second, at: CGPoint(x: 139, y: 70))), "the first is where it was")
        h.editor.outlineStandoff = 0
        expectEqual(changedPixels(second, renderBitmap(h.editor, size: outlineCanvas), in: CGRect(origin: .zero, size: outlineCanvas)), 0,
                    "the standoff changes neither")
    },
    test("an open shape is stroked on its own path whatever its ring") {
        requireShippedStandoff()
        let outlined = Outlined()
        let h = try outlineHarness(outlined)
        let a = h.add(Box(CGRect(x: 20, y: 20, width: 40, height: 40)))
        let b = h.add(Box(CGRect(x: 100, y: 20, width: 40, height: 40)))
        let link = h.add(Link(from: a, to: b))             // the segment from (40, 40) to (120, 40)
        let plain = renderBitmap(h.editor, size: outlineCanvas)
        for ring in 0...2 {
            outlined.tinted = [TintedOutlines(color: tintGreen, shapes: [link], ring: ring)]
            let drawn = renderBitmap(h.editor, size: outlineCanvas)
            for y in [39, 40] as [CGFloat] { expect(isGreen(pixel(drawn, at: CGPoint(x: 80, y: y))), "the line, on the segment, ring \(ring)") }
            expectEqual(changedPixels(plain, drawn, in: CGRect(x: 65, y: 28, width: 30, height: 8)), 0, "not stood off above it, ring \(ring)")
            expectEqual(changedPixels(plain, drawn, in: CGRect(x: 65, y: 44, width: 30, height: 12)), 0, "nor below, ring \(ring)")
        }
    },
    test("a tinted shape that's outlined in full too stands one ring further out, 8 view points off, clear of the selection's line; one that's only tinted stays 4 off") {
        requireShippedStandoff()
        for zoom: CGFloat in [1, 2] {
            let outlined = Outlined()
            let h = try outlineHarness(outlined)
            h.editor.camera = Camera(origin: .zero, zoom: zoom)
            let selected = h.add(Box(CGRect(x: 10, y: 20, width: 50, height: 30)))
            let other = h.add(Box(CGRect(x: 90, y: 20, width: 50, height: 30)))
            let selectedRight = 60 * zoom, otherRight = 140 * zoom, middle = 35 * zoom
            outlined.tinted = [TintedOutlines(color: tintRed, shapes: [selected, other])]
            outlined.shapes = [selected]
            let drawn = renderBitmap(h.editor, size: outlineCanvas)
            for x in [selectedRight + 7, selectedRight + 8] { expect(isRed(pixel(drawn, at: CGPoint(x: x, y: middle))), "the selected shape's tint, 8 out, at \(zoom * 100)%") }
            for x in [selectedRight + 3, selectedRight + 4] { expect(!isRed(pixel(drawn, at: CGPoint(x: x, y: middle))), "not where it was, where the selection's line is") }
            for x in [otherRight + 3, otherRight + 4] { expect(isRed(pixel(drawn, at: CGPoint(x: x, y: middle))), "the other's, 4 out, at \(zoom * 100)%") }
            for x in [otherRight + 7, otherRight + 8] { expect(!isRed(pixel(drawn, at: CGPoint(x: x, y: middle))), "and not 8") }
            expect(isRed(pixel(drawn, at: CGPoint(x: 35 * zoom, y: 50 * zoom + 7))) && isRed(pixel(drawn, at: CGPoint(x: 35 * zoom, y: 50 * zoom + 8))),
                   "round the bottom of the selected one too")
            // The corner is concentric, a rounded rect of radius 8 about the box's, as any second ring's is.
            expect(isRed(pixel(drawn, at: CGPoint(x: selectedRight + 5, y: 50 * zoom + 5))) && !isRed(pixel(drawn, at: CGPoint(x: selectedRight + 7, y: 50 * zoom + 7))),
                   "its corner round")
            // The hint is the selection's line, and moves a tint as it does.
            outlined.shapes = []
            h.editor.hintedShapeID = selected
            expect(isRed(pixel(renderBitmap(h.editor, size: outlineCanvas), at: CGPoint(x: selectedRight + 7, y: middle))), "the hint, 8 out")
            h.editor.hintedShapeID = nil
            // A hover's faint line is over the tint where it is, and moves nothing.
            outlined.faint = [selected]
            let hovered = renderBitmap(h.editor, size: outlineCanvas)
            expect(!isRed(pixel(hovered, at: CGPoint(x: selectedRight + 7, y: middle))), "a hover moves no tint: nothing 8 out")
            expect(!isRed(pixel(hovered, at: CGPoint(x: selectedRight + 4, y: middle))), "the hover's faint line is over the tint, where it was")
            // Every ring of a shape in two groups moves out: 8 and 12.
            outlined.faint = []
            outlined.shapes = [selected]
            outlined.tinted = [TintedOutlines(color: tintRed, shapes: [selected, other]), TintedOutlines(color: tintGreen, shapes: [selected], ring: 1)]
            let two = renderBitmap(h.editor, size: outlineCanvas)
            for x in [selectedRight + 7, selectedRight + 8] { expect(isRed(pixel(two, at: CGPoint(x: x, y: middle))), "the first light's, 8 out") }
            for x in [selectedRight + 11, selectedRight + 12] { expect(isGreen(pixel(two, at: CGPoint(x: x, y: middle))), "the second's, 12 out") }
            #if DEBUG
            expectEqual(h.editor.outlinesGrownByArithmetic, 0)
            #endif
        }
    },
    test("with a big selection, the ones that are tinted too stand out as well, and the ones that aren't don't") {
        requireShippedStandoff()
        let outlined = Outlined()
        let h = try outlineHarness(outlined)
        // Twelve boxes in two rows of six, the first ten of them selected (more than a few, so they're looked up through a set), and every other one tinted.
        let boxes = (0..<12).map { h.add(Box(CGRect(x: CGFloat($0 % 6) * 50, y: CGFloat($0 / 6) * 50 + 10, width: 30, height: 30))) }
        outlined.shapes = Array(boxes[0..<10])
        outlined.tinted = [TintedOutlines(color: tintRed, shapes: boxes.enumerated().filter { $0.offset % 2 == 0 }.map(\.element))]
        let drawn = renderBitmap(h.editor, size: outlineCanvas)
        for i in boxes.indices {
            let right = CGFloat(i % 6) * 50 + 30, middle = CGFloat(i / 6) * 50 + 25
            let tinted = i % 2 == 0, selected = i < 10
            let near = isRed(pixel(drawn, at: CGPoint(x: right + 3, y: middle))), far = isRed(pixel(drawn, at: CGPoint(x: right + 7, y: middle)))
            expect(near == (tinted && !selected), "box \(i): a tint 4 out only where it's not selected")
            expect(far == (tinted && selected), "box \(i): a tint 8 out only where it's selected")
        }
    },
    test("zoomed out, a tinted shape that's outlined in full too has its ring on the frame grown by one ring more, 4 view points") {
        let outlined = Outlined()
        let h = try outlineHarness(outlined)
        let box = h.add(Box(CGRect(x: 200, y: 200, width: 500, height: 300)))
        h.editor.camera = Camera(origin: .zero, zoom: 0.2)             // (40, 40) to (140, 100) on screen
        expect(h.editor.drawsSkeletons)
        outlined.tinted = [TintedOutlines(color: tintRed, shapes: [box])]
        outlined.shapes = [box]
        let drawn = renderBitmap(h.editor, size: outlineCanvas)
        for x in [143, 144] as [CGFloat] { expect(isRed(pixel(drawn, at: CGPoint(x: x, y: 70))), "the tint, 4 out of the frame: \(pixel(drawn, at: CGPoint(x: x, y: 70)))") }
        expect(!isRed(pixel(drawn, at: CGPoint(x: 139, y: 70))) && !isRed(pixel(drawn, at: CGPoint(x: 140, y: 70))), "not on it, where the selection's ring is")
        for y in [103, 104] as [CGFloat] { expect(isRed(pixel(drawn, at: CGPoint(x: 90, y: y))), "and below") }
    },
    test("a hover's faint outline is stronger beside tinted outlines, since it's the shape they're about, and as it was with none") {
        requireShippedStandoff()
        let outlined = Outlined()
        let h = try outlineHarness(outlined)
        let hovered = h.add(Box(CGRect(x: 40, y: 40, width: 80, height: 40)))
        let lit = h.add(Box(CGRect(x: 200, y: 40, width: 80, height: 40)))
        let plain = renderBitmap(h.editor, size: outlineCanvas)
        outlined.faint = [hovered]
        let alone = renderBitmap(h.editor, size: outlineCanvas)
        outlined.tinted = [TintedOutlines(color: tintRed, shapes: [lit])]
        let beside = renderBitmap(h.editor, size: outlineCanvas)
        outlined.tinted = []
        let after = renderBitmap(h.editor, size: outlineCanvas)
        // The line, 2.5 wide centered 4 out, covers the pixels 123 and 124 whole: the canvas and the accent, by its opacity.
        @MainActor func ink(_ rep: NSBitmapImageRep) -> Int {
            let p = pixel(rep, at: CGPoint(x: 123, y: 60)), q = pixel(plain, at: CGPoint(x: 123, y: 60))
            return zip(p, q).prefix(3).reduce(0) { $0 + abs($1.0 - $1.1) }
        }
        expect(ink(alone) > 150, "the hover alone, over the canvas: \(ink(alone))")
        let ratio = Double(ink(beside)) / Double(ink(alone))
        expect(abs(ratio - 0.85 / 0.6) < 0.05, "85% beside the tint, 60% alone: \(ratio) times as strong")
        expectEqual(ink(after), ink(alone), "as it was once nothing is tinted")
    },
    test("a tinted open shape of a kind drawn as a line is covered, as wide on screen as its line and a point more at 50%, 100% and 200%, so it doesn't stripe; zoomed out, where it's a skeleton, 2 wide") {
        let outlined = Outlined()
        let h = try outlineHarness(outlined)
        let cable = h.add(Cable(from: CGPoint(x: 20, y: 60), to: CGPoint(x: 140, y: 60)))        // 6 units wide
        outlined.tinted = [TintedOutlines(color: tintRed, shapes: [cable])]
        // The line is 6 × the zoom wide on screen: 3, 6 and 12 points; its cover a point more, 4, 7 and 13.
        for (zoom, wide) in [(0.5, 4), (1, 7), (2, 13)] as [(CGFloat, CGFloat)] {
            h.editor.camera = Camera(origin: .zero, zoom: zoom)
            expect(!h.editor.drawsSkeletons)
            let drawn = renderBitmap(h.editor, size: outlineCanvas)
            let line = 60 * zoom, column = 80 * zoom
            let thickness = redThickness(drawn, column: column, rows: 0...Int(outlineCanvas.height) - 1)
            expect(abs(thickness - wide) < 0.1, "\(wide) points of tint across the line at \(zoom * 100)%: \(thickness)")
            for y in Int(line - wide / 2 - 4)...Int(line + wide / 2 + 4) {
                expect(!isDark(pixel(drawn, at: CGPoint(x: column, y: CGFloat(y)))), "none of the line shows through, row \(y), at \(zoom * 100)%")
            }
        }
        // Round, past the line's own round end: at 200% the line ends at 280, 6 wide, its cover 6.5 out from there.
        h.editor.camera = Camera(origin: .zero, zoom: 2)
        let end = renderBitmap(h.editor, size: outlineCanvas)
        expect(isRed(pixel(end, at: CGPoint(x: 285, y: 120))), "its end is covered: \(pixel(end, at: CGPoint(x: 285, y: 120)))")
        let showing = (270..<290).flatMap { x in (110..<131).map { y in CGPoint(x: x, y: y) } }.filter { isDark(pixel(end, at: $0)) }
        expect(showing.isEmpty, "none of the line's end shows through: \(showing)")
        // Whatever the ring, an open shape's is on its path.
        outlined.tinted = [TintedOutlines(color: tintRed, shapes: [cable], ring: 2)]
        let ringTwo = redThickness(renderBitmap(h.editor, size: outlineCanvas), column: 160, rows: 0...239)
        expect(abs(ringTwo - 13) < 0.1, "ring 2, as wide: \(ringTwo)")
        // Zoomed out the skeleton's line is a point wide, and the outline stays the tinted outline's own 2.
        h.editor.camera = Camera(origin: .zero, zoom: 0.2)
        expect(h.editor.drawsSkeletons)
        let skeleton = renderBitmap(h.editor, size: outlineCanvas)
        expect(abs(redThickness(skeleton, column: 16, rows: 0...239) - 2) < 0.1, "2 points zoomed out: \(redThickness(skeleton, column: 16, rows: 0...239))")
    },
    test("a translucent tint is painted as a whole: no darker where a line's cover crosses a box's outline in one group") {
        requireShippedStandoff()
        let outlined = Outlined()
        let h = try outlineHarness(outlined)
        let box = h.add(Box(CGRect(x: 40, y: 40, width: 80, height: 40)))
        let cable = h.add(Cable(from: CGPoint(x: 100, y: 60), to: CGPoint(x: 160, y: 60)))      // across the box's right side
        outlined.tinted = [TintedOutlines(color: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.5), shapes: [box, cable])]
        let drawn = renderBitmap(h.editor, size: outlineCanvas)
        // The box's outline is 3 to 5 out of its right edge (123 to 125), over the cable's cover, which runs on past it.
        let crossing = pixel(drawn, at: CGPoint(x: 124, y: 60)), cover = pixel(drawn, at: CGPoint(x: 135, y: 60))
        expectEqual(crossing, cover, "where the outline and the cover meet, as the cover alone")
        // Over the cable's black, the half-red of the cover, and the outline's alone, over the canvas, is lighter.
        let outline = pixel(drawn, at: CGPoint(x: 124, y: 45))
        expect(outline[0] > cover[0] && outline[1] > cover[1], "the outline over the canvas is lighter than the cover over the cable: \(outline), \(cover)")
    },
    test("only a tinted outline covers a line: the selection's and a hover's stay as thin as they are, however wide the line") {
        let outlined = Outlined()
        let h = try outlineHarness(outlined)
        let cable = h.add(Cable(from: CGPoint(x: 20, y: 60), to: CGPoint(x: 140, y: 60)))
        h.editor.camera = Camera(origin: .zero, zoom: 2)              // the line is 12 wide, from row 114 to 125
        let plain = renderBitmap(h.editor, size: outlineCanvas)
        outlined.shapes = [cable]
        let selected = renderBitmap(h.editor, size: outlineCanvas)
        // The selection's 1.5 points are on the middle of it, rows 119 and 120; the rest of the line is as it was.
        expect(changedPixels(plain, selected, in: CGRect(x: 100, y: 118, width: 60, height: 4)) > 100, "its line, in the middle")
        expectEqual(changedPixels(plain, selected, in: CGRect(x: 100, y: 113, width: 60, height: 5)), 0, "not over the line's upper edge")
        expectEqual(changedPixels(plain, selected, in: CGRect(x: 100, y: 122, width: 60, height: 5)), 0, "nor its lower")
        outlined.shapes = []
        outlined.faint = [cable]
        let hovered = renderBitmap(h.editor, size: outlineCanvas)
        expect(changedPixels(plain, hovered, in: CGRect(x: 100, y: 118, width: 60, height: 4)) > 100, "a hover's, in the middle")
        expectEqual(changedPixels(plain, hovered, in: CGRect(x: 100, y: 113, width: 60, height: 5)), 0, "not over the line's upper edge")
        expectEqual(changedPixels(plain, hovered, in: CGRect(x: 100, y: 122, width: 60, height: 5)), 0, "nor its lower")
    },
    test("an overlay is told how far the tinted rings round a shape stand beyond ring 0: none with none or one, 4 view points for each ring past the first, counting a selected shape's tint a ring further, none for an open shape") {
        let outlined = Outlined(), probe = OutsetProbe()
        let h = try outlineHarness(outlined, probe: probe)
        let a = h.add(Box(CGRect(x: 10, y: 10, width: 40, height: 40)))
        let b = h.add(Box(CGRect(x: 80, y: 10, width: 40, height: 40)))
        let c = h.add(Box(CGRect(x: 150, y: 10, width: 40, height: 40)))
        let d = h.add(Box(CGRect(x: 220, y: 10, width: 40, height: 40)))
        let cable = h.add(Cable(from: CGPoint(x: 10, y: 100), to: CGPoint(x: 100, y: 100)))
        let missing = ShapeID()
        probe.shapes = [a, b, c, d, cable, missing]
        @MainActor func outsets() -> [CGFloat] {
            probe.outsets = [:]
            probe.greatest = -1
            _ = renderBitmap(h.editor, size: outlineCanvas)
            return probe.shapes.map { probe.outsets[$0] ?? -1 }
        }
        expectEqual(outsets(), [0, 0, 0, 0, 0, 0], "no tinted group")
        expectEqual(probe.greatest, 0)
        // A has one ring; B two (0 and 1); C only ring 2; D none; the cable one, on its line.
        outlined.tinted = [TintedOutlines(color: tintRed, shapes: [a, b, cable]), TintedOutlines(color: tintGreen, shapes: [b], ring: 1),
                           TintedOutlines(color: tintRed, shapes: [c], ring: 2)]
        expectEqual(outsets(), [0, 4, 8, 0, 0, 0], "a ring is a line and a gap, 4 points")
        expectEqual(probe.greatest, 8)
        // Selected, a shape's tint is a ring further out: A's is the second ring, B's the third. D isn't tinted, nor the cable's anything but its line.
        outlined.shapes = [a, b, d, cable]
        expectEqual(outsets(), [4, 8, 8, 0, 0, 0], "a selected shape's tint a ring further out")
        expectEqual(probe.greatest, 12, "at most the outermost ring and the one more of a selected one")
        h.editor.camera = Camera(origin: .zero, zoom: 0.2)
        expectEqual(outsets(), [4, 8, 8, 0, 0, 0], "zoomed out, where a ring is on the frame, as far")
        h.editor.camera = Camera(origin: .zero, zoom: 2)
        expectEqual(outsets(), [4, 8, 8, 0, 0, 0], "and zoomed in, in view points")
        outlined.tinted = []
        outlined.shapes = [a]
        expectEqual(outsets(), [0, 0, 0, 0, 0, 0], "none again once nothing is tinted, selected or not")
        expectEqual(probe.greatest, 0)
    },
    test("tinted outlines are left out while the session hides outlines, as the others are") {
        requireShippedStandoff()
        let outlined = Outlined()
        let h = try outlineHarness(outlined)
        let box = h.add(Box(CGRect(x: 40, y: 40, width: 80, height: 40)))
        let plain = renderBitmap(h.editor, size: outlineCanvas)
        outlined.tinted = [TintedOutlines(color: tintRed, shapes: [box])]
        let drawn = renderBitmap(h.editor, size: outlineCanvas)
        expect(changedPixels(plain, drawn, in: CGRect(origin: .zero, size: outlineCanvas)) > 20, "outlined without it")
        h.editor.session = OutlineHidingSession()
        expectEqual(changedPixels(plain, renderBitmap(h.editor, size: outlineCanvas), in: CGRect(origin: .zero, size: outlineCanvas)), 0, "nothing while it runs")
        expect(h.editor.outlines.tinted.isEmpty, "none asked for")
    },
    test("`editor.outlines.tinted` is every plugin's groups, as they come, in plugin order") {
        let first = Outlined(), second = Outlined()
        let h = try EditorHarness(plugins: [FixturesPlugin(), Contributor(id: "first") { r in
            r.outlines { _ in Outlines(shapes: first.shapes, faintShapes: first.faint, tinted: first.tinted) }
        }, Contributor(id: "second") { r in
            r.outlines { _ in Outlines(shapes: second.shapes, faintShapes: second.faint, tinted: second.tinted) }
        }])
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 40, height: 40))), b = h.add(Box(CGRect(x: 100, y: 0, width: 40, height: 40)))
        expect(h.editor.outlines.tinted.isEmpty)
        first.tinted = [TintedOutlines(color: tintRed, shapes: [a]), TintedOutlines(color: tintGreen, shapes: [a, b], ring: 1)]
        second.tinted = [TintedOutlines(color: tintGreen, shapes: [b])]
        expectEqual(h.editor.outlines.tinted, first.tinted + second.tinted, "appended, in source order, rings and all")
        first.shapes = [a]
        second.faint = [b]
        let all = h.editor.outlines
        expectEqual(all.shapes, [a])
        expectEqual(all.faintShapes, [b], "the other lists merge as they did")
        expectEqual(all.tinted.map(\.ring), [0, 1, 0])
        expectEqual(Outlines().tinted, [], "none by default")
        expectEqual(TintedOutlines(color: tintRed, shapes: []).ring, 0, "the first ring by default")
    },
    test("outlines compare equal when all four lists do, so a plugin that keeps what it hands the core can tell what changed") {
        let a = ShapeID(), b = ShapeID()
        let group = TintedOutlines(color: tintRed, shapes: [a, b], ring: 1)
        let outlines = Outlines(shapes: [a], rects: [CGRect(x: 0, y: 0, width: 10, height: 10)], faintShapes: [b], tinted: [group])
        expectEqual(outlines, Outlines(shapes: [a], rects: [CGRect(x: 0, y: 0, width: 10, height: 10)], faintShapes: [b], tinted: [group]))
        expectEqual(Outlines(), Outlines(), "none is none")
        expect(outlines != Outlines(shapes: [b], rects: outlines.rects, faintShapes: [b], tinted: [group]), "shapes")
        expect(outlines != Outlines(shapes: [a], rects: [], faintShapes: [b], tinted: [group]), "rects")
        expect(outlines != Outlines(shapes: [a], rects: outlines.rects, faintShapes: [], tinted: [group]), "faint shapes")
        expect(outlines != Outlines(shapes: [a], rects: outlines.rects, faintShapes: [b], tinted: []), "tinted groups")
        expect(Outlines(tinted: [group]) != Outlines(tinted: [TintedOutlines(color: tintGreen, shapes: [a, b], ring: 1)]), "a group's color")
        expect(Outlines(tinted: [group]) != Outlines(tinted: [TintedOutlines(color: tintRed, shapes: [a, b], ring: 0)]), "a group's ring")
        expect(Outlines(tinted: [group]) != Outlines(tinted: [TintedOutlines(color: tintRed, shapes: [b, a], ring: 1)]), "and the order of its shapes")
    },
])

/// The tests above set the standoff the app ships, so a change to `Style.outlineStandoff` moves
/// their pixels: they're written for 4.
@MainActor private func requireShippedStandoff() {
    expectEqual(Style.outlineStandoff, 4, "these tests' pixels are for a standoff of 4")
}

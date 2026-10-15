import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Keyboard
import Selection
import TableOfContents
import TestKit

// An arrow zoomed out, under 35% (`CustomSkeleton`): the arc through its kept geometry's start,
// middle and end, or its line, never under a view point wide, with its heads filled; its outline
// that arc.

private let canvas = CGSize(width: 180, height: 120)
/// Pixels per point.
private let scale: CGFloat = 4

/// A free arrow from (100, 200) to (500, 200), bent `bend`, drawn at `zoom`, with the canvas outlining
/// in colors of its own what `lit` says, if given.
@MainActor private func arrowHarness(bend: CGFloat, endArrowhead: Bool = true, zoom: CGFloat = 0.3,
                                     lit: TintedOutlinesBox? = nil) throws -> (EditorHarness, ShapeID) {
    let lights = lit.map { lit in [Contributor(id: "lights") { $0.outlines { _ in Outlines(tinted: lit.groups) } }] } ?? []
    let h = try EditorHarness(plugins: arrowsPlugins() + lights)
    let id = h.add(Arrow(start: .free(CGPoint(x: 100, y: 200)), end: .free(CGPoint(x: 500, y: 200)), bend: bend, endArrowhead: endArrowhead))
    h.editor.camera = Camera(origin: .zero, zoom: zoom)
    return (h, id)
}

/// The color where a world point is drawn.
@MainActor private func color(_ rep: NSBitmapImageRep, atWorld point: CGPoint, zoom: CGFloat = 0.3) -> [Int] {
    pixel(rep, at: CGPoint(x: point.x * zoom, y: point.y * zoom), scale: scale)
}

@MainActor private func isInked(_ color: [Int]) -> Bool { color.prefix(3).allSatisfy { $0 < 100 } }

@MainActor let arrowSkeletonTests = Suite("Arrow skeletons", [
    test("at 30% a bent arrow is the arc through its start, middle and end, either way it bends, never the chord") {
        for bend: CGFloat in [100, -100] {
            let (h, id) = try arrowHarness(bend: bend)
            let geometry = try require(h.editor.arrowGeometry(of: id))
            let arc = try require(Arc(from: geometry.start, through: geometry.middle, to: geometry.end))
            let drawn = renderBitmap(h.editor, size: canvas, scale: scale)
            for t: CGFloat in [0.1, 0.25, 0.5, 0.75] {
                expect(isInked(color(drawn, atWorld: arc.point(at: t))), "bent \(bend), along the arc at \(t): \(color(drawn, atWorld: arc.point(at: t)))")
            }
            expect(!isInked(color(drawn, atWorld: (geometry.start + geometry.end) / 2)), "bent \(bend), not the chord")
            expect(!isInked(color(drawn, atWorld: (geometry.start + geometry.middle) / 2)), "bent \(bend), nor a line to its middle")
        }
    },
    test("a straight arrow is its line, a view point wide at the least, with its head a filled triangle at its end") {
        let (h, id) = try arrowHarness(bend: 0)
        let geometry = try require(h.editor.arrowGeometry(of: id))
        let drawn = renderBitmap(h.editor, size: canvas, scale: scale)
        for x: CGFloat in [150, 300, 450] {
            expect(isInked(color(drawn, atWorld: CGPoint(x: x, y: 200))), "along its line at \(x)")
            expect(!isInked(color(drawn, atWorld: CGPoint(x: x, y: 206))), "and no wider, at \(x)")
        }
        // A head is 10.5 long, its wings 30° off: 8.25 back from the tip it's 4.8 either side,
        // where the line, 1.75 either side, isn't.
        let inHead = CGPoint(x: geometry.end.x - 8.25, y: 203)
        expect(isInked(color(drawn, atWorld: inHead)), "its head")
        let (headless, _) = try arrowHarness(bend: 0, endArrowhead: false)
        expect(!isInked(color(renderBitmap(headless.editor, size: canvas, scale: scale), atWorld: inHead)), "none without one")
        let (both, bothID) = try arrowHarness(bend: 0)
        both.editor.transact { $0.update(bothID, as: Arrow.self) { $0.props.startArrowhead = true } }
        expect(isInked(color(renderBitmap(both.editor, size: canvas, scale: scale), atWorld: CGPoint(x: geometry.start.x + 8.25, y: 203))), "and one at its start")

        // At 10% the render's 3.5 units are a third of a point; the skeleton's a point, as solid as
        // the render's line at 100%.
        let (near, _) = try arrowHarness(bend: 0, zoom: 1)
        let solid = pixel(renderBitmap(near.editor, size: CGSize(width: 600, height: 300), scale: 1), at: CGPoint(x: 300, y: 200))
        let (farOut, _) = try arrowHarness(bend: 0, zoom: 0.1)
        let skeleton = renderBitmap(farOut.editor, size: canvas, scale: scale)
        expectEqual(color(skeleton, atWorld: CGPoint(x: 300, y: 200), zoom: 0.1), solid)
        farOut.editor.skeletonZoom = 0
        expect(color(renderBitmap(farOut.editor, size: canvas, scale: scale), atWorld: CGPoint(x: 300, y: 200), zoom: 0.1) != solid, "the render's, fainter")
    },
    test("selected at 30%, its outline follows its arc, not its kept geometry's two segments") {
        let (h, id) = try arrowHarness(bend: 100)
        let geometry = try require(h.editor.arrowGeometry(of: id))
        let arc = try require(Arc(from: geometry.start, through: geometry.middle, to: geometry.end))
        let plain = renderBitmap(h.editor, size: canvas, scale: scale)
        h.editor.selection = id
        let selected = renderBitmap(h.editor, size: canvas, scale: scale)
        for t: CGFloat in [0.2, 0.3, 0.7, 0.8] {
            let point = arc.point(at: t)
            expect(color(plain, atWorld: point) != color(selected, atWorld: point), "outlined along the arc at \(t)")
        }
        for point in [(geometry.start + geometry.middle) / 2, (geometry.middle + geometry.end) / 2] {
            expectEqual(color(plain, atWorld: point), color(selected, atWorld: point), "not along a segment, at \(point)")
        }
    },
    test("an arrow's outline zoomed out holds the heads it draws, each a triangle, so any outline of it (here a tint, which draws no handles) shows which way it points; one with none holds none") {
        // A straight arrow from (100, 200) to (500, 200): a head is 10.5 long, its wings 30° off the body, so
        // 9.09 back from the tip, 5.25 either side: the far edge of the head at the end runs along x = 490.9 from
        // y = 194.75 to 205.25, near its ends 4.5 clear of the body, whose outline reaches 3.3 either side of it.
        let end = [CGPoint(x: 490.9, y: 204.5), CGPoint(x: 490.9, y: 195.5)], start = [CGPoint(x: 109.1, y: 204.5), CGPoint(x: 109.1, y: 195.5)]
        let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        /// Whether lighting the arrow changes the pixel at each point.
        @MainActor func changed(_ h: EditorHarness, _ id: ShapeID, _ lit: TintedOutlinesBox, at points: [CGPoint]) -> [Bool] {
            lit.groups = []
            let plain = renderBitmap(h.editor, size: canvas, scale: scale)
            lit.groups = [TintedOutlines(color: red, shapes: [id])]
            let tinted = renderBitmap(h.editor, size: canvas, scale: scale)
            return points.map { color(plain, atWorld: $0) != color(tinted, atWorld: $0) }
        }
        let lit = TintedOutlinesBox()
        let (headed, headedID) = try arrowHarness(bend: 0, lit: lit)
        expectEqual(changed(headed, headedID, lit, at: end), [true, true], "the head at its end: its far edge is outlined")
        expectEqual(changed(headed, headedID, lit, at: start), [false, false], "none at its start")
        headed.editor.transact { $0.update(headedID, as: Arrow.self) { $0.props.startArrowhead = true } }
        expectEqual(changed(headed, headedID, lit, at: end + start), [true, true, true, true], "and with one at its start, both")
        let (bare, bareID) = try arrowHarness(bend: 0, endArrowhead: false, lit: lit)
        expectEqual(changed(bare, bareID, lit, at: end + start), [false, false, false, false], "an arrow with no head has none in its outline")
        // Bent, the head follows the arc: 10 along its wing from the tip, which is 5 clear of the body.
        let (bent, bentID) = try arrowHarness(bend: 100, lit: lit)
        let geometry = try require(bent.editor.arrowGeometry(of: bentID))
        let arc = try require(Arc(from: geometry.start, through: geometry.middle, to: geometry.end))
        let tip = arc.point(at: 1)
        let step = 2 * asin(10.5 / (2 * arc.radius)) / abs(arc.sweep)
        let wing = arc.point(at: 1 - step).rotated(around: tip, by: .pi / 6)
        let along = tip + (wing - tip) * (10 / 10.5)
        expectEqual(changed(bent, bentID, lit, at: [along]), [true], "a bent arrow's head, along its arc, at \(along)")
    },
    test("at 35% and above an arrow draws in full, as it did") {
        for zoom: CGFloat in [0.35, 0.5] {
            for bend: CGFloat in [0, 100] {
                let (h, _) = try arrowHarness(bend: bend, zoom: zoom)
                let drawn = renderBitmap(h.editor, size: canvas, scale: scale)
                h.editor.skeletonZoom = 0
                expectEqual(largestDifference(drawn, renderBitmap(h.editor, size: canvas, scale: scale), in: CGRect(origin: .zero, size: canvas), scale: scale),
                            0, "at \(zoom), bent \(bend)")
            }
        }
    },
])

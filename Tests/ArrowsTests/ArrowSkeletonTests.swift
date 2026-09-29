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

/// A free arrow from (100, 200) to (500, 200), bent `bend`, drawn at `zoom`.
@MainActor private func arrowHarness(bend: CGFloat, endArrowhead: Bool = true, zoom: CGFloat = 0.3) throws -> (EditorHarness, ShapeID) {
    let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), ArrowsPlugin(), TableOfContentsPlugin()])
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

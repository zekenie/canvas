import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import TestKit
import Titles

// Zoomed out, a titled shape waiting to be placed (`editor.placeLater`) says its title on itself as a placed
// one does, faint, where it would land; in full, its pill shows above it, faint.

/// A plaque titled "Front desk" waiting to be placed, the pointer off the canvas: its bounds in the middle of
/// the 400 × 300 view.
@MainActor private func waitingPlaque(_ editor: CanvasEditor, zoom: CGFloat, title: String? = "Front desk") {
    editor.viewportDidResize(to: canvasView.size)
    editor.camera = Camera(origin: .zero, zoom: zoom)
    var plaque = ShapeRecord(Plaque(CGRect(origin: .zero, size: world(plaqueFrame, atZoom: zoom).size)))
    plaque[TitleProperty.self] = title
    expect(editor.placeLater(PendingPlacement([AnyShapeRecord(plaque)], stepName: "Add Plaque") { _ in [.zero] }))
}

/// Where a waiting plaque is in view: 200 × 120 points, in the middle of the 400 × 300 canvas.
let waitingFrame = CGRect(x: 100, y: 90, width: 200, height: 120)

@MainActor let pendingCoverTests = Suite("Titles of shapes waiting to be placed", [
    test("zoomed out, a waiting titled shape has its cover on it as a placed one does, faint; Escape takes it away") {
        let empty = try titleEditor()
        empty.viewportDidResize(to: canvasView.size)
        empty.camera = Camera(origin: .zero, zoom: 0.3)
        let placed = try titleEditor()
        placed.viewportDidResize(to: canvasView.size)
        placed.camera = Camera(origin: .zero, zoom: 0.3)
        let id = placed.add(Plaque(world(waitingFrame, atZoom: 0.3)))
        placed.rename(id, "Front desk")
        let waiting = try titleEditor(), untitled = try titleEditor()
        waitingPlaque(waiting, zoom: 0.3)
        waitingPlaque(untitled, zoom: 0.3, title: nil)
        let ground = render(empty), solid = render(placed), faint = render(waiting)
        let cover = try require(placed.titleCover(of: id))
        let text = placed.camera.toView(cover.rect).integral
        expect(changedPixels(ground, faint, in: text) > 0, "the waiting plaque is drawn")
        expect(changedPixels(render(untitled), faint, in: text) > 0, "and its title is said on it")
        expect(inkPixels(solid, in: text, dark: true) > 0, "a placed plaque's cover is dark ink on white")
        expect(inkPixels(faint, in: text, dark: true) < inkPixels(solid, in: text, dark: true), "the waiting one's is fainter")
        expect(changedPixels(solid, faint, in: text) > 0)
        waiting.cancel()
        expectEqual(changedPixels(ground, render(waiting), in: waitingFrame.insetBy(dx: -8, dy: -8)), 0, "gone with Escape")
    },
    test("in full, a waiting titled shape's pill shows above it, faint") {
        let empty = try titleEditor()
        empty.viewportDidResize(to: canvasView.size)
        let waiting = try titleEditor()
        waitingPlaque(waiting, zoom: 1)
        // The plaque is 200 × 120 in the middle of the view; its pill's row is the 18 points above its top-left
        // corner, 9 off its edge.
        let row = CGRect(x: waitingFrame.minX, y: waitingFrame.minY - 27, width: 80, height: 18)
        expect(changedPixels(render(empty), render(waiting), in: row) > 20, "the pill drawn above it")
    },
])

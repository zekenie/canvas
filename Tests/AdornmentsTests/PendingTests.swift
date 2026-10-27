import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Geometry
import TestKit

// Shapes waiting to be placed (`editor.placeLater`) show their adornments as they're drawn: faint, where
// they'd land, laid out as any shape's are, and gone as they go.

/// A box waiting to be placed with its top-left corner on the pointer, which is at the test box's corner.
@MainActor private func waitingBox(_ h: EditorHarness) {
    h.editor.viewportDidResize(to: wholeView.size)
    h.move(to: boxFrame.origin)
    let record = AnyShapeRecord(ShapeRecord(Box(CGRect(origin: .zero, size: boxFrame.size))))
    expect(h.editor.placeLater(PendingPlacement([record], stepName: "Add Box") { _ in [.zero] }))
}

@MainActor let pendingAdornmentTests = Suite("Adornments of shapes waiting to be placed", [
    test("a waiting shape's caption is drawn where it would be on the shape put down there, faint, and goes with it") {
        let caption = { everyShape(Caption.self) { _ in AdornmentLabel("Lobby") } }
        let empty = try adornedHarness([caption()])
        empty.editor.viewportDidResize(to: wholeView.size)
        let placed = try adornedHarness([caption()])
        let box = placed.add(Box(boxFrame))
        let frame = try require(placed.editor.rects(box).first).insetBy(dx: -1, dy: -1).integral
        let waiting = try adornedHarness([caption()])
        waitingBox(waiting)
        let ground = render(empty), solid = render(placed), faint = render(waiting)
        expect(changedPixels(ground, faint, in: frame) > 20, "drawn in its frame")
        expect(changedPixels(solid, faint, in: frame) > 20, "but not as a placed shape's is")
        let outside = CGRect(x: frame.maxX + 2, y: frame.minY, width: 60, height: frame.height)
        expectEqual(changedPixels(ground, faint, in: outside), 0, "and nowhere past it")
        // The capsule's fill, dark gray over the light canvas: fainter is nearer the ground.
        let middle = CGPoint(x: frame.minX + 6, y: frame.midY)
        let groundRed = pixel(ground, at: middle)[0], faintRed = pixel(faint, at: middle)[0], solidRed = pixel(solid, at: middle)[0]
        expect(abs(faintRed - groundRed) < abs(solidRed - groundRed), "faint: \(faintRed), solid \(solidRed), ground \(groundRed)")
        waiting.escape()
        expectEqual(changedPixels(ground, render(waiting), in: frame), 0, "gone as it goes")
    },
])

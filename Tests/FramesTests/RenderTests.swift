import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Frames
import Geometry
import TestKit

// The look: a surface with a hairline border just inside its edge and no shadow, white on the light
// canvas and a raised gray on the dark; zoomed out (below 35%), two fills, square. A frame at
// `frameRect` (100, 100, 400 × 300), at 100% from the origin unless a test zooms.

/// A board with one frame at `frameRect`, holding a box at (150, 150) if `holding`.
@MainActor private func board(holding: Bool = false) throws -> EditorHarness {
    let h = try frameHarness()
    let frame = h.addFrame()
    if holding { h.addBox(CGRect(x: 150, y: 150, width: 100, height: 100), in: frame) }
    return h
}

@MainActor let renderTests = Suite("The frame's look", [
    test("a white surface in a hairline border just inside its edge, rounded, with no shadow") {
        let h = try board()
        let drawn = render(h.editor)
        expectColor(pixel(drawn, at: CGPoint(x: 300, y: 250)), [255, 255, 255], "its surface")
        expectColor(pixel(drawn, at: CGPoint(x: 300, y: 100)), [224, 224, 224], "its border, a point inside its top edge", within: 4)
        expectColor(pixel(drawn, at: CGPoint(x: 499, y: 250)), [224, 224, 224], "and its right", within: 4)
        expectColor(pixel(drawn, at: CGPoint(x: 300, y: 98)), lightCanvas, "no shadow above it", within: 2)
        expectColor(pixel(drawn, at: CGPoint(x: 502, y: 250)), lightCanvas, "nor beside it", within: 2)
        expectColor(pixel(drawn, at: CGPoint(x: 101, y: 101)), lightCanvas, "its corner, rounded", within: 2)
    },
    test("in the dark, a raised gray surface in a lighter hairline") {
        let h = try board()
        let drawn = render(h.editor, dark: true)
        let surface = pixel(drawn, at: CGPoint(x: 300, y: 250))
        expectColor(surface, [38, 38, 38], "its surface, a step up from the canvas")
        let border = pixel(drawn, at: CGPoint(x: 300, y: 100))
        expect(border[0] > surface[0] + 20, "its border, lighter: \(border)")
        expectColor(pixel(drawn, at: CGPoint(x: 300, y: 97)), darkCanvas, "no shadow", within: 3)
    },
    test("what it holds draws over it, and its dots stop at its edge") {
        let h = try board(holding: true)
        let drawn = render(h.editor)
        expect(pixel(drawn, at: CGPoint(x: 200, y: 200))[0] < 200, "the box, over its surface")
        let empty = render(try board().editor)
        var dots = 0
        for y in stride(from: 110, to: 390, by: 2) {
            for x in stride(from: 110, to: 490, by: 2) where pixel(empty, at: CGPoint(x: x, y: y)).prefix(3) != [255, 255, 255] { dots += 1 }
        }
        expectEqual(dots, 0, "one white inside it: the dots stop at its edge")
    },
    test("zoomed out, two fills, square: its border's ring to the corner, and its surface inside; no pill; nothing past its frame") {
        let h = try board(holding: true)
        h.editor.camera = Camera(origin: .zero, zoom: 0.3)
        let skeleton = render(h.editor)
        h.editor.skeletonZoom = 0
        let full = render(h.editor)
        // At 30% the frame is 30 to 150 across, 30 to 120 down.
        expectColor(pixel(skeleton, at: CGPoint(x: 30, y: 30)), [224, 224, 224], "the ring, to its very corner", within: 6)
        expectColor(pixel(full, at: CGPoint(x: 30, y: 30)), lightCanvas, "where the full frame's corner is rounded", within: 4)
        expectColor(pixel(skeleton, at: CGPoint(x: 140, y: 100)), [255, 255, 255], "its surface")
        expectColor(pixel(skeleton, at: CGPoint(x: 152, y: 75)), lightCanvas, "nothing past it", within: 2)
        let blank = try frameHarness()
        blank.editor.camera = Camera(origin: .zero, zoom: 0.3)
        let canvas = render(blank.editor)
        let around = CGRect(x: 0, y: 0, width: 600, height: 500)
        let ring = CGRect(x: 30, y: 30, width: 120, height: 90)
        expectEqual(changedPixels(canvas, skeleton, in: around), changedPixels(canvas, skeleton, in: ring), "drawn within its frame: no pill above it")
    },
    test("zoomed out in the dark: the raised gray in a lighter ring") {
        let h = try board()
        h.editor.camera = Camera(origin: .zero, zoom: 0.3)
        let drawn = render(h.editor, dark: true)
        let surface = pixel(drawn, at: CGPoint(x: 90, y: 75))
        expectColor(surface, [38, 38, 38], "its surface")
        expect(pixel(drawn, at: CGPoint(x: 30, y: 75))[0] > surface[0] + 20, "its ring, lighter")
    },
    test("while it's drawn, it shows over what's under it, a third of its surface, and once it's put down it's the frame, under what it took in") {
        let h = try frameHarness()
        h.addBox(CGRect(x: 150, y: 150, width: 100, height: 100))
        let before = render(h.editor)
        h.frameTool()
        h.press(at: CGPoint(x: 100, y: 100))
        h.drag(to: CGPoint(x: 300, y: 250))
        h.drag(to: CGPoint(x: 500, y: 400))
        let drawing = render(h.editor)
        let box = pixel(before, at: CGPoint(x: 200, y: 200)), through = pixel(drawing, at: CGPoint(x: 200, y: 200))
        expect(through[0] > box[0] && through[0] < 255, "the box shows through it, a little lighter: \(box) then \(through)")
        expectColor(pixel(drawing, at: CGPoint(x: 300, y: 100)), [224, 224, 224], "its border, as it will be", within: 8)
        h.release()
        let drawn = render(h.editor)
        expectColor(pixel(drawn, at: CGPoint(x: 200, y: 200)), box, "put down, it took the box in, which draws over it", within: 1)
        expectColor(pixel(drawn, at: CGPoint(x: 400, y: 300)), [255, 255, 255], "on its surface")
    },
])

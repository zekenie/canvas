import Adornments
import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Selection
import TestKit

// Where an open shape's adornments go: above its label if it has one, else above the middle of its
// outline, either widened about its center to 120 points (view points, so more in world units zoomed
// out) so a row has room. A closed shape keeps its bounds. The strand is an open shape from (100,
// 150) to (360, 250), through (230, 200), with a label of its own or none.

let strandFrom = CGPoint(x: 100, y: 150), strandTo = CGPoint(x: 360, y: 250)

@MainActor func strandHarness(_ more: [any CanvasPlugin]) throws -> EditorHarness {
    try adornedHarness([StrandsPlugin(), everyShape(Caption.self, id: "captions") { _ in AdornmentLabel("Lobby") },
                        everyShape(Flag.self, id: "flags") { _ in flagLabel }] + more)
}

@MainActor let anchorTests = Suite("Where an open shape's adornments are", [
    test("above its label, widened to 120 points when the label is shorter: the caption at its left end, the flag at its right") {
        let h = try strandHarness([])
        let strand = h.add(Strand(from: strandFrom, to: strandTo, label: CGRect(x: 200, y: 185, width: 60, height: 30)))
        let frames = h.editor.adornmentFrames(of: strand)
        expectEqual(frames.map(\.adornment), [.of(Caption.self), .of(Flag.self)])
        expectEqual(frames[0].rect.minX, 170, "the label's center (230), less 60")
        expectEqual(frames[0].rect.minY, 158, "27 above the label's top")
        expectEqual(frames[1].rect, CGRect(x: 272, y: 158, width: 18, height: 18), "at 290")
    },
    test("a label wider than 120 points is the anchor as it is") {
        let h = try strandHarness([])
        let strand = h.add(Strand(from: strandFrom, to: strandTo, label: CGRect(x: 150, y: 185, width: 180, height: 30)))
        let frames = h.editor.adornmentFrames(of: strand)
        expectEqual(frames[0].rect.minX, 150)
        expectEqual(frames[1].rect.maxX, 330)
    },
    test("with no label: the middle of its outline, a point, widened to 120") {
        let h = try strandHarness([])
        let strand = h.add(Strand(from: strandFrom, to: strandTo))
        let frames = h.editor.adornmentFrames(of: strand)
        expectEqual(frames[0].rect.minX, 170)
        expectEqual(frames[0].rect.minY, 173, "27 above the middle, (230, 200)")
        expectEqual(frames[1].rect, CGRect(x: 272, y: 173, width: 18, height: 18))
    },
    test("the 120 points are view points: zoomed out to 50% they are 240 world units, and the chips are 36 across") {
        let h = try strandHarness([])
        let strand = h.add(Strand(from: strandFrom, to: strandTo))
        h.editor.camera = Camera(origin: .zero, zoom: 0.5)
        let frames = h.editor.adornmentFrames(of: strand)
        expectEqual(frames[0].rect.minX, 110, "230 less 120")
        expectEqual(frames[1].rect, CGRect(x: 314, y: 146, width: 36, height: 36), "at 350")
    },
    test("a closed shape's adornments are where they were: its bounds") {
        let h = try strandHarness([])
        let box = h.add(Box(boxFrame))
        let frames = h.editor.adornmentFrames(of: box)
        expectEqual(frames[0].rect.minX, 100)
        expectEqual(frames[1].rect, CGRect(x: 282, y: 73, width: 18, height: 18))
    },
    test("a wire just left of the view, whose widened anchor reaches in, is drawn and hit") {
        let h = try adornedHarness([StrandsPlugin(), everyShape(Pin.self) { _ in pinLabel }])
        let plain = try adornedHarness([StrandsPlugin()])
        let from = CGPoint(x: -120, y: 150), to = CGPoint(x: -10, y: 250)
        // Its bounds end at -10, 10 points left of the view; the anchor, -85 to 35, reaches in.
        let strand = h.add(Strand(from: from, to: to, label: CGRect(x: -40, y: 190, width: 30, height: 20)))
        plain.add(Strand(from: from, to: to, label: CGRect(x: -40, y: 190, width: 30, height: 20)))
        let pin = try require(h.editor.adornmentFrames(of: strand).first).rect
        expectEqual(pin, CGRect(x: 17, y: 163, width: 18, height: 18))
        let drawn = changedPixels(render(plain), render(h), in: pin.insetBy(dx: -1, dy: -1).integral)
        expect(drawn > 100, "drawn: \(drawn)")
        expectEqual(changedPixels(render(plain), render(h), in: wholeView) - drawn, 0)
        expectEqual(h.editor.button(atViewPoint: CGPoint(x: pin.midX, y: pin.midY)), AnyHashable(AdornmentButton(Pin.self, on: strand)))
    },
])

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
// 150) to (360, 250), through (230, 200), with a label of its own or none. It falls to the right (slope
// 100 / 260), so its row slid clear of its body, right of the anchor's left edge by what the tests say.

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
        // The row's bottom is 24 above the middle of the 30-tall label; the body rises 100 / 260 to the left, so the
        // row starts no farther left than 60 - 20 / (100 / 260) + 4 = 12 from the anchor's left edge, 170 + 12.
        expectEqual(frames[0].rect.minX, 182, "the label's center (230), less 60, slid 12 clear of the body")
        expectEqual(frames[0].rect.minY, 158, "27 above the label's top")
        expectEqual(frames[1].rect, CGRect(x: 284, y: 158, width: 18, height: 18), "at 290, slid with the row")
    },
    test("a label wider than 120 points is the anchor as it is") {
        let h = try strandHarness([])
        let strand = h.add(Strand(from: strandFrom, to: strandTo, label: CGRect(x: 150, y: 185, width: 180, height: 30)))
        let frames = h.editor.adornmentFrames(of: strand)
        // 90 to the middle, less 20 / (100 / 260) and plus 4: the row starts 42 in, and its right end goes with it.
        expectEqual(frames[0].rect.minX, 192, "150, slid 42")
        expectEqual(frames[1].rect.maxX, 372, "330, slid 42")
    },
    test("with no label: the middle of its outline, a point, widened to 120") {
        let h = try strandHarness([])
        let strand = h.add(Strand(from: strandFrom, to: strandTo))
        let frames = h.editor.adornmentFrames(of: strand)
        // No label: the row's bottom is 9 above the middle, so 5 clear: it starts at 60 - 5 / (100 / 260) + 4 = 51 from the left edge.
        expectEqual(frames[0].rect.minX, 221, "170, slid 51")
        expectEqual(frames[0].rect.minY, 173, "27 above the middle, (230, 200)")
        expectEqual(frames[1].rect, CGRect(x: 323, y: 173, width: 18, height: 18), "272, slid 51")
    },
    test("the 120 points are view points: zoomed out to 50% they are 240 world units, and the chips are 36 across") {
        let h = try strandHarness([])
        let strand = h.add(Strand(from: strandFrom, to: strandTo))
        h.editor.camera = Camera(origin: .zero, zoom: 0.5)
        let frames = h.editor.adornmentFrames(of: strand)
        // The chips are 36 across in world units, the drop 5 view points is 10, the margin 8: 120 - 5 / (100 / 260) * 2 + 8 = 102 from the left edge.
        expectEqual(frames[0].rect.minX, 212, "230 less 120, slid 102")
        expectEqual(frames[1].rect, CGRect(x: 416, y: 146, width: 36, height: 36), "at 350, slid with the row")
    },
    test("a lone adornment is centred on the middle of an open shape with no label, and starts at the label's left edge on a labelled one and at the bounds' on a closed one: the shape's own point-ness is what centres") {
        let h = try adornedHarness([StrandsPlugin(), everyShape(Caption.self, id: "captions") { _ in AdornmentLabel("Lobby") }])
        let level = (from: CGPoint(x: 100, y: 200), to: CGPoint(x: 360, y: 200))
        let bare = h.add(Strand(from: level.from, to: level.to))
        let caption = try require(h.editor.adornmentFrames(of: bare).first).rect
        // The middle of the outline is (230, 200); the caption is the whole row, so its middle is there.
        expectEqual(caption.midX, 230, "centred on the middle: the same wherever the strand is, not 60 points left of it")
        expect(caption.width < 120, "and narrower than the anchor, so that is not its left edge: \(caption)")
        let labelled = h.add(Strand(from: level.from, to: level.to, label: CGRect(x: 200, y: 185, width: 60, height: 30)))
        expectEqual(try require(h.editor.adornmentFrames(of: labelled).first).rect.minX, 170, "from the label's anchor's left edge (230 less 60)")
        let box = h.add(Box(boxFrame))
        expectEqual(try require(h.editor.adornmentFrames(of: box).first).rect.minX, boxFrame.minX, "from the bounds' left edge")
        let anchor = try require(h.editor.adornmentAnchor(of: bare))
        expectEqual(anchor.minX, caption.minX, "and what hangs from the row hangs from where the caption is")
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
    test("the anchor is public: a closed shape's bounds, an open shape's label (widened to 120 points) or the middle of its outline, nil for what is not there, and the row's frames hang from it") {
        let h = try strandHarness([])
        let box = h.add(Box(boxFrame))
        expectEqual(h.editor.adornmentAnchor(of: box), boxFrame, "a note's top-left is the row's")
        let labeled = h.add(Strand(from: strandFrom, to: strandTo, label: CGRect(x: 200, y: 185, width: 60, height: 30)))
        expectEqual(h.editor.adornmentAnchor(of: labeled), CGRect(x: 182, y: 185, width: 120, height: 30), "above the label, widened about its center, moved with the row 12 along it (the strand falls)")
        let wide = h.add(Strand(from: strandFrom, to: strandTo, label: CGRect(x: 150, y: 385, width: 180, height: 30)))
        expectEqual(h.editor.adornmentAnchor(of: wide), CGRect(x: 192, y: 385, width: 180, height: 30), "a wider label as it is, moved with the row 42")
        let bare = h.add(Strand(from: strandFrom, to: strandTo))
        expectEqual(h.editor.adornmentAnchor(of: bare), CGRect(x: 221, y: 200, width: 120, height: 0), "a point at the outline's middle, widened, moved with the row 51")
        for id in [box, labeled, bare] {
            let row = try require(h.editor.adornmentFrames(of: id).first).rect
            let anchor = try require(h.editor.adornmentAnchor(of: id))
            expectEqual(row.minX, anchor.minX, "the row starts at the anchor's left, which the row's slide moved")
            expect(row.maxY <= anchor.minY, "and sits above it")
        }
        expectEqual(h.editor.adornmentAnchor(of: ShapeID()), nil, "a shape that is not there")
        h.editor.camera = Camera(origin: .zero, zoom: 0.5)
        expectEqual(h.editor.adornmentAnchor(of: bare), CGRect(x: 212, y: 200, width: 240, height: 0), "120 view points, so 240 world units at 50%, moved with the row 102")
        expectEqual(h.editor.adornmentAnchor(of: box), boxFrame, "a closed shape's, whatever the zoom")
    },
])

import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Geometry
import Selection
import TestKit

// Zoomed out, where the canvas draws shapes as skeletons (under 35%), no adornment is shown on one:
// none is drawn, laid out, pointed at, made or kept (what a shape is called is said on it instead:
// Titles' cover). The shape being edited is drawn in full, and so are its adornments. The test box
// is drawn where it is at 100% (`world(_:atZoom:)`): its top-left corner at (100, 100) in view,
// 200 wide.

/// Text at the row's right end that a click does something with.
enum Stamp {}
extension Stamp: Adornment {
    static var placement: AdornmentPlacement { .aboveTopRight }
}
extension Stamp: ClickableAdornment {
    static func click(_ click: AdornmentClick, in editor: CanvasEditor) { clicked.append(click.shape) }
}

/// Where a box is at `zoom` to be where `boxFrame` is at 100%, in view.
func world(_ frame: CGRect, atZoom zoom: CGFloat) -> CGRect {
    CGRect(x: frame.minX / zoom, y: frame.minY / zoom, width: frame.width / zoom, height: frame.height / zoom)
}

/// A shape's caption's frame, in view points.
@MainActor func captionRect(_ h: EditorHarness, _ id: ShapeID) throws -> CGRect {
    h.editor.camera.toView(try require(h.editor.adornmentFrames(of: id).first { $0.adornment == .of(Caption.self) }).rect)
}

/// A shape's stamp's frame, in view points.
@MainActor func stampRect(_ h: EditorHarness, _ id: ShapeID) throws -> CGRect {
    h.editor.camera.toView(try require(h.editor.adornmentFrames(of: id).first { $0.adornment == .of(Stamp.self) }).rect)
}

@MainActor let skeletonTests = Suite("Adornments zoomed out", [
    test("below 35%, no adornment is drawn or laid out on a shape; at 35%, each is drawn in its frame") {
        let cases: [(String, any CanvasPlugin)] = [
            ("a caption", everyShape(Caption.self) { _ in AdornmentLabel("Lobby") }),
            ("a long caption", everyShape(Caption.self) { _ in AdornmentLabel(longText) }),
            ("a flag", everyShape(Flag.self) { _ in flagLabel }),
            ("a pin", everyShape(Pin.self) { _ in pinLabel }),
            ("a count", everyShape(Count.self) { _ in AdornmentLabel("☑ 2/5") }),
        ]
        for (name, plugin) in cases {
            for zoom in [0.3, 0.1, 0.35] as [CGFloat] {
                let (plain, adorned, h) = try renders([plugin], zoom: zoom) { $0.add(Box(world(boxFrame, atZoom: zoom))) }
                let box = h.editor.document.shapes[0].id
                if zoom < 0.35 {
                    expectEqual(h.editor.rects(box), [], "\(name) at \(zoom): no frame")
                    expectEqual(changedPixels(plain, adorned, in: wholeView), 0, "\(name) at \(zoom): nothing drawn")
                } else {
                    let frame = try require(viewRects(h, box).first).insetBy(dx: -1, dy: -1).integral
                    let drawn = changedPixels(plain, adorned, in: frame)
                    expect(drawn > 100, "\(name) at 35% draws: \(drawn)")
                    expectEqual(changedPixels(plain, adorned, in: wholeView) - drawn, 0, "\(name) draws nowhere else")
                }
            }
        }
    },
    test("the level is 35%: there a caption has its frame, just under it none, and back at 35% its frame again") {
        let h = try adornedHarness([everyShape(Caption.self) { _ in AdornmentLabel("Lobby") }])
        let box = h.add(Box(world(boxFrame, atZoom: 0.35)))
        var counts: [Int] = []
        for zoom in [0.35, 0.349, 0.35] as [CGFloat] {
            h.editor.camera = Camera(origin: .zero, zoom: zoom)
            counts.append(h.editor.rects(box).count)
        }
        expectEqual(counts, [1, 0, 1])
    },
    test("zoomed out, no label is made, no text set or measured, nothing kept; zoomed in, those in view are made and measured") {
        let calls = Calls()
        let h = try adornedHarness([countedCaptions(calls)])
        h.editor.transact { transaction in
            for row in 0..<25 {
                for column in 0..<40 {
                    transaction.insert(ShapeRecord(Box(CGRect(x: column * 100, y: row * 100, width: 80, height: 60))))
                }
            }
        }
        h.editor.camera = Camera(origin: .zero, zoom: 0.1)          // the whole board in view
        _ = render(h)
        h.move(to: CGPoint(x: 150, y: 150))
        _ = render(h)
        expectEqual(calls.counts.count, 0, "no label made")
        expectEqual(h.editor.adornmentsKept, 0)
        expectEqual(h.editor.adornmentFacesMade, 0, "none measured")
        expectEqual(h.editor.adornmentFacesKept, 0)
        h.editor.camera = Camera(origin: .zero, zoom: 1)
        _ = render(h)
        let measured = h.editor.adornmentFacesMade
        expect(measured > 0 && measured < 40, "those in view measured: \(measured)")
        expectEqual(h.editor.adornmentFacesKept, measured)
        expectEqual(calls.counts.count, measured, "and their labels made")
        h.editor.camera = Camera(origin: .zero, zoom: 0.1)
        expectEqual(h.editor.adornmentFacesKept, 0, "zoomed out, the measured faces go")
        expectEqual(h.editor.adornmentsKept, 0, "and the labels")
        _ = render(h)
        expectEqual(h.editor.adornmentFacesMade, measured, "and none is measured")
        expect(calls.counts.values.allSatisfy { $0 == 1 }, "no label made twice: \(Set(calls.counts.values))")
    },
    test("zoomed out, a point where an adornment would be is not on one: a click there clicks nothing, a hover hovers nothing; in full it does") {
        clicked = []
        let h = try adornedHarness([everyShape(Pin.self) { _ in pinLabel }, everyShape(Caption.self, id: "captions") { _ in AdornmentLabel("WWWWWWWW") }])
        let box = h.add(Box(world(boxFrame, atZoom: 0.3)))
        h.editor.camera = Camera(origin: .zero, zoom: 0.3)
        h.click(at: flagCenter)
        expectEqual(clicked, [], "no pin on a skeleton")
        let caption = CGPoint(x: 110, y: 82)
        h.move(to: caption)
        expectEqual(h.editor.hovered, nil, "no caption on a skeleton: that's empty canvas")
        h.editor.skeletonZoom = 0.2                                 // in full at 30%
        expectEqual(h.editor.hovered, box, "in full, on the caption")
        h.click(at: flagCenter)
        expectEqual(clicked, [box], "and on the pin")
    },
    test("as the level changes under a still pointer, the select tool looks there again: a button gone as shapes become skeletons, and back") {
        // Selection looks again as it hears the level change (its `drawsSkeletonsDidChange`), for
        // every plugin's buttons; Adornments adds no look of its own, so without Selection's none
        // of this would follow.
        clicked = []
        let h = try adornedHarness([everyShape(Stamp.self) { _ in AdornmentLabel("WWWWWWWW") }])
        let box = h.add(Box(world(boxFrame, atZoom: 0.3)))
        h.editor.camera = Camera(origin: .zero, zoom: 0.3)
        h.editor.skeletonZoom = 0.2                                 // in full
        let stamp = AnyHashable(AdornmentButton(Stamp.self, on: box))
        let full = try stampRect(h, box)
        let point = CGPoint(x: full.midX, y: full.midY)
        h.move(to: point)
        expectEqual(h.editor.hoveredButton, stamp)
        expectEqual(h.editor.cursor, .pointingHand)
        h.editor.skeletonZoom = 0.35                                // skeletons
        expectEqual(h.editor.hoveredButton, nil, "let go of, on a skeleton")
        expectEqual(h.editor.cursor, .standard)
        h.editor.skeletonZoom = 0.2
        expectEqual(h.editor.hoveredButton, stamp, "found again, in full")
        h.click(at: point)
        expectEqual(clicked, [box])
    },
    test("zoomed out, the shape being edited is drawn in full, and its adornments are too, drawn and pointed at, while another's aren't shown") {
        let plugins = [everyShape(Stamp.self) { _ in AdornmentLabel("WWWWWWWW") }, everyShape(Caption.self, id: "captions") { _ in AdornmentLabel("WWWWWWWW") }]
        let h = try adornedHarness(plugins)
        // Two cards, which are edited in place: the other 150 points below.
        let edited = h.add(Card(world(boxFrame, atZoom: 0.3)))
        let other = h.add(Card(world(boxFrame.offsetBy(dx: 0, dy: 150), atZoom: 0.3)))
        h.editor.camera = Camera(origin: .zero, zoom: 0.3)
        expectEqual(h.editor.rects(edited), [], "skeletons, before it's edited")
        h.editor.skeletonZoom = 0.2                                 // in full at 30%
        let full = try captionRect(h, edited), fullStamp = try stampRect(h, edited)
        h.editor.skeletonZoom = 0.35
        let idle = render(h)
        expect(h.editor.beginEditing(edited))
        expect(h.editor.drawsSkeletons && !h.editor.drawsSkeleton(of: edited))
        expectEqual(try captionRect(h, edited), full, "laid out in full")
        expectEqual(try stampRect(h, edited), fullStamp)
        expectEqual(h.editor.rects(other), [], "the other's none")
        let editing = render(h)
        h.editor.skeletonZoom = 0.2
        let inFull = render(h)
        h.editor.skeletonZoom = 0.35
        for (name, rect) in [("caption", full), ("stamp", fullStamp)] {
            expect(changedPixels(idle, editing, in: rect) > 100, "the \(name) drawn")
            expectEqual(changedPixels(inFull, editing, in: rect.insetBy(dx: -2, dy: -2)), 0, "the \(name) as it's drawn in full")
        }
        expectEqual(changedPixels(idle, editing, in: CGRect(x: 0, y: 222, width: 400, height: 78)), 0, "the other, as it was")
        // Pointed at where they're drawn: on the edited card's, none on the other's.
        h.move(to: CGPoint(x: full.minX + 10, y: full.midY))
        expectEqual(h.editor.hovered, edited, "on its caption, in full")
        h.move(to: CGPoint(x: fullStamp.midX, y: fullStamp.midY))
        expectEqual(h.editor.hoveredButton, AnyHashable(AdornmentButton(Stamp.self, on: edited)), "on its stamp, in full")
        h.move(to: CGPoint(x: full.minX + 10, y: full.midY + 150))
        expectEqual(h.editor.hovered, nil, "the other's caption isn't there")
        h.move(to: CGPoint(x: fullStamp.midX, y: fullStamp.midY + 150))
        expectEqual(h.editor.hoveredButton, nil)
        h.editor.endEditing()
        expectEqual(h.editor.rects(edited), [], "none again once it's no longer edited")
        expectEqual(changedPixels(idle, render(h), in: wholeView), 0)
    },
])

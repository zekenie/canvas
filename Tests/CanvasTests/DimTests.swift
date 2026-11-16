import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import TestKit

// `Outlines.dim`: the board drawn quieter but for some shapes, each kept at a strength. What's dimmed is drawn at the core's
// opacity (45% on the light canvas, 30% on the dark), a kept shape between by its strength, and the grid, the outlines and
// what overlays draw are as they were. While the camera moves the dim is left out (`Style.dimCameraRest`, 150 ms after the last change),
// the outlines as ever, and the canvas is asked to draw again when it rests.

/// What a test dims, as plugins' dims would be.
@MainActor private final class Dimmed {
    var dim: Dimming?
    var tinted: [TintedOutlines] = []
}

private let dimCanvas = CGSize(width: 320, height: 240)

/// Boxes and corrals, and a plugin that dims what `dimmed` says (a second one for the test of two).
@MainActor private func dimHarness(_ dimmed: Dimmed, also second: Dimmed? = nil) throws -> EditorHarness {
    try EditorHarness(plugins: [FixturesPlugin(), CorralsPlugin(), Contributor(id: "dimmer") { r in
        r.outlines { _ in Outlines(tinted: dimmed.tinted, dim: dimmed.dim) }
    }, Contributor(id: "other-dimmer") { r in
        if let second { r.outlines { _ in Outlines(dim: second.dim) } }
    }])
}

/// The canvas drawn in the light appearance or the dark.
@MainActor private func render(_ editor: CanvasEditor, dark: Bool) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(dimCanvas.width), pixelsHigh: Int(dimCanvas.height),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let cg = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    cg.translateBy(x: 0, y: dimCanvas.height)
    cg.scaleBy(x: 1, y: -1)
    NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        let bounds = CGRect(origin: .zero, size: dimCanvas)
        editor.draw(in: cg, bounds: bounds, dirtyRect: bounds)
        NSGraphicsContext.restoreGraphicsState()
    }
    return rep
}

/// Whether a pixel is what `shape` shows when `alpha` of it is drawn over `behind`, within a few levels.
private func isBlend(_ pixel: [Int], of shape: [Int], over behind: [Int], alpha: CGFloat, _ tolerance: Int = 3) -> Bool {
    (0..<3).allSatisfy { channel in
        let back = CGFloat(behind[channel]), front = CGFloat(shape[channel])
        let expected: CGFloat = (back + (front - back) * alpha).rounded()
        return abs(pixel[channel] - Int(expected)) <= tolerance
    }
}

/// A box with a red ring (6 wide, on its edge) and a dim keeping nothing, a host counting redraws: the box's middle and the ring's pixel
/// read off a frame, the camera panned `pan` view points to the left or not.
@MainActor private struct Resting {
    let dimmed = Dimmed(), redraws = Redraws(), h: EditorHarness
    let box = CGPoint(x: 220, y: 70), ring = CGPoint(x: 180, y: 70)
    init() throws {
        h = try dimHarness(dimmed)
        h.editor.delegate = redraws
        let id = h.add(Box(CGRect(x: 180, y: 40, width: 120, height: 60)))
        dimmed.tinted = [TintedOutlines(color: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), shapes: [id], width: 6)]
        dimmed.dim = Dimming(focus: [:])
    }
    /// A frame, without a dim and with, at the camera as it is: the box's middle in each, and the ring's pixel in the one with.
    func frames(shifted: CGFloat = 0) -> (plain: [Int], dimmed: [Int], ring: [Int]) {
        let kept = dimmed.dim
        dimmed.dim = nil
        let plain = render(h.editor, dark: false)
        dimmed.dim = kept
        let drawn = render(h.editor, dark: false)
        return (pixel(plain, at: box), pixel(drawn, at: box), pixel(drawn, at: CGPoint(x: ring.x - shifted, y: ring.y)))
    }
    func pan(by x: CGFloat) { h.editor.camera = Camera(origin: CGPoint(x: h.editor.camera.origin.x + x, y: 0), zoom: 1) }
}

private let wholeCanvas = CGRect(origin: .zero, size: dimCanvas)
private let nothing = CGPoint(x: 150, y: 232)

@MainActor let dimTests = Suite("Dimming", [
    test("every shape in view that isn't kept is drawn at 45% on the light canvas and 30% on the dark; the kept shape is as it was") {
        for (dark, opacity) in [(false, 0.45), (true, 0.30)] as [(Bool, CGFloat)] {
            let dimmed = Dimmed()
            let h = try dimHarness(dimmed)
            let kept = h.add(Box(CGRect(x: 40, y: 40, width: 80, height: 60)))
            let other = h.add(Box(CGRect(x: 180, y: 40, width: 80, height: 60)))
            let plain = render(h.editor, dark: dark)
            dimmed.dim = Dimming(focus: [kept: 1])
            let drawn = render(h.editor, dark: dark)
            let canvas = pixel(plain, at: nothing), box = pixel(plain, at: CGPoint(x: 220, y: 70))
            expect(box != canvas, "the box shows on the canvas, \(dark ? "dark" : "light")")
            let dimmedBox = pixel(drawn, at: CGPoint(x: 220, y: 70))
            expect(isBlend(dimmedBox, of: box, over: canvas, alpha: opacity), "\(opacity * 100)% of the box over the canvas: \(dimmedBox) from \(box) on \(canvas)")
            expectEqual(changedPixels(plain, drawn, in: CGRect(x: 0, y: 0, width: 150, height: 240)), 0, "the kept box, its shadow and the canvas beside it as they were")
            _ = other
        }
    },
    test("a kept shape with a strength under 1 is drawn between the dimmed and as it is, in ten steps; one at 0.995 or over is as it is") {
        let dimmed = Dimmed()
        let h = try dimHarness(dimmed)
        let boxes = (0..<6).map { h.add(Box(CGRect(x: 10 + CGFloat($0) * 50, y: 60, width: 40, height: 40))) }
        let plain = render(h.editor, dark: false)
        let canvas = pixel(plain, at: nothing)
        let strengths: [CGFloat] = [0, 0.25, 0.5, 0.95, 0.996, 1]
        dimmed.dim = Dimming(focus: Dictionary(uniqueKeysWithValues: zip(boxes, strengths)))
        let drawn = render(h.editor, dark: false)
        var alphas: [CGFloat] = []
        for (i, strength) in strengths.enumerated() {
            let at = CGPoint(x: 30 + CGFloat(i) * 50, y: 80)
            let shown = pixel(drawn, at: at), full = pixel(plain, at: at)
            // The band the strength is in, ten of them: the middle of it between the dimmed opacity and full.
            let band = min(9, Int(strength * 10))
            let alpha = strength >= 0.995 ? 1 : 0.45 + 0.55 * (CGFloat(band) + 0.5) / 10
            alphas.append(alpha)
            expect(isBlend(shown, of: full, over: canvas, alpha: alpha), "strength \(strength): \(alpha) of the box, \(shown) from \(full) on \(canvas)")
        }
        expect(alphas == alphas.sorted() && alphas.first! > 0.45 && alphas.last! == 1, "each stronger shape is stronger drawn")
        expectEqual(changedPixels(plain, drawn, in: CGRect(x: 235, y: 55, width: 80, height: 50)), 0, "the last two, 0.996 and 1, as they were")
    },
    test("a kept frame is drawn behind what it holds, dimmed or not: the shapes in it show over it, at the dimmed opacity") {
        for strength: CGFloat in [1, 0.5] {
            let dimmed = Dimmed()
            let h = try dimHarness(dimmed)
            let corral = h.add(Corral(CGRect(x: 20, y: 20, width: 280, height: 200)))
            let held = h.add(Box(CGRect(x: 60, y: 60, width: 80, height: 60)))
            h.editor.transact { $0.setContainer(held, to: corral) }
            let plain = render(h.editor, dark: false)
            let frameOnly = pixel(plain, at: CGPoint(x: 250, y: 180)), member = pixel(plain, at: CGPoint(x: 100, y: 90))
            expect(frameOnly != member, "the frame and what it holds show apart")
            dimmed.dim = Dimming(focus: [corral: strength])
            let drawn = render(h.editor, dark: false)
            let alpha = strength >= 0.995 ? 1 : 0.45 + 0.55 * (CGFloat(min(9, Int(strength * 10))) + 0.5) / 10
            let canvas = pixel(plain, at: nothing)
            let frame = pixel(drawn, at: CGPoint(x: 250, y: 180))
            expect(isBlend(frame, of: frameOnly, over: canvas, alpha: alpha), "the frame at its strength \(strength): \(frame)")
            // What it holds is dimmed over the frame as drawn, not under it and not hidden by it.
            let shown = pixel(drawn, at: CGPoint(x: 100, y: 90))
            expect(isBlend(shown, of: member, over: frame, alpha: 0.45, 4), "the member's 45% over the frame at \(strength): \(shown) from \(member) on \(frame)")
        }
    },
    test("a kept shape in a dimmed frame is drawn over it as it is") {
        let dimmed = Dimmed()
        let h = try dimHarness(dimmed)
        let corral = h.add(Corral(CGRect(x: 20, y: 20, width: 280, height: 200)))
        let held = h.add(Box(CGRect(x: 60, y: 60, width: 80, height: 60)))
        h.editor.transact { $0.setContainer(held, to: corral) }
        let plain = render(h.editor, dark: false)
        dimmed.dim = Dimming(focus: [held: 1])
        let drawn = render(h.editor, dark: false)
        expectEqual(pixel(drawn, at: CGPoint(x: 100, y: 90)), pixel(plain, at: CGPoint(x: 100, y: 90)), "the member as it was")
        let canvas = pixel(plain, at: nothing), frame = pixel(plain, at: CGPoint(x: 250, y: 180))
        expect(isBlend(pixel(drawn, at: CGPoint(x: 250, y: 180)), of: frame, over: canvas, alpha: 0.45), "the frame dimmed")
    },
    test("the grid, the outlines and what overlays draw are not dimmed") {
        let dimmed = Dimmed()
        let h = try dimHarness(dimmed)
        let box = h.add(Box(CGRect(x: 180, y: 40, width: 80, height: 60)))
        // A line 6 wide on the box's edge, so the pixels in the middle of it are all the tint.
        dimmed.tinted = [TintedOutlines(color: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), shapes: [box], width: 6)]
        let plain = render(h.editor, dark: false)
        dimmed.dim = Dimming(focus: [:])
        let drawn = render(h.editor, dark: false)
        let line = pixel(drawn, at: CGPoint(x: 180, y: 70))
        expect(line[0] > 250 && line[1] < 5 && line[2] < 5, "the outline is as drawn: \(line)")
        // Away from the box: the canvas and its grid, as they were.
        expectEqual(changedPixels(plain, drawn, in: CGRect(x: 0, y: 0, width: 150, height: 240)), 0, "the grid as it was")
        expectEqual(changedPixels(plain, drawn, in: CGRect(x: 0, y: 120, width: 320, height: 120)), 0, "and below")
    },
    test("nothing changes, byte for byte, without a dim: a plugin that asks for none, and one that isn't there") {
        let dimmed = Dimmed()
        let h = try dimHarness(dimmed)
        let bare = try EditorHarness(plugins: [FixturesPlugin(), CorralsPlugin()])
        for harness in [h, bare] {
            let corral = harness.add(Corral(CGRect(x: 20, y: 20, width: 280, height: 200)))
            let held = harness.add(Box(CGRect(x: 60, y: 60, width: 80, height: 60)))
            harness.editor.transact { $0.setContainer(held, to: corral) }
        }
        let asked = render(h.editor, dark: false), alone = render(bare.editor, dark: false)
        expectEqual(changedPixels(asked, alone, in: wholeCanvas), 0, "the same canvas")
        expectEqual(asked.tiffRepresentation, alone.tiffRepresentation, "byte for byte")
        expect(h.editor.outlines.dim == nil, "no dim asked for")
    },
    test("two plugins' dims are one: the union of what they keep, each shape at its strongest") {
        let first = Dimmed(), second = Dimmed()
        let h = try dimHarness(first, also: second)
        let a = h.add(Box(CGRect(x: 10, y: 60, width: 40, height: 40)))
        let b = h.add(Box(CGRect(x: 70, y: 60, width: 40, height: 40)))
        let c = h.add(Box(CGRect(x: 130, y: 60, width: 40, height: 40)))
        let d = h.add(Box(CGRect(x: 190, y: 60, width: 40, height: 40)))
        let plain = render(h.editor, dark: false)
        first.dim = Dimming(focus: [a: 1, b: 0.3, c: 0.8])
        second.dim = Dimming(focus: [b: 0.9, c: 0.2, d: 1])
        expectEqual(h.editor.outlines.dim, Dimming(focus: [a: 1, b: 0.9, c: 0.8, d: 1]), "the strongest of each")
        let drawn = render(h.editor, dark: false)
        let canvas = pixel(plain, at: nothing)
        for (id, strength) in [(a, 1), (b, 0.9), (c, 0.8), (d, 1)] as [(ShapeID, CGFloat)] {
            let box = h.editor.shapeContext.frame(of: id)!, at = CGPoint(x: box.midX, y: box.midY)
            let alpha = strength >= 0.995 ? 1 : 0.45 + 0.55 * (CGFloat(min(9, Int(strength * 10))) + 0.5) / 10
            expect(isBlend(pixel(drawn, at: at), of: pixel(plain, at: at), over: canvas, alpha: alpha), "shape at \(box.midX) drawn at \(alpha)")
        }
        // Either alone is its own; the other's nil is no dim at all.
        first.dim = nil
        expectEqual(h.editor.outlines.dim, second.dim, "one plugin's, as it is")
        second.dim = nil
        expect(h.editor.outlines.dim == nil, "none from none")
    },
    test("an empty dim dims every shape; a session that hides outlines hides the dim too") {
        let dimmed = Dimmed()
        let h = try dimHarness(dimmed)
        _ = h.add(Box(CGRect(x: 180, y: 40, width: 80, height: 60)))
        let plain = render(h.editor, dark: false)
        dimmed.dim = Dimming(focus: [:])
        expect(changedPixels(plain, render(h.editor, dark: false), in: CGRect(x: 170, y: 30, width: 100, height: 80)) > 100, "every shape dimmed")
        h.editor.session = OutlineHidingSession()
        expectEqual(changedPixels(plain, render(h.editor, dark: false), in: wholeCanvas), 0, "nothing while it runs")
        expect(h.editor.outlines.dim == nil, "none asked for")
        h.editor.session = nil
        expect(h.editor.outlines.dim != nil, "and back after")
    },
    test("a dim that names thousands of shapes that are nowhere in view draws the same twice, and the shape in view at its strength") {
        let dimmed = Dimmed()
        let h = try dimHarness(dimmed)
        let kept = h.add(Box(CGRect(x: 40, y: 40, width: 80, height: 60)))
        var focus = Dictionary(uniqueKeysWithValues: (0..<20_000).map { _ in (ShapeID(), CGFloat(1)) })
        focus[kept] = 0.5
        dimmed.dim = Dimming(focus: focus)
        let drawn = render(h.editor, dark: false)
        expect(changedPixels(drawn, render(h.editor, dark: false), in: wholeCanvas) == 0, "drawn the same twice")
        expect(h.editor.outlines.dim?.focus.count == 20_001)
    },
    test("a lit frame inside a dimmed one stays over it: the inner frame reads at its strength, not washed by the outer one") {
        for strength: CGFloat in [1, 0.5] {
            let dimmed = Dimmed()
            let h = try dimHarness(dimmed)
            let outer = h.add(Corral(CGRect(x: 20, y: 20, width: 280, height: 200)))
            let inner = h.add(Corral(CGRect(x: 60, y: 60, width: 160, height: 120)))
            h.editor.transact { $0.setContainer(inner, to: outer) }
            let plain = render(h.editor, dark: false)
            // The frames share a fill, so what shows the inner one apart is its edge: the pixel across x = 60 that differs most.
            let fill = pixel(plain, at: CGPoint(x: 200, y: 160)), outerOnly = pixel(plain, at: CGPoint(x: 270, y: 200))
            let edge = (58...62).map { CGPoint(x: CGFloat($0), y: 100) }.max { lhs, rhs in
                let l = pixel(plain, at: lhs), r = pixel(plain, at: rhs)
                return (0..<3).reduce(0) { $0 + abs(l[$1] - fill[$1]) } < (0..<3).reduce(0) { $0 + abs(r[$1] - fill[$1]) }
            }!
            let edgeOnly = pixel(plain, at: edge)
            expect(edgeOnly != fill, "the inner frame's edge shows")
            dimmed.dim = Dimming(focus: [inner: strength])
            let drawn = render(h.editor, dark: false)
            let canvas = pixel(plain, at: nothing)
            let alpha = strength >= 0.995 ? 1 : 0.45 + 0.55 * (CGFloat(min(9, Int(strength * 10))) + 0.5) / 10
            // The outer frame dimmed on the canvas, the inner over it at its strength: its edge is that much of itself over the
            // dimmed outer frame, not washed by the outer frame's layer.
            let outerDimmed = pixel(drawn, at: CGPoint(x: 270, y: 200))
            expect(isBlend(outerDimmed, of: outerOnly, over: canvas, alpha: 0.45), "the outer frame at 45%: \(outerDimmed)")
            let shown = pixel(drawn, at: edge)
            expect(isBlend(shown, of: edgeOnly, over: outerDimmed, alpha: alpha, 4), "the inner frame's edge at \(alpha) over the dimmed outer one, strength \(strength): \(shown) from \(edgeOnly) on \(outerDimmed)")
        }
    },
    test("a strength that isn't a number, or infinite, is 0: nothing traps, and the shape is drawn at the dimmed opacity, in a dim and joined with another") {
        let first = Dimmed(), second = Dimmed()
        let h = try dimHarness(first, also: second)
        let a = h.add(Box(CGRect(x: 10, y: 60, width: 40, height: 40)))
        let b = h.add(Box(CGRect(x: 70, y: 60, width: 40, height: 40)))
        let c = h.add(Box(CGRect(x: 130, y: 60, width: 40, height: 40)))
        let frame = h.add(Corral(CGRect(x: 190, y: 20, width: 100, height: 120)))
        let plain = render(h.editor, dark: false)
        let canvas = pixel(plain, at: nothing)
        let bad = Dimming(focus: [a: .nan, b: .infinity, c: -.infinity, frame: .nan])
        expectEqual(bad.focus, [a: 0, b: 0, c: 0, frame: 0], "set to 0 as the dim is made")
        first.dim = bad
        second.dim = Dimming(focus: [b: .nan, c: 0.8])
        expectEqual(h.editor.outlines.dim?.focus[b], 0, "joined: a number that isn't one is 0 whichever dim has it")
        expectEqual(h.editor.outlines.dim?.focus[c], 0.8, "and the other's strength is the stronger")
        // And one written into a dim after it's made, which the frame reads as 0 too.
        var late = Dimming(focus: [a: 1])
        late.focus[a] = .nan
        late.focus[frame] = .nan
        first.dim = late
        second.dim = nil
        let drawn = render(h.editor, dark: false)
        let shown = pixel(drawn, at: CGPoint(x: 30, y: 80)), full = pixel(plain, at: CGPoint(x: 30, y: 80))
        let alpha = 0.45 + 0.55 * 0.5 / 10
        expect(isBlend(shown, of: full, over: canvas, alpha: alpha), "the box at the faintest band: \(shown)")
    },
    test("a camera change leaves the dim out of the frame, a tinted ring still drawn; 150 ms after it the canvas is asked to draw again, and draws the dim") {
        let r = try Resting()
        let still = r.frames()
        expect(still.dimmed != still.plain, "at rest the box is dimmed")
        r.pan(by: 10)
        let moving = r.frames(shifted: 10)
        expectEqual(moving.dimmed, moving.plain, "moving: the box as it is, no dim")
        expect(moving.ring[0] > 250 && moving.ring[1] < 5 && moving.ring[2] < 5, "and the ring is drawn: \(moving.ring)")
        let asked = r.redraws.count
        r.h.wait(149)
        expectEqual(r.redraws.count, asked, "149 ms: not yet")
        expectEqual(r.frames(shifted: 10).dimmed, moving.plain, "still no dim")
        r.h.wait(1)
        expectEqual(r.redraws.count, asked + 1, "150 ms: asked to draw again")
        let rested = r.frames(shifted: 10)
        expect(rested.dimmed != rested.plain, "at rest the box is dimmed again")
        expectEqual(r.h.scheduler.pendingCount, 0, "the timer is spent")
        r.h.wait(1000)
        expectEqual(r.redraws.count, asked + 1, "and asks once")
    },
    test("changes 100 ms apart keep the dim out until 150 ms after the last, and ask for one frame") {
        let r = try Resting()
        r.pan(by: 10)
        _ = r.frames(shifted: 10)
        for step in 2...4 {
            r.h.wait(100)
            r.pan(by: 10)
            let moving = r.frames(shifted: CGFloat(10 * step))
            expectEqual(moving.dimmed, moving.plain, "change \(step): still no dim")
        }
        let asked = r.redraws.count
        r.h.wait(149)
        let late = r.frames(shifted: 40)
        expectEqual(late.dimmed, late.plain, "149 ms after the last change: out")
        expectEqual(r.redraws.count, asked, "and not asked")
        r.h.wait(1)
        expectEqual(r.redraws.count, asked + 1, "150 ms after the last: asked, once")
        let rested = r.frames(shifted: 40)
        expect(rested.dimmed != rested.plain, "dimmed again")
    },
    test("a camera set to the value it has is no motion: the dim is drawn, and no frame is asked for at rest") {
        let r = try Resting()
        r.pan(by: 10)
        r.h.wait(150)
        let same = r.h.editor.camera
        r.h.editor.camera = same
        let frames = r.frames(shifted: 10)
        expect(frames.dimmed != frames.plain, "the dim is drawn")
        let asked = r.redraws.count
        r.h.wait(1000)
        expectEqual(r.redraws.count, asked, "nothing asked later")
    },
    test("a camera that moves with no dim asks for no frame at rest, and sets no timer") {
        let r = try Resting()
        r.dimmed.dim = nil
        r.pan(by: 10)
        _ = r.frames(shifted: 10)
        let asked = r.redraws.count
        expectEqual(r.h.scheduler.pendingCount, 0, "no timer")
        r.h.wait(1000)
        expectEqual(r.redraws.count, asked, "no frame at rest")
    },
    test("a dim let go while the camera moves asks for no frame at rest") {
        let r = try Resting()
        r.pan(by: 10)
        _ = render(r.h.editor, dark: false)
        r.dimmed.dim = nil
        _ = render(r.h.editor, dark: false)
        let asked = r.redraws.count
        r.h.wait(1000)
        expectEqual(r.redraws.count, asked, "no frame at rest: nothing was left out")
    },
    test("a dim that first shows while the camera moves is left out, and drawn once it rests") {
        let r = try Resting()
        r.dimmed.dim = nil
        r.pan(by: 10)
        _ = render(r.h.editor, dark: false)
        r.h.wait(50)
        r.dimmed.dim = Dimming(focus: [:])
        let moving = r.frames(shifted: 10)
        expectEqual(moving.dimmed, moving.plain, "out while it moves")
        let asked = r.redraws.count
        r.h.wait(99)
        expectEqual(r.redraws.count, asked, "not yet")
        r.h.wait(1)
        expectEqual(r.redraws.count, asked + 1, "asked 150 ms after the change")
        let rested = r.frames(shifted: 10)
        expect(rested.dimmed != rested.plain, "dimmed")
    },
    test("an animation of the camera keeps the dim out until it has been still 150 ms") {
        let r = try Resting()
        r.h.editor.animateCamera(to: Camera(origin: CGPoint(x: 40, y: 0), zoom: 1), duration: .milliseconds(200))
        var frame = r.frames()
        for _ in 0..<6 {
            r.h.wait(16)
            frame = r.frames(shifted: r.h.editor.camera.origin.x)
            expectEqual(frame.dimmed, frame.plain, "no dim as it moves")
        }
        r.h.wait(104)
        expectEqual(r.h.editor.camera.origin.x, 40, "arrived at 200 ms")
        let asked = r.redraws.count
        r.h.wait(149)
        let last = r.frames(shifted: 40)
        expectEqual(last.dimmed, last.plain, "149 ms after it arrived: out")
        expectEqual(r.redraws.count, asked, "not asked yet")
        r.h.wait(1)
        expectEqual(r.redraws.count, asked + 1, "asked 150 ms after it arrived")
        let rested = r.frames(shifted: 40)
        expect(rested.dimmed != rested.plain, "dimmed")
    },
])

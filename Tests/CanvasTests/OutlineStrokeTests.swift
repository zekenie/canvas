import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import TestKit

// Open shapes' outlines are stroked a path each (rather than all in one: Core Graphics goes super-linear on thousands of
// round-capped lines crossing in one path), so what overlaps must still be painted once: a translucent tint is painted in one
// layer, and an opaque one is the same wherever lines cross.

private let strokeCanvas = CGSize(width: 320, height: 240)
private let widthRed = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)

/// How many view points of red lie across a column of `rep`: each pixel's share, from how far its red is past its green.
@MainActor private func redAcross(_ rep: NSBitmapImageRep, column x: CGFloat) -> CGFloat {
    (0..<Int(strokeCanvas.height)).reduce(0) { total, y in
        let p = pixel(rep, at: CGPoint(x: x, y: CGFloat(y)))
        return total + CGFloat(p[0] - p[1]) / 255
    }
}

@MainActor let outlineStrokeTests = Suite("Outline strokes", [
    test("lines crossing in a translucent tint are painted once where they cross: covers at 100%, skeleton lines at 10%") {
        for zoom: CGFloat in [1, 0.1] {
            let outlined = Outlined()
            let h = try outlineHarness(outlined)
            h.editor.camera = Camera(origin: .zero, zoom: zoom)
            let scale = 1 / zoom
            // Two cables across each other at the middle of the view, a third one alone beside them.
            let a = h.add(Cable(from: CGPoint(x: 40 * scale, y: 60 * scale), to: CGPoint(x: 160 * scale, y: 180 * scale)))
            let b = h.add(Cable(from: CGPoint(x: 40 * scale, y: 180 * scale), to: CGPoint(x: 160 * scale, y: 60 * scale)))
            let c = h.add(Cable(from: CGPoint(x: 200 * scale, y: 120 * scale), to: CGPoint(x: 300 * scale, y: 120 * scale)))
            let plain = renderBitmap(h.editor, size: strokeCanvas)
            outlined.tinted = [TintedOutlines(color: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.5), shapes: [a, b, c])]
            let drawn = renderBitmap(h.editor, size: strokeCanvas)
            let alone = pixel(drawn, at: CGPoint(x: 250, y: 120))
            let crossing = pixel(drawn, at: CGPoint(x: 100, y: 120))
            let arm = pixel(drawn, at: CGPoint(x: 70, y: 90))
            expect(alone[0] - alone[1] > 50, "the tint is painted on the line alone, at \(zoom * 100)%: \(alone)")
            // Along a slanted line (its pixels as covered as the crossing's), the same strength.
            expect(abs(crossing[0] - arm[0]) <= 3 && abs(crossing[1] - arm[1]) <= 3 && abs(crossing[2] - arm[2]) <= 3,
                   "where two lines cross the tint is no stronger than along one, at \(zoom * 100)%: \(crossing) against \(arm)")
            expect(changedPixels(plain, drawn, in: CGRect(x: 0, y: 0, width: 320, height: 240)) > 100, "the lines were drawn at \(zoom * 100)%")
        }
    },
    test("many open shapes tinted an opaque color paint it whole where they cross, each one's line in a path of its own") {
        let outlined = Outlined()
        let h = try outlineHarness(outlined)
        var ids: [ShapeID] = []
        // Cables fanned from one point: all cross at it.
        for i in 0..<12 {
            let angle = CGFloat(i) * .pi / 12
            ids.append(h.add(Cable(from: CGPoint(x: 160 - cos(angle) * 100, y: 120 - sin(angle) * 100),
                                   to: CGPoint(x: 160 + cos(angle) * 100, y: 120 + sin(angle) * 100))))
        }
        outlined.tinted = [TintedOutlines(color: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), shapes: ids)]
        let drawn = renderBitmap(h.editor, size: strokeCanvas)
        let middle = pixel(drawn, at: CGPoint(x: 160, y: 120))
        expect(middle[0] > 250 && middle[1] < 5 && middle[2] < 5, "the point they all cross is the tint, whole: \(middle)")
        let tip = pixel(drawn, at: CGPoint(x: 160 + 99, y: 120))
        expect(tip[0] > 250 && tip[1] < 5, "and a line's end: \(tip)")
    },
    test("a group's width is its line's width in view points at every zoom: nil is the core's 2, and where its ring stands doesn't move") {
        for zoom: CGFloat in [1, 2] {
            let outlined = Outlined()
            let h = try outlineHarness(outlined)                        // the shipped standoff
            expectEqual(Style.outlineStandoff, 4, "these pixels are for a standoff of 4")
            h.editor.camera = Camera(origin: .zero, zoom: zoom)
            let box = h.add(Box(CGRect(x: 40, y: 40, width: 80, height: 40)))
            let top = 40 * zoom, column = 80 * zoom
            // The top's line, down a column through the middle of the box's top side: 4 off the edge, a line wide.
            @MainActor func across(_ width: CGFloat?) -> (thickness: CGFloat, center: CGFloat) {
                outlined.tinted = [TintedOutlines(color: widthRed, shapes: [box], width: width)]
                let rep = renderBitmap(h.editor, size: strokeCanvas)
                var total: CGFloat = 0, weighted: CGFloat = 0
                for y in 0..<Int(top) {
                    let p = pixel(rep, at: CGPoint(x: column, y: CGFloat(y)))
                    let share = CGFloat(p[0] - p[1]) / 255
                    total += share
                    weighted += share * (CGFloat(y) + 0.5)
                }
                return (total, total > 0 ? weighted / total : 0)
            }
            let core = across(nil), two = across(2), six = across(6), one = across(1)
            expect(abs(core.thickness - 2) < 0.1, "nil is 2 view points, at \(zoom * 100)%: \(core.thickness)")
            expect(abs(two.thickness - 2) < 0.1 && abs(two.center - core.center) < 0.1, "2 is the core's, in the same place, at \(zoom * 100)%")
            expect(abs(six.thickness - 6) < 0.1, "6 view points wide at \(zoom * 100)%: \(six.thickness)")
            expect(abs(one.thickness - 1) < 0.1, "1 view point wide at \(zoom * 100)%: \(one.thickness)")
            expect(abs(six.center - core.center) < 0.1 && abs(one.center - core.center) < 0.1, "centered where the core's line is, 4 off the edge, at \(zoom * 100)%")
            expect(abs(core.center - (top - 4)) < 0.1, "4 off the edge: \(core.center) for an edge at \(top)")
        }
    },
    test("a group's width reaches a line's cover and a skeleton's ring: a cover is never narrower than it, and zoomed out the ring is that wide") {
        let outlined = Outlined()
        let h = try outlineHarness(outlined)
        let cable = h.add(Cable(from: CGPoint(x: 20, y: 60), to: CGPoint(x: 140, y: 60)))      // 6 wide: its cover 7 at 100%
        let box = h.add(Box(CGRect(x: 200, y: 200, width: 500, height: 300)))
        for (width, wanted) in [(nil, 7), (3, 7), (12, 12)] as [(CGFloat?, CGFloat)] {
            outlined.tinted = [TintedOutlines(color: widthRed, shapes: [cable], width: width)]
            h.editor.camera = Camera(origin: .zero, zoom: 1)
            let thickness = redAcross(renderBitmap(h.editor, size: strokeCanvas), column: 80)
            expect(abs(thickness - wanted) < 0.1, "the cover with width \(String(describing: width)): \(thickness), not \(wanted)")
        }
        // Zoomed out the ring is on the frame, the line's width wide: 6 points, the two columns of 3 either side of x = 140.
        outlined.tinted = [TintedOutlines(color: widthRed, shapes: [box], width: 6)]
        h.editor.camera = Camera(origin: .zero, zoom: 0.2)
        expect(h.editor.drawsSkeletons)
        let ring = renderBitmap(h.editor, size: strokeCanvas)
        var across: CGFloat = 0
        for x in 100..<180 {
            let p = pixel(ring, at: CGPoint(x: CGFloat(x), y: 70))
            if p[0] > 200 && p[1] < 50 { across += 1 }                  // the ring's pixels are whole: opaque red
        }
        expect(abs(across - 6) < 0.2, "a ring 6 wide on the right edge: \(across)")
    },
    test("a group's width is part of what makes two groups equal, so a plugin that keeps what it hands the core sees a change") {
        let box = ShapeID()
        expect(TintedOutlines(color: widthRed, shapes: [box]) == TintedOutlines(color: widthRed, shapes: [box], width: nil))
        expect(TintedOutlines(color: widthRed, shapes: [box]) != TintedOutlines(color: widthRed, shapes: [box], width: 4))
        expect(Outlines(tinted: [TintedOutlines(color: widthRed, shapes: [box], width: 3)]) != Outlines(tinted: [TintedOutlines(color: widthRed, shapes: [box], width: 4)]))
    },
    test("many large tinted groups with few shapes in view make a set each once, kept through frames in the order they're drawn, and one map of rings for the groups") {
        #if DEBUG
        let outlined = Outlined(), probe = OutsetProbe()
        let h = try outlineHarness(outlined, probe: probe)
        // Twelve groups of 40 boxes each, the boxes far off to the right but for the first of each, which are in view.
        var groups: [TintedOutlines] = []
        var visible: [ShapeID] = []
        for group in 0..<12 {
            var ids: [ShapeID] = []
            for i in 0..<40 {
                let x = i == 0 ? 10 + CGFloat(group) * 20 : 5_000 + CGFloat(group * 40 + i) * 150
                ids.append(h.add(Box(CGRect(x: x, y: i == 0 ? 20 : 10, width: 10, height: 10))))
            }
            visible.append(ids[0])
            groups.append(TintedOutlines(color: widthRed, shapes: ids, ring: group % 3))
        }
        outlined.tinted = groups
        probe.shapes = visible
        h.editor.camera = Camera(origin: .zero, zoom: 1)
        let counted = h.editor.outlineSetsMade, rings = h.editor.tintedRingMapsMade
        _ = renderBitmap(h.editor, size: strokeCanvas)
        expectEqual(h.editor.outlineSetsMade, counted + 12, "a set for each group, the first frame")
        expectEqual(h.editor.tintedRingMapsMade, rings + 1, "one map of rings for the groups")
        expect(probe.outsets[visible[0]] != nil, "an overlay asked")
        for _ in 0..<3 { _ = renderBitmap(h.editor, size: strokeCanvas) }
        h.editor.camera = Camera(origin: CGPoint(x: 1, y: 1), zoom: 1)
        _ = renderBitmap(h.editor, size: strokeCanvas)
        expectEqual(h.editor.outlineSetsMade, counted + 12, "no set made again over more frames, and a pan")
        expectEqual(h.editor.tintedRingMapsMade, rings + 1, "nor the map of rings")
        // A group changed: its set and the map are made again, the others kept.
        outlined.tinted[3] = TintedOutlines(color: widthRed, shapes: Array(groups[3].shapes.dropLast()), ring: 3)
        _ = renderBitmap(h.editor, size: strokeCanvas)
        expectEqual(h.editor.outlineSetsMade, counted + 13, "one set more, for the group that changed")
        expectEqual(h.editor.tintedRingMapsMade, rings + 2, "and the map")
        #endif
    },
])

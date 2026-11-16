import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Geometry
import Mentions
import ShippedTesting
import StickyNotes
import TestKit

// What outlining open shapes costs a frame: a hover that lights thousands of arrows strokes a line for each (and a cover under it
// at 100%), and the lines cross over each other. Each shape is stroked in a path of its own, so the cost is a shape's, however many
// cross: Core Graphics, given one path of thousands of overlapping round-capped lines, took +1.9 s a frame at 2,561 arrows at 10%
// and +58 s at 8,700. `./build.sh bench` holds the cost of a lit shape and that it stays one as their number grows; `./test.sh`
// runs it small, in debug, and only reports.

extension Budget {
    /// What one tinted open shape adds to a frame zoomed out to 10%, where each is a skeleton's line, in microseconds of the
    /// thread's CPU time, at 2,500 lit and at 8,000 (some 9 µs).
    static let litArrow = 15.0
    /// How many times more a lit shape may cost at 8,000 lit than at 2,500: one for linear, with room for the noise of a busy
    /// machine (a path of all of them grew some sixty times over the same growth).
    static let litArrowGrowth = 2.0
}

// And what a dim adds to a frame (`Outlines.dim`): the shapes in view each asked whether they're kept, and drawn in layers, one for
// the shapes that aren't, one for each band of strength.

extension Budget {
    /// What a dim adds to a frame over the same frame with none, with 1,900 boxes in view at 100%, in milliseconds of the thread's
    /// CPU, held for the worst of three: none kept, one in ten kept (the rest in one layer, the kept over it) and all of them
    /// kept in three bands of strength (a layer each, 0.25, 0.55 and 0.85). The design proposed 5 ms, which a layer over a view
    /// 1,200 × 800 points costs by itself (some 3.5 ms, each, whatever it holds: the pass that clears and composites it), so with
    /// the unkept shapes' layer it holds for one band; this is set to what it measures, some 3.5 ms with none kept and 10.5 with
    /// three bands. All kept in ten bands, reported and not held, is 31 ms: a dim costs a layer for each strength band in use.
    static let dimFrame100 = 14.0
    /// The same with 10,000 notes, all in view zoomed out to 10%, where each is a skeleton (some 7 ms with none kept, 14 with three
    /// bands, the design's 8 being for one band; ten bands 35).
    static let dimFrame10 = 18.0
}

// And what a dim with many kept frames below full strength adds (a layer for each frame, clipped to the frame, consecutive ones of
// one strength in one), and tinted groups many and large with few of their shapes in view (a set made for each, kept).

extension Budget {
    /// What a dim over 48 frames in view at 100%, every one kept at a strength under 1 (alternating among three, so no two in a row
    /// share a layer), adds to a frame, in milliseconds of the thread's CPU. A layer the size of the view costs some 3.5 ms, which
    /// 48 of them would be 170; clipped to each frame, a layer costs what the frame covers.
    static let dimFrames = 25.0
    /// What twenty tinted groups of 2,000 shapes each, on a board of 20,000 with some 20 in view, add to a frame at 100%, in
    /// milliseconds of the thread's CPU: the sets of the groups' ids are made once and kept, and a frame goes through the shapes in
    /// view, not the groups' ids. It measures some 0.5 ms (the sets' cache held to four lists, as it was, made all twenty sets
    /// again every frame: some 2 ms), so this is set between the two.
    static let tintedGroupsFrame = 1.5
}

/// What the lit-arrows benchmark outlines: set to the ids, tinted, or empty.
@MainActor private final class Lit {
    var shapes: [ShapeID] = []
    var groups: [TintedOutlines] = []
}

@MainActor let outlineBenchmarks = Suite("Outline benchmarks", [
    test("lit open shapes cost a frame each: tinted arrows, 2,500 and 8,000 of them crossing over each other, at 10%, linear in their number") {
        #if DEBUG
        let counts = [100, 300]
        #else
        let counts = [2_500, 8_000]
        #endif
        let viewport = CGSize(width: 1200, height: 800)
        let context = try bitmapContext(viewport)
        var perShape: [Double] = []
        for count in counts {
            let lit = Lit()
            let h = try EditorHarness(plugins: [FixturesPlugin(), CablesPlugin(), Contributor(id: "lights") { r in
                r.outlines { _ in
                    Outlines(tinted: lit.shapes.isEmpty ? [] : [TintedOutlines(color: NSColor(srgbRed: 0.8, green: 0.2, blue: 0.9, alpha: 1), shapes: lit.shapes)])
                }
            }])
            // Lines of 300 to 2,000 units at every angle across the 12,000 × 8,000 the view shows at 10%: each crossing many.
            var seed: UInt64 = 0x9E3779B97F4A7C15
            func next() -> CGFloat {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return CGFloat(seed >> 33) / CGFloat(1 << 31)
            }
            var ids: [ShapeID] = []
            for _ in 0..<count {
                let from = CGPoint(x: next() * 11_000, y: next() * 7_000)
                let angle = next() * .pi * 2, length = 300 + next() * 1_700
                ids.append(h.add(Cable(from: from, to: CGPoint(x: from.x + cos(angle) * length, y: from.y + sin(angle) * length))))
            }
            h.editor.viewportDidResize(to: viewport)
            let board = CGRect(x: 0, y: 0, width: 12_000, height: 8_000)
            let camera = camera(centering: board, at: 0.1, in: viewport)
            // A frame drawn again with the camera a point from the last one's, as a pan's is.
            @MainActor func frame() -> Double {
                var step = 0.0
                let pan = {
                    step = step == 0 ? 1 : 0
                    h.editor.camera = Camera(origin: CGPoint(x: camera.origin.x + step / camera.zoom, y: camera.origin.y), zoom: camera.zoom)
                }
                h.editor.camera = camera
                draw(h.editor, into: context, size: viewport)
                return median(runs: 5, prepare: pan, onThread: true) { draw(h.editor, into: context, size: viewport) }
            }
            let unlit = frame()
            lit.shapes = ids
            let drawn = frame()
            let each = (drawn - unlit) * 1000 / Double(count)
            perShape.append(each)
            report(String(format: "%5d lit arrows at 10%%: a frame %7.1f ms over %6.1f unlit, %5.1f µs a shape (budget %.0f)", count, drawn - unlit, unlit, each, Budget.litArrow))
            if holdsToBudgets { expect(each < Budget.litArrow, "\(count) lit arrows cost \(each) µs each in a frame") }
        }
        if let small = perShape.first, let large = perShape.last, small > 0 {
            report(String(format: "a lit arrow costs %.2f times as much at %d lit as at %d (limit %.1f)", large / small, counts[1], counts[0], Budget.litArrowGrowth))
            if holdsToBudgets { expect(large / small < Budget.litArrowGrowth, "a lit arrow cost \(large / small) times as much at \(counts[1]) as at \(counts[0])") }
        }
    },
    test("a dim adds little to a frame: 1,900 notes in view at 100%, and 10,000 zoomed out to 10%, none kept, one in ten kept and kept in three bands of strength") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let viewport = CGSize(width: 1200, height: 800)
        let context = try bitmapContext(viewport)
        for (what, count, zoom, spacing, side, budget) in [("1,900 in view at 100%", 1_944, CGFloat(1), CGFloat(22), CGFloat(16), Budget.dimFrame100),
                                                            ("10,000 in view at 10%", 10_000, CGFloat(0.1), CGFloat(95), CGFloat(80), Budget.dimFrame10)] {
            #if DEBUG
            let count = min(count, 300)
            #endif
            let kept = KeptBox()
            let dimmer = Contributor(id: "dimmer") { r in r.outlines { _ in Outlines(dim: kept.dim) } }
            let registry = try Registry(plugins: zoom == 1 ? [FixturesPlugin(), dimmer] : shippedPlugins(pasteboard) + [dimmer])
            let columns = zoom == 1 ? 54 : 120
            var records: [AnyShapeRecord] = []
            for i in 0..<count {
                let frame = CGRect(x: CGFloat(i % columns) * spacing, y: CGFloat(i / columns) * spacing, width: side, height: side)
                // Notes where they're skeletons; at 100% boxes, which draw a fill and its shadow, so the frame isn't the notes' text.
                records.append(zoom == 1 ? AnyShapeRecord(ShapeRecord(id: ShapeID(), Box(frame)))
                                         : AnyShapeRecord(ShapeRecord(id: ShapeID(), StickyNote(frame: frame, text: MentionText(plain: "Note \(i)")))))
            }
            let h = EditorHarness { CanvasEditor(registry: registry, document: CanvasDocument(shapes: records), scheduler: $0) }
            h.editor.viewportDidResize(to: viewport)
            let board = h.editor.shapeBounds
            let camera = zoom == 1 ? Camera(origin: .zero, zoom: 1) : camera(centering: board, at: zoom, in: viewport)
            // Each frame after the camera has rested (150 ms on the harness's clock): the core leaves a dim out while it moves.
            @MainActor func frame() -> Double {
                var step = 0.0
                let pan = {
                    step = step == 0 ? 1 : 0
                    h.editor.camera = Camera(origin: CGPoint(x: camera.origin.x + step / camera.zoom, y: camera.origin.y), zoom: camera.zoom)
                    h.wait(150)
                }
                h.editor.camera = camera
                h.wait(150)
                draw(h.editor, into: context, size: viewport)
                return median(runs: 11, prepare: pan, onThread: true) { draw(h.editor, into: context, size: viewport) }
            }
            let ids = records.map(\.id)
            let none = frame()
            var lines: [String] = []
            var worst = 0.0
            let variants: [(String, Dimming)] = [
                ("none kept", Dimming(focus: [:])),
                ("one in ten kept", Dimming(focus: Dictionary(uniqueKeysWithValues: ids.enumerated().filter { $0.offset % 10 == 0 }.map { ($0.element, CGFloat(1)) }))),
                ("all kept in 3 bands", Dimming(focus: Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, [0.25, 0.55, 0.85][$0.offset % 3]) }))),
                ("all kept in 10 bands", Dimming(focus: Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, CGFloat($0.offset % 10) / 10 + 0.05) }))),
            ]
            for (name, dim) in variants {
                kept.dim = dim
                let added = frame() - none
                if !name.hasSuffix("10 bands") { worst = max(worst, added) }
                lines.append(String(format: "%@ +%.2f ms", name, added))
            }
            kept.dim = nil
            report(String(format: "%d notes (%@), the frame %.1f ms undimmed: %@ (budget %.0f)", count, what, none, lines.joined(separator: "; "), budget))
            if holdsToBudgets { expect(worst < budget, "a dim added \(worst) ms to a frame of \(what)") }
        }
    },
    test("a dim with many frames kept below full strength adds little to a frame: 48 frames in view, each a layer clipped to its own size") {
        let viewport = CGSize(width: 1200, height: 800)
        let context = try bitmapContext(viewport)
        let kept = KeptBox()
        let h = try EditorHarness(plugins: [FixturesPlugin(), CorralsPlugin(), Contributor(id: "dimmer") { r in r.outlines { _ in Outlines(dim: kept.dim) } }])
        var frames: [ShapeID] = []
        for i in 0..<48 {
            let frame = CGRect(x: CGFloat(i % 8) * 150 + 5, y: CGFloat(i / 8) * 130 + 5, width: 140, height: 120)
            frames.append(h.add(Corral(frame)))
            _ = h.add(Box(CGRect(x: frame.minX + 20, y: frame.minY + 20, width: 40, height: 30)))
        }
        h.editor.viewportDidResize(to: viewport)
        h.editor.camera = Camera(origin: .zero, zoom: 1)
        // Each frame after the camera has rested (150 ms on the harness's clock): the core leaves a dim out while it moves.
        @MainActor func frame() -> Double {
            var step = 0.0
            let pan = {
                step = step == 0 ? 1 : 0
                h.editor.camera = Camera(origin: CGPoint(x: step, y: 0), zoom: 1)
                h.wait(150)
            }
            h.wait(150)
            draw(h.editor, into: context, size: viewport)
            return median(runs: 7, prepare: pan, onThread: true) { draw(h.editor, into: context, size: viewport) }
        }
        let none = frame()
        kept.dim = Dimming(focus: Dictionary(uniqueKeysWithValues: frames.enumerated().map { ($0.element, [0.25, 0.55, 0.85][$0.offset % 3]) }))
        let alternating = frame() - none
        kept.dim = Dimming(focus: Dictionary(uniqueKeysWithValues: frames.map { ($0, CGFloat(0.55)) }))
        let alike = frame() - none
        kept.dim = nil
        report(String(format: "48 frames kept under full in view at 100%%, the frame %.1f ms undimmed: strengths alternating +%.2f ms, all one +%.2f ms (budget %.0f)", none, alternating, alike, Budget.dimFrames))
        if holdsToBudgets { expect(max(alternating, alike) < Budget.dimFrames, "a dim over many kept frames added \(max(alternating, alike)) ms to a frame") }
    },
    test("many large tinted groups with few of their shapes in view cost a frame the shapes in view: twenty groups of 2,000 on 20,000 boxes") {
        #if DEBUG
        let (count, perGroup) = (2_000, 100)
        #else
        let (count, perGroup) = (20_000, 2_000)
        #endif
        let viewport = CGSize(width: 1200, height: 800)
        let context = try bitmapContext(viewport)
        let lit = Lit()
        let h = try EditorHarness(plugins: [FixturesPlugin(), Contributor(id: "lights") { r in
            r.outlines { _ in Outlines(tinted: lit.groups) }
        }])
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next() -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int(seed >> 33)
        }
        // Boxes over a board of 30,000 × 30,000, the view showing 1,200 × 800 of it: some 20 in view.
        var ids: [ShapeID] = []
        for _ in 0..<count {
            ids.append(h.add(Box(CGRect(x: CGFloat(next() % 30_000), y: CGFloat(next() % 30_000), width: 40, height: 30))))
        }
        h.editor.viewportDidResize(to: viewport)
        h.editor.camera = Camera(origin: .zero, zoom: 1)
        @MainActor func frame() -> Double {
            var step = 0.0
            let pan = {
                step = step == 0 ? 1 : 0
                h.editor.camera = Camera(origin: CGPoint(x: step, y: 0), zoom: 1)
            }
            draw(h.editor, into: context, size: viewport)
            return median(runs: 9, prepare: pan, onThread: true) { draw(h.editor, into: context, size: viewport) }
        }
        let unlit = frame()
        lit.groups = (0..<20).map { group in
            TintedOutlines(color: NSColor(srgbRed: 0.8, green: 0.2, blue: 0.9, alpha: 1), shapes: (0..<perGroup).map { ids[(group * 997 + $0 * 7) % count] }, ring: group % 4)
        }
        let added = frame() - unlit
        lit.groups = []
        report(String(format: "20 tinted groups of %d on %d boxes, a frame %.2f ms over %.1f unlit (budget %.0f)", perGroup, count, added, unlit, Budget.tintedGroupsFrame))
        if holdsToBudgets { expect(added < Budget.tintedGroupsFrame, "twenty tinted groups added \(added) ms to a frame") }
    },
])


@MainActor private final class KeptBox {
    var dim: Dimming?
}
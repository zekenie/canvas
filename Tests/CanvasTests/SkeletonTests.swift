import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import TestKit

/// A box that says what it was asked to draw: its render fills it black, its skeleton
/// (`CustomSkeleton`) fills it green through the default's drawing, with two greeked lines that
/// overlap across its top half; its outline (`indicatorPath`) is the ellipse inside it, so an
/// outline of its geometry (the frame) tells from one of its own; and its skeleton's outline is
/// that geometry's, or, once its log says so (`outlinesSkeleton`), the frame's middle half, a rect
/// a quarter in from each side. Editable, with an empty view.
struct Sketch: BoxShapeProps {
    static let kind: ShapeKind = "sketch"
    static let properties = Properties<Sketch> {
        Property("frame", \.frame).required()
    }
    var frame: CGRect
}

extension Sketch {
    init() { self.init(frame: .zero) }
}

@MainActor final class SketchLog {
    var renders: [ShapeID] = []
    var skeletons: [ShapeID] = []
    var indicators: [ShapeID] = []
    var skeletonIndicators: [ShapeID] = []
    var outlinesSkeleton = false

    func clear() {
        renders = []
        skeletons = []
        indicators = []
        skeletonIndicators = []
    }
}

struct SketchDefinition {
    let log: SketchLog
    static let green = NSColor(srgbRed: 0, green: 0.8, blue: 0, alpha: 1)
}

extension SketchDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Sketch>, in context: RenderContext) {
        log.renders.append(shape.id)
        context.cg.setFillColor(CGColor(gray: 0, alpha: 1))
        context.cg.fill(shape.frame)
    }

    func indicatorPath(of shape: ShapeRecord<Sketch>, in context: ShapeContext) -> CGPath {
        log.indicators.append(shape.id)
        return CGPath(ellipseIn: shape.frame, transform: nil)
    }
}

extension SketchDefinition: CustomSkeleton {
    func renderSkeleton(_ shape: ShapeRecord<Sketch>, in context: RenderContext) {
        log.skeletons.append(shape.id)
        if let geometry = context.shapes.geometry(of: shape.id) { context.drawSkeleton(of: geometry, color: Self.green) }
        let f = shape.frame
        // Handed over as they're made, with no array.
        context.fillSkeletonText((0..<2).lazy.map { CGRect(x: f.minX + f.width / 3 * CGFloat($0), y: f.minY, width: f.width * 2 / 3, height: f.height / 2) })
    }
}

extension SketchDefinition: CustomSkeletonOutline {
    func skeletonIndicatorPath(of shape: ShapeRecord<Sketch>, in context: ShapeContext) -> CGPath? {
        log.skeletonIndicators.append(shape.id)
        return log.outlinesSkeleton ? CGPath(rect: shape.frame.insetBy(dx: shape.frame.width / 4, dy: shape.frame.height / 4), transform: nil) : nil
    }
}

extension SketchDefinition: Editable {
    func makeEditingView(for shape: ShapeRecord<Sketch>, context: EditContext<Sketch>) -> EditingView {
        let view = NSView()
        return EditingView(view: view, firstResponder: view)
    }
}

/// What an overlay was told, each frame: whether shapes are skeletons, and whether one shape is.
@MainActor final class SkeletonProbe {
    var shape: ShapeID?
    var told: [(all: Bool, shape: Bool)] = []
}

struct SkeletonProbeOverlay: CanvasOverlay {
    let probe: SkeletonProbe
    var space: OverlaySpace { .world }
    func draw(in context: OverlayContext) {
        probe.told.append((context.drawsSkeletons, probe.shape.map { context.drawsSkeleton(of: $0) } ?? false))
    }
}

@MainActor final class Redraws: CanvasEditorDelegate {
    var count = 0
    func editorNeedsDisplay(_ editor: CanvasEditor) { count += 1 }
    func editorCursorDidChange(_ editor: CanvasEditor) {}
    func editorEditingDidChange(_ editor: CanvasEditor) {}
}

@MainActor private func sketches(_ log: SketchLog, outlined: Outlined = Outlined(), probe: SkeletonProbe = SkeletonProbe()) -> Contributor {
    Contributor(id: "sketches") {
        $0.shape(SketchDefinition(log: log))
        $0.outlines { _ in Outlines(shapes: outlined.shapes, rects: outlined.rects, faintShapes: outlined.faint) }
        $0.overlay(SkeletonProbeOverlay(probe: probe))
    }
}

/// A color as `renderBitmap` puts it in a bitmap, 0...255 RGBA.
@MainActor private func swatch(_ color: NSColor) -> [Int] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let cg = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    cg.setFillColor(color.cgColor)
    cg.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    return pixel(rep, at: CGPoint(x: 1, y: 1))
}

/// The default skeleton's gray on the light canvas: a board preview's (`Style.boardPreview`).
@MainActor private var skeletonGray: [Int] { swatch(NSColor(srgbRed: 0.6, green: 0.62, blue: 0.64, alpha: 1)) }

/// The rects just outside a rect of view points, `width` deep: where a shadow would show.
private func ring(around rect: CGRect, width: CGFloat) -> [CGRect] {
    [CGRect(x: rect.minX - width, y: rect.minY - width, width: rect.width + 2 * width, height: width),
     CGRect(x: rect.minX - width, y: rect.maxY, width: rect.width + 2 * width, height: width),
     CGRect(x: rect.minX - width, y: rect.minY, width: width, height: rect.height),
     CGRect(x: rect.maxX, y: rect.minY, width: width, height: rect.height)]
}

@MainActor private func changedPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, in rects: [CGRect]) -> Int {
    rects.reduce(0) { $0 + changedPixels(a, b, in: $1) }
}

// Shapes zoomed out (`CustomSkeleton`): under the editor's `skeletonZoom` each draws its skeleton in
// place of its render, a kind's own or the default (its geometry in one gray), but the shape being
// edited; and outlines, drawn only for shapes near the view, follow what's drawn.
@MainActor let skeletonTests = Suite("Skeletons", [
    test("below skeletonZoom (35%) a kind's own skeleton draws in place of its render; at it and above, its render") {
        let log = SketchLog(), probe = SkeletonProbe()
        let h = try EditorHarness(plugins: [sketches(log, probe: probe)])
        let id = h.add(Sketch(frame: CGRect(x: 0, y: 0, width: 100, height: 100)))
        expectEqual(h.editor.skeletonZoom, 0.35)
        for (zoom, skeleton) in [(0.1, true), (0.3, true), (0.349, true), (0.35, false), (1, false), (4, false)] as [(CGFloat, Bool)] {
            log.clear()
            probe.told = []
            h.editor.camera = Camera(zoom: zoom)
            expectEqual(h.editor.drawsSkeletons, skeleton, "at \(zoom)")
            _ = renderBitmap(h.editor, size: CGSize(width: 100, height: 100))
            expectEqual(log.skeletons, skeleton ? [id] : [], "at \(zoom)")
            expectEqual(log.renders, skeleton ? [] : [id], "at \(zoom)")
            expectEqual(probe.told.map(\.all), [skeleton], "overlays are told, at \(zoom)")
        }
    },
    test("a kind's skeleton draws with the default's drawing in its own color, and greeked lines in one translucent fill over it") {
        let log = SketchLog()
        let h = try EditorHarness(plugins: [sketches(log)])
        h.add(Sketch(frame: CGRect(x: 0, y: 0, width: 300, height: 300)))    // 90 points square at 30%
        h.editor.camera = Camera(zoom: 0.3)
        let rep = renderBitmap(h.editor, size: CGSize(width: 100, height: 100))
        let fill = pixel(rep, at: CGPoint(x: 45, y: 70))
        expectEqual(fill, swatch(SketchDefinition.green), "the lower half is the skeleton's fill")
        let first = pixel(rep, at: CGPoint(x: 10, y: 10)), both = pixel(rep, at: CGPoint(x: 45, y: 10)), second = pixel(rep, at: CGPoint(x: 80, y: 10))
        expect(first[0...2].reduce(0, +) < fill[0...2].reduce(0, +) && first[1] > 0, "a line is the fill darkened: \(first) over \(fill)")
        expectEqual(both, first, "two lines where they overlap are no darker than one: one fill")
        expectEqual(second, first)
    },
    test("the default skeleton fills a box's frame in one gray, with no shadow past it; a shape with no outline draws nothing") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        h.editor.camera = Camera(zoom: 0.3)
        let size = CGSize(width: 120, height: 90)
        let empty = renderBitmap(h.editor, size: size)
        h.add(Tag(target: nil))
        expectEqual(changedPixels(empty, renderBitmap(h.editor, size: size), in: CGRect(origin: .zero, size: size)), 0, "a tag has no outline")
        h.add(Box(CGRect(x: 100, y: 100, width: 200, height: 100)))             // (30, 30) to (90, 60) on screen
        let skeleton = renderBitmap(h.editor, size: size)
        expectEqual(pixel(skeleton, at: CGPoint(x: 60, y: 45)), skeletonGray)
        expectEqual(pixel(skeleton, at: CGPoint(x: 31, y: 31)), skeletonGray, "to its corners")
        let frame = CGRect(x: 30, y: 30, width: 60, height: 30)
        expectEqual(changedPixels(empty, skeleton, in: ring(around: frame, width: 4)), 0, "nothing past its frame")
        h.editor.skeletonZoom = 0
        let full = renderBitmap(h.editor, size: size)
        expect(changedPixels(empty, full, in: ring(around: frame, width: 4)) > 0, "its render's shadow shows past it")
        expect(pixel(full, at: CGPoint(x: 60, y: 45)) != skeletonGray, "its render is its own gray")
    },
    test("the default skeleton fills a disc's geometry, not its bounds; a line's is stroked") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), LinksPlugin()])
        h.editor.camera = Camera(zoom: 0.3)
        let size = CGSize(width: 200, height: 120)
        let empty = renderBitmap(h.editor, size: size)
        h.add(Disc(CGRect(x: 100, y: 100, width: 200, height: 200)))           // (30, 30) to (90, 90) on screen
        let disc = renderBitmap(h.editor, size: size)
        expectEqual(pixel(disc, at: CGPoint(x: 60, y: 60)), skeletonGray)
        expectEqual(pixel(disc, at: CGPoint(x: 32, y: 32)), pixel(empty, at: CGPoint(x: 32, y: 32)), "its bounds' corner is left empty")

        let lines = try EditorHarness(plugins: [FixturesPlugin(), LinksPlugin()])
        lines.editor.camera = Camera(zoom: 0.3)
        let a = lines.add(Box(CGRect(x: 0, y: 200, width: 100, height: 100))), b = lines.add(Box(CGRect(x: 500, y: 200, width: 100, height: 100)))
        let boxes = renderBitmap(lines.editor, size: size)
        lines.add(Link(from: a, to: b))                                          // (15, 75) to (165, 75) on screen
        let linked = renderBitmap(lines.editor, size: size)
        expect(changedPixels(boxes, linked, in: CGRect(x: 40, y: 73, width: 100, height: 4)) > 0, "the line between them")
        expectEqual(changedPixels(boxes, linked, in: CGRect(x: 40, y: 0, width: 100, height: 72)), 0, "only there")
        expectEqual(changedPixels(boxes, linked, in: CGRect(x: 40, y: 78, width: 100, height: 42)), 0, "only there")
        lines.editor.skeletonZoom = 0
        expectEqual(changedPixels(boxes, renderBitmap(lines.editor, size: size), in: CGRect(x: 40, y: 73, width: 100, height: 4)), 0,
                    "its render draws nothing: the line is its skeleton")
    },
    test("a shape a pixel or less across still shows, the pixel its middle is in, whole; one a few pixels across is its bounds") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        h.editor.camera = Camera(zoom: 0.1)
        let size = CGSize(width: 100, height: 60)
        let empty = renderBitmap(h.editor, size: size)
        h.add(Disc(CGRect(x: 300, y: 300, width: 5, height: 5)))                // half a point on screen, from (30, 30)
        h.add(Disc(CGRect(x: 600, y: 300, width: 30, height: 30)))              // 3 points, at (60, 30)
        h.add(Disc(CGRect(x: 396, y: 396, width: 8, height: 8)))                // 0.8 points, its middle on a pixel's corner, (40, 40)
        let rep = renderBitmap(h.editor, size: size)
        /// What changed in the 5 × 5 pixels around a point.
        @MainActor func changed(around point: CGPoint) -> [[Int]] {
            (-2...2).flatMap { dy in (-2...2).map { dx in CGPoint(x: point.x + CGFloat(dx), y: point.y + CGFloat(dy)) } }
                .filter { pixel(rep, at: $0) != pixel(empty, at: $0) }.map { pixel(rep, at: $0) }
        }
        expectEqual(pixel(rep, at: CGPoint(x: 30, y: 30)), skeletonGray, "the tiny one is the pixel its middle is in, whole")
        expectEqual(changed(around: CGPoint(x: 30, y: 30)), [skeletonGray], "that pixel alone")
        expectEqual(changed(around: CGPoint(x: 40, y: 40)), [skeletonGray], "one whose middle is on a corner is one pixel too, not a quarter of each of four")
        expectEqual(pixel(rep, at: CGPoint(x: 60, y: 30)), skeletonGray, "the small one fills its bounds' corner, as its outline wouldn't")
        expectEqual(pixel(rep, at: CGPoint(x: 62, y: 32)), skeletonGray)
        // At 2× a pixel is half a point, so the small one is 6 pixels across, past the few that make
        // a shape its bounds: its outline, as the rule counts the context's pixels, not points.
        let fine = renderBitmap(h.editor, size: size, scale: 2)
        expectEqual(pixel(fine, at: CGPoint(x: 61.5, y: 31.5), scale: 2), skeletonGray, "its middle")
        expect(pixel(fine, at: CGPoint(x: 60, y: 30), scale: 2) != skeletonGray, "its bounds' corner, left out at 2×")
    },
    test("the shape being edited draws in full under its editing view, the rest as skeletons; drawsSkeleton(of:) says which") {
        let log = SketchLog(), probe = SkeletonProbe()
        let h = try EditorHarness(plugins: [sketches(log, probe: probe)])
        let edited = h.add(Sketch(frame: CGRect(x: 0, y: 0, width: 100, height: 100)))
        let other = h.add(Sketch(frame: CGRect(x: 200, y: 0, width: 100, height: 100)))
        probe.shape = edited
        h.editor.camera = Camera(zoom: 0.3)
        expect(h.editor.beginEditing(edited))
        let size = CGSize(width: 100, height: 40)
        let rep = renderBitmap(h.editor, size: size)
        expectEqual(log.renders, [edited])
        expectEqual(log.skeletons, [other])
        expect(h.editor.drawsSkeletons)
        expect(!h.editor.drawsSkeleton(of: edited) && h.editor.drawsSkeleton(of: other))
        expectEqual(probe.told.map(\.all), [true])
        expectEqual(probe.told.map(\.shape), [false], "an overlay is told the shape being edited is drawn in full")
        expectEqual(pixel(rep, at: CGPoint(x: 15, y: 25)), [0, 0, 0, 255], "its render's black")
        h.editor.endEditing()
        log.clear()
        probe.told = []
        _ = renderBitmap(h.editor, size: size)
        expectEqual(log.skeletons, [edited, other])
        expectEqual(log.renders, [])
        expectEqual(probe.told.map(\.shape), [true])
    },
    test("a skeleton painted over the shape being edited, drawn in full, is over it where they overlap: the paint order holds") {
        let log = SketchLog()
        let h = try EditorHarness(plugins: [sketches(log)])
        let edited = h.add(Sketch(frame: CGRect(x: 0, y: 0, width: 200, height: 200)))       // (0, 0) to (60, 60) at 30%
        let above = h.add(Sketch(frame: CGRect(x: 100, y: -100, width: 200, height: 200)))   // (30, -30) to (90, 30): its lower half in view
        h.editor.camera = Camera(zoom: 0.3)
        expect(h.editor.beginEditing(edited))
        let rep = renderBitmap(h.editor, size: CGSize(width: 100, height: 70))
        expectEqual(log.renders, [edited])
        expectEqual(log.skeletons, [above])
        expectEqual(pixel(rep, at: CGPoint(x: 45, y: 15)), swatch(SketchDefinition.green), "the skeleton above, where they overlap")
        expectEqual(pixel(rep, at: CGPoint(x: 15, y: 45)), [0, 0, 0, 255], "the render below, where they don't")
        expectEqual(pixel(rep, at: CGPoint(x: 45, y: 45)), [0, 0, 0, 255])
    },
    test("skeletonZoom 0 draws every shape in full at every zoom; setting it redraws") {
        let log = SketchLog()
        let h = try EditorHarness(plugins: [sketches(log)])
        let id = h.add(Sketch(frame: CGRect(x: 0, y: 0, width: 100, height: 100)))
        let redraws = Redraws()
        h.editor.delegate = redraws
        h.editor.camera = Camera(zoom: Camera.zoomRange.lowerBound)
        redraws.count = 0
        h.editor.skeletonZoom = 0
        expectEqual(redraws.count, 1)
        h.editor.skeletonZoom = 0
        expectEqual(redraws.count, 1, "the same again changes nothing")
        expect(!h.editor.drawsSkeletons && !h.editor.drawsSkeleton(of: id))
        _ = renderBitmap(h.editor, size: CGSize(width: 40, height: 40))
        expectEqual(log.renders, [id])
        expectEqual(log.skeletons, [])
    },
    test("a skeleton drawn away from where it is (a shake) is drawn there") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        h.editor.camera = Camera(zoom: 0.3)
        let size = CGSize(width: 140, height: 90)
        let empty = renderBitmap(h.editor, size: size)
        let box = h.add(Box(CGRect(x: 100, y: 100, width: 200, height: 100)))   // (30, 30) to (90, 60) on screen
        h.editor.setDrawingOffset(CGPoint(x: 20, y: 0), for: box)
        let shaken = renderBitmap(h.editor, size: size)
        expectEqual(pixel(shaken, at: CGPoint(x: 40, y: 45)), pixel(empty, at: CGPoint(x: 40, y: 45)), "gone from where it is")
        expectEqual(pixel(shaken, at: CGPoint(x: 85, y: 45)), skeletonGray)
        expectEqual(pixel(shaken, at: CGPoint(x: 105, y: 45)), skeletonGray, "20 points on")
    },
    test("a board's owner drawn as the default skeleton asks for no preview of its board") {
        let log = PreviewLog()
        let owner = ShapeRecord(Showcase(frame: CGRect(x: 0, y: 0, width: 1000, height: 1000)))
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(owner)]),
                              children: [owner.id: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(Box(CGRect(x: 0, y: 0, width: 10, height: 10))))])])
        let registry = try Registry(plugins: [FixturesPlugin(), Contributor(id: "showcases") { $0.shape(ShowcaseDefinition(log: log)) }])
        let h = EditorHarness { CanvasEditor(registry: registry, file: file, scheduler: $0) }
        h.editor.camera = Camera(zoom: 0.3)                                      // 300 points on screen: room for a preview
        let size = CGSize(width: 320, height: 320)
        let rep = renderBitmap(h.editor, size: size)
        expectEqual(log.drawn, [], "its render isn't asked")
        expectEqual(pixel(rep, at: CGPoint(x: 150, y: 150)), skeletonGray)
        expect(!h.editor.boardPreviews.isPending, "nothing waits")
        expectEqual(h.scheduler.pendingCount, 0, "no frame asked for")
        h.editor.skeletonZoom = 0
        _ = renderBitmap(h.editor, size: size)
        expectEqual(log.drawn, [false], "drawn in full, it asks")
        expectEqual(h.editor.boardPreviews.waiting.map(\.board), [BoardID(owner: owner.id)])
    },
    test("outlines are stroked only for shapes near the view: one out of view is never asked for its outline, however it's outlined") {
        let log = SketchLog(), outlined = Outlined()
        let h = try EditorHarness(plugins: [sketches(log, outlined: outlined)])
        let near = h.add(Sketch(frame: CGRect(x: 20, y: 20, width: 40, height: 40)))
        let far = h.add(Sketch(frame: CGRect(x: 5000, y: 5000, width: 40, height: 40)))
        let size = CGSize(width: 160, height: 80)
        let plain = renderBitmap(h.editor, size: size)
        outlined.shapes = [near, far]
        log.clear()
        let both = renderBitmap(h.editor, size: size)
        expectEqual(log.indicators, [near])
        expect(pixel(both, at: CGPoint(x: 40, y: 20)) != pixel(plain, at: CGPoint(x: 40, y: 20)), "the one in view is outlined")
        outlined.shapes = []
        outlined.faint = [far]
        log.clear()
        _ = renderBitmap(h.editor, size: size)
        expectEqual(log.indicators, [], "faintly")
        outlined.faint = []
        h.editor.hintedShapeID = far
        log.clear()
        _ = renderBitmap(h.editor, size: size)
        expectEqual(log.indicators, [], "as the hint")
    },
    test("a shape and a plugin's rect across the view's edge, mostly out of view, are still outlined, in full and as skeletons") {
        let log = SketchLog(), outlined = Outlined()
        let h = try EditorHarness(plugins: [sketches(log, outlined: outlined)])
        let size = CGSize(width: 160, height: 80)
        // At 100% the shape runs from x = 150 to 450 and the rect from y = 70 to 370: a tenth of
        // each in view. At 30%, from 45 to 135, and from 21 to 111 (a third, and three fifths).
        let across = h.add(Sketch(frame: CGRect(x: 150, y: 10, width: 300, height: 40)))
        let rect = CGRect(x: 20, y: 70, width: 60, height: 300)
        for (zoom, left, top) in [(1, 150, 70), (0.3, 45, 21)] as [(CGFloat, CGFloat, CGFloat)] {
            h.editor.camera = Camera(zoom: zoom)
            outlined.shapes = []
            outlined.rects = []
            let plain = renderBitmap(h.editor, size: size)
            outlined.shapes = [across]
            outlined.rects = [rect]
            let rep = renderBitmap(h.editor, size: size)
            /// On the shape's left edge (the frame's, at 30%; the ellipse's end at 100%), and the
            /// rect's top edge.
            let onShape = CGPoint(x: left, y: (10 + 20) * zoom), onRect = CGPoint(x: 50 * zoom, y: top)
            expect(pixel(rep, at: onShape) != pixel(plain, at: onShape), "the shape across the right edge, at \(zoom)")
            expect(pixel(rep, at: onRect) != pixel(plain, at: onRect), "the rect across the bottom edge, at \(zoom)")
        }
    },
    test("a shape out of view but drawn into it (a shake) is drawn there, and outlined there") {
        let log = SketchLog(), outlined = Outlined()
        let h = try EditorHarness(plugins: [sketches(log, outlined: outlined)])
        let size = CGSize(width: 160, height: 80)
        let plain = renderBitmap(h.editor, size: size)
        let shaken = h.add(Sketch(frame: CGRect(x: 260, y: 20, width: 40, height: 40)))   // 100 points past the view's right edge
        h.editor.setDrawingOffset(CGPoint(x: -120, y: 0), for: shaken)                    // drawn from x = 140
        outlined.shapes = [shaken]
        let rep = renderBitmap(h.editor, size: size)
        expectEqual(log.renders, [shaken])
        expectEqual(log.indicators, [shaken])
        expectEqual(pixel(rep, at: CGPoint(x: 150, y: 40)), [0, 0, 0, 255], "its render")
        expect(pixel(rep, at: CGPoint(x: 139, y: 40)) != pixel(plain, at: CGPoint(x: 139, y: 40)), "its outline")
    },
    test("drawn as skeletons, a shape's outline is its geometry's, not its indicatorPath; the shape being edited keeps its own") {
        let log = SketchLog(), outlined = Outlined()
        let h = try EditorHarness(plugins: [sketches(log, outlined: outlined)])
        let id = h.add(Sketch(frame: CGRect(x: 100, y: 100, width: 200, height: 200)))   // (30, 30) to (90, 90) at 30%
        h.editor.camera = Camera(zoom: 0.3)
        let size = CGSize(width: 120, height: 120)
        /// Beside the left edge, where the frame's outline is and the ellipse's isn't.
        let edge = CGPoint(x: 29, y: 40)
        let plain = renderBitmap(h.editor, size: size)
        outlined.shapes = [id]
        log.clear()
        let skeleton = renderBitmap(h.editor, size: size)
        expectEqual(log.indicators, [], "never asked")
        expect(pixel(skeleton, at: edge) != pixel(plain, at: edge), "the frame is outlined")
        h.editor.skeletonZoom = 0
        outlined.shapes = []
        let plainFull = renderBitmap(h.editor, size: size)
        outlined.shapes = [id]
        log.clear()
        let full = renderBitmap(h.editor, size: size)
        expectEqual(log.indicators, [id])
        expectEqual(pixel(full, at: edge), pixel(plainFull, at: edge), "in full, the ellipse is outlined")
        h.editor.skeletonZoom = 0.35
        expect(h.editor.beginEditing(id))
        log.clear()
        _ = renderBitmap(h.editor, size: size)
        expectEqual(log.indicators, [id], "the shape being edited, drawn in full, keeps its own")
    },
    test("drawn as skeletons, a rect's outline is a ring, as its stroke would paint: hollow, and where two cross, drawn") {
        let outlined = Outlined()
        let h = try EditorHarness(plugins: [FixturesPlugin(), outlines(outlined)])
        let a = h.add(Box(CGRect(x: 0, y: 200, width: 100, height: 100)))      // (0, 60) to (30, 90) at 30%
        let c = h.add(Box(CGRect(x: 50, y: 150, width: 100, height: 100)))     // (15, 45) to (45, 75): its left edge crosses a's top
        h.editor.camera = Camera(zoom: 0.3)
        // At 2×, so the line's 1.5 points cover whole pixels: 59.25 to 60.75 on a's top edge.
        let size = CGSize(width: 60, height: 100)
        let plain = renderBitmap(h.editor, size: size, scale: 2)
        outlined.shapes = [a, c]
        let rep = renderBitmap(h.editor, size: size, scale: 2)
        let edge = pixel(rep, at: CGPoint(x: 5, y: 60), scale: 2), crossing = pixel(rep, at: CGPoint(x: 15, y: 60), scale: 2)
        expect(edge != pixel(plain, at: CGPoint(x: 5, y: 60), scale: 2), "a's top edge")
        expectEqual(crossing, edge, "where a's top edge and c's left edge cross, as on either")
        expectEqual(pixel(rep, at: CGPoint(x: 5, y: 80), scale: 2), pixel(plain, at: CGPoint(x: 5, y: 80), scale: 2), "inside a, nothing")
        expectEqual(pixel(rep, at: CGPoint(x: 25, y: 70), scale: 2), pixel(plain, at: CGPoint(x: 25, y: 70), scale: 2), "inside both")
    },
    test("drawn as skeletons, a translucent ring and a stroke that meet are no darker there than either") {
        let outlined = Outlined()
        let h = try EditorHarness(plugins: [FixturesPlugin(), LinksPlugin(), outlines(outlined)])
        let a = h.add(Box(CGRect(x: 0, y: 200, width: 100, height: 100)))      // (0, 60) to (30, 90) at 30%
        let b = h.add(Box(CGRect(x: 500, y: 200, width: 100, height: 100)))
        let link = h.add(Link(from: a, to: b))                                  // from (15, 75) on
        h.editor.camera = Camera(zoom: 0.3)
        outlined.faint = [a, link]
        // The faint line is 2.5 points: a's right edge's ring runs from 28.75 to 31.25, the link's
        // stroke from 73.75 to 76.25, whole pixels at 2×.
        let size = CGSize(width: 60, height: 100)
        let rep = renderBitmap(h.editor, size: size, scale: 2)
        let ring = pixel(rep, at: CGPoint(x: 29.5, y: 65), scale: 2), both = pixel(rep, at: CGPoint(x: 29.5, y: 74.5), scale: 2)
        expectEqual(both, ring)
        outlined.faint = [a]
        expectEqual(pixel(renderBitmap(h.editor, size: size, scale: 2), at: CGPoint(x: 29.5, y: 65), scale: 2), ring, "as the ring alone")
    },
    test("drawn as a skeleton, a kind with its own skeleton outline is outlined that way; in full, and editing, by its indicatorPath") {
        let log = SketchLog(), outlined = Outlined()
        log.outlinesSkeleton = true
        let h = try EditorHarness(plugins: [sketches(log, outlined: outlined)])
        let id = h.add(Sketch(frame: CGRect(x: 100, y: 100, width: 200, height: 200)))   // (30, 30) to (90, 90) at 30%
        h.editor.camera = Camera(zoom: 0.3)
        let size = CGSize(width: 120, height: 120)
        /// Beside the frame's left edge, and on the middle half's (x = 45, y from 45 to 75).
        let frameEdge = CGPoint(x: 29, y: 40), ownEdge = CGPoint(x: 45, y: 60)
        let plain = renderBitmap(h.editor, size: size)
        outlined.shapes = [id]
        log.clear()
        let skeleton = renderBitmap(h.editor, size: size)
        expectEqual(log.skeletonIndicators, [id])
        expectEqual(log.indicators, [], "its indicatorPath isn't asked")
        expect(pixel(skeleton, at: ownEdge) != pixel(plain, at: ownEdge), "its own outline")
        expectEqual(pixel(skeleton, at: frameEdge), pixel(plain, at: frameEdge), "not its geometry's")
        h.editor.camera = Camera(zoom: 0.35)
        log.clear()
        _ = renderBitmap(h.editor, size: size)
        expectEqual(log.skeletonIndicators, [], "in full")
        expectEqual(log.indicators, [id])
        h.editor.camera = Camera(zoom: 0.3)
        expect(h.editor.beginEditing(id))
        log.clear()
        _ = renderBitmap(h.editor, size: size)
        expectEqual(log.skeletonIndicators, [], "being edited")
        expectEqual(log.indicators, [id])
    },
    test("services hear the canvas start or stop drawing skeletons: once each way across skeletonZoom, and never within a level or for editing") {
        let heard = LevelLog()
        let log = SketchLog()
        let h = try EditorHarness(plugins: [sketches(log), levelListener(heard)])
        let id = h.add(Sketch(frame: CGRect(x: 0, y: 0, width: 100, height: 100)))
        for zoom in [0.5, 0.36, 0.35, 0.349, 0.2, 0.1, 0.3, 0.34, 0.35, 1, 4, 0.6] as [CGFloat] { h.editor.camera = Camera(zoom: zoom) }
        expectEqual(heard.events, ["skeletons", "in full"], "across 35% on the way out, and on the way back")
        heard.events = []
        h.editor.camera = Camera(zoom: 0.3)
        expect(h.editor.beginEditing(id))
        h.editor.endEditing()
        h.editor.camera = Camera(origin: CGPoint(x: 50, y: 50), zoom: 0.3)
        expectEqual(heard.events, ["skeletons"], "editing and panning tell nothing")
        // The host's skeletonZoom, moved past the zoom (30%) and within a level.
        heard.events = []
        h.editor.skeletonZoom = 0.25
        h.editor.skeletonZoom = 0.2
        h.editor.skeletonZoom = 0
        h.editor.skeletonZoom = 0.5
        h.editor.skeletonZoom = 0.4
        h.editor.skeletonZoom = 0.4
        expectEqual(heard.events, ["in full", "skeletons"])
    },
    test("a board shown with its camera at the other level tells services once they've heard the switch") {
        let heard = LevelLog()
        let pocket = ShapeRecord(Pocket(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(pocket)]),
                              children: [pocket.id: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(Box(CGRect(x: 0, y: 0, width: 10, height: 10))))])])
        let h = try EditorHarness(plugins: [FixturesPlugin(), PocketsPlugin(), levelListener(heard)], file: file)
        h.editor.camera = Camera(zoom: 0.2)
        heard.events = []
        expect(h.enter(pocket.id))                                               // a first visit, with no view: Camera(), at 100%
        expectEqual(h.editor.camera.zoom, 1)
        expectEqual(heard.events, ["board", "in full"])
        heard.events = []
        h.editor.showBoard(.root)                                                // where it was left, at 20%
        expectEqual(heard.events, ["board", "skeletons"])
        heard.events = []
        h.editor.camera = Camera(zoom: 0.25)
        h.enter(pocket.id)
        h.editor.camera = Camera(zoom: 0.3)
        h.editor.showBoard(.root)
        expectEqual(heard.events, ["board", "in full", "skeletons", "board"], "not for a board shown at the level left")
    },
])

/// What a service heard, in order: each switch of board, and each change of level, as the level
/// it changed to.
@MainActor final class LevelLog {
    var events: [String] = []
}

final class LevelListener {
    let log: LevelLog
    init(log: LevelLog) { self.log = log }
}

extension LevelListener: EditorService {
    func drawsSkeletonsDidChange(in editor: CanvasEditor) {
        log.events.append(editor.drawsSkeletons ? "skeletons" : "in full")
    }

    func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        log.events.append("board")
    }
}

/// Outlines what `outlined` says, with no shapes of its own.
@MainActor private func outlines(_ outlined: Outlined) -> Contributor {
    Contributor(id: "outlines") { $0.outlines { _ in Outlines(shapes: outlined.shapes, rects: outlined.rects, faintShapes: outlined.faint) } }
}

@MainActor private func levelListener(_ log: LevelLog) -> Contributor {
    Contributor(id: "levels") { r in r.service { _ in LevelListener(log: log) } }
}

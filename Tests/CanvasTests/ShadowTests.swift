import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Geometry
import TestKit

@MainActor let shadowTests = Suite("Shadows", [
    test("a shape holding everything in view draws no shadow, and the frame is the same as with it, byte for byte, at 1× and 2×") {
        for scale in [1, 2] as [CGFloat] {
            let drawn = try drawnAt800(Slab(frame: slab), on: CGPoint(x: 50, y: 50), scale: scale)
            expectEqual(drawn.skipped, 1, "at \(scale)×")
            expect(sameBytes(drawn.frame, drawn.control), "at \(scale)×, the frame is the one with the shadow")
            expectEqual(pixel(drawn.frame, at: CGPoint(x: 50, y: 50), scale: scale), [230, 128, 51, 255], "at \(scale)×")
        }
    },
    test("a shadow that could show in view is drawn: an edge on the view's edge, an edge in view, a translucent fill, a shape whose bounds hold the view but whose notch is in it, and a shape shaken onto the view's middle") {
        for scale in [1, 2] as [CGFloat] {
            // The view's left edge on the slab's: its antialiasing could show what's under it.
            let onEdge = try drawnAt800(Slab(frame: slab), on: CGPoint(x: 6.25, y: 50), scale: scale)
            expectEqual(onEdge.skipped, 0, "the slab's edge on the view's, at \(scale)×")
            expect(sameBytes(onEdge.frame, onEdge.control), "the slab's edge on the view's, at \(scale)×")
            // Its left edge down the middle of the view: the shadow a point out from it.
            let edge = try drawnAt800(Slab(frame: slab), on: CGPoint(x: 0, y: 50), scale: scale)
            expectEqual(edge.skipped, 0, "the slab's edge in view, at \(scale)×")
            expect(sameBytes(edge.frame, edge.control), "the slab's edge in view, at \(scale)×")
            expect(edge.shadowed(at: CGPoint(x: 49, y: 50)), "the shadow beside the edge, at \(scale)×")
            // Half opaque: the shadow shows through it.
            let translucent = try drawnAt800(Slab(frame: slab, opacity: 0.5), on: CGPoint(x: 50, y: 50), scale: scale)
            expectEqual(translucent.skipped, 0, "a translucent slab, at \(scale)×")
            expect(sameBytes(translucent.frame, translucent.control), "a translucent slab, at \(scale)×")
            // An L whose bounds hold the view, its inner corner in the middle: the notch is in view.
            let notched = try drawnAt800(Slab(frame: slab, notched: true), on: CGPoint(x: 50, y: 50), scale: scale)
            expectEqual(notched.skipped, 0, "an L's notch in view, at \(scale)×")
            expect(sameBytes(notched.frame, notched.control), "an L's notch in view, at \(scale)×")
            expect(notched.shadowed(at: CGPoint(x: 60, y: 40)), "the shadow in the notch by its corner, at \(scale)×")
            // Shaken 400 points right (50 world units), so its left edge is drawn down the view's middle.
            let shaken = try drawnAt800(Slab(frame: slab), on: CGPoint(x: 50, y: 50), scale: scale, offset: CGPoint(x: 400, y: 0))
            expectEqual(shaken.skipped, 0, "a slab shaken onto the view, at \(scale)×")
            expect(sameBytes(shaken.frame, shaken.control), "a slab shaken onto the view, at \(scale)×")
            expect(shaken.shadowed(at: CGPoint(x: 49, y: 50)), "the shadow beside the shaken slab's edge, at \(scale)×")
        }
    },
    test("what's drawn into decides, not the view: a frame clipped to a rect inside the shape leaves its shadow out, though its edge is in view") {
        let h = try EditorHarness(plugins: [SlabPlugin()])
        h.add(Slab(frame: slab))
        h.editor.camera = camera800(on: CGPoint(x: 0, y: 50))
        // The view's right half is inside the slab (world 0...6.25 across), its left half outside.
        let clip = CGRect(x: 60, y: 0, width: 40, height: 100)
        let before = h.editor.shadowsSkipped
        let frame = renderBitmap(h.editor, size: viewSize, scale: 2, clip: clip)
        expectEqual(h.editor.shadowsSkipped - before, 1)
        h.editor.shadowsAlwaysDrawn = true
        expect(sameBytes(frame, renderBitmap(h.editor, size: viewSize, scale: 2, clip: clip)), "the clipped frame is the one with the shadow")
    },
])

/// The slab's frame: 100 world units square at the origin, 800 view points at 800%.
private let slab = CGRect(x: 0, y: 0, width: 100, height: 100)
/// The views' size, in view points: 12.5 world units across at 800%.
private let viewSize = CGSize(width: 100, height: 100)

/// The camera at 800% with `point` (world units) at the middle of the view.
private func camera800(on point: CGPoint) -> Camera {
    Camera(origin: CGPoint(x: point.x - viewSize.width / 16, y: point.y - viewSize.height / 16), zoom: 8)
}

/// A slab drawn at 800% with `point` at the middle of the view, `offset` view points from where it is.
@MainActor
private func drawnAt800(_ props: Slab, on point: CGPoint, scale: CGFloat, offset: CGPoint = .zero) throws -> Drawn {
    let h = try EditorHarness(plugins: [SlabPlugin()])
    let id = h.add(props)
    h.editor.setDrawingOffset(offset, for: id)
    h.editor.camera = camera800(on: point)
    let before = h.editor.shadowsSkipped
    let frame = renderBitmap(h.editor, size: viewSize, scale: scale)
    let skipped = h.editor.shadowsSkipped - before
    h.editor.shadowsAlwaysDrawn = true
    let control = renderBitmap(h.editor, size: viewSize, scale: scale)
    let empty = try EditorHarness(plugins: [SlabPlugin()])
    empty.editor.camera = h.editor.camera
    return Drawn(frame: frame, control: control, empty: renderBitmap(empty.editor, size: viewSize, scale: scale), skipped: skipped, scale: scale)
}

/// A frame as the canvas draws it, the control with every shadow drawn, the empty board's frame,
/// and how many shadows the frame left out.
@MainActor
private struct Drawn {
    let frame: NSBitmapImageRep, control: NSBitmapImageRep, empty: NSBitmapImageRep
    let skipped: Int
    /// Pixels a view point.
    let scale: CGFloat

    /// The frame is darker than the empty board's at a view point: a shadow is there.
    func shadowed(at point: CGPoint) -> Bool {
        let shown = pixel(frame, at: point, scale: scale), bare = pixel(empty, at: point, scale: scale)
        return shown[0..<3].reduce(0, +) < bare[0..<3].reduce(0, +)
    }
}

/// Two bitmaps of one layout are the same, byte for byte.
@MainActor
private func sameBytes(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Bool {
    guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh, a.bytesPerRow == b.bytesPerRow,
          let p = a.bitmapData, let q = b.bitmapData else { return false }
    return memcmp(p, q, a.bytesPerRow * a.pixelsHigh) == 0
}

/// Its frame's rounded rect, or that less its top-right quarter (an L), in an orange at `opacity`
/// over the canvas's shadow.
struct Slab: BoxShapeProps {
    static let kind: ShapeKind = "slab"
    static let properties = Properties<Slab> {
        Property("frame", \.frame).required()
        Property("opacity", \.opacity)
        Property("notched", \.notched)
    }
    var frame: CGRect
    var opacity: Double = 1
    var notched = false
}

extension Slab {
    init() { self.init(frame: .zero) }
}

struct SlabDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Slab>, in context: RenderContext) {
        let f = shape.frame
        let path = shape.props.notched
            ? { let p = CGMutablePath(); p.addLines(between: [CGPoint(x: f.minX, y: f.minY), CGPoint(x: f.midX, y: f.minY), CGPoint(x: f.midX, y: f.midY),
                                                              CGPoint(x: f.maxX, y: f.midY), CGPoint(x: f.maxX, y: f.maxY), CGPoint(x: f.minX, y: f.maxY)]); p.closeSubpath(); return p }()
            : CGPath(roundedRect: f, cornerWidth: 8, cornerHeight: 8, transform: nil)
        context.fillWithShadow(path, NSColor(deviceRed: 0.9, green: 0.5, blue: 0.2, alpha: shape.props.opacity))
    }
}

struct SlabPlugin: CanvasPlugin {
    let id: PluginID = "slabs"
    func register(into registrar: inout PluginRegistrar) { registrar.shape(SlabDefinition()) }
}

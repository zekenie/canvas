import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import TestKit

@MainActor let drawingTests = Suite("Drawing", [
    test("a box kind that overrides only its geometry is hit and outlined by that geometry, not its frame") {
        let h = try EditorHarness(plugins: [Contributor(id: "diamonds") { $0.shape(DiamondDefinition()) }])
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let diamond = h.add(Diamond(frame))
        let corner = CGPoint(x: 5, y: 5)                           // inside the frame, outside the diamond
        expectEqual(h.editor.shape(at: CGPoint(x: 50, y: 50)), diamond)
        expectEqual(h.editor.shape(at: corner), nil)
        let outline = DiamondDefinition().indicatorPath(of: ShapeRecord(Diamond(frame)), in: h.editor.shapeContext)
        expect(outline.contains(CGPoint(x: 50, y: 50)) && !outline.contains(corner), "the outline is the diamond's")
    },
    test("overlays draw in plugin order, world ones with the camera applied and view ones after, without it") {
        let log = OverlayLog()
        let h = try EditorHarness(plugins: [
            Contributor(id: "first") { $0.overlay(LogOverlay(name: "view 1", space: .view, log: log)); $0.overlay(LogOverlay(name: "world 1", space: .world, log: log)) },
            Contributor(id: "second") { $0.overlay(LogOverlay(name: "world 2", space: .world, log: log)); $0.overlay(LogOverlay(name: "view 2", space: .view, log: log)) },
        ])
        h.editor.camera = Camera(origin: CGPoint(x: 10, y: 20), zoom: 2)
        _ = renderBitmap(h.editor, size: CGSize(width: 100, height: 100))
        expectEqual(log.drawn.map(\.name), ["world 1", "world 2", "view 1", "view 2"])
        let view = try require(log.drawn.last?.ctm), world = try require(log.drawn.first?.ctm)
        expectEqual(world, CGAffineTransform(translationX: -10, y: -20).concatenating(CGAffineTransform(scaleX: 2, y: 2)).concatenating(view))
    },
    test("state a shape's render leaves behind doesn't leak into the shapes drawn after it") {
        @MainActor func rendered(_ shapes: [any ShapeProps]) throws -> [Int] {
            let h = try EditorHarness(plugins: [FixturesPlugin(), Contributor(id: "leaks") { $0.shape(LeakDefinition()) }])
            for shape in shapes { h.editor.transact { $0.insert(AnyShapeRecord.make(shape)) } }
            return pixel(renderBitmap(h.editor, size: CGSize(width: 100, height: 100)), at: CGPoint(x: 50, y: 50))
        }
        let box = Box(CGRect(x: 20, y: 20, width: 60, height: 60))
        expectEqual(try rendered([Leak(frame: CGRect(x: 0, y: 0, width: 10, height: 10)), box]), try rendered([box]))
    },
    test("a path a render adds but never paints isn't painted by the shape drawn after it") {
        @MainActor func rendered(_ shapes: [any ShapeProps]) throws -> [Int] {
            let h = try EditorHarness(plugins: [FixturesPlugin(), Contributor(id: "leaks") { $0.shape(LeakDefinition()) }])
            for shape in shapes { h.editor.transact { $0.insert(AnyShapeRecord.make(shape)) } }
            return pixel(renderBitmap(h.editor, size: CGSize(width: 100, height: 100)), at: CGPoint(x: 15, y: 15))
        }
        let box = Box(CGRect(x: 50, y: 50, width: 40, height: 40))
        expectEqual(try rendered([Leak(frame: CGRect(x: 0, y: 0, width: 30, height: 30), leavesPath: true), box]), try rendered([box]))
    },
    test("state an overlay leaves behind doesn't leak into the overlays drawn after it") {
        let h = try EditorHarness(plugins: [Contributor(id: "overlays") {
            $0.overlay(LeakyOverlay())
            $0.overlay(PaintOverlay(rect: CGRect(x: 20, y: 20, width: 60, height: 60)))
        }])
        expectEqual(pixel(renderBitmap(h.editor, size: CGSize(width: 100, height: 100)), at: CGPoint(x: 50, y: 50)), [0, 0, 0, 255])
    },
    test("draw(in:) into a bare CGContext, with no NSGraphicsContext current, draws AppKit fills there") {
        let h = try EditorHarness(plugins: [Contributor(id: "leaks") { $0.shape(LeakDefinition()) }])
        h.add(Leak(frame: CGRect(x: 0, y: 0, width: 40, height: 40), fillsWithAppKit: true))
        let cg = try require(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        expect(NSGraphicsContext.current == nil)
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        h.editor.draw(in: cg, bounds: bounds, dirtyRect: bounds)
        expect(NSGraphicsContext.current == nil, "the context it installed is taken down again")
        let rep = NSBitmapImageRep(cgImage: try require(cg.makeImage()))
        var opaque = 0, black = 0
        for y in 0..<100 {
            for x in 0..<100 {
                let p = pixel(rep, at: CGPoint(x: x, y: y))
                if p[3] == 255 { opaque += 1 }
                if p == [0, 0, 0, 255] { black += 1 }
            }
        }
        expectEqual(opaque, 100 * 100, "the background (an AppKit fill) covers the context")
        expectEqual(black, 40 * 40, "the shape's AppKit fill lands in the context")
    },
    test("plugins' outlines and the hint are stroked in one pass: a shape outlined twice looks outlined once; a session can hide the plugins'") {
        @MainActor func render(outlining shapes: @escaping @MainActor ([ShapeID]) -> Outlines, hint: Bool, hidingOutlines: Bool = false) throws -> NSBitmapImageRep {
            let ids = IDBox()
            let h = try EditorHarness(plugins: [FixturesPlugin(), Contributor(id: "outliner") { r in r.outlines { _ in shapes(ids.ids) } }])
            ids.ids = [h.add(Box(CGRect(x: 20, y: 20, width: 40, height: 40))), h.add(Box(CGRect(x: 100, y: 20, width: 40, height: 40)))]
            if hint { h.editor.hintedShapeID = ids.ids[0] }
            if hidingOutlines { h.editor.session = OutlineHidingSession() }
            return renderBitmap(h.editor, size: CGSize(width: 160, height: 80))
        }
        let everywhere = CGRect(x: 0, y: 0, width: 160, height: 80)
        let plain = try render(outlining: { _ in Outlines() }, hint: false)
        let first = try render(outlining: { Outlines(shapes: [$0[0]]) }, hint: false)
        expect(pixel(first, at: CGPoint(x: 20, y: 40)) != pixel(plain, at: CGPoint(x: 20, y: 40)), "the first box is outlined")
        expectEqual(changedPixels(plain, first, in: CGRect(x: 90, y: 0, width: 70, height: 80)), 0, "the second isn't")
        expectEqual(changedPixels(first, try render(outlining: { _ in Outlines() }, hint: true), in: everywhere), 0, "the hint alone looks the same")
        expectEqual(changedPixels(first, try render(outlining: { Outlines(shapes: [$0[0], $0[0]]) }, hint: true), in: everywhere), 0,
                    "outlined twice by the plugin and once as the hint: still one stroke")
        let hidden = try render(outlining: { Outlines(shapes: [$0[1]]) }, hint: true, hidingOutlines: true)
        expectEqual(changedPixels(first, hidden, in: everywhere), 0, "a session that hides outlines leaves only the hint")
        let rect = try render(outlining: { _ in Outlines(rects: [CGRect(x: 10, y: 10, width: 140, height: 60)]) }, hint: false)
        expect(pixel(rect, at: CGPoint(x: 80, y: 10)) != pixel(plain, at: CGPoint(x: 80, y: 10)), "rects are stroked")
        expectEqual(pixel(rect, at: CGPoint(x: 80, y: 40)), pixel(plain, at: CGPoint(x: 80, y: 40)), "not filled")
    },
    test("a running session draws above the world overlays, with the camera applied, and below the view overlays") {
        let log = OverlayLog()
        let h = try EditorHarness(plugins: [Contributor(id: "overlays") {
            $0.overlay(PaintOverlay(rect: CGRect(x: 10, y: 10, width: 20, height: 20)))
            $0.overlay(LogOverlay(name: "view", space: .view, log: log))
        }])
        h.editor.camera = Camera(origin: .zero, zoom: 2)
        let session = PaintingSession(log: log)
        h.editor.session = session
        let bitmap = renderBitmap(h.editor, size: CGSize(width: 100, height: 100))
        expectEqual(pixel(bitmap, at: CGPoint(x: 40, y: 40)), [255, 255, 255, 255], "the session's white over the overlay's black")
        expectEqual(pixel(bitmap, at: CGPoint(x: 22, y: 22)), [0, 0, 0, 255], "the overlay where the session doesn't draw")
        expectEqual(log.drawn.map(\.name), ["session", "view"])
    },
])

/// Draws nothing of its own, but leaves the context 90% transparent; or fills its frame black
/// the AppKit way (`NSColor.set`, `NSRect.fill`), through the current NSGraphicsContext.
struct Leak: BoxShapeProps {
    static let kind: ShapeKind = "leak"
    var frame: CGRect
    var fillsWithAppKit = false
    /// Adds its frame to the current path, and paints nothing.
    var leavesPath = false
}

struct LeakDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Leak>, in context: RenderContext) {
        if shape.props.fillsWithAppKit {
            NSColor.black.setFill()
            shape.frame.fill()
        } else if shape.props.leavesPath {
            context.cg.addRect(shape.frame)
        } else {
            context.cg.setAlpha(0.1)
        }
    }
}

struct LeakyOverlay: CanvasOverlay {
    var space: OverlaySpace { .world }
    func draw(in context: OverlayContext) { context.cg.setAlpha(0.1) }
}

struct PaintOverlay: CanvasOverlay {
    let rect: CGRect
    var space: OverlaySpace { .world }
    func draw(in context: OverlayContext) {
        context.cg.setFillColor(CGColor(gray: 0, alpha: 1))
        context.cg.fill(rect)
    }
}

final class OverlayLog {
    var drawn: [(name: String, ctm: CGAffineTransform)] = []
}

struct LogOverlay: CanvasOverlay {
    let name: String
    let space: OverlaySpace
    let log: OverlayLog
    func draw(in context: OverlayContext) { log.drawn.append((name, context.cg.ctm)) }
}

extension AnyShapeRecord {
    static func make(_ props: any ShapeProps) -> AnyShapeRecord {
        func open<P: ShapeProps>(_ props: P) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(props)) }
        return open(props)
    }
}

@MainActor final class IDBox {
    var ids: [ShapeID] = []
}

/// Fills (15, 15, 15, 15) white, in world units.
final class PaintingSession {
    let log: OverlayLog
    init(log: OverlayLog) { self.log = log }
}

extension PaintingSession: Session {
    func drag(_ pointer: Pointer, in editor: CanvasEditor) {}
    func draw(in context: OverlayContext) {
        log.drawn.append(("session", context.cg.ctm))
        context.cg.setFillColor(CGColor(gray: 1, alpha: 1))
        context.cg.fill(CGRect(x: 15, y: 15, width: 15, height: 15))
    }
}

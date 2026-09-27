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
    test("two selected shapes are both outlined, with the selection box around them") {
        let (h, disc, box, _) = try selectables()
        let unselected = renderBitmap(h.editor, size: selectablesCanvas)
        h.editor.selectedShapeIDs = [disc, box]
        let selected = renderBitmap(h.editor, size: selectablesCanvas)
        for edge in [CGPoint(x: 60, y: 40), CGPoint(x: 100, y: 80)] {          // the disc's right, the box's left
            expect(pixel(selected, at: edge) != pixel(unselected, at: edge), "outlined at \(edge)")
        }
        // The union of their bounds, (20, 20)–(140, 100), where neither shape is.
        for edge in [CGPoint(x: 80, y: 20), CGPoint(x: 80, y: 100), CGPoint(x: 20, y: 80)] {
            expect(pixel(selected, at: edge) != pixel(unselected, at: edge), "the box at \(edge)")
        }
        expectEqual(pixel(selected, at: CGPoint(x: 80, y: 60)), pixel(unselected, at: CGPoint(x: 80, y: 60)), "it's a box, not a fill")
    },
    test("one selected shape is outlined, with no box") {
        let (h, disc, _, _) = try selectables()
        let unselected = renderBitmap(h.editor, size: selectablesCanvas)
        h.editor.selection = disc
        let selected = renderBitmap(h.editor, size: selectablesCanvas)
        expect(pixel(selected, at: CGPoint(x: 60, y: 40)) != pixel(unselected, at: CGPoint(x: 60, y: 40)))
        let frameCorner = CGRect(x: 18, y: 18, width: 5, height: 5)             // clear of the disc's outline
        expectEqual(changedPixels(unselected, selected, in: frameCorner), 0)
        expectEqual(changedPixels(unselected, selected, in: CGRect(x: 64, y: 0, width: 136, height: 120)), 0)
        expectEqual(changedPixels(unselected, selected, in: CGRect(x: 0, y: 64, width: 200, height: 56)), 0)
    },
    test("a session that hides the selection indicator hides every outline and the box, not the hint") {
        let (h, disc, box, hinted) = try selectables()
        h.editor.hintedShapeID = hinted
        let unselected = renderBitmap(h.editor, size: selectablesCanvas)
        h.editor.selectedShapeIDs = [disc, box]
        h.editor.session = HidingSession()
        expectEqual(changedPixels(unselected, renderBitmap(h.editor, size: selectablesCanvas), in: CGRect(origin: .zero, size: selectablesCanvas)), 0)
    },
    test("translating hides every outline and the box; brushing keeps them") {
        let (h, disc, box, _) = try selectables()
        let everywhere = CGRect(origin: .zero, size: selectablesCanvas)
        let unselected = renderBitmap(h.editor, size: selectablesCanvas)
        h.editor.selectedShapeIDs = [disc, box]
        let selected = renderBitmap(h.editor, size: selectablesCanvas)
        // Empty space in the selection box: past the threshold and back, so nothing has moved.
        h.press(at: CGPoint(x: 80, y: 60)); h.drag(to: CGPoint(x: 90, y: 60)); h.drag(to: CGPoint(x: 80, y: 60))
        expectEqual(changedPixels(unselected, renderBitmap(h.editor, size: selectablesCanvas), in: everywhere), 0)
        h.release()
        h.hold(.shift)
        h.press(at: CGPoint(x: 195, y: 115)); h.drag(to: CGPoint(x: 190, y: 110))
        expect(h.editor.brush != nil)
        expectEqual(changedPixels(selected, renderBitmap(h.editor, size: selectablesCanvas), in: CGRect(x: 0, y: 0, width: 185, height: 105)), 0)
        h.release()
    },
    test("the brush fills tldraw's gray at 0.102 and strokes it at 0.251, 1 view point wide at zoom 1 and 2") {
        for zoom: CGFloat in [1, 2] {
            let h = try EditorHarness(plugins: [])
            h.editor.camera = Camera(origin: .zero, zoom: zoom)
            let size = CGSize(width: 100, height: 100)
            let background = renderBitmap(h.editor, size: size, scale: 2)
            h.press(at: CGPoint(x: 20, y: 20)); h.drag(to: CGPoint(x: 80, y: 70))
            let brushed = renderBitmap(h.editor, size: size, scale: 2)
            h.release()
            // Device pixels at 2×: the left edge's 1 pt stroke covers x 19.5–20.5, the fill x ≥ 20.
            func blend(_ under: [Int], _ alpha: CGFloat) -> [Int] {
                under.prefix(3).map { Int((CGFloat($0) + (0.56 * 255 - CGFloat($0)) * alpha).rounded()) } + [255]
            }
            @MainActor func expectNear(_ point: CGPoint, _ expected: [Int], _ what: String) {
                let actual = pixel(brushed, at: point, scale: 2)
                expect(zip(actual, expected).allSatisfy { abs($0 - $1) <= 1 }, "\(what) at zoom \(zoom): \(actual), not \(expected)")
            }
            let bg = pixel(background, at: CGPoint(x: 21, y: 45), scale: 2)
            expectEqual(pixel(brushed, at: CGPoint(x: 19.25, y: 45), scale: 2), pixel(background, at: CGPoint(x: 19.25, y: 45), scale: 2), "outside at zoom \(zoom)")
            expectNear(CGPoint(x: 19.75, y: 45), blend(bg, 0.251), "stroke")
            expectNear(CGPoint(x: 20.25, y: 45), blend(blend(bg, 0.102), 0.251), "fill and stroke")
            expectNear(CGPoint(x: 21, y: 45), blend(bg, 0.102), "fill")
        }
    },
])

let selectablesCanvas = CGSize(width: 200, height: 120)

/// A disc in (20, 20, 40, 40), a box at (100, 60, 40, 40), and a small box at (160, 10, 20, 20).
@MainActor func selectables() throws -> (EditorHarness, ShapeID, ShapeID, ShapeID) {
    let h = try EditorHarness(plugins: [FixturesPlugin()])
    let disc = h.add(Disc(CGRect(x: 20, y: 20, width: 40, height: 40)))
    let box = h.add(Box(CGRect(x: 100, y: 60, width: 40, height: 40)))
    let small = h.add(Box(CGRect(x: 160, y: 10, width: 20, height: 20)))
    return (h, disc, box, small)
}

/// Stands in for a drag of the selection.
final class HidingSession {}

extension HidingSession: Session {
    var hidesSelectionIndicator: Bool { true }
    func drag(_ pointer: Pointer, in editor: CanvasEditor) {}
}

/// A box kind whose definition states only `render` and `geometry`: a diamond inside its frame.
struct Diamond: BoxShapeProps {
    static let kind: ShapeKind = "diamond"
    var frame: CGRect
    init(_ frame: CGRect) { self.frame = frame }
}

struct DiamondDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Diamond>, in context: RenderContext) {}
    func geometry(of shape: ShapeRecord<Diamond>, in context: ShapeContext) -> ShapeGeometry {
        let f = shape.frame
        return ShapeGeometry(outline: [CGPoint(x: f.midX, y: f.minY), CGPoint(x: f.maxX, y: f.midY),
                                       CGPoint(x: f.midX, y: f.maxY), CGPoint(x: f.minX, y: f.midY)], bounds: f)
    }
}

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

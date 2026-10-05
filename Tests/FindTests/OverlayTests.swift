import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Find
import Geometry
import Keyboard
import Selection
import TestKit
import Topology

/// A memo-like kind whose rects take a millisecond each to lay out: what the overlay's budget holds
/// a frame to.
@MainActor final class SlowPlugin: CanvasPlugin {
    nonisolated var id: PluginID { "slow" }
    var layouts = 0

    func register(into registrar: inout PluginRegistrar) {
        registrar.findableTexts("slow", where: { $0.kind == Disc.kind }, texts: { _, _ in [FindableText(field: "slow", text: "slow disc")] },
                                rects: { [self] _, _, ranges, _ in
                                    layouts += 1
                                    let clock = ContinuousClock(), end = clock.now + .milliseconds(1)
                                    while clock.now < end {}
                                    return ranges.map { _ in [CGRect(x: 0, y: 0, width: 10, height: 10)] }
                                })
    }
}

/// A box whose label (its geometry's `label`) hangs from another shape's left edge, as an arrow's
/// follows the shapes it is bound to: it moves, within bounds of one size, as that shape does.
struct Leashed: BoxShapeProps {
    static let kind: ShapeKind = "leashed"
    static let properties = Properties<Leashed> {
        Property("frame", \.frame).required()
        Property("leader", \.leader)
    }
    var frame: CGRect
    var leader: ShapeID?

    init(_ frame: CGRect, leader: ShapeID?) {
        self.frame = frame
        self.leader = leader
    }
}

extension Leashed {
    init() { self.init(.zero, leader: nil) }
}

struct LeashedDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Leashed>, in context: RenderContext) {}

    func geometry(of shape: ShapeRecord<Leashed>, in context: ShapeContext) -> ShapeGeometry {
        var geometry = ShapeGeometry(outline: shape.frame.polygon, bounds: shape.frame)
        if let leader = shape.props.leader.flatMap({ context.shape($0)?.box }) {
            geometry.label = CGRect(x: leader.minX, y: shape.frame.minY, width: 40, height: 16)
        }
        return geometry
    }
}

/// The leashed kind, its label's text found where its geometry puts the label: `layouts` counts the
/// shapes laid out.
@MainActor final class LeashedPlugin: CanvasPlugin {
    nonisolated var id: PluginID { "leashed" }
    var layouts = 0

    func register(into registrar: inout PluginRegistrar) {
        registrar.shape(LeashedDefinition()) { leashed in
            leashed.findableTexts("label", texts: { _, _ in [FindableText(field: "label", text: "leashed label")] },
                                  rects: { [self] record, _, ranges, context in
                                      layouts += 1
                                      guard let geometry = context.editor.shapeContext.geometry(of: record.id), let label = geometry.label else { return ranges.map { _ in [] } }
                                      return ranges.map { _ in [label.offsetBy(dx: -geometry.bounds.minX, dy: -geometry.bounds.minY)] }
                                  })
        }
    }
}

/// Whether a pixel is Find's orange: red full, blue well under green.
func isOrange(_ pixel: [Int]) -> Bool { pixel[0] > 230 && pixel[2] < pixel[1] - 40 && pixel[2] < 150 }

/// Whether a pixel is tinted orange over what was there: further from blue toward red.
func isTinted(_ pixel: [Int], over plain: [Int]) -> Bool { pixel[0] - pixel[2] > plain[0] - plain[2] + 40 }

@MainActor let overlayTests = Suite("Find's highlights", [
    test("in full: each hit where its text is, the current one deeper; nothing else; nothing once closed") {
        let id = ShapeID()
        let h = try findHarness(CanvasFile(root: CanvasDocument(shapes: memos(["xx pear yy pear"], ids: [id]))))
        let find = try search("pear", in: h)
        expectEqual(find.currentNumber, 1)
        let image = renderBitmap(h.editor, size: viewport)
        let current = try require(memoRect(id, 3..<7, in: h.editor)), other = try require(memoRect(id, 11..<15, in: h.editor))
        let gap = try require(memoRect(id, 8..<10, in: h.editor))
        let currentPixel = pixel(image, at: CGPoint(x: current.midX, y: current.midY))
        let otherPixel = pixel(image, at: CGPoint(x: other.midX, y: other.midY))
        expect(isOrange(currentPixel), "\(currentPixel)")
        expect(isOrange(otherPixel), "\(otherPixel)")
        expect(currentPixel[1] < otherPixel[1] - 20, "the current one deeper: \(currentPixel) against \(otherPixel)")
        expectEqual(pixel(image, at: CGPoint(x: gap.midX, y: gap.midY)), [255, 255, 255, 255], "between them, the memo's white")
        find.close()
        let closed = renderBitmap(h.editor, size: viewport)
        expectEqual(pixel(closed, at: CGPoint(x: current.midX, y: current.midY)), [255, 255, 255, 255])
    },
    test("a shape moved keeps its highlights where it's drawn, laid out once; an edit lays it out again") {
        let id = ShapeID()
        let plugin = MemosPlugin()
        let h = try findHarness(CanvasFile(root: CanvasDocument(shapes: memos(["pear"], ids: [id]))), memos: plugin)
        let find = try search("pear", in: h)
        _ = renderBitmap(h.editor, size: viewport)
        expectEqual(plugin.rectsAsked, 1)
        _ = renderBitmap(h.editor, size: viewport)
        expectEqual(plugin.rectsAsked, 1, "kept")
        h.editor.transact { $0.moveBox(id, to: CGPoint(x: 300, y: 300)) }
        let moved = renderBitmap(h.editor, size: viewport)
        expectEqual(plugin.rectsAsked, 1, "a move keeps the layout: its rects are the shape's own")
        let rect = try require(memoRect(id, 0..<4, in: h.editor))
        expect(isOrange(pixel(moved, at: CGPoint(x: rect.midX, y: rect.midY))))
        h.editor.transact { $0.update(id, as: Memo.self) { $0.props.body = "a pear" } }
        try settle(find, h)
        _ = renderBitmap(h.editor, size: viewport)
        expectEqual(plugin.rectsAsked, 2)
    },
    test("a label that moves within bounds of one size, as the shape it hangs from moves, is laid out again; one that stays is kept") {
        let leader = ShapeID(), leashed = ShapeID()
        let plugin = LeashedPlugin()
        let records = [AnyShapeRecord(ShapeRecord(id: leader, Memo(CGRect(x: 100, y: 300, width: 160, height: 40), "memo"))),
                       AnyShapeRecord(ShapeRecord(id: leashed, Leashed(CGRect(x: 50, y: 100, width: 600, height: 40), leader: leader)))]
        let h = try findHarness(CanvasFile(root: CanvasDocument(shapes: records)), more: [plugin])
        let find = try search("leashed", in: h)
        _ = renderBitmap(h.editor, size: viewport)
        let hit = try require(find.currentHit).hit
        expectEqual(try require(find.rects(of: hit, in: leashed).first).minX, 100, "hung from the leader's left edge")
        expectEqual(plugin.layouts, 1)
        _ = renderBitmap(h.editor, size: viewport)
        expectEqual(plugin.layouts, 1, "kept while nothing moves")
        h.editor.transact { $0.moveBox(leader, to: CGPoint(x: 400, y: 300)) }
        _ = renderBitmap(h.editor, size: viewport)
        expectEqual(try require(find.rects(of: hit, in: leashed).first).minX, 400, "the label moved, the bounds' size didn't")
        expectEqual(plugin.layouts, 2, "laid out again")
        h.editor.transact { $0.moveBox(leashed, to: CGPoint(x: 80, y: 120)) }
        h.editor.transact { $0.moveBox(leader, to: CGPoint(x: 430, y: 320)) }
        _ = renderBitmap(h.editor, size: viewport)
        expectEqual(plugin.layouts, 2, "both moved together: the label is where it was from the bounds, and kept")
    },
    test("a frame lays out what it has time for, tints the rest where they are, and asks for another frame") {
        let slow = SlowPlugin()
        let discs = (0..<12).map { i in AnyShapeRecord(ShapeRecord(Disc(CGRect(x: 20 + CGFloat(i % 6) * 120, y: 50 + CGFloat(i / 6) * 150, width: 80, height: 80)))) }
        let h = try findHarness(CanvasFile(root: CanvasDocument(shapes: discs)), more: [slow])
        let find = try search("slow", in: h)
        expectEqual(find.results.count, 12)
        let pending = h.scheduler.pendingCount
        let first = renderBitmap(h.editor, size: viewport)
        expect(slow.layouts >= 1 && slow.layouts < 12, "\(slow.layouts) laid out in the first frame")
        expect(h.scheduler.pendingCount > pending, "another frame asked for")
        let last = try require(discs.last?.box)
        var frames = 1
        while slow.layouts < 12, frames < 20 {
            h.wait(0)
            _ = renderBitmap(h.editor, size: viewport)
            frames += 1
        }
        expectEqual(slow.layouts, 12, "laid out over \(frames) frames")
        let done = renderBitmap(h.editor, size: viewport)
        let corner = CGPoint(x: last.maxX - 3, y: last.maxY - 3)
        expect(pixel(first, at: corner) != pixel(done, at: corner), "the last one, not laid out at first, was tinted over its bounds meanwhile")
    },
    test("zoomed out, each shape with hits is washed alike, the current one lined round too, and none without") {
        let ids = (0..<3).map { _ in ShapeID() }
        let h = try findHarness(CanvasFile(root: CanvasDocument(shapes: memos(["pear", "plum", "pear"], ids: ids))))
        h.editor.camera = Camera(origin: .zero, zoom: 0.2)
        let find = try search("pear", in: h)
        expectEqual(find.currentHit?.shape, ids[0])
        let image = renderBitmap(h.editor, size: viewport)
        find.close()
        let plain = renderBitmap(h.editor, size: viewport)
        @MainActor func center(_ id: ShapeID) throws -> CGPoint {
            let box = try require(h.editor.document[id]?.box)
            return h.editor.camera.toView(CGPoint(x: box.midX, y: box.midY))
        }
        // On the line round a shape: out from its right edge by FindStyle's gap and half its line (2 and
        // 1 view points).
        @MainActor func lined(_ id: ShapeID) throws -> CGPoint {
            let box = try require(h.editor.document[id]?.box)
            let edge = h.editor.camera.toView(CGPoint(x: box.maxX, y: box.midY))
            return CGPoint(x: edge.x + 3, y: edge.y)
        }
        let current = pixel(image, at: try center(ids[0])), other = pixel(image, at: try center(ids[2]))
        expect(isTinted(current, over: pixel(plain, at: try center(ids[0]))), "\(current)")
        expect(isTinted(other, over: pixel(plain, at: try center(ids[2]))), "\(other)")
        expectEqual(current, other, "washed alike: what's said on the current one reads as on any")
        expect(pixel(image, at: try lined(ids[0])) != pixel(plain, at: try lined(ids[0])), "the current one lined round")
        expectEqual(pixel(image, at: try lined(ids[2])), pixel(plain, at: try lined(ids[2])), "another not")
        expectEqual(pixel(image, at: try center(ids[1])), pixel(plain, at: try center(ids[1])), "no hits: as without Find")
    },
    test("zoomed out, a contribution's place for its text is tinted, not the shape; a ring follows the zoom in full") {
        let badges = BadgesPlugin()
        let box = AnyShapeRecord(ShapeRecord(Box(CGRect(x: 100, y: 100, width: 400, height: 400))))
        let h = try findHarness(CanvasFile(root: CanvasDocument(shapes: [box])), more: [badges])
        let find = try search("badge", in: h)
        _ = renderBitmap(h.editor, size: viewport)
        expectEqual(badges.layouts, 1)
        h.editor.camera = Camera(origin: .zero, zoom: 0.5)
        _ = renderBitmap(h.editor, size: viewport)
        expectEqual(badges.layouts, 2, "laid out again at another zoom")
        h.editor.camera = Camera(origin: .zero, zoom: 0.25)
        let image = renderBitmap(h.editor, size: viewport)
        find.close()
        let plain = renderBitmap(h.editor, size: viewport)
        let top = h.editor.camera.toView(CGPoint(x: 300, y: 150)), bottom = h.editor.camera.toView(CGPoint(x: 300, y: 450))
        expect(isTinted(pixel(image, at: top), over: pixel(plain, at: top)), "its top quarter, \(pixel(image, at: top))")
        expectEqual(pixel(image, at: bottom), pixel(plain, at: bottom), "not the rest")
    },
])

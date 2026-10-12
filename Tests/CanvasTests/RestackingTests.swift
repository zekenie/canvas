@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import TestKit

// The core's restacking of several shapes at once (`bringToFront`, `sendToBack`, `bringForward`,
// `sendBackward`), over CanvasTesting's boxes and corrals, plus one anchored box kind (Banner)
// declared in this file. Restacking on a board that isn't shown is in MovingOffBoardsTests.

/// A box painted by anchor, as an arrow is: document order doesn't decide where it's drawn.
private struct Banner: BoxShapeProps {
    static let kind: ShapeKind = "banner"
    static let properties = Properties<Banner> {
        Property("frame", \.frame).required()
    }
    var frame: CGRect
    init(_ frame: CGRect) { self.frame = frame }
    init() { self.init(.zero) }
}

private struct BannerDefinition: ShapeDefinition, PaintOrderAnchored {
    func render(_ shape: ShapeRecord<Banner>, in context: RenderContext) {}
    func paintAnchor(of shape: ShapeRecord<Banner>, in document: CanvasDocument) -> ShapeID? { nil }
}

@MainActor private func order(_ h: EditorHarness) -> [ShapeID] { h.editor.document.shapes.map(\.id) }

@MainActor let restackingTests = Suite("Restacking several shapes", [
    test("to front and to back keep the shapes' order among themselves, whatever order they're given in") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let b = h.add(Box(CGRect(x: 200, y: 0, width: 100, height: 100)))
        let c = h.add(Box(CGRect(x: 400, y: 0, width: 100, height: 100)))
        h.editor.transact("Send to Back") { $0.sendToBack([c, a]) }
        expectEqual(order(h), [a, c, b])
        h.editor.transact("Bring to Front") { $0.bringToFront([c, a]) }
        expectEqual(order(h), [b, a, c])
    },
    test("Bring Forward and Send Backward step past the next shape each overlaps, keeping the shapes' order") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let b = h.add(Box(CGRect(x: 50, y: 0, width: 100, height: 100)))      // overlaps a
        let c = h.add(Box(CGRect(x: 500, y: 0, width: 100, height: 100)))     // overlaps nothing
        let d = h.add(Box(CGRect(x: 60, y: 0, width: 100, height: 100)))      // overlaps a and b
        @MainActor func forward(_ ids: [ShapeID]) { h.editor.transact("Bring Forward") { $0.bringForward(ids) } }
        @MainActor func backward(_ ids: [ShapeID]) { h.editor.transact("Send Backward") { $0.sendBackward(ids) } }
        forward([a])
        expectEqual(order(h), [b, a, c, d])
        forward([a])
        expectEqual(order(h), [b, c, d, a], "past c, which it doesn't overlap, to above d")
        let revision = h.editor.revision
        forward([a])
        expectEqual(h.editor.revision, revision, "nothing above it: nothing to do")
        backward([a])
        expectEqual(order(h), [b, c, a, d])
        backward([a])
        expectEqual(order(h), [a, b, c, d], "past c again, to below b")

        forward([b, a])
        expectEqual(order(h), [c, d, a, b], "each past d, the next it overlaps, a still below b")
        backward([b, a])
        expectEqual(order(h), [c, a, b, d])
    },
    test("a container steps past the next shape it overlaps that it doesn't hold, what it holds going with it") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), CorralsPlugin()])
        let corral = h.add(Corral(CGRect(x: 0, y: 0, width: 300, height: 200)))
        let held = h.add(Box(CGRect(x: 20, y: 20, width: 100, height: 100)))
        h.editor.put([held], in: corral)
        let over = h.add(Box(CGRect(x: 250, y: 50, width: 100, height: 100)))       // overlaps the corral, above it
        expectEqual(order(h), [corral, held, over])
        h.editor.transact("Bring Forward") { $0.bringForward([corral]) }
        expectEqual(order(h), [over, corral, held], "past the box above it, not its own box, which goes with it")
        h.editor.transact("Send Backward") { $0.sendBackward([corral]) }
        expectEqual(order(h), [corral, held, over])
    },
    test("a shape painted by anchor isn't one to step past") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), Contributor(id: "banners") { $0.shape(BannerDefinition()) }])
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let banner = h.add(Banner(CGRect(x: 20, y: 0, width: 100, height: 100)))   // overlaps a
        let c = h.add(Box(CGRect(x: 50, y: 0, width: 100, height: 100)))           // overlaps a
        h.editor.transact("Bring Forward") { $0.bringForward([a]) }
        expectEqual(order(h), [banner, c, a], "past c, the banner not counted")
        h.editor.transact("Send Backward") { $0.sendBackward([a]) }
        expectEqual(order(h), [banner, a, c], "below c again")
    },
    test("the list forms leave a read-only shape where it is, and say so once") {
        let log = RefusalLog()
        let h = try EditorHarness(plugins: [FixturesPlugin(), FreezingPlugin(log: log)])
        let locked = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let a = h.add(Box(CGRect(x: 20, y: 0, width: 100, height: 100)))
        let b = h.add(Box(CGRect(x: 40, y: 0, width: 100, height: 100)))
        h.editor.freeze([locked])
        h.editor.transact("Front") { $0.bringToFront([locked, a]) }
        expectEqual(order(h), [locked, b, a])
        expectEqual(log.refusals, [[locked]])
        h.editor.transact("Forward") { $0.bringForward([locked]) }
        expectEqual(order(h), [locked, b, a])
        h.editor.transact("Backward") { $0.sendBackward([locked]) }
        expectEqual(order(h), [locked, b, a])
        h.editor.transact("Back") { $0.sendToBack([locked, a]) }
        expectEqual(order(h), [a, locked, b], "a goes to the back, the locked shape stays")
        expectEqual(log.refusals.count, 3, "all but the step back from the back, which has nowhere to go")
    },
])

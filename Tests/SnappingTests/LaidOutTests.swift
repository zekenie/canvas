@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Snapping
import TestKit

// A shape laid out larger than it stores (CanvasTesting's stretch, laid out by the gauge it names)
// snaps, and is snapped to, by the frame it is laid out in.
@MainActor let laidOutSnappingTests = Suite("Snapping laid-out frames", [
    test("a dragged stretch snaps its laid-out right edge onto a box's left edge, which its stored box would be too far from") {
        let h = try snapHarness(shapes: [FixturesPlugin(), StretchesPlugin()])
        h.add(Box(CGRect(x: 400, y: 0, width: 100, height: 100)))
        let gauge = h.add(CanvasTesting.Gauge(CGRect(x: 900, y: 700, width: 60, height: 40), width: 200, height: 60))
        let stretch = h.add(Stretch(CGRect(x: 0, y: 200, width: 100, height: 60), gauge: gauge))
        h.press(at: CGPoint(x: 50, y: 230))
        h.drag(to: CGPoint(x: 247, y: 230))                          // its frame's right edge 3 short of 400
        expectEqual(h.origin(of: stretch), CGPoint(x: 200, y: 200))
        expectEqual(h.editor.snapGuides.count, 1)
        h.release()
        expectEqual(h.editor.document[stretch]?.box?.size, CGSize(width: 100, height: 60), "what it stores is what it did")
    },
    test("a dragged box snaps its top onto a stretch's laid-out bottom edge") {
        let h = try snapHarness(shapes: [FixturesPlugin(), StretchesPlugin()])
        let gauge = h.add(CanvasTesting.Gauge(CGRect(x: 900, y: 700, width: 60, height: 40), width: 100, height: 200))
        h.add(Stretch(CGRect(x: 400, y: 0, width: 100, height: 60), gauge: gauge))
        let box = h.add(Box(CGRect(x: 0, y: 300, width: 100, height: 100)))
        h.press(at: CGPoint(x: 50, y: 350))
        h.drag(to: CGPoint(x: 50, y: 253))                           // its top 3 under the frame's bottom (200)
        expectEqual(h.origin(of: box), CGPoint(x: 0, y: 200))
        h.release()
    },
    test("a gauge changed mid-drag is followed at the next event: the dragged stretch snaps by the frame it has by then") {
        let h = try snapHarness(shapes: [FixturesPlugin(), StretchesPlugin()])
        h.add(Box(CGRect(x: 400, y: 0, width: 100, height: 100)))
        let gauge = h.add(CanvasTesting.Gauge(CGRect(x: 900, y: 700, width: 60, height: 40), width: 100, height: 60))
        let stretch = h.add(Stretch(CGRect(x: 0, y: 200, width: 100, height: 60), gauge: gauge))
        h.press(at: CGPoint(x: 50, y: 230))
        h.drag(to: CGPoint(x: 80, y: 230))
        expectEqual(h.origin(of: stretch), CGPoint(x: 30, y: 200))
        h.editor.transact("Gauge") { $0.update(gauge, as: CanvasTesting.Gauge.self) { $0.props.width = 200 } }
        h.drag(to: CGPoint(x: 247, y: 230))                          // 3 short of 400 by the new frame, 103 by the old
        expectEqual(h.origin(of: stretch), CGPoint(x: 200, y: 200))
        h.release()
    },
    test("a stretch laid out smaller than it stores snaps its smaller right edge onto a box's left edge, and a box snaps to its smaller bottom edge, not the stored one") {
        let h = try snapHarness(shapes: [FixturesPlugin(), StretchesPlugin(shrinking: true)])
        h.add(Box(CGRect(x: 400, y: 0, width: 100, height: 100)))
        let gauge = h.add(CanvasTesting.Gauge(CGRect(x: 900, y: 700, width: 60, height: 40), width: 50, height: 30))
        let stretch = h.add(Stretch(CGRect(x: 0, y: 200, width: 100, height: 60), gauge: gauge))
        h.press(at: CGPoint(x: 20, y: 215))
        h.drag(to: CGPoint(x: 367, y: 215))                          // its frame's right edge 3 short of 400; its stored box's would be 53 past
        expectEqual(h.origin(of: stretch), CGPoint(x: 350, y: 200))
        expectEqual(h.editor.snapGuides.count, 1)
        h.release()
        expectEqual(h.editor.document[stretch]?.box?.size, CGSize(width: 100, height: 60), "what it stores is what it did")
        let box = h.add(Box(CGRect(x: 0, y: 500, width: 100, height: 100)))
        h.press(at: CGPoint(x: 50, y: 550))
        h.drag(to: CGPoint(x: 328, y: 283))                          // its top 3 under the frame's bottom (230); the stored box's (260) is 27 further
        expectEqual(h.origin(of: box)?.y, 230)
        h.release()
    },
])

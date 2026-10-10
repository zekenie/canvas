import Adornments
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import TestKit

// A shape laid out larger than it stores (CanvasTesting's stretch, laid out by the gauge it names): its
// chips go by the frame it is laid out in, and follow it when it is laid out again.

@MainActor let laidOutAdornmentTests = Suite("Adornments on laid-out frames", [
    test("a chip row's right end is at the laid-out right edge, and moves when the stretch is laid out again, with the stretch not committed") {
        let h = try adornedHarness([StretchesPlugin(), everyShape(Flag.self) { _ in flagLabel }])
        let gauge = h.add(CanvasTesting.Gauge(CGRect(x: 900, y: 700, width: 60, height: 40), width: 400, height: 120))
        let stretch = h.add(Stretch(boxFrame, gauge: gauge))
        expectEqual(h.editor.adornmentFrames(of: stretch).first?.rect, CGRect(x: 482, y: 73, width: 18, height: 18), "at 500, not the stored 300")
        let stored = h.editor.document[stretch]
        h.editor.transact("Gauge") { $0.update(gauge, as: CanvasTesting.Gauge.self) { $0.props.width = 600 } }
        expectEqual(h.editor.adornmentFrames(of: stretch).first?.rect, CGRect(x: 682, y: 73, width: 18, height: 18), "laid out again")
        expectEqual(h.editor.document[stretch], stored, "the stretch is as it was")
    },
])

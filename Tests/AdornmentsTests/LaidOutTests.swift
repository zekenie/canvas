import Adornments
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import TestKit

// A shape laid out larger than it stores (CanvasTesting's stretch, laid out by the gauge it names): its
// chips go by the frame it is laid out in, and follow it when it is laid out again.

@MainActor let laidOutAdornmentTests = Suite("Adornments on laid-out frames", [
    test("a chip row's right end is at the laid-out right edge, and moves when its gauge is committed, the stretch itself not") {
        let h = try adornedHarness([StretchesPlugin(), everyShape(Flag.self) { _ in flagLabel }])
        let gauge = h.add(CanvasTesting.Gauge(CGRect(x: 900, y: 700, width: 60, height: 40), width: 400, height: 120))
        let stretch = h.add(Stretch(boxFrame, gauge: gauge))
        expectEqual(h.editor.adornmentFrames(of: stretch).first?.rect, CGRect(x: 482, y: 73, width: 18, height: 18), "at 500, not the stored 300")
        let stored = h.editor.document[stretch]
        h.editor.transact("Gauge") { $0.update(gauge, as: CanvasTesting.Gauge.self) { $0.props.width = 600 } }
        expectEqual(h.editor.adornmentFrames(of: stretch).first?.rect, CGRect(x: 682, y: 73, width: 18, height: 18), "laid out again")
        expectEqual(h.editor.document[stretch], stored, "the stretch is as it was")
    },
    test("a shape laid out smaller than it stores has its chip row at the smaller frame, and they follow the gauge down and up") {
        let h = try adornedHarness([StretchesPlugin(shrinking: true), everyShape(Flag.self) { _ in flagLabel }])
        let gauge = h.add(CanvasTesting.Gauge(CGRect(x: 900, y: 700, width: 60, height: 40), width: 120, height: 40))
        let stretch = h.add(Stretch(boxFrame, gauge: gauge))
        expectEqual(h.editor.shapeContext.frame(of: stretch), CGRect(x: 100, y: 100, width: 120, height: 40), "the laid-out frame, not the stored 200 by 120")
        expectEqual(h.editor.adornmentFrames(of: stretch).first?.rect, CGRect(x: 202, y: 73, width: 18, height: 18), "at 220, not the stored 300")
        h.editor.transact("Gauge") { $0.update(gauge, as: CanvasTesting.Gauge.self) { $0.props.width = 400 } }
        expectEqual(h.editor.shapeContext.frame(of: stretch), CGRect(x: 100, y: 100, width: 400, height: 40), "larger again")
        expectEqual(h.editor.adornmentFrames(of: stretch).first?.rect, CGRect(x: 482, y: 73, width: 18, height: 18))
        expectEqual(h.editor.document[stretch]?.box, boxFrame, "the stored box is as it was")
    },
    test("the public anchor of a shape laid out smaller than it stores is its laid-out frame, and follows the gauge") {
        let h = try adornedHarness([StretchesPlugin(shrinking: true), everyShape(Flag.self) { _ in flagLabel }])
        let gauge = h.add(CanvasTesting.Gauge(CGRect(x: 900, y: 700, width: 60, height: 40), width: 120, height: 40))
        let stretch = h.add(Stretch(boxFrame, gauge: gauge))
        expectEqual(h.editor.adornmentAnchor(of: stretch), CGRect(x: 100, y: 100, width: 120, height: 40), "not the stored 200 by 120")
        h.editor.transact("Gauge") { $0.update(gauge, as: CanvasTesting.Gauge.self) { $0.props.width = 400 } }
        expectEqual(h.editor.adornmentAnchor(of: stretch), CGRect(x: 100, y: 100, width: 400, height: 40), "larger again")
    },
])

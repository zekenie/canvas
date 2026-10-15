import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import TestKit

// An arrow bound to a shape laid out larger than it stores (CanvasTesting's stretch, laid out by the
// gauge it names) ends on the frame the shape is laid out in, and follows it when it is laid out again,
// with no commit of the arrow's or the stretch's: the arrow's cached geometry is the one dependent that
// has to be told (`layoutDidChange`).

@MainActor let arrowLaidOutTests = Suite("Arrows on laid-out frames", [
    test("an arrow bound to a stretch ends on its laid-out edge, and follows the stretch when its gauge grows") {
        let h = try EditorHarness(plugins: arrowsPlugins(more: [StretchesPlugin()]))
        let gauge = h.add(CanvasTesting.Gauge(CGRect(x: 900, y: 700, width: 60, height: 40), width: 200, height: 120))
        let stretch = h.add(Stretch(CGRect(x: 460, y: 80, width: 100, height: 60), gauge: gauge))     // laid out to x 660
        let arrow = h.add(Arrow(start: .free(CGPoint(x: 1200, y: 140)),
                                end: .bound(ArrowBinding(shapeID: stretch, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false))))
        let end = try require(h.editor.arrowGeometry(of: arrow)).end
        expect(end.x > 640 && end.x < 700, "ends at the laid-out right edge (660), not the stored one (560): \(end)")
        let stored = h.editor.document[stretch]
        let revision = h.editor.revision
        h.editor.transact("Gauge") { $0.update(gauge, as: CanvasTesting.Gauge.self) { $0.props.width = 400 } }
        expectEqual(h.editor.revision, revision + 1, "the gauge's commit alone")
        let grown = try require(h.editor.arrowGeometry(of: arrow)).end
        expect(grown.x > 840 && grown.x < 900, "followed it to the new right edge (860): \(grown)")
        expectEqual(h.editor.document[stretch], stored, "the stretch is not edited")
        h.editor.undo()
        expectEqual(try require(h.editor.arrowGeometry(of: arrow)).end, end, "and undone with the gauge")
    },
    test("an arrow bound to a stretch laid out smaller than it stores ends on its smaller edge, and follows it as its gauge grows and shrinks") {
        let h = try EditorHarness(plugins: arrowsPlugins(more: [StretchesPlugin(shrinking: true)]))
        let gauge = h.add(CanvasTesting.Gauge(CGRect(x: 900, y: 700, width: 60, height: 40), width: 40, height: 30))
        let stretch = h.add(Stretch(CGRect(x: 460, y: 80, width: 200, height: 120), gauge: gauge))     // stored to x 660, laid out to x 500
        let arrow = h.add(Arrow(start: .free(CGPoint(x: 1200, y: 95)),
                                end: .bound(ArrowBinding(shapeID: stretch, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false))))
        let end = try require(h.editor.arrowGeometry(of: arrow)).end
        expect(end.x > 480 && end.x < 540, "ends at the laid-out right edge (500), not the stored one (660): \(end)")
        expectEqual(h.editor.shapeContext.geometry(of: stretch)?.bounds, CGRect(x: 460, y: 80, width: 40, height: 30))
        let stored = h.editor.document[stretch]
        h.editor.transact("Gauge") { $0.update(gauge, as: CanvasTesting.Gauge.self) { $0.props.width = 100 } }
        let grown = try require(h.editor.arrowGeometry(of: arrow)).end
        expect(grown.x > 540 && grown.x < 600, "followed it to the new right edge (560): \(grown)")
        h.editor.transact("Gauge") { $0.update(gauge, as: CanvasTesting.Gauge.self) { $0.props.width = 20 } }
        let shrunk = try require(h.editor.arrowGeometry(of: arrow)).end
        expect(shrunk.x > 470 && shrunk.x < 500, "and in to 480: \(shrunk)")
        expectEqual(h.editor.document[stretch], stored, "the stretch is not edited")
        h.editor.undo()
        h.editor.undo()
        expectEqual(try require(h.editor.arrowGeometry(of: arrow)).end, end, "and undone with the gauge")
    },
])

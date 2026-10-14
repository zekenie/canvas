import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Geometry
import TestKit

// A shape laid out other than stored, with its gauge on another board: every reader follows the gauge
// when it changes there, with no commit on the shape's board.

@MainActor let laidOutAcrossBoardsTests = Suite("Laid out by a shape on another board", [
    test("a gauge on another board changed there lays the stretch out smaller and larger with no commit on its board: hit, culling, bounds and damage follow each time") {
        let stretch = ShapeID(), gauge = ShapeID(), pocket = ShapeID(), far = ShapeID()
        let root = CanvasDocument(shapes: [
            AnyShapeRecord(ShapeRecord(id: stretch, Stretch(CGRect(x: 0, y: 0, width: 300, height: 200), gauge: gauge))),
            AnyShapeRecord(ShapeRecord(id: far, Box(CGRect(x: -500, y: -500, width: 10, height: 10)))),
            AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: -300, y: 0, width: 100, height: 100)))),
        ])
        let inside = CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: gauge, StretchGauge(CGRect(x: 0, y: 0, width: 60, height: 40), width: 400, height: 300)))])
        let h = try EditorHarness(plugins: [FixturesPlugin(), PocketsPlugin(), StretchesPlugin(shrinking: true)],
                                  file: CanvasFile(root: root, children: [pocket: inside]))
        let e = h.editor
        let board = BoardID(owner: pocket)
        @MainActor func set(_ width: CGFloat, _ height: CGFloat) {
            e.transact(on: board, "Gauge") { $0.update(gauge, as: StretchGauge.self) { $0.props.width = width; $0.props.height = height } }
        }
        expectEqual(e.shapeContext.frame(of: stretch), CGRect(x: 0, y: 0, width: 400, height: 300), "larger than stored")
        expectEqual(e.shapeBounds.maxX, 400)
        expectEqual(e.shapeBounds.maxY, 300)
        expectEqual(e.shape(at: CGPoint(x: 390, y: 290)), stretch)
        var mark = e.damageMark
        set(100, 40)
        expectEqual(e.shapeContext.frame(of: stretch), CGRect(x: 0, y: 0, width: 100, height: 40), "smaller than stored, no commit here")
        expectEqual(e.shapeBounds.maxX, 100, "the bounds shrink to the frame, inside the stored box")
        expectEqual(e.shapeBounds.maxY, 100, "the pocket's bottom")
        expectEqual(e.shape(at: CGPoint(x: 250, y: 150)), nil, "in the stored box, outside the frame")
        expectEqual(e.shape(at: CGPoint(x: 390, y: 290)), nil)
        expectEqual(e.paintOrder(in: CGRect(x: 240, y: 140, width: 10, height: 10)).map(\.id), [])
        expectEqual(e.paintOrder(in: CGRect(x: 50, y: 10, width: 10, height: 10)).map(\.id), [stretch])
        expect(e.damage(since: mark).contains(CGRect(x: 0, y: 0, width: 400, height: 300)), "where it was is redrawn: \(e.damage(since: mark))")
        mark = e.damageMark
        set(350, 250)
        expectEqual(e.shapeContext.frame(of: stretch), CGRect(x: 0, y: 0, width: 350, height: 250))
        expectEqual(e.shapeBounds.maxX, 350)
        expectEqual(e.shape(at: CGPoint(x: 340, y: 240)), stretch)
        expectEqual(e.paintOrder(in: CGRect(x: 340, y: 240, width: 5, height: 5)).map(\.id), [stretch])
        expect(e.damage(since: mark).contains(CGRect(x: 0, y: 0, width: 350, height: 250)), "where it is now is redrawn")
        e.undo()
        _ = e.showBoard(.root)
        expectEqual(e.shapeContext.frame(of: stretch), CGRect(x: 0, y: 0, width: 100, height: 40), "undone on the other board")
        expectEqual(e.shapeBounds.maxX, 100)
        expectEqual(e.shape(at: CGPoint(x: 250, y: 150)), nil)
    },
    test("a stretch laid out larger than stored by the shrinking fixture's default sibling behaves as before: hit and bounds by the larger frame") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), PocketsPlugin(), StretchesPlugin()])
        let gauge = h.add(StretchGauge(CGRect(x: 1000, y: 1000, width: 60, height: 40), width: 50, height: 300))
        let stretch = h.add(Stretch(CGRect(x: 0, y: 0, width: 200, height: 100), gauge: gauge))
        expectEqual(h.editor.shapeContext.frame(of: stretch), CGRect(x: 0, y: 0, width: 200, height: 300))
        expectEqual(h.editor.shape(at: CGPoint(x: 190, y: 290)), stretch)
        expectEqual(h.editor.shapeBounds.minX, 0)
    },
])

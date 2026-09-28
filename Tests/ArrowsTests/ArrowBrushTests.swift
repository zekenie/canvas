import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Keyboard
import Selection
import TableOfContents
import TestKit

// Arrows answer the brush exactly, against their visible body.
@MainActor let arrowBrushTests = Suite("Arrow brushing", [
    test("a brush touching a straight arrow's body selects it; 1 pt off doesn't") {
        let board = try Board(arrow: 0)
        let arrow = try require(board.arrow), y = try require(board.h.editor.arrowGeometry(of: arrow)).start.y
        expectEqual(brushed(board.h, from: CGPoint(x: 350, y: 100), to: CGPoint(x: 380, y: y - 1)), [])
        expectEqual(brushed(board.h, from: CGPoint(x: 350, y: 100), to: CGPoint(x: 380, y: y)), [arrow])
    },
    test("a level arrow (zero-height bounds) is brushed") {
        let board = try Board(arrow: 0)
        let arrow = try require(board.arrow)
        expectEqual(board.h.editor.shapeContext.geometry(of: arrow)?.bounds.height, 0)
        expectEqual(brushed(board.h, from: CGPoint(x: 350, y: 100), to: CGPoint(x: 380, y: 250)), [arrow])
    },
    test("a brush inside a bent arrow's bounds but off its arc doesn't select it; one crossing the arc, away from its coarse outline, does") {
        let board = try Board(arrow: 150)
        let h = board.h, arrow = try require(board.arrow)
        let geometry = try require(h.editor.arrowGeometry(of: arrow))
        guard case .curved(let arc, let startT, let endT) = geometry.path else { return expect(false, "the arrow isn't bent") }
        let chordMiddle = (geometry.startHandle + geometry.endHandle) / 2
        let hollow = CGRect(center: geometry.middle.moved(toward: chordMiddle, by: 40), size: CGSize(width: 10, height: 10))
        expect(geometry.bodyPath.boundingBoxOfPath.contains(hollow))
        expectEqual(brushed(h, from: CGPoint(x: hollow.minX, y: hollow.minY), to: CGPoint(x: hollow.maxX, y: hollow.maxY)), [])
        // A quarter of the way along the body, where the arc bulges away from the straight line from
        // its start to its middle (the coarse outline) by more than the brush reaches; the press is
        // clear of the arc's hit margin.
        let point = arc.point(at: startT + (endT - startT) / 4)
        let outward = (point - arc.center).normalized * 6
        expect(distanceToSegment(from: point, geometry.start, geometry.middle) > 8)
        expectEqual(h.editor.shape(at: point + outward), nil)
        expectEqual(brushed(h, from: point + outward, to: point - outward), [arrow])
    },
    test("a bent arrow's hidden stretch doesn't count: a brush over it, touching the body's bounds, selects nothing") {
        let board = try Board(arrow: 150)
        let h = board.h, arrow = try require(board.arrow)
        let geometry = try require(h.editor.arrowGeometry(of: arrow))
        guard case .curved(let arc, _, _) = geometry.path else { return expect(false, "the arrow isn't bent") }
        // Between the arrowhead and B's bottom edge (y = 280): just above the visible end, clear of B.
        let end = geometry.end
        let brush = CGRect(x: end.x - 2, y: 280.5, width: 10, height: end.y - 3 - 280.5)
        expect(brush.touches(geometry.bodyPath.boundingBoxOfPath) && !brush.contains(end))
        expect(!intersections(of: arc, withPolygon: brush.polygon).isEmpty, "the whole arc crosses it")
        expectEqual(brushed(h, from: CGPoint(x: brush.maxX, y: brush.minY), to: CGPoint(x: brush.minX, y: brush.maxY)), [])
    },
    test("a brush over only the hidden stub inside a bound shape selects the shape, not the arrow") {
        let board = try Board(arrow: 0, second: CGRect(x: 460, y: 400, width: 200, height: 200))
        let h = board.h, arrow = try require(board.arrow)
        let geometry = try require(h.editor.arrowGeometry(of: arrow))
        let brush = CGRect(x: 270, y: 240, width: 20, height: 22)
        expect(!intersections(ofSegmentFrom: geometry.startHandle, to: geometry.start, withPolygon: brush.polygon).isEmpty, "over the stub")
        expectEqual(brushed(h, from: CGPoint(x: brush.maxX, y: brush.minY), to: CGPoint(x: brush.minX, y: brush.maxY)), [board.a])
    },
    test("⌘ selects an arrow only when its whole body is strictly inside") {
        let board = try Board(arrow: 0)
        let h = board.h, arrow = try require(board.arrow)
        let geometry = try require(h.editor.arrowGeometry(of: arrow))
        h.hold(.command)
        expectEqual(brushed(h, from: CGPoint(x: geometry.end.x, y: 250), to: CGPoint(x: geometry.start.x - 0.5, y: 100)), [])
        expectEqual(brushed(h, from: CGPoint(x: geometry.end.x + 0.5, y: 250), to: CGPoint(x: geometry.start.x, y: 100)), [])
        expectEqual(brushed(h, from: CGPoint(x: geometry.end.x + 0.5, y: 250), to: CGPoint(x: geometry.start.x - 0.5, y: 100)), [arrow])
    },
    test("brushing across 1,000 boxes and 1,000 bound arrows stays within the hover test's budget") {
        var shapes: [AnyShapeRecord] = []
        let boxes = (0..<1000).map { (i: Int) in
            ShapeRecord(Box(CGRect(x: CGFloat(i % 40) * 60, y: CGFloat(i / 40) * 60, width: 40, height: 40)))
        }
        shapes += boxes.map(AnyShapeRecord.init)
        for (i, box) in boxes.enumerated() {
            let next = boxes[(i + 1) % boxes.count]
            func bound(_ id: ShapeID) -> ArrowTerminal {
                .bound(ArrowBinding(shapeID: id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false))
            }
            shapes.append(AnyShapeRecord(ShapeRecord(Arrow(start: bound(box.id), end: bound(next.id)))))
        }
        let registry = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), ArrowsPlugin(), TableOfContentsPlugin()])
        let h = EditorHarness { CanvasEditor(registry: registry, document: CanvasDocument(shapes: shapes), scheduler: $0) }
        h.press(at: CGPoint(x: 2500, y: 1600))
        let elapsed = threadCPUTime {
            for i in 1...10 { h.drag(to: CGPoint(x: 2500 - CGFloat(i) * 250, y: 1600 - CGFloat(i) * 160)) }
        }
        expectEqual(h.editor.selectedShapeIDs.count, 2000)
        h.release()
        // About 2 ms of this thread's time a drag in a debug build (what else runs doesn't count).
        expect(elapsed / 10 < .milliseconds(25), "\(elapsed / 10) per drag")
    },
])

/// Brushes from `from` to `to` (view points) and returns what the brush selected.
@MainActor func brushed(_ h: EditorHarness, from: CGPoint, to: CGPoint) -> [ShapeID] {
    h.press(at: from)
    h.drag(to: to)
    h.release()
    return h.editor.selectedShapeIDs
}

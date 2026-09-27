import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Selection
import TableOfContents
import TestKit

@MainActor let arrowShapeTests = Suite("Arrows as shapes", [
    test("clipping golden: center to center between two boxes") {
        let board = try Board(arrow: 0)
        let geometry = try require(board.h.editor.arrowGeometry(of: try require(board.arrow)))
        expectClose(geometry.start, CGPoint(x: 280, y: 180))
        expectClose(geometry.end, CGPoint(x: 448.25, y: 180))
    },
    test("arrows bind to any closed shape, analytic hit tests included, and never to arrows") {
        let h = try EditorHarness(plugins: [SelectionPlugin(), FixturesPlugin(), ArrowsPlugin(), TableOfContentsPlugin()])
        let disc = h.add(Disc(CGRect(x: 460, y: 80, width: 200, height: 140)))
        h.add(Box(boxA))
        h.key("a"); h.move(to: boxA.center); h.press()
        h.drag(to: CGPoint(x: 465, y: 85), speed: fast)            // inside the disc's box, outside the disc
        expectEqual(h.editor.hintedShapeID, nil)
        h.drag(to: CGPoint(x: 560, y: 150), speed: fast)
        h.release()
        expectEqual(h.editor.document.shapes.last?.typed(as: Arrow.self)?.props.end.binding?.shapeID, disc)
        h.key("a"); h.move(to: CGPoint(x: 370, y: 150))              // on the first arrow's body
        expectEqual(h.editor.hintedShapeID, nil)
    },
    test("moving an arrow keeps its ends bound (made precise) while they stay on their shapes") {
        let board = try Board(arrow: 0)
        board.h.move(to: CGPoint(x: 364, y: 180)); board.h.press()
        board.h.drag(to: CGPoint(x: 364, y: 200)); board.h.drag(to: CGPoint(x: 364, y: 230)); board.h.release()
        let arrow = try require(board.arrows.first)
        expectEqual(arrow.start.binding?.isPrecise, true)
        expectClose(try require(arrow.end.binding?.normalizedAnchor), CGPoint(x: 0.5, y: 0.75))
        board.h.press(at: CGPoint(x: 320, y: 230))                  // on the body, clear of the bend handle
        board.h.drag(to: CGPoint(x: 320, y: 250)); board.h.drag(to: CGPoint(x: 320, y: 570)); board.h.release()
        expectEqual(board.arrows.first?.start, .free(CGPoint(x: 180, y: 570)))
    },
    test("an arrow is hit within its stroke and margin at any zoom, and where the shapes it joins have taken it") {
        let board = try Board(arrow: 0)
        let arrow = try require(board.arrow)
        let h = board.h
        // The body runs along y = 180 from x = 280. Its reach: 3 pt of margin and half its 3.5 stroke.
        expectEqual(h.editor.shape(at: CGPoint(x: 364, y: 184.5)), arrow)
        expectEqual(h.editor.shape(at: CGPoint(x: 364, y: 185)), nil)
        h.editor.camera = Camera(origin: .zero, zoom: 0.25)
        expectEqual(h.editor.shape(at: CGPoint(x: 364, y: 193.5)), arrow, "3 pt is 12 world units at 25%")
        h.editor.camera = Camera()
        h.editor.transact { $0.update(board.b, as: Box.self) { $0.frame.origin.y += 300 } }
        expectEqual(h.editor.shape(at: CGPoint(x: 364, y: 180)), nil, "the arrow went with B")
        let moved = try require(h.editor.arrowGeometry(of: arrow))
        expectEqual(h.editor.shape(at: (moved.start + moved.end) / 2), arrow)
    },
    test("deleting a shape frees the arrow's end where it visibly was, keeping the curve") {
        let board = try Board(arrow: 70)
        let id = try require(board.arrow)
        let before = try require(board.h.editor.arrowGeometry(of: id))
        board.h.editor.selection = board.b
        board.h.editor.deleteSelection()
        let after = try require(board.h.editor.arrowGeometry(of: id))
        expectEqual(board.arrows.first?.end, .free(before.end))
        expectClose(after.start, before.start, within: 1e-6)
        expectClose(after.middle, before.middle, within: 1e-6)
        expectClose(after.end, before.end, within: 1e-6)
    },
    test("an arrow paints just above the highest shape it's bound to; unbound arrows paint on top") {
        let board = try Board(arrow: 0)
        let c = board.h.add(Box(CGRect(x: 0, y: 600, width: 50, height: 50)))
        board.drawArrow(from: CGPoint(x: 700, y: 700), to: CGPoint(x: 800, y: 800))   // unbound
        let loose = try require(board.arrowIDs.last)
        expectEqual(board.h.editor.paintOrder().map(\.id), [board.a, board.b, try require(board.arrow), c, loose])
        board.h.editor.transact { $0.bringToFront(board.a) }       // raising A carries nothing; B is still higher
        expectEqual(board.h.editor.paintOrder().map(\.id), [board.b, c, board.a, try require(board.arrow), loose])
    },
    test("in the table of contents an arrow is listed under the shape it starts from, and at the top when that shape isn't listed") {
        let board = try Board(arrow: 0)
        let contents = try require(board.h.editor.tableOfContents)
        board.drawArrow(from: CGPoint(x: 700, y: 700), to: CGPoint(x: 800, y: 800))   // starts free
        let loose = try require(board.arrowIDs.last)
        board.h.editor.selectedShapeIDs = []
        let entries = contents.entries
        expectEqual(entries.map(\.id), [board.a, board.b, loose])
        expectEqual(entries.first?.children?.map(\.id), [try require(board.arrow)])
        expectEqual(entries.first?.children?.first?.label?.text, "Arrow", "the arrow tool's label")
        expectEqual(entries.first?.children?.first?.symbol, "arrow.up.right")
        board.h.editor.selectedShapeIDs = [try require(board.arrow), board.b]
        expectEqual(contents.entries.map(\.id), [board.b, try require(board.arrow)], "its start isn't selected, so it's at the top")
    },
    test("pressing an arrow selects it without reordering anything") {
        let board = try Board(arrow: 0)
        board.h.add(Box(CGRect(x: 0, y: 600, width: 50, height: 50)))      // so the arrow isn't last
        let order = board.h.editor.document.shapes.map(\.id)
        let revision = board.h.editor.revision
        board.h.press(at: CGPoint(x: 364, y: 180)); board.h.release()
        expectEqual(board.h.editor.selection, board.arrow)
        expectEqual(board.h.editor.document.shapes.map(\.id), order)
        expectEqual(board.h.editor.revision, revision)
    },
    test("at 1,000 shapes and 1,000 bound arrows, hovering stays fast: finding a shape by id is constant time") {
        var shapes: [AnyShapeRecord] = []
        let boxes = (0..<1000).map { i in
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
        let registry = try Registry(plugins: [SelectionPlugin(), FixturesPlugin(), ArrowsPlugin(), TableOfContentsPlugin()])
        let h = EditorHarness { CanvasEditor(registry: registry, document: CanvasDocument(shapes: shapes), scheduler: $0) }
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for i in 0..<10 { h.move(to: CGPoint(x: 20 + CGFloat(i) * 60, y: 20)) }
        }
        // About 12 ms in a debug build; looking shapes up by scanning made it about 225 ms.
        expect(elapsed / 10 < .milliseconds(80), "\(elapsed / 10) per move")
    },
    test("the hit margin is 3 view points beyond the stroke, at any zoom") {
        for zoom: CGFloat in [1, 4] {
            let board = try Board(arrow: 0)
            let id = try require(board.arrow)
            let margin = 3 / zoom + 1.75
            board.h.editor.camera = Camera(origin: .zero, zoom: zoom)
            expectEqual(board.h.editor.shape(at: CGPoint(x: 364, y: 180 + margin - 0.001)), id)
            expectEqual(board.h.editor.shape(at: CGPoint(x: 364, y: 180 + margin + 0.001)), nil)
        }
    },
])

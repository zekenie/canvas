import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Mentions
import Selection
import TableOfContents
import TestKit

/// The tinted groups a test has the canvas outline.
@MainActor final class TintedOutlinesBox {
    var groups: [TintedOutlines] = []
}

@MainActor let arrowShapeTests = Suite("Arrows as shapes", [
    test("clipping golden: center to center between two boxes") {
        let board = try Board(arrow: 0)
        let geometry = try require(board.h.editor.arrowGeometry(of: try require(board.arrow)))
        expectClose(geometry.start, CGPoint(x: 280, y: 180))
        expectClose(geometry.end, CGPoint(x: 448.25, y: 180))
    },
    test("arrows bind to any closed shape, analytic hit tests included, and never to arrows") {
        let h = try EditorHarness(plugins: arrowsPlugins())
        let disc = h.add(Disc(CGRect(x: 460, y: 80, width: 200, height: 140)))
        let a = h.add(Box(boxA))
        let arrow = h.add(Arrow(start: .bound(ArrowBinding(shapeID: a, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false)),
                                end: .free(CGPoint(x: 400, y: 400))))
        h.editor.selection = arrow
        h.move(to: CGPoint(x: 400, y: 400)); h.press()               // its free end's handle
        h.drag(to: CGPoint(x: 465, y: 85), speed: fast)            // inside the disc's box, outside the disc
        expectEqual(h.editor.hintedShapeID, nil)
        h.drag(to: CGPoint(x: 560, y: 150), speed: fast)
        h.release()
        expectEqual(h.editor.document[arrow]?.typed(as: Arrow.self)?.props.end.binding?.shapeID, disc)
        let body = try require(h.editor.arrowGeometry(of: arrow)).middle
        let other = h.add(Arrow(start: .free(CGPoint(x: 300, y: 500)), end: .free(CGPoint(x: 400, y: 500))))
        h.editor.selection = other
        h.move(to: CGPoint(x: 400, y: 500)); h.press()
        h.drag(to: body, speed: fast)                               // on the first arrow's body
        expectEqual(h.editor.hintedShapeID, nil)
        h.release()
        expectEqual(h.editor.document[other]?.typed(as: Arrow.self)?.props.end, .free(body))
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
    test("a copy of an arrow stays bound to the copies of its shapes, anchors and all") {
        let board = try Board(arrow: 70)
        let record = try require(board.arrow.flatMap { board.h.editor.document[$0] })
        let a2 = ShapeID(), b2 = ShapeID()
        let copy = try require(record.remappingReferences({ [board.a: a2, board.b: b2][$0] }, in: board.h.editor.shapeContext)?.typed(as: Arrow.self)?.props)
        let arrow = try require(record.typed(as: Arrow.self)?.props)
        expectEqual(copy.start.binding?.shapeID, a2)
        expectEqual(copy.end.binding?.shapeID, b2)
        expectEqual(copy.start.binding?.normalizedAnchor, arrow.start.binding?.normalizedAnchor)
        expectEqual(copy.bend, arrow.bend)
    },
    test("a copy of an arrow lets go of a shape copied without it as deleting that shape would: where it visibly was, keeping the curve") {
        let board = try Board(arrow: 70)
        let id = try require(board.arrow)
        let record = try require(board.h.editor.document[id])
        let a2 = ShapeID()
        let copy = try require(record.remappingReferences({ $0 == board.a ? a2 : nil }, in: board.h.editor.shapeContext)?.typed(as: Arrow.self)?.props)
        board.h.editor.transact { $0.delete([board.b]) }
        var released = try require(board.arrows.first)
        expectEqual(released.start.binding?.shapeID, board.a)
        released.start = .bound(ArrowBinding(shapeID: a2, normalizedAnchor: released.start.binding!.normalizedAnchor, isPrecise: false, isExact: false))
        expectEqual(copy, released)
    },
    test("an arrow can't let go of a shape it can't find, since it can't tell where that end is drawn") {
        let board = try Board(arrow: 70)
        let record = try require(board.arrow.flatMap { board.h.editor.document[$0] })
        let without = CanvasDocument(shapes: board.h.editor.document.shapes.filter { $0.id != board.b })
        let context = ShapeContext(document: without, registry: board.h.editor.registry)
        expect(record.remappingReferences({ $0 == board.a ? $0 : nil }, in: context) == nil)
        expect(record.remappingReferences({ $0 }, in: context) != nil, "renamed, it needn't find it")
    },
    test("an arrow paints just above the highest shape it's bound to; unbound arrows paint on top") {
        let board = try Board(arrow: 0)
        let c = board.h.add(Box(CGRect(x: 0, y: 600, width: 50, height: 50)))
        let loose = board.h.add(Arrow(start: .free(CGPoint(x: 700, y: 700)), end: .free(CGPoint(x: 800, y: 800))))   // unbound
        expectEqual(board.h.editor.paintOrder().map(\.id), [board.a, board.b, try require(board.arrow), c, loose])
        board.h.editor.transact { $0.bringToFront(board.a) }       // raising A carries nothing; B is still higher
        expectEqual(board.h.editor.paintOrder().map(\.id), [board.b, c, board.a, try require(board.arrow), loose])
    },
    test("in the table of contents an arrow is listed under the shape it starts from, at the top when it starts at none, whatever is selected") {
        let board = try Board(arrow: 0)
        let contents = try require(board.h.editor.tableOfContents)
        let loose = board.h.add(Arrow(start: .free(CGPoint(x: 700, y: 700)), end: .free(CGPoint(x: 800, y: 800))))   // starts free
        board.h.editor.selectedShapeIDs = []
        let entries = contents.entries
        expectEqual(entries.map(\.id), [board.a, board.b, loose])
        expectEqual(entries.first?.children?.map(\.id), [try require(board.arrow)])
        expectEqual(entries.first?.children?.first?.label?.text, "Arrow", "the kind's label")
        expectEqual(entries.first?.children?.first?.symbol, "arrow.up.right")
        board.h.editor.selectedShapeIDs = [try require(board.arrow), board.b]
        expectEqual(contents.entries.map(\.id), [board.a, board.b, loose], "its start not selected, it stays under it")
        expectEqual(contents.entries.first?.children?.map(\.id), [try require(board.arrow)])
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
        let registry = try Registry(plugins: arrowsPlugins())
        let h = EditorHarness { CanvasEditor(registry: registry, document: CanvasDocument(shapes: shapes), scheduler: $0) }
        let elapsed = threadCPUTime {
            for i in 0..<10 { h.move(to: CGPoint(x: 20 + CGFloat(i) * 60, y: 20)) }
        }
        // About 2 ms of this thread's time a move in a debug build (what else runs doesn't count);
        // looking shapes up by scanning made a move about 225 ms.
        expect(elapsed / 10 < .milliseconds(25), "\(elapsed / 10) per move")
    },
    test("an arrow says how wide its line is, 3.5 world units whatever it holds, and a box that it has none") {
        let h = try EditorHarness(plugins: arrowsPlugins())
        let free = Arrow(start: .free(CGPoint(x: 20, y: 60)), end: .free(CGPoint(x: 140, y: 60)), bend: 30, startArrowhead: true, text: "calls")
        // The document is a value: read it after the shapes are added, not before.
        let arrowID = h.add(free), boxID = h.add(Box(boxA))
        let arrow = try require(h.editor.document[arrowID]), box = try require(h.editor.document[boxID])
        expectEqual(h.editor.registry.lineWidth(of: arrow, in: h.editor.shapeContext), 3.5)
        expectEqual(h.editor.registry.lineWidth(of: box, in: h.editor.shapeContext), nil, "a kind that isn't drawn as a line has none")
    },
    test("a tinted outline of an arrow covers it, line and heads, as wide as it's drawn and a point more: 2.75 view points at 50%, 8 at 200%") {
        let tint = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        let tinted = TintedOutlinesBox()
        let h = try EditorHarness(plugins: arrowsPlugins(more: [Contributor(id: "lights") { r in r.outlines { _ in Outlines(tinted: tinted.groups) } }]))
        let id = h.add(Arrow(start: .free(CGPoint(x: 20, y: 60)), end: .free(CGPoint(x: 140, y: 60)), startArrowhead: true, endArrowhead: true))
        tinted.groups = [TintedOutlines(color: tint, shapes: [id])]
        let size = CGSize(width: 320, height: 240)
        for (zoom, wide) in [(0.5, 2.75), (2, 8)] as [(CGFloat, CGFloat)] {
            h.editor.camera = Camera(origin: .zero, zoom: zoom)
            let drawn = renderBitmap(h.editor, size: size)
            // The thickness of the tint across the middle of the body, from how much red is over green in each pixel.
            let column = 80 * zoom
            let thickness = (0..<Int(size.height)).reduce(CGFloat(0)) { total, y in
                let p = pixel(drawn, at: CGPoint(x: column, y: CGFloat(y)))
                return total + CGFloat(p[0] - p[1]) / 255
            }
            expect(abs(thickness - wide) < 0.1, "\(wide) points across the body at \(zoom * 100)%: \(thickness)")
            // None of the arrow's own line or heads shows through the tint, along its length or at its ends.
            var showing = 0
            for y in 0..<Int(size.height) {
                for x in 0..<Int(size.width) {
                    let p = pixel(drawn, at: CGPoint(x: x, y: y))
                    if p[0] < 100 && p[1] < 100 && p[2] < 100 { showing += 1 }
                }
            }
            expectEqual(showing, 0, "no dark pixel of the arrow, at \(zoom * 100)%")
        }
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

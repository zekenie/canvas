import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Keyboard
import Selection
import TableOfContents
import TestKit

// Arrows moved with other shapes follow tldraw's onTranslateStart/onTranslate; a lone arrow is
// pinned by the characterization tests and the POC transcript.
let boxC = CGRect(x: 80, y: 600, width: 100, height: 100)

@MainActor let arrowTranslateTests = Suite("Arrow translation", [
    test("an arrow moved with one of its shapes keeps both bindings (imprecise stays imprecise) and stretches to the other; a free end moves by the delta") {
        let board = try Board(arrow: 0)
        let h = board.h, arrow = try require(board.arrow)
        let loose = h.add(Arrow(start: .bound(ArrowBinding(shapeID: board.a, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false)),
                                end: .free(CGPoint(x: 760, y: 440)), bend: 0))
        let before = h.editor.document[arrow]
        let looseStart = h.editor.document[loose]?.typed(as: Arrow.self)?.props.start
        h.editor.selectedShapeIDs = [board.a, arrow, loose]
        h.press(at: CGPoint(x: 130, y: 130))                              // on A, clear of both arrows
        h.drag(to: CGPoint(x: 130, y: 160)); h.drag(to: CGPoint(x: 150, y: 190))
        h.release()
        expectEqual(h.editor.document[board.a]?.box?.origin, CGPoint(x: 100, y: 140))
        expectEqual(h.editor.document[arrow], before)
        let geometry = try require(h.editor.arrowGeometry(of: arrow))
        expectEqual(geometry.startHandle, CGPoint(x: 200, y: 240))
        expectEqual(geometry.endHandle, boxB.center)
        let moved = try require(h.editor.document[loose]?.typed(as: Arrow.self)?.props)
        expectEqual(moved.start, looseStart)
        expectEqual(moved.end, .free(CGPoint(x: 780, y: 500)))
    },
    test("an arrow moved with both its shapes keeps its record; its geometry shifts exactly by the delta") {
        let board = try Board(arrow: 40)
        let h = board.h, arrow = try require(board.arrow)
        let before = try require(h.editor.document[arrow])
        let geometry = try require(h.editor.arrowGeometry(of: arrow))
        h.editor.selectedShapeIDs = [board.a, board.b, arrow]
        h.press(at: CGPoint(x: 130, y: 130))
        h.drag(to: CGPoint(x: 140, y: 150)); h.drag(to: CGPoint(x: 150, y: 170))
        h.release()
        expectEqual(h.editor.document[arrow], before)
        let delta = CGPoint(x: 20, y: 40)
        let shifted = try require(h.editor.arrowGeometry(of: arrow))
        expectClose(shifted.start, geometry.start + delta, within: 1e-9)
        expectClose(shifted.middle, geometry.middle + delta, within: 1e-9)
        expectClose(shifted.end, geometry.end + delta, within: 1e-9)
    },
    test("an arrow selected with an unrelated box follows the lone-arrow rule, and binds again when moved back over its shape") {
        let lone = try Board(arrow: 0)
        lone.h.add(Box(boxC))
        let board = try Board(arrow: 0)
        let c = board.h.add(Box(boxC))
        let arrow = try require(board.arrow)
        board.h.editor.selectedShapeIDs = [arrow, c]                     // no handles: the press is on the body
        for h in [lone.h, board.h] { h.move(to: CGPoint(x: 364, y: 180)); h.press() }
        expectEqual(board.h.editor.selectedShapeIDs, [arrow, c])
        for point in [CGPoint(x: 364, y: 200), CGPoint(x: 364, y: 520), CGPoint(x: 364, y: 210)] {
            lone.h.drag(to: point)
            board.h.drag(to: point)
            expectEqual(board.arrows, lone.arrows.map { rebound($0, [lone.a: board.a, lone.b: board.b]) })
        }
        lone.h.release(); board.h.release()
        expectEqual(board.arrows.first?.start.binding?.shapeID, board.a)
        expectEqual(board.arrows.first?.start.binding?.isPrecise, true)
        expectEqual(board.arrows.first?.end.binding?.shapeID, board.b)
        expectEqual(board.h.editor.document[c]?.box?.origin, CGPoint(x: 80, y: 630))
    },
    test("an unselected arrow bound to a moving shape keeps its record and follows") {
        let board = try Board(arrow: 0)
        let h = board.h, arrow = try require(board.arrow)
        let c = h.add(Box(boxC))
        let before = h.editor.document[arrow]
        h.editor.selectedShapeIDs = [board.a, c]
        h.press(at: CGPoint(x: 130, y: 130))
        h.drag(to: CGPoint(x: 130, y: 160)); h.drag(to: CGPoint(x: 150, y: 190))
        h.release()
        expectEqual(h.editor.document[arrow], before)
        expectEqual(h.editor.arrowGeometry(of: arrow)?.startHandle, CGPoint(x: 200, y: 240))
    },
    test("a free arrow in a multi-selection moves both ends by the delta, with no begin commit; the bend is unchanged") {
        let h = try EditorHarness(plugins: arrowsPlugins())
        let c = h.add(Box(boxC))
        let arrow = h.add(Arrow(start: .free(CGPoint(x: 700, y: 500)), end: .free(CGPoint(x: 900, y: 560)), bend: 30))
        h.editor.selectedShapeIDs = [arrow, c]
        let revision = h.editor.revision
        h.press(at: CGPoint(x: 130, y: 650))                              // on C
        h.drag(to: CGPoint(x: 140, y: 690))
        expectEqual(h.editor.revision, revision + 1)
        h.drag(to: CGPoint(x: 150, y: 680))
        h.release()
        expectEqual(h.editor.revision, revision + 2)
        expectEqual(h.editor.document[arrow]?.typed(as: Arrow.self)?.props,
                    Arrow(start: .free(CGPoint(x: 720, y: 530)), end: .free(CGPoint(x: 920, y: 590)), bend: 30))
    },
    test("Escape mid arrow translation restores its imprecise bindings; later drags do nothing") {
        let board = try Board(arrow: 0)
        let h = board.h
        let before = board.arrows
        h.move(to: CGPoint(x: 364, y: 180)); h.press()
        h.drag(to: CGPoint(x: 364, y: 200)); h.drag(to: CGPoint(x: 364, y: 520))
        expectEqual(board.arrows.first?.start.binding, nil)
        h.escape()
        expectEqual(board.arrows, before)
        h.drag(to: CGPoint(x: 364, y: 230)); h.release()
        expectEqual(board.arrows, before)
        expectEqual(h.editor.selection, board.arrow)
    },
    test("deleting a selection of one shape and an arrow bound elsewhere: one commit; other arrows' ends freed where they were") {
        let board = try Board(arrow: 0)
        let h = board.h, arrow = try require(board.arrow)
        let c = h.add(Box(boxC))
        let elsewhere = h.add(Arrow(start: .bound(ArrowBinding(shapeID: board.b, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false)),
                                    end: .bound(ArrowBinding(shapeID: c, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false)),
                                    bend: 0))
        let visibleStart = try require(h.editor.arrowGeometry(of: arrow)?.start)
        h.editor.selectedShapeIDs = [board.a, elsewhere]
        let revision = h.editor.revision
        h.editor.deleteSelection()
        expectEqual(h.editor.revision, revision + 1)
        expectEqual(h.editor.document.shapes.map(\.id), [board.b, arrow, c])
        expectEqual(board.arrows.first?.start, .free(visibleStart))
        expectEqual(board.arrows.first?.end.binding?.shapeID, board.b)
        expectEqual(h.editor.selectedShapeIDs, [])
    },
    test("binding hints and handles show only for an only-selected arrow") {
        let board = try Board(arrow: 0)
        let h = board.h, arrow = try require(board.arrow)
        let c = h.add(Box(CGRect(x: 600, y: 600, width: 100, height: 100)))   // the selection box stays right of A
        let size = CGSize(width: 700, height: 300)
        let insideA = CGRect(x: 100, y: 160, width: 170, height: 40)      // the start's hint and handle; the body starts at x 280
        let unselected = renderBitmap(h.editor, size: size)
        h.editor.selection = arrow
        expect(changedPixels(unselected, renderBitmap(h.editor, size: size), in: insideA) > 0, "alone, it shows them")
        h.editor.selectedShapeIDs = [arrow, c]
        let several = renderBitmap(h.editor, size: size)
        expectEqual(changedPixels(unselected, several, in: insideA), 0)
        expect(changedPixels(unselected, several, in: CGRect(x: 290, y: 170, width: 150, height: 20)) > 0, "but it's outlined")
    },
    test("a box moved onto a pocket's board with the arrow bound to it and free at the other end, then put where it lands as Moving's commit does (the box and what rode along): the arrow keeps its free end against the box; undo and redo exact") {
        let a = ShapeRecord(Box(boxA)), pocket = ShapeRecord(Pocket(boxB)), inner = ShapeRecord(Box(boxA))
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(a), AnyShapeRecord(pocket)]),
                              children: [pocket.id: CanvasDocument(shapes: [AnyShapeRecord(inner)])])
        let h = try EditorHarness(plugins: arrowsPlugins(before: [PocketsPlugin()]), file: file)
        let free = CGPoint(x: 400, y: 400), delta = CGPoint(x: 1000, y: 500), there = BoardID(owner: pocket.id)
        let arrow = h.add(Arrow(start: .bound(ArrowBinding(shapeID: a.id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false)),
                                end: .free(free)))
        let before = h.file
        h.editor.transact("Move") { tx in
            expect(tx.move([a.id], to: there))
            expectEqual(tx.rodeAlong, [arrow], "the arrow rode along")
            tx.translate(Set([a.id]).union(tx.rodeAlong), by: delta, on: there)
        }
        expectEqual(h.file.board(containing: arrow), there, "on the box's board")
        expectEqual(h.file.record(a.id)?.box?.origin, boxA.origin + delta, "the box is where it landed")
        let props = try require(h.file.record(arrow)?.typed(as: Arrow.self)?.props)
        expectEqual(props.start.binding?.shapeID, a.id, "bound still")
        expectEqual(props.end, .free(free + delta), "its free end is where it was against the box")
        let after = h.file
        h.editor.undo()
        expectEqual(h.file, before, "undo")
        h.editor.redo()
        expectEqual(h.file, after, "redo")
    },
    test("an arrow bound at both ends to shapes that move rides along bound, nothing of it changed by the translation") {
        let a = ShapeRecord(Box(boxA)), b = ShapeRecord(Box(boxB)), pocket = ShapeRecord(Pocket(boxC))
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(a), AnyShapeRecord(b), AnyShapeRecord(pocket)]))
        let h = try EditorHarness(plugins: arrowsPlugins(before: [PocketsPlugin()]), file: file)
        let there = BoardID(owner: pocket.id)
        let arrow = h.add(Arrow(start: .bound(ArrowBinding(shapeID: a.id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false)),
                                end: .bound(ArrowBinding(shapeID: b.id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false))))
        let bound = h.file.record(arrow)?.typed(as: Arrow.self)?.props
        h.editor.transact("Move") { tx in
            expect(tx.move([a.id, b.id], to: there))
            tx.translate(Set([a.id, b.id]).union(tx.rodeAlong), by: CGPoint(x: 30, y: 40), on: there)
        }
        expectEqual(h.file.board(containing: arrow), there)
        expectEqual(h.file.record(arrow)?.typed(as: Arrow.self)?.props, bound)
    },
])

/// The arrow with its bindings moved to other shapes: the same arrow on another board.
func rebound(_ arrow: Arrow, _ ids: [ShapeID: ShapeID]) -> Arrow {
    var arrow = arrow
    for end in [ArrowEnd.start, .end] {
        guard var binding = arrow[end].binding else { continue }
        binding.shapeID = ids[binding.shapeID] ?? binding.shapeID
        arrow[end] = .bound(binding)
    }
    return arrow
}

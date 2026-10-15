import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Geometry
import TestKit

// The two other ways Moving's commit moves shapes onto a board (`Sources/Moving/Move.swift`: off a board that isn't shown, onto the board
// shown or onto a third), with the real arrow, by the same two calls: `move(_:from:to:)`, then
// `translate(ids ∪ rodeAlong, by:on:)`.

private let home = CGRect(x: 80, y: 120, width: 200, height: 120)
private let far = CGRect(x: 600, y: 120, width: 200, height: 120)

private func bound(_ id: ShapeID) -> ArrowTerminal {
    .bound(ArrowBinding(shapeID: id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false))
}

@MainActor let arrowMovingOntoBoardsTests = Suite("Arrows moved onto a board off one that is not shown", [
    test("a box moved off a pocket's board that isn't shown, onto the board shown and onto a third, with an arrow free at its other end and one between two boxes that move: the free end keeps its place against the box, undo and redo exact") {
        for ontoShown in [true, false] {
            let a = ShapeRecord(Box(home)), b = ShapeRecord(Box(far)), pocket = ShapeRecord(Pocket(home)), other = ShapeRecord(Pocket(far))
            let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(pocket), AnyShapeRecord(other)]),
                                  children: [pocket.id: CanvasDocument(shapes: [AnyShapeRecord(a), AnyShapeRecord(b)])])
            let h = try EditorHarness(plugins: arrowsPlugins(before: [PocketsPlugin()]), file: file)
            let source = BoardID(owner: pocket.id), target = ontoShown ? BoardID.root : BoardID(owner: other.id)
            expect(h.enter(pocket.id))
            let free = CGPoint(x: 400, y: 600), delta = CGPoint(x: 1000, y: 500)
            let dangling = h.add(Arrow(start: bound(a.id), end: .free(free)))
            let between = h.add(Arrow(start: bound(a.id), end: bound(b.id)))
            expect(h.editor.showBoard(.root))
            h.editor.undoHistory.seal()
            let before = h.file, betweenBefore = before.record(between)?.typed(as: Arrow.self)?.props
            let what = ontoShown ? "onto the board shown" : "onto a third board"
            h.editor.transact("Move") { tx in
                expect(tx.move([a.id, b.id], from: source, to: target), what)
                expectEqual(tx.rodeAlong, [dangling, between], "\(what): both arrows rode along")
                tx.translate(Set([a.id, b.id]).union(tx.rodeAlong), by: delta, on: target)
            }
            expectEqual(h.file.board(containing: dangling), target, what)
            expectEqual(h.file.board(containing: between), target, what)
            expectEqual(h.file.record(a.id)?.box?.origin, home.origin + delta, "\(what): the box is where it landed")
            let props = try require(h.file.record(dangling)?.typed(as: Arrow.self)?.props)
            expectEqual(props.start.binding?.shapeID, a.id, "\(what): bound still")
            expectEqual(props.end, .free(free + delta), "\(what): its free end is where it was against the box")
            expectEqual(h.file.record(between)?.typed(as: Arrow.self)?.props, betweenBefore, "\(what): the arrow between the two is as it was")
            let after = h.file
            h.editor.undo()
            expectEqual(h.file, before, "\(what): undo")
            h.editor.redo()
            expectEqual(h.file, after, "\(what): redo")
        }
    },
])

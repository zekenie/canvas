import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import Connections
import CoreGraphics
import Geometry
import TestKit

// A port's drag let go back on the shape it starts from: a loop on the side of the dot it was pulled from, shown as soon as
// the drag comes back onto the shape and kept on the release (Arrows' `ArrowConnections.loop`), in the drag's one step; a
// second loop on a side goes round the first. Types' use of it, a type related to itself, is ReleaseBetweenTypesTests'.

/// Where a loop on A leaves its side and comes back, either side of the side's middle: 28 world units, as a share of A's side.
private let along = 28 / boxA.height

@MainActor let arrowLoopTests = Suite("A port's drag let go on the shape it starts from", [
    test("let go back on A, a drag from A's right dot is a loop on A's right side: both ends on that side, clockwise, bowed out past it, on A's channel; one step, Add Arrow, which one Undo takes back") {
        let board = try PortBoard()
        let h = board.h
        board.connect(to: boxA.center)
        expectEqual(board.arrows.count, 1)
        let loop = try require(board.arrows.first)
        expectEqual(loop.props.start, binding(board.a, CGPoint(x: 1, y: 0.5 - along), precise: true), "leaves above the middle")
        expectEqual(loop.props.end, binding(board.a, CGPoint(x: 1, y: 0.5 + along), precise: true), "comes back below it")
        expectEqual(loop.props.bend, -64)
        expectEqual(loop[ChannelProperty.self], Wire.id)
        let middle = try require(h.editor.arrowGeometry(of: loop.id)).middle
        expect(abs(middle.x - (boxA.maxX + 64)) < 1 && abs(middle.y - boxA.midY) < 1, "out past the right side: \(middle)")
        expectEqual(h.editor.undoHistory.undoName, "Add Arrow")
        h.editor.undo()
        expect(board.arrows.isEmpty)
    },
    test("while the drag is back on A it is the loop, A the target; on to B it starts from A's middle again, straight, and let go there it joins A to B") {
        let board = try PortBoard()
        let h = board.h
        board.connect(to: boxA.center, release: false)
        let shown = try require(board.arrows.first)
        expectEqual(shown.props.start, binding(board.a, CGPoint(x: 1, y: 0.5 - along), precise: true))
        expectEqual(shown.props.bend, -64)
        expectEqual(h.editor.hintedShapeID, board.a)
        h.drag(to: boxB.center, speed: fast)
        let across = try require(board.arrows.first)
        expectEqual(across.props.start, binding(board.a), "from A's middle, as it began")
        expectEqual(across.props.end.binding?.shapeID, board.b)
        expectEqual(across.props.bend, 0)
        expectEqual(h.editor.hintedShapeID, board.b)
        h.drag(to: boxA.center, speed: fast)
        expectEqual(board.arrows.first?.props.bend, -64, "back on A, the loop again")
        h.drag(to: boxB.center, speed: fast)
        h.release()
        expectEqual(board.arrows.count, 1)
        expectEqual(board.arrows.first?.props.start, binding(board.a))
        expectEqual(board.arrows.first?.props.end.binding?.shapeID, board.b)
    },
    test("let go anywhere on A, arrived at slowly or held there past the precise timer, it is the same loop") {
        for (point, speed, wait) in [(boxA.center, slow, 0), (CGPoint(x: 110, y: 250), fast, 400)] as [(CGPoint, CGFloat, Int)] {
            let board = try PortBoard()
            board.connect(to: point, speed: speed, release: false)
            if wait > 0 { board.h.wait(wait) }
            board.h.release()
            let loop = try require(board.arrows.first)
            expectEqual(loop.props.start, binding(board.a, CGPoint(x: 1, y: 0.5 - along), precise: true), "\(point)")
            expectEqual(loop.props.end, binding(board.a, CGPoint(x: 1, y: 0.5 + along), precise: true), "\(point)")
            expectEqual(loop.props.bend, -64, "\(point)")
        }
    },
    test("from A's bottom dot the loop is below A; a second loop on the right goes round the first, and one made once the inner one is deleted takes its place") {
        let board = try PortBoard()
        board.connect(from: aBottomDot, to: boxA.center)
        let below = try require(board.arrows.last)
        expectEqual(below.props.start, binding(board.a, CGPoint(x: 0.5 + along, y: 1), precise: true))
        expectEqual(below.props.end, binding(board.a, CGPoint(x: 0.5 - along, y: 1), precise: true))
        expectEqual(below.props.bend, -64, "the first on its side")
        let middle = try require(board.h.editor.arrowGeometry(of: below.id)).middle
        expect(abs(middle.y - (boxA.maxY + 64)) < 1, "out past the bottom: \(middle)")
        board.connect(to: boxA.center)
        board.connect(to: boxA.center)
        expectEqual(board.arrows.count, 3)
        expectEqual(board.arrows.suffix(2).map(\.props.bend), [-64, -98], "the second round the first")
        expectEqual(board.arrows.last?.props.start, binding(board.a, CGPoint(x: 1, y: 0.5 - 42 / boxA.height), precise: true))
        let inner = board.arrows[1].id
        board.h.editor.transact("Delete") { $0.delete([inner]) }
        board.connect(to: boxA.center)
        expectEqual(board.arrows.last?.props.bend, -64, "the place the deleted one left")
    },
    test("back on A after leaving it for empty canvas, it is the loop again; with ⌘ held over A it binds to nothing, and let go so nothing is drawn") {
        let board = try PortBoard()
        board.connect(to: boxA.center, release: false)
        board.h.drag(to: CGPoint(x: 380, y: 340), speed: fast)
        expectEqual(board.arrows.first?.props.start, binding(board.a), "off A: from its middle")
        expectEqual(board.arrows.first?.props.bend, 0)
        board.h.drag(to: boxA.center, speed: fast)
        board.h.release()
        expectEqual(board.arrows.count, 1)
        expectEqual(board.arrows.first?.props.bend, -64)
        let held = try PortBoard()
        let before = held.h.editor.document
        held.connect(to: boxA.center, release: false)
        held.h.hold(.command)
        expectEqual(held.arrows.first?.props.end.binding, nil, "⌘ binds nothing")
        expectEqual(held.arrows.first?.props.start, binding(held.a), "and it starts from A's middle again")
        held.h.release()
        held.h.hold([])
        expectEqual(held.h.editor.document, before)
    },
    test("Escape while the loop shows, or a release off every shape, leaves nothing") {
        for escapes in [true, false] {
            let board = try PortBoard()
            let before = board.h.editor.document
            board.connect(to: boxA.center, release: false)
            expectEqual(board.arrows.first?.props.bend, -64)
            if escapes {
                board.h.escape()
            } else {
                board.h.drag(to: CGPoint(x: 380, y: 340), speed: fast)
                board.h.release()
            }
            expectEqual(board.h.editor.document, before, "escapes: \(escapes)")
        }
    },
    test("a disc, which takes the pipe and not the wire, is no end for a box's drag: let go on the disc, nothing; the disc's own drag let go back on it is a loop on the pipe") {
        let board = try PortBoard()
        board.connect(to: discC.center)
        expect(board.arrows.isEmpty)
        board.h.move(to: discC.center)
        board.h.move(to: CGPoint(x: discC.maxX + 12, y: discC.midY))
        board.h.press()
        board.h.drag(to: discC.center, speed: fast)
        board.h.release()
        let loop = try require(board.arrows.first)
        expectEqual(loop.props.start.binding?.shapeID, board.c)
        expectEqual(loop.props.end.binding?.shapeID, board.c)
        expectEqual(loop[ChannelProperty.self], Pipe.id)
    },
])

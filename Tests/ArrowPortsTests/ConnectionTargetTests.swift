import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Ports
import Selection
import TestKit

// Where a connection drawn from a port may end: on a shape that takes one of the port's channels,
// looking through any that doesn't, and never on its own shape. Anywhere else, nothing is drawn.

/// A disc over B's top-left, in front of it: (490, 130) is on both.
let discOverB = CGRect(x: 400, y: 60, width: 120, height: 120)
let overBoth = CGPoint(x: 490, y: 130)

@MainActor let connectionTargetTests = Suite("Connection targets", [
    test("the end looks through a shape that doesn't take the channel to the one behind that does") {
        let board = try PortBoard()
        let disc = board.h.add(Disc(discOverB))
        expectEqual(board.h.editor.selectableShape(at: overBoth), disc, "the disc is in front")
        board.connect(to: overBoth, release: false)
        expectEqual(board.arrows.first?.props.end, binding(board.b))
        expectEqual(board.h.editor.hintedShapeID, board.b)
        board.h.release()
        expectEqual(board.arrows.count, 1)
        expectEqual(board.arrows.first?.props.end, binding(board.b))
        expectEqual(board.arrows.first?[ChannelProperty.self], Wire.id)
    },
    test("the end looks through its own shape to one behind it that takes the channel") {
        let board = try PortBoard()
        let behind = board.h.add(Box(CGRect(x: 200, y: 200, width: 200, height: 200)))
        board.h.editor.transact { $0.sendToBack(behind) }
        let overlap = CGPoint(x: 250, y: 250)
        expectEqual(board.h.editor.selectableShape(at: overlap), board.a, "A is in front")
        board.connect(to: overlap, release: false)
        expectEqual(board.h.editor.hintedShapeID, behind)
        board.h.release()
        expectEqual(board.arrows.first?.props.start, binding(board.a))
        expectEqual(board.arrows.first?.props.end, binding(behind))
    },
    test("released on empty canvas, on a shape that doesn't take the channel, or back on its own shape, nothing is drawn") {
        for (place, point) in [("empty canvas", CGPoint(x: 380, y: 500)), ("the disc", discC.center), ("A", CGPoint(x: 150, y: 150))] {
            let board = try PortBoard()
            let before = board.h.editor.document
            board.connect(to: point, release: false)
            expectEqual(board.arrows.first?.props.end, .free(point), place)
            expectEqual(board.h.editor.hintedShapeID, nil, place)
            board.h.release()
            expect(board.arrows.isEmpty, place)
            expectEqual(board.h.editor.document, before, place)
            expect(board.h.editor.session == nil, place)
        }
    },
    test("an end taken to the target and off it again frees it; released there, nothing is drawn") {
        let board = try PortBoard()
        board.connect(to: boxB.center, release: false)
        expectEqual(board.arrows.first?.props.end.binding?.shapeID, board.b)
        board.h.drag(to: CGPoint(x: 380, y: 340), speed: fast)
        expectEqual(board.arrows.first?.props.end, .free(CGPoint(x: 380, y: 340)))
        board.h.release()
        expect(board.arrows.isEmpty)
    },
    test("a shape whose ports on the channel only start connections takes none; one whose ports only take them does") {
        for (role, takes) in [(PortRole.source, false), (.target, true), (.both, true)] {
            let board = try PortBoard(more: [morePorts(Disc.self, on: Wire.self, role: role)])
            board.connect(to: discC.center)
            expectEqual(board.arrows.count, takes ? 1 : 0, "\(role)")
            if takes {
                expectEqual(board.arrows.first?.props.end, binding(board.c), "\(role)")
                expectEqual(board.arrows.first?[ChannelProperty.self], Wire.id, "\(role)")
            }
        }
    },
    test("a port on several channels draws on the first one the target takes") {
        let board = try PortBoard(more: [morePorts(Box.self, on: Pipe.self)])      // A's dots: wire, then pipe
        board.connect(to: discC.center)
        board.connect(to: boxB.center)
        expectEqual(board.arrows.count, 2)
        expectEqual(board.arrows.first { $0.props.end.binding?.shapeID == board.c }?[ChannelProperty.self], Pipe.id)
        expectEqual(board.arrows.first { $0.props.end.binding?.shapeID == board.b }?[ChannelProperty.self], Wire.id)
    },
    test("a connection leaving through the dot it was drawn from hides it (a press there takes the arrow); the shape's other dots still connect") {
        let board = try PortBoard()
        let d = board.h.add(Box(boxD))
        board.connect(to: boxB.center)
        let first = try require(board.arrows.first?.id)
        board.h.move(to: CGPoint(x: 180, y: 180))
        board.h.move(to: aRightDot)
        expectEqual(board.h.editor.button(atViewPoint: aRightDot), nil)
        expectEqual(board.h.editor.selectableShape(at: aRightDot), first)
        board.connect(from: CGPoint(x: 180, y: 292), to: boxD.center)          // A's bottom dot
        expectEqual(board.arrows.count, 2)
        let second = try require(board.arrows.last)
        expectEqual(second.props.start, binding(board.a))
        expectEqual(second.props.end, binding(d))
        expectEqual(second[ChannelProperty.self], Wire.id)
        expectEqual(board.arrow(first)?.props.end, binding(board.b))
    },
    test("a connection from the disc's port ends only on another shape on the pipe") {
        let board = try PortBoard()
        let other = board.h.add(Disc(boxD))
        let discLeftDot = CGPoint(x: 448, y: 500)
        board.h.move(to: discC.center)
        board.h.move(to: discLeftDot)
        board.h.press()
        board.h.drag(to: boxA.center, speed: fast)
        expectEqual(board.arrows.first?.props.end, .free(boxA.center), "a box takes no pipe")
        board.h.drag(to: boxD.center, speed: fast)
        board.h.release()
        expectEqual(board.arrows.count, 1)
        expectEqual(board.arrows.first?.props.start, binding(board.c))
        expectEqual(board.arrows.first?.props.end, binding(other))
        expectEqual(board.arrows.first?[ChannelProperty.self], Pipe.id)
    },
])

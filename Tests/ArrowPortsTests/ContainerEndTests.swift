import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import Connections
import CoreGraphics
import Geometry
import Selection
import TestKit

// Where an end lands on a container (CanvasTesting's paddock, hollow as a frame is: hit only on its
// edge while it holds shapes): anywhere inside it, as tldraw's ends land in frames, what it holds in
// front of it; and never a container and what it holds, either way round (Connections' rule,
// `mayConnect`, which `ArrowPortsPlugin`'s binding rule keeps).

/// A paddock right of B, with ports on the wire, holding a box near its top-left and a disc beside it,
/// its empty inside below them.
let paddockFrame = CGRect(x: 760, y: 80, width: 420, height: 380)
let boxInPaddock = CGRect(x: 800, y: 120, width: 120, height: 120)
let discInPaddock = CGRect(x: 980, y: 120, width: 120, height: 120)
/// In the paddock's empty inside, far from its edge and from what it holds.
let paddockInside = CGPoint(x: 970, y: 380)
/// The box's right dot, and the paddock's, 12 points out from the middle of their sides.
let heldRightDot = CGPoint(x: 932, y: 180), paddockRightDot = CGPoint(x: 1192, y: 270)

@MainActor struct PaddockBoard {
    let board: PortBoard
    let paddock: ShapeID, box: ShapeID, disc: ShapeID

    init() throws {
        board = try PortBoard(more: [PaddocksPlugin(), Contributor(id: "paddock-ports") { $0.ports(Paddock.self, on: Wire.self) }])
        paddock = board.h.add(Paddock(paddockFrame))
        box = board.h.add(Box(boxInPaddock))
        disc = board.h.add(Disc(discInPaddock))
        board.h.editor.put([box, disc], in: paddock)
    }

    var h: EditorHarness { board.h }

    /// Hovers the shape at `body`, presses its dot at `dot` and drags fast to `point`; releases unless told not to.
    func connect(from dot: CGPoint, via body: CGPoint, to point: CGPoint, release: Bool = true) {
        h.move(to: body)
        h.move(to: dot)
        h.press()
        h.drag(to: point, speed: fast)
        if release { h.release() }
    }
}

@MainActor let containerEndTests = Suite("Ends on containers", [
    test("an end let go in a container's empty inside, or on a shape in it that doesn't take its channel, ends on the container, aimed at its middle and stopping at its edge") {
        for (place, point) in [("its empty inside", paddockInside), ("the disc in it, which takes no wire", discInPaddock.center)] {
            let p = try PaddockBoard()
            p.board.connect(to: point, release: false)
            expectEqual(p.h.editor.hintedShapeID, p.paddock, place)
            p.h.release()
            expectEqual(p.board.arrows.map(\.props.end), [binding(p.paddock)], place)
            expectEqual(p.board.arrows.first?[ChannelProperty.self], Wire.id, place)
            let end = try require(p.h.editor.arrowGeometry(of: try require(p.board.arrows.first).id)).end
            expect(end.x < paddockFrame.minX && end.x > paddockFrame.minX - 20, "\(place): it stops short of its left edge, at \(end)")
        }
        let p = try PaddockBoard()
        p.board.connect(to: boxInPaddock.center)
        expectEqual(p.board.arrows.map(\.props.end), [binding(p.box)], "a shape in it that takes the wire is in front of it")
    },
    test("an end never lands on the container that holds the shape it starts on: let go in its empty inside, nothing is drawn") {
        let p = try PaddockBoard()
        let before = p.h.editor.document
        p.connect(from: heldRightDot, via: boxInPaddock.center, to: paddockInside, release: false)
        expectEqual(p.board.arrows.first?.props.end, .free(paddockInside))
        expectEqual(p.h.editor.hintedShapeID, nil)
        p.h.release()
        expectEqual(p.h.editor.document, before)
        // Out to a shape beside it, it binds as ever.
        p.connect(from: heldRightDot, via: boxInPaddock.center, to: CGPoint(x: 560, y: 180))
        expectEqual(p.board.arrows.map { [$0.props.start, $0.props.end] }, [[binding(p.box), binding(p.board.b)]])
    },
    test("an end never lands on a shape inside the container it starts on: let go on one, it is on the container, where it began, and a loop on it") {
        let p = try PaddockBoard()
        p.connect(from: paddockRightDot, via: CGPoint(x: 1180, y: 330), to: boxInPaddock.center)
        expectEqual(p.board.arrows.count, 1)
        let loop = try require(p.board.arrows.first)
        expectEqual(loop.props.start.binding?.shapeID, p.paddock)
        expectEqual(loop.props.end.binding?.shapeID, p.paddock)
        expectEqual(loop.props.bend, -64)
    },
    test("made by name, a container and what it holds are no connection, either way round, on a channel or none; beside it, they are") {
        let p = try PaddockBoard()
        let registry = p.h.editor.registry, shapes = p.h.editor.shapeContext
        for (from, to) in [(p.paddock, p.box), (p.box, p.paddock)] {
            for channel in [Wire.id, nil] {
                expect(registry.connection(ConnectionRequest(from: from, to: to, channel: channel), in: shapes) == nil, "\(from) to \(to) on \(channel?.rawValue ?? "none")")
            }
        }
        expect(registry.connection(ConnectionRequest(from: p.board.a, to: p.paddock, channel: Wire.id), in: shapes) != nil, "A beside it")
        expect(registry.connection(ConnectionRequest(from: p.box, to: p.board.a, channel: Wire.id), in: shapes) != nil, "the box to A")
    },
    test("re-aimed, an end lands on a container anywhere inside it, unless the container holds the arrow's other end") {
        let p = try PaddockBoard()
        let arrow = p.board.addArrow(channel: Wire.id)
        let end = p.h.view(try require(p.h.editor.arrowGeometry(of: arrow)).endHandle)
        p.board.reaim(arrow, from: end, to: paddockInside)
        expectEqual(p.board.arrow(arrow)?.props.end, binding(p.paddock), "A's arrow into it")

        var held = ShapeRecord(Arrow(start: binding(p.box), end: binding(p.board.b)))
        held[ChannelProperty.self] = Wire.id
        p.h.editor.transact { $0.insert(held) }
        let heldEnd = p.h.view(try require(p.h.editor.arrowGeometry(of: held.id)).endHandle)
        p.board.reaim(held.id, from: heldEnd, to: paddockInside)
        expectEqual(p.board.arrow(held.id)?.props.end, .free(paddockInside), "the box's arrow: the paddock holds the box")
    },
    test("an arrow a move nests (its shape put in the container it's bound to) stays bound; moved alone, both its ends let go where it's drawn") {
        let p = try PaddockBoard()
        // A box below the paddock, its arrow up into it; then the box is put in the paddock.
        let below = p.h.add(Box(CGRect(x: 900, y: 560, width: 100, height: 80)))
        var record = ShapeRecord(Arrow(start: binding(below), end: binding(p.paddock)))
        record[ChannelProperty.self] = Wire.id
        p.h.editor.transact { $0.insert(record) }
        p.h.editor.put([below], in: p.paddock)
        expectEqual(p.h.editor.holder(of: below), p.paddock)
        expectEqual(p.board.arrow(record.id).map { [$0.props.start, $0.props.end] }, [binding(below), binding(p.paddock)], "the move lets go of nothing")
        let middle = p.h.view(try require(p.h.editor.arrowGeometry(of: record.id)).middle)
        p.h.move(to: middle)
        p.h.press()
        p.h.drag(to: middle + CGPoint(x: 30, y: 0))
        p.h.release()
        expectEqual(p.board.arrow(record.id)?.props.start.binding, nil)
        expectEqual(p.board.arrow(record.id)?.props.end.binding, nil)
        // A's arrow to B, moved alone, keeps both: nothing nests it.
        let arrow = p.board.addArrow(channel: Wire.id)
        let arrowMiddle = p.h.view(try require(p.h.editor.arrowGeometry(of: arrow)).middle)
        p.h.move(to: arrowMiddle)
        p.h.press()
        p.h.drag(to: arrowMiddle + CGPoint(x: 0, y: 20))
        p.h.release()
        expectEqual(p.board.arrow(arrow)?.props.start.binding?.shapeID, p.board.a)
        expectEqual(p.board.arrow(arrow)?.props.end.binding?.shapeID, p.board.b)
    },
])

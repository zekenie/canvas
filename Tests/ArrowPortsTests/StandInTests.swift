import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import Connections
import CoreGraphics
import Geometry
import Selection
import TestKit
import Topology

// An arrow ends on a shape that stands for others (a reference) by what it stands for now: drawn
// from a port, it ends only on one whose targets take one of the port's channels; re-aimed, an end
// binds only to one whose targets take its channel, in that end's role, and never to one that stands
// for nothing. The resolved edge runs to what the stand-in stands for. Fixtures: relays, which stand
// for the shapes they cite, boxes (wire), discs (pipe) and hubs (a wire that only starts arrows).

private let wireEdge = EdgeTypeID(rawValue: Wire.id.rawValue)

@MainActor private func relayBoard() throws -> PortBoard { try PortBoard(more: [relaysPlugin()]) }

@MainActor let standInArrowTests = Suite("Arrows at a stand-in", [
    test("a drag from a box's port ends on a relay standing for a box, and the arrow is on the wire") {
        let board = try relayBoard()
        let relay = board.addRelay(for: [board.b])
        board.connect(to: boxD.center)
        let arrow = try require(board.arrows.first)
        expectEqual(arrow.props.start, binding(board.a))
        expectEqual(arrow.props.end, binding(relay))
        expectEqual(arrow[ChannelProperty.self], Wire.id)
        let resolved = try require(board.h.editor.topology?.edges(of: board.b, .incoming, types: .only(wireEdge)).first)
        expectEqual(resolved.source, board.a, "drawn into the relay, it reads as into the box it stands for")
        expectEqual(resolved.literalTarget, relay)
        expectEqual(resolved.carrier, arrow.id)
    },
    test("a drag from a box's port released on a relay standing for a disc, for nothing, or for a hub that only starts wires draws nothing") {
        for (what, stands) in [("a disc", { (b: PortBoard) in [b.c] }), ("nothing", { _ in [] }), ("a hub", { _ in [] })] {
            let board = try relayBoard()
            var shapes = stands(board)
            if what == "a hub" { shapes = [board.h.add(Hub(CGRect(x: 800, y: 80, width: 100, height: 100)))] }
            board.addRelay(for: shapes)
            let before = board.h.editor.document
            board.connect(to: boxD.center, release: false)
            expectEqual(board.arrows.first?.props.end, .free(boxD.center), what)
            expectEqual(board.h.editor.hintedShapeID, nil, what)
            board.h.release()
            expect(board.arrows.isEmpty, what)
            expectEqual(board.h.editor.document, before, what)
        }
    },
    test("a drag from a disc's port ends on a relay standing for a disc, and the arrow is on the pipe") {
        let board = try relayBoard()
        let relay = board.addRelay(for: [board.c])
        board.h.move(to: discC.center)
        board.h.move(to: CGPoint(x: discC.minX - 12, y: discC.midY))
        board.h.press()
        board.h.drag(to: boxD.center, speed: fast)
        board.h.release()
        let arrow = try require(board.arrows.first)
        expectEqual(arrow.props.start, binding(board.c))
        expectEqual(arrow.props.end, binding(relay))
        expectEqual(arrow[ChannelProperty.self], Pipe.id)
    },
    test("a drag from a relay's dot starts on what it stands for, and runs from the box it stands for") {
        let board = try relayBoard()
        let relay = board.addRelay(at: boxD, for: [board.b])
        let dotRight = CGPoint(x: boxD.maxX + 12, y: boxD.midY)
        board.h.move(to: boxD.center)
        board.h.move(to: dotRight)
        board.h.press()
        board.h.drag(to: boxB.center, speed: fast)
        board.h.release()
        let arrow = try require(board.arrows.first)
        expectEqual(arrow.props.start, binding(relay))
        expectEqual(arrow.props.end, binding(board.b))
        expectEqual(arrow[ChannelProperty.self], Wire.id)
        let resolved = try require(board.h.editor.topology?.edges(of: board.b, .incoming, types: .only(wireEdge)).first)
        expectEqual(resolved.source, board.b, "its start is the relay, which stands for B: so it's an edge from B to B, as drawn")
        expectEqual(resolved.literalSource, relay)
    },
    test("an arrow's end re-aimed onto a relay standing for a shape that takes its channel binds to it; onto one that stands for nothing, or for what doesn't, it stays free") {
        for (what, stands, binds) in [("a box", { (b: PortBoard) in [b.b] }, true), ("a disc", { b in [b.c] }, false),
                                      ("nothing", { _ in [] }, false), ("a removed box", { b in [b.b] }, false)] {
            let board = try relayBoard()
            let relay = board.addRelay(for: stands(board))
            let arrow = board.addArrow(channel: Wire.id)
            if what == "a removed box" {
                let gone = board.h.add(Box(CGRect(x: 800, y: 400, width: 100, height: 100)))
                board.repoint(relay, to: [gone])
                board.h.editor.transact { $0.delete([gone]) }
            }
            board.reaim(arrow, from: boxB.center, to: boxD.center, release: false)
            expectEqual(board.arrow(arrow)?.props.end, binds ? binding(relay) : .free(boxD.center), what)
            expectEqual(board.h.editor.hintedShapeID, binds ? relay : nil, what)
            board.h.release()
            expectEqual(board.arrow(arrow)?.props.end, binds ? binding(relay) : .free(boxD.center), what)
            expectEqual(board.arrow(arrow)?[ChannelProperty.self], Wire.id, what)
        }
    },
    test("a re-aimed end looks through a relay that doesn't take its channel to the shape behind it that does") {
        let board = try relayBoard()
        let relay = board.addRelay(for: [board.c])
        let behind = board.h.add(Box(boxD))
        board.h.editor.transact { $0.sendToBack(behind) }
        let arrow = board.addArrow(channel: Wire.id)
        expectEqual(board.h.editor.selectableShape(at: boxD.center), relay, "the relay is in front")
        board.reaim(arrow, from: boxB.center, to: boxD.center)
        expectEqual(board.arrow(arrow)?.props.end, binding(behind))
    },
    test("a re-aimed start binds to a relay for what can start the arrow's channel, and an end only to one that can end it") {
        let board = try relayBoard()
        let hub = board.h.add(Hub(CGRect(x: 800, y: 80, width: 100, height: 100)))
        let relay = board.addRelay(for: [hub])
        let arrow = board.addArrow(channel: Wire.id)
        board.reaim(arrow, from: boxB.center, to: boxD.center)
        expectEqual(board.arrow(arrow)?.props.end, .free(boxD.center), "a hub's wire only starts arrows")
        board.reaim(arrow, from: boxA.center, to: boxD.center)
        expectEqual(board.arrow(arrow)?.props.start, binding(relay))
    },
    test("an arrow without a channel, or on one nobody declares, binds wherever an arrow can, a relay standing for nothing too") {
        let board = try relayBoard()
        let relay = board.addRelay()
        let arrow = board.addArrow(channel: nil)
        board.reaim(arrow, from: boxB.center, to: boxD.center)
        expectEqual(board.arrow(arrow)?.props.end, binding(relay))
        let rope = board.addArrow(channel: "rope")
        board.reaim(rope, from: boxB.center, to: boxD.center)
        expectEqual(board.arrow(rope)?.props.end, binding(relay))
    },
    test("an arrow already bound keeps its binding and its channel when the relay is re-pointed to what doesn't take it") {
        let board = try relayBoard()
        let relay = board.addRelay(for: [board.b])
        board.connect(to: boxD.center)
        let arrow = try require(board.arrows.first?.id)
        board.repoint(relay, to: [board.c])
        expectEqual(board.arrow(arrow)?.props.end, binding(relay), "arrows never let go because what they bind to changed")
        expectEqual(board.arrow(arrow)?[ChannelProperty.self], Wire.id)
        expectEqual(board.h.editor.topology?.edges(of: board.c, .incoming, types: .only(wireEdge)).map(\.source), [board.a], "the edge follows what it stands for")
        board.repoint(relay, to: [])
        expectEqual(board.arrow(arrow)?.props.end, binding(relay))
        expectEqual(board.h.editor.topology?.edges(of: relay, .incoming, types: .only(wireEdge)).map(\.source), [board.a], "stands for nothing: into the relay")
    },
    test("an arrow bound to a relay, moved alone, keeps both ends bound, as it does to a box") {
        let board = try relayBoard()
        let relay = board.addRelay(for: [board.b])
        board.connect(to: boxD.center)
        let arrow = try require(board.arrows.first?.id)
        board.h.move(to: CGPoint(x: 180, y: 340))
        board.h.press()
        board.h.drag(to: CGPoint(x: 190, y: 340))
        board.h.drag(to: CGPoint(x: 210, y: 340))
        board.h.release()
        expectEqual(board.arrow(arrow)?.props.start, binding(board.a, CGPoint(x: 0.65, y: 0.5), precise: true))
        expectEqual(board.arrow(arrow)?.props.end, binding(relay, CGPoint(x: 0.65, y: 0.5), precise: true))
        expectEqual(board.arrow(arrow)?[ChannelProperty.self], Wire.id)
    },
])

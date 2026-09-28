import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Ports
import Selection
import TestKit

// Rules for arrows already drawn: an arrow on a channel some plugin declares binds, at each end,
// only to shapes that take it there (its start to one that can start one, its end to one that can
// end one), looking through the rest, re-aimed or moved; one without a channel (`canvas draw`'s
// `channel: none`), or on a channel nobody declares, binds wherever an arrow can.

/// A disc over B's center, in front of it: where a connection's end, moved down 30, lands.
let discOverBCenter = CGRect(x: 500, y: 140, width: 120, height: 120)

@MainActor let drawnArrowTests = Suite("Arrows already drawn", [
    test("a connection's end re-aimed over a shape that doesn't take its channel stays free there") {
        let board = try PortBoard()
        board.connect(to: boxB.center)
        let arrow = try require(board.arrows.first?.id)
        board.reaim(arrow, from: boxB.center, to: discC.center, release: false)
        expectEqual(board.arrow(arrow)?.props.end, .free(discC.center))
        expectEqual(board.h.editor.hintedShapeID, nil)
        board.h.release()
        expectEqual(board.arrow(arrow)?.props.end, .free(discC.center))
        expectEqual(board.arrow(arrow)?[ChannelProperty.self], Wire.id)
    },
    test("a connection's end re-aimed over another shape that takes its channel binds to it") {
        let board = try PortBoard()
        let d = board.h.add(Box(boxD))
        board.connect(to: boxB.center)
        let arrow = try require(board.arrows.first?.id)
        board.reaim(arrow, from: boxB.center, to: boxD.center, release: false)
        expectEqual(board.h.editor.hintedShapeID, d)
        board.h.release()
        expectEqual(board.arrow(arrow)?.props.end, binding(d))
        expectEqual(board.arrow(arrow)?.props.start, binding(board.a))
    },
    test("a connection's end re-aimed over a shape in front of one that takes its channel binds to the one behind") {
        let board = try PortBoard()
        let arrow = board.addArrow(channel: Wire.id)
        let d = board.h.add(Box(boxD))
        board.h.add(Disc(CGRect(x: 120, y: 440, width: 120, height: 120)))           // over D's center
        board.reaim(arrow, from: boxB.center, to: boxD.center)
        expectEqual(board.arrow(arrow)?.props.end, binding(d))
    },
    test("a connection's end held still over a shape in front that doesn't take its channel binds precisely to the one behind") {
        let board = try PortBoard()
        let arrow = board.addArrow(channel: Wire.id)
        board.h.add(Disc(discOverBCenter))
        board.reaim(arrow, from: boxB.center, to: CGPoint(x: 590, y: 200), release: false)
        expectEqual(board.arrow(arrow)?.props.end, binding(board.b))
        board.h.wait(400)
        board.h.release()
        expectEqual(board.arrow(arrow)?.props.end, binding(board.b, CGPoint(x: 0.65, y: 0.6), precise: true))
    },
    test("a connection's end re-aimed with ⌘ held over a shape in front binds to the one behind 150 ms after letting go") {
        let board = try PortBoard()
        let arrow = board.addArrow(channel: Wire.id)
        board.h.add(Disc(discOverBCenter))
        board.h.editor.selection = arrow
        board.h.move(to: boxB.center)
        board.h.press()
        board.h.hold(.command)
        board.h.drag(to: CGPoint(x: 590, y: 200), speed: fast)
        expectEqual(board.arrow(arrow)?.props.end, .free(CGPoint(x: 590, y: 200)))
        board.h.hold([])
        board.h.wait(150)
        expectEqual(board.arrow(arrow)?.props.end.binding?.shapeID, board.b)
        expectEqual(board.h.editor.hintedShapeID, board.b)
        board.h.release()
        expectEqual(board.arrow(arrow)?.props.end.binding?.shapeID, board.b)
    },
    test("a connection's start re-aimed binds only to a shape that can start one") {
        // Discs take the wire, but only as where a connection ends.
        let board = try PortBoard(more: [morePorts(Disc.self, on: Wire.self, role: .target)])
        let d = board.h.add(Box(boxD))
        board.connect(to: boxB.center)
        let arrow = try require(board.arrows.first?.id)
        board.reaim(arrow, from: boxA.center, to: discC.center)
        expectEqual(board.arrow(arrow)?.props.start, .free(discC.center))
        board.reaim(arrow, from: discC.center, to: boxD.center)
        expectEqual(board.arrow(arrow)?.props.start, binding(d))
        expectEqual(board.arrow(arrow)?.props.end, binding(board.b))
    },
    test("a connection's end re-aimed binds only to a shape that can end one") {
        for (role, binds) in [(PortRole.target, true), (.source, false)] {
            let board = try PortBoard(more: [morePorts(Disc.self, on: Wire.self, role: role)])
            let arrow = board.addArrow(channel: Wire.id)
            board.reaim(arrow, from: boxB.center, to: discC.center)
            expectEqual(board.arrow(arrow)?.props.end, binds ? binding(board.c) : .free(discC.center), "\(role)")
        }
    },
    test("a connection's start re-aimed onto a shape whose ports only start connections binds to it") {
        let board = try PortBoard(more: [morePorts(Disc.self, on: Wire.self, role: .source)])
        let arrow = board.addArrow(channel: Wire.id)
        board.reaim(arrow, from: boxA.center, to: discC.center)
        expectEqual(board.arrow(arrow)?.props.start, binding(board.c))
    },
    test("a connection moved alone keeps its end bound through a shape in front that doesn't take its channel; an arrow without one lets go") {
        for channel in [Wire.id, nil] {
            let board = try PortBoard()
            let arrow = board.addArrow(channel: channel)
            board.h.add(Disc(discOverBCenter))
            board.h.move(to: CGPoint(x: 364, y: 180))                                    // on its body
            board.h.press()
            board.h.drag(to: CGPoint(x: 364, y: 200))
            board.h.drag(to: CGPoint(x: 364, y: 210))
            board.h.release()
            let moved = try require(board.arrow(arrow))
            expectEqual(moved.props.start, binding(board.a, CGPoint(x: 0.5, y: 0.65), precise: true), "\(String(describing: channel))")
            expectEqual(moved.props.end, channel == nil ? .free(CGPoint(x: 560, y: 210)) : binding(board.b, CGPoint(x: 0.5, y: 0.65), precise: true),
                        "\(String(describing: channel))")
            expectEqual(moved[ChannelProperty.self], channel)
        }
    },
    test("an arrow without a channel, re-aimed, binds to the shape in front") {
        let board = try PortBoard()
        let disc = board.h.add(Disc(discOverB))
        let arrow = board.addArrow(channel: nil)
        board.reaim(arrow, from: boxB.center, to: CGPoint(x: 490, y: 130))
        expectEqual(board.arrow(arrow)?.props.end, binding(disc))
        expectEqual(board.arrow(arrow)?[ChannelProperty.self], nil)
    },
    test("an arrow without a channel re-aimed binds to any shape") {
        let board = try PortBoard()
        let arrow = board.addArrow(channel: nil)
        board.reaim(arrow, from: boxB.center, to: discC.center)
        expectEqual(board.arrow(arrow)?.props.end, binding(board.c))
        board.reaim(arrow, from: boxA.center, to: discC.center)
        expectEqual(board.arrow(arrow)?.props.start.binding?.shapeID, board.c)
    },
    test("an arrow on a channel no installed plugin declares binds to any shape, at either end") {
        let board = try PortBoard()
        let arrow = board.addArrow(channel: "retired")
        expectEqual(board.arrow(arrow)?[ChannelProperty.self], "retired")
        board.reaim(arrow, from: boxB.center, to: discC.center)
        expectEqual(board.arrow(arrow)?.props.end, binding(board.c))
        let d = board.h.add(Disc(boxD))
        board.reaim(arrow, from: boxA.center, to: boxD.center)
        expectEqual(board.arrow(arrow)?.props.start, binding(d))
    },
])

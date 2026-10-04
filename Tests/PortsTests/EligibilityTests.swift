import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Connections
import CoreGraphics
import Geometry
import Keyboard
import Selection
import TestKit
import Topology

// Where a connection drawn from a port may end: on a shape whose kind takes one of its channels
// (`editor.channel(of:endingAt:)`), which the overlay outlines faintly while it's drawn. The box
// at `boxFrame` starts it, from its right dot; two more boxes, above and below on the right, could
// take it, and a disc, below the first box, takes only the pipe.

let aboveFrame = CGRect(x: 400, y: 40, width: 150, height: 80)
let belowFrame = CGRect(x: 400, y: 260, width: 150, height: 80)
let discFrame = CGRect(x: 100, y: 260, width: 150, height: 80)
/// Where the connections here are dragged to: empty canvas.
let openSpace = CGPoint(x: 350, y: 210)
/// Across the top of the disc's outline.
let discTop = CGRect(x: discFrame.midX - 15, y: discFrame.minY - 3, width: 30, height: 6)

/// The board, with the test connector.
@MainActor struct EligibilityBoard {
    let h: EditorHarness
    let connections: ConnectionLog
    let start: ShapeID
    let above: ShapeID
    let below: ShapeID
    let disc: ShapeID

    init(_ connections: ConnectionLog = ConnectionLog(), boxRole: PortRole = .both, plugins: [any CanvasPlugin]? = nil) throws {
        self.connections = connections
        if let plugins {
            h = try EditorHarness(plugins: plugins)
        } else {
            h = try portsHarness(connections, boxRole: boxRole)
        }
        start = h.add(Box(boxFrame))
        above = h.add(Box(aboveFrame))
        below = h.add(Box(belowFrame))
        disc = h.add(Disc(discFrame))
    }

    /// The channel `connection` would be drawn on, ended at `id`.
    func channel(_ connection: Connection, endingAt id: ShapeID) throws -> ChannelID? {
        h.editor.channel(of: connection, endingAt: try require(h.editor.document[id]))
    }

    /// Drags from the first box's right dot to open space, and holds it there.
    func startConnecting() throws -> Connection {
        h.connect(from: rightDot, to: openSpace, releasing: false)
        return try require(connections.begun.last)
    }
}

@MainActor let eligibilityTests = Suite("Where a connection may end", [
    test("a connection may end on a shape whose kind takes one of its channels, never where it starts, nor on a connection") {
        let board = try EligibilityBoard()
        let tag = board.h.add(Tag())
        let connection = try board.startConnecting()
        expectEqual(try board.channel(connection, endingAt: board.start), nil, "where it starts")
        expectEqual(try board.channel(connection, endingAt: board.above), Wire.id)
        expectEqual(try board.channel(connection, endingAt: board.below), Wire.id)
        expectEqual(try board.channel(connection, endingAt: board.disc), nil, "discs take the pipe")
        expectEqual(try board.channel(connection, endingAt: tag), nil)
    },
    test("a kind whose ports only start connections takes none") {
        let board = try EligibilityBoard(boxRole: .source)
        let connection = try board.startConnecting()
        expectEqual(try board.channel(connection, endingAt: board.above), nil)
    },
    test("ports that only take connections take them, but give the kind no dot on their channel") {
        let wiredDiscs = Contributor(id: "wired-discs") { $0.ports(Disc.self, on: Wire.self, role: .target) }
        let connections = ConnectionLog()
        let board = try EligibilityBoard(connections, plugins: [KeyboardPlugin(), SelectionPlugin(), TopologyPlugin(), FixturesPlugin(), PortsPlugin(),
                                                                channelsPlugin(), connectorPlugin(connections), wiredDiscs])
        let connection = try board.startConnecting()
        expectEqual(try board.channel(connection, endingAt: board.disc), Wire.id)
        board.h.release()
        let discRightDot = CGPoint(x: discFrame.maxX + 12, y: discFrame.midY)
        board.h.connect(from: discRightDot, to: CGPoint(x: 330, y: 380), via: CGPoint(x: discFrame.midX, y: discFrame.midY))
        let fromDisc = try require(connections.begun.last)
        expectEqual(fromDisc.shape, board.disc)
        expectEqual(fromDisc.channels, [Pipe.id])
    },
    test("a shape the board keeps aside takes nothing, whatever its kind") {
        let connections = ConnectionLog()
        let (h, kept) = try harnessKeepingABoxAside(connections)
        h.add(Box(boxFrame))
        let other = h.add(Box(aboveFrame))
        h.connect(from: rightDot, to: openSpace, releasing: false)
        let connection = try require(connections.begun.first)
        expectEqual(h.editor.channel(of: connection, endingAt: try require(h.editor.document[kept])), nil)
        expectEqual(h.editor.channel(of: connection, endingAt: try require(h.editor.document[other])), Wire.id)
    },
    test("a side with ports on two channels begins connections on both, in plugin order, each drawn on the first its end takes") {
        let pipedBoxes = Contributor(id: "piped-boxes") { $0.ports(Box.self, on: Pipe.self, sides: [.right]) }
        let connections = ConnectionLog()
        let board = try EligibilityBoard(connections, plugins: [KeyboardPlugin(), SelectionPlugin(), TopologyPlugin(), FixturesPlugin(), PortsPlugin(),
                                                                channelsPlugin(), connectorPlugin(connections), pipedBoxes])
        let plain = render(board.h)
        let right = try board.startConnecting()
        expectEqual(right.channels, [Wire.id, Pipe.id])
        expectEqual(try board.channel(right, endingAt: board.above), Wire.id, "boxes take both: the first")
        expectEqual(try board.channel(right, endingAt: board.disc), Pipe.id)
        expect(changedPixels(plain, render(board.h), in: discTop) > 20, "so the disc's outlined")
        board.h.release()
        board.h.connect(from: leftDot, to: CGPoint(x: 40, y: 150))
        let left = try require(connections.begun.last)
        expectEqual(left.channels, [Wire.id], "the other sides are on the wire alone")
        expectEqual(try board.channel(left, endingAt: board.disc), nil)
    },
    test("plugin order decides which channel comes first: ports on the pipe given before the wire's put it first") {
        let pipesFirst = Contributor(id: "pipes-first") { $0.ports(Box.self, on: Pipe.self, sides: [.right]) }
        let connections = ConnectionLog()
        let board = try EligibilityBoard(connections, plugins: [KeyboardPlugin(), SelectionPlugin(), TopologyPlugin(), FixturesPlugin(), PortsPlugin(),
                                                                pipesFirst, channelsPlugin(), connectorPlugin(connections)])
        let right = try board.startConnecting()
        expectEqual(right.channels, [Pipe.id, Wire.id])
        expectEqual(try board.channel(right, endingAt: board.above), Pipe.id)
    },
    test("while a connection is drawn, each shape it could end on is outlined faintly, as a hovered shape is; no other, and not once it ends") {
        let board = try EligibilityBoard()
        let h = board.h
        let plain = render(h)
        h.move(to: CGPoint(x: belowFrame.midX, y: belowFrame.midY))
        let belowHovered = render(h)
        _ = try board.startConnecting()
        let drawing = render(h)
        expect(changedPixels(plain, drawing, in: topEdge(of: belowFrame)) > 100, "a box below")
        expectEqual(changedPixels(belowHovered, drawing, in: topEdge(of: belowFrame)), 0, "as a hover's outline")
        expect(changedPixels(plain, drawing, in: topEdge(of: aboveFrame)) > 100, "a box above")
        expectEqual(changedPixels(plain, drawing, in: discTop), 0, "not the disc: it takes the pipe")
        expectEqual(changedPixels(plain, drawing, in: topEdge(of: boxFrame)), 0, "not where it starts")
        h.release()
        let ended = render(h)
        expectEqual(changedPixels(plain, ended, in: topEdge(of: belowFrame)), 0)
        expectEqual(changedPixels(plain, ended, in: topEdge(of: aboveFrame)), 0)
    },
    test("a shape drawn away from where it is (a locked shape's shake) is outlined where it's drawn, as its hover would be") {
        let board = try EligibilityBoard()
        let h = board.h
        h.editor.setDrawingOffset(CGPoint(x: 0, y: 6), for: board.below)
        let still = render(h)
        h.move(to: CGPoint(x: belowFrame.midX, y: belowFrame.midY))
        let belowHovered = render(h)
        _ = try board.startConnecting()
        let drawing = render(h)
        let shaken = topEdge(of: belowFrame.offsetBy(dx: 0, dy: 6))
        expect(changedPixels(still, drawing, in: shaken) > 100, "outlined")
        expectEqual(changedPixels(belowHovered, drawing, in: shaken), 0, "where its hover's outline is")
    },
    test("the shape the connection would end on now has the hint's outline alone, not the faint one as well") {
        let board = try EligibilityBoard()
        let h = board.h
        _ = try board.startConnecting()
        h.editor.hintedShapeID = board.above
        let drawing = render(h)
        h.release()
        h.editor.hintedShapeID = board.above
        let hintAlone = render(h)
        expectEqual(changedPixels(hintAlone, drawing, in: topEdge(of: aboveFrame)), 0, "the hinted box")
        expect(changedPixels(hintAlone, drawing, in: topEdge(of: belowFrame)) > 100, "the other box, faintly")
    },
    test("a shape the connector can't connect to isn't outlined, nor one whose kind only starts connections") {
        let connections = ConnectionLog()
        let board = try EligibilityBoard(connections)
        connections.canConnect = { $0 != board.below }
        let plain = render(board.h)
        _ = try board.startConnecting()
        let drawing = render(board.h)
        expectEqual(changedPixels(plain, drawing, in: topEdge(of: belowFrame)), 0, "the connector says no")
        expect(changedPixels(plain, drawing, in: topEdge(of: aboveFrame)) > 100)

        let sources = try EligibilityBoard(boxRole: .source)
        let before = render(sources.h)
        _ = try sources.startConnecting()
        expectEqual(changedPixels(before, render(sources.h), in: topEdge(of: aboveFrame)), 0, "sources only")
    },
])

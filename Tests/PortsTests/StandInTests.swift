import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Connections
import CoreGraphics
import Geometry
import Selection
import TestKit

// A kind may have ports on every channel (`portsOnEveryChannel`), and a shape that stands for others
// (Topology's stand-ins) has the ports of what it stands for, instance by instance: one kind, that
// kind's channels and roles on its own sides; several, the channels every kind takes with the roles
// all allow, in the order of the first; none, none, so no dots show and no connection ends there. A
// box (wire, all sides) and a disc (pipe) are what a relay stands for here; a hub's wire only starts
// connections, and a junction has the pipe first and then every channel.

private let boxEnd = CGPoint(x: farBox.maxX + 12, y: farBox.midY)       // the far box's right dot
private let farMiddle = CGPoint(x: farBox.midX, y: farBox.midY)

@MainActor let standInPortTests = Suite("Ports at a stand-in", [
    test("a kind with ports on every channel has them on each channel the registry declares, in plugin order, on its sides") {
        let registry = try relayHarness().editor.registry
        expectEqual(registry.portChannels(of: Relay.kind), [Wire.id, Pipe.id])
        expectEqual(registry.portSides(of: Relay.kind, on: Wire.id, as: .both), [.left, .right])
        expectEqual(registry.portSides(of: Relay.kind, on: Pipe.id, as: .both), [.left, .right])
        expectEqual(registry.dotChannels(of: Relay.kind, side: .left), [Wire.id, Pipe.id])
        expectEqual(registry.dotChannels(of: Relay.kind, side: .top), [])
        let relay = AnyShapeRecord(ShapeRecord(Relay(boxFrame)))
        for channel in [Wire.id, Pipe.id] {
            expect(registry.accepts(relay, on: channel, as: .target), "\(channel): a translated arrow keeps its end at one, whatever it stands for")
            expect(registry.accepts(relay, on: channel, as: .source))
        }
        expectEqual(registry.connectionChannel(from: Box.kind, to: Relay.kind), Wire.id, "a script's edge picks as a drag does, by kind")
        expectEqual(registry.connectionChannel(from: Disc.kind, to: Relay.kind), Pipe.id)
        expectEqual(reportLine(registry, "relays"), "shape relay · ports on every channel → relay · stands in → relay · shape hub · ports wire → hub · ports pipe → hub")
    },
    test("the registry's lookups answer for a stand-in by the kinds of what it stands for, as a shape's ports do: the channels they all take, with the roles all allow, on the stand-in's own sides") {
        let registry = try relayHarness().editor.registry
        // One kind: its channels, on the relay's own sides.
        expectEqual(registry.portChannels(of: Relay.kind, standingFor: [Box.kind]), [Wire.id])
        expectEqual(registry.portChannels(of: Relay.kind, standingFor: [Disc.kind]), [Pipe.id])
        expectEqual(registry.portSides(of: Relay.kind, standingFor: [Box.kind], on: Wire.id, as: .target), [.left, .right])
        expectEqual(registry.portSides(of: Relay.kind, standingFor: [Box.kind], on: Pipe.id, as: .target), [], "a box has no pipe")
        expectEqual(registry.portSides(of: Relay.kind, standingFor: [Box.kind]), [.left, .right], "on any channel: where it takes connections at all")
        expectEqual(registry.portSides(of: Relay.kind), [.left, .right], "its own, standing for nothing")
        expect(registry.takes(Relay.kind, standingFor: [Box.kind], Wire.id, as: .target, side: .left))
        expect(!registry.takes(Relay.kind, standingFor: [Box.kind], Wire.id, as: .target, side: .top), "none on its top, whatever a box has")
        expect(!registry.takes(Relay.kind, standingFor: [Box.kind], Pipe.id, as: .target))
        expectEqual(registry.dotChannels(of: Relay.kind, standingFor: [Disc.kind], side: .right), [Pipe.id])
        expectEqual(registry.dotChannels(of: Relay.kind, standingFor: [Disc.kind], side: .top), [])
        // A hub's wire only starts connections: so does a stand-in for one.
        expect(registry.takes(Relay.kind, standingFor: [Hub.kind], Wire.id, as: .source))
        expect(!registry.takes(Relay.kind, standingFor: [Hub.kind], Wire.id, as: .target))
        expectEqual(registry.dotChannels(of: Relay.kind, standingFor: [Hub.kind]), [Wire.id, Pipe.id])
        // Several kinds: the channels all take. A box and a disc share none.
        expectEqual(registry.portChannels(of: Relay.kind, standingFor: [Box.kind, Hub.kind]), [Wire.id])
        expectEqual(registry.portChannels(of: Relay.kind, standingFor: [Box.kind, Disc.kind]), [])
        expect(!registry.hasPorts(Relay.kind, standingFor: [Box.kind, Disc.kind]))
        expectEqual(registry.portSides(of: Relay.kind, standingFor: [Box.kind, Disc.kind]), [])
        expect(registry.hasPorts(Relay.kind, standingFor: [Box.kind]))
        // A connection by name is on the channel a drag from the port would find, with a stand-in at either end.
        expectEqual(registry.connectionChannel(from: Box.kind, to: Relay.kind, toStandingFor: [Box.kind]), Wire.id)
        expectEqual(registry.connectionChannel(from: Box.kind, to: Relay.kind, toStandingFor: [Disc.kind]), nil)
        expectEqual(registry.connectionChannel(from: Disc.kind, to: Relay.kind, toStandingFor: [Disc.kind]), Pipe.id)
        expectEqual(registry.connectionChannel(from: Relay.kind, fromStandingFor: [Box.kind], to: Box.kind), Wire.id)
        expectEqual(registry.connectionChannel(from: Relay.kind, fromStandingFor: [Disc.kind], to: Box.kind), nil)
        expectEqual(registry.connectionChannel(from: Relay.kind, fromSide: .left, fromStandingFor: [Box.kind], to: Box.kind, toSide: .top), Wire.id, "a box has a port on its top")
        expectEqual(registry.connectionChannel(from: Box.kind, to: Relay.kind, toSide: .top, toStandingFor: [Box.kind]), nil, "a relay has none")
        expectEqual(registry.connectionChannel(from: Box.kind, fromSide: .top, to: Relay.kind, toSide: .left, toStandingFor: [Box.kind]), Wire.id)
    },
    test("a channel the kind was given ports on first keeps them; the expansion fills in the others, and a role comes with it") {
        let own = Contributor(id: "own") { $0.ports(Relay.self, on: Wire.self, sides: [.top], role: .source) }
        let h = try portsHarness(more: [own, relaysPlugin(role: .target)])
        let registry = h.editor.registry
        expectEqual(registry.portChannels(of: Relay.kind), [Wire.id, Pipe.id])
        expectEqual(registry.portSides(of: Relay.kind, on: Wire.id, as: .source), [.top])
        expectEqual(registry.portSides(of: Relay.kind, on: Wire.id, as: .target), [], "its own role on the wire")
        expectEqual(registry.portSides(of: Relay.kind, on: Pipe.id, as: .target), [.left, .right])
        expectEqual(registry.dotChannels(of: Relay.kind), [Wire.id], "the pipe's ports only take connections: no dot")
    },
    test("ports on every channel are given once, and not to the connector's own kind") {
        let again = Contributor(id: "again") { $0.portsOnEveryChannel(Relay.self) }
        expectThrows(RegistryError.conflict(point: "ShapePorts", key: "relay's ports on every channel", plugins: ["relays", "again"])) {
            _ = try portsHarness(more: [relaysPlugin(), again])
        }
        let tags = Contributor(id: "tag-ports") { $0.portsOnEveryChannel(Tag.self) }
        expectThrows(RegistryError.invalid(point: "ShapePorts", reason: "tag-ports gives tag ports, but it's what connections are")) {
            _ = try portsHarness(more: [tags])
        }
    },
    test("a stand-in for a box shows its dots on its own left and right, and none on the sides it has no ports on") {
        let h = try relayHarness()
        let box = h.add(Box(farBox))
        h.add(Relay(boxFrame, stands: [box]))
        let plain = render(h)
        h.move(to: boxMiddle)
        let hovered = render(h)
        expectEqual(dotPixels(plain, hovered, at: leftDot), 16)
        expectEqual(dotPixels(plain, hovered, at: rightDot), 16)
        expectEqual(dotPixels(plain, hovered, at: topDot), 0)
        expectEqual(dotPixels(plain, hovered, at: bottomDot), 0)
    },
    test("a drag from its dot starts on the channels of what it stands for: a box's wire, a disc's pipe") {
        let connections = ConnectionLog()
        let h = try relayHarness(connections)
        let box = h.add(Box(farBox)), disc = h.add(Disc(farBox))
        let relay = h.add(Relay(boxFrame, stands: [box]))
        h.connect(from: rightDot, to: rightDot + CGPoint(x: 30, y: 0))
        expectEqual(connections.begun.last?.channels, [Wire.id])
        expectEqual(connections.begun.last?.shape, relay)
        h.repoint(relay, to: [disc])
        h.connect(from: leftDot, to: leftDot - CGPoint(x: 30, y: 0))
        expectEqual(connections.begun.last?.channels, [Pipe.id], "re-pointed, its dots follow in that commit")
        expectEqual(connections.begun.count, 2)
    },
    test("a stand-in for nothing has no dots and nothing ends on it: empty, missing, or removed") {
        let connections = ConnectionLog()
        let h = try relayHarness(connections)
        let box = h.add(Box(farBox))
        let relay = h.add(Relay(boxFrame))
        let from = try h.beginConnection(connections, from: boxEnd, via: farMiddle)
        let plain = render(h)
        h.move(to: boxMiddle)
        let hovered = render(h)
        for (side, center) in boxDots { expectEqual(dotPixels(plain, hovered, at: center), 0, "empty: \(side)") }
        h.move(to: rightDot)
        expectEqual(h.editor.hoveredButton, nil)
        expectEqual(h.editor.channel(of: from, endingAt: try require(h.editor.document[relay])), nil, "empty")
        h.repoint(relay, to: [box])
        expectEqual(h.editor.channel(of: from, endingAt: try require(h.editor.document[relay])), Wire.id, "standing for the box it starts at: it takes it")
        expectEqual(h.editor.channel(of: from, endingAt: try require(h.editor.document[box])), Wire.id, "and so does where it starts")
        let other = h.add(Box(CGRect(x: 400, y: 400, width: 100, height: 100)))
        h.repoint(relay, to: [other])
        expectEqual(h.editor.channel(of: from, endingAt: try require(h.editor.document[relay])), Wire.id)
        h.editor.transact { $0.delete([other]) }
        expectEqual(h.editor.channel(of: from, endingAt: try require(h.editor.document[relay])), nil, "what it stood for is gone")
        h.editor.undo()
        expectEqual(h.editor.channel(of: from, endingAt: try require(h.editor.document[relay])), Wire.id, "and back")
    },
    test("a stand-in's kept ports go with it: deleted here, deleted with a board that isn't shown, and with a file put in place; a move keeps them") {
        let h = try portsHarness(more: [relaysPlugin(), PocketsPlugin()])
        let box = h.add(Box(farBox))
        let relay = h.add(Relay(boxFrame, stands: [box]))
        expectEqual(h.editor.standingPortsKept, 0, "none asked of yet")
        h.move(to: boxMiddle)
        expectEqual(h.editor.standingPortsKept, 1, "asked of once its dots were wanted")
        h.editor.transact { $0.translate([relay], by: CGPoint(x: 1, y: 0)) }
        expectEqual(h.editor.standingPortsKept, 1, "a move changes nothing it stands for")
        h.editor.transact { $0.delete([relay]) }
        expectEqual(h.editor.standingPortsKept, 0, "deleted on the board shown")
        h.editor.undo()
        h.move(to: CGPoint(x: 301, y: 150))
        expectEqual(h.editor.standingPortsKept, 1, "back with its undo, asked of again")

        // A stand-in on a board that isn't shown, taken with its board.
        let pocket = h.add(Pocket(CGRect(x: 600, y: 500, width: 50, height: 50)))
        expect(h.enter(pocket))
        let inner = h.add(Box(farBox))
        h.add(Relay(boxFrame, stands: [inner]))
        h.move(to: boxMiddle)
        expectEqual(h.editor.standingPortsKept, 2, "the pocket's board's relay, and the root's")
        expect(h.editor.showBoard(.root))
        expectEqual(h.editor.standingPortsKept, 2, "leaving a board forgets nothing: its stand-ins are still there")
        h.editor.transact { $0.delete([pocket]) }
        expectEqual(h.editor.standingPortsKept, 1, "the board's stand-in went with it, as the root's did not")

        // A file put in place: the file's stand-ins are not these.
        h.editor.replaceFile(with: h.editor.file)
        expectEqual(h.editor.standingPortsKept, 0, "a board read again keeps none")
        h.move(to: boxMiddle)
        expectEqual(h.editor.standingPortsKept, 1)
        h.editor.replaceFile(with: CanvasFile(root: CanvasDocument()), showing: .root)
        expectEqual(h.editor.standingPortsKept, 0, "nor a file with other shapes")
    },
    test("a file put in place while another board is shown keeps none of the stand-ins' ports either") {
        let h = try portsHarness(more: [relaysPlugin(), PocketsPlugin()])
        let pocket = h.add(Pocket(CGRect(x: 600, y: 500, width: 50, height: 50)))
        expect(h.enter(pocket))
        let inner = h.add(Box(farBox))
        h.add(Relay(boxFrame, stands: [inner]))
        h.move(to: boxMiddle)
        expectEqual(h.editor.standingPortsKept, 1)
        h.editor.replaceFile(with: h.editor.file, showing: .root)
        expectEqual(h.editor.board, .root, "the file's put in place and the root shown")
        expectEqual(h.editor.standingPortsKept, 0)
    },
    test("a connection from a box ends on a stand-in for a box and not on one for a disc") {
        let connections = ConnectionLog()
        let h = try relayHarness(connections)
        let box = h.add(Box(farBox)), disc = h.add(Disc(CGRect(x: 400, y: 400, width: 100, height: 100)))
        let forBox = h.add(Relay(boxFrame, stands: [box]))
        let forDisc = h.add(Relay(CGRect(x: 100, y: 300, width: 200, height: 100), stands: [disc]))
        let from = try h.beginConnection(connections, from: boxEnd, via: farMiddle)
        expectEqual(from.channels, [Wire.id])
        expectEqual(h.editor.channel(of: from, endingAt: try require(h.editor.document[forBox])), Wire.id)
        expectEqual(h.editor.channel(of: from, endingAt: try require(h.editor.document[forDisc])), nil)
        expectEqual(h.editor.channel(of: from, endingAt: try require(h.editor.document[box])), Wire.id, "its own shape, as any")
        h.repoint(forDisc, to: [box])
        expectEqual(h.editor.channel(of: from, endingAt: try require(h.editor.document[forDisc])), Wire.id, "re-pointed")
        h.repoint(forBox, to: [disc])
        expectEqual(h.editor.channel(of: from, endingAt: try require(h.editor.document[forBox])), nil)
    },
    test("a stand-in for shapes of several kinds has the channels every kind takes, with the roles all allow") {
        let connections = ConnectionLog()
        let h = try relayHarness(connections)
        let discFrame = CGRect(x: 400, y: 400, width: 100, height: 100)
        let box = h.add(Box(farBox)), disc = h.add(Disc(discFrame)), hub = h.add(Hub(CGRect(x: 600, y: 100, width: 100, height: 100)))
        let relay = h.add(Relay(boxFrame))
        let fromBox = try h.beginConnection(connections, from: boxEnd, via: farMiddle)
        let fromDisc = try h.beginConnection(connections, from: CGPoint(x: discFrame.maxX + 12, y: discFrame.midY), via: discFrame.center)
        expectEqual(fromBox.channels, [Wire.id])
        expectEqual(fromDisc.channels, [Pipe.id])
        @MainActor func ends(_ connection: Connection) throws -> ChannelID? { h.editor.channel(of: connection, endingAt: try require(h.editor.document[relay])) }
        // A box and a hub share the wire, which a hub's ports only start connections on: so does the
        // stand-in for both, and nothing ends on it.
        h.repoint(relay, to: [box, hub])
        expectEqual(try ends(fromBox), nil)
        h.connect(from: rightDot, to: rightDot + CGPoint(x: 30, y: 0))
        expectEqual(connections.begun.last?.shape, relay)
        expectEqual(connections.begun.last?.channels, [Wire.id])
        // A disc and a hub share the pipe, both ways.
        h.repoint(relay, to: [disc, hub])
        expectEqual(try ends(fromDisc), Pipe.id)
        expectEqual(try ends(fromBox), nil)
        // A box and a disc share none.
        h.repoint(relay, to: [box, disc])
        expectEqual(try ends(fromDisc), nil)
        expectEqual(try ends(fromBox), nil)
        h.move(to: boxMiddle)
        h.move(to: rightDot)
        expectEqual(h.editor.hoveredButton, nil, "no dot")
        h.repoint(relay, to: [box])
        expectEqual(try ends(fromBox), Wire.id)
    },
    test("a stand-in has the channels of what it stands for in that kind's order, not its own: for a junction, the pipe first, so its dots are the pipe's and a drag from it ends on another junction on the pipe") {
        let connections = ConnectionLog()
        let h = try relayHarness(connections, more: [junctionsPlugin()])
        let registry = h.editor.registry
        expectEqual(registry.portChannels(of: Junction.kind), [Pipe.id, Wire.id], "its own channel first, then every other")
        expectEqual(registry.portChannels(of: Relay.kind), [Wire.id, Pipe.id], "the relay's, the order the channels are declared in")
        let junction = h.add(Junction(farBox)), other = h.add(Junction(CGRect(x: 400, y: 400, width: 100, height: 100)))
        let relay = h.add(Relay(boxFrame, stands: [junction]))
        h.hoverDot(rightDot)
        let lit = pixel(render(h), at: rightDot)
        expect(abs(lit[0] - lit[1]) < 16 && abs(lit[1] - lit[2]) < 16, "gray, the pipe's, not the wire's red: \(lit)")
        h.connect(from: rightDot, to: rightDot + CGPoint(x: 30, y: 0))
        let from = try require(connections.begun.last)
        expectEqual(from.shape, relay)
        expectEqual(from.channels, [Pipe.id, Wire.id], "the junction's order, not the relay's")
        let box = h.add(Box(CGRect(x: 550, y: 250, width: 100, height: 100))), disc = h.add(Disc(CGRect(x: 550, y: 400, width: 100, height: 100)))
        expectEqual(h.editor.channel(of: from, endingAt: try require(h.editor.document[box])), Wire.id, "a box takes the wire")
        expectEqual(h.editor.channel(of: from, endingAt: try require(h.editor.document[disc])), Pipe.id, "a disc, the pipe")
        expectEqual(h.editor.channel(of: from, endingAt: try require(h.editor.document[other])), Pipe.id, "a junction both, and the pipe is first")
    },
    test("a stand-in for shapes of several kinds has the channels they all take in the order of the first one") {
        let connections = ConnectionLog()
        let h = try relayHarness(connections, more: [junctionsPlugin()])
        let junction = h.add(Junction(farBox)), hub = h.add(Hub(CGRect(x: 600, y: 100, width: 100, height: 100)))
        let relay = h.add(Relay(boxFrame))
        // A hub's ports are the wire, which only starts connections, and then the pipe; a junction's the pipe, then the wire.
        h.repoint(relay, to: [hub, junction])
        h.connect(from: rightDot, to: rightDot + CGPoint(x: 30, y: 0))
        expectEqual(connections.begun.last?.channels, [Wire.id, Pipe.id], "the hub's order")
        h.repoint(relay, to: [junction, hub])
        h.connect(from: leftDot, to: leftDot - CGPoint(x: 30, y: 0))
        expectEqual(connections.begun.last?.channels, [Pipe.id, Wire.id], "the junction's")
        expectEqual(connections.begun.count, 2)
    },
    test("while a connection is drawn from a port, only the stand-ins that would take it are outlined") {
        let connections = ConnectionLog()
        let h = try relayHarness(connections)
        let box = h.add(Box(farBox)), disc = h.add(Disc(CGRect(x: 400, y: 400, width: 100, height: 100)))
        let forBox = h.add(Relay(boxFrame, stands: [box]))
        let forDisc = h.add(Relay(CGRect(x: 100, y: 300, width: 200, height: 100), stands: [disc]))
        let plain = render(h)
        h.hoverDot(boxEnd, from: farMiddle)
        h.press()
        h.drag(to: CGPoint(x: 540, y: 330))
        let drawing = render(h)
        expect(h.editor.session is RecordingSession)
        expect(changedPixels(plain, drawing, in: topEdge(of: boxFrame)) > 0, "the stand-in for a box is outlined")
        expectEqual(changedPixels(plain, drawing, in: topEdge(of: CGRect(x: 100, y: 300, width: 200, height: 100))), 0, "the one for a disc isn't")
        _ = (forBox, forDisc)
    },
])

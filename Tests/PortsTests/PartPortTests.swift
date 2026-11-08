import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Connections
import CoreGraphics
import Keyboard
import Selection
import TestKit
import Topology

// Ports on a kind's parts (`partPorts`): the row the pointer is on shows a dot just outside each of its ends, no other row
// does, and a drag from one begins a connection from that row. A channel kinds open to every channel don't take
// (`Channel.isOnEveryChannel`): a kind with ports on every channel has none on it. Rosters (CanvasTesting) stand in for
// tables.

/// A key-like channel, column to column: a kind with ports on every channel takes none.
enum Tether {}
extension Tether: Channel {
    static let id: ChannelID = "tether"
    static var color: NSColor { .systemBlue }
    static var isOnEveryChannel: Bool { false }
}

/// A roster at (100, 100), 200 wide, three rows 20 apart under a 10-unit head: its rows' dots on the strand channel.
let rosterFrame = CGRect(x: 100, y: 100, width: 200, height: 80)

@MainActor func rosterPortsHarness(_ connections: ConnectionLog = ConnectionLog()) throws -> (h: EditorHarness, roster: ShapeID, rows: [RosterRow]) {
    let tethers = Contributor(id: "tethers") { registrar in
        registrar.channel(Tether.self)
        registrar.partPorts(Roster.self, on: Tether.self)
        registrar.portsOnEveryChannel(Disc.self)
    }
    let h = try portsHarness(connections, more: [RostersPlugin(), tethers])
    let rows = ["one", "two", "three"].map { RosterRow(name: $0) }
    let roster = h.add(Roster(rosterFrame, rows: rows))
    return (h, roster, rows)
}

/// The middle of row `index` of the roster across, and its dots' centers.
func rosterRow(_ index: Int) -> (middle: CGPoint, left: CGPoint, right: CGPoint) {
    let y = rosterFrame.minY + Roster.head + Roster.rowHeight * (CGFloat(index) + 0.5)
    return (CGPoint(x: rosterFrame.midX, y: y), CGPoint(x: rosterFrame.minX - 12, y: y), CGPoint(x: rosterFrame.maxX + 12, y: y))
}

@MainActor let partPortTests = Suite("Ports on a kind's rows", [
    test("the row the pointer is on shows a dot just outside each end, and no other row does; moving to another row moves them") {
        let (h, _, _) = try rosterPortsHarness()
        let plain = render(h)
        h.move(to: rosterRow(1).middle)
        let onTwo = render(h)
        expectEqual(dotPixels(plain, onTwo, at: rosterRow(1).left), 16)
        expectEqual(dotPixels(plain, onTwo, at: rosterRow(1).right), 16)
        for other in [0, 2] {
            expectEqual(dotPixels(plain, onTwo, at: rosterRow(other).left), 0, "row \(other)")
            expectEqual(dotPixels(plain, onTwo, at: rosterRow(other).right), 0, "row \(other)")
        }
        h.move(to: rosterRow(2).middle)
        let onThree = render(h)
        expectEqual(dotPixels(plain, onThree, at: rosterRow(2).right), 16)
        expectEqual(dotPixels(plain, onThree, at: rosterRow(1).right), 0)
    },
    test("the row's dot is hovered as a button naming its row, and kept while the pointer goes out to it") {
        let (h, roster, rows) = try rosterPortsHarness()
        h.move(to: rosterRow(1).middle)
        h.move(to: CGPoint(x: rosterFrame.maxX + 4, y: rosterRow(1).right.y))
        h.move(to: rosterRow(1).right)
        expectEqual(h.editor.hoveredButton?.base as? PortDot, PortDot(shape: roster, side: .right, part: rows[1].id))
    },
    test("a drag from a row's dot begins a connection from that row, on the row's channels") {
        let connections = ConnectionLog()
        let (h, roster, rows) = try rosterPortsHarness(connections)
        h.connect(from: rosterRow(0).left, to: CGPoint(x: 0, y: 300), via: rosterRow(0).middle)
        let begun = try require(connections.begun.first)
        expectEqual(begun.shape, roster)
        expectEqual(begun.part, rows[0].id)
        expectEqual(begun.side, .left)
        expectEqual(begun.channels, [Tether.id])
    },
    test("a channel kinds open to every channel don't take: a disc with ports on every channel has none on it; the roster takes it either way") {
        let (h, _, _) = try rosterPortsHarness()
        let registry = h.editor.registry
        expectEqual(registry.portChannels(of: Disc.kind).contains(Tether.id), false)
        expectEqual(registry.portChannels(of: Disc.kind).contains(Wire.id), true)
        expect(registry.takesOnParts(Roster.kind, Tether.id, as: .source))
        expect(registry.takesOnParts(Roster.kind, Tether.id, as: .target))
        expectEqual(registry.partDotChannels(of: Roster.kind), [Tether.id])
        expectEqual(registry.dotChannels(of: Roster.kind), [], "no dot on a side")
    },
    test("ports on the rows of a kind with none are refused when the registry is built") {
        let refused = Contributor(id: "box-rows") { registrar in
            registrar.channel(Tether.self)
            registrar.partPorts(Box.self, on: Tether.self)
        }
        do {
            _ = try portsHarness(more: [refused])
            expect(false, "the registry took ports on a box's rows")
        } catch {
            expect("\(error)".contains("PartedShape"), "\(error)")
        }
    },
])

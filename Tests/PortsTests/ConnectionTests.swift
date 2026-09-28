import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Geometry
import Keyboard
import Ports
import Selection
import TestKit

// Ports without a drag: the port table as the registry's lookups read it (one order, the one a drag
// from a dot goes by), what the connector says it can connect in the document it's given, and
// connections made, changed and read through the connector (`registry.connection`,
// `registry.connectionEnds`). The connector here draws links (CanvasTesting's `Link`), which it
// makes and reads without a drag; the drags stay the tag connector's (`connectorPlugin`).

/// A connector over links that makes them without a drag: from the request's first shape to its
/// second, on its channel when new; a change keeps the channel (links have no sides or heads). It
/// can connect a closed shape in the document it's asked of (`canConnect`), and draws nothing from a
/// port.
@MainActor func linkConnectorPlugin() -> Contributor {
    Contributor(id: "link-connector") { registrar in
        registrar.connects(Link.self, canConnect: { id, shapes in shapes.geometry(of: id)?.isClosed == true },
                           make: { request, existing, shapes in
                               guard shapes.shape(request.from) != nil, shapes.shape(request.to) != nil else { return nil }
                               var link = existing?.typed(as: Link.self) ?? ShapeRecord(Link())
                               if existing == nil { link[ChannelProperty.self] = request.channel }
                               link.props.from = request.from
                               link.props.to = request.to
                               var made = AnyShapeRecord(link)
                               if let existing { made.meta = existing.meta }
                               return made
                           },
                           ends: { record in
                               guard let link = record.typed(as: Link.self)?.props, let from = link.from, let to = link.to else { return nil }
                               return (from, to)
                           }) { _, _ in nil }
    }
}

/// The keys, the selection, the fixtures and links, the tests' channels, and the link connector.
@MainActor func linksHarness(boxSides: [PortSide] = PortSide.allCases, boxRole: PortRole = .both) throws -> EditorHarness {
    try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), LinksPlugin(), PortsPlugin(),
                                channelsPlugin(boxSides: boxSides, boxRole: boxRole), linkConnectorPlugin()])
}

/// A connection's ends, as a list, so they compare.
func endsList(_ ends: (from: ShapeID, to: ShapeID)?) -> [ShapeID]? { ends.map { [$0.from, $0.to] } }

/// Boxes' ports on the pipe, on their right side, from a plugin of its own.
@MainActor func pipedBoxesPlugin() -> Contributor {
    Contributor(id: "piped-boxes") { $0.ports(Box.self, on: Pipe.self, sides: [.right]) }
}

@MainActor let connectionTests = Suite("Ports without a drag", [
    test("the port table has one order, plugin order: the lookups, a drag's channels and where it ends agree") {
        for pipesFirst in [true, false] {
            let connections = Connections()
            let plugins: [any CanvasPlugin] = [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), PortsPlugin()]
                + (pipesFirst ? [pipedBoxesPlugin(), channelsPlugin()] : [channelsPlugin(), pipedBoxesPlugin()]) + [connectorPlugin(connections)]
            let h = try EditorHarness(plugins: plugins)
            let registry = h.editor.registry
            let order = pipesFirst ? [Pipe.id, Wire.id] : [Wire.id, Pipe.id]
            expectEqual(registry.portChannels(of: Box.kind), order, "pipes first: \(pipesFirst)")
            expectEqual(registry.dotChannels(of: Box.kind), order)
            expectEqual(registry.dotChannels(of: Box.kind, side: .right), order)
            expectEqual(registry.dotChannels(of: Box.kind, side: .left), [Wire.id])
            h.add(Box(boxFrame))
            let other = h.add(Box(CGRect(x: 400, y: 100, width: 150, height: 100)))
            h.connect(from: rightDot, to: CGPoint(x: 350, y: 300), releasing: false)
            let connection = try require(connections.begun.first)
            expectEqual(connection.channels, registry.dotChannels(of: Box.kind, side: .right))
            expectEqual(h.editor.channel(of: connection, endingAt: try require(h.editor.document[other])), order.first)
        }
    },
    test("a kind's ports, by the lookups: its channels, its dots by side, what they let it be and where") {
        let h = try linksHarness(boxSides: [.right, .left, .right])
        let registry = h.editor.registry
        expect(registry.hasPorts(Box.kind) && registry.hasPorts(Disc.kind))
        expect(!registry.hasPorts(Tag.kind) && !registry.hasPorts(Link.kind), "no ports")
        expect(!registry.hasPorts("nothing"), "no such kind")
        expectEqual(registry.portChannels(of: Box.kind), [Wire.id])
        expectEqual(registry.portChannels(of: Tag.kind), [])
        expectEqual(registry.dotChannels(of: Box.kind, side: .top), [], "a side without ports has no dot")
        expectEqual(registry.dotChannels(of: Box.kind, side: .left), [Wire.id])
        expectEqual(registry.portSides(of: Box.kind, on: Wire.id, as: .source), [.right, .left], "as given, each once")
        expectEqual(registry.portSides(of: Box.kind, on: Wire.id, as: .target), [.right, .left])
        expectEqual(registry.portSides(of: Box.kind, on: Pipe.id, as: .source), [])
        expectEqual(registry.portSides(of: Disc.kind, on: Pipe.id, as: .both), PortSide.allCases)
        expect(registry.takes(Box.kind, Wire.id, as: .source) && registry.takes(Box.kind, Wire.id, as: .target))
        expect(registry.takes(Box.kind, Wire.id, as: .source, side: .left))
        expect(!registry.takes(Box.kind, Wire.id, as: .target, side: .top), "not on a side without ports")
        expect(!registry.takes(Box.kind, Pipe.id, as: .target), "not on a channel it has no ports on")
        expect(!registry.takes(Tag.kind, Wire.id, as: .target))
    },
    test("ports that only start connections, or only take them, say so through every lookup") {
        let sources = try linksHarness(boxRole: .source).editor.registry
        expectEqual(sources.dotChannels(of: Box.kind), [Wire.id])
        expect(sources.takes(Box.kind, Wire.id, as: .source) && !sources.takes(Box.kind, Wire.id, as: .target))
        expectEqual(sources.portSides(of: Box.kind, on: Wire.id, as: .target), [])
        expectEqual(sources.portSides(of: Box.kind, on: Wire.id, as: .both), [])
        let targets = try linksHarness(boxSides: [.left], boxRole: .target).editor.registry
        expect(targets.hasPorts(Box.kind))
        expectEqual(targets.portChannels(of: Box.kind), [Wire.id])
        expectEqual(targets.dotChannels(of: Box.kind), [], "no dots")
        expectEqual(targets.dotChannels(of: Box.kind, side: .left), [])
        expect(!targets.takes(Box.kind, Wire.id, as: .source) && targets.takes(Box.kind, Wire.id, as: .target, side: .left))
        expect(!targets.takes(Box.kind, Wire.id, as: .target, side: .right))
        expectEqual(targets.portSides(of: Box.kind, on: Wire.id, as: .target), [.left])
    },
    test("the connector's kind, and whether it makes connections without a drag") {
        let links = try linksHarness().editor.registry
        expectEqual(links.connectorKind, Link.kind)
        expect(links.makesConnections)
        let tags = try portsHarness().editor.registry
        expectEqual(tags.connectorKind, Tag.kind)
        expect(!tags.makesConnections, "the tag connector only draws from a port")
        let none = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), PortsPlugin(), channelsPlugin()])
        expectEqual(none.connectorKind, nil)
        expect(!none.makesConnections)
    },
    test("canConnect is asked of the document it's given: a shape a transaction inserts connects in the transaction's") {
        let h = try linksHarness()
        let registry = h.editor.registry
        let box = h.add(Box(boxFrame)), tag = h.add(Tag())
        expect(registry.canConnect(box, in: h.editor.shapeContext))
        expect(!registry.canConnect(tag, in: h.editor.shapeContext), "the connector says no: a tag isn't closed")
        expect(!registry.canConnect(ShapeID(), in: h.editor.shapeContext), "not on the board")
        let drawn = ShapeRecord(Disc(CGRect(x: 400, y: 100, width: 100, height: 100)))
        var inTransaction = false, inEditor = true
        h.editor.transact { transaction in
            transaction.insert(drawn)
            inTransaction = registry.canConnect(drawn.id, in: transaction.shapes)
            inEditor = registry.canConnect(drawn.id, in: h.editor.shapeContext)
        }
        expect(inTransaction, "in the transaction's document")
        expect(!inEditor, "not yet in the editor's")
        let none = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), PortsPlugin(), channelsPlugin()])
        expect(!none.canConnect(box, in: ShapeContext(document: h.editor.document, registry: none)), "no connector")
    },
    test("a shape the board keeps aside can't be connected, whatever the connector says") {
        let (h, kept) = try harnessKeepingABoxAside(Connections())
        expect(!h.editor.registry.canConnect(kept, in: h.editor.shapeContext))
    },
    test("the dots ask the connector in the editor's document, as it is now") {
        let wide = Contributor(id: "wide-connector") { registrar in
            registrar.connects(Tag.self, canConnect: { id, shapes in shapes.shape(id)?.box == boxFrame }) { _, _ in nil }
        }
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), PortsPlugin(), channelsPlugin(), wide])
        let box = h.add(Box(boxFrame))
        h.hoverDot(rightDot)
        expectEqual(h.editor.hoveredButton?.base as? PortDot, PortDot(shape: box, side: .right))
        h.editor.transact { $0.update(box) { $0.box = CGRect(x: 100, y: 100, width: 190, height: 100) } }
        h.hoverDot(CGPoint(x: 302, y: 150))
        expectEqual(h.editor.hoveredButton, nil, "the connector reads the box as it is now")
    },
    test("a connection made without a drag is the connector's, not inserted, on the request's channel; its ends read back") {
        let h = try linksHarness()
        let registry = h.editor.registry
        let a = h.add(Box(boxFrame)), b = h.add(Box(CGRect(x: 400, y: 100, width: 150, height: 100)))
        let before = h.editor.document
        let made = try require(registry.connection(ConnectionRequest(from: a, to: b, channel: Wire.id), in: h.editor.shapeContext))
        expectEqual(h.editor.document, before, "not inserted")
        expectEqual(made.kind, Link.kind)
        expectEqual(made.typed(as: Link.self)?.props, Link(from: a, to: b))
        expectEqual(made[ChannelProperty.self], Wire.id)
        expectEqual(endsList(registry.connectionEnds(of: made)), [a, b])
        h.editor.transact { $0.insert(made) }
        let inserted = try require(h.editor.document[made.id])
        expectEqual(endsList(registry.connectionEnds(of: inserted)), [a, b])
        let plain = try require(registry.connection(ConnectionRequest(from: b, to: a), in: h.editor.shapeContext))
        expectEqual(plain[ChannelProperty.self], nil, "no channel: a plain connection")
        expectEqual(endsList(registry.connectionEnds(of: plain)), [b, a])
        expectEqual(registry.connection(ConnectionRequest(from: a, to: ShapeID()), in: h.editor.shapeContext), nil, "the connector refuses")
    },
    test("a connection changed without a drag keeps its id and what the connector keeps; unchanged, it's the one given") {
        let h = try linksHarness()
        let registry = h.editor.registry
        let a = h.add(Box(boxFrame)), b = h.add(Box(CGRect(x: 400, y: 100, width: 150, height: 100)))
        let c = h.add(Disc(CGRect(x: 100, y: 260, width: 150, height: 80)))
        var link = ShapeRecord(Link(from: a, to: b))
        link[ChannelProperty.self] = Wire.id
        h.editor.transact { $0.insert(link) }
        let existing = try require(h.editor.document[link.id])
        let shapes = h.editor.shapeContext
        let same = try require(registry.connection(ConnectionRequest(from: a, to: b, channel: Wire.id), existing: existing, in: shapes))
        expectEqual(same, existing, "nothing changes: the connection given, place in the stack and all")
        let changed = try require(registry.connection(ConnectionRequest(from: a, to: c, channel: Pipe.id), existing: existing, in: shapes))
        expectEqual(changed.id, existing.id)
        expect(changed != existing)
        expectEqual(changed.typed(as: Link.self)?.props, Link(from: a, to: c))
        expectEqual(changed[ChannelProperty.self], Wire.id, "the connector keeps the channel")
        h.editor.transact { $0.update(existing.id) { $0 = changed } }
        expectEqual(h.editor.document[existing.id]?.stackingKey, existing.stackingKey, "in its place")
        expectEqual(endsList(registry.connectionEnds(of: try require(h.editor.document[existing.id]))), [a, c])
        let box = try require(h.editor.document[a])
        expectEqual(registry.connection(ConnectionRequest(from: a, to: b), existing: box, in: h.editor.shapeContext), nil, "a box isn't a connection")
    },
    test("a connection's ends are nil for what isn't one, and for one not joined at both ends") {
        let h = try linksHarness()
        let registry = h.editor.registry
        let a = h.add(Box(boxFrame))
        let loose = h.add(Link(from: a, to: nil)), tag = h.add(Tag(target: a))
        expectEqual(endsList(registry.connectionEnds(of: try require(h.editor.document[loose]))), nil)
        expectEqual(endsList(registry.connectionEnds(of: try require(h.editor.document[tag]))), nil, "a tag isn't a connection here")
        expectEqual(endsList(registry.connectionEnds(of: try require(h.editor.document[a]))), nil)
    },
    test("a connector that only draws from a port makes nothing without a drag, and reads no ends") {
        let h = try portsHarness()
        let registry = h.editor.registry
        let a = h.add(Box(boxFrame)), b = h.add(Box(CGRect(x: 400, y: 100, width: 150, height: 100)))
        let tag = h.add(Tag(target: a))
        expectEqual(registry.connection(ConnectionRequest(from: a, to: b), in: h.editor.shapeContext), nil)
        expectEqual(endsList(registry.connectionEnds(of: try require(h.editor.document[tag]))), nil)
    },
    test("a connection can join shapes the same transaction inserts, made in its document") {
        let h = try linksHarness()
        let registry = h.editor.registry
        let a = h.add(Box(boxFrame))
        let drawn = ShapeRecord(Disc(CGRect(x: 400, y: 100, width: 100, height: 100)))
        var outside: AnyShapeRecord?
        h.editor.transact { transaction in
            transaction.insert(drawn)
            let request = ConnectionRequest(from: a, to: drawn.id, channel: Pipe.id)
            outside = registry.connection(ConnectionRequest(from: a, to: drawn.id), in: h.editor.shapeContext)
            if let made = registry.connection(request, in: transaction.shapes) { transaction.insert(made) }
        }
        expectEqual(outside, nil, "the editor's document hasn't the new disc yet")
        let link = try require(h.editor.document.shapes.last)
        expectEqual(link.kind, Link.kind)
        expectEqual(endsList(registry.connectionEnds(of: link)), [a, drawn.id])
        expectEqual(link[ChannelProperty.self], Pipe.id)
    },
    test("the link fixture: deleting a shape it joins lets go of that end, and its outline runs center to center") {
        let h = try linksHarness()
        let a = h.add(Box(boxFrame)), b = h.add(Box(CGRect(x: 400, y: 100, width: 200, height: 100)))
        let link = h.add(Link(from: a, to: b))
        expectEqual(h.editor.shapeContext.geometry(of: link)?.outline, [CGPoint(x: 200, y: 150), CGPoint(x: 500, y: 150)])
        h.editor.transact { $0.delete([b]) }
        expectEqual(h.editor.document[link]?.typed(as: Link.self)?.props, Link(from: a, to: nil))
        expectEqual(h.editor.shapeContext.geometry(of: link)?.outline, [])
    },
])

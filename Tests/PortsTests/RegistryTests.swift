import Canvas
import CanvasTesting
import Connections
import CoreGraphics
import Foundation
import Keyboard
import Selection
import TestKit
import Topology

/// Declares the wire channel once more, under another type.
enum Cable {}
extension Cable: Channel {
    static let id: ChannelID = "wire"
}

/// A channel nobody declares.
enum Rope {}
extension Rope: Channel {
    static let id: ChannelID = "rope"
}

/// A second connector's family of connections: another type, so only the connectors conflict.
enum Strand {}
extension Strand: EdgeType {
    static let id: EdgeTypeID = "strand"
}

@MainActor let registryTests = Suite("Channels and ports in the registry", [
    test("channels, ports and the connector are what their plugins declare, and the report names each") {
        let registry = try portsHarness().editor.registry
        expectEqual(registry.contributions(to: Channels.self).map(\.value.id), [Wire.id, Pipe.id])
        expectEqual(reportLine(registry, "channels"), "channel wire · edge type wire · channel pipe · edge type pipe · ports wire → box · ports pipe → disc")
        expectEqual(reportLine(registry, "tag-connector"), "property channel → tag · edge type hookup · connector → tag")
        expectEqual(reportLine(registry, .ports), "property channel · service PortState · overlay PortOverlay · CanvasButtons")
    },
    test("a kind's ports given through its own registrar are its plugin's, in the report too") {
        let registry = try portsHarness(more: [dialsPlugin()]).editor.registry
        expectEqual(reportLine(registry, "dials"), "shape dial · ports wire → dial")
    },
    test("a channel declared twice is a conflict, whichever types declare it") {
        let twice = Contributor(id: "more-channels") { $0.channel(Wire.self) }
        expectThrows(RegistryError.conflict(point: "Channels", key: "channel wire", plugins: ["channels", "more-channels"])) {
            _ = try portsHarness(more: [twice])
        }
        let sameID = Contributor(id: "cables") { $0.channel(Cable.self) }
        expectThrows(RegistryError.conflict(point: "Channels", key: "channel wire", plugins: ["channels", "cables"])) {
            _ = try portsHarness(more: [sameID])
        }
    },
    test("a kind's ports on one channel are given once") {
        let again = Contributor(id: "more-ports") { $0.ports(Box.self, on: Wire.self, sides: [.top]) }
        expectThrows(RegistryError.conflict(point: "ShapePorts", key: "box's ports on wire", plugins: ["channels", "more-ports"])) {
            _ = try portsHarness(more: [again])
        }
    },
    test("ports on a channel no installed plugin declares are refused") {
        let loose = Contributor(id: "loose") { $0.ports(Box.self, on: Rope.self) }
        expectThrows(RegistryError.invalid(point: "ShapePorts", reason: "loose gives box ports on channel rope, which no installed plugin declares")) {
            _ = try portsHarness(more: [loose])
        }
    },
    test("ports on the connector's own kind are refused: a connection doesn't start or end on another") {
        let tagPorts = Contributor(id: "tag-ports") { $0.ports(Tag.self, on: Wire.self) }
        expectThrows(RegistryError.invalid(point: "ShapePorts", reason: "tag-ports gives tag ports, but it's what connections are")) {
            _ = try portsHarness(more: [tagPorts])
        }
    },
    test("there's one connector at most") {
        let another = Contributor(id: "disc-connector") { registrar in
            registrar.connects(Disc.self, edgeType: Strand.self, canConnect: { _, _ in true }) { _, _ in nil }
        }
        expectThrows(RegistryError.conflict(point: "Connectors", key: "the connector", plugins: ["tag-connector", "disc-connector"])) {
            _ = try portsHarness(more: [another])
        }
    },
    test("channels and ports need the Ports plugin") {
        expectThrows(RegistryError.ownerNotInstalled(point: "Channels", owner: .ports, contributor: "channels")) {
            _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), channelsPlugin()])
        }
    },
    test("without a connector the list is fine, and no kind has the channel property") {
        let registry = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), TopologyPlugin(), FixturesPlugin(), PortsPlugin(), channelsPlugin()])
        expect(registry.declaredProperties.contains(ChannelProperty.key))
        for kind in registry.kinds { expectEqual(registry.properties(for: kind), [], "\(kind)") }
    },
    test("the channel property is Ports', and only the connector's kind has it: a write to any other shape is dropped") {
        let h = try portsHarness()
        let registry = h.editor.registry
        expectEqual(registry.owner(of: ChannelProperty.key), .ports)
        expectEqual(registry.properties(for: Tag.kind), [ChannelProperty.key])
        expectEqual(registry.properties(for: Box.kind), [])
        expectEqual(registry.properties(for: Disc.kind), [])
        let schema = registry.schema(for: Tag.kind)?.json["properties"]?.objectValue?[ChannelProperty.key.rawValue]?.objectValue
        expectEqual(schema?["type"], .string("string"))
        expectEqual(schema?["x-canvas-owner"], .string(PluginID.ports.rawValue))
        let tag = h.add(Tag()), box = h.add(Box(boxFrame))
        expectEqual(h.editor.document[tag]?[ChannelProperty.self], nil, "none until a connection is drawn on one")
        h.editor.transact { transaction in
            transaction.update(tag) { $0[ChannelProperty.self] = Wire.id }
            transaction.update(box) { $0[ChannelProperty.self] = Wire.id }
        }
        expectEqual(h.editor.document[tag]?[ChannelProperty.self], Wire.id)
        expectEqual(h.editor.document[box]?[ChannelProperty.self], nil)
    },
    test("a connection's channel is saved as its id alone, and read back") {
        let h = try portsHarness()
        let tag = h.add(Tag())
        h.editor.transact { $0.update(tag) { $0[ChannelProperty.self] = Wire.id } }
        let codec = BoardCodec(registry: h.editor.registry)
        let data = try codec.encode(h.editor.document)
        let text = String(decoding: data, as: UTF8.self)
        expect(text.contains(#""channel" : "wire""#) || text.contains(#""channel":"wire""#), text)
        expectEqual(try codec.decode(data).document[tag]?[ChannelProperty.self], Wire.id)
    },
    test("a shape accepts a channel it has ports on as what their role lets it be, and no other") {
        for (role, source, target) in [(PortRole.both, true, true), (.source, true, false), (.target, false, true)] {
            let h = try portsHarness(boxRole: role)
            let registry = h.editor.registry
            let ids = (box: h.add(Box(boxFrame)), disc: h.add(Disc(boxFrame)), tag: h.add(Tag()))
            let box = try require(h.editor.document[ids.box])
            expectEqual(registry.accepts(box, on: Wire.id, as: .source), source, "\(role) as a source")
            expectEqual(registry.accepts(box, on: Wire.id, as: .target), target, "\(role) as a target")
            expect(!registry.accepts(box, on: Pipe.id, as: .source) && !registry.accepts(box, on: Pipe.id, as: .target), "\(role): no pipe")
            let disc = try require(h.editor.document[ids.disc])
            expect(registry.accepts(disc, on: Pipe.id, as: .source) && registry.accepts(disc, on: Pipe.id, as: .target))
            expect(!registry.accepts(disc, on: Wire.id, as: .target))
            let tag = try require(h.editor.document[ids.tag])
            expect(!registry.accepts(tag, on: Wire.id, as: .target) && !registry.accepts(tag, on: Pipe.id, as: .target))
        }
    },
    test("asked whether a shape can be both where a connection starts and where one ends, only a kind whose ports do both can") {
        for (role, both) in [(PortRole.both, true), (.source, false), (.target, false)] {
            expectEqual(role.allows(.both), both, "\(role)")
            let h = try portsHarness(boxRole: role)
            let id = h.add(Box(boxFrame))
            let box = try require(h.editor.document[id])
            expectEqual(h.editor.registry.accepts(box, on: Wire.id, as: .both), both, "\(role)")
        }
    },
    test("a shape the board keeps aside accepts nothing, whatever its kind") {
        let (h, kept) = try harnessKeepingABoxAside(ConnectionLog())
        let record = try require(h.editor.document[kept])
        expect(record.isOpaque)
        expectEqual(record.kind, Box.kind)
        expect(!h.editor.registry.accepts(record, on: Wire.id, as: .source))
        expect(!h.editor.registry.accepts(record, on: Wire.id, as: .target))
    },
    test("a registry declares the channels its plugins declare, and no other") {
        let registry = try portsHarness().editor.registry
        expect(registry.declares(Wire.id))
        expect(registry.declares(Pipe.id))
        expect(!registry.declares(Rope.id))
        let without = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), TopologyPlugin(), FixturesPlugin(), PortsPlugin()])
        expect(!without.declares(Wire.id))
    },
])

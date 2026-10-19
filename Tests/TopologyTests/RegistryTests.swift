import Canvas
import CanvasTesting
import CoreGraphics
import TestKit
import Topology

// Edge types and sources as the registry takes them: one declaration per type, a parent that's
// declared, no type under itself; a parent worked out from the registry; the tree; and what a
// record carries, worked out from the record alone (`registry.edges(of:)`).

@MainActor private func declaring(_ id: PluginID, _ body: @escaping @MainActor (inout PluginRegistrar) -> Void) -> Contributor {
    Contributor(id: id, body)
}

@MainActor let registryTests = Suite("Edge types and sources in the registry", [
    test("two declarations of one type conflict") {
        expectThrows(RegistryError.conflict(point: "EdgeTypes", key: "edge type wire", plugins: ["graph", "more"])) {
            _ = try Registry(plugins: graphPlugins(more: [declaring("more") { $0.edgeType(WireEdge.self) }]))
        }
    },

    test("a parent no plugin declares is refused, naming the plugin that declared the type") {
        expectThrows(RegistryError.invalid(point: "EdgeTypes", reason: "more declares edge type spark under fire, which no installed plugin declares")) {
            _ = try Registry(plugins: graphPlugins(more: [declaring("more") { $0.edgeType("spark", parent: { _ in "fire" }) }]))
        }
    },

    test("a type under itself is refused, with the loop") {
        let loop = declaring("more") { r in
            r.edgeType("spark", parent: { _ in "flame" })
            r.edgeType("flame", parent: { _ in "spark" })
        }
        expectThrows(RegistryError.invalid(point: "EdgeTypes", reason: "more declares edge type spark under itself: spark → flame → spark")) {
            _ = try Registry(plugins: graphPlugins(more: [loop]))
        }
        expectThrows(RegistryError.invalid(point: "EdgeTypes", reason: "more declares edge type spark under itself: spark → spark")) {
            _ = try Registry(plugins: graphPlugins(more: [declaring("more") { $0.edgeType("spark", parent: { _ in "spark" }) }]))
        }
    },

    test("a parent worked out from the registry follows what's installed") {
        let spark = declaring("more") { $0.edgeType("spark", parent: { $0.kinds.contains(Link.kind) ? WireEdge.id : nil }) }
        let types = try Registry(plugins: graphPlugins(more: [spark])).edgeTypes
        expectEqual(types.parent(of: "spark"), WireEdge.id)
        expectEqual(types.descendants(of: WireEdge.id), [HotWireEdge.id, "spark"])

        let alone = try Registry(plugins: [TopologyPlugin(), spark]).edgeTypes
        expectEqual(alone.parent(of: "spark"), nil, "without links, a root")
        expectEqual(alone.declared, [StandingEdge.id, "spark"], "Topology declares its own")
    },

    test("contributing without Topology installed is refused") {
        expectThrows(RegistryError.ownerNotInstalled(point: "EdgeTypes", owner: .topology, contributor: "graph")) {
            _ = try Registry(plugins: [FixturesPlugin(), LinksPlugin(), NamingPlugin(), GraphPlugin()])
        }
    },

    test("the tree: parents, children, descendants and ancestors, who declares each, and a type nobody declares") {
        let spark = declaring("more") { $0.edgeType("spark", parent: { _ in HotWireEdge.id }) }
        let types = try Registry(plugins: graphPlugins(more: [spark])).edgeTypes
        expectEqual(types.declared, [StandingEdge.id, WireEdge.id, HotWireEdge.id, QuoteEdge.id, CiteEdge.id, "spark"])
        expectEqual(types.children(of: WireEdge.id), [HotWireEdge.id])
        expectEqual(types.descendants(of: WireEdge.id), [HotWireEdge.id, "spark"])
        expectEqual(types.ancestors(of: "spark"), [HotWireEdge.id, WireEdge.id])
        expectEqual(types.plugin(declaring: "spark"), "more")
        expectEqual(types.plugin(declaring: WireEdge.id), "graph")
        expect(types.isDeclared(HotWireEdge.id))
        expect(!types.isDeclared(tether))
        expectEqual(types.parent(of: tether), nil)
        expectEqual(types.descendants(of: tether), [])

        expect(EdgeTypeFilter.within(WireEdge.id).admits("spark", in: types))
        expect(!EdgeTypeFilter.only(WireEdge.id).admits(HotWireEdge.id, in: types))
        expect(EdgeTypeFilter.within(tether).admits(tether, in: types))
        expect(EdgeTypeFilter.all.admits(tether, in: types))
        expect(!EdgeTypeFilter.within(WireEdge.id).admits(tether, in: types))
    },

    test("what a record carries is its sources', from the record alone: bound at both ends, or nothing") {
        let registry = try Registry(plugins: graphPlugins())
        let a = ShapeID(), b = ShapeID(), l = ShapeID()
        expectEqual(registry.edges(of: link(l, a, b)), [edge(WireEdge.id, a, b, by: l)])
        expectEqual(registry.edges(of: link(l, a, nil)), [], "one end free: no edge")
        expectEqual(registry.edges(of: link(l, nil, nil)), [])
        expectEqual(registry.edges(of: box(a)), [], "a kind with no source")
        let t = ShapeID()
        expectEqual(registry.edges(of: AnyShapeRecord(ShapeRecord(id: t, Tag(target: a)))), [edge(tether, t, a, by: t)],
                    "a type nobody declares, kept as written")
    },

    test("sources add up, in plugin order, and a kind's own sugar gives it the record typed") {
        let extra = declaring("extra") { r in
            r.forShapes(adopting: ShapeCapability("that is a link") { $0.kind == Link.kind }) { links in
                links.edges { record, _, sink in
                    guard let to = (record.props as? Link)?.to else { return }
                    sink.emit("echo", from: record.id, to: to)
                }
            }
        }
        let registry = try Registry(plugins: graphPlugins(more: [extra]))
        let a = ShapeID(), b = ShapeID(), l = ShapeID()
        expectEqual(registry.edges(of: link(l, a, b)), [edge(WireEdge.id, a, b, by: l), edge("echo", l, b, by: l)])
        expectEqual(registry.edges(of: link(l, nil, b)), [edge("echo", l, b, by: l)])
        expectEqual(registry.edges(of: box(a)), [], "the scope reaches links alone")

        let own = declaring("own") { r in
            r.shape(OwnDefinition()) { own in
                own.edges { shape, _, sink in
                    if let target = shape.props.target { sink.emit("own", from: shape.id, to: target) }
                }
            }
        }
        let owned = try Registry(plugins: [TopologyPlugin(), own])
        let o = ShapeID()
        expectEqual(owned.edges(of: AnyShapeRecord(ShapeRecord(id: o, Owned(target: a)))), [edge("own", o, a, by: o)])
    },
])

/// A kind whose own plugin says what it carries.
struct Owned: ShapeProps {
    static let kind: ShapeKind = "owned"
    static let properties = Properties<Owned> {
        Property("target", \.target)
    }
    var target: ShapeID?
    init(target: ShapeID?) { self.target = target }
}

extension Owned {
    init() { self.init(target: nil) }
}

struct OwnDefinition {}

extension OwnDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Owned>, in context: RenderContext) {}
    func geometry(of shape: ShapeRecord<Owned>, in context: ShapeContext) -> ShapeGeometry {
        ShapeGeometry(outline: [], bounds: .zero, isClosed: false)
    }
}

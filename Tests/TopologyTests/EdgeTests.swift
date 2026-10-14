import Canvas
import CanvasTesting
import TestKit
import Topology

// Reading edges: what a carrier emits, in order, counted, by slot; a shape's edges either way, a
// self-edge once; its neighbors by type; the file's by type; and the filters over the tree.

/// On the root, in this order: boxes A, B and C; memo M, whose note cites B, C and B again, whose
/// lead is A and whose citations are C; link L from A to B; citing tag T on A; tag G on B; link S
/// from A to A; memo N, whose lead is itself.
@MainActor private struct Graph {
    let a = ShapeID(), b = ShapeID(), c = ShapeID(), m = ShapeID(), l = ShapeID(), t = ShapeID(), g = ShapeID(), s = ShapeID(), n = ShapeID()
    let h: EditorHarness
    var index: TopologyIndex { h.topology }

    init() throws {
        var cited = ShapeRecord(id: m, Memo(unit, notes: [MemoNote("x", cites: [Citation(b), Citation(c), Citation(b)])], lead: Citation(a)))
        cited[CitationsProperty.self] = [Citation(c)]
        h = try graph(CanvasFile(root: board(box(a), box(b), box(c), AnyShapeRecord(cited), link(l, a, b),
                                             AnyShapeRecord(ShapeRecord(id: t, CitingTag(target: a))), AnyShapeRecord(ShapeRecord(id: g, Tag(target: b))),
                                             link(s, a, a), memo(n, lead: n))))
    }
}

@MainActor let edgeTests = Suite("Edges", [
    test("a carrier's edges are in the order it emits them, each once with its count, in its slot") {
        let x = try Graph()
        expectEqual(x.index.edges(carriedBy: x.m), [edge(QuoteEdge.id, x.m, x.b, by: x.m, slot: "notes", count: 2),
                                                    edge(QuoteEdge.id, x.m, x.c, by: x.m, slot: "notes"),
                                                    edge(QuoteEdge.id, x.m, x.a, by: x.m, slot: "lead"),
                                                    edge(CiteEdge.id, x.m, x.c, by: x.m, slot: "citations")])
        expectEqual(x.index.edges(carriedBy: x.l), [edge(WireEdge.id, x.a, x.b, by: x.l)], "an arrow-like carrier is neither end, in no slot")
        expectEqual(x.index.edges(carriedBy: x.a), [], "a box carries nothing")
        expectEqual(x.index.edges(carriedBy: ShapeID()), [])
        expect(x.index.edges(carriedBy: x.l).allSatisfy(\.isConnection), "the carrier's own edge, in the empty slot, is the connection")
        expect(x.index.edges(carriedBy: x.m).allSatisfy { !$0.isConnection }, "an edge a property holds is not")
    },

    test("a shape's edges, either way, by carrier in the order they came; a self-edge once") {
        let x = try Graph()
        let quote = edge(QuoteEdge.id, x.m, x.a, by: x.m, slot: "lead"), wire = edge(WireEdge.id, x.a, x.b, by: x.l)
        let hot = edge(HotWireEdge.id, x.t, x.a, by: x.t), loop = edge(WireEdge.id, x.a, x.a, by: x.s)
        expectEqual(x.index.edges(of: x.a), [quote, wire, hot, loop])
        expectEqual(x.index.edges(of: x.a, .outgoing), [wire, loop])
        expectEqual(x.index.edges(of: x.a, .incoming), [quote, hot, loop])
        expectEqual(x.index.edges(of: x.n), [edge(QuoteEdge.id, x.n, x.n, by: x.n, slot: "lead")])
        expectEqual(x.index.edges(of: ShapeID()), [])
    },

    test("filters: within a type takes the types under it, only takes it alone, and a type nobody declares matches itself and all") {
        let x = try Graph()
        let wire = edge(WireEdge.id, x.a, x.b, by: x.l), hot = edge(HotWireEdge.id, x.t, x.a, by: x.t), loop = edge(WireEdge.id, x.a, x.a, by: x.s)
        expectEqual(x.index.edges(of: x.a, types: .within(WireEdge.id)), [wire, hot, loop])
        expectEqual(x.index.edges(of: x.a, types: .only(WireEdge.id)), [wire, loop])
        expectEqual(x.index.edges(of: x.a, types: .only(HotWireEdge.id, QuoteEdge.id)), [edge(QuoteEdge.id, x.m, x.a, by: x.m, slot: "lead"), hot])
        let tied = edge(tether, x.g, x.b, by: x.g)
        expectEqual(x.index.edges(of: x.b, .incoming, types: .only(tether)), [tied])
        expectEqual(x.index.edges(of: x.b, .incoming, types: .within(tether)), [tied])
        expect(x.index.edges(of: x.b, types: .all).contains(tied))
        expect(!x.index.edges(of: x.b, types: .within(WireEdge.id)).contains(tied), "a type nobody declares has no parent")
        expect(!x.index.types.isDeclared(tether))
    },

    test("hasEdges finds what edges(of:) would, of the types asked, that its predicate takes") {
        let x = try Graph()
        expect(x.index.hasEdges(of: x.a))
        expect(x.index.hasEdges(of: x.a, .incoming, types: .only(HotWireEdge.id)))
        expect(!x.index.hasEdges(of: x.c, .outgoing))
        expect(!x.index.hasEdges(of: ShapeID()))
        expect(x.index.hasEdges(of: x.a, .incoming) { $0.carrier != x.a }, "the lead, the hot wire and the loop")
        expect(x.index.hasEdges(of: x.n, .incoming))
        expect(!x.index.hasEdges(of: x.n, .incoming) { $0.carrier != x.n }, "N's lead is its own: nothing else's")
        expect(!x.index.hasEdges(of: x.a, .outgoing, types: .only(QuoteEdge.id)) { _ in true })
        var asked = 0
        expect(x.index.hasEdges(of: x.a) { _ in asked += 1; return true })
        expectEqual(asked, 1, "it stops at the first")
    },

    test("neighbors: what's at the other end, by type, each once per type") {
        let x = try Graph()
        expectEqual(x.index.neighbors(of: x.a), [QuoteEdge.id: [x.m], WireEdge.id: [x.b, x.a], HotWireEdge.id: [x.t]])
        expectEqual(x.index.neighbors(of: x.a, .outgoing), [WireEdge.id: [x.b, x.a]])
        expectEqual(x.index.neighbors(of: x.b, .incoming), [QuoteEdge.id: [x.m], WireEdge.id: [x.a], tether: [x.g]],
                    "M quotes B twice in one edge: once")
        expectEqual(x.index.neighbors(of: x.m), [QuoteEdge.id: [x.b, x.c, x.a], CiteEdge.id: [x.c]], "C is quoted and cited: once for each")
        expectEqual(x.index.neighbors(of: x.a, types: .within(WireEdge.id)), [WireEdge.id: [x.b, x.a], HotWireEdge.id: [x.t]])
        expectEqual(x.index.neighbors(of: x.n), [QuoteEdge.id: [x.n]])
    },

    test("the file's edges by type: declared types in plugin order, then the rest; within and only") {
        let x = try Graph()
        let wires = [edge(WireEdge.id, x.a, x.b, by: x.l), edge(WireEdge.id, x.a, x.a, by: x.s)]
        let hot = [edge(HotWireEdge.id, x.t, x.a, by: x.t)]
        let quotes = x.index.edges(carriedBy: x.m).filter { $0.type == QuoteEdge.id } + [edge(QuoteEdge.id, x.n, x.n, by: x.n, slot: "lead")]
        let cites = [edge(CiteEdge.id, x.m, x.c, by: x.m, slot: "citations")]
        let tied = [edge(tether, x.g, x.b, by: x.g)]
        expectEqual(x.index.edges(ofType: .all), wires + hot + quotes + cites + tied)
        expectEqual(x.index.edges(ofType: .within(WireEdge.id)), wires + hot)
        expectEqual(x.index.edges(ofType: .only(WireEdge.id)), wires)
        expectEqual(x.index.edges(ofType: .only(tether)), tied)
        expectEqual(x.index.edges(ofType: .only("nothing")), [])
    },

    test("the property rule: what an added property's value names, on the kinds that opt in, in its key's slot") {
        let h = try graph()
        let a = ShapeID(), b = ShapeID(), m = ShapeID()
        h.editor.transact { t in
            t.insert(box(a))
            t.insert(box(b))
            var cited = memo(m)
            cited[CitationsProperty.self] = [Citation(a)]
            t.insert(cited)
        }
        expectEqual(h.topology.edges(carriedBy: m), [edge(CiteEdge.id, m, a, by: m, slot: CitationsProperty.key.rawValue)])
        h.editor.transact { $0.update(m) { $0[CitationsProperty.self] = [Citation(b)] } }
        expectEqual(h.topology.edges(of: a), [])
        expectEqual(h.topology.edges(of: b), [edge(CiteEdge.id, m, b, by: m, slot: "citations")])
        h.editor.transact { $0.update(m) { $0[CitationsProperty.self] = nil } }
        expectEqual(h.topology.edges(carriedBy: m), [])
        expectEqual(h.topology.edges(ofType: .all), [])
    },
])

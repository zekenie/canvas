import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Foundation
import Queries
import QueryCommands
import TestKit
import Topology

// `canvas query` over stand-ins it knows nothing of (a proxy for the shapes its record cites, a
// lens for what was provided): a row's connection says what it went through, member by member,
// and only when it went through one; and a query that reads edges waits for answers still arriving,
// and says so when it goes on without them.

/// A box that stands for the shapes it cites.
struct Proxy: BoxShapeProps {
    static let kind: ShapeKind = "proxy"
    static let properties = Properties<Proxy> {
        Property("frame", \.frame).required()
        Property("stands", \.stands)
    }
    var frame: CGRect
    var stands: [Citation]
    init(_ frame: CGRect, stands: [Citation] = []) {
        self.frame = frame
        self.stands = stands
    }
}

extension Proxy {
    init() { self.init(.zero) }
}

/// A box that stands for what's provided for the question it asks.
struct Lens: BoxShapeProps {
    static let kind: ShapeKind = "lens"
    static let properties = Properties<Lens> {
        Property("frame", \.frame).required()
        Property("asks", \.asks)
    }
    var frame: CGRect
    var asks: String
    init(_ frame: CGRect, asks: String = "") {
        self.frame = frame
        self.asks = asks
    }
}

extension Lens {
    init() { self.init(.zero) }
}

struct ProxyDefinition {}

extension ProxyDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Proxy>, in context: RenderContext) {}
}

struct LensDefinition {}

extension LensDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Lens>, in context: RenderContext) {}
}

struct StandInsPlugin: CanvasPlugin {
    var id: PluginID { "stand-ins" }

    func register(into registrar: inout PluginRegistrar) {
        registrar.shape(ProxyDefinition()) { proxy in
            proxy.standsIn { shape, _ in shape.props.stands.isEmpty ? nil : .shapes(shape.props.stands.map(\.shape)) }
        }
        registrar.shape(LensDefinition()) { lens in
            lens.standsIn { shape, _ in shape.props.asks.isEmpty ? nil : .provided(ForwardingKey(shape.props.asks)) }
        }
    }
}

/// Chores 1 "Alpha", 2 "Beta" and 3 "Gamma", a proxy 5 for 2 and 1, a lens 6 asking "q", and wires: 7 from
/// Gamma to the proxy, 8 from Gamma to the lens, 9 from Gamma to Alpha as drawn.
@MainActor func relayHarness() throws -> EditorHarness {
    let proxy = AnyShapeRecord(ShapeRecord(id: id(5), Proxy(unit, stands: [Citation(id(2)), Citation(id(1))])))
    let lens = AnyShapeRecord(ShapeRecord(id: id(6), Lens(unit, asks: "q")))
    let file = CanvasFile(root: CanvasDocument(shapes: [chore(id(1), caption: "Alpha"), chore(id(2), caption: "Beta"), chore(id(3), caption: "Gamma"),
                                                        proxy, lens, link(id(7), id(3), id(5)), link(id(8), id(3), id(6)), link(id(9), id(3), id(1))]))
    return try EditorHarness(plugins: commandPlugins() + [StandInsPlugin()], file: file)
}

private func end(_ n: Int, _ title: String? = nil) -> JSON {
    title.map { .object(["id": .string(uuid(n)), "title": .string($0)]) } ?? .object(["id": .string(uuid(n))])
}

@MainActor let standInTests = Suite("query, through stand-ins", [
    test("a connection as drawn is written as it was; one that went through a stand-in says which, and the others it reached") {
        let h = try relayHarness()
        let answer = try answered(["query", "link"], on: h)
        let connections = Dictionary(uniqueKeysWithValues: (answer["rows"]?.arrayValue ?? []).compactMap { row in
            row["id"]?.stringValue.map { ($0, row["connection"]) }
        })
        // As drawn: no via, no more.
        expectEqual(connections[uuid(9)], .object(["type": "wire", "from": end(3, "Gamma"), "to": end(1, "Alpha")]))
        // Through the proxy, which stands for two: the first in file order, the other under `more`, the proxy (untitled) by id alone.
        expectEqual(connections[uuid(7)], .object(["type": "wire", "from": end(3, "Gamma"), "to": end(1, "Alpha"), "via": .object(["to": end(5)]),
                                                   "more": .array([.object(["from": end(3, "Gamma"), "to": end(2, "Beta")])])]))
        // The lens has no answer: the arrow stays at it, as drawn.
        expectEqual(connections[uuid(8)], .object(["type": "wire", "from": end(3, "Gamma"), "to": end(6)]))
        expectEqual(answer["warnings"], nil, "answers have all come")
    },
    test("a row is written member by member, `via` and `more` only when there are some") {
        let plain = QueryRow(id: id(7), kind: "link", connection: QueryConnection(type: "wire", from: QueryEnd(id: id(1)), to: QueryEnd(id: id(2))))
        expectEqual(QueryOutput.row(plain)["connection"]?["via"], nil)
        expectEqual(QueryOutput.row(plain)["connection"]?["more"], nil)
        let through = QueryRow(id: id(7), kind: "link", connection: QueryConnection(type: "wire", from: QueryEnd(id: id(1)), to: QueryEnd(id: id(2)),
                                                                                     via: QueryVia(from: QueryEnd(id: id(5), title: "Pill"), to: nil),
                                                                                     more: []))
        let written = QueryOutput.row(through)["connection"]
        expectEqual(written?["via"], .object(["from": end(5, "Pill")]), "an end that wasn't a stand-in is left out")
        expectEqual(written?["more"], .array([]), "present means present")
    },
    test("it waits for answers still arriving, and goes on after two seconds with a pending warning") {
        let h = try relayHarness()
        let topology = try require(h.editor.topology)
        let source = topology.keepsSettling { !topology.pendingStandIns.isEmpty }
        let pending = try start(["query", #"chore:connected-to("Beta")"#], on: h)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        expect(pending.result == nil, "it waits")
        h.scheduler.advance(by: .milliseconds(1_999))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        expect(pending.result == nil, "for two seconds")
        h.scheduler.advance(by: .milliseconds(1))
        guard case .success(let answer) = try finish(pending) else { throw RequireFailed() }
        expectEqual(answer["count"], 1, "read as the edges were: Gamma, through the proxy, which stands for Beta; the lens has no answer")
        let warnings = try require(answer["warnings"]?.arrayValue)
        expectEqual(warnings.count, 1)
        expectEqual(warnings.first?["reason"], "pending")
        expectEqual(warnings.first?["message"]?.stringValue, QueryWarning.pending(1).message)
        source.cancel()
        // A query that reads no edge doesn't wait.
        let busy = topology.keepsSettling { true }
        expectEqual(try answered(["query", "chore", "--count"], on: h)["count"], 3)
        busy.cancel()
    },
    test("answers that come while it waits are the ones it reads") {
        let h = try relayHarness()
        let topology = try require(h.editor.topology)
        let source = topology.keepsSettling { !topology.pendingStandIns.isEmpty }
        let pending = try start(["query", #"chore:connected-to("Beta")"#, "--brief"], on: h)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        expect(pending.result == nil)
        topology.provide([id(6): ProvidedForwarding(key: ForwardingKey("q"), shapes: [id(2)], revision: 1)])
        guard case .success(let answer) = try finish(pending) else { throw RequireFailed() }
        expectEqual(rowIDs(answer), [uuid(3)])
        expectEqual(answer["warnings"], nil)
        source.cancel()
    },
])

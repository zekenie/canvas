@_spi(Host) import Canvas
import CanvasTesting
import Foundation
import Observation
import TestKit
import Topology

// Following the file: every way a commit reaches the index reads again only the records it changed
// (`recordsRead`), and leaves the index as reading the file afresh would.

/// The index as a fresh one reads the file now: every carrier's edges.
@MainActor private func fresh(_ h: EditorHarness) throws -> [Edge] {
    let registry = h.editor.registry
    let editor = CanvasEditor(registry: registry, file: h.file, showing: h.editor.board)
    return try require(editor.topology).edges(ofType: .all)
}

@MainActor private func expectFresh(_ h: EditorHarness, _ message: String = "", file: StaticString = #fileID, line: UInt = #line) throws {
    expectEqual(Set(h.topology.edges(ofType: .all)), Set(try fresh(h)), "as reading the file afresh: " + message, file: file, line: line)
}

private final class Flag: @unchecked Sendable {
    var fired = false
}

/// Whether reading `id`'s revision is told of the next change: observed now, checked by the caller.
@MainActor private func observing(_ index: TopologyIndex, _ id: ShapeID) -> Flag {
    let flag = Flag()
    withObservationTracking { _ = index.revision(of: id) } onChange: { flag.fired = true }
    return flag
}

/// Reads a shape's edges as it hears each commit, before and after asking the index to catch up: a
/// service made before the index's, so it hears of each commit first.
@MainActor private final class Probe {
    let watched: ShapeID
    var before: [[Edge]] = []
    var after: [[Edge]] = []
    init(watching id: ShapeID) { watched = id }
}

extension Probe: EditorService {
    func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        guard let index = editor.topology else { return }
        before.append(index.edges(of: watched))
        index.catchUp(changes)
        after.append(index.edges(of: watched))
        index.catchUp(changes)
    }
}

/// The same, through a reference to the index it holds, which is no lookup (as a service that kept one from its `make`):
/// hearing a commit first, it reads the index as it was until it asks it to catch up.
@MainActor private final class KeptProbe {
    let watched: ShapeID
    weak var index: TopologyIndex?
    var before: [[Edge]] = []
    var after: [[Edge]] = []
    init(watching id: ShapeID) { watched = id }
}

extension KeptProbe: EditorService {
    func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        guard let index else { return }
        before.append(index.edges(of: watched))
        index.catchUp(changes)
        after.append(index.edges(of: watched))
        index.catchUp(changes)
    }
}

@MainActor let upkeepTests = Suite("Following the file", [
    test("opening reads every board the editor can show, and only the kinds with sources") {
        let tree = Nest()
        let h = try graph(tree.file)
        expectEqual(h.topology.recordsRead, 3, "the three links")
        expectEqual(h.topology.edges(of: tree.a), [edge(WireEdge.id, tree.a, tree.b, by: tree.l), edge(WireEdge.id, tree.c, tree.a, by: tree.m)],
                    "the root's carriers first, then the board below's")
        expectEqual(h.topology.edges(of: tree.c), [edge(WireEdge.id, tree.c, tree.a, by: tree.m), edge(WireEdge.id, tree.d, tree.c, by: tree.n)])
        expectEqual(h.topology.touched, [])
    },

    test("adding, changing and removing a carrier reads it alone, and touches the ends whose edges changed") {
        let tree = Nest(), x = ShapeID()
        let h = try graph(tree.file)
        let read = h.topology.recordsRead
        h.editor.transact { $0.insert(link(x, tree.a, tree.c)) }
        expectEqual(h.topology.recordsRead, read + 1)
        expectEqual(h.topology.touched, [tree.a, tree.c])
        expectEqual(h.topology.edges(of: tree.c, .incoming), [edge(WireEdge.id, tree.d, tree.c, by: tree.n), edge(WireEdge.id, tree.a, tree.c, by: x)],
                    "carriers in the order they came: the one added after those read as the editor opened, wherever they are")
        h.editor.transact { $0.update(x, as: Link.self) { $0.props.from = tree.b } }
        expectEqual(h.topology.recordsRead, read + 2)
        expectEqual(h.topology.touched, [tree.a, tree.b, tree.c])
        expectEqual(h.topology.edges(of: tree.a, .outgoing), [edge(WireEdge.id, tree.a, tree.b, by: tree.l)])
        h.editor.transact { $0.update(x, as: Link.self) { $0.props.to = nil } }
        expectEqual(h.topology.edges(carriedBy: x), [], "one end free: no edge")
        expectEqual(h.topology.touched, [tree.b, tree.c])
        h.editor.transact { $0.update(x, as: Link.self) { $0.props.to = tree.a } }
        h.editor.transact { $0.delete([x]) }
        expectEqual(h.topology.edges(carriedBy: x), [])
        expectEqual(h.topology.touched, [tree.b, tree.a])
        try expectFresh(h)

        h.editor.transact { $0.update(tree.l) { $0.meta[Note.self] = "hi" } }
        expectEqual(h.topology.touched, [], "a change that changes no edge touches nothing")
    },

    test("touched(types:) is the ends of the edges of those types the last commit changed") {
        let tree = Nest(), m = ShapeID(), t = ShapeID()
        let h = try graph(tree.file)
        h.editor.transact { $0.insert(link(t, tree.a, tree.b)) }
        expectEqual(h.topology.touched(types: .only(QuoteEdge.id)), [], "a wire")
        expectEqual(h.topology.touched(types: .within(WireEdge.id)), [tree.a, tree.b])
        expectEqual(h.topology.touched(types: .all), h.topology.touched)
        h.editor.transact {
            $0.insert(memo(m, lead: tree.b))
            $0.delete([t])
        }
        expectEqual(h.topology.touched, [m, tree.a, tree.b])
        expectEqual(h.topology.touched(types: .only(QuoteEdge.id)), [m, tree.b])
        expectEqual(h.topology.touched(types: .only(WireEdge.id)), [tree.a, tree.b])
        h.editor.transact { $0.update(m, as: Memo.self) { $0.props.lead = Citation(tree.a) } }
        expectEqual(h.topology.touched(types: .only(QuoteEdge.id)), [m, tree.a, tree.b])
        h.editor.transact { $0.update(tree.l) { $0.meta[Note.self] = "hi" } }
        expectEqual(h.topology.touched(types: .only(QuoteEdge.id)), [], "the last commit's alone")
        expect(h.editor.showBoard(tree.pBoard))
        expectEqual(h.topology.touched(types: .all), [], "none after a switch of board")
    },

    test("a commit that only moves shapes reads nothing") {
        let m = ShapeID(), a = ShapeID()
        let h = try graph(CanvasFile(root: board(box(a), memo(m, lead: a))))
        let read = h.topology.recordsRead
        h.editor.transact { $0.moveBox(m, to: CGPoint(x: 300, y: 40)) }
        h.editor.transact { $0.translate([m, a], by: CGPoint(x: 5, y: 5)) }
        expectEqual(h.topology.recordsRead, read)
        expectEqual(h.topology.touched, [])
        h.editor.transact { $0.update(m, as: Memo.self) { $0.props.frame.origin.x = 0; $0.props.text = "a quote" } }
        expectEqual(h.topology.recordsRead, read + 1, "more than a move: read again")
        expectEqual(h.topology.edges(of: a), [edge(QuoteEdge.id, m, a, by: m, slot: "lead")])
    },

    test("a write to a board that isn't shown is read, and the board shown stays") {
        let tree = Nest()
        let h = try graph(tree.file)
        let read = h.topology.recordsRead
        h.editor.transact(on: tree.pBoard, "Rewire") { $0.update(tree.m, as: Link.self) { $0.props.to = tree.b } }
        expectEqual(h.editor.board, .root)
        expectEqual(h.topology.recordsRead, read + 1)
        expectEqual(h.topology.edges(of: tree.a, .incoming), [])
        expectEqual(h.topology.edges(of: tree.b, .incoming), [edge(WireEdge.id, tree.a, tree.b, by: tree.l), edge(WireEdge.id, tree.c, tree.b, by: tree.m)])
        expectEqual(h.topology.touched, [tree.c, tree.a, tree.b])
        h.editor.undo()
        expectEqual(h.topology.edges(of: tree.a, .incoming), [edge(WireEdge.id, tree.c, tree.a, by: tree.m)], "undone: as it was")
        try expectFresh(h)
    },

    test("deleting a pocket takes the edges its boards carried, all the way down; undo brings them back, and redo takes them again") {
        let tree = Nest()
        let h = try graph(tree.file)
        let opened = h.topology.edges(ofType: .all)
        h.editor.transact("Delete") { $0.delete([tree.p]) }
        expectEqual(h.topology.edges(ofType: .all), [edge(WireEdge.id, tree.a, tree.b, by: tree.l)])
        expectEqual(h.topology.edges(of: tree.c), [])
        expectEqual(h.topology.touched, [tree.c, tree.a, tree.d])
        h.editor.undo()
        expectEqual(Set(h.topology.edges(ofType: .all)), Set(opened))
        expectEqual(h.topology.edges(of: tree.c).count, 2)
        h.editor.redo()
        expectEqual(h.topology.edges(ofType: .all), [edge(WireEdge.id, tree.a, tree.b, by: tree.l)])
        try expectFresh(h)
    },

    test("a paste that brings boards brings their edges; its undo takes them") {
        let tree = Nest(), p2 = ShapeID(), c2 = ShapeID(), m2 = ShapeID(), q2 = ShapeID(), n2 = ShapeID()
        let h = try graph(tree.file)
        let read = h.topology.recordsRead
        h.editor.transact("Paste") { t in
            t.insert(pocket(p2), contents: [p2: board(box(c2), link(m2, c2, tree.a), pocket(q2)), q2: board(link(n2, c2, c2))])
        }
        expectEqual(h.topology.recordsRead, read + 2, "the two links it brought")
        expectEqual(h.topology.edges(of: tree.a, .incoming).map(\.carrier), [tree.m, m2])
        expectEqual(Set(h.topology.edges(of: c2)), [edge(WireEdge.id, c2, tree.a, by: m2), edge(WireEdge.id, c2, c2, by: n2)],
                    "carriers that come in one commit come in no order among themselves")
        h.editor.undo()
        expectEqual(h.topology.edges(of: c2), [])
        expectEqual(h.topology.edges(of: tree.a, .incoming).map(\.carrier), [tree.m])
        try expectFresh(h)
    },

    test("a file put in place is read afresh, on the board shown or across a switch; so is a document") {
        let tree = Nest()
        let h = try graph(tree.file)
        let other = CanvasFile(root: board(box(tree.a), box(tree.b), link(tree.l, tree.b, tree.a), pocket(tree.p)),
                               children: [tree.p: board(box(tree.c), link(tree.m, tree.c, tree.b))])
        h.editor.replaceFile(with: other)
        expectEqual(h.topology.edges(of: tree.a), [edge(WireEdge.id, tree.b, tree.a, by: tree.l)])
        expectEqual(h.topology.edges(of: tree.b, .incoming), [edge(WireEdge.id, tree.c, tree.b, by: tree.m)])
        expectEqual(h.topology.edges(carriedBy: tree.n), [], "the board it was on isn't in the file")
        try expectFresh(h)

        // Shown inside Q, which the next file doesn't have: it goes up to P as it's put in place.
        let h2 = try graph(tree.file)
        expect(h2.enter(tree.p))
        expect(h2.enter(tree.q))
        h2.editor.replaceFile(with: other)
        expectEqual(h2.editor.board, tree.pBoard)
        expectEqual(h2.topology.edges(of: tree.b, .incoming), [edge(WireEdge.id, tree.c, tree.b, by: tree.m)])
        expectEqual(h2.topology.edges(carriedBy: tree.n), [])
        expect(h2.topology.touched.contains(tree.d), "the edges it lost touch their ends")
        try expectFresh(h2)

        h.editor.replaceDocument(with: board(box(tree.a), link(tree.l, tree.a, tree.a)))
        expectEqual(h.topology.edges(ofType: .all), [edge(WireEdge.id, tree.a, tree.a, by: tree.l)])
    },

    test("what's kept aside, and the boards under it, carry nothing, through Delete Hidden Shapes and its undo") {
        let loaded = try hiddenFile()
        let h = try graph(loaded.file)
        let only = [edge(WireEdge.id, id(1), id(3), by: id(2))]
        expectEqual(h.topology.edges(ofType: .all), only, "the links on the gadget's board carry nothing")
        expectEqual(h.topology.edges(of: id(1)), only)
        let read = h.topology.recordsRead
        h.editor.discardKeptAside(shapes: [id(10)], boards: [])
        expectEqual(h.file.record(id(13)), nil)
        expectEqual(h.topology.edges(ofType: .all), only)
        h.editor.undo()
        expect(h.file.record(id(13)) != nil, "undone: the board is back, and still can't be shown")
        expectEqual(h.topology.edges(ofType: .all), only)
        expectEqual(h.topology.recordsRead, read, "nothing it can't show is read")
        h.editor.redo()
        expectEqual(h.topology.edges(ofType: .all), only)
    },

    test("a shape kept aside carries nothing, though its kind's source would emit without reading its props") {
        let loaded = try newerDiscsFile()
        let h = try graph(loaded.file, more: [signalsPlugin()])
        let kept = try require(h.editor.document[id(20)])
        expect(kept.isOpaque, "a newer version than the fixtures'")
        expectEqual(h.topology.edges(carriedBy: id(20)), [], "read as the editor opens")
        expectEqual(h.editor.registry.edges(of: kept), [], "read by the registry")
        h.editor.replaceDocument(with: CanvasDocument(shapes: [kept]))
        expectEqual(h.topology.edges(ofType: .all), [], "read again as a board is put in place")
        let disc = h.add(Disc(unit))
        expectEqual(h.topology.edges(carriedBy: disc), [edge(WireEdge.id, disc, disc, by: disc)], "one that isn't kept aside carries its wire")
    },

    test("showing another board reads nothing and touches nothing") {
        let tree = Nest()
        let h = try graph(tree.file)
        h.editor.transact { $0.update(tree.l, as: Link.self) { $0.props.to = tree.a } }
        let read = h.topology.recordsRead, all = h.topology.edges(ofType: .all)
        expect(h.enter(tree.p))
        expect(h.enter(tree.q))
        expectEqual(h.topology.recordsRead, read)
        expectEqual(h.topology.touched, [])
        expectEqual(h.topology.edges(ofType: .all), all)
        expect(h.editor.showBoard(.root))
        expectEqual(h.topology.recordsRead, read)

        // And from inside, a commit there reads what it changed.
        expect(h.enter(tree.p))
        h.editor.transact { $0.update(tree.m, as: Link.self) { $0.props.from = nil } }
        expectEqual(h.topology.recordsRead, read + 1)
        expectEqual(h.topology.edges(of: tree.a, .incoming), [edge(WireEdge.id, tree.a, tree.a, by: tree.l)])
    },

    test("a shape's revision moves when its edges change, and tells only its own observers") {
        let tree = Nest(), x = ShapeID()
        let h = try graph(tree.file)
        let index = h.topology
        let a = index.revision(of: tree.a), b = index.revision(of: tree.b), c = index.revision(of: tree.c)
        let onA = observing(index, tree.a), onB = observing(index, tree.b)
        h.editor.transact { $0.insert(link(x, tree.a, tree.c)) }
        expect(index.revision(of: tree.a) > a)
        expect(index.revision(of: tree.c) > c)
        expectEqual(index.revision(of: tree.b), b)
        expect(onA.fired)
        expect(!onB.fired)

        let onD = observing(index, tree.d)
        h.editor.transact { $0.moveBox(tree.a, to: CGPoint(x: 400, y: 0)) }
        expect(!onD.fired)
        h.editor.transact("Delete") { $0.delete([tree.p]) }
        expect(onD.fired, "a board taken with its owner touches the ends of what it carried")
    },

    test("a service that hears a commit before the index finds it up to date: looking it up has it hear the commit, once") {
        let tree = Nest(), x = ShapeID(), probe = Probe(watching: tree.b)
        let h = try graph(tree.file, first: [Contributor(id: "probe") { $0.service { _ in probe } }])
        let read = h.topology.recordsRead
        h.editor.transact { $0.insert(link(x, tree.c, tree.b)) }
        let lone = edge(WireEdge.id, tree.a, tree.b, by: tree.l), added = edge(WireEdge.id, tree.c, tree.b, by: x)
        expectEqual(probe.before, [[lone, added]], "the index heard the commit as the probe looked it up")
        expectEqual(probe.after, [[lone, added]])
        expectEqual(h.topology.recordsRead, read + 1, "read once: catching up, and the index's own turn, do nothing")
        expectEqual(h.topology.touched, [tree.c, tree.b])
    },
    test("a service that holds the index and hears a commit before it brings it up to date, once") {
        let tree = Nest(), x = ShapeID(), probe = KeptProbe(watching: tree.b)
        let h = try graph(tree.file, first: [Contributor(id: "probe") { $0.service { _ in probe } }])
        probe.index = h.topology
        let read = h.topology.recordsRead
        h.editor.transact { $0.insert(link(x, tree.c, tree.b)) }
        let lone = edge(WireEdge.id, tree.a, tree.b, by: tree.l), added = edge(WireEdge.id, tree.c, tree.b, by: x)
        expectEqual(probe.before, [[lone]], "read through the reference, before the index has heard")
        expectEqual(probe.after, [[lone, added]])
        expectEqual(h.topology.recordsRead, read + 1, "read once: the index's own turn is a no-op")
        expectEqual(h.topology.touched, [tree.c, tree.b])
    },
])

/// Metadata a test writes, which changes a record and no edge.
enum Note: ShapeMetaKey {
    static let owner: PluginID = "graph"
    static let name = "note"
    typealias Value = String
}

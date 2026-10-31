@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import TestKit
import Topology

// Containers within a board (CanvasTesting's corrals, standing in for frames) as the second kind of
// link in containment's tree, beside boards: a shape in a container is inside it, a container is
// inside its own container or its board's owner, and file order goes into each container before the
// shape after it; on the index and a snapshot alike, whichever board is shown, as shapes are put in
// and taken out, moved, deleted and brought back, a move reading no record.

/// A kind that both owns a board and holds shapes on its own, which the registry allows: what it
/// holds comes before its board's shapes.
struct Coffer: BoxShapeProps {
    static let kind: ShapeKind = "coffer"
    static let properties = Properties<Coffer> {
        Property("frame", \.frame).required()
    }
    var frame: CGRect
    init(_ frame: CGRect) { self.frame = frame }
    init() { self.init(.zero) }
}

struct CofferDefinition {}

extension CofferDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Coffer>, in context: RenderContext) {}
}

extension CofferDefinition: BoardOwning {}
extension CofferDefinition: ShapeContaining {}

@MainActor func coffersPlugin() -> Contributor { Contributor(id: "coffers") { $0.shape(CofferDefinition()) } }

/// What `ChangeSet.mayHaveChangedBoardOrder` said of each commit it heard.
@MainActor private final class OrderVerdicts {
    var said: [Bool] = []
}

extension OrderVerdicts: EditorService {
    func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        said.append(changes.mayHaveChangedBoardOrder(in: editor.file))
    }
}

/// Every shape on the boards the app can show, as an editor has them: what's asked about.
@MainActor private func showable(_ h: EditorHarness) -> [ShapeID] {
    var ids: [ShapeID] = []
    h.topology.snapshot().forEachShape { record, _ in ids.append(record.id) }
    return ids
}

/// The snapshot answers every containment question as the index does now.
@MainActor private func expectSnapshotAgrees(_ h: EditorHarness, about ids: [ShapeID], file: StaticString = #fileID, line: UInt = #line) {
    let index = h.topology, snapshot = index.snapshot()
    for id in ids {
        expectEqual(snapshot.parent(of: id), index.parent(of: id), "parent", file: file, line: line)
        expectEqual(snapshot.children(of: id), index.children(of: id), "children", file: file, line: line)
        expectEqual(snapshot.ancestors(of: id), index.ancestors(of: id), "ancestors", file: file, line: line)
        for other in ids { expectEqual(snapshot.isInside(id, other), index.isInside(id, other), "isInside", file: file, line: line) }
    }
}

/// A record on the board it's on.
@MainActor private func record(_ id: ShapeID, in h: EditorHarness) throws -> AnyShapeRecord { try require(h.file.record(id)) }

/// A board file with corral 30 holding box 31 and disc 32 (kept aside: newer than the fixtures'), and
/// box 33 in nothing; the corral at `corralVersion`.
private func keptAsideFile(corralVersion: Int) -> Data {
    func frame() -> String { "\"frame\" : [[0, 0], [100, 100]]" }
    return Data("""
    { "format" : 5, "versions" : { "kinds" : { "box" : 0, "disc" : 99, "corral" : \(corralVersion) } },
      "shapes" : [ { "id" : "\(uuid(30))", "kind" : "corral", "index" : "a0", "props" : { \(frame()) } },
                   { "id" : "\(uuid(31))", "kind" : "box", "index" : "a1", "props" : { \(frame()) }, "container" : "\(uuid(30))" },
                   { "id" : "\(uuid(32))", "kind" : "disc", "index" : "a2", "props" : { \(frame()) }, "container" : "\(uuid(30))" },
                   { "id" : "\(uuid(33))", "kind" : "box", "index" : "a3", "props" : { \(frame()) } } ] }
    """.utf8)
}

@MainActor let containerTests = Suite("Containers", [
    test("a shape in a container is inside it, a container inside its own container or its board's owner: one tree, whichever board is shown") {
        let pen = Pen()
        let h = try graph(pen.file, more: [CorralsPlugin()])
        let index = h.topology
        for shown in [nil, pen.p, pen.q] {
            if let shown { expect(h.enter(shown)) }
            expectEqual(index.parent(of: pen.a), pen.f)
            expectEqual(index.parent(of: pen.b), pen.g)
            expectEqual(index.parent(of: pen.g), pen.f, "a container in a container")
            expectEqual(index.parent(of: pen.p), pen.f, "an owner in a container")
            expectEqual(index.parent(of: pen.f), nil, "on the root in no container")
            expectEqual(index.parent(of: pen.e), nil)
            expectEqual(index.parent(of: pen.r), pen.p, "a container on a pocket's board, in none")
            expectEqual(index.parent(of: pen.d), pen.p)
            expectEqual(index.parent(of: pen.c), pen.r)
            expectEqual(index.parent(of: pen.q), pen.r)
            expectEqual(index.parent(of: pen.k), pen.q)
            expectEqual(index.children(of: pen.f), [pen.a, pen.g, pen.p], "what it holds, back to front")
            expectEqual(index.children(of: pen.g), [pen.b])
            expectEqual(index.children(of: pen.p), [pen.r, pen.d], "its board's shapes in no container")
            expectEqual(index.children(of: pen.r), [pen.c, pen.q])
            expectEqual(index.children(of: pen.q), [pen.k])
            expectEqual(index.children(of: pen.a), [])
            expectEqual(index.children(of: pen.l), [])
            expectEqual(index.ancestors(of: pen.k), [pen.q, pen.r, pen.p, pen.f], "the nearest first")
            expectEqual(index.ancestors(of: pen.b), [pen.g, pen.f])
            expectEqual(index.ancestors(of: pen.d), [pen.p, pen.f])
            expectEqual(index.ancestors(of: pen.f), [])
            expectEqual(index.ancestors(of: pen.e), [])
            expect(index.isInside(pen.k, pen.f))
            expect(index.isInside(pen.c, pen.p))
            expect(index.isInside(pen.b, pen.f))
            expect(!index.isInside(pen.d, pen.r), "beside a container, not in it")
            expect(!index.isInside(pen.e, pen.f))
            expect(!index.isInside(pen.f, pen.f))
            expect(!index.isInside(pen.f, pen.a))
            expectSnapshotAgrees(h, about: pen.fileOrder)
        }
        expectEqual(index.containerKinds, [Pocket.kind, Corral.kind])
    },

    test("file order: each container followed at once by what it holds, an owner by its board's shapes in no container, before the next; keys sort alike") {
        let pen = Pen()
        let h = try graph(pen.file, more: [CorralsPlugin()])
        let snapshot = h.topology.snapshot()
        var order: [ShapeID] = [], boards: [BoardID] = []
        snapshot.forEachShape { record, board in
            order.append(record.id)
            boards.append(board)
        }
        expectEqual(order, pen.fileOrder)
        expectEqual(boards, [.root, .root, .root, .root, .root, pen.pBoard, pen.pBoard, pen.pBoard, pen.qBoard, pen.pBoard, .root, .root])
        expectEqual(snapshot.topLevel, [pen.f, pen.e, pen.l], "the root's shapes in no container")
        expectEqual(pen.fileOrder.filter(snapshot.isTopLevel), [pen.f, pen.e, pen.l])
        expectEqual(snapshot.descendants(of: pen.f), [pen.a, pen.g, pen.b, pen.p, pen.r, pen.c, pen.q, pen.k, pen.d])
        expectEqual(snapshot.descendants(of: pen.p), [pen.r, pen.c, pen.q, pen.k, pen.d])
        expectEqual(snapshot.descendants(of: pen.r), [pen.c, pen.q, pen.k])
        expectEqual(snapshot.descendants(of: pen.g), [pen.b])
        expectEqual(snapshot.descendants(of: pen.a), [])
        expectEqual(snapshot.fileOrderKey(of: pen.f), [0])
        expectEqual(snapshot.fileOrderKey(of: pen.b), [0, 2, 3])
        expectEqual(snapshot.fileOrderKey(of: pen.p), [0, 4])
        expectEqual(snapshot.fileOrderKey(of: pen.k), [0, 4, 0, 3, 0])
        expectEqual(snapshot.fileOrderKey(of: pen.d), [0, 4, 1])
        expectEqual(snapshot.fileOrderKey(of: pen.e), [5])
        let keyed = order.shuffled().sorted { snapshot.fileOrderKey(of: $0)!.lexicographicallyPrecedes(snapshot.fileOrderKey(of: $1)!) }
        expectEqual(keyed, order, "sorting by key puts shapes in file order")
        // What a reader that has the record and its board asks: its parent, when that's a container.
        expectEqual(snapshot.container(of: try record(pen.b, in: h), on: .root), pen.g)
        expectEqual(snapshot.container(of: try record(pen.g, in: h), on: .root), pen.f)
        expectEqual(snapshot.container(of: try record(pen.c, in: h), on: pen.pBoard), pen.r)
        expectEqual(snapshot.container(of: try record(pen.d, in: h), on: pen.pBoard), nil)
        expectEqual(snapshot.container(of: try record(pen.k, in: h), on: pen.qBoard), nil, "in a pocket, which is no container")
    },

    test("a snapshot reads containers off the main actor as the index does on it: the boards' own index, shared with the file") {
        let pen = Pen()
        let h = try graph(pen.file, more: [CorralsPlugin()])
        let index = h.topology, snapshot = index.snapshot()
        let far = try require(offMain {
            var order: [ShapeID] = []
            snapshot.forEachShape { record, _ in order.append(record.id) }
            return (order, pen.fileOrder.map(snapshot.ancestors(of:)), snapshot.descendants(of: pen.f), pen.fileOrder.map(snapshot.fileOrderKey(of:)),
                    pen.fileOrder.map(snapshot.parent(of:)), snapshot.topLevel)
        })
        expectEqual(far.0, pen.fileOrder)
        expectEqual(far.1, pen.fileOrder.map(index.ancestors(of:)))
        expectEqual(far.2, [pen.a, pen.g, pen.b, pen.p, pen.r, pen.c, pen.q, pen.k, pen.d])
        expectEqual(far.3, pen.fileOrder.map(snapshot.fileOrderKey(of:)))
        expectEqual(far.4, pen.fileOrder.map(index.parent(of:)))
        expectEqual(far.5, [pen.f, pen.e, pen.l])
    },

    test("what the core doesn't go by holds nothing: a container kept aside, or of a kind not installed, and a shape kept aside are in none") {
        // Corrals installed: corral 30 holds box 31; disc 32, kept aside, is in none.
        let read = try BoardCodec(registry: Registry(plugins: graphPlugins(more: [CorralsPlugin()]))).decode(keptAsideFile(corralVersion: 0))
        let h = try graph(read.file, more: [CorralsPlugin()])
        expect(try record(id(32), in: h).isOpaque)
        expectEqual(h.topology.parent(of: id(31)), id(30))
        expectEqual(h.topology.parent(of: id(32)), nil, "a shape kept aside is on its board directly")
        expectEqual(h.topology.children(of: id(30)), [id(31)])
        expectEqual(showable(h), [id(30), id(31), id(32), id(33)])
        expectEqual(h.topology.snapshot().topLevel, [id(30), id(32), id(33)])

        // The corral newer than the app (kept aside), or of a kind nothing installs: no container.
        for (corrals, version) in [(true, 99), (false, 0)] {
            let more: [any CanvasPlugin] = corrals ? [CorralsPlugin()] : []
            let kept = try BoardCodec(registry: Registry(plugins: graphPlugins(more: more))).decode(keptAsideFile(corralVersion: version))
            let h = try graph(kept.file, more: more)
            expect(try record(id(30), in: h).isOpaque)
            expectEqual(try record(id(31), in: h).container, id(30), "kept as written")
            expectEqual(h.topology.parent(of: id(31)), nil, "in nothing the app can use")
            expectEqual(h.topology.children(of: id(30)), [])
            expectEqual(h.topology.ancestors(of: id(31)), [])
            expectEqual(showable(h), [id(30), id(31), id(32), id(33)])
            let snapshot = h.topology.snapshot()
            expectEqual(snapshot.topLevel, [id(30), id(31), id(32), id(33)])
            expectEqual(snapshot.fileOrderKey(of: id(31)), [1])
            expect(snapshot.isTopLevel(id(31)))
        }
    },

    test("moving a container carries what it holds and reads no record; putting a shape in, taking it out, deleting a container and undo follow at once") {
        let f = ShapeID(), g = ShapeID(), m = ShapeID(), a = ShapeID(), b = ShapeID()
        let h = try graph(CanvasFile(root: board(corral(f), held(corral(g), in: f), held(memo(m, lead: a), in: g), held(box(b), in: g), box(a))),
                          more: [CorralsPlugin()])
        let index = h.topology, read = index.recordsRead
        expectEqual(index.ancestors(of: m), [g, f])
        h.editor.transact("Move") { $0.translate([f], by: CGPoint(x: 40, y: 10)) }
        expectEqual(h.file.record(m)?.box?.origin, CGPoint(x: 40, y: 10), "carried")
        expectEqual(index.recordsRead, read, "a move reads nothing")
        expectEqual(index.ancestors(of: m), [g, f])

        h.editor.put([m], in: nil)
        expectEqual(index.parent(of: m), nil, "taken out, where it was in the stack")
        expectEqual(index.children(of: g), [b])
        expectEqual(index.snapshot().topLevel, [f, m, a])
        h.editor.put([m], in: f)
        expectEqual(h.file.root.shapes.map(\.id), [f, g, b, m, a], "joining raises it above what the container holds")
        expectEqual(index.parent(of: m), f)
        expectEqual(index.children(of: f), [g, m])
        expectEqual(index.snapshot().descendants(of: f), [g, b, m])
        expectSnapshotAgrees(h, about: [f, g, m, a, b])

        // Deleting a container lets go of what it holds into its own container.
        h.editor.transact("Delete") { $0.delete([g]) }
        expectEqual(index.parent(of: b), f)
        expectEqual(index.children(of: f), [b, m])
        h.editor.undo()
        expectEqual(index.parent(of: b), g)
        expectEqual(index.ancestors(of: b), [g, f])
        h.editor.undo()
        h.editor.undo()
        expectEqual(index.parent(of: m), g, "undone: back where it was")
        expectEqual(index.ancestors(of: m), [g, f])
        expectSnapshotAgrees(h, about: [f, g, m, a, b])
    },

    test("a kind that both owns a board and holds shapes: what it holds comes before its board's shapes, in children, file order and keys") {
        let x = ShapeID(), a = ShapeID(), b = ShapeID(), c = ShapeID(), y = ShapeID(), d = ShapeID()
        let coffer = AnyShapeRecord(ShapeRecord(id: x, Coffer(unit)))
        let h = try graph(CanvasFile(root: board(coffer, held(box(a), in: x), box(b)),
                                     children: [x: board(box(c), corral(y), held(box(d), in: y))]),
                          more: [CorralsPlugin(), coffersPlugin()])
        let index = h.topology, snapshot = index.snapshot()
        expectEqual(index.containerKinds, [Pocket.kind, Corral.kind, Coffer.kind])
        expectEqual(index.children(of: x), [a, c, y])
        expectEqual(index.parent(of: a), x)
        expectEqual(index.parent(of: c), x)
        expectEqual(index.ancestors(of: d), [y, x])
        var order: [ShapeID] = []
        snapshot.forEachShape { record, _ in order.append(record.id) }
        expectEqual(order, [x, a, c, y, d, b])
        expectEqual(snapshot.descendants(of: x), [a, c, y, d])
        expectEqual(snapshot.fileOrderKey(of: a), [0, 1])
        expectEqual(snapshot.fileOrderKey(of: c), [0, 3], "after what the coffer holds on the root (3 shapes there)")
        expectEqual(snapshot.fileOrderKey(of: d), [0, 4, 2])
        let keyed = order.shuffled().sorted { snapshot.fileOrderKey(of: $0)!.lexicographicallyPrecedes(snapshot.fileOrderKey(of: $1)!) }
        expectEqual(keyed, order)
        // Board order lists what the coffer holds on the root with the root's shapes, then its board: the owner's
        // offset in the file order key is not in the board order key.
        let boardOrder = [x, a, b, c, y, d]
        expectEqual(snapshot.boardOrder(from: .root), boardOrder)
        expectEqual(snapshot.boardOrder(from: BoardID(owner: x)), [c, y, d])
        let boardKeys = Dictionary(uniqueKeysWithValues: boardOrder.map { ($0, snapshot.boardOrderKey(of: $0)!) })
        expectEqual(order.shuffled().sorted { boardKeys[$0]! < boardKeys[$1]! }, boardOrder)
        expect(boardKeys[a]! < boardKeys[b]! && boardKeys[b]! < boardKeys[c]!, "what the coffer holds, then the root's rest, then its board")
        expect(boardKeys[c]! < boardKeys[y]! && boardKeys[y]! < boardKeys[d]!)
        expectSnapshotAgrees(h, about: order)
    },

    test("a coffer inside a frame: board order lists the frame, the coffer, what it holds, the rest of the root, then the coffer's board") {
        let f = ShapeID(), x = ShapeID(), a = ShapeID(), e = ShapeID(), c = ShapeID(), y = ShapeID(), d = ShapeID()
        let coffer = AnyShapeRecord(ShapeRecord(id: x, Coffer(unit)))
        let h = try graph(CanvasFile(root: board(corral(f), held(coffer, in: f), held(box(a), in: x), box(e)),
                                     children: [x: board(box(c), corral(y), held(box(d), in: y))]),
                          more: [CorralsPlugin(), coffersPlugin()])
        let snapshot = h.topology.snapshot()
        expectEqual(h.topology.parent(of: x), f)
        expectEqual(h.topology.parent(of: a), x)
        let boardOrder = [f, x, a, e, c, y, d]
        expectEqual(snapshot.boardOrder(from: .root), boardOrder)
        expectEqual(snapshot.boardOrder(from: BoardID(owner: x)), [c, y, d])
        let keys = Dictionary(uniqueKeysWithValues: boardOrder.map { ($0, snapshot.boardOrderKey(of: $0)!) })
        expectEqual(boardOrder.shuffled().sorted { keys[$0]! < keys[$1]! }, boardOrder)
        expect(keys[e]! < keys[c]!, "the root's own shapes come before the board under any owner")
        expectSnapshotAgrees(h, about: boardOrder)
    },

    test("a loop of containers, which reading breaks, is never walked into, and nothing asked of it goes round for ever") {
        let a = ShapeID(), y = ShapeID(), z = ShapeID(), w = ShapeID()
        let h = try graph(CanvasFile(root: board(box(a), held(corral(y), in: z), held(corral(z), in: y), held(box(w), in: y))),
                          more: [CorralsPlugin()])
        let snapshot = h.topology.snapshot()
        var order: [ShapeID] = []
        snapshot.forEachShape { record, _ in order.append(record.id) }
        expectEqual(order, [a])
        expectEqual(snapshot.topLevel, [a])
        for id in [y, z, w] {
            expectEqual(snapshot.fileOrderKey(of: id), nil)
            expect(!snapshot.isTopLevel(id))
            expect(snapshot.descendants(of: id).count <= 3)
            expect(snapshot.ancestors(of: id).count <= 2)
        }
    },

    test("a commit may have changed board order when shapes came, went, were restacked or put in another container; an edit or a move changes none") {
        let g = ShapeID(), f = ShapeID(), a = ShapeID(), b = ShapeID()
        let h = try graph(CanvasFile(root: board(corral(g), corral(f), box(a))),
                          more: [CorralsPlugin(), Contributor(id: "order-verdicts") { $0.service { _ in OrderVerdicts() } }])
        let verdicts = try require(h.editor.service(OrderVerdicts.self))
        @MainActor func commit(_ name: String, _ body: (inout Transaction) -> Void) -> Bool {
            let before = verdicts.said.count
            h.editor.transact(name, body)
            return verdicts.said.count == before + 1 ? verdicts.said[before] : true
        }
        expect(!commit("Move") { $0.translate([a], by: CGPoint(x: 5, y: 5)) }, "a move of a box changes no board order")
        expect(!commit("Edit") { $0.update(a, as: Box.self) { $0.props.frame = unit.insetBy(dx: 1, dy: 1) } }, "nor does an edit that leaves the container")
        expect(commit("Front") { $0.bringToFront(g) }, "a restack does")
        expect(commit("Add") { $0.insert(box(b)) }, "a shape added does")
        expect(commit("Delete") { $0.delete([b]) }, "and a shape removed")
        // F is above G in the stack already, so nothing is restacked: only its container changes.
        h.editor.transact("Back") { $0.sendToBack(f) }
        h.editor.transact("Front") { $0.bringToFront(f) }
        expect(commit("Put in a frame") { $0.setContainer(f, to: g) }, "a shape put in a container does, though nothing is restacked")
        expect(commit("Take out") { $0.setContainer(f, to: nil) }, "and one taken out")
        expect(!commit("Edit again") { $0.update(a, as: Box.self) { $0.props.frame = unit } })
    },
])

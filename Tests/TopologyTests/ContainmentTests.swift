@_spi(Host) import Canvas
import CanvasTesting
import TestKit
import Topology

// Where an edge's ends are now, and what's inside what: the board tree read the same way, on boards
// the editor can show only.

@MainActor let endTests = Suite("Ends", [
    test("an end is live on its board, whichever is shown; missing once it's gone from the file; back with undo") {
        let tree = Nest()
        let h = try graph(tree.file)
        expectEqual(h.topology.end(tree.a), .live(.root))
        expectEqual(h.topology.end(tree.d), .live(tree.qBoard))
        expectEqual(h.topology.end(ShapeID()), .missing)
        expect(h.enter(tree.p))
        expectEqual(h.topology.end(tree.c), .live(tree.pBoard))
        expectEqual(h.topology.end(tree.a), .live(.root))
        expect(h.editor.showBoard(.root))
        h.editor.transact("Delete") { $0.delete([tree.p]) }
        expectEqual(h.topology.end(tree.d), .missing)
        h.editor.undo()
        expectEqual(h.topology.end(tree.d), .live(tree.qBoard))
    },

    test("an end on a board the editor can't show is unavailable; a link to one that was never there, missing") {
        let h = try graph(try hiddenFile().file)
        expectEqual(h.topology.end(id(11)), .unavailable)
        expectEqual(h.topology.end(id(10)), .live(.root), "the gadget itself is on the root, kept aside")
        expectEqual(h.topology.end(id(3)), .missing)
        h.editor.discardKeptAside(shapes: [id(10)], boards: [])
        expectEqual(h.topology.end(id(11)), .missing)
    },
])

@MainActor let containmentTests = Suite("Containment", [
    test("parent, children and ancestors follow the board tree, two deep") {
        let tree = Nest()
        let h = try graph(tree.file)
        let index = h.topology
        expectEqual(index.parent(of: tree.a), nil, "on the root")
        expectEqual(index.parent(of: tree.c), tree.p)
        expectEqual(index.parent(of: tree.d), tree.q)
        expectEqual(index.ancestors(of: tree.d), [tree.q, tree.p], "the nearest first")
        expectEqual(index.ancestors(of: tree.a), [])
        expectEqual(index.children(of: tree.p), [tree.c, tree.m, tree.q], "in document order")
        expectEqual(index.children(of: tree.q), [tree.d, tree.n])
        expectEqual(index.children(of: tree.a), [], "a box owns no board")
        expectEqual(index.children(of: ShapeID()), [])

        expect(h.enter(tree.p))
        expect(h.enter(tree.q))
        expectEqual(index.children(of: tree.q), [tree.d, tree.n], "the same, shown")
        expectEqual(index.parent(of: tree.d), tree.q)
        expectEqual(index.ancestors(of: tree.c), [tree.p])
    },

    test("isInside is strict, at any depth") {
        let tree = Nest()
        let h = try graph(tree.file)
        let index = h.topology
        expect(index.isInside(tree.d, tree.q))
        expect(index.isInside(tree.d, tree.p))
        expect(index.isInside(tree.q, tree.p))
        expect(!index.isInside(tree.p, tree.d))
        expect(!index.isInside(tree.d, tree.d))
        expect(!index.isInside(tree.a, tree.p))
        expect(!index.isInside(tree.d, ShapeID()))
    },

    test("shapes on a board the editor can't show have no parent, no ancestors, and an owner kept aside no children") {
        let h = try graph(try hiddenFile().file)
        let index = h.topology
        expectEqual(index.parent(of: id(11)), nil)
        expectEqual(index.ancestors(of: id(11)), [])
        expect(!index.isInside(id(11), id(10)))
        expectEqual(index.children(of: id(10)), [])
    },

    test("a pocket's children follow its board's commits, and go with it") {
        let tree = Nest(), e = ShapeID()
        let h = try graph(tree.file)
        h.editor.transact(on: tree.qBoard, "Add") { $0.insert(box(e)) }
        expectEqual(h.topology.children(of: tree.q), [tree.d, tree.n, e])
        expect(h.topology.isInside(e, tree.p))
        h.editor.transact("Delete") { $0.delete([tree.p]) }
        expectEqual(h.topology.children(of: tree.q), [])
        expectEqual(h.topology.parent(of: e), nil)
    },
])

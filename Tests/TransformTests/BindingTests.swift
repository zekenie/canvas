import Canvas
import CanvasTesting
import CoreGraphics
import TestKit
import Transform

// What binds or names a shape that turns, or one that moves with it: a binding to what stays, or between
// what moves, as a deletion or a cut treats it (Transaction.move's rules, through the container
// channel), and a name, which is never let go of.

private func memo(_ id: ShapeID, naming shape: ShapeID, x: CGFloat, in container: ShapeID? = nil) -> AnyShapeRecord {
    AnyShapeRecord(ShapeRecord(id: id, Memo(CGRect(x: x, y: 0, width: 40, height: 30), lead: Citation(shape)))).copy(as: id, container: container)
}

@MainActor let transformBindingTests = Suite("Turning and what binds or names a shape", [
    test("a binding between shapes that move with the corral rides along; one across its edge lets go of its end on what moved; one to the corral stays") {
        let k = ShapeID(), a = ShapeID(), b = ShapeID(), c = ShapeID(), d = ShapeID()
        let i = ShapeID(), o = ShapeID(), p = ShapeID(), q = ShapeID(), r = ShapeID(), s = ShapeID(), n = ShapeID()
        let h = try transformHarness(file: CanvasFile(root: board(corral(k, CGRect(x: 0, y: 0, width: 400, height: 300)), box(a, x: 20, y: 20, in: k),
                                                                  box(b, x: 120, y: 20, in: k), box(c, x: 600), box(d, x: 700),
                                                                  link(i, a, b), link(o, a, c), link(p, c, b), link(q, a, k), link(r, c, d), link(s, k, c),
                                                                  link(n, nil, nil))))
        let before = h.file
        expect(h.editor.transforms?.turn([k], into: Pocket.kind) == true)
        expectEqual(ids(h.contents(of: k)), [a, b, i], "bound only to what moved")
        expectEqual(h.props(i, as: Link.self), Link(from: a, to: b))
        expectEqual(h.props(o, as: Link.self), Link(from: nil, to: c), "from inside to outside: the end on what moved is let go of")
        expectEqual(h.props(p, as: Link.self), Link(from: c, to: nil), "and from outside to inside")
        expectEqual(h.props(q, as: Link.self), Link(from: nil, to: k), "one to the corral too: it's still there, as a pocket")
        expectEqual(h.props(r, as: Link.self), Link(from: c, to: d), "outside, and untouched")
        expectEqual(h.props(s, as: Link.self), Link(from: k, to: c), "bound to the turned shape, by its id")
        expectEqual(h.props(n, as: Link.self), Link(from: nil, to: nil), "bound to nothing: it stays")
        expectEqual(h.file.board(containing: n), .root)
        h.editor.undo()
        try expectFile(h, before, "every binding as it was")
    },

    test("a name of any of them is kept, wherever it is: the shape's id is the same, and the name outlives where it was") {
        let k = ShapeID(), a = ShapeID(), b = ShapeID(), m1 = ShapeID(), m2 = ShapeID(), m3 = ShapeID(), m4 = ShapeID()
        let h = try transformHarness(file: CanvasFile(root: board(corral(k, CGRect(x: 0, y: 0, width: 400, height: 300)), box(a, x: 20, y: 20, in: k),
                                                                  box(b, x: 120, y: 20, in: k), memo(m1, naming: k, x: 600), memo(m2, naming: a, x: 700),
                                                                  memo(m3, naming: b, x: 150, in: k), memo(m4, naming: k, x: 200, in: k))))
        expect(h.editor.transforms?.turn([k], into: Pocket.kind) == true)
        expectEqual(h.props(m1, as: Memo.self)?.lead, Citation(k), "a memo outside names the turned shape, which has its id")
        expectEqual(h.props(m2, as: Memo.self)?.lead, Citation(a), "one outside names a shape that moved")
        expectEqual(h.props(m3, as: Memo.self)?.lead, Citation(b), "one that moved names one that did too")
        expectEqual(h.props(m4, as: Memo.self)?.lead, Citation(k), "and one inside names the shape that now owns its board")
        expectEqual(ids(h.contents(of: k)), [a, b, m3, m4])
        expectEqual(h.file.board(containing: m1), .root)
    },
])

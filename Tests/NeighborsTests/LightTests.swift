import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Neighbors
import Queries
import Selection
import TestKit
import Topology

// What a hover lights: each light's matches in its color, a ring for each light a shape is in, a
// card for what's on another board, nothing for the subject or what's on a board above, and what a
// reference's arrows and what it stands for add. Every shape here is a fixture.

/// On the root: S, a memo quoting Q; B, which S has a wire to (link L1); C, which has a wire to S (L2);
/// M, a memo quoting S; and U, with a wire (L3) to B, which touches nothing S does.
struct Star {
    let s = ShapeID(), q = ShapeID(), b = ShapeID(), c = ShapeID(), m = ShapeID(), u = ShapeID()
    let l1 = ShapeID(), l2 = ShapeID(), l3 = ShapeID()

    /// The file, with `extra` on the root too.
    func file(adding extra: [AnyShapeRecord] = []) -> CanvasFile {
        CanvasFile(root: CanvasDocument(shapes: [memo(s, quoting: q, at: CGPoint(x: 400, y: 300)), box(q, at: CGPoint(x: 800, y: 300)),
                                                 box(b, at: CGPoint(x: 400, y: 100)), box(c, at: CGPoint(x: 100, y: 300)),
                                                 memo(m, quoting: s, at: CGPoint(x: 400, y: 500)), box(u, at: CGPoint(x: 800, y: 100)),
                                                 link(l1, s, b), link(l2, c, s), link(l3, u, b)] + extra))
    }
}

/// On the root: S, pocket P, link L from S to X and link L2 from S to Y; on P's board: X, Z, a link L3
/// from X to Z, and pocket Q, whose board holds Y.
struct Nest {
    let s = ShapeID(), p = ShapeID(), x = ShapeID(), z = ShapeID(), q = ShapeID(), y = ShapeID()
    let l = ShapeID(), l2 = ShapeID(), l3 = ShapeID()
    var pBoard: BoardID { BoardID(owner: p) }
    var qBoard: BoardID { BoardID(owner: q) }

    var file: CanvasFile {
        CanvasFile(root: CanvasDocument(shapes: [box(s, at: CGPoint(x: 100, y: 100)), pocket(p, at: CGPoint(x: 500, y: 100)), link(l, s, x), link(l2, s, y)]),
                   children: [p: CanvasDocument(shapes: [box(x, at: CGPoint(x: 100, y: 100)), box(z, at: CGPoint(x: 400, y: 100)),
                                                         pocket(q, at: CGPoint(x: 100, y: 400)), link(l3, x, z)]),
                              q: CanvasDocument(shapes: [box(y, at: CGPoint(x: 100, y: 100))])])
    }
}

@MainActor let lightTests = Suite("Neighbors: what a hover lights", [
    test("a hover lights what each light matches, in its color: what it points to and the arrows out, what points to it, what it quotes, what quotes it") {
        let star = Star()
        let h = try neighborHarness(star.file())
        expectEqual(h.lit, [], "nothing hovered, nothing lit")
        h.editor.hovered = star.s
        h.settle()
        expectEqual(h.lit, [Lit(.out, 0, [star.b, star.l1]), Lit(.into, 0, [star.c, star.l2]), Lit(.quotes, 0, [star.q]), Lit(.quoted, 0, [star.m])])
        expectEqual(h.faint, [star.s], "the subject is on the board shown: Selection's faint outline is all there is of it")
        expectEqual(h.neighbors.subject, star.s)
        h.editor.hovered = nil
        h.wait(0)
        expectEqual(h.lit, [], "the lights go with the hover, at once")
        expectEqual(h.neighbors.subject, nil)
        expect(!h.neighbors.isAsking)
    },
    test("every light is asked in one batch: the engine takes up the file once, in the one view when nothing stands in, and each shape is lit once") {
        let star = Star()
        let h = try neighborHarness(star.file())
        h.editor.hovered = star.b
        h.settle()
        // Two wires end at B, S's and U's, with the shapes they start at.
        expectEqual(h.lit, [Lit(.into, 0, [star.s, star.u, star.l1, star.l3])])
        #if DEBUG
        let queries = try require(h.editor.queries)
        expectEqual(queries.captures, 1, "one batch for the four lights")
        expectEqual(h.neighbors.requested, 4, "each in the one view: with no stand-in the literal view is the same edges")
        expectEqual(queries.liveSnapshots, 0, "nothing held once it's answered")
        #endif
    },
    test("the literal view is asked where a shape stands in, and only then: a pill added makes the next ask read both views") {
        let a = ShapeID(), n = ShapeID(), r = ShapeID(), wire = ShapeID(), into = ShapeID()
        let h = try neighborHarness(CanvasFile(root: board(box(a), box(n, at: CGPoint(x: 500, y: 0)), link(wire, a, n))))
        h.editor.hovered = a
        h.settle()
        expectEqual(h.lit, [Lit(.out, 0, [n, wire])])
        #if DEBUG
        expectEqual(h.neighbors.requested, 4)
        #endif
        // A pill standing for N, and a wire to it: A's, as drawn, ends at the pill and, as the graph reads it, at N.
        h.editor.transact("Pill") {
            $0.insert(pill(r, standingFor: [n], at: CGPoint(x: 250, y: 200)))
            $0.insert(link(into, a, r))
        }
        h.settle()
        expectEqual(h.lit, [Lit(.out, 0, [n, r, wire, into])])
        #if DEBUG
        expectEqual(h.neighbors.requested, 4 + 8, "the four lights in the two views, once a pill stands in")
        #endif
    },
    test("a shape in two lights has a ring for each, the first in the first ring: its second light's is a ring further out") {
        let star = Star()
        let extra = link(ShapeID(), star.s, star.c)                       // S has a wire to C, which has one to S
        let h = try neighborHarness(star.file(adding: [extra]))
        h.editor.hovered = star.s
        h.settle()
        expectEqual(h.lit, [Lit(.out, 0, [star.b, star.c, star.l1, extra.id]), Lit(.into, 0, [star.l2]), Lit(.into, 1, [star.c]),
                            Lit(.quotes, 0, [star.q]), Lit(.quoted, 0, [star.m])])
    },
    test("a shape in three lights has three rings; the subject is in none, though it matches itself") {
        let s = ShapeID(), x = ShapeID(), out = ShapeID(), into = ShapeID()
        let h = try neighborHarness(CanvasFile(root: board(memo(s, quoting: x), box(x, at: CGPoint(x: 300, y: 0)), link(out, s, x), link(into, x, s))))
        h.editor.hovered = s
        h.settle()
        expectEqual(h.lit, [Lit(.out, 0, [x, out]), Lit(.into, 0, [into]), Lit(.into, 1, [x]), Lit(.quotes, 2, [x])])
        // A shape that is its own neighbor: a wire to itself and a quote of itself.
        let loops = ShapeID(), loop = ShapeID()
        let again = try neighborHarness(CanvasFile(root: board(memo(loops, quoting: loops), link(loop, loops, loops))))
        again.editor.hovered = loops
        again.settle()
        expectEqual(again.lit, [Lit(.out, 0, [loop]), Lit(.into, 1, [loop])], "the link, which starts and ends at it; never the shape itself")
    },
    test("a shape on a pocket's board lights the pocket that holds it, once, however many of its shapes match") {
        let nest = Nest()
        let h = try neighborHarness(nest.file)
        h.editor.hovered = nest.s
        h.settle()
        // X is on P's board and Y is two boards down, on Q's, which is on P's: both are drawn as P.
        expectEqual(h.lit, [Lit(.out, 0, [nest.p, nest.l, nest.l2])])
        expectEqual(h.faint, [nest.s], "S is on the board shown, hovered: its faint outline is Selection's")
    },
    test("a shape on a board above lights nothing: on a pocket's board, what's on the root isn't lit, what's there is") {
        let nest = Nest()
        let h = try neighborHarness(nest.file)
        expect(h.enter(nest.p))
        h.editor.hovered = nest.x
        h.settle()
        // X's wire to Z is on this board; S's wire to X is on the root, with S.
        expectEqual(h.lit, [Lit(.out, 0, [nest.z, nest.l3])])
        // Hovering Z, which only X has a wire to: X and the link.
        h.editor.hovered = nest.z
        h.settle()
        expectEqual(h.lit, [Lit(.into, 0, [nest.x, nest.l3])])
        // Hovering Q (a pocket here), which nothing connects: nothing.
        h.editor.hovered = nest.q
        h.settle()
        expectEqual(h.lit, [])
    },
    test("a shape in a frame on a pocket's board lights the pocket, not the frame: the frame isn't on the board shown either") {
        let s = ShapeID(), p = ShapeID(), f = ShapeID(), x = ShapeID(), l = ShapeID()
        // On the root: S and pocket P, and a wire from S to X, which is in frame F on P's board.
        let h = try neighborHarness(CanvasFile(root: board(box(s), pocket(p, at: CGPoint(x: 400, y: 0)), link(l, s, x)),
                                               children: [p: board(corral(f), held(box(x), in: f))]))
        h.editor.hovered = s
        h.settle()
        expectEqual(h.lit, [Lit(.out, 0, [p, l])])
        // On P's board X is where it is, in its frame, and S and the wire are on the root, above it.
        expect(h.enter(p))
        h.editor.hovered = x
        h.settle()
        expectEqual(h.lit, [])
        h.editor.hovered = f
        h.settle()
        expectEqual(h.lit, [], "the frame has no edge of its own")
    },
    test("a reference's own arrows count, and so does what it stands for: both views are asked where a shape stands in") {
        // A has a wire to a pill that stands for N.
        let a = ShapeID(), n = ShapeID(), r = ShapeID(), wire = ShapeID()
        let h = try neighborHarness(CanvasFile(root: board(box(a), box(n, at: CGPoint(x: 500, y: 0)), pill(r, standingFor: [n], at: CGPoint(x: 250, y: 200)),
                                                           link(wire, a, r))))
        // What it points to is the pill as drawn and N as the graph reads it, and the arrow.
        h.editor.hovered = a
        h.settle()
        expectEqual(h.lit, [Lit(.out, 0, [n, r, wire])])
        // N is pointed to by A (through the pill), by the pill (it stands for N), and the arrow into it.
        h.editor.hovered = n
        h.settle()
        expectEqual(h.lit, [Lit(.into, 0, [a, r, wire])])
        // The pill points to what it stands for, and is pointed to as drawn.
        h.editor.hovered = r
        h.settle()
        expectEqual(h.lit, [Lit(.out, 0, [n]), Lit(.into, 0, [a, wire])])
        #if DEBUG
        expectEqual(h.neighbors.requested, 3 * 8, "four lights in the two views, for each of the three hovers")
        #endif
    },
    test("an arrow hovered lights where it ends as what it points to, and where it starts as what points to it") {
        let star = Star()
        let h = try neighborHarness(star.file())
        h.editor.hovered = star.l1                          // from S to B
        h.settle()
        expectEqual(h.lit, [Lit(.out, 0, [star.b]), Lit(.into, 0, [star.s])])
        h.editor.hovered = star.l2                          // from C to S
        h.settle()
        expectEqual(h.lit, [Lit(.out, 0, [star.s]), Lit(.into, 0, [star.c])])
    },
    test("a light the engine refuses lights nothing, and the others still do") {
        let star = Star()
        let lights = [NeighborLight(color: Light.out.color) { ":edge-from(\($0), nonesuch)" }, testLights()[1]]
        let h = try neighborHarness(star.file(), lights: lights)
        h.editor.hovered = star.s
        h.settle()
        expectEqual(h.lit, [Lit(.into, 0, [star.c, star.l2])])
    },
    test("a shape deleted while lit is dropped from the lights at once: it needs no new answer") {
        let star = Star()
        let h = try neighborHarness(star.file())
        h.editor.hovered = star.s
        h.settle()
        #if DEBUG
        let asked = h.neighbors.asked
        #endif
        // Q is quoted by the subject's memo: the name outlives it, so the quote edge is the same.
        h.editor.transact("Delete") { $0.delete([star.q]) }
        expectEqual(h.lit, [Lit(.out, 0, [star.b, star.l1]), Lit(.into, 0, [star.c, star.l2]), Lit(.quoted, 0, [star.m])], "Q is no longer lit")
        #if DEBUG
        expectEqual(h.neighbors.asked, asked, "nothing asked: a name outlives the shape, and the edges didn't change")
        #endif
        h.editor.undo()
        h.settle()
        expectEqual(h.lit.count, 4, "undone, it's lit again")
        expect(h.lit.contains(Lit(.quotes, 0, [star.q])))
        #if DEBUG
        expectEqual(h.neighbors.asked, asked, "and nothing asked: the answer had matched it")
        #endif
    },
])

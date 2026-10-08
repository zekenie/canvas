import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Neighbors
import Queries
import Selection
import TestKit

// What the subject is, and how the answer for it comes: the pointer on a shape, a shape hovered
// elsewhere (the shape of a row of another board's shapes, which the canvas doesn't show), the answer
// for the shape before staying until the next lands, a hover that changes cancelling the ask, the
// lights going with a session or a board.

@MainActor let subjectTests = Suite("Neighbors: the subject and its answer", [
    test("the pointer on a shape hovers it, which lights its neighbors; off the shape lights none") {
        let a = ShapeID(), b = ShapeID(), l = ShapeID()
        let h = try neighborHarness(CanvasFile(root: board(box(a, at: CGPoint(x: 100, y: 100)), box(b, at: CGPoint(x: 400, y: 100)), link(l, a, b))))
        h.move(to: CGPoint(x: 110, y: 110))               // a's corner, clear of the link between the middles
        h.settle()
        expectEqual(h.editor.hovered, a)
        expectEqual(h.lit, [Lit(.out, 0, [b, l])])
        h.move(to: CGPoint(x: 600, y: 500))               // empty canvas
        h.wait(0)
        expectEqual(h.editor.hovered, nil)
        expectEqual(h.lit, [])
        h.move(to: CGPoint(x: 410, y: 110))               // b's corner
        h.settle()
        expectEqual(h.lit, [Lit(.into, 0, [a, l])])
    },
    test("a shape hovered elsewhere is the subject, its card faint and never lit; on the board shown it's the hover that is") {
        let nest = Nest()
        let h = try neighborHarness(nest.file)
        // X is on P's board, which the canvas doesn't show: where a list shows its row the shape is hovered
        // elsewhere, and it lights what it's connected to there.
        h.editor.hoveredElsewhere = nest.x
        h.settle()
        expectEqual(h.editor.hovered, nil)
        expectEqual(h.neighbors.subject, nest.x)
        // S, and the wire from it to X, are on the board shown. What X has a wire to (Z, the wire) is on P's board,
        // which is the card X is on: outlined faintly, never lit.
        expectEqual(h.lit, [Lit(.into, 0, [nest.s, nest.l])])
        expectEqual(h.faint, [nest.p], "where X is: Selection outlines the card that holds it")
        h.editor.hoveredElsewhere = nil
        h.wait(0)
        expectEqual(h.lit, [])
        expectEqual(h.faint, [])
        expectEqual(h.neighbors.subject, nil)
        // A shape on the board shown isn't hovered elsewhere (that's the hover): setting it names no subject.
        h.editor.hoveredElsewhere = nest.s
        h.settle()
        expectEqual(h.editor.hoveredElsewhere, nil)
        expectEqual(h.neighbors.subject, nil)
        expectEqual(h.lit, [])
    },
    test("a shape that's two boards down is on its pocket: the nearest card on the board shown is outlined faintly") {
        let nest = Nest()
        let h = try neighborHarness(nest.file)
        h.editor.hoveredElsewhere = nest.y                // on Q's board, under P's
        h.settle()
        expectEqual(h.lit, [Lit(.into, 0, [nest.s, nest.l2])])
        expectEqual(h.faint, [nest.p], "Y is on Q's board, which is on P's: P is where it is, on the board shown")
    },
    test("what's hovered on the canvas wins over a shape hovered elsewhere, and that is the subject again when it's let go of") {
        let nest = Nest()
        let h = try neighborHarness(nest.file)
        h.editor.hoveredElsewhere = nest.x
        h.settle()
        expectEqual(h.neighbors.subject, nest.x)
        h.editor.hovered = nest.s
        h.settle()
        expectEqual(h.neighbors.subject, nest.s)
        expectEqual(h.lit, [Lit(.out, 0, [nest.p, nest.l, nest.l2])])
        expectEqual(h.faint, [nest.s], "S is on the board shown: only the hover is outlined, not a card")
        h.editor.hovered = nil
        h.settle()
        expectEqual(h.neighbors.subject, nest.x, "the pointer is still on X's row")
        expectEqual(h.lit, [Lit(.into, 0, [nest.s, nest.l])])
        expectEqual(h.faint, [nest.p])
    },
    test("the answer for the shape before stays until the next lands; the lights go when the subject does") {
        let star = Star()
        let h = try neighborHarness(star.file())
        h.editor.hovered = star.s
        h.settle()
        let before = h.lit
        expectEqual(before.count, 4)
        h.editor.hovered = star.b
        h.wait(0)
        expect(h.neighbors.isAsking, "B's answer is on its way")
        expectEqual(h.neighbors.subject, star.b)
        expectEqual(h.lit, before, "S's lights stay")
        h.settle()
        expectEqual(h.lit, [Lit(.into, 0, [star.s, star.u, star.l1, star.l3])])
        h.editor.hovered = nil
        h.wait(0)
        expectEqual(h.lit, [], "no turn of the run loop: gone at once")
        h.editor.hovered = star.c
        h.settle()
        expectEqual(h.lit, [Lit(.out, 0, [star.s, star.l2])], "and each hover after asks, as the first does")
    },
    test("`landed()` returns once the answer is in, at once when none is on its way, and again after a re-ask") {
        let star = Star()
        let h = try neighborHarness(star.file())
        let neighbors = h.neighbors
        try awaitResult { await neighbors.landed() }          // nothing asked
        h.editor.hovered = star.s
        h.wait(0)
        expect(neighbors.isAsking)
        try awaitResult { await neighbors.landed() }
        expect(!neighbors.isAsking)
        expectEqual(h.lit.count, 4, "the lights are in when it returns")
        // A commit to the subject's edges asks again, which landed() waits out as well.
        let added = ShapeID()
        h.editor.transact("Link") { $0.insert(link(added, star.s, star.u)) }
        try awaitResult { await neighbors.landed() }
        expectEqual(h.lit.first, Lit(.out, 0, [star.b, star.u, star.l1, added]))
    },
    test("a hover that changes lets go of the ask running: only the new subject's answer lands, and the engine takes up the file once") {
        let star = Star()
        let h = try neighborHarness(star.file())
        let queries = try require(h.editor.queries)
        #if DEBUG
        let captures = queries.captures
        #endif
        h.editor.hovered = star.s
        h.wait(0)                                         // the ask for S is out, its task not yet run
        h.editor.hovered = star.b
        h.wait(0)                                         // S's is let go of, B's is out
        h.settle()
        expectEqual(h.neighbors.subject, star.b)
        expectEqual(h.lit, [Lit(.into, 0, [star.s, star.u, star.l1, star.l3])])
        #if DEBUG
        expectEqual(h.neighbors.asked, 2)
        expectEqual(queries.captures - captures, 1, "S's never took up the file")
        expectEqual(queries.liveSnapshots, 0)
        #endif
    },
    test("an answer for a shape that isn't the subject any more lands nothing") {
        let star = Star()
        let h = try neighborHarness(star.file())
        h.editor.hovered = star.s
        h.wait(0)                                         // asked: the answer is for S
        h.editor.hovered = nil                            // the hover goes before it lands
        h.wait(0)
        expect(!h.neighbors.isAsking, "the ask is let go of")
        h.settle()
        expectEqual(h.lit, [], "and nothing it found is kept")
    },
    test("another board shown clears what's lit, and an ask out for the board left lands nothing") {
        let nest = Nest()
        let h = try neighborHarness(nest.file)
        h.editor.hovered = nest.s
        h.settle()
        expectEqual(h.lit.count, 1)
        expect(h.enter(nest.p))
        expectEqual(h.lit, [], "at once, with the switch")
        h.settle()
        expectEqual(h.neighbors.subject, nil)
        // An ask under way as the board changes.
        h.editor.hovered = nest.x
        h.wait(0)
        expect(h.neighbors.isAsking)
        expect(h.editor.showBoard(.root))
        h.settle()
        expectEqual(h.lit, [])
        expectEqual(h.neighbors.subject, nil)
        // And the next hover, on the board shown now, asks as ever.
        h.editor.hovered = nest.s
        h.settle()
        expectEqual(h.lit, [Lit(.out, 0, [nest.p, nest.l, nest.l2])])
        // A shape hovered elsewhere goes with the board shown too (and X is on it, once P's is).
        h.editor.hoveredElsewhere = nest.x
        h.editor.hovered = nil
        h.settle()
        expectEqual(h.neighbors.subject, nest.x)
        expect(h.enter(nest.p))
        h.settle()
        expectEqual(h.editor.hoveredElsewhere, nil)
        expectEqual(h.neighbors.subject, nil)
        expectEqual(h.lit, [])
        expectEqual(h.faint, [])
    },
    test("nothing is outlined while a session runs, and what was lit shows again once it ends") {
        let star = Star()
        let h = try neighborHarness(star.file())
        h.editor.hovered = star.s
        h.settle()
        let lit = h.lit
        expectEqual(lit.count, 4)
        h.editor.session = IdleSession()
        expectEqual(h.lit, [], "no tint while a drag runs")
        expectEqual(h.faint, [])
        h.editor.session = nil
        expectEqual(h.lit, lit, "the hover is where it was")
        // An ask that lands during a session is kept for when it ends.
        h.editor.hovered = star.b
        h.wait(0)
        h.editor.session = IdleSession()
        h.settle()
        expectEqual(h.lit, [])
        h.editor.session = nil
        expectEqual(h.lit, [Lit(.into, 0, [star.s, star.u, star.l1, star.l3])])
    },
    test("without the query engine nothing is asked or lit, and with no light nor") {
        let star = Star()
        let bare = try neighborHarness(star.file(), queries: false)
        bare.editor.hovered = star.s
        bare.settle()
        expectEqual(bare.lit, [])
        expect(!bare.neighbors.isAsking)
        #if DEBUG
        expectEqual(bare.neighbors.asked, 0)
        #endif
        let dark = try neighborHarness(star.file(), lights: [])
        dark.editor.hovered = star.s
        dark.settle()
        expectEqual(dark.lit, [])
        #if DEBUG
        expectEqual(dark.neighbors.asked, 0)
        #endif
    },
])

import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Neighbors
import Queries
import Selection
import TestKit
import Topology

// What keeps the lights right as the file changes under the hover: a change to the edges of the
// subject or of what's lit asks again, one to others' doesn't; an arrow hovered is asked about again
// when its own edge changes, though a change lists only its ends; a shape that comes back is lit; where
// a lit shape is (a move onto a pocket's board, a deletion) is worked out again without asking, and
// only by a commit that names what's lit; a drag's every event costs a look at its change set; a
// provide that changes what a stand-in stands for asks again; and the canvas draws again only when
// what's outlined changed.

@MainActor let upkeepTests = Suite("Neighbors: keeping up with the file", [
    test("it asks again when a commit changes the edges of the subject or of what's lit, or adds a shape no answer matched, and not when it changes others' or only moves shapes") {
        let star = Star()
        let x = ShapeID(), y = ShapeID(), y2 = ShapeID(), w = ShapeID()      // a wire between two shapes that touch nothing S does
        let h = try neighborHarness(star.file(adding: [box(x, at: CGPoint(x: 1200, y: 100)), box(y, at: CGPoint(x: 1200, y: 300)),
                                                       box(y2, at: CGPoint(x: 1200, y: 500)), link(w, x, y)]))
        h.editor.hovered = star.s
        h.settle()
        #if DEBUG
        expectEqual(h.reach.asked, 1)
        #endif
        // A wire from S to U, added: S's edges changed.
        let added = ShapeID()
        h.editor.transact("Link") { $0.insert(link(added, star.s, star.u)) }
        h.settleCommits()
        expectEqual(h.lit, [Lit(.out, 0, [star.b, star.u, star.l1, added]), Lit(.into, 0, [star.c, star.l2]), Lit(.quotes, 0, [star.q]),
                            Lit(.quoted, 0, [star.m])], "U and the wire are lit")
        #if DEBUG
        expectEqual(h.reach.asked, 2, "once, though the commit added a shape no answer had matched: its edges asked already")
        #endif
        // Another wire's end moved between two others, and a drag's moves, one of S itself and one of a shape lit: none asks.
        h.editor.transact("Rewire") { $0.update(w, as: Link.self) { $0.props.to = y2 } }
        h.settleCommits()
        h.editor.transact("Move") { $0.moveBox(star.b, to: CGPoint(x: 1000, y: 1000)) }
        h.editor.transact("Move") { $0.moveBox(star.s, to: CGPoint(x: 700, y: 700)) }
        h.settleCommits()
        #if DEBUG
        expectEqual(h.reach.asked, 2, "other shapes' edges, and moves, ask nothing")
        #endif
        // That wire moved to a shape that's lit (C): not S's edge, but the answer's shapes are what a change may touch.
        h.editor.transact("Rewire") { $0.update(w, as: Link.self) { $0.props.to = star.c } }
        h.settleCommits()
        #if DEBUG
        expectEqual(h.reach.asked, 3, "a change that touches what was matched asks again")
        #endif
        // A shape added that no answer matched: the lights are queries, and a new shape may be what one finds.
        h.editor.transact("Add") { $0.insert(box(ShapeID(), at: CGPoint(x: 1500, y: 100))) }
        h.settleCommits()
        #if DEBUG
        expectEqual(h.reach.asked, 4)
        #endif
        // The wire taken out again, and put back.
        h.editor.transact("Delete") { $0.delete([added]) }
        h.settleCommits()
        expectEqual(h.lit.first, Lit(.out, 0, [star.b, star.l1]), "U and the wire aren't lit any more")
        #if DEBUG
        expectEqual(h.reach.asked, 5)
        #endif
        h.editor.undo()
        h.settleCommits()
        expectEqual(h.lit.first, Lit(.out, 0, [star.b, star.u, star.l1, added]))
        #if DEBUG
        expectEqual(h.reach.asked, 6)
        #endif
    },
    test("a commit on the subject's edges in the middle of an ask asks again once commits have settled: what lands is the file as it is") {
        let star = Star()
        let h = try neighborHarness(star.file())
        h.editor.hovered = star.s
        h.wait(0)                                          // the ask is out, its task not yet run
        let added = ShapeID()
        h.editor.transact("Link") { $0.insert(link(added, star.s, star.u)) }
        h.settleCommits()
        expectEqual(h.lit.first, Lit(.out, 0, [star.b, star.u, star.l1, added]))
        #if DEBUG
        expectEqual(h.reach.asked, 2)
        expectEqual(try require(h.editor.queries).captures, 2, "the first ask was let go of before it took up the file: the second's one hop and reach are the two")
        #endif
    },
    test("an arrow hovered is asked about again when its edge changes, though a change lists its ends and never the arrow: re-aimed and undone, let go of and bound again") {
        let star = Star()
        let h = try neighborHarness(star.file())
        h.editor.hovered = star.l1                         // from S to B
        h.settle()
        expectEqual(h.lit, [Lit(.out, 0, [star.b]), Lit(.into, 0, [star.s])])
        #if DEBUG
        expectEqual(h.reach.asked, 1)
        #endif
        // Re-aimed at C: the change lists S, B and C, and B is where the last answer matched it.
        h.editor.transact("Rewire") { $0.update(star.l1, as: Link.self) { $0.props.to = star.c } }
        h.settleCommits()
        expectEqual(h.lit, [Lit(.out, 0, [star.c]), Lit(.into, 0, [star.s])])
        #if DEBUG
        expectEqual(h.reach.asked, 2, "once: the commit names the arrow too, but its edges' ask is the one")
        #endif
        h.editor.undo()
        h.settleCommits()
        expectEqual(h.lit, [Lit(.out, 0, [star.b]), Lit(.into, 0, [star.s])], "and undone, back")
        #if DEBUG
        expectEqual(h.reach.asked, 3)
        #endif
        // An end let go of: no edge, so nothing's lit.
        h.editor.transact("Detach") { $0.update(star.l1, as: Link.self) { $0.props.to = nil } }
        h.settleCommits()
        expectEqual(h.lit, [])
        #if DEBUG
        expectEqual(h.reach.asked, 4)
        #endif
        // Bound again: the arrow carried no edge, so no end was matched and the change lists none of them
        // that the answer had: only the arrow's own record says so.
        h.editor.transact("Attach") { $0.update(star.l1, as: Link.self) { $0.props.to = star.q } }
        h.settleCommits()
        expectEqual(h.lit, [Lit(.out, 0, [star.q]), Lit(.into, 0, [star.s])])
        #if DEBUG
        expectEqual(h.reach.asked, 5)
        #endif
        // The arrow moved by an end that's deleted: the end is let go of where it is.
        h.editor.transact("Delete") { $0.delete([star.q]) }
        h.settleCommits()
        expectEqual(h.lit, [])
        #if DEBUG
        expectEqual(h.reach.asked, 6)
        #endif
        h.editor.undo()
        h.settleCommits()
        expectEqual(h.lit, [Lit(.out, 0, [star.q]), Lit(.into, 0, [star.s])], "undone: the end is bound again")
    },
    test("a shape deleted before the hover and brought back after it is lit when it comes back: what names it outlived it, so no edge changed") {
        let star = Star()
        let h = try neighborHarness(star.file())
        h.editor.transact("Delete") { $0.delete([star.q]) }          // S quotes Q: the quote stays
        h.editor.hovered = star.s
        h.settle()
        expectEqual(h.lit, [Lit(.out, 0, [star.b, star.l1]), Lit(.into, 0, [star.c, star.l2]), Lit(.quoted, 0, [star.m])], "Q isn't a shape: nothing to light")
        #if DEBUG
        expectEqual(h.reach.asked, 1)
        #endif
        h.editor.undo()
        h.settleCommits()
        expectEqual(h.lit, [Lit(.out, 0, [star.b, star.l1]), Lit(.into, 0, [star.c, star.l2]), Lit(.quotes, 0, [star.q]), Lit(.quoted, 0, [star.m])],
                    "Q is back, and lit")
        #if DEBUG
        expectEqual(h.reach.asked, 2, "a shape came that the answer hadn't matched: the quote of it may reach it now")
        #endif
        // A shape on another board, put back there: one the answer hadn't matched, which another board's commit names.
        let s = ShapeID(), p = ShapeID(), q = ShapeID()
        let nested = try neighborHarness(CanvasFile(root: board(memo(s, quoting: q), pocket(p, at: CGPoint(x: 400, y: 0))),
                                                    children: [p: board(box(q), box(ShapeID(), at: CGPoint(x: 300, y: 0)))]))
        let pBoard = BoardID(owner: p)
        nested.editor.transact(on: pBoard, "Delete") { $0.delete([q]) }
        nested.editor.hovered = s
        nested.settle()
        expectEqual(nested.lit, [])
        nested.editor.transact(on: pBoard, "Restore") { $0.insert(box(q)) }
        nested.settleCommits()
        expectEqual(nested.lit, [Lit(.quotes, 0, [p])], "Q is on P's board: P is where it's drawn")
    },
    test("a lit shape moved onto a pocket's board is drawn as the pocket once the answer after the commit lands; a drag's moves ask and work out nothing") {
        let s = ShapeID(), b = ShapeID(), p = ShapeID()
        let h = try neighborHarness(CanvasFile(root: board(memo(s, quoting: b), box(b, at: CGPoint(x: 400, y: 0)), pocket(p, at: CGPoint(x: 800, y: 0)))))
        h.editor.hovered = s
        h.settle()
        expectEqual(h.lit, [Lit(.quotes, 0, [b])])
        #if DEBUG
        let asked = h.reach.asked, composed = h.reach.composed
        #endif
        h.editor.transact("Move") { _ = $0.move([b], toBoardOwnedBy: p) }
        expectEqual(h.lit, [Lit(.quotes, 0, [b])], "the commit works out nothing itself")
        h.settleCommits()
        expectEqual(h.lit, [Lit(.quotes, 0, [p])], "drawn as the pocket once the answer after the commit lands")
        #if DEBUG
        expectEqual(h.reach.asked, asked + 1, "a matched shape left the board, so it asks again, though the quote is a name and the file's edges are the same")
        expect(h.reach.composed > composed, "and works out what shows when it lands")
        #endif
        // A drag's every event, a nudge of what's lit among them (a shape and the pocket it's drawn as), asks and works out nothing.
        h.wait(200)                                        // the pointer has rested, the reach settled
        #if DEBUG
        let before = h.reach.composed, askedBefore = h.reach.asked
        #endif
        for step in 1...5 {
            h.editor.transact("Move") { $0.moveBox(s, to: CGPoint(x: CGFloat(step) * 10, y: 0)) }
            h.editor.transact("Move") { $0.moveBox(p, to: CGPoint(x: 800 + CGFloat(step) * 10, y: 0)) }
        }
        h.settleCommits()
        #if DEBUG
        expectEqual(h.reach.composed, before, "moves work out nothing")
        expectEqual(h.reach.asked, askedBefore, "and ask nothing")
        #endif
        expectEqual(h.lit, [Lit(.quotes, 0, [p])])
        // Deleting the pocket takes B with its board: nothing is there to light.
        h.editor.transact("Delete") { $0.delete([p]) }
        h.settleCommits()
        expectEqual(h.lit, [])
        h.editor.undo()
        h.settleCommits()
        expectEqual(h.lit, [Lit(.quotes, 0, [p])], "and undone, the pocket and what it holds are back")
    },
    test("a lit shape moved down a board and back is drawn as the pocket, then as itself, each once the answer after the commit lands") {
        let p = ShapeID(), q = ShapeID(), x = ShapeID(), z = ShapeID()
        // On P's board: a memo X quoting Z, Z, and an empty pocket Q.
        let h = try neighborHarness(CanvasFile(root: board(pocket(p)),
                                               children: [p: board(memo(x, quoting: z), box(z, at: CGPoint(x: 300, y: 0)), pocket(q, at: CGPoint(x: 600, y: 0))),
                                                          q: board()]))
        expect(h.enter(p))
        h.editor.hovered = x
        h.settle()
        expectEqual(h.lit, [Lit(.quotes, 0, [z])])
        #if DEBUG
        let asked = h.reach.asked
        #endif
        h.editor.transact("Move") { _ = $0.move([z], toBoardOwnedBy: q) }
        h.settleCommits()
        expectEqual(h.lit, [Lit(.quotes, 0, [q])], "Z is on Q's board: Q is where it's drawn here")
        h.editor.transact("Move") { _ = $0.move([z], from: BoardID(owner: q), to: BoardID(owner: p)) }
        h.settleCommits()
        expectEqual(h.lit, [Lit(.quotes, 0, [z])], "and back, it's itself")
        #if DEBUG
        expectEqual(h.reach.asked, asked + 2, "each move of a matched shape between boards asks again")
        #endif
        // A card that's the pocket the subject is in never lights: X is on P's board, where nothing is above it.
        h.editor.transact("Move") { _ = $0.move([x], toBoardOwnedBy: q) }
        h.settleCommits()
        expectEqual(h.reach.subject, nil, "the shape moved off the board shown ends its hover")
        h.wait(150)
        expectEqual(h.lit, [], "and what it lit goes with the release")
    },
    test("a commit that names nothing lit asks and works out nothing: an unrelated shape edited or restacked, and a drag; one that names what's lit asks again") {
        let star = Star()
        let x = ShapeID(), y = ShapeID()
        let h = try neighborHarness(star.file(adding: [box(x, at: CGPoint(x: 1200, y: 100)), box(y, at: CGPoint(x: 1200, y: 300))]))
        h.editor.hovered = star.s
        h.settle()
        #if DEBUG
        let asked = h.reach.asked, composed = h.reach.composed
        #endif
        let lit = h.lit
        // A shape that isn't lit, resized (an edit) and brought to the front (a restack), and a lit one dragged.
        h.editor.transact("Resize") { $0.update(x, as: Box.self) { $0.props.frame.size.width = 200 } }
        h.editor.transact("Front") { $0.bringToFront(y) }
        h.editor.transact("Move") { $0.moveBox(x, to: CGPoint(x: 1300, y: 100)) }
        h.editor.transact("Move") { $0.moveBox(star.b, to: CGPoint(x: 400, y: 120)) }
        h.editor.transact("Move") { $0.moveBox(star.s, to: CGPoint(x: 410, y: 310)) }
        h.settleCommits()
        #if DEBUG
        expectEqual(h.reach.composed, composed, "an edit, a restack and moves of others, and of what's lit, work out nothing")
        expectEqual(h.reach.asked, asked, "and ask nothing")
        #endif
        expectEqual(h.lit, lit)
        // A lit shape restacked or edited is named: asked again once the commits settle (the edges are the same, so what shows is too).
        h.editor.transact("Front") { $0.bringToFront(star.b) }
        h.settleCommits()
        #if DEBUG
        expectEqual(h.reach.asked, asked + 1, "a restack of a lit shape")
        expect(h.reach.composed > composed, "and works out what shows when its answers land")
        #endif
        h.editor.transact("Resize") { $0.update(star.c, as: Box.self) { $0.props.frame.size.width = 200 } }
        h.settleCommits()
        #if DEBUG
        expectEqual(h.reach.asked, asked + 2, "an edit of one")
        #endif
        expectEqual(h.lit, lit)
    },
    test("the canvas is asked to draw only when what's outlined changes: lighting something, the answer for a shape lighting nothing after it, and the lights going with the release") {
        let star = Star()
        let lone = ShapeID(), other = ShapeID()
        let h = try neighborHarness(star.file(adding: [box(lone, at: CGPoint(x: 1200, y: 100)), box(other, at: CGPoint(x: 1200, y: 300))]))
        let redraws = Redraws()
        h.editor.delegate = redraws
        // Nothing is connected to either: the answers light nothing.
        h.editor.hovered = lone
        var drawn = redraws.count
        h.settle()
        expectEqual(h.lit, [])
        expectEqual(redraws.count, drawn, "an answer that lights nothing, after nothing lit, draws nothing")
        h.editor.hovered = other
        drawn = redraws.count
        h.settle()
        expectEqual(redraws.count, drawn, "nor the next")
        // An answer that lights something draws, and so does what it lights going: the answer for a shape lighting nothing.
        h.editor.hovered = star.s
        drawn = redraws.count
        h.settle()
        expectEqual(h.lit.count, 4)
        expect(redraws.count > drawn, "lighting four groups draws")
        h.editor.hovered = lone
        drawn = redraws.count
        h.settle()
        expectEqual(h.lit, [])
        expect(redraws.count > drawn, "and so does the answer that lights nothing, after four groups")
        h.editor.hovered = star.s
        h.settle()
        expectEqual(h.lit.count, 4)
        h.editor.hovered = nil
        h.wait(0)
        drawn = redraws.count
        h.wait(150)
        expectEqual(h.lit, [])
        expect(redraws.count > drawn, "the lights going with the release")
        // Hovered and let go of with nothing lit: nothing to go.
        h.editor.hovered = other
        h.settle()
        h.editor.hovered = nil
        h.wait(0)
        drawn = redraws.count
        h.wait(150)
        expectEqual(h.lit, [])
        expectEqual(redraws.count, drawn, "none lit, none to go")
    },
    test("a shape deleted while its reach shows: once the commit settles, the reach is gone with it, not kept for the release") {
        let star = Star()
        let h = try neighborHarness(star.file())
        h.editor.hovered = star.s
        h.settle()
        h.wait(200)                                        // rested: the reach, and the dim
        expect(!h.editor.outlines.tinted.isEmpty)
        h.editor.transact("Delete") { $0.delete([star.s]) }
        h.editor.hovered = nil
        h.settleCommits()
        expect(h.editor.outlines.tinted.isEmpty, "nothing is drawn for a shape that is gone")
        expect(h.editor.outlines.dim == nil, "nor the dim")
    },
    test("an edge changed by a provide asks again: what a lens stands for comes in after the hover, with no commit") {
        let a = ShapeID(), n = ShapeID(), r = ShapeID(), wire = ShapeID()
        let h = try neighborHarness(CanvasFile(root: board(box(a), box(n, at: CGPoint(x: 500, y: 0)), lens(r, asks: "what?", at: CGPoint(x: 250, y: 200)),
                                                           link(wire, a, r))))
        let topology = try require(h.editor.topology)
        h.editor.hovered = a
        h.settle()
        // The lens stands for nothing yet: A has a wire to the lens, as drawn.
        expectEqual(h.lit, [Lit(.out, 0, [r, wire])])
        #if DEBUG
        let asked = h.reach.asked
        #endif
        topology.provide([r: ProvidedForwarding(key: ForwardingKey("what?"), shapes: [n], revision: 1)])
        h.settleCommits()
        expectEqual(h.lit, [Lit(.out, 0, [n, r, wire])], "now through it: N too")
        #if DEBUG
        expectEqual(h.reach.asked, asked + 1)
        #endif
        // An answer that changes nothing of A's edges asks nothing.
        topology.provide([r: ProvidedForwarding(key: ForwardingKey("what?"), shapes: [n], revision: 2)])
        h.settleCommits()
        #if DEBUG
        expectEqual(h.reach.asked, asked + 1)
        #endif
        // N, hovered: the lens stands for it now, and the arrow into the lens is one into N.
        h.editor.hovered = n
        h.settle()
        expectEqual(h.lit, [Lit(.into, 0, [a, r, wire])])
    },
    test("a provide that re-points a lens at an arrow's end asks again: the arrow is the subject, which the change never lists, but the lens is what it matched") {
        let a = ShapeID(), n = ShapeID(), m = ShapeID(), r = ShapeID(), wire = ShapeID()
        let h = try neighborHarness(CanvasFile(root: board(box(a), box(n, at: CGPoint(x: 500, y: 0)), box(m, at: CGPoint(x: 500, y: 300)),
                                                           lens(r, asks: "what?", at: CGPoint(x: 250, y: 200)), link(wire, a, r))))
        let topology = try require(h.editor.topology)
        topology.provide([r: ProvidedForwarding(key: ForwardingKey("what?"), shapes: [n], revision: 1)])
        h.editor.hovered = wire
        h.settle()
        // It starts at A, and ends at the lens as drawn and at N as the graph reads it.
        expectEqual(h.lit, [Lit(.out, 0, [n, r]), Lit(.into, 0, [a])])
        #if DEBUG
        let asked = h.reach.asked
        #endif
        topology.provide([r: ProvidedForwarding(key: ForwardingKey("what?"), shapes: [m], revision: 2)])
        h.settleCommits()
        expectEqual(h.lit, [Lit(.out, 0, [m, r]), Lit(.into, 0, [a])], "now at M")
        #if DEBUG
        expectEqual(h.reach.asked, asked + 1)
        #endif
    },
    test("a pill a commit re-points at an arrow's end asks again too: the commit names the pill, not the arrow hovered, and the pill is what it matched") {
        let a = ShapeID(), n = ShapeID(), m = ShapeID(), r = ShapeID(), wire = ShapeID()
        let h = try neighborHarness(CanvasFile(root: board(box(a), box(n, at: CGPoint(x: 500, y: 0)), box(m, at: CGPoint(x: 500, y: 300)),
                                                           pill(r, standingFor: [n], at: CGPoint(x: 250, y: 200)), link(wire, a, r))))
        h.editor.hovered = wire
        h.settle()
        expectEqual(h.lit, [Lit(.out, 0, [n, r]), Lit(.into, 0, [a])])
        #if DEBUG
        let asked = h.reach.asked
        #endif
        h.editor.transact("Re-point") { $0.update(r, as: Pill.self) { $0.props.stands = [Citation(m)] } }
        h.settleCommits()
        expectEqual(h.lit, [Lit(.out, 0, [m, r]), Lit(.into, 0, [a])], "now at M")
        #if DEBUG
        expectEqual(h.reach.asked, asked + 1)
        #endif
    },
    test("with nothing hovered a commit costs the lights nothing: nothing is asked or worked out") {
        let star = Star()
        let h = try neighborHarness(star.file())
        h.editor.transact("Link") { $0.insert(link(ShapeID(), star.s, star.u)) }
        h.editor.transact("Move") { $0.moveBox(star.b, to: CGPoint(x: 1000, y: 1000)) }
        h.settleCommits()
        expectEqual(h.lit, [])
        #if DEBUG
        expectEqual(h.reach.asked, 0)
        expectEqual(h.reach.composed, 0)
        #endif
    },
])

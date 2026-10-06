@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Moving
import SlashCommands
import TestKit

// Which shapes each command takes: its rule, which is also what the `@` picker lists on its line. /move-to
// takes a corral or a pocket (a frame, a subboard) on any board the app can show, that would take the
// shape; /move-near any shape but what goes with the one moved.

@MainActor let movingTakingTests = Suite("What each command takes", [
    test("/move-to takes corrals and pockets, on the board shown and on other boards: a pocket's board, and a pocket's pocket") {
        let s = ShapeID(), f = ShapeID(), p = ShapeID(), q = ShapeID(), pp = ShapeID()
        let h = try movingHarness(CanvasFile(root: board(box(s, 0, 0), corral(f, at(300, 0, 400, 300)), pocket(p, 0, 400)),
                                             children: [p: board(corral(q, at(0, 0, 400, 300)), pocket(pp, 500, 0))]))
        for target in [f, p, q, pp] { expect(h.admits("move-to", on: s, target), "\(target)") }
    },

    test("/move-to takes neither a box nor a link: those aren't of the kinds it names, whatever its rule would say") {
        let s = ShapeID(), b = ShapeID(), l = ShapeID()
        let h = try movingHarness(CanvasFile(root: board(box(s, 0, 0), box(b, 300, 0), link(l, s, b))))
        expect(!h.admits("move-to", on: s, b))
        expect(!h.admits("move-to", on: s, l))
    },

    test("/move-to takes nothing where the shape already is: the corral it's directly in, or the pocket whose board it's on; the corral that holds that one, it takes") {
        let s = ShapeID(), k = ShapeID(), o = ShapeID(), p = ShapeID(), t = ShapeID(), f = ShapeID()
        let h = try movingHarness(CanvasFile(root: board(corral(o, at(0, 0, 900, 700)), corral(k, at(50, 50, 500, 400), in: o), box(s, 100, 100, in: k),
                                                         pocket(p, 1000, 0), corral(f, at(1000, 300, 400, 300))),
                                             children: [p: board(box(t, 0, 0))]))
        expect(!h.admits("move-to", on: s, k), "the corral it's in")
        expect(h.admits("move-to", on: s, o), "the corral that one's in")
        expect(h.enter(p))
        expect(!h.admits("move-to", on: t, p), "the pocket whose board it's on")
        expect(h.admits("move-to", on: t, f), "a corral on the root, from inside a pocket")
    },

    test("/move-to takes nothing frozen: a frozen corral or pocket, a corral in a frozen corral, or a corral on a frozen pocket's board, which takes no shapes") {
        let s = ShapeID(), fc = ShapeID(), outer = ShapeID(), inner = ShapeID(), fp = ShapeID(), q = ShapeID(), log = RefusalLog()
        let h = try movingHarness(CanvasFile(root: board(box(s, 0, 0), corral(fc, at(300, 0, 400, 300)), corral(outer, at(800, 0, 800, 600)),
                                                         corral(inner, at(850, 50, 400, 300), in: outer), pocket(fp, 0, 700)),
                                             children: [fp: board(corral(q, at(0, 0, 400, 300)))]), log: log)
        for target in [fc, inner, q, fp] { expect(h.admits("move-to", on: s, target), "\(target), before") }
        h.freeze([fc, outer, fp])
        expect(!h.admits("move-to", on: s, fc), "a frozen corral")
        expect(!h.admits("move-to", on: s, inner), "one in a frozen corral")
        expect(!h.admits("move-to", on: s, fp), "a frozen pocket")
        expect(!h.admits("move-to", on: s, q), "a corral on a frozen pocket's board")
        expectEqual(log.refusals, [], "asking shakes nothing")
    },

    test("/move-to takes no corral too small to hold the shape, narrower or shorter; one just its size it takes") {
        let s = ShapeID(), narrow = ShapeID(), short = ShapeID(), snug = ShapeID()
        let h = try movingHarness(CanvasFile(root: board(box(s, 0, 0), corral(narrow, at(300, 0, 99, 400)), corral(short, at(500, 0, 400, 99)),
                                                         corral(snug, at(1000, 0, 100, 100)))))
        expect(!h.admits("move-to", on: s, narrow))
        expect(!h.admits("move-to", on: s, short))
        expect(h.admits("move-to", on: s, snug))
    },

    test("/move-to takes no corral on a board the app can't show: one a box owns") {
        let s = ShapeID(), b = ShapeID(), z = ShapeID()
        let h = try movingHarness(CanvasFile(root: board(box(s, 0, 0), box(b, 300, 0)), children: [b: board(corral(z, at(0, 0, 400, 300)))]))
        expect(!h.admits("move-to", on: s, z))
    },

    test("/move-to takes nothing that goes with the shape: a corral itself, a corral it holds at any depth, a pocket's own board and those under it, a pocket a corral holds") {
        let k = ShapeID(), kk = ShapeID(), deep = ShapeID(), kp = ShapeID(), f = ShapeID(), p = ShapeID(), q = ShapeID(), pp = ShapeID(), r = ShapeID(), g = ShapeID()
        let h = try movingHarness(CanvasFile(root: board(corral(k, at(0, 0, 900, 700)), corral(kk, at(50, 50, 500, 400), in: k),
                                                         corral(deep, at(60, 60, 300, 200), in: kk), pocket(kp, 600, 50, in: k),
                                                         corral(f, at(1000, 0, 1000, 800)), pocket(p, 0, 1000)),
                                             children: [p: board(corral(q, at(0, 0, 400, 300)), pocket(pp, 500, 0)), pp: board(corral(r, at(0, 0, 400, 300))),
                                                        kp: board(corral(g, at(0, 0, 400, 300)))]))
        expect(!h.admits("move-to", on: k, k), "itself")
        expect(!h.admits("move-to", on: k, kk), "a corral it holds")
        expect(!h.admits("move-to", on: k, deep), "and one that holds")
        expect(!h.admits("move-to", on: k, kp), "a pocket it holds")
        expect(!h.admits("move-to", on: k, g), "a corral on the board of a pocket it holds")
        expect(h.admits("move-to", on: k, f))
        expect(!h.admits("move-to", on: p, q), "a corral on its own board")
        expect(!h.admits("move-to", on: p, pp), "a pocket on its own board")
        expect(!h.admits("move-to", on: p, r), "a corral on a board under its own")
        expect(h.admits("move-to", on: p, f))
    },

    test("/move-near takes any shape but the shape itself: a box, a link, a frozen shape, a shape on another board") {
        let s = ShapeID(), b = ShapeID(), l = ShapeID(), fz = ShapeID(), p = ShapeID(), t = ShapeID()
        let h = try movingHarness(CanvasFile(root: board(box(s, 0, 0), box(b, 300, 0), link(l, s, b), box(fz, 600, 0), pocket(p, 0, 400)),
                                             children: [p: board(box(t, 0, 0))]))
        h.freeze([fz])
        for target in [b, l, fz, p, t] { expect(h.admits("move-near", on: s, target), "\(target)") }
        expect(!h.admits("move-near", on: s, s))
    },

    test("/move-near takes nothing that goes with the shape: what a corral holds, what's on a pocket's board") {
        let k = ShapeID(), a = ShapeID(), b = ShapeID(), p = ShapeID(), t = ShapeID()
        let h = try movingHarness(CanvasFile(root: board(corral(k, at(0, 0, 600, 400)), box(a, 50, 50, in: k), box(b, 800, 0), pocket(p, 0, 600)),
                                             children: [p: board(box(t, 0, 0))]))
        expect(!h.admits("move-near", on: k, a), "what it holds")
        expect(h.admits("move-near", on: k, b))
        expect(!h.admits("move-near", on: p, t), "what's on its board")
        expect(h.admits("move-near", on: p, b))
        expect(h.admits("move-near", on: a, k), "a shape near the corral it's in")
    },
])

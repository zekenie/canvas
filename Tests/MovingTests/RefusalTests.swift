@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import SlashCommands
import TestKit

// All or nothing: a move a read-only shape stands in the way of (a frozen corral it would land in, the frozen
// owner of the board it would go onto, a frozen shape it would take onto another board) changes nothing and
// makes no step, and the frozen shapes are heard refused, as Transform's turns are.

@MainActor let movingRefusalTests = Suite("Moves refused", [
    test("landing in a frozen corral: nothing moves, no step, and the corral is heard refused") {
        let f = ShapeID(), x = ShapeID(), s = ShapeID(), log = RefusalLog()
        let h = try movingHarness(CanvasFile(root: board(corral(f, at(0, 0, 800, 600)), box(x, 100, 100, in: f), box(s, 2000, 0))), log: log)
        h.freeze([f])
        expect(h.admits("move-near", on: s, x), "a shape in it is still one to be beside")
        let before = h.file, revision = h.editor.revision
        h.run("move-near", on: s, with: x)
        expectEqual(h.file, before, "it's where it was")
        expectEqual(h.editor.revision, revision, "nothing committed")
        expectEqual(h.editor.undoHistory.undoName, "Freeze", "no step of its own")
        expectEqual(log.refusals, [[f]])
        expect(!h.editor.isGliding(s))
    },

    test("onto a frozen pocket's board: nothing moves, no step, and the pocket, which would take it, is heard refused") {
        let p = ShapeID(), x = ShapeID(), s = ShapeID(), log = RefusalLog()
        let h = try movingHarness(CanvasFile(root: board(pocket(p, 0, 0), box(s, 400, 0)), children: [p: board(box(x, 0, 0))]), log: log)
        h.freeze([p])
        let before = h.file, revision = h.editor.revision
        h.run("move-near", on: s, with: x)
        expectEqual(h.file, before)
        expectEqual(h.editor.revision, revision)
        expectEqual(h.editor.undoHistory.undoName, "Freeze")
        expectEqual(log.refusals, [[p]])
    },

    test("beside a shape two boards under a frozen pocket: nothing moves, no step, and the owner of the board it would go onto is heard refused, though it isn't frozen; a shape on a read-only board offers no command to leave it with") {
        let p = ShapeID(), q = ShapeID(), x = ShapeID(), s = ShapeID(), t = ShapeID(), log = RefusalLog()
        let h = try movingHarness(CanvasFile(root: board(pocket(p, 0, 0), box(s, 800, 0)),
                                             children: [p: board(pocket(q, 0, 0), box(t, 400, 0)), q: board(box(x, 0, 0))]), log: log)
        h.freeze([p])
        expect(h.admits("move-near", on: s, x), "a shape on a read-only board is still one to be beside")
        let before = h.file, revision = h.editor.revision
        h.run("move-near", on: s, with: x)
        expectEqual(h.file, before)
        expectEqual(h.editor.revision, revision)
        expectEqual(h.editor.undoHistory.undoName, "Freeze")
        expectEqual(log.refusals, [[q]], "its board is read-only with the frozen pocket's")
        expect(h.enter(p))
        expect(h.editor.slashCommands?.command(named: "move-near", for: t) == nil, "none offered: it's read-only")
        expect(!h.run("move-near", on: t, with: s))
        expectEqual(h.file, before)
        expectEqual(log.refusals, [[q]])
    },

    test("a corral holding a frozen box moves on its board, taking the box along as a drag does, but not onto another board, where the box is heard refused") {
        let k = ShapeID(), a = ShapeID(), f = ShapeID(), p = ShapeID(), log = RefusalLog()
        let h = try movingHarness(CanvasFile(root: board(corral(k, at(0, 0, 300, 200)), box(a, 40, 40, in: k), corral(f, at(500, 0, 600, 400)), pocket(p, 0, 600))),
                                  log: log)
        h.freeze([a])
        let before = h.file
        h.run("move-to", on: k, with: p)
        expectEqual(h.file, before, "nothing went onto the pocket's board")
        expectEqual(log.refusals, [[a]])
        expect(h.run("move-to", on: k, with: f))
        expectEqual(h.editor.holder(of: k), f)
        expectEqual(h.frame(of: a), at(580, 80), "the box went along")
    },

    test("a frozen box among the shapes selected is not one of the shapes the commands act on, `2 of 3`: the others move as a block and the frozen one stays; with every one frozen, neither command is offered") {
        let f = ShapeID(), a = ShapeID(), b = ShapeID(), c = ShapeID(), log = RefusalLog()
        let h = try movingHarness(CanvasFile(root: board(corral(f, at(100, 100, 800, 600)), box(a, 1000, 0), box(b, 1200, 0), box(c, 1000, 200))), log: log)
        h.freeze([b])
        let state = try require(h.editor.slashCommands)
        for name in ["move-to", "move-near"] {
            let command = try require(state.command(named: name, for: .selection([a, b, c])), name)
            expectEqual(command.shapes, [a, c], name)
            expect(command.isPartial, name)
        }
        expect(h.run("move-to", onSelection: [a, b, c], with: f))
        expectEqual(h.frame(of: a), at(140, 140), "the two that can move are a block of 100 across and 300 down, 40 in")
        expectEqual(h.frame(of: c), at(140, 340))
        expectEqual(h.frame(of: b), at(1200, 0), "the frozen one stays")
        expectEqual(h.editor.holder(of: b), nil)
        expectEqual(log.refusals, [], "left out, not refused: nothing shakes")
        h.freeze([a, c])
        expectEqual(state.commands(for: .selection([a, b, c])).map(\.name), [])
    },
])

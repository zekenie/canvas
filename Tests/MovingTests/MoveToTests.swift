@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import SlashCommands
import TestKit

// /move-to: into a corral, as `canvas draw` puts a shape `in "F"` (against its top-left, 40 in, pushed clear
// of what it holds, kept within it), on the board shown or another; onto a pocket's board, as draw puts the
// one shape a script leaves unplaced (the middle of the view that board would be shown with, or the nearest
// clear spot); in one step, Move.

/// The view the editor is given, in view points, where a test needs one.
private let viewSize = CGSize(width: 1000, height: 700)

@MainActor let moveToTests = Suite("Moving into a frame or onto a board", [
    test("into a corral on the board shown: 40 in from its top-left, pushed clear of what it holds, and in it; one step, Move, that undo takes back; it glides there") {
        let f = ShapeID(), b = ShapeID(), s = ShapeID()
        let h = try movingHarness(CanvasFile(root: board(corral(f, at(100, 100, 600, 400)), box(b, 140, 140, in: f), box(s, 1000, 1000))))
        let before = h.file
        expect(h.run("move-to", on: s, with: f))
        expectEqual(h.frame(of: s), at(280, 140), "40 down from its top, and right of the box at its top-left by draw's clearance")
        expectEqual(h.editor.holder(of: s), f, "in it")
        expectEqual(h.editor.undoHistory.undoName, "Move")
        expect(h.editor.isGliding(s), "from where it was")
        expect(!h.editor.isGliding(b))
        let after = h.file
        h.editor.undo()
        try expectFile(h, before, "where it was, in nothing")
        h.editor.redo()
        try expectFile(h, after, "and in the corral again")
    },

    test("into a full corral: with no room clear of what it holds, at its top-left, 40 in, over what's there, and in it") {
        let f = ShapeID(), b = ShapeID(), s = ShapeID()
        let h = try movingHarness(CanvasFile(root: board(corral(f, at(100, 100, 300, 300)), box(b, 130, 130, size: 240, in: f), box(s, 1000, 1000))))
        expect(h.run("move-to", on: s, with: f))
        expectEqual(h.frame(of: s), at(140, 140))
        expectEqual(h.editor.holder(of: s), f)
        expect(h.editor.document.index(of: s)! > h.editor.document.index(of: b)!, "it paints above what it's over")
    },

    test("into a corral with a corral at its top-left that holds a box: in the outer corral itself, pushed clear of the inner one, never in it") {
        let f = ShapeID(), g = ShapeID(), b = ShapeID(), s = ShapeID()
        let h = try movingHarness(CanvasFile(root: board(corral(f, at(100, 100, 800, 500)), corral(g, at(120, 120, 300, 300), in: f),
                                                         box(b, 140, 140, in: g), box(s, 1000, 1000))))
        expect(h.run("move-to", on: s, with: f))
        expectEqual(h.frame(of: s), at(460, 140), "right of the inner corral by draw's clearance, at the outer one's top, 40 in")
        expectEqual(h.editor.holder(of: s), f, "in the corral it was moved to")
    },

    test("a shape in the inner corral, moved to the outer one, leaves the inner one") {
        let f = ShapeID(), g = ShapeID(), b = ShapeID(), s = ShapeID()
        let h = try movingHarness(CanvasFile(root: board(corral(f, at(100, 100, 800, 500)), corral(g, at(120, 120, 300, 300), in: f),
                                                         box(b, 140, 140, in: g), box(s, 280, 280, in: g))))
        expect(h.admits("move-to", on: s, f), "the outer corral isn't where it is: it's in the inner one")
        expect(h.run("move-to", on: s, with: f))
        expectEqual(h.frame(of: s), at(460, 140))
        expectEqual(h.editor.holder(of: s), f)
    },

    test("into a corral with no room from its top-left (the inner corral pushes it out the bottom): from its top-right corner") {
        let f = ShapeID(), g = ShapeID(), b = ShapeID(), s = ShapeID()
        let h = try movingHarness(CanvasFile(root: board(corral(f, at(100, 100, 800, 400)), corral(g, at(120, 120, 500, 150), in: f),
                                                         box(b, 140, 140, size: 50, in: g), box(s, 1000, 1000, size: 200))))
        expect(h.run("move-to", on: s, with: f))
        expectEqual(h.frame(of: s), at(660, 140, 200, 200), "40 in from the outer corral's top-right corner")
        expectEqual(h.editor.holder(of: s), f)
    },

    test("into a corral barely bigger than the shape: half the room it has in from its top-left, less than 40") {
        let f = ShapeID(), s = ShapeID()
        let h = try movingHarness(CanvasFile(root: board(corral(f, at(100, 100, 150, 120)), box(s, 1000, 1000))))
        expect(h.run("move-to", on: s, with: f))
        expectEqual(h.frame(of: s), at(125, 110))
        expectEqual(h.editor.holder(of: s), f)
    },

    test("a corral moved into another takes what it holds along, which is never in its way, and keeps holding it") {
        let k = ShapeID(), a = ShapeID(), f = ShapeID()
        let h = try movingHarness(CanvasFile(root: board(corral(k, at(0, 0, 300, 200)), box(a, 40, 40, in: k), corral(f, at(500, 0, 600, 400)))))
        expect(h.run("move-to", on: k, with: f))
        expectEqual(h.frame(of: k), at(540, 40, 300, 200))
        expectEqual(h.frame(of: a), at(580, 80), "by as much")
        expectEqual(h.editor.holder(of: k), f)
        expectEqual(h.editor.holder(of: a), k)
        expect(h.editor.isGliding(k) && h.editor.isGliding(a))
    },

    test("a card being edited, moved into a corral, is put down: editing ends, as a draw that moves it ends it") {
        let f = ShapeID()
        let h = try movingHarness(CanvasFile(root: board(corral(f, at(0, 0, 600, 400)))))
        let card = h.add(Card(at(1000, 0, 100, 60), text: "keep"))
        expect(h.editor.beginEditing(card))
        expect(h.run("move-to", on: card, with: f))
        expectEqual(h.editor.editingShapeID, nil)
        expectEqual(h.frame(of: card), at(40, 40, 100, 60))
        expectEqual(h.editor.holder(of: card), f)
    },

    test("onto a pocket's board: at the middle of the view it would be shown with (a first visit's, to a board with nothing on it), gone from the board shown; one step that undo takes back, both boards exactly") {
        let p = ShapeID(), s = ShapeID()
        let h = try movingHarness(CanvasFile(root: board(pocket(p, 0, 0), box(s, 400, 0))))
        h.editor.viewportDidResize(to: viewSize)
        let before = h.file
        expect(h.run("move-to", on: s, with: p))
        expectEqual(h.editor.document[s], nil, "off the board shown")
        expectEqual(h.file.board(containing: s), BoardID(owner: p))
        expectEqual(h.frame(of: s), at(450, 300), "centered on the view's middle, (500, 350)")
        expectEqual(h.editor.undoHistory.undoName, "Move")
        expect(!h.editor.isGliding(s), "nothing glides off the board shown")
        expectEqual(h.editor.board, .root, "the window stays where it is")
        let after = h.file
        h.editor.undo()
        try expectFile(h, before, "the root as it was, and no board for the pocket")
        h.editor.redo()
        try expectFile(h, after, "and on the pocket's board again")
    },

    test("onto a pocket's board where something's at the middle of the view: the nearest spot around it that's clear, ring by ring") {
        let p = ShapeID(), s = ShapeID(), b = ShapeID()
        let h = try movingHarness(CanvasFile(root: board(pocket(p, 0, 0), box(s, 400, 0)), children: [p: board(box(b, 450, 300))]))
        h.editor.viewportDidResize(to: viewSize)
        expect(h.run("move-to", on: s, with: p))
        expectEqual(h.file.board(containing: s), BoardID(owner: p))
        expectEqual(h.frame(of: s), at(450, 100), "above it, draw's 80 clear of it, on the first ring that's clear")
    },

    test("onto a pocket's board, what's bound to it across the edge lets go where it was drawn, not where it lands, as after a cut: a locked pin stays at the middle of where it was; one that isn't goes with it") {
        let p = ShapeID(), s = ShapeID(), pin = ShapeID(), free = ShapeID()
        let h = try movingHarness(CanvasFile(root: board(pocket(p, 0, 0), box(s, 400, 0), AnyShapeRecord(ShapeRecord(id: pin, Pin(target: s, at: .zero))),
                                                         AnyShapeRecord(ShapeRecord(id: free, Pin(target: s, at: .zero))))),
                                  [PinsPlugin()])
        h.editor.viewportDidResize(to: viewSize)
        h.freeze([pin])
        expect(h.run("move-to", on: s, with: p))
        expectEqual(h.frame(of: s), at(450, 300), "on the pocket's board, at its view's middle")
        let released = try require(h.editor.document[pin]?.typed(as: Pin.self)?.props)
        expectEqual(released.target, nil)
        expectEqual(released.at, CGPoint(x: 450, y: 50), "where the box was drawn on the root, not (500, 350)")
        expectEqual(h.file.board(containing: free), BoardID(owner: p), "a pin bound only to it moves with it")
        expectEqual(h.file.record(free)?.typed(as: Pin.self)?.props.target, s, "bound still")
    },

    test("a shape being edited, moved onto a pocket's board, is gone from the board shown, so it isn't edited") {
        let p = ShapeID()
        let h = try movingHarness(CanvasFile(root: board(pocket(p, 0, 0))))
        let card = h.add(Card(at(400, 0, 100, 60), text: "keep"))
        expect(h.editor.beginEditing(card))
        expect(h.run("move-to", on: card, with: p))
        expectEqual(h.editor.editingShapeID, nil)
        expectEqual(h.file.board(containing: card), BoardID(owner: p))
    },

    test("into a corral on a pocket's board: onto that board, in the corral there") {
        let p = ShapeID(), q = ShapeID(), b = ShapeID(), s = ShapeID()
        let h = try movingHarness(CanvasFile(root: board(pocket(p, 0, 0), box(s, 400, 0)),
                                             children: [p: board(corral(q, at(0, 0, 600, 400)), box(b, 40, 40, in: q))]))
        let before = h.file
        expect(h.run("move-to", on: s, with: q))
        expectEqual(h.file.board(containing: s), BoardID(owner: p))
        expectEqual(h.frame(of: s), at(180, 40), "clear of the box at its top-left")
        expectEqual(h.container(of: s), q)
        h.editor.undo()
        try expectFile(h, before, "both boards as they were")
    },

    test("into a corral on the root, from a pocket's board: onto the root, in the corral; the window stays on the pocket's board") {
        let p = ShapeID(), f = ShapeID(), s = ShapeID()
        let h = try movingHarness(CanvasFile(root: board(pocket(p, 0, 0), corral(f, at(400, 0, 600, 400))), children: [p: board(box(s, 0, 0))]))
        expect(h.enter(p))
        expect(h.run("move-to", on: s, with: f))
        expectEqual(h.editor.board, BoardID(owner: p))
        expectEqual(h.file.board(containing: s), .root)
        expectEqual(h.frame(of: s), at(440, 40))
        expectEqual(h.container(of: s), f)
        expectEqual(h.editor.undoHistory.undoName, "Move")
        h.editor.undo()
        expectEqual(h.file.board(containing: s), BoardID(owner: p), "undone")
    },

    test("a target it no longer takes moves nothing: a corral that's gone") {
        let f = ShapeID(), s = ShapeID()
        let h = try movingHarness(CanvasFile(root: board(corral(f, at(0, 0, 600, 400)), box(s, 1000, 0))))
        let state = try require(h.editor.slashCommands)
        let command = try require(state.command(named: "move-to", for: s))
        h.editor.transact { $0.delete([f]) }
        let before = h.file
        expect(!state.run(command, on: s, with: SlashArguments([.shape(f, label: "Pen")])), "not accepted: the rule is asked again")
        expectEqual(h.file, before)
    },
])

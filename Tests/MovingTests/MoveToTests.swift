@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import SlashCommands
import TableOfContents
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

    test("a shape in the inner corral, moved to the outer one, leaves the inner one: beside it, kept in the outer one, as Move To ▸ and a drop on the outer corral's row put it") {
        let f = ShapeID(), g = ShapeID(), b = ShapeID(), s = ShapeID()
        let file = CanvasFile(root: board(corral(f, at(100, 100, 800, 500)), corral(g, at(120, 120, 300, 300), in: f),
                                          box(b, 140, 140, in: g), box(s, 280, 280, in: g)))
        let h = try movingHarness(file)
        expect(h.admits("move-to", on: s, f), "the outer corral isn't where it is: it's in the inner one")
        expect(h.run("move-to", on: s, with: f))
        // `/move-to` goes by Move To ▸'s rule (`Drop`), so that it, the menu and the table of contents refuse and land
        // alike, and it can move several shapes as one block: a shape nested in the corral it is moved to leaves the
        // nested one beside it (right of it, 80 away, centered on it), kept within the outer one. It used to be put at the
        // outer corral's top-left, 40 in, pushed clear of what it holds ((460, 140)).
        expectEqual(h.frame(of: s), at(500, 220))
        expectEqual(h.editor.holder(of: s), f)
        let reference = try droppingHarness(file)
        expect(reference.drop([s], on: f, .on))
        expectEqual(h.frame(of: s), reference.frame(of: s), "where a drop on the outer corral's row puts it")
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

    test("onto a pocket's board: at the middle of the view it would be shown with (a first visit's, to a board with nothing on it), and the window goes after it; one step that undo takes back, both boards exactly, back on the root") {
        let p = ShapeID(), s = ShapeID()
        let h = try movingHarness(CanvasFile(root: board(pocket(p, 0, 0), box(s, 400, 0))))
        h.editor.viewportDidResize(to: viewSize)
        let before = h.file
        expect(h.run("move-to", on: s, with: p))
        expectEqual(h.file.board(containing: s), BoardID(owner: p))
        expectEqual(h.frame(of: s), at(450, 300), "centered on the view's middle, (500, 350)")
        expectEqual(h.editor.undoHistory.undoName, "Move")
        expectEqual(h.editor.board, BoardID(owner: p), "the window shows the board it went to")
        expect(h.editor.document[s] != nil, "on the board shown")
        expect(!h.editor.isGliding(s), "nothing glides onto another board")
        let after = h.file
        h.editor.undo()
        expectEqual(h.editor.board, .root, "undo shows the board the step was made on")
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
        let released = try require(h.file.record(pin)?.typed(as: Pin.self)?.props)
        expectEqual(h.file.board(containing: pin), .root, "the locked pin stays")
        expectEqual(released.target, nil)
        expectEqual(released.at, CGPoint(x: 450, y: 50), "where the box was drawn on the root, not (500, 350)")
        expectEqual(h.file.board(containing: free), BoardID(owner: p), "a pin bound only to it moves with it")
        expectEqual(h.file.record(free)?.typed(as: Pin.self)?.props.target, s, "bound still")
    },

    test("a shape being edited, moved onto a pocket's board, isn't edited there: editing ends as it leaves the board it was edited on") {
        let p = ShapeID()
        let h = try movingHarness(CanvasFile(root: board(pocket(p, 0, 0))))
        let card = h.add(Card(at(400, 0, 100, 60), text: "keep"))
        expect(h.editor.beginEditing(card))
        expect(h.run("move-to", on: card, with: p))
        expectEqual(h.editor.editingShapeID, nil)
        expectEqual(h.file.board(containing: card), BoardID(owner: p))
        expectEqual(h.editor.board, BoardID(owner: p))
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

    test("into a corral on the root, from a pocket's board: onto the root, in the corral; the window goes to the root after it") {
        let p = ShapeID(), f = ShapeID(), s = ShapeID()
        let h = try movingHarness(CanvasFile(root: board(pocket(p, 0, 0), corral(f, at(400, 0, 600, 400))), children: [p: board(box(s, 0, 0))]))
        expect(h.enter(p))
        expect(h.run("move-to", on: s, with: f))
        expectEqual(h.editor.board, .root)
        expectEqual(h.file.board(containing: s), .root)
        expectEqual(h.frame(of: s), at(440, 40))
        expectEqual(h.container(of: s), f)
        expectEqual(h.editor.undoHistory.undoName, "Move")
        h.editor.undo()
        expectEqual(h.file.board(containing: s), BoardID(owner: p), "undone")
    },

    test("three boxes selected, /move-to a corral: one block, the box around them 40 in from its top-left as a single box is, each where it was to the others, in the corral; one step, Move, that undo takes back exactly") {
        let f = ShapeID(), a = ShapeID(), b = ShapeID(), c = ShapeID()
        let h = try movingHarness(CanvasFile(root: board(corral(f, at(100, 100, 800, 600)), box(a, 1000, 0), box(b, 1200, 0), box(c, 1000, 200))))
        let before = h.file, selection = [a, b, c]
        expect(h.admits("move-to", onSelection: selection, f))
        expect(h.run("move-to", onSelection: selection, with: f))
        expectEqual(selection.map { h.frame(of: $0) }, [at(140, 140), at(340, 140), at(140, 340)], "300 across and down, 40 in; the same 200 apart")
        expectEqual(selection.map { h.editor.holder(of: $0) }, [f, f, f])
        expectEqual(h.editor.undoHistory.undoName, "Move")
        expect(selection.allSatisfy { h.editor.isGliding($0) }, "from where they were")
        let after = h.file
        h.editor.undo()
        try expectFile(h, before, "all three where they were, in nothing: one step")
        h.editor.redo()
        try expectFile(h, after, "and in the corral again")
    },

    test("several selected, /move-to a corral that holds a box: the block lands clear of it, still in one piece") {
        let f = ShapeID(), x = ShapeID(), a = ShapeID(), b = ShapeID()
        let h = try movingHarness(CanvasFile(root: board(corral(f, at(100, 100, 800, 500)), box(x, 140, 140, in: f), box(a, 1000, 0), box(b, 1200, 100))))
        expect(h.run("move-to", onSelection: [a, b], with: f))
        // The block is 300 across and 200 down; it is put right of the box at the corral's top-left, as one box is.
        expectEqual(h.frame(of: a), at(280, 140))
        expectEqual(h.frame(of: b), at(480, 240))
        expectEqual([a, b, x].map { h.editor.holder(of: $0) }, [f, f, f])
    },

    test("a corral and a box selected, /move-to another corral: one block, the corral taking what it holds along, each where it was to the others") {
        let k = ShapeID(), a = ShapeID(), s = ShapeID(), f = ShapeID()
        let h = try movingHarness(CanvasFile(root: board(corral(k, at(0, 0, 300, 200)), box(a, 40, 40, in: k), box(s, 400, 0), corral(f, at(1000, 0, 900, 600)))))
        expect(h.run("move-to", onSelection: [k, s], with: f))
        // The box around the corral and the box: (0, 0) to (500, 200), put 40 in.
        expectEqual(h.frame(of: k), at(1040, 40, 300, 200))
        expectEqual(h.frame(of: a), at(1080, 80), "carried by as much")
        expectEqual(h.frame(of: s), at(1440, 40))
        expectEqual([k, s].map { h.editor.holder(of: $0) }, [f, f])
        expectEqual(h.editor.holder(of: a), k, "still in the corral it was in")
    },

    test("boxes some of which are in the corral already: those that aren't come in, those that are stay where they are") {
        let f = ShapeID(), a = ShapeID(), b = ShapeID()
        let h = try movingHarness(CanvasFile(root: board(corral(f, at(100, 100, 800, 500)), box(a, 500, 300, in: f), box(b, 1000, 0))))
        expect(h.run("move-to", onSelection: [a, b], with: f))
        expectEqual(h.frame(of: a), at(500, 300), "where it was")
        expectEqual(h.frame(of: b), at(140, 140), "40 in, clear of it")
        expectEqual([a, b].map { h.editor.holder(of: $0) }, [f, f])
        expect(!h.admits("move-to", onSelection: [a], f), "all of them in it: nowhere to go")
    },

    test("three boxes selected, /move-to a pocket: onto its board as one block, the box around them at the middle of the view it would be shown with, each where it was to the others; the window goes after them; one step that undo takes back, both boards exactly") {
        let p = ShapeID(), a = ShapeID(), b = ShapeID(), c = ShapeID()
        let h = try movingHarness(CanvasFile(root: board(pocket(p, 0, 0), box(a, 400, 0), box(b, 600, 0), box(c, 400, 200))))
        h.editor.viewportDidResize(to: viewSize)
        let before = h.file, selection = [a, b, c]
        expect(h.run("move-to", onSelection: selection, with: p))
        expectEqual(selection.map { h.file.board(containing: $0) }, Array(repeating: BoardID(owner: p), count: 3))
        expectEqual(selection.map { h.frame(of: $0) }, [at(350, 200), at(550, 200), at(350, 400)], "300 across and down, centered on (500, 350)")
        expectEqual(h.editor.undoHistory.undoName, "Move")
        expectEqual(h.editor.board, BoardID(owner: p), "the window shows the board they went to")
        let after = h.file
        h.editor.undo()
        try expectFile(h, before, "the root as it was, and no board for the pocket")
        h.editor.redo()
        try expectFile(h, after, "and on the pocket's board again")
    },

    test("several selected, /move-to a corral on a pocket's board: onto that board, in the corral there") {
        let p = ShapeID(), q = ShapeID(), a = ShapeID(), b = ShapeID()
        let h = try movingHarness(CanvasFile(root: board(pocket(p, 0, 0), box(a, 400, 0), box(b, 600, 100)),
                                             children: [p: board(corral(q, at(0, 0, 800, 600)))]))
        expect(h.run("move-to", onSelection: [a, b], with: q))
        expectEqual([a, b].map { h.file.board(containing: $0) }, [BoardID(owner: p), BoardID(owner: p)])
        expectEqual(h.frame(of: a), at(40, 40))
        expectEqual(h.frame(of: b), at(240, 140))
        expectEqual([a, b].map { h.container(of: $0) }, [q, q])
    },

    test("a shape in a corral on a pocket's board, /move-to the pocket whose board is shown: out of the corral and onto the board, beside the corral, as a drop among the board's rows puts it; a box already on the board is not taken") {
        let p = ShapeID(), k = ShapeID(), s = ShapeID(), t = ShapeID()
        let h = try movingHarness(CanvasFile(root: board(pocket(p, 0, 0)), children: [p: board(corral(k, at(0, 0, 600, 400)), box(s, 100, 100, in: k), box(t, 900, 0))]))
        expect(h.enter(p))
        expect(!h.admits("move-to", on: t, p), "a box on the pocket's board already")
        expect(h.admits("move-to", on: s, p), "a box in a corral there is not")
        expect(h.run("move-to", on: s, with: p))
        expectEqual(h.frame(of: s), at(680, 150), "right of the corral, 80 away, centered on it")
        expectEqual(h.container(of: s), nil)
        expectEqual(h.editor.board, BoardID(owner: p), "the window stays where it is")
        expectEqual(h.editor.undoHistory.undoName, "Move")
    },

    test("into a corral that a corral nested in it covers, with no room clear of it: nothing changes and no step is made, since put down over the nested corral the shape would be in that one, not in the corral it was moved to") {
        let f = ShapeID(), g = ShapeID(), s = ShapeID()
        let file = CanvasFile(root: board(corral(f, at(100, 100, 300, 300)), corral(g, at(110, 110, 280, 280), in: f), box(s, 1000, 1000)))
        let h = try movingHarness(file)
        let before = h.file, revision = h.editor.revision
        expect(h.admits("move-to", on: s, f), "the rule is about the corral's size, not what's in it")
        h.run("move-to", on: s, with: f)
        expectEqual(h.file, before, "where it was: a drop puts them where it says, or nowhere")
        expectEqual(h.editor.revision, revision, "nothing committed")
        expectEqual(h.editor.undoHistory.undoName, nil, "no step")
        let reference = try droppingHarness(file)
        reference.drop([s], on: f, .on)
        expectEqual(reference.file, before, "and a drop of its row on the corral's leaves it so")
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

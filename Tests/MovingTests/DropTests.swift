@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Selection
import TableOfContents
import TestKit

// Rows dropped in the table of contents somewhere their shapes aren't (`ContentsMoves`): into a corral (its
// row, or among the rows it holds) as `/move-to` puts a shape there, onto a pocket's board (its row, or
// among its board's rows) as `/move-to` puts one there, out of corrals beside the outermost one left as
// `/move-near` puts one beside it, several as one block; then restacked where the drop says, in the one step.

/// The view the editor is given, in view points, where a test needs one.
private let viewSize = CGSize(width: 1000, height: 700)

@MainActor private func ids(_ document: CanvasDocument) -> [ShapeID] { document.shapes.map(\.id) }

@MainActor let dropTests = Suite("Dropping rows somewhere else", [
    test("on a corral's row: into it as /move-to puts it, in front of what it holds; one step, Move, that undo takes back; it glides there") {
        let f = ShapeID(), b = ShapeID(), s = ShapeID()
        let h = try droppingHarness(CanvasFile(root: board(corral(f, at(100, 100, 600, 400)), box(b, 140, 140, in: f), box(s, 1000, 1000))))
        let before = h.file
        expect(h.drop([s], on: f, .on))
        expectEqual(h.frame(of: s), at(280, 140), "40 down from its top, right of the box at its top-left by draw's clearance")
        expectEqual(h.editor.holder(of: s), f)
        expectEqual(ids(h.editor.document), [f, b, s], "in front of what it holds")
        expectEqual(h.editor.undoHistory.undoName, "Move")
        expect(h.editor.isGliding(s), "from where it was")
        expectEqual(h.editor.tableOfContents?.dragShapes, nil, "the drag is over")
        let after = h.file
        h.editor.undo()
        try expectFile(h, before, "where it was, in nothing")
        h.editor.redo()
        try expectFile(h, after, "and in the corral again")
    },
    test("above a row in a corral: into it, just in front of that row's shape; below one: just behind it") {
        let f = ShapeID(), b1 = ShapeID(), b2 = ShapeID(), s = ShapeID()
        let h = try droppingHarness(CanvasFile(root: board(corral(f, at(100, 100, 800, 500)), box(b1, 140, 600, in: f), box(b2, 700, 600, in: f),
                                                            box(s, 2000, 2000))))
        expect(h.drop([s], on: b1, .above))
        expectEqual(h.editor.holder(of: s), f)
        expectEqual(ids(h.editor.document), [f, b1, s, b2], "in front of B1, behind B2")
        h.editor.undo()
        expect(h.drop([s], on: b1, .below))
        expectEqual(h.editor.holder(of: s), f)
        expectEqual(ids(h.editor.document), [f, s, b1, b2], "behind B1")
        expectEqual(h.editor.undoHistory.undoName, "Move", "the move and the restack, one step")
        h.editor.undo()
        expectEqual(ids(h.editor.document), [f, b1, b2, s])
    },
    test("among the board's rows, out of the corral it's in: beside the corral, as /move-near puts it, and in front of the row's shape") {
        let x = ShapeID(), f = ShapeID(), s = ShapeID(), y = ShapeID()
        let h = try droppingHarness(CanvasFile(root: board(box(x, 2000, 2000), corral(f, at(100, 100, 600, 400)), box(s, 140, 140, in: f),
                                                            box(y, 2000, 0))))
        let before = h.file
        expect(h.drop([s], on: x, .above))
        expectEqual(h.editor.holder(of: s), nil, "out of the corral")
        expectEqual(h.frame(of: s), at(780, 250), "right of the corral, 80 away, centered on it")
        expectEqual(ids(h.editor.document), [x, s, f, y], "just in front of X")
        expectEqual(h.editor.undoHistory.undoName, "Move")
        h.editor.undo()
        try expectFile(h, before, "back in the corral")
    },
    test("out of an inner corral among the outer one's rows: beside the inner one, in the outer one") {
        let f = ShapeID(), g = ShapeID(), s = ShapeID(), a = ShapeID()
        let h = try droppingHarness(CanvasFile(root: board(corral(f, at(100, 100, 800, 500)), corral(g, at(120, 120, 300, 300), in: f),
                                                            box(s, 140, 140, in: g), box(a, 750, 450, in: f))))
        expect(h.drop([s], on: a, .below))
        expectEqual(h.editor.holder(of: s), f, "in the outer corral")
        expectEqual(h.frame(of: s), at(500, 220), "right of the inner one, 80 away, centered on it")
        expectEqual(ids(h.editor.document), [f, g, s, a], "behind A, which it was dropped below")
    },
    test("on a pocket's row: onto its board, near the middle of the view it would be shown with, in front of what it holds; the window goes after it, selected there, one step back to the root") {
        let p = ShapeID(), s = ShapeID(), x = ShapeID()
        let h = try droppingHarness(CanvasFile(root: board(pocket(p, 0, 0), box(s, 400, 0)), children: [p: board(box(x, 2000, 2000))]))
        h.editor.viewportDidResize(to: viewSize)
        let before = h.file
        expect(h.drop([s], on: p, .on))
        expectEqual(ids(h.file[BoardID(owner: p)]), [x, s], "on top of what it holds")
        expectEqual(h.frame(of: s), at(2000, 1800), "the view a first visit fits to X is around it: the nearest clear ring, above it, draw's 80 clear")
        expect(!h.editor.isGliding(s))
        expectEqual(h.editor.board, BoardID(owner: p), "the board it went to")
        expectEqual(h.editor.selectedShapeIDs, [s])
        h.editor.goBack()
        expectEqual(h.editor.board, .root, "back where it was dropped from")
        h.editor.undo()
        try expectFile(h, before, "both boards as they were")
    },
    test("among a pocket's board's rows: onto that board, just in front of the row's shape, or just behind it") {
        let p = ShapeID(), s = ShapeID(), x = ShapeID(), y = ShapeID()
        let pBoard = BoardID(owner: p)
        let h = try droppingHarness(CanvasFile(root: board(pocket(p, 0, 0), box(s, 400, 0)), children: [p: board(box(x, 2000, 2000), box(y, 2400, 2000))]))
        h.editor.viewportDidResize(to: viewSize)
        expect(h.drop([s], on: x, .above))
        expectEqual(ids(h.file[pBoard]), [x, s, y])
        h.editor.undo()
        expect(h.drop([s], on: x, .below))
        expectEqual(ids(h.file[pBoard]), [s, x, y])
    },
    test("a row of a pocket's board, which isn't shown, among the root's rows: off that board, onto the root, in front of the row's shape; undo puts both back") {
        let p = ShapeID(), s = ShapeID(), x = ShapeID(), y = ShapeID()
        let pBoard = BoardID(owner: p)
        let h = try droppingHarness(CanvasFile(root: board(pocket(p, 0, 0), box(x, 2000, 2000), box(y, 2400, 2000)), children: [p: board(box(s, 100, 100))]))
        h.editor.viewportDidResize(to: viewSize)
        let before = h.file
        expect(h.drop([s], on: x, .above))
        expectEqual(h.file.board(containing: s), .root)
        expectEqual(ids(h.editor.document), [p, x, s, y], "just in front of X")
        expect(h.file.children[p] == nil, "the board it left had nothing else")
        h.editor.undo()
        try expectFile(h, before, "back on the pocket's board")
    },
    test("a row of a pocket's board on a corral's row on the root: into the corral, off that board") {
        let p = ShapeID(), s = ShapeID(), f = ShapeID()
        let h = try droppingHarness(CanvasFile(root: board(pocket(p, 0, 0), corral(f, at(400, 100, 600, 400))), children: [p: board(box(s, 100, 100))]))
        expect(h.drop([s], on: f, .on))
        expectEqual(h.file.board(containing: s), .root)
        expectEqual(h.editor.holder(of: s), f)
        expectEqual(h.frame(of: s), at(440, 140), "40 in from its top-left")
    },
    test("a row of a shape laid out wider than it stores, dropped on a corral's row: it lands clear of what the corral holds and within it by the frame it is laid out in, from the board shown or from one that isn't") {
        let p = ShapeID(), f = ShapeID(), b = ShapeID(), g = ShapeID(), s = ShapeID()
        @MainActor func landed(stretchOn pocketBoard: Bool) throws -> (stored: CGRect, laidOut: CGRect, holder: ShapeID?) {
            let gauge = AnyShapeRecord(ShapeRecord(id: g, CanvasTesting.Gauge(at(1000, 1000, 60, 40), width: 400, height: 100)))
            let stretch = AnyShapeRecord(ShapeRecord(id: s, Stretch(at(1000, 1200), gauge: g)))
            let root = pocketBoard ? [pocket(p, 3000, 0)] : [pocket(p, 3000, 0), gauge, stretch]
            let file = CanvasFile(root: CanvasDocument(shapes: root + [corral(f, at(100, 100, 500, 400)), box(b, 140, 140, in: f)]),
                                  children: pocketBoard ? [p: CanvasDocument(shapes: [gauge, stretch])] : [:])
            let h = try droppingHarness(file, [StretchesPlugin()])
            expect(h.drop([s], on: f, .on))
            expectEqual(h.file.board(containing: s), .root)
            let frame = try require(h.editor.shapeContext.frame(of: s))
            return (try require(h.frame(of: s)), frame, h.editor.holder(of: s))
        }
        let shown = try landed(stretchOn: false), apart = try landed(stretchOn: true)
        expectEqual(shown.laidOut.size, CGSize(width: 400, height: 100))
        for frame in [shown.laidOut, apart.laidOut] {
            expect(!frame.intersects(at(140, 140)), "clear of the box in the corral: \(frame)")
            expect(at(100, 100, 500, 400).contains(frame), "and in it: \(frame)")
        }
        expectEqual(shown.holder, f)
        expectEqual(shown.stored, at(140, 360), "below the box, not at (280, 140) where its 100 would fit: the 400 wide frame would not")
        expectEqual(shown.stored, apart.stored, "the same from either board")
    },
    test("several rows at once: one block, as they are to each other, in their order") {
        let f = ShapeID(), s1 = ShapeID(), s2 = ShapeID()
        let h = try droppingHarness(CanvasFile(root: board(corral(f, at(100, 100, 600, 400)), box(s1, 1000, 1000), box(s2, 1200, 1100))))
        expect(h.drop([s2, s1], on: f, .on))
        expectEqual(h.frame(of: s1), at(140, 140), "the box around them, 40 in from the corral's top-left")
        expectEqual(h.frame(of: s2), at(340, 240), "where it was from the other")
        expectEqual(h.editor.holder(of: s1), f)
        expectEqual(h.editor.holder(of: s2), f)
        expectEqual(ids(h.editor.document), [f, s1, s2], "in their order")
        expectEqual(h.editor.undoHistory.undoName, "Move")
    },
    test("several rows behind a corral dropped on its row: in it, in their order") {
        let f = ShapeID(), s1 = ShapeID(), s2 = ShapeID()
        let h = try droppingHarness(CanvasFile(root: board(box(s1, 1000, 1000), box(s2, 1200, 1100), corral(f, at(100, 100, 600, 400)))))
        expect(h.drop([s1, s2], on: f, .on))
        expectEqual(h.editor.holder(of: s1), f)
        expectEqual(h.editor.holder(of: s2), f)
        expectEqual(ids(h.editor.document), [f, s1, s2], "raised over it together, S1 still behind S2")
    },
    test("out of a corral nested in another, among the outer one's rows: beside the inner one, kept in the outer one") {
        let f = ShapeID(), g = ShapeID(), s = ShapeID(), a = ShapeID()
        let h = try droppingHarness(CanvasFile(root: board(corral(f, at(100, 100, 700, 600)), corral(g, at(120, 120, 560, 300), in: f),
                                                            box(s, 140, 140, in: g), box(a, 600, 640, in: f))))
        expect(h.drop([s], on: a, .above))
        expectEqual(h.editor.holder(of: s), f, "in the outer corral")
        let box = try require(h.frame(of: s))
        expect(box.minY >= 420 + 80 - 0.5 && box.maxY <= 700 - 40 + 0.5, "below the inner one, kept 40 in from the outer one's edge: \(box)")
    },
    test("out of a corral nested in another that leaves it no room clear of the inner one: nothing changes, no step") {
        let f = ShapeID(), g = ShapeID(), s = ShapeID(), a = ShapeID()
        let h = try droppingHarness(CanvasFile(root: board(corral(f, at(100, 100, 600, 400)), corral(g, at(110, 110, 580, 380), in: f),
                                                            box(s, 140, 140, in: g), box(a, 2000, 2000))))
        h.editor.put([a], in: f)
        let before = h.file, step = h.editor.undoHistory.undoName
        expect(h.drop([s], on: a, .above), "the list took the drop")
        expectEqual(h.file, before, "it would only have gone back into the inner corral")
        expectEqual(h.editor.undoHistory.undoName, step)
    },
    test("a corral dropped into another takes what it holds along") {
        let f = ShapeID(), g = ShapeID(), b = ShapeID()
        let h = try droppingHarness(CanvasFile(root: board(corral(f, at(100, 100, 800, 600)), corral(g, at(1000, 1000, 300, 200)), box(b, 1040, 1040, in: g))))
        expect(h.drop([g], on: f, .on))
        expectEqual(h.editor.holder(of: g), f)
        expectEqual(h.editor.holder(of: b), g)
        expectEqual(h.frame(of: g), at(140, 140, 300, 200))
        expectEqual(h.frame(of: b), at(180, 180), "where it was in the corral that took it along")
    },
    test("not taken: a corral too small for what's dropped, or frozen; a frozen pocket's board; a corral into itself or what it holds, a pocket onto its own board") {
        let f = ShapeID(), small = ShapeID(), frozen = ShapeID(), p = ShapeID(), q = ShapeID(), g = ShapeID(), b = ShapeID(), s = ShapeID()
        let h = try droppingHarness(CanvasFile(root: board(corral(f, at(100, 100, 600, 400)), corral(small, at(800, 100, 50, 50)),
                                                            corral(frozen, at(1000, 100, 600, 400)), pocket(p, 2000, 0), pocket(q, 2400, 0),
                                                            corral(g, at(100, 700, 600, 400)), box(b, 140, 740, in: g), box(s, 3000, 3000)),
                                            children: [q: board(box(ShapeID(), 0, 0))]))
        h.editor.freeze([frozen, p])
        expect(!h.admitsDrop([s], on: small, .on), "too small for a 100 × 100 box")
        expect(!h.admitsDrop([s], on: frozen, .on), "frozen")
        expect(!h.admitsDrop([s], on: p, .on), "a frozen pocket's board")
        expect(!h.admitsDrop([g], on: g, .on), "a corral into itself")
        expect(!h.admitsDrop([g], on: b, .above), "beside what it holds")
        expect(!h.admitsDrop([q], on: q, .on), "a pocket onto its own board")
        expect(h.admitsDrop([s], on: f, .on) && h.admitsDrop([s], on: q, .on) && h.admitsDrop([g], on: f, .on))
        let step = h.editor.undoHistory.undoName
        expect(!h.drop([s], on: small, .on))
        expectEqual(h.editor.holder(of: s), nil)
        expectEqual(h.editor.undoHistory.undoName, step, "no step")
    },
    test("a frozen shape's row doesn't drag, and isn't among a selection's that do") {
        let f = ShapeID(), s = ShapeID(), t = ShapeID()
        let h = try droppingHarness(CanvasFile(root: board(corral(f, at(100, 100, 600, 400)), box(s, 1000, 1000), box(t, 1200, 1000))))
        h.editor.freeze([s])
        let state = try require(h.editor.tableOfContents)
        expectEqual(state.dragged(from: s), [])
        h.editor.selectedShapeIDs = [s, t]
        expectEqual(state.dragged(from: t), [t])
        expect(h.drop([t], on: f, .on))
        expectEqual(h.editor.holder(of: t), f)
        expectEqual(h.editor.holder(of: s), nil)
    },
    test("dropped where landing takes it into a frozen corral: nothing changes, no step, the corral heard") {
        let f = ShapeID(), k = ShapeID(), s = ShapeID(), log = RefusalLog()
        let h = try droppingHarness(CanvasFile(root: board(corral(f, at(100, 100, 600, 400)), corral(k, at(110, 110, 580, 380), in: f), box(s, 1000, 1000))),
                                    log: log)
        h.editor.freeze([k])
        let before = h.file, step = h.editor.undoHistory.undoName
        // No room in F clear of the frozen corral filling it: at F's top-left, 40 in, over it, so that one would take it.
        expect(h.drop([s], on: f, .on), "the list took the drop")
        expectEqual(h.editor.holder(of: s), nil)
        expectEqual(h.file, before)
        expectEqual(h.editor.undoHistory.undoName, step, "no step")
        expectEqual(log.refusals.last, [k])
    },
])

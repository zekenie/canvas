@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import TestKit

// /move-near: beside a shape, as `canvas draw` places `right of "X"` (80 away, centered on it the other way),
// on the first of its four sides that's free (right, below, left, above), and with none free, the one that
// frees up nearest once pushed past what's there; then put down by the in-or-out rule, on the board the
// shape is on, which may be another.

/// X: the box shapes are moved near, 100 × 100 at (400, 400).
private let xFrame = at(400, 400)

/// Where a box 100 × 100 lands near X with these boxes around it, on the root.
@MainActor private func landing(among others: [CGRect], file: StaticString = #fileID, line: UInt = #line) throws -> CGRect? {
    let x = ShapeID(), s = ShapeID()
    var records = [box(s, 2000, 2000), AnyShapeRecord(ShapeRecord(id: x, Box(xFrame)))]
    for other in others { records.append(AnyShapeRecord(ShapeRecord(Box(other)))) }
    let h = try movingHarness(CanvasFile(root: CanvasDocument(shapes: records)))
    expect(h.run("move-near", on: s, with: x), "run", file: file, line: line)
    return h.frame(of: s)
}

@MainActor let moveNearTests = Suite("Moving beside a shape", [
    test("right of it when that's free: 80 away, centered on it; one step, Move, that undo takes back; it glides there") {
        let x = ShapeID(), s = ShapeID()
        let h = try movingHarness(CanvasFile(root: board(box(s, 2000, 2000), AnyShapeRecord(ShapeRecord(id: x, Box(xFrame))))))
        let before = h.file
        expect(h.run("move-near", on: s, with: x))
        expectEqual(h.frame(of: s), at(580, 400))
        expectEqual(h.editor.undoHistory.undoName, "Move")
        expect(h.editor.isGliding(s))
        h.editor.undo()
        try expectFile(h, before, "where it was")
    },

    test("a shape laid out wider than it stores is placed by the frame it is laid out in: right is taken by what its stored box would clear, so below, centered by its frame") {
        let x = ShapeID(), s = ShapeID(), g = ShapeID()
        let records = [AnyShapeRecord(ShapeRecord(id: g, CanvasTesting.Gauge(at(3000, 3000), width: 300, height: 100))),
                       AnyShapeRecord(ShapeRecord(id: s, Stretch(at(2000, 2000), gauge: g))), AnyShapeRecord(ShapeRecord(id: x, Box(xFrame))),
                       AnyShapeRecord(ShapeRecord(Box(at(700, 400))))]
        let h = try movingHarness(CanvasFile(root: CanvasDocument(shapes: records)), [StretchesPlugin()])
        expect(h.run("move-near", on: s, with: x))
        expectEqual(h.frame(of: s), at(300, 580), "its 300 centered on X's middle, and the same 100 it stores")
        expectEqual(h.editor.shapeContext.frame(of: s), at(300, 580, 300, 100))
    },

    test("each side in turn, the first that's free: right, then below, then left, then above") {
        let right = at(580, 400), below = at(400, 580), left = at(220, 400), above = at(400, 220)
        expectEqual(try landing(among: []), right)
        expectEqual(try landing(among: [right]), below, "right is taken")
        expectEqual(try landing(among: [right, below]), left, "and below")
        expectEqual(try landing(among: [right, below, left]), above, "and left")
    },

    test("with all four taken, the side that frees up nearest once pushed past what's there: draw's clearance beyond it, 40 across and 64 up and down") {
        // Pushed past these, right lands 420 from X, below 244, left 220 and above 244.
        let others = [at(580, 380, 300, 140), at(400, 580), at(220, 400), at(400, 220)]
        expectEqual(try landing(among: others), at(80, 400), "left, 40 clear of what's there")
        // A tie goes to the earlier side: below and above are both 244 off once left is as far.
        expectEqual(try landing(among: [at(580, 380, 300, 140), at(400, 580), at(150, 400, 170, 100), at(400, 220)]), at(400, 744), "below, 64 clear")
    },

    test("next to a shape it's already beside, it moves nowhere: nothing commits, no step, and a card being edited goes on being edited") {
        let x = ShapeID()
        let h = try movingHarness(CanvasFile(root: board(AnyShapeRecord(ShapeRecord(id: x, Box(xFrame))))))
        let card = h.add(Card(at(580, 420, 100, 60), text: "keep"))
        expect(h.editor.beginEditing(card))
        let revision = h.editor.revision
        expect(h.run("move-near", on: card, with: x))
        expectEqual(h.editor.revision, revision, "nothing committed")
        expectEqual(h.editor.editingShapeID, card)
        expectEqual(h.editor.undoHistory.undoName, nil)
    },

    test("a card being edited, moved beside a shape, is put down: editing ends") {
        let x = ShapeID()
        let h = try movingHarness(CanvasFile(root: board(AnyShapeRecord(ShapeRecord(id: x, Box(xFrame))))))
        let card = h.add(Card(at(0, 0, 100, 60), text: "keep"))
        expect(h.editor.beginEditing(card))
        expect(h.run("move-near", on: card, with: x))
        expectEqual(h.frame(of: card), at(580, 420, 100, 60))
        expectEqual(h.editor.editingShapeID, nil)
    },

    test("beside a shape in a corral, it lands in the corral and is put in it; the corral, a region it sits in, is no shape in its way") {
        let k = ShapeID(), x = ShapeID(), s = ShapeID()
        let h = try movingHarness(CanvasFile(root: board(corral(k, at(0, 0, 800, 600)), box(x, 100, 100, in: k), box(s, 2000, 0))))
        expect(h.run("move-near", on: s, with: x))
        expectEqual(h.frame(of: s), at(280, 100))
        expectEqual(h.editor.holder(of: s), k)
    },

    test("beside a shape out of the corral it's in, it leaves the corral") {
        let k = ShapeID(), x = ShapeID(), s = ShapeID()
        let h = try movingHarness(CanvasFile(root: board(corral(k, at(0, 0, 400, 400)), box(s, 50, 50, in: k), box(x, 600, 100))))
        expect(h.run("move-near", on: s, with: x))
        expectEqual(h.frame(of: s), at(780, 100))
        expectEqual(h.editor.holder(of: s), nil)
    },

    test("beside the corral it's in, it leaves it") {
        let k = ShapeID(), s = ShapeID()
        let h = try movingHarness(CanvasFile(root: board(corral(k, at(0, 0, 400, 400)), box(s, 50, 50, in: k))))
        expect(h.run("move-near", on: s, with: k))
        expectEqual(h.frame(of: s), at(480, 150))
        expectEqual(h.editor.holder(of: s), nil)
    },

    test("onto a region that paints above it (a box twice the size of the shape it lands beside), it's raised above that, as draw raises a shape over a zone it sits in") {
        let z = ShapeID(), x = ShapeID(), s = ShapeID()
        let h = try movingHarness(CanvasFile(root: board(box(s, 2000, 0), box(z, 0, 0, size: 1000), box(x, 100, 100))))
        expect(h.run("move-near", on: s, with: x))
        expectEqual(h.frame(of: s), at(280, 100), "on the region, not pushed off it")
        expectEqual(h.editor.document.shapes.map(\.id), [z, s, x], "just above the region, still under what it was beside")
    },

    test("a corral moved beside a shape takes what it holds along, which is never in its way") {
        let k = ShapeID(), a = ShapeID(), x = ShapeID()
        let h = try movingHarness(CanvasFile(root: board(corral(k, at(0, 0, 300, 200)), box(a, 40, 40, in: k), box(x, 1000, 0))))
        expect(h.run("move-near", on: k, with: x))
        expectEqual(h.frame(of: k), at(1180, -50, 300, 200))
        expectEqual(h.frame(of: a), at(1220, -10))
        expectEqual(h.editor.holder(of: a), k)
    },

    test("beside a shape on the root, from a pocket's board: onto the root, put down there; the window stays where it is") {
        let p = ShapeID(), x = ShapeID(), s = ShapeID()
        let h = try movingHarness(CanvasFile(root: board(pocket(p, 0, 0), box(x, 400, 400)), children: [p: board(box(s, 0, 0))]))
        expect(h.enter(p))
        let before = h.file
        expect(h.run("move-near", on: s, with: x))
        expectEqual(h.editor.board, BoardID(owner: p))
        expectEqual(h.editor.document[s], nil)
        expectEqual(h.file.board(containing: s), .root)
        expectEqual(h.frame(of: s), at(580, 400))
        expectEqual(h.editor.undoHistory.undoName, "Move")
        h.editor.undo()
        try expectFile(h, before, "back on the pocket's board")
    },

    test("beside a shape on a pocket's board, from the root: onto that board, put down there, in the corral the shape is in") {
        let p = ShapeID(), k = ShapeID(), x = ShapeID(), s = ShapeID()
        let h = try movingHarness(CanvasFile(root: board(pocket(p, 0, 0), box(s, 400, 0)),
                                             children: [p: board(corral(k, at(0, 0, 800, 600)), box(x, 100, 100, in: k))]))
        expect(h.run("move-near", on: s, with: x))
        expectEqual(h.file.board(containing: s), BoardID(owner: p))
        expectEqual(h.frame(of: s), at(280, 100))
        expectEqual(h.container(of: s), k)
    },

    test("beside a frozen shape: it doesn't change, so it's fine") {
        let x = ShapeID(), s = ShapeID()
        let h = try movingHarness(CanvasFile(root: board(box(s, 2000, 2000), AnyShapeRecord(ShapeRecord(id: x, Box(xFrame))))))
        h.freeze([x])
        expect(h.run("move-near", on: s, with: x))
        expectEqual(h.frame(of: s), at(580, 400))
    },
])

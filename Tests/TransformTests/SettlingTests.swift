import Canvas
import CanvasTesting
import CoreGraphics
import TestKit
import Transform

// A shape turned is put down anew, by the in-or-out rule (`Transaction.settle`), as a placement is: one
// that turns into a larger shape may hang over the container it's in, or reach into another.

@MainActor let transformSettlingTests = Suite("Turning and the in-or-out rule", [
    test("a turned shape poking out of the corral it's in is nudged back inside, in the turn's own step, and glides there") {
        let o = ShapeID(), k = ShapeID()
        let h = try transformHarness(file: CanvasFile(root: board(corral(o, CGRect(x: 0, y: 0, width: 600, height: 400)),
                                                                  corral(k, CGRect(x: 400, y: 100, width: 90, height: 60), in: o))))
        let before = h.file
        expect(h.editor.transforms?.turn([k], into: Pocket.kind) == true)
        // 240 wide from x = 400 would reach 640; 16 units inside the container's edge is 584.
        expectEqual(h.editor.document[k]?.box, CGRect(x: 344, y: 100, width: pocketSize.width, height: pocketSize.height))
        expectEqual(h.editor.holder(of: k), o, "still in its corral")
        expect(h.editor.isGliding(k), "it eases to where it is")
        expectEqual(h.editor.drawingOffset(of: k), CGPoint(x: 56, y: 0), "from where it was drawn at the corral's corner")
        expectEqual(h.editor.undoHistory.undoName, "Turn into Pocket")
        h.editor.undo()
        try expectFile(h, before, "the nudge is part of the step")
    },

    test("one that would land mostly outside the corral it's in is shifted back inside it all the same: it keeps its container") {
        let o = ShapeID(), k = ShapeID()
        let h = try transformHarness(file: CanvasFile(root: board(corral(o, CGRect(x: 0, y: 0, width: 600, height: 400)),
                                                                  corral(k, CGRect(x: 500, y: 100, width: 90, height: 60), in: o))))
        expect(h.editor.transforms?.turn([k], into: Pocket.kind) == true)
        // From x = 500 a pocket would lie 100 of its 240 inside: by area alone it would go out. 16 inside the edge is 344.
        expectEqual(h.editor.document[k]?.box, CGRect(x: 344, y: 100, width: pocketSize.width, height: pocketSize.height))
        expectEqual(h.editor.holder(of: k), o, "still in its corral")
        expect(h.editor.isGliding(k))
        expectEqual(h.editor.drawingOffset(of: k), CGPoint(x: 156, y: 0), "from where it was drawn at the corral's corner")
    },

    test("a shape turned into a larger one that reaches into a container beside it is nudged out of it, as a placement would be") {
        let k = ShapeID(), m = ShapeID()
        let h = try transformHarness(file: CanvasFile(root: board(corral(k, CGRect(x: 0, y: 0, width: 100, height: 60)),
                                                                  corral(m, CGRect(x: 150, y: 0, width: 300, height: 200)))))
        expect(h.editor.transforms?.turn([k], into: Pocket.kind) == true)
        // Clear of the other corral by 16 units, the shortest way.
        expectEqual(h.editor.document[k]?.box, CGRect(x: -106, y: 0, width: pocketSize.width, height: pocketSize.height))
        expectEqual(h.editor.holder(of: k), nil)
        expect(h.editor.isGliding(k))
    },

    test("one that fits where it is isn't nudged, and doesn't glide") {
        let k = ShapeID(), a = ShapeID()
        let h = try transformHarness(file: CanvasFile(root: board(corral(k, CGRect(x: 100, y: 100, width: 300, height: 200)), box(a, x: 120, y: 120, in: k))))
        expect(h.editor.transforms?.turn([k], into: Pocket.kind) == true)
        expectEqual(h.editor.document[k]?.box, CGRect(x: 100, y: 100, width: pocketSize.width, height: pocketSize.height))
        expect(!h.editor.isGliding(k))
    },
])

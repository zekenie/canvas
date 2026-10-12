@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Keyboard
import Selection
import TestKit

// Resizing a container (CanvasTesting's corrals, resizable from another plugin): on the release, not while
// it goes, what it now reaches or lets go of settles in or out of it, gliding there, in the resize's
// step; and a shape in a container never grows across its edge. The camera is at the origin at 100%,
// so view points and world units agree.

/// Corrals that resize, from another plugin, never smaller than 20 by 20.
@MainActor func resizableCorrals() -> Contributor {
    Contributor(id: "resizable-corrals") { $0.resizable(Corral.self, minimumSize: CGSize(width: 20, height: 20)) }
}

/// An editor with keys, the selection, the fixtures, corrals, and boxes and corrals that resize.
@MainActor func corralResizeHarness() throws -> EditorHarness {
    let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), CorralsPlugin(), resizableBoxes(), resizableCorrals()])
    return h
}

@MainActor let resizeSettleTests = Suite("Resizing containers", [
    test("a container grown over shapes takes in, at the release, what's mostly inside it, nudging in what hangs over, and nudges out what's mostly outside") {
        let h = try corralResizeHarness()
        let corral = h.add(Corral(CGRect(x: 100, y: 100, width: 300, height: 200)))
        let wholly = h.add(Box(CGRect(x: 420, y: 150, width: 60, height: 40)))       // inside once it's grown
        let mostly = h.add(Box(CGRect(x: 550, y: 210, width: 80, height: 40)))       // 50 of 80 inside
        let barely = h.add(Box(CGRect(x: 580, y: 150, width: 80, height: 40)))       // 20 of 80 inside
        h.editor.replaceDocument(with: h.editor.document)                            // nothing to undo
        let before = h.editor.document
        h.editor.selection = corral
        let handle = CGPoint(x: 400, y: 200)
        h.move(to: handle)
        h.press(at: handle)
        h.drag(to: CGPoint(x: 500, y: 200))
        h.drag(to: CGPoint(x: 600, y: 200))
        expectEqual(h.frame(of: corral), CGRect(x: 100, y: 100, width: 500, height: 200))
        expectEqual(h.editor.holder(of: wholly), nil, "nothing settles while it goes")
        expectEqual(h.frame(of: barely), CGRect(x: 580, y: 150, width: 80, height: 40))
        h.release()
        expectEqual(h.editor.holder(of: wholly), corral, "wholly inside: in, where it is")
        expectEqual(h.frame(of: wholly), CGRect(x: 420, y: 150, width: 60, height: 40))
        expectEqual(h.editor.holder(of: mostly), corral, "mostly inside: in")
        expectEqual(h.frame(of: mostly), CGRect(x: 504, y: 210, width: 80, height: 40), "nudged to the gap inside the edge")
        expectEqual(h.editor.holder(of: barely), nil, "mostly outside: out")
        expectEqual(h.frame(of: barely), CGRect(x: 616, y: 150, width: 80, height: 40), "nudged to the gap outside the edge")
        expect(h.editor.isGliding(mostly) && h.editor.isGliding(barely), "the nudged glide there")
        expect(!h.editor.isGliding(wholly))
        expectEqual(h.editor.undoHistory.undoName, "Resize", "the resize and its settling are one step")
        h.editor.undo()
        expectEqual(h.editor.document, before, "undone whole: sizes, places and containers")
    },
    test("a container shrunk off what's in it lets go of what's mostly outside, nudged out, and nudges in what's mostly inside") {
        let h = try corralResizeHarness()
        let corral = h.add(Corral(CGRect(x: 100, y: 100, width: 400, height: 300)))
        let leaving = h.add(Box(CGRect(x: 380, y: 150, width: 100, height: 50)))     // 20 of 100 inside, shrunk
        let staying = h.add(Box(CGRect(x: 330, y: 220, width: 60, height: 40)))      // still wholly inside
        let kept = h.add(Box(CGRect(x: 350, y: 300, width: 60, height: 40)))         // 50 of 60 inside
        h.editor.put([leaving, staying, kept], in: corral)
        h.editor.selection = corral
        h.resize(corral, .right, by: CGPoint(x: -100, y: 0))
        expectEqual(h.frame(of: corral), CGRect(x: 100, y: 100, width: 300, height: 300))
        expectEqual(h.editor.holder(of: leaving), nil)
        expectEqual(h.frame(of: leaving), CGRect(x: 416, y: 150, width: 100, height: 50))
        expectEqual(h.editor.holder(of: staying), corral)
        expectEqual(h.frame(of: staying), CGRect(x: 330, y: 220, width: 60, height: 40))
        expectEqual(h.editor.holder(of: kept), corral)
        expectEqual(h.frame(of: kept), CGRect(x: 324, y: 300, width: 60, height: 40))
    },
    test("a shape in a container stops the gap inside its edge, however far it's pulled; one on the board grows freely") {
        let h = try corralResizeHarness()
        let outer = h.add(Corral(CGRect(x: 100, y: 100, width: 400, height: 300)))
        let inner = h.add(Corral(CGRect(x: 150, y: 150, width: 100, height: 100)))
        h.editor.put([inner], in: outer)
        h.editor.selection = inner
        h.resize(inner, .right, by: CGPoint(x: 400, y: 0))
        expectEqual(h.frame(of: inner), CGRect(x: 150, y: 150, width: 334, height: 100), "to 16 inside the outer's right edge")
        expectEqual(h.editor.holder(of: inner), outer)
        h.resize(inner, .topLeft, by: CGPoint(x: -400, y: -400))
        expectEqual(h.frame(of: inner), CGRect(x: 116, y: 116, width: 368, height: 134))
        h.editor.selection = outer
        h.resize(outer, .bottomRight, by: CGPoint(x: 300, y: 300))
        expectEqual(h.frame(of: outer), CGRect(x: 100, y: 100, width: 700, height: 600), "on the board, nothing stops it")
    },
    test("a box that isn't a container settles nothing as it's resized") {
        let h = try corralResizeHarness()
        let box = h.add(Box(CGRect(x: 100, y: 100, width: 200, height: 100)))
        let other = h.add(Box(CGRect(x: 320, y: 120, width: 60, height: 40)))
        h.editor.selection = box
        h.resize(box, .right, by: CGPoint(x: 150, y: 0))
        expectEqual(h.frame(of: box), CGRect(x: 100, y: 100, width: 350, height: 100))
        expectEqual(h.frame(of: other), CGRect(x: 320, y: 120, width: 60, height: 40), "boxes overlap as they always could")
        expect(!h.editor.isGliding(other))
    },
    test("a container resized settles its members by their laid-out frames: one grown past the new edge is nudged in at the release, in the resize's step") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), CorralsPlugin(), resizableBoxes(), resizableCorrals(), StretchesPlugin()])
        let corral = h.add(Corral(CGRect(x: 100, y: 100, width: 300, height: 200)))
        let gauge = h.add(CanvasTesting.Gauge(CGRect(x: 900, y: 700, width: 60, height: 40), width: 200, height: 60))
        let member = h.add(Stretch(CGRect(x: 250, y: 150, width: 100, height: 60), gauge: gauge))      // stored inside, laid out to x 450
        h.editor.put([member], in: corral)
        h.editor.replaceDocument(with: h.editor.document)
        let before = h.editor.document
        h.editor.selection = corral
        let handle = CGPoint(x: 400, y: 200)
        h.move(to: handle)
        h.press(at: handle)
        h.drag(to: CGPoint(x: 410, y: 200))
        h.drag(to: CGPoint(x: 420, y: 200))
        expectEqual(h.editor.document[member]?.box?.origin, CGPoint(x: 250, y: 150), "nothing settles while it goes")
        h.release()
        expectEqual(h.editor.holder(of: member), corral)
        expectEqual(h.editor.document[member]?.box?.origin, CGPoint(x: 204, y: 150), "its frame brought in to the gap inside the new edge, 420")
        expectEqual(h.editor.undoHistory.undoName, "Resize")
        h.editor.undo()
        expectEqual(h.editor.document, before, "undone whole")
    },
])

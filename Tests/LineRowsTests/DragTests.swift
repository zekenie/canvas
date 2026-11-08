import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Geometry
import LineRows
import Selection
import TestKit

// Rows dragged, over tallies on a real canvas: entries selected as items and pressed past the threshold, or an entry's lead
// pressed at any time, drag a session that writes nothing until the release, then `moveRows`: into the tally under the pointer
// before the gap nearest it, or onto the board as a tally of their own. While it runs: the rows faded where they are, the
// drop line at the gap, the target hinted, a ghost of the rows under the pointer; Escape changes nothing; it scrolls at the
// edges; a folded target unfolds as they land; a read-only one refuses. A header moves with the rows it heads.

extension Bench {
    /// The middle of entry `label`'s line in tally `id`, world units.
    func middle(of label: String, in id: ShapeID) -> CGPoint {
        let rect = editor.shapeContext.geometry(of: id)?.parts.frame(ids(id, label)[0])?.rect ?? .zero
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    /// Where the gap before line `gap` of tally `id` is, a little below it, world units (the left of its middle).
    func gap(_ gap: Int, of id: ShapeID, dy: CGFloat = 3) -> CGPoint {
        let frame = editor.shapeContext.frame(of: editor.document[id]!)!
        return CGPoint(x: frame.midX, y: frame.minY + Tally.head + CGFloat(gap) * Tally.rowHeight + dy)
    }

    /// A press at a world point, dragged past the threshold, then to `to`: not let go.
    func startDrag(at from: CGPoint, to: CGPoint) {
        h.press(at: h.view(from))
        h.drag(to: h.view(CGPoint(x: from.x, y: from.y + 8)))
        h.drag(to: h.view(to))
    }

    /// `labels` of `id` selected as items of it.
    func selectItems(_ id: ShapeID, _ labels: String...) {
        editor.selectedShapeIDs = [id]
        editor.selectItems(labels.flatMap { ids(id, $0) }.map(AnyHashable.init), of: id)
    }

    /// The canvas drawn as a bitmap, 800 by 600.
    func picture() -> NSBitmapImageRep { renderBitmap(editor, size: CGSize(width: 800, height: 600)) }
}

/// Whether a pixel is the accent's: bluer than it is red, and not the paper's or the canvas's grey.
@MainActor private func isAccent(_ rgba: [Int]) -> Bool { rgba[2] > rgba[0] + 60 }

@MainActor let dragTests = Suite("Rows dragged", [
    test("A drop at each gap of the tally lands the selected entry there, one Move Entry; a gap inside the block or beside it is no move and no step") {
        let b = try Bench()
        let id = b.tally("fruit", ["one", "two", "three", "four"])
        let expected: [Int: [String]] = [0: ["two", "one", "three", "four"], 3: ["one", "three", "two", "four"], 4: ["one", "three", "four", "two"]]
        for gap in 0...4 {
            b.selectItems(id, "two")
            b.editor.undoHistory.seal()
            let steps = b.undoName
            b.startDrag(at: b.middle(of: "two", in: id), to: b.gap(gap, of: id))
            expectEqual(b.labels(id), ["one", "two", "three", "four"], "nothing written before the release (gap \(gap))")
            b.h.release()
            if let order = expected[gap] {
                expectEqual(b.labels(id), order, "gap \(gap)")
                expectEqual(b.undoName, "Move Entry")
                expectEqual(b.itemLabels, ["two"], "still selected")
                b.editor.undo()
            } else {
                expectEqual(b.labels(id), ["one", "two", "three", "four"], "gap \(gap) is the block's own: no move")
                expectEqual(b.undoName, steps, "and no step")
            }
            expectEqual(b.editor.session == nil, true)
        }
    },
    test("While it runs the rows are drawn faded, the drop line in the accent across the gap, the target hinted, and a ghost of the rows under the pointer; nothing at a gap that's no move") {
        let b = try Bench()
        let a = b.tally("a", ["one", "two", "three"])
        let c = b.tally("c", ["x", "y"], at: CGPoint(x: 450, y: 100))
        let before = b.picture()
        b.selectItems(a, "two")
        b.startDrag(at: b.middle(of: "two", in: a), to: b.gap(1, of: c, dy: 2))
        expectEqual(b.editor.hintedShapeID, c, "the tally it would land in, outlined")
        expectEqual(b.drawn().filter { $0.hasPrefix("~") }, ["~two"], "the row dragged, faded where it is")
        let during = b.picture()
        let lineY = 100 + Tally.head + Tally.rowHeight
        expect(isAccent(pixel(during, at: CGPoint(x: 560, y: lineY))), "the drop line at the gap: \(pixel(during, at: CGPoint(x: 560, y: lineY)))")
        expect(!isAccent(pixel(before, at: CGPoint(x: 560, y: lineY))))
        expect(!isAccent(pixel(during, at: CGPoint(x: 560, y: lineY + 8))), "two points, at the gap only")
        // The faded bar of two at the source: lighter than one's, darker than the paper.
        let one = pixel(during, at: b.middle(of: "one", in: a) + CGPoint(x: -111, y: 0))
        let two = pixel(during, at: b.middle(of: "two", in: a) + CGPoint(x: -111, y: 0))
        expect(one[0] < 30 && two[0] > 120 && two[0] < 230, "one \(one), two \(two) faded")
        // The ghost: its bar where the press grabbed it, moved with the pointer (grabbed 111 right of its bar's middle).
        let pointer = b.gap(1, of: c, dy: 2)
        let ghostBar = pixel(during, at: CGPoint(x: pointer.x - 111, y: pointer.y))
        expect(ghostBar[0] < 200, "the ghost's bar, faint: \(ghostBar)")
        expect(pixel(before, at: CGPoint(x: pointer.x - 111, y: pointer.y))[0] > 200)
        // Over its own gap: nothing hinted, and the release moves nothing.
        b.h.drag(to: b.h.view(b.gap(1, of: a, dy: 2)))
        expectEqual(b.editor.hintedShapeID, nil)
        b.h.release()
        expectEqual(b.labels(a), ["one", "two", "three"])
        expectEqual(b.drawn().filter { $0.hasPrefix("~") }, [], "faded no longer")
    },
    test("Into another tally before the gap, its ids kept and the tally selected with them; onto the board a tally of their own where the ghost is, Move Entry to New Tally") {
        let b = try Bench()
        let a = b.tally("a", ["one", "two", "three"])
        let c = b.tally("c", ["x", "y"], at: CGPoint(x: 450, y: 100))
        let two = b.ids(a, "two")[0]
        b.selectItems(a, "two")
        b.startDrag(at: b.middle(of: "two", in: a), to: b.gap(1, of: c))
        b.h.release()
        expectEqual(b.labels(a), ["one", "three"])
        expectEqual(b.labels(c), ["x", "two", "y"])
        expectEqual(b.ids(c, "two"), [two], "the id kept")
        expectEqual(b.undoName, "Move Entry")
        expectEqual(b.editor.selectedShapeIDs, [c])
        expectEqual(b.itemLabels, ["two"])
        expectEqual(b.editor.hintedShapeID, nil, "the hint let go")
        b.editor.undo()
        b.selectItems(a, "two", "three")
        b.startDrag(at: b.middle(of: "two", in: a), to: CGPoint(x: 300, y: 400))
        expectEqual(b.editor.hintedShapeID, nil, "the board: no target")
        b.h.release()
        expectEqual(b.labels(a), ["one"])
        let out = try require(b.editor.selectedShapeIDs.first)
        expectEqual(b.labels(out), ["two", "three"])
        expectEqual(b.undoName, "Move Entries to New Tally")
        // Its first line where the ghost's was: under the pointer as two was grabbed.
        let first = try require(b.editor.shapeContext.geometry(of: out)?.parts.frame(two)?.rect)
        expectEqual(first.midY, 400, "grabbed at its middle")
    },
    test("Escape changes nothing: no step, the rows where they were and not faded, no hint, no session") {
        let b = try Bench()
        let a = b.tally("a", ["one", "two"])
        let c = b.tally("c", ["x"], at: CGPoint(x: 450, y: 100))
        b.selectItems(a, "two")
        b.editor.undoHistory.seal()
        let steps = b.undoName
        b.startDrag(at: b.middle(of: "two", in: a), to: b.gap(1, of: c))
        b.h.escape()
        expectEqual(b.editor.session == nil, true)
        expectEqual(b.editor.hintedShapeID, nil)
        expectEqual(b.drawn().filter { $0.hasPrefix("~") }, [])
        b.h.release()
        expectEqual(b.labels(a), ["one", "two"])
        expectEqual(b.labels(c), ["x"])
        expectEqual(b.undoName, steps)
    },
    test("It scrolls at the canvas's edge, and what's under the pointer as it scrolls is where the rows go") {
        let b = try Bench()
        let a = b.tally("a", ["one", "two"])
        b.selectItems(a, "two")
        let origin = b.editor.camera.origin
        b.startDrag(at: b.middle(of: "two", in: a), to: b.editor.camera.toWorld(CGPoint(x: 798, y: 300)))
        b.h.wait(800)
        expect(b.editor.camera.origin.x > origin.x + 20, "scrolled right: \(b.editor.camera.origin)")
        b.h.release()
        let out = try require(b.editor.selectedShapeIDs.first)
        expect(out != a)
        let frame = try require(b.editor.shapeContext.frame(of: b.editor.document[out]!))
        expect(frame.minX > 600, "put down where the pointer was once scrolled: \(frame)")
    },
    test("A drop into a folded tally lands the entry and unfolds it, so the rows stay in sight") {
        let b = try Bench()
        let a = b.tally("a", ["one", "two"])
        let c = b.tally("c", ["x 1", "y", "z"], at: CGPoint(x: 450, y: 100))
        b.editor.rowFolds?.fold([c])
        b.window.settle()
        expectEqual(b.drawn().filter { ["x", "y", "z", "+2"].contains($0) }, ["x", "+2"], "folded: x and the +2 line")
        b.selectItems(a, "two")
        b.startDrag(at: b.middle(of: "two", in: a), to: b.gap(1, of: c))
        b.h.release()
        expectEqual(b.labels(c), ["x", "two", "y", "z"], "past x, before the rows the fold hid")
        expectEqual(b.editor.rowFolds?.isFolded(c), false)
    },
    test("A read-only tally takes nothing: no hint and no line over it, and the release shakes it and writes nothing") {
        let b = try Bench()
        let a = b.tally("a", ["one", "two"])
        let c = b.tally("c", ["x", "y"], at: CGPoint(x: 450, y: 100))
        b.editor.freeze([c])
        b.selectItems(a, "two")
        b.editor.undoHistory.seal()
        let steps = b.undoName
        b.startDrag(at: b.middle(of: "two", in: a), to: b.gap(1, of: c, dy: 2))
        expectEqual(b.editor.hintedShapeID, nil)
        expect(!isAccent(pixel(b.picture(), at: CGPoint(x: 560, y: 100 + Tally.head + Tally.rowHeight))), "no line")
        b.h.release()
        expectEqual(b.labels(a), ["one", "two"])
        expectEqual(b.labels(c), ["x", "y"])
        expectEqual(b.undoName, steps, "no step")
        expect(b.refusals.refusals.last?.contains(c) == true, "it shakes")
    },
    test("An entry's lead drags it at once, the tally unselected; a click on it selects the tally, then the entry") {
        let b = try Bench()
        let a = b.tally("a", ["one 1", "two"])
        let c = b.tally("c", ["x"], at: CGPoint(x: 450, y: 100))
        let lead = CGPoint(x: 105, y: b.middle(of: "one", in: a).y)
        b.editor.selectedShapeIDs = []
        b.startDrag(at: lead, to: b.gap(1, of: c))
        b.h.release()
        expectEqual(b.labels(c), ["x", "one"])
        expectEqual(b.editor.selectedShapeIDs, [c])
        b.editor.undo()
        b.editor.selectedShapeIDs = []
        b.h.click(at: b.h.view(lead))
        expectEqual(b.editor.selectedShapeIDs, [a], "a click on the lead: the tally")
        expectEqual(b.editor.selectedItems, nil)
        b.h.wait(1000)
        b.h.click(at: b.h.view(lead))
        expectEqual(b.itemLabels, ["one"], "then the entry")
        // An entry with no count has no lead: a press there on an unselected tally moves the tally.
        b.editor.selectedShapeIDs = []
        let tally = try require(b.editor.document[a]?.box)
        b.h.wait(1000)
        b.startDrag(at: CGPoint(x: 105, y: b.middle(of: "two", in: a).y), to: CGPoint(x: 105, y: 400))
        b.h.release()
        expect(b.editor.document[a]?.box != tally, "the tally moved")
        expectEqual(b.labels(a), ["one", "two"])
    },
    test("A header moves with the entries it heads: ⌥↓ passes the next group, ⌥↑ back, none past the first; dragged, it takes them along") {
        let b = try Bench()
        let id = b.tally("t", ["top", "g/", "one", "two", "h/", "three"])
        b.selectItems(id, "g/")
        b.press(.optionDown)
        expectEqual(b.labels(id), ["top", "h/", "three", "g/", "one", "two"])
        expectEqual(b.undoName, "Move Entries")
        expectEqual(b.itemLabels, ["g/"], "the header still the one selected")
        b.press(.optionDown)
        expectEqual(b.labels(id), ["top", "h/", "three", "g/", "one", "two"], "the last group goes no further")
        b.hold(.optionUp, repeats: 1)
        expectEqual(b.labels(id), ["top", "g/", "one", "two", "h/", "three"], "back, and no group goes above the rows under none")
        b.editor.undo()
        expectEqual(b.labels(id), ["top", "h/", "three", "g/", "one", "two"], "a held key one step")
        b.editor.undo()
        expectEqual(b.labels(id), ["top", "g/", "one", "two", "h/", "three"])
        b.selectItems(id, "one")
        b.press(.optionUp)
        expectEqual(b.labels(id), ["top", "one", "g/", "two", "h/", "three"], "an entry passes a header on its own")
        b.editor.undo()
        b.selectItems(id, "g/")
        b.startDrag(at: b.middle(of: "g/", in: id), to: b.gap(6, of: id))
        b.h.release()
        expectEqual(b.labels(id), ["top", "h/", "three", "g/", "one", "two"], "dragged to the end, its entries with it")
    },
])

import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Geometry
import TestKit

// A container's tab gives way to a row a shape in it keeps zoomed out (`RowZoomedOut`): up off the edge (left, turned) where the row
// can't start past the tab and keep its least; the row that can, and a kind that keeps none, leave it on its edge. Toy kinds only
// (CanvasTesting's corrals and boxes), so the point knows no real one.

/// A plugin that gives every box in a container (kind "box") a row at `rect` of it zoomed out, keeping at least `least`; nil for `nil`.
@MainActor private func rows(least: CGFloat, nil omits: Bool = false, _ rect: @escaping @MainActor (CGRect) -> CGRect) -> Contributor {
    Contributor(id: "box-rows") { r in
        r.forShapes(adopting: ShapeCapability("that box-rows picks", { $0.kind == Box.kind })) {
            $0.rowZoomedOut { shape, _ in
                guard !omits, let box = shape.box else { return nil }
                return RowZoomedOut(rect: rect(box), least: least)
            }
        }
    }
}

@MainActor private func scene(_ more: Contributor, corral frame: CGRect, label: String = "Lobby", zoom: CGFloat = 0.1) throws -> (h: EditorHarness, corral: ShapeID) {
    let h = try adornedHarness([CorralsPlugin(), everyShape(Banner.self, where: { $0.kind == Corral.kind }) { _ in AdornmentLabel(label) }, more])
    h.editor.viewportDidResize(to: CGSize(width: 400, height: 300))
    h.editor.camera = Camera(origin: .zero, zoom: zoom)
    return (h, h.add(Corral(frame)))
}

@MainActor private func tab(_ h: EditorHarness, _ id: ShapeID) throws -> CGRect {
    _ = render(h)
    return try require(h.editor.adornmentFrames(of: id).first { $0.adornment == .of(Banner.self) }?.rect, "a tab")
}

@MainActor let rowGiveWayTests = Suite("A tab giving way to a row kept zoomed out", [
    test("a row that can't start past the tab lifts it up off its edge, its bottom a spacing above the row; at full zoom the tab stays") {
        let (h, corral) = try scene(rows(least: 100) { $0 }, corral: CGRect(x: 100, y: 100, width: 800, height: 500))
        let box = h.add(Box(CGRect(x: 132, y: 132, width: 260, height: 60)))
        h.editor.put([box], in: corral)
        let lifted = try tab(h, corral)
        expect(lifted.maxY <= 132 - AdornmentLayout.spacing / 0.1 + 0.5, "clear of the row: \(lifted)")
        expect(lifted.maxY < 100, "off the edge: \(lifted)")
        h.editor.camera = Camera(origin: .zero, zoom: 1)
        let full = try tab(h, corral)
        expect(full.minY < 100 && full.maxY > 100, "on the edge at 100%: \(full)")
    },
    test("a row with room past the tab for its least keeps its place, the tab on its edge") {
        let (h, corral) = try scene(rows(least: 100) { $0 }, corral: CGRect(x: 100, y: 100, width: 800, height: 500))
        let box = h.add(Box(CGRect(x: 132, y: 132, width: 3000, height: 60)))
        h.editor.put([box], in: corral)
        let kept = try tab(h, corral)
        expect(kept.minY < 100 && kept.maxY > 100, "on its edge: \(kept)")
        // Its least met exactly: a row of the tab's room and the least stays, one a point short lifts it.
        let start = kept.maxX + AdornmentLayout.spacing * AdornmentLayout.scale(atZoom: 0.1) - 132
        h.editor.transact { $0.update(box) { $0.box = CGRect(x: 132, y: 132, width: start + 100, height: 60) } }
        let met = try tab(h, corral)
        expect(met.maxY > 100, "the least met: on the edge, \(met)")
        h.editor.transact { $0.update(box) { $0.box = CGRect(x: 132, y: 132, width: start + 99, height: 60) } }
        expect(try tab(h, corral).maxY < 100, "a point short: lifted")
    },
    test("a kind whose row is nil leaves the tab alone") {
        let (h, corral) = try scene(rows(least: 100, nil: true) { $0 }, corral: CGRect(x: 100, y: 100, width: 800, height: 500))
        h.editor.put([h.add(Box(CGRect(x: 132, y: 132, width: 260, height: 60)))], in: corral)
        let kept = try tab(h, corral)
        expect(kept.minY < 100 && kept.maxY > 100, "on its edge: \(kept)")
    },
    test("a row out of the view and its container's tab: placed with the view's tabs, and a row off the container's top-left corner leaves it") {
        let (h, corral) = try scene(rows(least: 100) { $0 }, corral: CGRect(x: 100, y: 100, width: 800, height: 500))
        h.editor.put([h.add(Box(CGRect(x: 600, y: 400, width: 100, height: 60)))], in: corral)
        let kept = try tab(h, corral)
        expect(kept.minY < 100 && kept.maxY > 100, "a table far from the corner: on its edge: \(kept)")
    },
    test("deleting, cutting out, or moving off the row the tab made way for places it on its edge again, the view unchanged (review U13-C1)") {
        let (h, corral) = try scene(rows(least: 100) { $0 }, corral: CGRect(x: 100, y: 100, width: 800, height: 500))
        let box = h.add(Box(CGRect(x: 132, y: 132, width: 260, height: 60)))
        h.editor.put([box], in: corral)
        expect(try tab(h, corral).maxY < 100, "lifted")
        h.editor.transact("Delete") { $0.delete([box]) }
        let back = try tab(h, corral)
        expect(back.minY < 100 && back.maxY > 100, "deleted: back on its edge: \(back)")
        h.editor.undo()
        expect(try tab(h, corral).maxY < 100, "undone: lifted again")
        h.editor.transact("Move") { $0.update(box) { $0.box = CGRect(x: 600, y: 400, width: 100, height: 60) } }
        expect(try tab(h, corral).maxY > 100, "moved away: back on its edge")
    },
    test("a tall narrow container's turned tab gives way left of the row, and stays where the row can start past it") {
        let (h, corral) = try scene(rows(least: 200) { $0 }, corral: CGRect(x: 100, y: 100, width: 400, height: 2000), label: "Lobby hall")
        let box = h.add(Box(CGRect(x: 150, y: 250, width: 240, height: 60)))
        h.editor.put([box], in: corral)
        let turned = try tab(h, corral)
        expect(turned.height > turned.width, "turned: \(turned)")
        expect(turned.maxX <= 150 - AdornmentLayout.spacing / 0.1 + 0.5, "left of the row, a spacing clear: \(turned)")
        // With the row a long way down the edge, past the tab's end: on its edge.
        h.editor.transact { $0.update(box) { $0.box = CGRect(x: 150, y: 1500, width: 240, height: 60) } }
        let kept = try tab(h, corral)
        expect(kept.minX < 100 && kept.maxX > 100, "on its edge: \(kept)")
    },
    test("a tab lifted over another shape goes left of its container's edge instead, and stays lifted where both are taken (review U13-E3)") {
        let (h, corral) = try scene(rows(least: 100) { $0 }, corral: CGRect(x: 100, y: 300, width: 800, height: 500))
        let box = h.add(Box(CGRect(x: 132, y: 332, width: 260, height: 60)))
        h.editor.put([box], in: corral)
        // A shape above the container where the lifted tab lands, and the edge of the corral free to its left.
        let above = h.add(Box(CGRect(x: 100, y: 60, width: 500, height: 200)))
        let moved = try tab(h, corral)
        expect(moved.maxX <= 100 + 0.5, "left of the container's edge: \(moved)")
        let box2 = h.editor.document[above]!.box!
        expect(!moved.intersects(box2), "clear of the shape above: \(moved) and \(box2)")
    },
])

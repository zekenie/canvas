@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import TestKit

// A placed shape written to suit where it lands (`registrar.placementFit`): a fit that marks what's placed
// in the corrals it names ("pens") and widens a disc there to 60, so a disc placed near a pen's edge hangs
// over it once fitted and is settled again; or, `turning`, answers a box for a disc there, which an open
// kind takes and a closed one doesn't. A second fit says what it was handed, so the chain shows. The pen
// is a corral 400 × 300 at (100, 100); the camera is at the origin at 100%, so view points are world units.

private let penRect = CGRect(x: 100, y: 100, width: 400, height: 300)

/// What a fit writes on a shape it fits.
private enum Fitted: ShapeProperty {
    static let key: PropertyKey = "fitted"
    static var defaultValue: String? { nil }
}

/// The corrals the fit writes into, and what each fit was handed.
@MainActor private final class Pens {
    var pens: Set<ShapeID> = []
    var turning = false
    var asks: [(kind: ShapeKind, place: ShapePlace, kindIsOpen: Bool)] = []
    /// What the second fit was handed: the first one's mark, or nil.
    var seen: [String?] = []
}

@MainActor private func fitting(_ pens: Pens) -> Contributor {
    Contributor(id: "fits") { r in
        r.declare(Fitted.self)
        r.optInEveryShape(to: Fitted.self)
        r.shape(BoxDefinitionForTests())
        r.placementFit { fit in
            pens.asks.append((fit.record.kind, fit.place, fit.kindIsOpen))
            var record = fit.record
            if record.kind == Corral.kind {
                record[Fitted.self] = "around"
                return record
            }
            guard case .container(let id) = fit.place, pens.pens.contains(id) else { return nil }
            if record.kind == Disc.kind, pens.turning, let box = record.box {
                var turned = AnyShapeRecord(ShapeRecord(id: record.id, Box(box)))
                turned[Fitted.self] = "turned"
                return turned
            }
            if record.kind == Disc.kind { record.box?.size.width = 60 }
            record[Fitted.self] = "pen"
            return record
        }
    }
}

@MainActor private func seeing(_ pens: Pens) -> Contributor {
    Contributor(id: "seeing") { r in
        r.placementFit { fit in
            pens.seen.append(fit.record[Fitted.self])
            return nil
        }
    }
}

@MainActor private func fitHarness(_ pens: Pens) throws -> EditorHarness {
    let h = try EditorHarness(plugins: [CorralsPlugin(), discTools(), CardsPlugin(), fitting(pens), seeing(pens)])
    h.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
    return h
}

extension EditorHarness {
    fileprivate func box(of shape: ShapeID) -> CGRect? { editor.document[shape]?.box }
    fileprivate func fitted(_ shape: ShapeID) -> String? { editor.document[shape]?[Fitted.self] }
    fileprivate var discPlacement: Placement { editor.registry.placement(for: Disc.kind)! }
    fileprivate var newest: ShapeID? { editor.document.shapes.last?.id }
}

/// A container a tool places, 400 × 300: what a fit can make refuse what it lands on.
private struct Fold: BoxShapeProps {
    static let kind: ShapeKind = "fold"
    static let properties = Properties<Fold> { Property("frame", \.frame).required() }
    var frame: CGRect
    init(_ frame: CGRect) { self.frame = frame }
    init() { self.init(.zero) }
}

private struct FoldDefinition {}

extension FoldDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Fold>, in context: RenderContext) {}
}

extension FoldDefinition: ShapeContaining {}

/// Folds a tool places, fitted "picky", and a judge that lets no disc moved in into a picky fold.
@MainActor private func pickyFolds() -> Contributor {
    Contributor(id: "folds") { r in
        r.declare(Fitted.self)
        r.optInEveryShape(to: Fitted.self)
        r.shape(FoldDefinition()) { fold in
            fold.tool(label: "Fold", systemImage: "square", placing: fold.placement(size: CGSize(width: 400, height: 300)) { Fold() })
        }
        r.placementFit { fit in
            guard fit.record.kind == Fold.kind else { return nil }
            var record = fit.record
            record[Fitted.self] = "picky"
            return record
        }
        r.admission { admission in
            for arrival in admission.arrivals where !arrival.isNew && arrival.record.kind == Disc.kind {
                if case .container(let id) = arrival.to, admission.context.shape(id)?[Fitted.self] == "picky" {
                    return .refuses(shaking: [id], saying: nil)
                }
            }
            return .admits
        }
    }
}

@MainActor let placementFitTests = Suite("Placement fit", [
    test("a shape placed with no press is fitted where it lands and settled again, nudged in as it's laid out now, one step undone whole") {
        let pens = Pens()
        let h = try fitHarness(pens)
        let pen = h.add(Corral(penRect))
        pens.pens = [pen]
        h.editor.place(h.discPlacement, at: CGPoint(x: 480, y: 200))         // a 40-point disc at (460, 180): wholly in
        let d = try require(h.newest)
        expectEqual(h.fitted(d), "pen")
        expectEqual(h.box(of: d), CGRect(x: 424, y: 180, width: 60, height: 40), "60 wide, it hung over: nudged to the gap inside the edge")
        expectEqual(h.editor.holder(of: d), pen)
        expectEqual(h.editor.drawingOffset(of: d), CGPoint(x: 36, y: 0), "glides from where it was put down")
        expectEqual(pens.asks.map(\.place), [.container(pen)], "asked once settling said where it goes")
        expectEqual(pens.seen, ["pen"], "the next fit is handed the last one's record")
        expectEqual(h.editor.undoHistory.undoName, "Add Disc")
        h.editor.undo()
        expectEqual(h.editor.document[d], nil, "one step, undone whole")
        h.editor.redo()
        expectEqual(h.fitted(d), "pen")
        expectEqual(h.box(of: d), CGRect(x: 424, y: 180, width: 60, height: 40))
    },
    test("a shape placed with a press is fitted where it's released, in the press's step") {
        let pens = Pens()
        let h = try fitHarness(pens)
        let pen = h.add(Corral(penRect))
        pens.pens = [pen]
        h.editor.setTool("disc")
        h.press(at: CGPoint(x: 700, y: 200))
        let d = try require(h.newest)
        expectEqual(pens.asks.count, 0, "not while it follows the pointer")
        h.drag(to: CGPoint(x: 600, y: 200))
        h.drag(to: CGPoint(x: 480, y: 200))
        h.release()
        expectEqual(h.fitted(d), "pen")
        expectEqual(h.box(of: d), CGRect(x: 424, y: 180, width: 60, height: 40))
        expectEqual(h.editor.holder(of: d), pen)
        expectEqual(pens.asks.map(\.place), [.container(pen)])
        expectEqual(h.editor.undoHistory.undoName, "Add Disc")
        h.editor.undo()
        expectEqual(h.editor.document[d], nil)
    },
    test("outside a pen nothing is written, and the shape is asked about on the board's top level") {
        let pens = Pens()
        let h = try fitHarness(pens)
        let pen = h.add(Corral(penRect))
        pens.pens = [pen]
        h.editor.place(h.discPlacement, at: CGPoint(x: 700, y: 200))
        let d = try require(h.newest)
        expectEqual(h.fitted(d), nil)
        expectEqual(h.box(of: d), CGRect(x: 680, y: 180, width: 40, height: 40))
        expectEqual(pens.asks.map(\.place), [.board(.root)])
    },
    test("a placement in a rect, at the keyboard and by Insert is fitted too") {
        let pens = Pens()
        let h = try fitHarness(pens)
        let pen = h.add(Corral(penRect))
        pens.pens = [pen]
        h.editor.place(h.discPlacement, in: CGRect(x: 200, y: 200, width: 40, height: 40))
        let inRect = try require(h.newest)
        expectEqual(h.fitted(inRect), "pen")
        expectEqual(h.box(of: inRect), CGRect(x: 200, y: 200, width: 60, height: 40))
        h.editor.setTool("disc")
        h.move(to: CGPoint(x: 300, y: 300))
        expect(h.editor.placeAtKeyboard())
        let atKeyboard = try require(h.newest)
        expect(atKeyboard != inRect)
        expectEqual(h.fitted(atKeyboard), "pen")
        expect(h.editor.insert(ToolID(placing: Disc.kind), beside: []))      // in the middle of the view, (400, 300): in the pen
        let inserted = try require(h.newest)
        expect(inserted != atKeyboard)
        expectEqual(h.fitted(inserted), "pen")
        expectEqual(h.editor.holder(of: inserted), pen)
    },
    test("shapes placed later are fitted, put down by a press or by Return") {
        let pens = Pens()
        let h = try fitHarness(pens)
        let pen = h.add(Corral(penRect))
        pens.pens = [pen]
        func later() -> PendingPlacement {
            PendingPlacement([AnyShapeRecord(ShapeRecord(Disc(CGRect(x: 0, y: 0, width: 40, height: 40))))], stepName: "Add Discs") { _ in
                [CGPoint(x: -20, y: -20)]
            }
        }
        h.move(to: CGPoint(x: 300, y: 200))
        expect(h.editor.placeLater(later()))
        h.click()
        let pressed = try require(h.newest)
        expectEqual(h.fitted(pressed), "pen")
        expectEqual(h.editor.undoHistory.undoName, "Add Discs")
        h.move(to: CGPoint(x: 300, y: 300))
        expect(h.editor.placeLater(later()))
        expect(h.editor.placeAtKeyboard())
        let returned = try require(h.newest)
        expect(returned != pressed)
        expectEqual(h.fitted(returned), "pen")
        expectEqual(pens.asks.map(\.kindIsOpen), [false, false], "shapes placed later keep their kinds")
    },
    test("an editing placement edits the shape as fitted") {
        let pens = Pens()
        let h = try fitHarness(pens)
        let pen = h.add(Corral(penRect))
        pens.pens = [pen]
        h.editor.setTool("card")
        h.press(at: CGPoint(x: 300, y: 200))
        let card = try require(h.newest)
        h.release()
        expectEqual(h.fitted(card), "pen")
        expectEqual(h.editor.editingShapeID, card)
        h.editor.endEditing()
        h.editor.place(try require(h.editor.registry.placement(for: Card.kind)), at: CGPoint(x: 300, y: 300))
        let placed = try require(h.newest)
        expectEqual(h.fitted(placed), "pen")
        expectEqual(h.editor.editingShapeID, placed)
    },
    test("an open kind may become another: a closed one keeps its kind, the answer of another kind passed over") {
        let pens = Pens()
        let h = try fitHarness(pens)
        let pen = h.add(Corral(penRect))
        pens.pens = [pen]
        pens.turning = true
        h.editor.place(h.discPlacement, at: CGPoint(x: 300, y: 200))
        let closed = try require(h.newest)
        expectEqual(h.editor.document[closed]?.kind, Disc.kind)
        expectEqual(h.fitted(closed), nil)
        expectEqual(pens.seen, [nil], "the next fit is handed the shape as it was")
        h.editor.place(h.discPlacement.openingKind(), at: CGPoint(x: 300, y: 300))
        let open = try require(h.newest)
        expectEqual(h.editor.document[open]?.kind, Box.kind)
        expectEqual(h.fitted(open), "turned")
        expectEqual(h.box(of: open), CGRect(x: 280, y: 280, width: 40, height: 40))
        expectEqual(h.editor.holder(of: open), pen, "in its place, under its id")
        expectEqual(pens.asks.map(\.kindIsOpen), [false, true])
        h.editor.undo()
        expectEqual(h.editor.document[open], nil, "one step")
    },
    test("an open kind stays open as a placement is mapped, sized and set; a placement starts closed") {
        let h = try fitHarness(Pens())
        let placement = h.discPlacement
        expect(!placement.kindIsOpen)
        let open = placement.openingKind()
        expect(open.kindIsOpen)
        expect(open.mapping { $0 }.kindIsOpen)
        expect(open.sized(CGSize(width: 80, height: 80)).kindIsOpen)
        expect(open.setting(Fitted.self, to: "set").kindIsOpen)
        expect(!placement.mapping { $0 }.sized(CGSize(width: 80, height: 80)).kindIsOpen)
    },
    test("a container put down around shapes is fitted where it goes, before it holds them") {
        let pens = Pens()
        let h = try fitHarness(pens)
        let pen = h.add(Corral(penRect))
        pens.pens = [pen]
        let a = h.add(Disc(CGRect(x: 150, y: 150, width: 40, height: 40))), b = h.add(Disc(CGRect(x: 250, y: 150, width: 40, height: 40)))
        h.editor.put([a, b], in: pen)
        let made = try require(h.editor.place(ShapeRecord(Corral()), around: [a, b], padding: 10))
        expectEqual(h.fitted(made), "around")
        expectEqual(pens.asks.map(\.kind), [Corral.kind])
        expectEqual(pens.asks.map(\.place), [.container(pen)])
        expectEqual([h.editor.holder(of: a), h.editor.holder(of: b)], [made, made])
    },
    test("a container placed over shapes is fitted before it takes them in, so they come into it as it will be: one it refuses stays out") {
        let h = try EditorHarness(plugins: [CorralsPlugin(), discTools(), CardsPlugin(), pickyFolds()])
        h.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        let d = h.add(Disc(CGRect(x: 200, y: 200, width: 50, height: 50))), card = h.add(Card(CGRect(x: 300, y: 200, width: 50, height: 50)))
        let placement = try require(h.editor.registry.placement(for: Fold.kind))
        h.editor.place(placement, in: CGRect(x: 100, y: 100, width: 400, height: 300))
        let fold = try require(h.editor.document.shapes.first { $0.kind == Fold.kind }?.id)
        expectEqual(h.fitted(fold), "picky")
        expectEqual(h.editor.holder(of: d), nil, "refused by the fold as fitted, left out where it is")
        expectEqual(h.box(of: d), CGRect(x: 200, y: 200, width: 50, height: 50))
        expectEqual(h.editor.holder(of: card), fold, "what it takes, it takes in")
        expectEqual(h.editor.undoHistory.undoName, "Add Fold")
        h.editor.undo()
        expectEqual(h.editor.document[fold], nil, "one step")
        // Put down around them instead, it's fitted first too, and refuses them whole.
        expectEqual(h.editor.place(ShapeRecord(Fold()), around: [d, card], padding: 10), nil)
    },
    test("an insert that isn't a placement, settled, is never fitted") {
        let pens = Pens()
        let h = try fitHarness(pens)
        let pen = h.add(Corral(penRect))
        pens.pens = [pen]
        let d = ShapeID()
        h.editor.transact("Paste") { transaction in
            transaction.insert(ShapeRecord(id: d, Disc(CGRect(x: 300, y: 200, width: 40, height: 40))))
            _ = transaction.settle([d])
        }
        expectEqual(h.editor.holder(of: d), pen)
        expectEqual(h.fitted(d), nil)
        expectEqual(pens.asks.count, 0)
    },
])

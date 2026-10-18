@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import TestKit

// A kind's rule keeps two values its shapes hold saying one thing (`keepsInStep`): asked of every
// shape a transaction puts in and of every write of one's added values, whoever writes, inside the
// transaction, so what it writes is in the same commit and step, held as the rest of the write is.

private let unit = CGRect(x: 0, y: 0, width: 100, height: 100)

/// What the rule was handed, a call each: whether it had the shape as it was, and its stars then.
@MainActor private final class Asks {
    var calls: [(hadBefore: Bool, stars: Int?)] = []
}

/// Boxes' sticker says their stars ("3 stars"), and a sticker written as "N stars" is their stars:
/// the two kept in step, whichever was written, as a type's color and its `$color` are.
@MainActor private func stepping(_ asks: Asks) -> Contributor {
    ratings { r in
        r.keepsInStep(Box.self) { before, record in
            asks.calls.append((before != nil, before?[Stars.self]))
            let stars = record[Stars.self] ?? 0, sticker = record[Sticker.self]
            if sticker != before?[Sticker.self], let sticker, let said = Int(sticker.split(separator: " ").first ?? "") {
                record[Stars.self] = said
            } else if stars != before?[Stars.self] {
                record[Sticker.self] = "\(stars) stars"
            }
            // What the kind doesn't hold is dropped.
            record[Ribbons.self] = [Ribbon()]
        }
    }
}

@MainActor private func box(_ h: EditorHarness, _ id: ShapeID) -> AnyShapeRecord? { h.editor.document[id] }

@MainActor let keepsInStepTests = Suite("Keeping in step", [
    test("a shape put in is asked with no shape before, and kept in step in its own commit") {
        let asks = Asks()
        let h = try EditorHarness(plugins: [FixturesPlugin(), stepping(asks)])
        let id = h.add(Box(unit))
        expectEqual(asks.calls.count, 1)
        expectEqual(asks.calls.first?.hadBefore, false)
        expectEqual(box(h, id)?[Sticker.self], "0 stars", "the default's stars")
        expectEqual(box(h, id)?[Ribbons.self], nil, "a value its kind doesn't hold is dropped")
    },
    test("a write of either value writes the other in the same commit and step; undo puts both back, asking nothing") {
        let asks = Asks()
        let h = try EditorHarness(plugins: [FixturesPlugin(), stepping(asks)])
        let id = h.add(Box(unit))
        let revision = h.editor.revision
        h.editor.transact("Rate") { $0.update(id) { $0[Stars.self] = 3 } }
        expectEqual(h.editor.revision, revision + 1, "one commit")
        expectEqual(box(h, id)?[Sticker.self], "3 stars")
        expectEqual(asks.calls.last?.hadBefore, true)
        expectEqual(asks.calls.last?.stars, 0, "handed the shape as it was")
        h.editor.transact("Sticker") { $0.update(id) { $0[Sticker.self] = "5 stars" } }
        expectEqual(box(h, id)?[Stars.self], 5)
        let asked = asks.calls.count
        h.editor.undo()
        expectEqual(box(h, id)?[Stars.self], 3)
        expectEqual(box(h, id)?[Sticker.self], "3 stars", "both back in one step")
        h.editor.undo()
        expectEqual(box(h, id)?[Stars.self], 0)
        expectEqual(box(h, id)?[Sticker.self], "0 stars")
        h.editor.redo()
        expectEqual(box(h, id)?[Sticker.self], "3 stars")
        expectEqual(asks.calls.count, asked, "undo and redo put a step back whole")
    },
    test("a move, a change of props alone, and another kind ask nothing") {
        let asks = Asks()
        let h = try EditorHarness(plugins: [FixturesPlugin(), stepping(asks)])
        let id = h.add(Box(unit)), disc = h.add(Disc(unit))
        let asked = asks.calls.count
        h.editor.transact { $0.translate([id], by: CGPoint(x: 10, y: 0)) }
        h.editor.transact { $0.update(id, as: Box.self) { $0.props.frame.size.width = 140 } }
        h.editor.transact { $0.update(disc, as: Disc.self) { $0.props.frame.size.width = 140 } }
        expectEqual(asks.calls.count, asked)
        expectEqual(asked, 1, "the box going in, and not the disc")
    },
    test("a read-only shape refuses the write whole, the rule's part with it") {
        let asks = Asks()
        let log = RefusalLog()
        let h = try EditorHarness(plugins: [FixturesPlugin(), stepping(asks), FreezingPlugin(log: log)])
        let id = h.add(Box(unit))
        h.editor.transact { $0.update(id) { $0[Frozen.self] = true } }
        h.editor.transact { $0.update(id) { $0[Stars.self] = 4 } }
        expectEqual(box(h, id)?[Stars.self], 0)
        expectEqual(box(h, id)?[Sticker.self], "0 stars")
        expectEqual(log.refusals, [[id]])
    },
    test("a write on another board is kept in step there, in the same step") {
        let asks = Asks()
        let pocket = ShapeID(), inside = ShapeID()
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: pocket, Pocket(unit)))]),
                              children: [pocket: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: inside, Box(unit)))])])
        let h = try EditorHarness(plugins: [FixturesPlugin(), PocketsPlugin(), stepping(asks)], file: file)
        h.editor.transact("Rate") { $0.update(inside, on: BoardID(owner: pocket)) { $0[Stars.self] = 2 } }
        expectEqual(h.file.record(inside)?[Sticker.self], "2 stars")
        h.editor.undo()
        expectEqual(h.file.record(inside)?[Stars.self], 0)
    },
    test("a shape turned into a kind with a rule is asked, with the shape as it was") {
        let asks = Asks()
        let h = try EditorHarness(plugins: [FixturesPlugin(), stepping(asks)])
        let id = h.add(Disc(unit))
        h.editor.transact { _ = $0.turn(id, into: Box(unit)) }
        expectEqual(asks.calls.count, 1)
        expectEqual(asks.calls.first?.hadBefore, true)
        expectEqual(box(h, id)?[Sticker.self], "0 stars")
    },
    test("the report says which kind keeps what in step") {
        let registry = try Registry(plugins: [FixturesPlugin(), stepping(Asks())])
        expect(registry.report.contains("keeps in step → box"), registry.report)
    },
])

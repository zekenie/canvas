@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import TestKit

// Work done whole or not at all (`editor.transactWhole`): what a grouping, a recolor across the file, a
// move, a turn, a paste and a relationship drawn go through. CanvasTesting's `Frozen` flag stands in for
// a lock, and a corral for a frame.

@MainActor private func wholeHarness(_ refusals: RefusalLog) throws -> EditorHarness {
    try EditorHarness(plugins: [FixturesPlugin(), CorralsPlugin(), FreezingPlugin(log: refusals)])
}

private func box(_ x: CGFloat) -> Box { Box(CGRect(x: x, y: 0, width: 40, height: 30)) }

@MainActor let wholeTests = Suite("Work whole", [
    test("with nothing refused it commits as transact does: one step, named, and the body's value") {
        let refusals = RefusalLog()
        let h = try wholeHarness(refusals)
        let a = h.add(box(0))
        let answer = h.editor.transactWhole("Nudge") { transaction -> Int in
            transaction.translate([a], by: CGPoint(x: 10, y: 0))
            return 7
        }
        expectEqual(answer, 7)
        expectEqual(h.editor.document[a]?.box?.minX, 10)
        expectEqual(h.editor.undoHistory.undoName, "Nudge")
        expectEqual(refusals.refusals, [])
    },
    test("a read-only shape it would change refuses the whole: nothing commits, no step opens, what there was to redo stays, and the refused shake once") {
        let refusals = RefusalLog()
        let h = try wholeHarness(refusals)
        let a = h.add(box(0)), b = h.add(box(100))
        h.editor.freeze([b])
        h.editor.transact("Move") { $0.translate([a], by: CGPoint(x: 1, y: 0)) }
        h.editor.undo()
        expect(h.editor.canRedo)
        let before = h.editor.document
        let result: Void? = h.editor.transactWhole("Both") { transaction in
            transaction.translate([a, b], by: CGPoint(x: 5, y: 5))
        }
        expect(result == nil, "nothing committed")
        expectEqual(h.editor.document, before, "a, which could move, didn't either")
        expect(h.editor.canRedo, "no step opened, so what there was to redo stays")
        expectEqual(refusals.refusals, [[b]])
    },
    test("a read-only container that a settle would put a shape in refuses the whole, and the container shakes") {
        let refusals = RefusalLog()
        let h = try wholeHarness(refusals)
        let pen = h.add(Corral(CGRect(x: 0, y: 0, width: 400, height: 300)))
        h.editor.freeze([pen])
        let record = AnyShapeRecord(ShapeRecord(id: ShapeID(), Box(CGRect(x: 100, y: 100, width: 40, height: 30))))
        let placed = h.editor.transactWhole("Add Box") { transaction in
            transaction.insert(record)
            return transaction.settle([record.id])
        }
        expect(placed == nil)
        expect(h.editor.document[record.id] == nil, "nothing put down")
        expectEqual(refusals.refusals, [[pen]])
    },
    test("a body gives up with Transaction.Refused: what it names shakes with what was refused, in one refusal; any other error commits nothing and shakes nothing, as transact hears no refusal of a body that throws") {
        let refusals = RefusalLog()
        let h = try wholeHarness(refusals)
        let a = h.add(box(0)), b = h.add(box(100))
        h.editor.freeze([b])
        let before = h.editor.document
        let given: Void? = h.editor.transactWhole("Give up") { transaction in
            transaction.translate([b], by: CGPoint(x: 5, y: 0))
            throw Transaction.Refused([a])
        }
        expect(given == nil)
        expectEqual(refusals.refusals, [[a, b]])
        struct Other: Error {}
        let other: Void? = h.editor.transactWhole("Fail") { transaction in
            transaction.translate([a, b], by: CGPoint(x: 5, y: 0))
            throw Other()
        }
        expect(other == nil)
        expectEqual(h.editor.document, before, "neither committed")
        expectEqual(refusals.refusals, [[a, b]], "b was refused on the way, but what stopped it was no refusal, so nothing shook")
        let asked: Void? = h.editor.transactWhole("Fail", shaking: [a]) { _ in throw Other() }
        expect(asked == nil)
        expectEqual(refusals.refusals, [[a, b], [a]], "given shaking, those shake whatever stopped it")
    },
    test("shaking says exactly what shakes on a refusal, whatever was refused: the shape asked of, or none") {
        let refusals = RefusalLog()
        let h = try wholeHarness(refusals)
        let a = h.add(box(0)), b = h.add(box(100))
        h.editor.freeze([b])
        h.editor.transactWhole("Asked", shaking: [a]) { $0.translate([b], by: CGPoint(x: 5, y: 0)) }
        expectEqual(refusals.refusals, [[a]])
        h.editor.transactWhole("Quiet", shaking: []) { $0.translate([b], by: CGPoint(x: 5, y: 0)) }
        expectEqual(refusals.refusals, [[a]], "none named, none shakes")
    },
    test("coalescing is transact's: two whole commits under one key are one step") {
        let h = try wholeHarness(RefusalLog())
        let a = h.add(box(0))
        h.editor.undoHistory.seal()
        for _ in 0..<2 { h.editor.transactWhole("Type", coalescing: "run") { $0.translate([a], by: CGPoint(x: 5, y: 0)) } }
        expectEqual(h.editor.document[a]?.box?.minX, 10)
        h.editor.undo()
        expectEqual(h.editor.document[a]?.box?.minX, 0, "one undo takes both back")
    },
])

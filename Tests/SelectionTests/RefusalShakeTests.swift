@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Keyboard
import Selection
import TestKit

// The shake a shape gives when something tries to change it and it can't be (`RefusalShake`),
// whoever's rule made it read-only: CanvasTesting's `Frozen` here, never Locking. It plays on every
// refusal services hear: 360 ms, a frame every 16 ms, side to side, 5 points at most, dying away.

@MainActor private func frozenHarness(_ more: [any CanvasPlugin] = []) throws -> EditorHarness {
    try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), FreezingPlugin()] + more)
}

@MainActor let refusalShakeTests = Suite("Shaking a shape that can't change", [
    test("dragging a read-only shape leaves it where it is, and shakes it, side to side, then puts it back where it's drawn") {
        let h = try frozenHarness()
        let box = h.add(Box(CGRect(x: 100, y: 100, width: 100, height: 100)))
        h.editor.freeze([box])
        h.press(at: CGPoint(x: 150, y: 150))
        h.drag(to: CGPoint(x: 200, y: 180))
        expectEqual(h.editor.document[box]?.box, CGRect(x: 100, y: 100, width: 100, height: 100))
        let shake = try require(h.editor.service(RefusalShake.self))
        expect(shake.isShaking)
        var offsets: [CGPoint] = []
        for _ in 0..<24 {
            h.wait(16)
            offsets.append(h.editor.drawingOffset(of: box))
        }
        expect(offsets.allSatisfy { $0.y == 0 }, "only side to side")
        expect(offsets.allSatisfy { abs($0.x) <= 5 }, "\(offsets)")
        expect(offsets.contains { $0.x > 2 } && offsets.contains { $0.x < -2 }, "both ways: \(offsets)")
        expect(abs(offsets[1].x) > abs(offsets[20].x) || offsets[20].x == 0, "dying away")
        expectEqual(offsets.last, .zero, "done by 384 ms")
        expect(!shake.isShaking)
        h.release()
    },
    test("the offset is the sine of three cycles over 360 ms, times what's left, and nothing at either end") {
        expectEqual(RefusalShake.offset(at: .zero), 0)
        expectEqual(RefusalShake.offset(at: .milliseconds(360)), 0)
        expectEqual(RefusalShake.offset(at: .milliseconds(400)), 0)
        // A twelfth of the way (30 ms): a quarter of a cycle, the peak of the first, at 11/12 of its strength.
        expect(abs(RefusalShake.offset(at: .milliseconds(30)) - 5 * 11 / 12) < 1e-9)
        expect(abs(RefusalShake.offset(at: .milliseconds(90)) + 5 * 9 / 12) < 1e-9, "and back the other way")
    },
    test("any refusal shakes, however it came: a service's own call to refuseChanges too; a click on the shape doesn't") {
        let h = try frozenHarness()
        let box = h.add(Box(CGRect(x: 100, y: 100, width: 100, height: 100)))
        h.editor.freeze([box])
        h.press(at: CGPoint(x: 150, y: 150))
        h.release()
        h.wait(32)
        expectEqual(h.editor.drawingOffset(of: box), .zero, "a click isn't a try to move it")
        h.editor.refuseChanges(to: [box])
        h.wait(16)
        expect(h.editor.drawingOffset(of: box) != .zero)
    },
    test("a shake under way isn't started over by another try; one after it is a new shake") {
        let h = try frozenHarness()
        let box = h.add(Box(CGRect(x: 100, y: 100, width: 100, height: 100)))
        h.editor.refuseChanges(to: [box])
        h.wait(160)
        h.editor.refuseChanges(to: [box])               // 160 ms in
        h.wait(224)                                     // 384 ms in: over, had it started over it'd be 224 ms into another
        expectEqual(h.editor.drawingOffset(of: box), .zero)
        h.editor.refuseChanges(to: [box])
        h.wait(16)
        expect(h.editor.drawingOffset(of: box) != .zero)
    },
    test("a container shakes with what it holds, at any depth; a shape that isn't there doesn't shake") {
        let h = try frozenHarness([CorralsPlugin()])
        let corral = h.add(Corral(CGRect(x: 100, y: 100, width: 400, height: 300)))
        let box = h.add(Box(CGRect(x: 150, y: 150, width: 100, height: 100)))
        let inner = h.add(Corral(CGRect(x: 300, y: 150, width: 150, height: 150)))
        let deep = h.add(Box(CGRect(x: 320, y: 170, width: 50, height: 50)))
        let loose = h.add(Box(CGRect(x: 600, y: 150, width: 100, height: 100)))
        h.editor.put([box, inner], in: corral)
        h.editor.put([deep], in: inner)
        h.editor.refuseChanges(to: [corral, ShapeID()])
        h.wait(16)
        for id in [corral, box, inner, deep] { expect(h.editor.drawingOffset(of: id) != .zero) }
        expectEqual(h.editor.drawingOffset(of: loose), .zero)
        expectEqual(h.editor.drawingOffset(of: deep), h.editor.drawingOffset(of: corral), "together")
    },
    test("a refusal naming the owner of a read-only board shakes it only where it's on the board shown: a move onto its board from the board its card is on shakes the card; a placement on the board shown, whose owner is on the board above, shakes nothing") {
        let outside = ShapeID(), pocket = ShapeID(), inside = ShapeID()
        var frozen = AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 500, y: 100, width: 100, height: 100))))
        frozen[Frozen.self] = true
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: outside, Box(CGRect(x: 100, y: 100, width: 100, height: 100)))), frozen]),
                              children: [pocket: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: inside, Box(CGRect(x: 100, y: 100, width: 100, height: 100))))])])
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), FreezingPlugin(), PocketsPlugin(), TilesPlugin()], file: file)
        let shake = try require(h.editor.service(RefusalShake.self))
        h.editor.transact("Move") { $0.move([outside], to: BoardID(owner: pocket)) }
        h.wait(16)
        expect(h.editor.drawingOffset(of: pocket) != .zero, "the card, on the board shown, shakes")
        expectEqual(h.editor.drawingOffset(of: outside), .zero, "the shape it tried to move doesn't: it isn't read-only")
        h.wait(500)
        expect(!shake.isShaking)
        expect(h.enter(pocket))
        h.editor.place(try require(h.editor.registry.placement(for: Tile.kind)), at: CGPoint(x: 400, y: 300))
        h.wait(16)
        expect(!shake.isShaking, "its owner is on the board above: nothing here to shake")
        expectEqual(h.editor.drawingOffset(of: inside), .zero)
    },
    test("showing another board stops a shake under way, and a deleted shape stops shaking") {
        let h = try frozenHarness([PocketsPlugin()])
        let box = h.add(Box(CGRect(x: 100, y: 100, width: 100, height: 100)))
        let gone = h.add(Box(CGRect(x: 300, y: 100, width: 100, height: 100)))
        let pocket = h.add(Pocket(CGRect(x: 500, y: 100, width: 100, height: 100)))
        let shake = try require(h.editor.service(RefusalShake.self))
        h.editor.refuseChanges(to: [box, gone])
        h.wait(32)
        h.editor.transact("Delete") { $0.delete([gone]) }
        h.wait(32)
        expect(shake.isShaking, "the other still shakes")
        expect(h.enter(pocket))
        expect(!shake.isShaking)
        h.wait(500)
        expect(h.editor.showBoard(.root))
        expectEqual(h.editor.drawingOffset(of: box), .zero, "not left shaken")
    },
])

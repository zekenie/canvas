@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import TestKit

@MainActor private func key(_ raw: String) throws -> StackingKey { try require(StackingKey(raw), "\(raw) is a key") }

/// A reproducible stream of choices for the property tests.
private struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

@MainActor let stackingKeyTests = Suite("Stacking keys", [
    test("open ends start at a0 and count in whole keys, up and down") {
        expectEqual(StackingKey.between(nil, nil).rawValue, "a0")
        expectEqual(StackingKey.between(try key("a0"), nil).rawValue, "a1")
        expectEqual(StackingKey.between(try key("az"), nil).rawValue, "b00")
        expectEqual(StackingKey.between(try key("Zz"), nil).rawValue, "a0")
        expectEqual(StackingKey.between(nil, try key("a0")).rawValue, "Zz")
        expectEqual(StackingKey.between(nil, try key("b00")).rawValue, "az")
        expectEqual(StackingKey.between(nil, try key("Z0")).rawValue, "Yzz")
        // A key with a fraction: its integer part is below it.
        expectEqual(StackingKey.between(nil, try key("a1V")).rawValue, "a1")
        expectEqual(StackingKey.between(try key("a1V"), nil).rawValue, "a2")
    },
    test("a key between two others is the shortest one strictly between them") {
        expectEqual(StackingKey.between(try key("a0"), try key("a1")).rawValue, "a0V")
        expectEqual(StackingKey.between(try key("a0"), try key("a0V")).rawValue, "a0G")
        expectEqual(StackingKey.between(try key("a0V"), try key("a1")).rawValue, "a0l")
        expectEqual(StackingKey.between(try key("a0"), try key("a2")).rawValue, "a1")
        expectEqual(StackingKey.between(try key("a1"), try key("a1001")).rawValue, "a1000V")
        expectEqual(StackingKey.between(try key("a0z"), try key("a1")).rawValue, "a0zV")
    },
    test("only well-formed keys are keys") {
        for good in ["a0", "Zz", "a0V", "b00", "b00V", "zzzzzzzzzzzzzzzzzzzzzzzzzzz", "A00000000000000000000000001"] {
            expect(StackingKey(good) != nil, good)
        }
        // Empty; an integer part too short; a fraction ending in 0; not base 62; the unusable smallest integer.
        for bad in ["", "a", "b0", "a00", "a0V0", "a0!", "-a0", "a0 ", "A00000000000000000000000000"] {
            expect(StackingKey(bad) == nil, bad)
        }
    },
    test("keys compare as bytes, digits before capitals before lower case") {
        expect(try key("Zz") < key("a0"))
        expect(try key("a0") < key("a0V"))
        expect(try key("a09") < key("a0A"))
        expect(try key("a0Z") < key("a0a"))
        expect(try key("az") < key("b00"))
    },
    test("keys made between random neighbors keep every shape in order, whichever generator makes them") {
        for generator in [StackingKeyGenerator.sequential, .jittered] {
            var random = SeededRandom(state: 42)
            var keys: [StackingKey] = []
            for _ in 0..<600 {
                let slot = Int.random(in: 0...keys.count, using: &random)
                let below = slot > 0 ? keys[slot - 1] : nil, above = slot < keys.count ? keys[slot] : nil
                let new = generator.key(between: below, and: above)
                expect(below.map { $0 < new } ?? true, "\(new) is above \(String(describing: below))")
                expect(above.map { new < $0 } ?? true, "\(new) is below \(String(describing: above))")
                expect(StackingKey(new.rawValue) != nil, "\(new) is well formed")
                keys.insert(new, at: slot)
            }
            expectEqual(keys, keys.sorted())
            expectEqual(Set(keys).count, keys.count)
        }
    },
    test("shapes brought to the front again and again keep short keys, jittered or not") {
        for generator in [StackingKeyGenerator.sequential, .jittered] {
            var top = generator.key(between: nil, and: nil)
            var bottom = top
            for _ in 0..<5000 {
                let next = generator.key(between: top, and: nil)
                expect(top < next)
                top = next
                let below = generator.key(between: nil, and: bottom)
                expect(below < bottom)
                bottom = below
            }
            expect(top.rawValue.count <= 10, "\(top) after 5000 bring-to-fronts")
            expect(bottom.rawValue.count <= 10, "\(bottom) after 5000 send-to-backs")
        }
    },
    test("jittered keys differ where plain ones collide") {
        let top = StackingKey.between(nil, nil)
        let keys = (0..<20).map { _ in StackingKeyGenerator.jittered.key(between: top, and: nil) }
        expect(Set(keys).count > 15, "\(keys)")
    },
    test("a document numbers shapes without rising keys in the order given, and keeps rising keys") {
        let ids = [ShapeID(), ShapeID(), ShapeID()]
        let document = CanvasDocument(shapes: ids.map { AnyShapeRecord(ShapeRecord(id: $0, Box(.zero))) })
        expectEqual(document.shapes.map(\.id), ids)
        expectEqual(document.shapes.map { $0.stackingKey?.rawValue }, ["a0", "a1", "a2"])
        let kept = CanvasDocument(shapes: [document.shapes[0], document.shapes[2]])
        expectEqual(kept.shapes.map { $0.stackingKey?.rawValue }, ["a0", "a2"])
        let reversed = CanvasDocument(shapes: document.shapes.reversed())
        expectEqual(reversed.shapes.map(\.id), ids.reversed())
        expectEqual(reversed.shapes.map { $0.stackingKey?.rawValue }, ["a0", "a1", "a2"])
    },
    test("inserting, bringing to front and sending to back set the shape's key, and only its own") {
        let h = try EditorHarness { CanvasEditor(registry: try Registry(plugins: [FixturesPlugin()]), scheduler: $0, stackingKeys: .sequential) }
        let a = h.add(Box(.zero)), b = h.add(Box(.zero)), c = h.add(Box(.zero))
        let key = { (id: ShapeID) in h.editor.document[id]?.stackingKey?.rawValue }
        expectEqual([key(a), key(b), key(c)], ["a0", "a1", "a2"])
        h.editor.transact { $0.bringToFront(a) }
        expectEqual([key(b), key(c), key(a)], ["a1", "a2", "a3"])
        h.editor.transact { $0.sendToBack(c) }
        expectEqual([key(c), key(b), key(a)], ["a0", "a1", "a3"])
        expectEqual(h.editor.document.shapes.map(\.id), [c, b, a])
    },
    test("moving a shape just above or below another gives it a key between its new neighbors") {
        let h = try EditorHarness { CanvasEditor(registry: try Registry(plugins: [FixturesPlugin()]), scheduler: $0, stackingKeys: .sequential) }
        let ids = (0..<4).map { _ in h.add(Box(.zero)) }
        h.editor.transact { $0.move(ids[0], above: ids[2]) }
        expectEqual(h.editor.document[ids[0]]?.stackingKey?.rawValue, "a2V")
        h.editor.transact { $0.move(ids[3], below: ids[1]) }
        expectEqual(h.editor.document[ids[3]]?.stackingKey?.rawValue, "a0")
        expectEqual(h.editor.document.shapes.map(\.id), [ids[3], ids[1], ids[2], ids[0]])
        let keys = h.editor.document.shapes.compactMap(\.stackingKey)
        expectEqual(keys, keys.sorted())
    },
    test("an update can't move a shape in the stack, even by putting back an old record") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        let a = h.add(Box(.zero)); h.add(Box(.zero))
        let before = try require(h.editor.document[a])
        h.editor.transact { $0.bringToFront(a) }
        let raised = try require(h.editor.document[a]?.stackingKey)
        let revision = h.editor.revision
        h.editor.transact { $0.update(a) { $0 = before } }
        expectEqual(h.editor.document[a]?.stackingKey, raised)
        expectEqual(h.editor.document.shapes.last?.id, a)
        expectEqual(h.editor.revision, revision, "putting back the same props changes nothing")
    },
    test("a frame that isn't finite never reaches the document") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 10, height: 10)))
        let revision = h.editor.revision
        h.editor.transact { $0.update(box, as: Box.self) { $0.frame.origin.x = .nan } }
        h.editor.transact { $0.update(box, as: Box.self) { $0.frame.size.width = .infinity } }
        expectEqual(h.editor.revision, revision)
        expectEqual(h.editor.document[box]?.box, CGRect(x: 0, y: 0, width: 10, height: 10))
        h.editor.transact { $0.insert(ShapeRecord(Box(CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1)))) }
        expectEqual(h.editor.document.shapes.count, 1)
        expectEqual(h.editor.revision, revision)
    },
])

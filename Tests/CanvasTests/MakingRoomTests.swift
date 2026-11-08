@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import TestKit

// Making room below a shape that grows (`Transaction.makeRoom()`, which `transact` runs as a step finishes), with
// CanvasTesting's piles standing in for tables: a pile is 20 world units a layer, and a shape below it that its new
// bottom comes nearer than 32 (`Style.roomReach`) moves down by as much as the pile grew, keeping its gap.

@MainActor private func roomHarness() throws -> EditorHarness {
    try EditorHarness(plugins: [FixturesPlugin(), CorralsPlugin(), PilesPlugin(), FreezingPlugin()])
}

extension EditorHarness {
    fileprivate func y(_ id: ShapeID) -> CGFloat? { editor.document[id]?.box?.minY }
    fileprivate func box(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat = 100, _ height: CGFloat = 50) -> ShapeID {
        add(Box(CGRect(x: x, y: y, width: width, height: height)))
    }
    fileprivate func pile(_ x: CGFloat, _ y: CGFloat, layers: Int, width: CGFloat = 100) -> ShapeID {
        add(Pile(CGRect(x: x, y: y, width: width, height: 20), layers: layers))
    }
    fileprivate var bytes: Data { (try? BoardCodec(registry: editor.registry).encode(editor.document)) ?? Data() }
}

@MainActor let makingRoomTests = Suite("Making room", [
    test("a pile that grows pushes what its new bottom reaches below it down by the growth, in the same step") {
        let h = try roomHarness()
        let pile = h.pile(0, 0, layers: 2)                  // y 0…40
        let near = h.box(0, 60)                             // a gap of 20
        let aside = h.box(300, 60)                          // not under it
        let far = h.box(0, 300)                             // beyond the reach of what's pushed
        h.editor.setLayers(3, of: pile)                     // bottom 60
        expectEqual(h.y(near), 80, "pushed by 20, the gap of 20 kept")
        expectEqual(h.y(aside), 60, "nothing sideways")
        expectEqual(h.y(far), 300)
        expectEqual(h.editor.undoHistory.undoName, "Add Layer", "one step, its name kept")
    },
    test("what the new bottom doesn't reach stays, and the gap closes") {
        let h = try roomHarness()
        let pile = h.pile(0, 0, layers: 2)                  // bottom 40
        let below = h.box(0, 100)                           // a gap of 60: 60 is not under 20 + 32
        h.editor.setLayers(3, of: pile)
        expectEqual(h.y(below), 100)
        h.editor.setLayers(4, of: pile)                     // a gap of 40 now: under 20 + 32
        expectEqual(h.y(below), 120, "the gap of 40 it had kept")
    },
    test("each shape pushed pushes what it now reaches, so a column moves down together") {
        let h = try roomHarness()
        let pile = h.pile(0, 0, layers: 2)                  // bottom 40
        let first = h.box(0, 50), second = h.box(20, 110), third = h.box(40, 170, 200)
        let wide = h.box(-200, 400, 600)                    // 180 under the third: not reached
        h.editor.setLayers(5, of: pile)                     // +60
        expectEqual([h.y(first), h.y(second), h.y(third), h.y(wide)], [110, 170, 230, 400])
        h.editor.undo()
        expectEqual([h.y(first), h.y(second), h.y(third)], [50, 110, 170], "one Undo takes the growth and the moves")
    },
    test("one Undo is exact, and Redo puts the moves back, in the board's bytes") {
        let h = try roomHarness()
        let pile = h.pile(0, 0, layers: 2)
        _ = h.box(0, 50)
        _ = h.box(0, 110)
        let before = h.bytes
        h.editor.setLayers(4, of: pile)
        let after = h.bytes
        expect(before != after)
        h.editor.undo()
        expectEqual(h.bytes, before)
        h.editor.redo()
        expectEqual(h.bytes, after)
    },
    test("a shape two growths reach moves by the larger, once") {
        let h = try roomHarness()
        let left = h.pile(0, 0, layers: 2), right = h.pile(200, 0, layers: 2)
        let under = h.box(0, 50, 300)
        h.editor.transact("Add Layer") { transaction in
            transaction.update(left, as: Pile.self) { $0.props.layers = 3 }       // +20
            transaction.update(right, as: Pile.self) { $0.props.layers = 5 }      // +60
        }
        expectEqual(h.y(under), 110)
    },
    test("shrinking pulls nothing up") {
        let h = try roomHarness()
        let pile = h.pile(0, 0, layers: 4)                  // bottom 80
        let below = h.box(0, 90)
        h.editor.setLayers(2, of: pile)
        expectEqual(h.y(below), 90, "nothing pulled up")
        h.editor.setLayers(4, of: pile)                     // +40: the gap of 50 it has now is under 40 + 32
        expectEqual(h.y(below), 130, "growing back pushes from the gap it has now")
    },
    test("a shape laid out taller by a value set for it is measured without it") {
        let h = try roomHarness()
        let pile = h.pile(0, 0, layers: 2)                  // bottom 40 at rest
        let below = h.box(0, 50)
        let steps = h.editor.undoHistory.undoName
        h.editor.setLayoutInput(Piles.waiting, true, for: pile)   // drawn a layer taller: no step, no write
        expectEqual(h.y(below), 50)
        expectEqual(h.editor.undoHistory.undoName, steps)
        h.editor.setLayers(3, of: pile)                     // at rest 40 → 60, drawn 60 → 80
        expectEqual(h.y(below), 70, "by the layer written, not the one shown")
    },
    test("in a container, what's pushed stays in it, and the container grows to hold it, pushing in its own container") {
        let h = try roomHarness()
        let pen = h.add(Corral(CGRect(x: 0, y: 0, width: 300, height: 300)))
        let pile = h.pile(16, 16, layers: 2)                // bottom 56
        let inner = h.add(Corral(CGRect(x: 16, y: 70, width: 200, height: 200)))   // bottom 270, 30 inside
        let held = h.box(30, 100)
        h.editor.put([pile, inner], in: pen)
        h.editor.put([held], in: inner)
        let next = h.box(0, 320)                            // 20 under the pen
        let beside = h.box(230, 100, 50, 20)
        h.editor.put([beside], in: pen)
        h.editor.setLayers(5, of: pile)                     // +60
        expectEqual(h.y(inner), 130, "pushed in the pen")
        expectEqual(h.y(held), 160, "what it holds goes with it")
        expectEqual(h.editor.holder(of: inner), pen)
        expectEqual(h.editor.document[pen]?.box?.height, 346, "grown to hold it the gap inside: 330 + 16")
        expectEqual(h.y(next), 366, "pushed by the pen's growth of 46")
        expectEqual(h.y(beside), 100, "not under it")
        h.editor.undo()
        expectEqual([h.y(inner), h.y(held), h.y(next)], [70, 100, 320])
        expectEqual(h.editor.document[pen]?.box?.height, 300)
    },
    test("only the shapes at its level: one on the board under a container isn't pushed by what grows in it") {
        let h = try roomHarness()
        let pen = h.add(Corral(CGRect(x: 0, y: 0, width: 300, height: 300)))
        let pile = h.pile(16, 16, layers: 2)                // bottom 56, far inside
        h.editor.put([pile], in: pen)
        let outside = h.box(0, 60)                           // on the board, across the pen's middle: another level
        h.editor.setLayers(3, of: pile)
        expectEqual(h.y(outside), 60)
        expectEqual(h.editor.document[pen]?.box?.height, 300, "nothing taken past its bottom")
    },
    test("a read-only shape never moves, and stops the push in its column") {
        let h = try roomHarness()
        let pile = h.pile(0, 0, layers: 2)                  // bottom 40
        let frozen = h.box(0, 50)
        let under = h.box(0, 120, 50)                       // 20 under the frozen one, 80 under the pile
        let open = h.box(90, 50)                            // under the pile too, beside the frozen one
        h.editor.freeze([frozen])
        h.editor.setLayers(4, of: pile)                     // +40
        expectEqual(h.y(frozen), 50, "left overlapping, for the person")
        expectEqual(h.y(under), 120)
        expectEqual(h.y(open), 90)
    },
    test("a shape the step put in or moved stays where the step put it") {
        let h = try roomHarness()
        let pile = h.pile(0, 0, layers: 2)
        let moved = h.box(400, 0)
        var added: ShapeID?
        h.editor.transact("Add Layer") { transaction in
            transaction.update(pile, as: Pile.self) { $0.props.layers = 4 }
            transaction.update(moved) { $0.box?.origin = CGPoint(x: 0, y: 50) }
            let id = ShapeID()
            transaction.insert(ShapeRecord(id: id, Box(CGRect(x: 0, y: 120, width: 100, height: 50))))
            added = id
        }
        expectEqual(h.y(moved), 50)
        expectEqual(added.flatMap { h.y($0) }, 120)
    },
    test("asked again in the same step, it makes room once; madeRoom says what it moved") {
        let h = try roomHarness()
        let pile = h.pile(0, 0, layers: 2)
        let below = h.box(0, 50)
        var first: [ShapeID: CGPoint] = [:], second: [ShapeID: CGPoint] = [:], made: [ShapeID: CGPoint] = [:]
        h.editor.transact("Add Layer") { transaction in
            transaction.update(pile, as: Pile.self) { $0.props.layers = 3 }
            first = transaction.makeRoom()
            second = transaction.makeRoom()
            made = transaction.madeRoom
        }
        expectEqual(first, [below: CGPoint(x: 0, y: 20)])
        expectEqual(second, [:])
        expectEqual(made, [below: CGPoint(x: 0, y: 20)])
        expectEqual(h.y(below), 70, "and the step's own run found nothing more")
    },
    test("past the most moves a step makes, the rest stay") {
        let h = try roomHarness()
        let pile = h.pile(0, 0, layers: 2)                  // bottom 40
        var column: [ShapeID] = []
        for index in 0..<210 { column.append(h.box(0, 50 + CGFloat(index) * 30, 100, 20)) }   // gaps of 10
        h.editor.setLayers(3, of: pile)
        let pushed = column.filter { h.y($0) != 50 + CGFloat(column.firstIndex(of: $0)!) * 30 }
        expectEqual(pushed.count, 200)
        expectEqual(pushed, Array(column.prefix(200)), "from the top")
    },
    test("a kind that doesn't make room grows over what's below, as before") {
        let h = try roomHarness()
        let box = h.box(0, 0)
        let below = h.box(0, 60)
        h.editor.transact { $0.update(box) { $0.box?.size.height = 100 } }
        expectEqual(h.y(below), 60)
    },
])

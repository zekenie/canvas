import Canvas
import CanvasTesting
import CoreGraphics
import TestKit
import Transform

// All or nothing: a read-only shape (frozen, or in a frozen corral), among those turned or among what
// the turn would move, keeps every turn from happening, with no step; services hear the read-only shapes
// refused, and a target that throws commits nothing either.

private struct Declined: Error {}

/// A step named Freeze, so that what's undone next tells whether a turn made a step.
@MainActor private func freeze(_ h: EditorHarness, _ ids: [ShapeID], _ frozen: Bool = true) {
    h.editor.undoHistory.group("Freeze") { h.editor.freeze(ids, frozen) }
}

@MainActor let transformRefusalTests = Suite("Turning with read-only shapes", [
    test("a frozen shape the corral holds keeps the turn from happening: nothing changes, no step is made, and the frozen shape is heard refused; unfrozen, it turns") {
        let k = ShapeID(), a = ShapeID(), b = ShapeID(), c = ShapeID(), log = RefusalLog()
        let file = CanvasFile(root: board(corral(k, CGRect(x: 0, y: 0, width: 300, height: 200)), box(a, x: 20, y: 20, in: k), box(b, x: 120, y: 20, in: k),
                                          box(c, x: 600)))
        let outside = try transformHarness(file: file)
        outside.editor.freeze([c])
        expect(outside.editor.transforms?.turn([k], into: Pocket.kind) == true, "a frozen shape outside the corral is in no one's way")

        let h = try transformHarness(file: file, log: log)
        let transforms = try require(h.editor.transforms)
        freeze(h, [b])
        let before = h.file, revision = h.editor.revision
        expect(!transforms.turn([k], into: Pocket.kind))
        expectEqual(h.file, before, "the corral is a corral, and still holds both")
        expectEqual(h.editor.revision, revision, "nothing committed")
        expectEqual(h.editor.undoHistory.undoName, "Freeze", "no step of its own")
        expectEqual(log.refusals, [[b]], "the shape in the way, not the corral")
        freeze(h, [b], false)
        expect(transforms.turn([k], into: Pocket.kind))
        expectEqual(ids(h.contents(of: k)), [a, b])
    },

    test("a frozen corral isn't turned: its menu has the item, and choosing it changes nothing and shakes the corral") {
        let k = ShapeID(), a = ShapeID(), log = RefusalLog()
        let h = try transformHarness(file: CanvasFile(root: board(corral(k, CGRect(x: 0, y: 0, width: 300, height: 200)), box(a, x: 20, y: 20, in: k))), log: log)
        freeze(h, [k])
        let before = h.file, revision = h.editor.revision
        let menu = try require(h.secondaryClick(at: CGPoint(x: 250, y: 150)))
        expectEqual(menu.outline, ["Turn into Pocket", "—", "Delete"])
        try menu.choose("Turn into Pocket")
        expectEqual(h.file, before)
        expectEqual(h.editor.revision, revision)
        expectEqual(h.editor.undoHistory.undoName, "Freeze")
        expectEqual(log.refusals, [[k]])
    },

    test("a corral in a frozen corral is read-only with it: nothing turns, and it's the corral tried that's refused") {
        let f = ShapeID(), k = ShapeID(), a = ShapeID(), log = RefusalLog()
        let h = try transformHarness(file: CanvasFile(root: board(corral(f, CGRect(x: 0, y: 0, width: 600, height: 400)),
                                                                  corral(k, CGRect(x: 50, y: 50, width: 300, height: 200), in: f), box(a, x: 70, y: 70, in: k))), log: log)
        freeze(h, [f])
        let before = h.file, revision = h.editor.revision
        expect(!h.editor.transforms!.turn([k], into: Pocket.kind))
        expectEqual(h.file, before)
        expectEqual(h.editor.revision, revision)
        expectEqual(log.refusals, [[k]])
    },

    test("one frozen shape among several keeps all of them as they are: the others aren't turned, and only the frozen one is refused") {
        let k = ShapeID(), l = ShapeID(), a = ShapeID(), log = RefusalLog()
        let h = try transformHarness(file: CanvasFile(root: board(corral(k, CGRect(x: 0, y: 0, width: 300, height: 200)), box(a, x: 20, y: 20, in: k),
                                                                  corral(l, CGRect(x: 400, y: 0, width: 300, height: 200)))), log: log)
        let transforms = try require(h.editor.transforms)
        freeze(h, [l])
        let before = h.file, revision = h.editor.revision
        expect(!transforms.turn([k, l], into: Pocket.kind))
        expectEqual(h.file, before, "the corral that could turn didn't")
        expectEqual(h.editor.revision, revision)
        expectEqual(log.refusals, [[l]])
        expect(transforms.turn([k], into: Pocket.kind), "alone it does")
    },

    test("a frozen shape deep in nested corrals, among what the inner and outer one hold, keeps both from turning, though the inner went first") {
        let o = ShapeID(), i = ShapeID(), b = ShapeID(), c = ShapeID(), log = RefusalLog()
        let h = try transformHarness(file: CanvasFile(root: board(corral(o, CGRect(x: 0, y: 0, width: 600, height: 400)),
                                                                  corral(i, CGRect(x: 100, y: 100, width: 300, height: 200), in: o), box(b, x: 120, y: 120, in: i),
                                                                  box(c, x: 200, y: 120, in: i))), log: log)
        freeze(h, [b])
        let before = h.file, revision = h.editor.revision
        expect(!h.editor.transforms!.turn([o, i], into: Pocket.kind))
        expectEqual(h.file, before, "the inner corral, which turned first in the transaction, is a corral")
        expectEqual(h.editor.revision, revision)
        expectEqual(h.editor.undoHistory.undoName, "Freeze")
        expectEqual(log.refusals, [[b]])
        expectEqual(h.editor.holder(of: c), i)
    },

    test("a turned shape that would land in a frozen container isn't: a corral lying over a frozen one is refused with it") {
        let f = ShapeID(), k = ShapeID(), log = RefusalLog()
        // Not in it, though over it: nothing put it there by the in-or-out rule, which turning puts it through.
        let h = try transformHarness(file: CanvasFile(root: board(corral(f, CGRect(x: 0, y: 0, width: 400, height: 300)),
                                                                  corral(k, CGRect(x: 10, y: 10, width: 50, height: 40)))), log: log)
        freeze(h, [f])
        let before = h.file, revision = h.editor.revision
        expect(!h.editor.transforms!.turn([k], into: Pocket.kind), "a pocket's size over the frozen corral would be in it")
        expectEqual(h.file, before)
        expectEqual(h.editor.revision, revision)
        expectEqual(log.refusals, [[f]], "the frozen corral that would have taken it")
        freeze(h, [f], false)
        expect(h.editor.transforms!.turn([k], into: Pocket.kind))
        expectEqual(h.editor.holder(of: k), f, "and thawed, it's taken in")
    },

    test("a read-only shape is refused before its target is asked, whatever the target would do: one that never touches the shape isn't run") {
        let k = ShapeID(), calls = CallLog(), log = RefusalLog()
        let h = try transformHarness([plugin("logging") { r in
            r.turnable(Corral.self, through: LooseChannel.self)
            r.turnable(into: Tag.self, through: LooseChannel.self) { id, transaction in
                calls.ids.append(id)
                transaction.insert(AnyShapeRecord(ShapeRecord(Tag(target: nil))))
            }
        }], file: CanvasFile(root: board(corral(k, CGRect(x: 0, y: 0, width: 300, height: 200)))), log: log)
        freeze(h, [k])
        let before = h.file, revision = h.editor.revision
        expect(!h.editor.transforms!.turn([k], into: Tag.kind))
        expectEqual(calls.ids, [], "the target never ran")
        expectEqual(h.file, before, "so what it would have put on the board isn't there")
        expectEqual(h.editor.revision, revision)
        expectEqual(log.refusals, [[k]])
        freeze(h, [k], false)
        expect(h.editor.transforms!.turn([k], into: Tag.kind))
        expectEqual(calls.ids, [k])
    },

    test("once one is refused no other target runs, the turn being thrown away; every read-only one among them is still heard") {
        let k1 = ShapeID(), k2 = ShapeID(), k3 = ShapeID(), calls = CallLog(), log = RefusalLog()
        let h = try transformHarness([plugin("logging") { r in
            r.turnable(Corral.self, through: LooseChannel.self)
            r.turnable(into: Tag.self, through: LooseChannel.self) { id, transaction in
                calls.ids.append(id)
                transaction.insert(AnyShapeRecord(ShapeRecord(Tag(target: nil))))
            }
        }], file: CanvasFile(root: board(corral(k1, CGRect(x: 0, y: 0, width: 100, height: 80)),
                                         corral(k2, CGRect(x: 200, y: 0, width: 100, height: 80)),
                                         corral(k3, CGRect(x: 400, y: 0, width: 100, height: 80)))), log: log)
        freeze(h, [k1, k3])
        let before = h.file
        expect(!h.editor.transforms!.turn([k1, k2, k3], into: Tag.kind))
        expectEqual(calls.ids, [], "the first is refused, so the second's target isn't asked")
        expectEqual(h.file, before)
        expectEqual(log.refusals, [[k1, k3]], "both frozen ones shake")
    },

    test("a target that throws turns nothing: no change, no step, no refusal") {
        let log = RefusalLog()
        let h = try transformHarness([plugin("declining") { r in
            r.turnable(Box.self, through: BoxChannel.self)
            r.turnable(into: Disc.self, through: BoxChannel.self) { id, transaction in
                transaction.turn(id, into: Disc(CGRect(x: 0, y: 0, width: 5, height: 5)))
                throw Declined()
            }
        }], log: log)
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 40, height: 40))), b = h.add(Box(CGRect(x: 100, y: 0, width: 40, height: 40)))
        let before = h.file, revision = h.editor.revision
        expect(!h.editor.transforms!.turn([a, b], into: Disc.kind), "it changed the shape, then threw")
        expectEqual(h.file, before)
        expectEqual(h.editor.revision, revision)
        expectEqual(h.editor.undoHistory.undoName, nil, "no step named for the turn")
        expectEqual(log.refusals, [])
        expectEqual(h.editor.document[a]?.kind, Box.kind)
    },
])

@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Selection
import TestKit
import Transform

// Offers that come from the file, not the registry: what a provider returns when the menu opens, how
// one or several render, and choosing one, which turns as a target does (one step, all or nothing).

private struct Declined: Error {}

/// A provider for boxes alone: an offer for each label, which turns a box into a disc on its own frame.
/// `log` hears each shape it turns, in order.
@MainActor private func offering(_ labels: [String], log: CallLog = CallLog(), asked: Counter = Counter(),
                                 id: PluginID = "offering") -> Contributor {
    plugin(id) { r in
        r.turnOffers { shapes, _ in
            asked.count += 1
            guard shapes.allSatisfy({ $0.kind == Box.kind }) else { return [] }
            return labels.map { label in
                TurnOffer(id: label.lowercased(), label: label) { shape, transaction in
                    log.ids.append(shape)
                    guard let frame = transaction.document[shape]?.box else { return }
                    transaction.turn(shape, into: Disc(frame))
                }
            }
        }
    }
}

@MainActor private final class Counter {
    var count = 0
}


@MainActor let transformOfferTests = Suite("Turn offers from the file", [
    test("one offer is an item, Turn into <label>, beside the kind's own targets, flat, in plugin order; choosing it turns the shape under its id in one step named for it") {
        let log = CallLog()
        let h = try transformHarness([boxesTurnIntoDiscs(), offering(["Ring"], log: log)])
        let a = h.add(Box(boxSlot))
        let before = h.file
        let menu = try require(h.secondaryClick(at: boxPoint))
        expectEqual(menu.outline, ["Turn into Ring", "Turn into Disc", "—", "Delete"])
        try menu.choose("Turn into Ring")
        expectEqual(h.file.record(a)?.kind, Disc.kind, "under its own id")
        expectEqual(h.file.record(a)?.box, boxSlot)
        expectEqual(log.ids, [a])
        expectEqual(h.editor.undoHistory.undoName, "Turn into Ring")
        let after = h.file
        h.editor.undo()
        try expectFile(h, before, "the box")
        h.editor.redo()
        try expectFile(h, after, "the disc")
    },

    test("several offers are a Turn into submenu, in the order given and across providers, the first of an id staying; a kind's own targets stay flat beside it") {
        let h = try transformHarness([boxesTurnIntoDiscs(), offering(["Ring", "Dot"], id: "first"), offering(["Dot", "Bead"], id: "second")])
        h.add(Box(boxSlot))
        let menu = try require(h.secondaryClick(at: boxPoint))
        expectEqual(menu.outline, ["Turn into ▸", "  Ring", "  Dot", "  Bead", "Turn into Disc", "—", "Delete"])
        try menu.choose("Turn into", "Bead")
        expectEqual(h.editor.undoHistory.undoName, "Turn into Bead")
    },

    test("the providers are asked once per menu, with the menu's shapes in order, and nothing shows unless they offer for every one: a box and a corral get none from boxes' provider") {
        let asked = Counter()
        let h = try transformHarness([offering(["Ring"], asked: asked)])
        let a = h.add(Box(boxSlot))
        let k = h.add(Corral(CGRect(x: 300, y: 0, width: 150, height: 100)))
        _ = try require(h.secondaryClick(at: boxPoint))
        expectEqual(asked.count, 1)
        h.editor.selectedShapeIDs = [a, k]
        expectEqual(try require(h.secondaryClick(at: boxPoint)).outline, ["Delete"])
        expectEqual(asked.count, 2)
        expectEqual(try require(h.secondaryClick(at: CGPoint(x: 350, y: 50))).outline, ["Delete"], "a corral alone")
        let second = h.add(Box(CGRect(x: 600, y: 0, width: 100, height: 80)))
        h.editor.selectedShapeIDs = [a, second]
        expectEqual(try require(h.secondaryClick(at: boxPoint)).outline, ["Turn into Ring", "—", "Delete"], "two boxes")
    },

    test("offers(for:) is empty for no shape, a shape off the board shown or one kept aside, even when a provider would offer for the rest") {
        let h = try transformHarness([offering(["Ring"])])
        let transforms = try require(h.editor.transforms)
        let a = h.add(Box(boxSlot))
        expectEqual(transforms.offers(for: [a]).map(\.id), ["ring"])
        expectEqual(transforms.offers(for: []).map(\.id), [])
        expectEqual(transforms.offers(for: [a, ShapeID()]).map(\.id), [], "a shape that isn't there")
        let aside = try keptAside(Box.kind, id: ShapeID(), in: h.editor.registry)
        h.editor.replaceDocument(with: CanvasDocument(shapes: h.editor.document.shapes + [aside]))
        expectEqual(transforms.offers(for: [a, aside.id]).map(\.id), [], "a shape kept aside")
        expect(!transforms.turn([aside.id], by: TurnOffer(id: "x", label: "X") { _, _ in }), "and none is turned")
    },

    test("several shapes turn together, the deepest first, in one step; the order given changes nothing") {
        let k = ShapeID(), a = ShapeID(), b = ShapeID()
        let file = CanvasFile(root: board(corral(k, CGRect(x: 0, y: 0, width: 400, height: 300)), box(a, x: 20, y: 20, in: k), box(b, x: 600)))
        let anything = plugin("anything") { r in
            r.turnOffers { _, _ in
                [TurnOffer(id: "ring", label: "Ring") { id, transaction in
                    guard let frame = transaction.document[id]?.box else { return }
                    transaction.turn(id, into: Disc(frame))
                }]
            }
        }
        for order in [[k, a, b], [b, a, k]] {
            let h = try transformHarness([anything], file: file)
            let transforms = try require(h.editor.transforms)
            let offer = try require(transforms.offers(for: order).first)
            expect(transforms.turn(order, by: offer))
            expectEqual(h.editor.document.shapes.map(\.kind), [Disc.kind, Disc.kind, Disc.kind], "\(order)")
            expectEqual(h.editor.undoHistory.undoName, "Turn into Ring")
            h.editor.undo()
            try expectFile(h, file, "one step undoes all three")
        }
        let log = CallLog()
        let watching = plugin("watching") { r in
            r.turnOffers { _, _ in [TurnOffer(id: "ring", label: "Ring") { id, _ in log.ids.append(id) }] }
        }
        let h = try transformHarness([watching], file: file)
        let transforms = try require(h.editor.transforms)
        transforms.turn([b, k, a], by: try require(transforms.offers(for: [k]).first))
        expectEqual(log.ids.first, a, "the box in the corral, before the corral")
        expectEqual(Set(log.ids), [k, a, b])
    },

    test("a frozen shape among them refuses all: nothing changes, no step is made, and it's heard refused; an offer that throws turns nothing either") {
        let log = RefusalLog()
        let h = try transformHarness([offering(["Ring"])], log: log)
        let a = h.add(Box(boxSlot))
        let b = h.add(Box(CGRect(x: 300, y: 0, width: 100, height: 80)))
        h.editor.undoHistory.group("Freeze") { h.editor.freeze([b]) }
        let before = h.file, revision = h.editor.revision
        let transforms = try require(h.editor.transforms)
        let offer = try require(transforms.offers(for: [a, b]).first)
        expect(!transforms.turn([a, b], by: offer))
        expectEqual(h.file, before)
        expectEqual(h.editor.revision, revision)
        expectEqual(h.editor.undoHistory.undoName, "Freeze")
        expectEqual(log.refusals, [[b]])
        let menu = try require(h.secondaryClick(at: CGPoint(x: 350, y: 40)))
        try menu.choose("Turn into Ring")
        expectEqual(h.file, before, "the same from the menu")
        expectEqual(log.refusals, [[b], [b]])

        let throwing = try transformHarness([plugin("throwing") { r in
            r.turnOffers { _, _ in
                [TurnOffer(id: "bad", label: "Bad") { id, transaction in
                    transaction.update(id) { $0.box = CGRect(x: 5, y: 5, width: 5, height: 5) }
                    throw Declined()
                }]
            }
        }])
        let c = throwing.add(Box(boxSlot))
        let kept = throwing.file, count = throwing.editor.revision
        let thrower = try require(throwing.editor.transforms?.offers(for: [c]).first)
        expect(throwing.editor.transforms?.turn([c], by: thrower) == false)
        expectEqual(throwing.file, kept, "the box as it was")
        expectEqual(throwing.editor.revision, count)
    },

    test("the report says what a provider is: turn offers → every shape; Transform's own line gains its item for the canvas") {
        let r = try Registry(plugins: transformPlugins([offering(["Ring"])]))
        let lines = r.report.split(separator: "\n").map(String.init)
        expect(try require(lines.first { $0.hasPrefix("offering") }).hasSuffix("turn offers → every shape"))
        expect(try require(lines.first { $0.hasPrefix("transform") }).hasSuffix("service TransformState · CanvasContextMenu"))
        expectThrows(RegistryError.ownerNotInstalled(point: "TransformOffers", owner: .transform, contributor: "offering")) {
            _ = try Registry(plugins: [offering(["Ring"])])
        }
    },
])

import Canvas
import CanvasTesting
import CoreGraphics
import TestKit
import Transform

// A rule that refuses a turn before it happens, whatever the turn is into: nothing changes, no step is
// made, the refused shapes are heard refused, and the rule's action runs.

/// A box the tests' box channel hands over (it is narrow), at the origin; `boxPoint` is on it.
private let narrow = CGRect(x: 0, y: 0, width: 80, height: 80)

/// What a veto was asked and did.
@MainActor private final class VetoLog {
    var asked: [TurnRequest] = []
    var actions: [String] = []
}

/// Refuses to turn the shapes `refuses` picks, and says so in `log`, naming itself in its action's note.
@MainActor private func vetoing(_ id: PluginID = "veto", log: VetoLog, refuses: @escaping @MainActor (ShapeID, CanvasEditor) -> Bool) -> Contributor {
    plugin(id) { r in
        r.vetoTurns { request, editor in
            log.asked.append(request)
            let held = Set(request.shapes.filter { refuses($0, editor) })
            return held.isEmpty ? nil : TurnVeto(shapes: held) { log.actions.append("\(id.rawValue): \(held.count)") }
        }
    }
}

/// Boxes offer "Ring", which turns them into discs.
@MainActor private func ringOffer() -> Contributor {
    plugin("ring") { r in
        r.turnOffers { shapes, _ in
            [TurnOffer(id: "ring", label: "Ring") { id, transaction in
                guard let frame = transaction.document[id]?.box else { return }
                transaction.turn(id, into: Disc(frame))
            }]
        }
    }
}

@MainActor let transformVetoTests = Suite("Vetoing turns", [
    test("a veto refuses a target of the registry: nothing turns, no step is made, the shape is heard refused and the action runs; a veto that lets it pass changes nothing") {
        let vetoes = VetoLog(), refusals = RefusalLog()
        let h = try transformHarness([boxesTurnIntoDiscs(), vetoing(log: vetoes) { _, _ in true }], log: refusals)
        let a = h.add(Box(narrow))
        let before = h.file, revision = h.editor.revision, undo = h.editor.undoHistory.undoName
        let transforms = try require(h.editor.transforms)
        expect(!transforms.turn([a], into: Disc.kind))
        expectEqual(h.file, before)
        expectEqual(h.editor.revision, revision)
        expectEqual(h.editor.undoHistory.undoName, undo, "no step")
        expectEqual(refusals.refusals, [[a]])
        expectEqual(vetoes.actions, ["veto: 1"])
        let asked = try require(vetoes.asked.first)
        expectEqual(asked.shapes, [a])
        expectEqual(asked.label, "Disc")
        expectEqual(asked.kind, Disc.kind)
        expectEqual(asked.offer, nil)

        let allowed = VetoLog()
        let open = try transformHarness([boxesTurnIntoDiscs(), vetoing(log: allowed) { _, _ in false }])
        let b = open.add(Box(narrow))
        expect(open.editor.transforms?.turn([b], into: Disc.kind) == true)
        expectEqual(allowed.actions, [])
        expectEqual(open.file.record(b)?.kind, Disc.kind)
    },

    test("the same from the menu and the slash command, and for an offer from the file, which the veto sees as one") {
        let vetoes = VetoLog(), refusals = RefusalLog()
        let h = try transformHarness([boxesTurnIntoDiscs(), ringOffer(), vetoing(log: vetoes) { _, _ in true }], log: refusals)
        let a = h.add(Box(narrow))
        let before = h.file
        let menu = try require(h.secondaryClick(at: boxPoint))
        try menu.choose("Turn into Disc")
        try menu.choose("Turn into Ring")
        expectEqual(h.file, before)
        expectEqual(refusals.refusals, [[a], [a]])
        expectEqual(vetoes.actions.count, 2)
        let offered = try require(vetoes.asked.last)
        expectEqual(offered.label, "Ring")
        expectEqual(offered.kind, nil)
        expectEqual(offered.offer, "ring")
    },

    test("it is asked about the shapes that would turn, not the rest; with none, it isn't asked; a read-only shape is vetoed before it is refused") {
        let vetoes = VetoLog(), refusals = RefusalLog()
        let h = try transformHarness([boxesTurnIntoDiscs(), vetoing(log: vetoes) { _, _ in false }], log: refusals)
        let a = h.add(Box(narrow))
        let k = h.add(Corral(CGRect(x: 300, y: 0, width: 150, height: 100)))
        let transforms = try require(h.editor.transforms)
        expect(!transforms.turn([k], into: Disc.kind), "a corral can't turn into a disc")
        expectEqual(vetoes.asked.count, 0)
        expect(transforms.turn([a, k, a], into: Disc.kind))
        expectEqual(vetoes.asked.map(\.shapes), [[a]], "only the box, once")

        let log = VetoLog(), shakes = RefusalLog()
        let g = try transformHarness([boxesTurnIntoDiscs(), vetoing(log: log) { id, _ in true }], log: shakes)
        let b = g.add(Box(narrow))
        g.editor.freeze([b])
        expect(g.editor.transforms?.turn([b], into: Disc.kind) == false)
        expectEqual(log.actions.count, 1)
        expectEqual(shakes.refusals, [[b]], "heard once, as the veto's refusal")
    },

    test("every veto is asked, in plugin order: the shapes shake together and the actions run in order; a veto refusing some shapes holds the whole turn") {
        let log = VetoLog(), refusals = RefusalLog(), a = ShapeID()
        let h = try transformHarness([boxesTurnIntoDiscs(),
                                      vetoing("one", log: log) { id, _ in id == a },
                                      vetoing("two", log: log) { _, _ in true }], log: refusals)
        h.add(Box(narrow), id: a)
        let b = h.add(Box(CGRect(x: 300, y: 0, width: 50, height: 50)))
        let before = h.file
        expect(h.editor.transforms?.turn([a, b], into: Disc.kind) == false)
        expectEqual(h.file, before, "b would have been let go by the first, and is held back with the rest")
        expectEqual(log.asked.count, 2)
        expectEqual(log.actions, ["one: 1", "two: 2"])
        expectEqual(refusals.refusals, [[a, b]])
    },

    test("the report says what a veto is; it needs Transform installed") {
        let log = VetoLog()
        let r = try Registry(plugins: transformPlugins([vetoing(log: log) { _, _ in false }]))
        expect(try require(r.report.split(separator: "\n").first { $0.hasPrefix("veto") }).hasSuffix("turn veto → every shape"))
        expectThrows(RegistryError.ownerNotInstalled(point: "TransformVetoes", owner: .transform, contributor: "veto")) {
            _ = try Registry(plugins: [vetoing(log: log) { _, _ in false }])
        }
    },
])

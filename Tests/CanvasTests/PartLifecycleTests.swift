@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import TestKit

// A part's lifecycle, over CanvasTesting's musters (a kind that takes what's bound to it), rosters (one that doesn't) and
// straps (bound at each end to a shape or a row): a row taken out (`removeParts`) takes its straps along from a muster,
// counted, and leaves a roster's bound to the roster as a whole; a locked strap stays as it was; rows moved (`moveParts`)
// rebind their straps and are heard by `partsMoved`; one undo puts it all back.

@MainActor private struct Scene {
    let h: EditorHarness
    let log = PartsMovedLog()
    let alice = RosterRow(name: "alice"), bob = RosterRow(name: "bob"), carol = RosterRow(name: "carol")
    let muster: ShapeID, roster: ShapeID, other: ShapeID

    init() throws {
        h = try EditorHarness(plugins: [FixturesPlugin(), RostersPlugin(), StrapsPlugin(log: log), FreezingPlugin()])
        muster = h.add(Muster(CGRect(x: 0, y: 0, width: 100, height: 80), rows: [alice, bob]))
        roster = h.add(Roster(CGRect(x: 200, y: 0, width: 100, height: 80), rows: [carol]))
        other = h.add(Muster(CGRect(x: 400, y: 0, width: 100, height: 80), rows: []))
    }

    func strap(_ from: PartAddress?, _ to: PartAddress?) -> ShapeID { h.add(Strap(from: from, to: to)) }

    func strap(_ id: ShapeID) -> Strap? { h.editor.document[id]?.typed(as: Strap.self)?.props }
}

@MainActor let partLifecycleTests = Suite("A part's lifecycle", [
    test("removeParts: a strap at a muster's row goes with it, counted along; one at a roster's row is bound to the roster as a whole; others stay") {
        let s = try Scene()
        let atBob = s.strap(PartAddress(s.muster, part: s.bob.id), PartAddress(s.roster, part: s.carol.id))
        let atAlice = s.strap(PartAddress(s.muster, part: s.alice.id), PartAddress(s.roster))
        let atCarol = s.strap(PartAddress(s.other), PartAddress(s.roster, part: s.carol.id))
        s.h.editor.undoHistory.seal()
        var taken: Set<ShapeID> = [], along: [KindCount] = []
        s.h.editor.transact("Delete Entry") { tx in
            tx.update(s.muster, as: Muster.self) { $0.props.rows = [s.alice] }
            taken = tx.removeParts([PartAddress(s.muster, part: s.bob.id)])
            along = tx.deletedAlong
        }
        expectEqual(taken, [atBob], "the strap at bob goes")
        expectEqual(along, [KindCount(kind: Strap.kind, count: 1)], "counted along")
        expectEqual(s.h.editor.document[atBob], nil)
        expectEqual(s.strap(atAlice)?.from, PartAddress(s.muster, part: s.alice.id), "another row's strap stays")
        s.h.editor.transact { tx in
            tx.update(s.roster, as: Roster.self) { $0.props.rows = [] }
            tx.removeParts([PartAddress(s.roster, part: s.carol.id)])
        }
        expectEqual(s.strap(atCarol)?.to, PartAddress(s.roster), "a roster takes nothing along: its strap is bound to it as a whole")
        expectEqual(s.strap(atCarol)?.from, PartAddress(s.other), "the other end as it was")
        s.h.editor.undo()
        s.h.editor.undo()
        expectEqual(s.strap(atBob)?.from, PartAddress(s.muster, part: s.bob.id), "one undo brings the strap back")
        expectEqual(s.h.editor.document[s.muster]?.typed(as: Muster.self)?.props.rows.count, 2, "and the row")
        expectEqual(s.strap(atCarol)?.to, PartAddress(s.roster, part: s.carol.id), "and the binding to the row")
    },
    test("removeParts leaves a read-only strap as it was, still at the row; and a list of no parts does nothing") {
        let s = try Scene()
        let locked = s.strap(PartAddress(s.muster, part: s.bob.id), nil)
        let atRoster = s.strap(PartAddress(s.roster, part: s.carol.id), nil)
        s.h.editor.freeze([locked, atRoster])
        var taken: Set<ShapeID> = []
        s.h.editor.transact { tx in
            taken = tx.removeParts([PartAddress(s.muster, part: s.bob.id), PartAddress(s.roster, part: s.carol.id)])
            taken.formUnion(tx.removeParts([PartAddress(s.muster)]))
        }
        expect(taken.isEmpty)
        expectEqual(s.strap(locked)?.from, PartAddress(s.muster, part: s.bob.id))
        expectEqual(s.strap(atRoster)?.from, PartAddress(s.roster, part: s.carol.id))
    },
    test("moveParts rebinds every strap at a moved row to where it went, a row of another shape or a shape as a whole; partsMoved hears the moves once") {
        let s = try Scene()
        let atBob = s.strap(PartAddress(s.muster, part: s.bob.id), PartAddress(s.muster, part: s.alice.id))
        let atCarol = s.strap(PartAddress(s.roster, part: s.carol.id), nil)
        let locked = s.strap(PartAddress(s.muster, part: s.bob.id), nil)
        s.h.editor.freeze([locked])
        let moved = RosterRow(id: s.bob.id, name: "bob")
        let moves = [PartAddress(s.muster, part: s.bob.id): PartAddress(s.other, part: moved.id),
                     PartAddress(s.roster, part: s.carol.id): PartAddress(s.other)]
        s.h.editor.transact("Move Entry") { tx in
            tx.update(s.other, as: Muster.self) { $0.props.rows = [moved] }
            tx.moveParts(moves)
        }
        expectEqual(s.strap(atBob)?.from, PartAddress(s.other, part: s.bob.id), "to the row where it went")
        expectEqual(s.strap(atBob)?.to, PartAddress(s.muster, part: s.alice.id), "the other end kept")
        expectEqual(s.strap(atCarol)?.from, PartAddress(s.other), "to the shape as a whole")
        expectEqual(s.strap(locked)?.from, PartAddress(s.muster, part: s.bob.id), "a read-only one as it was")
        expectEqual(s.log.moves, [moves], "heard once")
        expectEqual(s.h.editor.undoHistory.undoName, "Move Entry")
        s.h.editor.undo()
        expectEqual(s.strap(atBob)?.from, PartAddress(s.muster, part: s.bob.id))
        s.h.editor.transact { $0.moveParts([PartAddress(s.muster, part: s.alice.id): PartAddress(s.muster, part: s.alice.id)]) }
        expectEqual(s.log.moves.count, 1, "a part that stays where it is moves nothing and is heard by none")
    },
    test("the registry says who hears parts moved") {
        let s = try Scene()
        expect(s.h.editor.registry.report.contains("parts moved"), "\(s.h.editor.registry.report)")
    },
])

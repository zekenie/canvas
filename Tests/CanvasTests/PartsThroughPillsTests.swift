@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import TestKit

// A part's lifecycle through a pill (K10): a strap on a pocket's board bound to a box that stands for a muster on the root, the
// muster's row named on the strap's binding, as a key to a column on another board is bound to a pill for its table. The core
// learns which shapes stand for which from the one stand-in lookup a plugin gives (`registrar.standInLookup`: Topology's, as
// shipped; here a table the test writes). `removeParts` reaches the strap in the same step, on its board; `moveParts` rebinds it.

/// Which boxes stand for which shapes, as a test says: the stand-in lookup the core reads.
@MainActor private final class StandingTable {
    var standing: [ShapeID: [ShapeID]] = [:]
}

@MainActor private func lookupPlugin(_ table: StandingTable) -> Contributor {
    Contributor(id: "lookup") { registrar in
        registrar.standInLookup { _, shape in table.standing[shape] ?? [] }
    }
}

@MainActor private struct Far {
    let h: EditorHarness
    let table = StandingTable()
    let log = PartsMovedLog()
    let alice = RosterRow(name: "alice"), bob = RosterRow(name: "bob"), carol = RosterRow(name: "carol")
    let muster = ShapeID(), roster = ShapeID(), other = ShapeID(), pocket = ShapeID(), pill = ShapeID(), rosterPill = ShapeID(), local = ShapeID()
    var board: BoardID { BoardID(owner: pocket) }

    init() throws {
        let root = CanvasDocument(shapes: [
            AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 0, y: 0, width: 200, height: 100)))),
            AnyShapeRecord(ShapeRecord(id: muster, Muster(CGRect(x: 300, y: 0, width: 100, height: 80), rows: [alice, bob]))),
            AnyShapeRecord(ShapeRecord(id: roster, Roster(CGRect(x: 500, y: 0, width: 100, height: 80), rows: [carol]))),
            AnyShapeRecord(ShapeRecord(id: other, Muster(CGRect(x: 700, y: 0, width: 100, height: 80), rows: []))),
        ])
        let far = CanvasDocument(shapes: [
            AnyShapeRecord(ShapeRecord(id: pill, Box(CGRect(x: 0, y: 0, width: 80, height: 40)))),
            AnyShapeRecord(ShapeRecord(id: rosterPill, Box(CGRect(x: 0, y: 100, width: 80, height: 40)))),
            AnyShapeRecord(ShapeRecord(id: local, Box(CGRect(x: 200, y: 0, width: 80, height: 40)))),
        ])
        h = try EditorHarness(plugins: [FixturesPlugin(), PocketsPlugin(), RostersPlugin(), StrapsPlugin(log: log), FreezingPlugin(), lookupPlugin(table)],
                              file: CanvasFile(root: root, children: [pocket: far]))
        table.standing = [muster: [pill], roster: [rosterPill]]
    }

    /// A strap on the pocket's board, from the local box to `to`.
    func strap(to: PartAddress) -> ShapeID {
        let id = ShapeID()
        h.editor.transact(on: board) { $0.insert(AnyShapeRecord(ShapeRecord(id: id, Strap(from: PartAddress(local), to: to)))) }
        return id
    }

    func strap(_ id: ShapeID) -> Strap? { h.file[board][id]?.typed(as: Strap.self)?.props }
}

@MainActor let partsThroughPillsTests = Suite("A part's lifecycle through a pill", [
    test("removeParts: a strap on another board bound through a pill to a muster's row goes in the same step, counted along; a roster's is bound to its pill as a whole") {
        let s = try Far()
        let atBob = s.strap(to: PartAddress(s.pill, part: s.bob.id))
        let atAlice = s.strap(to: PartAddress(s.pill, part: s.alice.id))
        let atCarol = s.strap(to: PartAddress(s.rosterPill, part: s.carol.id))
        s.h.editor.undoHistory.seal()
        var taken: Set<ShapeID> = [], along: [KindCount] = []
        s.h.editor.transact("Delete Entry") { tx in
            tx.update(s.muster, as: Muster.self) { $0.props.rows = [s.alice] }
            taken = tx.removeParts([PartAddress(s.muster, part: s.bob.id)])
            along = tx.deletedAlong
        }
        expectEqual(taken, [atBob], "the strap through the pill at bob goes")
        expectEqual(along, [KindCount(kind: Strap.kind, count: 1)], "counted along, on its own board")
        expectEqual(s.strap(atBob), nil)
        expectEqual(s.strap(atAlice)?.to, PartAddress(s.pill, part: s.alice.id), "another row's strap stays")
        s.h.editor.transact("Delete Member") { tx in
            tx.update(s.roster, as: Roster.self) { $0.props.rows = [] }
            tx.removeParts([PartAddress(s.roster, part: s.carol.id)])
        }
        expectEqual(s.strap(atCarol)?.to, PartAddress(s.rosterPill), "a roster takes nothing along: bound to its pill as a whole")
        s.h.editor.undo()
        s.h.editor.undo()
        expectEqual(s.strap(atBob)?.to, PartAddress(s.pill, part: s.bob.id), "one undo brings the strap back on its board")
        expectEqual(s.strap(atCarol)?.to, PartAddress(s.rosterPill, part: s.carol.id))
        expectEqual(s.h.editor.document[s.muster]?.typed(as: Muster.self)?.props.rows.count, 2)
    },
    test("removeParts leaves a read-only strap through a pill as it was") {
        let s = try Far()
        let locked = s.strap(to: PartAddress(s.pill, part: s.bob.id))
        s.h.editor.transact(on: s.board) { $0.update(locked) { $0[Frozen.self] = true } }
        var taken: Set<ShapeID> = []
        s.h.editor.transact { tx in taken = tx.removeParts([PartAddress(s.muster, part: s.bob.id)]) }
        expect(taken.isEmpty)
        expectEqual(s.strap(locked)?.to, PartAddress(s.pill, part: s.bob.id))
    },
    test("moveParts through a pill: within its shape through the pill, to another shape through the pill that stands for it, else to the pill as a whole; heard once") {
        let s = try Far()
        let otherPill = ShapeID()
        s.h.editor.transact(on: s.board) { $0.insert(AnyShapeRecord(ShapeRecord(id: otherPill, Box(CGRect(x: 0, y: 200, width: 80, height: 40))))) }
        let atBob = s.strap(to: PartAddress(s.pill, part: s.bob.id))
        let atAlice = s.strap(to: PartAddress(s.pill, part: s.alice.id))
        let atCarol = s.strap(to: PartAddress(s.rosterPill, part: s.carol.id))
        s.table.standing[s.other] = [otherPill]
        let renewed = PartID()
        let moves = [PartAddress(s.muster, part: s.bob.id): PartAddress(s.other, part: s.bob.id),
                     PartAddress(s.muster, part: s.alice.id): PartAddress(s.muster, part: renewed),
                     PartAddress(s.roster, part: s.carol.id): PartAddress(s.muster, part: s.carol.id)]
        s.table.standing[s.muster] = [s.pill]
        s.h.editor.transact("Move Entries") { $0.moveParts(moves) }
        expectEqual(s.strap(atBob)?.to, PartAddress(otherPill, part: s.bob.id), "through the pill for the shape it went to")
        expectEqual(s.strap(atAlice)?.to, PartAddress(s.pill, part: renewed), "within its shape: through the same pill")
        expectEqual(s.strap(atCarol)?.to, PartAddress(s.pill, part: s.carol.id), "to the muster, which the pill on that board stands for")
        expectEqual(s.log.moves, [moves], "heard once")
        s.table.standing[s.other] = []
        s.h.editor.undo()
        let lone = s.strap(to: PartAddress(s.pill, part: s.bob.id))
        s.h.editor.transact { $0.moveParts([PartAddress(s.muster, part: s.bob.id): PartAddress(s.other, part: s.bob.id)]) }
        expectEqual(s.strap(lone)?.to, PartAddress(s.pill), "nothing on that board stands for where it went: the pill as a whole")
    },
    test("without a stand-in lookup, a strap through a pill is not reached: the core knows no pill") {
        let s = try Far()
        let atBob = s.strap(to: PartAddress(s.pill, part: s.bob.id))
        s.table.standing = [:]
        s.h.editor.transact { tx in _ = tx.removeParts([PartAddress(s.muster, part: s.bob.id)]) }
        expectEqual(s.strap(atBob)?.to, PartAddress(s.pill, part: s.bob.id))
        expect(s.h.editor.registry.report.contains("stand-in lookup"), "\(s.h.editor.registry.report)")
    },
])

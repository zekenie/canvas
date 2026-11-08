@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Mentions
import TestKit
import Titles
import Topology
import Types
import Validation

// The edges of deleting a relationship type and of the loose end's line: boards not shown, a pill, undo and redo, a
// delete made of the same transaction's own writes, a type moved alone, and what a file with no relationship type pays.

private let line = "This arrow isn’t attached at both ends."

@MainActor private func issues(_ editor: CanvasEditor, _ id: ShapeID) -> [String] { editor.issues(id).map(\.message).sorted() }

@MainActor private func fresh(_ editor: CanvasEditor, _ id: ShapeID) throws -> [String] {
    let other = try bondEditor(file: editor.file, more: [FreezingPlugin()])
    return try require(other.fieldChecks).fullCheck(of: try require(other.file.record(id))).problems.map(\.message).sorted()
}

extension RelationScene {
    fileprivate func probePill(on board: BoardID, standingFor shape: ShapeID, at origin: CGPoint) -> ShapeID {
        let record = AnyShapeRecord(ShapeRecord(id: ShapeID(), Relay(CGRect(origin: origin, size: CGSize(width: 100, height: 32)), stands: [shape], says: "p")))
        editor.transact(on: board, "Draw") { $0.insert(record) }
        return record.id
    }

    fileprivate func probeBond(on board: BoardID, _ from: ShapeID?, _ to: ShapeID?, name: String = "") -> ShapeID {
        let record = AnyShapeRecord(ShapeRecord(id: ShapeID(), Bond(from: from, to: to, text: MentionText(plain: name))))
        editor.transact(on: board, "Draw") { $0.insert(record) }
        return record.id
    }
}

@MainActor let relationshipDeleteEdgeTests = Suite("Deleting a relationship type, the edges", [
    test("a relationship type deleted in a file opened afresh takes its ends, near and far") {
        let s = try RelationScene(more: [FreezingPlugin()])
        let from = s.fromEnd("a"), to = s.toEnd("b")
        s.setOpen(s.rel)
        s.setOpen(s.feature)
        let featurePill = s.probePill(on: s.pocketBoard, standingFor: s.feature, at: CGPoint(x: 0, y: 200))
        let relPill = s.probePill(on: s.pocketBoard, standingFor: s.rel, at: CGPoint(x: 300, y: 200))
        let there = s.probeBond(on: s.pocketBoard, featurePill, relPill, name: "far")
        let opened = try bondEditor(file: s.editor.file, more: [FreezingPlugin()])
        opened.transact("Delete") { $0.delete([s.rel]) }
        expect(opened.file.record(s.rel) == nil)
        expect(opened.file.record(from) == nil && opened.file.record(to) == nil && opened.file.record(there) == nil, "every end went")
    },
    test("Undo, Redo and Undo again of a relationship type's delete with ends near, far and at a pill, one locked, are exact each time") {
        let s = try RelationScene(more: [FreezingPlugin()])
        let from = s.fromEnd("a"), to = s.toEnd("b")
        s.setOpen(s.rel)
        s.setOpen(s.feature)
        let featurePill = s.probePill(on: s.pocketBoard, standingFor: s.feature, at: CGPoint(x: 0, y: 200))
        let relPill = s.probePill(on: s.pocketBoard, standingFor: s.rel, at: CGPoint(x: 300, y: 200))
        let there = s.probeBond(on: s.pocketBoard, featurePill, relPill, name: "far")
        s.editor.freeze([to])
        s.editor.undoHistory.seal()
        let start = s.editor.file, startBytes = try s.bytes()
        s.editor.transact("Delete") { $0.delete([s.rel]) }
        expect(s.editor.document[from] == nil && s.editor.file.record(there) == nil && s.editor.document[to] != nil)
        let after = s.editor.file, afterBytes = try s.bytes()
        for round in 0..<2 {
            s.editor.undo()
            expectEqual(s.editor.file, start, "undo \(round)")
            expect(try s.bytes() == startBytes, "undo bytes \(round)")
            expectEqual(s.index.endArrows(of: s.rel), [from, to, there], "ends again \(round)")
            expectEqual(issues(s.editor, to), [], "an end again \(round)")
            s.editor.redo()
            expectEqual(s.editor.file, after, "redo \(round)")
            expect(try s.bytes() == afterBytes, "redo bytes \(round)")
            expectEqual(issues(s.editor, to), [line], "loose again \(round)")
        }
        expectEqual(s.editor.undoHistory.undoName, "Delete")
    },
    test("a relationship type deleted with one of its end types, or with one of its own end arrows, takes its ends and Undo is exact") {
        let s = try RelationScene(more: [FreezingPlugin()])
        let from = s.fromEnd("a"), to = s.toEnd("b")
        s.editor.undoHistory.seal()
        let start = s.editor.file, startBytes = try s.bytes()
        s.editor.transact("Delete") { $0.delete([s.rel, s.layer]) }
        expect(s.editor.document[from] == nil && s.editor.document[to] == nil)
        s.editor.undo()
        expectEqual(s.editor.file, start)
        expect(try s.bytes() == startBytes)
        s.editor.transact("Delete") { $0.delete([s.rel, from]) }
        expect(s.editor.document[from] == nil && s.editor.document[to] == nil && s.editor.document[s.rel] == nil)
        s.editor.undo()
        expectEqual(s.editor.file, start)
        expect(try s.bytes() == startBytes)
    },
    test("an end arrow on a read-only board stays when its relationship type is deleted from another board, and Undo is exact") {
        let s = try RelationScene(more: [FreezingPlugin()])
        s.fromEnd()
        s.setOpen(s.rel)
        s.setOpen(s.feature)
        let featurePill = s.probePill(on: s.pocketBoard, standingFor: s.feature, at: CGPoint(x: 0, y: 200))
        let relPill = s.probePill(on: s.pocketBoard, standingFor: s.rel, at: CGPoint(x: 300, y: 200))
        let there = s.probeBond(on: s.pocketBoard, featurePill, relPill, name: "far")
        s.editor.freeze([s.pocket])
        expect(s.editor.isReadOnly(board: s.pocketBoard), "the pocket's board is read-only")
        s.editor.undoHistory.seal()
        let start = s.editor.file
        let pocketBefore = s.editor.contents(of: s.pocketBoard)
        s.editor.transact("Delete") { $0.delete([s.rel]) }
        expect(s.editor.document[s.rel] == nil, "the delete is not refused")
        expect(s.editor.file.record(there) != nil, "the arrow on the read-only board stays")
        expectEqual(s.editor.contents(of: s.pocketBoard), pocketBefore, "nothing on the read-only board changed")
        s.editor.undo()
        expectEqual(s.editor.file, start)
    },
    test("a relationship type on a board not shown whose ends are on the board shown, deleted from the board shown with delete(inFile:), takes the ends here and Undo is exact") {
        let s = try RelationScene(more: [FreezingPlugin()])
        let there = ShapeID()
        var record = slipTypeRecord(TypeSchemaProperty.starter, title: "there", at: CGPoint(x: 200, y: 0), id: there)
        record[RelationshipProperty.self] = true
        let made = record
        s.editor.transact(on: s.pocketBoard, "Draw") { $0.insert(made) }
        s.setOpen(there)
        let pill = s.editor.addRelay(standingFor: [there], says: "there")
        let a = s.editor.addBond(s.feature, pill, name: "a"), b = s.editor.addBond(pill, s.layer)
        expectEqual(s.index.endArrows(of: there), [a, b])
        s.editor.undoHistory.seal()
        let start = s.editor.file, startBytes = try s.bytes()
        s.editor.transact("Delete") { $0.delete(inFile: [there]) }
        expect(s.editor.file.record(there) == nil)
        expect(s.editor.document[a] == nil && s.editor.document[b] == nil, "the ends on the board shown went")
        expect(s.editor.document[pill] != nil, "the pill stays")
        s.editor.undo()
        expect(s.editor.file == start, "undone")
        expect(try s.bytes() == startBytes)
    },
    test("a relationship type on a board not shown, deleted by a step on its own board with an end on the board shown, is deleted and that end stays, since the step cannot reach the board shown") {
        let s = try RelationScene(more: [FreezingPlugin()])
        let there = ShapeID()
        var record = slipTypeRecord(TypeSchemaProperty.starter, title: "there", at: CGPoint(x: 200, y: 0), id: there)
        record[RelationshipProperty.self] = true
        let made = record
        s.editor.transact(on: s.pocketBoard, "Draw") { $0.insert(made) }
        s.setOpen(there)
        let pill = s.editor.addRelay(standingFor: [there], says: "there")
        let a = s.editor.addBond(s.feature, pill, name: "a")
        expectEqual(s.index.endArrows(of: there), [a])
        s.editor.undoHistory.seal()
        let start = s.editor.file
        let passes = RelationshipIndex.endDeletes
        let ran: Bool? = s.editor.transact(on: s.pocketBoard, "Delete") { $0.delete([there]); return true }
        expectEqual(ran, true, "the body ran")
        expectEqual(RelationshipIndex.endDeletes, passes + 1, "and the handler with it")
        expect(s.editor.file.record(there) == nil, "the relationship type is deleted")
        expect(s.editor.file != start, "something was committed")
        expect(s.editor.undoHistory.canUndo, "and there is a step to undo")
        expect(s.editor.document[a] != nil, "the end on the board shown stays, let go of the type")
        s.editor.undo()
        expectEqual(s.editor.file, start, "one Undo")
    },
    test("the board shown holds the relationship type and an end is on the board above: the end goes and Undo is exact") {
        let s = try RelationScene(more: [FreezingPlugin()])
        let there = ShapeID()
        var record = slipTypeRecord(TypeSchemaProperty.starter, title: "there", at: CGPoint(x: 200, y: 0), id: there)
        record[RelationshipProperty.self] = true
        let made = record
        s.editor.transact(on: s.pocketBoard, "Draw") { $0.insert(made) }
        s.setOpen(there)
        let pill = s.editor.addRelay(standingFor: [there], says: "there")
        let a = s.editor.addBond(s.feature, pill, name: "a")
        expect(s.editor.showBoard(s.pocketBoard))
        s.editor.undoHistory.seal()
        let start = s.editor.file, startBytes = try s.bytes()
        s.editor.transact("Delete") { $0.delete([there]) }
        expect(s.editor.file.record(there) == nil, "deleted on the board shown")
        expect(s.editor.file.record(a) == nil, "its end on the root went with it")
        expectEqual(s.editor.undoHistory.undoName, "Delete")
        s.editor.undo()
        expect(s.editor.file == start, "undone")
        expect(try s.bytes() == startBytes)
    },
    test("a relationship type and the pocket whose board holds one of its ends, deleted together: Undo, Redo and Undo are exact") {
        let s = try RelationScene(more: [FreezingPlugin()])
        let from = s.fromEnd("a")
        s.setOpen(s.rel)
        s.setOpen(s.feature)
        let featurePill = s.probePill(on: s.pocketBoard, standingFor: s.feature, at: CGPoint(x: 0, y: 200))
        let relPill = s.probePill(on: s.pocketBoard, standingFor: s.rel, at: CGPoint(x: 300, y: 200))
        let there = s.probeBond(on: s.pocketBoard, featurePill, relPill, name: "far")
        expectEqual(s.index.endArrows(of: s.rel), [from, there])
        s.editor.undoHistory.seal()
        let start = s.editor.file, startBytes = try s.bytes()
        s.editor.transact("Delete") { $0.delete([s.rel, s.pocket]) }
        expect(s.editor.file.record(s.rel) == nil && s.editor.file.record(s.pocket) == nil && s.editor.file.record(there) == nil && s.editor.document[from] == nil)
        let after = s.editor.file
        s.editor.undo()
        expect(s.editor.file == start, "undone")
        expect(try s.bytes() == startBytes, "byte for byte")
        s.editor.redo()
        expect(s.editor.file == after, "redone")
        s.editor.undo()
        expect(s.editor.file == start, "undone again")
        expectEqual(s.index.endArrows(of: s.rel), [from, there])
    },
    test("deleting a relationship type with a locked end shakes nothing, and a selection of the type and its locked end refuses only the end") {
        let log = RefusalLog()
        let s = try RelationScene(more: [FreezingPlugin(log: log)])
        let from = s.fromEnd("a"), to = s.toEnd("b")
        s.editor.freeze([to])
        s.editor.transact("Delete") { $0.delete([s.rel]) }
        expect(s.editor.document[s.rel] == nil && s.editor.document[from] == nil && s.editor.document[to] != nil)
        expectEqual(log.refusals, [], "nothing refused, nothing shakes")
        s.editor.undo()
        s.editor.transact("Delete") { $0.delete([s.rel, to]) }
        expect(s.editor.document[s.rel] == nil && s.editor.document[to] != nil)
        expectEqual(log.refusals, [[to]], "the locked arrow the person asked for is the only refusal")
    },
    test("a locked end arrow that runs into a pill for a type, with a name, is a loose end once its relationship type is deleted") {
        let s = try RelationScene(more: [FreezingPlugin()])
        s.fromEnd()
        let far = ShapeID()
        s.editor.transact(on: s.pocketBoard, "Draw") { $0.insert(slipTypeRecord(TypeSchemaProperty.starter, title: "Company", at: CGPoint(x: 600, y: 0), id: far)) }
        s.setOpen(far)
        let farPill = s.editor.addRelay(standingFor: [far], says: "Company")
        let intoPill = s.editor.addBond(s.rel, farPill, name: "employer")
        expect(s.index.endArrows(of: s.rel).contains(intoPill), "an end, read through the pill")
        s.editor.freeze([intoPill])
        s.editor.transact("Delete") { $0.delete([s.rel]) }
        expect(s.editor.document[intoPill] != nil, "the locked end stays")
        expectEqual(s.editor.document[intoPill]?.typed(as: Bond.self)?.props.from, nil)
        expectEqual(issues(s.editor, intoPill), [line], "a locked end left at a pill for a type is orange")
    },
    test("an end arrow whose other end was freed earlier, bound to the relationship type alone, goes with the type") {
        let s = try RelationScene(more: [FreezingPlugin()])
        s.fromEnd()
        let to = s.toEnd("layers")
        s.editor.transact("Delete") { $0.delete([s.layer]) }
        expectEqual(issues(s.editor, to), ["in isn’t attached at both ends."], "a loose end of the type")
        s.editor.transact("Delete") { $0.delete([s.rel]) }
        expect(s.editor.document[to] == nil, "an end arrow whose other end is a type's note, a stand-in, or nothing goes")
    },
    test("an end freed by its end type's delete is an end again, with the same name, when it is re-aimed at another type") {
        let s = try RelationScene(more: [FreezingPlugin()])
        s.fromEnd("friends")
        let to = s.toEnd("layers")
        let other = s.editor.addSlipType(featureRowsSchema, title: "Other", at: CGPoint(x: 0, y: 600))
        s.editor.transact("Delete") { $0.delete([s.layer]) }
        expectEqual(s.index.end(to)?.type, nil, "freed, it is no end")
        s.editor.transact("Re-aim") { $0.update(to, as: Bond.self) { $0.props.to = other } }
        expectEqual(s.index.end(to)?.type, s.rel, "an end again")
        expectEqual(s.index.end(to)?.side, .to)
        expectEqual(s.editor.document[to]?.typed(as: Bond.self)?.props.text.stored, "layers", "with its name")
        expectEqual(issues(s.editor, to), [], "and no loose end")
    },
    test("a named arrow that loses an end at a type's note is a loose end, in a file with a type and no relationship type, and a bare one says nothing") {
        let editor = try bondEditor()
        let type = editor.addSlipType(featureRowsSchema, title: "Service")
        let note = editor.addSlip("a box")
        let named = editor.addBond(type, note, name: "rings")
        let bare = editor.addBond(type, note)
        expectEqual(issues(editor, named), [])
        editor.transact("Delete") { $0.delete([note]) }
        expect(editor.relationships?.isActive == false)
        expectEqual(issues(editor, named), [line], "a name on an arrow left at a type's note: what a deleted relationship type leaves, and the arrow cannot say which")
        expectEqual(issues(editor, bare), [], "with no name and no rule it is a plain arrow that lost an end")
    },
    test("a relationship type moved alone to another board leaves its named ends orange, its bare ends silent, and a file read afresh agrees; Undo clears them") {
        let s = try RelationScene(more: [FreezingPlugin()])
        let from = s.fromEnd("a"), to = s.toEnd()
        s.editor.undoHistory.seal()
        let start = s.editor.file
        s.editor.transact("Move") { _ = $0.move([s.rel], toBoardOwnedBy: s.pocket) }
        expectEqual(s.editor.file.board(containing: s.rel), s.pocketBoard)
        expectEqual(s.editor.document[from]?.typed(as: Bond.self)?.props.to, nil)
        expectEqual(issues(s.editor, from), [line])
        expectEqual(issues(s.editor, to), [])
        expectEqual(try fresh(s.editor, from), [line])
        s.editor.undo()
        expectEqual(s.editor.file, start)
        expectEqual(issues(s.editor, from), [])
    },
    test("an end drawn in the transaction that deletes its relationship type goes with it") {
        let s = try RelationScene(more: [FreezingPlugin()])
        let from = s.fromEnd("a")
        let late = AnyShapeRecord(ShapeRecord(id: ShapeID(), Bond(from: s.rel, to: s.layer, text: MentionText(plain: "late"))))
        s.editor.transact("Delete") {
            $0.insert(late)
            $0.delete([s.rel])
        }
        expect(s.editor.document[from] == nil)
        expect(s.editor.document[late.id] == nil, "an end the same transaction drew is an end too")
    },
    test("an end re-aimed to a note that is no type in the transaction that deletes its relationship type is a plain arrow and stays") {
        let s = try RelationScene(more: [FreezingPlugin()])
        let to = s.toEnd("b")
        s.editor.transact("Delete") {
            $0.update(to, as: Bond.self) { $0.props.to = s.layerNote }
            $0.delete([s.rel])
        }
        expect(s.editor.document[to] != nil, "an arrow between the type and a note that is no type is a plain arrow and stays")
    },
    test("a subboard that holds a relationship type, deleted, runs no handler for it and leaves the ends drawn at a pill for it on other boards, silent") {
        let s = try RelationScene(more: [FreezingPlugin()])
        let there = ShapeID()
        var record = slipTypeRecord(TypeSchemaProperty.starter, title: "there", at: CGPoint(x: 200, y: 0), id: there)
        record[RelationshipProperty.self] = true
        let made = record
        s.editor.transact(on: s.pocketBoard, "Draw") { $0.insert(made) }
        s.setOpen(there)
        let pill = s.editor.addRelay(standingFor: [there], says: "there")
        let a = s.editor.addBond(s.feature, pill, name: "a"), b = s.editor.addBond(pill, s.layer)
        expectEqual(s.index.endArrows(of: there), [a, b])
        let passes = RelationshipIndex.endDeletes
        s.editor.transact("Delete") { $0.delete([s.pocket]) }
        expect(s.editor.file.record(there) == nil, "the board went with the pocket")
        expectEqual(RelationshipIndex.endDeletes, passes, "no handler ran for what was on the board")
        expect(s.editor.document[a] != nil && s.editor.document[b] != nil, "the ends stay")
        expectEqual(issues(s.editor, a), [])
        expectEqual(issues(s.editor, b), [])
    },
    test("an instance of a deleted relationship type stays and still names it") {
        let s = try RelationScene(more: [FreezingPlugin()])
        s.fromEnd()
        s.toEnd()
        let arrow = s.relate(s.note, s.layerNote)
        expectEqual(issues(s.editor, arrow), [])
        s.editor.transact("Delete") { $0.delete([s.rel]) }
        expect(s.editor.document[arrow] != nil, "the relationship stays")
        expectEqual(s.editor.document[arrow]?[IsAProperty.self]?.map(\.shape), [s.rel], "naming a gone type")
    },
    test("making a note a type in a file with no relationship type costs the same on a board of 10,000 arrows as on one of 100") {
        @MainActor func cost(_ count: Int) throws -> Duration {
            let editor = try bondEditor()
            let a = editor.addSlip("a"), b = editor.addSlip("b", at: CGPoint(x: 600, y: 400))
            editor.transact { transaction in
                for _ in 0..<count { transaction.insert(AnyShapeRecord(ShapeRecord(id: ShapeID(), Bond(from: a, to: b, text: MentionText(plain: "rings"))))) }
            }
            _ = editor.validation?.results
            expect(editor.relationships?.isActive == false)
            var types: [Duration] = []
            for round in 0..<7 {
                types.append(threadCPUTime { _ = editor.addSlipType(featureRowsSchema, title: "T \(round)", at: CGPoint(x: 1300, y: 400 + 80 * Double(round))) })
            }
            return types.sorted()[3]
        }
        let small = try cost(100), large = try cost(10_000)
        // A pass over 10,000 arrows took 16 ms (0.25 ms at 100); without it a type made costs 0.3 ms at either.
        expect(large < small + .milliseconds(5), "a type made: \(small) at 100 arrows, \(large) at 10,000")
    },
])

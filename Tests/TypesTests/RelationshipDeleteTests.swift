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

// Deleting a relationship type takes its end arrows with it, in the delete's own step, except a locked one, which stays a
// loose end: on the board the type is on and on every other, through a pill, from a board not shown, and exact on undo.

private let line = "This arrow isn’t attached at both ends."

@MainActor private func issues(_ editor: CanvasEditor, _ id: ShapeID) -> [String] { editor.issues(id).map(\.message).sorted() }

/// What an editor opened afresh on the same file says of an arrow.
@MainActor private func fresh(_ editor: CanvasEditor, _ id: ShapeID) throws -> [String] {
    let other = try bondEditor(file: editor.file)
    return try require(other.fieldChecks).fullCheck(of: try require(other.file.record(id))).problems.map(\.message).sorted()
}

@MainActor private final class Counted {
    var began = 0
}

extension RelationScene {
    /// The undo steps a body opens.
    fileprivate func steps(_ body: () -> Void) -> Int {
        let counted = Counted()
        editor.undoHistory.didChange = { if $0 == .began { counted.began += 1 } }
        defer { editor.undoHistory.didChange = { _ in } }
        body()
        return counted.began
    }

    /// A type on the pocket's board, `open` so a pill may stand for it, titled `title`.
    fileprivate func farType(_ title: String) -> ShapeID {
        let id = ShapeID()
        editor.transact(on: pocketBoard, "Draw") { $0.insert(slipTypeRecord(TypeSchemaProperty.starter, title: title, at: CGPoint(x: 600, y: 0), id: id)) }
        setOpen(id)
        return id
    }

    /// A pill on the pocket's board for a type, and an arrow between two shapes there.
    fileprivate func pill(on board: BoardID, standingFor shape: ShapeID, at origin: CGPoint) -> ShapeID {
        let record = AnyShapeRecord(ShapeRecord(id: ShapeID(), Relay(CGRect(origin: origin, size: CGSize(width: 100, height: 32)), stands: [shape], says: "p")))
        editor.transact(on: board, "Draw") { $0.insert(record) }
        return record.id
    }

    fileprivate func bond(on board: BoardID, _ from: ShapeID?, _ to: ShapeID?, name: String = "") -> ShapeID {
        let record = AnyShapeRecord(ShapeRecord(id: ShapeID(), Bond(from: from, to: to, text: MentionText(plain: name))))
        editor.transact(on: board, "Draw") { $0.insert(record) }
        return record.id
    }
}

@MainActor let relationshipDeleteTests = Suite("Deleting a relationship type", [
    test("both end arrows go with it in one step, an arrow between it and a note that is no type stays, and one Undo brings the file back byte for byte") {
        let s = try RelationScene(more: [FreezingPlugin()])
        let from = s.fromEnd("friends"), to = s.toEnd()
        let plain = s.editor.addBond(s.rel, s.note)
        expectEqual(s.index.endArrows(of: s.rel), [from, to])
        s.editor.undoHistory.seal()
        let start = s.editor.file, startBytes = try s.bytes()
        let count = s.steps { s.editor.transact("Delete") { $0.delete([s.rel]) } }
        expectEqual(count, 1, "one step")
        expect(s.editor.document[from] == nil && s.editor.document[to] == nil, "both end arrows deleted")
        expect(s.editor.document[s.rel] == nil)
        expectEqual(s.editor.document[plain]?.typed(as: Bond.self)?.props.from, nil, "the arrow to a note that is no type stays, let go of the type")
        expectEqual(s.editor.typesOf(s.note), [s.feature], "the instances keep their types")
        expectEqual(s.names(s.note), ["purpose"], "and lose the row")
        expectEqual(s.index.endArrows(of: s.rel), [])
        let after = s.editor.file
        s.editor.undo()
        expectEqual(s.editor.file, start, "one Undo brings the file back")
        expect(try s.bytes() == startBytes, "byte for byte")
        expectEqual(s.editor.relationships?.graph.sides(of: s.rel).from.map(\.type), [s.feature])
        s.editor.redo()
        expectEqual(s.editor.file, after, "and Redo takes them again")
    },
    test("an end arrow that is locked stays, let go of the type, and is an orange loose end when it has a name or a rule and says nothing when it has neither; an unlocked one goes; Undo is exact") {
        let s = try RelationScene(more: [FreezingPlugin()])
        let named = s.editor.addBond(s.feature, s.rel, name: "friends")
        let ruled = s.editor.addBond(s.rel, s.layer, rule: EndRule(needed: true, onlyOne: false))
        let bare = s.editor.addBond(s.feature, s.rel)
        let free = s.editor.addBond(s.rel, s.layer, name: "layers")
        s.editor.freeze([named, ruled, bare])
        s.editor.undoHistory.seal()
        let start = s.editor.file, startBytes = try s.bytes()
        s.editor.transact("Delete") { $0.delete([s.rel]) }
        expect(s.editor.document[s.rel] == nil, "the delete of the type is not refused")
        expect(s.editor.document[free] == nil, "the unlocked end arrow went")
        for id in [named, ruled, bare] { expect(s.editor.document[id] != nil, "a locked end arrow stays") }
        expectEqual(s.editor.document[named]?.typed(as: Bond.self)?.props.from, s.feature, "bound at its type's end")
        expectEqual(s.editor.document[named]?.typed(as: Bond.self)?.props.to, nil, "let go of the relationship type, where it was drawn")
        expectEqual(s.editor.document[ruled]?.typed(as: Bond.self)?.props.from, nil)
        expectEqual(s.editor.document[ruled]?.typed(as: Bond.self)?.props.to, s.layer)
        expectEqual(issues(s.editor, named), [line], "a name makes it a loose end")
        expectEqual(issues(s.editor, ruled), [line], "so does a rule")
        expectEqual(issues(s.editor, bare), [], "an arrow with neither is a plain arrow that lost an end")
        for id in [named, ruled, bare] { expectEqual(try fresh(s.editor, id), issues(s.editor, id), "a file opened afresh says the same") }
        s.editor.undo()
        expectEqual(s.editor.file, start)
        expect(try s.bytes() == startBytes, "byte for byte")
        expectEqual(issues(s.editor, named), [], "the arrow is an end again")
        s.editor.redo()
        expectEqual(issues(s.editor, named), [line], "and a loose end again")
    },
    test("an end arrow on another board, drawn through pills, goes too, and an end into a stand-in on this board; one Undo gives back both boards byte for byte") {
        let s = try RelationScene(more: [FreezingPlugin()])
        s.fromEnd()
        s.setOpen(s.rel)
        s.setOpen(s.feature)
        let far = s.farType("Company")
        // On this board, an end into a pill for a type on the pocket's board.
        let farPill = s.editor.addRelay(standingFor: [far], says: "Company")
        let intoPill = s.editor.addBond(s.rel, farPill)
        // On the pocket's board, an end between a pill for Feature and a pill for the relationship type.
        let featurePill = s.pill(on: s.pocketBoard, standingFor: s.feature, at: CGPoint(x: 0, y: 200))
        let relPill = s.pill(on: s.pocketBoard, standingFor: s.rel, at: CGPoint(x: 300, y: 200))
        let there = s.bond(on: s.pocketBoard, featurePill, relPill)
        expectEqual(s.index.endArrows(of: s.rel).count, 3, "the index reads the ends through the pills")
        s.editor.undoHistory.seal()
        let start = s.editor.file, startBytes = try s.bytes()
        let count = s.steps { s.editor.transact("Delete") { $0.delete([s.rel]) } }
        expectEqual(count, 1)
        expect(s.editor.document[intoPill] == nil, "the end into a pill went")
        expect(s.editor.file.record(there) == nil, "the end on the other board went")
        expect(s.editor.file.record(relPill) != nil && s.editor.file.record(featurePill) != nil && s.editor.document[farPill] != nil, "the pills stay")
        s.editor.undo()
        expectEqual(s.editor.file, start)
        expect(try s.bytes() == startBytes, "both boards, byte for byte")
        expectEqual(s.index.endArrows(of: s.rel).count, 3)
    },
    test("a relationship type on a board that is not shown, deleted through the core's delete across boards or by a step on its own board: its end arrows go with it and an Undo is exact") {
        for byHidden in [false, true] {
            let s = try RelationScene(more: [FreezingPlugin()])
            s.setOpen(s.feature)
            s.setOpen(s.layer)
            let there = ShapeID()
            var record = slipTypeRecord(TypeSchemaProperty.starter, title: "there", at: CGPoint(x: 200, y: 0), id: there)
            record[RelationshipProperty.self] = true
            s.editor.transact(on: s.pocketBoard, "Draw") { $0.insert(record) }
            let featurePill = s.pill(on: s.pocketBoard, standingFor: s.feature, at: CGPoint(x: 0, y: 200))
            let layerPill = s.pill(on: s.pocketBoard, standingFor: s.layer, at: CGPoint(x: 400, y: 200))
            let a = s.bond(on: s.pocketBoard, featurePill, there, name: "a"), b = s.bond(on: s.pocketBoard, there, layerPill)
            expectEqual(s.index.endArrows(of: there), [a, b], "\(byHidden)")
            s.editor.undoHistory.seal()
            let start = s.editor.file, startBytes = try s.bytes()
            if byHidden {
                s.editor.transact(on: s.pocketBoard, "Delete") { $0.delete([there]) }
            } else {
                s.editor.transact("Delete") { $0.delete(inFile: [there]) }
            }
            expect(s.editor.file.record(there) == nil, "the type is deleted, \(byHidden)")
            expect(s.editor.file.record(a) == nil && s.editor.file.record(b) == nil, "its end arrows with it, \(byHidden)")
            expect(s.editor.file.record(featurePill) != nil && s.editor.file.record(layerPill) != nil, "the pills stay")
            _ = s.editor.showBoard(.root)
            s.editor.undo()
            _ = s.editor.showBoard(.root)
            expectEqual(s.editor.file, start, "undone, \(byHidden)")
            expect(try s.bytes() == startBytes, "byte for byte, \(byHidden)")
            expectEqual(s.index.endArrows(of: there), [a, b])
        }
    },
    test("two relationship types that share an end type, deleted together: every end arrow goes in one step, and a locked one of either stays") {
        let s = try RelationScene(more: [FreezingPlugin()])
        let other = s.editor.addRelationshipType("with", at: CGPoint(x: 240, y: 300))
        let ends = [s.fromEnd(), s.toEnd(), s.editor.addBond(s.feature, other), s.editor.addBond(other, s.layer, name: "kept")]
        s.editor.freeze([ends[3]])
        s.editor.undoHistory.seal()
        let start = s.editor.file, startBytes = try s.bytes()
        let count = s.steps { s.editor.transact("Delete") { $0.delete([s.rel, other]) } }
        expectEqual(count, 1)
        expect(ends[0...2].allSatisfy { s.editor.document[$0] == nil }, "the unlocked ones went")
        expect(s.editor.document[ends[3]] != nil, "the locked one stayed")
        expectEqual(issues(s.editor, ends[3]), [line])
        s.editor.undo()
        expectEqual(s.editor.file, start)
        expect(try s.bytes() == startBytes)
    },
    test("a delete of shapes that are no relationship type runs nothing of it: a type at an end only frees its arrow, and a note or a type costs a lookup") {
        let s = try RelationScene(more: [FreezingPlugin()])
        let from = s.fromEnd("friends"), to = s.toEnd()
        let passes = RelationshipIndex.endDeletes
        s.editor.transact("Delete") { $0.delete([s.note, s.layerNote]) }
        s.editor.transact("Delete") { $0.delete([s.layer]) }
        expectEqual(RelationshipIndex.endDeletes, passes, "no pass over a relationship type's ends")
        expect(s.editor.document[from] != nil && s.editor.document[to] != nil, "the end arrows stay")
        expectEqual(s.editor.document[to]?.typed(as: Bond.self)?.props.from, s.rel)
        expectEqual(s.editor.document[to]?.typed(as: Bond.self)?.props.to, nil, "the end let go of the deleted type, where it was drawn")
        expectEqual(issues(s.editor, to), ["in isn’t attached at both ends."])
        s.editor.transact("Delete") { $0.delete([s.rel]) }
        expectEqual(RelationshipIndex.endDeletes, passes + 1, "one pass for a relationship type")
        expect(s.editor.document[from] == nil, "the end arrow still bound at its type goes")
    },
    test("Remove Type on a relationship type, and the mark taken off, delete nothing") {
        let s = try RelationScene(more: [FreezingPlugin()])
        let from = s.fromEnd(), to = s.toEnd()
        s.editor.removeType(s.rel)
        expect(s.editor.document[from] != nil && s.editor.document[to] != nil, "the end arrows stay, now arrows between a type and a plain note")
        s.editor.undo()
        s.editor.makePlainTypes([s.rel])
        expect(s.editor.document[from] != nil && s.editor.document[to] != nil, "the mark taken off")
    },
])

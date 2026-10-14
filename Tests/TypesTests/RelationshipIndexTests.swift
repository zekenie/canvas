@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Mentions
import TestKit
import Titles
import Topology
import Types

// The service that keeps the ends: each way a commit changes them is told by the ids it names, and an undo
// puts the ends and the announcement back. Over bonds, with pills and boards the editor may not show.

/// Person, Company, Employment; Ann (a Person), Acme (a Company), and a relationship `job` of Employment
/// between them, drawn before any end, so the instances of Employment are there to be named.
@MainActor private struct Scene {
    let editor: CanvasEditor
    let person: ShapeID, company: ShapeID, employment: ShapeID, ann: ShapeID, acme: ShapeID, job: ShapeID
    let heard: RelationshipHeard

    init() throws {
        editor = try bondEditor()
        person = editor.addType(TypeSchemaProperty.starter, title: "Person", at: CGPoint(x: 40, y: 40))
        company = editor.addType(TypeSchemaProperty.starter, title: "Company", at: CGPoint(x: 40, y: 200))
        employment = editor.addRelationshipType("Employment")
        ann = editor.addInstance("Ann", of: [person])
        acme = editor.addInstance("Acme", of: [company], at: CGPoint(x: 400, y: 400))
        job = editor.addBond(ann, acme, of: [employment])
        heard = RelationshipHeard(editor)
    }

    var index: RelationshipIndex { editor.relationships! }
    var graph: RelationshipGraph { index.graph }
}

@MainActor let relationshipIndexTests = Suite("What a commit changed in the relationships", [
    test("an arrow between a type and a relationship type, drawn, undone, redone, re-aimed and deleted, names its instances and the types whose notes gain or lose a row") {
        let s = try Scene()
        let before = s.index.revision, stamp = s.index.stamp(of: s.job)
        let end = s.editor.addBond(s.person, s.employment)
        let change = try require(s.heard.last)
        expect(change.arrows.isSuperset(of: [end, s.job]), "the end, and the instances of Employment: their fit")
        expect(change.layout.contains(s.person), "Person's notes gain a row")
        expect(s.index.revision > before)
        expect(s.index.stamp(of: end) > stamp, "the end's stamp moved")
        s.editor.undo()
        expect(try require(s.heard.last).arrows.isSuperset(of: [end, s.job]) && s.heard.last?.layout.contains(s.person) == true)
        expectEqual(s.graph.sides(of: s.employment), RelationshipSides(), "undone")
        s.editor.redo()
        expectEqual(s.graph.sides(of: s.employment).from.map(\.carrier), [end])
        // Re-aimed at Company.
        s.editor.transact { $0.update(end, as: Bond.self) { $0.props.from = s.company } }
        let aimed = try require(s.heard.last)
        expect(aimed.arrows.isSuperset(of: [end, s.job]) && aimed.layout.isSuperset(of: [s.person, s.company]))
        expectEqual(s.graph.sides(of: s.employment).from.map(\.type), [s.company])
        s.editor.undo()
        expectEqual(s.graph.sides(of: s.employment).from.map(\.type), [s.person])
        // Deleted.
        s.editor.transact { $0.delete([end]) }
        expect(try require(s.heard.last).arrows.isSuperset(of: [end, s.job]) && s.heard.last?.layout.contains(s.person) == true)
        expectEqual(s.graph.sides(of: s.employment), RelationshipSides())
        s.editor.undo()
        expectEqual(s.graph.sides(of: s.employment).from.map(\.carrier), [end])
    },
    test("an end's words change a row's name and no row's count: its instances are not named, and the row's place and name stay the row's") {
        let s = try Scene()
        let end = s.editor.addBond(s.person, s.employment)
        let before = s.index.revision
        s.editor.transact { $0.update(end, as: Bond.self) { $0.props.text = MentionText(plain: "employer") } }
        let change = try require(s.heard.last)
        expect(change.rows && change.layout.isEmpty, "a renamed row: a redraw")
        expect(change.arrows.contains(end) && !change.arrows.contains(s.job), "the end itself, and none of the instances")
        expect(s.index.revision > before)
        expectEqual(s.graph.rows(for: [s.person], isType: false).map(\.key.label), [.typed("employer")])
        // A keystroke more is a redraw as well.
        s.editor.transact { $0.update(end, as: Bond.self) { $0.props.text = MentionText(plain: "employers") } }
        expect(s.heard.last?.rows == true && s.heard.last?.arrows.contains(s.job) == false)
        // Two ends of one side that share a name become one row: the count changes, so the type is laid out.
        let other = s.editor.addType(TypeSchemaProperty.starter, title: "Agency", at: CGPoint(x: 400, y: 600))
        s.editor.addBond(other, s.employment, name: "agent")
        expectEqual(s.graph.rows(for: [other], isType: false).count, 1)
        s.editor.undo()
        expect(s.graph.rows(for: [other], isType: false).isEmpty)
        // A rule is part of an end: the same.
        s.editor.transact { $0.update(end) { $0[RelationshipEndProperty.self] = EndRule(needed: true, onlyOne: false) } }
        expectEqual(s.graph.sides(of: s.employment).from.first?.rule, EndRule(needed: true, onlyOne: false))
        expect(s.heard.last?.arrows.contains(s.job) == false, "a rule alone names no instance")
    },
    test("a flip of the mark with no end drawn names the instances of the type and what is bound to it with a free end, and undo does as much") {
        let s = try Scene()
        let mentor = s.editor.addType(TypeSchemaProperty.starter, title: "Mentor", at: CGPoint(x: 800, y: 40))
        let instance = s.editor.addBond(s.ann, s.acme, of: [mentor])
        let loose = s.editor.addBond(mentor, nil)
        let before = s.index.revision
        s.editor.transact { $0.update(mentor) { $0[RelationshipProperty.self] = true } }
        let change = try require(s.heard.last)
        expect(change.arrows.isSuperset(of: [instance, loose]), "the instances, and the loose end that is a function of the mark")
        expect(s.index.revision > before)
        expect(s.graph.isRelationshipType(mentor))
        s.editor.undo()
        expect(try require(s.heard.last).arrows.isSuperset(of: [instance, loose]), "and back")
        expect(!s.graph.isRelationshipType(mentor))
    },
    test("a type unmarked, and the last relationship type gone, take every end with them, and an undo brings them back") {
        let s = try Scene()
        let end = s.editor.addBond(s.person, s.employment)
        s.editor.addBond(s.employment, s.company)
        expect(s.index.isActive)
        s.editor.transact { $0.update(s.employment) { $0[RelationshipProperty.self] = nil } }
        let change = try require(s.heard.last)
        expect(change.arrows.isSuperset(of: [end, s.job]) && change.layout.isSuperset(of: [s.person, s.company]), "\(change)")
        expect(!s.index.isActive)
        expect(s.index.end(end) == nil)
        expectEqual(s.graph.rows(for: [s.person], isType: false), [])
        expectEqual(s.graph.sides(of: s.employment), RelationshipSides())
        s.editor.undo()
        expect(s.index.isActive && s.index.end(end) != nil)
        expectEqual(s.graph.rows(for: [s.person], isType: false).count, 1)
        // Deleted outright: the ends are free, and the index is idle.
        s.editor.transact { $0.delete([s.employment]) }
        expect(!s.index.isActive && s.index.end(end) == nil)
        expect(try require(s.heard.last).layout.contains(s.person))
        s.editor.undo()
        expect(s.index.isActive && s.index.end(end) != nil, "undone")
    },
    test("a type's own list changed, a lineage edit, moves every row its instances read from: the types and their instances are named") {
        let s = try Scene()
        s.editor.addBond(s.person, s.employment)
        let employee = s.editor.addType(TypeSchemaProperty.starter, title: "Employee", at: CGPoint(x: 400, y: 600))
        let bo = s.editor.addInstance("Bo", of: [employee])
        let before = s.index.revision
        expectEqual(s.graph.rows(for: [employee], isType: false), [])
        s.editor.addTypeLink(s.person, to: employee)
        let change = try require(s.heard.last)
        expect(s.index.revision > before)
        expect(change.layout.contains(employee) && change.notes.contains(bo) && change.arrows.contains(s.job), "\(change)")
        expectEqual(s.graph.rows(for: [employee], isType: false).count, 1)
        expectEqual(s.index.rows(for: [employee], isType: false).count, 1, "the memo of the rows follows the revision")
        s.editor.undo()
        expect(s.heard.last?.layout.contains(employee) == true)
        expectEqual(s.index.rows(for: [employee], isType: false), [])
    },
    test("a note that becomes a type, or stops being one, turns the arrows at it into ends, or back into plain ones") {
        let s = try Scene()
        let draft = s.editor.addInstance("Draft", of: [], at: CGPoint(x: 800, y: 40))
        let bond = s.editor.addBond(draft, s.employment)
        expect(s.index.end(bond) == nil, "a note and a relationship type: plain")
        s.editor.makeType(draft)
        expect(s.heard.last?.arrows.contains(bond) == true)
        expectEqual(s.index.end(bond)?.type, s.employment)
        expectEqual(s.graph.sides(of: s.employment).from.map(\.type), [draft])
        s.editor.removeType(draft)
        expect(s.index.end(bond) == nil && s.graph.sides(of: s.employment).isEmpty)
        s.editor.undo()
        expect(s.index.end(bond) != nil)
        // A type at an end that becomes a relationship type: the end is a plain arrow between two.
        s.editor.transact { $0.update(draft) { $0[RelationshipProperty.self] = true } }
        expect(s.index.end(bond) == nil && s.graph.sides(of: s.employment).isEmpty)
        s.editor.undo()
        expect(s.index.end(bond) != nil, "unmarked again")
    },
    test("an end edited on a board that is not shown is read as it is, and the board's own ends are the file's") {
        let p = ShapeID(), person = ShapeID(), employment = ShapeID(), bond = ShapeID()
        var related = slipTypeRecord(TypeSchemaProperty.starter, title: "Employment", id: employment)
        related[RelationshipProperty.self] = true
        let pocket = AnyShapeRecord(ShapeRecord(id: p, Pocket(CGRect(x: 0, y: 500, width: 100, height: 100))))
        let file = CanvasFile(root: CanvasDocument(shapes: [pocket]),
                              children: [p: CanvasDocument(shapes: [slipTypeRecord(TypeSchemaProperty.starter, title: "Person", id: person), related,
                                                                    AnyShapeRecord(ShapeRecord(id: bond, Bond(from: person, to: employment)))])])
        let editor = try bondEditor(file: file)
        let index = try require(editor.relationships)
        let heard = RelationshipHeard(editor)
        expectEqual(index.graph.sides(of: employment).from.map(\.carrier), [bond], "read as the file opened, on a board not shown")
        editor.transact(on: BoardID(owner: p), "Rename") { $0.update(bond, as: Bond.self) { $0.props.text = MentionText(plain: "employer") } }
        expectEqual(index.graph.sides(of: employment).from.first?.name, "employer")
        expect(heard.last?.rows == true, "\(String(describing: heard.last))")
        editor.transact(on: BoardID(owner: p), "Delete") { $0.delete([bond]) }
        expectEqual(index.graph.sides(of: employment), RelationshipSides())
        expect(heard.last?.arrows.contains(bond) == true && heard.last?.layout.contains(person) == true)
        editor.undo()
        expectEqual(index.graph.sides(of: employment).from.first?.name, "employer", "undone, on the board it was on")
    },
    test("a relationship type moved alone to another board loses its end arrows' end, and the move undone gives it back") {
        let s = try Scene()
        let p = ShapeID()
        s.editor.transact { $0.insert(AnyShapeRecord(ShapeRecord(id: p, Pocket(CGRect(x: 0, y: 900, width: 100, height: 100))))) }
        let end = s.editor.addBond(s.person, s.employment)
        expectEqual(s.index.end(end)?.type, s.employment)
        s.editor.transact("Move") { $0.move([s.employment], toBoardOwnedBy: p) }
        let change = try require(s.heard.last)
        expect(s.index.end(end) == nil, "the arrow's end on Employment is let go: it is free")
        expectEqual(s.graph.sides(of: s.employment), RelationshipSides())
        expect(change.arrows.contains(end) && change.layout.contains(s.person), "\(change)")
        s.editor.undo()
        expectEqual(s.index.end(end)?.type, s.employment)
        expectEqual(s.graph.sides(of: s.employment).from.map(\.type), [s.person])
    },
    test("a pill re-pointed, or made open or private, is read through at once: the type behind it counts whether or not it reads through") {
        let s = try Scene()
        let pill = s.editor.addRelay(standingFor: [s.person], says: "Person")
        let end = s.editor.addBond(pill, s.employment)
        expectEqual(s.index.end(end)?.type, s.employment)
        expectEqual(s.graph.sides(of: s.employment).from.map(\.type), [s.person], "a pill that is not open")
        let before = s.index.revision
        s.editor.open(s.person)
        s.editor.transact { $0.update(s.person) { $0.meta[Open.self] = nil } }
        expectEqual(s.graph.sides(of: s.employment).from.map(\.type), [s.person], "made private: the side does not widen")
        // Re-pointed at a note that is no type: the arrow is no end.
        s.editor.transact { $0.update(pill, as: Relay.self) { $0.props.stands = [Citation(s.ann)] } }
        expect(s.index.end(end) == nil && s.graph.sides(of: s.employment).isEmpty, "a pill for a note is no end")
        expect(s.index.revision > before)
        expect(try require(s.heard.last).layout.contains(s.person) && s.heard.last?.arrows.contains(end) == true, "\(String(describing: s.heard.last))")
        s.editor.undo()
        expectEqual(s.graph.sides(of: s.employment).from.map(\.type), [s.person])
        // The pill deleted: the arrow's end is free.
        s.editor.transact { $0.delete([pill]) }
        expect(s.graph.sides(of: s.employment).isEmpty)
    },
    test("a drag, a switch of board, an idle file and a keystroke below any rule tell nobody; a file put in place tells everything") {
        let s = try Scene()
        let p = ShapeID()
        s.editor.transact { $0.insert(AnyShapeRecord(ShapeRecord(id: p, Pocket(CGRect(x: 0, y: 900, width: 100, height: 100))))) }
        s.editor.addBond(s.person, s.employment)
        let count = s.heard.changes.count, revision = s.index.revision
        s.editor.transact { transaction in
            for id in [s.person, s.ann, s.acme] { transaction.update(id, as: Memo.self) { $0.props.frame.origin.x += 7 } }
        }
        expectEqual(s.heard.changes.count, count, "a move tells nothing")
        s.editor.transact { $0.update(s.ann, as: Memo.self) { $0.props.text = MentionText(plain: "Ann Lee") } }
        expectEqual(s.heard.changes.count, count, "a note's words tell nothing")
        _ = s.editor.showBoard(BoardID(owner: p))
        _ = s.editor.showBoard(.root)
        expectEqual(s.heard.changes.count, count, "a switch tells nothing")
        expectEqual(s.index.revision, revision)
        s.editor.replaceFile(with: CanvasFile(root: CanvasDocument()), showing: .root)
        expectEqual(s.heard.last?.everything, true)
        expect(!s.index.isActive)
        // An idle file.
        let idle = try bondEditor()
        let index = try require(idle.relationships)
        let heard = RelationshipHeard(idle)
        let id = idle.addInstance("a note", of: [])
        idle.addBond(id, id)
        idle.transact { $0.update(id, as: Memo.self) { $0.props.text = MentionText(plain: "more") } }
        expect(!index.isActive)
        expect(heard.changes.isEmpty, "nothing told in a file with no relationship type")
    },
    test("a relating arrow is named by the kind that holds endRule, not by a family: a bond outside any family is still an end") {
        let w = try bondEditor()
        let person = w.addType(TypeSchemaProperty.starter, title: "Person"), employment = w.addRelationshipType("Employment")
        let bond = w.addBond(person, employment)
        let registry = w.registry
        expect(registry.relates(Bond.kind) && !registry.relates(Memo.kind))
        expectEqual(w.relationships?.end(bond)?.side, .from)
    },
    test("a pill that is not admitted keeps its end through the deletion of its type and the undo, and a file opened again reads the same ends") {
        let s = try Scene()
        let pill = s.editor.addRelay(standingFor: [s.person], says: "Person")
        let end = s.editor.addBond(pill, s.employment)
        expectEqual(s.graph.sides(of: s.employment).from.map(\.type), [s.person], "before")
        s.editor.transact { $0.delete([s.person]) }
        expectEqual(s.graph.sides(of: s.employment).from.map(\.type), [], "deleted")
        s.editor.undo()
        expectEqual(s.graph.sides(of: s.employment).from.map(\.type), [s.person], "undone: the file is as it was")
        expectEqual(s.index.end(end)?.type, s.employment)
        let reopened = try require(try bondEditor(file: s.editor.file).relationships)
        expectEqual(reopened.end(end)?.type, s.employment, "the same file opened again")
        expectEqual(reopened.graph.sides(of: s.employment), s.graph.sides(of: s.employment))
    },
    test("an arrow into a pill that is not admitted, for the relationship type itself, is an end of it as drawn and as opened") {
        let s = try Scene()
        let pill = s.editor.addRelay(standingFor: [s.employment], says: "Employment")
        let end = s.editor.addBond(s.person, pill)
        expectEqual(s.index.end(end)?.type, s.employment, "drawn in this session")
        expectEqual(s.graph.sides(of: s.employment).from.map(\.type), [s.person])
        let reopened = try require(try bondEditor(file: s.editor.file).relationships)
        expectEqual(reopened.end(end)?.type, s.employment, "the same file opened again")
        expectEqual(reopened.graph.sides(of: s.employment).from.map(\.type), [s.person], "the same ends")
    },
    test("a pill that is not admitted turns its arrow into an end when its note becomes a type, and when its type is marked") {
        let s = try Scene()
        let draft = s.editor.addInstance("Draft", of: [], at: CGPoint(x: 800, y: 40))
        let draftPill = s.editor.addRelay(standingFor: [draft], says: "Draft")
        let fromDraft = s.editor.addBond(draftPill, s.employment)
        expect(s.index.end(fromDraft) == nil)
        s.editor.makeType(draft)
        expectEqual(s.index.end(fromDraft)?.type, s.employment, "the pill names a type now")
        s.editor.undo()
        expect(s.index.end(fromDraft) == nil)
        // A pill for a plain type; the type is marked, and the arrow between it and Person is an end of it.
        let plain = s.editor.addType(TypeSchemaProperty.starter, title: "Mentor", at: CGPoint(x: 800, y: 300))
        let plainPill = s.editor.addRelay(standingFor: [plain], says: "Mentor")
        let toPill = s.editor.addBond(s.person, plainPill)
        expect(s.index.end(toPill) == nil, "between two types: plain")
        s.editor.transact { $0.update(plain) { $0[RelationshipProperty.self] = true } }
        expectEqual(s.index.end(toPill)?.type, plain, "the pill now names a relationship type")
        s.editor.undo()
        expect(s.index.end(toPill) == nil)
    },
    test("a relationship type unmarked and marked again while an arrow runs into a pill for it that is not admitted keeps that end, and so does the undo of each") {
        let s = try Scene()
        let pill = s.editor.addRelay(standingFor: [s.employment], says: "Employment")
        let end = s.editor.addBond(s.person, pill)
        let ends = s.graph.sides(of: s.employment)
        expectEqual(s.index.end(end)?.type, s.employment, "drawn into a pill that is not admitted")
        expectEqual(ends.from.map(\.carrier), [end])
        s.editor.transact { $0.update(s.employment) { $0[RelationshipProperty.self] = nil } }
        expect(s.index.end(end) == nil, "unmarked: the pill names a plain type")
        s.editor.transact { $0.update(s.employment) { $0[RelationshipProperty.self] = true } }
        expectEqual(s.index.end(end)?.type, s.employment, "marked again: the end is back, though the pill reads through to nothing")
        expectEqual(s.graph.sides(of: s.employment), ends)
        expect(try require(s.heard.last).arrows.contains(end), "and the arrow was named")
        s.editor.undo()
        expect(s.index.end(end) == nil, "the mark taken off again")
        s.editor.undo()
        expectEqual(s.index.end(end)?.type, s.employment, "the first unmark undone")
        expectEqual(s.graph.sides(of: s.employment), ends)
        let reopened = try require(try bondEditor(file: s.editor.file).relationships)
        expectEqual(reopened.graph.sides(of: s.employment), ends, "the file opened again reads the same")
    },
    test("a relationship type on a board not shown, with its pill and bond, keeps the end it reads through the deletion of the type behind it and its undo, open or private") {
        let p = ShapeID(), person = ShapeID(), employment = ShapeID(), pill = ShapeID(), bond = ShapeID()
        var related = slipTypeRecord(TypeSchemaProperty.starter, title: "Employment", id: employment)
        related[RelationshipProperty.self] = true
        var personRecord = slipTypeRecord(TypeSchemaProperty.starter, title: "Person", id: person)
        personRecord.meta[Open.self] = true
        let pocket = AnyShapeRecord(ShapeRecord(id: p, Pocket(CGRect(x: 0, y: 500, width: 100, height: 100))))
        let relay = AnyShapeRecord(ShapeRecord(id: pill, Relay(CGRect(x: 40, y: 700, width: 100, height: 32), stands: [person], says: "Person")))
        let file = CanvasFile(root: CanvasDocument(shapes: [pocket, personRecord]),
                              children: [p: CanvasDocument(shapes: [related, relay, AnyShapeRecord(ShapeRecord(id: bond, Bond(from: pill, to: employment)))])])
        let editor = try bondEditor(file: file)
        let index = try require(editor.relationships)
        expectEqual(index.graph.sides(of: employment).from.map(\.type), [person], "as opened")
        editor.transact { $0.delete([person]) }
        expectEqual(index.graph.sides(of: employment).from.map(\.type), [], "the type behind the pill is gone")
        editor.undo()
        expectEqual(index.graph.sides(of: employment).from.map(\.type), [person], "and back")
        editor.transact { $0.update(person) { $0.meta[Open.self] = nil } }
        expectEqual(index.graph.sides(of: employment).from.map(\.type), [person], "made private: the pill is not admitted")
        editor.transact { $0.delete([person]) }
        expectEqual(index.graph.sides(of: employment).from.map(\.type), [], "gone while private")
        editor.undo()
        expectEqual(index.graph.sides(of: employment).from.map(\.type), [person], "back while private")
    },
    test("a relationship type deleted and brought back by undo keeps an end that is a pill for the type at its other end") {
        let s = try Scene()
        let pill = s.editor.addRelay(standingFor: [s.person], says: "Person")
        let end = s.editor.addBond(pill, s.employment)
        s.editor.transact { $0.delete([s.employment]) }
        expect(s.index.end(end) == nil)
        s.editor.undo()
        expectEqual(s.index.end(end)?.type, s.employment)
        expectEqual(s.graph.sides(of: s.employment).from.map(\.type), [s.person])
    },
    test("a pill re-pointed from one type to another, or at the relationship type it is an end of, is read again, open or not, and undone") {
        for open in [true, false] {
            let s = try Scene()
            if open { s.editor.open(s.person); s.editor.open(s.company) }
            let pill = s.editor.addRelay(standingFor: [s.person], says: "Person")
            let end = s.editor.addBond(pill, s.employment)
            expectEqual(s.graph.sides(of: s.employment).from.map(\.type), [s.person])
            s.editor.transact { $0.update(pill, as: Relay.self) { $0.props.stands = [Citation(s.company)] } }
            expectEqual(s.graph.sides(of: s.employment).from.map(\.type), [s.company], "re-pointed")
            expect(s.heard.last?.arrows.contains(end) == true)
            s.editor.undo()
            expectEqual(s.graph.sides(of: s.employment).from.map(\.type), [s.person], "undone")
            s.editor.transact { $0.update(pill, as: Relay.self) { $0.props.stands = [Citation(s.employment)] } }
            expect(s.index.end(end) == nil, "a pill for the relationship type: both ends are relationship types")
            expectEqual(s.graph.sides(of: s.employment), RelationshipSides())
            s.editor.undo()
            expectEqual(s.index.end(end)?.type, s.employment)
            s.editor.transact { $0.delete([s.person]) }
            expectEqual(s.graph.sides(of: s.employment).from.map(\.type), [], "target deleted")
            s.editor.undo()
            expectEqual(s.graph.sides(of: s.employment).from.map(\.type), [s.person], "target back")
        }
    },
    test("unmarking one of two relationship types makes the arrow between them an end of the other, and the undo gives it back") {
        let s = try Scene()
        let mentor = s.editor.addRelationshipType("Mentor", at: CGPoint(x: 800, y: 40))
        let bond = s.editor.addBond(s.employment, mentor)
        expect(s.index.end(bond) == nil, "between two relationship types")
        s.editor.transact { $0.update(mentor) { $0[RelationshipProperty.self] = nil } }
        expectEqual(s.index.end(bond)?.type, s.employment)
        expectEqual(s.graph.sides(of: s.employment).to.map(\.type), [mentor])
        expect(s.heard.last?.arrows.contains(bond) == true)
        s.editor.undo()
        expect(s.index.end(bond) == nil)
        expectEqual(s.graph.sides(of: s.employment), RelationshipSides())
    },
    test("a relating arrow given an is list is named, with the stamps of its ends; a note's list names the connections at it") {
        let s = try Scene()
        let plain = s.editor.addBond(s.ann, s.acme)
        let stamp = s.index.stamp(of: plain), annStamp = s.index.stamp(of: s.ann), acmeStamp = s.index.stamp(of: s.acme)
        s.editor.addTypeLink(s.employment, to: plain)
        expect(s.heard.last?.arrows.contains(plain) == true, "\(String(describing: s.heard.last))")
        expect(s.index.stamp(of: plain) > stamp)
        expect(s.index.stamp(of: s.ann) > annStamp && s.index.stamp(of: s.acme) > acmeStamp, "its two ends' stamps")
        let before = s.index.stamp(of: s.job)
        s.editor.removeTypeLink(s.person, from: s.ann)
        expect(s.index.stamp(of: s.job) > before, "the connection at a note whose list changed")
        expect(s.heard.last?.arrows.contains(s.job) == true)
    },
    test("a plain arrow at a note that becomes a type is named, though it is no end before or after") {
        let s = try Scene()
        let draft = s.editor.addInstance("Draft", of: [], at: CGPoint(x: 800, y: 40))
        let plain = s.editor.addBond(draft, s.ann)
        s.editor.makeType(draft)
        expect(s.heard.last?.arrows.contains(plain) == true, "its end is a type now, so its role is another: \(String(describing: s.heard.last))")
        expect(s.index.end(plain) == nil)
        s.editor.undo()
        expect(s.heard.last?.arrows.contains(plain) == true)
    },
    test("an end type renamed or its schema typed announces the rows only when it is an end") {
        let s = try Scene()
        s.editor.addBond(s.person, s.employment)
        let count = s.heard.changes.count
        s.editor.transact { $0.update(s.company) { $0[TitleProperty.self] = "Firm" } }
        expectEqual(s.heard.changes.count, count, "Company is no end: nobody told")
        s.editor.transact { $0.update(s.person) { $0[TitleProperty.self] = "Human" } }
        expect(s.heard.last?.rows == true, "Person is an end")
    },
    test("a note related to itself has the one arrow once") {
        let s = try Scene()
        s.editor.addBond(s.person, s.employment)
        s.editor.addBond(s.employment, s.person)
        let loop = s.editor.addBond(s.ann, s.ann, of: [s.employment])
        expectEqual(s.index.relations(of: s.ann).filter { $0.arrow == loop }.count, 1)
    },
    test("a rename that gives a type the row of the type it builds on takes a row from its notes and lays them out") {
        let s = try Scene()
        let employee = s.editor.addType(TypeSchemaProperty.starter, title: "Employee", at: CGPoint(x: 400, y: 600))
        s.editor.addTypeLink(s.person, to: employee)
        s.editor.addInstance("Bo", of: [employee])
        s.editor.addBond(s.person, s.employment, name: "x")
        let own = s.editor.addBond(employee, s.employment, name: "y")
        expectEqual(s.graph.rows(for: [employee], isType: false).count, 2)
        s.editor.transact { $0.update(own, as: Bond.self) { $0.props.text = MentionText(plain: "x") } }
        expectEqual(s.graph.rows(for: [employee], isType: false).count, 1, "the more specific type's row replaces the general one's")
        let change = try require(s.heard.last)
        expect(change.layout.contains(employee), "Bo's rows went from two to one: \(change)")
    },
    test("a list changed on a shape that is no type, with instances, names them: the chain runs through it") {
        let s = try Scene()
        s.editor.addBond(s.person, s.employment)
        let employee = s.editor.addType(TypeSchemaProperty.starter, title: "Employee", at: CGPoint(x: 400, y: 600))
        s.editor.addTypeLink(s.person, to: employee)
        let bo = s.editor.addInstance("Bo", of: [employee])
        expectEqual(s.graph.rows(for: [employee], isType: false).count, 1)
        s.editor.removeType(employee)
        expect(!s.editor.types!.isType(employee))
        s.editor.removeTypeLink(s.person, from: employee)
        expectEqual(s.graph.rows(for: [employee], isType: false).count, 0, "Employee builds on nothing now")
        expect(s.heard.last?.notes.contains(bo) == true, "Bo's rows moved: \(String(describing: s.heard.last))")
    },
    test("a deleted shape that held an is list keeps no stamp") {
        let s = try Scene()
        let floor = s.index.stamp(of: ShapeID())
        s.editor.transact { $0.delete([s.ann]) }
        expectEqual(s.index.stamp(of: s.ann), floor, "a deleted note")
        let end = s.editor.addBond(s.person, s.employment)
        s.editor.transact { $0.delete([s.job, end]) }
        expectEqual(s.index.stamp(of: s.job), floor, "a deleted relating arrow")
        expectEqual(s.index.stamp(of: end), floor, "a deleted end")
    },
    test("many relationship types made in one commit on a big board cost one pass over its arrows, not one for each") {
        let editor = try bondEditor()
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person")
        var shapes: [AnyShapeRecord] = []
        for i in 0..<3000 { shapes.append(instanceRecord("n\(i)", of: [person], at: CGPoint(x: Double(i % 100) * 10, y: 400 + Double(i / 100) * 10))) }
        let notes = shapes.map(\.id)
        for i in 0..<1500 { shapes.append(AnyShapeRecord(ShapeRecord(id: ShapeID(), Bond(from: notes[i], to: nil)))) }
        editor.transact { t in for r in shapes { t.insert(r) } }
        @MainActor func marked(_ count: Int, from first: Int) -> [AnyShapeRecord] {
            (0..<count).map { i in
                var r = slipTypeRecord(TypeSchemaProperty.starter, title: "R\(first + i)", at: CGPoint(x: 2000 + Double(first + i) * 10, y: 40))
                r[RelationshipProperty.self] = true
                return r
            }
        }
        let one = marked(1, from: 0), many = marked(100, from: 1)
        let single = threadCPUTime { editor.transact { t in for r in one { t.insert(r) } } }
        let batch = threadCPUTime { editor.transact { t in for r in many { t.insert(r) } } }
        expect(batch < single * 25, "100 marked types in one commit took \(batch), one took \(single)")
    },
])

// MARK: Reading an end through a pill

@MainActor let relationshipFarTests = Suite("Reading an end", [
    test("a shape is itself, a bond's free end is free, and a shape that is not there is free") {
        let w = try bondEditor()
        let ann = w.addInstance("Ann", of: [])
        let index = try require(w.relationships)
        expectEqual(index.reading(ofEnd: ann), .note(ann))
        expectEqual(index.reading(ofEnd: ShapeID()), .free)
        expectEqual(ReadEnd(literal: ann, reading: .note(ann)).via, nil)
        expectEqual(ReadEnd(literal: nil, reading: .free).via, nil)
    },
    test("a pill is the shape it names while it is open; not admitted, with the word the kind needs; gone, with the name it kept") {
        let w = try bondEditor()
        let acme = w.addInstance("Acme", of: [])
        let pill = w.addRelay(standingFor: [acme], says: "Acme Corp")
        let index = try require(w.relationships)
        expectEqual(index.reading(ofEnd: pill), .notAdmitted(acme, needs: "open"))
        w.open(acme)
        expectEqual(index.reading(ofEnd: pill), .note(acme))
        expectEqual(ReadEnd(literal: pill, reading: index.reading(ofEnd: pill)).via, pill, "read through the pill")
        w.undo()
        expectEqual(index.reading(ofEnd: pill), .notAdmitted(acme, needs: "open"), "undone")
        w.open(acme)
        w.transact { $0.delete([acme]) }
        expectEqual(index.reading(ofEnd: pill), .gone(called: "Acme Corp"))
        w.undo()
        expectEqual(index.reading(ofEnd: pill), .note(acme))
    },
    test("a pill that finds shapes is a query, one that stands for nothing is empty, and each says what it was called") {
        let w = try bondEditor()
        let a = w.addInstance("A", of: []), b = w.addInstance("B", of: [])
        w.open(a)
        w.open(b)
        let index = try require(w.relationships)
        let both = w.addRelay(standingFor: [a, b], says: "every pet")
        expectEqual(index.reading(ofEnd: both), .query(called: "every pet"))
        expectEqual(index.reading(ofEnd: w.addRelay(standingFor: [])), .empty)
        expectEqual(index.reading(ofEnd: w.addRelay(standingFor: [a, a])), .note(a), "one shape named twice is one")
        expectEqual(ReadEnd(literal: both, reading: index.reading(ofEnd: both)).via, both)
    },
    test("a relationship that ends on a pill is read through it from the near note and plain from the far one") {
        let w = try bondEditor()
        let person = w.addType(TypeSchemaProperty.starter, title: "Person"), company = w.addType(TypeSchemaProperty.starter, title: "Company", at: CGPoint(x: 400, y: 40))
        let employment = w.addRelationshipType("Employment", at: CGPoint(x: 200, y: 40))
        w.addBond(person, employment)
        w.addBond(employment, company)
        let ann = w.addInstance("Ann", of: [person]), acme = w.addInstance("Acme", of: [company], at: CGPoint(x: 400, y: 400))
        w.open(acme)
        let pill = w.addRelay(standingFor: [acme], says: "Acme")
        let job = w.addBond(ann, pill, of: [employment])
        let index = try require(w.relationships)
        expectEqual(index.relations(of: ann), [Relation(arrow: job, type: employment, side: .from, far: ReadEnd(literal: pill, reading: .note(acme)))])
        expectEqual(index.relations(of: acme).map(\.far), [ReadEnd(literal: ann, reading: .note(ann))], "the near note is plain on the far note's row")
        expectEqual(index.relations(of: acme).map(\.side), [.to])
        // The note goes private again: the far note sees nothing, the near note a dashed pill.
        w.transact { $0.update(acme) { $0.meta[Open.self] = nil } }
        expectEqual(index.relations(of: ann).map(\.far.reading), [.notAdmitted(acme, needs: "open")])
        expect(index.relations(of: acme).isEmpty)
        // The reading of the connection says the same.
        expectEqual(index.subjects(of: job)?.to.reading, .notAdmitted(acme, needs: "open"))
    },
    test("a pill for a note on a board the editor cannot show is unavailable, and says what it was called") {
        let source = try bondEditor()
        let p = ShapeID()
        let hidden = instanceRecord("Hidden", of: [])
        let pill = ShapeID()
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: p, Pocket(CGRect(x: 0, y: 500, width: 100, height: 100)))),
                                                           AnyShapeRecord(ShapeRecord(id: pill, Relay(CGRect(x: 40, y: 700, width: 100, height: 32), stands: [hidden.id], says: "Hidden Co")))]),
                              children: [p: CanvasDocument(shapes: [hidden])])
        // The owner of the board is of a kind this app does not have.
        let text = try require(String(data: BoardCodec(registry: source.registry).encode(file), encoding: .utf8))
        let data = Data(text.replacingOccurrences(of: "\"pocket\"", with: "\"gadget\"").utf8)
        let reopened = try bondEditor(file: BoardCodec(registry: source.registry).decode(data).file)
        let index = try require(reopened.relationships)
        expectEqual(reopened.topology?.end(hidden.id), .unavailable)
        expectEqual(index.reading(ofEnd: pill), .unavailable(called: "Hidden Co"))
    },
])

// MARK: A bond drawn by a script

@MainActor let bondDrawTests = Suite("A bond drawn by a script", [
    test("a script's edge between a type and a relationship type is an end of it, as any arrow would be") {
        let editor = try typeEditorWithDraw()
        let script = """
        memo "Person" schema: "{\\"type\\": \\"object\\", \\"properties\\": {}}"
        memo "Employment" right of "Person" schema: "{\\"type\\": \\"object\\", \\"properties\\": {}}" relationship: true
        edge "Person" -> "Employment"
        """
        try drawScript(script, on: editor)
        let bond = try require(editor.document.shapes.first { $0.typed(as: Bond.self) != nil })
        let relationships = try require(editor.relationships)
        expectEqual(relationships.end(bond.id)?.side, .from)
        expect(relationships.graph.sides(of: try require(relationships.end(bond.id)).type).from.count == 1)
    },
    test("an edge's endRule is written member by member: a statement sets the members it names and keeps the rest") {
        let editor = try typeEditorWithDraw()
        try drawScript("""
        memo "Person" schema: "{\\"type\\": \\"object\\", \\"properties\\": {}}"
        memo "Employment" right of "Person" schema: "{\\"type\\": \\"object\\", \\"properties\\": {}}" relationship: true
        edge "Person" -> "Employment" endRule: {"needed": true}
        """, on: editor)
        let bond = try require(editor.document.shapes.first { $0.typed(as: Bond.self) != nil })
        expectEqual(bond[RelationshipEndProperty.self], EndRule(needed: true, onlyOne: false))
        try drawScript(#"edge "Person" -> "Employment" endRule: {"onlyOne": true}"#, on: editor)
        expectEqual(editor.document[bond.id]?[RelationshipEndProperty.self], EndRule(needed: true, onlyOne: true), "Only one joined Needed")
        expectEqual(editor.document.shapes.filter { $0.typed(as: Bond.self) != nil }.count, 1, "the same edge")
        try drawScript(#"edge "Person" -> "Employment" endRule: {"needed": null}"#, on: editor)
        expectEqual(editor.document[bond.id]?[RelationshipEndProperty.self], EndRule(needed: false, onlyOne: true), "null takes a member away")
        expectEqual(try require(editor.relationships).graph.sides(of: try require(editor.relationships?.end(bond.id)).type).from.first?.rule, EndRule(needed: false, onlyOne: true))
    },
    test("a script's mark and rule are cleared by false, null and both members false; a rule on a kind that holds none is refused") {
        let editor = try typeEditorWithDraw()
        try drawScript("""
        memo "Person" schema: "{\\"type\\": \\"object\\", \\"properties\\": {}}"
        memo "Employment" right of "Person" schema: "{\\"type\\": \\"object\\", \\"properties\\": {}}" relationship: true
        """, on: editor)
        let employment = try require(editor.document.shapes.first { $0[RelationshipProperty.self] == true })
        try drawScript(#"memo "Employment" relationship: false"#, on: editor)
        expectEqual(editor.document[employment.id]?[RelationshipProperty.self], nil, "false is none")
        try drawScript(#"memo "Employment" relationship: true"#, on: editor)
        try drawScript(#"memo "Employment" relationship: null"#, on: editor)
        expectEqual(editor.document[employment.id]?[RelationshipProperty.self], nil, "null is none")
        try drawScript(#"edge "Person" -> "Employment" endRule: {"needed": false, "onlyOne": false}"#, on: editor)
        let bond = try require(editor.document.shapes.first { $0.typed(as: Bond.self) != nil })
        expectEqual(bond[RelationshipEndProperty.self], nil, "both false is none")
        try drawScript(#"edge "Person" -> "Employment" endRule: {"needed": true}"#, on: editor)
        try drawScript(#"edge "Person" -> "Employment" endRule: null"#, on: editor)
        expectEqual(editor.document[bond.id]?[RelationshipEndProperty.self], nil, "null clears")
        var refused = false
        do { try drawScript(#"memo "Person" endRule: {"needed": true}"#, on: editor) } catch { refused = true }
        expect(refused, "a memo does not relate")
    },
])

@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Foundation
import Mentions
import TestKit
import Titles
import Topology
import Types
import Validation

// The check of an arrow's ends as the service keeps it, and as Validation holds it: every change that can move a
// verdict moves it with no commit to the arrow, and the undo of the change moves it back. Over bonds.

/// Person, Company, Layer and Employment from a Person to a Company; Ann, Acme (a Company), `foundation` (a Layer),
/// and `job`, an Employment from Ann to Acme: a relationship that fits.
@MainActor private struct Scene {
    let editor: CanvasEditor
    let person: ShapeID, company: ShapeID, layer: ShapeID, employment: ShapeID
    let ann: ShapeID, acme: ShapeID, foundation: ShapeID, job: ShapeID

    init(more: [any CanvasPlugin] = []) throws {
        editor = try bondEditor(more: more)
        person = editor.addType(TypeSchemaProperty.starter, title: "Person", at: CGPoint(x: 40, y: 40))
        company = editor.addType(TypeSchemaProperty.starter, title: "Company", at: CGPoint(x: 40, y: 200))
        layer = editor.addType(TypeSchemaProperty.starter, title: "Layer", at: CGPoint(x: 40, y: 360))
        employment = editor.addRelationshipType("Employment")
        editor.addBond(person, employment)
        editor.addBond(employment, company)
        ann = editor.addInstance("Ann", of: [person], at: CGPoint(x: 500, y: 400))
        acme = editor.addInstance("Acme", of: [company], at: CGPoint(x: 800, y: 400))
        foundation = editor.addInstance("foundation", of: [layer], at: CGPoint(x: 800, y: 700))
        job = editor.addBond(ann, acme, of: [employment])
    }

    var checks: FieldChecks { editor.fieldChecks! }

    /// What the check says of a shape, in words, in order.
    func said(_ id: ShapeID) -> [String] { checks.fullCheck(of: editor.file.record(id)!).problems.map(\.message) }
    /// What Validation holds of it: errors and warnings.
    func kept(_ id: ShapeID) -> [String] { editor.issues(id).map(\.message) }

    /// The check and Validation say the same, and it is `expected`.
    func expectSaid(_ id: ShapeID, _ expected: [String], _ message: String = "") {
        expectEqual(said(id), expected, message)
        expectEqual(kept(id).sorted(), expected.sorted(), "Validation, \(message)")
    }
}

private let misfitAcme = "Employment runs to a Company. “Acme” has no type."

@MainActor let relationChecksServiceTests = Suite("The check of an arrow's ends, kept", [
    test("a fitting arrow says nothing; an end note that loses the type that fits it makes the arrow a misfit with no commit to the arrow, and the undo clears it") {
        let s = try Scene()
        s.expectSaid(s.job, [])
        let record = s.editor.document[s.job]
        s.editor.removeTypeLink(s.company, from: s.acme)
        s.expectSaid(s.job, [misfitAcme], "Acme is no Company now")
        expectEqual(s.editor.document[s.job], record, "the arrow was not written")
        let issue = try require(s.editor.issues(s.job).first)
        expectEqual(issue.severity, .error)
        expectEqual(issue.field, "to", "an error at the end")
        expectEqual(s.editor.validation?.result(for: s.job)?.isValid, false, "it rings")
        expect(s.editor.validation?.result(for: s.acme) == nil, "the note at the end has no issue")
        s.editor.undo()
        s.expectSaid(s.job, [])
        s.editor.redo()
        s.expectSaid(s.job, [misfitAcme])
        s.editor.addTypeLink(s.company, to: s.acme)
        s.expectSaid(s.job, [], "given the type back by hand")
    },
    test("a type that stops building on another, or starts, flips the arrows of the notes of the one that builds") {
        let s = try Scene()
        let employee = s.editor.addType(TypeSchemaProperty.starter, title: "Employee", at: CGPoint(x: 400, y: 40))
        let bo = s.editor.addInstance("Bo", of: [employee], at: CGPoint(x: 500, y: 700))
        let boJob = s.editor.addBond(bo, s.acme, of: [s.employment])
        s.expectSaid(boJob, ["Employment runs from a Person. “Bo” is an Employee."], "an Employee is no Person yet")
        s.editor.addTypeLink(s.person, to: employee)
        s.expectSaid(boJob, [], "it builds on Person")
        s.editor.removeTypeLink(s.person, from: employee)
        s.expectSaid(boJob, ["Employment runs from a Person. “Bo” is an Employee."])
        s.editor.undo()
        s.expectSaid(boJob, [])
        s.editor.undo()
        s.expectSaid(boJob, ["Employment runs from a Person. “Bo” is an Employee."])
    },
    test("an end drawn, deleted or re-aimed at the relationship type flips the arrows of the type, and the undo of each flips them back") {
        let s = try Scene()
        let misfit = s.editor.addBond(s.ann, s.foundation, of: [s.employment])
        let words = "Employment runs to a Company. “foundation” is a Layer."
        s.expectSaid(misfit, [words])
        let end = s.editor.addBond(s.employment, s.layer)
        s.expectSaid(misfit, [], "Layer is a side of Employment now")
        s.editor.undo()
        s.expectSaid(misfit, [words])
        s.editor.redo()
        s.editor.transact { $0.delete([end]) }
        s.expectSaid(misfit, [words], "the end deleted")
        s.editor.undo()
        s.expectSaid(misfit, [])
        s.editor.transact { $0.update(end, as: Bond.self) { $0.props.to = s.company } }
        s.expectSaid(misfit, [words], "the end re-aimed at Company: Layer is no side")
        s.expectSaid(s.job, [])
        s.editor.undo()
        s.expectSaid(misfit, [])
    },
    test("a relationship type unmarked or marked flips its arrows with no commit to them; the only one, unmarked, clears what its arrows said, and the undo says it again") {
        let s = try Scene()
        let free = s.editor.addBond(s.ann, nil, of: [s.employment])
        let misfit = s.editor.addBond(s.ann, s.foundation, of: [s.employment])
        s.expectSaid(free, ["Employment isn’t attached at both ends."])
        s.expectSaid(misfit, ["Employment runs to a Company. “foundation” is a Layer."])
        expect(!(s.editor.relationships?.graph.types.relationshipTypes.isEmpty ?? true))
        s.editor.transact { $0.update(s.employment) { $0[RelationshipProperty.self] = nil } }
        expect(s.editor.relationships?.isActive == false, "no relationship type is left")
        s.expectSaid(free, [], "unmarked: a plain type is not judged")
        s.expectSaid(misfit, [])
        s.editor.undo()
        s.expectSaid(free, ["Employment isn’t attached at both ends."])
        s.expectSaid(misfit, ["Employment runs to a Company. “foundation” is a Layer."])
        s.editor.transact { $0.delete([s.employment]) }
        s.expectSaid(misfit, [], "the type deleted")
        s.editor.undo()
        s.expectSaid(misfit, ["Employment runs to a Company. “foundation” is a Layer."])
        // Marked later: a plain type given the mark judges the arrows already in its list.
        let mentor = s.editor.addType(TypeSchemaProperty.starter, title: "Mentorship", at: CGPoint(x: 800, y: 40))
        let early = s.editor.addBond(s.ann, s.acme, of: [mentor])
        s.expectSaid(early, [])
        s.editor.transact { $0.update(mentor) { $0[RelationshipProperty.self] = true } }
        s.expectSaid(early, [], "no end drawn: it fits anything")
        s.editor.addBond(mentor, s.layer)
        s.expectSaid(early, ["Mentorship runs to a Layer. “Acme” is a Company."])
    },
    test("an arrow with no type that is bound to a relationship type and not at both ends carries one orange line, in the file as it opens and after an undo") {
        let s = try Scene()
        let loose = s.editor.addBond(s.employment, nil)
        s.expectSaid(loose, ["Employment isn’t attached at both ends."])
        expectEqual(s.editor.issues(loose).map(\.severity), [.warning])
        let plain = s.editor.addBond(s.ann, nil)
        let whole = s.editor.addBond(s.person, s.employment)
        s.expectSaid(plain, [], "bound to a note: no line")
        s.expectSaid(whole, [], "bound at both ends: an end, no line")
        let reopened = try bondEditor(file: s.editor.file)
        let again = try require(reopened.fieldChecks?.fullCheck(of: try require(reopened.document[loose])))
        expectEqual(again.problems.map(\.message), ["Employment isn’t attached at both ends."], "the line is a function of the record")
        s.editor.transact { $0.update(s.employment) { $0[RelationshipProperty.self] = nil } }
        s.expectSaid(loose, [], "the mark taken off")
        s.editor.undo()
        s.expectSaid(loose, ["Employment isn’t attached at both ends."], "and back")
        s.editor.transact { $0.update(loose, as: Bond.self) { $0.props.to = s.person } }
        s.expectSaid(loose, [], "mended")
        s.editor.undo()
        s.expectSaid(loose, ["Employment isn’t attached at both ends."])
        let idle = try bondEditor()
        let bare = idle.addBond(nil, nil)
        expectEqual(try require(idle.fieldChecks).fullCheck(of: try require(idle.document[bare])), .clean, "with no relationship type in the file it is not reached")
    },
    test("an end type renamed changes the sentence, an end note renamed changes the name it quotes, and a keystroke below its first line makes nothing again") {
        let s = try Scene()
        let misfit = s.editor.addBond(s.ann, s.foundation, of: [s.employment])
        s.expectSaid(misfit, ["Employment runs to a Company. “foundation” is a Layer."])
        s.editor.transact { $0.update(s.company) { $0[TitleProperty.self] = "Firm" } }
        s.expectSaid(misfit, ["Employment runs to a Firm. “foundation” is a Layer."], "the end type renamed")
        s.editor.undo()
        s.expectSaid(misfit, ["Employment runs to a Company. “foundation” is a Layer."])
        s.editor.transact { $0.update(s.employment) { $0[TitleProperty.self] = "Job" } }
        s.expectSaid(misfit, ["Job runs to a Company. “foundation” is a Layer."], "the relationship type renamed")
        s.editor.undo()
        s.editor.transact { $0.update(s.layer) { $0[TitleProperty.self] = "Stratum" } }
        s.expectSaid(misfit, ["Employment runs to a Company. “foundation” is a Stratum."], "the type of the end renamed")
        s.editor.undo()
        s.editor.transact { $0.update(s.foundation, as: Memo.self) { $0.props.text = MentionText(plain: "bedrock") } }
        s.expectSaid(misfit, ["Employment runs to a Company. “bedrock” is a Layer."], "the end note renamed")
        s.editor.undo()
        s.expectSaid(misfit, ["Employment runs to a Company. “foundation” is a Layer."])
        #if DEBUG
        let made = s.checks.relationPartsMade
        s.editor.transact { $0.update(s.foundation, as: Memo.self) { $0.props.text = MentionText(plain: "foundation\nmore below the first line") } }
        s.expectSaid(misfit, ["Employment runs to a Company. “foundation” is a Layer."], "a keystroke below the first line")
        expectEqual(s.checks.relationPartsMade, made, "nothing was made again")
        #endif
        let long = String(repeating: "x", count: 60)
        s.editor.transact { $0.update(s.foundation, as: Memo.self) { $0.props.text = MentionText(plain: long) } }
        s.expectSaid(misfit, ["Employment runs to a Company. “" + String(repeating: "x", count: 40) + "…” is a Layer."], "a name cut at 40")
    },
    test("a pill re-pointed, its note made private or open, deleted and brought back, each flips the arrow into it with no commit to the arrow") {
        let s = try Scene()
        s.editor.open(s.acme)
        s.editor.open(s.foundation)
        let pill = s.editor.addRelay(standingFor: [s.acme], says: "Acme")
        let into = s.editor.addBond(s.ann, pill, of: [s.employment])
        s.expectSaid(into, [], "a pill for a Company: read through to Acme")
        s.editor.transact { $0.update(pill, as: Relay.self) { $0.props.stands = [Citation(s.foundation)] } }
        s.expectSaid(into, ["Employment runs to a Company. “foundation” is a Layer."], "re-pointed: the sentence names the note, not the pill")
        s.editor.undo()
        s.expectSaid(into, [])
        s.editor.transact { $0.update(s.acme) { $0.meta[Open.self] = nil } }
        s.expectSaid(into, ["Employment runs to “Acme”, which isn’t open."], "made private: an orange line, not a misfit")
        expectEqual(s.editor.issues(into).map(\.severity), [.warning])
        s.editor.transact { $0.update(s.acme) { $0.meta[Open.self] = true } }
        s.expectSaid(into, [], "made open again")
        s.editor.transact { $0.delete([s.acme]) }
        s.expectSaid(into, ["Employment runs to “Acme”, which is gone."], "the note deleted: the pill kept its name")
        s.editor.undo()
        s.expectSaid(into, [])
        let query = s.editor.addRelay(standingFor: [s.acme, s.foundation])
        let several = s.editor.addBond(s.ann, query, of: [s.employment])
        s.expectSaid(several, ["Employment runs to a pill that stands for several notes."])
        let nothing = s.editor.addBond(s.ann, s.editor.addRelay(standingFor: []), of: [s.employment])
        s.expectSaid(nothing, ["Employment runs to a pill that stands for nothing."])
    },
    test("a note that becomes a type, and an arrow given or stripped of its type, flip the verdict; a note's own type list is written only by the person") {
        let s = try Scene()
        s.editor.makeType(s.acme)
        s.expectSaid(s.job, ["Employment runs to a Company. “Acme” is a type."], "an end that is a type's own note")
        s.editor.undo()
        s.expectSaid(s.job, [])
        let plain = s.editor.addBond(s.ann, s.foundation)
        s.expectSaid(plain, [])
        s.editor.addTypeLink(s.employment, to: plain)
        s.expectSaid(plain, ["Employment runs to a Company. “foundation” is a Layer."], "given the type")
        s.editor.removeTypeLink(s.employment, from: plain)
        s.expectSaid(plain, [], "and taken off")
        s.editor.undo()
        s.expectSaid(plain, ["Employment runs to a Company. “foundation” is a Layer."])
    },
    test("a note on a board that is not shown, read through a pill, flips the arrow when it is edited there, and the undo flips it back") {
        let s = try Scene()
        let p = ShapeID()
        s.editor.transact { $0.insert(AnyShapeRecord(ShapeRecord(id: p, Pocket(CGRect(x: 0, y: 1200, width: 100, height: 100))))) }
        let far = s.editor.addInstance("Far", of: [s.company], at: CGPoint(x: 900, y: 1000))
        s.editor.open(far)
        let pill = s.editor.addRelay(standingFor: [far], says: "Far")
        let into = s.editor.addBond(s.ann, pill, of: [s.employment])
        s.editor.transact("Move") { $0.move([far], toBoardOwnedBy: p) }
        s.expectSaid(into, [], "read through the pill to a note on another board")
        s.editor.transact(on: BoardID(owner: p), "Retype") { $0.update(far) { $0[IsAProperty.self] = [TypeLink(s.layer)] } }
        s.expectSaid(into, ["Employment runs to a Company. “Far” is a Layer."])
        s.editor.undo()
        _ = s.editor.showBoard(.root)
        s.expectSaid(into, [])
        s.editor.transact(on: BoardID(owner: p), "Rename") { $0.update(far, as: Memo.self) { $0.props.text = MentionText(plain: "Farther") } }
        s.expectSaid(into, [], "a rename of a note nobody quotes")
        s.editor.transact(on: BoardID(owner: p), "Retype") { $0.update(far) { $0[IsAProperty.self] = [] } }
        s.expectSaid(into, ["Employment runs to a Company. “Farther” has no type."])
        s.editor.transact(on: BoardID(owner: p), "Rename") { $0.update(far, as: Memo.self) { $0.props.text = MentionText(plain: "Farthest") } }
        s.expectSaid(into, ["Employment runs to a Company. “Farthest” has no type."], "a quoted note renamed on a board not shown")
        s.editor.undo()
        _ = s.editor.showBoard(.root)
        s.expectSaid(into, ["Employment runs to a Company. “Farther” has no type."])
    },
    test("a drag, a keystroke in a note nobody quotes, a clean arrow's relationship type's schema and a new relationship each make no other arrow's part again") {
        let s = try Scene()
        #if DEBUG
        let other = s.editor.addBond(s.ann, s.foundation, of: [s.employment])
        s.expectSaid(other, ["Employment runs to a Company. “foundation” is a Layer."])
        s.expectSaid(s.job, [])
        let made = s.checks.relationPartsMade
        s.editor.transact { transaction in
            for id in [s.ann, s.acme, s.foundation] { transaction.update(id, as: Memo.self) { $0.props.frame.origin.x += 9 } }
        }
        s.expectSaid(other, ["Employment runs to a Company. “foundation” is a Layer."])
        expectEqual(s.checks.relationPartsMade, made, "a drag of the notes")
        s.editor.transact { $0.update(s.ann, as: Memo.self) { $0.props.text = MentionText(plain: "Ann Lee") } }
        s.expectSaid(s.job, [])
        expectEqual(s.checks.relationPartsMade, made, "a keystroke in a note nobody quotes")
        s.editor.transact { $0.update(s.acme, as: Memo.self) { $0.props.text = MentionText(plain: "Acme Inc") } }
        expectEqual(s.checks.relationPartsMade, made, "a keystroke in a fitting end, which is not quoted")
        s.editor.transact { $0.update(s.employment) { $0[TypeSchemaProperty.self] = SchemaText(#"{"type":"object","properties":{"role":{"type":"string"}}}"#) } }
        s.expectSaid(s.job, [])
        expectEqual(s.checks.relationPartsMade, made + 1, "a keystroke in the relationship type's schema: the misfit's words name titles, so its part is made again, and the clean arrow's is not")
        let third = s.editor.addBond(s.ann, s.acme, of: [s.employment])
        s.expectSaid(third, [])
        expectEqual(s.checks.relationPartsMade, made + 2, "a new relationship makes its own part and no other's")
        #endif
    },
    test("with no relationship type in the file the part is never made, and a plain note's check is as it was") {
        let editor = try bondEditor()
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person")
        let ann = editor.addInstance("Ann", of: [person])
        let bond = editor.addBond(ann, ann, of: [person])
        let checks = try require(editor.fieldChecks)
        expectEqual(checks.fullCheck(of: try require(editor.document[bond])), .clean)
        expectEqual(checks.fullCheck(of: try require(editor.document[ann])), .clean)
        #if DEBUG
        expectEqual(checks.relationPartsMade, 0)
        #endif
        expect(editor.issues(bond).isEmpty)
    },
    test("a run says what an arrow's ends say, whether it restates the arrow or changes it, and the commit's own check says the same") {
        let s = try Scene()
        let misfit = s.editor.addBond(s.ann, s.foundation, of: [s.employment])
        let words = "Employment runs to a Company. “foundation” is a Layer."
        s.expectSaid(misfit, [words])
        let record = try require(s.editor.document[misfit])
        var restated: [String]?, changed: [String]?
        s.editor.transact("Run") { transaction in
            // Something written, so the reading is a run's and not the committed file's.
            transaction.update(s.ann, as: Memo.self) { $0.props.text = MentionText(plain: "Ann Lee") }
            guard let reading = transaction.shapes.reading else { return }
            restated = s.checks.check(of: record, reading: reading).problems.map(\.message)
            var edited = record
            edited[FieldValuesProperty.self] = FieldValues(["role": "clerk"])
            transaction.update(misfit) { $0[FieldValuesProperty.self] = FieldValues(["role": "clerk"]) }
            changed = s.checks.check(of: edited, reading: transaction.shapes.reading ?? reading).problems.map(\.message)
        }
        expectEqual(restated, [words], "a restated arrow: the relation part is the run's own, over the run's graph")
        expectEqual(changed, [words], "a changed one: made too")
        s.expectSaid(misfit, [words], "the commit's rings say it")
    },
])

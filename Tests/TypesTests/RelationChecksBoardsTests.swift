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

// The order trap, a board kept and taken back, an arrow's own values beside its ends.

@MainActor private func keptIssues(_ editor: CanvasEditor, _ id: ShapeID) -> [String] { editor.issues(id).map(\.message).sorted() }

@MainActor private func freshIssues(_ editor: CanvasEditor, _ id: ShapeID) throws -> [String] {
    let other = try bondEditor(file: editor.file)
    return try require(other.fieldChecks).fullCheck(of: try require(other.file.record(id))).problems.map(\.message).sorted()
}

@MainActor let relationChecksBoardsTests = Suite("Relation checks, boards and order", [
    test("the order trap: one commit that makes a relationship type, draws its ends and a misfit; Validation holds the misfit, and the undo nothing") {
        let editor = try bondEditor()
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person", at: CGPoint(x: 40, y: 40))
        let company = editor.addType(TypeSchemaProperty.starter, title: "Company", at: CGPoint(x: 40, y: 200))
        let layer = editor.addType(TypeSchemaProperty.starter, title: "Layer", at: CGPoint(x: 40, y: 360))
        let ann = editor.addInstance("Ann", of: [person], at: CGPoint(x: 500, y: 400))
        let foundation = editor.addInstance("foundation", of: [layer], at: CGPoint(x: 800, y: 700))
        _ = editor.validation?.results
        var related = slipTypeRecord(TypeSchemaProperty.starter, title: "Employment", at: CGPoint(x: 400, y: 40))
        related[RelationshipProperty.self] = true
        var arrow = AnyShapeRecord(ShapeRecord(id: ShapeID(), Bond(from: ann, to: foundation)))
        arrow[IsAProperty.self] = [TypeLink(related.id)]
        let loose = AnyShapeRecord(ShapeRecord(id: ShapeID(), Bond(from: related.id, to: nil)))
        editor.transact("All") { transaction in
            transaction.insert(related)
            transaction.insert(AnyShapeRecord(ShapeRecord(id: ShapeID(), Bond(from: person, to: related.id))))
            transaction.insert(AnyShapeRecord(ShapeRecord(id: ShapeID(), Bond(from: related.id, to: company))))
            transaction.insert(arrow)
            transaction.insert(loose)
        }
        expectEqual(keptIssues(editor, arrow.id), ["Employment runs to a Company. “foundation” is a Layer."])
        expectEqual(keptIssues(editor, loose.id), ["Employment isn’t attached at both ends."])
        expectEqual(try freshIssues(editor, arrow.id), ["Employment runs to a Company. “foundation” is a Layer."])
        editor.undo()
        expect(editor.document[arrow.id] == nil)
        editor.redo()
        expectEqual(keptIssues(editor, arrow.id), ["Employment runs to a Company. “foundation” is a Layer."], "redone")
        expectEqual(keptIssues(editor, loose.id), ["Employment isn’t attached at both ends."], "redone")
    },
    test("a board kept and taken back: a change made while another board is shown flips the arrow's kept verdict when its board is shown again") {
        let editor = try bondEditor()
        let pocket = ShapeID()
        editor.transact { $0.insert(AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 0, y: 1200, width: 100, height: 100))))) }
        let away = BoardID(owner: pocket)
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person", at: CGPoint(x: 40, y: 40))
        let company = editor.addType(TypeSchemaProperty.starter, title: "Company", at: CGPoint(x: 40, y: 200))
        let layer = editor.addType(TypeSchemaProperty.starter, title: "Layer", at: CGPoint(x: 40, y: 360))
        let employment = editor.addRelationshipType("Employment")
        editor.addBond(person, employment)
        let toEnd = editor.addBond(employment, company)
        let ann = editor.addInstance("Ann", of: [person], at: CGPoint(x: 500, y: 400))
        let acme = editor.addInstance("Acme", of: [company], at: CGPoint(x: 800, y: 400))
        let foundation = editor.addInstance("foundation", of: [layer], at: CGPoint(x: 800, y: 700))
        let job = editor.addBond(ann, acme, of: [employment])
        let misfit = editor.addBond(ann, foundation, of: [employment])
        let loose = editor.addBond(employment, nil)
        let words = "Employment runs to a Company. “foundation” is a Layer.", line = "Employment isn’t attached at both ends."
        @MainActor func expectRoot(_ jobSays: [String], _ misfitSays: [String], _ looseSays: [String], _ message: String) throws {
            expect(editor.showBoard(.root))
            let held = (keptIssues(editor, job), keptIssues(editor, misfit), keptIssues(editor, loose))
            expectEqual(held.0, jobSays, "job, \(message)")
            expectEqual(held.1, misfitSays, "misfit, \(message)")
            expectEqual(held.2, looseSays, "loose, \(message)")
            expectEqual(try freshIssues(editor, job), jobSays, "job afresh, \(message)")
            expectEqual(try freshIssues(editor, misfit), misfitSays, "misfit afresh, \(message)")
            expectEqual(try freshIssues(editor, loose), looseSays, "loose afresh, \(message)")
        }
        try expectRoot([], [words], [line], "as drawn")
        // The mark taken off from another board.
        expect(editor.showBoard(away))
        editor.transact(on: .root, "Unmark") { $0.update(employment) { $0[RelationshipProperty.self] = nil } }
        try expectRoot([], [], [], "unmarked while away")
        expect(editor.showBoard(away))
        editor.transact(on: .root, "Mark") { $0.update(employment) { $0[RelationshipProperty.self] = true } }
        try expectRoot([], [words], [line], "marked again while away")
        // An end note's type taken off from another board.
        expect(editor.showBoard(away))
        editor.transact(on: .root, "Untype") { $0.update(acme) { $0[IsAProperty.self] = nil } }
        try expectRoot(["Employment runs to a Company. “Acme” has no type."], [words], [line], "Acme untyped while away")
        expect(editor.showBoard(away))
        editor.transact(on: .root, "Retype") { $0.update(acme) { $0[IsAProperty.self] = [TypeLink(company)] } }
        try expectRoot([], [words], [line], "typed again while away")
        // An end deleted from another board.
        expect(editor.showBoard(away))
        editor.transact(on: .root, "Delete") { $0.delete([toEnd]) }
        try expectRoot([], [], [line], "the to end deleted while away")
        expect(editor.showBoard(away))
        editor.undo()
        try expectRoot([], [words], [line], "and its undo")
        // A quoted note renamed from another board.
        expect(editor.showBoard(away))
        editor.transact(on: .root, "Rename") { $0.update(foundation, as: Memo.self) { $0.props.text = MentionText(plain: "bedrock") } }
        try expectRoot([], ["Employment runs to a Company. “bedrock” is a Layer."], [line], "the quoted note renamed while away")
        // An end type renamed from another board.
        expect(editor.showBoard(away))
        editor.transact(on: .root, "Rename") { $0.update(company) { $0[TitleProperty.self] = "Firm" } }
        try expectRoot([], ["Employment runs to a Firm. “bedrock” is a Layer."], [line], "the end type renamed while away")
    },
    test("an arrow's own wrong value and its misfit are both listed, the field at its key and the end at to; typing in the field leaves the end's line") {
        let editor = try bondEditor()
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person", at: CGPoint(x: 40, y: 40))
        let company = editor.addType(TypeSchemaProperty.starter, title: "Company", at: CGPoint(x: 40, y: 200))
        var related = slipTypeRecord(#"{"type":"object","properties":{"role":{"type":"string"},"since":{"type":"string"}},"required":["since"]}"#, title: "Employment", at: CGPoint(x: 400, y: 40))
        related[RelationshipProperty.self] = true
        editor.transact { $0.insert(related) }
        editor.addBond(person, related.id)
        editor.addBond(related.id, company)
        let ann = editor.addInstance("Ann", of: [person], at: CGPoint(x: 500, y: 400))
        let other = editor.addInstance("Other", of: [person], at: CGPoint(x: 800, y: 400))
        let job = editor.addBond(ann, other, of: [related.id])
        editor.transact { $0.update(job) { $0[FieldValuesProperty.self] = FieldValues(["role": 5]) } }
        let issues = editor.issues(job)
        expectEqual(issues.map(\.field), ["role", "since", "to"], "\(issues.map(\.message))")
        expectEqual(issues.map(\.severity), [.error, .incomplete, .error])
        let check = try require(editor.fieldChecks).fullCheck(of: try require(editor.document[job]))
        expect(check.isIncomplete, "since is needed: amber, and an issue of the third level")
        expect(check.isMisfit)
        expectEqual(check.endMark(.to), .wrong)
        expect(editor.validation?.result(for: ann) == nil && editor.validation?.result(for: other) == nil, "the notes at its ends are not marked")
        let role = FieldPath(field: "role")
        editor.fieldChecks?.typing = (job, role)
        expectEqual(editor.issues(job).map(\.field), ["since", "to"], "the field with the caret is left out, the end is not")
        editor.fieldChecks?.typing = nil
        expectEqual(editor.issues(job).map(\.field), ["role", "since", "to"])
    },
])

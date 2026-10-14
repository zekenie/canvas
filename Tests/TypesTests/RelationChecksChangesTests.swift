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

// Each case is a change that can move an arrow's verdict with no commit to the arrow, held to Validation's kept issues and to a fresh read of the same file.

@MainActor private struct Scene {
    let editor: CanvasEditor
    let person: ShapeID, company: ShapeID, layer: ShapeID, employment: ShapeID
    let ann: ShapeID, acme: ShapeID, foundation: ShapeID, job: ShapeID
    let toEnd: ShapeID, fromEnd: ShapeID

    init(more: [any CanvasPlugin] = []) throws {
        editor = try bondEditor(more: more)
        person = editor.addType(TypeSchemaProperty.starter, title: "Person", at: CGPoint(x: 40, y: 40))
        company = editor.addType(TypeSchemaProperty.starter, title: "Company", at: CGPoint(x: 40, y: 200))
        layer = editor.addType(TypeSchemaProperty.starter, title: "Layer", at: CGPoint(x: 40, y: 360))
        employment = editor.addRelationshipType("Employment")
        fromEnd = editor.addBond(person, employment)
        toEnd = editor.addBond(employment, company)
        ann = editor.addInstance("Ann", of: [person], at: CGPoint(x: 500, y: 400))
        acme = editor.addInstance("Acme", of: [company], at: CGPoint(x: 800, y: 400))
        foundation = editor.addInstance("foundation", of: [layer], at: CGPoint(x: 800, y: 700))
        job = editor.addBond(ann, acme, of: [employment])
    }

    var checks: FieldChecks { editor.fieldChecks! }

    /// What the kept service says, asked now.
    func said(_ id: ShapeID) -> [String] { checks.fullCheck(of: editor.file.record(id)!).problems.map(\.message) }
    /// What Validation holds.
    func kept(_ id: ShapeID) -> [String] { editor.issues(id).map(\.message).sorted() }
    /// What an editor opened afresh on the same file says.
    func fresh(_ id: ShapeID) throws -> [String] {
        let other = try bondEditor(file: editor.file)
        return try require(other.fieldChecks).fullCheck(of: try require(other.file.record(id))).problems.map(\.message).sorted()
    }

    /// Validation's kept issues (read first, before anything asks the service afresh), then the service, are what a
    /// fresh read of the file says, and that is `expected`.
    func expectAll(_ id: ShapeID, _ expected: [String], _ message: String) throws {
        let held = kept(id)
        expectEqual(try fresh(id), expected.sorted(), "a fresh read, \(message)")
        expectEqual(held, expected.sorted(), "Validation's kept issues, \(message)")
        expectEqual(said(id).sorted(), expected.sorted(), "the kept check, \(message)")
    }
}

@MainActor let relationChecksChangesTests = Suite("Relation checks over changes", [
    test("a type between an end note and the side's type is deleted: the arrow of a note of the deleted type is a misfit, with no commit to the arrow; undo and redo") {
        let p = try Scene()
        let employee = p.editor.addType(TypeSchemaProperty.starter, title: "Employee", at: CGPoint(x: 400, y: 200))
        p.editor.addTypeLink(p.person, to: employee)
        let bo = p.editor.addInstance("Bo", of: [employee], at: CGPoint(x: 500, y: 700))
        let boJob = p.editor.addBond(bo, p.acme, of: [p.employment])
        try p.expectAll(boJob, [], "an Employee is a Person")
        let record = p.editor.document[boJob]
        p.editor.transact("Delete") { $0.delete([employee]) }
        expectEqual(p.editor.document[boJob], record, "the arrow was not written")
        try p.expectAll(boJob, ["Employment runs from a Person. “Bo” has no type."], "Employee deleted")
        p.editor.undo()
        try p.expectAll(boJob, [], "the delete undone")
        p.editor.redo()
        try p.expectAll(boJob, ["Employment runs from a Person. “Bo” has no type."], "the delete redone")
    },
    test("the type of a misfit end is deleted, or has its schema removed: the sentence Validation holds says what the end is now") {
        let p = try Scene()
        let misfit = p.editor.addBond(p.ann, p.foundation, of: [p.employment])
        try p.expectAll(misfit, ["Employment runs to a Company. “foundation” is a Layer."], "as drawn")
        p.editor.removeType(p.layer)
        try p.expectAll(misfit, ["Employment runs to a Company. “foundation” has no type."], "Remove Type on Layer")
        p.editor.undo()
        try p.expectAll(misfit, ["Employment runs to a Company. “foundation” is a Layer."], "undone")
        p.editor.transact("Delete") { $0.delete([p.layer]) }
        try p.expectAll(misfit, ["Employment runs to a Company. “foundation” has no type."], "Layer deleted")
        p.editor.undo()
        try p.expectAll(misfit, ["Employment runs to a Company. “foundation” is a Layer."], "the delete undone")
    },
    test("an end type renamed in the commit that changes its schema: the sentence Validation holds names it as it is") {
        let p = try Scene()
        let misfit = p.editor.addBond(p.ann, p.foundation, of: [p.employment])
        try p.expectAll(misfit, ["Employment runs to a Company. “foundation” is a Layer."], "as drawn")
        p.editor.transact("Edit") {
            $0.update(p.company) {
                $0[TitleProperty.self] = "Firm"
                $0[TypeSchemaProperty.self] = SchemaText(#"{"type":"object","properties":{"name":{"type":"string"}}}"#)
            }
        }
        try p.expectAll(misfit, ["Employment runs to a Firm. “foundation” is a Layer."], "renamed with its schema")
        p.editor.undo()
        try p.expectAll(misfit, ["Employment runs to a Company. “foundation” is a Layer."], "undone")
    },
    test("the note at an end moved to another board frees the end: one orange line, and undo and redo") {
        let p = try Scene()
        let pocket = ShapeID()
        p.editor.transact { $0.insert(AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 0, y: 1200, width: 100, height: 100))))) }
        try p.expectAll(p.job, [], "as drawn")
        _ = p.editor.transact("Move") { $0.move([p.acme], toBoardOwnedBy: pocket) }
        try p.expectAll(p.job, ["Employment isn’t attached at both ends."], "Acme moved away")
        p.editor.undo()
        _ = p.editor.showBoard(.root)
        try p.expectAll(p.job, [], "undone")
        p.editor.redo()
        _ = p.editor.showBoard(.root)
        try p.expectAll(p.job, ["Employment isn’t attached at both ends."], "redone")
    },
    test("the type at an end of the relationship type stops being a type, or is deleted: the side is open, a misfit clears, and undo brings it back") {
        let p = try Scene()
        let misfit = p.editor.addBond(p.ann, p.foundation, of: [p.employment])
        let words = "Employment runs to a Company. “foundation” is a Layer."
        try p.expectAll(misfit, [words], "as drawn")
        p.editor.removeType(p.company)
        try p.expectAll(misfit, [], "Company is no type: the to side has no end")
        p.editor.undo()
        try p.expectAll(misfit, [words], "undone")
        p.editor.redo()
        try p.expectAll(misfit, [], "redone")
        p.editor.undo()
        p.editor.transact("Delete") { $0.delete([p.company]) }
        try p.expectAll(misfit, [], "Company deleted")
        p.editor.undo()
        try p.expectAll(misfit, [words], "the delete undone")
        p.editor.redo()
        try p.expectAll(misfit, [], "the delete redone")
    },
    test("the loose end's line: the relationship type deleted, Remove Type on it, the arrow given a type, each with undo and redo, and a reopen after each") {
        let p = try Scene()
        let loose = p.editor.addBond(p.employment, nil)
        let line = "Employment isn’t attached at both ends."
        try p.expectAll(loose, [line], "as drawn")
        p.editor.removeType(p.employment)
        try p.expectAll(loose, [], "Remove Type")
        p.editor.undo()
        try p.expectAll(loose, [line], "undone")
        p.editor.redo()
        try p.expectAll(loose, [], "redone")
        p.editor.undo()
        p.editor.transact("Delete") { $0.delete([p.employment]) }
        expect(p.editor.file.record(loose) == nil, "an arrow bound to the type alone goes with it")
        p.editor.undo()
        try p.expectAll(loose, [line], "the delete undone")
        p.editor.redo()
        expect(p.editor.file.record(loose) == nil, "and again when the delete is redone")
        p.editor.undo()
        // A second relationship type: the first unmarked while another exists.
        let other = p.editor.addRelationshipType("Other", at: CGPoint(x: 900, y: 40))
        p.editor.makePlainTypes([p.employment])
        try p.expectAll(loose, [], "the mark taken off while another relationship type exists")
        p.editor.undo()
        try p.expectAll(loose, [line], "undone")
        _ = other
    },
    test("the only relationship type unmarked, then deleted, each undone and redone: free end, misfit and loose end all clear and come back") {
        let p = try Scene()
        let free = p.editor.addBond(p.ann, nil, of: [p.employment])
        let misfit = p.editor.addBond(p.ann, p.foundation, of: [p.employment])
        let loose = p.editor.addBond(nil, p.employment)
        let freeLine = "Employment isn’t attached at both ends.", words = "Employment runs to a Company. “foundation” is a Layer."
        @MainActor func all(_ on: Bool, _ message: String) throws {
            try p.expectAll(free, on ? [freeLine] : [], "free, \(message)")
            try p.expectAll(misfit, on ? [words] : [], "misfit, \(message)")
            try p.expectAll(loose, on ? [freeLine] : [], "loose, \(message)")
        }
        try all(true, "as drawn")
        p.editor.makePlainTypes([p.employment])
        expect(p.editor.relationships?.isActive == false)
        try all(false, "unmarked")
        p.editor.undo()
        try all(true, "unmark undone")
        p.editor.redo()
        try all(false, "unmark redone")
        p.editor.undo()
        p.editor.transact("Delete") { $0.delete([p.employment]) }
        try p.expectAll(free, [], "free, deleted")
        try p.expectAll(misfit, [], "misfit, deleted")
        p.editor.undo()
        try all(true, "delete undone")
        p.editor.redo()
        try p.expectAll(free, [], "free, delete redone")
        try p.expectAll(misfit, [], "misfit, delete redone")
        p.editor.undo()
        try all(true, "delete undone again")
    },
    test("a pill at an end deleted, and its note deleted on another board, with undo and redo") {
        let p = try Scene()
        let pocket = ShapeID()
        p.editor.transact { $0.insert(AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 0, y: 1200, width: 100, height: 100))))) }
        let far = p.editor.addInstance("Far", of: [p.company], at: CGPoint(x: 900, y: 1000))
        p.editor.open(far)
        let pill = p.editor.addRelay(standingFor: [far], says: "Far")
        let into = p.editor.addBond(p.ann, pill, of: [p.employment])
        _ = p.editor.transact("Move") { $0.move([far], toBoardOwnedBy: pocket) }
        try p.expectAll(into, [], "through the pill")
        p.editor.transact(on: BoardID(owner: pocket), "Delete") { $0.delete([far]) }
        try p.expectAll(into, ["Employment runs to “Far”, which is gone."], "the far note deleted on its board")
        p.editor.undo()
        _ = p.editor.showBoard(.root)
        try p.expectAll(into, [], "undone")
        p.editor.redo()
        _ = p.editor.showBoard(.root)
        try p.expectAll(into, ["Employment runs to “Far”, which is gone."], "redone")
        p.editor.undo()
        _ = p.editor.showBoard(.root)
        p.editor.transact("Delete") { $0.delete([pill]) }
        try p.expectAll(into, ["Employment isn’t attached at both ends."], "the pill deleted")
        p.editor.undo()
        try p.expectAll(into, [], "undone")
        // The far note made a type on its board: an end that is a type's own note.
        p.editor.transact(on: BoardID(owner: pocket), "Make Type") { $0.update(far) { $0[TypeSchemaProperty.self] = SchemaText(TypeSchemaProperty.starter) } }
        try p.expectAll(into, ["Employment runs to a Company. “Far” is a type."], "the far note made a type")
        p.editor.undo()
        _ = p.editor.showBoard(.root)
        try p.expectAll(into, [], "undone")
    },
    test("two arrows quote one note: after it is renamed, a keystroke below its first line makes no part again") {
        let p = try Scene()
        let first = p.editor.addBond(p.ann, p.foundation, of: [p.employment])
        let second = p.editor.addBond(p.ann, p.foundation, of: [p.employment])
        let words = "Employment runs to a Company. “foundation” is a Layer."
        try p.expectAll(first, [words], "first")
        try p.expectAll(second, [words], "second")
        p.editor.transact { $0.update(p.foundation, as: Memo.self) { $0.props.text = MentionText(plain: "bedrock") } }
        let renamed = "Employment runs to a Company. “bedrock” is a Layer."
        try p.expectAll(first, [renamed], "first, renamed")
        try p.expectAll(second, [renamed], "second, renamed")
        #if DEBUG
        let made = p.checks.relationPartsMade
        p.editor.transact { $0.update(p.foundation, as: Memo.self) { $0.props.text = MentionText(plain: "bedrock\nmore below") } }
        expectEqual(p.kept(first), [renamed])
        expectEqual(p.kept(second), [renamed])
        expectEqual(p.checks.relationPartsMade, made, "a keystroke below the first line of a note two arrows quote")
        p.editor.transact { $0.update(p.foundation, as: Memo.self) { $0.props.text = MentionText(plain: "bedrock\nmore below, again") } }
        expectEqual(p.kept(first), [renamed])
        expectEqual(p.checks.relationPartsMade, made, "and the next")
        #endif
    },
    test("a note at an end given a second type, a subtype's list, and a note's list emptied through undo and redo") {
        let p = try Scene()
        let misfit = p.editor.addBond(p.ann, p.foundation, of: [p.employment])
        let words = "Employment runs to a Company. “foundation” is a Layer."
        try p.expectAll(misfit, [words], "as drawn")
        p.editor.addTypeLink(p.company, to: p.foundation)
        try p.expectAll(misfit, [], "foundation is a Company too")
        p.editor.undo()
        try p.expectAll(misfit, [words], "undone")
        p.editor.redo()
        try p.expectAll(misfit, [], "redone")
        p.editor.undo()
        p.editor.addTypeLink(p.company, to: p.layer)
        try p.expectAll(misfit, [], "Layer builds on Company")
        p.editor.undo()
        try p.expectAll(misfit, [words], "undone")
        p.editor.redo()
        try p.expectAll(misfit, [], "redone")
    },
    test("a misfit is never refused: addTypeLink, setRelationshipType, a re-aim and draw all write it") {
        let p = try Scene()
        let plain = p.editor.addBond(p.ann, p.foundation)
        p.editor.setRelationshipType(p.employment, of: [plain])
        expectEqual(p.editor.typesOf(plain), [p.employment])
        try p.expectAll(plain, ["Employment runs to a Company. “foundation” is a Layer."], "given by setRelationshipType")
        p.editor.transact { $0.update(p.job, as: Bond.self) { $0.props.to = p.foundation } }
        try p.expectAll(p.job, ["Employment runs to a Company. “foundation” is a Layer."], "re-aimed")
        let issue = try require(p.editor.issues(p.job).first)
        expectEqual(issue.field, "to")
        expectEqual(issue.severity, .error)
        p.editor.undo()
        try p.expectAll(p.job, [], "undone")
        p.editor.redo()
        try p.expectAll(p.job, ["Employment runs to a Company. “foundation” is a Layer."], "redone")
    },
])

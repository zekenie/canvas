@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Mentions
import Queries
import TestKit
import Titles
import Types
import Validation

// what Validation keeps of the third level on a board it keeps and takes back, and what
// `:incomplete` answers while a needed field has the caret.

private let featureSchema = #"{"type": "object", "properties": {"purpose": {"type": "string"}}}"#

private func ticketSchema(required: [String]) -> String {
    let names = required.map { "\"\($0)\"" }.joined(separator: ",")
    return #"{"type":"object","properties":{"title":{"type":"string"},"owner":{"type":"string"}},"required":[\#(names)]}"#
}

@MainActor private func needs(_ editor: CanvasEditor, _ id: ShapeID) -> [String] {
    _ = editor.validation?.results
    return editor.issues(id).filter { $0.severity == .incomplete }.map(\.message)
}

@MainActor let incompleteKeptBoardTests = Suite("the third level on kept boards, and :incomplete while a needed field has the caret", [
    test("a field made needed while the note's board is kept (and unchanged) is there when the board is taken back, and its undo takes it away") {
        let editor = try queryBondEditor()
        let pocket = ShapeID()
        editor.transact { $0.insert(AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 0, y: 1200, width: 100, height: 100))))) }
        let away = BoardID(owner: pocket)
        let ticket = editor.addSlipType(ticketSchema(required: []), words: "A ticket", title: "Ticket", at: CGPoint(x: 40, y: 40))
        let note = slipRecord("n", of: [ticket], at: CGPoint(x: 40, y: 40))
        editor.transact(on: away, "Add") { $0.insert(note) }
        expect(editor.showBoard(away))
        expectEqual(needs(editor, note.id), [], "nothing needed yet")
        expect(editor.showBoard(.root))
        _ = editor.validation?.results
        editor.transact("Edit Type") { $0.update(ticket) { $0[TypeSchemaProperty.self] = SchemaText(ticketSchema(required: ["title"])) } }
        expectEqual(try queried(":incomplete", on: editor).rows.map(\.id), [note.id], "the query, from root")
        expect(editor.showBoard(away))
        expectEqual(needs(editor, note.id), ["title is needed"], "taken back")
        expectEqual(editor.validation?.result(for: note.id)?.worst, nil)
        expectEqual(try queried(":incomplete", on: editor).rows.map(\.id), [note.id], "the query, from its board")
        expect(editor.showBoard(.root))
        editor.undo()
        expect(editor.showBoard(away))
        expectEqual(needs(editor, note.id), [], "undone while away")
        expectEqual(try queried(":incomplete", on: editor).rows.map(\.id), [], "the query after the undo")
        expect(editor.showBoard(.root))
        editor.redo()
        expect(editor.showBoard(away))
        expectEqual(needs(editor, note.id), ["title is needed"], "redone while away")
    },
    test("a Needed row of a note on a kept board: a relationship drawn at its pill on another board fills it, deleted empties it, the rule taken off and its undo") {
        let editor = try queryBondEditor()
        let pocket = ShapeID()
        editor.transact { $0.insert(AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 0, y: 1200, width: 100, height: 100))))) }
        let away = BoardID(owner: pocket)
        let feature = editor.addSlipType(featureSchema, words: "A feature", title: "Feature", at: CGPoint(x: 40, y: 40))
        let layer = editor.addSlipType(featureSchema, words: "A layer", title: "Layer", at: CGPoint(x: 440, y: 40))
        let rel = editor.addRelationshipType("in", at: CGPoint(x: 240, y: 40))
        let fromEnd = editor.addBond(feature, rel, name: "layer", rule: EndRule(needed: true, onlyOne: false))
        editor.addBond(rel, layer)
        let foundation = editor.addSlip("Foundation", of: [layer], at: CGPoint(x: 440, y: 500))
        var signIn = slipRecord("Sign in", of: [feature], at: CGPoint(x: 40, y: 40))
        signIn.meta[Open.self] = true
        editor.transact(on: away, "Add") { $0.insert(signIn) }
        let relay = editor.addRelay(standingFor: [signIn.id], says: "Sign in", at: CGPoint(x: 40, y: 500))
        @MainActor func seen(_ says: [String], _ message: String) throws {
            expect(editor.showBoard(away))
            expectEqual(needs(editor, signIn.id), says, message)
            let fresh = try bondEditor(file: editor.file)
            let wanted = try require(fresh.fieldChecks).fullCheck(of: try require(fresh.file.record(signIn.id))).problems.filter { $0.kind == .needed }.map(\.message)
            expectEqual(wanted, says, "afresh, \(message)")
            expectEqual(try queried(":incomplete", on: editor).rows.map(\.id).contains(signIn.id), !says.isEmpty, "the query on its board, \(message)")
            expect(editor.showBoard(.root))
            _ = editor.validation?.results
            expectEqual(try queried(":incomplete", on: editor).rows.map(\.id).contains(signIn.id), !says.isEmpty, "the query from root, \(message)")
        }
        try seen(["layer is needed"], "as made")
        let arrow = editor.addBond(relay, foundation, of: [rel])
        try seen([], "a relationship drawn at the pill")
        editor.undo()
        try seen(["layer is needed"], "its undo")
        editor.redo()
        try seen([], "its redo")
        editor.transact("Delete") { $0.delete([arrow]) }
        try seen(["layer is needed"], "the relationship deleted")
        editor.undo()
        try seen([], "the delete undone")
        editor.transact("Delete") { $0.delete([arrow]) }
        try seen(["layer is needed"], "deleted again")
        editor.transact("Rule") { $0.update(fromEnd) { $0[RelationshipEndProperty.self] = nil } }
        try seen([], "the rule taken off")
        editor.undo()
        try seen(["layer is needed"], "the rule back")
        editor.transact("Rename") { $0.update(fromEnd, as: Bond.self) { $0.props.text = MentionText(plain: "tier") } }
        try seen(["tier is needed"], "the row renamed")
        editor.undo()
        try seen(["layer is needed"], "the rename undone")
        // The note deleted while away: nothing is kept for it.
        editor.transact(on: away, "Delete") { $0.delete([signIn.id]) }
        expect(editor.showBoard(away))
        _ = editor.validation?.results
        expect(editor.validation?.result(for: signIn.id) == nil, "nothing kept for a shape that is gone")
        expectEqual(try queried(":incomplete", on: editor).rows.map(\.id).contains(signIn.id), false)
    },
    test(":incomplete lists a note whose needed field has the caret, as it did when the word read the whole check") {
        let editor = try queryBondEditor()
        let ticket = editor.addSlipType(ticketSchema(required: ["title"]), words: "A ticket", title: "Ticket", at: CGPoint(x: 40, y: 40))
        let note = editor.addSlip("n", of: [ticket], at: CGPoint(x: 40, y: 500))
        _ = editor.validation?.results
        expectEqual(try queried(":incomplete", on: editor).rows.map(\.id), [note], "before the caret")
        let checks = try require(editor.fieldChecks)
        checks.typing = (note, FieldPath(field: "title"))
        expect(checks.fullCheck(of: try require(editor.document[note])).isIncomplete, "the whole check, which the word read, still says it")
        let rows = try queried(":incomplete", on: editor).rows
        expectEqual(rows.map(\.id), [note], "with the caret in the empty needed field")
        expectEqual(rows.first?.problems?.map(\.message), ["title is needed"])
        checks.typing = nil
        expectEqual(try queried(":incomplete", on: editor).rows.map(\.id), [note], "after the caret left")
    },
    test("a Needed end renamed and then the note only moved: :incomplete says the new row name") {
        let editor = try queryBondEditor()
        let feature = editor.addSlipType(featureSchema, words: "A feature", title: "Feature", at: CGPoint(x: 40, y: 40))
        let layer = editor.addSlipType(featureSchema, words: "A layer", title: "Layer", at: CGPoint(x: 440, y: 40))
        let rel = editor.addRelationshipType("In", at: CGPoint(x: 240, y: 40))
        let fromEnd = editor.addBond(feature, rel, name: "layer", rule: EndRule(needed: true, onlyOne: false))
        editor.addBond(rel, layer)
        let note = editor.addSlip("Sign in", of: [feature], at: CGPoint(x: 40, y: 500))
        _ = editor.validation?.results
        editor.transact("Rename") { $0.update(fromEnd, as: Bond.self) { $0.props.text = MentionText(plain: "tier") } }
        _ = editor.validation?.results
        editor.transact("Move") { $0.translate([note], by: CGPoint(x: 10, y: 0)) }
        _ = editor.validation?.results
        let rows = try queried(":incomplete", on: editor).rows
        expectEqual(rows.first(where: { $0.id == note })?.problems?.map(\.message), ["tier is needed"])
    },
])

@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Draw
import Foundation
import Mentions
import TestKit
import Titles
import Types

// The warnings a run gives of a relationship type and an arrow it draws that say less than they seem to, and the class a
// row's problems carry.

private let schema = #"{\"type\": \"object\", \"properties\": {}}"#

@MainActor private func ran(_ script: String, on editor: CanvasEditor) throws -> (rows: [JSONObject], warnings: [String]) {
    let result = try draw(script: script, dryRun: false, reveal: false, program: "canvas", in: editor)
    let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(result))
    let rows = (json["changes"]?.arrayValue ?? []).compactMap(\.objectValue)
    let warnings = (json["warnings"]?.arrayValue ?? []).compactMap { $0["message"]?.stringValue }
    return (rows, warnings)
}

@MainActor let relationshipReportWarningsTests = Suite("What a run warns of a relationship type and its arrows", [
    test("relationship: true on a note with no schema is drawn and warned of once, and the mark does nothing") {
        let editor = try typeEditorWithDraw()
        let first = try ran(#"memo "Employment" relationship: true"#, on: editor)
        expectEqual(first.warnings.filter { $0.contains("relationship: says something only on a type, a note with a schema:") }.count, 1, "\(first.warnings)")
        expectEqual(first.rows[0]["relates"], nil, "it relates nothing")
        let again = try ran(#"memo "Employment" relationship: true"#, on: editor)
        expectEqual(again.warnings, [], "not said again of a row that changes nothing")
        let typed = try ran(#"memo "Employment" schema: "\#(schema)""#, on: editor)
        expectEqual(typed.warnings, [], "with a schema the mark is a relationship type")
        expectEqual(typed.rows[0]["relates"], .object(["from": "anything", "to": "anything"]))
    },
    test("a two-headed arrow at an end is drawn and warned of, naming the end it is, and not warned of again") {
        let editor = try typeEditorWithDraw()
        _ = try ran("""
        memo "Person" schema: "\(schema)"
        memo "Employment" right of "Person" schema: "\(schema)" relationship: true
        """, on: editor)
        let first = try ran(#"edge "Person" <-> "Employment""#, on: editor)
        expectEqual(first.rows[0]["endOf"], .object(["type": "Employment", "side": "from"]), "read from its start to its end")
        let words = "A two-headed arrow is read from its start to its end, so this is only the from end of “Employment”. For a type related to itself write two edges."
        expectEqual(first.warnings.filter { $0.contains(words) }.count, 1, "\(first.warnings)")
        let again = try ran(#"edge "Person" <-> "Employment""#, on: editor)
        expectEqual(again.warnings, [])
        let one = try ran(#"edge "Employment" -> "Person""#, on: editor)
        expectEqual(one.warnings, [], "one head says nothing of heads")
    },
    test("a row's problems carry the class warning for an end that cannot be read") {
        let editor = try bondEditor()
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person", at: CGPoint(x: 40, y: 40))
        let company = editor.addType(TypeSchemaProperty.starter, title: "Company", at: CGPoint(x: 40, y: 200))
        let employment = editor.addRelationshipType("Employment")
        editor.addBond(person, employment)
        editor.addBond(employment, company)
        let ann = editor.addInstance("Ann", of: [person], at: CGPoint(x: 500, y: 400))
        let closed = editor.addInstance("Acme", of: [company], at: CGPoint(x: 800, y: 400))
        let pill = editor.addRelay(standingFor: [closed], says: "Acme", at: CGPoint(x: 800, y: 700))
        let job = editor.addBond(ann, pill, of: [employment])
        let record = try require(editor.shape(inFile: job))
        let reading = try require(editor.shapeContext.reading)
        let drawn = try require(editor.fieldChecks).drawn(record, written: nil, reading: reading)
        expectEqual(drawn.check.problems.map { $0.kind.word }, ["warning"], "a pill for a note that is not open: orange, not an error")
    },
])

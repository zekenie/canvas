import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasUI
import CanvasTesting
import Foundation
import LanguageModels
import ShippedTesting
import TestKit
import Titles
import Types
import Validation

// The skill's relationships page as prose (what its blocks
// do not run), and the check over real arrows through `canvas` as built.

private let story = [
    #"""
    sticky-note "Person" schema: "{\"type\": \"object\", \"properties\": {\"name\": {\"type\": \"string\"}}}" text: "A person: their name"
    sticky-note "Employment" right of "Person" relationship: true schema: "{\"type\": \"object\", \"properties\": {\"role\": {\"type\": \"string\"}, \"since\": {\"type\": \"string\", \"format\": \"date\"}}}" text: "A job: the role, and when it started"
    sticky-note "Company" right of "Employment" schema: "{\"type\": \"object\", \"properties\": {\"name\": {\"type\": \"string\"}}}" text: "A company: its name"
    """#,
    #"""
    edge "Person" -> "Employment" text: "jobs" endRule: {"onlyOne": true}
    edge "Employment" -> "Company" text: "staff"
    """#,
    #"""
    sticky-note "Ann" below "Person" is: "Person" fieldValues: {"name": "Ann Lee"}
    sticky-note "Acme" below "Company" is: "Company" fieldValues: {"name": "Acme"}
    edge "Ann" -> "Acme" is: "Employment" fieldValues: {"role": "Staff engineer", "since": "2021-03-01"}
    """#,
]

@MainActor private func arrows(_ editor: CanvasEditor) -> [AnyShapeRecord] { editor.document.shapes.filter { $0.kind == "arrow" } }

@MainActor private func titled(_ title: String, in editor: CanvasEditor) throws -> ShapeID {
    try require(editor.document.shapes.first { $0[TitleProperty.self] == title }, "a shape titled \(title)").id
}

@MainActor let relationChecksShippedTests = Suite("Relation checks, shipped", [
    test("the skill's page, its prose: delete edge with is:, a second arrow of a pair, ambiguous_edge, endRule's null, and what deleting a type does to its end arrows") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let editor = board.editor
        for script in story {
            let ran = try draw(script, on: board, server)
            expectEqual(ran.status, 0, ran.error)
        }
        expectEqual(arrows(editor).count, 3)
        // "`edge "Ann" -> "Acme" is: "Mentorship"` beside it is a second arrow between the same two notes".
        let mentor = try draw(#"sticky-note "Mentorship" below "Employment" relationship: true schema: "{\"type\": \"object\"}" text: "Mentoring""#, on: board, server)
        expectEqual(mentor.status, 0, mentor.error)
        let second = try draw(#"edge "Ann" -> "Acme" is: "Mentorship""#, on: board, server)
        expectEqual(second.status, 0, second.error)
        expectEqual(arrows(editor).count, 4, "a second arrow, not a replacement")
        // "Writing `edge "Ann" -> "Acme"` with no `is:` ... is refused (`ambiguous_edge`) when it holds two arrows."
        let bare = try draw(#"edge "Ann" -> "Acme""#, on: board, server, ["--dry-run"])
        expectEqual(bare.status, 1, bare.output)
        expectEqual((try? JSON(text: bare.error))?["error"]?["reason"]?.stringValue, "ambiguous_edge", bare.error)
        // "to change it, delete it (`delete edge "Ann" -> "Acme" is: "Employment"`) above the line."
        let changed = try draw("delete edge \"Ann\" -> \"Acme\" is: \"Mentorship\"\n", on: board, server)
        expectEqual(changed.status, 0, changed.error)
        expectEqual(arrows(editor).count, 3, "the one arrow deleted")
        // "`null` takes a member off."
        let person = try titled("Person", in: editor), employment = try titled("Employment", in: editor)
        let fromEnd = try require(arrows(editor).first { editor.relationships?.end($0.id)?.side == .from }, "the from end")
        expectEqual(fromEnd[RelationshipEndProperty.self], EndRule(needed: false, onlyOne: true))
        let cleared = try draw(#"edge "Person" -> "Employment" endRule: {"onlyOne": null}"#, on: board, server)
        expectEqual(cleared.status, 0, cleared.error)
        expectEqual(editor.document[fromEnd.id]?[RelationshipEndProperty.self], nil, "the member taken off: no rule is left")
        // "Deleting a type deletes its end arrows (`delete "Person"` takes `edge "Person" -> "Employment"` with it),
        // and the relationship type then has no end on that side".
        let deleted = try draw("delete \"Person\"\n", on: board, server)
        expectEqual(deleted.status, 0, deleted.error)
        expect(editor.document[person] == nil, "Person is deleted")
        expect(editor.document[fromEnd.id] == nil, "the skill says its end arrow goes with it")
        expectEqual(editor.relationships?.graph.sides(of: employment).from.count, 0, "no end on that side")
        _ = editor.validation?.results
        expectEqual(editor.issues(of: fromEnd.id), [], "and nothing is left to carry a line")
    },
    test("real arrows: a misfit is drawn and flagged, never refused, by canvas draw; arrow:invalid says field to; a note deleted frees the end; a type removed in the chain flips its notes' arrows") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let editor = board.editor
        for script in story {
            let ran = try draw(script, on: board, server)
            expectEqual(ran.status, 0, ran.error)
        }
        let layer = try draw(#"""
        sticky-note "Layer" below "Employment" schema: "{\"type\": \"object\"}" text: "A layer"
        sticky-note "foundation" below "Layer" is: "Layer"
        sticky-note "Employee" right of "Company" is: "Person" schema: "{\"type\": \"object\"}" text: "An employee"
        sticky-note "Bo" below "Employee" is: "Employee"
        """#, on: board, server)
        expectEqual(layer.status, 0, layer.error)
        let drawn = try draw(#"""
        edge "Ann" -> "foundation" is: "Employment"
        edge "Bo" -> "Acme" is: "Employment"
        """#, on: board, server)
        expectEqual(drawn.status, 0, "a misfit is never refused: \(drawn.error)")
        let foundation = try titled("foundation", in: editor), bo = try titled("Bo", in: editor), employee = try titled("Employee", in: editor)
        let misfit = try require(arrows(editor).first { editor.relationships?.subjects(of: $0.id)?.to.literal == foundation }, "the arrow into foundation").id
        let boJob = try require(arrows(editor).first { editor.relationships?.subjects(of: $0.id)?.from.literal == bo }, "Bo's arrow").id
        expectEqual(editor.issues(of: misfit), ["Employment runs to a Company. “foundation” is a Layer."])
        expectEqual(editor.issues(of: boJob), [], "an Employee is a Person")
        let invalid = try JSON(text: canvas(server, ["query", "arrow:invalid"]).output)
        expectEqual(invalid["count"], .number(1), "arrow:invalid")
        let problems = invalid["rows"]?.arrayValue?.first?["problems"]?.arrayValue ?? []
        expectEqual(problems.first?["field"]?.stringValue, "to", "\(problems)")
        // The type Bo's fit runs through is deleted by hand: Bo's arrow is a misfit now, with no commit to it.
        let before = editor.document[boJob]
        editor.transact("Delete") { $0.delete([employee]) }
        expectEqual(editor.document[boJob], before, "the arrow was not written")
        let fresh = ShippedPlugins.makeEditor(document: editor.document, scheduler: ManualScheduler(), pasteboard: pasteboard, model: ScriptedLanguageModel())
        let freshSaid = try require(fresh.fieldChecks).fullCheck(of: try require(fresh.document[boJob])).problems.map(\.message)
        expectEqual(freshSaid, ["Employment runs from a Person. “Bo” has no type."], "a fresh read of the file")
        expectEqual(editor.issues(of: boJob), freshSaid, "Validation's kept issues are the fresh read's")
        editor.undo()
        expectEqual(editor.issues(of: boJob), [])
    },
    test("real arrows: an end note deleted by hand frees the relationship's end (one orange line); a type at an end deleted by hand leaves the end arrow loose (one orange line); undo and redo of each") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let editor = board.editor
        for script in story {
            let ran = try draw(script, on: board, server)
            expectEqual(ran.status, 0, ran.error)
        }
        let acme = try titled("Acme", in: editor), company = try titled("Company", in: editor), employment = try titled("Employment", in: editor)
        let job = try require(arrows(editor).first { editor.relationships?.subjects(of: $0.id)?.to.literal == acme }, "the relationship").id
        let toEnd = try require(arrows(editor).first { editor.relationships?.end($0.id)?.side == .to }, "the to end").id
        let line = "Employment isn’t attached at both ends."
        expectEqual(editor.issues(of: job), [])
        expectEqual(editor.issues(of: toEnd), [])
        editor.transact("Delete") { $0.delete([acme]) }
        expect(editor.document[job] != nil, "the arrow outlives the note, as tldraw's does")
        expectEqual(editor.issues(of: job), [line], "a free end")
        expectEqual(editor.validation?.result(for: job)?.issues.map(\.severity), [.warning])
        editor.undo()
        expectEqual(editor.issues(of: job), [], "undone")
        editor.redo()
        expectEqual(editor.issues(of: job), [line], "redone")
        editor.undo()
        editor.transact("Delete") { $0.delete([company]) }
        expect(editor.document[toEnd] != nil, "the end arrow outlives the type")
        expectEqual(editor.issues(of: toEnd), [line], "a loose end")
        expectEqual(editor.relationships?.graph.sides(of: employment).to.count, 0)
        editor.undo()
        expectEqual(editor.issues(of: toEnd), [], "undone")
        expectEqual(editor.relationships?.graph.sides(of: employment).to.count, 1)
        editor.redo()
        expectEqual(editor.issues(of: toEnd), [line], "redone")
        // As the file opens.
        let fresh = ShippedPlugins.makeEditor(document: editor.document, scheduler: ManualScheduler(), pasteboard: pasteboard, model: ScriptedLanguageModel())
        expectEqual(fresh.issues(of: toEnd), [line], "the loose end after the file is opened again")
    },
])

extension CanvasEditor {
    fileprivate func issues(of id: ShapeID) -> [String] { validation?.result(for: id)?.issues.map(\.message) ?? [] }
}

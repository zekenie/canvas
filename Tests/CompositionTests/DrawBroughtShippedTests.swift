import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasUI
import Connections
import CoreGraphics
import Foundation
import Mentions
import StickyNotes
import Subboards
import TestKit
import Titles
import Types
import Validation

// What a run says of shapes it did not write, through `canvas` as built and the shipped kinds: the owner's example
// (a second job drawn for Ann by a later run of one line), a type restated so that a note the run does not restate
// holds a wrong value, and a note deleted that another note mentions (which is no issue of the mentioner's, so nothing
// is said of it).

private let model = #"""
sticky-note "Person" schema: "{\"type\": \"object\", \"properties\": {\"level\": {\"type\": \"string\"}}}" text: "A person: their level"
sticky-note "Employment" right of "Person" relationship: true schema: "{\"type\": \"object\", \"properties\": {\"role\": {\"type\": \"string\"}}}" text: "A job: the role"
sticky-note "Company" right of "Employment" schema: "{\"type\": \"object\", \"properties\": {\"name\": {\"type\": \"string\"}}}" text: "A company: its name"
edge "Person" -> "Employment" text: "jobs" endRule: {"onlyOne": true}
edge "Employment" -> "Company" text: "staff"
sticky-note "Ann" below "Person" is: "Person" fieldValues: {"level": "senior"}
sticky-note "Acme" below "Company" is: "Company" fieldValues: {"name": "Acme"}
sticky-note "Globex" below "Acme" is: "Company" fieldValues: {"name": "Globex"}
edge "Ann" -> "Acme" is: "Employment"
"""#

@MainActor private func shown(_ board: BoardDocument, _ title: String) throws -> [String] {
    let editor = board.editor
    let record = try require(editor.document.shapes.first { editor.registry.title(of: $0) == title })
    return editor.validation?.result(for: record.id)?.issues.map { "\($0.severity == .error ? "error" : $0.severity == .warning ? "warning" : "incomplete") \($0.field ?? "-"): \($0.message)" } ?? []
}

@MainActor let drawBroughtShippedTests = Suite("canvas draw: what a run brings to shapes it did not write, as shipped", [
    test("a second job for Ann, drawn by a later run of one line: the row is connected, the warning names Ann with the edge's line, and the board rings her") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        @MainActor func run(_ arguments: [String]) throws -> JSON {
            let result = try canvas(server, ["draw"] + arguments)
            expectEqual(result.status, 0, result.error)
            return try JSON(text: result.output)
        }
        expectEqual(try run([model])["warnings"]?.arrayValue ?? [], [], "the model and Ann's first job break nothing")
        let script = #"edge "Ann" -> "Globex" is: "Employment""#
        let warning: JSON = ["line": 1, "severity": "error", "attribute": "jobs", "message": "\"Ann\": jobs has 2 notes, and should have at most 1"]
        let revision = board.editor.revision
        let dry = try run(["--dry-run", script])
        expectEqual(dry["warnings"]?.arrayValue ?? [], [warning], "a dry run says it")
        expectEqual(board.editor.revision, revision, "and changes nothing")
        expectEqual(try shown(board, "Ann"), [])
        let real = try run([script])
        expectEqual(real["warnings"]?.arrayValue ?? [], [warning])
        let rows = real["changes"]?.arrayValue ?? []
        expectEqual(rows.count, 1, "the edge's row alone: Ann has none")
        expectEqual(rows.first?["did"], "connected")
        expectEqual(rows.first?["is"], ["Employment"])
        expectEqual(try shown(board, "Ann"), ["error jobs: jobs has 2 notes, and should have at most 1"], "the board says the same of her")
        expectEqual(board.editor.undoHistory.undoName, "Draw", "one step, as before")
        // Run again, the edge is unchanged and brings nothing; deleted, it mends, which is not said.
        expectEqual(try run([script])["warnings"]?.arrayValue ?? [], [])
        expectEqual(try run([#"delete edge "Ann" -> "Globex" is: "Employment""#])["warnings"]?.arrayValue ?? [], [])
        expectEqual(try shown(board, "Ann"), [])
        // A script that restates Ann as she is and draws the edge says it once, on the edge's line.
        let both = try run(["sticky-note \"Ann\"\n" + script])
        expectEqual(both["warnings"]?.arrayValue ?? [], [["line": 2, "severity": "error", "attribute": "jobs", "message": "\"Ann\": jobs has 2 notes, and should have at most 1"]])
        expectEqual((both["changes"]?.arrayValue ?? []).first?["did"], "unchanged")
    },
    test("a type restated so that a note the run does not restate holds a wrong value warns of the note, on the type's line; a field made needed says what she still needs") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        @MainActor func run(_ script: String) throws -> JSON {
            let result = try canvas(server, ["draw", script])
            expectEqual(result.status, 0, result.error)
            return try JSON(text: result.output)
        }
        _ = try run(model)
        let needed = try run(#"sticky-note "Person" schema: "{\"type\": \"object\", \"properties\": {\"level\": {\"type\": \"string\"}, \"team\": {\"type\": \"string\"}}, \"required\": [\"team\"]}" text: "A person: their level and their team, which is needed""#)
        let askedOfAnn = (needed["warnings"]?.arrayValue ?? []).filter { $0["message"]?.stringValue?.hasPrefix("\"Ann\"") == true }
        expectEqual(askedOfAnn.count, 1, "Ann has no team: what she still needs is said, once")
        expectEqual(askedOfAnn.first?["severity"], "incomplete")
        expectEqual(askedOfAnn.first?["attribute"], "team")
        expectEqual(askedOfAnn.first?["line"], 1)
        expectEqual(askedOfAnn.first?["message"], "\"Ann\": team is needed")
        let narrowed = try run(#"sticky-note "Person" schema: "{\"type\": \"object\", \"properties\": {\"level\": {\"type\": \"string\", \"enum\": [\"junior\", \"staff\"]}}}" text: "A person: their level, junior or staff""#)
        let said = (narrowed["warnings"]?.arrayValue ?? []).filter { $0["message"]?.stringValue?.hasPrefix("\"Ann\"") == true }
        expectEqual(said.count, 1, "\(narrowed["warnings"] ?? .null)")
        expectEqual(said.first?["line"], 1)
        expectEqual(said.first?["severity"], "error")
        expectEqual(said.first?["attribute"], "level")
        let shownOfAnn = try shown(board, "Ann")
        expectEqual(shownOfAnn.count, 1)
        expectEqual(said.first?["message"]?.stringValue, shownOfAnn.first.map { "\"Ann\": " + $0.dropFirst("error level: ".count) }, "the run's words are the board's")
    },
    test("a note renamed to the title of a note on the board of another subboard of its subboard's title: both share a path now, and the run warns of the one it did not write too") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        @MainActor func run(_ script: String) throws -> JSON {
            let result = try canvas(server, ["draw", script])
            expectEqual(result.status, 0, result.error)
            return try JSON(text: result.output)
        }
        // Two subboards called Area, which `canvas draw` can't tell apart (it refuses a title two shapes have), so put
        // there through the editor: Cart on the first's board, Billing on the second's. Area › Cart and Area › Billing.
        let editor = board.editor
        var first = ShapeRecord(Subboard(frame: CGRect(x: 0, y: 0, width: 240, height: 160))), second = ShapeRecord(Subboard(frame: CGRect(x: 400, y: 0, width: 240, height: 160)))
        first[TitleProperty.self] = "Area"
        second[TitleProperty.self] = "Area"
        editor.transact("Add") { transaction in
            transaction.insert(first)
            transaction.insert(second)
        }
        for (owner, title) in [(first.id, "Cart"), (second.id, "Billing")] {
            var note = ShapeRecord(StickyNote(frame: CGRect(x: 0, y: 0, width: 200, height: 200), text: MentionText(plain: "The \(title.lowercased())")))
            note[TitleProperty.self] = title
            editor.transact(on: BoardID(owner: owner), "Add") { $0.insert(note) }
        }
        let renamed = try run(#"sticky-note "Cart" title: "Billing""#)
        expectEqual((renamed["changes"]?.arrayValue ?? []).map { $0["did"] }, ["renamed"])
        let said = renamed["warnings"]?.arrayValue ?? []
        expectEqual(said.map { $0["message"] }, [#""Cart": “Area › Billing” is another shape’s path too."#, #""Billing": “Area › Billing” is another shape’s path too."#],
                    "the note the run renamed, by its statement, and the note on the other Area's board, which it did not write")
        expectEqual(said.map { $0["line"] }, [1, 1])
        expectEqual(said.map { $0["severity"] }, ["warning", "warning"])
        expectEqual(said.map { $0["attribute"] }, ["title", "title"])
        expect(editor.showBoard(BoardID(owner: first.id)))
        expectEqual(try shown(board, "Billing"), ["warning title: “Area › Billing” is another shape’s path too."], "the board says it of the one it shows")
    },
    test("a note deleted that another note mentions: the mention shows as missing and is no issue, so the run says nothing of the note that mentions it") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        @MainActor func run(_ script: String) throws -> JSON {
            let result = try canvas(server, ["draw", script])
            expectEqual(result.status, 0, result.error)
            return try JSON(text: result.output)
        }
        _ = try run(#"""
        sticky-note "Plan" text: "The plan"
        sticky-note "Notes" below "Plan" text: "See @[Plan] first"
        """#)
        _ = board.editor.validation?.results
        let deleted = try run(#"delete "Plan""#)
        expectEqual((deleted["changes"]?.arrayValue ?? []).map { $0["did"] }, ["deleted"])
        expectEqual(deleted["warnings"]?.arrayValue ?? [], [], "Validation has no issue for a mention of a shape that is gone: its pill says so")
        expectEqual(try shown(board, "Notes"), [], "and the board has none either")
    },
])

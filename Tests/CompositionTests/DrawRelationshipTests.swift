import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasUI
import Foundation
import TestKit
import Titles
import Types
import Validation

// A relationship through `canvas` as built, over a socket of its own: what a run says of the arrows it draws (the
// row's `is`, `endOf`, `fits`, `relates` and `problems`, the run's error for a misfit), that it says the same on a
// dry run and again, and that Undo takes the whole run back.

private let person = scripted(#"{"type": "object", "properties": {"name": {"type": "string"}}}"#)
private let employment = scripted(#"{"type": "object", "properties": {"role": {"type": "string"}, "since": {"type": "string", "format": "date"}}}"#)

/// Person, Employment from a Person to a Company, Company; Ann and Bo (Persons), Acme (a Company).
private let types = """
sticky-note "Person" schema: "\(person)"
sticky-note "Employment" right of "Person" relationship: true schema: "\(employment)"
sticky-note "Company" right of "Employment" schema: "\(person)"
edge "Person" -> "Employment" text: "jobs" endRule: {"onlyOne": true}
edge "Employment" -> "Company" text: "staff"
"""

private let notes = """
sticky-note "Ann" below "Person" is: "Person"
sticky-note "Bo" right of "Ann" is: "Person"
sticky-note "Acme" below "Company" is: "Company"
"""

private func rows(_ result: JSON) -> [JSON] { result["changes"]?.arrayValue ?? [] }
private func messages(_ result: JSON) -> [String] { (result["warnings"]?.arrayValue ?? []).compactMap { $0["message"]?.stringValue } }

@MainActor let drawRelationshipTests = Suite("A relationship, drawn and read through canvas", [
    test("a relationship type, its ends and the notes in one run: each row says what it became, and a run again is unchanged with the same members") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = newBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let script = types + "\n" + notes + "\n" + #"edge "Ann" -> "Acme" is: "Employment" fieldValues: {"role": "Staff engineer", "since": "2021-03-01"}"#
        let made = try JSON(text: canvas(server, ["draw", script]).output)
        let byLine = Dictionary(grouping: rows(made), by: { $0["line"]?.numberValue.map(Int.init) ?? 0 })
        expectEqual(byLine[2]?.first?["relates"], .object(["from": .array([.string("Person")]), "to": .array([.string("Company")])]),
                    "the relationship type says what it relates, the ends it was drawn with in the same run")
        expectEqual(byLine[4]?.first?["endOf"], .object(["type": .string("Employment"), "side": .string("from"), "row": .string("jobs"), "onlyOne": .bool(true)]))
        expectEqual(byLine[5]?.first?["endOf"], .object(["type": .string("Employment"), "side": .string("to"), "row": .string("staff")]))
        expectEqual(byLine[9]?.first?["is"], .array([.string("Employment")]))
        expect(byLine[9]?.first?["problems"] == nil, "it fits")
        expectEqual(messages(made).filter { $0.contains("Employment runs") }, [], "no misfit")
        expectEqual(board.editor.undoHistory.undoName, "Draw")
        board.editor.undo()
        expectEqual(board.editor.document.shapes.count, 0, "one step takes the types, the ends, the notes and the relationship back")
        board.editor.redo()
        let again = try JSON(text: canvas(server, ["draw", script]).output)
        expectEqual(rows(again).map { $0["did"] }, Array(repeating: "unchanged", count: 9), "run again")
        expectEqual(rows(again).map { $0["endOf"] }, rows(made).map { $0["endOf"] }, "the members are the same on an unchanged row")
        expectEqual(rows(again).map { $0["is"] }, rows(made).map { $0["is"] })
        expectEqual(rows(again).map { $0["relates"] }, rows(made).map { $0["relates"] })
        let dry = try JSON(text: canvas(server, ["draw", "--dry-run", script]).output)
        expectEqual(rows(dry).map { $0["endOf"] }, rows(made).map { $0["endOf"] }, "a dry run says what a real run says")
    },

    test("a misfit drawn by a script says so in its row and in an error, is drawn all the same, and the query, Validation and the board agree") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = newBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        _ = try canvas(server, ["draw", types + "\n" + notes])
        let result = try JSON(text: canvas(server, ["draw", #"edge "Ann" -> "Bo" is: "Employment""#]).output)
        let words = "Employment runs to a Company. “Bo” is a Person."
        let row = try require(rows(result).first)
        expectEqual(row["did"], "connected", "drawn")
        expectEqual(row["is"], .array([.string("Employment")]))
        expectEqual(row["problems"], .array([.object(["field": "to", "class": "wrong", "message": .string(words)])]))
        let warning = try require(result["warnings"]?.arrayValue?.first { $0["message"]?.stringValue?.contains(words) == true })
        expectEqual(warning["severity"], "error")
        expectEqual(warning["attribute"], "to")
        expectEqual(warning["line"], 1)
        let arrow = try require(board.editor.document.shapes.first { $0.kind.rawValue == "arrow" && ($0[IsAProperty.self] ?? []).isEmpty == false })
        expectEqual(board.editor.validation?.result(for: arrow.id)?.issues.map(\.message), [words], "the commit's rings say the same")
        let again = try JSON(text: canvas(server, ["draw", #"edge "Ann" -> "Bo" is: "Employment""#]).output)
        expectEqual(rows(again).first?["did"], "unchanged")
        expectEqual(rows(again).first?["problems"], row["problems"], "an unchanged row says what is wrong")
        // The same misfit in a run that draws the types, the ends and the notes with it.
        let together = try JSON(text: canvas(server, ["draw", "--dry-run", types + "\n" + notes + "\n" + #"edge "Ann" -> "Bo" is: "Employment""#]).output)
        expectEqual(rows(together).last?["problems"], row["problems"], "in one run with the ends it judges by")
    },

    test("a plain arrow between two notes that fit says which relationship types would take it, and the script writes is:; the type is never picked for it") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = newBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        _ = try canvas(server, ["draw", types + "\n" + notes])
        let plain = try JSON(text: canvas(server, ["draw", #"edge "Ann" -> "Acme""#]).output)
        expectEqual(rows(plain).first?["fits"], .array([.string("Employment")]))
        expect(rows(plain).first?["is"] == nil, "no type was picked")
        let none = try JSON(text: canvas(server, ["query", "--brief", #"arrow:is-a("Employment")"#]).output)
        expectEqual(none["count"], 0, "no arrow has the type")
        let typed = try JSON(text: canvas(server, ["draw", #"edge "Ann" -> "Acme" is: "Employment""#]).output)
        expectEqual(rows(typed).map { $0["did"] }, ["reconnected"], "the plain arrow takes the type")
        expectEqual(rows(typed).first?["is"], .array([.string("Employment")]))
        expect(rows(typed).first?["fits"] == nil, "a typed arrow lists no fit")
        let nothing = try JSON(text: canvas(server, ["draw", #"edge "Acme" -> "Ann""#]).output)
        expect(rows(nothing).first?["fits"] == nil, "none fit")
    },

    test("two relationships between one pair are two arrows, each restated unchanged with its type, and delete edge without is: says what it removed") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = newBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let friendship = scripted(#"{"type": "object", "properties": {"since": {"type": "string", "format": "date"}}}"#)
        let setup = """
        sticky-note "Person" schema: "\(person)"
        sticky-note "Friendship" right of "Person" relationship: true schema: "\(friendship)"
        sticky-note "Mentorship" right of "Friendship" relationship: true schema: "\(friendship)"
        edge "Person" -> "Friendship" text: "friends"
        edge "Friendship" -> "Person" text: "friends"
        sticky-note "Ann" below "Person" is: "Person"
        sticky-note "Bo" below "Friendship" is: "Person"
        """
        let setupResult = try canvas(server, ["draw", setup])
        expectEqual(setupResult.status, 0, setupResult.error)
        let two = """
        edge "Ann" -> "Bo" is: "Friendship" fieldValues: {"since": "2019-05-01"}
        edge "Ann" -> "Bo" is: "Mentorship"
        """
        let firstResult = try canvas(server, ["draw", two])
        expectEqual(firstResult.status, 0, firstResult.error)
        let first = try JSON(text: firstResult.output)
        expectEqual(rows(first).map { $0["did"] }, ["connected", "connected"])
        expectEqual(rows(first).map { $0["is"] }, [.array([.string("Friendship")]), .array([.string("Mentorship")])])
        let again = try JSON(text: canvas(server, ["draw", two]).output)
        expectEqual(rows(again).map { $0["did"] }, ["unchanged", "unchanged"])
        expectEqual(rows(again).map { $0["is"] }, rows(first).map { $0["is"] })
        // Without is:, every arrow of the pair goes, and the rows say what each was.
        let removed = try JSON(text: canvas(server, ["draw", #"delete edge "Ann" -> "Bo""#]).output)
        expectEqual(rows(removed).map { $0["did"] }, ["deleted", "deleted"])
        expectEqual(Set(rows(removed).compactMap { $0["is"] }), [.array([.string("Friendship")]), .array([.string("Mentorship")])])
        let said = messages(removed)
        expectEqual(said.count, 2, "a warning for each typed arrow: \(said)")
        expect(said.allSatisfy { $0.contains("removed an arrow of") && $0.contains("is:") }, "\(said)")
        // With is:, only that one, and nothing to warn of.
        _ = try canvas(server, ["draw", two])
        let one = try JSON(text: canvas(server, ["draw", #"delete edge "Ann" -> "Bo" is: "Mentorship""#]).output)
        expectEqual(rows(one).map { $0["is"] }, [.array([.string("Mentorship")])])
        expectEqual(messages(one), [])
    },

    test("an arrow that says nothing is warned: between two types, between two relationship types, from a relationship type to a note, endRule off an end, a plain type on an arrow") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = newBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let friendship = scripted(#"{"type": "object"}"#)
        _ = try canvas(server, ["draw", types + "\n" + notes + "\n" + #"sticky-note "Plain" below "Acme" schema: "\#(friendship)""#])
        @MainActor func said(_ script: String) throws -> [String] { messages(try JSON(text: canvas(server, ["draw", script]).output)) }
        expect(try said(#"edge "Person" -> "Company""#).contains { $0.contains("Both ends are types, so this arrow says nothing. Put a relationship type between them") },
               "between two types")
        let second = scripted(#"{"type": "object"}"#)
        _ = try canvas(server, ["draw", #"sticky-note "Mentorship" below "Employment" relationship: true schema: "\#(second)""#])
        expect(try said(#"edge "Employment" -> "Mentorship""#).contains { $0.contains("Both ends are relationship types, so this arrow says nothing.") },
               "between two relationship types")
        expect(try said(#"edge "Employment" -> "Ann""#).contains { $0.contains("“Ann” isn't a type, so this arrow is not an end of “Employment”.") },
               "from a relationship type to a note")
        expect(try said(#"edge "Ann" -> "Bo" endRule: {"needed": true}"#).contains { $0.contains("endRule says something only on an arrow between a type and a relationship type.") },
               "a rule off an end")
        expect(try said(#"edge "Ann" -> "Bo" is: "Plain""#).contains { $0.contains("“Plain” isn't a relationship type, so nothing checks this arrow's ends. Mark it with relationship: true.") },
               "a plain type on an arrow")
        expectEqual(try said(#"edge "Ann" -> "Acme" is: "Employment""#), [], "a relationship that fits says nothing")
        expectEqual(try said(#"edge "Person" -> "Company""#), [], "a restated arrow that changes nothing is not warned of again")
    },
])

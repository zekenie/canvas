import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasRPC
import CanvasUI
import CoreGraphics
import Foundation
import Mentions
import Publishing
import References
import StickyNotes
import Subboards
import TestKit
import Titles
import Topology
import Types
import Validation

// A relationship to a note on another board, drawn by a script through a
// reference the same run makes, says in its row what the board says a moment later, in a run that draws the ends too.

@MainActor private struct FarWorld {
    let person = ShapeID(), employment = ShapeID(), company = ShapeID(), ann = ShapeID(), far = ShapeID(), acme = ShapeID(), zed = ShapeID(), hid = ShapeID()

    var file: CanvasFile {
        func note(_ id: ShapeID, _ title: String, at point: CGPoint, schema: Bool = false, marked: Bool = false, of type: ShapeID? = nil, public isPublic: Bool = false) -> AnyShapeRecord {
            var record = AnyShapeRecord(ShapeRecord(id: id, StickyNote(frame: CGRect(origin: point, size: CGSize(width: 200, height: 200)), text: MentionText(plain: title))))
            record[TitleProperty.self] = title
            if schema { record[TypeSchemaProperty.self] = SchemaText(#"{"type": "object", "properties": {}}"#) }
            if marked { record[RelationshipProperty.self] = true }
            if let type { record[IsAProperty.self] = [TypeLink(type)] }
            if !isPublic { record[PrivateProperty.self] = true }
            return record
        }
        var subboard = AnyShapeRecord(ShapeRecord(id: far, Subboard(frame: CGRect(x: 100, y: 900, width: 240, height: 160))))
        subboard[TitleProperty.self] = "Far"
        return CanvasFile(root: CanvasDocument(shapes: [note(person, "Person", at: CGPoint(x: 100, y: 100), schema: true),
                                                        note(employment, "Employment", at: CGPoint(x: 500, y: 100), schema: true, marked: true),
                                                        note(company, "Company", at: CGPoint(x: 900, y: 100), schema: true),
                                                        note(ann, "Ann", at: CGPoint(x: 100, y: 500), of: person),
                                                        subboard]),
                          children: [far: CanvasDocument(shapes: [note(acme, "Acme", at: CGPoint(x: 0, y: 0), of: company, public: true),
                                                                  note(zed, "Zed", at: CGPoint(x: 300, y: 0), of: person, public: true),
                                                                  note(hid, "Hid", at: CGPoint(x: 600, y: 0), of: company)])])
    }
}

private func rows(_ result: JSON) -> [JSON] { result["changes"]?.arrayValue ?? [] }
private func messages(_ result: JSON) -> [String] { (result["warnings"]?.arrayValue ?? []).compactMap { $0["message"]?.stringValue } }

@MainActor let drawRelationshipFarTests = Suite("A relationship to a far note, drawn with its ends in one run", [
    test("the rows and warnings the skill's relationships page prints are the rows and warnings a run of its story gives") {
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
        /// A row or a warning without where it is on the board, as the page prints one.
        func printed(_ value: JSON?) -> JSON? {
            guard var object = value?.objectValue else { return value }
            object["at"] = nil
            object["inView"] = nil
            object["id"] = nil   // the page's rows leave out the ids, which are each board's own
            return .object(object)
        }
        _ = try run(#"""
        sticky-note "Person" schema: "{\"type\": \"object\", \"properties\": {\"name\": {\"type\": \"string\"}}}" text: "A person: their name"
        sticky-note "Employment" right of "Person" relationship: true schema: "{\"type\": \"object\", \"properties\": {\"role\": {\"type\": \"string\"}, \"since\": {\"type\": \"string\", \"format\": \"date\"}}}" text: "A job: the role, and when it started"
        sticky-note "Company" right of "Employment" schema: "{\"type\": \"object\", \"properties\": {\"name\": {\"type\": \"string\"}}}" text: "A company: its name"
        """#)
        let ends = try run(#"""
        edge "Person" -> "Employment" text: "jobs" endRule: {"onlyOne": true}
        edge "Employment" -> "Company" text: "staff"
        """#)
        expectEqual(printed(ends["changes"]?.arrayValue?.first),
                    ["line": 1, "did": "connected", "kind": "arrow", "from": "Person", "to": "Employment", "channel": "note-link",
                     "endOf": ["type": "Employment", "side": "from", "row": "jobs", "onlyOne": true]], "the end's row, as the page prints it")
        _ = try run(#"""
        sticky-note "Ann" below "Person" is: "Person" fieldValues: {"name": "Ann Lee"}
        sticky-note "Acme" below "Company" is: "Company" fieldValues: {"name": "Acme"}
        edge "Ann" -> "Acme" is: "Employment" fieldValues: {"role": "Staff engineer", "since": "2021-03-01"}
        """#)
        let restated = try run(#"sticky-note "Employment""#)
        expectEqual(printed(restated["changes"]?.arrayValue?.first),
                    ["line": 1, "did": "unchanged", "kind": "sticky-note", "title": "Employment", "relates": ["from": ["Person"], "to": ["Company"]]],
                    "the relationship type restated, as the page prints it")
        let plain = try run(#"""
        sticky-note "Bo" right of "Ann" is: "Person" fieldValues: {"name": "Bo Park"}
        edge "Bo" -> "Acme"
        """#)
        expectEqual(printed(plain["changes"]?.arrayValue?.last),
                    ["line": 2, "did": "connected", "kind": "arrow", "from": "Bo", "to": "Acme", "channel": "note-link", "fits": ["Employment"]], "the plain arrow's row")
        let typed = try run(#"edge "Bo" -> "Acme" is: "Employment" fieldValues: {"role": "Analyst"}"#)
        expectEqual(printed(typed["changes"]?.arrayValue?.first),
                    ["line": 1, "did": "reconnected", "kind": "arrow", "from": "Bo", "to": "Acme", "channel": "note-link", "is": ["Employment"]], "the arrow that took the type")
        let misfit = try run(#"edge "Ann" -> "Bo" is: "Employment""#)
        expectEqual(printed(misfit["changes"]?.arrayValue?.first),
                    ["line": 1, "did": "connected", "kind": "arrow", "from": "Ann", "to": "Bo", "channel": "note-link", "is": ["Employment"],
                     "problems": [["field": "to", "class": "wrong", "message": "Employment runs to a Company. “Bo” is a Person."]]], "the misfit's row")
        expectEqual(misfit["warnings"]?.arrayValue ?? [],
                    [["line": 1, "severity": "error", "attribute": "to", "message": "edge \"Ann\" -> \"Bo\": Employment runs to a Company. “Bo” is a Person."],
                     ["line": 1, "severity": "error", "attribute": "jobs", "message": "\"Ann\": jobs has 2 notes, and should have at most 1"]],
                    "the misfit's warnings, as the page prints them: the arrow's own, and what the run brought to Ann, whom it did not write")
        _ = try run(#"""
        edge "Employment" -> "Company" text: "staff" endRule: {"needed": true}
        sticky-note "Initech" below "Acme" is: "Company" fieldValues: {"name": "Initech"}
        """#)
        let second = try run(#"edge "Bo" -> "Initech" is: "Employment""#)
        expectEqual(printed(second["changes"]?.arrayValue?.first),
                    ["line": 1, "did": "connected", "kind": "arrow", "from": "Bo", "to": "Initech", "channel": "note-link", "is": ["Employment"]],
                    "the one-line run's row, as the page prints it")
        expectEqual(second["warnings"]?.arrayValue ?? [],
                    [["line": 1, "severity": "error", "attribute": "jobs", "message": "\"Bo\": jobs has 2 notes, and should have at most 1"]],
                    "and its warning, which names Bo, whom the run did not write")
        // Bo's second job gone leaves Initech, which the run does not write, with no one in its Needed row: what it still needs is said at its own level.
        let left = try run(#"delete edge "Bo" -> "Initech" is: "Employment""#)
        expectEqual(left["changes"]?.arrayValue ?? [], [["line": 1, "did": "deleted", "kind": "arrow", "from": "Bo", "to": "Initech", "is": ["Employment"]]],
                    "the deleted arrow's row, as the page prints it")
        expectEqual(left["warnings"]?.arrayValue ?? [],
                    [["line": 1, "severity": "incomplete", "attribute": "staff", "message": "\"Initech\": staff is needed"]],
                    "and its warning, which names Initech, whom the run did not write: what it still needs, not an error")
        _ = try run(#"""
        sticky-note "Mentorship" below "Bo" relationship: true schema: "{\"type\": \"object\", \"properties\": {\"since\": {\"type\": \"string\", \"format\": \"date\"}}}" text: "One person guiding another, and since when"
        edge "Person" -> "Mentorship" text: "mentors"
        edge "Mentorship" -> "Person" text: "mentees"
        """#)
        _ = try run(#"edge "Ann" -> "Bo" is: "Mentorship" fieldValues: {"since": "2022-02-01"}"#)
        _ = try run(#"delete edge "Ann" -> "Bo" is: "Employment""#)
        let removed = try run(#"delete edge "Ann" -> "Bo""#)
        expectEqual(removed["changes"]?.arrayValue ?? [], [["line": 1, "did": "deleted", "kind": "arrow", "from": "Ann", "to": "Bo", "is": ["Mentorship"]]], "the deleted arrow's row")
        expectEqual(removed["warnings"]?.arrayValue ?? [],
                    [["line": 1, "severity": "warning", "attribute": "is", "message": "delete edge \"Ann\" -> \"Bo\": it removed an arrow of Mentorship, since a delete edge without is: removes every arrow of the pair"]],
                    "the warning of a delete edge without is:, as the page prints it")
    },
    test("a quoted second argument that is a plain note's title, on a board with no type, keeps the refusal's own hint and is not called a type") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = newBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        _ = try canvas(server, ["draw", "sticky-note \"Ann\"\nsticky-note \"Bo\" right of \"Ann\"\nedge \"Ann\" -> \"Bo\""])
        let refused = try canvas(server, ["query", #":edge-to("Bo", "Ann")"#])
        expectEqual(refused.status, 1)
        let error = try JSON(text: refused.error)["error"]
        expectEqual(error?["reason"], "bad_argument")
        let hint = error?["hint"]?.stringValue ?? ""
        expect(!hint.contains("is a type"), "Ann is a note with no schema, and the file has no type: \(hint)")
        expectEqual(hint, #":edge-to(:is("Bo", "Ann"))"#, "the hint the refusal had before: either shape")
        // And a bare word that happens to be a note's title, where an edge type was mistyped.
        _ = try canvas(server, ["draw", "sticky-note \"Mentions\" below \"Ann\""])
        let bare = try JSON(text: canvas(server, ["query", #":edge-to("Bo", mentions)"#]).error)["error"]
        expectEqual(bare?["reason"], "unknown_edge_type")
        expect(bare?["hint"]?.stringValue?.contains("is a type") == false, "Mentions is a plain note: \(bare?["hint"]?.stringValue ?? "")")
    },
    test("the ends and two relationships into references, one fitting and one not, in one script: the rows against the board") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let world = FarWorld()
        let board = windowedBoard()
        board.editor.replaceFile(with: world.file)
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let script = """
        edge "Person" -> "Employment" text: "jobs"
        edge "Employment" -> "Company" text: "staff"
        edge "Ann" -> "Acme" is: "Employment"
        edge "Ann" -> "Zed" is: "Employment"
        """
        let dryOut = try canvas(server, ["draw", "--dry-run", script])
        expectEqual(dryOut.status, 0, dryOut.error)
        let dry = try JSON(text: dryOut.output)
        let realOut = try canvas(server, ["draw", script])
        expectEqual(realOut.status, 0, realOut.error)
        let real = try JSON(text: realOut.output)
        let words = "Employment runs to a Company. “Zed” is a Person."
        func arrows(_ result: JSON) -> [JSON] { rows(result).filter { $0["kind"] == "arrow" } }
        expectEqual(arrows(real).map { $0["via"] }, [nil, nil, "reference", "reference"])
        expectEqual(arrows(real).map { $0["is"] }, [nil, nil, .array([.string("Employment")]), .array([.string("Employment")])])
        expectEqual(arrows(real).map { $0["endOf"]?["side"] }, ["from", "to", nil, nil])
        expectEqual(arrows(real).map { $0["problems"]?.arrayValue?.compactMap { $0["message"]?.stringValue } ?? [] }, [[], [], [], [words]], "the real run's rows")
        expectEqual(arrows(dry).map { $0["problems"]?.arrayValue?.compactMap { $0["message"]?.stringValue } ?? [] }, [[], [], [], [words]], "the dry run's rows")
        expectEqual((real["warnings"]?.arrayValue ?? []).filter { $0["severity"] == "error" }.compactMap { $0["message"]?.stringValue }.filter { $0.contains(words) }.count, 1,
                    "one error for the misfit: \(real["warnings"]?.arrayValue ?? [])")
        // The board, a moment later.
        let editor = board.editor
        let typed = editor.document.shapes.filter { $0.kind == Arrow.kind && !($0[IsAProperty.self] ?? []).isEmpty }
        expectEqual(typed.count, 2)
        expectEqual(typed.map { editor.validation?.result(for: $0.id)?.issues.map(\.message) ?? [] }, [[], [words]], "Validation's kept issues")
        let misfit = try JSON(text: canvas(server, ["query", "--brief", "arrow:misfit"]).output)
        expectEqual(misfit["count"], 1, ":misfit")
        let again = try JSON(text: canvas(server, ["draw", script]).output)
        expectEqual(rows(again).map { $0["did"] }, Array(repeating: "unchanged", count: rows(again).count), "run again")
        expectEqual(arrows(again).map { $0["problems"] }, arrows(real).map { $0["problems"] })
        expectEqual(arrows(again).map { $0["is"] }, arrows(real).map { $0["is"] })
        expectEqual(arrows(again).map { $0["endOf"] }, arrows(real).map { $0["endOf"] })
        // A plain arrow to the far note that fits says so.
        let plain = try JSON(text: canvas(server, ["draw", "--dry-run", #"delete edge "Ann" -> "Acme""# + "\n" + #"edge "Ann" -> "Acme""#]).output)
        expectEqual(rows(plain).last?["fits"], .array([.string("Employment")]), "a plain arrow into a reference that fits: \(rows(plain))")
        let removed = rows(plain).filter { $0["did"] == "deleted" && $0["kind"] == "arrow" }
        expectEqual(removed.map { $0["is"] }, [.array([.string("Employment")])], "the deleted arrow's row says what it was")
        expectEqual((plain["warnings"]?.arrayValue ?? []).compactMap { $0["message"]?.stringValue }.filter { $0.contains("removed an arrow of Employment") }.count, 1,
                    "\(plain["warnings"]?.arrayValue ?? [])")
    },
    test("a note on another board that is not public cannot be the end of an arrow, and the refusal draws nothing") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let world = FarWorld()
        let board = windowedBoard()
        board.editor.replaceFile(with: world.file)
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let before = board.editor.document.shapes.count
        let refused = try canvas(server, ["draw", #"edge "Ann" -> "Hid" is: "Employment""#])
        expectEqual(refused.status, 1, "a private note on another board is refused: \(refused.output) \(refused.error)")
        expectEqual(board.editor.document.shapes.count, before, "nothing was drawn")
    },
    test("a type related to itself is two arrows, each an end of the relationship type on its own side") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = newBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let schema = #"{\"type\": \"object\", \"properties\": {}}"#
        let out = try canvas(server, ["draw", """
        sticky-note "Person" schema: "\(schema)"
        sticky-note "Friendship" right of "Person" relationship: true schema: "\(schema)"
        edge "Person" -> "Friendship" text: "friends"
        edge "Friendship" -> "Person" text: "friends"
        """])
        expectEqual(out.status, 0, out.error)
        let result = try JSON(text: out.output)
        expectEqual(rows(result)[1]["relates"], .object(["from": .array([.string("Person")]), "to": .array([.string("Person")])]), "it runs from a Person to a Person")
        expectEqual(rows(result).compactMap { $0["endOf"]?["side"] }, ["from", "to"], "two arrows, one on each side")
        expectEqual(messages(result), [], "no warning: nothing is two-headed")
    },
])

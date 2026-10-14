import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasUI
import Connections
import CoreGraphics
import Foundation
import Mentions
import StickyNotes
import TestKit
import Titles
import Types
import Validation

// What a run says of the shapes it broke and did not write, through `canvas` as built: the line that brought it, a board a
// run deletes, the name of a shape with no title on another board, and the count after twenty.

private let model = #"""
sticky-note "Person" schema: "{\"type\": \"object\", \"properties\": {\"level\": {\"type\": \"string\"}}}" text: "A person: their level"
sticky-note "Employment" right of "Person" relationship: true schema: "{\"type\": \"object\", \"properties\": {\"role\": {\"type\": \"string\"}}}" text: "A job: the role"
sticky-note "Company" right of "Employment" schema: "{\"type\": \"object\", \"properties\": {\"name\": {\"type\": \"string\"}}}" text: "A company: its name"
edge "Person" -> "Employment" text: "jobs"
edge "Employment" -> "Company" text: "staff"
sticky-note "Ann" below "Person" is: "Person" fieldValues: {"level": "senior"}
sticky-note "Acme" below "Company" is: "Company" fieldValues: {"name": "Acme"}
sticky-note "Globex" below "Acme" is: "Company" fieldValues: {"name": "Globex"}
edge "Ann" -> "Acme" is: "Employment"
"""#

/// Every issue the engine keeps of the shapes on the board shown, by shape id.
@MainActor private func kept(_ board: BoardDocument) -> [ShapeID: [String]] {
    let editor = board.editor
    _ = editor.validation?.results
    var found: [ShapeID: [String]] = [:]
    for record in editor.document.shapes {
        let issues = editor.validation?.result(for: record.id)?.issues.map { "\($0.severity == .error ? "error" : $0.severity == .warning ? "warning" : "incomplete") \($0.field ?? "-"): \($0.message)" } ?? []
        if !issues.isEmpty { found[record.id] = issues }
    }
    return found
}

@MainActor private func name(_ id: ShapeID, _ board: BoardDocument) -> String {
    board.editor.shape(inFile: id).flatMap { board.editor.registry.title(of: $0) } ?? "(\(board.editor.shape(inFile: id)?.kind.rawValue ?? "gone"))"
}

@MainActor private struct World {
    let board: BoardDocument
    let server: CommandServer
    let pasteboard: NSPasteboard

    init() throws {
        pasteboard = NSPasteboard.withUniqueName()
        try configureBoards(pasteboard: pasteboard)
        board = windowedBoard()
        server = try startCommandServer(boards: [board], frontmost: board)
    }

    func stop() {
        server.stop()
        board.close()
        pasteboard.releaseGlobally()
    }

    func run(_ arguments: [String]) throws -> JSON {
        let result = try canvas(server, ["draw"] + arguments)
        expectEqual(result.status, 0, result.error)
        return try JSON(text: result.output)
    }

    /// Runs a script dry and for real: what a real run warned, the dry run having said the same.
    func ran(_ script: String) throws -> [JSON] {
        let dry = try run(["--dry-run", script])
        let result = try run([script])
        expectEqual(dry["warnings"], result["warnings"], "a dry run says what a real one does")
        return result["warnings"]?.arrayValue ?? []
    }
}

@MainActor let drawBroughtFarShippedTests = Suite("A run warns of what it breaks, far and near", [
    test("an end given a rule beside an unrelated statement keeps the line of the statement that brought the issue") {
        let w = try World()
        defer { w.stop() }
        _ = try w.run([model])
        _ = try w.run([#"edge "Ann" -> "Globex" is: "Employment""#])
        let alone = try w.ran(#"sticky-note "Zed" below "Globex" text: "z""#)
        expectEqual(alone.filter { $0["attribute"] != nil }.count, 0)
        let said = try w.ran("sticky-note \"Yan\" below \"Zed\" text: \"y\"\nedge \"Person\" -> \"Employment\" text: \"jobs\" endRule: {\"onlyOne\": true}")
        let ann = said.filter { $0["message"]?.stringValue?.hasPrefix("\"Ann\"") == true }
        expectEqual(ann.count, 1)
        expectEqual(ann.first?["line"], 2, "one statement brought it: the rule's")
    },
    test("a note renamed to the title of a note the same run deletes with its board shares no title, and the run says nothing of it") {
        let w = try World()
        defer { w.stop() }
        _ = try w.run([#"""
        sticky-note "Cart" text: "The cart"
        subboard "Area" right of "Cart"
        """#])
        _ = try w.run([#"sticky-note "Billing" in "Area" text: "The bills""#])
        let script = "delete \"Area\"\nsticky-note \"Cart\" title: \"Billing\""
        let dry = try w.run(["--dry-run", script])
        let real = try w.run([script])
        let titled = (real["warnings"]?.arrayValue ?? []).filter { $0["attribute"] == "title" }
        let board = kept(w.board).values.flatMap { $0 }
        expectEqual(board, [], "the board, once the run is in, has no issue: the only other Billing went with Area's board")
        expectEqual(titled, [], "so the run has none to say")
        expectEqual((dry["warnings"]?.arrayValue ?? []).filter { $0["attribute"] == "title" }, [], "nor a dry run")
    },
    test("a subboard deleted whose board holds the note a relationship runs to, through a pill, has the run say each issue the board gains") {
        let w = try World()
        defer { w.stop() }
        _ = try w.run([model])
        _ = try w.run([#"subboard "Area" right of "Company""#])
        _ = try w.run([#"sticky-note "Initech" in "Area" is: "Company" public: true fieldValues: {"name": "Initech"}"#])
        _ = try w.run([#"edge "Ann" -> "Initech" is: "Employment""#])
        let before = kept(w.board)
        let script = #"delete "Area""#
        let dry = try w.run(["--dry-run", script])
        let real = try w.run([script])
        let after = kept(w.board)
        var gained: [String] = []
        for (id, issues) in after { gained += issues.filter { !(before[id] ?? []).contains($0) }.map { "\(name(id, w.board)) \($0)" } }
        let said = (real["warnings"]?.arrayValue ?? []).filter { $0["attribute"] != nil }
        expectEqual(said.count, gained.count, "the run says each issue the board gained on a shape it did not write: \(gained)")
        expectEqual(dry["warnings"], real["warnings"])
    },
    test("an arrow with no title on the board shown, broken by a run, is named by its kind and where it is") {
        let w = try World()
        defer { w.stop() }
        _ = try w.run([model])
        _ = try w.run([#"subboard "Area" right of "Company""#])
        _ = try w.run([#"sticky-note "Initech" in "Area" is: "Company" public: true fieldValues: {"name": "Initech"}"#])
        _ = try w.run([#"edge "Ann" -> "Initech" is: "Employment""#])
        let editor = w.board.editor
        let pills = Set(editor.document.shapes.filter { $0.kind == "reference" }.map(\.id))
        let arrow = try require(editor.document.shapes.first { shape in
            shape.kind == "arrow" && (shape[IsAProperty.self] ?? []).count == 1 && !pills.isDisjoint(with: shape.boundShapes(in: editor.shapeContext))
        })
        let bounds = try require(editor.shapeContext.geometry(of: arrow.id)?.bounds)
        let real = try w.run([#"sticky-note "Initech" is: "Person""#])
        let said = try require((real["warnings"]?.arrayValue ?? []).first { $0["attribute"] == "to" }?["message"]?.stringValue)
        expect(said.hasPrefix("arrow at \(Int(bounds.midX.rounded())),\(Int(bounds.midY.rounded()))"), "the arrow's middle is at \(Int(bounds.midX.rounded())),\(Int(bounds.midY.rounded())): \(said)")
    },
    test("the count after twenty says a command that lists the shapes it counted, a warning among them") {
        let w = try World()
        defer { w.stop() }
        _ = try w.run([#"subboard "Area""#])
        var far: [String] = [], near: [String] = [], renames: [String] = []
        for index in 1...22 {
            let n = String(format: "%02d", index)
            far.append(#"sticky-note "B\#(n)" in "Area" \#(index == 1 ? "" : "below \"B\(String(format: "%02d", index - 1))\"") text: "b""#)
            near.append(#"sticky-note "C\#(n)" \#(index == 1 ? "below \"Area\"" : "below \"C\(String(format: "%02d", index - 1))\"") text: "c""#)
            renames.append(#"sticky-note "C\#(n)" title: "B\#(n)""#)
        }
        _ = try w.run([far.joined(separator: "\n")])
        _ = try w.run([near.joined(separator: "\n")])
        let result = try w.run([renames.joined(separator: "\n")])
        let warnings = result["warnings"]?.arrayValue ?? []
        let brought = warnings.filter { $0["message"]?.stringValue?.hasPrefix("\"B") == true }
        let last = try require(warnings.last?["message"]?.stringValue)
        expect(last.hasPrefix("and 2 more shapes now have issues"), last)
        // The command the count says to ask lists the shapes the run broke.
        let command = try require(last.components(separatedBy: "ask canvas query ").last).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let asked = try JSON(text: try canvas(w.server, ["query", command]).output)
        let listed = Set((asked["rows"]?.arrayValue ?? []).compactMap { $0["title"]?.stringValue })
        expect(listed.contains("B21") && listed.contains("B22"), "`canvas query \"\(command)\"` lists \(listed.count) shapes, and not the two the run counted: their issue is a warning, which \(command) does not match")
    },
    test("the count after twenty lists what shapes still need too: a type restated with a field newly needed, twenty-two notes the run does not restate") {
        let w = try World()
        defer { w.stop() }
        _ = try w.run([#"sticky-note "Person" schema: "{\"type\": \"object\", \"properties\": {\"level\": {\"type\": \"string\"}}}" text: "A person: their level""#])
        var notes: [String] = []
        for index in 1...22 {
            let n = String(format: "%02d", index), prior = String(format: "%02d", index - 1)
            notes.append(#"sticky-note "P\#(n)" \#(index == 1 ? "below \"Person\"" : "below \"P\(prior)\"") is: "Person" fieldValues: {"level": "a"}"#)
        }
        _ = try w.run([notes.joined(separator: "\n")])
        let result = try w.run([#"sticky-note "Person" schema: "{\"type\": \"object\", \"properties\": {\"level\": {\"type\": \"string\"}, \"team\": {\"type\": \"string\"}}, \"required\": [\"team\"]}" text: "A person: their level and team""#])
        let warnings = result["warnings"]?.arrayValue ?? []
        expectEqual(warnings.count, 21)
        expect(warnings.dropLast().allSatisfy { $0["severity"] == "incomplete" && $0["attribute"] == "team" && $0["line"] == 1 }, "\(warnings)")
        expectEqual(warnings.dropLast().compactMap { $0["message"]?.stringValue }, (1...20).map { "\"P" + String(format: "%02d", $0) + "\": team is needed" })
        let last = try require(warnings.last?["message"]?.stringValue)
        expectEqual(last, #"and 2 more shapes now have issues: ask canvas query ":invalid, :warned, :incomplete""#)
        // The command the count says to ask lists the shapes the run left needing something, the two counted among them.
        let command = try require(last.components(separatedBy: "ask canvas query ").last).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let asked = try JSON(text: try canvas(w.server, ["query", command]).output)
        let listed = Set((asked["rows"]?.arrayValue ?? []).compactMap { $0["title"]?.stringValue })
        expect(listed.contains("P21") && listed.contains("P22") && listed.count == 22, "`canvas query \"\(command)\"` lists \(listed.count) shapes: \(listed.sorted())")
    },
    test("a far note renamed to a near note's title warns of both") {
        let w = try World()
        defer { w.stop() }
        _ = try w.run([#"""
        sticky-note "Cart" text: "The cart"
        subboard "Area" right of "Cart"
        """#])
        _ = try w.run([#"sticky-note "Billing" in "Area" text: "The bills""#])
        let said = try w.ran(#"sticky-note "Billing" title: "Cart""#)
        expectEqual(said.filter { $0["attribute"] == "title" }.count, 2)
    },
    test("a type restated breaks an instance of a type built on it, once") {
        let w = try World()
        defer { w.stop() }
        _ = try w.run([model])
        _ = try w.run([#"sticky-note "Employee" below "Globex" is: "Person" schema: "{\"type\": \"object\", \"properties\": {\"badge\": {\"type\": \"string\"}}}" text: "An employee: a badge""#])
        _ = try w.run([#"sticky-note "Eve" below "Employee" is: "Employee" fieldValues: {"level": "senior", "badge": "7"}"#])
        let said = try w.ran(#"sticky-note "Person" schema: "{\"type\": \"object\", \"properties\": {\"level\": {\"type\": \"string\", \"enum\": [\"junior\", \"staff\"]}}}" text: "A person: their level, junior or staff""#)
        expectEqual(said.filter { $0["message"]?.stringValue?.hasPrefix("\"Eve\"") == true }.count, 1)
    },
    test("a type restated breaks an instance on another board") {
        let w = try World()
        defer { w.stop() }
        _ = try w.run([model])
        _ = try w.run([#"subboard "Area" right of "Company""#])
        _ = try w.run([#"sticky-note "Bea" in "Area" is: "Person" fieldValues: {"level": "senior"}"#])
        let said = try w.ran(#"sticky-note "Person" schema: "{\"type\": \"object\", \"properties\": {\"level\": {\"type\": \"string\", \"enum\": [\"junior\", \"staff\"]}}}" text: "A person: their level, junior or staff""#)
        expectEqual(said.filter { $0["message"]?.stringValue?.hasPrefix("\"Bea\"") == true }.count, 1, "Bea is on Area's board, and the run did not write her")
    },
    test("a dry run that would break a shape leaves the board, the issues it keeps and the next real run as they were") {
        let w = try World()
        defer { w.stop() }
        _ = try w.run([model])
        _ = try w.run([#"edge "Person" -> "Employment" text: "jobs" endRule: {"onlyOne": true}"#])
        let before = kept(w.board), revision = w.board.editor.revision
        let dry = try w.run(["--dry-run", #"edge "Ann" -> "Globex" is: "Employment""#])
        expectEqual((dry["warnings"]?.arrayValue ?? []).filter { $0["attribute"] != nil }.count, 1, "the dry run says what it would break")
        expectEqual(w.board.editor.revision, revision)
        expectEqual(kept(w.board), before)
        let real = try w.run([#"edge "Ann" -> "Globex" is: "Employment""#])
        expectEqual(real["warnings"], dry["warnings"])
    },
    test("a subboard's delete says the line of the one statement for the shapes its board's notes reached, dry and real") {
        let w = try World()
        defer { w.stop() }
        _ = try w.run([model])
        _ = try w.run([#"subboard "Area" right of "Company""#])
        _ = try w.run([#"sticky-note "Initech" in "Area" is: "Company" public: true fieldValues: {"name": "Initech"}"#])
        _ = try w.run([#"edge "Ann" -> "Initech" is: "Employment""#])
        for dry in [true, false] {
            let result = try w.run((dry ? ["--dry-run"] : []) + [#"delete "Area""#])
            let said = (result["warnings"]?.arrayValue ?? []).filter { $0["attribute"] != nil }
            expect(!said.isEmpty, "the delete brings issues (dry \(dry)): \(result["warnings"] ?? .null)")
            for warning in said { expectEqual(warning["line"], 1, "\(warning)") }
        }
    },
    test("a run on the root that empties the Needed row of an untitled note on a subboard's board names it by its id and the board once quoted") {
        let w = try World()
        defer { w.stop() }
        _ = try w.run([model])
        _ = try w.run([#"edge "Employment" -> "Company" text: "staff" endRule: {"needed": true}"#])
        _ = try w.run([#"subboard "Area" right of "Company""#])
        _ = try w.run([#"sticky-note "Hooli" in "Area" is: "Company" public: true"#])
        _ = try w.run([#"edge "Ann" -> "Hooli" is: "Employment""#])
        let editor = w.board.editor
        let area = try require(editor.document.shapes.first { editor.registry.title(of: $0) == "Area" }, "Area").id
        let hooli = try require(editor.file[BoardID(owner: area)].shapes.first { editor.registry.title(of: $0) == "Hooli" }, "Hooli on Area's board").id
        editor.transact(on: BoardID(owner: area), "Blank") {
            $0.update(hooli, as: StickyNote.self) { $0.props.text = MentionText(plain: "") }
            $0.update(hooli) { $0[TitleProperty.self] = nil }
        }
        let said = try w.ran(#"delete "Ann""#).compactMap { $0["message"]?.stringValue }
        let far = try require(said.first { $0.hasPrefix("#\(hooli)") }, "a warning naming Hooli by its id: \(said)")
        expect(far.hasPrefix("#\(hooli) on \"Area\"'s board: "), "the board is named once quoted: \(far)")
    },
    test("a pill a delete by id took has a deleted row with its kind alone, while the note the statement named has its id") {
        let w = try World()
        defer { w.stop() }
        _ = try w.run([model])
        _ = try w.run([#"subboard "Area" right of "Company""#])
        _ = try w.run([#"sticky-note "Initech" in "Area" is: "Company" public: true"#])
        _ = try w.run([#"edge "Ann" -> "Initech" is: "Employment""#])
        let editor = w.board.editor
        let ann = try require(editor.document.shapes.first { editor.registry.title(of: $0) == "Ann" }, "Ann").id
        let result = try w.run(["delete #\(ann.description)"])
        let rows = result["changes"]?.arrayValue ?? []
        let pill = try require(rows.first { $0["kind"]?.stringValue == "reference" }, "a deleted pill row: \(rows)")
        expectEqual(pill["id"], nil, "a pill has its kind alone: \(pill)")
        expectEqual(rows.first { $0["kind"]?.stringValue == "sticky-note" }?["id"], .string(ann.description))
    },
])

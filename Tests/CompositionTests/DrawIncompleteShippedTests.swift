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

// what a run says of what a shape still needs, through `canvas` as built.

private let model = #"""
sticky-note "Person" schema: "{\"type\": \"object\", \"properties\": {\"level\": {\"type\": \"string\"}}}" text: "A person: their level"
sticky-note "Employment" right of "Person" relationship: true schema: "{\"type\": \"object\", \"properties\": {\"role\": {\"type\": \"string\"}}}" text: "A job: the role"
sticky-note "Company" right of "Employment" schema: "{\"type\": \"object\", \"properties\": {\"name\": {\"type\": \"string\"}}}" text: "A company: its name"
edge "Person" -> "Employment" text: "jobs"
edge "Employment" -> "Company" text: "staff" endRule: {"needed": true}
sticky-note "Ann" below "Person" is: "Person" fieldValues: {"level": "senior"}
sticky-note "Acme" below "Company" is: "Company" fieldValues: {"name": "Acme"}
edge "Ann" -> "Acme" is: "Employment"
"""#

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
}

private func row(_ result: JSON, titled title: String) -> JSON? {
    (result["changes"]?.arrayValue ?? []).first { $0["title"]?.stringValue == title }
}

private func warnings(_ result: JSON, of title: String) -> [JSON] {
    (result["warnings"]?.arrayValue ?? []).filter { $0["message"]?.stringValue?.hasPrefix("\"\(title)\"") == true }
}

@MainActor let drawIncompleteShippedTests = Suite("what a run says of what a shape still needs, as shipped", [
    test("a note the script restates as it is, whose Needed row the same script empties, is told what it needs once: in its row's problems, not also as a warning") {
        let w = try World()
        defer { w.stop() }
        expectEqual(try w.run([model])["warnings"]?.arrayValue ?? [], [])
        let script = "sticky-note \"Acme\"\ndelete edge \"Ann\" -> \"Acme\" is: \"Employment\""
        let dry = try w.run(["--dry-run", script])
        let acme = try require(row(dry, titled: "Acme"))
        expectEqual(acme["did"], "unchanged")
        expectEqual(acme["problems"], [["field": "staff", "class": "needed", "message": "staff is needed"]], "its row says it")
        expectEqual(warnings(dry, of: "Acme"), [], "and so no warning says it again")
    },
    test("a type restated with a field newly needed and its instance restated as it is in the same script: the instance's row says it, and no warning says it again") {
        let w = try World()
        defer { w.stop() }
        expectEqual(try w.run([model])["warnings"]?.arrayValue ?? [], [])
        let script = #"""
        sticky-note "Person" schema: "{\"type\": \"object\", \"properties\": {\"level\": {\"type\": \"string\"}, \"team\": {\"type\": \"string\"}}, \"required\": [\"team\"]}" text: "A person: their level and team"
        sticky-note "Ann"
        """#
        let dry = try w.run(["--dry-run", script])
        let ann = try require(row(dry, titled: "Ann"))
        expectEqual(ann["did"], "unchanged")
        expectEqual(ann["problems"]?.arrayValue?.map { $0["class"] }, ["needed"], "its row says it")
        expectEqual(warnings(dry, of: "Ann"), [], "and so no warning says it again")
    },
    test("a note the run changes while its Needed row empties gets no warning and its row says it; one it makes, the same; a mend says nothing; the board rings nothing") {
        let w = try World()
        defer { w.stop() }
        expectEqual(try w.run([model])["warnings"]?.arrayValue ?? [], [])
        let made = try w.run([#"sticky-note "Globex" below "Acme" is: "Company" fieldValues: {"name": "Globex"}"#])
        expectEqual(made["warnings"]?.arrayValue ?? [], [], "a note the run makes")
        expectEqual(row(made, titled: "Globex")?["problems"], [["field": "staff", "class": "needed", "message": "staff is needed"]])
        let mended = try w.run([#"edge "Ann" -> "Globex" is: "Employment""#])
        expectEqual(mended["warnings"]?.arrayValue ?? [], [], "a mend")
        let changed = try w.run(["sticky-note \"Acme\" fieldValues: {\"name\": \"Acme Inc\"}\ndelete edge \"Ann\" -> \"Acme\" is: \"Employment\""])
        expectEqual(changed["warnings"]?.arrayValue ?? [], [], "a note the run changed")
        expectEqual(row(changed, titled: "Acme")?["problems"], [["field": "staff", "class": "needed", "message": "staff is needed"]])
        let editor = w.board.editor
        _ = editor.validation?.results
        let acme = try require(editor.document.shapes.first { editor.registry.title(of: $0) == "Acme" })
        expectEqual(editor.validation?.result(for: acme.id)?.issues.map(\.severity), [.incomplete])
        expectEqual(editor.validation?.result(for: acme.id)?.worst, nil)
        let asked = try JSON(text: try canvas(w.server, ["query", ":invalid, :warned, :incomplete"]).output)
        expectEqual((asked["rows"]?.arrayValue ?? []).compactMap { $0["title"]?.stringValue }, ["Acme"])
        expectEqual((asked["rows"]?.arrayValue ?? []).first?["problems"], [["field": "staff", "class": "needed", "message": "staff is needed"]])
    },
])

import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasUI
import Foundation
import References
import TestKit
import Titles
import Types

// The first minute of the relationships redesign (board 1), as an agent has it, through `canvas` as built: the types
// Feature and Layer and a relationship type between them in one run, a Feature and a Layer with their values and the
// relationship between them in the next, and, as the step 10 of board 1 asks, what the Feature is related to read
// back by a query. Nothing asks the model. The first test titles its notes; the second leaves them without, as a person's
// are: a script names a shape with no title by its id, the one a query's row gave, and a far one through its pill.

private let feature = scripted(#"{"type": "object", "properties": {"summary": {"type": "string"}}}"#)
private let layer = scripted(#"{"type": "object", "properties": {"depth": {"type": "integer"}}}"#)
private let inLayer = scripted(#"{"type": "object", "properties": {"since": {"type": "string", "format": "date"}}}"#)

@MainActor let agentFirstMinuteTests = Suite("Board 1, for an agent", [
    test("types and a relationship type with both ends in one run, two notes and their relationship in the next, and what the Feature is related to read back") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = newBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        @MainActor func rows(_ result: ProcessOutput) throws -> [JSON] {
            expectEqual(result.status, 0, result.error)
            return try JSON(text: result.output)["changes"]?.arrayValue ?? []
        }
        @MainActor func query(_ text: String, properties: [String] = []) throws -> JSON {
            let result = try canvas(server, ["query"] + properties.flatMap { ["--fields", $0] } + [text])
            expectEqual(result.status, 0, result.error)
            return try JSON(text: result.output)
        }

        // 1. The model: Feature, Layer, In layer from a Feature to a Layer, and its two ends, in one run (a dry run first).
        let model = """
        sticky-note "Feature" schema: "\(feature)" text: "A feature: its summary"
        sticky-note "In layer" right of "Feature" relationship: true schema: "\(inLayer)" text: "Which layer a feature lives in"
        sticky-note "Layer" right of "In layer" schema: "\(layer)" text: "A layer: how deep it sits"
        edge "Feature" -> "In layer" text: "layer" endRule: {"needed": true}
        edge "In layer" -> "Layer" text: "features"
        """
        let dry = try canvas(server, ["draw", "--dry-run", model])
        let dryRows = try rows(dry)
        expectEqual(dryRows.compactMap { $0["endOf"] }, [
            .object(["type": "In layer", "side": "from", "row": "layer", "needed": true]),
            .object(["type": "In layer", "side": "to", "row": "features"]),
        ], "a dry run says what each end became")
        expectEqual(board.editor.document.shapes.count, 0, "and changes nothing")
        let made = try canvas(server, ["draw", model])
        let madeRows = try rows(made)
        expectEqual(madeRows.first { $0["title"] == "In layer" }?["relates"], .object(["from": .array([.string("Feature")]), "to": .array([.string("Layer")])]),
                    "the relationship type says what it relates, by ends drawn in its own run")
        expectEqual(board.editor.undoHistory.undoName, "Draw")
        expectEqual(board.editor.document.shapes.count, 5)

        // 2. A Feature and a Layer, with values, and the relationship between them, with its own.
        let notes = """
        sticky-note "Checkout" below "Feature" is: "Feature" fieldValues: {"summary": "Pay for the cart"}
        sticky-note "foundation" below "Layer" is: "Layer" fieldValues: {"depth": 1}
        edge "Checkout" -> "foundation" is: "In layer" fieldValues: {"since": "2026-10-01"}
        """
        let related = try canvas(server, ["draw", notes])
        let relatedRows = try rows(related)
        expectEqual(relatedRows.last?["is"], .array([.string("In layer")]))
        expect(relatedRows.last?["problems"] == nil, "it fits")
        let warnings = try JSON(text: related.output)["warnings"]?.arrayValue ?? []
        expectEqual(warnings.count, 0, "nothing to say: \(warnings)")

        // 10. What the Feature is related to: one row, the Layer, with its values.
        let relatedTo = try query(#":end-of(arrow:is-a([relationship]):starts-at("Checkout")), :start-of(arrow:is-a([relationship]):ends-at("Checkout"))"#,
                                  properties: ["fieldValues"])
        expectEqual(relatedTo["count"], 1)
        expectEqual(relatedTo["rows"]?.arrayValue?.first?["title"], "foundation")
        expectEqual(relatedTo["rows"]?.arrayValue?.first?["properties"]?["fieldValues"], .object(["depth": 1]), "with its values")
        expectEqual(try query(#"arrow:is-a("In layer"):between("Checkout", "foundation")"#, properties: [])["count"], 1)
        expectEqual(try query("arrow:misfit")["count"], 0)
        let arrow = try query(#"arrow:is-a("In layer")"#, properties: ["fieldValues"])
        expectEqual(arrow["rows"]?.arrayValue?.first?["properties"]?["fieldValues"], .object(["since": "2026-10-01"]), "the relationship holds its values")

        // The same again changes nothing; one Undo takes the second run back whole.
        let again = try canvas(server, ["draw", notes])
        expectEqual(try rows(again).map { $0["did"] }, ["unchanged", "unchanged", "unchanged"])
        board.editor.undo()
        expectEqual(board.editor.document.shapes.count, 5, "the notes and the relationship together")
    },
    test("board 1 with notes that have no title: related by the two ids a query gave, read back, and again; a far note with none through its pill") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = newBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        @MainActor func draw(_ script: String, _ options: [String] = []) throws -> JSON {
            let result = try canvas(server, ["draw"] + options + [script])
            expectEqual(result.status, 0, result.error)
            return try JSON(text: result.output)
        }
        @MainActor func query(_ text: String, properties: [String] = []) throws -> JSON {
            let result = try canvas(server, ["query"] + properties.flatMap { ["--fields", $0] } + [text])
            expectEqual(result.status, 0, result.error)
            return try JSON(text: result.output)
        }
        func rows(_ result: JSON) -> [JSON] { result["changes"]?.arrayValue ?? [] }

        // The model, as in board 1: the types and the relationship type with both ends, in one run.
        _ = try draw("""
            sticky-note "Feature" schema: "\(feature)" text: "A feature: its summary"
            sticky-note "In layer" right of "Feature" relationship: true schema: "\(inLayer)" text: "Which layer a feature lives in"
            sticky-note "Layer" right of "In layer" schema: "\(layer)" text: "A layer: how deep it sits"
            edge "Feature" -> "In layer" text: "layer" endRule: {"needed": true}
            edge "In layer" -> "Layer" text: "features"
            """)
        // The user's notes: no titles, only values. Nothing names them but their ids.
        let notes = """
            sticky-note is: "Feature" fieldValues: {"summary": "Pay for the cart"} below "Feature"
            sticky-note is: "Layer" fieldValues: {"depth": 1} below "Layer"
            """
        let dry = try draw(notes, ["--dry-run"])
        expectEqual(rows(dry).map { $0["title"] }, [nil, nil], "no title")
        expectEqual(rows(dry).map { $0["id"] }, [nil, nil], "a dry run's created rows have no id")
        let made = rows(try draw(notes))
        expectEqual(made.compactMap { $0["id"]?.stringValue }.count, 2, "a real run's rows say the ids")
        expectEqual(try query(#":incomplete"#)["count"], 1, "the Feature note's Needed layer row is empty")

        // A query finds them, and its rows give the ids.
        let found = try query(#"sticky-note:not([title]):is-a("Feature"), sticky-note:not([title]):is-a("Layer")"#)
        let ids = try require(found["rows"]?.arrayValue).compactMap { $0["id"]?.stringValue }
        expectEqual(ids.count, 2)
        expectEqual(ids, made.compactMap { $0["id"]?.stringValue }, "the ids the run said are the ids the query gives")
        let (featureID, layerID) = (ids[0], ids[1])

        // They are related by those two ids.
        let relate = "edge #\(featureID) -> #\(layerID) is: \"In layer\" fieldValues: {\"since\": \"2026-10-01\"}"
        let planned = try draw(relate, ["--dry-run"])
        expectEqual(rows(planned).first?["is"], .array([.string("In layer")]))
        expectEqual(rows(planned).first?["fromId"], .string(featureID))
        expectEqual(rows(planned).first?["toId"], .string(layerID))
        expectEqual(board.editor.document.shapes.count, 7, "the dry run drew nothing")
        let related = try draw(relate)
        let row = try require(rows(related).first)
        expectEqual(row["did"], "connected")
        expectEqual(row["is"], .array([.string("In layer")]))
        expectEqual(row["from"], .string("#\(featureID)"), "an end with no title is called by the id as written")
        expect(row["problems"] == nil, "it fits")
        expectEqual((related["warnings"]?.arrayValue ?? []).count, 0)
        expectEqual(board.editor.undoHistory.undoName, "Draw")
        expectEqual(try query(#":incomplete"#)["count"], 0, "the Feature's Needed row is filled")

        // Step 10 of board 1, by id: what the Feature is related to is one row, the Layer, with its values.
        let relatedTo = try query(":end-of(arrow:is-a([relationship]):starts-at(#\(featureID)))", properties: ["fieldValues"])
        expectEqual(relatedTo["count"], 1)
        expectEqual(relatedTo["rows"]?.arrayValue?.first?["id"], .string(layerID))
        expectEqual(relatedTo["rows"]?.arrayValue?.first?["properties"]?["fieldValues"], .object(["depth": 1]))
        expectEqual(try query("arrow:misfit")["count"], 0)

        // An arrow has no name a script could write: its id is refused, in the shipped app's own words for its kind.
        let arrowID = try require(try query("arrow:is-a([relationship])")["rows"]?.arrayValue?.first?["id"]?.stringValue)
        let named = try canvas(server, ["draw", "edge \"Feature\" -> #\(arrowID)"])
        expectEqual(named.status, 1)
        let refusal = try require(try JSON(text: named.error)["error"])
        expectEqual(refusal["reason"], "invalid_value")
        expect(named.error.contains("#\(arrowID) is an arrow, which a script can't name"), named.error)

        // The relationship is taken back by its ends, one of them an id, and its type: a typed arrow is found as a titled one is.
        let taken = try draw("delete edge #\(featureID) -> #\(layerID) is: \"In layer\"")
        expectEqual(rows(taken).map { $0["did"] }, ["deleted"])
        expectEqual(board.editor.undoHistory.undoName, "Draw")
        board.editor.undo()
        expectEqual(try query("arrow:is-a([relationship])")["count"], 1, "one Undo gives it back")

        // Written again it is the same arrow; one Undo takes the relationship back and nothing else.
        expectEqual(rows(try draw(relate)).map { $0["did"] }, ["unchanged"])
        board.editor.undo()
        expectEqual(board.editor.document.shapes.count, 7, "the relationship is gone, the notes stay")
        _ = try draw(relate)

        // A note with no title on another board, public as every shape is: an edge to its id goes through a pill.
        _ = try draw(#"subboard "Archive" below board"#)
        _ = try draw(#"sticky-note is: "Layer" fieldValues: {"depth": 9} in "Archive""#)
        let everything = try query(#"sticky-note:not([title]):is-a("Layer")"#)
        let far = try require(try require(everything["rows"]?.arrayValue).first { $0["board"] != "root" }?["id"]?.stringValue)
        let through = try draw("edge #\(featureID) -> #\(far) is: \"In layer\"")
        expectEqual(rows(through).map { $0["did"] }, ["created", "connected"])
        expectEqual(rows(through).last?["via"], "reference")
        expectEqual(rows(through).last?["toId"], .string(far))
        let pills = board.editor.document.shapes.compactMap { $0.typed(as: Reference.self) }
        expectEqual(pills.count, 1)
        expectEqual(pills.first?.props.target?.label, "9", "the pill is called what the note is called where it has no title: its values")
        expectEqual(pills.first?.props.target?.id.description, far)
        let both = try query(":end-of(arrow:is-a([relationship]):starts-at(#\(featureID)))")
        expectEqual(Set(try require(both["rows"]?.arrayValue).compactMap { $0["id"]?.stringValue }), [layerID, far], "read through the pill")
        expectEqual(try query("arrow:misfit")["count"], 0)
        expectEqual(rows(try draw("edge #\(featureID) -> #\(far) is: \"In layer\"")).map { $0["did"] }, ["unchanged"], "found where the pill is")
    },
])

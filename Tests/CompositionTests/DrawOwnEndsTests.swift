import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasUI
import Foundation
import TestKit
import Titles
import Types

// A run that sees its own ends, through `canvas` as built over a socket of its own: one script that draws the types,
// a relationship type with its ends and the notes of those types reports the frames the board then has (the notes
// are laid out with the rows the run's own ends give them), a dry run says the same, and `canvas measure` of the
// script says the same sizes. (The script is board 1's: Feature, Layer and what relates them.)

private let feature = scripted(#"{"type": "object", "properties": {"summary": {"type": "string"}, "owner": {"type": "string"}, "estimate": {"type": "string"}, "status": {"type": "string"}, "risk": {"type": "string"}, "notes": {"type": "string"}}}"#)
private let layer = scripted(#"{"type": "object", "properties": {"depth": {"type": "integer"}}}"#)
private let inLayer = scripted(#"{"type": "object", "properties": {"since": {"type": "string", "format": "date"}}}"#)

/// The types and what relates them: three notes and two ends.
private let model = """
sticky-note "Feature" schema: "\(feature)" text: "A feature: its summary"
sticky-note "In layer" right of "Feature" relationship: true schema: "\(inLayer)" text: "Which layer a feature lives in"
sticky-note "Layer" right of "In layer" schema: "\(layer)" text: "A layer: how deep it sits"
edge "Feature" -> "In layer" text: "layer" endRule: {"needed": true}
edge "In layer" -> "Layer" text: "features"
"""

/// Two notes of those types and the relationship between them, and a plain note placed below the first.
private let instances = """
sticky-note "Checkout" below "Feature" is: "Feature" fieldValues: {"summary": "Pay for the cart"}
sticky-note "foundation" below "Layer" is: "Layer" fieldValues: {"depth": 1}
edge "Checkout" -> "foundation" is: "In layer" fieldValues: {"since": "2026-10-01"}
sticky-note "Later" below "Checkout" text: "Placed below the Feature"
"""

private func rows(_ output: String) throws -> [JSON] { try JSON(text: output)["changes"]?.arrayValue ?? [] }

/// A row's frame, from its `at`: `[[x, y], [width, height]]`.
private func frame(_ row: JSON?) -> CGRect? {
    guard let at = row?["at"]?.arrayValue, at.count == 2, let origin = at[0].arrayValue?.compactMap(\.numberValue),
          let size = at[1].arrayValue?.compactMap(\.numberValue), origin.count == 2, size.count == 2 else { return nil }
    return CGRect(x: origin[0], y: origin[1], width: size[0], height: size[1])
}

private func size(_ json: JSON?) -> CGSize? {
    guard let values = json?.arrayValue?.compactMap(\.numberValue), values.count == 2 else { return nil }
    return CGSize(width: values[0], height: values[1])
}

/// The frame the board has for the shape called `title`.
@MainActor private func boardFrame(_ title: String, on board: BoardDocument) throws -> CGRect {
    let editor = board.editor
    let record = try require(editor.document.shapes.first { editor.registry.title(of: $0) == title })
    return try require(editor.shapeContext.frame(of: record.id))
}

@MainActor let drawOwnEndsTests = Suite("A run sees its own ends", [
    test("one script that draws the types, the ends and the notes reports the frames the board has: a dry run says the same, and the shape below is clear of the note's rows") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = newBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let script = model + "\n" + instances
        let dry = try canvas(server, ["draw", "--dry-run", script])
        expectEqual(dry.status, 0, dry.error)
        expectEqual(board.editor.document.shapes.count, 0, "a dry run changes nothing")
        let made = try canvas(server, ["draw", script])
        expectEqual(made.status, 0, made.error)
        let drawn = try rows(made.output)
        let dryRows = try rows(dry.output)
        expectEqual(drawn.count, 9)
        // Every shape's row is the frame the board has a moment later, the type notes' included (they list their ends).
        for row in drawn {
            guard let title = row["title"]?.stringValue else { continue }
            expectEqual(frame(row), try boardFrame(title, on: board), "\(title): the row's frame is the board's")
        }
        expectEqual(dryRows.map { frame($0) }, drawn.map { frame($0) }, "a dry run says what a real run says")
        // The rows are there: the notes are taller than the same notes drawn where the types have no ends.
        let plain = newBoard()
        defer { plain.close() }
        let plainServer = try startCommandServer(boards: [plain], frontmost: plain)
        defer { plainServer.stop() }
        let without = try canvas(plainServer, ["draw", model.split(separator: "\n").prefix(3).joined(separator: "\n") + "\n" + instances.split(separator: "\n").filter { !$0.hasPrefix("edge") }.joined(separator: "\n")])
        expectEqual(without.status, 0, without.error)
        let plainRows = try rows(without.output)
        let withRows = try require(frame(drawn.first { $0["title"] == "Feature" })), withoutRows = try require(frame(plainRows.first { $0["title"] == "Feature" }))
        expect(withRows.height > withoutRows.height, "the Feature type lists its end: \(withRows.height) against \(withoutRows.height)")
        // The note placed below the Feature note is clear of it as the board has it.
        let later = try require(frame(drawn.first { $0["title"] == "Later" }))
        let checkout = try require(frame(drawn.first { $0["title"] == "Checkout" }))
        expect(later.minY >= checkout.maxY, "\(later) is below \(checkout)")
        expect(!later.intersects(try boardFrame("Checkout", on: board)))
        // No warning on the way: the relationship fits, and it is the run's own ends that say so.
        let warnings = try JSON(text: made.output)["warnings"]?.arrayValue ?? []
        expectEqual(warnings.count, 0, "\(warnings)")
        // The same again changes nothing, and still says the frames the board has; one Undo takes the lot back.
        let again = try canvas(server, ["draw", script])
        expectEqual(try rows(again.output).map { $0["did"] }, Array(repeating: "unchanged", count: 9))
        expectEqual(try rows(again.output).map { frame($0) }, drawn.map { frame($0) })
        expectEqual(board.editor.undoHistory.undoName, "Draw")
        board.editor.undo()
        expectEqual(board.editor.document.shapes.count, 0)
    },

    test("canvas measure of the script says the sizes a run of it gives: alone, and given a board that holds the types and their ends") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = newBoard(), empty = newBoard()
        defer { board.close(); empty.close() }
        let server = try startCommandServer(boards: [board, empty], frontmost: empty)
        defer { server.stop() }
        let script = model + "\n" + instances
        // Measured on an empty board: the script alone, ends and all.
        let before = empty.editor.file, revision = empty.editor.revision, step = empty.editor.undoHistory.undoName
        let alone = try canvas(server, ["measure", "-"], input: script)
        expectEqual(alone.status, 0, alone.error)
        let measured = try JSON(text: alone.output)
        expectEqual(measured["warnings"], nil, "nothing it could not find: \(String(describing: measured["warnings"]))")
        expect(empty.editor.file == before && empty.editor.revision == revision && empty.editor.undoHistory.undoName == step, "the board is as it was")
        let made = try canvas(server, ["draw", "--board", "\(board.number)", script])
        expectEqual(made.status, 0, made.error)
        let drawn = try rows(made.output)
        let shapes = try require(measured["shapes"]?.arrayValue)
        expectEqual(shapes.count, 6, "the six notes")
        for shape in shapes {
            let title = try require(shape["title"]?.stringValue)
            let row = try require(drawn.first { $0["title"]?.stringValue == title })
            expectEqual(size(shape["size"]), frame(row)?.size, "\(title): measure says what the run's row says")
            expectEqual(size(shape["size"]), try boardFrame(title, on: board).size, "\(title): and what the board has")
        }
        // Given a board that holds the types and their ends, the notes alone measure as the run draws them.
        let notesOnly = try canvas(server, ["measure", "--board", "\(board.number)", "-"], input: #"""
        sticky-note "Pay" is: "Feature"
        sticky-note "base" is: "Layer"
        sticky-note "Plain"
        """#)
        expectEqual(notesOnly.status, 0, notesOnly.error)
        let notes = try require(JSON(text: notesOnly.output)["shapes"]?.arrayValue)
        let drew = try canvas(server, ["draw", "--board", "\(board.number)", #"""
        sticky-note "Pay" below "Later" is: "Feature"
        sticky-note "base" right of "Pay" is: "Layer"
        sticky-note "Plain" right of "base"
        """#])
        expectEqual(drew.status, 0, drew.error)
        let drewRows = try rows(drew.output)
        expectEqual(notes.map { size($0["size"]) }, drewRows.map { frame($0)?.size }, "given the board's types and ends")
        expectEqual(try JSON(text: notesOnly.output)["warnings"], nil)
    },

    test("a delete edge in the script takes the row away from a type note the same script restates: the row is the board's frame, and the end drawn again brings it back") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = newBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        expectEqual(try canvas(server, ["draw", model]).status, 0)
        let listed = try boardFrame("Feature", on: board)
        let restated = #"sticky-note "Feature" schema: "\#(feature)" text: "A feature: its summary""#
        // The end deleted and the type restated in one run: the type is laid out without the row it had.
        let removal = "delete edge \"Feature\" -> \"In layer\"\n" + restated
        let dry = try canvas(server, ["draw", "--dry-run", removal])
        expectEqual(dry.status, 0, dry.error)
        let removed = try canvas(server, ["draw", removal])
        expectEqual(removed.status, 0, removed.error)
        let row = try require(try rows(removed.output).first { $0["title"] == "Feature" })
        expectEqual(frame(row), try boardFrame("Feature", on: board), "the row is the board's frame")
        expect(try require(frame(row)).height < listed.height, "without its end the type note is shorter: \(String(describing: frame(row))) against \(listed)")
        expectEqual(try rows(dry.output).first { $0["title"] == "Feature" }.flatMap(frame), frame(row), "a dry run says the same")
        // And the end written again in the same run as the restated type: the row is back, at the frame the board has.
        let back = try canvas(server, ["draw", restated + "\n" + #"edge "Feature" -> "In layer" text: "layer" endRule: {"needed": true}"#])
        expectEqual(back.status, 0, back.error)
        let again = try require(try rows(back.output).first { $0["title"] == "Feature" })
        expectEqual(frame(again), try boardFrame("Feature", on: board))
        expectEqual(frame(again)?.height, listed.height, "listing its end again, as it did")
    },

    test("an end restated with other words is one end, not two: the type note has the rows it had, at the frame the board has, and a measure of the script says it") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = newBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        expectEqual(try canvas(server, ["draw", model]).status, 0)
        let listed = try boardFrame("Feature", on: board)
        let script = #"edge "Feature" -> "In layer" text: "layers" endRule: {"needed": true}"# + "\n" + #"sticky-note "Feature" schema: "\#(feature)" text: "A feature: its summary""#
        let result = try canvas(server, ["draw", script])
        expectEqual(result.status, 0, result.error)
        let changes = try rows(result.output)
        expectEqual(changes.first?["did"], "reconnected", "the same arrow, with its row renamed")
        let row = try require(changes.first { $0["title"] == "Feature" })
        expectEqual(frame(row), try boardFrame("Feature", on: board), "the row is the board's frame")
        expectEqual(frame(row)?.height, listed.height, "one row for the end, not two")
        expectEqual(board.editor.document.shapes.filter { $0.kind.rawValue == "arrow" }.count, 2, "no second arrow")
    },

    test("an edge through a reference stays a sizing in a measure: the reference is sized and no arrow is drawn, and a plain edge is laid out with the notes") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = newBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        // A note that is not public: a draw would refuse the pill, a measure only sizes it.
        let script = """
        sticky-note "Hub" text: "Many arrows point here"
        sticky-note "Spoke" text: "One of them"
        edge "Spoke" -> "Hub" via: reference
        edge "Spoke" -> "Hub"
        """
        let asked = try canvas(server, ["measure", "-"], input: script)
        expectEqual(asked.status, 0, asked.error)
        let json = try JSON(text: asked.output)
        expectEqual(json["references"]?.arrayValue?.count, 1, "the pill is sized")
        expectEqual(json["shapes"]?.arrayValue?.count, 2)
        expectEqual(json["warnings"], nil)
        expectEqual(board.editor.document.shapes.count, 0, "nothing is drawn")
    },
])

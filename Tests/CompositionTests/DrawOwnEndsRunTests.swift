import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasUI
import Draw
import Foundation
import TestKit
import Titles
import Types

// More of a run that sees its own ends (DrawOwnEndsTests): other statement orders, other boards, ends added and deleted over
// notes, a measure given a board, the limit, and an edge through a reference to a shape the run draws.

private func schema(_ count: Int, _ prefix: String) -> String {
    let properties = (1...count).map { "\"\(prefix)\($0)\": {\"type\": \"string\"}" }.joined(separator: ", ")
    return scripted("{\"type\": \"object\", \"properties\": {\(properties)}}")
}

private let big = schema(12, "f"), small = schema(1, "d"), held = schema(1, "s")

private let types = """
sticky-note "Feature" schema: "\(big)" text: "A feature"
sticky-note "In layer" right of "Feature" relationship: true schema: "\(held)" text: "Which layer"
sticky-note "Layer" right of "In layer" schema: "\(big)" text: "A layer"
"""
private let ends = """
edge "Feature" -> "In layer" text: "layer" endRule: {"needed": true}
edge "In layer" -> "Layer" text: "features"
"""
private let notes = """
sticky-note "Checkout" below "Feature" is: "Feature" fieldValues: {"f1": "Pay"}
sticky-note "foundation" below "Layer" is: "Layer" fieldValues: {"f1": "x"}
sticky-note "Later" below "Checkout" text: "Placed below"
sticky-note "Deeper" below "foundation" text: "Placed below"
"""
private let relation = #"edge "Checkout" -> "foundation" is: "In layer""#

private func rows(_ output: String) throws -> [JSON] { try JSON(text: output)["changes"]?.arrayValue ?? [] }

private func frame(_ row: JSON?) -> CGRect? {
    guard let at = row?["at"]?.arrayValue, at.count == 2, let origin = at[0].arrayValue?.compactMap(\.numberValue),
          let size = at[1].arrayValue?.compactMap(\.numberValue), origin.count == 2, size.count == 2 else { return nil }
    return CGRect(x: origin[0], y: origin[1], width: size[0], height: size[1])
}

private func size(_ json: JSON?) -> CGSize? {
    guard let values = json?.arrayValue?.compactMap(\.numberValue), values.count == 2 else { return nil }
    return CGSize(width: values[0], height: values[1])
}

/// The frame the file has for the shape called `title`, on whichever board.
@MainActor private func fileFrame(_ title: String, in board: BoardDocument) throws -> CGRect {
    let editor = board.editor
    let all = editor.file.root.shapes + editor.file.children.values.flatMap(\.shapes)
    let record = try require(all.first { editor.registry.title(of: $0) == title }, "no shape called \(title)")
    if let reading = editor.file.board(containing: record.id).flatMap({ editor.reading(of: $0) }) {
        return try require(reading.shapes.frame(of: record.id))
    }
    return try require(editor.shapeContext.frame(of: record))
}

/// Runs `script` dry, then for real, then again, and holds each row's `at` to the board; a measure too, when asked.
@MainActor @discardableResult
private func agree(_ server: CommandServer, _ board: BoardDocument, _ script: String, _ label: String, measured: Bool = true, rerun: Bool = true) throws -> [JSON] {
    let number = "\(board.number)"
    var sizes: [String: CGSize] = [:]
    if measured {
        let asked = try canvas(server, ["measure", "--board", number, "-"], input: script)
        expectEqual(asked.status, 0, "\(label): measure: \(asked.error)")
        let json = try JSON(text: asked.output)
        expectEqual(json["warnings"], nil, "\(label): measure warned")
        for shape in json["shapes"]?.arrayValue ?? [] {
            if let title = shape["title"]?.stringValue, let size = size(shape["size"]) { sizes[title] = size }
        }
    }
    let dry = try canvas(server, ["draw", "--board", number, "--dry-run", "-"], input: script)
    expectEqual(dry.status, 0, "\(label): dry: \(dry.error)")
    let made = try canvas(server, ["draw", "--board", number, "-"], input: script)
    expectEqual(made.status, 0, "\(label): draw: \(made.error)")
    let drawn = try rows(made.output), dryRows = try rows(dry.output)
    for row in drawn {
        guard let title = row["title"]?.stringValue, row["did"] != "deleted" else { continue }
        expectEqual(frame(row), try fileFrame(title, in: board), "\(label): \(title): the row's frame is the board's")
        if measured, let size = sizes[title] { expectEqual(size, frame(row)?.size, "\(label): \(title): measure says the row's size") }
    }
    expectEqual(dryRows.map { frame($0) }, drawn.map { frame($0) }, "\(label): a dry run says what a real run says")
    guard rerun, !script.contains("delete ") else { return drawn }
    let again = try canvas(server, ["draw", "--board", number, "-"], input: script)
    expectEqual(again.status, 0, "\(label): again: \(again.error)")
    // (A reference a run made for an edge has a row only in the run that made it.)
    for row in try rows(again.output) {
        expectEqual(row["did"], "unchanged", "\(label): \(row["title"]?.stringValue ?? "an edge"): the same again changes nothing")
        guard let title = row["title"]?.stringValue else { continue }
        expectEqual(frame(row), frame(drawn.first { $0["title"]?.stringValue == title }), "\(label): \(title): and says the same frame")
    }
    return drawn
}

@MainActor private func stage() throws -> (BoardDocument, CommandServer, NSPasteboard) {
    let pasteboard = NSPasteboard.withUniqueName()
    try configureBoards(pasteboard: pasteboard)
    let board = windowedBoard()
    let server = try startCommandServer(boards: [board], frontmost: board)
    return (board, server, pasteboard)
}

@MainActor private func clear(_ a: String, _ b: String, in board: BoardDocument, _ label: String) throws {
    let first = try fileFrame(a, in: board), second = try fileFrame(b, in: board)
    expect(!first.intersects(second), "\(label): \(a) \(first) is clear of \(b) \(second)")
}

@MainActor let drawOwnEndsRunTests = Suite("A run sees its own ends, through the app's commands", [
    test("an instance note grows by its row in a one-script run: the row is the board's frame, a measure, a dry run and the same again say the same, and what is placed below is clear") {
        let (board, server, pasteboard) = try stage()
        defer { board.close(); server.stop(); pasteboard.releaseGlobally() }
        let drawn = try agree(server, board, [types, ends, notes, relation].joined(separator: "\n"), "one script")
        let plain = windowedBoard()
        defer { plain.close() }
        let plainServer = try startCommandServer(boards: [plain], frontmost: plain)
        defer { plainServer.stop() }
        let without = try rows(try canvas(plainServer, ["draw", "-"], input: types + "\n" + notes).output)
        let tall = try require(frame(drawn.first { $0["title"] == "Checkout" })), short = try require(frame(without.first { $0["title"] == "Checkout" }))
        expect(tall.height > short.height, "the instance grows by its row: \(tall.height) against \(short.height)")
        try clear("Checkout", "Later", in: board, "one script")
        try clear("foundation", "Deeper", in: board, "one script")
    },

    test("the statements of a one-script run in the reverse order lay out as the board has them") {
        let (board, server, pasteboard) = try stage()
        defer { board.close(); server.stop(); pasteboard.releaseGlobally() }
        let script = [relation, notes.split(separator: "\n").reversed().joined(separator: "\n"), ends, types.split(separator: "\n").reversed().joined(separator: "\n")].joined(separator: "\n")
        try agree(server, board, script, "reversed")
        try clear("Checkout", "Later", in: board, "reversed")
        try clear("foundation", "Deeper", in: board, "reversed")
    },

    test("notes in a frame the script draws its types beside are laid out with their rows, and a measure agrees") {
        let (board, server, pasteboard) = try stage()
        defer { board.close(); server.stop(); pasteboard.releaseGlobally() }
        expectEqual(try canvas(server, ["draw", "-"], input: #"frame "Sprint" size: 1400x1600"#).status, 0)
        let inFrame = """
        sticky-note "Checkout" in "Sprint" is: "Feature" fieldValues: {"f1": "Pay"}
        sticky-note "foundation" in "Sprint" right of "Checkout" is: "Layer" fieldValues: {"f1": "x"}
        sticky-note "Later" in "Sprint" below "Checkout" text: "Placed below"
        sticky-note "Deeper" in "Sprint" below "foundation" text: "Placed below"
        """
        let script = [types.replacingOccurrences(of: #"sticky-note "Feature""#, with: #"sticky-note "Feature" right of "Sprint""#), ends, inFrame, relation].joined(separator: "\n")
        try agree(server, board, script, "frame")
        try clear("Checkout", "Later", in: board, "frame")
        try clear("foundation", "Deeper", in: board, "frame")
    },

    test("a whole model drawn on a subboard's board is laid out with its rows") {
        let (board, server, pasteboard) = try stage()
        defer { board.close(); server.stop(); pasteboard.releaseGlobally() }
        expectEqual(try canvas(server, ["draw", "-"], input: #"subboard "Sub""#).status, 0)
        let script = [types, ends, notes, relation].joined(separator: "\n").split(separator: "\n").map { line -> String in
            line.hasPrefix("edge") ? String(line) : line.replacingOccurrences(of: "sticky-note \"", with: "sticky-note in \"Sub\" \"", options: [], range: line.range(of: "sticky-note \""))
        }.joined(separator: "\n")
        let moved = script.replacingOccurrences(of: "sticky-note in \"Sub\" \"", with: "sticky-note \"").split(separator: "\n").map { line -> String in
            line.hasPrefix("edge") ? String(line) : String(line) + " in \"Sub\""
        }.joined(separator: "\n")
        try agree(server, board, moved, "subboard")
        try clear("Checkout", "Later", in: board, "subboard")
        try clear("foundation", "Deeper", in: board, "subboard")
    },

    test("an end to a relationship type on another board, through a reference the run makes, gives the notes of its type their row at once") {
        let (board, server, pasteboard) = try stage()
        defer { board.close(); server.stop(); pasteboard.releaseGlobally() }
        // The relationship type and Layer on the root, public; a subboard to draw on.
        let root = """
        sticky-note "In layer" relationship: true public: true schema: "\(held)" text: "Which layer"
        sticky-note "Layer" right of "In layer" public: true schema: "\(big)" text: "A layer"
        edge "In layer" -> "Layer" text: "features"
        subboard "Sub" below "In layer"
        """
        expectEqual(try canvas(server, ["draw", "-"], input: root).status, 0)
        let far = """
        sticky-note "Feature" in "Sub" schema: "\(big)" text: "A feature"
        edge "Feature" -> "In layer" text: "layer" endRule: {"needed": true}
        sticky-note "Checkout" in "Sub" below "Feature" is: "Feature" fieldValues: {"f1": "Pay"}
        sticky-note "Later" in "Sub" below "Checkout" text: "Placed below"
        """
        try agree(server, board, far, "far end", measured: false)
        try clear("Checkout", "Later", in: board, "far end")
    },

    test("an end added over notes the script restates grows them, at the frame the board has") {
        let (board, server, pasteboard) = try stage()
        defer { board.close(); server.stop(); pasteboard.releaseGlobally() }
        expectEqual(try canvas(server, ["draw", "-"], input: types + "\n" + notes).status, 0)
        let before = try fileFrame("Checkout", in: board)
        let script = ends + "\n" + #"sticky-note "Checkout""# + "\n" + #"sticky-note "foundation""# + "\n" + #"sticky-note "Feature""#
        let drawn = try agree(server, board, script, "end added", measured: false)
        expect(try require(frame(drawn.first { $0["title"] == "Checkout" })).height > before.height, "the restated note grew")
    },

    test("an end added over notes restated with a placement keeps a note placed below clear of them") {
        let (board, server, pasteboard) = try stage()
        defer { board.close(); server.stop(); pasteboard.releaseGlobally() }
        expectEqual(try canvas(server, ["draw", "-"], input: types + "\n" + notes).status, 0)
        let script = ends + "\n" + #"sticky-note "Feature""# + "\n" + #"sticky-note "Checkout" below "Feature""# + "\n" + #"sticky-note "Later" below "Checkout""#
        try agree(server, board, script, "end added, placed", measured: false)
        try clear("Checkout", "Later", in: board, "end added, placed")
    },

    test("an end deleted over notes the script restates shrinks them, at the frame the board has") {
        let (board, server, pasteboard) = try stage()
        defer { board.close(); server.stop(); pasteboard.releaseGlobally() }
        expectEqual(try canvas(server, ["draw", "-"], input: [types, ends, notes].joined(separator: "\n")).status, 0)
        let before = try fileFrame("Checkout", in: board)
        let script = "delete edge \"Feature\" -> \"In layer\"\n" + #"sticky-note "Checkout""# + "\n" + #"sticky-note "Feature""#
        let drawn = try agree(server, board, script, "end deleted", measured: false)
        expect(try require(frame(drawn.first { $0["title"] == "Checkout" })).height < before.height, "the restated note shrank")
    },

    test("an existing type marked a relationship type, and unmarked, gives and takes the rows of the notes the script restates") {
        let (board, server, pasteboard) = try stage()
        defer { board.close(); server.stop(); pasteboard.releaseGlobally() }
        let unmarked = types.replacingOccurrences(of: " relationship: true", with: "")
        expectEqual(try canvas(server, ["draw", "-"], input: [unmarked, ends.replacingOccurrences(of: #" endRule: {"needed": true}"#, with: ""), notes].joined(separator: "\n")).status, 0)
        let before = try fileFrame("Checkout", in: board)
        let restated = #"sticky-note "Checkout""# + "\n" + #"sticky-note "Feature""# + "\n" + #"sticky-note "Layer""# + "\n" + #"sticky-note "foundation""#
        let drawn = try agree(server, board, #"sticky-note "In layer" relationship: true"# + "\n" + restated, "marked", measured: false)
        expect(try require(frame(drawn.first { $0["title"] == "Checkout" })).height > before.height, "the restated note grew")
        let back = try agree(server, board, #"sticky-note "In layer" relationship: false"# + "\n" + restated, "unmarked", measured: false)
        expectEqual(try require(frame(back.first { $0["title"] == "Checkout" })).height, before.height, "and is as it was")
    },

    test("a script that fails after its connections were laid in leaves the file, the revision and the undo name as they were, and a one-script run is one undo and one redo, exactly") {
        let (board, server, pasteboard) = try stage()
        defer { board.close(); server.stop(); pasteboard.releaseGlobally() }
        expectEqual(try canvas(server, ["draw", "-"], input: #"sticky-note "Seed" text: "Here first""#).status, 0)
        let before = board.editor.file, revision = board.editor.revision
        let script = [types, ends, notes, relation].joined(separator: "\n")
        let failing = script + "\n" + #"edge "Later" -> "Deeper" startArrowhead: true"#
        let refused = try canvas(server, ["draw", "-"], input: failing)
        expectEqual(refused.status, 1, refused.output)
        expect(board.editor.file == before, "nothing drawn")
        expectEqual(board.editor.revision, revision, "no commit")
        expectEqual(board.editor.undoHistory.undoName, "Draw", "the seed's step is the last")
        let seedFrame = try fileFrame("Seed", in: board)
        try agree(server, board, script, "after a refusal")
        expectEqual(try fileFrame("Seed", in: board), seedFrame)
        let after = board.editor.file
        // Three runs in agree: only the first changed anything.
        expectEqual(board.editor.undoHistory.undoName, "Draw")
        board.editor.undo()
        expect(board.editor.file == before, "one undo takes the whole run back, exactly")
        board.editor.redo()
        expect(board.editor.file == after, "and redo brings it back, exactly")
    },

    test("an end drawn through a reference to a relationship type the same script draws gives the notes of its type a row") {
        let (board, server, pasteboard) = try stage()
        defer { board.close(); server.stop(); pasteboard.releaseGlobally() }
        let model = """
        sticky-note "Feature" schema: "\(big)" text: "A feature"
        sticky-note "In layer" right of "Feature" (gap: 600) relationship: true public: true schema: "\(held)" text: "Which layer"
        """
        let end = #"edge "Feature" -> "In layer" via: reference text: "layer" endRule: {"needed": true}"#
        let instances = """
        sticky-note "Checkout" below "Feature" is: "Feature" fieldValues: {"f1": "Pay"}
        sticky-note "Later" below "Checkout" text: "Placed below"
        """
        // In two runs first, on a board of its own: the end through the reference gives the rows.
        let other = windowedBoard()
        defer { other.close() }
        let otherServer = try startCommandServer(boards: [other], frontmost: other)
        defer { otherServer.stop() }
        expectEqual(try canvas(otherServer, ["draw", "-"], input: model + "\n" + instances).status, 0)
        let short = try fileFrame("Checkout", in: other)
        let ended = try canvas(otherServer, ["draw", "-"], input: end)
        expectEqual(ended.status, 0, ended.error)
        let tall = try fileFrame("Checkout", in: other)
        expect(tall.height > short.height, "an end through a reference gives its type's notes a row: \(tall.height) against \(short.height)")
        // And in one run.
        try agree(server, board, [model, end, instances].joined(separator: "\n"), "via reference", measured: false)
        try clear("Checkout", "Later", in: board, "via reference")
    },

    test("a relationship type deleted takes its rows from the notes the script restates, at the frame the board has") {
        let (board, server, pasteboard) = try stage()
        defer { board.close(); server.stop(); pasteboard.releaseGlobally() }
        expectEqual(try canvas(server, ["draw", "-"], input: [types, ends, notes].joined(separator: "\n")).status, 0)
        let before = try fileFrame("Checkout", in: board)
        let script = "delete \"In layer\"\n" + #"sticky-note "Checkout""# + "\n" + #"sticky-note "Feature""#
        let dry = try canvas(server, ["draw", "--dry-run", "-"], input: script)
        let made = try canvas(server, ["draw", "-"], input: script)
        expectEqual(made.status, 0, made.error)
        let drawn = try rows(made.output)
        for title in ["Checkout", "Feature"] {
            let row = try require(drawn.first { $0["title"]?.stringValue == title })
            expectEqual(frame(row), try fileFrame(title, in: board), "\(title): the row is the board's frame")
        }
        expectEqual(try rows(dry.output).map { frame($0) }, drawn.map { frame($0) })
        expect(try fileFrame("Checkout", in: board).height < before.height, "the note lost its row")
    },

    test("an end deleted and drawn again in one script leaves the notes restated one row, at the frame the board has") {
        let (board, server, pasteboard) = try stage()
        defer { board.close(); server.stop(); pasteboard.releaseGlobally() }
        expectEqual(try canvas(server, ["draw", "-"], input: [types, ends, notes].joined(separator: "\n")).status, 0)
        let before = try fileFrame("Checkout", in: board)
        let script = "delete edge \"Feature\" -> \"In layer\"\n" + #"edge "Feature" -> "In layer" text: "tier""# + "\n" + #"sticky-note "Checkout""# + "\n" + #"sticky-note "Feature""#
        let made = try canvas(server, ["draw", "-"], input: script)
        expectEqual(made.status, 0, made.error)
        let drawn = try rows(made.output)
        for title in ["Checkout", "Feature"] {
            let row = try require(drawn.first { $0["title"]?.stringValue == title })
            expectEqual(frame(row), try fileFrame(title, in: board), "\(title): the row is the board's frame")
        }
        expectEqual(try fileFrame("Checkout", in: board).height, before.height, "one row, as before")
    },

    test("canvas measure given a board: ends added to its types and notes of them, the whole model again, notes of its ends, and an end nobody has is a warning") {
        let (board, server, pasteboard) = try stage()
        defer { board.close(); server.stop(); pasteboard.releaseGlobally() }
        expectEqual(try canvas(server, ["draw", "-"], input: types).status, 0)
        // Ends to types the board has, and notes of them: agree measures first.
        let drawn = try agree(server, board, [ends, notes, relation].joined(separator: "\n"), "ends over a board's types", rerun: false)
        let plainHeight = try require(frame(drawn.first { $0["title"] == "Later" })).height
        expect(try require(frame(drawn.first { $0["title"] == "Checkout" })).height > plainHeight)
        // The whole model measured again over the board that holds it: what a run of it says.
        let whole = [types, ends, notes, relation].joined(separator: "\n")
        let asked = try canvas(server, ["measure", "--board", "\(board.number)", "-"], input: whole)
        expectEqual(asked.status, 0, asked.error)
        let again = try rows(try canvas(server, ["draw", "--dry-run", "-"], input: whole).output)
        for shape in try JSON(text: asked.output)["shapes"]?.arrayValue ?? [] {
            let title = try require(shape["title"]?.stringValue)
            expectEqual(size(shape["size"]), frame(again.first { $0["title"]?.stringValue == title })?.size, "\(title): measured over its own board")
        }
        // New notes of the board's types, related: the ends are the board's.
        let more = """
        sticky-note "Pay" is: "Feature"
        sticky-note "base" right of "Pay" is: "Layer"
        edge "Pay" -> "base" is: "In layer"
        edge "Pay" -> "Checkout" channel: none
        """
        try agree(server, board, more, "new notes over the board's ends")
        // An end nobody has: a warning, and the rest measured.
        let missing = try canvas(server, ["measure", "--board", "\(board.number)", "-"], input: "sticky-note \"Solo\"\nedge \"Solo\" -> \"Nowhere\"")
        expectEqual(missing.status, 0, missing.error)
        let json = try JSON(text: missing.output)
        expectEqual(json["shapes"]?.arrayValue?.count, 1)
        expect((json["warnings"]?.arrayValue?.first?["message"]?.stringValue ?? "").hasSuffix("; measured without it"), "\(String(describing: json["warnings"]))")
    },

    test("canvas measure given a board keeps every shape new: a relationship type restated with its ends but not their types lays them beside the board's own") {
        let (board, server, pasteboard) = try stage()
        defer { board.close(); server.stop(); pasteboard.releaseGlobally() }
        expectEqual(try canvas(server, ["draw", "-"], input: [types, ends].joined(separator: "\n")).status, 0)
        let script = [#"sticky-note "In layer" relationship: true schema: "\#(held)" text: "Which layer""#, ends, notes].joined(separator: "\n")
        // (The design's P9: the restated type is a new shape in a measure, so the ends the script writes lie beside the board's own.)
        let asked = try canvas(server, ["measure", "--board", "\(board.number)", "-"], input: script)
        expectEqual(asked.status, 0, asked.error)
        var measured: [String: CGSize] = [:]
        for shape in try require(try JSON(text: asked.output)["shapes"]?.arrayValue) {
            if let title = shape["title"]?.stringValue, let size = size(shape["size"]) { measured[title] = size }
        }
        let made = try canvas(server, ["draw", "--board", "\(board.number)", "-"], input: script)
        expectEqual(made.status, 0, made.error)
        let drawn = try rows(made.output)
        let checkout = try require(frame(drawn.first { $0["title"] == "Checkout" })), counted = try require(measured["Checkout"])
        expectEqual(checkout, try fileFrame("Checkout", in: board), "the run's row is the board's frame")
        expect(counted.height > checkout.height, "measure counts the ends twice: \(counted.height) against \(checkout.height)")
        // The whole model restated, and the ends alone, measure as the run draws.
        for (label, restated) in [("the whole model", [types, ends, notes]), ("the ends alone", [ends, notes])] {
            let again = try canvas(server, ["measure", "--board", "\(board.number)", "-"], input: restated.joined(separator: "\n"))
            expectEqual(again.status, 0, again.error)
            for shape in try require(try JSON(text: again.output)["shapes"]?.arrayValue) {
                guard let title = shape["title"]?.stringValue, let row = drawn.first(where: { $0["title"]?.stringValue == title }) else { continue }
                expectEqual(size(shape["size"]), frame(row)?.size, "\(label): \(title): measure says the row's size")
            }
        }
    },

    test("a note put down in a frame it only just fits with its row is refused where the row leaves it no room, and kept wholly in where it fits") {
        // The note is 230 high without its row and 260 with it; a frame needs 80 more than the note.
        for height in [310, 320, 330, 340, 360] {
            let (board, server, pasteboard) = try stage()
            defer { board.close(); server.stop(); pasteboard.releaseGlobally() }
            expectEqual(try canvas(server, ["draw", "-"], input: "frame \"F\" size: 500x\(height)\n" + types.replacingOccurrences(of: #"sticky-note "Feature""#, with: #"sticky-note "Feature" right of "F""#)).status, 0)
            let script = ends + "\n" + #"sticky-note "Checkout" in "F" is: "Feature" fieldValues: {"f1": "Pay"}"#
            let made = try canvas(server, ["draw", "-"], input: script)
            guard height >= 340 else {
                expectEqual(made.status, 1, "\(height): the note with its row does not fit")
                expect(made.error.contains("no_room"), "\(height): \(made.error)")
                expect(board.editor.file.root.shapes.allSatisfy { board.editor.registry.title(of: $0) != "Checkout" }, "\(height): nothing drawn")
                continue
            }
            expectEqual(made.status, 0, "\(height): \(made.error)")
            let row = try require(try rows(made.output).first { $0["title"] == "Checkout" })
            let note = try fileFrame("Checkout", in: board), holder = try fileFrame("F", in: board)
            expectEqual(frame(row), note, "\(height): the row is the board's frame")
            expect(holder.contains(note), "\(height): \(note) is in \(holder)")
        }
    },

    test("an end added to a type whose note the script does not restate leaves a note placed against it against the old size: the limit") {
        let (board, server, pasteboard) = try stage()
        defer { board.close(); server.stop(); pasteboard.releaseGlobally() }
        expectEqual(try canvas(server, ["draw", "-"], input: types + "\n" + #"sticky-note "Checkout" below "Feature" is: "Feature" fieldValues: {"f1": "Pay"}"#).status, 0)
        let script = ends + "\n" + #"sticky-note "Later" below "Checkout" (gap: none) text: "Placed below""#
        let made = try canvas(server, ["draw", "-"], input: script)
        expectEqual(made.status, 0, made.error)
        // Checkout is read at the size it had, so Later sits against its old bottom, and the commit grows Checkout under it.
        let checkout = try fileFrame("Checkout", in: board), later = try fileFrame("Later", in: board)
        expect(checkout.intersects(later), "the note the script does not restate grew into the shape placed against it: \(checkout) and \(later)")
        let again = try canvas(server, ["draw", "-"], input: script)
        expect(try rows(again.output).map { $0["did"]?.stringValue ?? "" }.contains("moved"), "and the same again moves it")
        // Restated, the note is laid out with its row and the shape below is clear of it, and the same again changes nothing.
        let restated = ends + "\n" + #"sticky-note "Checkout" below "Feature" is: "Feature" fieldValues: {"f1": "Pay"}"# + "\n" + #"sticky-note "Later" below "Checkout" (gap: none) text: "Placed below""#
        expectEqual(try canvas(server, ["draw", "-"], input: restated).status, 0)
        try clear("Checkout", "Later", in: board, "restated")
        let last = try canvas(server, ["draw", "-"], input: restated)
        expectEqual(try rows(last.output).map { $0["did"]?.stringValue ?? "" }, Array(repeating: "unchanged", count: 4), "and the same again changes nothing")
    },

    test("canvas measure given a board whose window shows another board than the ends' counts an end the file has, written again, once") {
        let (board, server, pasteboard) = try stage()
        defer { board.close(); server.stop(); pasteboard.releaseGlobally() }
        expectEqual(try canvas(server, ["draw", "-"], input: [types, ends, #"subboard "Sub" below "Feature""#].joined(separator: "\n")).status, 0)
        let sub = try require(board.editor.document.shapes.first { board.editor.registry.title(of: $0) == "Sub" })
        // Something on Sub's board, so it is a board, and the window on it.
        expectEqual(try canvas(server, ["draw", "-"], input: #"sticky-note "Inside" in "Sub""#).status, 0)
        expect(board.editor.showBoard(BoardID(owner: sub.id)), "the window shows Sub's board")
        let script = #"edge "Feature" -> "In layer" text: "layer" endRule: {"needed": true}"# + "\n" + #"sticky-note "Extra" is: "Feature" fieldValues: {"f1": "x"}"#
        let asked = try canvas(server, ["measure", "--board", "\(board.number)", "-"], input: script)
        expectEqual(asked.status, 0, asked.error)
        let measured = try require(try JSON(text: asked.output)["shapes"]?.arrayValue?.first)
        let made = try canvas(server, ["draw", "--board", "\(board.number)", "-"], input: script)
        expectEqual(made.status, 0, made.error)
        let drawn = try rows(made.output)
        expectEqual(drawn.first?["did"], "unchanged", "the end is the one the file has")
        let row = try require(drawn.first { $0["title"] == "Extra" })
        expectEqual(frame(row), try fileFrame("Extra", in: board), "the row is the board's frame")
        expectEqual(size(measured["size"]), frame(row)?.size, "measure says the row's size")
    },
    test("a note put down across a frame's edge is judged in or out by the size its row gives it, and ends wholly in or wholly out") {
        // Tried at several depths over the edge: wherever the verdict turns on the row, the note must still end clear of the edge.
        var accepted = 0
        for gap in [40, 60, 80, 90, 100, 110, 120, 130, 140, 160] {
            let (board, server, pasteboard) = try stage()
            defer { board.close(); server.stop(); pasteboard.releaseGlobally() }
            let setup = """
            sticky-note "Anchor" size: 320x200
            frame "F" below "Anchor" (gap: 200) size: 700x700
            \(types.replacingOccurrences(of: #"sticky-note "Feature""#, with: #"sticky-note "Feature" right of "F" (gap: 300)"#))
            """
            expectEqual(try canvas(server, ["draw", "-"], input: setup).status, 0)
            let script = ends + "\n" + "sticky-note \"Checkout\" below \"Anchor\" (gap: \(gap)) overlap: allow is: \"Feature\" fieldValues: {\"f1\": \"Pay\"}"
            let made = try canvas(server, ["draw", "-"], input: script)
            guard made.status == 0 else { continue }
            accepted += 1
            let row = try require(try rows(made.output).first { $0["title"] == "Checkout" })
            let note = try fileFrame("Checkout", in: board), holder = try fileFrame("F", in: board)
            expectEqual(frame(row), note, "\(gap): the row is the board's frame")
            expect(holder.contains(note) || !holder.intersects(note), "\(gap): \(note) sits across the edge of \(holder)")
        }
        expect(accepted > 0, "some depth was drawn")
    },
    test("an edge through a reference to a shape the same script draws is laid out as the arrow that is drawn, whatever the two ends are") {
        for (from, to) in [("subboard", "sticky-note"), ("sticky-note", "subboard"), ("subboard", "subboard"), ("sticky-note", "sticky-note")] {
            let (board, server, pasteboard) = try stage()
            defer { board.close(); server.stop(); pasteboard.releaseGlobally() }
            let script = "\(from) \"S\"\n\(to) \"Hub\" right of \"S\" (gap: 600) public: true\nedge \"S\" -> \"Hub\" via: reference"
            // (A debug build holds the arrow drawn to the one laid out, and stops the process if they differ.)
            let made = try canvas(server, ["draw", "-"], input: script)
            expectEqual(made.status, 0, "\(from) to \(to): \(made.error)")
            let again = try canvas(server, ["draw", "-"], input: script)
            expectEqual(again.status, 0, "\(from) to \(to): \(again.error)")
            expectEqual(try rows(again.output).map { $0["did"]?.stringValue ?? "" }, Array(repeating: "unchanged", count: 3), "\(from) to \(to): the same again changes nothing")
        }
    },

    test("an end through a reference to a relationship type the same script draws, with its sides or its channel written, lays out as the board has it") {
        for written in ["to: left", "from: right", "from: bottom to: top", "channel: note-link", "channel: none"] {
            let (board, server, pasteboard) = try stage()
            defer { board.close(); server.stop(); pasteboard.releaseGlobally() }
            let script = """
            sticky-note "Feature" schema: "\(big)" text: "A feature"
            sticky-note "In layer" right of "Feature" (gap: 600) relationship: true public: true schema: "\(held)" text: "Which layer"
            edge "Feature" -> "In layer" via: reference text: "layer" \(written)
            sticky-note "Checkout" below "Feature" is: "Feature" fieldValues: {"f1": "Pay"}
            sticky-note "Later" below "Checkout" text: "Placed below"
            """
            let made = try canvas(server, ["draw", "-"], input: script)
            // (A side or channel the pair does not take is the maker's refusal, said by the run as it is by the commit.)
            guard made.status == 0 else { expect(!made.error.isEmpty, "\(written): refused with a message"); continue }
            for row in try rows(made.output) {
                guard let title = row["title"]?.stringValue else { continue }
                expectEqual(frame(row), try fileFrame(title, in: board), "\(written): \(title): the row's frame is the board's")
            }
            try clear("Checkout", "Later", in: board, written)
        }
    },
])

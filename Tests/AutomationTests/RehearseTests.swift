import Automation
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import Draw
import Foundation
import TestKit

// `canvas rehearse`: several scripts drawn in turn on a copy of the file, each saying what it did as a dry run says it,
// a later one finding what an earlier one made, and the file never changed. Over the fixtures: tiles, links, and the
// harbor's pockets for a script on another board.

/// `canvas rehearse -`, the scripts on standard input as a JSON list.
@MainActor private func rehearsal(_ scripts: [String], on editor: CanvasEditor) throws -> Result<JSON, RPCError> {
    let list = try require(String(data: JSONEncoder().encode(scripts), encoding: .utf8))
    return try run(["rehearse", "-"], on: editor, input: list)
}

/// What a rehearsal that succeeds says: each script's result.
@MainActor private func rehearsed(_ scripts: [String], on editor: CanvasEditor) throws -> [JSON] {
    switch try rehearsal(scripts, on: editor) {
    case .success(let json): return json["runs"]?.arrayValue ?? []
    case .failure(let error): throw DrawFailed(error: error)
    }
}

/// Why a rehearsal that should stop did.
@MainActor private func stopped(_ scripts: [String], on editor: CanvasEditor) throws -> RPCError {
    switch try rehearsal(scripts, on: editor) {
    case .success(let json): throw DrewAnyway(result: json)
    case .failure(let error): return error
    }
}

@MainActor let rehearseTests = Suite("rehearse", [
    test("each script is drawn in turn on a copy: a later one finds what an earlier made, each says it as a dry run, and the file isn't changed") {
        let editor = try drawEditor()
        let before = editor.file, revision = editor.revision
        var events: [UndoEvent] = []
        editor.undoHistory.didChange = { events.append($0) }
        let runs = try rehearsed([#"tile "Hub""#, #"tile "East" right of "Hub""#, #"edge "Hub" -> "East""#], on: editor)
        expectEqual(runs.count, 3)
        expectEqual(runs.map { rows($0).map { $0["did"] } }, [["created"], ["created"], ["connected"]])
        expectEqual(runs.map { $0["dryRun"] }, [true, true, true])
        expectEqual(rows(runs[1]).first?["id"], nil, "a shape made on the copy has no id the file will know")
        expectEqual(editor.file, before)
        expectEqual(editor.revision, revision)
        expectEqual(events, [], "no step opens")
        // Drawn for real, one at a time, the scripts land where the rehearsal said.
        let hub = try drawn(#"tile "Hub""#, on: editor), east = try drawn(#"tile "East" right of "Hub""#, on: editor)
        expectEqual(rows(hub).first?["at"], rows(runs[0]).first?["at"])
        expectEqual(rows(east).first?["at"], rows(runs[1]).first?["at"])
    },
    test("no row says an id the file won't have: a shape the copy made has none, in its own script or a later one that restates it, and a shape the file has keeps its own") {
        let editor = try drawEditor()
        let runs = try rehearsed([#"tile "Hub""#, #"tile "Hub""#, #"tile "East" right of "Hub""#], on: editor)
        expectEqual(runs.map { rows($0).map { $0["did"] } }, [["created"], ["unchanged"], ["created"]])
        expect(runs.allSatisfy { rows($0).allSatisfy { $0["id"] == nil } }, "no id of the copy's: \(runs)")
        let base = try require(rows(try drawn(#"tile "Base""#, on: editor)).first?["id"])
        expectEqual(rows(try rehearsed([#"tile "Base""#], on: editor)[0]).first?["id"], base, "the file's shape, by its id")
    },
    test("a script that names what an earlier one makes is refused alone, and goes through in a rehearsal after it") {
        let editor = try drawEditor()
        expectEqual(try refused(#"tile "East" right of "Hub""#, on: editor).reason, "unknown_title")
        expectEqual(try rehearsed([#"tile "Hub""#, #"tile "East" right of "Hub""#], on: editor).count, 2)
    },
    test("a script refused stops it: the error is draw's, with which script it is, and nothing is drawn") {
        let editor = try drawEditor()
        let error = try stopped([#"tile "Hub""#, #"tile "East" right of "Nowhere""#, #"tile "West""#], on: editor)
        expectEqual(error.reason, "unknown_title")
        expectEqual(error.data?["script"], 1)
        expectEqual(error.data?["line"], 1)
        expectEqual(editor.document.shapes.count, 0)
    },
    test("a script on another board finds a shape an earlier script made there, and says which board it drew on") {
        let editor = try Harbor().editor()
        let before = editor.file
        let runs = try rehearsed([#"tile "Mast" in "P""#, #"tile "Sail" right of "Mast""#], on: editor)
        expectEqual(runs.map { $0["on"]?["title"] }, ["P", "P"])
        expectEqual(runs.map { rows($0).map { $0["did"] } }, [["created"], ["created"]])
        expectEqual(editor.file, before)
    },
    test("the scripts are a JSON list of strings") {
        let editor = try drawEditor()
        guard case .failure(let error) = try run(["rehearse", "-"], on: editor, input: #"tile "Hub""#) else { return expect(false, "not a list") }
        expectEqual(error.reason, "invalid_params")
        expectEqual(try rehearsed([], on: editor).count, 0, "an empty list draws nothing, and says so")
    },
])

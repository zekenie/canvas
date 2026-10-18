import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CanvasUI
import Foundation
import Grouping
import Selection
import ShippedTesting
import TestKit
import Titles

// `canvas draw`'s `group` and `ungroup` through `canvas` as built, over what ships: the notes, frames and subboards a script
// draws, the groups Grouping writes, and what a click on one of them then selects (Selection's `selectionUnit(of:)`).

/// The shape of a board called this.
@MainActor private func shape(_ title: String, in board: BoardDocument) -> ShapeID? {
    board.editor.document.shapes.first { board.editor.registry.title(of: $0) == title }?.id
}

@MainActor let drawGroupsShippedTests = Suite("canvas draw: group and ungroup, as built", [
    test("a script that draws three notes and groups two: a click on one selects both; ungroup takes the group apart") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let result = try draw("""
            sticky-note "Draft" text: "First pass"
            sticky-note "Review" right of "Draft" text: "A second pair of eyes"
            sticky-note "Ship" right of "Review" text: "Out the door"
            group "Draft" and "Review"
            """, on: board, server)
        expectEqual(result.status, 0, result.error)
        let rows = try JSON(text: result.output)["changes"]?.arrayValue ?? []
        expectEqual(rows.map { $0["did"] }, ["created", "created", "created", "grouped"])
        expectEqual(rows.last, ["line": 4, "did": "grouped", "shapes": ["Draft", "Review"]])
        let draft = try require(shape("Draft", in: board)), review = try require(shape("Review", in: board)), ship = try require(shape("Ship", in: board))
        expectEqual(board.editor.selectionUnit(of: draft), [draft, review], "a click on one selects both")
        expectEqual(board.editor.selectionUnit(of: review), [draft, review])
        expectEqual(board.editor.selectionUnit(of: ship), [ship], "and none of the third")
        expectEqual(board.editor.undoHistory.undoName, "Draw", "one step, with the notes")
        expectEqual(board.editor.document[draft]?[GroupsProperty.self], board.editor.document[review]?[GroupsProperty.self])
        expectEqual(board.editor.document[ship]?[GroupsProperty.self], nil)

        // A run again changes nothing: no step.
        let editedAt = board.editor.revision
        let again = try draw(#"group "Review" and "Draft""#, on: board, server)
        expectEqual(try JSON(text: again.output)["changes"]?.arrayValue?.map { $0["did"] }, ["unchanged"])
        expectEqual(board.editor.revision, editedAt)

        // Ungroup takes a shape out: the other is alone, and no group.
        let apart = try draw(#"ungroup "Draft""#, on: board, server)
        expectEqual(apart.status, 0, apart.error)
        expectEqual(try JSON(text: apart.output)["changes"], [["line": 1, "did": "ungrouped", "shapes": ["Draft"]]])
        expectEqual(board.editor.selectionUnit(of: draft), [draft])
        expectEqual(board.editor.selectionUnit(of: review), [review], "one shape left is no group, though it still holds the id")
        expect(board.editor.document[review]?[GroupsProperty.self] != nil)
        expectEqual(board.editor.document[draft]?[GroupsProperty.self], nil)
        let nothing = try draw(#"ungroup "Draft" and "Review""#, on: board, server)
        expectEqual(try JSON(text: nothing.output)["changes"]?.arrayValue?.map { $0["did"] }, ["unchanged"], "in no group that counts")

        // Undone, the group is back.
        board.editor.undo()
        expectEqual(board.editor.selectionUnit(of: draft), [draft, review])
    },
    test("any kind that ships can be grouped: notes, a frame and a subboard are one group; a dry run says so and changes nothing") {
        try configureBoards()
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let drawn = try draw("""
            sticky-note "Note" text: "A note"
            frame "Sprint" right of "Note" size: 400x300
            subboard "Plans" right of "Sprint"
            """, on: board, server)
        expectEqual(drawn.status, 0, drawn.error)
        let before = board.editor.document
        let dry = try draw(#"group "Plans" and "Note" and "Sprint""#, on: board, server, ["--dry-run"])
        expectEqual(try JSON(text: dry.output)["dryRun"], true)
        expectEqual(try JSON(text: dry.output)["changes"]?.arrayValue?.map { $0["did"] }, ["grouped"])
        expectEqual(board.editor.document, before)
        let result = try draw(#"group "Plans" and "Note" and "Sprint""#, on: board, server)
        expectEqual(try JSON(text: result.output)["changes"], [["line": 1, "did": "grouped", "shapes": ["Plans", "Note", "Sprint"]]])
        let note = try require(shape("Note", in: board))
        expectEqual(Set(board.editor.selectionUnit(of: note)), Set(["Note", "Sprint", "Plans"].compactMap { shape($0, in: board) }))
    },
    test("a group is its shapes on one board, and a locked note can't be taken in or out: several_boards, read_only") {
        try configureBoards()
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        _ = try draw("""
            sticky-note "Draft" text: "First pass"
            sticky-note "Review" right of "Draft" text: "A second pair of eyes" locked: true
            subboard "Plans" right of "Review"
            """, on: board, server)
        _ = try draw(#"sticky-note "Inner" in "Plans" text: "On the board of Plans""#, on: board, server)
        let before = board.editor.file
        let apart = try draw(#"group "Draft" and "Inner""#, on: board, server)
        expectEqual(apart.status, 1)
        expectEqual((try JSON(text: apart.error))["error"]?["reason"], "several_boards")
        let locked = try draw(#"group "Draft" and "Review""#, on: board, server)
        expectEqual(locked.status, 1)
        let error = try JSON(text: locked.error)["error"]
        expectEqual(error?["reason"], "read_only")
        expectEqual(error?["message"], #""Review" is read-only (locked, say), so it can't be grouped"#)
        expectEqual(error?["line"], 1)
        expectEqual(board.editor.file, before, "nothing was written")
        // Grouping two notes on the board of a subboard is a group there, without moving the window.
        _ = try draw(#"sticky-note "Second" in "Plans" right of "Inner" text: "Next to it""#, on: board, server)
        let there = try draw(#"group "Inner" and "Second""#, on: board, server)
        expectEqual(there.status, 0, there.error)
        let plans = try require(shape("Plans", in: board))
        expectEqual(try JSON(text: there.output)["on"]?["board"], .string(plans.description))
        let inner = try require(board.editor.file[BoardID(owner: plans)].shapes.first { board.editor.registry.title(of: $0) == "Inner" })
        let second = try require(board.editor.file[BoardID(owner: plans)].shapes.first { board.editor.registry.title(of: $0) == "Second" })
        expect(inner[GroupsProperty.self] != nil && inner[GroupsProperty.self] == second[GroupsProperty.self])
        expectEqual(board.editor.board, .root)
    },
])

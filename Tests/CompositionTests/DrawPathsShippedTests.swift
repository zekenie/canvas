import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CanvasUI
import Foundation
import ShippedTesting
import StickyNotes
import TestKit
import Titles
import Validation

// `canvas draw` names a shape by a path through `canvas` as built, over the frames and subboards that ship: two notes called
// Checkout in two frames, an edge between them by path, and the same script again, which changes nothing. Two shapes may share a
// title in different containers; a lone title that names both is `ambiguous_title`, said by the shapes' paths.

/// The shapes of a board called this, with the container each is in.
@MainActor private func called(_ title: String, in board: BoardDocument) -> [(id: ShapeID, holder: ShapeID?)] {
    let editor = board.editor
    return editor.document.shapes.filter { editor.registry.title(of: $0) == title }.map { ($0.id, editor.holder(of: $0.id)) }
}

@MainActor let drawPathsShippedTests = Suite("canvas draw: paths, as built", [
    test("two notes of one title in two frames, an edge between them by path, and the same script again unchanged") {
        try configureBoards()
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let frames = try draw("""
            frame "Payments" size: 700x400
            frame "Billing" right of "Payments" size: 700x400
            subboard "Plans" below "Payments"
            """, on: board, server)
        expectEqual(frames.status, 0, frames.error)
        let script = """
            sticky-note "Payments" > "Checkout" text: "Takes the card"
            sticky-note "Billing" > "Checkout" text: "Sends the invoice"
            edge "Payments" > "Checkout" -> "Billing" > "Checkout"
            """
        let result = try draw(script, on: board, server)
        expectEqual(result.status, 0, result.error)
        let json = try JSON(text: result.output)
        expectEqual((json["changes"]?.arrayValue ?? []).map { $0["did"] }, ["created", "created", "connected"])
        let checkouts = called("Checkout", in: board)
        expectEqual(checkouts.count, 2, "two notes of one title")
        let payments = try require(board.editor.document.shapes.first { board.editor.registry.title(of: $0) == "Payments" }?.id)
        let billing = try require(board.editor.document.shapes.first { board.editor.registry.title(of: $0) == "Billing" }?.id)
        expectEqual(Set(checkouts.map(\.holder)), [payments, billing], "each in its frame")
        expectEqual(board.editor.undoHistory.undoName, "Draw")
        // They share a title and not a path: the run warns of nothing, and neither note warns on the board.
        expectEqual(json["warnings"]?.arrayValue ?? [], [])
        for checkout in checkouts { expectEqual(board.editor.validation?.result(for: checkout.id)?.issues ?? [], []) }

        // The one arrow joins the two.
        let arrows = board.editor.document.shapes.filter { $0.kind == "arrow" }
        expectEqual(arrows.count, 1)

        // The same script again changes nothing.
        let revision = board.editor.revision
        let again = try draw(script, on: board, server)
        expectEqual(again.status, 0, again.error)
        expectEqual((try JSON(text: again.output)["changes"]?.arrayValue ?? []).map { $0["did"] }, ["unchanged", "unchanged", "unchanged"])
        expectEqual(board.editor.revision, revision)
        expectEqual(called("Checkout", in: board).count, 2)

        // A lone title names neither: it is ambiguous, said by the paths, and nothing is drawn.
        let lone = try draw(#"sticky-note "Checkout" text: "Which?""#, on: board, server)
        expectEqual(lone.status, 1)
        let error = try JSON(text: lone.error)["error"]
        expectEqual(error?["reason"], "ambiguous_title")
        expectEqual(error?["message"], #"the board has 2 shapes called "Checkout": a sticky-note "Payments" > "Checkout" and a sticky-note "Billing" > "Checkout""#)
        expectEqual(error?["hint"], #"write the path of the one you mean, as "Payments" > "Checkout", or its #id, which a query's row gives"#)
        expectEqual(board.editor.revision, revision)

        // `in` finds its own title inside the frame, and makes a second Router when the first is in another frame.
        let inside = try draw(#"sticky-note "Checkout" in "Billing" text: "Sends the invoice""#, on: board, server)
        expectEqual(try JSON(text: inside.output)["changes"]?.arrayValue?.map { $0["did"] }, ["unchanged"])
        let router = try draw(#"sticky-note "Router" in "Payments" right of "Checkout" text: "Routes""# + "\n" + #"sticky-note "Router" in "Billing" right of "Checkout" text: "Routes too""#, on: board, server)
        expectEqual(router.status, 0, router.error)
        expectEqual(Set(called("Router", in: board).map(\.holder)), [payments, billing])
        let moved = try draw(#"sticky-note "Router" in "Billing" text: "Routes too""#, on: board, server)
        expectEqual(try JSON(text: moved.output)["changes"]?.arrayValue?.map { $0["did"] }, ["unchanged"], "the one in Billing; the other stays in Payments")
        expectEqual(Set(called("Router", in: board).map(\.holder)), [payments, billing])

        // A shape moves from one frame into another by its id with `in`: a lone title would make a new one there.
        let framed = try draw(#"frame "Refunds" right of "Billing" size: 700x400"#, on: board, server)
        expectEqual(framed.status, 0, framed.error)
        let refunds = try require(board.editor.document.shapes.first { board.editor.registry.title(of: $0) == "Refunds" }?.id)
        let paymentsRouter = try require(called("Router", in: board).first { $0.holder == payments }?.id)
        let into = try draw("sticky-note #\(paymentsRouter) in \"Refunds\"", on: board, server)
        expectEqual(into.status, 0, into.error)
        expectEqual(board.editor.holder(of: paymentsRouter), refunds, "the Router that was in Payments is in Refunds")
        expectEqual(called("Router", in: board).count, 2, "moved, not copied")

        // Delete by path leaves the other.
        let deleted = try draw(#"delete "Billing" > "Checkout""#, on: board, server)
        expectEqual(deleted.status, 0, deleted.error)
        expectEqual(called("Checkout", in: board).map(\.holder), [payments])
        board.editor.undo()
        expectEqual(called("Checkout", in: board).count, 2)
    },
    test("a path through a subboard names the note on its board, and a subboard is shown by a path") {
        try configureBoards()
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        _ = try draw("""
            subboard "Plans" size: 300x200
            subboard "Archive" right of "Plans" size: 300x200
            frame "Sprint" below "Plans" size: 520x360
            """, on: board, server)
        let first = try draw(#"sticky-note "Plans" > "Checkout" text: "In Plans""#, on: board, server)
        expectEqual(first.status, 0, first.error)
        expectEqual(try JSON(text: first.output)["on"]?["title"], "Plans", "the path says the board the run draws on")
        let second = try draw(#"sticky-note "Archive" > "Checkout" text: "In Archive""#, on: board, server)
        expectEqual(second.status, 0, second.error)
        expectEqual(try JSON(text: second.output)["on"]?["title"], "Archive")
        expectEqual(try JSON(text: second.output)["changes"]?.arrayValue?.map { $0["did"] }, ["created"], "a second Checkout on another board is a shape of its own")
        // `board` is the top of the board the run draws on: the hint says which, where that is not the one the window shows.
        let missing = try draw(#"sticky-note "Draft" in "Plans" right of board > "Missing" text: "A draft""#, on: board, server)
        expectEqual(missing.status, 1)
        let refused = try JSON(text: missing.error)["error"]
        expectEqual(refused?["reason"], "unknown_title")
        expectEqual(refused?["hint"], #"board (the top of "Plans"'s board, where this run draws) holds no shape called "Missing""#)
        let shown = try canvas(server, ["show", #""Plans" > "Checkout""#])
        expectEqual(shown.status, 1, "a note holds no board")
        expectEqual(try JSON(text: shown.error)["error"]?["reason"], "cannot_contain")
        let archive = try canvas(server, ["show", "Archive"])
        expectEqual(archive.status, 0, archive.error)
    },
])

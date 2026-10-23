import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CanvasUI
import Foundation
import TestKit

// `canvas capture` as shipped: `canvas` as built, asking the app's command server, on real boards of
// the shipped kinds, drawn first with `canvas draw`. What the picture holds is where the draw's rows
// and the capture's `region` say.

/// A folder of the test's own for the pictures it takes, gone as the test ends.
@MainActor private func pictures() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("capture-shipped-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    afterThisTest { try? FileManager.default.removeItem(at: folder) }
    return folder
}

/// The numbers of a rect as a result writes one, `[[x, y], [width, height]]`.
@MainActor private func rect(_ json: JSON?) throws -> CGRect {
    let numbers = json?.arrayValue?.compactMap(\.arrayValue).flatMap { $0.compactMap(\.numberValue) } ?? []
    let four = try require(numbers.count == 4 ? numbers : nil, "a rect, not \(json?.compactText ?? "nothing")")
    return CGRect(x: four[0], y: four[1], width: four[2], height: four[3])
}

@MainActor let captureShippedTests = Suite("canvas capture, shipped", [
    test("notes drawn and pictured, whole and by a title: the server names the board, and a note's paper is where the rows say") {
        try configureBoards()
        let board = newBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let drew = try canvas(server, ["draw", "-"], input: """
            sticky-note "Checkout" text: "Pays for the cart"
            sticky-note "Ledger" right of "Checkout" text: "Keeps the books"
            """)
        expectEqual(drew.status, 0, drew.error)
        let rows = try require(try JSON(text: drew.output)["changes"]?.arrayValue)
        let checkout = try rect(rows[0]["at"]), ledger = try rect(rows[1]["at"])
        let revision = board.editor.revision, file = try pictures().appendingPathComponent("board.png").path
        let whole = try canvas(server, ["capture", file])
        expectEqual(whole.status, 0, whole.error)
        let result = try JSON(text: whole.output)
        expectEqual(result["board"], ["id": .number(Double(board.number)), "name": .string(board.displayName ?? "untitled"), "shows": "root", "showsPath": ["root"]])
        expectEqual(result["zoom"], 100)
        expectEqual(result["warnings"], nil)
        let region = try rect(result["region"])
        expect(region.contains(checkout.union(ledger)), "the whole board is in it: \(region)")
        let picture = try require(NSBitmapImageRep(data: Data(contentsOf: URL(fileURLWithPath: file))))
        expectEqual([picture.pixelsWide, picture.pixelsHigh], [Int(region.width), Int(region.height)], "a pixel a point, the region's size")
        // Checkout's paper, inside its bottom-right corner, clear of its words: a note's yellow.
        let paper = try require(picture.colorAt(x: Int(checkout.maxX - region.minX) - 12, y: Int(checkout.maxY - region.minY) - 12)?.usingColorSpace(.sRGB))
        expect(paper.redComponent - paper.blueComponent > 0.2, "a note's yellow paper: \(paper)")
        expectEqual(board.editor.revision, revision, "a picture changes nothing")
        // By its title: the view fitted to Ledger, in the middle of 1200 × 800.
        let near = try canvas(server, ["capture", file, "--shape", "Ledger"])
        expectEqual(near.status, 0, near.error)
        let fitted = try rect(try JSON(text: near.output)["region"])
        expectEqual(fitted.width, 1200)
        expect(abs(fitted.midX - ledger.midX) <= 1 && abs(fitted.midY - ledger.midY) <= 1, "centered on Ledger: \(fitted), \(ledger)")
        let typo = try canvas(server, ["capture", file, "--shape", "Ledgr"])
        expectEqual(typo.status, 1)
        let refusal = try JSON(text: typo.error)["error"]
        expectEqual(refusal?["reason"], "unknown_title")
        expectEqual(refusal?["hint"], #"did you mean "Ledger"?"#)
    },
    test("a subboard's board, by its title or a shape on it, is pictured with the window staying on the root") {
        try configureBoards()
        let board = newBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        // Two runs: a run draws on one board, and a shape goes in a subboard drawn before.
        let drew = try canvas(server, ["draw", #"subboard "Payments""#])
        expectEqual(drew.status, 0, drew.error)
        let payments = try require(try JSON(text: drew.output)["changes"]?.arrayValue?.first?["id"]?.stringValue)
        let inside = try canvas(server, ["draw", #"sticky-note "Refunds" in "Payments" text: "Money back""#])
        expectEqual(inside.status, 0, inside.error)
        let file = try pictures().appendingPathComponent("payments.png").path
        for arguments in [["--in", "Payments"], ["--shape", "Refunds"]] {
            let taken = try canvas(server, ["capture", file] + arguments)
            expectEqual(taken.status, 0, taken.error)
            let result = try JSON(text: taken.output)
            expectEqual(result["board"]?["shows"], .string(payments), "\(arguments)")
            expectEqual(result["board"]?["showsPath"], ["root", .string(payments)])
        }
        expectEqual(board.editor.board, .root, "the window stays where it is")
    },
    test("canvas help capture says what it takes") {
        try configureBoards()
        let board = newBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let help = try canvas(server, ["help", "capture"])
        expectEqual(help.status, 0, help.error)
        for part in ["canvas capture <file>", "--shape <name>", "--zoom <number>", "--in <name>", "--root", "--size <width,height>", "--scale <number>", "--dark",
                     "--board <board>"] {
            expect(help.output.contains(part), "\(part) in:\n\(help.output)")
        }
    },
])

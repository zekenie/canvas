import AppKit
import Canvas
import CanvasRPC
import CanvasUI
import Composition
import Foundation
import LanguageModels
import Schemas
import StickyNotes
import TestKit
import Titles

// The command line end to end, as an agent uses it: `canvas`, as it's built, talking to the app's
// command server, started as the app starts it (the shipped plugins' commands), on boards
// configured as the app configures them.

/// The app's command server on a socket of the test's own, for these boards.
@MainActor func startCommandServer(boards: [BoardDocument], frontmost: BoardDocument?) throws -> CommandServer {
    let commands = ShippedPlugins.commands(in: try require(BoardDocument.configuration).registry)
    let server = CommandServer(path: temporarySocketPath(), commands: CommandServer.Commands(specs: commands.specs, run: commands.run),
                               boards: { boards }, frontmost: { frontmost })
    try server.start()
    return server
}

/// `canvas`, as built, asking `server`.
@MainActor func canvas(_ server: CommandServer, _ arguments: [String]) throws -> ProcessOutput {
    try run(builtExecutable("CanvasCLI"), ["--socket", server.path] + arguments)
}

@MainActor func newBoard() -> BoardDocument {
    let board = BoardDocument()
    board.start(with: CanvasDocument())
    return board
}

@MainActor let commandLineTests = Suite("Command line", [
    test("canvas create puts a shape on the board in front, as its tool would, with what it's told; the board is edited") {
        try configureBoards()
        let board = newBoard()
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let result = try canvas(server, ["create", "sticky-note", "--at", "100,100", "--set", "text=Hello", "--set", "title=Plan"])
        expectEqual(result.status, 0, result.error)
        let id = try require(try JSON(text: result.output)["id"]?.stringValue.flatMap(UUID.init(uuidString:)))
        let note = try require(board.editor.document[ShapeID(id)])
        expectEqual(note.typed(as: StickyNote.self)?.props.text, "Hello")
        expectEqual(note[TitleProperty.self], "Plan")
        expectEqual(note.box, CGRect(x: 0, y: 0, width: 200, height: 200))
        expect(board.isDocumentEdited)
        let unknown = try canvas(server, ["create", "stickynote"])
        expectEqual(unknown.status, 1)
        expectEqual(try JSON(text: unknown.error)["error"]?["reason"], "unknown_kind")
        expect(try JSON(text: unknown.error)["error"]?["hint"]?.stringValue?.hasPrefix("Did you mean sticky-note?") == true, unknown.error)
        expectEqual(board.editor.document.shapes.count, 1)
    },
    test("canvas create schema-card is as tall as the schema it's given, as the panel makes it; a --size is as asked") {
        try configureBoards()
        let board = newBoard()
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let schema = #"{"type": "object", "properties": {"a": {}, "b": {}, "c": {}, "d": {}, "e": {}, "f": {}}}"#
        for (arguments, size) in [([String](), CGSize(width: 240, height: try require(SchemaCard.height(for: schema)))),
                                  (["--size", "300,100"], CGSize(width: 300, height: 100))] {
            let result = try canvas(server, ["create", "schema-card", "--at", "0,0", "--set", "schema=\(schema)"] + arguments)
            expectEqual(result.status, 0, result.error)
            let id = try require(try JSON(text: result.output)["id"]?.stringValue.flatMap(UUID.init(uuidString:)))
            let card = try require(board.editor.document[ShapeID(id)]?.typed(as: SchemaCard.self)?.props)
            expectEqual(card.schema, schema)
            expectEqual(card.frame.size, size, "six rows: 177 high, where the placed card is 67")
        }
    },
    test("canvas boards lists the open boards; --board picks one by its id, its file or its name") {
        try configureBoards()
        let first = newBoard(), second = newBoard()
        second.fileURL = URL(fileURLWithPath: "/tmp/Plans For Q4.canvasboard")
        let server = try startCommandServer(boards: [first, second], frontmost: nil)
        defer { server.stop() }
        let boards = try JSON(text: canvas(server, ["boards"]).output).arrayValue ?? []
        expectEqual(boards.compactMap { $0["id"]?.intValue }, [first.number, second.number])
        expectEqual(boards.last?["path"], "/tmp/Plans For Q4.canvasboard")
        expectEqual(boards.map { $0["frontmost"] }, [false, false])
        let ambiguous = try canvas(server, ["create", "ellipse"])
        expectEqual(ambiguous.status, 1)
        expectEqual(try JSON(text: ambiguous.error)["error"]?["reason"], "ambiguous_board")
        expectEqual(try canvas(server, ["create", "ellipse", "--board", "\(second.number)"]).status, 0)
        expectEqual(try canvas(server, ["create", "ellipse", "--board", "/tmp/Plans For Q4.canvasboard"]).status, 0)
        expectEqual(try canvas(server, ["create", "ellipse", "--board", second.displayName]).status, 0)
        expectEqual(second.editor.document.shapes.count, 3)
        expectEqual(first.editor.document.shapes.count, 0)
        let missing = try canvas(server, ["create", "ellipse", "--board", "Nope"])
        expectEqual(try JSON(text: missing.error)["error"]?["reason"], "unknown_board")
    },
    test("status, kinds and help describe the app the command line is talking to") {
        try configureBoards()
        let board = newBoard()
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let status = try JSON(text: canvas(server, ["status"]).output)
        expectEqual(status["protocol"], .number(Double(RPC.protocolVersion)))
        expectEqual(status["boards"], 1)
        expectEqual(status["frontmost"], .number(Double(board.number)))
        let kinds = try JSON(text: canvas(server, ["kinds"]).output).arrayValue?.compactMap { $0["kind"]?.stringValue } ?? []
        expectEqual(kinds, try ShippedPlugins.registry(model: ScriptedLanguageModel()).kinds.map(\.rawValue).sorted())
        let note = try JSON(text: canvas(server, ["kinds", "sticky-note", "--schema"]).output).arrayValue?.first
        expectEqual(note?["schema"]?["properties"]?["title"]?["maxLength"], 80)
        let help = try canvas(server, ["help"]).output
        for command in ["status", "boards", "create", "kinds"] { expect(help.contains("\n  \(command) "), help) }
    },
])

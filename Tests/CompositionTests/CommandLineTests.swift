import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CanvasUI
import Composition
import Foundation
import LanguageModels
import Mentions
import Schemas
import StickyNotes
import SwiftUI
import TableOfContents
import TaskCards
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
    test("canvas create sticky-note --set text= takes plain text as it is, and mentions as written: of a task on the board, named as it is now") {
        try configureBoards()
        let board = newBoard()
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        @MainActor func created(_ result: ProcessOutput) throws -> (record: AnyShapeRecord, warnings: JSON?) {
            expectEqual(result.status, 0, result.error)
            let json = try JSON(text: result.output)
            let id = try require(json["id"]?.stringValue.flatMap(UUID.init(uuidString:)))
            return (try require(board.editor.document[ShapeID(id)]), json["warnings"])
        }
        @MainActor func text(_ record: AnyShapeRecord) throws -> MentionText { try require(record.typed(as: StickyNote.self)?.props.text) }

        let plain = try created(canvas(server, ["create", "sticky-note", "--at", "100,100", "--set", #"text=a@b.c, @ [x] and C:\path"#]))
        expectEqual(try text(plain.record).stored, #"a@b.c, @ [x] and C:\path"#)
        expectEqual(try text(plain.record).mentioned, [])
        expectEqual(plain.warnings, nil)

        let task = try created(canvas(server, ["create", "task-card", "--at", "500,100", "--set", "title=Ship it"])).record
        let written = "Ask @[Ship](shape:\(task.id.rawValue.uuidString)) first, then @[it](shape:\(task.id.rawValue.uuidString.lowercased()))"
        let note = try created(canvas(server, ["create", "sticky-note", "--at", "100,400", "--set", "text=\(written)"]))
        expectEqual(note.warnings, nil, "every shape it mentions is there")
        expectEqual(try text(note.record).stored, written, "kept as written, an agent's lowercase id too")
        expectEqual(try text(note.record).mentioned, [task.id, task.id])
        expectEqual(board.editor.mentions?.mentioners(of: task.id), [note.record.id])
        let row = board.editor.tableOfContents?.entries.first { $0.id == note.record.id }?.label?.text
        expectEqual(row, "Ask @Ship it first, then @Ship it", "each mention by the task's title now")
    },
    test("canvas create sticky-note makes a note mentioning a shape that isn't in the file, and warns that it shows as missing") {
        try configureBoards()
        let board = newBoard()
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let gone = ShapeID()
        let result = try canvas(server, ["create", "sticky-note", "--set", "text=See @[Old plan](shape:\(gone)) again"])
        expectEqual(result.status, 0, result.error)
        let json = try JSON(text: result.output)
        expectEqual(json["warnings"], [.string("text names shapes that aren't in the file: \(gone); they show as missing.")])
        let id = try require(json["id"]?.stringValue.flatMap(UUID.init(uuidString:)))
        let note = try require(board.editor.document[ShapeID(id)]?.typed(as: StickyNote.self))
        expectEqual(note.props.text.mentioned, [gone])
        expectEqual(board.editor.mentions?.resolve(gone), .missing)
        expectEqual(board.editor.tableOfContents?.entries.first?.label?.text, "See @Old plan again", "by the name it holds")
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
    test("status and boards say which board inside each file its window shows, and a board command works there") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        BoardDocument.configuration = BoardConfiguration(registry: try Registry(plugins: ShippedPlugins.plugins(pasteboard: pasteboard, model: ScriptedLanguageModel()) + [PocketsPlugin()])) { _ in
            AnyView(EmptyView())
        }
        // Pocket P on the root; pocket Q on P's board, with a note on its board.
        let p = ShapeRecord(Pocket(CGRect(x: 0, y: 0, width: 160, height: 100))), q = ShapeRecord(Pocket(CGRect(x: 0, y: 0, width: 160, height: 100)))
        let note = ShapeRecord(StickyNote(frame: CGRect(x: 0, y: 0, width: 200, height: 200), text: "Deep"))
        let board = BoardDocument(), other = newBoard()
        board.editor.replaceFile(with: CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(p)]),
                                                  children: [p.id: CanvasDocument(shapes: [AnyShapeRecord(q)]),
                                                             q.id: CanvasDocument(shapes: [AnyShapeRecord(note)])]))
        expect(board.editor.showBoard(BoardID(owner: p.id)) && board.editor.showBoard(BoardID(owner: q.id)))
        let server = try startCommandServer(boards: [board, other], frontmost: board)
        defer { server.stop() }
        let status = try JSON(text: canvas(server, ["status"]).output)
        expectEqual(status["frontmostShows"], .string(q.id.description))
        let boards = try JSON(text: canvas(server, ["boards"]).output).arrayValue ?? []
        expectEqual(boards.map { $0["shows"] }, [.string(q.id.description), "root"])
        expectEqual(boards.first?["showsPath"], .array(["root", .string(p.id.description), .string(q.id.description)]))
        expectEqual(boards.first?["shapes"], 1, "the board shown's")
        let text = try canvas(server, ["boards", "--format", "text"]).output
        expect(text.contains("shows") && text.contains(q.id.description), text)

        expectEqual(try canvas(server, ["create", "ellipse"]).status, 0)
        expectEqual(board.editor.document.shapes.count, 2, "on the board shown")
        expectEqual(board.editor.file.root.shapes.map(\.id), [p.id])
        board.editor.showBoard(.root)
        board.editor.undo()
        expectEqual(board.editor.board, BoardID(owner: q.id), "the command's step is on the board it ran on")
        expectEqual(board.editor.document.shapes.map(\.id), [note.id])
        board.close()
        other.close()
    },
])

import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CanvasUI
import Connections
import Foundation
import LanguageModels
import Mentions
import ShippedTesting
import StickyNotes
import SwiftUI
import TableOfContents
import TestKit
import Titles
import Types

// The command line end to end, as an agent uses it: `canvas`, as it's built, talking to the app's
// command server, started as the app starts it (the shipped plugins' commands), on boards
// configured as the app configures them.

/// The app's command server on a socket of the test's own, for these boards; `build` is the build it says it is (a test process is none).
@MainActor func startCommandServer(boards: [BoardDocument], frontmost: BoardDocument?, build: String? = nil) throws -> CommandServer {
    // As the app makes it: the commands the plugins gave the host's slot for them.
    let server = CommandServer(path: temporarySocketPath(), commands: CommandServer.Commands(registry: try require(BoardDocument.configuration).registry),
                               build: build, boards: { boards }, frontmost: { frontmost })
    try server.start()
    return server
}

/// `canvas`, as built, asking `server`; `input` is its standard input.
@MainActor func canvas(_ server: CommandServer, _ arguments: [String], input: String? = nil) throws -> ProcessOutput {
    try run(builtExecutable("CanvasCLI"), ["--socket", server.path] + arguments, input: input)
}

/// Notes and two subboards, joined: the notes on their channel (once from and to named sides), the
/// subboards on theirs, and, plain, a note to a subboard, which has to say so (unwritten, it's on
/// the note's channel).
let diagram = #"""
sticky-note "Web" text: "Browser app"
sticky-note "API" right of "Web" text: "Public API"
sticky-note "Jobs" below "API" text: "Background work"
sticky-note "Mail" right of "Jobs" text: "Sends email"
subboard "Backend" below "Jobs" size: 600x200
subboard "Cache" left of "Backend"
edge "Web" -> "API"
edge "Jobs" -> "Mail" from: right to: left
edge "Backend" -> "Cache"
edge "API" -> "Cache" channel: none
"""#

/// The boards a test's server opened (`CommandServer`'s `show`), in order.
@MainActor final class Opened {
    var boards: [BoardDocument] = []
}

@MainActor func newBoard() -> BoardDocument {
    let board = BoardDocument()
    board.start(with: CanvasDocument())
    return board
}

@MainActor let commandLineTests = Suite("Command line", [
    test("canvas draw puts shapes on the board in front, as their tools would, with what it's told; the board is edited") {
        try configureBoards()
        let board = newBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let result = try canvas(server, ["draw", "sticky-note text: Hello"])
        expectEqual(result.status, 0, result.error)
        let changes = try JSON(text: result.output)["changes"]?.arrayValue ?? []
        expectEqual(changes.map { $0["did"] }, ["created"])
        expectEqual(changes.first?["kind"], "sticky-note")
        let note = try require(board.editor.document.shapes.first)
        expectEqual(note.typed(as: StickyNote.self)?.props.text, "Hello")
        // No window, so no view: a drawing with nothing to hang on is centered where the camera is.
        let size = StickyNote.defaultSize
        expectEqual(note.box, CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
        expect(board.isDocumentEdited)
        let unknown = try canvas(server, ["draw", "stickynote"])
        expectEqual(unknown.status, 1)
        expectEqual(try JSON(text: unknown.error)["error"]?["reason"], "unknown_kind")
        expect(try JSON(text: unknown.error)["error"]?["hint"]?.stringValue?.hasPrefix("did you mean sticky-note?") == true, unknown.error)
        expectEqual(try JSON(text: unknown.error)["error"]?["line"], 1)
        expectEqual(board.editor.document.shapes.count, 1)
    },
    test("canvas draw sticky-note text: takes plain text as it is, and mentions as written: of a subboard on the board, named as it is now") {
        try configureBoards()
        let board = newBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        // What a draw made: the shape new to the board (the result names no ids), and what it said.
        @MainActor func drew(_ script: String) throws -> (record: AnyShapeRecord, warnings: JSON?) {
            let before = Set(board.editor.document.shapes.map(\.id))
            let result = try canvas(server, ["draw", script])
            expectEqual(result.status, 0, result.error)
            let made = try require(board.editor.document.shapes.first { !before.contains($0.id) })
            return (made, try JSON(text: result.output)["warnings"])
        }
        @MainActor func text(_ record: AnyShapeRecord) throws -> MentionText { try require(record.typed(as: StickyNote.self)?.props.text) }

        // A backslash in a script's string is written twice.
        let plain = try drew(#"sticky-note text: "a@b.c, @ [x] and C:\\path""#)
        expectEqual(try text(plain.record).stored, #"a@b.c, @ [x] and C:\path"#)
        expectEqual(try text(plain.record).mentioned, [])
        expectEqual(plain.warnings, [])

        let subboard = try drew(#"subboard "Ship it""#).record
        let written = "Ask @[Ship](shape:\(subboard.id.rawValue.uuidString)) first, then @[it](shape:\(subboard.id.rawValue.uuidString.lowercased()))"
        let note = try drew(#"sticky-note text: "\#(written)""#)
        expectEqual(note.warnings, [], "every shape it mentions is there")
        expectEqual(try text(note.record).stored, written, "kept as written, an agent's lowercase id too")
        expectEqual(try text(note.record).mentioned, [subboard.id, subboard.id])
        expectEqual(board.editor.mentions?.mentioners(of: subboard.id), [note.record.id])
        let row = board.editor.tableOfContents?.entries.first { $0.id == note.record.id }?.label?.text
        expectEqual(row, "Ask @Ship it first, then @Ship it", "each mention by the subboard's title now")
    },
    test("canvas draw makes a note mentioning a shape that isn't in the file, and warns that it shows as missing; restated as it is, it says nothing more") {
        try configureBoards()
        let board = newBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let gone = ShapeID()
        let script = #"sticky-note "Plan" text: "See @[Old plan](shape:\#(gone)) again""#
        let result = try canvas(server, ["draw", script])
        expectEqual(result.status, 0, result.error)
        let json = try JSON(text: result.output)
        expectEqual(json["warnings"], [["line": 1, "message": .string(#""Plan": text names shapes that aren't in the file: \#(gone); they show as missing"#),
                                        "severity": "warning", "attribute": "text"]])
        let note = try require(board.editor.document.shapes.first?.typed(as: StickyNote.self))
        expectEqual(note.props.text.mentioned, [gone])
        expectEqual(board.editor.mentions?.resolve(gone), .missing)
        let again = try JSON(text: canvas(server, ["draw", script]).output)
        expectEqual(again["changes"]?.arrayValue?.map { $0["did"] }, ["unchanged"])
        expectEqual(again["warnings"], [], "what it names hasn't changed")
    },
    test("canvas draw sticky-note is as tall as its text, from its top; a size: is the least it is, kept through typing, and never cuts its text off") {
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
        let lines = (1...12).map { "Line \($0)" }.joined(separator: "\\n")
        _ = try drawnInProcess(#"sticky-note "Long" text: "\#(lines)""#, on: editor)
        _ = try drawnInProcess(#"sticky-note "Sized" right of "Long" text: "\#(lines)" size: 200x200"#, on: editor)
        _ = try drawnInProcess(#"sticky-note "Short" right of "Sized" text: "Hi""#, on: editor)
        _ = try drawnInProcess(#"sticky-note "Tall" right of "Short" text: "Hi" size: 260x400"#, on: editor)
        @MainActor func note(_ title: String) -> ShapeRecord<StickyNote>? {
            editor.document.shapes.first { $0[TitleProperty.self] == title }?.typed(as: StickyNote.self)
        }
        @MainActor func height(_ title: String) -> CGFloat? { note(title)?.frame.height }
        expectEqual(height("Long"), 12 * 19 + 33, "twelve lines")
        expectEqual(height("Sized"), 12 * 19 + 33, "as tall as its text, past the height asked")
        expectEqual(note("Sized")?.props.givenHeight, 200, "which it keeps")
        expectEqual(height("Short"), 200, "a new note's")
        expectEqual(height("Tall"), 400, "as asked")
        // Typed into, it keeps the height it was given, as a note resized by hand does.
        let tall = try require(note("Tall")?.id)
        expect(editor.beginEditing(tall))
        let textView = try require(editor.makeEditingView()?.firstResponder as? NSTextView)
        textView.insertText(" there", replacementRange: textView.selectedRange())
        editor.endEditing()
        expectEqual(height("Tall"), 400, "typing keeps it")
        // Restated shorter than a new note, with a line of text: as asked, the text fitting.
        _ = try drawnInProcess(#"sticky-note "Short" size: 260x120"#, on: editor)
        expectEqual(height("Short"), 120)
    },
    test("canvas boards lists the open boards; --board picks one by its id, its file or its name") {
        try configureBoards()
        let first = newBoard(), second = newBoard()
        defer { first.close(); second.close() }
        second.fileURL = URL(fileURLWithPath: "/tmp/Plans For Q4.canvasboard")
        let server = try startCommandServer(boards: [first, second], frontmost: nil)
        defer { server.stop() }
        let boards = try JSON(text: canvas(server, ["boards"]).output).arrayValue ?? []
        expectEqual(boards.compactMap { $0["id"]?.intValue }, [first.number, second.number])
        expectEqual(boards.last?["path"], "/tmp/Plans For Q4.canvasboard")
        expectEqual(boards.map { $0["frontmost"] }, [false, false])
        let ambiguous = try canvas(server, ["draw", "sticky-note"])
        expectEqual(ambiguous.status, 1)
        expectEqual(try JSON(text: ambiguous.error)["error"]?["reason"], "ambiguous_board")
        expectEqual(try canvas(server, ["draw", "sticky-note", "--board", "\(second.number)"]).status, 0)
        expectEqual(try canvas(server, ["draw", "sticky-note", "--board", "/tmp/Plans For Q4.canvasboard"]).status, 0)
        expectEqual(try canvas(server, ["--board", second.displayName, "draw", "sticky-note"]).status, 0)
        expectEqual(second.editor.document.shapes.count, 3)
        expectEqual(first.editor.document.shapes.count, 0)
        let missing = try canvas(server, ["draw", "sticky-note", "--board", "Nope"])
        expectEqual(try JSON(text: missing.error)["error"]?["reason"], "unknown_board")
    },
    test("canvas new makes a board's file as Save As does, opens it, and says it as boards lists it; a file that's there or open, a folder that isn't, another type's file and a save that fails are refused") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let first = newBoard()
        defer { first.close() }
        let folder = scratchURL("new")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let opened = Opened()
        defer { for board in opened.boards { board.close() } }
        let commands = try require(BoardDocument.configuration).registry.hostCommands
        let server = CommandServer(path: temporarySocketPath(), commands: CommandServer.Commands(specs: commands.specs, run: commands.run),
                                   boards: { [first] + opened.boards }, frontmost: { opened.boards.last ?? first }, show: { opened.boards.append($0) })
        try server.start()
        defer { server.stop() }

        let made = try canvas(server, ["new", folder.appendingPathComponent("Plans").path])
        expectEqual(made.status, 0, made.error)
        let board = try require(opened.boards.first)
        let file = folder.appendingPathComponent("Plans.canvasboard")
        expectEqual(board.fileURL?.resolvingSymlinksInPath(), file.resolvingSymlinksInPath(), "with the boards' extension")
        expectEqual(board.fileType, BoardConfiguration.typeIdentifier)
        expectEqual(try Data(contentsOf: file), try BoardCodec(registry: board.editor.registry).encode(CanvasFile()), "the codec's empty board")
        expect(!board.isDocumentEdited)
        let said = try JSON(text: made.output)
        let listed = try JSON(text: canvas(server, ["boards"]).output).arrayValue ?? []
        expectEqual(listed.count, 2)
        expectEqual(said, listed.last, "as boards lists it")
        expectEqual(said["id"], .number(Double(board.number)))
        expectEqual(said["path"], board.fileURL.map { .string($0.path) })
        expectEqual(said["frontmost"], true)
        expectEqual(said["fileShapes"], 0)
        let drawn = try canvas(server, ["draw", #"sticky-note "First""#, "--board", "\(board.number)"])
        expectEqual(drawn.status, 0, drawn.error)
        expectEqual(board.editor.document.shapes.count, 1, "its id is its --board")
        expectEqual(first.editor.document.shapes.count, 0)

        @MainActor func refused(_ path: String) throws -> JSON? { try JSON(text: canvas(server, ["new", path]).error)["error"] }
        let again = try refused(file.path)
        expectEqual(again?["reason"], "file_exists")
        expectEqual(again?["message"], .string("\(file.path) is open already, as board \(board.number)."))
        expectEqual(again?["hint"], .string("Name it with --board \(board.number), or make another file."))
        let old = folder.appendingPathComponent("Old.canvasboard")
        FileManager.default.createFile(atPath: old.path, contents: Data("kept".utf8))
        expectEqual(try refused(old.path)?["reason"], "file_exists")
        expectEqual(try Data(contentsOf: old), Data("kept".utf8), "left as it was")
        let sub = folder.appendingPathComponent("Sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        expectEqual(try refused(sub.path)?["message"], .string("\(sub.path) is a folder."), "as written, a folder, not Sub.canvasboard")
        let text = try refused(folder.appendingPathComponent("Notes.txt").path)
        expectEqual(text?["reason"], "invalid_params")
        expectEqual(text?["message"], "A board's file ends in .canvasboard, and Notes.txt is a .txt file.")
        expectEqual(text?["hint"], .string("canvas new \(folder.appendingPathComponent("Notes.canvasboard").path)"))
        let nowhere = try refused(folder.appendingPathComponent("Later/Plans.canvasboard").path)
        expectEqual(nowhere?["reason"], "no_folder")
        expectEqual(nowhere?["message"], .string("There's no folder \(folder.appendingPathComponent("Later").path)."))
        let locked = folder.appendingPathComponent("Locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        expectEqual(try refused(locked.appendingPathComponent("Plans").path)?["reason"], "cannot_save")
        expectEqual(opened.boards.count, 1, "nothing refused was opened")
        expectEqual(BoardDocument.unclosed.count, 2, "a board whose save failed is closed")
        expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("Notes.canvasboard").path))
        expectEqual(try canvas(server, ["new", "--board", "1", file.path]).status, 2, "about the app, not a board")

        // A name with a dot that's no type's extension is a name: the boards' extension goes after it.
        let dotted = try canvas(server, ["new", folder.appendingPathComponent("Sprint 3.2").path])
        expectEqual(dotted.status, 0, dotted.error)
        expect(try JSON(text: dotted.output)["path"]?.stringValue?.hasSuffix("/Sprint 3.2.canvasboard") == true, dotted.output)
        expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Sprint 3.2.canvasboard").path))
        // Two at once for one file: one makes it, and the other is refused, whichever comes first.
        let request = RPCRequest(id: .number(1), method: RPC.newCommand, params: ["path": .string(folder.appendingPathComponent("Twice").path)])
        let both = try awaitResult {
            async let one = server.respond(to: request)
            async let two = server.respond(to: request)
            return await [one, two]
        }
        expectEqual(both.filter { (try? $0.get()) != nil }.count, 1)
        expectEqual(both.compactMap { if case .failure(let error) = $0 { error.reason } else { nil } }, ["file_exists"])
        expectEqual(opened.boards.count, 3)

        let none = CommandServer(path: temporarySocketPath(), commands: CommandServer.Commands(specs: commands.specs, run: commands.run),
                                 boards: { [] }, frontmost: { nil })
        try none.start()
        defer { none.stop() }
        let nothing = try JSON(text: canvas(none, ["draw", #"sticky-note "A""#]).error)["error"]
        expectEqual(nothing?["reason"], "no_board")
        expectEqual(nothing?["hint"], "Make one: canvas new <file>, or open one in Infinite Canvas.")
    },
    test("a board command's result says which board it worked on, as boards lists it; an app command's doesn't") {
        try configureBoards()
        let first = newBoard(), second = newBoard()
        defer { first.close(); second.close() }
        let server = try startCommandServer(boards: [first, second], frontmost: first)
        defer { server.stop() }
        let listed = try JSON(text: canvas(server, ["boards"]).output).arrayValue ?? []
        let front = try JSON(text: canvas(server, ["draw", "sticky-note"]).output)
        expectEqual(front["board"], ["id": .number(Double(first.number)), "name": .string(first.displayName), "shows": "root", "showsPath": ["root"]])
        for key in ["id", "name", "shows", "showsPath"] { expectEqual(front["board"]?[key], listed.first?[key], key) }
        let named = try JSON(text: canvas(server, ["draw", "sticky-note", "--board", "\(second.number)"]).output)
        expectEqual(named["board"]?["id"], .number(Double(second.number)))
        expect(named["changes"] != nil && named["warnings"] != nil, "beside what the command said")
        let kinds = try JSON(text: canvas(server, ["kinds", "sticky-note"]).output)
        expect(kinds.arrayValue != nil, "a list, which has no board")
        let status = try JSON(text: canvas(server, ["status"]).output)
        expectEqual(status["board"], nil)
    },
    test("measure is a board command whose board is optional, as the app describes it, and the protocol is still 2; other board commands are not optional") {
        try configureBoards()
        let board = newBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let measure = try JSON(text: canvas(server, ["help", "measure", "--format", "json"]).output).decode(CommandSpec.self)
        expectEqual(measure.scope, .board)
        expectEqual(measure.boardOptional, true)
        let draw = try JSON(text: canvas(server, ["help", "draw", "--format", "json"]).output).decode(CommandSpec.self)
        expectEqual(draw.boardOptional, nil)
        expectEqual(try JSON(text: canvas(server, ["status"]).output)["protocol"], .number(Double(RPC.protocolVersion)))
        expectEqual(RPC.protocolVersion, 2, "a command's boardOptional is a member an older reader passes over")
        // With no board open it runs, on none; a board command that isn't optional is refused.
        let empty = try startCommandServer(boards: [], frontmost: nil)
        defer { empty.stop() }
        let none = try canvas(empty, ["measure", "-"], input: #"sticky-note "A""#)
        expectEqual(none.status, 0, none.error)
        expectEqual(try JSON(text: none.output)["board"], nil)
        let refused = try canvas(empty, ["draw", "sticky-note"])
        expect(refused.status != 0 && refused.error.contains("no_board"), refused.error)
    },
    test("canvas draw draws a diagram of the shipped kinds, titled, placed, and joined on their channels or plainly") {
        try configureBoards()
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        // As the skill writes it: the options between the command and its script, on standard input.
        let result = try canvas(server, ["draw", "--board", "\(board.number)", "-"], input: diagram)
        expectEqual(result.status, 0, result.error)
        let said = try JSON(text: result.output)
        let rows = said["changes"]?.arrayValue ?? []
        expectEqual(rows.map { $0["did"] }, Array(repeating: "created", count: 6) + Array(repeating: "connected", count: 4))
        expectEqual(rows.compactMap { $0["title"]?.stringValue }, ["Web", "API", "Jobs", "Mail", "Backend", "Cache"])
        expectEqual(rows.filter { $0["from"] != nil }.map { $0["channel"] }, ["note-link", "note-link", "subboard-link", nil])
        expectEqual(said["warnings"], [], "clear of each other, and valid")
        expectEqual(said["dryRun"], nil)

        let editor = board.editor, registry = editor.registry
        @MainActor func shape(_ title: String) throws -> AnyShapeRecord { try require(editor.document.shapes.first { registry.title(of: $0) == title }, title) }
        let web = try require(try shape("Web").box), api = try require(try shape("API").box)
        expectEqual(api.minX, web.maxX + 80, "a normal gap")
        expectEqual(api.midY, web.midY, "a lone direction centers the other axis")
        expectEqual(try shape("Cache").kind, "subboard")

        let arrows = editor.document.shapes.compactMap { $0.typed(as: Arrow.self) }
        @MainActor func title(_ terminal: ArrowTerminal) -> String? { terminal.binding.flatMap { editor.document[$0.shapeID] }.flatMap { registry.title(of: $0) } }
        expectEqual(arrows.map { "\(title($0.props.start) ?? "?") -> \(title($0.props.end) ?? "?") \($0[ChannelProperty.self]?.rawValue ?? "plain")" },
                    ["Web -> API note-link", "Jobs -> Mail note-link", "Backend -> Cache subboard-link", "API -> Cache plain"])
        let aimed = try require(arrows.first { title($0.props.start) == "Jobs" })
        expectEqual(aimed.props.start.binding?.normalizedAnchor, CGPoint(x: 1, y: 0.5), "from: right")
        expectEqual(aimed.props.end.binding?.normalizedAnchor, CGPoint(x: 0, y: 0.5), "to: left")
        expect(aimed.props.start.binding?.isPrecise == true && aimed.props.end.binding?.isPrecise == true)
    },
    test("canvas draw run again changes nothing: every row unchanged, no shape added; a named side that faces away is said") {
        try configureBoards()
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        expectEqual(try draw(diagram, on: board, server).status, 0)
        let drawn = board.editor.document
        let again = try draw(diagram, on: board, server)
        expectEqual(again.status, 0, again.error)
        let rows = try JSON(text: again.output)["changes"]?.arrayValue ?? []
        expectEqual(rows.count, 10)
        expectEqual(Set(rows.compactMap { $0["did"]?.stringValue }), ["unchanged"])
        expectEqual(board.editor.document, drawn)
        let away = try JSON(text: try draw(#"edge "Web" -> "API" from: left"#, on: board, server).output)
        expectEqual(away["changes"]?.arrayValue?.map { $0["did"] }, ["reconnected"])
        expectEqual(away["warnings"]?.arrayValue?.compactMap { $0["message"]?.stringValue },
                    [#"from: left: "API" is right of "Web", so the line leaves "Web" by its right side — name a side that faces "API", or leave from: out"#])
    },
    test("canvas draw writes what an arrow says, and where, as attributes of its edge; a head its arrow doesn't say is refused") {
        try configureBoards()
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        expectEqual(try draw(diagram, on: board, server).status, 0)
        let labeled = try draw(#"edge "Web" -> "API" text: "Calls" labelPosition: 0.25"#, on: board, server)
        expectEqual(try JSON(text: labeled.output)["changes"]?.arrayValue?.map { $0["did"] }, ["reconnected"], labeled.error)
        let editor = board.editor
        @MainActor func said() -> [String] {
            editor.document.shapes.compactMap { $0.typed(as: Arrow.self) }.filter(\.props.hasText).map { "\($0.props.text) \($0.props.labelPosition)" }
        }
        expectEqual(said(), ["Calls 0.25"])
        expectEqual(try JSON(text: try draw(#"edge "Web" -> "API""#, on: board, server).output)["changes"]?.arrayValue?.map { $0["did"] }, ["unchanged"],
                    "restated without it, it keeps what it says")
        expectEqual(try draw(#"edge "Web" -> "API" text: null"#, on: board, server).status, 0)
        expectEqual(said(), [])
        let head = try draw(#"edge "Web" -> "API" startArrowhead: true"#, on: board, server)
        expectEqual(head.status, 1)
        expectEqual(try JSON(text: head.error)["error"]?["message"], #"edge "Web" -> "API": startArrowhead: true isn't what the edge as written says"#)
        let quoted = try draw(#"edge "Web" -> "API" "Calls""#, on: board, server)
        expectEqual(try JSON(text: quoted.error)["error"]?["hint"], #"what an edge says is written after a key: text: "Calls""#)
    },
    test("canvas draw --dry-run says what it would do and commits nothing; a script can be the one argument") {
        try configureBoards()
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let dry = try draw(diagram, on: board, server, ["--dry-run"])
        expectEqual(dry.status, 0, dry.error)
        let said = try JSON(text: dry.output)
        expectEqual(said["dryRun"], true)
        expectEqual(said["changes"]?.arrayValue?.count, 10)
        expectEqual(board.editor.document.shapes.count, 0)
        expect(!board.isDocumentEdited)
        let argument = try canvas(server, ["draw", #"sticky-note "Zone" size: 400x200"#])
        expectEqual(argument.status, 0, argument.error)
        expectEqual(board.editor.document.shapes.map(\.kind), ["sticky-note"])
    },
    test("a script canvas draw refuses changes nothing, and says why on standard error: each line's problem, the first leading") {
        try configureBoards()
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let result = try draw("""
            sticky-note "A" text: "a"
            sticky-note "B" right of "A" locked: maybe
            sticky-note "C" below "A" colr: red
            """, on: board, server)
        expectEqual(result.status, 1)
        expectEqual(result.output, "")
        let error = try require(try JSON(text: result.error)["error"])
        expectEqual(error["reason"], "invalid_value")
        expectEqual(error["line"], 2)
        expectEqual(error["statement"], #"sticky-note "B" right of "A" locked: maybe"#)
        expectEqual(error["hint"], "locked: takes true|false")
        expectEqual(error["status"], 1)
        let each = error["errors"]?.arrayValue ?? []
        expectEqual(each.map { $0["line"] }, [2, 3])
        expectEqual(each.map { $0["reason"] }, ["invalid_value", "unknown_attribute"])
        expectEqual(each.last?["statement"], #"sticky-note "C" below "A" colr: red"#)
        expectEqual(board.editor.document.shapes.count, 0)
        let text = try draw(#"sticky-note "A" rigth of "B""#, on: board, server, ["--format", "text"])
        expectEqual(text.error, "canvas: line 1: sticky-note \"A\": rigth isn't a placement\n  sticky-note \"A\" rigth of \"B\"\nhint: did you mean right?\n")
    },
    test("status, kinds and help describe the app the command line is talking to") {
        try configureBoards()
        let board = newBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let status = try JSON(text: canvas(server, ["status"]).output)
        expectEqual(status["protocol"], .number(Double(RPC.protocolVersion)))
        expectEqual(status["boards"], 1)
        expectEqual(status["frontmost"], .number(Double(board.number)))
        expectEqual(status["build"], nil, "a process that is not a built app says no build")
        let built = CommandServer(path: temporarySocketPath(), commands: CommandServer.Commands(registry: try require(BoardDocument.configuration).registry),
                                  build: "abc123-dirty-0f0f0f0f", boards: { [board] }, frontmost: { board })
        try built.start()
        defer { built.stop() }
        expectEqual(try JSON(text: canvas(built, ["status"]).output)["build"], "abc123-dirty-0f0f0f0f", "status says the build")
        let described = try JSON(text: canvas(built, ["help", "--format", "json"]).output).decode(AppDescription.self)
        expectEqual(described.app.build, "abc123-dirty-0f0f0f0f", "and so does describe")
        let kinds = try JSON(text: canvas(server, ["kinds"]).output).arrayValue?.compactMap { $0["kind"]?.stringValue } ?? []
        expectEqual(kinds, try ShippedPlugins.registry(model: ScriptedLanguageModel()).kinds.map(\.rawValue).sorted())
        let note = try JSON(text: canvas(server, ["kinds", "sticky-note", "--schema"]).output).arrayValue?.first
        expectEqual(note?["schema"]?["properties"]?["title"]?["maxLength"], 80)
        let help = try canvas(server, ["help"]).output
        for command in ["status", "boards", "new", "draw", "kinds"] { expect(help.contains("\n  \(command) "), help) }
    },
    test("canvas draw says what a habit meant, refuses a kind no tool places, and deletes an arrow with the shape it leaves") {
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
        editor.viewportDidResize(to: CGSize(width: 1440, height: 900))
        // Another language's word for a shape is told the kind like it; its word for a connection, the edge.
        let word = try refusedInProcess(#"note "Idea" text: "Try a cache""#, on: editor)
        expectEqual(word.reason, "unknown_kind")
        expectEqual(word.hint, #"did you mean sticky-note? the kinds drawn here: frame, reference, sticky-note, subboard; a statement starts with its kind, as in sticky-note "A""#)
        expectEqual(try refusedInProcess(#"link "A""#, on: editor).hint,
                    #"to join two shapes, write edge "A" -> "B"; the kinds drawn here: frame, reference, sticky-note, subboard"#)
        // A kind no tool places: an arrow is an edge.
        let placing = try refusedInProcess(#"arrow "A""#, on: editor)
        expectEqual(placing.reason, "not_placeable")
        expectEqual(placing.hint, #"to join two shapes, write edge "A" -> "B""#)
        // A delete takes an arrow that leaves the shape for empty canvas.
        _ = try drawnInProcess(#"sticky-note "Old""#, on: editor)
        let old = try require(editor.document.shapes.first { editor.registry.title(of: $0) == "Old" })
        let arrow = AnyShapeRecord(ShapeRecord(Arrow(start: .bound(ArrowBinding(shapeID: old.id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false,
                                                                                isExact: false)),
                                                     end: .free(CGPoint(x: 5000, y: 5000)))))
        editor.transact { $0.insert(arrow) }
        let deleted = try drawnInProcess(#"delete "Old""#, on: editor)
        expectEqual(deleted["changes"]?.arrayValue?.map { [$0["did"], $0["kind"]] }, [["deleted", "sticky-note"], ["deleted", "arrow"]])
        expectEqual(editor.document[arrow.id], nil)
    },
    test("a hint that says what to write runs as written, and a script can't take a title away, however it says none") {
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
        editor.viewportDidResize(to: CGSize(width: 1440, height: 900))
        let braces = try refusedInProcess(#"sticky-note "Web" {"size": "300x200", "gap": "wide", "text": "x"}"#, on: editor)
        let hint = try require(braces.hint)
        expectEqual(hint, #"write size: 300x200 gap: wide text: "x""#)
        let hinted = try drawnInProcess(#"sticky-note "Web" "# + hint.dropFirst("write ".count), on: editor)
        expectEqual(hinted["changes"]?.arrayValue?.first?["at"], [[570, 350], [300, 200]])
        for none in ["none", "nil", "null"] {
            expectEqual(try refusedInProcess(#"sticky-note "Web" title: "# + none, on: editor).reason, "unsupported", none)
        }
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
        other.editor.viewportDidResize(to: CGSize(width: 1440, height: 900))   // the other's window has a size; the first's has none yet
        let server = try startCommandServer(boards: [board, other], frontmost: board)
        defer { server.stop() }
        let status = try JSON(text: canvas(server, ["status"]).output)
        expectEqual(status["frontmostShows"], .string(q.id.description))
        let boards = try JSON(text: canvas(server, ["boards"]).output).arrayValue ?? []
        expectEqual(boards.map { $0["shows"] }, [.string(q.id.description), "root"])
        expectEqual(boards.first?["showsPath"], .array(["root", .string(p.id.description), .string(q.id.description)]))
        expectEqual(boards.first?["shapes"], 1, "the board shown's")
        expectEqual(boards.first?["fileShapes"], 3, "every board's")
        expectEqual(boards.last?["fileShapes"], 0)
        // view: the room a window has for a board fit into it, the canvas less a fit's margin; none for a window with no size
        let inset = Double(CanvasEditor.firstVisitInset)
        expectEqual(boards.last?["view"], .array([.number(1440 - 2 * inset), .number(900 - 2 * inset)]), "what a first visit fits a board into")
        expectEqual(boards.first?["view"], nil, "a window with no size says none")
        other.editor.viewportDidResize(to: CGSize(width: 100, height: 2 * CanvasEditor.firstVisitInset))
        expectEqual(try JSON(text: canvas(server, ["boards"]).output).arrayValue?.last?["view"], nil, "nor one with no room to spare")
        let text = try canvas(server, ["boards", "--format", "text"]).output
        expect(text.contains("shows") && text.contains(q.id.description), text)

        let drawn = try canvas(server, ["draw", #"sticky-note "E""#])
        expectEqual(drawn.status, 0, drawn.error)
        expectEqual(try JSON(text: drawn.output)["board"]?["shows"], .string(q.id.description), "it says where it drew")
        expectEqual(board.editor.document.shapes.count, 2, "on the board shown")
        expectEqual(board.editor.undoHistory.undoName, "Draw")
        expectEqual(board.editor.file.root.shapes.map(\.id), [p.id])
        board.editor.showBoard(.root)
        board.editor.undo()
        expectEqual(board.editor.board, BoardID(owner: q.id), "the command's step is on the board it ran on")
        expectEqual(board.editor.document.shapes.map(\.id), [note.id])
        board.close()
        other.close()
    },
    test("a board command's result names the board it ran on, read as it runs: a switch between its request and its run is where it ran") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureQueryBoards(pasteboard: pasteboard, model: ScriptedLanguageModel())
        let board = try QueryStory.document(windowed: false)
        defer { board.close() }
        let look = CommandServer.Commands(specs: [CommandSpec(name: "look", summary: "Say which board it's on.", scope: .board)]) { _, _, editor async throws(RPCError) -> JSON in
            ["saw": .string(editor?.board.description ?? "none")]
        }
        let server = CommandServer(path: temporarySocketPath(), commands: look, boards: { [board] }, frontmost: { board })
        let answer = Handoff<Result<JSON, RPCError>>()
        Task { @MainActor in answer.value = await server.respond(to: RPCRequest(id: .number(1), method: "look")) }
        // Queued after the request's job, so before the command's, which the request's job queues:
        // as the person going into a board while the request is read.
        DispatchQueue.main.async { MainActor.assumeIsolated { _ = board.editor.showBoard(BoardID(owner: QueryStory.payments)) } }
        spinRunLoop(until: { answer.value != nil })
        let result = try require(answer.value).get()
        let payments = JSON.string(QueryStory.payments.description)
        expectEqual(result["saw"], payments)
        expectEqual(result["board"]?["shows"], payments, "the board it ran on")
        expectEqual(result["board"]?["showsPath"], ["root", payments])
        expectEqual(result["board"]?["id"], .number(Double(board.number)))
    },
    test("a board command still running when its board's file closes is answered board_closed at once, and its task cancelled") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = newBoard(), lingering = Lingering()
        let server = CommandServer(path: temporarySocketPath(), commands: lingering.commands, boards: { [board] }, frontmost: { board })
        try server.start()
        defer { server.stop() }
        let answer = Handoff<Result<JSON, ClientError>>(), path = server.path
        Thread { answer.value = Result { () throws(ClientError) in try RPCClient(path: path).call("linger") } }.start()
        spinRunLoop(until: { lingering.isWaiting })
        expect(lingering.editor === board.editor, "it runs on the board's editor")
        board.close()
        spinRunLoop(until: { answer.value != nil })
        expect(lingering.isWaiting, "answered before the command finished")
        guard case .failure(.remote(let error)) = answer.value else { return expect(false, "\(String(describing: answer.value))") }
        expectEqual(error.reason, "board_closed")
        expectEqual(error.message, "The board was closed before the command finished.")
        spinRunLoop(until: { lingering.wasCancelled })
        spinRunLoop(until: { RPCListener.activitiesHeld == 0 })
        expect(lingering.isWaiting, "the request's activity ends with its answer, though the command runs on")
        lingering.letGo()
        spinRunLoop(until: { lingering.finished })
    },
    test("a command whose canvas stops waiting (a timeout, ^C) is cancelled") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = newBoard(), lingering = Lingering()
        let server = CommandServer(path: temporarySocketPath(), commands: lingering.commands, boards: { [board] }, frontmost: { board })
        try server.start()
        defer { server.stop() }
        let late = try canvas(server, ["--timeout", "0.3", "linger"])
        expectEqual(late.status, 3, late.error)
        expectEqual(try JSON(text: late.error)["error"]?["reason"], "timed_out")
        expect(lingering.isWaiting)
        spinRunLoop(until: { lingering.wasCancelled })
        spinRunLoop(until: { RPCListener.activitiesHeld == 0 })
        expect(lingering.isWaiting, "the request's activity ends as canvas hangs up, though the command runs on")
        lingering.letGo()
        spinRunLoop(until: { lingering.finished })
        board.close()
    },
    test("canvas draw joins two frames on the frame link, and a subboard to a frame; a note and a frame share no channel; a frame and a shape it holds, no edge, on any channel or none") {
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
        editor.viewportDidResize(to: CGSize(width: 1440, height: 900))
        _ = try drawnInProcess("""
            frame "Sprint 1" size: 400x300
            frame "Sprint 2" right of "Sprint 1" size: 400x300
            subboard "Archive" below "Sprint 1"
            """, on: editor)
        _ = try drawnInProcess(#"sticky-note "Login" in "Sprint 1""#, on: editor)
        let joined = try drawnInProcess("""
            edge "Sprint 1" -> "Sprint 2"
            edge "Archive" -> "Sprint 2"
            """, on: editor)
        expectEqual(joined["changes"]?.arrayValue?.map { $0["channel"] }, ["frame-link", "frame-link"])
        let apart = try refusedInProcess(#"edge "Login" -> "Sprint 2""#, on: editor)
        expectEqual(apart.reason, "no_channel")
        expectEqual(apart.message, #""Login" and "Sprint 2" share no channel: a sticky-note connects on note-link, a frame on frame-link"#)
        let holds = try refusedInProcess(#"edge "Sprint 1" -> "Login""#, on: editor)
        expectEqual(holds.reason, "cannot_connect")
        expectEqual(holds.message, #""Sprint 1" can't be connected to "Login", which it holds"#)
        expectEqual(holds.hint, #"connect "Login" to a shape that doesn't hold it"#)
        let held = try refusedInProcess(#"edge "Login" -> "Sprint 1" channel: none"#, on: editor)
        expectEqual(held.reason, "cannot_connect")
        expectEqual(held.message, #""Login" can't be connected to "Sprint 1", which holds it"#)
    },
])

/// A board command, `linger`, that waits until the test lets it go, whatever happens meanwhile (as a
/// command that never checks for cancellation does), and notes the editor it ran on, whether its task
/// was cancelled, and that it finished.
@MainActor
final class Lingering {
    private var waiting: CheckedContinuation<Void, Never>?
    private(set) weak var editor: CanvasEditor?
    private(set) var wasCancelled = false
    private(set) var finished = false

    var isWaiting: Bool { waiting != nil }

    func letGo() {
        waiting?.resume()
        waiting = nil
    }

    var commands: CommandServer.Commands {
        CommandServer.Commands(specs: [CommandSpec(name: "linger", summary: "Wait until let go.", scope: .board)]) { [self] _, _, editor async throws(RPCError) -> JSON in
            self.editor = editor
            await withTaskCancellationHandler {
                await withCheckedContinuation { waiting = $0 }
            } onCancel: {
                Task { @MainActor in self.wasCancelled = true }
            }
            finished = true
            return ["lingered": true]
        }
    }
}

/// `draw`, as the app's command server runs it, in this process, on `editor`.
@MainActor func drawInProcess(_ script: String, on editor: CanvasEditor) -> Result<JSON, RPCError> {
    let commands = editor.registry.hostCommands
    let result = try? awaitResult { () async -> Result<JSON, RPCError> in
        do throws(RPCError) {
            return .success(try await commands.run("draw", ["script": .string(script)], editor))
        } catch {
            return .failure(error)
        }
    }
    return result ?? .failure(RPCError(RPCError.internalError, reason: "timed_out", "draw didn't answer."))
}

@MainActor func drawnInProcess(_ script: String, on editor: CanvasEditor) throws -> JSON {
    try drawInProcess(script, on: editor).get()
}

@MainActor func refusedInProcess(_ script: String, on editor: CanvasEditor) throws -> RPCError {
    guard case .failure(let error) = drawInProcess(script, on: editor) else {
        expect(false, "\(script) should be refused")
        return RPCError(RPCError.failed, reason: "", "")
    }
    return error
}

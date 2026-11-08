import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasUI
import Foundation
import LanguageModels
import Queries
import Selection
import ShippedTesting
import SwiftUI
import TestKit
import Titles

// `canvas query`, as it's built, against the app's command server on real boards (the story file
// in a board document, `QueryStory.document()`): JSON and text, its options, its refusals with
// their carets and exit codes, the whole file and the board its window shows, a query that changes
// nothing, and `--ask` waiting on a model (a `ScriptedLanguageModel`) while the app goes on.

/// Boards as the app configures them (`configureBoards`), their clipboard on `pasteboard` and their
/// language model `model`, a test's own.
@MainActor func configureQueryBoards(pasteboard: NSPasteboard, model: ScriptedLanguageModel) throws {
    BoardDocument.configuration = BoardConfiguration(registry: try ShippedPlugins.registry(pasteboard: pasteboard, model: model)) { board in
        AnyView(InspectorHost(editor: board.editor, focus: board.focus, showsDetails: board.view.showsDetails, showsMinimap: board.view.showsMinimap,
                              view: board.view))
    }
}

/// The app's command server on a socket of the test's own, for `board` alone, which it holds
/// weakly (as the app holds its documents' list): once the board is closed and let go of, it's gone.
@MainActor func startQueryServer(for board: BoardDocument?) throws -> CommandServer {
    let commands = try require(BoardDocument.configuration).registry.hostCommands
    let server = CommandServer(path: temporarySocketPath(), commands: CommandServer.Commands(specs: commands.specs, run: commands.run),
                               boards: { [weak board] in board.map { [$0] } ?? [] }, frontmost: { [weak board] in board })
    try server.start()
    return server
}

/// `canvas`, as built, asking `server`, left running while the test goes on: an agent's call that
/// waits on the app (a model's answer). `finish` waits for it to end.
@MainActor final class RunningCanvas {
    private let process = Process()
    private let folder: URL
    private let output: URL
    private let error: URL

    init(_ server: CommandServer, _ arguments: [String], input: String? = nil) throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        output = folder.appendingPathComponent("out")
        error = folder.appendingPathComponent("err")
        let standardInput = folder.appendingPathComponent("in")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        FileManager.default.createFile(atPath: error.path, contents: nil)
        FileManager.default.createFile(atPath: standardInput.path, contents: Data((input ?? "").utf8))
        process.executableURL = builtExecutable("CanvasCLI")
        process.arguments = ["--socket", server.path] + arguments
        process.standardOutput = try FileHandle(forWritingTo: output)
        process.standardError = try FileHandle(forWritingTo: error)
        process.standardInput = try FileHandle(forReadingFrom: standardInput)
        try process.run()
    }

    var isRunning: Bool { process.isRunning }

    /// Turns the main run loop until it ends (or `timeout` seconds pass, and it's stopped), and says
    /// how it ended and what it wrote.
    func finish(timeout: TimeInterval = 20) throws -> (status: Int32, output: String, error: String) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while process.isRunning, Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.002)) }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        defer { try? FileManager.default.removeItem(at: folder) }
        return (process.terminationStatus, try String(contentsOf: output, encoding: .utf8), try String(contentsOf: error, encoding: .utf8))
    }
}

/// `canvas query - --board <board>` with `query` on standard input, and `options`.
@MainActor func query(_ query: String, on board: BoardDocument, _ server: CommandServer, _ options: [String] = []) throws -> ProcessOutput {
    try canvas(server, ["query", "-", "--board", "\(board.number)"] + options, input: query)
}

/// The ids of a query's rows, as `canvas` wrote them.
func rowIDs(_ output: String) throws -> [String] {
    try JSON(text: output)["rows"]?.arrayValue?.compactMap { $0["id"]?.stringValue } ?? []
}

/// The story's shapes by their letters, as `canvas` writes their ids.
@MainActor func storyIDs(_ letters: String) -> [String] {
    QueryStory.ids(letters).map(\.description)
}

@MainActor let queryCommandLineTests = Suite("Query command line", [
    test("canvas query answers as JSON: each row's id, kind, title, board, the boards it's inside and its attributes, and the board it ran on") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureQueryBoards(pasteboard: pasteboard, model: ScriptedLanguageModel())
        let board = try QueryStory.document(windowed: false)
        defer { board.close() }
        let server = try startQueryServer(for: board)
        defer { server.stop() }

        let answered = try query(#"sticky-note:mentions("API gateway")"#, on: board, server)
        expectEqual(answered.status, 0, answered.error)
        expectEqual(answered.error, "")
        expectEqual(try JSON(text: answered.output), [
            "query": #"sticky-note:mentions("API gateway")"#,
            "count": 1,
            "rows": [[
                "id": "00000000-0000-4000-8000-000000000011", "kind": "sticky-note", "title": "Checkout",
                "board": "00000000-0000-4000-8000-000000000001", "inside": ["Payments"], "at": [[80, 80], [260, 200]],
                "properties": ["text": "Calls @API gateway for tokens"],
            ]],
            "board": ["id": .number(Double(board.number)), "name": .string(board.displayName), "shows": "root", "showsPath": ["root"]],
        ])

        // A connection's row says where it runs; an untitled shape's has no title, and one on the
        // top board no inside.
        let link = try query("arrow[channel=note-link]", on: board, server)
        expectEqual(try JSON(text: link.output)["rows"], [[
            "id": "00000000-0000-4000-8000-000000000008", "kind": "arrow", "board": "root",
            "properties": ["bend": 0, "channel": "note-link", "endArrowhead": true, "labelPosition": 0.5, "startArrowhead": false, "text": ""],
            "connection": ["type": "note-link", "from": ["id": "00000000-0000-4000-8000-000000000002", "title": "API gateway"],
                           "to": ["id": "00000000-0000-4000-8000-000000000003", "title": "Auth"]],
        ]])

        // A query in a heredoc, as the skill passes one: several lines, and comments, which the
        // query as it ran leaves out.
        let heredoc = try query("/* every note, */\nsticky-note,\n  /* and what's in Payments */\n  \"Payments\" *\n", on: board, server, ["--brief"])
        expectEqual(heredoc.status, 0, heredoc.error)
        expectEqual(try JSON(text: heredoc.output)["query"], #"sticky-note, "Payments" *"#)
        expectEqual(try rowIDs(heredoc.output), storyIDs("C, F, Y, N2, A, U, N1, W, S, V, L, T1, T2, I"))
    },
    test("canvas query gives a row of :incomplete its problems, field by field, and leaves the member off a count and off a row with none") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureQueryBoards(pasteboard: pasteboard, model: ScriptedLanguageModel())
        let board = try QueryStory.document(windowed: false)
        defer { board.close() }
        let server = try startQueryServer(for: board)
        defer { server.stop() }

        // Ann is an Employee card, a Person, and has no name: the one thing she needs.
        let incomplete = try query(":incomplete", on: board, server, ["--brief"])
        expectEqual(incomplete.status, 0, incomplete.error)
        let rows = try require(try JSON(text: incomplete.output)["rows"]?.arrayValue)
        expectEqual(rows.count, 1)
        expectEqual(rows.first?["title"], "Ann")
        expectEqual(rows.first?["problems"], [["field": "name", "path": "/name", "class": "needed", "message": "name is needed"]])
        let counted = try query(":incomplete", on: board, server, ["--count"])
        expectEqual(try JSON(text: counted.output)["count"], 1)
        expectEqual(try JSON(text: counted.output)["rows"], nil)
        let complete = try query(#":is-a("Person"):not(:incomplete)"#, on: board, server, ["--brief"])
        expect(try JSON(text: complete.output)["rows"]?.arrayValue?.allSatisfy { $0["problems"] == nil } == true, "no member on a row with none")
        let invalid = try query(":invalid", on: board, server, ["--brief"])
        expectEqual(try rowIDs(invalid.output), storyIDs("V"))
        expectEqual(try JSON(text: invalid.output)["rows"]?.arrayValue?.first?["problems"]?.arrayValue?.count, 1, "the schema's own error")
    },
    test("canvas query warns unknown_field for a path no type has, and answers the lists and dates of the story's values") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureQueryBoards(pasteboard: pasteboard, model: ScriptedLanguageModel())
        let board = try QueryStory.document(windowed: false)
        defer { board.close() }
        let server = try startQueryServer(for: board)
        defer { server.stop() }

        let list = try query(#"[fieldValues.teams.name="search"]"#, on: board, server, ["--brief"])
        expectEqual(try rowIDs(list.output), storyIDs("I"))
        expectEqual(try JSON(text: list.output)["warnings"], nil, "the field is one a type has")
        let date = try query(#"[fieldValues.started<"2025-01-01"]"#, on: board, server, ["--brief"])
        expectEqual(try rowIDs(date.output), storyIDs("I"))
        let typo = try query(#"[fieldValues.strted<"2025-01-01"]"#, on: board, server, ["--brief"])
        expectEqual(typo.status, 0, typo.error)
        expectEqual(try rowIDs(typo.output), [], "nothing holds it")
        expectEqual(try JSON(text: typo.output)["warnings"],
                    [["reason": "unknown_field", "message": "No type in the file has fieldValues.strted. Did you mean fieldValues.started?"]])
        let refused = try query(#"[fieldValues.started<"Oct 1"]"#, on: board, server)
        expectEqual(refused.status, 1)
        expect((refused.output + refused.error).contains("isn't a number or a date"), refused.output + refused.error)
    },
    test("canvas query answers as text for a person: the rows as a table, id, kind and title first, each one's attributes under it") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureQueryBoards(pasteboard: pasteboard, model: ScriptedLanguageModel())
        let board = try QueryStory.document(windowed: false)
        defer { board.close() }
        let server = try startQueryServer(for: board)
        defer { server.stop() }

        let text = try query(#"sticky-note:mentions("API gateway")"#, on: board, server, ["--format", "text"])
        expectEqual(text.status, 0, text.error)
        let lines = text.output.components(separatedBy: "\n")
        expect(lines.contains("count: 1"), text.output)
        expect(lines.contains(#"query: sticky-note:mentions("API gateway")"#), text.output)
        let rows = try require(lines.firstIndex(of: "rows:"), text.output)
        expectEqual(Array(lines[rows...].prefix(5)), [
            "rows:",
            "  id                                    kind         title     at                    board                                 inside",
            "  00000000-0000-4000-8000-000000000011  sticky-note  Checkout  [80, 80], [260, 200]  00000000-0000-4000-8000-000000000001  Payments",
            "    properties:",
            "      text: Calls @API gateway for tokens",
        ])
    },
    test("--count counts, --limit lists so many and says how many more, --brief leaves attributes out, --fields names them, whole") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureQueryBoards(pasteboard: pasteboard, model: ScriptedLanguageModel())
        let board = try QueryStory.document(windowed: false)
        defer { board.close() }
        let server = try startQueryServer(for: board)
        defer { server.stop() }

        let counted = try JSON(text: query("sticky-note", on: board, server, ["--count"]).output)
        expectEqual(counted["count"], 13)
        expectEqual(counted["rows"], nil)
        expectEqual(counted["query"], "sticky-note")

        let limited = try query("sticky-note", on: board, server, ["--limit", "2", "--brief"])
        let two = try JSON(text: limited.output)
        expectEqual(two["count"], 13, "count is of them all")
        expectEqual(try rowIDs(limited.output), storyIDs("C, Y"))
        expectEqual(two["rows"]?.arrayValue?.compactMap { $0["properties"] }, [], "--brief lists no attributes")
        expectEqual(two["warnings"]?.arrayValue?.map { $0["reason"] }, ["limited"])
        expect(two["warnings"]?.arrayValue?.first?["message"]?.stringValue?.hasPrefix("2 of 13 listed.") == true, limited.output)

        let fields = try JSON(text: query(#""Refund policy""#, on: board, server, ["--fields", "locked"]).output)
        expectEqual(fields["rows"]?.arrayValue?.first?["properties"], ["locked": true])

        // Text past 500 characters is cut, and the row says so, unless --fields names it.
        let long = String(repeating: "Long enough to cut. ", count: 30)
        let drew = try canvas(server, ["draw", "-", "--board", "\(board.number)"], input: #"sticky-note "Long" text: "\#(long)""#)
        expectEqual(drew.status, 0, drew.error)
        let cut = try JSON(text: query(#""Long""#, on: board, server).output)["rows"]?.arrayValue?.first
        expectEqual(cut?["properties"]?["text"]?.stringValue, String(long.prefix(QueryBudget.cut)) + "…")
        expectEqual(cut?["cut"], ["text"])
        let whole = try JSON(text: query(#""Long""#, on: board, server, ["--fields", "text"]).output)["rows"]?.arrayValue?.first
        expectEqual(whole?["properties"]?["text"]?.stringValue, long)
        expectEqual(whole?["cut"], nil)

        // What the options can't say together, or without a query.
        let both = try query("sticky-note", on: board, server, ["--brief", "--fields", "text"])
        expectEqual(both.status, 1)
        expectEqual(try JSON(text: both.error)["error"]?["reason"], "invalid_params")
        let nothing = try canvas(server, ["query", "--board", "\(board.number)"])
        expectEqual(nothing.status, 1)
        expectEqual(try JSON(text: nothing.error)["error"]?["message"], #"Say what to find: a query, or --ask "…"."#)
        let none = try query("sticky-note", on: board, server, ["--limit", "0"])
        expectEqual(try JSON(text: none.error)["error"]?["reason"], "invalid_params")
    },
    test("a refusal says its reason, where in the query it is and what to write: as JSON, and as text with a caret under what's wrong") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureQueryBoards(pasteboard: pasteboard, model: ScriptedLanguageModel())
        let board = try QueryStory.document(windowed: false)
        defer { board.close() }
        let server = try startQueryServer(for: board)
        defer { server.stop() }

        let refused = try query(#"sticky-note:mention("API gateway")"#, on: board, server)
        expectEqual(refused.status, 1)
        expectEqual(refused.output, "")
        expectEqual(try JSON(text: refused.error), ["error": [
            "reason": "unknown_pseudo_class", "message": ":mention isn't a pseudo-class.",
            "hint": "Did you mean :mentions? :mentions(S): its text mentions a shape S matches.",
            "status": 1, "line": 1, "column": 12, "length": 8, "statement": #"sticky-note:mention("API gateway")"#,
        ]])
        let text = try query(#"sticky-note:mention("API gateway")"#, on: board, server, ["--format", "text"])
        expectEqual(text.status, 1)
        expectEqual(text.error, """
            canvas: line 1, column 12: :mention isn't a pseudo-class.
              sticky-note:mention("API gateway")
                         ^^^^^^^^
            hint: Did you mean :mentions? :mentions(S): its text mentions a shape S matches.

            """)

        // On the line it's on, in a query of several; a title no shape has is refused, with the
        // one like it, and, since a mention on the board points at a shape that's gone, how to
        // find what holds such mentions.
        let second = try query("/* notes that mention the gateway */\nsticky-note:mentions(\"API gatewey\")", on: board, server, ["--format", "text"])
        expectEqual(second.status, 1)
        expectEqual(second.error, """
            canvas: line 2, column 22: No shape is titled API gatewey.
              sticky-note:mentions("API gatewey")
                                   ^^^^^^^^^^^^^
            hint: Did you mean "API gateway"? Some mention edges point at shapes that aren't there: :dangling(mention) finds what carries them.

            """)

        // Every problem that doesn't hang on another comes back at once, each where it is.
        let several = try JSON(text: query(#"note, sticky-note[txt*="x"]"#, on: board, server).error)["error"]
        expectEqual(several?["reason"], "unknown_kind")
        expectEqual(several?["errors"]?.arrayValue?.map { $0["reason"] }, ["unknown_kind", "unknown_attribute"])
        expectEqual(several?["errors"]?.arrayValue?.map { $0["column"] }, [1, 18])
    },
    test("canvas query exits 0 whatever the count, 1 when the app refuses the query, 2 when the command line is wrong, 3 when there's no app") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureQueryBoards(pasteboard: pasteboard, model: ScriptedLanguageModel())
        let board = try QueryStory.document(windowed: false)
        defer { board.close() }
        let server = try startQueryServer(for: board)
        defer { server.stop() }

        let no = try query(#""Checkout":inside("Refunds")"#, on: board, server)
        expectEqual(no.status, 0, "a no is an answer")
        expectEqual(try JSON(text: no.output)["count"], 0)
        let yes = try query(#""Refund policy":inside("Payments")"#, on: board, server)
        expectEqual(try JSON(text: yes.output)["count"], 1)
        let refused = try query("note", on: board, server)
        expectEqual(refused.status, 1)
        expectEqual(try JSON(text: refused.error)["error"]?["reason"], "unknown_kind")
        let option = try canvas(server, ["query", "sticky-note", "--bogus", "--board", "\(board.number)"])
        expectEqual(option.status, 2)
        expectEqual(try JSON(text: option.error)["error"]?["reason"], "usage")
        let number = try canvas(server, ["query", "sticky-note", "--limit", "many", "--board", "\(board.number)"])
        expectEqual(number.status, 2)
        let unreachable = try run(builtExecutable("CanvasCLI"), ["--socket", temporarySocketPath(), "query", "*"])
        expectEqual(unreachable.status, 3)
        expectEqual(try JSON(text: unreachable.error)["error"]?["reason"], "not_running")
    },
    test("a query reads every board of the file; :current-board, and the result's board, are the one the window shows, before and after a switch") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureQueryBoards(pasteboard: pasteboard, model: ScriptedLanguageModel())
        let board = try QueryStory.document(windowed: false)
        defer { board.close() }
        let server = try startQueryServer(for: board)
        defer { server.stop() }

        let all = try JSON(text: query("*", on: board, server, ["--brief"]).output)
        expectEqual(all["rows"]?.arrayValue?.compactMap { $0["id"]?.stringValue }, QueryStory.fileOrder.map(\.description))
        expectEqual(all["rows"]?.arrayValue?.map { $0["board"] ?? .null }, [
            "root", "00000000-0000-4000-8000-000000000001", "00000000-0000-4000-8000-000000000001", "00000000-0000-4000-8000-000000000012",
            "00000000-0000-4000-8000-000000000001", "root", "root", "root", "root", "root", "root", "root", "root", "root",
            "root", "root", "root",
        ])

        /// What `:current-board` lists, and the board the result says it ran on.
        @MainActor func current() throws -> (ids: [String], board: JSON?) {
            let answered = try query(":current-board", on: board, server, ["--brief"])
            expectEqual(answered.status, 0, answered.error)
            return (try rowIDs(answered.output), try JSON(text: answered.output)["board"])
        }
        let top = try current()
        expectEqual(top.ids, storyIDs("P, A, U, N1, W, S, V, R1, R2, L, T1, T2, I"))
        expectEqual(top.board?["shows"], "root")

        expect(board.editor.showBoard(BoardID(owner: QueryStory.payments)))
        let payments = try current()
        expectEqual(payments.ids, storyIDs("C, F, N2"))
        expectEqual(payments.board?["shows"], "00000000-0000-4000-8000-000000000001")
        expectEqual(payments.board?["showsPath"], ["root", "00000000-0000-4000-8000-000000000001"])
        expectEqual(try rowIDs(query("*", on: board, server, ["--brief"]).output), QueryStory.fileOrder.map(\.description),
                    "every board, wherever the window is")

        expect(board.editor.showBoard(BoardID(owner: QueryStory.refunds)))
        expectEqual(try current().ids, storyIDs("Y"))
        expect(board.editor.showBoard(.root))
        expectEqual(try current().ids, top.ids)
        expect(!board.isDocumentEdited, "going into a board isn't an edit")
    },
    test("a query changes nothing: the file as it was, not edited, no step to undo, the selection and the board shown kept") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureQueryBoards(pasteboard: pasteboard, model: ScriptedLanguageModel())
        let board = try QueryStory.document(windowed: false)
        defer { board.close() }
        let server = try startQueryServer(for: board)
        defer { server.stop() }
        let before = board.editor.file
        expect(!board.isDocumentEdited)
        expect(!board.editor.undoHistory.canUndo)

        // Every sort of word: names (derived ones too), attributes and mention text, containment,
        // edges, the selection, and validity on boards that aren't shown.
        for text in ["*", #""Order""#, #"sticky-note[text*="@API gateway"]"#, #""Payments" *"#, #":downstream-of("Checkout")"#,
                     ":selected", ":invalid", ":warned", ":dangling", #":contains("retry")"#] {
            let answered = try query(text, on: board, server)
            expectEqual(answered.status, 0, "\(text): \(answered.error)")
        }
        _ = try query("note", on: board, server)
        _ = try canvas(server, ["query", "*", "--count", "--board", "\(board.number)"])

        expectEqual(board.editor.file, before)
        expect(!board.isDocumentEdited)
        expect(!board.editor.undoHistory.canUndo, "no step: \(board.editor.undoHistory.undoName ?? "unnamed")")
        expectEqual(board.editor.selectedShapeIDs, [QueryStory.auth])
        expectEqual(board.editor.board, .root)
        expectEqual(board.editor.queries?.liveSnapshots, 0, "no query holds the file once it's answered")
    },
    test("--ask has the model write the query, runs it, and says what was asked and what it wrote; a refused query is sent back once") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let model = ScriptedLanguageModel(answers: [#"sticky-note:mentions("API gateway")"#])
        try configureQueryBoards(pasteboard: pasteboard, model: model)
        let board = try QueryStory.document(windowed: false)
        defer { board.close() }
        let server = try startQueryServer(for: board)
        defer { server.stop() }

        let asked = try canvas(server, ["query", "--ask", "Which notes mention the gateway?", "--board", "\(board.number)"])
        expectEqual(asked.status, 0, asked.error)
        let answer = try JSON(text: asked.output)
        expectEqual(answer["asked"], "Which notes mention the gateway?")
        expectEqual(answer["query"], #"sticky-note:mentions("API gateway")"#)
        expectEqual(try rowIDs(asked.output), storyIDs("C"))
        expectEqual(answer["board"]?["shows"], "root")
        let request = try require(model.lastRequest?.messages.first?.text)
        expect(request.contains("<question>\nWhich notes mention the gateway?\n</question>"), request)
        expect(request.contains(#""API gateway" sticky-note"#), "the titles: \(request)")
        expect(!request.contains("Calls @API gateway"), "no shape's text leaves the machine")

        model.queue("note")
        model.queue("sticky-note")
        let repaired = try canvas(server, ["query", "--ask", "Every note", "--count", "--board", "\(board.number)"])
        expectEqual(repaired.status, 0, repaired.error)
        let second = try JSON(text: repaired.output)
        expectEqual(second["count"], 13)
        expectEqual(second["warnings"]?.arrayValue?.map { $0["reason"] }, ["repaired"])
        let error = try require(model.lastRequest?.messages.last?.text)
        expect(error.contains("refused: unknown_kind"), error)
        expect(!board.isDocumentEdited)
    },
    test("a draw is answered while an --ask waits on the model: the question was asked about the file before it, and the query it wrote answers the file after") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let model = ScriptedLanguageModel()
        model.holdsAnswers = true
        try configureQueryBoards(pasteboard: pasteboard, model: model)
        let board = try QueryStory.document(windowed: false)
        defer { board.close() }
        let server = try startQueryServer(for: board)
        defer { server.stop() }

        let ask = try RunningCanvas(server, ["query", "--ask", "Which notes are about notes?", "--board", "\(board.number)"])
        spinRunLoop(until: { model.waiting == 1 }, timeout: 10)
        let drew = try canvas(server, ["draw", "-", "--board", "\(board.number)"], input: #"sticky-note "Gateway notes" text: "What the gateway logs""#)
        expectEqual(drew.status, 0, drew.error)
        expectEqual(try JSON(text: drew.output)["changes"]?.arrayValue?.first?["did"], "created")
        expect(ask.isRunning, "the draw was answered first, while the model still had the question")
        let titles = try require(model.lastRequest?.messages.first?.text)
        expect(titles.contains(#""API gateway" sticky-note"#) && !titles.contains("Gateway notes"), "asked about the file before the draw: \(titles)")

        model.queue(#"sticky-note[title$="notes"]"#)
        model.release()
        let answered = try ask.finish()
        expectEqual(answered.status, 0, answered.error)
        let drawn = try require(board.editor.document.shapes.first { $0[TitleProperty.self] == "Gateway notes" })
        expectEqual(try rowIDs(answered.output), [drawn.id.description], "its query ran once it was written, on the file with the draw")
    },
    test("--ask's result names the board its query ran on: a switch while the model thinks is the board :current-board and the result are") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let model = ScriptedLanguageModel()
        model.holdsAnswers = true
        try configureQueryBoards(pasteboard: pasteboard, model: model)
        let board = try QueryStory.document(windowed: false)
        defer { board.close() }
        let server = try startQueryServer(for: board)
        defer { server.stop() }

        let ask = try RunningCanvas(server, ["query", "--ask", "What's on this board?", "--brief", "--board", "\(board.number)"])
        spinRunLoop(until: { model.waiting == 1 }, timeout: 10)
        expect(board.editor.showBoard(BoardID(owner: QueryStory.payments)))
        model.queue(":current-board")
        model.release()
        let answered = try ask.finish()
        expectEqual(answered.status, 0, answered.error)
        let payments = JSON.string(QueryStory.payments.description)
        expectEqual(try rowIDs(answered.output), storyIDs("C, F, N2"), "the query ran on the board shown as it ran")
        let result = try JSON(text: answered.output)
        expectEqual(result["board"]?["shows"], payments, "and the result says so")
        expectEqual(result["board"]?["showsPath"], ["root", payments])
        expectEqual(result["board"]?["id"], .number(Double(board.number)))
        expectEqual(result["board"]?["name"], .string(try require(board.displayName)))
    },
    test("canvas --timeout 0.5 gives up on an --ask the model holds, and the app lets go of the call; queries go on after it") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let model = ScriptedLanguageModel(answers: ["sticky-note"])
        model.holdsAnswers = true
        try configureQueryBoards(pasteboard: pasteboard, model: model)
        let board = try QueryStory.document(windowed: false)
        defer { board.close() }
        let server = try startQueryServer(for: board)
        defer { server.stop() }

        let gaveUp = try canvas(server, ["--timeout", "0.5", "query", "--ask", "Every note", "--board", "\(board.number)"])
        expectEqual(gaveUp.status, 3)
        expectEqual(try JSON(text: gaveUp.error)["error"]?["reason"], "timed_out")
        spinRunLoop(until: { model.waiting == 0 && model.answered == 1 }, timeout: 5)
        expectEqual(model.answered, 1, "the call was cancelled")
        expectEqual(model.queued.count, 1, "and took no answer")
        expectEqual(board.editor.queries?.liveSnapshots, 0)

        let after = try query("sticky-note", on: board, server, ["--count"])
        expectEqual(after.status, 0, after.error)
        expectEqual(try JSON(text: after.output)["count"], 13)
    },
    test("the file closed while an --ask waits on the model is answered board_closed at once, and its editor goes once the call stops") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let model = ScriptedLanguageModel()
        model.holdsAnswers = true
        try configureQueryBoards(pasteboard: pasteboard, model: model)
        weak var editor: CanvasEditor?
        var server: CommandServer?
        defer { server?.stop() }
        let ask: RunningCanvas = try autoreleasepool {
            let board = try QueryStory.document(windowed: false)
            editor = board.editor
            server = try startQueryServer(for: board)
            let ask = try RunningCanvas(try require(server), ["query", "--ask", "Every note", "--board", "\(board.number)"])
            spinRunLoop(until: { model.waiting == 1 }, timeout: 10)
            board.close()
            return ask
        }
        // The model never answers: closing the file is what ends the command.
        let answered = try ask.finish(timeout: 5)
        expectEqual(answered.status, 1)
        let error = try JSON(text: answered.error)["error"]
        expectEqual(error?["reason"], "board_closed")
        expectEqual(error?["message"], "The board was closed before the command finished.")
        spinRunLoop(until: { model.waiting == 0 }, timeout: 5)
        spinRunLoop(until: { editor == nil }, timeout: 5)
        expect(editor == nil, "nothing keeps the closed file's editor")
    },
    test("canvas query-vocabulary says what the app's queries can name, for the app, with no board; help says how to pass a query") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureQueryBoards(pasteboard: pasteboard, model: ScriptedLanguageModel())
        let registry = try require(BoardDocument.configuration).registry
        let server = try startQueryServer(for: nil)
        defer { server.stop() }

        let said = try canvas(server, ["query-vocabulary"])
        expectEqual(said.status, 0, said.error)
        let vocabulary = try JSON(text: said.output)
        expectEqual(vocabulary["vocabulary"]?.stringValue, QueryVocabulary(registry: registry).text, "the block --ask sends")
        let note = try require(vocabulary["kinds"]?.arrayValue?.first { $0["kind"] == "sticky-note" })
        expectEqual(note["label"], "Note")
        expectEqual(note["naming"], "named")
        expectEqual(note["holdsShapes"], false)
        expectEqual(note["holdsBoard"], false)
        expectEqual(note["attributes"]?["text"], "text (mentions read as @Name)")
        expect(vocabulary["kinds"]?.arrayValue?.contains { $0["naming"] == "derived" } == false, "no shipped kind's titles are worked out")
        expectEqual(note["attributes"]?["schema"], "text")
        expectEqual(vocabulary["kinds"]?.arrayValue?.first { $0["kind"] == "subboard" }?["holdsShapes"], true)
        expectEqual(vocabulary["kinds"]?.arrayValue?.first { $0["kind"] == "subboard" }?["holdsBoard"], true)
        expectEqual(vocabulary["edgeTypes"]?.arrayValue?.map { $0["type"] }, ["stands-for", "mention", "is-a", "arrow", "note-link", "subboard-link", "frame-link", "foreign-key", "calls", "writes", "reads"])
        expectEqual(vocabulary["edgeTypes"]?.arrayValue?.map { $0["under"] ?? .null }, [.null, .null, .null, .null, "arrow", "arrow", "arrow", "arrow", "arrow", "arrow", "arrow"])
        let words = vocabulary["words"]?.arrayValue ?? []
        expectEqual(words.filter { $0["from"] != "queries" }.map { $0["word"] }, ["mentions", "mentioned-by", "invalid", "warned", "incomplete", "is-a", "misfit", "grouped-with", "selected", "drawn-by", "changed"])
        expectEqual(words.first { $0["word"] == "mentions" }?["takes"], "shapes")
        expectEqual(words.first { $0["word"] == "drawn-by" }?["takes"], "name")

        let onBoard = try canvas(server, ["query-vocabulary", "--board", "1"])
        expectEqual(onBoard.status, 2, "it's about the app, not a board")

        let help = try canvas(server, ["help", "query"])
        expectEqual(help.status, 0)
        expect(help.output.contains("--ask <question>|-"), help.output)
        expect(help.output.contains("(waits up to 60 s)"), help.output)
        expect(help.output.contains("reference/query.md"), help.output)
    },
])

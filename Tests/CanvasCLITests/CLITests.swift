import CanvasRPC
import Foundation
import TestKit

// The command line as it's built, run as an agent runs it, against an app of the test's own: one
// that describes a few commands and answers each with what it was sent.

/// An app for `canvas` to talk to. Its commands: `echo` (its params back), `recite` (its script
/// back, which standard input may give), `touch` (a board's: the board it's given back), `fail`
/// (an error; with `--lines`, one about a script, as `draw`'s are, and with `--at`, one about where
/// on a line, as a query's are), `rows` (a list), `drew` (what a draw says), `sorts` (a list whose
/// rows have objects and sentences, as `kinds`'s do), `found` (shapes, as a query finds them), `file`
/// (a file, as `new` takes one, back), and `slow` (an answer a second late, the main actor free
/// meanwhile; `--briefly` says to wait for it 0.3 s, and `--patiently` 3).
@MainActor
final class FakeApp {
    let path = temporarySocketPath()
    private(set) var methods: [String] = []
    private var listener: RPCListener?
    var protocolVersion = RPC.protocolVersion

    static let point: JSON = ["description": "[x, y]", "type": "array", "prefixItems": [["type": "number"], ["type": "number"]], "items": false, "minItems": 2]

    var description: AppDescription {
        AppDescription(protocolVersion: protocolVersion, app: AppInfo(name: "Fake", version: "1", pid: 1), commands: [
            CommandSpec(name: "echo", summary: "Say it back.", scope: .app, params: [
                "type": "object",
                "properties": [
                    "text": ["type": "string", "description": "What to say."],
                    "count": ["type": "integer"],
                    "loud": ["type": "boolean"],
                    "at": ["$ref": "#/$defs/core.point"],
                    "tags": ["type": "array", "items": ["type": "string"]],
                ],
                "required": ["text"],
                "$defs": ["core.point": FakeApp.point],
            ], positionals: ["text"], examples: [CommandExample("canvas echo hi", "Says hi.")]),
            CommandSpec(name: "recite", summary: "Say a script back.", scope: .app, params: [
                "type": "object",
                "properties": ["script": ["type": "string", "x-stdin": true, "description": "The script."]],
                "required": ["script"],
            ], positionals: ["script"]),
            CommandSpec(name: "touch", summary: "Touch a board.", scope: .board),
            CommandSpec(name: "peek", summary: "Look at a board, if one is there.", scope: .board, boardOptional: true),
            CommandSpec(name: "fail", summary: "Fail.", scope: .app, params: ["type": "object", "properties": ["lines": ["type": "boolean"],
                                                                                                          "at": ["type": "boolean"],
                                                                                                          "wide": ["type": "boolean"]]]),
            CommandSpec(name: "rows", summary: "Some rows.", scope: .app),
            CommandSpec(name: "drew", summary: "Say what was drawn.", scope: .app),
            CommandSpec(name: "sorts", summary: "Some sorts of shape.", scope: .app),
            CommandSpec(name: "found", summary: "Say what was found.", scope: .app),
            CommandSpec(name: "file", summary: "Name a file.", scope: .app, params: [
                "type": "object", "properties": ["path": ["type": "string", "x-path": true]], "required": ["path"],
            ], positionals: ["path"]),
            CommandSpec(name: "slow", summary: "Answer late.", scope: .app, params: [
                "type": "object",
                "properties": [
                    "briefly": ["type": "boolean", "description": "Wait only a moment.", "x-timeout": 0.3],
                    "patiently": ["type": "boolean", "description": "Wait a while.", "x-timeout": 3],
                ],
            ]),
        ])
    }

    /// A warning as long as a draw's, whose end is what to do about it.
    static let pushed = #""Ship" was pushed right past "DB" to keep clear of it, so it no longer sits against "API" — place it on another side, or say overlap: allow"#
    static let outside = "1 shape landed outside the view — --reveal brings them into view"
    /// Why a kind can't be drawn, as long as `kinds` says it.
    static let undrawable = "its tool (Squiggle) draws one by hand, so a script can't place one"

    /// What `draw` says, as the app sends it.
    static let drawn: JSON = [
        "board": ["id": 2, "name": "Plans"],
        "changes": [["line": 1, "did": "created", "kind": "box", "title": "Ship", "at": [[400, 300], [200, 200]], "inView": true, "pushedPast": ["DB"]],
                    ["line": 2, "did": "connected", "kind": "connector", "from": "Ship", "to": "API"]],
        "warnings": [["line": 1, "message": .string(pushed), "severity": "warning"],
                     ["message": .string(outside), "severity": "warning"]],
    ]

    /// What `fail --lines` fails with: an error about a script's second line, and one about its
    /// fourth, with members of its own named like those `canvas` says itself, which it keeps.
    static let scriptError = RPCError(RPCError.failed, reason: "unknown_title", #""Web" isn't on the board."#, hint: #"Did you mean "web"?"#, details: [
        "line": 2, "statement": #"box "API" right of "Web""#, "message": "not this", "status": 7,
        "errors": [
            ["line": 2, "statement": #"box "API" right of "Web""#, "reason": "unknown_title", "message": #""Web" isn't on the board."#,
             "hint": #"Did you mean "web"?"#],
            ["line": 4, "statement": "box left of", "reason": "syntax", "message": "left of what? A placement needs a shape to go against."],
        ],
    ])

    /// What `fail --at` fails with: an error about where on a line, what a query's are.
    static let wordError = RPCError(RPCError.failed, reason: "unknown_word", ":mention isn't a pseudo-class.", hint: "Did you mean :mentions?", details: [
        "line": 1, "column": 12, "length": 8, "statement": #"sticky-note:mention("API gateway")"#,
        "errors": [
            ["line": 1, "column": 12, "length": 8, "statement": #"sticky-note:mention("API gateway")"#, "reason": "unknown_word",
             "message": ":mention isn't a pseudo-class."],
            ["line": 1, "column": 21, "length": 1, "statement": #"sticky-note:mention("API gateway")"#, "reason": "unknown_title",
             "message": "\"API gateway\" isn't in the file."],
        ],
    ])

    /// What `fail --wide` fails with: an error about where on a line whose characters before it,
    /// and in it, take two cells in a terminal (an emoji, Japanese).
    static let wideError = RPCError(RPCError.failed, reason: "unknown_title", #""発射" isn't in the file."#, details: [
        "line": 1, "column": 16, "length": 4, "statement": #""🚀 発射":mention("発射")"#,
    ])

    /// What `found` says: a shape, as a query's rows have it.
    static let found: JSON = [
        "count": 1,
        "rows": [["id": "A1", "kind": "note", "title": "Checkout", "board": "root", "inside": ["Payments"], "properties": ["text": "Calls the gateway"]]],
    ]

    init() throws {
        let listener = RPCListener(path: path) { [unowned self] request in await answer(request) }
        try listener.start()
        self.listener = listener
    }

    func stop() { listener?.stop() }

    private func answer(_ request: RPCRequest) async -> Result<JSON, RPCError> {
        methods.append(request.method)
        switch request.method {
        case RPC.describeMethod: return .success(try! JSON(encoding: description))
        case "echo", "recite", "file": return .success(request.params ?? [:])
        case "touch": return .success(["board": request.params?["board"] ?? .null])
        case "fail" where request.params?["lines"] == true: return .failure(FakeApp.scriptError)
        case "fail" where request.params?["at"] == true: return .failure(FakeApp.wordError)
        case "fail" where request.params?["wide"] == true: return .failure(FakeApp.wideError)
        case "fail": return .failure(.failed("It didn't work.", reason: "no_luck", hint: "Try luck."))
        case "rows": return .success([["id": 2, "name": "Plans", "shapes": 12], ["id": 10, "name": "Untitled", "edited": true]])
        case "drew": return .success(FakeApp.drawn)
        case "sorts": return .success([["kind": "box", "drawable": true, "attributes": ["color": "text"], "edges": ["left": ["wire"]]],
                                       ["kind": "squiggle", "drawable": false, "why": .string(FakeApp.undrawable)]])
        case "found": return .success(FakeApp.found)
        case "slow":
            try? await Task.sleep(for: .seconds(1))
            return .success([:])
        default: return .failure(RPCError(code: RPCError.methodNotFound, message: "no \(request.method)"))
        }
    }
}

/// `canvas`, as build.sh built it beside this test.
@MainActor func canvas(_ arguments: [String], environment: [String: String] = [:]) throws -> ProcessOutput {
    try run(builtExecutable("CanvasCLI"), arguments, environment: environment)
}

@MainActor let cliTests = Suite("canvas", [
    test("it asks the app what it runs, reads a command's arguments as its params, and prints the result as JSON when piped") {
        let app = try FakeApp()
        defer { app.stop() }
        let result = try canvas(["--socket", app.path, "echo", "hello", "--count", "2", "--loud", "--at", "1,-2", "--tags", "a", "--tags", "b"])
        expectEqual(result.status, 0, result.error)
        expectEqual(try JSON(text: result.output), ["text": "hello", "count": 2, "loud": true, "at": [1, -2], "tags": ["a", "b"]])
        expectEqual(app.methods, [RPC.describeMethod, "echo"])
    },
    test("CANVAS_SOCKET says where the app is, and its own options may come anywhere") {
        let app = try FakeApp()
        defer { app.stop() }
        let result = try canvas(["echo", "hi", "--format", "json"], environment: [SocketPath.environmentKey: app.path])
        expectEqual(result.status, 0, result.error)
        expectEqual(try JSON(text: result.output), ["text": "hi"])
    },
    test("as text: an object's members as lines, a list of objects as a table") {
        let app = try FakeApp()
        defer { app.stop() }
        let object = try canvas(["--socket", app.path, "--format", "text", "echo", "hi", "--count", "3", "--at", "1.5,2"])
        expectEqual(object.status, 0, object.error)
        expectEqual(object.output, "at:    1.5, 2\ncount: 3\ntext:  hi\n")
        let table = try canvas(["--socket", app.path, "--format", "text", "rows"])
        expectEqual(table.output, "id  name      edited  shapes\n2   Plans             12\n10  Untitled  yes\n")
    },
    test("as text, a draw's rows lead with their line and what they did, and its warnings are whole, what to do and all") {
        let app = try FakeApp()
        defer { app.stop() }
        let text = try canvas(["--socket", app.path, "--format", "text", "drew"])
        expectEqual(text.status, 0, text.error)
        let lines = text.output.components(separatedBy: "\n")
        let header = try require(lines.first { $0.hasPrefix("  line") })
        expectEqual(header.split(separator: " ").prefix(4).joined(separator: " "), "line did kind title", "then the rest by name")
        expect(lines.contains("  line  severity  message"), text.output)
        expect(lines.contains("  1     warning   \(FakeApp.pushed)"), text.output)
        expect(lines.contains("        warning   \(FakeApp.outside)"), text.output)
    },
    test("as text, what a table's rows have that isn't a value goes under each row, indented, and a kind's why is whole") {
        let app = try FakeApp()
        defer { app.stop() }
        let text = try canvas(["--socket", app.path, "--format", "text", "sorts"])
        expect(FakeApp.undrawable.count > 60, "longer than a cell")
        expectEqual(text.output, "kind      drawable  why\nbox       yes\n  attributes:\n    color: text\n  edges:\n    left: wire\n"
            + "squiggle  no        \(FakeApp.undrawable)\n")
    },
    test("as text, a shape a query found leads with its id, kind and title, and its properties go under it") {
        let app = try FakeApp()
        defer { app.stop() }
        let text = try canvas(["--socket", app.path, "--format", "text", "found"])
        expectEqual(text.status, 0, text.error)
        expectEqual(text.output, """
            count: 1
            rows:
              id  kind  title     board  inside
              A1  note  Checkout  root   Payments
                properties:
                  text: Calls the gateway

            """)
    },
    test("an answer that doesn't come in time is exit 3, timed_out, and says the app may still do it") {
        let app = try FakeApp()
        defer { app.stop() }
        let late = try canvas(["--socket", app.path, "--timeout", "0.3", "slow"])
        expectEqual(late.status, 3)
        let error = try JSON(text: late.error)["error"]
        expectEqual(error?["reason"], "timed_out")
        expectEqual(error?["hint"], "The app may still do it: check before running it again. --timeout waits longer.")
    },
    test("a param that says its answer takes a while (x-timeout) is waited for that long when it's given, the longest of those given; --timeout still wins") {
        let app = try FakeApp()
        defer { app.stop() }
        let brief = try canvas(["--socket", app.path, "slow", "--briefly"])
        expectEqual(brief.status, 3, "waited 0.3 s, not the usual 10")
        expectEqual(try JSON(text: brief.error)["error"]?["reason"], "timed_out")
        let patient = try canvas(["--socket", app.path, "slow", "--briefly", "--patiently"])
        expectEqual(patient.status, 0, patient.error)
        let told = try canvas(["--socket", app.path, "--timeout", "5", "slow", "--briefly"])
        expectEqual(told.status, 0, told.error)
        let help = try canvas(["--socket", app.path, "help", "slow"])
        expect(help.output.contains("Wait a while. (waits up to 3 s)"), help.output)
    },
    test("a board command's --board, when it's a file, is sent as the whole path") {
        let app = try FakeApp()
        defer { app.stop() }
        let result = try canvas(["--socket", app.path, "touch", "--board", "plans/b.canvasboard"])
        expectEqual(result.status, 0, result.error)
        let expected = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("plans/b.canvasboard").standardizedFileURL.path
        expectEqual(try JSON(text: result.output), ["board": .string(expected)])
        let byID = try canvas(["--socket", app.path, "touch", "--board", "2"])
        expectEqual(try JSON(text: byID.output), ["board": "2"])
        let first = try canvas(["--socket", app.path, "--board", "2", "touch"])
        expectEqual(first.status, 0, first.error)
        expectEqual(try JSON(text: first.output), ["board": "2"], "the command's options may come before its name")
    },
    test("a param that's a file (x-path) is sent as the whole path, named from where canvas runs; other text is sent as typed") {
        let app = try FakeApp()
        defer { app.stop() }
        let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let relative = try canvas(["--socket", app.path, "file", "plans/../b.canvasboard"])
        expectEqual(relative.status, 0, relative.error)
        expectEqual(try JSON(text: relative.output), ["path": .string(here.appendingPathComponent("b.canvasboard").standardizedFileURL.path)])
        let home = try canvas(["--socket", app.path, "file", "--path=~/b.canvasboard"])
        expectEqual(try JSON(text: home.output), ["path": .string(NSHomeDirectory() + "/b.canvasboard")])
        expectEqual(try JSON(text: canvas(["--socket", app.path, "file", "/tmp/b.canvasboard"]).output), ["path": "/tmp/b.canvasboard"])
        expectEqual(try JSON(text: canvas(["--socket", app.path, "echo", "plans/b"]).output), ["text": "plans/b"])
    },
    test("help lists the app's commands, and a command's help its arguments, with no request run") {
        let app = try FakeApp()
        defer { app.stop() }
        let general = try canvas(["--socket", app.path])
        expectEqual(general.status, 0)
        expect(general.output.contains("Commands:\n  echo"), general.output)
        expect(general.output.contains("Exit status:\n  0         Done."), general.output)
        for arguments in [["help", "echo"], ["echo", "--help"], ["echo", "-h"]] {
            let help = try canvas(["--socket", app.path] + arguments)
            expectEqual(help.status, 0)
            expect(help.output.hasPrefix("Say it back.\n\nUsage: canvas echo <text> [--at <x,y>] [--count <number>] [--loud] [--tags <tags>]..."), help.output)
            expect(help.output.contains("Examples:\n  canvas echo hi"), help.output)
        }
        expectEqual(app.methods, Array(repeating: RPC.describeMethod, count: 4))
    },
    test("help asked for as JSON is what the app says: every command, or one, with its params' schema") {
        let app = try FakeApp()
        defer { app.stop() }
        let all = try canvas(["--socket", app.path, "help", "--format", "json"])
        expectEqual(all.status, 0)
        expectEqual(try JSON(text: all.output).decode(AppDescription.self), app.description)
        let one = try canvas(["--socket", app.path, "help", "echo", "--format", "json"])
        expectEqual(try JSON(text: one.output).decode(CommandSpec.self), app.description.commands.first)
    },
    test("a command or an option that isn't one is a usage error, exit 2, with what it probably was") {
        let app = try FakeApp()
        defer { app.stop() }
        let command = try canvas(["--socket", app.path, "ech", "hi"])
        expectEqual(command.status, 2)
        let error = try JSON(text: command.error)["error"]
        expectEqual(error?["reason"], "usage")
        expectEqual(error?["message"], "canvas has no command ech hi")
        expectEqual(error?["hint"], "Did you mean echo? `canvas help` lists the commands.")
        let option = try canvas(["--socket", app.path, "--format", "text", "echo", "hi", "--cont", "2"])
        expectEqual(option.status, 2)
        expectEqual(option.error, "canvas: echo has no option --cont\nhint: Did you mean --count?\n")
        let value = try canvas(["--socket", app.path, "echo", "hi", "--count", "many"])
        expectEqual(value.status, 2)
        expectEqual(try JSON(text: value.error)["error"]?["message"], "--count is a whole number, not many")
        // A command with no options says so, and one about the app says it takes no --board.
        let none = try canvas(["--socket", app.path, "--format", "text", "rows", "--board", "1"])
        expectEqual(none.status, 2)
        expectEqual(none.error, "canvas: rows has no option --board\nhint: It's about the app, not a board. It takes no options.\n")
        let board = try canvas(["--socket", app.path, "--format", "text", "touch", "--quick"])
        expectEqual(board.error, "canvas: touch has no option --quick\nhint: Its options: --board.\n")
        expectEqual(app.methods, Array(repeating: RPC.describeMethod, count: 5), "nothing ran")
    },
    test("an error from the app is exit 1, with its reason and hint") {
        let app = try FakeApp()
        defer { app.stop() }
        let json = try canvas(["--socket", app.path, "fail"])
        expectEqual(json.status, 1)
        expectEqual(json.output, "")
        expectEqual(try JSON(text: json.error), ["error": ["reason": "no_luck", "message": "It didn't work.", "hint": "Try luck.", "status": 1]])
        let text = try canvas(["--socket", app.path, "fail", "--format", "text"])
        expectEqual(text.error, "canvas: It didn't work.\nhint: Try luck.\n")
    },
    test("an error about a script says where: as JSON, what the app says beside canvas's own members; as text, the line, its statement, the hint, then the rest") {
        let app = try FakeApp()
        defer { app.stop() }
        let json = try canvas(["--socket", app.path, "fail", "--lines"])
        expectEqual(json.status, 1)
        expectEqual(try JSON(text: json.error), ["error": [
            "reason": "unknown_title", "message": #""Web" isn't on the board."#, "status": 1, "hint": #"Did you mean "web"?"#,
            "line": 2, "statement": #"box "API" right of "Web""#,
            "errors": [
                ["line": 2, "statement": #"box "API" right of "Web""#, "reason": "unknown_title", "message": #""Web" isn't on the board."#,
                 "hint": #"Did you mean "web"?"#],
                ["line": 4, "statement": "box left of", "reason": "syntax", "message": "left of what? A placement needs a shape to go against."],
            ],
        ]])
        let text = try canvas(["--socket", app.path, "fail", "--lines", "--format", "text"])
        expectEqual(text.status, 1)
        expectEqual(text.error, """
            canvas: line 2: "Web" isn't on the board.
              box "API" right of "Web"
            hint: Did you mean "web"?
            line 4: left of what? A placement needs a shape to go against.

            """)
    },
    test("an error about where on a line says the column, and marks what's wrong under the statement") {
        let app = try FakeApp()
        defer { app.stop() }
        let json = try canvas(["--socket", app.path, "fail", "--at"])
        expectEqual(json.status, 1)
        let error = try JSON(text: json.error)["error"]
        expectEqual(error?["column"], 12)
        expectEqual(error?["length"], 8)
        let text = try canvas(["--socket", app.path, "fail", "--at", "--format", "text"])
        expectEqual(text.status, 1)
        expectEqual(text.error, """
            canvas: line 1, column 12: :mention isn't a pseudo-class.
              sticky-note:mention("API gateway")
                         ^^^^^^^^
            hint: Did you mean :mentions?
            line 1, column 21: "API gateway" isn't in the file.

            """)
    },
    test("the marks under a statement line up in a terminal, where an emoji or a Japanese character takes two cells") {
        let app = try FakeApp()
        defer { app.stop() }
        let text = try canvas(["--socket", app.path, "fail", "--wide", "--format", "text"])
        expectEqual(text.status, 1)
        // Before the column: a quote, the rocket (2), a space, two characters (2 each), a quote, and
        // `:mention(`, 18 cells; under it, a quote, two characters and a quote, 6.
        expectEqual(text.error, """
            canvas: line 1, column 16: "発射" isn't in the file.
              "🚀 発射":mention("発射")
                                ^^^^^^

            """)
    },
    test("a script given as - is read from standard input, and help says it can be") {
        let app = try FakeApp()
        defer { app.stop() }
        let script = "box \"A\"\nbox \"B\" right of \"A\"\n"
        let piped = try run(builtExecutable("CanvasCLI"), ["--socket", app.path, "recite", "-"], input: script)
        expectEqual(piped.status, 0, piped.error)
        expectEqual(try JSON(text: piped.output), ["script": .string(script)])
        let typed = try canvas(["--socket", app.path, "recite", #"box "A""#])
        expectEqual(try JSON(text: typed.output), ["script": #"box "A""#])
        let help = try canvas(["--socket", app.path, "help", "recite"])
        expect(help.output.contains("Usage: canvas recite <script>|-"), help.output)
    },
    test("help says --board's default for a command that works with none too: the board in front, if any") {
        let app = try FakeApp()
        defer { app.stop() }
        let peek = try canvas(["--socket", app.path, "help", "peek"])
        expectEqual(peek.status, 0, peek.error)
        func flat(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        expect(flat(peek.output).contains("Default: the board in front, if any."), peek.output)
        let touch = try canvas(["--socket", app.path, "help", "touch"])
        expect(flat(touch.output).contains("Default: the board in front."), touch.output)
        expect(!flat(touch.output).contains("if any"), touch.output)
    },
    test("standard input that can't be read, or is closed, or isn't UTF-8, is a usage error, exit 2, not a crash or a wait") {
        let app = try FakeApp()
        defer { app.stop() }
        let shell = URL(fileURLWithPath: "/bin/sh"), built = builtExecutable("CanvasCLI").path
        for (redirect, why) in [("< /", "standard input couldn't be read"), ("<&-", "it's closed")] {
            let result = try run(shell, ["-c", "\"$0\" --socket \"$1\" recite - \(redirect)", built, app.path])
            expectEqual(result.status, 2, "\(redirect): \(result.error)")
            let message = try JSON(text: result.error)["error"]?["message"]?.stringValue ?? ""
            expect(message.hasPrefix("<script>: standard input couldn't be read") && message.contains(why), "\(redirect): \(message)")
        }
        let latin1 = try run(shell, ["-c", "printf 'Caf\\351' | \"$0\" --socket \"$1\" recite -", built, app.path])
        expectEqual(latin1.status, 2, latin1.error)
        expect(latin1.error.contains("it isn't UTF-8 text"), latin1.error)
    },
    test("with no app to talk to: exit 3, not_running; help still says how canvas works") {
        let path = temporarySocketPath()
        let result = try canvas(["--socket", path, "echo", "hi"])
        expectEqual(result.status, 3)
        expectEqual(try JSON(text: result.error)["error"]?["reason"], "not_running")
        let help = try canvas(["--socket", path, "help"])
        expectEqual(help.status, 0)
        expect(help.output.contains("Its commands can't be listed"), help.output)
    },
    test("an app that speaks another protocol is refused, exit 3") {
        let app = try FakeApp()
        defer { app.stop() }
        app.protocolVersion = RPC.protocolVersion + 1
        let result = try canvas(["--socket", app.path, "echo", "hi"])
        expectEqual(result.status, 3)
        expectEqual(try JSON(text: result.error)["error"]?["reason"], "protocol_mismatch")
        expectEqual(app.methods, [RPC.describeMethod])
    },
    test("--version says the protocol it speaks") {
        let result = try canvas(["--version"])
        expectEqual(result.status, 0)
        expectEqual(try JSON(text: result.output), ["protocol": .number(Double(RPC.protocolVersion))])
    },
])

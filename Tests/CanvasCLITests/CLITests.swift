import CanvasRPC
import Foundation
import TestKit

// The command line as it's built, run as an agent runs it, against an app of the test's own: one
// that describes a few commands and answers each with what it was sent.

/// An app for `canvas` to talk to. Its commands: `echo` (its params back), `touch` (a board's: the
/// board it's given back), `fail` (an error), `rows` (a list).
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
            CommandSpec(name: "touch", summary: "Touch a board.", scope: .board),
            CommandSpec(name: "fail", summary: "Fail.", scope: .app),
            CommandSpec(name: "rows", summary: "Some rows.", scope: .app),
        ])
    }

    init() throws {
        let listener = RPCListener(path: path) { [unowned self] request in answer(request) }
        try listener.start()
        self.listener = listener
    }

    func stop() { listener?.stop() }

    private func answer(_ request: RPCRequest) -> Result<JSON, RPCError> {
        methods.append(request.method)
        switch request.method {
        case RPC.describeMethod: return .success(try! JSON(encoding: description))
        case "echo": return .success(request.params ?? [:])
        case "touch": return .success(["board": request.params?["board"] ?? .null])
        case "fail": return .failure(.failed("It didn't work.", reason: "no_luck", hint: "Try luck."))
        case "rows": return .success([["id": 2, "name": "Plans", "shapes": 12], ["id": 10, "name": "Untitled", "edited": true]])
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
        expectEqual(app.methods, Array(repeating: RPC.describeMethod, count: 3), "nothing ran")
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

import CanvasRPC
import Darwin
import Foundation

/// How a run of `canvas` ends. Agents branch on it; the error printed says why.
enum ExitStatus: Int32 {
    case done = 0
    /// The app got the command and couldn't do it: no such kind, no such board.
    case failed = 1
    /// The command line itself is wrong: no such command or option, a value that isn't one.
    case usage = 2
    /// The app couldn't be reached, or didn't answer: not running, timed out, another protocol.
    case unavailable = 3
}

enum OutputFormat: String {
    /// Pretty-printed, keys sorted: for agents and scripts, and the default when the output isn't
    /// a terminal.
    case json
    /// For people at a terminal.
    case text
}

/// One run of `canvas`: it asks the app what commands it has (`describe`), reads the arguments as
/// one of them, runs it on the app, and prints what the app says. Every command, its arguments and
/// its help come from the app, which the plugins it's built from contribute to; `canvas` itself
/// knows only `help` and its own options.
struct Invocation {
    let arguments: [String]
    let environment: [String: String]
    var write: (String, _ toError: Bool) -> Void = { text, toError in
        FileHandle(fileDescriptor: toError ? STDERR_FILENO : STDOUT_FILENO).write(Data((text + "\n").utf8))
    }
    var isTerminal: Bool = isatty(STDOUT_FILENO) == 1

    func run() -> ExitStatus {
        let options: Options
        do {
            options = try Options(arguments)
        } catch {
            return fail(.usage, reason: "usage", error.message, hint: error.hint, format: .text)
        }
        let format = options.format ?? (environment["CANVAS_FORMAT"].flatMap(OutputFormat.init) ?? (isTerminal ? .text : .json))
        if options.version {
            print("\(RPC.commandName) (protocol \(RPC.protocolVersion))", format: format, json: ["protocol": .number(Double(RPC.protocolVersion))])
            return .done
        }
        let path = options.socket ?? SocketPath.resolve(environment: environment)
        let client: RPCClient
        do {
            client = try RPCClient(path: path)
        } catch {
            if options.help || options.words.isEmpty {
                write(generalHelp(app: nil, problem: error.description), false)
                return .done
            }
            return fail(.unavailable, error, format: format)
        }
        let app: AppDescription
        do {
            app = try client.describe(timeout: options.timeout)
        } catch {
            return fail(.unavailable, error, format: format)
        }
        guard app.protocolVersion == RPC.protocolVersion else {
            let bundled = app.app.path.map { " Use the one in the app: \($0)/Contents/Helpers/\(RPC.commandName)." } ?? ""
            return fail(.unavailable, reason: "protocol_mismatch",
                        "\(app.app.name) speaks protocol \(app.protocolVersion), and this \(RPC.commandName) speaks \(RPC.protocolVersion).",
                        hint: "Use the \(RPC.commandName) that came with the app.\(bundled)", format: format)
        }
        // Help is text, for reading, wherever it goes; asked for as JSON, it's what the app said:
        // every command, with its params' JSON Schema.
        let helpAsJSON = options.format == .json
        guard !options.words.isEmpty else {
            write(helpAsJSON ? (try? JSON(encoding: app))?.prettyText ?? "" : generalHelp(app: app, problem: nil), false)
            return .done
        }
        guard let (command, rest) = app.command(in: options.words) else {
            let names = app.commands.map { String($0.name.split(separator: " ")[0]) }
            let guess = options.words.lazy.filter { !$0.hasPrefix("-") }.compactMap { CommandSpec.closest(to: $0, among: names) }.first
            return fail(.usage, reason: "usage", "\(RPC.commandName) has no command \(options.words.joined(separator: " "))",
                        hint: (guess.map { "Did you mean \($0)? " } ?? "") + "`\(RPC.commandName) help` lists the commands.", format: format)
        }
        if options.help {
            write(helpAsJSON ? (try? JSON(encoding: command))?.prettyText ?? "" : command.help(), false)
            return .done
        }
        var params: [String: JSON]
        do {
            params = try command.params(from: rest)
        } catch {
            return fail(.usage, reason: "usage", error.message, hint: error.hint ?? "Usage: \(command.usage())", format: format)
        }
        if command.scope == .board, let board = params[RPC.boardParam]?.stringValue, Self.isPath(board) {
            params[RPC.boardParam] = .string(Self.absolute(board))
        }
        do {
            let result = try client.call(command.name, params: .object(params), timeout: options.timeout)
            print(TextOutput.render(result), format: format, json: result)
            return .done
        } catch .remote(let error) {
            return fail(.failed, reason: error.reason ?? "failed", error.message, hint: error.hint, format: format)
        } catch {
            return fail(.unavailable, error, format: format)
        }
    }

    // MARK: Printing

    /// `text` is made only when it's what's printed.
    private func print(_ text: @autoclosure () -> String, format: OutputFormat, json: JSON) {
        switch format {
        case .json:
            write(json.prettyText, false)
        case .text:
            let text = text()
            if !text.isEmpty { write(text, false) }
        }
    }

    private func fail(_ status: ExitStatus, _ error: ClientError, format: OutputFormat) -> ExitStatus {
        switch error {
        case .notRunning:
            return fail(status, reason: "not_running", error.description,
                        hint: "Open Infinite Canvas, then try again. (\(SocketPath.environmentKey) or --socket says where to find it, if it's somewhere else.)",
                        format: format)
        case .unreachable:
            return fail(status, reason: "unreachable", error.description, hint: "A sandbox may be keeping \(RPC.commandName) from connecting to the socket.",
                        format: format)
        case .timedOut: return fail(status, reason: "timed_out", error.description, hint: "--timeout waits longer.", format: format)
        case .connectionClosed: return fail(status, reason: "connection_closed", error.description, hint: nil, format: format)
        case .malformedRequest, .malformedResponse: return fail(status, reason: "malformed", error.description, hint: nil, format: format)
        case .remote(let remote): return fail(.failed, reason: remote.reason ?? "failed", remote.message, hint: remote.hint, format: format)
        }
    }

    /// Says what went wrong on standard error: as JSON (`{"error": {…}}`) or as text, with the hint.
    private func fail(_ status: ExitStatus, reason: String, _ message: String, hint: String?, format: OutputFormat) -> ExitStatus {
        switch format {
        case .json:
            var error: [String: JSON] = ["reason": .string(reason), "message": .string(message), "status": .number(Double(status.rawValue))]
            if let hint { error["hint"] = .string(hint) }
            write(JSON.object(["error": .object(error)]).prettyText, true)
        case .text:
            write("\(RPC.commandName): \(message)" + (hint.map { "\nhint: \($0)" } ?? ""), true)
        }
        return status
    }

    // MARK: Boards named by their files

    /// Whether `--board` names a file rather than a board's id or name.
    /// A name may end in .canvasboard too (the window's title can), so that alone makes a file only
    /// if there's one.
    static func isPath(_ reference: String) -> Bool {
        reference.contains("/") || reference.hasPrefix("~")
            || (reference.hasSuffix(".canvasboard") && FileManager.default.fileExists(atPath: absolute(reference)))
    }

    /// A file named relative to where `canvas` runs, as the app, which runs elsewhere, needs it.
    static func absolute(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
        return url.standardizedFileURL.path
    }
}

/// The command line's own options, read wherever they are (before `--`); everything else is the
/// command's.
struct Options {
    var socket: String?
    var format: OutputFormat?
    var timeout: TimeInterval = 10
    var help = false
    var version = false
    /// The command's name and arguments, in order.
    var words: [String] = []

    init(_ arguments: [String]) throws(ArgumentError) {
        var index = 0, optionsEnded = false
        func value(of option: String, inline: String?) throws(ArgumentError) -> String {
            if let inline { return inline }
            guard index < arguments.count else { throw ArgumentError("--\(option) needs a value") }
            defer { index += 1 }
            return arguments[index]
        }
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if optionsEnded || !argument.hasPrefix("-") {
                if words.isEmpty, argument == "help", !optionsEnded {
                    help = true
                } else {
                    words.append(argument)
                }
                continue
            }
            if argument == "--" {
                optionsEnded = true
                words.append(argument)
                continue
            }
            let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
            let name = parts[0], inline = parts.count > 1 ? parts[1] : nil
            switch name {
            case "-h", "--help": help = true
            case "--version": version = true
            case "--socket": socket = try value(of: "socket", inline: inline)
            case "--format":
                let text = try value(of: "format", inline: inline)
                guard let format = OutputFormat(rawValue: text) else { throw ArgumentError("--format is json or text, not \(text)") }
                self.format = format
            case "--timeout":
                let text = try value(of: "timeout", inline: inline)
                guard let seconds = TimeInterval(text), seconds > 0, seconds.isFinite else {
                    throw ArgumentError("--timeout is a number of seconds, not \(text)")
                }
                timeout = seconds
            default: words.append(argument)
            }
        }
    }
}

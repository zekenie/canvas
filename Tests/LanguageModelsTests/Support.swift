import Foundation
import LanguageModels
import os
import TestKit

/// The network, stubbed: a session whose every request goes to `StubProtocol`, which keeps it and
/// answers what the test said to (a status and a body, a transport error, or nothing, until the
/// request is cancelled). Nothing leaves the machine.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    enum Answer: Sendable {
        case http(status: Int, body: String)
        case failure(URLError.Code)
        /// Never answers: the request waits until it's cancelled.
        case hang
    }

    /// A request as it arrived, its body read out of its stream.
    struct Received: Sendable {
        let request: URLRequest
        let body: Data
    }

    private struct State {
        var answer: Answer = .failure(.notConnectedToInternet)
        var received: [Received] = []
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    /// A session that reaches only this stub, answering `answer` from now on.
    static func session(answering answer: Answer) -> URLSession {
        state.withLock { $0 = State(answer: answer) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    static var received: [Received] { state.withLock { $0.received } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map(Self.readAll) ?? Data()
        let answer = Self.state.withLock { state in
            state.received.append(Received(request: request, body: body))
            return state.answer
        }
        switch answer {
        case let .http(status, text):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["content-type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case let .failure(code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .hang:
            break
        }
    }

    override func stopLoading() {}

    private static func readAll(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// A fake key: what the tests save, and expect in the header.
let testKey = "sk-ant-test-0123456789"

/// A key store in a new temporary directory, which `body` may fill; removed after.
@MainActor
func withTemporaryStore(_ body: (AnthropicKeyStore) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "LanguageModelsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(AnthropicKeyStore(url: directory.appending(path: "InfiniteCanvas/anthropic-api-key", directoryHint: .notDirectory)))
}

/// Claude, with `testKey` saved in a temporary store, over a session that reaches only the stub.
@MainActor
func withStubbedModel(answering answer: StubProtocol.Answer, _ body: (AnthropicModel) throws -> Void) throws {
    try withTemporaryStore { keys in
        try keys.write(testKey)
        try body(AnthropicModel(keys: keys, session: StubProtocol.session(answering: answer)))
    }
}

/// What `model` answers `request`, or the error it throws.
@MainActor
func outcome(of model: any LanguageModel, _ request: ModelRequest = ModelRequest(messages: [.user("Hi")])) throws -> Result<ModelResponse, LanguageModelError> {
    try awaitResult {
        do throws(LanguageModelError) {
            return .success(try await model.respond(to: request))
        } catch {
            return .failure(error)
        }
    }
}

/// A successful reply from the Messages API.
func reply(_ text: String, stopReason: String = "end_turn") -> String {
    """
    {"id":"msg_01","type":"message","role":"assistant","model":"claude-haiku-4-5",
     "content":[{"type":"text","text":\(json(text))}],
     "stop_reason":"\(stopReason)","stop_sequence":null,"usage":{"input_tokens":12,"output_tokens":3}}
    """
}

func errorBody(_ type: String, _ message: String) -> String {
    #"{"type":"error","error":{"type":"\#(type)","message":\#(json(message))},"request_id":"req_01"}"#
}

private func json(_ string: String) -> String {
    String(decoding: try! JSONEncoder().encode(string), as: UTF8.self)
}

/// A stand-in for `claude`: a script in a temporary directory that writes down how it was run (its
/// arguments, environment and standard input, for each of `-p`, `auth status`, `auth login` and
/// `auth logout`) and answers what the test said for that command, or never answers (`hang`), until
/// it's stopped. Nothing it does reaches the network or the person's own Claude Code.
struct FakeClaude {
    /// One of the commands it answers, named for the files it keeps.
    enum Command: String {
        case print, authStatus = "auth-status", authLogin = "auth-login", authLogout = "auth-logout"
    }

    let directory: URL
    var executable: URL { directory.appending(path: "claude", directoryHint: .notDirectory) }
    /// The app's Claude Code folder, as the tests' `ClaudeCode` names it.
    var configDirectory: URL { directory.deletingLastPathComponent().appending(path: "claude-code", directoryHint: .isDirectory) }
    var claudeCode: ClaudeCode { ClaudeCode(executable: executable, configDirectory: configDirectory) }

    init(in directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = #"""
        #!/bin/sh
        dir="$(dirname "$0")"
        key=print
        [ "$1" = auth ] && key="auth-$2"
        echo $$ >> "$dir/started-$key"
        : > "$dir/args-$key"
        for a in "$@"; do printf '%s\n' "$a" >> "$dir/args-$key"; done
        env > "$dir/env-$key"
        cat > "$dir/stdin-$key"
        [ -f "$dir/hang-$key" ] && echo $$ > "$dir/pid-$key" && exec sleep 30
        if [ -f "$dir/hold-$key" ]; then sleep 30 & echo $! >> "$dir/held-$key"; fi
        [ -f "$dir/out-$key" ] && cat "$dir/out-$key"
        [ -f "$dir/err-$key" ] && cat "$dir/err-$key" >&2
        exit "$(cat "$dir/status-$key" 2>/dev/null || echo 0)"
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    /// Answers `command` with `stdout` and `stderr`, ending with `status`.
    func answer(_ command: Command, stdout: String, stderr: String = "", status: Int32 = 0) throws {
        try stdout.write(to: file("out", command), atomically: true, encoding: .utf8)
        try stderr.write(to: file("err", command), atomically: true, encoding: .utf8)
        try String(status).write(to: file("status", command), atomically: true, encoding: .utf8)
    }

    /// Never answers `command`: it waits until it's stopped.
    func hang(_ command: Command) throws {
        try "".write(to: file("hang", command), atomically: true, encoding: .utf8)
    }

    /// Answers `command`, then leaves a program of its own running that holds its output open.
    func holdOutput(_ command: Command) throws {
        try "".write(to: file("hold", command), atomically: true, encoding: .utf8)
    }

    /// Whether `command` was run.
    func ran(_ command: Command) -> Bool { FileManager.default.fileExists(atPath: file("args", command).path) }

    /// The arguments `command` was last run with.
    func arguments(_ command: Command) -> [String]? {
        (try? String(contentsOf: file("args", command), encoding: .utf8)).map { $0.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init) }
    }

    /// The environment `command` was last run with.
    func environment(_ command: Command) -> [String: String] {
        let text = (try? String(contentsOf: file("env", command), encoding: .utf8)) ?? ""
        return Dictionary(text.split(separator: "\n").compactMap { line in
            line.firstIndex(of: "=").map { (String(line[..<$0]), String(line[line.index(after: $0)...])) }
        }, uniquingKeysWith: { $1 })
    }

    /// How many times `command` has been started.
    func started(_ command: Command) -> Int {
        ((try? String(contentsOf: file("started", command), encoding: .utf8)) ?? "").split(separator: "\n").count
    }

    /// Whether the process `command` last started is still running.
    func isRunning(_ command: Command) -> Bool {
        let last = ((try? String(contentsOf: file("started", command), encoding: .utf8)) ?? "").split(separator: "\n").last
        return last.flatMap { pid_t($0) }.map { kill($0, 0) == 0 } ?? false
    }

    /// Ends the processes of `command` still waiting, as a test cleans up after one it left running.
    func endAll(_ command: Command) {
        for name in ["started", "held"] {
            for pid in ((try? String(contentsOf: file(name, command), encoding: .utf8)) ?? "").split(separator: "\n").compactMap({ pid_t($0) }) {
                kill(pid, SIGTERM)
            }
        }
    }

    /// The process of `command` waiting (`hang`), which keeps its id as it waits.
    func pid(_ command: Command) -> pid_t? {
        (try? String(contentsOf: file("pid", command), encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// What `command` was last given on its standard input.
    func input(_ command: Command) -> String? { try? String(contentsOf: file("stdin", command), encoding: .utf8) }

    private func file(_ name: String, _ command: Command) -> URL {
        directory.appending(path: "\(name)-\(command.rawValue)", directoryHint: .notDirectory)
    }
}

/// What `claude -p --output-format json` prints for an answer, in the fields the model reads.
func claudeResult(_ text: String, stopReason: String = "end_turn", isError: Bool = false, status: Int? = nil) -> String {
    """
    {"type":"result","subtype":"success","is_error":\(isError),"result":\(json(text)),"stop_reason":"\(stopReason)",\
    "api_error_status":\(status.map(String.init) ?? "null"),"duration_ms":812,\
    "usage":{"input_tokens":9,"cache_creation_input_tokens":0,"cache_read_input_tokens":40,"output_tokens":2}}
    """
}

/// An account in a new temporary directory: its way and key there, and a stand-in `claude` with
/// its folder; removed after.
@MainActor
func withTemporaryAccount(_ body: (AnthropicAccount, FakeClaude) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "LanguageModelsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let claude = try FakeClaude(in: directory.appending(path: "bin", directoryHint: .isDirectory))
    let support = directory.appending(path: "InfiniteCanvas", directoryHint: .isDirectory)
    let account = AnthropicAccount(methodURL: support.appending(path: "sign-in", directoryHint: .notDirectory),
                                   keys: AnthropicKeyStore(url: support.appending(path: "anthropic-api-key", directoryHint: .notDirectory)),
                                   claudeCode: claude.claudeCode)
    try body(account, claude)
}

/// What `claude auth status` prints, signed in or out (as recorded: `ClaudeCodeRecordings`).
func claudeStatus(signedIn: Bool) -> String {
    signedIn ? ClaudeCodeRecordings.signedIn : ClaudeCodeRecordings.signedOut
}

/// Turns the main run loop until `done`, for as long as a run of the stand-in `claude` may take on
/// a machine running every test at once (each is a shell starting a few programs), then fails the
/// test if it isn't.
@MainActor
@discardableResult
func runsFor(_ done: () -> Bool, file: StaticString = #fileID, line: UInt = #line) -> Bool {
    spinRunLoop(until: done, timeout: 10, file: file, line: line)
}

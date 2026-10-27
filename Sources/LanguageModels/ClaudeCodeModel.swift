import Foundation

/// Claude, asked through the person's own Claude Code, signed in in the app's folder (`ClaudeCode`):
/// each call is one `claude -p` run with no tools, no MCP servers, no skills or commands and no
/// session kept, in an empty directory, its system prompt the request's, the conversation on its
/// standard input, and the answer read from its JSON; at most four at once (`ClaudeCodeTurns`),
/// each stopped when the task asking is cancelled or its time is up. Its usage is the person's
/// Claude plan's. What `claude -p` has no way to say is left out: a request's `temperature`,
/// `stopSequences` and `fallbacks`, which no shipped request sets.
public struct ClaudeCodeModel: LanguageModel {
    /// The model that answers a request that names none: the app's (`AnthropicModel.haiku`).
    public let model: String
    public let claudeCode: ClaudeCode
    /// Seconds to wait for an answer, at the least, as `AnthropicModel.timeout`: a request that may
    /// be answered at length waits longer (`timeout(for:)`).
    public let timeout: TimeInterval
    /// The turns its calls wait for (`ClaudeCodeTurns.shared`, four at once, in the app).
    public let turns: ClaudeCodeTurns

    public init(model: String = AnthropicModel.haiku, claudeCode: ClaudeCode = .standard, timeout: TimeInterval = 60) {
        self.init(model: model, claudeCode: claudeCode, timeout: timeout, turns: .shared)
    }

    /// With turns of its own (tests count them).
    public init(model: String, claudeCode: ClaudeCode, timeout: TimeInterval, turns: ClaudeCodeTurns) {
        self.model = model
        self.claudeCode = claudeCode
        self.timeout = timeout
        self.turns = turns
    }

    public func respond(to request: ModelRequest) async throws(LanguageModelError) -> ModelResponse {
        if Task.isCancelled { throw .cancelled }
        guard !claudeCode.isKnownSignedOut, let executable = await claudeCode.executable() else { throw .notSignedIn }
        guard await turns.take() else { throw .cancelled }
        let output: ProcessOutput
        do throws(ProcessFailure) {
            defer { Task { await turns.done() } }
            output = try await claudeCode.run(executable, arguments(for: request), input: Data(Self.prompt(for: request.messages).utf8),
                                              extra: Self.variables(for: request), timeout: timeout(for: request))
        } catch {
            switch error {
            case .cancelled: throw .cancelled
            case .timedOut: throw .timedOut
            case let .notStarted(why): throw .claudeCode("Claude Code couldn’t start: \(why)")
            }
        }
        if Task.isCancelled { throw .cancelled }
        do throws(LanguageModelError) {
            return try Self.decode(output)
        } catch {
            if error == .notSignedIn { claudeCode.remember(signedOut: true) }
            throw error
        }
    }

    /// How long to wait for the answer to `request`, as `AnthropicModel.timeout(for:)` says.
    public func timeout(for request: ModelRequest) -> TimeInterval {
        timeout + Double(request.maxTokens) / AnthropicModel.slowestTokensPerSecond
    }

    // MARK: The request

    /// `claude`'s arguments for `request`: print one answer as JSON, with the request's model, its
    /// effort, and its system prompt in place of Claude Code's; no tools, no MCP servers (the
    /// account's connectors included), no skills or commands (signed in, Claude Code copies the
    /// account's skills into its folder), and no session kept.
    func arguments(for request: ModelRequest) -> [String] {
        var arguments = ["-p", "--output-format", "json", "--model", request.model ?? model, "--tools", "",
                         "--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence"]
        if let system = request.system, !system.isEmpty { arguments += ["--system-prompt", system] }
        if let effort = request.effort { arguments += ["--effort", effort] }
        return arguments
    }

    /// The request's limit on the answer, and its effort, which Claude Code takes as variables: in
    /// `-p` the `--effort` flag isn't applied (a run at `low` thinks as one at `high` does), and
    /// `CLAUDE_CODE_EFFORT_LEVEL` outranks every other way of saying it.
    static func variables(for request: ModelRequest) -> [String: String] {
        var variables = ["CLAUDE_CODE_MAX_OUTPUT_TOKENS": String(request.maxTokens)]
        if let effort = request.effort { variables["CLAUDE_CODE_EFFORT_LEVEL"] = effort }
        return variables
    }

    /// The conversation as the one message `claude -p` takes: the last turn as it is, and any turns
    /// before it (a question asked again, with the answer it got and what was wrong with it) above
    /// it, each in a tag named for who said it.
    public static func prompt(for messages: [ModelMessage]) -> String {
        guard let last = messages.last else { return "" }
        let earlier = messages.dropLast()
        guard !earlier.isEmpty else { return last.text }
        let turns = earlier.map { "<\($0.role.rawValue)>\n\($0.text)\n</\($0.role.rawValue)>" }.joined(separator: "\n")
        return "<earlier_turns>\n\(turns)\n</earlier_turns>\n\n\(last.text)"
    }

    // MARK: The answer

    private struct Reply: Decodable {
        struct Usage: Decodable {
            let inputTokens: Int?
            let cacheCreationInputTokens: Int?
            let cacheReadInputTokens: Int?
            let outputTokens: Int?
        }

        let type: String?
        let isError: Bool?
        let result: String?
        let stopReason: String?
        let apiErrorStatus: Int?
        let usage: Usage?
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    /// What `claude -p --output-format json` printed, as an answer or the failure it says. Its
    /// `result` is the answer's text, or, with `is_error`, the failure's own words. An answer that
    /// ran past `maxTokens` is a failure to Claude Code (after three more tries); here it's an
    /// answer cut off, as a key's would be. Input tokens count what was read from and written to
    /// Claude Code's cache too. Output that isn't its JSON is a failure in the last words it wrote
    /// to standard error.
    static func decode(_ output: ProcessOutput) throws(LanguageModelError) -> ModelResponse {
        guard let reply = try? decoder.decode(Reply.self, from: output.stdout), reply.type == "result" else {
            let said = String(decoding: output.stderr, as: UTF8.self).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .last { !$0.isEmpty && !$0.hasPrefix("[claude-code:") }
            throw error(status: nil, message: said ?? "Claude Code exited with status \(output.status)")
        }
        let text = reply.result ?? ""
        let usage = reply.usage
        let input = (usage?.inputTokens ?? 0) + (usage?.cacheCreationInputTokens ?? 0) + (usage?.cacheReadInputTokens ?? 0)
        let outputTokens = usage?.outputTokens ?? 0
        if reply.isError == true {
            if text.contains("output token maximum") {
                return ModelResponse(text: "", stopReason: .maxTokens, inputTokens: input, outputTokens: outputTokens)
            }
            throw error(status: reply.apiErrorStatus, message: text)
        }
        return ModelResponse(text: text, stopReason: StopReason(rawValue: reply.stopReason ?? StopReason.endTurn.rawValue),
                             inputTokens: input, outputTokens: outputTokens)
    }

    /// A failure Claude Code reported, as a `LanguageModelError`: by the service's status where it
    /// gives one, else by its words. Signed out, a sign-in expired or refused is `.notSignedIn`
    /// (signing in again is the remedy); a plan's limit, as too many requests, is `.rateLimited`.
    public static func error(status: Int?, message: String) -> LanguageModelError {
        let words = message.lowercased()
        func says(_ any: String...) -> Bool { any.contains { words.contains($0) } }
        if let status {
            switch status {
            case 401: return .notSignedIn
            case 429: return .rateLimited
            case 529: return .overloaded
            default: return .server(status: status, message: message)
            }
        }
        if says("not logged in", "/login", "login again", "sign in again", "authentication required", "failed to authenticate",
                "oauth token") {
            return .notSignedIn
        }
        if says("hit your", "usage limit", "limiting requests", "(429)", "rate limit") { return .rateLimited }
        if says("overloaded", "high load") { return .overloaded }
        if says("unable to connect", "connection refused", "can't reach", "can’t reach", "no internet", "couldn't connect",
                "couldn’t connect", "connection dropped", "socket is closed") {
            return .network(message)
        }
        if says("request timed out") { return .timedOut }
        return .claudeCode(message)
    }
}

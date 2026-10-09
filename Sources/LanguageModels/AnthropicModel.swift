import Foundation

/// Claude, over Anthropic's Messages API (`POST https://api.anthropic.com/v1/messages`), straight
/// from the app: no SDK, one request per call, no streaming, no retries (a caller that wants one
/// offers it: `LanguageModelError.isTransient`). The key is read from `keys` at every call, so a
/// key saved in Settings works at once, and one removed stops working at once.
public struct AnthropicModel: LanguageModel {
    /// Claude Haiku 4.5: fast and cheap, the app's model.
    public static let haiku = "claude-haiku-4-5"
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    /// The `anthropic-version` header.
    public static let apiVersion = "2023-06-01"
    /// The `anthropic-beta` header a request that asks for the service's fallback sends
    /// (`ModelFallbacks.default`, the body's `"fallbacks": "default"`).
    public static let fallbackBeta = "server-side-fallback-2026-07-01"

    /// The model's id: the one that answers a request that names none (`ModelRequest.model`).
    public let model: String
    /// Where the key is read from.
    public let keys: AnthropicKeyStore
    /// Seconds to wait for an answer, at the least: a request that may be answered at length waits
    /// longer (`timeout(for:)`).
    public let timeout: TimeInterval
    /// Nil for `URLSession.shared`, taken at the first call: the app makes its model as it starts,
    /// and the launch needn't make a session nothing uses until a type asks Claude something.
    let session: URLSession?

    /// `session` is for tests, which stub the network with a `URLProtocol`.
    public init(model: String = AnthropicModel.haiku, keys: AnthropicKeyStore = .standard, timeout: TimeInterval = 60,
                session: URLSession? = nil) {
        self.model = model
        self.keys = keys
        self.timeout = timeout
        self.session = session
    }

    public func respond(to request: ModelRequest) async throws(LanguageModelError) -> ModelResponse {
        if Task.isCancelled { throw .cancelled }
        guard let key = keys.read() else { throw .noKey }
        let urlRequest = self.urlRequest(for: request, key: key)
        let data: Data, response: URLResponse
        do {
            (data, response) = try await (session ?? .shared).data(for: urlRequest)
        } catch {
            throw Self.transportError(error)
        }
        if Task.isCancelled { throw .cancelled }
        guard let http = response as? HTTPURLResponse else { throw .malformedResponse }
        guard (200..<300).contains(http.statusCode) else { throw Self.error(status: http.statusCode, body: data, key: key) }
        return try Self.decode(data)
    }

    // MARK: The request

    /// Haiku writes some 150 tokens a second; a request waits for its answer as if this many, a
    /// second for each of them it may write.
    static let slowestTokensPerSecond = 100.0

    /// How long to wait for the answer to `request`: `timeout`, and a second for every
    /// `slowestTokensPerSecond` tokens it may write. It comes whole, all at once (nothing streams),
    /// so a long answer is a long silence: 16,000 tokens wait 220 s.
    public func timeout(for request: ModelRequest) -> TimeInterval {
        timeout + Double(request.maxTokens) / Self.slowestTokensPerSecond
    }

    /// What's sent, in the API's names (snake case); what's nil is left out. An answer another model
    /// gave in the asked one's place (`fallbacks`) is read as any other: the block that marks the
    /// switch isn't text.
    private struct Body: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }

        struct OutputConfig: Encodable {
            let effort: String
        }

        let model: String
        let maxTokens: Int
        let system: String?
        let messages: [Message]
        let temperature: Double?
        let stopSequences: [String]?
        let outputConfig: OutputConfig?
        let fallbacks: String?
    }

    func urlRequest(for request: ModelRequest, key: String) -> URLRequest {
        var urlRequest = URLRequest(url: Self.endpoint, timeoutInterval: timeout(for: request))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue(key, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        if request.fallbacks != nil { urlRequest.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta") }
        let body = Body(model: request.model ?? model, maxTokens: request.maxTokens,
                        system: request.system.flatMap { $0.isEmpty ? nil : $0 },
                        messages: request.messages.map { Body.Message(role: $0.role.rawValue, content: $0.text) },
                        temperature: request.temperature,
                        stopSequences: request.stopSequences.isEmpty ? nil : request.stopSequences,
                        outputConfig: request.effort.map(Body.OutputConfig.init), fallbacks: request.fallbacks?.rawValue)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = .sortedKeys
        // Strings, numbers and arrays of them: nothing here can fail to encode.
        urlRequest.httpBody = try? encoder.encode(body)
        return urlRequest
    }

    // MARK: The answer

    private struct Reply: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }

        struct Usage: Decodable {
            let inputTokens: Int?
            let outputTokens: Int?
        }

        let content: [Block]
        let stopReason: String
        let usage: Usage?
    }

    private struct ErrorReply: Decodable {
        struct Detail: Decodable {
            let type: String?
            let message: String?
        }

        let error: Detail?
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    static func decode(_ data: Data) throws(LanguageModelError) -> ModelResponse {
        guard let reply = try? decoder.decode(Reply.self, from: data) else { throw .malformedResponse }
        return ModelResponse(text: reply.content.filter { $0.type == "text" }.compactMap(\.text).joined(),
                             stopReason: StopReason(rawValue: reply.stopReason),
                             inputTokens: reply.usage?.inputTokens ?? 0, outputTokens: reply.usage?.outputTokens ?? 0)
    }

    /// An error status as a `LanguageModelError`, with the service's message where it says one:
    /// shown to a person (`LanguageModelError.message`), so the key, were the service ever to say
    /// it, is taken out first.
    static func error(status: Int, body: Data, key: String) -> LanguageModelError {
        let detail = (try? decoder.decode(ErrorReply.self, from: body))?.error
        if detail?.type == "overloaded_error" { return .overloaded }
        switch status {
        case 401: return .unauthorized
        case 429: return .rateLimited
        case 529: return .overloaded
        default: return .server(status: status, message: scrubbed(detail?.message ?? "", key: key))
        }
    }

    /// `text` with every occurrence of `key` replaced by `…`.
    static func scrubbed(_ text: String, key: String) -> String {
        key.isEmpty ? text : text.replacingOccurrences(of: key, with: "…")
    }

    static func transportError(_ error: any Error) -> LanguageModelError {
        if error is CancellationError { return .cancelled }
        if let error = error as? URLError {
            switch error.code {
            case .cancelled: return .cancelled
            case .timedOut: return .timedOut
            default: return .network(error.localizedDescription)
            }
        }
        return .network(error.localizedDescription)
    }
}

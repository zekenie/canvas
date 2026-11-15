import Foundation
import LanguageModels

/// Where the OpenAI API key is kept, by default
/// `~/Library/Application Support/InfiniteCanvas/openai-api-key`, beside Anthropic's and TypeSafe's: the
/// key alone, in a file only its owner can read (`KeyFile`). Never print, log or show what it reads.
public struct OpenAIKeyStore: KeyFile, Equatable {
    /// The file.
    public let url: URL

    /// A store in any file (tests use a temporary directory).
    public init(url: URL) { self.url = url }

    /// The app's: `~/Library/Application Support/InfiniteCanvas/openai-api-key`.
    public static var standard: OpenAIKeyStore { OpenAIKeyStore(url: applicationSupport("openai-api-key")) }
}

/// OpenAI's text-embedding-3-large, over its API (`POST https://api.openai.com/v1/embeddings`), straight
/// from the app: the texts of a call in requests of up to `textsPerRequest`, one after another, each
/// text a vector of 3,072 numbers, no retries (a caller that wants one offers it:
/// `EmbeddingModelError.isTransient`). The key is read from `keys` at every call, so a key saved in
/// Settings works at once and one removed stops working at once. Every text sent leaves the machine.
public struct OpenAIEmbeddingModel: EmbeddingModel {
    /// OpenAI's largest embedding model.
    public static let latest = "text-embedding-3-large"
    public static let endpoint = URL(string: "https://api.openai.com/v1/embeddings")!
    /// What its errors call it.
    public static let provider = "OpenAI"

    /// The model asked.
    public let model: String
    /// Where the key is read from.
    public let keys: OpenAIKeyStore
    /// Seconds each request may take in all, from sending it to its whole answer (256 texts of a few hundred
    /// words each take a few seconds): the longest silence on it (`URLRequest.timeoutInterval`) and, with
    /// no `session` given, the whole request (the session's `timeoutIntervalForResource`), so a reply that
    /// trickles in is cut off too. A `session` given is the caller's to bound.
    public let timeout: TimeInterval
    public let textsPerRequest: Int
    /// Nil for a session of its own, made for each call (`embed`) with `timeout` bounding each request, and
    /// let go after it.
    let session: URLSession?

    /// `session` is for tests, which stub the network with a `URLProtocol`.
    public nonisolated init(model: String = OpenAIEmbeddingModel.latest, keys: OpenAIKeyStore = .standard, timeout: TimeInterval = 60,
                            textsPerRequest: Int = 256, session: URLSession? = nil) {
        self.model = model
        self.keys = keys
        self.timeout = timeout
        self.textsPerRequest = textsPerRequest
        self.session = session
    }

    /// The provider and the model: what its vectors are kept by.
    public var name: String { "openai/" + model }

    public func embed(_ texts: [String]) async throws(EmbeddingModelError) -> [[Float]] {
        if Task.isCancelled { throw failure(.cancelled) }
        guard let key = keys.read() else { throw failure(.noKey) }
        guard let session else {
            let own = boundedSession()
            defer { own.finishTasksAndInvalidate() }
            return try await embed(texts, key: key, over: own)
        }
        return try await embed(texts, key: key, over: session)
    }

    private func embed(_ texts: [String], key: String, over session: URLSession) async throws(EmbeddingModelError) -> [[Float]] {
        var vectors: [[Float]] = []
        vectors.reserveCapacity(texts.count)
        var start = 0
        while start < texts.count {
            let batch = Array(texts[start..<min(start + max(1, textsPerRequest), texts.count)])
            vectors += try await request(batch, key: key, over: session)
            start += batch.count
        }
        return vectors
    }

    /// The session `embed` makes when none is given, a call's own: every request on it bounded to `timeout`
    /// in all, answer and all, since the request's idle limit alone lets a reply that trickles in run for as
    /// long as it likes. Ephemeral. Public for a test to read its limits.
    public func boundedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        return URLSession(configuration: configuration)
    }

    private func request(_ texts: [String], key: String, over session: URLSession) async throws(EmbeddingModelError) -> [[Float]] {
        if Task.isCancelled { throw failure(.cancelled) }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest(for: texts, key: key))
        } catch {
            throw failure(Self.transportFailure(error))
        }
        if Task.isCancelled { throw failure(.cancelled) }
        guard let http = response as? HTTPURLResponse else { throw failure(.malformedResponse) }
        guard (200..<300).contains(http.statusCode) else { throw failure(Self.failure(status: http.statusCode, body: data, key: key)) }
        guard let vectors = Self.vectors(in: data, count: texts.count) else { throw failure(.malformedResponse) }
        return vectors
    }

    private func failure(_ failure: EmbeddingModelError.Failure) -> EmbeddingModelError {
        EmbeddingModelError(failure, provider: Self.provider)
    }

    // MARK: The request

    private struct Body: Encodable {
        var encoding_format = "base64"
        var input: [String]
        var model: String
    }

    /// What's sent, sorted keys: the model, the texts, and base64 for the numbers (little-endian `Float32`:
    /// exact, and a quarter the size of decimal text). No `dimensions`, so the vectors are the model's own
    /// 3,072 numbers.
    func body(for texts: [String]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // A struct of strings always encodes.
        return (try? encoder.encode(Body(input: texts, model: model))) ?? Data()
    }

    func urlRequest(for texts: [String], key: String) -> URLRequest {
        var urlRequest = URLRequest(url: Self.endpoint, timeoutInterval: timeout)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
        urlRequest.httpBody = body(for: texts)
        return urlRequest
    }

    // MARK: The answer

    private struct Reply: Decodable {
        struct Item: Decodable {
            var index: Int
            var embedding: String
        }
        var data: [Item]
    }

    /// The vectors in a reply, each by its `index`: nil unless every index `0..<count` is there exactly
    /// once, and every vector is the same non-zero length, of finite numbers (base64 of `Float32`,
    /// little-endian).
    static func vectors(in data: Data, count: Int) -> [[Float]]? {
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data), reply.data.count == count else { return nil }
        var vectors = [[Float]?](repeating: nil, count: count)
        for item in reply.data {
            guard (0..<count).contains(item.index), vectors[item.index] == nil, let bytes = Data(base64Encoded: item.embedding),
                  !bytes.isEmpty, bytes.count % 4 == 0 else { return nil }
            var vector = [Float](repeating: 0, count: bytes.count / 4)
            for i in vector.indices {
                let p = bytes.startIndex + 4 * i
                let value = Float(bitPattern: UInt32(bytes[p]) | UInt32(bytes[p + 1]) << 8 | UInt32(bytes[p + 2]) << 16 | UInt32(bytes[p + 3]) << 24)
                guard value.isFinite else { return nil }
                vector[i] = value
            }
            vectors[item.index] = vector
        }
        let all = vectors.compactMap { $0 }
        guard all.count == count, let length = all.first?.count, all.allSatisfy({ $0.count == length }) else { return nil }
        return all
    }

    private struct Refusal: Decodable {
        struct Detail: Decodable {
            var message: String?
            var code: String?
        }
        var error: Detail?
    }

    /// An error status as a failure, with the service's message where it says one: shown to a person
    /// (`EmbeddingModelError.message`), so the key is taken out first, whole and, as OpenAI's refusals
    /// quote a masked one (`sk-proj-****abcd`), in pieces. The body of a 401 or a 403 is never read.
    static func failure(status: Int, body: Data, key: String) -> EmbeddingModelError.Failure {
        switch status {
        case 401, 403: return .unauthorized
        case 503: return .overloaded
        default:
            let refusal = try? JSONDecoder().decode(Refusal.self, from: body)
            let message = scrubbed(refusal?.error?.message ?? "", key: key)
            // A 429 that says the quota is spent is about the money, not the rate.
            if status == 429 {
                guard refusal?.error?.code == "insufficient_quota" else { return .rateLimited }
                return .server(status: 429, message: LanguageModelError.firstSentence(of: message))
            }
            return .server(status: status, message: message.isEmpty ? nil : message)
        }
    }

    /// `text` with the key, and anything that looks like one, replaced by `…`.
    static func scrubbed(_ text: String, key: String) -> String {
        var text = key.isEmpty ? text : text.replacingOccurrences(of: key, with: "…")
        text = text.replacingOccurrences(of: #"sk-[A-Za-z0-9_*.\-]{4,}"#, with: "…", options: .regularExpression)
        return text
    }

    static func transportFailure(_ error: any Error) -> EmbeddingModelError.Failure {
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

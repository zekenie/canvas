import Canvas
import CanvasRPC
import Foundation
import LanguageModels

/// Where the TypeSafe API key is kept, by default
/// `~/Library/Application Support/InfiniteCanvas/typesafe-api-key`, beside Anthropic's: the key
/// alone, in a file only its owner can read (`KeyFile`). Never print, log or show what it reads.
public struct TypeSafeKeyStore: KeyFile, Equatable {
    /// The file.
    public let url: URL

    /// A store in any file (tests use a temporary directory).
    public init(url: URL) { self.url = url }

    /// The app's: `~/Library/Application Support/InfiniteCanvas/typesafe-api-key`.
    public static var standard: TypeSafeKeyStore { TypeSafeKeyStore(url: applicationSupport("typesafe-api-key")) }
}

/// TypeSafe's Jev, over its API (`POST https://api.typesafe.ai/v1/systemone`), straight from the
/// app: one request per call, each question a `noul` (a probability of yes), no retries (a caller
/// that wants one offers it: `DecisionModelError.isTransient`). The key is read from `keys` at every
/// call, so a key saved in Settings works at once, and one removed stops working at once.
public struct JevModel: DecisionModel {
    /// TypeSafe's latest Jev: the answer says which it was (`DecisionAnswers.model`).
    public static let latest = "jev-latest"
    public static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    /// What its errors call it.
    public static let provider = "TypeSafe"

    /// The model asked.
    public let model: String
    /// Where the key is read from.
    public let keys: TypeSafeKeyStore
    /// Seconds to wait for an answer: Jev answers in a fifth of a second, typically.
    public let timeout: TimeInterval
    /// Nil for `URLSession.shared`, taken at the first call.
    let session: URLSession?

    /// `session` is for tests, which stub the network with a `URLProtocol`.
    public init(model: String = JevModel.latest, keys: TypeSafeKeyStore = .standard, timeout: TimeInterval = 30,
                session: URLSession? = nil) {
        self.model = model
        self.keys = keys
        self.timeout = timeout
        self.session = session
    }

    public var name: String { model }
    public var cutoffs: DecisionCutoffs { .standard }

    public func decide(_ request: DecisionRequest) async throws(DecisionModelError) -> DecisionAnswers {
        if Task.isCancelled { throw failure(.cancelled) }
        guard let key = keys.read() else { throw failure(.noKey) }
        let urlRequest = self.urlRequest(for: request, key: key)
        let data: Data, response: URLResponse
        do {
            (data, response) = try await (session ?? .shared).data(for: urlRequest)
        } catch {
            throw failure(Self.transportFailure(error))
        }
        if Task.isCancelled { throw failure(.cancelled) }
        guard let http = response as? HTTPURLResponse else { throw failure(.malformedResponse) }
        guard (200..<300).contains(http.statusCode) else { throw failure(Self.failure(status: http.statusCode, body: data, key: key)) }
        guard let answers = Self.answers(data, questions: request.questions) else { throw failure(.malformedResponse) }
        return answers
    }

    private func failure(_ failure: DecisionModelError.Failure) -> DecisionModelError {
        DecisionModelError(failure, provider: Self.provider)
    }

    // MARK: The request

    /// What's sent: the state as it is, the model, and each question by its id, a `noul` whose
    /// instructions are the preface and what it asks, its criteria what a yes and a no mean.
    func body(for request: DecisionRequest) -> JSONValue {
        var questions: [String: JSONValue] = [:]
        for question in request.questions {
            questions[question.id] = ["type": "noul", "instructions": .string(request.text(of: question)),
                                      "criteria": ["true": .string(question.yes), "false": .string(question.no)]]
        }
        return ["state": request.state, "model": .string(model), "questions": .object(questions)]
    }

    func urlRequest(for request: DecisionRequest, key: String) -> URLRequest {
        var urlRequest = URLRequest(url: Self.endpoint, timeoutInterval: timeout)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
        urlRequest.httpBody = Data(body(for: request).compactText.utf8)
        return urlRequest
    }

    // MARK: The answer

    /// The answers in a reply: each question's `noul`, by its id (one missing is left out); nil for
    /// a reply that isn't one (no `answers` object, or a `noul` that isn't a number from 0 to 1).
    static func answers(_ data: Data, questions: [DecisionQuestion]) -> DecisionAnswers? {
        guard let reply = try? JSON(data: data), let answers = reply["answers"]?.objectValue else { return nil }
        var yes: [String: Double] = [:]
        for question in questions {
            guard let answer = answers[question.id] else { continue }
            guard let probability = answer["noul"]?.numberValue, (0...1).contains(probability) else { return nil }
            yes[question.id] = probability
        }
        let usage = DecisionUsage(inputTokens: reply["usage"]?["input_tokens"]?.intValue ?? 0,
                                  outputTokens: reply["usage"]?["output_tokens"]?.intValue ?? 0)
        return DecisionAnswers(model: reply["model"]?.stringValue ?? latest, yes: yes, usage: usage)
    }

    /// An error status as a failure, with the service's message where it says one: shown to a person
    /// (`DecisionModelError.message`), so the key, were the service ever to say it, is taken out
    /// first.
    static func failure(status: Int, body: Data, key: String) -> DecisionModelError.Failure {
        switch status {
        case 401, 403: return .unauthorized
        case 429: return .rateLimited
        case 503, 529: return .overloaded
        default: return .server(status: status, message: scrubbed(message(in: body) ?? "", key: key))
        }
    }

    /// What an error reply says: its `error`'s message, or its `error`, `detail` or `message` as text.
    static func message(in body: Data) -> String? {
        guard let reply = try? JSON(data: body) else { return nil }
        return reply["error"]?["message"]?.stringValue ?? reply["error"]?.stringValue ?? reply["detail"]?.stringValue
            ?? reply["message"]?.stringValue
    }

    /// `text` with every occurrence of `key` replaced by `…`.
    static func scrubbed(_ text: String, key: String) -> String {
        key.isEmpty ? text : text.replacingOccurrences(of: key, with: "…")
    }

    static func transportFailure(_ error: any Error) -> DecisionModelError.Failure {
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

import Foundation
import LanguageModels

// An embedding model, as the app's plugins see it: texts in, one vector of numbers for each out, or an
// error with a short message a person can read. Nothing here knows which model answers, or what the
// vectors are used for; `OpenAIEmbeddingModel` is the app's and `ScriptedEmbeddingModel` answers tests.

/// Why an embedding model didn't answer, naming whose model it is. `message` names it in a few words a
/// person reads beside what can be done about it (Open Settings… for a key, Retry for the rest); none
/// of them ever holds the key, or a piece of it.
public struct EmbeddingModelError: Error, Equatable, Sendable {
    public enum Failure: Equatable, Sendable {
        /// No API key is saved (Settings…).
        case noKey
        /// The key was refused: wrong, revoked or disabled.
        case unauthorized
        /// Too many requests just now (429).
        case rateLimited
        /// The service is overloaded.
        case overloaded
        /// Any other error status, with the service's own message where it said one, with the key taken
        /// out.
        case server(status: Int, message: String?)
        /// The service couldn't be reached (offline, no route), with the system's description, which
        /// `message` leaves out.
        case network(String)
        /// No answer came in the time allowed.
        case timedOut
        /// An answer came back that isn't one.
        case malformedResponse
        /// The task asking was cancelled.
        case cancelled
    }

    public var failure: Failure
    /// Whose model it is, as a person knows it: "OpenAI".
    public var provider: String

    public init(_ failure: Failure, provider: String) {
        self.failure = failure
        self.provider = provider
    }

    /// What went wrong, in a fragment with no period: the state, never what to do about it (the button
    /// beside it says that).
    public var message: String {
        switch failure {
        case .noKey: "No \(provider) key"
        case .unauthorized: "\(provider) key rejected"
        case .rateLimited: "Rate limited"
        case .overloaded: "\(provider) overloaded"
        case let .server(status, message):
            status < 500 ? LanguageModelError.firstSentence(of: message ?? "") ?? "\(provider) error \(status)" : "\(provider) error \(status)"
        case .network: "Can’t reach \(provider)"
        case .timedOut: "Timed out"
        case .malformedResponse: "Unusable answer"
        case .cancelled: "Cancelled"
        }
    }

    /// Whether the same request may well work if tried again later: too many requests, overloaded, the
    /// service's own failure (5xx), the network, or a wait too long.
    public var isTransient: Bool {
        switch failure {
        case .rateLimited, .overloaded, .network, .timedOut: true
        case let .server(status, _): status >= 500
        case .noKey, .unauthorized, .malformedResponse, .cancelled: false
        }
    }

    /// Whether the way out is Settings: no key saved, or the key saved refused.
    public var needsKey: Bool { failure == .noKey || failure == .unauthorized }
}

extension EmbeddingModelError: LocalizedError {
    public var errorDescription: String? { message }
}

/// Something that turns texts into vectors: OpenAI's text-embedding-3-large over the network in the app
/// (`OpenAIEmbeddingModel`), a scripted double in tests (`ScriptedEmbeddingModel`). Plugins reach the
/// registry's through `Embeddings` (EmbeddingModelsPlugin), which keeps what a model answered, never
/// by making one.
public protocol EmbeddingModel: Sendable {
    /// Which model is asked, as its provider and its name ("openai/text-embedding-3-large"): what
    /// vectors kept are kept under (`EmbeddingMemory`), so another model asks again. Read from any
    /// thread.
    var name: String { get }
    /// How many texts one request takes: `Embeddings` asks in chunks this big, and keeps each chunk's
    /// vectors as it lands. A model's `embed` given more splits them itself.
    var textsPerRequest: Int { get }
    /// The vector of each text, in the order of `texts`. Cancelling the task asking throws
    /// `.cancelled`.
    func embed(_ texts: [String]) async throws(EmbeddingModelError) -> [[Float]]
}

import Foundation

// A language model, as the app's plugins see it: a request (a system prompt and a conversation) in,
// a response (text) out, or an error with a short message a person can read. Nothing here knows
// which model answers, or what a plugin asks it for; `AnthropicModel` is the app's, and
// `ScriptedLanguageModel` answers tests.

/// One turn of a conversation: what the user said, or what the model answered.
public struct ModelMessage: Equatable, Sendable {
    public enum Role: String, Equatable, Sendable {
        case user, assistant
    }

    public var role: Role
    public var text: String

    public init(role: Role, text: String) {
        self.role = role
        self.text = text
    }

    public static func user(_ text: String) -> ModelMessage { ModelMessage(role: .user, text: text) }
    public static func assistant(_ text: String) -> ModelMessage { ModelMessage(role: .assistant, text: text) }
}

/// What to ask a model.
public struct ModelRequest: Equatable, Sendable {
    /// The instructions the conversation runs under: the task, its rules, the answer's format.
    /// Nil (or empty) for none.
    public var system: String?
    /// The conversation, oldest first: the user's turn first, then the two alternating.
    public var messages: [ModelMessage]
    /// The most the answer may run to, in tokens; past it, it's cut off (`StopReason.maxTokens`).
    public var maxTokens: Int
    /// 0 for the most predictable answers, 1 for the most varied; nil for the model's default.
    public var temperature: Double?
    /// Text that ends the answer where the model writes it (it isn't included).
    public var stopSequences: [String]

    public init(system: String? = nil, messages: [ModelMessage], maxTokens: Int = 1024, temperature: Double? = nil,
                stopSequences: [String] = []) {
        self.system = system
        self.messages = messages
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.stopSequences = stopSequences
    }
}

/// Why a model stopped writing. Open-ended, as the API's list grows; compare with the constants.
public struct StopReason: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// It finished what it had to say.
    public static let endTurn = StopReason(rawValue: "end_turn")
    /// It ran into `maxTokens`: the text is cut off.
    public static let maxTokens = StopReason(rawValue: "max_tokens")
    /// It wrote one of `stopSequences`.
    public static let stopSequence = StopReason(rawValue: "stop_sequence")
    /// It declined to answer.
    public static let refusal = StopReason(rawValue: "refusal")

    public var description: String { rawValue }
}

/// A model's answer.
public struct ModelResponse: Equatable, Sendable {
    /// What it wrote (its text blocks, joined).
    public var text: String
    public var stopReason: StopReason
    public var inputTokens: Int
    public var outputTokens: Int

    public init(text: String, stopReason: StopReason = .endTurn, inputTokens: Int = 0, outputTokens: Int = 0) {
        self.text = text
        self.stopReason = stopReason
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

/// Why a model didn't answer. `message` says so in a line a person can read (a status line, an
/// alert); none of them ever holds the key.
public enum LanguageModelError: Error, Equatable, Sendable {
    /// No API key is saved (Settings…).
    case noKey
    /// The key was refused (401): wrong, revoked or disabled.
    case unauthorized
    /// Too many requests just now (429).
    case rateLimited
    /// The service is overloaded (529).
    case overloaded
    /// Any other error status, with the service's own message (possibly empty).
    case server(status: Int, message: String)
    /// The service couldn't be reached (offline, no route), with the system's description.
    case network(String)
    /// No answer came in the time allowed (`AnthropicModel`'s, which grows with `maxTokens`).
    case timedOut
    /// An answer came back that isn't one.
    case malformedResponse
    /// The task asking was cancelled.
    case cancelled

    /// A short line for a person.
    public var message: String {
        switch self {
        case .noKey: "Add your Anthropic API key in Settings…"
        case .unauthorized: "Anthropic didn't accept the API key. Check it in Settings…"
        case .rateLimited: "Too many requests to Anthropic just now. Try again in a moment."
        case .overloaded: "Anthropic is overloaded. Try again in a moment."
        case let .server(status, message):
            message.isEmpty ? "Anthropic answered with an error (\(status))." : "Anthropic answered with an error (\(status)): \(message)"
        case let .network(description): description.isEmpty ? "Couldn't reach Anthropic." : "Couldn't reach Anthropic. \(description)"
        case .timedOut: "Anthropic took too long to answer. Try again in a moment."
        case .malformedResponse: "Anthropic's answer couldn't be read."
        case .cancelled: "Cancelled."
        }
    }

    /// Whether the same request may well work if tried again later: too many requests, overloaded,
    /// the service's own failure (5xx), the network, or a wait too long.
    public var isTransient: Bool {
        switch self {
        case .rateLimited, .overloaded, .network, .timedOut: true
        case let .server(status, _): status >= 500
        case .noKey, .unauthorized, .malformedResponse, .cancelled: false
        }
    }
}

extension LanguageModelError: LocalizedError {
    public var errorDescription: String? { message }
}

/// Something that answers requests: Claude over the network in the app (`AnthropicModel`), a
/// scripted double in tests (`ScriptedLanguageModel`). Plugins reach the editor's through
/// `editor.languageModel` (LanguageModelsPlugin), never by making one.
public protocol LanguageModel: Sendable {
    /// Asks, and waits for the answer. Cancelling the task asking throws `.cancelled`.
    func respond(to request: ModelRequest) async throws(LanguageModelError) -> ModelResponse
}

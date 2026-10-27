import Foundation

// A language model, as the app's plugins see it: a request (a system prompt and a conversation) in,
// a response (text) out, or an error with a short message a person can read. Nothing here knows
// which model answers, or what a plugin asks it for; `SignedInModel` is the app's (Claude with an
// API key, `AnthropicModel`, or through the person's Claude Code, `ClaudeCodeModel`), and
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
    /// Which model answers, by its id (`claude-sonnet-5-5`); nil for the one the editor's model is
    /// (`AnthropicModel.model`). For a plugin whose task one model does better than the app's.
    public var model: String?
    /// How much the model spends on its answer, thinking included (`low`, `medium`, `high`,
    /// `xhigh`, `max`); nil for its default. Only for a model that takes it: Haiku 4.5 refuses a
    /// request that says one.
    public var effort: String?
    /// Whether the service may answer with another model when this one declines (a refusal): nil
    /// for never, so a refusal comes back as one. Only for a model the service falls back from
    /// (Sonnet 5.5).
    public var fallbacks: ModelFallbacks?

    public init(system: String? = nil, messages: [ModelMessage], maxTokens: Int = 1024, temperature: Double? = nil,
                stopSequences: [String] = [], model: String? = nil, effort: String? = nil, fallbacks: ModelFallbacks? = nil) {
        self.system = system
        self.messages = messages
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.stopSequences = stopSequences
        self.model = model
        self.effort = effort
        self.fallbacks = fallbacks
    }
}

/// Which model the service answers with when the one asked declines.
public enum ModelFallbacks: String, Equatable, Sendable {
    /// The one the service recommends for why it declined (Anthropic's server-side fallback, its
    /// `"default"` form): Sonnet 5.5's cyber and frontier-LLM declines go to Sonnet 5, and the rest
    /// still come back as refusals.
    case `default`
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

/// Why a model didn't answer. `message` names it in a few words a person reads beside what can be
/// done about it (a status line with Retry or Open Settings…, Settings' Test); none of them ever
/// holds a key or a token.
public enum LanguageModelError: Error, Equatable, Sendable {
    /// Not signed in (Settings…): no way chosen, no key saved, or Claude Code not found, signed out
    /// or its sign-in refused.
    case notSignedIn
    /// The key was refused (401): wrong, revoked or disabled.
    case unauthorized
    /// Too many requests just now (429).
    case rateLimited
    /// The service is overloaded (529).
    case overloaded
    /// Any other error status, with the service's own message (possibly empty).
    case server(status: Int, message: String)
    /// The service couldn't be reached (offline, no route), with the system's description, which
    /// `message` leaves out.
    case network(String)
    /// No answer came in the time allowed (the model's, which grows with `maxTokens`).
    case timedOut
    /// An answer came back that isn't one.
    case malformedResponse
    /// Claude Code failed in a way none of the others says, in its own words (possibly empty).
    case claudeCode(String)
    /// The task asking was cancelled.
    case cancelled

    /// What went wrong, in a fragment with no period: the state, never what to do about it (the
    /// button beside it says that). The service's failure is its status (a 5xx says nothing a person
    /// can use); a request it refused (another 4xx) is its message's first sentence, which says why
    /// (a credit balance too low), or its status when it sent none.
    public var message: String {
        switch self {
        case .notSignedIn: "Not signed in"
        case .unauthorized: "API key rejected"
        case .rateLimited: "Rate limited"
        case .overloaded: "Anthropic overloaded"
        case let .server(status, message):
            status < 500 ? Self.firstSentence(of: message) ?? "Anthropic error \(status)" : "Anthropic error \(status)"
        case .network: "Can’t reach Anthropic"
        case .timedOut: "Timed out"
        case .malformedResponse: "Unusable answer"
        case let .claudeCode(words): Self.firstSentence(of: words) ?? "Claude Code failed"
        case .cancelled: "Cancelled"
        }
    }

    /// `text` up to its first sentence's end (`. `), trimmed, without a period at its end; nil if
    /// that leaves nothing.
    static func firstSentence(of text: String) -> String? {
        var sentence = text.range(of: ". ").map { String(text[..<$0.lowerBound]) } ?? text
        sentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        while sentence.hasSuffix(".") { sentence.removeLast() }
        sentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        return sentence.isEmpty ? nil : sentence
    }

    /// Whether the same request may well work if tried again later: too many requests, overloaded,
    /// the service's own failure (5xx), the network, or a wait too long.
    public var isTransient: Bool {
        switch self {
        case .rateLimited, .overloaded, .network, .timedOut: true
        case let .server(status, _): status >= 500
        case .notSignedIn, .unauthorized, .malformedResponse, .claudeCode, .cancelled: false
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

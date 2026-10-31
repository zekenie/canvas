import Canvas
import CanvasRPC
import Foundation
import LanguageModels

// A decision model, as the app's plugins see it: a state and yes-or-no questions about it in, each
// question's probability of yes out, or an error with a short message a person can read. Nothing
// here knows which model answers, or what a plugin asks it about; `JevModel` is the app's,
// `LanguageDecisionModel` asks a language model in words, and `ScriptedDecisionModel` answers tests.

/// A question a decision model answers yes or no.
public struct DecisionQuestion: Equatable, Sendable {
    /// Its name in the request, which its answer comes back under.
    public var id: String
    /// What's asked, in a sentence or a paragraph.
    public var asks: String
    /// What a yes means, and what a no means, in a few words ("Flag it", "Don't flag it"): a model
    /// that answers in words answers with these, so a question asked as "does it fail" is never
    /// answered as if "yes" meant it holds.
    public var yes: String
    public var no: String

    public init(id: String, asks: String, yes: String = "Yes", no: String = "No") {
        self.id = id
        self.asks = asks
        self.yes = yes
        self.no = no
    }
}

/// What to ask a decision model: what the questions are about, and the questions.
public struct DecisionRequest: Equatable, Sendable {
    /// Everything the model may judge from, as JSON.
    public var state: JSONValue
    /// What every question shares, said before them (the rules a shape is checked against); nil for
    /// nothing. A model that takes one question at a time reads it before each.
    public var preface: String?
    /// The questions, each answered on its own.
    public var questions: [DecisionQuestion]

    public init(state: JSONValue, preface: String? = nil, questions: [DecisionQuestion]) {
        self.state = state
        self.preface = preface
        self.questions = questions
    }

    /// A question's whole text: the preface, then what it asks.
    public func text(of question: DecisionQuestion) -> String {
        guard let preface, !preface.isEmpty else { return question.asks }
        return preface + "\n" + question.asks
    }
}

/// What a decision model spent on an answer.
public struct DecisionUsage: Equatable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

/// A decision model's answers.
public struct DecisionAnswers: Equatable, Sendable {
    /// Which model answered, with its version where it says one ("jev-1.14.0"): an answer kept is
    /// kept under it, so a new model asks again.
    public var model: String
    /// Each question's probability of yes, from 0 to 1, by its id; a question the model left
    /// unanswered isn't here.
    public var yes: [String: Double]
    public var usage: DecisionUsage

    public init(model: String, yes: [String: Double], usage: DecisionUsage = DecisionUsage()) {
        self.model = model
        self.yes = yes
        self.usage = usage
    }
}

/// What an answer says: yes, no, or neither clearly enough to act on.
public enum DecisionVerdict: String, Equatable, Sendable {
    case yes, no, unsure
}

/// Where a model's probabilities turn into verdicts: a yes at or above `yes`, a no at or below `no`,
/// unsure between. A model's own, set by its live evaluation (`scripts/language-rules`).
public struct DecisionCutoffs: Equatable, Sendable {
    public var yes: Double
    public var no: Double

    public init(yes: Double, no: Double) {
        self.yes = yes
        self.no = no
    }

    /// 0.7 and 0.3: where Jev's and Haiku's answers to rules separated cleanly on the prototype's
    /// boards (2026-10-27), with few left between.
    public static let standard = DecisionCutoffs(yes: 0.7, no: 0.3)

    public func verdict(_ probability: Double) -> DecisionVerdict {
        probability >= yes ? .yes : probability <= no ? .no : .unsure
    }
}

/// Why a decision model didn't answer, naming whose model it is. `message` names it in a few words a
/// person reads beside what can be done about it (Open Settings… for a key, Retry for the rest);
/// none of them ever holds the key.
public struct DecisionModelError: Error, Equatable, Sendable {
    public enum Failure: Equatable, Sendable {
        /// No API key is saved (Settings…).
        case noKey
        /// Not signed in to the service a language model is asked through (Settings…): no way chosen,
        /// no key saved, or Claude Code missing, signed out or refused.
        case notSignedIn
        /// The key was refused: wrong, revoked or disabled.
        case unauthorized
        /// Too many requests just now (429).
        case rateLimited
        /// The service is overloaded.
        case overloaded
        /// Any other error status, with the service's own message (possibly empty).
        case server(status: Int, message: String)
        /// The service couldn't be reached (offline, no route), with the system's description, which
        /// `message` leaves out.
        case network(String)
        /// No answer came in the time allowed.
        case timedOut
        /// An answer came back that isn't one.
        case malformedResponse
        /// The task asking was cancelled.
        case cancelled
        /// A failure the service said in its own words that none of the others says (Claude Code's,
        /// possibly empty).
        case other(String)
    }

    public var failure: Failure
    /// Whose model it is, as a person knows it: "TypeSafe", "Anthropic".
    public var provider: String

    public init(_ failure: Failure, provider: String) {
        self.failure = failure
        self.provider = provider
    }

    /// The same failure a language model had, said as `provider`'s.
    public init(_ error: LanguageModelError, of provider: String) {
        let failure: Failure = switch error {
        case .notSignedIn: .notSignedIn
        case .unauthorized: .unauthorized
        case .rateLimited: .rateLimited
        case .overloaded: .overloaded
        case let .server(status, message): .server(status: status, message: message)
        case let .network(description): .network(description)
        case .timedOut: .timedOut
        case .malformedResponse: .malformedResponse
        case .cancelled: .cancelled
        case let .claudeCode(words): .other(words)
        }
        self.init(failure, provider: provider)
    }

    /// What went wrong, in a fragment with no period: the state, never what to do about it (the
    /// button beside it says that).
    public var message: String {
        switch failure {
        case .noKey: "No \(provider) key"
        case .notSignedIn: "Not signed in"
        case .unauthorized: "\(provider) key rejected"
        case .rateLimited: "Rate limited"
        case .overloaded: "\(provider) overloaded"
        case let .server(status, message):
            status < 500 ? LanguageModelError.firstSentence(of: message) ?? "\(provider) error \(status)" : "\(provider) error \(status)"
        case .network: "Can’t reach \(provider)"
        case .timedOut: "Timed out"
        case .malformedResponse: "Unusable answer"
        case .cancelled: "Cancelled"
        case let .other(words): LanguageModelError.firstSentence(of: words) ?? "\(provider) failed"
        }
    }

    /// Whether the same request may well work if tried again later: too many requests, overloaded,
    /// the service's own failure (5xx), the network, or a wait too long.
    public var isTransient: Bool {
        switch failure {
        case .rateLimited, .overloaded, .network, .timedOut: true
        case let .server(status, _): status >= 500
        case .noKey, .notSignedIn, .unauthorized, .malformedResponse, .cancelled, .other: false
        }
    }

    /// Whether the way out is Settings: no key saved, not signed in, or the key saved refused.
    public var needsKey: Bool { failure == .noKey || failure == .notSignedIn || failure == .unauthorized }
}

extension DecisionModelError: LocalizedError {
    public var errorDescription: String? { message }
}

/// Something that answers yes-or-no questions about a state with probabilities: TypeSafe's Jev over
/// the network in the app (`JevModel`), a language model answering in words
/// (`LanguageDecisionModel`), a scripted double in tests (`ScriptedDecisionModel`). Plugins reach the
/// editor's through `editor.decisionModel` (DecisionModelsPlugin), never by making one.
public protocol DecisionModel: Sendable {
    /// Which model is asked, as its requests name it ("jev-latest"): what answers kept are kept under
    /// (`DecisionMemory`).
    var name: String { get }
    /// Where this model's answers turn into verdicts.
    var cutoffs: DecisionCutoffs { get }
    /// Asks every question, and waits for the answers. Cancelling the task asking throws
    /// `.cancelled`.
    func decide(_ request: DecisionRequest) async throws(DecisionModelError) -> DecisionAnswers
}

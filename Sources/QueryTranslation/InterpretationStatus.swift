import LanguageModels
import QueryLanguage

/// What a person is told of words being turned into a query, wherever they are (a reference's pill and panel, a
/// rule's chips, `/query`'s bar): one set of words and actions for every state. A host's own words (what a query it
/// stores found) are its own.
public enum InterpretationStatus: Equatable, Sendable {
    /// Resting before the model is asked, or asking it.
    case interpreting
    /// Nothing to ask with: no queries or no model in this app.
    case unavailable
    /// Not signed in to Claude, or the key there was refused: Settings is where that's mended.
    case notSignedIn
    case keyRejected
    /// The model failed in a way asking again may mend, in its own words ("Rate limited", "Can’t reach Anthropic",
    /// "Timed out").
    case model(String)
    /// The model declined, or said no query can say it.
    case noQuery
    /// The model's query, and its second, were refused.
    case unusable

    /// What a person can do about it.
    public enum Action: Equatable, Sendable {
        /// Ask again.
        case retry
        /// Open Settings, where a sign-in is mended.
        case openSettings
    }

    /// How a translation failed, as a person is told it; nil for a cancellation, which says nothing.
    public init?(_ error: QueryTranslationError) {
        switch error {
        case .cancelled: return nil
        case .noQueries, .noModel: self = .unavailable
        case .model(.notSignedIn, _): self = .notSignedIn
        case .model(.unauthorized, _): self = .keyRejected
        case .model(let error, _): self = .model(error.message)
        case .declined, .unanswerable: self = .noQuery
        case .unusable: self = .unusable
        // The engine refused something no second try mends (a closed file, no Topology): in its own words.
        case .refused(let refusal): self = .model(refusal.message)
        case .tooSlow: self = .model(LanguageModelError.timedOut.message)
        }
    }

    /// What it says.
    public var words: String {
        switch self {
        case .interpreting: InterpretationWords.interpreting
        case .unavailable: InterpretationWords.unavailable
        case .notSignedIn: InterpretationWords.notSignedIn
        case .keyRejected: InterpretationWords.keyRejected
        case .model(let message): message
        case .noQuery: InterpretationWords.noQuery
        case .unusable: InterpretationWords.unusable
        }
    }

    /// What a person can do about it: Settings where a sign-in is missing or a key refused, else ask again; nothing while it's
    /// under way, or with nothing to ask with.
    public var action: Action? {
        switch self {
        case .interpreting, .unavailable: nil
        case .notSignedIn, .keyRejected: .openSettings
        case .model, .noQuery, .unusable: .retry
        }
    }

    /// Whether it's under way (a spinner where its symbol goes).
    public var isBusy: Bool { self == .interpreting }
}

/// The words `InterpretationStatus` says, and its actions' titles.
public enum InterpretationWords {
    public static let interpreting = "Interpreting…"
    public static let unavailable = "Unavailable"
    public static let notSignedIn = "Not signed in"
    public static let keyRejected = "Key rejected"
    public static let noQuery = "No query for these words"
    public static let unusable = "Unusable answer"
    public static let retry = "Retry"
    public static let openSettings = "Open Settings…"
    /// Under rows of what a query found, past the most a host lists.
    public static func more(_ count: Int) -> String { "and \(count) more" }
    /// The line under words (`QueryPreview`): what it was asked for, nothing found, its buttons, the query box's name.
    public static func sample(_ name: String) -> String { "for \(name)" }
    public static let findsNothing = "Finds nothing"
    public static let editWords = "Edit Words"
    public static let interpret = "Interpret"
    public static let query = "Query"
    public static let previousSample = "Previous Sample"
    public static let nextSample = "Next Sample"
}

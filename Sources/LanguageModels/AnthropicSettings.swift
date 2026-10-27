import AppKit
import Foundation
import Observation

extension Notification.Name {
    /// Posted on the main thread when the sign-in changes in Settings: the API key saved, replaced
    /// or removed (`AnthropicKeySettings`), the way chosen (`SignInSettings`), or Claude Code signed
    /// in (`ClaudeCodeSettings`). What failed for want of a sign-in may go now, so a plugin that said
    /// so can try again by itself.
    public static let languageModelSignInDidChange = Notification.Name("LanguageModels.signInDidChange")
}

/// What the Settings window's Anthropic key does, apart from its view (so tests drive it
/// headlessly): save the key typed, remove the saved one, and test it with a tiny real call. Saving
/// and removing post `languageModelSignInDidChange`. Its status speaks only of a test and of what
/// failed: the field's prompt says whether a key is saved.
@MainActor
@Observable
public final class AnthropicKeySettings {
    public enum Status: Equatable, Sendable {
        case idle
        /// Saved, or removed: said by the field (its prompt) and Remove (enabled or not), not by the
        /// status, which has nothing to say (`statusText` is nil).
        case saved
        case removed
        case testing
        /// The test call was answered.
        case works
        /// Saving, removing or the test call failed: what went wrong, in a fragment, and the
        /// system's own words for it, if any, for the status's tooltip.
        case failed(String, detail: String? = nil)
    }

    /// What's typed in the field; cleared once saved. Never shown: the field is a secure one.
    /// Typing another clears what a test or a failure said: that was about the key before.
    public var draft = "" {
        didSet {
            guard draft != oldValue else { return }
            switch status {
            case .works, .failed: status = .idle
            case .idle, .saved, .removed, .testing: break
            }
        }
    }
    /// Whether a key is saved.
    public private(set) var hasKey: Bool
    public private(set) var status: Status = .idle {
        didSet {
            guard status != oldValue, let text = statusText else { return }
            announce(text)
        }
    }

    /// Says a status to whoever uses VoiceOver, as it changes (`statusText`): by default the app's
    /// announcement; a test sets it to hear what was said.
    @ObservationIgnored public var announce: @MainActor (String) -> Void = AnthropicKeySettings.announceToVoiceOver

    /// An announcement VoiceOver speaks at once.
    public static func announceToVoiceOver(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// Where the key is kept.
    public let keys: AnthropicKeyStore
    @ObservationIgnored private let model: any LanguageModel
    @ObservationIgnored private var testing: Task<Void, Never>?

    /// `model` is what Test asks: one that reads its key from `keys` (by default, Claude Haiku).
    public init(keys: AnthropicKeyStore, model: (any LanguageModel)? = nil) {
        self.keys = keys
        self.model = model ?? AnthropicModel(keys: keys)
        hasKey = keys.hasKey
    }

    /// The request Test sends: as small as a real call gets.
    public static let testRequest = ModelRequest(messages: [.user("Reply with the word OK.")], maxTokens: 5)

    public var canSave: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var canTest: Bool { (hasKey || canSave) && status != .testing }
    /// Not while a test runs: a key removed then can't be had back (Anthropic shows one only when
    /// it's made).
    public var canRemove: Bool { hasKey && status != .testing }

    /// Saves what's typed (trimmed) in place of the saved key, and clears the field.
    public func save() {
        guard canSave else { return }
        cancelTest()
        do {
            try keys.write(draft)
            draft = ""
            status = .saved
        } catch {
            status = .failed("Couldn’t save", detail: error.localizedDescription)
        }
        hasKey = keys.hasKey
        if status == .saved { NotificationCenter.default.post(name: .languageModelSignInDidChange, object: self) }
    }

    /// Removes the saved key; nothing while a test runs (`canRemove`).
    public func remove() {
        guard canRemove else { return }
        do {
            try keys.remove()
            status = .removed
        } catch {
            status = .failed("Couldn’t remove", detail: error.localizedDescription)
        }
        hasKey = keys.hasKey
        if status == .removed { NotificationCenter.default.post(name: .languageModelSignInDidChange, object: self) }
    }

    /// Saves what's typed, if anything, then asks the model something tiny with the saved key. A
    /// save that fails stops it there: the failure stays, and the key saved before isn't tested in
    /// its place. Whether a key is saved is read again with the outcome: a test that finds none
    /// (its file removed while Settings was open) leaves the field and Remove saying so too.
    public func test() {
        if canSave {
            save()
            guard status == .saved else { return }
        }
        guard hasKey, status != .testing else { return }
        status = .testing
        let model = model
        testing = Task {
            let outcome: Status
            do throws(LanguageModelError) {
                _ = try await model.respond(to: Self.testRequest)
                outcome = .works
            } catch {
                outcome = .failed(error.message)
            }
            guard !Task.isCancelled else { return }
            status = outcome
            hasKey = keys.hasKey
            testing = nil
        }
    }

    private func cancelTest() {
        testing?.cancel()
        testing = nil
        if status == .testing { status = .idle }
    }

    /// The status, as the line beside Test says it; nil when there's nothing to say (idle, and
    /// after a save or a removal, which the field says).
    public var statusText: String? {
        switch status {
        case .idle, .saved, .removed: nil
        case .testing: "Testing…"
        case .works: "Works"
        case let .failed(message, _): message
        }
    }

    /// The status's tooltip: the system's words for a failure to save or remove, else its text
    /// (which one line may cut short).
    public var statusHelp: String? {
        guard case let .failed(message, detail) = status else { return statusText }
        return detail ?? message
    }
}

import AppKit
import Foundation
import Observation
import SwiftUI

extension Notification.Name {
    /// Posted on the main thread when the API key is saved, replaced or removed in Settings
    /// (`AnthropicKeySettings`): what failed for want of a key may go now, so a plugin that said so
    /// can try again by itself.
    public static let languageModelKeyDidChange = Notification.Name("LanguageModels.keyDidChange")
}

/// What the Settings window's Anthropic key does, apart from its view (so tests drive it
/// headlessly): save the key typed, remove the saved one, and test it with a tiny real call. Saving
/// and removing post `languageModelKeyDidChange`. Its status speaks only of a test and of what
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
    public private(set) var status: Status = .idle

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
        if status == .saved { NotificationCenter.default.post(name: .languageModelKeyDidChange, object: self) }
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
        if status == .removed { NotificationCenter.default.post(name: .languageModelKeyDidChange, object: self) }
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

/// The Settings window's metrics. Points.
@MainActor
enum SettingsStyle {
    static let width: CGFloat = 480
    /// Between the buttons.
    static let buttonSpacing: CGFloat = 8
    /// The least room between the buttons and the status.
    static let statusGap: CGFloat = 12
    /// Between the status's symbol (or spinner) and its text.
    static let smallSpacing: CGFloat = 6
    /// The status's symbol or spinner: one width, so its text starts in one place.
    static let statusIconWidth: CGFloat = 16
}

/// The Settings window's content: the Anthropic API key (a secure field, Save, Remove, Test), and
/// where to get one. Where it's kept is the field's tooltip. The app hosts it (Infinite Canvas ›
/// Settings…, ⌘,), afresh each time the window opens.
public struct AnthropicSettingsView: View {
    @State private var settings: AnthropicKeySettings

    /// The key in `keys`, tested with `model` (by default, Claude Haiku reading `keys`).
    public init(keys: AnthropicKeyStore = .standard, model: (any LanguageModel)? = nil) {
        _settings = State(initialValue: AnthropicKeySettings(keys: keys, model: model))
    }

    /// Where keys are made.
    public static let consoleURL = URL(string: "https://console.anthropic.com/settings/keys")!

    /// The action that opens the app's Settings window, which the app answers (Infinite Canvas ›
    /// Settings…, ⌘,; CanvasUI's `BoardMenus.showSettings` is the same selector). A plugin that
    /// needs a key sends it up the responder chain with `showSettings()`.
    public static let showSettingsAction = NSSelectorFromString("showSettings:")

    /// Opens Settings, where the key is saved: `showSettingsAction`, sent up the responder chain.
    /// False if nothing answered it (no app around, as in tests).
    @discardableResult
    public static func showSettings() -> Bool {
        NSApplication.shared.sendAction(showSettingsAction, to: nil, from: nil)
    }

    /// The field's tooltip: where the key is kept (the path, never anything read from the file).
    static func storageHelp(_ keys: AnthropicKeyStore) -> String {
        "Saved in \((keys.url.path as NSString).abbreviatingWithTildeInPath)"
    }

    public var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                SecureField("Anthropic API key", text: $settings.draft, prompt: Text(settings.hasKey ? "Saved" : "sk-ant-…"))
                    .onSubmit { settings.save() }
                    .help(Self.storageHelp(settings.keys))
                HStack(spacing: SettingsStyle.buttonSpacing) {
                    Button("Save") { settings.save() }
                        .disabled(!settings.canSave)
                    Button("Remove") { settings.remove() }
                        .disabled(!settings.canRemove)
                    Spacer(minLength: SettingsStyle.statusGap)
                    statusLine
                    Button("Test") { settings.test() }
                        .disabled(!settings.canTest)
                        .help("Send a test request")
                }
            } footer: {
                Link("Get a key", destination: Self.consoleURL)
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsStyle.width)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// A test's progress or outcome, or a failure: its symbol (only the symbol takes the tone, as
    /// the detail panel's status lines do), then its text, on one line.
    @ViewBuilder private var statusLine: some View {
        if let text = settings.statusText {
            HStack(spacing: SettingsStyle.smallSpacing) {
                Group {
                    switch settings.status {
                    case .testing: ProgressView().controlSize(.small)
                    case .works: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    // The warning's tone, as the detail panel shows the same failures: red is kept
                    // for what's wrong in what someone made (a schema's errors).
                    default: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
                .frame(width: SettingsStyle.statusIconWidth)
                Text(text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .help(settings.statusHelp ?? text)
        }
    }
}

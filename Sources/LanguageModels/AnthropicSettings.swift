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

/// What the Settings window's Anthropic section does, apart from its view (so tests drive it
/// headlessly): save the key typed, remove the saved one, and test it with a tiny real call. Saving
/// and removing post `languageModelKeyDidChange`.
@MainActor
@Observable
public final class AnthropicKeySettings {
    public enum Status: Equatable, Sendable {
        case idle
        case saved
        case removed
        case testing
        /// The test call was answered.
        case works
        /// Saving, removing or the test call failed, and why.
        case failed(String)
    }

    /// What's typed in the field; cleared once saved. Never shown: the field is a secure one.
    public var draft = ""
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

    /// Saves what's typed (trimmed) in place of the saved key, and clears the field.
    public func save() {
        guard canSave else { return }
        cancelTest()
        do {
            try keys.write(draft)
            draft = ""
            status = .saved
        } catch {
            status = .failed("Couldn't save the key: \(error.localizedDescription)")
        }
        hasKey = keys.hasKey
        if status == .saved { NotificationCenter.default.post(name: .languageModelKeyDidChange, object: self) }
    }

    /// Removes the saved key.
    public func remove() {
        cancelTest()
        do {
            try keys.remove()
            status = .removed
        } catch {
            status = .failed("Couldn't remove the key: \(error.localizedDescription)")
        }
        hasKey = keys.hasKey
        if status == .removed { NotificationCenter.default.post(name: .languageModelKeyDidChange, object: self) }
    }

    /// Saves what's typed, if anything, then asks the model something tiny with the saved key.
    public func test() {
        if canSave { save() }
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
            testing = nil
        }
    }

    private func cancelTest() {
        testing?.cancel()
        testing = nil
        if status == .testing { status = .idle }
    }

    /// The status, as the line under the field says it; nil when there's nothing to say.
    public var statusText: String? {
        switch status {
        case .idle: nil
        case .saved: "Saved."
        case .removed: "Removed."
        case .testing: "Testing…"
        case .works: "The key works."
        case let .failed(message): message
        }
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
    /// Between the footer's lines, and the status's spinner and text.
    static let smallSpacing: CGFloat = 6
}

/// The Settings window's content: the Anthropic API key (a secure field, Save, Remove, Test),
/// where to make one, and where it's kept. The app hosts it (Infinite Canvas › Settings…, ⌘,).
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

    public var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                SecureField("API key", text: $settings.draft,
                            prompt: Text(settings.hasKey ? "Saved (paste another to replace it)" : "sk-ant-…"))
                    .onSubmit { settings.save() }
                HStack(spacing: SettingsStyle.buttonSpacing) {
                    Button("Save") { settings.save() }
                        .disabled(!settings.canSave)
                    Button("Remove") { settings.remove() }
                        .disabled(!settings.hasKey)
                    Spacer(minLength: SettingsStyle.statusGap)
                    statusLine
                    Button("Test") { settings.test() }
                        .disabled(!settings.canTest)
                        .help("Send Claude a tiny request with the saved key")
                }
            } header: {
                Text("Anthropic API key")
            } footer: {
                VStack(alignment: .leading, spacing: SettingsStyle.smallSpacing) {
                    Text("The app sends this key, with what it asks Claude, only to api.anthropic.com. It's saved in \((settings.keys.url.path as NSString).abbreviatingWithTildeInPath), which only you can read.")
                        .foregroundStyle(.secondary)
                    Link("Create a key at console.anthropic.com", destination: Self.consoleURL)
                }
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsStyle.width)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var statusLine: some View {
        if let text = settings.statusText {
            HStack(spacing: SettingsStyle.smallSpacing) {
                if settings.status == .testing { ProgressView().controlSize(.small) }
                Text(text)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .foregroundStyle(statusColor)
            }
            .font(.callout)
        }
    }

    private var statusColor: Color {
        switch settings.status {
        case .works: .green
        case .failed: .red
        default: .secondary
        }
    }
}

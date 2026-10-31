import AppKit
import Canvas
import Foundation
import SwiftUI

/// The Settings window's metrics. Points.
@MainActor
enum SettingsStyle {
    /// What the sign-in's pane is called in the Settings window.
    static let claudePane = "Claude"
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

/// The Settings window's content: how the app signs in to Claude, one of two ways. Claude Code: whom
/// the app is signed in as, Sign In… (Anthropic's page, in the browser), Cancel while the browser
/// waits, Sign Out and Test, and Install Claude Code when there's none. An API key: the key's rows
/// every key's pane has (`KeyRows`), and where to get one. The app hosts it (Infinite Canvas ›
/// Settings…, ⌘,), afresh each time the window opens; Claude Code is asked again whenever the app
/// comes forward (after it's been installed). The key's field takes the keyboard as it appears when
/// the window says this is its first pane (`settingsPaneTakesFocus`).
public struct AnthropicSettingsView: View {
    @State private var settings: SignInSettings
    @FocusState private var keyFieldFocused: Bool
    @Environment(\.settingsPaneTakesFocus) private var takesFocus
    /// True while a key's field has the keyboard, this pane's or another's (`KeyRows`).
    @FocusedValue(\.typingKey) private var typingKey

    /// The ways `model` signs in; `keyModel` and `claudeCodeModel` are what each way's Test asks (by
    /// default, the model's own for that way).
    public init(model: SignedInModel = SignedInModel(), keyModel: (any LanguageModel)? = nil, claudeCodeModel: (any LanguageModel)? = nil) {
        _settings = State(initialValue: SignInSettings(model: model, keyModel: keyModel, claudeCodeModel: claudeCodeModel))
    }

    /// Where keys are made.
    public static var consoleURL: URL { KeyService.anthropic.console }
    /// The request the key's Test sends: as small as a real call gets.
    public static let testRequest = ModelRequest(messages: [.user("Reply with the word OK.")], maxTokens: 5)
    /// Where Claude Code's installation is told.
    public static let claudeCodeSetupURL = URL(string: "https://code.claude.com/docs/en/setup")!

    /// The action that opens the app's Settings window, which the app answers (Infinite Canvas ›
    /// Settings…, ⌘,; CanvasUI's `BoardMenus.showSettings` is the same selector). A plugin that
    /// can't ask for want of a sign-in sends it up the responder chain with `showSettings()`.
    public static let showSettingsAction = NSSelectorFromString("showSettings:")

    /// Opens Settings, where the app signs in: `showSettingsAction`, sent up the responder chain.
    /// False if nothing answered it (no app around, as in tests).
    @discardableResult
    public static func showSettings() -> Bool {
        NSApplication.shared.sendAction(showSettingsAction, to: nil, from: nil)
    }

    /// The key field's tooltip: where the key is kept (the path, never anything read from the file).
    static func storageHelp(_ keys: AnthropicKeyStore) -> String { KeySettingsView.storageHelp(keys) }

    public var body: some View {
        Form {
            Section {
                Picker("Sign in with", selection: Binding(get: { settings.method }, set: { settings.choose($0) })) {
                    Text("Claude Code").tag(SignInMethod.claudeCode)
                    Text("API key").tag(SignInMethod.apiKey)
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                if let failure = settings.failure {
                    SettingsStatusLine(text: "Couldn’t save", tone: .warning, help: failure)
                }
                switch settings.method {
                case .claudeCode: claudeCodeRows
                case .apiKey: keyRows
                }
            } footer: {
                footer
            }
        }
        .formStyle(.grouped)
        .onAppear { keyFieldFocused = takesFocus && settings.method == .apiKey }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            settings.refresh()
        }
        .frame(width: SettingsStyle.width)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Claude Code

    @ViewBuilder private var claudeCodeRows: some View {
        let claudeCode = settings.claudeCode
        LabeledContent("Claude Code") {
            Text(claudeCode.accountText)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        switch claudeCode.state {
        case .signedOut:
            HStack(spacing: SettingsStyle.buttonSpacing) {
                Spacer(minLength: SettingsStyle.statusGap)
                // The default button but while a key's field has the keyboard: the window may hold
                // another pane's, where Return saves the key being typed.
                Button("Sign In…") { claudeCode.signIn() }
                    .keyboardShortcut(typingKey == true ? nil : .defaultAction)
                    .help("Sign in to Claude in your browser")
            }
        case .signingIn:
            HStack(spacing: SettingsStyle.buttonSpacing) {
                Spacer(minLength: SettingsStyle.statusGap)
                Button("Cancel") { claudeCode.cancelSignIn() }
            }
        case .signedIn:
            HStack(spacing: SettingsStyle.buttonSpacing) {
                Button("Sign Out") { claudeCode.signOut() }
                    .disabled(!claudeCode.canSignOut)
                Spacer(minLength: SettingsStyle.statusGap)
                if let text = claudeCode.statusText {
                    SettingsStatusLine(text: text, tone: Tone(claudeCode.status), help: text)
                }
                Button("Test") { claudeCode.test() }
                    .disabled(!claudeCode.canTest)
                    .help("Send a test request")
            }
        case .checking, .notInstalled:
            EmptyView()
        }
    }

    // MARK: The API key

    @ViewBuilder private var keyRows: some View {
        KeyRows(settings: settings.key, focused: $keyFieldFocused, isFocused: keyFieldFocused)
    }

    @ViewBuilder private var footer: some View {
        switch settings.method {
        case .apiKey:
            Link("Get a key", destination: Self.consoleURL)
                .font(.caption)
        case .claudeCode:
            if settings.claudeCode.state == .notInstalled {
                Link("Install Claude Code", destination: Self.claudeCodeSetupURL)
                    .font(.caption)
            }
        }
    }
}

/// What a status's symbol says.
enum Tone {
    case working, works, warning

    init(_ status: AnthropicKeySettings.Status) {
        switch status {
        case .testing: self = .working
        case .works: self = .works
        default: self = .warning
        }
    }

    init(_ status: ClaudeCodeSettings.Status) {
        switch status {
        case .testing: self = .working
        case .works: self = .works
        default: self = .warning
        }
    }
}

/// A test's progress or outcome, or a failure: its symbol (only the symbol takes the tone, as the
/// detail panel's status lines do), then its text, on one line; `help`, when it says more than the
/// text, is its tooltip and its accessibility hint.
struct SettingsStatusLine: View {
    let text: String
    let tone: Tone
    let help: String

    var body: some View {
        HStack(spacing: SettingsStyle.smallSpacing) {
            Group {
                switch tone {
                case .working: ProgressView().controlSize(.small)
                case .works: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                // The warning's tone, as the detail panel shows the same failures: red is kept for
                // what's wrong in what someone made (a schema's errors).
                case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            .frame(width: SettingsStyle.statusIconWidth)
            Text(text)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityHint(help == text ? "" : help)
    }
}

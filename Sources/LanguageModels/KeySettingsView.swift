import AppKit
import Canvas
import Foundation
import SwiftUI

/// A Settings pane for a service's API key alone (TypeSafe's): its rows (`KeyRows`) and where to get
/// one. Its field takes the keyboard as it appears when the window says it's the first pane
/// (`settingsPaneTakesFocus`).
public struct KeySettingsView: View {
    @State private var settings: KeySettings
    @FocusState private var keyFieldFocused: Bool
    @Environment(\.settingsPaneTakesFocus) private var takesFocus

    /// `settings` is kept the first time the view is made; later ones are let go.
    public init(settings: @autoclosure () -> KeySettings) {
        _settings = State(initialValue: settings())
    }

    /// The field's tooltip: where the key is kept (the path, never anything read from the file).
    static func storageHelp(_ keys: any KeyFile) -> String {
        "Saved in \((keys.url.path as NSString).abbreviatingWithTildeInPath)"
    }

    public var body: some View {
        Form {
            Section {
                KeyRows(settings: settings, focused: $keyFieldFocused, isFocused: keyFieldFocused)
            } footer: {
                Link("Get a key", destination: settings.service.console)
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .onAppear { if takesFocus { keyFieldFocused = true } }
        .frame(width: SettingsStyle.width)
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension FocusedValues {
    /// True while a key's field has the keyboard (`KeyRows`): Return saves the key typed there, so
    /// no other pane's button is the default meanwhile (the Claude pane's Sign In…).
    var typingKey: Bool? {
        get { self[TypingKey.self] }
        set { self[TypingKey.self] = newValue }
    }
}

private struct TypingKey: FocusedValueKey {
    typealias Value = Bool
}

/// A key's rows, in a pane's section: a secure field ("<name> API key", its prompt "Saved" or how
/// the service's keys start, where the key is kept its tooltip), then Save, Remove, the status and
/// Test. Every key's are these: the Claude pane's on the API key's way, and every `KeySettingsView`.
struct KeyRows: View {
    @Bindable var settings: KeySettings
    let focused: FocusState<Bool>.Binding
    /// Whether the field has the keyboard (what `focused` says, passed so the view is made again
    /// when it changes).
    let isFocused: Bool

    var body: some View {
        SecureField("\(settings.service.name) API key", text: $settings.draft,
                    prompt: Text(settings.hasKey ? "Saved" : settings.service.placeholder))
            .onSubmit { settings.save() }
            .focused(focused)
            .focusedValue(\.typingKey, true)
            .help(KeySettingsView.storageHelp(settings.keys))
        HStack(spacing: SettingsStyle.buttonSpacing) {
            // The default button only while its own field has the keyboard: the window may hold
            // several panes, and Return saves the key being typed.
            Button("Save") { settings.save() }
                .keyboardShortcut(isFocused ? .defaultAction : nil)
                .disabled(!settings.canSave)
            Button("Remove") { settings.remove() }
                .disabled(!settings.canRemove)
            Spacer(minLength: SettingsStyle.statusGap)
            if let text = settings.statusText {
                SettingsStatusLine(text: text, tone: Tone(settings.status), help: settings.statusHelp ?? text)
            }
            Button("Test") { settings.test() }
                .disabled(!settings.canTest)
                .help("Send a test request")
        }
    }
}

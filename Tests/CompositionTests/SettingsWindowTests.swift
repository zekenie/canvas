import AppKit
import Canvas
import CanvasTesting
import CanvasUI
import DecisionModels
import Foundation
import LanguageModels
import SwiftUI
import TestKit

/// The app's Settings window, never put on screen: `prepare` is what `show` does but bring it
/// forward, and a window never shown is a closed one. Its panes are the registry's, as the app's
/// are: the sign-in's, which the signed-in model brings, over an account in a temporary directory
/// whose way is the API key and whose Claude Code isn't there (no test's registry points at the
/// real key or runs the person's `claude`, and nothing here asks the model anything).
@MainActor let settingsWindowTests = Suite("The Settings window", [
    test("its content is the plugins' panes, made afresh each time it opens, and the window stays where it was, as big as it was") {
        let directory = FileManager.default.temporaryDirectory.appending(path: "SettingsWindowTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = AnthropicAccount(methodURL: directory.appending(path: "sign-in", directoryHint: .notDirectory),
                                       keys: AnthropicKeyStore(url: directory.appending(path: "anthropic-api-key", directoryHint: .notDirectory)),
                                       claudeCode: ClaudeCode(executable: directory.appending(path: "claude", directoryHint: .notDirectory),
                                                              configDirectory: directory.appending(path: "claude-code", directoryHint: .isDirectory)))
        try account.setMethod(.apiKey)
        let registry = try Registry(plugins: [LanguageModelsPlugin(model: SignedInModel(account: account))])
        expectEqual(registry.settingsPanes.map(\.title), ["Claude"])
        let settings = SettingsWindow(registry: registry, autosaveName: nil)
        let window = settings.prepare()
        window.settle()
        expectEqual(window.contentViewController?.view.descendants(NSSecureTextField.self).count, 1, "the key's field")
        let frame = window.frame
        expect(frame.width >= 400 && frame.height >= 100, "sized to its content: \(frame)")
        var shown = window.contentViewController
        for opening in 1...3 {
            expect(settings.prepare() === window, "one window")
            window.settle()
            expect(window.contentViewController !== shown, "made afresh, opening \(opening)")
            expectEqual(window.frame, frame, "opening \(opening)")
            shown = window.contentViewController
        }
    },
    test("with the TypeSafe key's pane under the Claude pane, on the API key's way the window opens with the keyboard in the first field, and Tab goes down to the second") {
        let directory = FileManager.default.temporaryDirectory.appending(path: "SettingsWindowTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = AnthropicAccount(methodURL: directory.appending(path: "sign-in", directoryHint: .notDirectory),
                                       keys: AnthropicKeyStore(url: directory.appending(path: "anthropic-api-key", directoryHint: .notDirectory)),
                                       claudeCode: ClaudeCode(executable: directory.appending(path: "claude", directoryHint: .notDirectory),
                                                              configDirectory: directory.appending(path: "claude-code", directoryHint: .isDirectory)))
        try account.setMethod(.apiKey)
        let typeSafe = TypeSafeKeyStore(url: directory.appending(path: "typesafe-api-key", directoryHint: .notDirectory))
        let registry = try Registry(plugins: [LanguageModelsPlugin(model: SignedInModel(account: account)),
                                              DecisionModelsPlugin(model: JevModel(keys: typeSafe))])
        expectEqual(registry.settingsPanes.map(\.title), ["Claude", "TypeSafe"])
        let window = SettingsWindow(registry: registry, autosaveName: nil).prepare()
        defer { window.close() }
        window.settle()
        let fields = try require(window.contentViewController?.view.descendants(NSSecureTextField.self))
        expectEqual(fields.count, 2)
        let top = try require(fields.min { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY })
        let bottom = try require(fields.first { $0 !== top })
        window.spin(until: { (window.firstResponder as? NSTextView)?.delegate === top })
        _ = window.press(.tab)
        window.spin(until: { (window.firstResponder as? NSTextView)?.delegate === bottom })
        _ = window.press(.backTab)
        window.spin(until: { (window.firstResponder as? NSTextView)?.delegate === top })
    },
])

import AppKit
import Canvas
import CanvasTesting
import CanvasUI
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
])

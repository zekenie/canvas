import AppKit
import Canvas
import CanvasTesting
import CanvasUI
import DecisionModels
import EmbeddingModels
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
    test("with the TypeSafe and OpenAI keys' panes under the Claude pane, on the API key's way the window opens with the keyboard in the first field alone, Tab goes down 1 to 2 to 3, and each step back is exact") {
        let directory = FileManager.default.temporaryDirectory.appending(path: "SettingsWindowTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = AnthropicAccount(methodURL: directory.appending(path: "sign-in", directoryHint: .notDirectory),
                                       keys: AnthropicKeyStore(url: directory.appending(path: "anthropic-api-key", directoryHint: .notDirectory)),
                                       claudeCode: ClaudeCode(executable: directory.appending(path: "claude", directoryHint: .notDirectory),
                                                              configDirectory: directory.appending(path: "claude-code", directoryHint: .isDirectory)))
        try account.setMethod(.apiKey)
        let typeSafe = TypeSafeKeyStore(url: directory.appending(path: "typesafe-api-key", directoryHint: .notDirectory))
        let openAI = OpenAIKeyStore(url: directory.appending(path: "openai-api-key", directoryHint: .notDirectory))
        let registry = try Registry(plugins: [LanguageModelsPlugin(model: SignedInModel(account: account)),
                                              DecisionModelsPlugin(model: JevModel(keys: typeSafe)),
                                              EmbeddingModelsPlugin(model: OpenAIEmbeddingModel(keys: openAI))])
        expectEqual(registry.settingsPanes.map(\.title), ["Claude", "TypeSafe", "OpenAI"])
        let settings = SettingsWindow(registry: registry, autosaveName: nil)
        let window = settings.prepare()
        defer { window.close() }
        window.settle()
        let fields = try require(window.contentViewController?.view.descendants(NSSecureTextField.self))
        expectEqual(fields.count, 3)
        let ordered = fields.sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
        @MainActor func focused(_ field: NSSecureTextField) -> Bool { (window.firstResponder as? NSTextView)?.delegate === field }
        window.spin(until: { focused(ordered[0]) })
        expect(!focused(ordered[1]) && !focused(ordered[2]), "only the first pane's field takes the keyboard as the window opens")
        // Down: 1 to 2, 2 to 3; and back from each, ⇧Tab landing exactly where Tab left.
        _ = window.press(.tab)
        window.spin(until: { focused(ordered[1]) })
        _ = window.press(.tab)
        window.spin(until: { focused(ordered[2]) })
        _ = window.press(.backTab)
        window.spin(until: { focused(ordered[1]) })
        _ = window.press(.backTab)
        window.spin(until: { focused(ordered[0]) })
        // Again, from the middle: Tab down and ⇧Tab back, one step each, at every stop.
        _ = window.press(.tab)
        window.spin(until: { focused(ordered[1]) })
        _ = window.press(.backTab)
        window.spin(until: { focused(ordered[0]) })
        // The window is sized to its three panes and stays that size as it opens again.
        let frame = window.frame
        expect(frame.width >= 400 && frame.height >= 300, "sized to its content: \(frame)")
        for opening in 1...2 {
            expect(settings.prepare() === window, "one window")
            window.settle()
            expectEqual(window.frame, frame, "opening \(opening)")
        }
    },
])

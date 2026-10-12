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
/// are: the key's, which the Anthropic model brings, its key in a temporary store (no test's
/// registry points at the real one, and nothing here asks the model anything).
@MainActor let settingsWindowTests = Suite("The Settings window", [
    test("its content is the plugins' panes, made afresh each time it opens, and the window stays where it was, as big as it was") {
        let directory = FileManager.default.temporaryDirectory.appending(path: "SettingsWindowTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let keys = AnthropicKeyStore(url: directory.appending(path: "anthropic-api-key", directoryHint: .notDirectory))
        let registry = try Registry(plugins: [LanguageModelsPlugin(model: AnthropicModel(keys: keys))])
        expectEqual(registry.settingsPanes.map(\.title), ["Anthropic"])
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

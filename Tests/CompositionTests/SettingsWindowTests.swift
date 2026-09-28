import AppKit
import CanvasTesting
import Composition
import Foundation
import LanguageModels
import SwiftUI
import TestKit

/// The app's Settings window, never put on screen: `prepare` is what `show` does but bring it
/// forward, and a window never shown is a closed one. Its key is in a temporary store.
@MainActor let settingsWindowTests = Suite("The Settings window", [
    test("its content is made afresh each time it opens, and the window stays where it was, as big as it was") {
        let directory = FileManager.default.temporaryDirectory.appending(path: "SettingsWindowTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let keys = AnthropicKeyStore(url: directory.appending(path: "anthropic-api-key", directoryHint: .notDirectory))
        let settings = SettingsWindow(autosaveName: nil) { AnthropicSettingsView(keys: keys, model: ScriptedLanguageModel()) }
        let window = settings.prepare()
        window.settle()
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

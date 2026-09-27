import AppKit
import CanvasTesting
import Foundation
import LanguageModels
import SwiftUI
import TestKit

// The view's buttons are SwiftUI's own in a grouped form (no NSButton to find), so what they do is
// tested on `AnthropicKeySettings`; here, that the view hosts, and its field saves.

/// The settings view in an unshown window, its key kept in `keys`.
@MainActor
private func hostSettings(keys: AnthropicKeyStore, model: ScriptedLanguageModel) -> (NSWindow, NSHostingView<AnthropicSettingsView>) {
    let hosting = NSHostingView(rootView: AnthropicSettingsView(keys: keys, model: model))
    let window = NSWindow(contentRect: CGRect(origin: .zero, size: hosting.fittingSize), styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = hosting
    window.settle()
    return (window, hosting)
}

@MainActor let settingsViewTests = Suite("The settings view", [
    test("hosts at its own size, with one secure field and the link to the console") {
        try withTemporaryStore { keys in
            let (window, hosting) = hostSettings(keys: keys, model: ScriptedLanguageModel())
            defer { window.close() }
            expectEqual(hosting.descendants(NSSecureTextField.self).count, 1)
            expectEqual(hosting.fittingSize.width, 480)
            expect(hosting.fittingSize.height > 120 && hosting.fittingSize.height < 400, "\(hosting.fittingSize)")
            expectEqual(AnthropicSettingsView.consoleURL.host(), "console.anthropic.com")
        }
    },
    test("a key typed in the field, then Return, is saved") {
        try withTemporaryStore { keys in
            let (window, hosting) = hostSettings(keys: keys, model: ScriptedLanguageModel())
            defer { window.close() }
            let field = try require(hosting.descendants(NSSecureTextField.self).first)
            window.focus(field)
            window.type(testKey)
            window.settle()
            window.pressReturn()
            window.spin(until: { keys.read() == testKey })
        }
    },
])

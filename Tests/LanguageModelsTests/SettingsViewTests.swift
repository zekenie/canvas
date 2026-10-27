import AppKit
import CanvasTesting
import Foundation
import LanguageModels
import SwiftUI
import TestKit

// The view's buttons are SwiftUI's own in a grouped form (no NSButton to find), so what they do is
// tested on `AnthropicKeySettings`, `ClaudeCodeSettings` and `SignInSettings`; here, that the view
// hosts each way, its field saves, Return signs in, and Tab walks it.

/// The settings view in an unshown window, signing in to `account`, each way's Test asking `model`.
@MainActor
private func hostSettings(account: AnthropicAccount, model: ScriptedLanguageModel) -> (NSWindow, NSHostingView<AnthropicSettingsView>) {
    let hosting = NSHostingView(rootView: AnthropicSettingsView(model: SignedInModel(account: account), keyModel: model, claudeCodeModel: model))
    let window = NSWindow(contentRect: CGRect(origin: .zero, size: hosting.fittingSize), styleMask: [.titled], backing: .buffered, defer: false)
    // Closed by the test, which holds it: released on close too, it would be released once too often.
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    window.settle()
    return (window, hosting)
}

@MainActor let settingsViewTests = Suite("The settings view", [
    test("hosts at its own size; the API key's way has one secure field and the link to the console") {
        try withTemporaryAccount { account, _ in
            try account.setMethod(.apiKey)
            let (window, hosting) = hostSettings(account: account, model: ScriptedLanguageModel())
            defer { window.close() }
            expectEqual(hosting.descendants(NSSecureTextField.self).count, 1)
            expectEqual(hosting.fittingSize.width, 480)
            expect(hosting.fittingSize.height > 120 && hosting.fittingSize.height < 400, "\(hosting.fittingSize)")
            expectEqual(AnthropicSettingsView.consoleURL.host(), "console.anthropic.com")
        }
    },
    test("a key typed in the field, then Return, is saved") {
        try withTemporaryAccount { account, _ in
            try account.setMethod(.apiKey)
            let keys = account.keys
            let (window, hosting) = hostSettings(account: account, model: ScriptedLanguageModel())
            defer { window.close() }
            let field = try require(hosting.descendants(NSSecureTextField.self).first)
            window.focus(field)
            window.type(testKey)
            window.settle()
            window.pressReturn()
            window.spin(until: { keys.read() == testKey })
        }
    },
    test("the key field has the keyboard once the view appears") {
        try withTemporaryAccount { account, _ in
            try account.setMethod(.apiKey)
            let (window, hosting) = hostSettings(account: account, model: ScriptedLanguageModel())
            defer { window.close() }
            let field = try require(hosting.descendants(NSSecureTextField.self).first)
            window.spin(until: { (window.firstResponder as? NSTextView)?.delegate === field })
        }
    },
    test("a status change is announced, and a failure's detail is its hint") {
        try withTemporaryStore { keys in
            try keys.write(testKey)
            let model = ScriptedLanguageModel()
            model.queue(.unauthorized)
            let settings = AnthropicKeySettings(keys: keys, model: model)
            var heard: [String] = []
            settings.announce = { heard.append($0) }
            settings.test()
            spinRunLoop(until: { settings.status != .testing })
            expectEqual(heard, ["Testing…", "API key rejected"])
            settings.remove()
            expectEqual(heard.count, 2, "a removal says nothing the field doesn't")
        }
    },
    test("with no way chosen it shows Claude Code's, which asks Claude Code whom the app is signed in as; no key field") {
        try withTemporaryAccount { account, claude in
            try claude.answer(.authStatus, stdout: claudeStatus(signedIn: true))
            let (window, hosting) = hostSettings(account: account, model: ScriptedLanguageModel())
            defer { window.close() }
            expectEqual(hosting.descendants(NSSecureTextField.self).count, 0)
            window.spin(until: { claude.ran(.authStatus) }, timeout: 10)
            expectEqual(hosting.fittingSize.width, 480)
        }
    },
    test("signed out, Return signs in through Claude Code") {
        try withTemporaryAccount { account, claude in
            try account.setMethod(.claudeCode)
            try claude.answer(.authStatus, stdout: claudeStatus(signedIn: false))
            try claude.answer(.authLogin, stdout: "Login successful.\n")
            let (window, _) = hostSettings(account: account, model: ScriptedLanguageModel())
            defer { window.close() }
            // Sign In… shows once Claude Code has said it's signed out; Return before then does nothing.
            window.spin(until: {
                window.pressReturn()
                return claude.ran(.authLogin)
            }, timeout: 10)
        }
    },
    test("by keys: Tab comes round the pane's stops and back to the key field, each shown and named") {
        try withTemporaryAccount { account, _ in
            try account.setMethod(.apiKey)
            let (window, hosting) = hostSettings(account: account, model: ScriptedLanguageModel())
            defer { window.close() }
            let field = try require(hosting.descendants(NSSecureTextField.self).first)
            window.spin(until: { (window.firstResponder as? NSTextView)?.delegate === field })
            let walk = KeyWalk(window)
            let start = walk.focus
            expect(start.acceptsText && start.isMarked, "the key field, with a caret: \(start)")
            // With macOS's Keyboard navigation off, the field is the pane's one stop, and Tab stays on it.
            let cycle = walk.expectCycle(inOrder: [start.id], wraps: walk.keyboardNavigation ? .closed : .stays)
            walk.expectShows(cycle.stops)
            expectEqual(walk.focus.id, start.id, walk.traceText)
        }
    },
])

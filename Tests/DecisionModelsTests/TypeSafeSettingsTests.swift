import AppKit
import CanvasTesting
import DecisionModels
import Foundation
import LanguageModels
import SwiftUI
import TestKit

/// The TypeSafe pane in an unshown window, its key kept in `keys`.
@MainActor
private func hostPane(keys: TypeSafeKeyStore, model: ScriptedDecisionModel) -> (NSWindow, NSHostingView<TypeSafeSettingsView>) {
    let hosting = NSHostingView(rootView: TypeSafeSettingsView(keys: keys, model: model))
    let window = NSWindow(contentRect: CGRect(origin: .zero, size: hosting.fittingSize), styleMask: [.titled], backing: .buffered, defer: false)
    // Closed by the test, which holds it: released on close too, it would be released once too often.
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    window.settle()
    return (window, hosting)
}

@MainActor let typeSafeSettingsTests = Suite("The TypeSafe key", [
    test("saved in its own file beside Anthropic's, readable only by its owner, and said changed as the decision model's key") {
        try withTemporaryStore { keys in
            let settings = TypeSafeKeySettings(keys: keys, model: ScriptedDecisionModel())
            expectEqual(settings.service, .typeSafe)
            var decision = 0, language = 0
            let heard = NotificationCenter.default.addObserver(forName: .decisionModelKeyDidChange, object: settings, queue: nil) { _ in
                MainActor.assumeIsolated { decision += 1 }
            }
            let other = NotificationCenter.default.addObserver(forName: .languageModelSignInDidChange, object: nil, queue: nil) { _ in
                MainActor.assumeIsolated { language += 1 }
            }
            defer {
                NotificationCenter.default.removeObserver(heard)
                NotificationCenter.default.removeObserver(other)
            }
            settings.draft = " \(testKey)\n"
            settings.save()
            expectEqual(keys.read(), testKey)
            let mode = try FileManager.default.attributesOfItem(atPath: keys.url.path)[.posixPermissions] as? Int
            expectEqual(mode, 0o600)
            settings.remove()
            expect(!keys.hasKey)
            expectEqual(decision, 2, "saved, then removed")
            expectEqual(language, 0, "never the language model's")
        }
    },
    test("Test asks one tiny question with the saved key, and says what came of it") {
        try withTemporaryStore { keys in
            try keys.write(testKey)
            let model = ScriptedDecisionModel()
            model.queue(yes: ["test": 1])
            model.queue(.unauthorized)
            let settings = TypeSafeKeySettings(keys: keys, model: model)
            var heard: [String] = []
            settings.announce = { heard.append($0) }
            settings.test()
            spinRunLoop(until: { settings.status != .testing })
            expectEqual(settings.status, .works)
            expectEqual(model.lastRequest, TypeSafeSettingsView.testRequest)
            expectEqual(TypeSafeSettingsView.testRequest.questions.count, 1)
            settings.test()
            spinRunLoop(until: { settings.status != .testing })
            expectEqual(settings.statusText, "Scripted key rejected")
            expectEqual(heard, ["Testing…", "Works", "Testing…", "Scripted key rejected"])
        }
    },
    test("Jev itself is what Test asks by default, with the saved key; with none saved and nothing typed, nothing is sent") {
        try withTemporaryStore { keys in
            try StubProtocol.intercepting(.http(status: 200, body: jevReply(["test": 0.9]))) {
                let unsaved = TypeSafeKeySettings(keys: keys)
                unsaved.draft = "   "
                unsaved.test()
                expectEqual(unsaved.status, .idle, "nothing to save, nothing saved: no test")
                expectEqual(StubProtocol.received.count, 0)
                try keys.write(testKey)
                let settings = TypeSafeKeySettings(keys: keys)
                settings.test()
                spinRunLoop(until: { settings.status != .testing })
                expectEqual(settings.status, .works)
                let sent = try require(StubProtocol.received.first)
                expectEqual(StubProtocol.received.count, 1)
                expectEqual(sent.request.url, JevModel.endpoint)
                expectEqual(sent.request.value(forHTTPHeaderField: "authorization"), "Bearer \(testKey)")
            }
        }
    },
    test("the pane hosts at Anthropic's width with one secure field, \"TypeSafe API key\", and takes the keyboard as it appears") {
        try withTemporaryStore { keys in
            let (window, hosting) = hostPane(keys: keys, model: ScriptedDecisionModel())
            defer { window.close() }
            let field = try require(hosting.descendants(NSSecureTextField.self).first)
            expectEqual(hosting.descendants(NSSecureTextField.self).count, 1)
            expectEqual(hosting.fittingSize.width, 480)
            expectEqual(field.placeholderString ?? field.placeholderAttributedString?.string, "Not saved")
            window.spin(until: { (window.firstResponder as? NSTextView)?.delegate === field })
            window.type(testKey)
            window.settle()
            window.pressReturn()
            window.spin(until: { keys.read() == testKey })
            expectEqual(TypeSafeSettingsView.pane, "TypeSafe")
        }
    },
])

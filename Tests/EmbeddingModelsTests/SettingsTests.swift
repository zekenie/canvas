import AppKit
import CanvasTesting
import EmbeddingModels
import Foundation
import LanguageModels
import SwiftUI
import TestKit

/// The OpenAI pane in an unshown window, its key kept in `keys`.
@MainActor
private func hostPane(keys: OpenAIKeyStore, model: ScriptedEmbeddingModel) -> (NSWindow, NSHostingView<OpenAISettingsView>) {
    let hosting = NSHostingView(rootView: OpenAISettingsView(keys: keys, model: model))
    let window = NSWindow(contentRect: CGRect(origin: .zero, size: hosting.fittingSize), styleMask: [.titled], backing: .buffered, defer: false)
    // Closed by the test, which holds it: released on close too, it would be released once too often.
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    window.settle()
    return (window, hosting)
}

@MainActor let settingsTests = Suite("The OpenAI pane", [
    test("Test asks one tiny request with the saved key, and says what came of it") {
        try withTemporaryStore { keys in
            try keys.write(testKey)
            let model = ScriptedEmbeddingModel.hashing()
            model.queue(.unauthorized)
            let settings = OpenAIKeySettings(keys: keys, model: model)
            var heard: [String] = []
            settings.announce = { heard.append($0) }
            settings.test()
            spinRunLoop(until: { settings.status != .testing })
            expectEqual(settings.statusText, "Scripted key rejected")
            settings.test()
            spinRunLoop(until: { settings.status != .testing })
            expectEqual(settings.status, .works)
            expectEqual(model.requests, [["Test"], ["Test"]])
            expectEqual(OpenAISettingsView.testRequest, ["Test"])
            expectEqual(heard, ["Testing…", "Scripted key rejected", "Testing…", "Works"])
        }
    },
    test("OpenAI's model is what Test asks, with the saved key; with none saved and nothing typed, nothing is sent") {
        try withTemporaryStore { keys in
            // The model makes a session of its own, which `URLProtocol.registerClass` doesn't reach: a stubbed one
            // is given, so nothing leaves the machine.
            let model = OpenAIEmbeddingModel(keys: keys, session: StubProtocol.session(answering: .http(status: 200, body: embeddingReply([[1, 2]]))))
            do {
                let unsaved = OpenAIKeySettings(keys: keys)
                unsaved.draft = "   "
                unsaved.test()
                expectEqual(unsaved.status, .idle, "nothing to save, nothing saved: no test")
                expectEqual(StubProtocol.received.count, 0)
                try? keys.write(testKey)
                let settings = OpenAIKeySettings(keys: keys, model: model)
                settings.test()
                spinRunLoop(until: { settings.status != .testing })
                expectEqual(settings.status, .works)
                expectEqual(StubProtocol.received.count, 1)
                let sent = StubProtocol.received.first
                expectEqual(sent?.request.url, OpenAIEmbeddingModel.endpoint)
                expectEqual(sent?.request.value(forHTTPHeaderField: "authorization"), "Bearer \(testKey)")
                expectEqual(sent.map(inputs(of:)) ?? [], ["Test"])
            }
        }
    },
    test("the pane hosts at Anthropic's width with one secure field, and takes the keyboard as it appears") {
        try withTemporaryStore { keys in
            let (window, hosting) = hostPane(keys: keys, model: ScriptedEmbeddingModel.hashing())
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
            expectEqual(OpenAISettingsView.pane, "OpenAI")
        }
    },
])

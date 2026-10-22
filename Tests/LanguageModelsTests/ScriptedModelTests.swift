import Canvas
import Foundation
import LanguageModels
import TestKit

@MainActor let scriptedModelTests = Suite("The scripted model", [
    test("keeps every request and answers from its queue, in order") {
        let model = ScriptedLanguageModel(answers: ["one"])
        model.queue("two", stopReason: .maxTokens)
        model.queue(.overloaded)
        let first = ModelRequest(system: "S", messages: [.user("1")])
        expectEqual(try outcome(of: model, first), .success(ModelResponse(text: "one")))
        expectEqual(try outcome(of: model), .success(ModelResponse(text: "two", stopReason: .maxTokens)))
        expectEqual(try outcome(of: model), .failure(.overloaded))
        expectEqual(model.requests.count, 3)
        expectEqual(model.requests.first, first)
        expectEqual(model.answered, 3)
        expect(model.queued.isEmpty)
    },
    test("with nothing queued, the fallback answers; without one, it fails") {
        let model = ScriptedLanguageModel()
        guard case .failure(.server(status: 0, _)) = try outcome(of: model) else { return expect(false, "it answered") }
        model.fallback = { .success(ModelResponse(text: "echo: \($0.messages.last?.text ?? "")")) }
        expectEqual(try outcome(of: model, ModelRequest(messages: [.user("hi")])).map(\.text), .success("echo: hi"))
    },
    test("while it holds answers, a call waits, its request kept, until released") {
        let model = ScriptedLanguageModel(answers: ["done"])
        model.holdsAnswers = true
        var result: Result<ModelResponse, LanguageModelError>?
        Task { @MainActor in
            do throws(LanguageModelError) { result = .success(try await model.respond(to: ModelRequest(messages: [.user("x")]))) } catch { result = .failure(error) }
        }
        spinRunLoop(until: { model.waiting == 1 })
        expectEqual(model.requests.count, 1)
        expectEqual(result, nil)
        expectEqual(model.answered, 0)
        model.release()
        spinRunLoop(until: { result != nil })
        expectEqual(result, .success(ModelResponse(text: "done")))
        expectEqual(model.waiting, 0)
    },
    test("a held call whose task is cancelled throws cancelled, and takes no answer") {
        let model = ScriptedLanguageModel(answers: ["kept"])
        model.holdsAnswers = true
        var result: Result<ModelResponse, LanguageModelError>?
        let task = Task { @MainActor in
            do throws(LanguageModelError) { result = .success(try await model.respond(to: ModelRequest(messages: [.user("x")]))) } catch { result = .failure(error) }
        }
        spinRunLoop(until: { model.waiting == 1 })
        task.cancel()
        spinRunLoop(until: { result != nil })
        expectEqual(result, .failure(.cancelled))
        expectEqual(model.queued.count, 1)
    },
])

@MainActor let pluginTests = Suite("The plugin", [
    test("lends its model to the editor") {
        let model = ScriptedLanguageModel()
        let editor = CanvasEditor(registry: try Registry(plugins: [LanguageModelsPlugin(model: model)]))
        expect(editor.languageModel as? ScriptedLanguageModel === model)
    },
    test("without it, the editor has no model") {
        expect(CanvasEditor(registry: try Registry(plugins: [])).languageModel == nil)
    },
    test("its registry line") {
        expectEqual(try Registry(plugins: [LanguageModelsPlugin(model: ScriptedLanguageModel())]).report, """
        core             tool hand · command undo · command redo · command zoomIn in ViewMenu.Zoom · command zoomOut in ViewMenu.Zoom · command zoomToActualSize in ViewMenu.Zoom · command zoomToFit in ViewMenu.Zoom · command pageUp · command pageDown · command scrollToStart · command scrollToEnd
        language-models  service LanguageModelState
        """)
    },
    test("the Anthropic model brings the Settings pane that keeps its key; a model that needs none brings no pane") {
        try withTemporaryStore { keys in
            let registry = try Registry(plugins: [LanguageModelsPlugin(model: AnthropicModel(keys: keys))])
            expectEqual(registry.settingsPanes.map(\.title), ["Anthropic"])
            expect(registry.report.hasSuffix("service LanguageModelState · settings pane Anthropic"), registry.report)
        }
        expectEqual(try Registry(plugins: [LanguageModelsPlugin(model: ScriptedLanguageModel())]).settingsPanes.count, 0)
    },
    test("the app's model is Claude Haiku 4.5, with the app's key") {
        let model = AnthropicModel()
        expectEqual(model.model, "claude-haiku-4-5")
        expectEqual(model.keys, .standard)
    },
])

/// What an observer heard.
@MainActor final class Heard {
    var statuses: [AnthropicKeySettings.Status] = []
}

@MainActor let settingsTests = Suite("The settings", [
    test("save writes what's typed, trimmed, and clears the field") {
        try withTemporaryStore { keys in
            let settings = AnthropicKeySettings(keys: keys, model: ScriptedLanguageModel())
            expect(!settings.hasKey && !settings.canSave && !settings.canTest)
            settings.draft = "  \(testKey) \n"
            expect(settings.canSave && settings.canTest)
            settings.save()
            expectEqual(keys.read(), testKey)
            expectEqual(settings.draft, "")
            expect(settings.hasKey)
            expectEqual(settings.status, .saved)
            expectEqual(settings.statusText, nil, "the field's prompt says it's saved")
        }
    },
    test("remove removes it") {
        try withTemporaryStore { keys in
            try keys.write(testKey)
            let settings = AnthropicKeySettings(keys: keys, model: ScriptedLanguageModel())
            expect(settings.hasKey)
            settings.remove()
            expect(!settings.hasKey)
            expectEqual(keys.read(), nil)
            expectEqual(settings.status, .removed)
            expectEqual(settings.statusText, nil, "the field's prompt, and Remove dimmed, say it's gone")
        }
    },
    test("saving and removing a key say so to whoever waits for one; a save that fails doesn't") {
        try withTemporaryStore { keys in
            let settings = AnthropicKeySettings(keys: keys, model: ScriptedLanguageModel())
            let heard = Heard()
            let observer = NotificationCenter.default.addObserver(forName: .languageModelKeyDidChange, object: settings, queue: nil) { _ in
                MainActor.assumeIsolated { heard.statuses.append(settings.status) }
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            settings.draft = testKey
            settings.save()
            settings.remove()
            expectEqual(heard.statuses, [.saved, .removed], "after the file changed, so a call made then reads it")
            // A directory where the key's folder should be: the save fails, and nothing is said.
            let blocked = AnthropicKeySettings(keys: AnthropicKeyStore(url: URL(fileURLWithPath: "/dev/null/key")), model: ScriptedLanguageModel())
            let blockedObserver = NotificationCenter.default.addObserver(forName: .languageModelKeyDidChange, object: blocked, queue: nil) { _ in
                MainActor.assumeIsolated { heard.statuses.append(blocked.status) }
            }
            defer { NotificationCenter.default.removeObserver(blockedObserver) }
            blocked.draft = testKey
            blocked.save()
            guard case let .failed(message, detail) = blocked.status else { return expect(false, "the save should fail") }
            expectEqual(message, "Couldn’t save")
            expectEqual(blocked.statusText, "Couldn’t save")
            expect(detail != nil && blocked.statusHelp == detail, "the system's words, in the status's tooltip")
            expectEqual(heard.statuses.count, 2)
        }
    },
    test("test asks something tiny, and says the key works") {
        try withTemporaryStore { keys in
            try keys.write(testKey)
            let model = ScriptedLanguageModel(answers: ["OK"])
            model.holdsAnswers = true
            let settings = AnthropicKeySettings(keys: keys, model: model)
            settings.test()
            expectEqual(settings.status, .testing)
            expect(!settings.canTest, "not twice at once")
            spinRunLoop(until: { model.waiting == 1 })
            expectEqual(model.lastRequest, AnthropicKeySettings.testRequest)
            expectEqual(model.lastRequest?.maxTokens, 5)
            model.release()
            spinRunLoop(until: { settings.status != .testing })
            expectEqual(settings.status, .works)
            expectEqual(settings.statusText, "Works")
        }
    },
    test("a failed test says why") {
        try withTemporaryStore { keys in
            try keys.write(testKey)
            let model = ScriptedLanguageModel()
            model.queue(.unauthorized)
            let settings = AnthropicKeySettings(keys: keys, model: model)
            settings.test()
            spinRunLoop(until: { settings.status != .testing })
            expectEqual(settings.status, .failed(LanguageModelError.unauthorized.message))
            expectEqual(settings.statusText, "API key rejected")
            expectEqual(settings.statusHelp, "API key rejected")
        }
    },
    test("test saves what's typed first, so it tests that key") {
        try withTemporaryStore { keys in
            let settings = AnthropicKeySettings(keys: keys, model: ScriptedLanguageModel(answers: ["OK"]))
            settings.draft = testKey
            settings.test()
            expectEqual(keys.read(), testKey)
            spinRunLoop(until: { settings.status != .testing })
            expectEqual(settings.status, .works)
        }
    },
    test("with no key, Test does nothing") {
        try withTemporaryStore { keys in
            let model = ScriptedLanguageModel(answers: ["OK"])
            let settings = AnthropicKeySettings(keys: keys, model: model)
            settings.test()
            expectEqual(settings.status, .idle)
            expect(model.requests.isEmpty)
        }
    },
    test("a new key typed whose save fails: Test says so, and doesn't test the key saved before") {
        try withTemporaryStore { keys in
            try keys.write(testKey)
            let model = ScriptedLanguageModel(answers: ["OK"])
            let settings = AnthropicKeySettings(keys: keys, model: model)
            // The key's folder, read-only: the new key can't be written beside the old one.
            let folder = keys.url.deletingLastPathComponent()
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
            settings.draft = "sk-ant-test-new"
            settings.test()
            guard case .failed("Couldn’t save", _) = settings.status else { return expect(false, "\(settings.status)") }
            settings.settleTest()
            guard case .failed("Couldn’t save", _) = settings.status else { return expect(false, "\(settings.status)") }
            expect(model.requests.isEmpty, "nothing sent")
            expectEqual(keys.read(), testKey)
            expectEqual(settings.draft, "sk-ant-test-new", "kept, to save again")
        }
    },
    test("Remove waits for a test to finish") {
        try withTemporaryStore { keys in
            try keys.write(testKey)
            let model = ScriptedLanguageModel(answers: ["OK"])
            model.holdsAnswers = true
            let settings = AnthropicKeySettings(keys: keys, model: model)
            expect(settings.canRemove)
            settings.test()
            expect(!settings.canRemove)
            settings.remove()
            expectEqual(keys.read(), testKey, "not removed")
            expectEqual(settings.status, .testing)
            spinRunLoop(until: { model.waiting == 1 })
            model.release()
            spinRunLoop(until: { settings.status != .testing })
            expect(settings.canRemove)
            settings.remove()
            expectEqual(keys.read(), nil)
        }
    },
    test("typing another key clears what a test or a failure said; not a test under way") {
        try withTemporaryStore { keys in
            try keys.write(testKey)
            let model = ScriptedLanguageModel(answers: ["OK"])
            let settings = AnthropicKeySettings(keys: keys, model: model)
            settings.test()
            spinRunLoop(until: { settings.status != .testing })
            expectEqual(settings.status, .works)
            settings.draft = "s"
            expectEqual(settings.status, .idle)
            expectEqual(settings.statusText, nil)
            settings.draft = ""
            model.queue(.unauthorized)
            settings.test()
            spinRunLoop(until: { settings.status != .testing })
            expectEqual(settings.status, .failed("API key rejected"))
            settings.draft = "sk"
            expectEqual(settings.status, .idle)
            model.holdsAnswers = true
            model.queue("OK")
            settings.draft = ""
            settings.test()
            settings.draft = "x"
            expectEqual(settings.status, .testing)
            spinRunLoop(until: { model.waiting == 1 })
            model.release()
            spinRunLoop(until: { settings.status != .testing })
        }
    },
    test("a test that finds no key (its file removed while Settings was open) says so, and so do the field and Remove") {
        try withTemporaryStore { keys in
            try keys.write(testKey)
            let model = ScriptedLanguageModel()
            let settings = AnthropicKeySettings(keys: keys, model: model)
            expect(settings.hasKey && settings.canRemove)
            try keys.remove()           // by hand, or by another window
            model.queue(.noKey)         // as the app's model finds it: it reads the file at every call
            settings.test()
            spinRunLoop(until: { settings.status != .testing })
            expectEqual(settings.statusText, "No API key")
            expect(!settings.hasKey, "the field's prompt is back to sk-ant-…, not Saved")
            expect(!settings.canRemove && !settings.canTest)
        }
    },
    test("a new one reads the store as it is and says nothing (the Settings window makes one each time it opens)") {
        try withTemporaryStore { keys in
            let first = AnthropicKeySettings(keys: keys, model: ScriptedLanguageModel(answers: ["OK"]))
            first.draft = testKey
            first.test()
            spinRunLoop(until: { first.status != .testing })
            expectEqual(first.status, .works)
            try keys.remove()           // by hand, or by another window
            let again = AnthropicKeySettings(keys: keys, model: ScriptedLanguageModel())
            expectEqual(again.status, .idle)
            expectEqual(again.statusText, nil)
            expectEqual(again.draft, "")
            expect(!again.hasKey, "read from the file, as it is now")
        }
    },
])

extension AnthropicKeySettings {
    /// Turns the run loop a few times, for a test that may have started.
    func settleTest() {
        for _ in 0..<5 { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
    }
}

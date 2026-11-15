import EmbeddingModels
import Foundation
import LanguageModels
import TestKit

@MainActor let keyStoreTests = Suite("The OpenAI key", [
    test("saved in its own file beside the other keys, readable only by its owner, and said changed as the embedding model's key alone") {
        try withTemporaryStore { keys in
            expectEqual(keys.url.lastPathComponent, "openai-api-key")
            expectEqual(OpenAIKeyStore.standard.url.deletingLastPathComponent(), AnthropicKeyStore.standard.url.deletingLastPathComponent())
            let settings = OpenAIKeySettings(keys: keys, model: ScriptedEmbeddingModel.hashing())
            expectEqual(settings.service, .openAI)
            expectEqual(settings.service.name, "OpenAI")
            expectEqual(settings.service.keyDidChange, .embeddingModelKeyDidChange)
            // Everything the settings post, whatever its name: only its own service's.
            var posted: [Notification.Name] = []
            let heard = NotificationCenter.default.addObserver(forName: nil, object: settings, queue: nil) { note in
                let name = note.name
                MainActor.assumeIsolated { posted.append(name) }
            }
            var language = 0
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
            expectEqual(posted.filter { $0 == .embeddingModelKeyDidChange }.count, 2, "saved, then removed")
            expectEqual(posted.filter { $0 != .embeddingModelKeyDidChange }, [], "nothing else of this one's")
            expectEqual(language, 0, "never the language model's")
        }
    },
    test("the name of what it posts is the module's, and its console is OpenAI's") {
        expectEqual(Notification.Name.embeddingModelKeyDidChange.rawValue, "EmbeddingModels.keyDidChange")
        expectEqual(KeyService.openAI.console, URL(string: "https://platform.openai.com/api-keys"))
        expectEqual(KeyService.openAI.placeholder, "Not saved")
    },
    test("a key is read without the whitespace round it, and a file of whitespace is none") {
        try withTemporaryStore { keys in
            try keys.write("  \(testKey) \n")
            expectEqual(keys.read(), testKey)
            try keys.write("   ")
            expect(!keys.hasKey)
        }
    },
])

import Canvas
import CanvasTesting
import EmbeddingModels
import Foundation
import TestKit

@MainActor let pluginTests = Suite("The plugin", [
    test("lends its embeddings to the registry and the editor; without it there are none") {
        let model = ScriptedEmbeddingModel.hashing()
        let registry = try Registry(plugins: [EmbeddingModelsPlugin(model: model)])
        let embeddings = try require(registry.embeddings)
        expect(embeddings.model as? ScriptedEmbeddingModel === model)
        let editor = CanvasEditor(registry: registry, scheduler: ManualScheduler())
        expect(editor.embeddings === embeddings, "one for the registry, whoever asks")
        expect(editor.embeddingModel as? ScriptedEmbeddingModel === model)
        let other = CanvasEditor(registry: registry, scheduler: ManualScheduler())
        expect(other.embeddings === embeddings, "one memory for every editor")
        let none = try Registry(plugins: [])
        expect(none.embeddings == nil)
        expect(CanvasEditor(registry: none, scheduler: ManualScheduler()).embeddingModel == nil)
    },
    test("its memory keeps nothing on disk unless it's given a file") {
        let plain = try Registry(plugins: [EmbeddingModelsPlugin(model: ScriptedEmbeddingModel.hashing())])
        expectEqual(plain.embeddings?.memory.url, nil)
        let url = URL(fileURLWithPath: "/tmp/never-written.bin")
        let kept = try Registry(plugins: [EmbeddingModelsPlugin(model: ScriptedEmbeddingModel.hashing(), memory: EmbeddingMemory(url: url))])
        expectEqual(kept.embeddings?.memory.url, url)
    },
    test("its registry line") {
        expectEqual(try Registry(plugins: [EmbeddingModelsPlugin(model: ScriptedEmbeddingModel.hashing())]).report, """
        core              tool hand · command undo · command redo · command zoomIn in ViewMenu.Zoom · command zoomOut in ViewMenu.Zoom · command zoomToActualSize in ViewMenu.Zoom · command zoomToFit in ViewMenu.Zoom · command pageUp · command pageDown · command scrollToStart · command scrollToEnd
        embedding-models  embeddings
        """)
    },
    test("OpenAI brings the Settings pane that keeps its key; a model that needs none brings no pane") {
        try withTemporaryStore { keys in
            let registry = try Registry(plugins: [EmbeddingModelsPlugin(model: OpenAIEmbeddingModel(keys: keys))])
            expectEqual(registry.settingsPanes.map(\.title), ["OpenAI"])
            expect(registry.report.hasSuffix("embeddings · settings pane OpenAI"), registry.report)
        }
        expectEqual(try Registry(plugins: [EmbeddingModelsPlugin(model: ScriptedEmbeddingModel.hashing())]).settingsPanes.count, 0)
    },
    test("made from nothing, as the product's list makes it, it is OpenAI's model with the key from Settings and the app's vector file, and touches neither") {
        let registry = try Registry(plugins: [EmbeddingModelsPlugin()])
        let embeddings = try require(registry.embeddings)
        let model = try require(embeddings.model as? OpenAIEmbeddingModel)
        expectEqual(model.model, OpenAIEmbeddingModel.latest)
        expectEqual(model.keys, .standard)
        expectEqual(embeddings.memory.url, EmbeddingMemory.standard().url)
        expectEqual(registry.settingsPanes.map(\.title), ["OpenAI"])
        let outward: any OutwardPlugin = EmbeddingModelsPlugin()
        expectEqual(outward.id, .embeddingModels)
    },
    test("two plugins that lend embeddings conflict, as two draw engines do") {
        expectThrows(RegistryError.conflict(point: "EmbeddingEngines", key: "embedding engine", plugins: ["embedding-models", "twin"])) {
            _ = try Registry(plugins: [EmbeddingModelsPlugin(model: ScriptedEmbeddingModel()), Twin()])
        }
    },
    test("a model's vectors reach a plugin through the editor, asked once") {
        let model = ScriptedEmbeddingModel.hashing()
        let editor = CanvasEditor(registry: try Registry(plugins: [EmbeddingModelsPlugin(model: model)]), scheduler: ManualScheduler())
        let embeddings = try require(editor.embeddings)
        for _ in 0..<3 {
            let answered = try awaitResult { () async throws -> EmbeddedTexts in try await embeddings.vectors(of: ["a", "b"]) }
            expectEqual(answered.vectors.count, 2)
        }
        expectEqual(model.requests.count, 1)
    },
])

/// A second plugin that lends embeddings.
private struct Twin: CanvasPlugin {
    var id: PluginID { "twin" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.contribute(Embeddings(model: ScriptedEmbeddingModel(), memory: EmbeddingMemory(url: nil)), to: EmbeddingEngines.self)
    }
}

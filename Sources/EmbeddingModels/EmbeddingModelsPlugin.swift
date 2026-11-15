import Canvas
import SwiftUI

/// The app's embedding model, as a plugin: it lends the registry one model for any plugin to have texts
/// turned into vectors by, and the vectors it gave, kept (`registry.embeddings`, and the editor's).
/// Generic: it knows nothing of what plugins use vectors for. Made from nothing (as the product's list
/// makes it), the model is OpenAI's, over the network, and the vectors are kept in a file in
/// Application Support. That reaches outside the process, so the plugin is an `OutwardPlugin`: anything
/// but the app that loads the list hands over its own, and tests pass a `ScriptedEmbeddingModel`, its
/// vectors kept in memory only, so no test ever reaches the network or the user's files.
///
/// A model that needs a key brings the Settings pane that keeps it: OpenAI's is its own key store's, so
/// the pane and the model read one key, and a list given another model has no OpenAI pane.
extension PluginID {
    public static let embeddingModels: PluginID = "embedding-models"
}

public struct EmbeddingModelsPlugin: OutwardPlugin {
    let embeddings: Embeddings

    /// The app's: OpenAI's text-embedding-3-large over the network with the key saved in Settings, its
    /// vectors kept in a file in Application Support (`EmbeddingMemory.standard()`). The one place the
    /// engine is chosen: another model (another provider, or one on the Mac) replaces it here, and nothing
    /// that uses vectors changes. Made from nothing it builds a URL and touches no file and no network;
    /// only a call does.
    public init() { self.init(model: OpenAIEmbeddingModel(keys: .standard), memory: .standard()) }
    /// `model`, its vectors kept by `memory` (by default in memory only).
    public init(model: any EmbeddingModel, memory: EmbeddingMemory? = nil) {
        embeddings = Embeddings(model: model, memory: memory ?? EmbeddingMemory(url: nil))
    }

    public var id: PluginID { .embeddingModels }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.contribute(embeddings, to: EmbeddingEngines.self)
        if let openAI = embeddings.model as? OpenAIEmbeddingModel {
            let keys = openAI.keys
            registrar.settingsPane(OpenAISettingsView.pane) { OpenAISettingsView(keys: keys) }
        }
    }
}

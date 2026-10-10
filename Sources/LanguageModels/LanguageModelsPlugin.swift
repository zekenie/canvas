import Canvas
import HostSlots
import SwiftUI

/// The app's language model, as a plugin: it lends every editor one model (`editor.languageModel`)
/// for any plugin to ask. Generic: it knows nothing of what plugins ask it for. The app's is
/// `AnthropicModel` (Claude Haiku, with the key saved in Settings); tests pass a
/// `ScriptedLanguageModel`, so no test ever reaches the network.
///
/// A model that needs a key brings the Settings pane that keeps it (the host's slot for one): the
/// Anthropic model's is its own key store's, so the pane and the model read one key, and a list
/// given another model (a test's scripted one) has no pane, and never points at the key's file.
extension PluginID {
    public static let languageModels: PluginID = "language-models"
}

public struct LanguageModelsPlugin: CanvasPlugin {
    let model: any LanguageModel

    public init(model: any LanguageModel) { self.model = model }
    public var id: PluginID { .languageModels }

    public func register(into registrar: inout PluginRegistrar) {
        let model = model
        registrar.service { _ in LanguageModelState(model: model) }
        if let anthropic = model as? AnthropicModel {
            let keys = anthropic.keys
            registrar.settingsPane(SettingsStyle.anthropicPane) { AnthropicSettingsView(keys: keys) }
        }
    }
}

/// Per editor: the model the plugin lends.
@MainActor
final class LanguageModelState {
    let model: any LanguageModel
    init(model: any LanguageModel) { self.model = model }
}

extension LanguageModelState: EditorService {
    /// Nothing kept per shape, so nothing to follow to another board.
    func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {}
}

extension CanvasEditor {
    /// The model plugins ask: Claude in the app, a scripted one in tests. Nil without
    /// LanguageModelsPlugin.
    public var languageModel: (any LanguageModel)? { service(LanguageModelState.self)?.model }
}

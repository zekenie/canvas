import Canvas

/// The app's language model, as a plugin: it lends every editor one model (`editor.languageModel`)
/// for any plugin to ask. Generic: it knows nothing of what plugins ask it for. The app's is
/// `AnthropicModel` (Claude Haiku, with the key saved in Settings); tests pass a
/// `ScriptedLanguageModel`, so no test ever reaches the network.
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

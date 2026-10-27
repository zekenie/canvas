import Canvas
import SwiftUI

/// The app's language model, as a plugin: it lends every editor one model (`editor.languageModel`)
/// for any plugin to ask. Generic: it knows nothing of what plugins ask it for. Made from nothing
/// (as the product's list makes it), the model is the app's: `SignedInModel`, Claude asked the way
/// the person signed in in Settings (an API key, over the network, or their Claude Code). That
/// reaches outside the process, so the plugin is an `OutwardPlugin`: anything but the app that
/// loads the list hands over its own, and tests pass a `ScriptedLanguageModel`, so no test ever
/// reaches the network or runs Claude Code.
///
/// The signed-in model brings the Settings pane it's signed in with (the host's slot for one), over
/// its own account, so the pane and the model read one way, one key and one Claude Code; a list
/// given another model (a test's scripted one) has no pane, and never points at the app's files.
extension PluginID {
    public static let languageModels: PluginID = "language-models"
}

public struct LanguageModelsPlugin: OutwardPlugin {
    let model: any LanguageModel

    public init() { self.init(model: SignedInModel(account: .standard)) }
    public init(model: any LanguageModel) { self.model = model }
    public var id: PluginID { .languageModels }

    public func register(into registrar: inout PluginRegistrar) {
        let model = model
        registrar.service { _ in LanguageModelState(model: model) }
        if let signedIn = model as? SignedInModel {
            registrar.settingsPane(SettingsStyle.claudePane) { AnthropicSettingsView(model: signedIn) }
        }
    }
}

/// Per editor: the model the plugin lends.
@MainActor
final class LanguageModelState {
    let model: any LanguageModel
    init(model: any LanguageModel) { self.model = model }
}

extension LanguageModelState: EditorService {}

extension CanvasEditor {
    /// The model plugins ask: Claude in the app, a scripted one in tests. Nil without
    /// LanguageModelsPlugin.
    public var languageModel: (any LanguageModel)? { service(LanguageModelState.self)?.model }
}

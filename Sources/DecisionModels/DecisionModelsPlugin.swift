import Canvas
import SwiftUI

/// The app's decision model, as a plugin: it lends every editor one model (`editor.decisionModel`)
/// for any plugin to ask yes-or-no questions of, and the answers it gave (`editor.decisions`, which
/// asks the model only what it hasn't answered today). Generic: it knows nothing of what plugins ask
/// it about. Made from nothing (as the product's list makes it), the model is the app's: `JevModel`
/// (TypeSafe's Jev, over the network, with the key saved in Settings), and its answers are kept in a
/// file in Application Support (`DecisionMemory.standard()`). That reaches outside the process, so
/// the plugin is an `OutwardPlugin`: anything but the app that loads the list hands over its own, and
/// tests pass a `ScriptedDecisionModel`, its answers kept in memory, so no test ever reaches the
/// network or the user's files.
///
/// A model that needs a key brings the Settings pane that keeps it: Jev's is its own key store's,
/// so the pane and the model read one key, and a list given another model has no TypeSafe pane.
extension PluginID {
    public static let decisionModels: PluginID = "decision-models"
}

public struct DecisionModelsPlugin: OutwardPlugin {
    let model: any DecisionModel
    let memory: DecisionMemory

    public init() { self.init(model: JevModel(keys: .standard), memory: .standard()) }
    /// `model`, its answers kept by `memory` (by default in memory only, for this plugin's editors).
    public init(model: any DecisionModel, memory: DecisionMemory? = nil) {
        self.model = model
        self.memory = memory ?? DecisionMemory(url: nil)
    }
    public var id: PluginID { .decisionModels }

    public func register(into registrar: inout PluginRegistrar) {
        let model = model, memory = memory
        registrar.service { Decisions(model: model, memory: memory, editor: $0) }
        if let jev = model as? JevModel {
            let keys = jev.keys
            registrar.settingsPane(TypeSafeSettingsView.pane) { TypeSafeSettingsView(keys: keys) }
        }
    }
}

/// Per editor: the model the plugin lends, and what it answered. A plugin asks through `decide`,
/// which answers from the memory what was asked today and asks the model the rest.
@MainActor
public final class Decisions {
    /// The model asked.
    public let model: any DecisionModel
    /// What it answered.
    public let memory: DecisionMemory
    private weak var editor: CanvasEditor?
    private var saving: ScheduledTask?

    init(model: any DecisionModel, memory: DecisionMemory, editor: CanvasEditor) {
        self.model = model
        self.memory = memory
        self.editor = editor
    }

    /// The answers to `request`: kept ones if the model answered it today, else the model's, kept
    /// (written to the memory's file a second after the last). Cancelling the asking task throws
    /// `.cancelled`.
    public func decide(_ request: DecisionRequest) async throws(DecisionModelError) -> DecisionAnswers {
        if let kept = memory.answers(to: request, from: model) { return kept }
        let answers = try await model.decide(request)
        memory.keep(answers, to: request, from: model)
        saving?.cancel()
        saving = editor?.scheduler.schedule(after: .seconds(1)) { [memory] in memory.save() }
        return answers
    }

    isolated deinit {
        saving?.cancel()
        memory.save()
    }
}

extension Decisions: EditorService {}

extension CanvasEditor {
    /// What plugins ask yes-or-no questions through: the model, and its answers kept. Nil without
    /// DecisionModelsPlugin.
    public var decisions: Decisions? { service(Decisions.self) }

    /// The model plugins ask yes-or-no questions of: Jev in the app, a scripted one in tests. Nil
    /// without DecisionModelsPlugin.
    public var decisionModel: (any DecisionModel)? { decisions?.model }
}

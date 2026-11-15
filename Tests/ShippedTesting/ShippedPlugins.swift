import AppKit
import Canvas
import Clipboard
import DecisionModels
import EmbeddingModels
import LanguageModels
import StickyNotes
import TestKit

/// The product's plugins, for the tests of what ships: the list the app is made of (`ShippedList`,
/// Package.swift's table, which the build puts in a test executable whose line ends `+ shipped`),
/// each plugin made by its name, with a pasteboard and three models of the test's own in place of
/// the four that reach outside the process (`OutwardPlugin`: the clipboard's, the language model's,
/// the decision model's and the embedding model's). So a test checks exactly what ships, and reaches
/// neither the network nor the user's pasteboard or files.
///
/// `model` has no default, so no test asks the real model by leaving it out: every test passes a
/// `ScriptedLanguageModel`, but the two live ones. The decision model is a `ScriptedDecisionModel`
/// unless a test passes its own (`decisionModel:`), so every call site that has no use for one
/// reads as before and none reaches TypeSafe; the embedding model is a hashing
/// `ScriptedEmbeddingModel` unless a test passes its own (`embeddingModel:`), its vectors kept in
/// memory only, so none reaches OpenAI or the vector file. The list itself refuses to load without
/// all four plugins (`ShippedListError.notSupplied`), and only the app and its extension may load
/// it whole.
@MainActor
public enum ShippedPlugins {
    /// The test's own pasteboard, which `plugins`, `registry` and `makeEditor` take when a test
    /// passes none: made when the test first asks, so its editors share it (two boards cutting and
    /// pasting between them), and released as the test ends (TestKit's `afterThisTest`), so no test
    /// sees what another copied, and none touches the user's.
    public static var pasteboard: NSPasteboard {
        if let testPasteboard { return testPasteboard }
        let made = NSPasteboard.withUniqueName()
        testPasteboard = made
        afterThisTest {
            made.releaseGlobally()
            if testPasteboard === made { testPasteboard = nil }
        }
        return made
    }

    private static var testPasteboard: NSPasteboard?

    /// The shipped list, its clipboard on `pasteboard`, its language model `model`, its decision
    /// model `decisionModel` and its embedding model `embeddingModel`.
    public static func plugins(pasteboard: NSPasteboard = ShippedPlugins.pasteboard, model: any LanguageModel,
                               decisionModel: any DecisionModel = ScriptedDecisionModel(),
                               embeddingModel: any EmbeddingModel = ScriptedEmbeddingModel.hashing()) -> [any CanvasPlugin] {
        do {
            return try ShippedList.plugins(supplying: [ClipboardPlugin(pasteboard: pasteboard), LanguageModelsPlugin(model: model),
                                                       DecisionModelsPlugin(model: decisionModel),
                                                       EmbeddingModelsPlugin(model: embeddingModel)])
        } catch {
            fatalError("The shipped plugins don't load: \(error)")   // ShippedTests' first test says why
        }
    }

    public static func registry(pasteboard: NSPasteboard = ShippedPlugins.pasteboard, model: any LanguageModel,
                                decisionModel: any DecisionModel = ScriptedDecisionModel(),
                                embeddingModel: any EmbeddingModel = ScriptedEmbeddingModel.hashing()) throws(RegistryError) -> Registry {
        try Registry(plugins: plugins(pasteboard: pasteboard, model: model, decisionModel: decisionModel, embeddingModel: embeddingModel))
    }

    /// An editor of the shipped plugins, on the sample board (`SampleBoard`) unless `document` says.
    public static func makeEditor(document: CanvasDocument = SampleBoard.document(), scheduler: any Scheduler = TaskScheduler(),
                                  pasteboard: NSPasteboard = ShippedPlugins.pasteboard, model: any LanguageModel,
                                  decisionModel: any DecisionModel = ScriptedDecisionModel(),
                                  embeddingModel: any EmbeddingModel = ScriptedEmbeddingModel.hashing()) -> CanvasEditor {
        do {
            return CanvasEditor(registry: try registry(pasteboard: pasteboard, model: model, decisionModel: decisionModel,
                                                       embeddingModel: embeddingModel),
                                document: document, scheduler: scheduler)
        } catch {
            fatalError("The shipped plugins don't register: \(error)")   // ShippedTests catches this first
        }
    }
}

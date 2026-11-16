import AppKit
import Canvas
import Clipboard
import DecisionModels
import EmbeddingModels
import LanguageModels
import Neighbors
import StickyNotes
import TestKit

/// The product's plugins, for the tests of what ships: the list the app is made of (`ShippedList`,
/// Package.swift's table, which the build puts in a test executable whose line ends `+ shipped`),
/// each plugin made by its name, with a pasteboard and three models of the test's own in place of
/// the four that reach outside the process (`OutwardPlugin`: the clipboard's, the language model's,
/// the decision model's and the embedding model's), and Neighbors with settings of the test's own in
/// place of the system's Reduce Motion (`reach`). So a test checks exactly what ships, and reaches neither
/// the network nor the user's pasteboard, files or preferences.
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

    /// The test's own reach settings (the pulse on, whatever the system's Reduce Motion), which `plugins`,
    /// `registry` and `makeEditor` take when a test passes none: so no test reads the system's setting.
    public static var reach: ReachSettings { ReachSettings(reducesMotion: { false }) }

    /// The shipped list, its clipboard on `pasteboard`, its language model `model`, its decision
    /// model `decisionModel`, its embedding model `embeddingModel` and its reach's settings `reach`.
    public static func plugins(pasteboard: NSPasteboard = ShippedPlugins.pasteboard, model: any LanguageModel,
                               decisionModel: any DecisionModel = ScriptedDecisionModel(),
                               embeddingModel: any EmbeddingModel = ScriptedEmbeddingModel.hashing(),
                               reach: ReachSettings = ShippedPlugins.reach) -> [any CanvasPlugin] {
        do {
            return try ShippedList.plugins(supplying: [ClipboardPlugin(pasteboard: pasteboard), LanguageModelsPlugin(model: model),
                                                       DecisionModelsPlugin(model: decisionModel),
                                                       EmbeddingModelsPlugin(model: embeddingModel), NeighborsPlugin(reach: reach)])
        } catch {
            fatalError("The shipped plugins don't load: \(error)")   // ShippedTests' first test says why
        }
    }

    public static func registry(pasteboard: NSPasteboard = ShippedPlugins.pasteboard, model: any LanguageModel,
                                decisionModel: any DecisionModel = ScriptedDecisionModel(),
                                embeddingModel: any EmbeddingModel = ScriptedEmbeddingModel.hashing(),
                                reach: ReachSettings = ShippedPlugins.reach) throws(RegistryError) -> Registry {
        try Registry(plugins: plugins(pasteboard: pasteboard, model: model, decisionModel: decisionModel, embeddingModel: embeddingModel, reach: reach))
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

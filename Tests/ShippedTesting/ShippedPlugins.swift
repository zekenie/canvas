import AppKit
import Canvas
import Clipboard
import LanguageModels
import StickyNotes
import TestKit

/// The product's plugins, for the tests of what ships: the list the app is made of (`ShippedList`,
/// Package.swift's table, which the build puts in a test executable whose line ends `+ shipped`),
/// each plugin made by its name, with a pasteboard and a language model of the test's own in place
/// of the two that reach outside the process (`OutwardPlugin`: the clipboard's and the language
/// model's). So a test checks exactly what ships, and reaches neither the network nor the user's
/// pasteboard.
///
/// `model` has no default, so no test asks the real model by leaving it out: every test passes a
/// `ScriptedLanguageModel`, but the two live ones. The list itself refuses to load without both
/// plugins (`ShippedListError.notSupplied`), and only the app and its extension may load it whole.
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

    /// The shipped list, its clipboard on `pasteboard` and its language model `model`.
    public static func plugins(pasteboard: NSPasteboard = ShippedPlugins.pasteboard, model: any LanguageModel) -> [any CanvasPlugin] {
        do {
            return try ShippedList.plugins(supplying: [ClipboardPlugin(pasteboard: pasteboard), LanguageModelsPlugin(model: model)])
        } catch {
            fatalError("The shipped plugins don't load: \(error)")   // ShippedTests' first test says why
        }
    }

    public static func registry(pasteboard: NSPasteboard = ShippedPlugins.pasteboard, model: any LanguageModel) throws(RegistryError) -> Registry {
        try Registry(plugins: plugins(pasteboard: pasteboard, model: model))
    }

    /// An editor of the shipped plugins, on the sample board (`SampleBoard`) unless `document` says.
    public static func makeEditor(document: CanvasDocument = SampleBoard.document(), scheduler: any Scheduler = TaskScheduler(),
                                  pasteboard: NSPasteboard = ShippedPlugins.pasteboard, model: any LanguageModel) -> CanvasEditor {
        do {
            return CanvasEditor(registry: try registry(pasteboard: pasteboard, model: model), document: document, scheduler: scheduler)
        } catch {
            fatalError("The shipped plugins don't register: \(error)")   // ShippedTests catches this first
        }
    }
}

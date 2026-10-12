import AppKit
import Canvas
import CanvasTesting
import DetailPanel
import Keyboard
import Observation
import Selection
import SwiftUI
import TestKit

/// What a takeover's content reads and writes: whether it's active, the text its field holds, and
/// what Escape ran, in order.
@Observable @MainActor final class TakeoverModel {
    var active = false
    var text = ""
    @ObservationIgnored var log: [String] = []
}

/// Gives the panel a takeover, as a plugin does: active while `model` says, a text field whose
/// placeholder is `name`, and Escape noted in `model.log`.
private struct TakeoverPlugin: CanvasPlugin {
    let model: TakeoverModel
    var name = "Takeover"
    var id: PluginID { PluginID(name.lowercased()) }

    func register(into registrar: inout PluginRegistrar) {
        let model = model, name = name
        registrar.detailTakeover(isActive: { _ in model.active }, onEscape: { _ in model.log.append("escape") }) { _, _ in
            TakeoverField(model: model, name: name)
        }
    }
}

private struct TakeoverField: View {
    @Bindable var model: TakeoverModel
    let name: String
    var body: some View { TextField(name, text: $model.text) }
}

@MainActor let takeoverTests = Suite("Panel overview and takeovers", [
    test("active, a takeover shows in place of the selection's panel and the overview; inactive, the panel is as it was") {
        let model = TakeoverModel()
        let editor = try gadgetEditor([OverviewPlugin(), TakeoverPlugin(model: model)], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let box = editor.add(Box(gadgetFrame))
        panel.window.spin { panel.fields.map(\.placeholderString) == ["Overview"] }
        editor.selection = box
        panel.window.spin { panel.fields.map(\.stringValue) == ["240 pt", "160 pt", "80 pt", "40 pt"] }
        model.active = true
        panel.window.spin { panel.fields.map(\.placeholderString) == ["Takeover"] }
        expectEqual(panel.fields.count, 1, "the selection's fields are gone")
        editor.selection = nil
        panel.window.settle()
        expectEqual(panel.fields.map(\.placeholderString), ["Takeover"], "no selection: still the takeover, not the overview")
        model.active = false
        panel.window.spin { panel.fields.map(\.placeholderString) == ["Overview"] }
        editor.selection = box
        panel.window.spin { panel.fields.map(\.stringValue) == ["240 pt", "160 pt", "80 pt", "40 pt"] }
    },
    test("the overview and a takeover are the panel's points: the report names them, and a list without the panel refuses either") {
        let registry = try Registry(plugins: [DetailPanelPlugin(), OverviewPlugin(), TakeoverPlugin(model: TakeoverModel())])
        let lines = registry.report.split(separator: "\n")
        expect(lines.contains { $0.hasPrefix("overview ") && $0.hasSuffix(" detail overview") }, registry.report)
        expect(lines.contains { $0.hasPrefix("takeover ") && $0.hasSuffix(" detail takeover") }, registry.report)
        expectThrows(RegistryError.ownerNotInstalled(point: "DetailOverviews", owner: .detailPanel, contributor: "overview")) {
            _ = try Registry(plugins: [OverviewPlugin()])
        }
        expectThrows(RegistryError.ownerNotInstalled(point: "DetailTakeovers", owner: .detailPanel, contributor: "takeover")) {
            _ = try Registry(plugins: [TakeoverPlugin(model: TakeoverModel())])
        }
    },
    test("the panel has one overview: a second is a conflict") {
        expectThrows(RegistryError.conflict(point: "DetailOverviews", key: "overview", plugins: ["overview", "second"])) {
            _ = try Registry(plugins: [DetailPanelPlugin(), OverviewPlugin(), OverviewPlugin(name: "Second")])
        }
    },
    test("of several takeovers the first that's active shows, in plugin order, and Escape is its own") {
        let first = TakeoverModel(), second = TakeoverModel()
        let editor = try gadgetEditor([TakeoverPlugin(model: first, name: "First"), TakeoverPlugin(model: second, name: "Second")], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        second.active = true
        panel.window.spin { panel.fields.map(\.placeholderString) == ["Second"] }
        first.active = true
        panel.window.spin { panel.fields.map(\.placeholderString) == ["First"] }
        panel.window.focus(try panel.field("First"))
        panel.window.pressEscape()
        panel.window.spin { panel.canvasHasKeyboard }
        expectEqual(first.log, ["escape"])
        expectEqual(second.log, [], "the one that isn't shown hears nothing")
        first.active = false
        panel.window.spin { panel.fields.map(\.placeholderString) == ["Second"] }
    },
    test("the panel is the window's inspector: wanted while a takeover is active, and dismissed as Escape escapes it") {
        let model = TakeoverModel()
        let editor = try gadgetEditor([TakeoverPlugin(model: model)])
        let inspector = try require(editor.registry.hostInspector)
        expect(!inspector.isRequested(editor), "the person's to show or hide")
        model.active = true
        expect(inspector.isRequested(editor))
        inspector.onDismiss(editor)
        expectEqual(model.log, ["escape"], "the takeover's own escape")
        model.active = false
        inspector.onDismiss(editor)
        expectEqual(model.log, ["escape"], "nothing to escape")
        let lines = editor.registry.report.split(separator: "\n")
        expect(lines.contains { $0.hasPrefix("detail-panel ") && $0.hasSuffix(" host inspector") }, editor.registry.report)
        expect(try Registry(plugins: [KeyboardPlugin(), SelectionPlugin()]).hostInspector == nil, "no panel, no inspector")
    },
    test("typing goes to the takeover's field; Escape in it runs onEscape, then onExit, and hands the keyboard to the canvas") {
        let model = TakeoverModel()
        model.active = true
        let editor = try gadgetEditor([TakeoverPlugin(model: model)], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        panel.window.spin { !panel.fields.isEmpty }
        panel.window.focus(try panel.field("Takeover"))
        panel.window.type("abc")
        expectEqual(model.text, "abc")
        expectEqual(editor.currentToolID, .select, "typing never switched tools")
        panel.window.pressEscape()
        panel.window.spin { panel.canvasHasKeyboard }
        expectEqual(model.log, ["escape"])
        expectEqual(panel.exits, 1, "onEscape ran, then onExit")
    },
    test("⌘. in the takeover's field does the same") {
        let model = TakeoverModel()
        model.active = true
        let editor = try gadgetEditor([TakeoverPlugin(model: model)], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        panel.window.spin { !panel.fields.isEmpty }
        panel.window.focus(try panel.field("Takeover"))
        panel.window.pressCommandPeriod()
        panel.window.spin { panel.canvasHasKeyboard }
        expectEqual(model.log, ["escape"])
        expectEqual(panel.exits, 1)
    },
    test("inactive, Escape never reaches onEscape") {
        let model = TakeoverModel()
        let editor = try gadgetEditor([TakeoverPlugin(model: model)], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let id = editor.add(Gadget(gadgetFrame))
        editor.selection = id
        panel.window.spin { !panel.fields.isEmpty }
        panel.window.focus(try panel.field("Name"))
        panel.window.pressEscape()
        panel.window.spin { panel.canvasHasKeyboard }
        expectEqual(model.log, [])
        expectEqual(panel.exits, 1)
    },
])

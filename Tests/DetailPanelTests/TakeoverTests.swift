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

@MainActor private func takeover(_ model: TakeoverModel) -> DetailTakeover {
    DetailTakeover(isActive: { _ in model.active }, onEscape: { model.log.append("escape") }) {
        TakeoverField(model: model)
    }
}

private struct TakeoverField: View {
    @Bindable var model: TakeoverModel
    var body: some View { TextField("Takeover", text: $model.text) }
}

@MainActor let takeoverTests = Suite("Panel takeover", [
    test("active, it shows in place of the selection's panel and the overview; inactive, the panel is as it was") {
        let editor = try gadgetEditor(scheduler: TaskScheduler())
        let model = TakeoverModel()
        let panel = PanelWindow(editor, withOverview: true, takeover: takeover(model))
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
    test("it outranks the No Details branch, where there's no panel state") {
        let editor = CanvasEditor(registry: try Registry(plugins: [KeyboardPlugin(), SelectionPlugin()]), file: CanvasFile(), scheduler: TaskScheduler())
        expect(editor.detailPanel == nil)
        let model = TakeoverModel()
        model.active = true
        let panel = PanelWindow(editor, takeover: takeover(model))
        panel.window.spin { panel.fields.map(\.placeholderString) == ["Takeover"] }
    },
    test("typing goes to the takeover's field; Escape in it runs onEscape, then onExit, and hands the keyboard to the canvas") {
        let editor = try gadgetEditor(scheduler: TaskScheduler())
        let model = TakeoverModel()
        model.active = true
        let panel = PanelWindow(editor, takeover: takeover(model))
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
        let editor = try gadgetEditor(scheduler: TaskScheduler())
        let model = TakeoverModel()
        model.active = true
        let panel = PanelWindow(editor, takeover: takeover(model))
        panel.window.spin { !panel.fields.isEmpty }
        panel.window.focus(try panel.field("Takeover"))
        panel.window.pressCommandPeriod()
        panel.window.spin { panel.canvasHasKeyboard }
        expectEqual(model.log, ["escape"])
        expectEqual(panel.exits, 1)
    },
    test("inactive, Escape never reaches onEscape") {
        let editor = try gadgetEditor(scheduler: TaskScheduler())
        let model = TakeoverModel()
        let panel = PanelWindow(editor, takeover: takeover(model))
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

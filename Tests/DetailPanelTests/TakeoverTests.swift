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

/// What a band's content reads and writes: whether it's active, the text its field holds, and what
/// cancelling it ran, in order.
@Observable @MainActor final class BandModel {
    var active = false
    var text = ""
    @ObservationIgnored var log: [String] = []
    /// Runs as the band is cancelled, for a test to see what the panel had done by then.
    @ObservationIgnored var onCancel: (@MainActor () -> Void)?
}

/// Gives the panel a band, as a plugin does: active while `model` says, a text field whose placeholder
/// is `name` and a button, or with `hasControls` false text alone (nothing the keys reach); cancelling
/// it is noted in `model.log`.
struct BandPlugin: CanvasPlugin {
    let model: BandModel
    var name = "Band"
    var hasControls = true
    /// A band that is one button and nothing else: reached by the keys only with Keyboard navigation on.
    var buttonOnly = false
    var id: PluginID { PluginID(name.lowercased()) }

    func register(into registrar: inout PluginRegistrar) {
        let model = model, name = name, hasControls = hasControls, buttonOnly = buttonOnly
        registrar.detailBand(isActive: { _ in model.active }, onCancel: { _ in
            model.log.append("cancel")
            model.onCancel?()
        }) { _, _ in
            BandContent(model: model, name: name, hasControls: hasControls, buttonOnly: buttonOnly)
        }
    }
}

private struct BandContent: View {
    @Bindable var model: BandModel
    let name: String
    let hasControls: Bool
    let buttonOnly: Bool
    var body: some View {
        // Borderless, as the panel's own band buttons are (`DetailCommandButton`): an AppKit button a test finds,
        // where a plain SwiftUI one is drawn with none.
        HStack {
            if buttonOnly {
                Button("Done") {}.buttonStyle(.borderless)
            } else if hasControls {
                TextField(name, text: $model.text)
                Button("Done") {}.buttonStyle(.borderless)
            } else {
                Text(name)
            }
        }
        // In the window's title bar's row while the panel is under one, as the issue walk's band is.
        .detailTitleRow(else: EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
    }
}

@MainActor let takeoverTests = Suite("Panel takeovers", [
    test("Next and Previous Inspector Tab step only the tabs the panel shows: not under a takeover") {
        let takeover = TakeoverModel()
        let editor = try gadgetEditor([WalkersPlugin(), TakeoverPlugin(model: takeover)], scheduler: TaskScheduler())
        let id = editor.add(Walker(gadgetFrame))
        editor.selection = id
        let state = try require(editor.detailPanel)
        @MainActor func tab() throws -> DetailTabID? { state.currentTab(in: try editor.layout(id), for: Walker.kind) }
        expectEqual(state.canStepTab, true)
        takeover.active = true
        expectEqual(state.canStepTab, false, "a takeover is in the tabs' place")
        expect(!state.stepTab(by: -1))
        expectEqual(try tab(), .of(WalkerTab.self), "and the remembered tab was not changed")
        takeover.active = false
        expect(state.stepTab(by: 1))
        expectEqual(try tab(), .of(SecondWalkerTab.self))
    },
    test("active, a takeover shows in place of the selection's panel, and with nothing selected; inactive, the panel is as it was") {
        let model = TakeoverModel()
        let editor = try gadgetEditor([TakeoverPlugin(model: model)], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let box = editor.add(Box(gadgetFrame))
        panel.window.settle()
        expectEqual(panel.fields.count, 0, "nothing selected, nothing to show")
        editor.selection = box
        panel.window.spin { panel.fields.map(\.stringValue) == ["240 pt", "160 pt", "80 pt", "40 pt"] }
        model.active = true
        panel.window.spin { panel.fields.map(\.placeholderString) == ["Takeover"] }
        expectEqual(panel.fields.count, 1, "the selection's fields are gone")
        editor.selection = nil
        panel.window.settle()
        expectEqual(panel.fields.map(\.placeholderString), ["Takeover"], "no selection: still the takeover")
        model.active = false
        panel.window.spin { panel.fields.isEmpty }
        editor.selection = box
        panel.window.spin { panel.fields.map(\.stringValue) == ["240 pt", "160 pt", "80 pt", "40 pt"] }
    },
    test("a takeover is the panel's point: the report names it, and a list without the panel refuses it") {
        let registry = try Registry(plugins: [KeyboardPlugin(), DetailPanelPlugin(), TakeoverPlugin(model: TakeoverModel())])
        let lines = registry.report.split(separator: "\n")
        expect(lines.contains { $0.hasPrefix("takeover ") && $0.hasSuffix(" detail takeover") }, registry.report)
        expectThrows(RegistryError.ownerNotInstalled(point: "DetailTakeovers", owner: .detailPanel, contributor: "takeover")) {
            _ = try Registry(plugins: [TakeoverPlugin(model: TakeoverModel())])
        }
    },
    test("hasTakeover(over:) says whether a takeover listed before a plugin's own is active, so it shows in place of it") {
        let first = TakeoverModel(), second = TakeoverModel()
        let editor = try gadgetEditor([TakeoverPlugin(model: first, name: "First"), TakeoverPlugin(model: second, name: "Second")])
        let state = try require(editor.detailPanel)
        expect(!state.hasTakeover(over: "first") && !state.hasTakeover(over: "second"), "none is active")
        second.active = true
        expect(!state.hasTakeover(over: "second"), "its own is not over it")
        expect(!state.hasTakeover(over: "first"), "one listed after it does not cover it")
        first.active = true
        expect(state.hasTakeover(over: "second"), "the first, active, shows in place of the second")
        expect(!state.hasTakeover(over: "first"))
        expect(state.hasTakeover(over: "other"), "a plugin with none: any active one")
        first.active = false
        second.active = false
        expect(!state.hasTakeover(over: "other"))
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
    test("the panel is the window's inspector: with something to show while shapes are selected, wanted while a takeover is active, and dismissed as Escape escapes it") {
        let model = TakeoverModel()
        let editor = try gadgetEditor([TakeoverPlugin(model: model)])
        let inspector = try require(editor.registry.hostInspector)
        expect(!inspector.shownWhile(editor), "nothing selected: nothing to show")
        let a = editor.add(Box(gadgetFrame)), b = editor.add(Box(gadgetFrame.offsetBy(dx: 300, dy: 0)))
        editor.selection = a
        expect(inspector.shownWhile(editor))
        editor.selectedShapeIDs = [a, b]
        expect(inspector.shownWhile(editor), "several: their header")
        editor.selection = nil
        expect(!inspector.isRequested(editor), "the person's to show or hide")
        model.active = true
        expect(inspector.isRequested(editor))
        inspector.onDismiss(editor)
        expectEqual(model.log, ["escape"], "the takeover's own escape")
        model.active = false
        inspector.onDismiss(editor)
        expectEqual(model.log, ["escape"], "nothing to escape")
        let lines = editor.registry.report.split(separator: "\n")
        expect(lines.contains { $0.hasPrefix("detail-panel ") && $0.contains(" host inspector") }, editor.registry.report)
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
    test("an active band shows above whatever the panel shows, the selection's panel and a takeover, and neither is rebuilt for it; inactive, it is gone") {
        let band = BandModel(), takeover = TakeoverModel()
        let editor = try gadgetEditor([BandPlugin(model: band), TakeoverPlugin(model: takeover)], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let box = editor.add(Box(gadgetFrame))
        @MainActor func top(_ field: NSTextField) -> CGFloat { field.convert(field.bounds, to: nil).maxY }
        editor.selection = box
        panel.window.spin { panel.fields.map(\.stringValue).contains("240 pt") }
        let width = try panel.field("240 pt")
        band.active = true
        panel.window.spin { panel.fields.contains { $0.placeholderString == "Band" } }
        expect(panel.fields.contains { $0 === width }, "the shape's panel is the same view")
        expect(top(try panel.field("Band")) > top(width), "over the shape's panel, whose header is under it")
        takeover.active = true
        panel.window.spin { panel.fields.compactMap(\.placeholderString).sorted() == ["Band", "Takeover"] }
        expect(top(try panel.field("Band")) > top(try panel.field("Takeover")), "over a takeover")
        takeover.active = false
        band.active = false
        panel.window.spin { !panel.fields.contains { $0.placeholderString == "Band" } && panel.fields.map(\.stringValue).contains("240 pt") }
    },
    test("of several bands the first that's active shows, in plugin order") {
        let first = BandModel(), second = BandModel()
        let editor = try gadgetEditor([BandPlugin(model: first, name: "First"), BandPlugin(model: second, name: "Second")], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        @MainActor func bands() -> [String] { panel.fields.compactMap(\.placeholderString).filter { $0 == "First" || $0 == "Second" } }
        second.active = true
        panel.window.spin { bands() == ["Second"] }
        first.active = true
        panel.window.spin { bands() == ["First"] }
        first.active = false
        panel.window.spin { bands() == ["Second"] }
        second.active = false
        panel.window.spin { bands().isEmpty }
    },
    test("a band is the panel's point: the report names it, and a list without the panel refuses it") {
        let registry = try Registry(plugins: [KeyboardPlugin(), DetailPanelPlugin(), BandPlugin(model: BandModel())])
        let lines = registry.report.split(separator: "\n")
        expect(lines.contains { $0.hasPrefix("band ") && $0.hasSuffix(" detail band") }, registry.report)
        expectThrows(RegistryError.ownerNotInstalled(point: "DetailBands", owner: .detailPanel, contributor: "band")) {
            _ = try Registry(plugins: [BandPlugin(model: BandModel())])
        }
    },
    test("a band keeps the inspector requested, and hiding the inspector cancels it after the takeover's escape") {
        let band = BandModel(), takeover = TakeoverModel()
        let editor = try gadgetEditor([BandPlugin(model: band), TakeoverPlugin(model: takeover)])
        let inspector = try require(editor.registry.hostInspector)
        expect(!inspector.isRequested(editor))
        band.active = true
        expect(inspector.isRequested(editor), "a band alone is wanted")
        takeover.active = true
        band.onCancel = { expectEqual(takeover.log, ["escape"], "the takeover first") }
        inspector.onDismiss(editor)
        expectEqual(takeover.log, ["escape"])
        expectEqual(band.log, ["cancel"])
        takeover.active = false
        inspector.onDismiss(editor)
        expectEqual(band.log, ["cancel", "cancel"], "a band alone is cancelled")
        band.active = false
        expect(!inspector.isRequested(editor))
        inspector.onDismiss(editor)
        expectEqual(band.log, ["cancel", "cancel"], "nothing to cancel")
    },
    test("Escape goes one level out: the takeover closes, the band has the keyboard, then the canvas has it, the band staying") {
        let band = BandModel(), takeover = TakeoverModel()
        let editor = try gadgetEditor([BandPlugin(model: band), TakeoverPlugin(model: takeover)], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        editor.selection = editor.add(Gadget(gadgetFrame))
        band.active = true
        panel.window.spin { panel.fields.contains { $0.placeholderString == "Band" } && panel.fields.contains { $0.placeholderString == "Name" } }
        let bandField = try panel.field("Band")
        @MainActor func inBand() -> Bool { (panel.window.firstResponder as? NSTextView)?.delegate === bandField }
        panel.window.focus(try panel.field("Name"))
        panel.window.pressEscape()
        panel.window.spin { inBand() }
        expectEqual(panel.exits, 0, "the band has the keyboard, not the canvas")
        panel.window.pressEscape()
        panel.window.spin { panel.canvasHasKeyboard }
        expectEqual(panel.exits, 1, "from the band, the canvas")
        expectEqual(band.log, [], "Escape cancels nothing")
        expect(band.active)
        // Under a takeover: its escape first, and not again from the band.
        takeover.active = true
        panel.window.spin { panel.fields.compactMap(\.placeholderString).contains("Takeover") }
        panel.window.focus(try panel.field("Takeover"))
        panel.window.pressEscape()
        panel.window.spin { inBand() }
        expectEqual(takeover.log, ["escape"])
        expectEqual(panel.exits, 1)
        panel.window.pressEscape()
        panel.window.spin { panel.canvasHasKeyboard }
        expectEqual(takeover.log, ["escape"], "the band's Escape leaves the takeover be")
        expectEqual(panel.exits, 2)
        expectEqual(band.log, [])
    },
    test("Escape with a band the keys don't reach goes out to the canvas") {
        let band = BandModel()
        let editor = try gadgetEditor([BandPlugin(model: band, hasControls: false)], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        editor.selection = editor.add(Gadget(gadgetFrame))
        band.active = true
        panel.window.spin { panel.fields.contains { $0.placeholderString == "Name" } }
        panel.window.focus(try panel.field("Name"))
        expect(try require(editor.detailPanel).focusBand() == false, "nothing to give the keyboard to")
        panel.window.pressEscape()
        panel.window.spin { panel.canvasHasKeyboard }
        expectEqual(panel.exits, 1)
    },
    test("⌘. ends it all: the takeover's escape, the band's cancel, then the canvas has the keyboard, from the takeover or from the band") {
        let band = BandModel(), takeover = TakeoverModel()
        takeover.active = true
        band.active = true
        let editor = try gadgetEditor([BandPlugin(model: band), TakeoverPlugin(model: takeover)], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        panel.window.spin { panel.fields.count == 2 }
        var seen: [String] = []
        band.onCancel = { seen = takeover.log + ["exits \(panel.exits)"] }
        panel.window.focus(try panel.field("Takeover"))
        panel.window.pressCommandPeriod()
        panel.window.spin { panel.canvasHasKeyboard }
        expectEqual(seen, ["escape", "exits 0"], "the takeover first, the canvas last")
        expectEqual(band.log, ["cancel"])
        expectEqual(panel.exits, 1)
        panel.window.focus(try panel.field("Band"))
        panel.window.pressCommandPeriod()
        panel.window.spin { panel.exits == 2 }
        expectEqual(band.log, ["cancel", "cancel"], "from inside the band too")
        expectEqual(takeover.log, ["escape", "escape"])
        // The key after it is no ⌘.'s.
        panel.window.focus(try panel.field("Band"))
        panel.window.pressEscape()
        panel.window.spin { panel.exits == 3 }
        expectEqual(band.log, ["cancel", "cancel"], "Escape cancels nothing")
    },
    test("keyboardPlace says where the keyboard is in the panel: the band, a takeover, the rest, or nowhere; focusBand puts it in the band") {
        let band = BandModel(), takeover = TakeoverModel()
        let editor = try gadgetEditor([BandPlugin(model: band), TakeoverPlugin(model: takeover)], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let state = try require(editor.detailPanel)
        editor.selection = editor.add(Gadget(gadgetFrame))
        panel.window.spin { panel.fields.contains { $0.placeholderString == "Name" } }
        expect(state.keyboardPlace == nil, "the canvas has it")
        expect(!state.focusBand(), "no band")
        panel.window.focus(try panel.field("Name"))
        expect(state.keyboardPlace == .content)
        band.active = true
        panel.window.spin { panel.fields.contains { $0.placeholderString == "Band" } }
        expect(state.keyboardPlace == .content, "the band came, the keyboard didn't move")
        expect(state.focusBand())
        expect(state.keyboardPlace == .band)
        takeover.active = true
        panel.window.spin { panel.fields.compactMap(\.placeholderString).contains("Takeover") }
        panel.window.focus(try panel.field("Takeover"))
        expect(state.keyboardPlace == .takeover)
        panel.window.focus(try panel.field("Band"))
        expect(state.keyboardPlace == .band, "the band's, under the takeover too")
        panel.window.makeFirstResponder(panel.canvas)
        expect(state.keyboardPlace == nil)
    },
    test("focusContent gives the canvas the keyboard when the shape's panel has no control and the window is left with it, once; with the keyboard elsewhere it leaves it be") {
        // A shape whose panel has no control: the kind's header is text, and no plugin gives it a section.
        @MainActor func scene() throws -> (TakeoverModel, PanelWindow, DetailPanelState) {
            let takeover = TakeoverModel()
            let editor = CanvasEditor(registry: try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), DetailPanelPlugin(), TakeoverPlugin(model: takeover)]),
                                      file: CanvasFile(), scheduler: TaskScheduler())
            let panel = PanelWindow(editor)
            editor.selection = editor.add(Box(gadgetFrame))
            panel.window.settle()
            let state = try require(editor.detailPanel)
            takeover.active = true
            panel.window.spin { panel.fields.compactMap(\.placeholderString).contains("Takeover") }
            panel.window.focus(try panel.field("Takeover"))
            takeover.active = false
            panel.window.spin { !panel.fields.compactMap(\.placeholderString).contains("Takeover") }
            return (takeover, panel, state)
        }
        // The takeover's field went with the takeover, and the window is first responder.
        let (_, panel, state) = try scene()
        expect(panel.fields.isEmpty, "the shape's panel has no control: \(panel.fields.map(\.stringValue))")
        panel.window.makeFirstResponder(nil)
        expect(panel.window.firstResponder === panel.window, "the window has the keyboard")
        state.focusContent()
        panel.window.spin { panel.exits == 1 }
        expectEqual(panel.exits, 1, "the panel handed the keyboard back, once")
        expect(panel.canvasHasKeyboard, "and the canvas has it")
        // Let the retries run out: it is not handed back again.
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        expectEqual(panel.exits, 1)
        // The keyboard is somewhere else (the canvas, not the window): nothing is handed back.
        let (_, other, otherState) = try scene()
        other.window.makeFirstResponder(other.canvas)
        otherState.focusContent()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        expectEqual(other.exits, 0, "the keyboard was not left on the window, so onExit did not run")
        expect(other.canvasHasKeyboard)
    },
    test("commitDraft writes a number being typed before a takeover takes the panel over; focusContent gives the keyboard to the shape's panel as the takeover closes") {
        let takeover = TakeoverModel()
        let editor = try gadgetEditor([TakeoverPlugin(model: takeover)], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let state = try require(editor.detailPanel)
        let id = editor.add(Box(gadgetFrame))
        editor.selection = id
        panel.window.spin { !panel.fields.isEmpty }
        panel.window.focus(try panel.field("240 pt"))
        panel.window.type("300")
        expectEqual(editor.document[id]?.box?.width, 240, "a draft")
        state.commitDraft()
        expectEqual(editor.document[id]?.box?.width, 300, "written, as Return writes it")
        state.commitDraft()
        expectEqual(editor.document[id]?.box?.width, 300, "and nothing is left to write")
        // The keyboard was in a field that the takeover removes; the panel it comes back to gets it in its first control.
        takeover.active = true
        panel.window.spin { panel.fields.compactMap(\.placeholderString).contains("Takeover") }
        panel.window.focus(try panel.field("Takeover"))
        expect(state.keyboardPlace == .takeover)
        takeover.active = false
        state.focusContent()
        panel.window.spin { state.keyboardPlace == .content }
        expect(state.keyboardPlace == .content, "the shape's panel has the keyboard")
        expect(panel.window.firstResponder !== panel.canvas)
    },
])

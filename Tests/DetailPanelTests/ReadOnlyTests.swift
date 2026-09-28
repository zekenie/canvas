import AppKit
import Canvas
import CanvasTesting
import DetailPanel
import Selection
import SwiftUI
import TestKit

// A read-only shape (`registrar.readOnlyShapes`; CanvasTesting's `Frozen`, standing in for a lock)
// shows its details, and nothing in them edits it: the panel disables its sections' controls and its
// header's, and leaves what isn't an edit (going back, collapsing a section) as it was.

/// Two command buttons in every box's panel, each running `command`: Run, in a section like any
/// other, and Go, in one that changes nothing of the shape (`enabledWhileReadOnly()`).
struct GoButtonPlugin: CanvasPlugin {
    static let command: CanvasCommand = "test-go"
    let count: RunCount
    var id: PluginID { "go-button" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.command(Self.command) { [count] _ in count.runs += 1 }
        registrar.detailsForEveryBox {
            DetailSection("Run", in: ArrangeTab.self) { _ in
                DetailCommandButton("Run", command: Self.command)
            }
            DetailSection("Go", in: ArrangeTab.self) { _ in
                DetailCommandButton("Go", command: Self.command)
            }
            .enabledWhileReadOnly()
        }
    }
}

@MainActor let readOnlyPanelTests = Suite("A read-only shape's panel", [
    test("its details show, but its fields and controls are disabled, until it can change again") {
        let editor = try gadgetEditor([FreezingPlugin()], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let id = editor.add(Gadget(gadgetFrame, name: "Widget"))
        editor.selection = id
        panel.window.spin { !panel.fields.isEmpty }
        @MainActor func controls() -> [NSControl] {
            panel.fields + panel.hosting.descendants(NSSegmentedControl.self) + panel.steppers
        }
        expect(controls().count >= 3, "\(controls())")
        expect(controls().allSatisfy(\.isEnabled))
        editor.freeze([id])
        panel.window.spin { controls().allSatisfy { !$0.isEnabled } }
        expectEqual(try panel.field("Widget").stringValue, "Widget", "shown as it is")
        editor.freeze([id], false)
        panel.window.spin { controls().allSatisfy(\.isEnabled) }
    },
    test("its header renames nothing, but the back button still goes back") {
        let editor = try gadgetEditor([CardsPlugin(), RenamingCards(), FreezingPlugin()], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let gadget = editor.add(Gadget(gadgetFrame, name: "Widget"))
        let card = editor.add(Card(gadgetFrame, text: "Hi"))
        editor.freeze([gadget, card])
        editor.selection = gadget
        editor.selection = card                   // a step back, so the header has its button
        panel.window.spin { panel.headerField != nil && panel.backButton != nil }
        expect(!(try require(panel.headerField)).isEnabled)
        expect(try require(panel.backButton).isEnabled)
        try require(panel.backButton).performClick(nil)
        panel.window.spin { editor.selection == gadget }
    },
    test("a section that changes nothing of the shape keeps its controls working: only the others are disabled") {
        let count = RunCount()
        let editor = try gadgetEditor([GoButtonPlugin(count: count), FreezingPlugin()], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        let id = editor.add(Box(gadgetFrame))
        editor.selection = id
        try require(editor.detailPanel).choose(.of(ArrangeTab.self), for: Box.kind)
        panel.window.spin { panel.checkboxes.count >= 2 }
        let buttons = panel.checkboxes.suffix(2)
        let run = try require(buttons.first), go = try require(buttons.last)
        expect(run.isEnabled && go.isEnabled)
        editor.freeze([id])
        panel.window.spin { !run.isEnabled }
        expect(go.isEnabled, "Go changes nothing of it")
        go.performClick(nil)
        expectEqual(count.runs, 1)
    },
])

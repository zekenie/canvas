import AppKit
import Canvas
import CanvasTesting
import DetailPanel
import Selection
import TestKit

// A read-only shape (`registrar.readOnlyShapes`; CanvasTesting's `Frozen`, standing in for a lock)
// shows its details, and nothing in them edits it: the panel disables its sections' controls and its
// header's, and leaves what isn't an edit (going back, collapsing a section) as it was.

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
])

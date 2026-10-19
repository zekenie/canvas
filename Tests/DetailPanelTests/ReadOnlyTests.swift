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
        registrar.command(Self.command, "Command") { [count] _ in count.runs += 1 }
        registrar.detailsForEveryBox {
            DetailSection("Run", in: FrameTab.self) { _ in
                DetailCommandButton("Run", command: Self.command)
            }
            DetailSection("Go", in: FrameTab.self) { _ in
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
        try require(editor.detailPanel).choose(.of(FrameTab.self), for: Box.kind)
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
    test("a shape on a locked subboard's board shows read-only too: its panel follows the lock above the board, as it lands in a commit on another board, and as it goes") {
        let pocket = ShapeRecord(Pocket(CGRect(x: 2000, y: 0, width: 100, height: 100)))
        let id = ShapeID()
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(pocket)]),
                              children: [pocket.id: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: id, Gadget(gadgetFrame, name: "Widget")))])])
        let editor = try gadgetEditor([FreezingPlugin(), PocketsPlugin()], file: file, scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        expect(editor.showBoard(BoardID(owner: pocket.id)))
        editor.selection = id
        panel.window.spin { !panel.fields.isEmpty }
        @MainActor func controls() -> [NSControl] {
            panel.fields + panel.hosting.descendants(NSSegmentedControl.self) + panel.steppers
        }
        expect(controls().count >= 3, "\(controls())")
        expect(controls().allSatisfy(\.isEnabled))
        let record = editor.document[id]
        editor.transact(on: .root, "Freeze") { $0.update(pocket.id) { $0[Frozen.self] = true } }
        panel.window.spin { controls().allSatisfy { !$0.isEnabled } }
        expect(editor.isReadOnly(id))
        expectEqual(editor.document[id], record, "its record as it was: the board's lock is what changed")
        expectEqual(try panel.field("Widget").stringValue, "Widget", "shown as it is")
        editor.transact(on: .root, "Thaw") { $0.update(pocket.id) { $0[Frozen.self] = nil } }
        panel.window.spin { controls().allSatisfy(\.isEnabled) }
        expect(!editor.isReadOnly(id))
    },
    test("a shape in a read-only container shows read-only too, at any depth: its panel follows the container's lock, and nothing else draws it again") {
        let editor = try gadgetEditor([FreezingPlugin(), CorralsPlugin()], scheduler: TaskScheduler())
        let state = try require(editor.detailPanel)
        let panel = PanelWindow(editor)
        let outer = editor.add(Corral(CGRect(x: 0, y: 0, width: 900, height: 700)))
        let inner = editor.add(Corral(CGRect(x: 40, y: 20, width: 600, height: 500)))
        let id = editor.add(Gadget(gadgetFrame, name: "Widget"))
        let other = editor.add(Gadget(CGRect(x: 2000, y: 0, width: 240, height: 160), name: "Other"))
        editor.put([inner], in: outer)
        editor.put([id], in: inner)
        editor.selection = id
        panel.window.spin { !panel.fields.isEmpty }
        @MainActor func controls() -> [NSControl] {
            panel.fields + panel.hosting.descendants(NSSegmentedControl.self) + panel.steppers
        }
        expect(controls().count >= 3, "\(controls())")
        expect(controls().allSatisfy(\.isEnabled))
        let record = editor.document[id]
        editor.freeze([outer])                  // two containers up
        panel.window.spin { controls().allSatisfy { !$0.isEnabled } }
        expect(editor.isReadOnly(id))
        expectEqual(editor.document[id], record, "its record as it was: the container's lock is what changed")
        expectEqual(try panel.field("Widget").stringValue, "Widget", "shown as it is")
        panel.window.settle()
        let drawn = state.panelsDrawn
        editor.transact { $0.translate([other], by: CGPoint(x: 10, y: 0)) }
        editor.freeze([other])
        panel.window.settle()
        expectEqual(state.panelsDrawn, drawn, "another shape's commits draw it no more")
        editor.freeze([outer], false)
        panel.window.spin { controls().allSatisfy(\.isEnabled) }
        editor.freeze([inner])                  // its own container
        panel.window.spin { controls().allSatisfy { !$0.isEnabled } }
        editor.freeze([inner], false)
        panel.window.spin { controls().allSatisfy(\.isEnabled) }
        editor.put([id], in: nil)               // out of it, the corral's lock isn't the gadget's
        editor.freeze([inner, outer])
        panel.window.settle()
        expect(controls().allSatisfy(\.isEnabled))
        expect(!editor.isReadOnly(id))
    },
])

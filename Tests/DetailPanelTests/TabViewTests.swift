import AppKit
import Canvas
import CanvasTesting
import DetailPanel
import SwiftUI
import TestKit

// One tab of a shape's panel drawn on its own (`DetailTabView`), as the panel draws it: its status
// lines, then its sections, live.

/// A status line in the walker's second tab, with a button.
private struct SecondTabLine: CanvasPlugin {
    var id: PluginID { "second-line" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.forEveryShape { scope in
            scope.detailStatus(in: SecondWalkerTab.self) { _, _ in
                [DetailStatus("Second tab line", tone: .warning, actions: [DetailStatusAction("Fix it") {}])]
            }
        }
    }
}

@MainActor private func host(_ view: some View, in window: NSWindow) -> NSHostingView<AnyView> {
    let hosting = NSHostingView(rootView: AnyView(view.frame(width: 300, height: 500)))
    hosting.frame = CGRect(x: 0, y: 0, width: 300, height: 500)
    window.contentView = hosting
    window.settle()
    return hosting
}

@MainActor let tabViewTests = Suite("Panel tab view", [
    test("a tab draws its sections and nothing of the other tabs, its status lines first, and follows the shape") {
        let editor = try gadgetEditor([WalkersPlugin(), SecondTabLine()], scheduler: TaskScheduler())
        let id = editor.add(Walker(gadgetFrame))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 500), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let second = host(DetailTabView(editor: editor, shape: id, tab: SecondWalkerTab.self), in: window)
        window.spin { !second.descendants(NSTextView.self).isEmpty }
        let labels = second.descendants(NSTextView.self).map { $0.accessibilityLabel() }
        expectEqual(labels, ["More notes"], "the Second tab's one box, not the first tab's")
        // Its status line's button, above the box: the lines lead.
        let buttons = second.descendants(NSButton.self)
        expectEqual(buttons.count, 1, "the line's button")
        if let button = buttons.first, let box = second.descendants(NSTextView.self).first {
            expect(button.convert(button.bounds, to: nil).minY > box.convert(box.bounds, to: nil).maxY, "above the box")
        }
        // It reads the shape live.
        editor.transact("Notes") { $0.update(id, as: Walker.self) { $0.props.notes = "typed elsewhere" } }
        window.spin { second.descendants(NSTextView.self).first?.string == "typed elsewhere" }
        expectEqual(second.descendants(NSTextView.self).first?.string, "typed elsewhere")
        // The first tab: its own boxes, a list and a checkbox.
        let first = host(DetailTabView(editor: editor, shape: id, tab: .of(WalkerTab.self)), in: window)
        window.spin { first.descendants(NSTextView.self).count >= 2 && !first.descendants(NSTableView.self).isEmpty }
        expectEqual(first.descendants(NSTextView.self).compactMap { $0.accessibilityLabel() }.sorted(), ["Code", "Notes"])
        let table = try require(first.descendants(NSTableView.self).first)
        let checkboxes = first.descendants(NSButton.self).filter { !$0.isDescendant(of: table) }
        expectEqual(checkboxes.count, 1, "the one checkbox, Allowed, beside the list's row buttons")
    },
    test("a tab the shape has nothing in, and a shape that is gone, draw nothing") {
        let editor = try gadgetEditor([WalkersPlugin()], scheduler: TaskScheduler())
        let id = editor.add(Walker(gadgetFrame))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 500), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let empty = host(DetailTabView(editor: editor, shape: id, tab: RemarksTab.self), in: window)
        expect(empty.descendants(NSTextView.self).isEmpty && empty.descendants(NSTableView.self).isEmpty)
        let view = host(DetailTabView(editor: editor, shape: id, tab: SecondWalkerTab.self), in: window)
        window.spin { !view.descendants(NSTextView.self).isEmpty }
        editor.transact("Delete") { $0.delete([id]) }
        window.spin { view.descendants(NSTextView.self).isEmpty }
        expect(view.descendants(NSTextView.self).isEmpty, "gone with its shape")
    },
    test("a section that is shown while a service says so is absent until it does, on a commit that writes nothing to the shape") {
        let editor = try gadgetEditor([watchingPlugin], scheduler: TaskScheduler())
        let watchers = try require(editor.watchers)
        let id = editor.add(Gadget(gadgetFrame))
        let other = editor.add(Box(gadgetFrame.offsetBy(dx: 400, dy: 0)))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 500), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = host(DetailTabView(editor: editor, shape: id, tab: WatchTab.self), in: window)
        expect(view.descendants(NSTextField.self).filter(\.isEditable).isEmpty, "not watched: nothing")
        watchers.watched.insert(id)
        editor.transact("Elsewhere") { $0.update(other, as: Box.self) { $0.frame.size.width += 1 } }
        window.spin { view.descendants(NSTextField.self).contains { $0.isEditable } }
        expectEqual(view.descendants(NSTextField.self).filter(\.isEditable).count, 1, "watched: its one field")
        watchers.watched = []
        editor.transact("Elsewhere") { $0.update(other, as: Box.self) { $0.frame.size.width += 1 } }
        window.spin { view.descendants(NSTextField.self).filter(\.isEditable).isEmpty }
        expect(view.descendants(NSTextField.self).filter(\.isEditable).isEmpty, "and gone again")
    },
    test("a folded section loses its body, and unfolds") {
        let editor = try gadgetEditor(scheduler: TaskScheduler())
        let id = editor.add(Gadget(gadgetFrame))
        let state = try require(editor.detailPanel)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 500), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = host(DetailTabView(editor: editor, shape: id, tab: GadgetTab.self), in: window)
        @MainActor func fields() -> Int { view.descendants(NSTextField.self).filter(\.isEditable).count }
        window.spin { fields() == 2 }
        expectEqual(fields(), 2, "the name and the count")
        let count = try require(editor.layout(id).sections(in: .of(GadgetTab.self)).last)
        state.setCollapsed(count, true)
        window.spin { fields() == 1 }
        expectEqual(fields(), 1, "the count's body is gone")
        state.setCollapsed(count, false)
        window.spin { fields() == 2 }
        expectEqual(fields(), 2, "unfolded")
    },
    test("a status line follows a commit, and a read-only shape's boxes are not editable") {
        let editor = try gadgetEditor([FreezingPlugin(), Contributor(id: "wide") { r in
            r.forEveryShape { scope in
                scope.detailStatus(in: SecondWalkerTab.self) { shape, _ in shape.box?.width ?? 0 > 300 ? [DetailStatus("Too wide", tone: .warning)] : [] }
            }
        }, WalkersPlugin()], scheduler: TaskScheduler())
        let id = editor.add(Walker(gadgetFrame))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 500), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = host(DetailTabView(editor: editor, shape: id, tab: SecondWalkerTab.self), in: window)
        window.spin { !view.descendants(NSTextView.self).isEmpty }
        @MainActor func line() -> Bool { view.descendants(NSTextField.self).contains { $0.stringValue.contains("Too wide") } || view.descendants(NSTextView.self).contains { $0.string.contains("Too wide") } }
        expect(!line(), "no line yet")
        editor.transact("Widen") { $0.update(id, as: Walker.self) { $0.props.frame.size.width = 400 } }
        window.spin { line() }
        expect(line(), "the line follows the commit")
        editor.transact("Narrow") { $0.update(id, as: Walker.self) { $0.props.frame.size.width = 200 } }
        window.spin { !line() }
        expect(!line(), "and goes with it")
        let box = try require(view.descendants(NSTextView.self).first)
        expect(box.isEditable, "writable")
        editor.freeze([id])
        window.spin { !(view.descendants(NSTextView.self).first?.isEditable ?? true) }
        expect(!(view.descendants(NSTextView.self).first?.isEditable ?? true), "frozen: the box can't be edited")
        editor.freeze([id], false)
        window.spin { view.descendants(NSTextView.self).first?.isEditable == true }
        expect(view.descendants(NSTextView.self).first?.isEditable == true, "thawed")
    },
])

import AppKit
import Canvas
import CanvasTesting
import Checklists
import DetailPanel
import Selection
import SwiftUI
import TestKit

/// The panel alone in an unshown window, on the Checklist tab: enough for its table, fields,
/// checkboxes and menu. The editor keeps real time, so SwiftUI's updates land while the main run
/// loop runs (`window.spin`, from CanvasTesting).
@MainActor
final class ChecklistWindow {
    let editor: CanvasEditor
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: DetailStyle.idealWidth, height: 700), styleMask: [.titled],
                          backing: .buffered, defer: false)
    let hosting: NSHostingView<DetailPanelView>

    init(_ editor: CanvasEditor) throws {
        self.editor = editor
        try require(editor.detailPanel).choose(.of(ChecklistTab.self), for: Chore.kind)
        hosting = NSHostingView(rootView: DetailPanelView(editor: editor))
        window.contentView = hosting
        window.spin { !tables.isEmpty }
    }

    var tables: [NSTableView] { hosting.descendants(NSTableView.self) }
    var checkboxes: [NSButton] { tables.flatMap { $0.descendants(NSButton.self) } }
    var fields: [NSTextField] { hosting.descendants(NSTextField.self).filter(\.isEditable) }
    var menuButton: NSPopUpButton? { hosting.descendants(NSPopUpButton.self).first }
    var progress: [Double] { hosting.descendants(NSProgressIndicator.self).map(\.doubleValue) }

    /// The Items header's menu. SwiftUI fills it only while it's open, so this opens it as a click
    /// would, on screen (a menu is a window of its own), and closes it at once. Only `menuTests` does.
    func openMenu() throws -> NSMenu {
        let button = try require(menuButton, "no menu")
        RunLoop.main.add(Timer(timeInterval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { button.menu?.cancelTracking() }
        }, forMode: .common)
        button.performClick(nil)
        return try require(button.menu)
    }

    /// Titles, parenthesized when disabled, less the pull-down's title and the separators.
    func menuItems() throws -> [String] {
        try openMenu().items.filter { !$0.title.isEmpty }.map { $0.isEnabled ? $0.title : "(\($0.title))" }
    }

    func choose(_ title: String) throws {
        let menu = try openMenu()
        menu.performActionForItem(at: menu.indexOfItem(withTitle: title))
        window.settle()
    }
}

@MainActor let windowTests = Suite("Checklist in a window", [
    test("Items has a row per item: its checkbox shows the item, its field edits it; Progress follows") {
        let editor = try choreEditor(scheduler: TaskScheduler())
        let id = editor.add(Chore(choreFrame, items: laundry(done: 1)))
        editor.selection = id
        let panel = try ChecklistWindow(editor)
        expectEqual(panel.tables.map(\.numberOfRows), [3])
        expectEqual(panel.checkboxes.map(\.state), [.on, .off, .off])
        expectEqual(panel.fields.map(\.stringValue), ["wash", "dry", "fold"])
        expectEqual(panel.progress, [1.0 / 3])

        editor.transact { $0.update(id, as: Chore.self) { $0.props.items[1].isDone = true } }
        panel.window.spin { panel.checkboxes.map(\.state) == [.on, .on, .off] }
        expectEqual(panel.checkboxes.map(\.state), [.on, .on, .off])
        expectEqual(panel.progress, [2.0 / 3])

        panel.window.focus(try require(panel.fields.last))
        panel.window.type("iron")
        expectEqual(editor.items(id)?.map(\.text), ["wash", "dry", "iron"])
        expectEqual(editor.items(id)?.map(\.isDone), [true, true, false])
    },
    test("the header's pull-down reads done of total, and follows the list") {
        let editor = try choreEditor(scheduler: TaskScheduler())
        let id = editor.add(Chore(choreFrame, items: laundry(done: 1)))
        editor.selection = id
        let panel = try ChecklistWindow(editor)
        expectEqual(panel.menuButton?.title, "1 of 3")
        editor.transact { $0.update(id, as: Chore.self) { ChecklistBulkAction.checkAll.apply(to: &$0.props.items) } }
        panel.window.spin { panel.menuButton?.title == "3 of 3" }
        expectEqual(panel.menuButton?.title, "3 of 3")
    },
    test("an empty checklist has no menu and no Progress") {
        let editor = try choreEditor(scheduler: TaskScheduler())
        editor.selection = editor.add(Chore(choreFrame))
        let panel = try ChecklistWindow(editor)
        expectEqual(panel.tables.map(\.numberOfRows), [0])
        expect(panel.menuButton == nil)
        expectEqual(panel.progress, [])
    },
])

/// Opens the real menu, which shows on screen for a moment each time, so it runs only with
/// TEST_UI_MENUS=1 (see main.swift). The actions' rules are tested headlessly in `itemTests`.
@MainActor let menuTests = Suite("Checklist menu, on screen", [
    test("the menu lists the bulk actions, off when there's nothing to do; choosing one is one transaction") {
        let editor = try choreEditor(scheduler: TaskScheduler())
        let id = editor.add(Chore(choreFrame, items: laundry(done: 1)))
        editor.selection = id
        let panel = try ChecklistWindow(editor)
        expectEqual(try panel.menuItems(), ["Check All", "Uncheck All", "Remove Checked"])
        let revision = editor.revision
        try panel.choose("Check All")
        expectEqual(editor.items(id)?.map(\.isDone), [true, true, true])
        expectEqual(editor.revision, revision + 1)
        expectEqual(try panel.menuItems(), ["(Check All)", "Uncheck All", "Remove Checked"])
    },
])

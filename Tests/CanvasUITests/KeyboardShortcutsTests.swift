import AppKit
import Canvas
import CanvasTesting
import CanvasUI
import SwiftUI
import TestKit

// The Keyboard Shortcuts window's sections, over a menu bar and rows of the tests' own: what it
// files where, and that it lists a key once.

/// Rows a test gives the window, and changes.
@MainActor private final class GivenRows {
    var rows: [KeyboardHelpRow] = []
}

@MainActor private func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
    let menu = NSMenu(title: title)
    for item in items { menu.addItem(item) }
    let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    top.submenu = menu
    return top
}

/// An item; one that runs a command carries it, as the menu bar's items do (`BoardMenus.command(of:)`).
@MainActor private func item(_ title: String, _ action: String, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command,
                             runs command: CanvasCommand? = nil) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: NSSelectorFromString(action), keyEquivalent: key)
    if !key.isEmpty { item.keyEquivalentModifierMask = modifiers }
    item.representedObject = command
    return item
}

@MainActor let keyboardShortcutsTests = Suite("Keyboard Shortcuts window", [
    test("tools first; then each menu, its items' keys and a command's registered keys under the item that runs it, a submenu's in its menu's; then the rest of the canvas's keys, the pointer's and text's; each key once, an empty menu left out") {
        let bar = NSMenu(title: "Main Menu")
        bar.addItem(menu("File", [item("New", "newDocument:", "n"), .separator(), item("Revert to Saved", "revertDocumentToSaved:")]))
        bar.addItem(menu("Edit", [
            item("Undo", "undo:", "z", runs: .undo), item("Delete", "delete:", runs: "scrap"),
            menu("Find", [item("Find Previous", "findPreviousMatch:", "g", [.command, .shift])]),
        ]))
        bar.addItem(menu("Window", [item("Zoom", "performZoom:")]))
        bar.addItem(menu("Go", [item("Back", "runCommand:", "[", runs: "back")]))
        let rows = [
            KeyboardHelpRow(keys: ["V"], title: "Select", place: .tool),
            KeyboardHelpRow(keys: ["Space"], title: "Pan", place: .canvas),
            KeyboardHelpRow(keys: ["⌘Z"], title: "Undo", place: .command(.undo)),
            KeyboardHelpRow(keys: ["⌫", "⌦"], title: "Delete", place: .command("scrap")),
            KeyboardHelpRow(keys: ["⌘["], title: "Back", place: .command("back")),
            KeyboardHelpRow(keys: ["⌘A"], title: "Select All", place: .command("pick-all")),
            KeyboardHelpRow(keys: ["⌘N"], title: "Stamp", place: .canvas),
            KeyboardHelpRow(keys: ["⌥ Drag"], title: "Drag a Copy", place: .pointer),
            KeyboardHelpRow(keys: ["⌘↩"], title: "Finish Editing", place: .text),
        ]
        let sections = KeyboardShortcutSection.sections(menu: bar, rows: rows)
        expectEqual(sections.map(\.title), ["Tools", "File", "Edit", "Go", "Canvas", "Pointer", "Editing Text"])
        func listed(_ title: String) -> [String] {
            sections.first { $0.title == title }?.rows.map { "\($0.keys.joined(separator: " ")) \($0.title)" } ?? []
        }
        expectEqual(listed("Tools"), ["V Select"])
        expectEqual(listed("File"), ["⌘N New"], "an item with no key isn't listed")
        expectEqual(listed("Edit"), ["⌘Z Undo", "⌫ ⌦ Delete", "⇧⌘G Find Previous"], "the menu's key and the command's are one key; a command's keys go with its item")
        expectEqual(listed("Go"), ["⌘[ Back"])
        expectEqual(listed("Canvas"), ["Space Pan", "⌘A Select All"], "a command no item runs, and the canvas's own; ⌘N was New's")
        expectEqual(listed("Pointer"), ["⌥ Drag Drag a Copy"])
        expectEqual(listed("Editing Text"), ["⌘↩ Finish Editing"])
        expectEqual(KeyboardShortcutSection.sections(menu: nil, rows: []), [], "nothing to list, no sections")
    },
    test("a menu item's key is written as menus write it: ⌃ ⌥ ⇧ ⌘, then the key, a capital held with ⇧, arrows and named keys by their signs") {
        expectEqual(KeyboardShortcutSection.key(of: item("A", "a:", "/", [.command, .option])), "⌥⌘/")
        expectEqual(KeyboardShortcutSection.key(of: item("B", "b:", "G")), "⇧⌘G")
        expectEqual(KeyboardShortcutSection.key(of: item("C", "c:", String(UnicodeScalar(UInt16(NSUpArrowFunctionKey))!))), "⌘↑")
        expectEqual(KeyboardShortcutSection.key(of: item("D", "d:", "1", .shift)), "⇧1")
        expectEqual(KeyboardShortcutSection.key(of: item("E", "e:", "f", [.command, .control])), "⌃⌘F")
        expectEqual(KeyboardShortcutSection.key(of: item("F", "f:")), nil)
    },
    test("opened again after it was closed, the window is the one it was, at the size it was left, its rows read again") {
        let given = GivenRows()
        given.rows = [KeyboardHelpRow(keys: ["V"], title: "Select", place: .tool)]
        let help = Contributor(id: "help") { $0.keyboardHelp { _ in given.rows } }
        let shortcuts = KeyboardShortcutsWindow(registry: try Registry(plugins: [help]), menu: { nil }, autosaveName: nil)
        let window = shortcuts.prepare()
        window.setContentSize(NSSize(width: 700, height: 500))
        expectEqual(shortcuts.sections.map(\.title), ["Tools"])
        given.rows = [KeyboardHelpRow(keys: ["⇧ Drag"], title: "Move Along One Axis", place: .pointer)]
        expect(shortcuts.prepare() === window)
        expectEqual(window.contentView?.frame.size, NSSize(width: 700, height: 500), "the size it was left")
        expectEqual(shortcuts.sections.map(\.title), ["Pointer"])
    },
    test("typing in the search leaves the rows whose title or keys it finds, a section with none gone; nothing typed lists all") {
        let sections = [
            KeyboardShortcutSection(title: "View", rows: [.init(keys: ["⌘+"], title: "Zoom In"), .init(keys: ["⌘-"], title: "Zoom Out"), .init(keys: ["⌘B"], title: "Toggle Sidebar")]),
            KeyboardShortcutSection(title: "Edit", rows: [.init(keys: ["⌘Z"], title: "Undo"), .init(keys: ["⌥⌘Z"], title: "Redo")]),
        ]
        expectEqual(KeyboardShortcutSection.filtered(sections, by: ""), sections)
        let zoom = KeyboardShortcutSection.filtered(sections, by: "zoom")
        expectEqual(zoom.map(\.title), ["View"])
        expectEqual(zoom[0].rows.map(\.title), ["Zoom In", "Zoom Out"])
        expectEqual(KeyboardShortcutSection.filtered(sections, by: "⌥⌘").flatMap(\.rows).map(\.title), ["Redo"], "by keys")
        expectEqual(KeyboardShortcutSection.filtered(sections, by: "qqq"), [])
    },
    test("a row reads its title, then its keys") {
        expectEqual(KeyboardShortcutSection.Row(keys: ["⌫", "⌦"], title: "Delete").spoken, "Delete, ⌫, ⌦")
    },
    test("the window opens with the search field focused and named, takes typing, and Escape closes it") {
        let given = GivenRows()
        given.rows = [KeyboardHelpRow(keys: ["⌘+"], title: "Zoom In", place: .canvas), KeyboardHelpRow(keys: ["⌘Z"], title: "Undo", place: .canvas)]
        let help = Contributor(id: "help") { $0.keyboardHelp { _ in given.rows } }
        let shortcuts = KeyboardShortcutsWindow(registry: try Registry(plugins: [help]), menu: { nil }, autosaveName: nil)
        let window = shortcuts.prepare()
        window.orderFront(nil)
        defer { window.close() }
        window.spin(until: { (window.firstResponder as? NSTextView)?.isFieldEditor == true })
        let field = try require(window.contentView?.descendants(NSTextField.self).first)
        expect((window.firstResponder as? NSTextView)?.delegate === field, "the search field has the keyboard")
        expectEqual(AccessibilityProbe.label(of: field), "Search")
        // SwiftUI builds its accessibility tree only for an assistive app, so the rows' and headings'
        // modifiers are not read here; what a row says is `spoken`, held above.
        window.type("zoom")
        window.settle()
        expectEqual(field.stringValue, "zoom", "typing goes to the search")
        expect(window.isVisible, "and doesn't close the window")
        window.pressEscape()
        window.settle()
        expect(!window.isVisible, "Escape closes it")
        // Opened again, it's made afresh: nothing typed, every row, and the search has the keyboard again.
        expect(shortcuts.prepare() === window)
        shortcuts.show()
        window.spin(until: { (window.firstResponder as? NSTextView)?.isFieldEditor == true })
        let again = try require(window.contentView?.descendants(NSTextField.self).first)
        expectEqual(again.stringValue, "", "what was typed last time is gone")
        expect((window.firstResponder as? NSTextView)?.delegate === again, "the search field has the keyboard")
        window.type("undo")
        window.settle()
        expectEqual(again.stringValue, "undo")
    },
    test("Settings closes on Escape, with its field focused or not, and ⌘.") {
        let settings = SettingsWindow(autosaveName: nil) { TextField("Key", text: .constant("")) }
        let window = settings.prepare()
        window.orderFront(nil)
        defer { window.close() }
        window.settle()
        window.pressEscape()
        window.settle()
        expect(!window.isVisible, "Escape closes it")
        window.orderFront(nil)
        window.makeFirstResponder(nil)
        window.pressCommandPeriod()
        window.settle()
        expect(!window.isVisible, "so does ⌘.")
    },
])

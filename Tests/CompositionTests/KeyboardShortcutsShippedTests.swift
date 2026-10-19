import AppKit
import Canvas
import CanvasUI
import Keyboard
import LanguageModels
import ShippedTesting
import TestKit

// The Keyboard Shortcuts window as the app opens it: the shipped plugins' keys and the menu bar's,
// none of it written by hand, so a key a plugin adds is listed with no change to the window.

@MainActor let keyboardShortcutsShippedTests = Suite("Keyboard Shortcuts window, shipped", [
    test("every key the app answers is listed exactly once, each named: every shortcut a shipped plugin registers, every key in the menu bar, and the hints") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let registry = try ShippedPlugins.registry(pasteboard: pasteboard, model: ScriptedLanguageModel())
        let menus = BoardMenus.make(appName: "Infinite Canvas", registry: registry)
        let sections = KeyboardShortcutsWindow(registry: registry, menu: { menus.main }, autosaveName: nil).sections
        let listed = sections.flatMap { $0.rows.flatMap(\.keys) }
        expectEqual(listed.count, Set(listed).count, "no key twice: \(listed)")
        for row in sections.flatMap(\.rows) { expect(!row.title.isEmpty && !row.keys.isEmpty, "\(row)") }
        let arrows: Set<Character> = [KeyChord.leftArrow.key, KeyChord.upArrow.key, KeyChord.rightArrow.key, KeyChord.downArrow.key]
        for shortcut in registry.shortcuts {
            let written = shortcut.chord.description
            let folded = String(written.dropLast()) + "←↑→↓"
            expect(listed.contains(written) || (arrows.contains(shortcut.chord.key) && listed.contains(folded)), "\(written), \(shortcut.action), is listed")
        }
        @MainActor func items(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { $0.submenu.map(items) ?? [$0] } }
        for item in items(menus.main) {
            guard let key = KeyboardShortcutSection.key(of: item) else { continue }
            expect(listed.contains(key), "\(item.title), \(key), is listed")
        }
        for hint in registry.keyboardHelp where hint.place == .pointer || hint.place == .text {
            expect(hint.keys.allSatisfy(listed.contains), "\(hint.title) is listed")
        }
    },
    test("each key is filed where a person looks for it: a tool's under Tools, a command's with the menu item that runs it, the rest under the canvas, the pointer and text") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let registry = try ShippedPlugins.registry(pasteboard: pasteboard, model: ScriptedLanguageModel())
        let menus = BoardMenus.make(appName: "Infinite Canvas", registry: registry)
        let sections = KeyboardShortcutsWindow(registry: registry, menu: { menus.main }, autosaveName: nil).sections
        expectEqual(sections.map(\.title), ["Tools", "Infinite Canvas", "File", "Edit", "Arrange", "View", "Go", "Window", "Help", "Canvas", "Pointer", "Editing Text"])
        @MainActor func row(_ section: String, _ title: String) -> [String]? {
            sections.first { $0.title == section }?.rows.first { $0.title == title }?.keys
        }
        expectEqual(row("Tools", "Select"), ["V"])
        expectEqual(row("Tools", "Note"), ["N"])
        expectEqual(row("Edit", "Delete"), ["⌫", "⌦"], "Delete's keys with its item, which has none of its own")
        expectEqual(row("Edit", "Undo"), ["⌘Z"])
        expectEqual(row("Edit", "Find Previous"), ["⇧⌘G"], "a submenu's items in its menu")
        expectEqual(row("Go", "Open Selection"), ["⌘↓", "↩", "⌤"], "Return and Enter open the selection too")
        expectEqual(row("View", "Zoom to Fit"), ["⇧1"])
        expectEqual(row("View", "Zoom In"), ["⌘=", "="], "the menu's key and the plain one, held to repeat")
        expectEqual(row("View", "Zoom Out"), ["⌘-", "-"])
        expectEqual(row("View", "Actual Size"), ["⌘0", "⇧0"])
        expectEqual(row("View", "Focus Inspector"), ["⌥⌘I"], "a menu item of the window's own: its key from the menu bar")
        expectEqual(row("Edit", "Paste at Pointer"), ["⇧⌘V"], "Clipboard's command, with the item that runs it")
        expectEqual(row("Edit", "Copy as Image"), ["⇧⌘C"], "the window's own item, its key from the menu bar")
        expectEqual(row("Canvas", "Tool Lock"), ["Q"], "a key that runs no command, under the canvas")
        expectEqual(row("Help", "Keyboard Shortcuts"), ["⌥⌘/"])
        expectEqual(row("Arrange", "Group"), ["⌥⌘G"])
        expectEqual(row("Arrange", "Bring to Front"), ["]"], "the shape commands with a fixed item are filed with it")
        expectEqual(row("Arrange", "Bring Forward"), ["⌥]"])
        expectEqual(row("Arrange", "Send Backward"), ["⌥["])
        expectEqual(row("Arrange", "Send to Back"), ["["])
        expectEqual(row("Canvas", "Lock or Unlock"), ["⇧L"], "no menu bar item runs it (the Shape menu is empty here, and its items run no command a key finds): the canvas's")
        expectEqual(row("Canvas", "Create Frame"), ["⇧⌘F"])
        expectEqual(row("Canvas", "Nudge"), ["←↑→↓", "⇧←↑→↓"])
        expectEqual(row("Canvas", "Cancel"), ["⎋", "⌘."])
        expectEqual(row("Canvas", "Next Shape"), ["⇥"])
        expectEqual(row("Canvas", "Previous Shape"), ["⇧⇥"])
        expectEqual(row("Canvas", "Select Nearest Shape"), ["⌥⌘←↑→↓"], "the four arrows are one key")
        expectEqual(row("Canvas", "Add Nearest Shape to Selection"), ["⌥⇧⌘←↑→↓"])
        expectEqual(row("Go", "Enclosing Board"), ["⌘↑"], "named as the command is, whatever step its item names")
        expectEqual(row("Pointer", "Drag a Copy"), ["⌥ Drag"])
        expectEqual(row("Editing Text", "Mention a Shape"), ["@"])
    },
])

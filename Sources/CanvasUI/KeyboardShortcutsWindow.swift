import AppKit
import Canvas
import SwiftUI

/// The Keyboard Shortcuts window: one for the app (Help › Keyboard Shortcuts, ⌥⌘/, which the app's
/// delegate answers with `show()`), listing every key the app answers, nothing of it written by
/// hand: the menu bar's keys, read off the menus as they are when it opens, and the rows the plugins
/// give (`registry.keyboardHelp`: the keys Keyboard registers, under what they do, and the hints
/// said beside the code that reads a key). Made afresh each time it opens, as Settings is.
@MainActor
public final class KeyboardShortcutsWindow {
    private let registry: Registry
    private let menu: @MainActor () -> NSMenu?
    private let autosaveName: String?
    private var window: NSWindow?

    /// The window for `registry`'s plugins and the menu bar `menu` gives when it opens (the app's,
    /// by default). AppKit keeps where it was left under `autosaveName` (nil: nowhere, as in tests).
    public init(registry: Registry, menu: @escaping @MainActor () -> NSMenu? = { NSApp.mainMenu },
                autosaveName: String? = "Keyboard Shortcuts") {
        self.registry = registry
        self.menu = menu
        self.autosaveName = autosaveName
    }

    /// What the window lists now.
    public var sections: [KeyboardShortcutSection] {
        KeyboardShortcutSection.sections(menu: menu(), rows: registry.keyboardHelp)
    }

    /// Brings the window forward, `prepare`d.
    public func show() {
        prepare().makeKeyAndOrderFront(nil)
    }

    /// The window as `show` brings it forward: made the first time; after, while it's closed, with
    /// its rows read afresh, at the size it was left; while it's open, as it is.
    @discardableResult
    public func prepare() -> NSWindow {
        guard let window else {
            let window = NSWindow(contentViewController: hosting())
            window.title = ShortcutsStyle.title
            window.styleMask = [.titled, .closable, .resizable]
            window.isReleasedWhenClosed = false
            window.center()
            if let autosaveName { window.setFrameAutosaveName(autosaveName) }
            self.window = window
            return window
        }
        // The rows again, in the view it has: a new controller would size the window to its view, losing
        // the size the person gave it.
        if !window.isVisible { (window.contentViewController as? NSHostingController<KeyboardShortcutsView>)?.rootView = KeyboardShortcutsView(sections: sections) }
        return window
    }

    private func hosting() -> NSHostingController<KeyboardShortcutsView> {
        let controller = NSHostingController(rootView: KeyboardShortcutsView(sections: sections))
        controller.view.setFrameSize(NSSize(width: ShortcutsStyle.width, height: ShortcutsStyle.height))
        return controller
    }
}

/// A heading of the Keyboard Shortcuts window and its rows: what each set of keys does, and the keys.
public struct KeyboardShortcutSection: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        public let keys: [String]
        public let title: String
    }

    public let title: String
    public let rows: [Row]

    /// The window's sections: Tools; then each of `menu`'s menus, in its order, with the keys of its
    /// items (a submenu's too) and the keys registered for the command an item runs, under the
    /// item's command's title; then Canvas, the keys that run a command no menu item runs or do
    /// something else on the canvas; then Pointer, the keys held with a click, a drag or a scroll;
    /// then Editing Text. A key is listed once, where it comes first; a row left with none, and a
    /// section with no rows, are left out.
    @MainActor
    public static func sections(menu: NSMenu?, rows: [KeyboardHelpRow]) -> [KeyboardShortcutSection] {
        var listed = Set<String>()
        func row(_ keys: [String], _ title: String) -> Row? {
            let fresh = keys.filter { listed.insert($0).inserted }
            return fresh.isEmpty ? nil : Row(keys: fresh, title: title)
        }
        var sections: [KeyboardShortcutSection] = []
        func add(_ title: String, _ rows: [Row?]) {
            let rows = rows.compactMap { $0 }
            if !rows.isEmpty { sections.append(KeyboardShortcutSection(title: title, rows: rows)) }
        }
        add(ShortcutsStyle.tools, rows.filter { $0.place == .tool }.map { row($0.keys, $0.title) })
        var commands: [CanvasCommand: KeyboardHelpRow] = [:]
        for help in rows { if case .command(let command) = help.place, commands[command] == nil { commands[command] = help } }
        var filed = Set<CanvasCommand>()
        for top in menu?.items ?? [] {
            guard let submenu = top.submenu else { continue }
            var found: [Row?] = []
            func walk(_ menu: NSMenu) {
                for item in menu.items where !item.isSeparatorItem {
                    if let submenu = item.submenu { walk(submenu); continue }
                    let own = MenuKey.written(item).map { [$0] } ?? []
                    if let command = item.action.flatMap({ BoardWindowController.menuCommands[$0] }), let help = commands[command] {
                        filed.insert(command)
                        found.append(row(own + help.keys, help.title))
                    } else if !own.isEmpty {
                        found.append(row(own, item.title))
                    }
                }
            }
            walk(submenu)
            add(submenu.title, found)
        }
        add(ShortcutsStyle.canvas, rows.filter { help in
            switch help.place {
            case .command(let command): !filed.contains(command)
            case .canvas: true
            default: false
            }
        }.map { row($0.keys, $0.title) })
        add(ShortcutsStyle.pointer, rows.filter { $0.place == .pointer }.map { row($0.keys, $0.title) })
        add(ShortcutsStyle.text, rows.filter { $0.place == .text }.map { row($0.keys, $0.title) })
        return sections
    }

    /// A menu item's key as the window writes it ("⇧⌘G", "⌥⌘/"); nil for an item with none.
    @MainActor public static func key(of item: NSMenuItem) -> String? { MenuKey.written(item) }
}

/// A menu item's key as menus write it: the modifiers in the order ⌃ ⌥ ⇧ ⌘ (fn as 🌐), then the key,
/// a letter as a capital (a capital key equivalent is held with ⇧, as AppKit reads it).
@MainActor
enum MenuKey {
    static func written(_ item: NSMenuItem) -> String? {
        let key = item.keyEquivalent
        guard !key.isEmpty else { return nil }
        var modifiers = item.keyEquivalentModifierMask
        if key.count == 1, key.first?.isUppercase == true { modifiers.insert(.shift) }
        var text = ""
        if modifiers.contains(.function) { text += "🌐" }
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + (names[key] ?? key.uppercased())
    }

    private static let names: [String: String] = [
        "\u{1b}": "⎋", "\r": "↩", "\u{3}": "⌤", "\u{7f}": "⌫", "\u{8}": "⌫", "\t": "⇥", " ": "Space",
        String(UnicodeScalar(UInt16(NSUpArrowFunctionKey))!): "↑", String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!): "↓",
        String(UnicodeScalar(UInt16(NSLeftArrowFunctionKey))!): "←", String(UnicodeScalar(UInt16(NSRightArrowFunctionKey))!): "→",
        String(UnicodeScalar(UInt16(NSDeleteFunctionKey))!): "⌦",
    ]
}

/// The window's content: each section's heading over its rows, what the keys do on the left and
/// the keys on the right.
struct KeyboardShortcutsView: View {
    let sections: [KeyboardShortcutSection]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ShortcutsStyle.sectionSpacing) {
                ForEach(sections.indices, id: \.self) { index in
                    let section = sections[index]
                    VStack(alignment: .leading, spacing: ShortcutsStyle.rowSpacing) {
                        Text(section.title).font(.headline)
                        ForEach(section.rows.indices, id: \.self) { row in
                            HStack(alignment: .firstTextBaseline) {
                                Text(section.rows[row].title)
                                Spacer(minLength: ShortcutsStyle.keysGap)
                                Text(section.rows[row].keys.joined(separator: ShortcutsStyle.keySeparator))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                }
            }
            .padding(ShortcutsStyle.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

@MainActor
enum ShortcutsStyle {
    static let title = "Keyboard Shortcuts"
    static let tools = "Tools"
    static let canvas = "Canvas"
    static let pointer = "Pointer"
    static let text = "Editing Text"
    static let width: CGFloat = 460
    static let height: CGFloat = 640
    static let padding: CGFloat = 20
    static let sectionSpacing: CGFloat = 18
    static let rowSpacing: CGFloat = 5
    static let keysGap: CGFloat = 16
    static let keySeparator = "   "
}

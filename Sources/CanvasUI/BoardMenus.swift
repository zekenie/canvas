import AppKit
@_spi(Host) import Canvas

/// The app's menus, built in code (there's no nib): a document app's standard items, sent to the
/// first responder, so the canvas, a panel's field, the board's window controller, the document,
/// the document controller or the app answers whichever it is. Edit › Spelling and Grammar's are
/// the text's with the keyboard (dimmed anywhere else): a text that checks its words as the app
/// does (TextEditing's `Spelling`) turns its toggles over for every such text. AppKit fills Open
/// Recent (it finds the menu by its Clear Menu item) and, since boards autosave in place, turns Save
/// As into Duplicate and Revert to Saved into Revert To. Shape, between Edit and Arrange, fills
/// itself each time it opens (`ShapeMenu`).
@MainActor
public enum BoardMenus {
    public struct Menus {
        public let main: NSMenu
        public let services: NSMenu
        public let windows: NSMenu
        public let help: NSMenu
    }

    /// What Infinite Canvas › Settings… (⌘,) sends up the responder chain: the app's delegate answers
    /// it, showing its Settings window (AppKit has no standard action for it).
    public static let showSettings = NSSelectorFromString("showSettings:")

    /// What Help › Keyboard Shortcuts (⌥⌘/) sends up the responder chain: the app's delegate answers
    /// it, showing its Keyboard Shortcuts window (`KeyboardShortcutsWindow`).
    public static let showKeyboardShortcuts = NSSelectorFromString("showKeyboardShortcuts:")

    /// Installs the menus as the app's.
    public static func install(appName: String) {
        let menus = make(appName: appName)
        NSApp.mainMenu = menus.main
        NSApp.servicesMenu = menus.services
        NSApp.windowsMenu = menus.windows
        NSApp.helpMenu = menus.help
    }

    /// The menus. Shape's items are the selection's menu (`editor.menuForSelection`) of the editor
    /// `editor` gives when the menu opens: the key window's board by default.
    public static func make(appName: String, editor: @escaping @MainActor () -> CanvasEditor? = keyBoardEditor) -> Menus {
        let services = NSMenu(title: "Services")
        let app = menu(appName, [
            item("About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Settings…", showSettings, ","),
            .separator(),
            submenu("Services", services),
            .separator(),
            item("Hide \(appName)", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q"),
        ])
        let file = menu("File", [
            item("New", #selector(NSDocumentController.newDocument(_:)), "n"),
            item("Open…", #selector(NSDocumentController.openDocument(_:)), "o"),
            submenu("Open Recent", menu("Open Recent", [item("Clear Menu", #selector(NSDocumentController.clearRecentDocuments(_:)))])),
            .separator(),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            item("Save…", NSSelectorFromString("saveDocument:"), "s"),
            item("Save As…", NSSelectorFromString("saveDocumentAs:"), "s", [.command, .shift]),
            item("Revert to Saved", NSSelectorFromString("revertDocumentToSaved:")),
        ])
        let edit = menu("Edit", [
            item("Undo", NSSelectorFromString("undo:"), "z"),
            item("Redo", NSSelectorFromString("redo:"), "z", [.command, .shift]),
            .separator(),
            item("Cut", NSSelectorFromString("cut:"), "x"),
            item("Copy", NSSelectorFromString("copy:"), "c"),
            item("Copy as Image", #selector(BoardWindowController.copyAsImage(_:)), "c", [.command, .shift]),
            item("Paste", NSSelectorFromString("paste:"), "v"),
            item("Paste at Pointer", #selector(BoardWindowController.pasteAtPointer(_:)), "v", [.command, .shift]),
            item("Duplicate", #selector(BoardWindowController.duplicate(_:)), "d"),
            item("Delete", NSSelectorFromString("delete:")),
            item("Select All", NSSelectorFromString("selectAll:"), "a"),
            .separator(),
            submenu("Find", menu("Find", [
                item("Find…", #selector(BoardWindowController.showFind(_:)), "f"),
                item("Find Next", #selector(BoardWindowController.findNextMatch(_:)), "g"),
                item("Find Previous", #selector(BoardWindowController.findPreviousMatch(_:)), "g", [.command, .shift]),
            ])),
            submenu("Spelling and Grammar", menu("Spelling and Grammar", [
                item("Show Spelling and Grammar", NSSelectorFromString("showGuessPanel:"), ":"),
                item("Check Document Now", NSSelectorFromString("checkSpelling:"), ";"),
                .separator(),
                item("Check Spelling While Typing", NSSelectorFromString("toggleContinuousSpellChecking:")),
                item("Check Grammar With Spelling", NSSelectorFromString("toggleGrammarChecking:")),
                item("Correct Spelling Automatically", NSSelectorFromString("toggleAutomaticSpellingCorrection:")),
            ])),
        ])
        // What the selection's context menu offers, less what the menu bar has (below, and Edit's): its items
        // fill themselves in each time it opens, so it holds none to start with.
        let shape = ShapeMenu(editor: editor)
        // Group and Ungroup, Keynote's and Freeform's keys (⌘G is Find Next), then the restacking: the
        // commands a plugin claims. Bring to Front and the rest are keys that type, so they are the text's
        // while it has the keyboard (`MenuBar`).
        let arrange = menu("Arrange", [
            item("Group", #selector(BoardWindowController.groupSelection(_:)), "g", [.command, .option]),
            item("Ungroup", #selector(BoardWindowController.ungroupSelection(_:)), "g", [.command, .option, .shift]),
            .separator(),
            item("Bring to Front", #selector(BoardWindowController.bringToFront(_:)), "]", []),
            item("Bring Forward", #selector(BoardWindowController.bringForward(_:)), "]", .option),
            item("Send Backward", #selector(BoardWindowController.sendBackward(_:)), "[", .option),
            item("Send to Back", #selector(BoardWindowController.sendToBack(_:)), "[", []),
        ])
        let view = menu("View", [
            item("Show Toolbar", #selector(NSWindow.toggleToolbarShown(_:)), "t", [.command, .option]),
            item("Show Inspector", #selector(BoardWindowController.toggleDetails(_:)), "i", [.command, .control]),
            item("Focus Inspector", #selector(BoardWindowController.focusInspector(_:)), "i", [.command, .option]),
            item("Show Minimap", #selector(BoardWindowController.toggleMinimap(_:)), "m", [.command, .control]),
            .separator(),
            item("Zoom In", NSSelectorFromString("zoomIn:"), "="),
            item("Zoom Out", NSSelectorFromString("zoomOut:"), "-"),
            item("Actual Size", NSSelectorFromString("zoomToActualSize:"), "0"),
            item("Zoom to Fit", NSSelectorFromString("zoomToFit:"), "1", .shift),
            item("Zoom to Selection", NSSelectorFromString("zoomToSelection:"), "2", .shift),
            .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])
        let go = menu("Go", [
            item("Back", #selector(BoardWindowController.goBack(_:)), "["),
            item("Enclosing Board", #selector(BoardWindowController.enclosingBoard(_:)), upArrow),
            item("Open Selection", #selector(BoardWindowController.openSelection(_:)), downArrow),
            .separator(),
            item("Jump To…", #selector(BoardWindowController.showJumpTo(_:)), "k"),
        ])
        let windows = menu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ])
        let help = menu("Help", [
            item("Keyboard Shortcuts", showKeyboardShortcuts, "/", [.command, .option]),
        ])
        let main = MenuBar(title: "Main Menu")
        for menu in [app, file, edit, shape, arrange, view, go, windows, help] { main.addItem(submenu(menu.title, menu)) }
        return Menus(main: main, services: services, windows: windows, help: help)
    }

    /// The editor of the window that has the keyboard, if it's a board's.
    public static let keyBoardEditor: @MainActor () -> CanvasEditor? = {
        [NSApp.keyWindow, NSApp.mainWindow].lazy.compactMap { $0 as? BoardWindow }.first?.editor
    }

    /// The arrow keys, as a menu item's key equivalent.
    static let upArrow = String(UnicodeScalar(UInt16(NSUpArrowFunctionKey))!)
    static let downArrow = String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!)

    private static func item(_ title: String, _ action: Selector, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { item.keyEquivalentModifierMask = modifiers }
        return item
    }

    private static func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
        let menu = NSMenu(title: title)
        for item in items { menu.addItem(item) }
        return menu
    }

    private static func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}

/// The Shape menu: what a right-click on the selected shapes would open (the plugin that claims the
/// selection's menu makes it: `editor.menuForSelection`), less the items the menu bar already has,
/// the ones that run a command one of its items runs (Cut, Copy, Paste, Duplicate, Delete, Select All,
/// Group, Ungroup and the restacking). It holds nothing until it opens, and fills itself then from the
/// editor of the window that has the keyboard, with the selection as it is; nothing selected, nothing
/// in it. The items it's given know their editor, so a pick reaches the window it was made for. Its
/// items show their keys, but only while it's open: AppKit isn't asked for a key equivalent here
/// (`menuHasKeyEquivalent`), and it empties as it closes, so a key never reaches a stale item.
final class ShapeMenu: NSMenu, NSMenuDelegate {
    private let editor: @MainActor () -> CanvasEditor?

    init(editor: @escaping @MainActor () -> CanvasEditor?) {
        self.editor = editor
        super.init(title: "Shape")
        autoenablesItems = false                // the items are set as they should be, and carry no responder to ask
        delegate = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("menus aren't archived") }

    func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            menu.removeAllItems()
            let commands = Set(BoardWindowController.menuCommands.values)
            guard let made = editor()?.menuForSelection(omitting: commands) else { return }
            for item in made.items {
                made.removeItem(item)
                menu.addItem(item)
            }
        }
    }

    /// Never: its keys are the canvas's and the menu bar's own items', so a key doesn't make AppKit fill
    /// this menu to look in it.
    func menuHasKeyEquivalent(_ menu: NSMenu, for event: NSEvent, target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
                              action: UnsafeMutablePointer<Selector?>) -> Bool {
        false
    }

    /// Empties, after the action of the item that was chosen (AppKit says it's closed first).
    func menuDidClose(_ menu: NSMenu) {
        DispatchQueue.main.async { MainActor.assumeIsolated { menu.removeAllItems() } }
    }
}

/// The menu bar: as any, but an item whose key is an arrow key (Go › Enclosing Board, ⌘↑, and Open
/// Selection, ⌘↓) leaves that key to the key window while it's disabled, as it is while text has the keyboard,
/// so the text moves its caret with it. (AppKit's menus take a disabled item's key, and beep.) And
/// an item whose key types (View › Zoom to Fit, ⇧1, and Zoom to Selection, ⇧2; Arrange › Bring to Front,
/// `]`, and the rest: no ⌘, so ⇧, ⌥ or nothing held with the key, ⌃ too) never takes it from text,
/// where it types ("!" on a US keyboard, a quote for ⌥]); elsewhere it answers the key it names (a digit
/// is the number row's key, whatever the layout types with it), and leaves it while it's disabled.
/// A key held with fn (🌐) is AppKit's as ever, text or not: the items it adds for them (Edit ›
/// Emoji & Symbols, 🌐E; Start Dictation, 🌐D; View › Enter Full Screen, 🌐F) answer only as key
/// equivalents. A ⇧⌘ letter goes to the item that names ⇧ (Edit › Find › Find Previous, ⇧⌘G), never to
/// the one with ⌘ alone (Find Next) that comes first, and where none names ⇧ it goes to none (⇧⌘F is
/// not Find's ⌘F).
final class MenuBar: NSMenu {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, let item = arrowItem(for: event, in: self) {
            item.menu?.update()
            if !item.isEnabled { return false }
        }
        // A ⇧⌘ letter goes to the item that names ⇧ (Find Previous, ⇧⌘G), not to the one with the same
        // letter and ⌘ alone (Find Next), which a menu may take it for, whichever comes first. And where
        // none names ⇧ (⇧⌘F: Create Frame is the canvas's key), the ⌘ one doesn't take it either.
        if event.type == .keyDown, event.modifierFlags.isSuperset(of: [.command, .shift]),
           let key = event.charactersIgnoringModifiers?.lowercased(), key.count == 1, key.first?.isLetter == true {
            let modifiers = event.modifierFlags.intersection(Self.keyModifiers)
            if let (menu, index) = typedItem(Character(key), modifiers, in: self) {
                menu.update()
                guard let item = menu.item(at: index), item.isEnabled else { return false }
                menu.performActionForItem(at: index)
                return true
            }
            if typedItem(Character(key), modifiers.subtracting(.shift), in: self) != nil { return false }
        }
        // A key held without ⌘ types (⌥ held, it still may: ⌥] is a quote). In text it's the text's, but one
        // held with ⌃, which types nothing, goes on to AppKit's menus as ever (⌃⇥, Window's next tab; a
        // service's key), then to the text's bindings (⌃A a line start). Elsewhere an item that names it
        // takes it, unless it's disabled, and only as it goes down: a held key's repeats run it no more,
        // as the canvas's shortcut for it doesn't repeat (⇧1 would flip between the fit and back).
        if event.type == .keyDown, !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.function) {
            // Menus are asked on the main thread.
            let window = event.window
            let inText = MainActor.assumeIsolated { (window ?? NSApp.keyWindow)?.firstResponder is NSText }
            let typed = event.charactersIgnoringModifiers?.lowercased()
            let modifiers = event.modifierFlags.intersection(Self.keyModifiers)
            let found = (KeyStroke.numberRow[event.keyCode] ?? (typed?.count == 1 ? typed?.first : nil)).flatMap { typedItem($0, modifiers, in: self) }
            if inText { return modifiers.contains(.control) ? super.performKeyEquivalent(with: event) : false }
            if let (menu, index) = found {
                menu.update()
                guard let item = menu.item(at: index), item.isEnabled else { return false }
                if event.isARepeat { return true }
                menu.performActionForItem(at: index)
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    private static let keyModifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    /// The item, in `menu` or a menu under it, whose key equivalent is `key` (in any case) with exactly
    /// these modifiers, and where it is.
    private func typedItem(_ key: Character, _ modifiers: NSEvent.ModifierFlags, in menu: NSMenu) -> (NSMenu, Int)? {
        for (index, item) in menu.items.enumerated() {
            if item.keyEquivalent.lowercased() == String(key).lowercased(), item.keyEquivalentModifierMask.intersection(Self.keyModifiers) == modifiers {
                return (menu, index)
            }
            if let submenu = item.submenu, let found = typedItem(key, modifiers, in: submenu) { return found }
        }
        return nil
    }

    private static let arrows: Set<String> = Set([NSUpArrowFunctionKey, NSDownArrowFunctionKey, NSLeftArrowFunctionKey, NSRightArrowFunctionKey]
        .map { String(UnicodeScalar(UInt16($0))!) })

    /// The item, in `menu` or a menu under it, whose key equivalent is `event`'s arrow key, with its
    /// modifiers (less the function and keypad flags every arrow key carries).
    private func arrowItem(for event: NSEvent, in menu: NSMenu) -> NSMenuItem? {
        guard let key = event.charactersIgnoringModifiers, Self.arrows.contains(key) else { return nil }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        for item in menu.items {
            if item.keyEquivalent == key, item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]) == modifiers { return item }
            if let submenu = item.submenu, let found = arrowItem(for: event, in: submenu) { return found }
        }
        return nil
    }
}

import AppKit
import Canvas

/// The app's menus, built in code (there's no nib): a document app's standard items, sent to the
/// first responder, so the canvas, a panel's field, the board's window controller, the document,
/// the document controller or the app answers whichever it is. Edit › Spelling and Grammar's are
/// the text's with the keyboard (dimmed anywhere else): a text that checks its words as the app
/// does (TextEditing's `Spelling`) turns its toggles over for every such text. AppKit fills Open
/// Recent (it finds the menu by its Clear Menu item) and, since boards autosave in place, turns Save
/// As into Duplicate and Revert to Saved into Revert To.
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

    /// Installs the menus as the app's.
    public static func install(appName: String, helpItems: [NSMenuItem] = []) {
        let menus = make(appName: appName, helpItems: helpItems)
        NSApp.mainMenu = menus.main
        NSApp.servicesMenu = menus.services
        NSApp.windowsMenu = menus.windows
        NSApp.helpMenu = menus.help
    }

    public static func make(appName: String, helpItems: [NSMenuItem] = []) -> Menus {
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
            item("Paste", NSSelectorFromString("paste:"), "v"),
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
        let view = menu("View", [
            item("Show Toolbar", #selector(NSWindow.toggleToolbarShown(_:)), "t", [.command, .option]),
            item("Show Inspector", #selector(BoardWindowController.toggleDetails(_:)), "i", [.command, .control]),
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
        let help = menu("Help", helpItems)
        let main = MenuBar(title: "Main Menu")
        for menu in [app, file, edit, view, go, windows, help] { main.addItem(submenu(menu.title, menu)) }
        return Menus(main: main, services: services, windows: windows, help: help)
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

/// The menu bar: as any, but an item whose key is an arrow key (Go › Enclosing Board, ⌘↑, and Open
/// Selection, ⌘↓) leaves that key to the key window while it's disabled, as it is while text has the keyboard,
/// so the text moves its caret with it. (AppKit's menus take a disabled item's key, and beep.) And
/// an item whose key types (View › Zoom to Fit, ⇧1, and Zoom to Selection, ⇧2: no ⌘, ⌃ or ⌥) never
/// takes it from text, where it types ("!" on a US keyboard); elsewhere it answers the number row's
/// key it names, whatever the layout types with it, and leaves it while it's disabled. A key held
/// with fn (🌐) is AppKit's as ever, text or not: the items it adds for them (Edit › Emoji & Symbols,
/// 🌐E; Start Dictation, 🌐D; View › Enter Full Screen, 🌐F) answer only as key equivalents.
/// A ⇧⌘ letter goes to the item that names ⇧ (Edit › Find › Find Previous, ⇧⌘G), never to the
/// one with ⌘ alone (Find Next) that comes first.
final class MenuBar: NSMenu {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, let item = arrowItem(for: event, in: self) {
            item.menu?.update()
            if !item.isEnabled { return false }
        }
        // A ⇧⌘ letter goes to the item that names ⇧ (Find Previous, ⇧⌘G), not to the one with the same
        // letter and ⌘ alone (Find Next), which a menu may take it for, whichever comes first.
        if event.type == .keyDown, event.modifierFlags.isSuperset(of: [.command, .shift]),
           let key = event.charactersIgnoringModifiers?.lowercased(), key.count == 1, key.first?.isLetter == true,
           let (menu, index) = typedItem(Character(key), event, in: self) {
            menu.update()
            guard let item = menu.item(at: index), item.isEnabled else { return false }
            menu.performActionForItem(at: index)
            return true
        }
        if event.type == .keyDown, event.modifierFlags.isDisjoint(with: [.command, .control, .option, .function]) {
            // Menus are asked on the main thread.
            let window = event.window
            let inText = MainActor.assumeIsolated { (window ?? NSApp.keyWindow)?.firstResponder is NSText }
            if inText { return false }
            if let digit = KeyStroke.numberRow[event.keyCode], let (menu, index) = typedItem(digit, event, in: self) {
                menu.update()
                guard let item = menu.item(at: index), item.isEnabled else { return false }
                menu.performActionForItem(at: index)
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    /// The item, in `menu` or a menu under it, whose key equivalent is `digit` (or a letter, in any
    /// case) with `event`'s modifiers (⇧ or none, for a digit), and where it is.
    private func typedItem(_ digit: Character, _ event: NSEvent, in menu: NSMenu) -> (NSMenu, Int)? {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        for (index, item) in menu.items.enumerated() {
            if item.keyEquivalent.lowercased() == String(digit).lowercased(), item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]) == modifiers {
                return (menu, index)
            }
            if let submenu = item.submenu, let found = typedItem(digit, event, in: submenu) { return found }
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

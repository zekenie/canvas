import AppKit

/// The app's menus, built in code (there's no nib): a document app's standard items, sent to the
/// first responder, so the canvas, a panel's field, the board's window controller, the document,
/// the document controller or the app answers whichever it is. AppKit fills Open Recent (it finds
/// the menu by its Clear Menu item) and, since boards autosave in place, turns Save As into
/// Duplicate and Revert to Saved into Revert To.
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
            item("Delete", NSSelectorFromString("delete:")),
            item("Select All", NSSelectorFromString("selectAll:"), "a"),
        ])
        let view = menu("View", [
            item("Show Toolbar", #selector(NSWindow.toggleToolbarShown(_:)), "t", [.command, .option]),
            item("Show Inspector", #selector(BoardWindowController.toggleDetails(_:)), "i", [.command, .control]),
            item("Show Minimap", #selector(BoardWindowController.toggleMinimap(_:)), "m", [.command, .control]),
            .separator(),
            item("Zoom In", NSSelectorFromString("zoomIn:"), "="),
            item("Zoom Out", NSSelectorFromString("zoomOut:"), "-"),
            item("Actual Size", NSSelectorFromString("zoomToActualSize:"), "0"),
            .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])
        let go = menu("Go", [
            item("Back", #selector(BoardWindowController.goBack(_:)), "["),
            item("Enclosing Board", #selector(BoardWindowController.enclosingBoard(_:)), upArrow),
            item("Open", #selector(BoardWindowController.openSelection(_:)), downArrow),
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

/// The menu bar: as any, but an item whose key is an arrow key (Go › Enclosing Board, ⌘↑, and Open,
/// ⌘↓) leaves that key to the key window while it's disabled, as it is while text has the keyboard,
/// so the text moves its caret with it. (AppKit's menus take a disabled item's key, and beep.)
final class MenuBar: NSMenu {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, let item = arrowItem(for: event, in: self) {
            item.menu?.update()
            if !item.isEnabled { return false }
        }
        return super.performKeyEquivalent(with: event)
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

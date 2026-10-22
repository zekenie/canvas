import AppKit
@_spi(Host) import Canvas

/// The app's menus, built in code (there's no nib): a document app's standard items, sent to the
/// first responder, so the canvas, a panel's field, the board's window controller, the document,
/// the document controller or the app answers whichever it is, and the plugins' commands, each where
/// its declaration says (`registrar.command(… menu:order:…)`, read as `registry.menuBarCommands`), made
/// in one loop and run by one action (`BoardWindowController.runCommand:`), which knows no command.
/// Edit's Undo, Redo, Cut, Copy, Paste, Delete and Select All are AppKit's own, which text answers
/// first, and run on the board the command that answers each (`registry.command(answering:)`). Edit ›
/// Spelling and Grammar's are the text's with the keyboard (dimmed anywhere else): a text that checks
/// its words as the app does (TextEditing's `Spelling`) turns its toggles over for every such text.
/// AppKit fills Open Recent (it finds the menu by its Clear Menu item) and, since boards autosave in
/// place, turns Save As into Duplicate and Revert to Saved into Revert To. Shape, after Edit, fills
/// itself each time it opens (`ShapeMenu`). A menu no command and no item of the window's is in isn't
/// there: a list without Grouping and Reordering has no Arrange.
@MainActor
public enum BoardMenus {
    public struct Menus {
        public let main: NSMenu
        public let services: NSMenu
        public let windows: NSMenu
        public let help: NSMenu
    }

    /// The command a menu item runs: one of the plugins' (`runCommand:`), or, for one of AppKit's own
    /// that runs one on the board (Edit › Cut), the command that answers it. Nil for any other.
    public static func command(of item: NSMenuItem) -> CanvasCommand? { item.representedObject as? CanvasCommand }

    /// The menus of a Mac app in the order they come, by title: the window's own and those commands
    /// name, as Apple's apps place them (Keynote's Arrange before View, the Finder's Go after it). A
    /// menu a command names that isn't here goes before Window, in the order commands first name it.
    static let menuOrder = ["File", "Edit", "Shape", "Format", "Arrange", "View", "Go"]

    /// What Infinite Canvas › Settings… (⌘,) sends up the responder chain: the app's delegate answers
    /// it, showing its Settings window (AppKit has no standard action for it).
    public static let showSettings = NSSelectorFromString("showSettings:")

    /// What Help › Keyboard Shortcuts (⌥⌘/) sends up the responder chain: the app's delegate answers
    /// it, showing its Keyboard Shortcuts window (`KeyboardShortcutsWindow`).
    public static let showKeyboardShortcuts = NSSelectorFromString("showKeyboardShortcuts:")

    /// Installs the menus as the app's, with `registry`'s commands.
    public static func install(appName: String, registry: Registry) {
        let menus = make(appName: appName, registry: registry)
        NSApp.mainMenu = menus.main
        NSApp.servicesMenu = menus.services
        NSApp.windowsMenu = menus.windows
        NSApp.helpMenu = menus.help
    }

    /// The menus, with `registry`'s commands. Shape's items are the selection's menu
    /// (`editor.menuForSelection`) of the editor `editor` gives when the menu opens: the key window's
    /// board by default.
    public static func make(appName: String, registry: Registry, editor: @escaping @MainActor () -> CanvasEditor? = keyBoardEditor) -> Menus {
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
        // The window's own items of every menu but the app's, each at its order there (a line between two
        // whose orders are in different hundreds), among which the commands placed in that menu go
        // (`registrar.command(… menu: "Edit", order: 140 …)`). AppKit's own items of Edit run on the board
        // the command that answers each (`registry.command(answering:)`); the window's other own items
        // (Copy as Image, the inspector's and the minimap's) run none.
        let standard: (String, StandardAction, String, String, NSEvent.ModifierFlags) -> NSMenuItem = { title, action, selector, key, modifiers in
            let made = item(title, NSSelectorFromString(selector), key, modifiers)
            made.representedObject = registry.command(answering: action)
            return made
        }
        let own: [String: [Placed]] = [
            "File": [
                Placed(0, item("New", #selector(NSDocumentController.newDocument(_:)), "n")),
                Placed(10, item("Open…", #selector(NSDocumentController.openDocument(_:)), "o")),
                Placed(20, submenu("Open Recent", menu("Open Recent", [item("Clear Menu", #selector(NSDocumentController.clearRecentDocuments(_:)))]))),
                Placed(100, item("Close", #selector(NSWindow.performClose(_:)), "w")),
                Placed(110, item("Save…", NSSelectorFromString("saveDocument:"), "s")),
                Placed(120, item("Save As…", NSSelectorFromString("saveDocumentAs:"), "s", [.command, .shift])),
                Placed(130, item("Revert to Saved", NSSelectorFromString("revertDocumentToSaved:"))),
            ],
            "Edit": [
                Placed(0, standard("Undo", .undo, "undo:", "z", .command)),
                Placed(10, standard("Redo", .redo, "redo:", "z", [.command, .shift])),
                Placed(100, standard("Cut", .cut, "cut:", "x", .command)),
                Placed(110, standard("Copy", .copy, "copy:", "c", .command)),
                Placed(120, item("Copy as Image", #selector(BoardWindowController.copyAsImage(_:)), "c", [.command, .shift])),
                Placed(130, standard("Paste", .paste, "paste:", "v", .command)),
                Placed(160, standard("Delete", .delete, "delete:", "", .command)),
                Placed(170, standard("Select All", .selectAll, "selectAll:", "a", .command)),
                Placed(290, submenu("Spelling and Grammar", menu("Spelling and Grammar", [
                    item("Show Spelling and Grammar", NSSelectorFromString("showGuessPanel:"), ":"),
                    item("Check Document Now", NSSelectorFromString("checkSpelling:"), ";"),
                    .separator(),
                    item("Check Spelling While Typing", NSSelectorFromString("toggleContinuousSpellChecking:")),
                    item("Check Grammar With Spelling", NSSelectorFromString("toggleGrammarChecking:")),
                    item("Correct Spelling Automatically", NSSelectorFromString("toggleAutomaticSpellingCorrection:")),
                ]))),
            ],
            "View": [
                Placed(0, item("Show Toolbar", #selector(NSWindow.toggleToolbarShown(_:)), "t", [.command, .option])),
                Placed(10, item("Show Inspector", #selector(BoardWindowController.toggleDetails(_:)), "i", [.command, .control])),
                Placed(20, item("Focus Inspector", #selector(BoardWindowController.focusInspector(_:)), "i", [.command, .option])),
                Placed(24, item("Focus Next Pane", #selector(BoardWindowController.focusNextPane(_:)), Self.f6, [])),
                Placed(25, item("Focus Previous Pane", #selector(BoardWindowController.focusPreviousPane(_:)), Self.f6, .shift)),
                Placed(30, item("Show Minimap", #selector(BoardWindowController.toggleMinimap(_:)), "m", [.command, .control])),
                Placed(900, item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])),
            ],
            "Window": [
                Placed(0, item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")),
                Placed(10, item("Zoom", #selector(NSWindow.performZoom(_:)))),
                Placed(100, item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))),
            ],
            "Help": [
                Placed(0, item("Keyboard Shortcuts", showKeyboardShortcuts, "/", [.command, .option])),
            ],
        ]
        // What the selection's context menu offers, less what the menu bar has: its items fill themselves
        // in each time it opens, so it holds none to start with, and it holds no command of its own.
        let shape = ShapeMenu(editor: editor)
        // Every menu in the Mac's order, then those only commands name, in the order they first do, then
        // Window and Help; each made in one loop of the window's own items and the commands placed there.
        let commands = registry.menuBarCommands
        // Shape is the selection's context menu, made as it opens: a command reaches it through a context
        // menu's item that runs it, never by placing itself there, which would put it in no menu at all.
        precondition(!commands.contains { $0.menu.titles[0] == shape.title },
                     "Shape holds the selection's context menu: give the command a context-menu item (MenuItem(command:)) instead")
        var titles = Self.menuOrder
        for command in commands where !titles.contains(command.menu.titles[0]) && !Self.lastMenus.contains(command.menu.titles[0]) {
            titles.append(command.menu.titles[0])
        }
        let main = MenuBar(title: "Main Menu")
        main.addItem(submenu(app.title, app))
        var made: [String: NSMenu] = [:]
        for title in titles + Self.lastMenus {
            if title == shape.title {
                main.addItem(submenu(title, shape))
                continue
            }
            let placed = (own[title] ?? []) + Placed.commands(commands.filter { $0.menu.titles[0] == title }, at: 1)
            guard !placed.isEmpty else { continue }
            made[title] = menu(title, Placed.arranged(placed))
            main.addItem(submenu(title, made[title]!))
        }
        shape.omitting = Set(Self.commands(in: main))
        return Menus(main: main, services: services, windows: made["Window"]!, help: made["Help"]!)
    }

    /// The menus that come last, after every other, whatever names them.
    static let lastMenus = ["Window", "Help"]

    /// Every command an item of `menu` runs, or one of its submenus'.
    static func commands(in menu: NSMenu) -> [CanvasCommand] {
        menu.items.flatMap { item in item.submenu.map(commands) ?? command(of: item).map { [$0] } ?? [] }
    }

    /// The item for a command: its title and the key it shows, run by the window's one action, which
    /// reads the command off it.
    static func item(for command: MenuBarCommand) -> NSMenuItem {
        let made = item(command.title, #selector(BoardWindowController.runCommand(_:)), command.key?.key ?? "", command.key?.modifierFlags ?? [])
        made.representedObject = command.command
        return made
    }

    /// The editor of the window that has the keyboard, if it's a board's.
    public static let keyBoardEditor: @MainActor () -> CanvasEditor? = {
        [NSApp.keyWindow, NSApp.mainWindow].lazy.compactMap { $0 as? BoardWindow }.first?.editor
    }

    /// F6, the key of View › Focus Next Pane.
    fileprivate static let f6 = String(UnicodeScalar(UInt16(NSF6FunctionKey))!)

    fileprivate static func item(_ title: String, _ action: Selector, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { item.keyEquivalentModifierMask = modifiers }
        return item
    }

    fileprivate static func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
        let menu = NSMenu(title: title)
        for item in items { menu.addItem(item) }
        return menu
    }

    fileprivate static func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}

/// An item of a menu at its order there: one of the window's own, or a command's.
@MainActor
struct Placed {
    let order: Int
    let item: NSMenuItem

    init(_ order: Int, _ item: NSMenuItem) {
        self.order = order
        self.item = item
    }

    /// The items by their order (of two at one order, the one that came first), a line between two whose
    /// orders are in different hundreds (-10 is in the hundred before 0's).
    static func arranged(_ placed: [Placed]) -> [NSMenuItem] {
        let sorted = placed.enumerated().sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }.map(\.element)
        let hundred: (Int) -> Int = { order in order >= 0 ? order / 100 : (order - 99) / 100 }
        var items: [NSMenuItem] = []
        for (index, entry) in sorted.enumerated() {
            if index > 0, hundred(sorted[index - 1].order) != hundred(entry.order) { items.append(.separator()) }
            items.append(entry.item)
        }
        return items
    }

    /// The commands' items at a level of a menu, `depth` titles down their paths: a command whose path
    /// ends here an item at its order, and those in a submenu of it (`"Edit › Find"`) that submenu, at
    /// the order of its first.
    static func commands(_ commands: [MenuBarCommand], at depth: Int) -> [Placed] {
        var placed: [Placed] = []
        var submenus: [String] = []
        for command in commands {
            if command.menu.titles.count == depth {
                placed.append(Placed(command.order, BoardMenus.item(for: command)))
            } else if !submenus.contains(command.menu.titles[depth]) {
                submenus.append(command.menu.titles[depth])
            }
        }
        for title in submenus {
            let inside = Self.commands(commands.filter { $0.menu.titles.count > depth && $0.menu.titles[depth] == title }, at: depth + 1)
            placed.append(Placed(inside.map(\.order).min() ?? 0, BoardMenus.submenu(title, BoardMenus.menu(title, arranged(inside)))))
        }
        return placed
    }
}

/// The Shape menu: what a right-click on the selected shapes would open (the plugin that claims the
/// selection's menu makes it: `editor.menuForSelection`), less the items the menu bar already has,
/// the ones that run a command one of its items runs (`omitting`: Cut, Copy, Paste, Duplicate, Delete,
/// Select All, Group, Ungroup, the restacking and the rest). It holds nothing until it opens, and fills
/// itself then from the editor of the window that has the keyboard, with the selection as it is;
/// nothing selected, nothing in it. The items it's given know their editor, so a pick reaches the
/// window it was made for. Its items show their keys, but only while it's open: AppKit isn't asked for
/// a key equivalent here (`menuHasKeyEquivalent`), and it empties as it closes, so a key never reaches
/// a stale item.
final class ShapeMenu: NSMenu, NSMenuDelegate {
    private let editor: @MainActor () -> CanvasEditor?
    /// The commands the menu bar's items run, which this menu leaves out.
    var omitting: Set<CanvasCommand> = []

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
            guard let made = editor()?.menuForSelection(omitting: omitting) else { return }
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
/// where it types ("!" on a US keyboard, a quote for ⌥]), and from a control of the panel (a checkbox), whose key it
/// is; only the canvas, the window itself and a list (the table of contents) answer the key it names (a digit
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
                // Only where the key is the board's: the canvas, the window itself, a list (the table of
                // contents). A panel's checkbox or button with the keyboard types or presses its own.
                let boards = MainActor.assumeIsolated {
                    let responder = (window ?? NSApp.keyWindow)?.firstResponder
                    return responder is CanvasView || responder is NSTableView || responder === (window ?? NSApp.keyWindow)
                }
                if !boards { return false }
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

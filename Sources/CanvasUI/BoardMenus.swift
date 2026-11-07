import AppKit
@_spi(Host) import Canvas

/// The app's menus, built in code (there's no nib): a document app's standard items, sent to the
/// first responder, so the canvas, a panel's field, the board's window controller, the document,
/// the document controller or the app answers whichever it is, and the plugins' commands, each in the
/// section its declaration names and where it says there (`registrar.command(… in:placed:…)`, read as
/// `registry.menuBarCommands`), arranged with the window's own items section by section (`MenuLayout`)
/// and run by one action (`BoardWindowController.runCommand:`), which knows no command.
/// Edit's Undo, Redo, Cut, Copy, Paste, Delete and Select All are AppKit's own, which text answers
/// first, and run on the board the command that answers each (`registry.command(answering:)`). Edit ›
/// Spelling and Grammar's are the text's with the keyboard (dimmed anywhere else): a text that checks
/// its words as the app does (TextEditing's `Spelling`) turns its toggles over for every such text.
/// AppKit fills Open Recent (it finds the menu by its Clear Menu item) and, since boards autosave in
/// place, turns Save As into Duplicate and Revert to Saved into Revert To. Shape, after Edit, fills
/// itself each time it opens (`ShapeMenu`). A menu no command and no item of the window's is in isn't
/// there: a list without Grouping and Reordering has no Arrange. An item whose command's plugin is in a
/// kit that's off in the key window's file isn't there either (`showCommands(of:in:registry:)`), and
/// File ▸ Kits, the core's item for each kit, turns one on or off.
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
    /// name, as Apple's apps place them (Keynote's and Freeform's Insert after Edit, Keynote's Arrange
    /// before View, the Finder's Go after it). A menu a command names that isn't here goes before
    /// Window, in the order commands first name it.
    static let menuOrder = ["File", "Edit", "Insert", "Shape", "Format", "Arrange", "View", "Go"]

    /// What Infinite Canvas › Settings… (⌘,) sends up the responder chain: the app's delegate answers
    /// it, showing its Settings window (AppKit has no standard action for it).
    public static let showSettings = NSSelectorFromString("showSettings:")

    /// What Help › Keyboard Shortcuts (⌥⌘/) sends up the responder chain: the app's delegate answers
    /// it, showing its Keyboard Shortcuts window (`KeyboardShortcutsWindow`).
    public static let showKeyboardShortcuts = NSSelectorFromString("showKeyboardShortcuts:")

    /// Installs the menus as the app's, with `registry`'s commands.
    public static func install(appName: String, registry: Registry) {
        let menus = make(appName: appName, registry: registry)
        showCommands(of: keyBoardEditor(), in: menus.main, registry: registry)
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
        // The window's own items of every menu but the app's, each in a section, in the order they come
        // there: the core's sections, where commands go beside them (`EditMenu`, `ViewMenu.Panels` and
        // `.Zoom`), or the window's alone. AppKit's own items of Edit run on the board the command that answers each
        // (`registry.command(answering:)`), and a command is placed beside one by naming that command
        // (`placed: .after(.paste)`); the window's other own items (Copy as Image, the inspector's and the
        // minimap's) run none, and nothing is placed beside them.
        let standard: (String, StandardAction, String, String, NSEvent.ModifierFlags) -> NSMenuItem = { title, action, selector, key, modifiers in
            let made = item(title, NSSelectorFromString(selector), key, modifiers)
            made.representedObject = registry.command(answering: action)
            return made
        }
        let own: [OwnItems] = [
            OwnItems(FileMenu.Open.self, [
                item("New", #selector(NSDocumentController.newDocument(_:)), "n"),
                item("Open…", #selector(NSDocumentController.openDocument(_:)), "o"),
                submenu("Open Recent", menu("Open Recent", [item("Clear Menu", #selector(NSDocumentController.clearRecentDocuments(_:)))])),
            ]),
            OwnItems(FileMenu.Save.self, [
                item("Close", #selector(NSWindow.performClose(_:)), "w"),
                item("Save…", NSSelectorFromString("saveDocument:"), "s"),
                item("Save As…", NSSelectorFromString("saveDocumentAs:"), "s", [.command, .shift]),
                item("Revert to Saved", NSSelectorFromString("revertDocumentToSaved:")),
            ]),
            OwnItems(EditMenu.Undo.self, [
                standard("Undo", .undo, "undo:", "z", .command),
                standard("Redo", .redo, "redo:", "z", [.command, .shift]),
            ]),
            OwnItems(EditMenu.CutCopyPaste.self, [
                standard("Cut", .cut, "cut:", "x", .command),
                standard("Copy", .copy, "copy:", "c", .command),
                item("Copy as Image", #selector(BoardWindowController.copyAsImage(_:)), "c", [.command, .shift]),
                standard("Paste", .paste, "paste:", "v", .command),
                standard("Delete", .delete, "delete:", "", .command),
                standard("Select All", .selectAll, "selectAll:", "a", .command),
            ]),
            OwnItems(EditMenu.FindAndSpelling.self, [
                submenu("Spelling and Grammar", menu("Spelling and Grammar", [
                    item("Show Spelling and Grammar", NSSelectorFromString("showGuessPanel:"), ":"),
                    item("Check Document Now", NSSelectorFromString("checkSpelling:"), ";"),
                    .separator(),
                    item("Check Spelling While Typing", NSSelectorFromString("toggleContinuousSpellChecking:")),
                    item("Check Grammar With Spelling", NSSelectorFromString("toggleGrammarChecking:")),
                    item("Correct Spelling Automatically", NSSelectorFromString("toggleAutomaticSpellingCorrection:")),
                ])),
            ]),
            OwnItems(ViewMenu.Panels.self, [
                item("Show Toolbar", #selector(NSWindow.toggleToolbarShown(_:)), "t", [.command, .option]),
                item("Show Sidebar", #selector(BoardWindowController.toggleSidebarShown(_:)), "s", [.command, .control]),
                item("Focus Sidebar", #selector(BoardWindowController.focusSidebar(_:)), "s", [.command, .option]),
                item("Show Inspector", #selector(BoardWindowController.toggleDetails(_:)), "i", [.command, .control]),
                item("Focus Inspector", #selector(BoardWindowController.focusInspector(_:)), "i", [.command, .option]),
            ]),
            // The panes' focus and the minimap close the section, so what a plugin adds there says nothing to
            // go after the inspector's items (Next and Previous Inspector Tab), or last to go after these.
            OwnItems(ViewMenu.Panels.self, placed: .last, [
                item("Focus Next Pane", #selector(BoardWindowController.focusNextPane(_:)), Self.f6, []),
                item("Focus Previous Pane", #selector(BoardWindowController.focusPreviousPane(_:)), Self.f6, .shift),
                item("Show Minimap", #selector(BoardWindowController.toggleMinimap(_:)), "m", [.command, .control]),
            ]),
            OwnItems(ViewMenu.FullScreen.self, [
                item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
            ]),
            OwnItems(WindowMenu.ThisWindow.self, [
                item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
                item("Zoom", #selector(NSWindow.performZoom(_:))),
            ]),
            OwnItems(WindowMenu.AllWindows.self, [
                item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
            ]),
            OwnItems(HelpMenu.Shortcuts.self, [
                item("Keyboard Shortcuts", showKeyboardShortcuts, "/", [.command, .option]),
            ]),
        ]
        // What the selection's context menu offers, less what the menu bar has: its items fill themselves
        // in each time it opens, so it holds none to start with, and it holds no command of its own.
        let shape = ShapeMenu(editor: editor)
        // The window's own items, then the commands' in plugin order, each in its section.
        var layout = MenuLayout()
        for list in own {
            for item in list.items { layout.add(item, in: list.section, anchor: Self.command(of: item).map(OrderAnchor.init), rule: list.rule) }
        }
        for command in registry.menuBarCommands {
            layout.add(item(for: command), in: command.section, anchor: OrderAnchor(command.command), rule: command.placement)
        }
        // Shape is the selection's context menu, made as it opens: a command reaches it through a context
        // menu's item that runs it, never by placing itself there, which would put it in no menu at all.
        precondition(!layout.titles.contains(shape.title),
                     "Shape holds the selection's context menu: give the command a context-menu item (MenuItem(command:)) instead")
        // Every menu in the Mac's order, then those only commands name, in the order they first do, then
        // Window and Help.
        var titles = Self.menuOrder
        for title in layout.titles where !titles.contains(title) && !Self.lastMenus.contains(title) {
            titles.append(title)
        }
        let main = MenuBar(title: "Main Menu")
        main.addItem(submenu(app.title, app))
        var made: [String: NSMenu] = [:]
        for title in titles + Self.lastMenus {
            if title == shape.title {
                main.addItem(submenu(title, shape))
                continue
            }
            guard let menu = layout.menu(titled: title) else { continue }
            made[title] = menu
            main.addItem(submenu(title, menu))
        }
        shape.omitting = Set(Self.commands(in: main))
        addOtherKeys(in: main, registry: registry)
        return Menus(main: main, services: services, windows: made["Window"]!, help: made["Help"]!)
    }

    /// Puts after each item that runs a command a hidden item for each other key that runs it (as the plugin
    /// that keeps the keys gives them, `registry.menuKeys(of:)`) held with ⌘ or ⌃, which type nothing: the
    /// same command, title and action, so AppKit's menus and `MenuBar` answer that key wherever the item's
    /// own works (Go › Back's ⌃-, beside its ⌘[, with text being typed too), and the controller's validation
    /// dims it with the item. A key held with neither types, and is the canvas's to answer (= and -, which
    /// zoom again and again while held): no item takes it.
    static func addOtherKeys(in menu: NSMenu, registry: Registry) {
        for item in menu.items {
            if let submenu = item.submenu {
                addOtherKeys(in: submenu, registry: registry)
                continue
            }
            guard item.action == #selector(BoardWindowController.runCommand(_:)), let command = command(of: item) else { continue }
            var index = menu.index(of: item)
            for key in registry.menuKeys(of: command).dropFirst() where !key.modifiers.isDisjoint(with: [.command, .control]) {
                let other = Self.item(item.title, #selector(BoardWindowController.runCommand(_:)), key.key, key.modifierFlags)
                other.representedObject = command
                other.isHidden = true
                other.allowsKeyEquivalentWhenHidden = true
                other.tag = otherKeyTag
                index += 1
                menu.insertItem(other, at: index)
            }
        }
    }

    /// The menus that come last, after every other, whatever names them.
    static let lastMenus = ["Window", "Help"]

    /// What marks a hidden item for another key of the item before it (`addOtherKeys`), which stays hidden
    /// and answers its key only while its command is there (`showCommands`).
    static let otherKeyTag = 0x6b657973

    /// Shows in `menu` the items of the commands the key window's file has (`editor.claims`), and only
    /// those: an item whose command's plugin is in a kit that's off there (`registrar.join`) is hidden, not
    /// dimmed, its other keys answer nothing, and a line or a submenu left with nothing to show between
    /// goes too, and comes back with it. With no board's window (`editor` nil) every kit is off, as in a new
    /// file. The menu bar is the app's, so a board's window calls this as it becomes key and as its file's
    /// kits change (`BoardWindowController`). Nothing changes for a list whose plugins join no kit.
    public static func showCommands(of editor: CanvasEditor?, in menu: NSMenu, registry: Registry) {
        guard !registry.kits.isEmpty else { return }
        showCommands(in: menu) { command in
            editor?.claims(command) ?? (registry.claims(command) && registry.kit(ofCommand: command) == nil)
        }
    }

    /// Shows in `menu`, and in its submenus, the items of the commands `isThere` says, then the lines and
    /// submenus around them; returns whether it holds a command's item at any depth (a menu that holds none,
    /// Open Recent or Services, is left as AppKit has it).
    @discardableResult
    private static func showCommands(in menu: NSMenu, where isThere: (CanvasCommand) -> Bool) -> Bool {
        var holdsCommands = false
        for item in menu.items {
            if let submenu = item.submenu {
                guard showCommands(in: submenu, where: isThere) else { continue }
                holdsCommands = true
                item.isHidden = !submenu.items.contains { !$0.isHidden && !$0.isSeparatorItem }
                continue
            }
            guard item.action == #selector(BoardWindowController.runCommand(_:)), let command = command(of: item) else { continue }
            holdsCommands = true
            if item.tag == otherKeyTag { item.allowsKeyEquivalentWhenHidden = isThere(command) } else { item.isHidden = !isThere(command) }
        }
        guard holdsCommands else { return false }
        // A line shows between two items that show, and only one.
        var after = false, line: NSMenuItem?
        for item in menu.items {
            if item.isSeparatorItem {
                item.isHidden = true
                if after, line == nil { line = item }
            } else if !item.isHidden {
                line?.isHidden = false
                line = nil
                after = true
            }
        }
        return true
    }

    /// Some of the window's own items of a section, in the order they come, each placed among the
    /// section's items as `rule` says (by default where it first appears).
    struct OwnItems {
        let section: any MenuBarSection.Type
        let rule: OrderRule
        let items: [NSMenuItem]

        init(_ section: any MenuBarSection.Type, placed rule: OrderRule = .natural, _ items: [NSMenuItem]) {
            self.section = section
            self.rule = rule
            self.items = items
        }
    }

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

    /// The editor of the window that has the keyboard, if it's a board's; none in a process with no app (a test's).
    public static let keyBoardEditor: @MainActor () -> CanvasEditor? = {
        guard let app = NSApp else { return nil }
        return [app.keyWindow, app.mainWindow].lazy.compactMap { $0 as? BoardWindow }.first?.editor
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

/// The menus as sections of items, gathered as the window's own items and the commands' are added: a
/// menu's sections in the order first met, a section's items too, and a submenu an item of the section
/// it's in, met with the first section in it. Made into menus with each section and each item arranged
/// by its order (`OrderRule.arranged`), a line between two sections.
@MainActor
struct MenuLayout {
    /// The menu bar's menus' titles, in the order first met.
    private(set) var titles: [String] = []
    private var sections: [ObjectIdentifier: Section] = [:]
    private var menus: [Menu: [ObjectIdentifier]] = [:]

    /// A menu: one of the menu bar's, by title, or a submenu, by the section it's in and its title.
    private enum Menu: Hashable {
        case named(String)
        case submenu(in: ObjectIdentifier, String)
    }

    private struct Section {
        let type: any MenuBarSection.Type
        var entries: [Entry] = []
    }

    /// An item of a section, or a submenu, with how another item names it (the command it runs, if
    /// any) and its place among the section's.
    private struct Entry {
        let anchor: OrderAnchor?
        let rule: OrderRule
        let content: Content
    }

    private enum Content {
        case item(NSMenuItem)
        case submenu(Menu, title: String)
    }

    /// Adds `item` to `section`, named by `anchor` and placed by `rule` among the section's items.
    mutating func add(_ item: NSMenuItem, in section: any MenuBarSection.Type, anchor: OrderAnchor?, rule: OrderRule = .natural) {
        enter(section)
        sections[ObjectIdentifier(section)]!.entries.append(Entry(anchor: anchor, rule: rule, content: .item(item)))
    }

    /// Makes `section` one of its menu's, the first time it's met; a submenu met for the first time
    /// becomes an item of the section it's in, at the place it says.
    private mutating func enter(_ section: any MenuBarSection.Type) {
        let id = ObjectIdentifier(section)
        guard sections[id] == nil else { return }
        sections[id] = Section(type: section)
        let menu: Menu
        switch section.menu {
        case .named(let title):
            menu = .named(title)
            if !titles.contains(title) { titles.append(title) }
        case .submenu(let title, let parent, let placed):
            menu = .submenu(in: ObjectIdentifier(parent), title)
            if menus[menu] == nil {
                enter(parent)
                sections[ObjectIdentifier(parent)]!.entries.append(Entry(anchor: nil, rule: placed.rule, content: .submenu(menu, title: title)))
            }
        }
        menus[menu, default: []].append(id)
    }

    /// The menu bar's menu titled `title`, made; nil for one nothing is in.
    func menu(titled title: String) -> NSMenu? {
        menus[.named(title)] == nil ? nil : make(.named(title), title: title)
    }

    private func make(_ menu: Menu, title: String) -> NSMenu {
        let made = NSMenu(title: title)
        let order = OrderRule.arranged(menus[menu] ?? []) { (sections[$0]!.type.orderAnchor, sections[$0]!.type.orderRule) }
        for id in order {
            if !made.items.isEmpty { made.addItem(.separator()) }
            for entry in OrderRule.arranged(sections[id]!.entries, by: { ($0.anchor, $0.rule) }) {
                switch entry.content {
                case .item(let item): made.addItem(item)
                case .submenu(let inner, let innerTitle): made.addItem(BoardMenus.submenu(innerTitle, make(inner, title: innerTitle)))
                }
            }
        }
        return made
    }
}

// The window's own sections, which only its items are in; those its items share with commands are the
// core's (`EditMenu`, `ViewMenu.Panels` and `.Zoom`), and come in the order the window lists its items, as
// File's own do before the core's Kits (`FileMenu.Kits`).

extension FileMenu {
    /// New, Open… and Open Recent.
    enum Open {}
    /// Close, Save…, Save As… and Revert to Saved.
    enum Save {}
}

extension FileMenu.Open: MenuBarSection {
    static var menu: MenuBarMenu { "File" }
}

extension FileMenu.Save: MenuBarSection {
    static var menu: MenuBarMenu { "File" }
}

extension ViewMenu {
    /// Enter Full Screen, the last of View, as the Mac has it, whatever else is there.
    enum FullScreen {}
}

extension ViewMenu.FullScreen: MenuBarSection {
    static var menu: MenuBarMenu { "View" }
    static var order: Order<Self> { .last }
}

enum WindowMenu {
    /// Minimize and Zoom: what's done to the window.
    enum ThisWindow {}
    /// Bring All to Front.
    enum AllWindows {}
}

extension WindowMenu.ThisWindow: MenuBarSection {
    static var menu: MenuBarMenu { "Window" }
}

extension WindowMenu.AllWindows: MenuBarSection {
    static var menu: MenuBarMenu { "Window" }
}

enum HelpMenu {
    /// Keyboard Shortcuts.
    enum Shortcuts {}
}

extension HelpMenu.Shortcuts: MenuBarSection {
    static var menu: MenuBarMenu { "Help" }
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
/// is the number row's key, whatever the layout types with it), and leaves it while it's disabled. A
/// hidden item's key (another key of the item before it, held with ⌘ or ⌃: `BoardMenus.addOtherKeys`)
/// types nothing, and is answered wherever that item's own is, a panel's control and text included.
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
                // contents). A panel's checkbox or button with the keyboard types or presses its own; but
                // a hidden item's key, another key of the item before it held with ⌃ (`addOtherKeys`),
                // types nothing, and is answered wherever that item's own is (Go › Back's ⌃-).
                let boards = MainActor.assumeIsolated {
                    let responder = (window ?? NSApp.keyWindow)?.firstResponder
                    return responder is CanvasView || responder is NSTableView || responder === (window ?? NSApp.keyWindow)
                }
                if !boards, menu.item(at: index)?.isHidden != true { return false }
                menu.update()
                guard let item = menu.item(at: index), item.isEnabled else { return false }
                if event.isARepeat { return true }
                menu.performActionForItem(at: index)
                return true
            }
            // AppKit's own matching hands Return to an item that names ⇧↩ (Insert › Note), which would put a note down
            // where Return opens the selection: an item that names the key with other modifiers takes it from none.
            if let key = typed, key.count == 1, typedItem(key.first!, nil, in: self) != nil { return false }
        }
        return super.performKeyEquivalent(with: event)
    }

    private static let keyModifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    /// The item, in `menu` or a menu under it, whose key equivalent is `key` (in any case) with exactly
    /// these modifiers (with any, for nil), and where it is.
    private func typedItem(_ key: Character, _ modifiers: NSEvent.ModifierFlags?, in menu: NSMenu) -> (NSMenu, Int)? {
        for (index, item) in menu.items.enumerated() {
            if item.keyEquivalent.lowercased() == String(key).lowercased(),
               modifiers.map({ item.keyEquivalentModifierMask.intersection(Self.keyModifiers) == $0 }) ?? true {
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

import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import TestKit

// The menu bar the window makes: its own items, and the plugins' commands, each in the section its
// declaration names and where it says there (`registrar.command(… in:placed:…)`), a line between two
// sections. Fixtures only: the window knows no shipped command.

/// What the selection's menu was told to leave out, each time it was asked.
@MainActor private final class Omitted {
    var asked: [Set<CanvasCommand>] = []
}

/// Stands in for a board window's controller: the commands its items ran, enabled while `enabled` says.
@MainActor private final class CommandRuns: NSObject, NSMenuItemValidation {
    var commands: [CanvasCommand] = []
    var enabled = true
    @objc func runCommand(_ sender: NSMenuItem) { BoardMenus.command(of: sender).map { commands.append($0) } }
    func validateMenuItem(_ item: NSMenuItem) -> Bool { enabled }
}

/// A control of a panel's with the keyboard: no canvas, list or window, so a plain key is its own.
private final class FocusableControl: NSView {
    override var acceptsFirstResponder: Bool { true }
}

/// Commands in sections of their own and in the window's, a key for one of them, and one that answers
/// the standard Delete, which the window's Delete runs, so an item placed beside it is placed beside Delete.
@MainActor private let declared = Contributor(id: "declared") { r in
    r.command("tidy", title: "Tidy", in: TidySection.self, runs: .whenIdle) { _ in }
    r.command("stack", title: "Stack", in: StackSection.self) { _ in }
    r.command("spin", title: "Spin", in: TidySection.self) { _ in }
    r.command("seek", title: "Seek…", in: SeekSection.self) { _ in }
    r.command("seek-next", title: "Seek Next", in: SeekSection.self) { _ in }
    r.command("shine", title: "Shine", in: EditMenu.CutCopyPaste.self, placed: .before("wipe")) { _ in }
    r.command("wander", title: "Wander", in: WanderSection.self) { _ in }
    r.command("brew", title: "Brew", in: BrewSection.self) { _ in }
    r.command("guide", title: "Guide", in: GuideSection.self) { _ in }
    r.command("wipe", title: "Wipe", answering: .delete) { _ in }
    r.menuKeys { command, _ in command == "tidy" ? [MenuKey(key: "t", modifiers: [.command, .option])] : [] }
}

/// Arrange's two: Tidy's, first met, and Stack's, which says it's first.
private enum TidySection {}
extension TidySection: MenuBarSection {
    static var menu: MenuBarMenu { "Arrange" }
}

private enum StackSection {}
extension StackSection: MenuBarSection {
    static var menu: MenuBarMenu { "Arrange" }
    static var order: Order<Self> { .first }
}

/// Edit › Seek, first in the section Spelling and Grammar is in; and a second section in it.
private enum SeekSection {}
extension SeekSection: MenuBarSection {
    static var menu: MenuBarMenu { .submenu("Seek", in: EditMenu.FindAndSpelling.self, placed: .first) }
}

private enum SeekMoreSection {}
extension SeekMoreSection: MenuBarSection {
    static var menu: MenuBarMenu { .submenu("Seek", in: EditMenu.FindAndSpelling.self, placed: .first) }
}

private enum WanderSection {}
extension WanderSection: MenuBarSection {
    static var menu: MenuBarMenu { "Go" }
}

/// A menu the window doesn't know.
private enum BrewSection {}
extension BrewSection: MenuBarSection {
    static var menu: MenuBarMenu { "Kitchen" }
}

/// After the window's own in Help.
private enum GuideSection {}
extension GuideSection: MenuBarSection {
    static var menu: MenuBarMenu { "Help" }
}

/// One of View's, which comes before Enter Full Screen's, last.
private enum PeekSection {}
extension PeekSection: MenuBarSection {
    static var menu: MenuBarMenu { "View" }
}

@MainActor private func titles(_ menus: BoardMenus.Menus, _ menu: String) throws -> [String] {
    try require(menus.main.item(withTitle: menu)?.submenu, menu).items.map(\.title)
}

@MainActor let menuBarTests = Suite("The menu bar", [
    test("a command is an item in the section it names, placed among the window's own items, a line between two sections, run by one action with the command it carries and the key the menu keys slot gives") {
        let menus = BoardMenus.make(appName: "Canvas", registry: try Registry(plugins: [declared]))
        expectEqual(try titles(menus, "Arrange"), ["Stack", "", "Tidy", "Spin"])
        let arrange = try require(menus.main.item(withTitle: "Arrange")?.submenu)
        expectEqual(arrange.items.compactMap(BoardMenus.command(of:)), ["stack", "tidy", "spin"])
        for item in arrange.items where !item.isSeparatorItem {
            expectEqual(item.action, #selector(BoardWindowController.runCommand(_:)), item.title)
        }
        let tidy = try require(arrange.item(withTitle: "Tidy"))
        expectEqual(tidy.keyEquivalent, "t")
        expectEqual(tidy.keyEquivalentModifierMask, [.command, .option])
        expectEqual(try require(arrange.item(withTitle: "Spin")).keyEquivalent, "", "no key without one from the slot")
        expectEqual(try titles(menus, "Edit"), ["Undo", "Redo", "", "Cut", "Copy", "Copy as Image", "Paste", "Shine", "Delete", "Select All", "",
                                               "Seek", "Spelling and Grammar"],
                    "right before the window's Delete, which runs the command it names; a submenu first in its section, beside Spelling with no line between")
        let seek = try require(menus.main.item(withTitle: "Edit")?.submenu?.item(withTitle: "Seek")?.submenu)
        expectEqual(seek.items.map(\.title), ["Seek…", "Seek Next"])
        expectEqual(seek.items.compactMap(BoardMenus.command(of:)), ["seek", "seek-next"])
        expectEqual(try titles(menus, "View"), ["Show Toolbar", "Show Sidebar", "Focus Sidebar", "Show Inspector", "Focus Inspector", "Focus Next Pane", "Focus Previous Pane", "Show Minimap", "", "Zoom In", "Zoom Out",
                                               "Actual Size", "Zoom to Fit", "", "Enter Full Screen"], "the core's zooms, among the window's own")
    },
    test("sections and items go where they say beside each other: a submenu's sections inside it with a line between, an item first, one beside a command that isn't there where one that says nothing goes, and Enter Full Screen last") {
        let menus = BoardMenus.make(appName: "Canvas", registry: try Registry(plugins: [declared, Contributor(id: "more") { r in
            r.command("seek-more", title: "Seek More", in: SeekMoreSection.self) { _ in }
            r.command("stray", title: "Stray", in: EditMenu.CutCopyPaste.self, placed: .after("gone")) { _ in }
            r.command("lead", title: "Lead", in: TidySection.self, placed: .first) { _ in }
            r.command("peek", title: "Peek", in: PeekSection.self) { _ in }
            r.command("lens", title: "Lens", in: ViewMenu.Panels.self) { _ in }
            r.command("glass", title: "Glass", in: ViewMenu.Panels.self, placed: .last) { _ in }
        }]))
        let seek = try require(menus.main.item(withTitle: "Edit")?.submenu?.item(withTitle: "Seek")?.submenu)
        expectEqual(seek.items.map(\.title), ["Seek…", "Seek Next", "", "Seek More"], "one submenu, both its sections inside it")
        expectEqual(try titles(menus, "Edit"), ["Undo", "Redo", "", "Cut", "Copy", "Copy as Image", "Paste", "Shine", "Delete", "Select All", "Stray", "",
                                               "Seek", "Spelling and Grammar"], "beside a command that isn't there: after the section's own")
        expectEqual(try titles(menus, "Arrange"), ["Stack", "", "Lead", "Tidy", "Spin"])
        expectEqual(try titles(menus, "View"), ["Show Toolbar", "Show Sidebar", "Focus Sidebar", "Show Inspector", "Focus Inspector", "Lens", "Focus Next Pane", "Focus Previous Pane",
                                               "Show Minimap", "Glass", "", "Zoom In", "Zoom Out", "Actual Size", "Zoom to Fit", "", "Peek", "",
                                               "Enter Full Screen"],
                    "among the panels, one that says nothing after the inspector's items, one placed last after the minimap's; a section of View's before Enter Full Screen")
    },
    test("the menus come in the Mac's order: Arrange after Shape, Go after View, one the window doesn't know before Window; a menu with nothing in it isn't there") {
        let menus = BoardMenus.make(appName: "Canvas", registry: try Registry(plugins: [declared]))
        expectEqual(menus.main.items.map(\.title), ["Canvas", "File", "Edit", "Insert", "Shape", "Arrange", "View", "Go", "Kitchen", "Window", "Help"])
        expectEqual(try titles(menus, "Help"), ["Keyboard Shortcuts", "", "Guide"], "one placed in the window's own Help, after its line")
        expect(menus.help === menus.main.item(withTitle: "Help")?.submenu && menus.windows === menus.main.item(withTitle: "Window")?.submenu)
        let none = BoardMenus.make(appName: "Canvas", registry: try Registry(plugins: []))
        expectEqual(none.main.items.map(\.title), ["Canvas", "File", "Edit", "Insert", "Shape", "View", "Window", "Help"], "the core's Insert, no Arrange, no Go")
        expectEqual(try titles(none, "Edit"), ["Undo", "Redo", "", "Cut", "Copy", "Copy as Image", "Paste", "Delete", "Select All", "", "Spelling and Grammar"])
    },
    test("AppKit's own items of Edit keep their actions, which text answers first, and carry the command that answers each on the board, if one does") {
        let menus = BoardMenus.make(appName: "Canvas", registry: try Registry(plugins: [declared]))
        let edit = try require(menus.main.item(withTitle: "Edit")?.submenu)
        let delete = try require(edit.item(withTitle: "Delete"))
        expectEqual(delete.action.map(NSStringFromSelector), "delete:")
        expectEqual(BoardMenus.command(of: delete), "wipe")
        expectEqual(BoardMenus.command(of: try require(edit.item(withTitle: "Undo"))), .undo, "the core's own")
        let cut = try require(edit.item(withTitle: "Cut"))
        expectEqual(cut.action.map(NSStringFromSelector), "cut:")
        expectEqual(BoardMenus.command(of: cut), nil, "nothing answers Cut: a text field's still")
        expectEqual(cut.keyEquivalent, "x")
    },
    test("a command's other keys held with ⌘ or ⌃ are hidden items after its own, answering wherever its key does; a key held with neither is left to the canvas; the Keyboard Shortcuts window lists the item once") {
        let registry = try Registry(plugins: [Contributor(id: "hops") { r in
            r.command("hop", title: "Hop", in: TidySection.self) { _ in }
            r.command("skip", title: "Skip", in: TidySection.self) { _ in }
            r.menuKeys { command, _ in
                command == "hop" ? [MenuKey(key: "[", modifiers: .command), MenuKey(key: "-", modifiers: .control), MenuKey(key: "h", modifiers: []),
                                    MenuKey(key: "j", modifiers: [.command, .shift])] : []
            }
        }])
        let menus = BoardMenus.make(appName: "Canvas", registry: registry)
        let arrange = try require(menus.main.item(withTitle: "Arrange")?.submenu)
        expectEqual(arrange.items.map(\.title), ["Hop", "Hop", "Hop", "Skip"], "one after it for each of ⌃- and ⇧⌘J; none for H")
        expectEqual(arrange.items.map(\.isHidden), [false, true, true, false])
        expectEqual(arrange.items.map(\.keyEquivalent), ["[", "-", "j", ""])
        expectEqual(arrange.items.map(\.keyEquivalentModifierMask).prefix(3), [.command, .control, [.command, .shift]])
        for item in arrange.items.prefix(3) {
            expectEqual(BoardMenus.command(of: item), "hop")
            expectEqual(item.action, #selector(BoardWindowController.runCommand(_:)))
        }
        expect(arrange.items[1].allowsKeyEquivalentWhenHidden && arrange.items[2].allowsKeyEquivalentWhenHidden, "AppKit answers a hidden item's key")
        let rows = [KeyboardHelpRow(keys: ["⌘[", "⌃-", "H", "⇧⌘J"], title: "Hop", place: .command("hop"))]
        let sections = KeyboardShortcutSection.sections(menu: menus.main, rows: rows)
        let filed = try require(sections.first { $0.title == "Arrange" })
        expectEqual(filed.rows.map(\.title), ["Hop"])
        expectEqual(filed.rows.first?.keys, ["⌘[", "⌃-", "H", "⇧⌘J"])
    },
    test("a hidden item's key, held with ⌃, is answered with a panel's control focused, where the control keeps a plain key and a dimmed item's key goes on") {
        let registry = try Registry(plugins: [Contributor(id: "hops") { r in
            r.command("hop", title: "Hop", in: TidySection.self) { _ in }
            r.command("tidy", title: "Tidy", in: TidySection.self) { _ in }
            r.menuKeys { command, _ in
                switch command {
                case "hop": [MenuKey(key: "[", modifiers: .command), MenuKey(key: "-", modifiers: .control)]
                case "tidy": [MenuKey(key: "]", modifiers: [])]
                default: []
                }
            }
        }])
        let menus = BoardMenus.make(appName: "Canvas", registry: registry)
        let runs = CommandRuns()
        for item in try require(menus.main.item(withTitle: "Arrange")?.submenu).items { item.target = runs }
        // Not deferred: its number is the key event's, which the menu bar reads the first responder through.
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let control = FocusableControl(frame: CGRect(x: 10, y: 10, width: 40, height: 20))
        window.contentView?.addSubview(control)
        expect(window.makeFirstResponder(control))
        expect(menus.main.performKeyEquivalent(with: window.keyEvent("\u{1f}", ignoringModifiers: "-", modifiers: .control)), "⌃- reached Hop")
        expect(!menus.main.performKeyEquivalent(with: window.keyEvent("]")), "] is the control's")
        expectEqual(runs.commands, ["hop"])
        runs.enabled = false
        expect(!menus.main.performKeyEquivalent(with: window.keyEvent("\u{1f}", ignoringModifiers: "-", modifiers: .control)), "dimmed, the key goes on")
        expectEqual(runs.commands, ["hop"])
    },
    test("the Shape menu leaves out every command the menu bar runs, its own items' and AppKit's") {
        let omitted = Omitted()
        let registry = try Registry(plugins: [declared, Contributor(id: "selection-menu") { r in
            r.menuForSelection { _, commands, _ in
                omitted.asked.append(commands)
                return NSMenu(title: "made")
            }
        }])
        let editor = CanvasEditor(registry: registry, scheduler: ManualScheduler())
        let menus = BoardMenus.make(appName: "Canvas", registry: registry, editor: { editor })
        let shape = try require(menus.main.item(withTitle: "Shape")?.submenu)
        shape.delegate?.menuNeedsUpdate?(shape)
        expectEqual(omitted.asked, [["stack", "tidy", "spin", "shine", "seek", "seek-next", "wander", "brew", "guide", "wipe", .undo, .redo, .insertBeside,
                                     .zoomIn, .zoomOut, .zoomToActualSize, .zoomToFit]])
    },
])

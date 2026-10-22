import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import TestKit

// The menu bar the window makes: its own items, and the plugins' commands, each where its declaration
// says (`registrar.command(… menu:order:…)`), made in one loop. Fixtures only: the window knows no
// shipped command.

/// What the selection's menu was told to leave out, each time it was asked.
@MainActor private final class Omitted {
    var asked: [Set<CanvasCommand>] = []
}

/// Commands placed in the window's menus and in menus of their own, a key for one of them, and one that
/// answers the standard Delete.
@MainActor private let declared = Contributor(id: "declared") { r in
    r.command("tidy", title: "Tidy", menu: "Arrange", order: 100, runs: .whenIdle) { _ in }
    r.command("stack", title: "Stack", menu: "Arrange", order: 0) { _ in }
    r.command("spin", title: "Spin", menu: "Arrange", order: 110) { _ in }
    r.command("seek", title: "Seek…", menu: "Edit › Seek", order: 200) { _ in }
    r.command("seek-next", title: "Seek Next", menu: "Edit › Seek", order: 210) { _ in }
    r.command("shine", title: "Shine", menu: "Edit", order: 140) { _ in }
    r.command("wander", title: "Wander", menu: "Go", order: 0) { _ in }
    r.command("brew", title: "Brew", menu: "Kitchen", order: 0) { _ in }
    r.command("guide", title: "Guide", menu: "Help", order: 100) { _ in }
    r.command("wipe", title: "Wipe", answering: .delete) { _ in }
    r.menuKeys { command, _ in command == "tidy" ? MenuKey(key: "t", modifiers: [.command, .option]) : nil }
}

@MainActor private func titles(_ menus: BoardMenus.Menus, _ menu: String) throws -> [String] {
    try require(menus.main.item(withTitle: menu)?.submenu, menu).items.map(\.title)
}

@MainActor let menuBarTests = Suite("The menu bar", [
    test("a command is an item in the menu it names, at its order among the window's own items, a line between hundreds, run by one action with the command it carries and the key the menu keys slot gives") {
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
                    "between the window's own, by its order; a submenu at its first item's, beside Spelling with no line between")
        let seek = try require(menus.main.item(withTitle: "Edit")?.submenu?.item(withTitle: "Seek")?.submenu)
        expectEqual(seek.items.map(\.title), ["Seek…", "Seek Next"])
        expectEqual(seek.items.compactMap(BoardMenus.command(of:)), ["seek", "seek-next"])
        expectEqual(try titles(menus, "View"), ["Show Toolbar", "Show Inspector", "Focus Inspector", "Focus Next Pane", "Focus Previous Pane", "Show Minimap", "", "Zoom In", "Zoom Out",
                                               "Actual Size", "Zoom to Fit", "", "Enter Full Screen"], "the core's zooms, among the window's own")
    },
    test("the menus come in the Mac's order: Arrange after Shape, Go after View, one the window doesn't know before Window; a menu with nothing in it isn't there") {
        let menus = BoardMenus.make(appName: "Canvas", registry: try Registry(plugins: [declared]))
        expectEqual(menus.main.items.map(\.title), ["Canvas", "File", "Edit", "Shape", "Arrange", "View", "Go", "Kitchen", "Window", "Help"])
        expectEqual(try titles(menus, "Help"), ["Keyboard Shortcuts", "", "Guide"], "one placed in the window's own Help, after its line")
        expect(menus.help === menus.main.item(withTitle: "Help")?.submenu && menus.windows === menus.main.item(withTitle: "Window")?.submenu)
        let none = BoardMenus.make(appName: "Canvas", registry: try Registry(plugins: []))
        expectEqual(none.main.items.map(\.title), ["Canvas", "File", "Edit", "Shape", "View", "Window", "Help"], "no Arrange, no Go")
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
        expectEqual(omitted.asked, [["stack", "tidy", "spin", "shine", "seek", "seek-next", "wander", "brew", "guide", "wipe", .undo, .redo,
                                     .zoomIn, .zoomOut, .zoomToActualSize, .zoomToFit]])
    },
])

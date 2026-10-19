import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import ContextMenus
import CoreGraphics
import Keyboard
import Selection
import TestKit

// Items that run a command: titled by it (or by their own title), showing its first key, running it on
// the selection the right-click made, left out while no plugin claims it; and the selection's menu, the
// same items with no click, less the commands a menu bar runs.

extension CanvasCommand {
    static let flash: CanvasCommand = "flash"
    static let dim: CanvasCommand = "dim"
    static let brighten: CanvasCommand = "brighten"
}

/// What the commands and items did.
@MainActor private final class Flashes {
    var runs: [String] = []
    var points: [CGPoint?] = []
}

/// A command `flash` (⇧⌘F, enabled for any selection) and an item for it in a group of its own, named by the
/// command, in every menu of shapes.
@MainActor private func flashing(_ log: Flashes, when: @escaping @MainActor (MenuSubject) -> Bool = { !$0.shapes.isEmpty }) -> Contributor {
    Contributor(id: "flashing") { r in
        r.command(.flash, "Flash Lamps", shortcuts: [KeyChord("f", [.command, .shift]), KeyChord("f", .option)],
                  isEnabled: { !$0.selectedShapeIDs.isEmpty }) { log.runs.append("flash \($0.selectedShapeIDs.count)") }
        r.contextMenuForCanvas {
            MenuItem(command: .flash, in: PowerMenuGroup.self, when: when)
        }
    }
}

@MainActor let commandItemsTests = Suite("Context menu items that run a command", [
    test("an item is titled by its command, shows the command's first key, and runs it on the selection the right-click made") {
        let log = Flashes()
        let h = try harness([flashing(log)])
        let a = h.add(Lamp(slot(0)))
        let b = h.add(Lamp(slot(1)))
        let menu = try require(h.secondaryClick(at: middle(0)))
        expectEqual(menu.outline, ["Turn On", "Brighter", "Level ▸", "  ✓ 1", "  2", "  3", "—", "Flash Lamps", "—", "Delete"])
        let item = try require(menu.item(withTitle: "Flash Lamps"))
        expectEqual(item.keyEquivalent, "f")
        expectEqual(item.keyEquivalentModifierMask, [.command, .shift], "the first of its keys")
        try menu.choose("Flash Lamps")
        expectEqual(log.runs, ["flash 1"], "a right-click on an unselected shape selected it first")
        h.editor.selectedShapeIDs = [a, b]
        try require(h.secondaryClick(at: middle(1))).choose("Flash Lamps")
        expectEqual(log.runs, ["flash 1", "flash 2"], "on a selected shape: the whole selection")
    },
    test("Delete and Select All are such items: their command's title, its first key") {
        let h = try harness()
        h.add(Lamp(slot(0)))
        let delete = try require(try require(h.secondaryClick(at: middle(0))).item(withTitle: "Delete"))
        expectEqual(delete.keyEquivalent, "\u{8}", "Delete, as a menu has Backspace's character")
        expectEqual(delete.keyEquivalentModifierMask, [])
        let selectAll = try require(try require(h.secondaryClick(at: emptyCanvas)).item(withTitle: "Select All"))
        expectEqual(selectAll.keyEquivalent, "a")
        expectEqual(selectAll.keyEquivalentModifierMask, .command)
    },
    test("an item's own title stands in for the command's, and several items run one command, each its own item") {
        let log = Flashes()
        let h = try harness([flashing(log), Contributor(id: "twice") { r in
            r.contextMenuForCanvas {
                MenuItem(command: .flash, title: "Start Flashing", in: PowerMenuGroup.self, when: { $0.shapes.count == 1 })
                MenuItem(command: .flash, title: "Stop Flashing", in: PowerMenuGroup.self, when: { $0.shapes.count == 2 })
            }
        }])
        let a = h.add(Lamp(slot(0)))
        let b = h.add(Lamp(slot(1)))
        let menu = try require(h.secondaryClick(at: middle(0)))
        expectEqual(menu.outline.filter { $0.contains("Flash") }, ["Flash Lamps", "Start Flashing"])
        try menu.choose("Start Flashing")
        h.editor.selectedShapeIDs = [a, b]
        expectEqual(try require(h.secondaryClick(at: middle(0))).outline.filter { $0.contains("Flash") }, ["Flash Lamps", "Stop Flashing"])
        try require(h.secondaryClick(at: middle(0))).choose("Stop Flashing")
        expectEqual(log.runs, ["flash 1", "flash 2"], "both run the command")
        expect(try require(h.secondaryClick(at: middle(0))).item(withTitle: "Stop Flashing")?.keyEquivalent == "f", "and show its key")
    },
    test("`when` leaves the item out; the command's own rule is asked once the menu is made, so a command that can't run does nothing") {
        let log = Flashes()
        let h = try harness([flashing(log, when: { $0.shapes.count > 1 })])
        let a = h.add(Lamp(slot(0)))
        let b = h.add(Lamp(slot(1)))
        expect(!(try require(h.secondaryClick(at: middle(0))).outline.contains("Flash Lamps")), "one shape: hidden by `when`")
        h.editor.selectedShapeIDs = [a, b]
        expect(try require(h.secondaryClick(at: middle(0))).outline.contains("Flash Lamps"))
        let menu = try require(h.secondaryClick(at: middle(0)))
        h.editor.selectedShapeIDs = []
        try menu.choose("Flash Lamps")
        expectEqual(log.runs, [], "the command refuses an empty selection: the menu it was in is stale")
    },
    test("an item whose command no plugin claims is left out, in a submenu too, with its submenu if that holds nothing else") {
        let h = try harness([Contributor(id: "orphans") { r in
            r.contextMenuForCanvas {
                MenuItem(command: "nobody", in: PowerMenuGroup.self)
                Submenu("Nested", in: PowerMenuGroup.self) { MenuItem(command: "nobody-either") }
                MenuItem("Hidden", command: "nobody", in: PowerMenuGroup.self) { _, _ in }
            }
        }])
        h.add(Lamp(slot(0)))
        expectEqual(try require(h.secondaryClick(at: middle(0))).outline,
                    ["Turn On", "Brighter", "Level ▸", "  ✓ 1", "  2", "  3", "—", "Delete"], "none of the three")
    },
    test("an item with an action of its own can stand for a command: its key, its action, not the command") {
        let log = Flashes()
        let h = try harness([flashing(log, when: { _ in false }), Contributor(id: "standing") { r in
            r.contextMenuForCanvas {
                MenuItem("Flash Here", command: .flash, in: PowerMenuGroup.self) { subject in
                    log.runs.append("here")
                    log.points.append(subject.point)
                }
            }
        }])
        h.add(Lamp(slot(0)))
        let menu = try require(h.secondaryClick(at: CGPoint(x: 40, y: 30)))
        expectEqual(menu.item(withTitle: "Flash Here")?.keyEquivalent, "f")
        try menu.choose("Flash Here")
        expectEqual(log.runs, ["here"])
        expectEqual(log.points, [CGPoint(x: 40, y: 30)], "with the point of the click")
    },
])

/// Dim (⌘D, runs on one shape) and Brighten (any) as commands, and their items: Dim, Adjust ▸ Brighten and Twirl (an
/// item of its own), and Where, which is made when the menu opens and notes the point it was asked at.
@MainActor private func dimming(_ log: Flashes) -> Contributor {
    Contributor(id: "dimming") { r in
        r.command(.dim, "Dim", shortcuts: [KeyChord("d", .command)], isEnabled: { $0.selectedShapeIDs.count == 1 }) { _ in log.runs.append("dim") }
        r.command(.brighten, "Brighten", isEnabled: { _ in true }) { _ in log.runs.append("brighten") }
        r.contextMenuForCanvas {
            MenuItem(command: .dim, in: PowerMenuGroup.self)
            Submenu("Adjust", in: PowerMenuGroup.self) {
                MenuItem(command: .brighten, in: PowerMenuGroup.self)
                MenuItem("Twirl", in: PowerMenuGroup.self) { _, _ in log.runs.append("twirl") }
            }
            MenuItems(in: PowerMenuGroup.self, id: "where") { subject in
                let _: Void = log.points.append(subject.point)
                MenuItem("Where", in: PowerMenuGroup.self) { _, _ in }
            }
        }
    }
}

/// A submenu of nothing but a command's item, in a group of its own.
@MainActor private func onlyDim() -> Contributor {
    Contributor(id: "only") { r in
        r.contextMenuForCanvas { Submenu("Only", in: LateMenuGroup.self) { MenuItem(command: .dim, in: LateMenuGroup.self) } }
    }
}

@MainActor let selectionMenuForBarTests = Suite("The selection's menu", [
    test("the same items as a right-click on the selection, made with no click, in the same order and groups") {
        let log = Flashes()
        let h = try harness([dimming(log)])
        let lamp = h.add(Lamp(slot(0)))
        h.editor.selectedShapeIDs = [lamp]
        let clicked = try require(h.secondaryClick(at: middle(0))).outline
        expectEqual(clicked, ["Turn On", "Brighter", "Level ▸", "  ✓ 1", "  2", "  3", "—", "Dim", "Adjust ▸", "  Brighten", "  Twirl", "Where", "—", "Delete"])
        expectEqual(log.points, [middle(0)], "the click's point")
        log.points = []
        let menu = try require(h.editor.menuForSelection(omitting: []))
        expectEqual(menu.outline, clicked)
        expectEqual(log.points, [nil], "no click, no point")
        expect(!menu.autoenablesItems, "its items are enabled as they were made")
        try menu.choose("Adjust", "Twirl")
        expectEqual(log.runs, ["twirl"])
    },
    test("nothing selected, nothing: not even the canvas's items; nor without the plugin") {
        let log = Flashes()
        let h = try harness([dimming(log)])
        let lamp = h.add(Lamp(slot(0)))
        h.editor.selection = nil
        expect(h.editor.menuForSelection(omitting: []) == nil)
        let without = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin()])
        without.editor.selection = without.add(Box(slot(0)))
        expect(without.editor.menuForSelection(omitting: []) == nil, "no plugin claims it")
        expect(h.editor.menuForSelection(omitting: []) == nil)
        h.editor.selection = lamp
        expect(h.editor.menuForSelection(omitting: []) != nil)
    },
    test("an item that runs a command it's told to leave out is left out, and with it the line its group made; a submenu with nothing left goes") {
        let log = Flashes()
        let h = try harness([dimming(log), onlyDim()])
        let lamp = h.add(Lamp(slot(0)))
        h.editor.selectedShapeIDs = [lamp]
        let lampItems = ["Turn On", "Brighter", "Level ▸", "  ✓ 1", "  2", "  3"]
        expectEqual(try require(h.editor.menuForSelection(omitting: [])).outline,
                    lampItems + ["—", "Dim", "Adjust ▸", "  Brighten", "  Twirl", "Where", "—", "Only ▸", "  Dim", "—", "Delete"])
        expectEqual(try require(h.editor.menuForSelection(omitting: [.dim])).outline,
                    lampItems + ["—", "Adjust ▸", "  Brighten", "  Twirl", "Where", "—", "Delete"], "both Dims, and the Only submenu they were all of")
        expectEqual(try require(h.editor.menuForSelection(omitting: [.dim, .brighten, .delete])).outline,
                    lampItems + ["—", "Adjust ▸", "  Twirl", "Where"], "Adjust keeps its own item; Delete's group leaves no line")
    },
    test("an item that runs a command is dimmed as the command is, now the selection is the menu's; a right-click's isn't, which can't know") {
        let log = Flashes()
        let h = try harness([dimming(log)])
        let a = h.add(Lamp(slot(0)))
        let b = h.add(Lamp(slot(1)))
        h.editor.selectedShapeIDs = [a, b]
        expect(try require(h.editor.menuForSelection(omitting: [])).outline.contains("(Dim)"), "two selected: Dim can't run")
        expect(try require(h.secondaryClick(at: middle(0))).outline.contains("Dim"), "a right-click's items are made before the selection is")
        h.editor.selectedShapeIDs = [a]
        let menu = try require(h.editor.menuForSelection(omitting: []))
        expect(menu.outline.contains("Dim"))
        try menu.choose("Dim")
        expectEqual(log.runs, ["dim"])
    },
    test("choosing an item ends editing first, as a right-click does") {
        let h = try harness([CardsPlugin(), Contributor(id: "clear") { r in
            r.contextMenu(Card.self) { MenuItem("Clear") { $0.text = "" } }
        }])
        let card = h.add(Card(slot(0), text: "a"))
        h.editor.selection = card
        h.editor.beginEditing(card)
        let menu = try require(h.editor.menuForSelection(omitting: []))
        expectEqual(h.editor.editingShapeID, card, "opening it leaves the shape being edited")
        try menu.choose("Clear")
        expectEqual(h.editor.editingShapeID, nil)
        expectEqual(h.editor.document[card]?.typed(as: Card.self)?.props.text, "")
    },
    test("the report: the plugin claims the selection's menu beside the secondary click") {
        let report = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), ContextMenusPlugin()]).report
        expect(report.split(separator: "\n").contains { $0.hasSuffix("secondary-click menu · selection menu · CanvasContextMenu") }, report)
    },
])

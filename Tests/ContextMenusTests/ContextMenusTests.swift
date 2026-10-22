import Canvas
import CanvasTesting
import ContextMenus
import CoreGraphics
import Keyboard
import Selection
import TestKit

@MainActor let menuTests = Suite("Context menus", [
    test("a right-click on a shape opens its kind's items, and selects it") {
        let h = try harness()
        let lamp = h.add(Lamp(slot(0)))
        let menu = try require(h.secondaryClick(at: middle(0)))
        expectEqual(menu.outline, ["Turn On", "Brighter", "Level ▸", "  ✓ 1", "  2", "  3", "—", "Delete"], "Delete last, the plugin's own")
        expectEqual(h.editor.selectedShapeIDs, [lamp])
    },
    test("choosing an item edits the live shape, in one transaction; when, isEnabled and isChecked follow its props") {
        let h = try harness()
        let lamp = h.add(Lamp(slot(0), level: 3))
        var menu = try require(h.secondaryClick(at: middle(0)))
        expectEqual(menu.outline, ["Turn On", "(Brighter)", "Level ▸", "  1", "  2", "  ✓ 3", "—", "Delete"])
        let revision = h.editor.revision
        try menu.choose("Turn On")
        expectEqual(h.editor.lamp(lamp)?.isOn, true)
        expectEqual(h.editor.revision, revision + 1)
        menu = try require(h.secondaryClick(at: middle(0)))
        expectEqual(menu.outline.first, "Turn Off")
        try menu.choose("Level", "2")
        expectEqual(h.editor.lamp(lamp)?.level, 2)
        try menu.choose("Level", "2")                // the level it has: nothing to commit
        expectEqual(h.editor.revision, revision + 2)
    },
    test("a shape with no items of its own has Delete alone; empty canvas, Select All while the board has shapes; where nothing applies, a right-click does nothing") {
        let h = try harness()
        expect(h.secondaryClick(at: emptyCanvas) == nil, "an empty board: nothing to select")
        let lamp = h.add(Lamp(slot(0)))
        let box = h.add(Box(slot(1)))
        h.editor.selection = lamp
        let revision = h.editor.revision
        expectEqual(try require(h.secondaryClick(at: emptyCanvas)).outline, ["Select All"])
        expectEqual(h.editor.selectedShapeIDs, [lamp], "a menu on empty canvas leaves the selection")
        try require(h.secondaryClick(at: emptyCanvas)).choose("Select All")
        expectEqual(h.editor.selectedShapeIDs, [lamp, box])
        h.editor.selection = lamp
        let menu = try require(h.secondaryClick(at: middle(1)))
        expectEqual(menu.outline, ["Delete"])
        expectEqual(h.editor.selectedShapeIDs, [box])
        expectEqual(h.editor.revision, revision, "nothing chosen, nothing changed")
        try menu.choose("Delete")
        expectEqual(h.editor.document.shapes.map(\.id), [lamp], "the box, as the Delete key deletes it")
        expectEqual(h.editor.undoHistory.undoName, "Delete")
    },
    test("a submenu's own when leaves it out, items and all") {
        let h = try harness([Contributor(id: "wide") { r in
            r.contextMenu(Box.self) {
                Submenu("Wide", when: { $0.frame.width > 150 }) { MenuItem("Stretch") { _ in } }
                MenuItem("Always") { _ in }
            }
        }])
        h.add(Box(slot(0)))
        h.add(Box(CGRect(x: 0, y: 200, width: 300, height: 100)))
        expectEqual(try require(h.secondaryClick(at: middle(0))).outline, ["Always", "—", "Delete"])
        expectEqual(try require(h.secondaryClick(at: CGPoint(x: 150, y: 250))).outline, ["Wide ▸", "  Stretch", "Always", "—", "Delete"])
    },
    test("every item hidden, or a submenu whose items all are, is left out; with nothing left, there's no menu") {
        let h = try harness([Contributor(id: "never") { r in
            r.contextMenu(Box.self) {
                MenuItem("Never", when: { _ in false }) { _ in }
                Submenu("Empty") { MenuItem("Never Either", when: { _ in false }) { _ in } }
            }
            r.contextMenuForCanvas {
                MenuItem("Never Here", when: { _ in false }) { _, _ in }
                Submenu("Empty Here") { MenuItem("Never Here Either", when: { _ in false }) { _, _ in } }
            }
        }])
        expect(h.secondaryClick(at: middle(0)) == nil, "an empty board, its items all hidden")
        h.add(Box(slot(0)))
        expectEqual(try require(h.secondaryClick(at: middle(0))).outline, ["Delete"])
    },
    test("items for the canvas: after a shape's own in their group's order, alone on empty canvas, each asked once with the menu's shapes") {
        let log = PerformLog()
        let h = try harness([Contributor(id: "canvas") { r in
            r.contextMenuForCanvas {
                MenuItem("Shapes", in: LateMenuGroup.self, when: { subject in
                    log.runs.append("asked \(subject.shapes.count)")
                    return !subject.shapes.isEmpty
                }) { ids, _ in log.runs.append("ran \(ids.count)") }
                MenuItem("Anywhere", in: PowerMenuGroup.self, isEnabled: { $0.editor.selectedShapeIDs.count < 3 }) { _, _ in }
            }
        }])
        let a = h.add(Lamp(slot(0)))
        let b = h.add(Lamp(slot(1)))
        h.editor.selectedShapeIDs = [a, b]
        let menu = try require(h.secondaryClick(at: middle(0)))
        expectEqual(menu.outline, ["Turn On", "Brighter", "Level ▸", "  ✓ 1", "  2", "  3", "—", "Anywhere", "—", "Shapes", "—", "Delete"])
        expectEqual(log.runs, ["asked 2"], "once for the menu, not once per shape")
        try menu.choose("Shapes")
        expectEqual(log.runs, ["asked 2", "ran 2"])
        expectEqual(try require(h.secondaryClick(at: CGPoint(x: 150, y: 400))).outline, ["Anywhere", "—", "Select All"])
        expectEqual(h.editor.selectedShapeIDs, [a, b], "a menu on empty canvas leaves the selection")
    },
    test("a kind's own item with a canvas item's group and id takes its place, shown or not; two plugins adding one canvas item conflict") {
        let h = try harness([Contributor(id: "canvas") { r in
            r.contextMenuForCanvas { MenuItem("Turn On", in: ShapeMenuGroup.self) { _, _ in } }
        }])
        let lamp = h.add(Lamp(slot(0)))
        h.add(Box(slot(1)))
        expectEqual(try require(h.secondaryClick(at: middle(0))).outline.filter { $0 == "Turn On" }.count, 1)
        h.editor.transact { $0.update(lamp, as: Lamp.self) { $0.props.isOn = true } }
        expectEqual(try require(h.secondaryClick(at: middle(0))).outline.first, "Turn Off")
        expect(try require(h.secondaryClick(at: middle(0))).outline.contains("Turn On") == false, "the lamp's own, hidden, still takes its place")
        expectEqual(try require(h.secondaryClick(at: middle(1))).outline, ["Turn On", "—", "Delete"])
        expectThrows(RegistryError.conflict(point: "CanvasContextMenu", key: "* Paste", plugins: ["one", "two"])) {
            _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), ContextMenusPlugin(),
                                       Contributor(id: "one") { $0.contextMenuForCanvas { MenuItem("Paste") { _, _ in } } },
                                       Contributor(id: "two") { $0.contextMenuForCanvas { MenuItem("Paste") { _, _ in } } }])
        }
    },
    test("without the plugin nothing claims the click; contributing needs it installed") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin()])
        h.add(Box(slot(0)))
        expect(h.secondaryClick(at: middle(0)) == nil)
        expectThrows(RegistryError.ownerNotInstalled(point: "ShapeContextMenus", owner: .contextMenus, contributor: "appliances")) {
            _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), AppliancesPlugin()])
        }
    },
    test("unselectable shapes are seen through: the click lands on what's beneath") {
        let h = try harness([Contributor(id: "glass") { r in
            r.contribute({ _ in false }, to: ShapeSelectability.self, for: .kind(Disc.kind))
            r.contextMenu(Disc.self) { MenuItem("Polish") { _ in } }
        }])
        let lamp = h.add(Lamp(slot(0)))
        h.add(Disc(slot(0).offsetBy(dx: 50, dy: 0)))
        expectEqual(try require(h.secondaryClick(at: CGPoint(x: 75, y: 50))).outline.first, "Turn On")
        expectEqual(h.editor.selectedShapeIDs, [lamp])
        expectEqual(try require(h.secondaryClick(at: CGPoint(x: 125, y: 50))).outline, ["Select All"], "the canvas's: nothing of the disc's")
    },
    test("a right-click ends editing when it opens a menu, and only then") {
        let h = try harness([CardsPlugin(), Contributor(id: "clear") { r in
            r.contextMenu(Card.self) { MenuItem("Clear") { $0.text = "" } }
        }])
        let editing = h.add(Card(slot(0), text: "a"))
        let other = h.add(Card(slot(1), text: "b"))
        // Every shape has a menu now (Delete), so no menu is a Control-click in another tool.
        h.editor.setTool(.hand)
        h.editor.selection = editing
        h.editor.beginEditing(editing)
        h.hold(.control)
        expect(h.secondaryClick(at: middle(1)) == nil, "a Control-click in the hand tool: no menu")
        h.hold([])
        expectEqual(h.editor.editingShapeID, editing)
        try require(h.secondaryClick(at: middle(1))).choose("Clear")
        expectEqual(h.editor.editingShapeID, nil)
        expectEqual(h.editor.selectedShapeIDs, [other])
        expectEqual(h.editor.document[other]?.typed(as: Card.self)?.props.text, "")
    },
    test("a right-click opens the menu in any tool; a Control-click only in select, since other tools read ⌃") {
        let h = try harness()
        h.add(Lamp(slot(0)))
        h.hold(.control)
        expect(h.secondaryClick(at: middle(0)) != nil, "select: a Control-click is the secondary click")
        h.editor.setTool(.hand)
        expect(h.secondaryClick() == nil, "hand: it's a press with ⌃")
        h.hold([])
        expect(h.secondaryClick() != nil, "hand: a right-click still opens the menu")
    },
    test("nothing opens while a press is under way") {
        let h = try harness()
        h.add(Lamp(slot(0)))
        h.press(at: middle(0))
        expect(h.editor.session != nil)
        expect(h.secondaryClick() == nil)
        h.release()
        expect(h.secondaryClick() != nil)
    },
])

@MainActor let selectionMenuTests = Suite("Context menus for the selection", [
    test("on a selected shape, the menu is for the whole selection: an item shows if every shape offers it") {
        let h = try harness()
        let a = h.add(Lamp(slot(0)))
        let b = h.add(Lamp(slot(1), isOn: true, level: 2))
        h.editor.selectedShapeIDs = [a, b]
        let menu = try require(h.secondaryClick(at: middle(0)))
        expectEqual(h.editor.selectedShapeIDs, [a, b])
        // Turn On is a's, Turn Off b's: neither is both's. The levels differ: each is mixed.
        expectEqual(menu.outline, ["Brighter", "Level ▸", "  – 1", "  – 2", "  3", "—", "Delete"])
        let revision = h.editor.revision
        try menu.choose("Level", "3")
        expectEqual([h.editor.lamp(a)?.level, h.editor.lamp(b)?.level], [3, 3])
        expectEqual(h.editor.revision, revision + 1)
    },
    test("an item is enabled if it is for any of the shapes, and runs on those") {
        let h = try harness()
        let a = h.add(Lamp(slot(0), level: 3))
        let b = h.add(Lamp(slot(1)))
        h.editor.selectedShapeIDs = [a, b]
        let menu = try require(h.secondaryClick(at: middle(1)))
        expectEqual(Array(menu.outline.prefix(2)), ["Turn On", "Brighter"])
        try menu.choose("Brighter")
        expectEqual([h.editor.lamp(a)?.level, h.editor.lamp(b)?.level], [3, 2])
    },
    test("the same item on two kinds is one item, and each kind's own edit runs") {
        let h = try harness()
        let lamp = h.add(Lamp(slot(0)))
        let fan = h.add(Fan(frame: slot(1)))
        h.editor.selectedShapeIDs = [lamp, fan]
        let menu = try require(h.secondaryClick(at: middle(1)))
        expectEqual(menu.outline, ["Turn On", "—", "Delete"])
        let revision = h.editor.revision
        try menu.choose("Turn On")
        expectEqual(h.editor.lamp(lamp)?.isOn, true)
        expectEqual(h.editor.fan(fan)?.isOn, true)
        expectEqual(h.editor.revision, revision + 1)
    },
    test("with nothing of their own every selected shape offers, the menu is Delete alone, for them all, and the selection stays") {
        let h = try harness()
        let lamp = h.add(Lamp(slot(0)))
        let box = h.add(Box(slot(1)))
        let other = h.add(Box(slot(2)))
        h.editor.selectedShapeIDs = [lamp, box]
        let menu = try require(h.secondaryClick(at: middle(0)))
        expectEqual(menu.outline, ["Delete"])
        expectEqual(h.editor.selectedShapeIDs, [lamp, box])
        try menu.choose("Delete")
        expectEqual(h.editor.document.shapes.map(\.id), [other])
    },
    test("on empty space inside a multi-selection's box, the menu is for the selection; outside it, there's none") {
        let h = try harness()
        let a = h.add(Lamp(slot(0)))
        let b = h.add(Lamp(slot(1)))
        h.editor.selectedShapeIDs = [a, b]
        let menu = try require(h.secondaryClick(at: emptyCanvas))
        expectEqual(menu.outline.first, "Turn On")
        expectEqual(h.editor.selectedShapeIDs, [a, b])
        try menu.choose("Turn On")
        expectEqual([h.editor.lamp(a)?.isOn, h.editor.lamp(b)?.isOn], [true, true])
        expectEqual(try require(h.secondaryClick(at: CGPoint(x: 150, y: 300))).outline, ["Select All"], "outside it, the canvas's")
        expectEqual(h.editor.selectedShapeIDs, [a, b])
    },
    test("an item one kind checks and another doesn't is mixed, not checked, for both") {
        let h = try harness([Contributor(id: "glow") { r in
            r.contextMenu(Lamp.self) { MenuItem("Glow", isChecked: { $0.isOn }) { $0.isOn = true } }
            r.contextMenu(Fan.self) { MenuItem("Glow") { _ in } }
        }])
        let lamp = h.add(Lamp(slot(0), isOn: true))
        let fan = h.add(Fan(frame: slot(1)))
        expect(try require(h.secondaryClick(at: middle(0))).outline.contains("✓ Glow"))
        h.editor.selectedShapeIDs = [lamp, fan]
        expect(try require(h.secondaryClick(at: middle(0))).outline.contains("– Glow"))
    },
    test("a right-click on a shape outside the selection selects just it") {
        let h = try harness()
        let a = h.add(Lamp(slot(0)))
        let b = h.add(Lamp(slot(1)))
        let fan = h.add(Fan(frame: slot(2)))
        h.editor.selectedShapeIDs = [a, b]
        expectEqual(try require(h.secondaryClick(at: middle(2))).outline, ["Turn On", "—", "Delete"])
        expectEqual(h.editor.selectedShapeIDs, [fan])
    },
])

@MainActor let contributionTests = Suite("Context menu contributions", [
    test("groups sort by order, then first appearance, with a separator between; a scope's items follow a kind's own") {
        let h = try harness([
            Contributor(id: "power") { r in r.contextMenu(Lamp.self) { MenuItem("Timer", in: PowerMenuGroup.self) { _ in } } },
            Contributor(id: "every") { r in
                r.forEveryShape {
                    $0.contextMenu {
                        MenuItem("Late", in: LateMenuGroup.self) { _ in }
                        MenuItem("Inspect") { _ in }
                    }
                }
            },
        ])
        h.add(Lamp(slot(0), isOn: true))
        h.add(Box(slot(1)))
        expectEqual(try require(h.secondaryClick(at: middle(0))).outline,
                    ["Turn Off", "Brighter", "Level ▸", "  ✓ 1", "  2", "  3", "Inspect", "—", "Timer", "—", "Late", "—", "Delete"])
        expectEqual(try require(h.secondaryClick(at: middle(1))).outline, ["Inspect", "—", "Late", "—", "Delete"])
    },
    test("a scope's items go on the kinds it reaches: by capability, or by an added property") {
        let h = try harness([Contributor(id: "lamps-only") { r in
            r.forShapes(adopting: LampDefinition.self) { $0.contextMenu { MenuItem("Dim") { _ in } } }
        }])
        h.add(Lamp(slot(0)))
        h.add(Box(slot(1)))
        expect(try require(h.secondaryClick(at: middle(0))).outline.contains("Dim"))
        expectEqual(try require(h.secondaryClick(at: middle(1))).outline, ["Delete"], "no Dim on a box")
    },
    test("a perform gets the shapes it's for, in selection order, once per contribution; a kind's own item replaces a scope's") {
        let log = PerformLog()
        let h = try harness([
            Contributor(id: "count") { r in
                r.forEveryShape {
                    $0.contextMenu {
                        MenuItem("Count") { ids, editor in log.runs.append("every \(ids.count) at \(editor.revision)") }
                    }
                }
                r.contextMenu(Lamp.self) {
                    MenuItem("Count") { ids, _ in log.runs.append("lamp \(ids.count)") }
                }
            },
        ])
        let box = h.add(Box(slot(0)))
        let lamp = h.add(Lamp(slot(1)))
        let disc = h.add(Disc(slot(2)))
        h.editor.selectedShapeIDs = [box, lamp, disc]
        let revision = h.editor.revision
        try require(h.secondaryClick(at: middle(1))).choose("Count")
        expectEqual(log.runs, ["every 2 at \(revision)", "lamp 1"])
    },
    test("two plugins can't add one item to a kind, nor in one scope, nor in two scopes that reach one kind; a builder can't repeat one in a submenu") {
        expectThrows(RegistryError.conflict(point: "ShapeContextMenus", key: "lamp Turn On", plugins: ["appliances", "more"])) {
            _ = try harness([Contributor(id: "more") { r in r.contextMenu(Lamp.self) { MenuItem("Turn On") { _ in } } }])
        }
        expectThrows(RegistryError.conflict(point: "ShapeContextMenus", key: "every shape Inspect", plugins: ["a", "b"])) {
            _ = try harness([Contributor(id: "a") { $0.forEveryShape { $0.contextMenu { MenuItem("Inspect") { _ in } } } },
                             Contributor(id: "b") { $0.forEveryShape { $0.contextMenu { MenuItem("Inspect") { _ in } } } }])
        }
        expectThrows(RegistryError.conflict(point: "ShapeContextMenus", key: "lamp Inspect", plugins: ["a", "b"])) {
            _ = try harness([Contributor(id: "a") { $0.forEveryShape { $0.contextMenu { MenuItem("Inspect") { _ in } } } },
                             Contributor(id: "b") { $0.forShapes(adopting: LampDefinition.self) { $0.contextMenu { MenuItem("Inspect") { _ in } } } }])
        }
        expectThrows(RegistryError.conflict(point: "ShapeContextMenus", key: "box Sort ▸ By Name", plugins: ["dup", "dup"])) {
            _ = try harness([Contributor(id: "dup") { r in
                r.contextMenu(Box.self) { Submenu("Sort") { MenuItem("By Name") { _ in }; MenuItem("By Name") { _ in } } }
            }])
        }
        // Another group's item of that name is another item, and a scope's may share a kind's.
        _ = try harness([Contributor(id: "more") { r in
            r.contextMenu(Lamp.self) { MenuItem("Turn On", in: PowerMenuGroup.self) { _ in } }
            r.forEveryShape { $0.contextMenu { MenuItem("Turn On") { _ in } } }
        }])
    },
    test("a scope's items for the canvas are in a menu whose every shape it reaches, in plugin order among the rest; never on empty canvas") {
        let log = PerformLog()
        let h = try harness([
            Contributor(id: "first") { r in r.contextMenuForCanvas { MenuItem("First", in: PowerMenuGroup.self, when: { !$0.shapes.isEmpty }) { _, _ in } } },
            Contributor(id: "lit") { r in
                r.forShapes(adopting: LampDefinition.self) {
                    $0.contextMenuForCanvas {
                        MenuItem("Dim All", in: PowerMenuGroup.self) { ids, _ in log.runs.append("dim \(ids.count)") }
                    }
                }
            },
            Contributor(id: "last") { r in r.contextMenuForCanvas { MenuItem("Last", in: PowerMenuGroup.self, when: { !$0.shapes.isEmpty }) { _, _ in } } },
        ])
        let a = h.add(Lamp(slot(0)))
        let b = h.add(Lamp(slot(1)))
        let box = h.add(Box(slot(2)))
        let lamp = try require(h.secondaryClick(at: middle(0)))
        expectEqual(lamp.outline.filter { ["First", "Dim All", "Last"].contains($0) }, ["First", "Dim All", "Last"])
        h.editor.selectedShapeIDs = [a, b]
        let lamps = try require(h.secondaryClick(at: middle(1)))
        expectEqual(lamps.outline.filter { ["First", "Dim All", "Last"].contains($0) }, ["First", "Dim All", "Last"])
        try lamps.choose("Dim All")
        expectEqual(log.runs, ["dim 2"], "once, with the menu's shapes")
        h.editor.selectedShapeIDs = [a, box]
        expectEqual(try require(h.secondaryClick(at: middle(2))).outline, ["First", "Last", "—", "Delete"], "a box it doesn't reach")
        h.editor.selectedShapeIDs = []
        expectEqual(try require(h.secondaryClick(at: middle(2))).outline, ["First", "Last", "—", "Delete"])
        expectEqual(try require(h.secondaryClick(at: emptyCanvas)).outline, ["Select All"], "no shapes, so no scope's")
    },
    test("a scope's item for the canvas claims its group and id on each kind it reaches, as every menu's does") {
        expectThrows(RegistryError.conflict(point: "CanvasContextMenu", key: "lamp Dim All", plugins: ["every", "lit"])) {
            _ = try harness([Contributor(id: "every") { r in r.contextMenuForCanvas { MenuItem("Dim All") { _, _ in } } },
                             Contributor(id: "lit") { r in r.forShapes(adopting: LampDefinition.self) { $0.contextMenuForCanvas { MenuItem("Dim All") { _, _ in } } } }])
        }
        let report = try harness([Contributor(id: "lit") { r in
            r.forShapes(adopting: LampDefinition.self) { $0.contextMenuForCanvas { MenuItem("Dim All") { _, _ in } } }
        }]).editor.registry.report
        expectEqual(report.split(separator: "\n").first { $0.hasPrefix("lit") }.map(String.init), "lit            CanvasContextMenu in ShapeMenuGroup first → every shape adopting LampDefinition")
    },
    test("the report: the plugin claims the secondary click, and each kind's items are one line, naming their groups with their orders") {
        let report = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), ContextMenusPlugin(), AppliancesPlugin()]).report
        expectEqual(report.split(separator: "\n").filter { $0.hasPrefix("context-menus") || $0.hasPrefix("appliances") }, [
            "context-menus  service ContextMenuState · secondary-click menu · selection menu · command showContextMenu · shortcut ⌃↩ → command showContextMenu · shortcut Menu → command showContextMenu · CanvasContextMenu in SelectionMenuGroup last",
            "appliances     shape lamp · ShapeContextMenus in ShapeMenuGroup first → lamp · shape fan · ShapeContextMenus in ShapeMenuGroup first → fan",
        ])
    },
    test("an item in ActionsMenuGroup, which only places other groups, is refused") {
        expectThrows(RegistryError.invalid(point: "CanvasContextMenu", reason: "Act is in ActionsMenuGroup, which holds no item: it's a place to be put beside, after every group right after a kind's own")) {
            _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), ContextMenusPlugin(), Contributor(id: "act") { r in
                r.contextMenuForCanvas { MenuItem("Act", in: ActionsMenuGroup.self) { _, _ in } }
            }])
        }
    },
    test("menu groups placed beside each other in a circle are refused") {
        expectThrows(RegistryError.invalid(point: "CanvasContextMenu", reason: "menu groups placed beside each other in a circle: PingMenuGroup before PongMenuGroup, PongMenuGroup before PingMenuGroup")) {
            _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), ContextMenusPlugin(), Contributor(id: "loop") { r in
                r.contextMenuForCanvas {
                    MenuItem("Ping", in: PingMenuGroup.self) { _, _ in }
                    MenuItem("Pong", in: PongMenuGroup.self) { _, _ in }
                }
            }])
        }
    },
])

/// Two groups each placed right before the other: no order would do.
enum PingMenuGroup {}
extension PingMenuGroup: MenuGroup {
    static var order: Order<Self> { .before(PongMenuGroup.self) }
}

enum PongMenuGroup {}
extension PongMenuGroup: MenuGroup {
    static var order: Order<Self> { .before(PingMenuGroup.self) }
}

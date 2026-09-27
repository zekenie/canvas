import Canvas
import CanvasTesting
import ContextMenus
import CoreGraphics
import Selection
import TestKit

@MainActor let menuTests = Suite("Context menus", [
    test("a right-click on a shape opens its kind's items, and selects it") {
        let h = try harness()
        let lamp = h.add(Lamp(slot(0)))
        let menu = try require(h.secondaryClick(at: middle(0)))
        expectEqual(menu.outline, ["Turn On", "Brighter", "Level ▸", "  ✓ 1", "  2", "  3"])
        expectEqual(h.editor.selectedShapeIDs, [lamp])
    },
    test("choosing an item edits the live shape, in one transaction; when, isEnabled and isChecked follow its props") {
        let h = try harness()
        let lamp = h.add(Lamp(slot(0), level: 3))
        var menu = try require(h.secondaryClick(at: middle(0)))
        expectEqual(menu.outline, ["Turn On", "(Brighter)", "Level ▸", "  1", "  2", "  ✓ 3"])
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
    test("a right-click where nothing applies does nothing: a shape with no items, empty canvas") {
        let h = try harness()
        let lamp = h.add(Lamp(slot(0)))
        h.add(Box(slot(1)))
        h.editor.selection = lamp
        let revision = h.editor.revision
        expect(h.secondaryClick(at: middle(1)) == nil)
        expect(h.secondaryClick(at: emptyCanvas) == nil)
        expectEqual(h.editor.selectedShapeIDs, [lamp])
        expectEqual(h.editor.revision, revision)
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
        expectEqual(try require(h.secondaryClick(at: middle(0))).outline, ["Always"])
        expectEqual(try require(h.secondaryClick(at: CGPoint(x: 150, y: 250))).outline, ["Wide ▸", "  Stretch", "Always"])
    },
    test("every item hidden, or a submenu whose items all are, and there's no menu") {
        let h = try harness([Contributor(id: "never") { r in
            r.contextMenu(Box.self) {
                MenuItem("Never", when: { _ in false }) { _ in }
                Submenu("Empty") { MenuItem("Never Either", when: { _ in false }) { _ in } }
            }
        }])
        h.add(Box(slot(0)))
        expect(h.secondaryClick(at: middle(0)) == nil)
        expectEqual(h.editor.selectedShapeIDs, [])
    },
    test("without the plugin nothing claims the click; contributing needs it installed") {
        let h = try EditorHarness(plugins: [SelectionPlugin(), FixturesPlugin()])
        h.add(Box(slot(0)))
        expect(h.secondaryClick(at: middle(0)) == nil)
        expectThrows(RegistryError.ownerNotInstalled(point: "ShapeContextMenus", owner: .contextMenus, contributor: "appliances")) {
            _ = try Registry(plugins: [SelectionPlugin(), AppliancesPlugin()])
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
        expect(h.secondaryClick(at: CGPoint(x: 125, y: 50)) == nil)
    },
    test("a right-click ends editing when it opens a menu, and only then") {
        let h = try harness([CardsPlugin(), Contributor(id: "clear") { r in
            r.contextMenu(Card.self) { MenuItem("Clear") { $0.text = "" } }
        }])
        let editing = h.add(Card(slot(0), text: "a"))
        let other = h.add(Card(slot(1), text: "b"))
        h.add(Box(slot(2)))
        h.editor.selection = editing
        h.editor.beginEditing(editing)
        expect(h.secondaryClick(at: middle(2)) == nil)
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
        expectEqual(menu.outline, ["Brighter", "Level ▸", "  – 1", "  – 2", "  3"])
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
        expectEqual(menu.outline, ["Turn On"])
        let revision = h.editor.revision
        try menu.choose("Turn On")
        expectEqual(h.editor.lamp(lamp)?.isOn, true)
        expectEqual(h.editor.fan(fan)?.isOn, true)
        expectEqual(h.editor.revision, revision + 1)
    },
    test("with nothing every selected shape offers, there's no menu, and the selection stays") {
        let h = try harness()
        let lamp = h.add(Lamp(slot(0)))
        let box = h.add(Box(slot(1)))
        h.editor.selectedShapeIDs = [lamp, box]
        expect(h.secondaryClick(at: middle(0)) == nil)
        expectEqual(h.editor.selectedShapeIDs, [lamp, box])
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
        expect(h.secondaryClick(at: CGPoint(x: 150, y: 300)) == nil)
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
        expectEqual(try require(h.secondaryClick(at: middle(2))).outline, ["Turn On"])
        expectEqual(h.editor.selectedShapeIDs, [fan])
    },
])

@MainActor let contributionTests = Suite("Context menu contributions", [
    test("groups sort by order, then first appearance, with a separator between; every shape's items follow a kind's own") {
        let h = try harness([
            Contributor(id: "power") { r in r.contextMenu(Lamp.self) { MenuItem("Timer", in: PowerMenuGroup.self) { _ in } } },
            Contributor(id: "every") { r in
                r.contextMenuForEveryShape {
                    MenuItem("Late", in: LateMenuGroup.self) { _ in }
                    MenuItem("Inspect") { _ in }
                }
            },
        ])
        h.add(Lamp(slot(0), isOn: true))
        h.add(Box(slot(1)))
        expectEqual(try require(h.secondaryClick(at: middle(0))).outline,
                    ["Turn Off", "Brighter", "Level ▸", "  ✓ 1", "  2", "  3", "Inspect", "—", "Timer", "—", "Late"])
        expectEqual(try require(h.secondaryClick(at: middle(1))).outline, ["Inspect", "—", "Late"])
    },
    test("a perform gets the shapes it's for, in selection order, once per contribution; a kind's own item replaces every shape's") {
        let log = PerformLog()
        let h = try harness([
            Contributor(id: "count") { r in
                r.contextMenuForEveryShape {
                    MenuItem("Count") { ids, editor in log.runs.append("every \(ids.count) at \(editor.revision)") }
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
    test("two plugins can't add one item to a kind, nor one to every shape; a builder can't repeat one in a submenu") {
        expectThrows(RegistryError.conflict(point: "ShapeContextMenus", key: "lamp Turn On", plugins: ["appliances", "more"])) {
            _ = try harness([Contributor(id: "more") { r in r.contextMenu(Lamp.self) { MenuItem("Turn On") { _ in } } }])
        }
        expectThrows(RegistryError.conflict(point: "ShapeContextMenus", key: "* Inspect", plugins: ["a", "b"])) {
            _ = try harness([Contributor(id: "a") { $0.contextMenuForEveryShape { MenuItem("Inspect") { _ in } } },
                             Contributor(id: "b") { $0.contextMenuForEveryShape { MenuItem("Inspect") { _ in } } }])
        }
        expectThrows(RegistryError.conflict(point: "ShapeContextMenus", key: "box Sort ▸ By Name", plugins: ["dup", "dup"])) {
            _ = try harness([Contributor(id: "dup") { r in
                r.contextMenu(Box.self) { Submenu("Sort") { MenuItem("By Name") { _ in }; MenuItem("By Name") { _ in } } }
            }])
        }
        // Another group's item of that name is another item, and every shape's may share a kind's.
        _ = try harness([Contributor(id: "more") { r in
            r.contextMenu(Lamp.self) { MenuItem("Turn On", in: PowerMenuGroup.self) { _ in } }
            r.contextMenuForEveryShape { MenuItem("Turn On") { _ in } }
        }])
    },
    test("the report: the plugin claims the secondary click, and each kind's items are one line") {
        let report = try Registry(plugins: [SelectionPlugin(), ContextMenusPlugin(), AppliancesPlugin()]).report
        expectEqual(report.split(separator: "\n").filter { $0.hasPrefix("context-menus") || $0.hasPrefix("appliances") }, [
            "context-menus  service ContextMenuState · secondary-click menu",
            "appliances     shape lamp · ShapeContextMenus → lamp · shape fan · ShapeContextMenus → fan",
        ])
    },
])

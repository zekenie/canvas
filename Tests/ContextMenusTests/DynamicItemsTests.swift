import Canvas
import CanvasTesting
import ContextMenus
import CoreGraphics
import Keyboard
import Selection
import TestKit

// Items for the canvas made when the menu opens (`MenuItems`): from what the file holds at that moment,
// asked once per menu, put in place of the entry that claimed them, the first of each id staying.

/// What the generating entries were asked, and the names they generate: a test changes `names` between menus.
@MainActor private final class Generator {
    var names: [String]
    var asked: [(shapes: Int, point: CGPoint?)] = []
    var ran: [String] = []

    init(_ names: [String]) { self.names = names }
}

@MainActor private func generating(_ generator: Generator, in group: any MenuGroup.Type = PowerMenuGroup.self, id: String = "generated") -> Contributor {
    Contributor(id: PluginID(id)) { r in
        r.contextMenuForCanvas {
            MenuItems(in: group, id: id) { subject in
                let _: Void = generator.asked.append((subject.shapes.count, subject.point))   // a declaration, since a builder takes no statements
                for name in generator.names {
                    MenuItem(name, in: group) { ids, _ in generator.ran.append("\(name) \(ids.count)") }
                }
            }
        }
    }
}

@MainActor let dynamicItemsTests = Suite("Items made when the menu opens", [
    test("the entry is asked once per menu, with its subject, and what it makes is the menu's, in its group's place after the shapes' own") {
        let generator = Generator(["Alpha", "Beta"])
        let h = try harness([generating(generator)])
        let a = h.add(Lamp(slot(0)))
        let b = h.add(Lamp(slot(1)))
        h.editor.selectedShapeIDs = [a, b]
        let menu = try require(h.secondaryClick(at: middle(0)))
        expectEqual(menu.outline, ["Turn On", "Brighter", "Level ▸", "  ✓ 1", "  2", "  3", "—", "Alpha", "Beta", "—", "Delete"])
        expectEqual(generator.asked.count, 1, "once for the menu, not once for each shape or item")
        expectEqual(generator.asked.first?.shapes, 2)
        expectEqual(generator.asked.first?.point, middle(0), "where it was asked for")
        try menu.choose("Beta")
        expectEqual(generator.ran, ["Beta 2"], "with the menu's shapes")
    },

    test("it is made each time a menu opens, from what the file holds then") {
        let generator = Generator(["Alpha"])
        let h = try harness([generating(generator)])
        h.add(Fan(frame: slot(0)))
        expectEqual(try require(h.secondaryClick(at: middle(0))).outline, ["Turn On", "—", "Alpha", "—", "Delete"])
        generator.names = ["Gamma", "Delta"]
        expectEqual(try require(h.secondaryClick(at: middle(0))).outline, ["Turn On", "—", "Gamma", "Delta", "—", "Delete"])
        generator.names = []
        expectEqual(try require(h.secondaryClick(at: middle(0))).outline, ["Turn On", "—", "Delete"], "nothing made shows nothing, no separator")
        expectEqual(generator.asked.count, 3)
    },

    test("on empty canvas it is the menu, or none when it makes nothing") {
        let generator = Generator(["Alpha"])
        let h = try harness([generating(generator)])
        expectEqual(try require(h.secondaryClick(at: emptyCanvas)).outline, ["Alpha"])
        expectEqual(generator.asked.first?.shapes, 0)
        generator.names = []
        expect(h.secondaryClick(at: emptyCanvas) == nil, "an empty board and nothing made")
    },

    test("an id made twice is shown once, the first staying, in a submenu too; an id a later entry made that an earlier one has is left out") {
        let generator = Generator(["Alpha", "Beta", "Alpha"])
        let h = try harness([generating(generator), Contributor(id: "second") { r in
            r.contextMenuForCanvas {
                MenuItems(in: PowerMenuGroup.self, id: "more") { _ in
                    MenuItem("Beta", in: PowerMenuGroup.self) { _, _ in }
                    Submenu("Nested", in: PowerMenuGroup.self) {
                        MenuItem("One", in: PowerMenuGroup.self) { _, _ in }
                        MenuItem("One", in: PowerMenuGroup.self) { _, _ in }
                        MenuItem("Two", in: PowerMenuGroup.self) { _, _ in }
                    }
                }
            }
        }])
        expectEqual(try require(h.secondaryClick(at: emptyCanvas)).outline, ["Alpha", "Beta", "Nested ▸", "  One", "  Two"])
    },

    test("a submenu it makes with nothing in it is left out; the entries it makes take `when` and isEnabled as any item for the canvas does") {
        let h = try harness([Contributor(id: "made") { r in
            r.contextMenuForCanvas {
                MenuItems(in: PowerMenuGroup.self, id: "made") { subject in
                    Submenu("Empty", in: PowerMenuGroup.self) { MenuItem("Never", when: { _ in false }) { _, _ in } }
                    MenuItem("Only With Shapes", in: PowerMenuGroup.self, when: { !$0.shapes.isEmpty }) { _, _ in }
                    MenuItem("Dimmed", in: PowerMenuGroup.self, isEnabled: { _ in false }) { _, _ in }
                }
            }
        }])
        expectEqual(try require(h.secondaryClick(at: emptyCanvas)).outline, ["(Dimmed)"])
        h.add(Fan(frame: slot(0)))
        expectEqual(try require(h.secondaryClick(at: middle(0))).outline, ["Turn On", "—", "Only With Shapes", "(Dimmed)", "—", "Delete"])
    },

    test("a kind's own item with the group and id of one made takes its place, as for any item for the canvas") {
        let generator = Generator(["Turn On", "Alpha"])
        let h = try harness([generating(generator, in: ShapeMenuGroup.self)])
        h.add(Fan(frame: slot(0)))
        expectEqual(try require(h.secondaryClick(at: middle(0))).outline, ["Turn On", "Alpha", "—", "Delete"], "the fan's, not a second")
        try require(h.secondaryClick(at: middle(0))).choose("Turn On")
        expectEqual(generator.ran, [], "the fan's ran")
    },

    test("choosing a made item is one undo group named for it, and what it does with `editor.transact` joins it") {
        let h = try harness([Contributor(id: "doing") { r in
            r.contextMenuForCanvas {
                MenuItems(in: PowerMenuGroup.self, id: "doing") { _ in
                    MenuItem("Brighten All", in: PowerMenuGroup.self) { ids, editor in
                        editor.transact { transaction in
                            for id in ids { transaction.update(id, as: Lamp.self) { $0.props.level = 3 } }
                        }
                    }
                }
            }
        }])
        let a = h.add(Lamp(slot(0)))
        try require(h.secondaryClick(at: middle(0))).choose("Brighten All")
        expectEqual(h.editor.lamp(a)?.level, 3)
        expectEqual(h.editor.undoHistory.undoName, "Brighten All")
        h.editor.undo()
        expectEqual(h.editor.lamp(a)?.level, 1)
    },
    test("an item whose title only makes sense in its submenu names its step with `stepName`: the undo group takes that name, and one undo takes it back") {
        let h = try harness([Contributor(id: "setting") { r in
            r.contextMenuForCanvas {
                MenuItems(in: PowerMenuGroup.self, id: "setting") { _ in
                    Submenu("Set Level", in: PowerMenuGroup.self) {
                        MenuItem("High", in: PowerMenuGroup.self, stepName: "Set Level High") { ids, editor in
                            editor.transact { transaction in
                                for id in ids { transaction.update(id, as: Lamp.self) { $0.props.level = 3 } }
                            }
                        }
                    }
                }
            }
        }])
        let a = h.add(Lamp(slot(0)))
        try require(h.secondaryClick(at: middle(0))).choose("Set Level", "High")
        expectEqual(h.editor.lamp(a)?.level, 3)
        expectEqual(h.editor.undoHistory.undoName, "Set Level High")
        h.editor.undo()
        expectEqual(h.editor.lamp(a)?.level, 1)
    },

    test("the entry claims its group and id when it is registered: two plugins making the same is a conflict, in different groups or ids they aren't, and it needs the plugin installed") {
        expectThrows(RegistryError.conflict(point: "CanvasContextMenu", key: "* made", plugins: ["one", "two"])) {
            _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), ContextMenusPlugin(), generating(Generator([]), id: "one", claiming: "made"),
                                       generating(Generator([]), id: "two", claiming: "made")])
        }
        _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), ContextMenusPlugin(), generating(Generator([]), id: "one", claiming: "made"),
                                   generating(Generator([]), id: "two", claiming: "made", in: LateMenuGroup.self),
                                   generating(Generator([]), id: "three", claiming: "other")])
        expectThrows(RegistryError.ownerNotInstalled(point: "CanvasContextMenu", owner: .contextMenus, contributor: "one")) {
            _ = try Registry(plugins: [generating(Generator([]), id: "one", claiming: "made")])
        }
    },

    test("the report counts it as an item for the canvas") {
        let r = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), ContextMenusPlugin(), generating(Generator([]), id: "made")])
        expect(try require(r.report.split(separator: "\n").first { $0.hasPrefix("made") }).hasSuffix("CanvasContextMenu in PowerMenuGroup after ShapeMenuGroup"))
    },
])

@MainActor private func generating(_ generator: Generator, id: PluginID, claiming claimed: String, in group: any MenuGroup.Type = PowerMenuGroup.self) -> Contributor {
    Contributor(id: id) { r in
        r.contextMenuForCanvas {
            MenuItems(in: group, id: claimed) { _ in
                for name in generator.names { MenuItem(name, in: group) { _, _ in } }
            }
        }
    }
}

import Canvas
import CanvasTesting
import ContextMenus
import Selection
import TestKit

/// A bulb's wattage, which every lamp and fan has.
enum Wattage {}
extension Wattage: ShapeProperty {
    static let key: PropertyKey = "wattage"
    static var defaultValue: Int? { 40 }
}

/// Declares wattage, opts lamps and fans in, and gives it items on every shape that has it.
struct WattagePlugin: CanvasPlugin {
    var id: PluginID { "wattage" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.declare(Wattage.self)
        registrar.optIn(Lamp.self, to: Wattage.self)
        registrar.optIn(Fan.self, to: Wattage.self)
        registrar.contextMenu(of: Wattage.self) {
            MenuItem("Brighter Bulb", in: PowerMenuGroup.self, when: { $0 < 100 }) { $0 += 20 }
            Submenu("Bulb", in: PowerMenuGroup.self) {
                for watts in [40, 60, 100] {
                    MenuItem("\(watts) W", isChecked: { $0 == watts }) { $0 = watts }
                }
            }
        }
    }
}

@MainActor let propertyMenuTests = Suite("Context menus for added properties", [
    test("a property's items show on the shapes that have it, after the kind's own, and edit its value in one transaction") {
        let h = try harness([WattagePlugin()])
        let lamp = h.add(Lamp(slot(0)))
        h.add(Box(slot(1)))
        let menu = try require(h.secondaryClick(at: middle(0)))
        expectEqual(menu.outline, ["Turn On", "Brighter", "Level ▸", "  ✓ 1", "  2", "  3", "—",
                                   "Brighter Bulb", "Bulb ▸", "  ✓ 40 W", "  60 W", "  100 W", "—", "Delete"])
        let revision = h.editor.revision
        try menu.choose("Bulb", "100 W")
        expectEqual(h.editor.document[lamp]?[Wattage.self], 100)
        expectEqual(h.editor.revision, revision + 1)
        expect(!(try require(h.secondaryClick(at: middle(0))).outline.contains("Brighter Bulb")), "at 100 W, there's nothing brighter")
        expectEqual(try require(h.secondaryClick(at: middle(1))).outline, ["Delete"], "a box has no wattage")
        expect(h.editor.registry.report.contains("wattage") && h.editor.registry.report.contains("ShapeContextMenus in PowerMenuGroup after ShapeMenuGroup → every shape holding wattage"),
               "the kinds that hold the property, said as its scope")
    },
    test("on two kinds that opt in, a property's item is one item, and it edits each shape's value") {
        let h = try harness([WattagePlugin()])
        let lamp = h.add(Lamp(slot(0)))
        let fan = h.add(Fan(frame: slot(1)))
        h.editor.transact { $0.update(fan) { $0[Wattage.self] = 60 } }
        h.editor.selectedShapeIDs = [lamp, fan]
        let menu = try require(h.secondaryClick(at: middle(1)))
        expectEqual(menu.outline, ["Turn On", "—", "Brighter Bulb", "Bulb ▸", "  – 40 W", "  – 60 W", "  100 W", "—", "Delete"])
        let revision = h.editor.revision
        try menu.choose("Brighter Bulb")
        expectEqual([h.editor.document[lamp]?[Wattage.self], h.editor.document[fan]?[Wattage.self]], [60, 80])
        expectEqual(h.editor.revision, revision + 1)
    },
])

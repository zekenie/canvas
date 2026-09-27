import Canvas
import CanvasTesting
import ContextMenus
import CoreGraphics
import Keyboard
import Selection
import TestKit

// Fixtures only: the CanvasTesting kinds plus two local appliances, so every test here shows the
// horizontal knows no real kind.

/// A lamp: on or off, at level 1, 2 or 3.
struct Lamp: BoxShapeProps {
    static let kind: ShapeKind = "lamp"
    var frame: CGRect
    var isOn: Bool
    var level: Int

    init(_ frame: CGRect, isOn: Bool = false, level: Int = 1) {
        self.frame = frame
        self.isOn = isOn
        self.level = level
    }
}

struct LampDefinition {}

extension LampDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Lamp>, in context: RenderContext) {}
}

/// A fan: on or off.
struct Fan: BoxShapeProps {
    static let kind: ShapeKind = "fan"
    var frame: CGRect
    var isOn = false
}

struct FanDefinition {}

extension FanDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Fan>, in context: RenderContext) {}
}

/// A feature's group, as a horizontal would declare one.
enum PowerMenuGroup {}
extension PowerMenuGroup: MenuGroup {
    static var order: Int { 50 }
}

/// A group every kind shares, after the rest.
enum LateMenuGroup {}
extension LateMenuGroup: MenuGroup {
    static var order: Int { 200 }
}

/// Each kind's own menu. A lamp: Turn On or Turn Off (whichever applies), Brighter (dimmed at the
/// top level), and a Level submenu that checks its level. A fan: the same Turn On and Turn Off, so a
/// lamp and a fan selected together share them.
struct AppliancesPlugin: CanvasPlugin {
    var id: PluginID { "appliances" }

    func register(into registrar: inout PluginRegistrar) {
        registrar.shape(LampDefinition()) { lamp in
            lamp.contextMenu {
                MenuItem("Turn On", when: { !$0.isOn }) { $0.isOn = true }
                MenuItem("Turn Off", when: { $0.isOn }) { $0.isOn = false }
                MenuItem("Brighter", isEnabled: { $0.level < 3 }) { $0.level += 1 }
                Submenu("Level") {
                    for level in 1...3 {
                        MenuItem("\(level)", isChecked: { $0.level == level }) { $0.level = level }
                    }
                }
            }
        }
        registrar.shape(FanDefinition()) { fan in
            fan.contextMenu {
                MenuItem("Turn On", when: { !$0.isOn }) { $0.isOn = true }
                MenuItem("Turn Off", when: { $0.isOn }) { $0.isOn = false }
            }
        }
    }
}

/// Selection, context menus, the CanvasTesting kinds and the appliances, then `more`.
@MainActor func harness(_ more: [any CanvasPlugin] = []) throws -> EditorHarness {
    try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), ContextMenusPlugin(), FixturesPlugin(), AppliancesPlugin()] + more)
}

/// Four slots in a row, 100 points square, 100 apart: shapes go in them, and clicks at their middles.
func slot(_ index: Int) -> CGRect { CGRect(x: 200 * index, y: 0, width: 100, height: 100) }
func middle(_ index: Int) -> CGPoint { CGPoint(x: 200 * index + 50, y: 50) }
let emptyCanvas = CGPoint(x: 150, y: 50)

extension CanvasEditor {
    func lamp(_ id: ShapeID) -> Lamp? { document[id]?.typed(as: Lamp.self)?.props }
    func fan(_ id: ShapeID) -> Fan? { document[id]?.typed(as: Fan.self)?.props }
}

/// What `perform` items were run with.
@MainActor final class PerformLog {
    var runs: [String] = []
}

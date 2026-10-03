@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import SlashCommands

// A kind of this target's own, which offers commands in every way a kind can: its own, over an
// added property it holds, and (a bridge's, in the tests) every shape's.

/// A lamp: on or off, at level 1, 2 or 3, and flaggable.
struct Lamp: BoxShapeProps {
    static let kind: ShapeKind = "lamp"
    static let properties = Properties<Lamp> {
        Property("frame", \.frame).required()
        Property("isOn", \.isOn)
        Property("level", \.level)
    }
    var frame: CGRect
    var isOn: Bool
    var level: Int

    init(_ frame: CGRect, isOn: Bool = false, level: Int = 1) {
        self.frame = frame
        self.isOn = isOn
        self.level = level
    }
}

extension Lamp {
    init() { self.init(.zero) }
}

struct LampDefinition {}

extension LampDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Lamp>, in context: RenderContext) {}
}

/// Lamps, which hold `Flagged` (from `ChoresPlugin`), and offer `turn-on`, `turn-off` and `level` of
/// their own, and `unflag` over the flag they hold.
struct LampsPlugin: CanvasPlugin {
    var id: PluginID { "lamps" }

    func register(into registrar: inout PluginRegistrar) {
        registrar.shape(LampDefinition()) { lamp in
            lamp.optIn(to: Flagged.self)
            lamp.slashCommands {
                SlashCommand("turn-on", when: { !$0.isOn }) { lamp, _ in lamp.isOn = true }
                SlashCommand("turn-off", when: { $0.isOn }) { lamp, _ in lamp.isOn = false }
                SlashCommand("level", argument: "1-3", accepts: { (1...3).contains(Int($0.text) ?? 0) }) { lamp, arguments in
                    lamp.level = Int(arguments.text) ?? lamp.level
                }
            }
            lamp.slashCommands(of: Flagged.self) {
                SlashCommand("unflag", when: { $0 }) { flagged, _ in flagged = false }
            }
        }
    }
}

extension CanvasEditor {
    func lamp(_ id: ShapeID) -> Lamp? { document[id]?.typed(as: Lamp.self)?.props }
}

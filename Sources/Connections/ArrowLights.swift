import AppKit
import Canvas
import Neighbors
import Topology

extension PluginID {
    public static let arrowLights: PluginID = "arrow-lights"
}

/// Arrows' lights for Neighbors: hover a shape and what it points to is outlined in green, what
/// points to it in purple, the arrows between with them. A plugin value of its own, after Neighbors,
/// so a list without Neighbors leaves it out, and `ArrowPortsPlugin`, which declares the `arrow`
/// edges its queries name: in a list without that one the engine refuses both, and nothing lights.
///
/// - What it points to: the shapes an arrow out of it ends at, and what a reference stands for
///   (`arrow` and `stands-for`), and the arrows themselves (`:starts-at`); for an arrow hovered,
///   the shape it ends at (`:end-of`).
/// - What points to it: the shapes an arrow into it starts at, and the references that stand for it,
///   and those arrows (`:ends-at`); for an arrow hovered, the shape it starts at (`:start-of`).
///
/// Neighbors asks each in the engine's resolved view of the edges and in the literal one, so a
/// reference's own arrows count, and so does what it stands for: an arrow into a reference is, to the
/// graph, an arrow into the shape, and drawn, one into the pill.
public struct ArrowLightsPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .arrowLights }

    public func register(into registrar: inout PluginRegistrar) {
        let arrow = ArrowEdge.id.rawValue, standing = StandingEdge.id.rawValue
        registrar.neighborLight(color: ArrowStyle.pointsToLight) {
            ":edge-from(\($0), \(arrow)|\(standing)), :starts-at(\($0), \(arrow)), :end-of(\($0), \(arrow))"
        }
        registrar.neighborLight(color: ArrowStyle.pointedToByLight) {
            ":edge-to(\($0), \(arrow)|\(standing)), :ends-at(\($0), \(arrow)), :start-of(\($0), \(arrow))"
        }
    }
}

/// The lights' colors, chosen in a design audit with Mentions' two (`MentionStyle`), from renders of
/// the four over both canvases, a fixed sRGB value for each appearance rather than a system color:
/// each is clear of Validation's red and orange and of Find's orange (so a lit shape never reads as
/// one with an issue or a hit), is not the accent (the selection's and a hover's color), and is at
/// least 3:1 against the canvas in the light and the dark. The two purples, this one and what
/// mentions a shape, are close for some color-vision deficiencies.
extension ArrowStyle {
    /// What a shape points to, and the arrows out of it: green.
    static let pointsToLight = NeighborLight.color(light: 0x07933B, dark: 0x2FD359)
    /// What points to it, and the arrows into it: purple.
    static let pointedToByLight = NeighborLight.color(light: 0x8C21A4, dark: 0xB851FD)
}

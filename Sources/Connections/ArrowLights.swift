import AppKit
import Canvas
import Neighbors
import Topology

extension PluginID {
    public static let arrowLights: PluginID = "arrow-lights"
}

/// Arrows' lights for Neighbors: hover a shape and what it points to is outlined in green, what
/// points to it in purple, the arrows between with them; its panel lists each under the light's
/// title, the arrows left out. A plugin value of its own, after Neighbors, so a list without
/// Neighbors leaves it out, and `ArrowPortsPlugin`, which declares the `arrow` edges its queries
/// name: in a list without that one the engine refuses both, and nothing lights.
///
/// - What it points to: the shapes an arrow out of it ends at, and what a reference stands for
///   (`arrow` and `stands-for`); for an arrow, the shape it ends at (`:end-of`). Between: the arrows
///   themselves (`:starts-at`).
/// - What points to it: the shapes an arrow into it starts at, and the references that stand for it;
///   for an arrow, the shape it starts at (`:start-of`). Between: those arrows (`:ends-at`).
///
/// Neighbors asks each in the engine's resolved view of the edges and in the literal one, so a
/// reference's own arrows count, and so does what it stands for: an arrow into a reference is, to the
/// graph, an arrow into the shape, and drawn, one into the pill.
public struct ArrowLightsPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .arrowLights }

    public func register(into registrar: inout PluginRegistrar) {
        let arrow = ArrowEdge.id.rawValue, standing = StandingEdge.id.rawValue
        registrar.neighborLight(ArrowStyle.pointsTo, color: ArrowStyle.pointsToLight, query: {
            ":edge-from(\($0), \(arrow)|\(standing)), :end-of(\($0), \(arrow))"
        }, between: {
            ":starts-at(\($0), \(arrow))"
        })
        registrar.neighborLight(ArrowStyle.pointedToBy, color: ArrowStyle.pointedToByLight, query: {
            ":edge-to(\($0), \(arrow)|\(standing)), :start-of(\($0), \(arrow))"
        }, between: {
            ":ends-at(\($0), \(arrow))"
        })
    }
}

/// The lights' colors, chosen in a design audit with Mentions' two (`MentionStyle`), from renders of
/// the four over both canvases, a fixed sRGB value for each appearance rather than a system color:
/// each is clear of Validation's red and orange and of Find's orange (so a lit shape never reads as
/// one with an issue or a hit), is not the accent (the selection's and a hover's color), and is at
/// least 3:1 against the canvas in the light and the dark. The two purples, this one and what
/// mentions a shape, are close for some color-vision deficiencies.
extension ArrowStyle {
    /// The lights' titles, over their lists in a shape's panel.
    nonisolated static let pointsTo = "Points To"
    nonisolated static let pointedToBy = "Pointed To By"
    /// What a shape points to, and the arrows out of it: green.
    static let pointsToLight = NeighborLight.color(light: 0x07933B, dark: 0x2FD359)
    /// What points to it, and the arrows into it: purple.
    static let pointedToByLight = NeighborLight.color(light: 0x8C21A4, dark: 0xB851FD)
}

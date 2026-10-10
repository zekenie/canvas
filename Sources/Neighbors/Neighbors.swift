import AppKit
import Canvas

extension PluginID {
    public static let neighbors: PluginID = "neighbors"
}

/// Neighbors: hover a shape, on the canvas or by its row in the table of contents, and every shape
/// connected to it is outlined in a color that says how, so in a dense graph what's connected shows at
/// a glance. A **light** is one color and the question that finds its shapes (`NeighborLight`): the
/// shapes it points to, the shapes that point to it, what it mentions, what mentions it. The questions
/// are queries, asked of the query engine for the shape hovered, so what counts as a neighbor is the
/// graph's and the lights' to say, never this module's: it knows no kind, edge type or concern, and
/// the plugins that own the edges contribute the lights (`registrar.neighborLight`: arrows' are
/// Connections', mentions' are Mentions'). A shape in two lights has a ring for each; a shape on another
/// board lights the card that holds it on the board shown. The core strokes the outlines
/// (`Outlines.tinted`) and the minimap fills the same shapes, so connected shapes off screen show
/// there too. A surface: what an edge's owner shows its edges on.
public struct NeighborLight: Sendable {
    /// What the shapes it matches are outlined in.
    public var color: NSColor
    /// The query whose matches light, given the selector that names the shape hovered (`#`, then its
    /// id, as the query language writes one).
    public var query: @Sendable (String) -> String

    public init(color: NSColor, query: @escaping @Sendable (String) -> String) {
        self.color = color
        self.query = query
    }

    /// A light's color as one sRGB value (`0xRRGGBB`) in the light appearance and another in the
    /// dark, for a light whose color is chosen against both canvases rather than left to a system
    /// color.
    public static func color(light: Int, dark: Int) -> NSColor {
        func srgb(_ hex: Int) -> NSColor {
            NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        return NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? srgb(dark) : srgb(light) }
    }
}

/// The lights, each a plugin's (`registrar.neighborLight`), in plugin order: a shape's first light is
/// its first ring.
public enum NeighborLights {}

extension NeighborLights: ExtensionPoint {
    public typealias Contribution = NeighborLight
    public static var owner: PluginID { .neighbors }
    public static func summary(of _: NeighborLight, for _: ShapeTarget) -> String { "neighbor light" }
}

extension PluginRegistrar {
    /// A light: hovering a shape outlines the matches of `query` in `color`. `query` is given the
    /// selector that names the shape hovered (`#` and its id) and returns a query in the query
    /// language, written from the edge types' ids, never as literals. Lights are in plugin order, and
    /// a plugin's in the order it gives them.
    public mutating func neighborLight(color: NSColor, query: @escaping @Sendable (String) -> String) {
        contribute(NeighborLight(color: color, query: query), to: NeighborLights.self)
    }
}

extension Registry {
    /// The lights plugins gave, in order.
    public var neighborLights: [NeighborLight] { contributions(to: NeighborLights.self).map(\.value) }
}

/// The plugin: a service that follows what's hovered and asks the engine (`NeighborState`), and the
/// outlines it hands the core. Needs `QueriesPlugin` and `TopologyPlugin` to light anything,
/// `SelectionPlugin` for something to hover (the table of contents' rows set Selection's hover too),
/// and a light from some plugin; without any of them it does nothing.
public struct NeighborsPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { .neighbors }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.service { NeighborState(editor: $0, lights: $0.registry.neighborLights) }
        registrar.outlines { $0.neighbors?.outlines ?? Outlines() }
    }
}

extension CanvasEditor {
    /// What's lit for the shape hovered; nil without NeighborsPlugin.
    public var neighbors: NeighborState? { service(NeighborState.self) }
}

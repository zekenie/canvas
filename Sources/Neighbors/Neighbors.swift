import AppKit
import Canvas

/// Neighbors: hover a shape, on the canvas or by its row in the table of contents, and every shape
/// connected to it is outlined in a color that says how, so in a dense graph what's connected shows at
/// a glance. A **light** is one color and the question that finds its shapes (`NeighborLight`): the
/// shapes it points to, the shapes that point to it, what it mentions, what mentions it. The questions
/// are queries, asked of the query engine for the shape hovered, so what counts as a neighbor is the
/// graph's and the lights' to say, never this module's: it knows no kind, edge type or concern, and
/// Composition writes the lights. A shape in two lights has a ring for each; a shape on another board
/// lights the card that holds it on the board shown. The core strokes the outlines (`Outlines.tinted`)
/// and the minimap fills the same shapes, so connected shapes off screen show there too. A feature no
/// kind opts into and nothing imports, as Jump To and Moving are.
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
}

/// The plugin: a service that follows what's hovered and asks the engine (`NeighborState`), and the
/// outlines it hands the core. Needs `QueriesPlugin` and `TopologyPlugin` to light anything, and
/// `SelectionPlugin` for something to hover (the table of contents' rows set Selection's hover too);
/// without any of them it does nothing. `lights` are in order: a shape's first light is its first ring.
public struct NeighborsPlugin: CanvasPlugin {
    let lights: [NeighborLight]

    public init(lights: [NeighborLight]) { self.lights = lights }
    public var id: PluginID { "neighbors" }

    public func register(into registrar: inout PluginRegistrar) {
        let lights = lights
        registrar.service { NeighborState(editor: $0, lights: lights) }
        registrar.outlines { $0.neighbors?.outlines ?? Outlines() }
    }
}

extension CanvasEditor {
    /// What's lit for the shape hovered; nil without NeighborsPlugin.
    public var neighbors: NeighborState? { service(NeighborState.self) }
}

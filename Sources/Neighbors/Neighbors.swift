import AppKit
import Canvas
import Palette

extension PluginID {
    public static let neighbors: PluginID = "neighbors"
}

/// Neighbors: hover a shape, on the canvas or by its row in the table of contents, and every shape
/// connected to it is outlined in a color that says how, so in a dense graph what's connected shows at
/// a glance, and select one and its panel lists them, by how (`NeighborDetailsPlugin`). A **light** is
/// one color, a title, the keys held while hovering that show it and the question that finds its
/// shapes (`NeighborLight`): the shapes it points to (a plain hover), the shapes that point to it (⌥),
/// what it mentions and what mentions it (⌃⌥). The questions
/// are queries, asked of the query engine for the shape hovered, so what counts as a neighbor is the
/// graph's and the lights' to say, never this module's: it knows no kind, edge type or concern, and
/// the plugins that own the edges contribute the lights (`registrar.neighborLight`: arrows' are
/// Arrows', mentions' are Mentions', and each says its keys). A shape in two lights shown together
/// has a ring for each; a shape on another
/// board lights the card that holds it on the board shown. The core strokes the outlines
/// (`Outlines.tinted`) and the minimap fills the same shapes, so connected shapes off screen show
/// there too. A surface: what an edge's owner shows its edges on.
public struct NeighborLight: Sendable {
    /// What the panel calls the shapes it matches, as the head of their list ("Points To").
    public var title: String
    /// What the shapes it matches are outlined in.
    public var color: NSColor
    /// The keys held while hovering that show it: none for a plain hover, `.option` for ⌥. Hovering
    /// shows the lights whose keys are exactly those held of the keys some light names, so a key no
    /// light names (⇧ for a click that adds to the selection) changes nothing. The panel lists every
    /// light whatever is held.
    public var keys: Modifiers
    /// The query that finds the shapes at the other end, given the selector that names the shape
    /// hovered or selected (`#`, then its id, as the query language writes one): what's outlined, and
    /// what the panel lists.
    public var query: @Sendable (String) -> String
    /// The query that finds what runs between the shape and those (an arrow), given the same
    /// selector: outlined with them, in the same color, and never listed. Nil for none.
    public var between: (@Sendable (String) -> String)?
    /// A line under a listed shape's name, from the shape the list is of and the listed one (a
    /// mentioner's text around its mention). Nil for none. Asked of the rows in view, as each is
    /// drawn, so it reads what's kept, never a board.
    public var caption: (@MainActor @Sendable (_ editor: CanvasEditor, _ subject: ShapeID, _ neighbor: ShapeID) -> String?)?

    public init(_ title: String, color: NSColor, keys: Modifiers = [], query: @escaping @Sendable (String) -> String,
                between: (@Sendable (String) -> String)? = nil,
                caption: (@MainActor @Sendable (_ editor: CanvasEditor, _ subject: ShapeID, _ neighbor: ShapeID) -> String?)? = nil) {
        self.title = title
        self.color = color
        self.keys = keys
        self.query = query
        self.between = between
        self.caption = caption
    }

    /// The query whose matches are outlined: the shapes at the other end, and what runs between.
    public func lit(_ selector: String) -> String {
        between.map { "\(query(selector)), \($0(selector))" } ?? query(selector)
    }

    /// A light's color as one sRGB value (`0xRRGGBB`) in the light appearance and another in the
    /// dark, for a light whose color is chosen against both canvases rather than left to a system
    /// color.
    public static func color(light: Int, dark: Int) -> NSColor {
        NSColor(light: RGB(hex: UInt32(truncatingIfNeeded: light)), dark: RGB(hex: UInt32(truncatingIfNeeded: dark)))
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
    /// A light: hovering a shape with `keys` held (none, a plain hover) outlines the matches of
    /// `query`, and of `between`, in `color`, and the shape's panel lists the matches of `query` under
    /// `title` (`NeighborDetailsPlugin`), each with `caption`'s line under it if it gives one. Each
    /// query is given the selector that names the shape (`#` and its id) and returns a query in the
    /// query language, written from the edge types' ids, never as literals. Lights are in plugin
    /// order, and a plugin's in the order it gives them. A light shown with keys is said beside it
    /// with `registrar.keyHint(…, while: .pointer)`, once for its keys, for the Keyboard Shortcuts
    /// window.
    public mutating func neighborLight(
        _ title: String, color: NSColor, keys: Modifiers = [], query: @escaping @Sendable (String) -> String,
        between: (@Sendable (String) -> String)? = nil,
        caption: (@MainActor @Sendable (_ editor: CanvasEditor, _ subject: ShapeID, _ neighbor: ShapeID) -> String?)? = nil
    ) {
        contribute(NeighborLight(title, color: color, keys: keys, query: query, between: between, caption: caption), to: NeighborLights.self)
    }
}

extension Registry {
    /// The lights plugins gave, in order.
    public var neighborLights: [NeighborLight] { contributions(to: NeighborLights.self).map(\.value) }
}

/// The plugin: a service that follows what's hovered and asks the engine (`HoverLights`: one hop,
/// `NeighborState`, or the whole reach, `ReachState`, as View › Show Whole Reach says), the outlines it
/// hands the core, and the command that turns the whole reach on and off. Needs `QueriesPlugin` and
/// `TopologyPlugin` to light anything, `SelectionPlugin` for something to hover (the table of
/// contents' rows set Selection's hover too), and a light from some plugin; without any of them it does
/// nothing.
public struct NeighborsPlugin: ListedPlugin {
    /// The settings its editors follow; nil for the app's (`ReachSettings.app`, in its user defaults).
    private let settings: ReachSettings?

    public init() { settings = nil }
    /// With settings of the caller's own: a test's, kept nowhere or in a suite of its own.
    public init(reach settings: ReachSettings) { self.settings = settings }
    public var id: PluginID { .neighbors }

    public func register(into registrar: inout PluginRegistrar) {
        let own = settings
        registrar.service { HoverLights(editor: $0, lights: $0.registry.neighborLights, settings: own ?? .app) }
        registrar.outlines { $0.hoverLights?.outlines ?? Outlines() }
        registrar.command(.showWholeReach, title: ReachStyle.menuTitle, in: ViewMenu.Panels.self, placed: .last,
                          isChecked: { _ in (own ?? .app).showsWholeReach }) { _ in
            let settings = own ?? .app
            settings.showsWholeReach.toggle()
        }
    }
}

extension CanvasEditor {
    /// How a hover lights, whichever way; nil without NeighborsPlugin.
    public var hoverLights: HoverLights? { service(HoverLights.self) }
    /// What's lit for the shape hovered, one hop; nil without NeighborsPlugin, and while the whole reach shows.
    public var neighbors: NeighborState? { hoverLights?.oneHop }
    /// What's lit for the shape hovered while the whole reach shows; nil without NeighborsPlugin, and while it's off.
    public var reach: ReachState? { hoverLights?.reach }
}

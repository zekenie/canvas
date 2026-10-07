import AppKit
import Connections
import Mentions
import Neighbors
import Topology

/// The lights the app ships for Neighbors (`NeighborsPlugin(lights:)`): hover a shape and what it
/// connects to is outlined in one color for each way, so what's connected shows at a glance. Each is
/// a query, asked for the shape hovered (`#id`), written from the edge types' ids, never as literals:
/// Neighbors knows no edge type, and only Composition depends on the plugins that declare them.
///
/// - What it points to: the shapes an arrow out of it ends at, and what a reference stands for
///   (`arrow` and `stands-for`), and the arrows themselves (`:starts-at`); for an arrow hovered,
///   the shape it ends at (`:end-of`).
/// - What points to it: the shapes an arrow into it starts at, and the references that stand for it,
///   and those arrows (`:ends-at`); for an arrow hovered, the shape it starts at (`:start-of`).
/// - What it mentions, and what mentions it (`mention`).
///
/// Neighbors asks each in the engine's resolved view of the edges and in the literal one, so a
/// reference's own arrows count, and so does what it stands for: an arrow into a reference is, to the
/// graph, an arrow into the shape, and drawn, one into the pill. A shape matched by two lights has a
/// ring for each.
///
/// The colors were chosen in a design audit, from renders of the lights over both canvases, a fixed
/// sRGB value for each appearance rather than a system color: each is clear of Validation's red and
/// orange and of Find's orange (so a lit shape never reads as one with an issue or a hit), is not the
/// accent (the selection's and a hover's color), and is at least 3:1 against the canvas in the light
/// and the dark. Two of the four, the purples, are close for some color-vision deficiencies.
@MainActor
public enum NeighborLights {
    /// What it points to, and the arrows out of it: green.
    public static let pointsTo = fixed(light: 0x07933B, dark: 0x2FD359)
    /// What points to it, and the arrows into it: purple.
    public static let pointedToBy = fixed(light: 0x8C21A4, dark: 0xB851FD)
    /// What its text mentions: teal.
    public static let mentions = fixed(light: 0x0E97B0, dark: 0x329AB4)
    /// What mentions it: lavender.
    public static let mentionedBy = fixed(light: 0xA76FE2, dark: 0xD0B0FE)

    /// A color that's one sRGB value (`0xRRGGBB`) in the light appearance and another in the dark, as
    /// the arrow's color is.
    private static func fixed(light: Int, dark: Int) -> NSColor {
        func srgb(_ hex: Int) -> NSColor {
            NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        return NSColor(name: nil) { $0.isDark ? srgb(dark) : srgb(light) }
    }

    /// The four lights, in the order a shape's rings go: the first it's matched by is its first ring.
    public static var shipped: [NeighborLight] {
        let arrow = ArrowEdge.id.rawValue, standing = StandingEdge.id.rawValue, mention = MentionEdge.id.rawValue
        return [
            NeighborLight(color: pointsTo) { ":edge-from(\($0), \(arrow)|\(standing)), :starts-at(\($0), \(arrow)), :end-of(\($0), \(arrow))" },
            NeighborLight(color: pointedToBy) { ":edge-to(\($0), \(arrow)|\(standing)), :ends-at(\($0), \(arrow)), :start-of(\($0), \(arrow))" },
            NeighborLight(color: mentions) { ":edge-from(\($0), \(mention))" },
            NeighborLight(color: mentionedBy) { ":edge-to(\($0), \(mention))" },
        ]
    }
}

extension NSAppearance {
    fileprivate var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

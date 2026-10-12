import Adornments
import AppKit
import Canvas

/// A type's color, worked out from its id and never stored: one of eight (`TypesStyle.colorTable`),
/// so two types can share one. The same everywhere the type shows: its pill is solid in it, the chips
/// of the shapes that are it are light in it, and a row of `/is-a`'s list is a capsule in it.
@MainActor
public enum TypeColors {
    /// Which of the eight a type's id says: the first eight bytes of its UUID, each summed with its
    /// position, modulo eight. Never `hashValue`, which changes with the process.
    public static func index(of id: ShapeID) -> Int {
        let bytes = id.rawValue.uuid
        let first = [bytes.0, bytes.1, bytes.2, bytes.3, bytes.4, bytes.5, bytes.6, bytes.7]
        return first.enumerated().reduce(0) { $0 + Int($1.element) + $1.offset } % TypesStyle.colorTable.count
    }

    /// The type's pill: its color, with white text.
    public static func solid(_ id: ShapeID) -> AdornmentTint { solids[index(of: id)] }
    /// The type's chip: its color faint, with a line of it, its title in the color's ink.
    public static func light(_ id: ShapeID) -> AdornmentTint { lights[index(of: id)] }
    /// The type's color alone: a row of `/is-a`'s list.
    public static func base(_ id: ShapeID) -> NSColor { solids[index(of: id)].color }

    /// What has no color of its own: `Type`, and a type that is untitled.
    public static let gray = AdornmentTint(TypesStyle.grayChip, style: .solid)

    private static let solids = TypesStyle.colorTable.map { AdornmentTint(color(from: $0.base), style: .solid) }
    private static let lights = TypesStyle.colorTable.map {
        AdornmentTint(color(from: $0.base), ink: ink(light: $0.lightInk, dark: $0.darkInk), style: .light)
    }

    private static func color(from rgb: TypesStyle.RGB) -> NSColor { NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1) }

    /// The ink that reads on the canvas of the appearance drawn, over its own faint tint.
    private static func ink(light: TypesStyle.RGB, dark: TypesStyle.RGB) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? color(from: dark) : color(from: light)
        }
    }
}

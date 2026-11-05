import AppKit
import Palette

/// What a pill wears of its original's color: made once from the color's roles (`Swatch`) and shared by every pill of
/// that color, the way a color's `CGColor`s are kept by the color book. The fill is the color's `wash`, the edge its
/// `solid` read against the canvas and a raised frame alike (`Swatch.reading`, so the indigo and the purple lift in the
/// dark, where the raw `solid` is under 3:1 on a frame), the symbol its `ink`, the count's capsule its `solid` at 30%,
/// and zoomed out a block of `solid` at 50% over the canvas. Both appearances are made together; drawing picks one.
@MainActor
final class PillColors {
    /// The colors a pill draws with in one appearance.
    struct Parts {
        let fill: CGColor
        let edge: CGColor
        let badge: CGColor
        let skeleton: CGColor
    }

    let swatch: Swatch
    /// The symbol's color, which follows the appearance.
    let symbol: NSColor
    private let light: Parts
    private let dark: Parts
    private let strength: CGFloat
    private var dimmedColors: PillColors?

    init(_ swatch: Swatch, strength: CGFloat = 1) {
        self.swatch = swatch
        self.strength = strength
        symbol = NSColor(swatch.ink)
        light = Self.parts(of: swatch, dark: false, strength: strength)
        dark = Self.parts(of: swatch, dark: true, strength: strength)
    }

    func parts(dark isDark: Bool) -> Parts { isDark ? dark : light }

    /// The same colors at `ReferenceStyle.findingStrength`: a pill looking for its answer wears the color of the last.
    var dimmed: PillColors {
        if strength < 1 { return self }
        if let dimmedColors { return dimmedColors }
        let made = PillColors(swatch, strength: ReferenceStyle.findingStrength)
        dimmedColors = made
        return made
    }

    private static func parts(of swatch: Swatch, dark: Bool, strength: CGFloat) -> Parts {
        let canvas = Swatch.canvas[dark: dark], raised = Swatch.raised[dark: dark]
        let solid = swatch.solid[dark: dark]
        let edge = Swatch.reading(solid, against: [canvas, raised], atLeast: Swatch.lineContrast)
        func color(_ rgb: RGB, _ alpha: CGFloat) -> CGColor {
            CGColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: alpha * strength)
        }
        return Parts(fill: color(swatch.wash[dark: dark], 1), edge: color(edge, 1),
                     badge: color(solid, ReferenceStyle.badgeStrength),
                     skeleton: color(solid.over(canvas, alpha: ReferenceStyle.skeletonStrength), 1))
    }
}

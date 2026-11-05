import Foundation

/// A color as how light it is, how colorful and which hue (OKLCH, Björn Ottosson's Oklab in polar
/// form): the space a color's variations are made in, since moving `lightness` alone keeps what
/// the eye calls the same color, where moving sRGB's components, or HSL's lightness, shifts its hue
/// and its strength with it.
public struct OKLCH: Hashable, Sendable {
    /// 0 for black to 1 for white.
    public var lightness: Double
    /// 0 for a gray; sRGB's most colorful colors are near 0.3.
    public var chroma: Double
    /// In radians, from Oklab's `a` axis toward its `b`. A gray's says nothing.
    public var hue: Double

    public init(lightness: Double, chroma: Double, hue: Double) {
        self.lightness = lightness
        self.chroma = chroma
        self.hue = hue
    }

    public init(_ color: RGB) {
        let (r, g, b) = color.linear
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        self.init(lightness: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s, chroma: hypot(a, bb), hue: atan2(bb, a))
    }

    /// The color in linear sRGB, which a color sRGB can't show falls outside 0 to 1 of.
    private var linear: (red: Double, green: Double, blue: Double) {
        let a = chroma * cos(hue), b = chroma * sin(hue)
        let l = pow(lightness + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(lightness - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(lightness - 0.0894841775 * a - 1.2914855480 * b, 3)
        return (4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
    }

    /// Whether sRGB can show it.
    public var isDisplayable: Bool {
        let (r, g, b) = linear
        return min(r, g, b) >= -Self.slack && max(r, g, b) <= 1 + Self.slack
    }

    /// How far outside 0 to 1 a component may fall and still count as shown: what a round trip
    /// through this space leaves of a color at sRGB's edge.
    private static let slack = 1e-6

    /// The color sRGB shows it as: itself, or, for one too colorful for sRGB at its lightness, the
    /// most colorful one of the same lightness and hue. So lightening or darkening a color never
    /// turns its hue, as clipping its components would; it only pales where it must.
    public var rgb: RGB {
        var color = self
        color.lightness = min(max(lightness, 0), 1)
        if !color.isDisplayable {
            var low = 0.0, high = color.chroma
            for _ in 0..<32 {
                color.chroma = (low + high) / 2
                if color.isDisplayable { low = color.chroma } else { high = color.chroma }
            }
            color.chroma = low
        }
        let (r, g, b) = color.linear
        return RGB(linear: min(max(r, 0), 1), min(max(g, 0), 1), min(max(b, 0), 1))
    }
}

extension RGB {
    /// This color quieted toward a gray of `lightness` (OKLCH's, 0 to 1): its lightness taken
    /// `amount` of the way there and its chroma cut by as much, its hue kept. So colors quieted
    /// together come out about as heavy as the gray and still apart by hue: 0 is the color, 1 the
    /// gray. What a board's preview draws a shape's color in.
    public func muted(by amount: Double, toward lightness: Double) -> RGB {
        let color = OKLCH(self)
        return OKLCH(lightness: color.lightness + (lightness - color.lightness) * amount, chroma: color.chroma * (1 - amount),
                     hue: color.hue).rgb
    }
}

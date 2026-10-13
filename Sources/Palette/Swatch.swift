import Foundation

/// A color in the light appearance and in the dark one.
public struct Tone: Hashable, Sendable {
    public var light: RGB
    public var dark: RGB

    public init(light: RGB, dark: RGB) {
        self.light = light
        self.dark = dark
    }

    /// The same in both appearances.
    public init(_ color: RGB) {
        self.init(light: color, dark: color)
    }

    public subscript(dark isDark: Bool) -> RGB {
        get { isDark ? dark : light }
        set { if isDark { dark = newValue } else { light = newValue } }
    }
}

/// The looks one color is drawn in. A color is a starting point: what draws it draws one of seven
/// roles worked out from it, each in the light appearance and the dark, so the same color suits a
/// line, a surface, text and a sheet of paper, on either canvas.
///
/// The roles are made in OKLCH from the one color, the same way for every color (a name's and a
/// value someone picked alike), and each meets its contrast floor by construction: where the color
/// as given doesn't read, its lightness is moved, its hue kept, only as far as the floor needs.
public struct Swatch: Hashable, Sendable {
    /// The color as a line or a symbol on the canvas (an arrow, a border), and as a fill that holds
    /// text (a pill): the color itself where it reads on the canvas at `lineContrast`, else the
    /// nearest lighter or darker color of its hue that does.
    public var solid: Tone
    /// Text on `solid`: white, or black where white doesn't read on it at `textContrast`.
    public var onSolid: Tone
    /// A faint surface of the color on the canvas (a region, a light chip): `solid` at
    /// `washStrength` over the canvas.
    public var wash: Tone
    /// A large surface that holds shapes (a region, a card): raised off the canvas as a panel is,
    /// white in the light and a lighter gray in the dark (`raised`), with a little of the color,
    /// `solid` at `surfaceStrength` over it.
    public var surface: Tone
    /// Text in the color, on the canvas, on `wash` or on `surface`: `solid`, made lighter or darker
    /// until it reads on all three at `textContrast`.
    public var ink: Tone
    /// A sheet of paper in the color (a note): its hue as a light pastel, the same in both
    /// appearances, since paper stays paper in the dark, and as light whatever the color, so the
    /// inks drawn on a note read on every one.
    public var paper: Tone
    /// Text on `paper`: a note's ink, whatever the color.
    public var paperInk: Tone { Tone(Self.paperInk) }

    /// The canvas the roles are made to read on, as the contrast math takes it: the light one and
    /// the dark one. The core's own (`Style.canvasBackground`) is these grays written as AppKit's
    /// white, a little darker in the dark than sRGB's 0.11, so what reads here reads there; a
    /// change to the core's is a change here.
    public static let canvas = Tone(light: RGB(white: 0.965), dark: RGB(white: 0.11))
    /// What a line or a symbol needs against what it's drawn on (WCAG's floor for what isn't text).
    public static let lineContrast = 3.0
    /// What text needs against what it's drawn on (WCAG's AA).
    public static let textContrast = 4.5
    /// How much of the color a wash is.
    public static let washStrength = 0.14
    /// What a surface that holds shapes is raised to before it takes its color: a step up from the
    /// canvas, as a panel is.
    public static let raised = Tone(light: .white, dark: RGB(white: 0.15))
    /// How much of the color a surface is.
    public static let surfaceStrength = 0.05
    /// How light every paper is (OKLCH's lightness), and the most colorful one may be.
    public static let paperLightness = 0.905
    public static let paperChroma = 0.07
    /// A note's ink.
    public static let paperInk = RGB(white: 0.12)

    /// The roles of `color`, made to read on `canvas`, its surface raised to `raised`.
    public init(_ color: RGB, on canvas: Tone = Swatch.canvas, raised: Tone = Swatch.raised) {
        let given = OKLCH(color)
        func roles(on ground: RGB, raised: RGB) -> (solid: RGB, onSolid: RGB, wash: RGB, surface: RGB, ink: RGB) {
            let solid = Self.reading(color, against: [ground], atLeast: Self.lineContrast)
            let wash = solid.over(ground, alpha: Self.washStrength)
            let surface = solid.over(raised, alpha: Self.surfaceStrength)
            let ink = Self.reading(solid, against: [wash, ground, surface], atLeast: Self.textContrast)
            // Over the floor by what `reading` is, so white still reads once the solid is rounded to 8 bits.
            let onSolid = RGB.white.contrast(with: solid) >= Self.textContrast * Self.margin ? RGB.white : RGB.black
            return (solid, onSolid, wash, surface, ink)
        }
        let light = roles(on: canvas.light, raised: raised.light), dark = roles(on: canvas.dark, raised: raised.dark)
        solid = Tone(light: light.solid, dark: dark.solid)
        onSolid = Tone(light: light.onSolid, dark: dark.onSolid)
        wash = Tone(light: light.wash, dark: dark.wash)
        surface = Tone(light: light.surface, dark: dark.surface)
        ink = Tone(light: light.ink, dark: dark.ink)
        paper = Tone(OKLCH(lightness: Self.paperLightness, chroma: min(given.chroma, Self.paperChroma), hue: given.hue).rgb)    }

    /// `color` if it reads against every one of `grounds` at `ratio`; else the color of its hue
    /// nearest it in lightness that does, darker on light grounds and lighter on dark ones, paler
    /// only where sRGB has no color that strong at that lightness. Where nothing reads at `ratio`
    /// (a mid-gray ground), black or white, whichever is away from the grounds.
    public static func reading(_ color: RGB, against grounds: [RGB], atLeast ratio: Double) -> RGB {
        let floor = ratio * margin
        func reads(_ candidate: RGB) -> Bool { grounds.allSatisfy { candidate.contrast(with: $0) >= floor } }
        if reads(color) { return color }
        let lightGrounds = grounds.map(\.luminance).reduce(0, +) / Double(max(grounds.count, 1)) > midLuminance
        var candidate = OKLCH(color)
        // `far` reads (or nothing does), `near` doesn't: halve the gap until they meet.
        var far = lightGrounds ? 0.0 : 1.0, near = min(max(candidate.lightness, 0), 1)
        for _ in 0..<32 {
            candidate.lightness = (far + near) / 2
            if reads(candidate.rgb) { far = candidate.lightness } else { near = candidate.lightness }
        }
        candidate.lightness = far
        return candidate.rgb
    }

    /// How far over a floor a color is made to read, so it still meets it rounded to 8 bits a component.
    private static let margin = 1.02
    /// The luminance black and white read equally well against.
    private static let midLuminance = 0.179
}

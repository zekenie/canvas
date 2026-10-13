import AppKit

extension NSAppearance {
    /// Whether this is a dark appearance: the one test a color that follows the appearance makes.
    public var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

extension NSColor {
    /// An opaque sRGB color.
    public convenience init(_ color: RGB) {
        self.init(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
    }

    /// A color that follows the appearance it's drawn in: `light`, and `dark` in a dark one. It's
    /// resolved as it's drawn, so read its `cgColor` in the drawing, never ahead of it.
    public convenience init(light: RGB, dark: RGB) {
        self.init(name: nil) { NSColor($0.isDark ? dark : light) }
    }

    /// A tone, following the appearance.
    public convenience init(_ tone: Tone) {
        self.init(light: tone.light, dark: tone.dark)
    }
}

extension RGB {
    /// An opaque sRGB color, for a drawing that knows which appearance it's in.
    public var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}

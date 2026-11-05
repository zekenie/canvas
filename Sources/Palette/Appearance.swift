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

    /// This color at `strength` of its opacity, still following the appearance it's drawn in: a system color's own
    /// `withAlphaComponent` is fixed to the appearance current as it's made (the dark's white, faded, is nothing on a
    /// light ground). The alpha is replaced, so at 1 a color with an alpha of its own (`labelColor`) is opaque.
    public func fading(to strength: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in NSColor.resolved(in: appearance) { self.withAlphaComponent(strength) } }
    }

    /// A color made as it is in `appearance`: the system's colors change with it.
    public static func resolved(in appearance: NSAppearance, _ make: () -> NSColor) -> NSColor {
        var color = NSColor.clear
        appearance.performAsCurrentDrawingAppearance { color = make() }
        return color
    }
}

extension RGB {
    /// An opaque sRGB color, for a drawing that knows which appearance it's in.
    public var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    /// A color's components in sRGB (one outside sRGB's range brought into it), its alpha dropped;
    /// nil for one Core Graphics can't convert (a pattern).
    public init?(_ color: CGColor) {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let components = color.converted(to: space, intent: .defaultIntent, options: nil)?.components, components.count >= 3
        else { return nil }
        self.init(min(max(components[0], 0), 1), min(max(components[1], 0), 1), min(max(components[2], 0), 1))
    }
}

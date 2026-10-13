import Palette

/// A color with a name: one of the built-in ones, the same in every file, or one a file added.
public struct NamedColor: Hashable, Sendable {
    /// As it's listed and written: a built-in one's is lowercase (`blue`).
    public var name: String
    /// The color itself, which its roles are made from.
    public var value: RGB
    public var isBuiltIn: Bool
    /// The roles it's drawn in: `Swatch(value)`, but for a built-in one's pinned roles.
    public var swatch: Swatch

    public init(name: String, value: RGB, isBuiltIn: Bool = false, swatch: Swatch? = nil) {
        self.name = name
        self.value = value
        self.isBuiltIn = isBuiltIn
        self.swatch = swatch ?? Swatch(value)
    }

    /// As a shape holds it.
    public var color: ShapeColor { .named(name) }

    /// As a list that names it in words says it (the panel's row, Color ▸): a built-in one's first
    /// letter capitalized (`Blue`), a file's as written.
    public var title: String { isBuiltIn ? name.prefix(1).uppercased() + name.dropFirst() : name }
}

/// The built-in colors: ten names every file has, in the order every list shows them. Each value
/// is one sRGB color chosen from renders of its roles on both canvases, dark enough that white
/// reads on its solid (but yellow's and orange's, which take black); its roles are worked out as any
/// color's are (`Swatch`), with a few pinned to what the app drew before colors had names: yellow's
/// paper is the note's yellow, and indigo's line in the dark and its surface are the subboard's.
public enum BuiltInColors {
    public static let gray = NamedColor(builtIn: "gray", 0x707070)
    public static let red = NamedColor(builtIn: "red", 0xD92D2D)
    public static let orange = NamedColor(builtIn: "orange", 0xD1500B)
    public static let yellow = NamedColor(builtIn: "yellow", 0xF2B705) { $0.paper = Tone(notePaper) }
    public static let green = NamedColor(builtIn: "green", 0x23833A)
    public static let teal = NamedColor(builtIn: "teal", 0x0A7C8C)
    public static let blue = NamedColor(builtIn: "blue", 0x1A73C7)
    public static let indigo = NamedColor(builtIn: "indigo", 0x5856D6) {
        $0.pin(surface: cardLight, dark: false)
        $0.pin(solid: RGB(hex: 0x5E5CE6), surface: cardDark, dark: true)
    }
    public static let purple = NamedColor(builtIn: "purple", 0xA23BC2)
    public static let pink = NamedColor(builtIn: "pink", 0xD6336C)

    /// In the order every list shows them.
    public static let all = [gray, red, orange, yellow, green, teal, blue, indigo, purple, pink]

    /// The yellow a note has always been.
    public static let notePaper = RGB(1.0, 0.87, 0.45)
    /// The card a subboard has always been, in the light and in the dark.
    public static let cardLight = RGB(0.98, 0.98, 1)
    public static let cardDark = RGB(0.15, 0.15, 0.19)

    private static let byKey = Dictionary(uniqueKeysWithValues: all.map { (ShapeColor.key(of: $0.name), $0) })

    /// The built-in color called `name`, whatever its case.
    public static func named(_ name: String) -> NamedColor? {
        byKey[ShapeColor.key(of: name)]
    }
}

extension NamedColor {
    fileprivate init(builtIn name: String, _ hex: UInt32, pinning pin: (inout Swatch) -> Void = { _ in }) {
        let value = RGB(hex: hex)
        var swatch = Swatch(value)
        pin(&swatch)
        self.init(name: name, value: value, isBuiltIn: true, swatch: swatch)
    }
}

extension Swatch {
    /// Pins roles of one appearance, and makes what follows from them there again: a pinned solid's
    /// wash and surface, and the ink that reads on all of it.
    fileprivate mutating func pin(solid pinned: RGB? = nil, surface pinnedSurface: RGB? = nil, dark isDark: Bool) {
        let ground = Swatch.canvas[dark: isDark]
        if let pinned {
            solid[dark: isDark] = pinned
            wash[dark: isDark] = pinned.over(ground, alpha: Swatch.washStrength)
            surface[dark: isDark] = pinned.over(Swatch.raised[dark: isDark], alpha: Swatch.surfaceStrength)
        }
        if let pinnedSurface { surface[dark: isDark] = pinnedSurface }
        ink[dark: isDark] = Swatch.reading(solid[dark: isDark], against: [wash[dark: isDark], ground, surface[dark: isDark]], atLeast: Swatch.textContrast)
    }
}

extension ShapeColor {
    public static let gray = BuiltInColors.gray.color
    public static let red = BuiltInColors.red.color
    public static let orange = BuiltInColors.orange.color
    public static let yellow = BuiltInColors.yellow.color
    public static let green = BuiltInColors.green.color
    public static let teal = BuiltInColors.teal.color
    public static let blue = BuiltInColors.blue.color
    public static let indigo = BuiltInColors.indigo.color
    public static let purple = BuiltInColors.purple.color
    public static let pink = BuiltInColors.pink.color
}

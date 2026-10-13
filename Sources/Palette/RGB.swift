import Foundation

/// A color as its sRGB components, each 0 to 1: what a color is written as (`#4465E9`), and what the
/// math here works on. It has no alpha: the colors this module makes are opaque, and a caller that
/// wants one faint mixes it over what it's drawn on (`over(_:alpha:)`) or fades it as it draws.
public struct RGB: Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(_ red: Double, _ green: Double, _ blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// A gray.
    public init(white: Double) {
        self.init(white, white, white)
    }

    /// `0xRRGGBB`.
    public init(hex: UInt32) {
        self.init(Double(hex >> 16 & 0xFF) / 255, Double(hex >> 8 & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }

    /// A color as it's written: `#4465E9`, or `#46E` for `#4466EE`, in either case. Nil for
    /// anything else, a name and a value with an alpha among them.
    public init?(hexString text: String) {
        guard text.first == "#" else { return nil }
        let digits = text.dropFirst()
        guard digits.count == 6 || digits.count == 3, digits.allSatisfy(\.isHexDigit), digits.allSatisfy(\.isASCII),
              let value = UInt32(digits.count == 6 ? String(digits) : digits.map { "\($0)\($0)" }.joined(), radix: 16)
        else { return nil }
        self.init(hex: value)
    }

    /// `#4465E9`: six digits, in capitals, each component rounded to the nearest of its 256 steps.
    public var hexString: String {
        // A component that isn't a number is written as none of it.
        func step(_ component: Double) -> Int { component.isNaN ? 0 : Int((min(max(component, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", step(red), step(green), step(blue))
    }

    public static let white = RGB(white: 1)
    public static let black = RGB(white: 0)

    /// This color at `alpha` over `ground`: what a faint fill of it looks like there.
    public func over(_ ground: RGB, alpha: Double) -> RGB {
        RGB(alpha * red + (1 - alpha) * ground.red, alpha * green + (1 - alpha) * ground.green, alpha * blue + (1 - alpha) * ground.blue)
    }

    /// The components as light adds up, undoing sRGB's curve.
    var linear: (red: Double, green: Double, blue: Double) {
        (Self.linear(red), Self.linear(green), Self.linear(blue))
    }

    init(linear red: Double, _ green: Double, _ blue: Double) {
        self.init(Self.encoded(red), Self.encoded(green), Self.encoded(blue))
    }

    static func linear(_ component: Double) -> Double {
        component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
    }

    static func encoded(_ component: Double) -> Double {
        component <= 0.0031308 ? component * 12.92 : 1.055 * pow(component, 1 / 2.4) - 0.055
    }

    /// How light it is, 0 for black to 1 for white, as WCAG measures it (relative luminance).
    public var luminance: Double {
        let (r, g, b) = linear
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    /// How well it reads against `other`, 1 for the same lightness to 21 for black on white: WCAG's
    /// contrast ratio, which the floors here are in (`Swatch.lineContrast`, `Swatch.textContrast`).
    public func contrast(with other: RGB) -> Double {
        let (a, b) = (luminance, other.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

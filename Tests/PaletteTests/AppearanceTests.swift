import AppKit
import Palette
import TestKit

/// `color` as `appearance` resolves it, in sRGB.
@MainActor private func resolved(_ color: NSColor, in name: NSAppearance.Name) throws -> RGB {
    var found: NSColor?
    try require(NSAppearance(named: name)).performAsCurrentDrawingAppearance { found = color.usingColorSpace(.sRGB) }
    let components = try require(found)
    return RGB(Double(components.redComponent), Double(components.greenComponent), Double(components.blueComponent))
}

@MainActor let appearanceTests = Suite("Appearance", [
    test("the dark appearances are dark, vibrant and high-contrast ones too, and the light ones aren't") {
        for name in [NSAppearance.Name.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastVibrantDark] {
            expect(try require(NSAppearance(named: name)).isDark, "\(name.rawValue) isn't dark")
        }
        for name in [NSAppearance.Name.aqua, .vibrantLight, .accessibilityHighContrastAqua, .accessibilityHighContrastVibrantLight] {
            expect(!(try require(NSAppearance(named: name)).isDark), "\(name.rawValue) is dark")
        }
    },
    test("a color of two values is the light one in a light appearance and the dark one in a dark") {
        let light = RGB(hex: 0x07933B), dark = RGB(hex: 0x2FD359)
        let color = NSColor(light: light, dark: dark)
        expectClose(try resolved(color, in: .aqua), light)
        expectClose(try resolved(color, in: .darkAqua), dark)
        expectClose(try resolved(NSColor(Tone(light: light, dark: dark)), in: .darkAqua), dark)
        expectClose(try resolved(NSColor(Tone(light)), in: .darkAqua), light)
    },
    test("a color made from sRGB components holds them, opaque, as an NSColor and as a CGColor") {
        let blue = RGB(hex: 0x4465E9)
        let color = try require(NSColor(blue).usingColorSpace(.sRGB))
        expectClose(color.redComponent, CGFloat(blue.red))
        expectClose(color.greenComponent, CGFloat(blue.green))
        expectClose(color.blueComponent, CGFloat(blue.blue))
        expectClose(color.alphaComponent, 1)
        let cg = blue.cgColor
        expectEqual(cg.colorSpace?.name, CGColorSpace.sRGB)
        expectEqual(cg.components?.map { Double($0) } ?? [], [blue.red, blue.green, blue.blue, 1])
    },
])

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

/// The opacity `appearance` resolves `color` to.
@MainActor private func opacity(_ color: NSColor, in name: NSAppearance.Name) throws -> CGFloat {
    var found: NSColor?
    try require(NSAppearance(named: name)).performAsCurrentDrawingAppearance { found = color.usingColorSpace(.sRGB) }
    return try require(found).alphaComponent
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
    test("a color faded is itself at that opacity in each appearance it's drawn in, whichever was current as it was made") {
        let light = RGB(hex: 0x07933B), dark = RGB(hex: 0x2FD359)
        for current in [NSAppearance.Name.aqua, .darkAqua] {
            var made: (two: NSColor, system: NSColor)?
            try require(NSAppearance(named: current)).performAsCurrentDrawingAppearance {
                made = (NSColor(light: light, dark: dark).fading(to: 0.3), NSColor.labelColor.fading(to: 0.15))
            }
            let (two, system) = try require(made)
            expectClose(try resolved(two, in: .aqua), light, "made in \(current.rawValue)")
            expectClose(try resolved(two, in: .darkAqua), dark, "made in \(current.rawValue)")
            expectClose(try resolved(system, in: .aqua), RGB(0, 0, 0), "a system color's own, dark on the light, made in \(current.rawValue)")
            expectClose(try resolved(system, in: .darkAqua), RGB(1, 1, 1), "and light on the dark, made in \(current.rawValue)")
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                expectClose(try opacity(two, in: name), 0.3)
                expectClose(try opacity(system, in: name), 0.15)
            }
        }
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
    test("a CGColor's sRGB components, read back as an RGB, from sRGB and from another space, converted, its alpha dropped, held to sRGB's range") {
        let blue = RGB(hex: 0x4465E9)
        expectClose(try require(RGB(blue.cgColor)), blue)
        expectClose(try require(RGB(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 0.5))), RGB(0.2, 0.4, 0.6))
        // A gray space's 50% is sRGB's 57% (its own curve): converted, never taken as the number it holds.
        let gray = try require(RGB(CGColor(gray: 0.5, alpha: 1)))
        expect(abs(gray.red - gray.green) < 1e-3 && abs(gray.green - gray.blue) < 1e-3 && (0.5...0.65).contains(gray.red), "\(gray.hexString)")
        let wide = try require(CGColor(colorSpace: try require(CGColorSpace(name: CGColorSpace.extendedSRGB)), components: [1.2, -0.1, 0.5, 1]))
        let held = try require(RGB(wide))
        for component in [held.red, held.green, held.blue] { expect((0...1).contains(component), "\(component) is out of range") }
    },
])

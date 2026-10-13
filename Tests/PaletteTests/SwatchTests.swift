import Foundation
import Palette
import TestKit

/// A color as a bitmap holds it: each component one of 256 steps.
private func rounded(_ color: RGB) -> RGB { RGB(hexString: color.hexString)! }

@MainActor let swatchTests = Suite("Swatch", [
    test("a color that reads on the canvas is its own solid, in both appearances") {
        let blue = RGB(hex: 0x4465E9), swatch = Swatch(blue)
        expectClose(swatch.solid.light, blue)
        expectClose(swatch.solid.dark, blue)
    },
    test("a color too light for the light canvas is darkened there, and one too dark for the dark canvas lightened there, only as far as a line needs") {
        let yellow = RGB(hex: 0xFFD60A), navy = RGB(hex: 0x0A1A4A)
        let light = Swatch(yellow).solid.light, dark = Swatch(navy).solid.dark
        expect(light != yellow && dark != navy)
        expectClose(Swatch(yellow).solid.dark, yellow, "yellow reads on the dark canvas as it is")
        expectClose(Swatch(navy).solid.light, navy, "navy reads on the light canvas as it is")
        for (moved, ground) in [(light, Swatch.canvas.light), (dark, Swatch.canvas.dark)] {
            let contrast = moved.contrast(with: ground)
            expect(contrast >= Swatch.lineContrast && contrast < Swatch.lineContrast * 1.04, "moved to \(contrast):1")
        }
        expect(OKLCH(light).lightness < OKLCH(yellow).lightness, "darker on the light canvas")
        expect(OKLCH(dark).lightness > OKLCH(navy).lightness, "lighter on the dark canvas")
    },
    test("every role of every color meets its floor on both canvases, also once rounded to 8 bits") {
        for color in sampleColors {
            let swatch = Swatch(color)
            for isDark in [false, true] {
                let canvas = Swatch.canvas[dark: isDark], name = "\(color.hexString) \(isDark ? "dark" : "light")"
                let solid = rounded(swatch.solid[dark: isDark]), wash = rounded(swatch.wash[dark: isDark])
                let ink = rounded(swatch.ink[dark: isDark]), onSolid = swatch.onSolid[dark: isDark]
                expect(solid.contrast(with: canvas) >= Swatch.lineContrast, "\(name): solid at \(solid.contrast(with: canvas))")
                expect(onSolid == .white || onSolid == .black, "\(name): text on solid is \(onSolid.hexString)")
                expect(onSolid.contrast(with: solid) >= Swatch.textContrast, "\(name): text on solid at \(onSolid.contrast(with: solid))")
                expect(ink.contrast(with: wash) >= Swatch.textContrast, "\(name): ink on wash at \(ink.contrast(with: wash))")
                expect(ink.contrast(with: canvas) >= Swatch.textContrast, "\(name): ink on the canvas at \(ink.contrast(with: canvas))")
                expectClose(swatch.wash[dark: isDark], swatch.solid[dark: isDark].over(canvas, alpha: Swatch.washStrength))
                let surface = rounded(swatch.surface[dark: isDark])
                expect(ink.contrast(with: surface) >= Swatch.textContrast, "\(name): ink on its surface at \(ink.contrast(with: surface))")
                expectClose(swatch.surface[dark: isDark], swatch.solid[dark: isDark].over(Swatch.raised[dark: isDark], alpha: Swatch.surfaceStrength))
            }
        }
    },
    test("text on a solid is white where white reads, else black") {
        expectEqual(Swatch(RGB(hex: 0x4465E9)).onSolid, Tone(.white))
        expectEqual(Swatch(RGB(hex: 0xFFD60A)).onSolid.dark, .black)
        expectEqual(Swatch(.black).onSolid.light, .white)
    },
    test("ink is the solid where the solid reads as text, else lighter or darker") {
        let navy = Swatch(RGB(hex: 0x0A1A4A)), blue = Swatch(RGB(hex: 0x4465E9))
        expectClose(navy.ink.light, navy.solid.light)
        expect(OKLCH(blue.ink.dark).lightness > OKLCH(blue.solid.dark).lightness, "lighter on the dark canvas")
        expect(OKLCH(blue.ink.light).lightness < OKLCH(blue.solid.light).lightness, "darker on the light canvas")
    },
    test("paper is one light sheet in both appearances, as light whatever the color, and no more colorful than its cap") {
        for color in sampleColors {
            let swatch = Swatch(color), paper = swatch.paper.light, there = OKLCH(paper)
            expectEqual(swatch.paper.dark, paper, "\(color.hexString): the same in the dark")
            expectClose(CGFloat(there.lightness), CGFloat(Swatch.paperLightness), within: 0.002)
            expect(there.chroma <= Swatch.paperChroma + 0.001, "\(color.hexString): paper's chroma is \(there.chroma)")
            expect(paper.luminance > 0.70 && paper.luminance < 0.80, "\(color.hexString): paper's luminance is \(paper.luminance)")
            expectEqual(swatch.paperInk, Tone(Swatch.paperInk))
            expect(swatch.paperInk.light.contrast(with: rounded(paper)) >= 12, "\(color.hexString): ink on paper at \(swatch.paperInk.light.contrast(with: paper))")
        }
        expect(OKLCH(Swatch(RGB(white: 0.4)).paper.light).chroma < 0.001, "a gray's paper is gray")
    },
    test("the roles keep the color's hue") {
        for color in sampleColors {
            let given = OKLCH(color)
            guard given.chroma > 0.04 else { continue }
            let swatch = Swatch(color)
            for (role, made) in [("solid", swatch.solid.light), ("solid, dark", swatch.solid.dark), ("ink", swatch.ink.light), ("ink, dark", swatch.ink.dark), ("paper", swatch.paper.light)] {
                let there = OKLCH(made)
                guard there.chroma > 0.02 else { continue }
                expect(degreesApart(there.hue, given.hue) < 1.5, "\(color.hexString): \(role) turned \(degreesApart(there.hue, given.hue))°")
            }
        }
    },
    test("the roles are made for the canvas they're handed") {
        let blue = RGB(hex: 0x4465E9), ground = Tone(light: .white, dark: .black)
        let swatch = Swatch(blue, on: ground)
        expectClose(swatch.wash.light, blue.over(.white, alpha: Swatch.washStrength))
        expectClose(swatch.wash.dark, swatch.solid.dark.over(.black, alpha: Swatch.washStrength))
        expect(swatch.wash != Swatch(blue).wash)
        let lifted = Swatch(blue, raised: Tone(light: RGB(white: 0.9), dark: RGB(white: 0.3)))
        expectClose(lifted.surface.light, blue.over(RGB(white: 0.9), alpha: Swatch.surfaceStrength))
        expectClose(lifted.surface.dark, lifted.solid.dark.over(RGB(white: 0.3), alpha: Swatch.surfaceStrength))
    },
    test("where nothing reads, a color is black or white, whichever is away from the ground") {
        let gray = RGB(white: 0.5)
        expectClose(Swatch.reading(gray, against: [RGB(white: 0.8)], atLeast: 21), .black, within: 1e-4)
        expectClose(Swatch.reading(gray, against: [RGB(white: 0.2)], atLeast: 21), .white, within: 1e-4)
    },
])

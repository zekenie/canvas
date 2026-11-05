import Foundation
import Palette
import TestKit

@MainActor let oklchTests = Suite("OKLCH", [
    test("white is all lightness and no color, black none of either, and red where Oklab puts it") {
        let white = OKLCH(.white), black = OKLCH(.black), red = OKLCH(RGB(1, 0, 0))
        expectClose(CGFloat(white.lightness), 1, within: 1e-4)
        expectClose(CGFloat(white.chroma), 0, within: 1e-4)
        expectClose(CGFloat(black.lightness), 0)
        expectClose(CGFloat(black.chroma), 0)
        // Ottosson's reference values for sRGB red.
        expectClose(CGFloat(red.lightness), 0.628, within: 0.001)
        expectClose(CGFloat(red.chroma), 0.2577, within: 0.001)
        expectClose(CGFloat(red.hue * 180 / .pi), 29.23, within: 0.05)
    },
    test("every sRGB color comes back as itself") {
        for color in sampleColors {
            let there = OKLCH(color)
            expect(there.isDisplayable, "\(color.hexString) isn't displayable")
            expectClose(there.rgb, color, within: 1e-5)
        }
    },
    test("a gray has no chroma, and lighter grays are lighter") {
        var last = -1.0
        for white in stride(from: 0.0, through: 1.0, by: 0.05) {
            let gray = OKLCH(RGB(white: white))
            expect(gray.chroma < 1e-4, "gray \(white) has chroma \(gray.chroma)")
            expect(gray.lightness > last, "gray \(white) isn't lighter than the one before")
            last = gray.lightness
        }
    },
    test("a color too colorful for sRGB is shown as the most colorful of its lightness and hue") {
        for degrees in stride(from: 0.0, to: 360.0, by: 15) {
            for lightness in [0.2, 0.5, 0.8, 0.95] {
                let wanted = OKLCH(lightness: lightness, chroma: 0.4, hue: degrees * .pi / 180)
                expect(!wanted.isDisplayable, "\(degrees)° at \(lightness) is displayable at 0.4")
                let shown = wanted.rgb
                for component in [shown.red, shown.green, shown.blue] { expect(component >= 0 && component <= 1, "\(component) is out of range") }
                let back = OKLCH(shown)
                expectClose(CGFloat(back.lightness), CGFloat(lightness), within: 0.002)
                expect(back.chroma < 0.4 && back.chroma > 0.02, "chroma \(back.chroma) at \(degrees)°, \(lightness)")
                expect(degreesApart(back.hue, wanted.hue) < 0.5, "hue turned \(degreesApart(back.hue, wanted.hue))° at \(degrees)°, \(lightness)")
                // No more colorful color of that lightness and hue is displayable.
                expect(!OKLCH(lightness: lightness, chroma: back.chroma + 0.002, hue: wanted.hue).isDisplayable, "\(degrees)° at \(lightness) could be more colorful")
            }
        }
    },
    test("a lightness outside 0 to 1 is shown as black or white") {
        expectClose(OKLCH(lightness: -0.2, chroma: 0.1, hue: 1).rgb, .black, within: 1e-4)
        expectClose(OKLCH(lightness: 1.3, chroma: 0.1, hue: 1).rgb, .white, within: 1e-4)
    },
    test("a color muted toward a gray: none of the way is the color, all of it the gray, half of it half its chroma and half way there in lightness, its hue kept") {
        for color in sampleColors where OKLCH(color).chroma > 0.02 {
            let there = OKLCH(color), gray = 0.68
            expectClose(color.muted(by: 0, toward: gray), color, within: 1e-5)
            let all = OKLCH(color.muted(by: 1, toward: gray))
            expect(all.chroma < 1e-4, "\(color.hexString) all the way is no gray: chroma \(all.chroma)")
            expectClose(CGFloat(all.lightness), CGFloat(gray), within: 1e-4)
            let half = OKLCH(color.muted(by: 0.5, toward: gray))
            expectClose(CGFloat(half.lightness), CGFloat((there.lightness + gray) / 2), within: 1e-4)
            expectClose(CGFloat(half.chroma), CGFloat(there.chroma / 2), within: 1e-4)
            let turned = abs(remainder(half.hue - there.hue, 2 * .pi)) * 180 / .pi
            expect(turned < 0.5, "\(color.hexString) turned \(turned)° muted")
        }
    },
])

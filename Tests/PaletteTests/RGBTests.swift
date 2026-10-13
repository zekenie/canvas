import Foundation
import Palette
import TestKit

@MainActor let rgbTests = Suite("RGB", [
    test("a color is written #RRGGBB in capitals, and read from six digits or three, in either case") {
        expectEqual(RGB(hex: 0x4465E9).hexString, "#4465E9")
        expectEqual(RGB(hexString: "#4465E9"), RGB(hex: 0x4465E9))
        expectEqual(RGB(hexString: "#4465e9"), RGB(hex: 0x4465E9))
        expectEqual(RGB(hexString: "#46E"), RGB(hex: 0x4466EE))
        expectEqual(RGB(hexString: "#46e")?.hexString, "#4466EE")
        expectEqual(RGB.white.hexString, "#FFFFFF")
        expectEqual(RGB.black.hexString, "#000000")
        expectEqual(RGB(white: 0.5).hexString, "#808080")
        expectEqual(RGB(1.2, -0.1, 0.5).hexString, "#FF0080", "a component out of range is written as the nearest in it")
        expectEqual(RGB(.nan, 1, .infinity).hexString, "#00FFFF", "one that isn't a number as none of it")
    },
    test("what isn't a hex color reads as none: a name, no #, an alpha, other lengths, other characters") {
        for text in ["blue", "4465E9", "#4465E9FF", "#4465", "#44", "#", "", "#GGGGGG", "# 4465E", "#４４６５Ｅ９", "#-12345", "#+12"] {
            expect(RGB(hexString: text) == nil, "\(text) read as a color")
        }
    },
    test("every color written is read back as itself") {
        for color in sampleColors {
            let written = color.hexString
            expectEqual(RGB(hexString: written)?.hexString, written)
        }
    },
    test("luminance is 0 for black, 1 for white, and green's share is the largest") {
        expectClose(CGFloat(RGB.black.luminance), 0)
        expectClose(CGFloat(RGB.white.luminance), 1)
        expectClose(CGFloat(RGB(1, 0, 0).luminance), 0.2126)
        expectClose(CGFloat(RGB(0, 1, 0).luminance), 0.7152)
        expectClose(CGFloat(RGB(0, 0, 1).luminance), 0.0722)
        expectClose(CGFloat(RGB(white: 0.5).luminance), 0.2140, within: 0.0001)
    },
    test("contrast is 21 for black on white, 1 for a color on itself, and the same either way round") {
        expectClose(CGFloat(RGB.black.contrast(with: .white)), 21)
        expectClose(CGFloat(RGB.white.contrast(with: .black)), 21)
        for color in sampleColors {
            expectClose(CGFloat(color.contrast(with: color)), 1)
            expectClose(CGFloat(color.contrast(with: .white)), CGFloat(RGB.white.contrast(with: color)))
        }
        // WebAIM's figure for #767676 on white, the lightest gray that passes AA.
        expectClose(CGFloat(RGB(hex: 0x767676).contrast(with: .white)), 4.54, within: 0.01)
    },
    test("a color over a ground is the ground at none of it, itself at all of it, and between them between") {
        let blue = RGB(hex: 0x4465E9), ground = RGB(white: 0.965)
        expectClose(blue.over(ground, alpha: 0), ground)
        expectClose(blue.over(ground, alpha: 1), blue)
        expectClose(blue.over(ground, alpha: 0.5), RGB((blue.red + 0.965) / 2, (blue.green + 0.965) / 2, (blue.blue + 0.965) / 2))
    },
])

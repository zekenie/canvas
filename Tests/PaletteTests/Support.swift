import Foundation
import Palette
import TestKit

/// Colors across sRGB: a grid of its cube, corners and grays included, and a few a person would pick.
let sampleColors: [RGB] = {
    let steps = [0.0, 0.2, 0.4, 0.6, 0.8, 1.0]
    var colors: [RGB] = []
    for r in steps { for g in steps { for b in steps { colors.append(RGB(r, g, b)) } } }
    return colors + [0x4465E9, 0xF1AC4B, 0x099268, 0xE03131, 0xAE3EC9, 0xE16919, 0x9FA8B2, 0xFFD60A, 0x0A1A4A, 0x5856D6].map { RGB(hex: $0) }
}()

@MainActor
func expectClose(_ actual: RGB, _ expected: RGB, within tolerance: Double = 1e-6, _ message: @autoclosure () -> String = "",
                 file: StaticString = #fileID, line: UInt = #line) {
    let off = max(abs(actual.red - expected.red), abs(actual.green - expected.green), abs(actual.blue - expected.blue))
    expect(off <= tolerance, "\(actual.hexString) isn't \(expected.hexString) (off by \(off)) \(message())", file: file, line: line)
}

/// How far apart two hues are, in degrees.
func degreesApart(_ a: Double, _ b: Double) -> Double {
    let turn = 2 * Double.pi
    let difference = abs(a - b).truncatingRemainder(dividingBy: turn)
    return min(difference, turn - difference) * 180 / .pi
}

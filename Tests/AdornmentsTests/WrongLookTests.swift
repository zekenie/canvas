import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Geometry
import TestKit

// The look of a chip that says something is wrong (`AdornmentLabel.wrong()`): a red fill at 14%
// (22% hovered, 30% pressed) with no line inside the edge, its text and symbol red, and a wavy line
// under the text, in either appearance, drawn in the overlay. Alone: it knows nothing of what is wrong.

/// The system red in an appearance, as 0...255 (what the bitmap's pixels hold, near enough).
@MainActor func systemRed(dark: Bool) -> [Int] {
    var resolved: [Int] = []
    NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
        let color = NSColor(cgColor: NSColor.systemRed.cgColor)!.usingColorSpace(.deviceRGB)!
        resolved = [color.redComponent, color.greenComponent, color.blueComponent].map { Int(($0 * 255).rounded()) }
    }
    return resolved
}

/// How many pixels of a bitmap in a rect are red: red well above green and blue.
@MainActor func reds(_ rep: NSBitmapImageRep, in rect: CGRect) -> Int {
    stride(from: rect.minY, to: rect.maxY, by: 1).reduce(0) { count, y in
        count + stride(from: rect.minX, to: rect.maxX, by: 1).count {
            let color = pixel(rep, at: CGPoint(x: $0, y: y))
            return color[0] > color[1] + 40 && color[0] > color[2] + 40
        }
    }
}

@MainActor let wrongLookTests = Suite("A chip that says something is wrong", [
    test("a label says it is wrong, and each copy of it keeps that; wrong is part of what makes two labels equal") {
        let label = AdornmentLabel("Role")
        expectEqual(label.isWrong, false)
        let wrong = label.wrong()
        expectEqual(wrong.isWrong, true)
        expect(wrong != label)
        expectEqual(wrong, label.wrong())
        expectEqual(wrong.opacity(0.5).isWrong, true)
        expectEqual(wrong.tagged(AdornmentTag("a")).isWrong, true)
        expectEqual(wrong.missing().isWrong, true)
        expectEqual(wrong.brightSymbol().isWrong, true)
        expectEqual(wrong.tinted(solidTint), wrong, "a tint set after it does not change it: the red stays")
        expectEqual(label.tinted(solidTint).wrong(), label.wrong(), "and one set before it is replaced")
    },
    test("the fill is red at 14% over the canvas in both appearances, with no line at the edge, and the text is red") {
        let (h, _, frame) = try tintedBoard(AdornmentLabel("Role").wrong())
        let plain = try adornedHarness([Contributor(id: "none") { $0.forEveryShape { scope in
            scope.adornments(Chips.self) { _, _ in [] }
        } }])
        plain.add(Box(boxFrame))
        for dark in [false, true] {
            let drawn = render(h, dark: dark), canvas = render(plain, dark: dark)
            let red = systemRed(dark: dark)
            let under = pixel(canvas, at: capsulePoint(frame)), fill = pixel(drawn, at: capsulePoint(frame))
            var expected: [Int] = []
            for (canvas, color) in zip(under.prefix(3), red) { expected.append(Int((Double(canvas) * 0.86 + Double(color) * 0.14).rounded())) }
            expect(zip(fill, expected).allSatisfy { abs($0 - $1) <= 4 }, "0.14 of the red over the canvas, dark \(dark): \(fill) is not \(expected)")
            let edge = pixel(drawn, at: CGPoint(x: frame.midX, y: frame.minY + 1)), inside = pixel(drawn, at: CGPoint(x: frame.midX, y: frame.minY + 3))
            expect(zip(edge, inside).allSatisfy { abs($0 - $1) <= 4 } || reds(drawn, in: CGRect(x: frame.midX, y: frame.minY + 1, width: 1, height: 1)) == 0,
                   "no line of its own at the edge, dark \(dark): \(edge) against \(inside)")
            expect(reds(drawn, in: frame.insetBy(dx: 8, dy: 3)) > 15, "red text, dark \(dark)")
        }
    },
    test("a wavy line is drawn under the text, and nowhere under a chip that is only red") {
        let (h, _, frame) = try tintedBoard(AdornmentLabel("Role").wrong())
        let (g, _, _) = try tintedBoard(AdornmentLabel("Role").tinted(AdornmentTint(.systemRed, style: .light)))
        // The text is 11 points in a line 18 tall, centered, with no letter below its baseline: the wave is below.
        let band = CGRect(x: frame.minX + 8, y: frame.midY + 5, width: frame.width - 16, height: 2)
        for dark in [false, true] {
            let wave = reds(render(h, dark: dark), in: band), without = reds(render(g, dark: dark), in: band)
            expect(wave >= 8, "the wave, dark \(dark): \(wave)")
            expectEqual(without, 0, "and none without it, dark \(dark)")
        }
    },
    test("the wave runs as far as the text and no farther, and is red") {
        let (h, _, frame) = try tintedBoard(AdornmentLabel("Role").wrong())
        let band = CGRect(x: frame.minX, y: frame.midY + 5, width: frame.width, height: 2)
        let drawn = render(h)
        var first: CGFloat?, last: CGFloat?
        for x in stride(from: band.minX, to: band.maxX, by: 1) where reds(drawn, in: CGRect(x: x, y: band.minY, width: 1, height: band.height)) > 0 {
            first = first ?? x
            last = x
        }
        let start = try require(first), end = try require(last)
        expect(start >= frame.minX + 7 && start <= frame.minX + 9, "from the text's start (7 in): \(start - frame.minX)")
        expect(end >= frame.maxX - 9 && end <= frame.maxX - 6, "to its end: \(frame.maxX - end)")
    },
    test("a symbol before the text is red too") {
        let (h, _, frame) = try tintedBoard(AdornmentLabel("Role", systemImage: "curlybraces").wrong())
        let place = CGRect(x: frame.minX + 7, y: frame.minY + 2, width: 11, height: 14)
        expect(reds(render(h, dark: false), in: place) > 4, "light")
        expect(reds(render(h, dark: true), in: place) > 4, "dark, after a light frame")
        expect(reds(render(h, dark: false), in: place) > 4, "and back")
    },
    test("hovered and pressed the red is stronger") {
        let (h, _, frame) = try tintedBoard(AdornmentLabel("Role").wrong())
        let point = capsulePoint(frame)
        let normal = luminance(pixel(render(h), at: point))
        h.move(to: CGPoint(x: frame.midX, y: frame.midY))
        let hovered = luminance(pixel(render(h), at: point))
        h.press(at: CGPoint(x: frame.midX, y: frame.midY))
        let pressed = luminance(pixel(render(h), at: point))
        expect(pressed < hovered && hovered < normal, "\(pressed) < \(hovered) < \(normal)")
    },
    test("a symbol alone is a red disc with no wave, and a missing label stays missing") {
        let (h, _, frame) = try tintedBoard(AdornmentLabel(systemImage: "flag.fill").wrong())
        expect(reds(render(h), in: frame.insetBy(dx: 3, dy: 3)) > 4, "the symbol in red")
        let (g, _, rect) = try tintedBoard(AdornmentLabel("Gone").missing().wrong())
        let plain = try adornedHarness([Contributor(id: "none") { $0.forEveryShape { scope in
            scope.adornments(Chips.self) { _, _ in [] }
        } }])
        plain.add(Box(boxFrame))
        expectEqual(pixel(render(g), at: capsulePoint(rect)), pixel(render(plain), at: capsulePoint(rect)), "no fill")
        expectEqual(reds(render(g), in: CGRect(x: rect.minX + 8, y: rect.midY + 5, width: rect.width - 16, height: 2)), 0, "and no wave")
    },
    test("it is drawn in its frame and nowhere else, and its width is the same as the chip's without it") {
        let (h, _, frame) = try tintedBoard(AdornmentLabel("Role").wrong())
        let (g, _, plainFrame) = try tintedBoard(AdornmentLabel("Role"))
        expectEqual(frame, plainFrame, "laid out as any chip")
        let empty = try adornedHarness([Contributor(id: "none") { $0.forEveryShape { scope in
            scope.adornments(Chips.self) { _, _ in [] }
        } }])
        empty.add(Box(boxFrame))
        let inside = changedPixels(render(empty), render(h), in: frame.insetBy(dx: -1, dy: -1).integral)
        expect(inside > 100, "draws: \(inside)")
        expectEqual(changedPixels(render(empty), render(h), in: wholeView) - inside, 0, "nowhere else")
        _ = g
    },
    test("a wrong chip's compact face is plain unless its maker made it wrong, as a tint's is") {
        let label = AdornmentLabel("Relationship").compact(AdornmentLabel(systemImage: "flag.fill")).wrong()
        expectEqual(label.isWrong, true)
        expectEqual(label.compactFace?.isWrong, false)
        expectEqual(AdornmentLabel("A").compact(AdornmentLabel("B").wrong()).compactFace?.isWrong, true)
    },
])

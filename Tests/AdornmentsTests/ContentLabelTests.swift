import Adornments
import AppKit
import CanvasTesting
import TestKit

// A label drawn in a shape's content (`AdornmentLabel.draw(at:in:)`, `contentSize`): the chip of a
// type in a row of fields. Drawn into a bitmap, no canvas.

private let blue = NSColor(srgbRed: 0.10, green: 0.40, blue: 0.90, alpha: 1)
/// An ink that follows the appearance, as a type's: dark on the light canvas, light on the dark.
private let followingInk = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.95, alpha: 1) : NSColor(white: 0.1, alpha: 1) }
private let lightBlue = AdornmentTint(blue, ink: followingInk, style: .light)
private let paperWhite = NSColor.white
private let paperYellow = NSColor(srgbRed: 1.0, green: 0.87, blue: 0.45, alpha: 1)

/// `label` drawn at (20, 10) on `paper` in a 240 by 60 bitmap, `scale` times as big, under the appearance
/// the drawing is made in (the canvas's).
@MainActor private func drawn(_ label: AdornmentLabel, on paper: NSColor = paperWhite, dark: Bool = false, scale: CGFloat = 1) -> NSBitmapImageRep {
    let size = CGSize(width: 240, height: 60)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let cg = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    cg.translateBy(x: 0, y: size.height)
    cg.scaleBy(x: 1, y: -1)
    NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
        cg.setFillColor(paper.cgColor)
        cg.fill(CGRect(origin: .zero, size: size))
        cg.scaleBy(x: scale, y: scale)
        label.draw(at: CGPoint(x: 20, y: 10), in: cg)
    }
    return rep
}

/// The box of the pixels that differ from the paper's, in pixels.
@MainActor private func inked(_ rep: NSBitmapImageRep, on paper: [Int] = [255, 255, 255, 255]) -> CGRect {
    var box = CGRect.null
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide where pixel(rep, at: CGPoint(x: x, y: y)) != paper {
            box = box.union(CGRect(x: x, y: y, width: 1, height: 1))
        }
    }
    return box
}

private func relativeLuminance(_ color: [Int]) -> Double {
    func linear(_ value: Int) -> Double {
        let c = Double(value) / 255
        return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(color[0]) + 0.7152 * linear(color[1]) + 0.0722 * linear(color[2])
}

private func contrast(_ a: [Int], _ b: [Int]) -> Double {
    let (hi, lo) = (max(relativeLuminance(a), relativeLuminance(b)), min(relativeLuminance(a), relativeLuminance(b)))
    return (hi + 0.05) / (lo + 0.05)
}

@MainActor let contentLabelTests = Suite("A label drawn in content", [
    test("a tinted label has its capsule at the point, as big as contentSize says, and nothing outside it") {
        let label = AdornmentLabel("Person").tinted(lightBlue)
        let size = label.contentSize
        expectEqual(size.height, 18)
        expect(size.width > 30, "a chip is wider than its padding: \(size.width)")
        let box = inked(drawn(label))
        expect(abs(box.minX - 20) <= 1 && abs(box.minY - 10) <= 1, "its top left is the point: \(box)")
        expect(abs(box.width - size.width) <= 1 && abs(box.height - size.height) <= 1, "its size is contentSize: \(box) against \(size)")
    },
    test("drawn at twice the scale it is twice the size") {
        let label = AdornmentLabel("Person").tinted(lightBlue)
        let one = inked(drawn(label)), two = inked(drawn(label, scale: 2))
        expect(abs(two.width - 2 * one.width) <= 2 && abs(two.height - 2 * one.height) <= 2, "\(one) against \(two)")
    },
    test("a missing label is dashed: no fill inside, the stroke broken along its top edge") {
        let label = AdornmentLabel("Room with a longer name").missing()
        let rep = drawn(label)
        expectEqual(pixel(rep, at: CGPoint(x: 24, y: 19)), [255, 255, 255, 255], "no fill")
        let width = Int(label.contentSize.width)
        let changed = (32..<(20 + width - 12)).filter { x in [9, 10].contains { y in pixel(rep, at: CGPoint(x: x, y: y)) != [255, 255, 255, 255] } }.count
        let share = Double(changed) / Double(20 + width - 12 - 32)
        expect(share > 0.3 && share < 0.8, "dashed: \(share)")
    },
    test("the same label twice makes one face") {
        #if DEBUG
        let label = AdornmentLabel("Same twice, once made").tinted(lightBlue)
        let before = AdornmentContentCounts.facesMade
        _ = label.contentSize
        _ = drawn(label)
        _ = drawn(label, scale: 2)
        expectEqual(AdornmentContentCounts.facesMade - before, 1)
        #endif
    },
    test("a light-tinted and a missing label come out the same under the dark appearance as under the light") {
        for label in [AdornmentLabel("Person").tinted(lightBlue), AdornmentLabel("Gone").missing(), AdornmentLabel("Gone").tinted(lightBlue).missing()] {
            let light = drawn(label), dark = drawn(label, dark: true)
            let box = inked(light)
            expectEqual(changedPixels(light, dark, in: CGRect(x: 0, y: 0, width: 240, height: 60)), 0, "\(label.text ?? ""): \(box)")
        }
    },
    test("a tinted label's ink reads at 4.5 to 1 on white and on a note's yellow, in either appearance") {
        let label = AdornmentLabel("Person").tinted(lightBlue)
        for (paper, color) in [(paperWhite, [255, 255, 255, 255]), (paperYellow, [255, 222, 115, 255])] {
            for dark in [false, true] {
                let rep = drawn(label, on: paper, dark: dark)
                var darkest = color
                for y in 12..<26 {
                    for x in 28..<(20 + Int(label.contentSize.width) - 8) {
                        let value = pixel(rep, at: CGPoint(x: x, y: y))
                        if relativeLuminance(value) < relativeLuminance(darkest) { darkest = value }
                    }
                }
                expect(contrast(darkest, color) >= 4.5, "dark \(dark): \(darkest) on \(color)")
            }
        }
    },
    test("a label drawn whole at a scale (a field's empty pill) is its chip at that scale; its chip alone is as wide as asked, its symbol in it and no text") {
        let size = CGSize(width: 240, height: 60)
        func bitmap(_ draw: (CGContext) -> Void) -> NSBitmapImageRep {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let cg = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: 1, y: -1)
            NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
                cg.setFillColor(paperWhite.cgColor)
                cg.fill(CGRect(origin: .zero, size: size))
                draw(cg)
            }
            return rep
        }
        let label = AdornmentLabel("Table", systemImage: "tablecells").tinted(lightBlue)
        let one = inked(bitmap { label.draw(at: CGPoint(x: 20, y: 10), scale: 1, in: $0) }), two = inked(bitmap { label.draw(at: CGPoint(x: 20, y: 10), scale: 2, in: $0) })
        expect(abs(one.minX - 20) <= 1 && abs(one.minY - 10) <= 1 && abs(one.height - 18) <= 1, "its top left is the point, a pill tall: \(one)")
        expect(abs(two.width - 2 * one.width) <= 2 && abs(two.height - 2 * one.height) <= 2, "twice the scale, twice the size: \(one) against \(two)")
        let chip = bitmap { label.drawChip(width: 60, at: CGPoint(x: 20, y: 10), scale: 1, in: $0) }, box = inked(chip)
        expect(abs(box.minX - 20) <= 1 && abs(box.width - 60) <= 1 && abs(box.height - 18) <= 1, "as wide as asked: \(box)")
        let wide = inked(bitmap { label.drawChip(width: 120, at: CGPoint(x: 20, y: 10), scale: 1, in: $0) })
        expect(abs(wide.width - 120) <= 1, "and no wider than that: \(wide)")
        // No text in it: the pixels past its symbol, in the middle of a wide chip, are the capsule's alone.
        let middle = pixel(bitmap { label.drawChip(width: 120, at: CGPoint(x: 20, y: 10), scale: 1, in: $0) }, at: CGPoint(x: 100, y: 19))
        let edge = pixel(bitmap { label.drawChip(width: 120, at: CGPoint(x: 20, y: 10), scale: 1, in: $0) }, at: CGPoint(x: 120, y: 12))
        expectEqual(middle, edge, "no text over the capsule")
    },
])

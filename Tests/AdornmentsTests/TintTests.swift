import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Geometry
import TestKit

// A tinted label (`AdornmentLabel.tinted(_:)`): a capsule in a fixed color, solid or light, text and
// symbol in white or the tint's ink, hovered and pressed in order, and a plain label drawn as ever.

let tintColor = NSColor(srgbRed: 0.10, green: 0.40, blue: 0.90, alpha: 1)
/// An ink that follows the appearance: near black on the light canvas, near white on the dark.
let tintInk = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.92, alpha: 1) : NSColor(white: 0.08, alpha: 1) }
let solidTint = AdornmentTint(tintColor, style: .solid)
let lightTint = AdornmentTint(tintColor, ink: tintInk, style: .light)

/// The board drawn in either appearance (`render(_:)` is the light one).
@MainActor func render(_ h: EditorHarness, dark: Bool) -> NSBitmapImageRep {
    let size = wholeView.size
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let cg = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    cg.translateBy(x: 0, y: size.height)
    cg.scaleBy(x: 1, y: -1)
    NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        h.editor.draw(in: cg, bounds: CGRect(origin: .zero, size: size), dirtyRect: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
    }
    return rep
}

let tintTag = AdornmentTag("tinted")

/// A box with one chip, `label` tagged `tintTag`, and the chip's frame in view points.
@MainActor func tintedBoard(_ label: AdornmentLabel) throws -> (h: EditorHarness, box: ShapeID, frame: CGRect) {
    let h = try adornedHarness([Contributor(id: "tinted") { $0.adornmentsForEveryShape(Chips.self) { _, _ in [label.tagged(tintTag)] } }])
    let box = h.add(Box(boxFrame))
    return (h, box, h.editor.camera.toView(try require(h.editor.rects(box).first)))
}

/// A point inside the capsule's left end, before its text.
func capsulePoint(_ frame: CGRect) -> CGPoint { CGPoint(x: frame.minX + 4, y: frame.midY) }

func luminance(_ color: [Int]) -> Int { color.prefix(3).reduce(0, +) / 3 }

/// The darkest and the lightest pixel of a bitmap in a rect: where text is, away from the capsule.
@MainActor func extremes(_ rep: NSBitmapImageRep, in rect: CGRect) -> (darkest: Int, lightest: Int) {
    var darkest = 255, lightest = 0
    for y in stride(from: rect.minY, to: rect.maxY, by: 1) {
        for x in stride(from: rect.minX, to: rect.maxX, by: 1) {
            let value = luminance(pixel(rep, at: CGPoint(x: x, y: y)))
            darkest = min(darkest, value)
            lightest = max(lightest, value)
        }
    }
    return (darkest, lightest)
}

@MainActor let tintTests = Suite("A tinted adornment", [
    test("a label says its tint, and each copy of it keeps it") {
        let label = AdornmentLabel("Person")
        expectEqual(label.tint, nil)
        let tinted = label.tinted(solidTint)
        expectEqual(tinted.tint, solidTint)
        expectEqual(tinted.opacity(0.5).tint, solidTint)
        expectEqual(tinted.tagged(AdornmentTag("a")).tint, solidTint)
        expectEqual(tinted.missing().tint, solidTint, "and a missing one ignores it when drawn")
        expectEqual(tinted.brightSymbol().tint, solidTint)
    },
    test("a tint, and a label's, are equal and hash by color, ink and style") {
        let label = AdornmentLabel("Person")
        expect(label.tinted(solidTint) != label)
        expect(label.tinted(solidTint) != label.tinted(lightTint))
        expect(label.tinted(solidTint) != label.tinted(AdornmentTint(.systemRed, style: .solid)))
        expectEqual(label.tinted(solidTint), label.tinted(AdornmentTint(tintColor, style: .solid)))
        expectEqual(label.tinted(solidTint).hashValue, label.tinted(AdornmentTint(tintColor, style: .solid)).hashValue)
        expect(label.tinted(solidTint).hashValue != label.hashValue)
        expectEqual(AdornmentTint(tintColor, style: .light).ink, tintColor, "the ink is the color by default")
    },
    test("a compact face is tinted only if whoever made it tinted it") {
        let face = AdornmentLabel(systemImage: "flag.fill")
        expectEqual(AdornmentLabel("Flag").tinted(solidTint).compact(face).compactFace?.tint, nil)
        expectEqual(AdornmentLabel("Flag").compact(face.tinted(solidTint)).compactFace?.tint, solidTint)
    },
    test("a solid label's capsule is its color, in both appearances, and its text is white") {
        let (h, _, frame) = try tintedBoard(AdornmentLabel("Person").tinted(solidTint))
        for dark in [false, true] {
            let drawn = render(h, dark: dark)
            let fill = pixel(drawn, at: capsulePoint(frame))
            expect(zip(fill, [26, 102, 230]).allSatisfy { abs($0 - $1) <= 4 }, "dark \(dark): \(fill)")
            expectEqual(extremes(drawn, in: frame.insetBy(dx: 8, dy: 4)).lightest > 235, true, "white text, dark \(dark)")
        }
    },
    test("a light label's capsule is its color at 0.14 over the canvas, with a line at the edge, and its text is the ink") {
        let (h, box, frame) = try tintedBoard(AdornmentLabel("Person").tinted(lightTint))
        let plain = try adornedHarness([Contributor(id: "none") { $0.adornmentsForEveryShape(Chips.self) { _, _ in [] } }])
        plain.add(Box(boxFrame))
        for dark in [false, true] {
            let drawn = render(h, dark: dark), canvas = render(plain, dark: dark)
            let under = pixel(canvas, at: capsulePoint(frame)), fill = pixel(drawn, at: capsulePoint(frame))
            var expected: [Int] = []
            for (canvas, color) in zip(under.prefix(3), [26, 102, 230]) { expected.append(Int((Double(canvas) * 0.86 + Double(color) * 0.14).rounded())) }
            expect(zip(fill, expected).allSatisfy { abs($0 - $1) <= 3 }, "0.14 of the color over the canvas, dark \(dark): \(fill) is not \(expected)")
            let edge = pixel(drawn, at: CGPoint(x: frame.midX, y: frame.minY))
            expect(edge != fill && edge[2] > fill[2] - 1 || edge != fill, "a line at the edge, dark \(dark): \(edge) against \(fill)")
            let text = extremes(drawn, in: frame.insetBy(dx: 8, dy: 4))
            if dark { expect(text.lightest > 200, "the dark ink is light: \(text)") } else { expect(text.darkest < 60, "the light ink is dark: \(text)") }
        }
        _ = box
    },
    test("a light label's text changes with the appearance with no new layout") {
        let (h, _, frame) = try tintedBoard(AdornmentLabel("Person").tinted(lightTint))
        _ = render(h, dark: false)
        #if DEBUG
        let made = h.editor.adornmentFacesMade
        #endif
        _ = render(h, dark: true)
        #if DEBUG
        expectEqual(h.editor.adornmentFacesMade, made, "the face was kept")
        #endif
        expectEqual(h.editor.camera.toView(try require(h.editor.rects(h.editor.document.shapes[0].id).first)), frame)
    },
    test("hovered a solid label is lighter and pressed darker; a light one hovered and pressed is the color stronger") {
        for (tint, name) in [(solidTint, "solid"), (lightTint, "light")] {
            let (h, _, frame) = try tintedBoard(AdornmentLabel("Person").tinted(tint))
            let point = capsulePoint(frame)
            let normal = luminance(pixel(render(h), at: point))
            h.move(to: CGPoint(x: frame.midX, y: frame.midY))
            let hovered = luminance(pixel(render(h), at: point))
            h.press(at: CGPoint(x: frame.midX, y: frame.midY))
            let pressed = luminance(pixel(render(h), at: point))
            if tint.style == .solid {
                expect(pressed < normal && normal < hovered, "\(name): \(pressed) < \(normal) < \(hovered)")
            } else {
                // The color is darker than the canvas: more of it is darker.
                expect(pressed < hovered && hovered < normal, "\(name): \(pressed) < \(hovered) < \(normal)")
            }
        }
    },
    test("a tint beats a tone, and a missing label ignores it") {
        let (h, _, frame) = try tintedBoard(AdornmentLabel("Done", tone: .success).tinted(solidTint))
        let fill = pixel(render(h), at: capsulePoint(frame))
        expect(zip(fill, [26, 102, 230]).allSatisfy { abs($0 - $1) <= 4 }, "the tint, not green: \(fill)")
        let (g, _, rect) = try tintedBoard(AdornmentLabel("Gone").tinted(solidTint).missing())
        let plain = try adornedHarness([Contributor(id: "none") { $0.adornmentsForEveryShape(Chips.self) { _, _ in [] } }])
        plain.add(Box(boxFrame))
        expectEqual(pixel(render(g), at: capsulePoint(rect)), pixel(render(plain), at: capsulePoint(rect)), "no fill")
    },
    test("a light label's symbol is in the ink, in both appearances, drawn after the other") {
        let (h, _, frame) = try tintedBoard(AdornmentLabel("Person", systemImage: "curlybraces").tinted(lightTint))
        let place = CGRect(x: frame.minX + 7, y: frame.minY + 2, width: 11, height: 14)
        let light = extremes(render(h, dark: false), in: place), dark = extremes(render(h, dark: true), in: place)
        expect(light.darkest < 80, "dark in light: \(light)")
        expect(dark.lightest > 180, "light in dark, after a light frame: \(dark)")
        let again = extremes(render(h, dark: false), in: place)
        expect(again.darkest < 80, "and back: \(again)")
    },
    test("a solid label's symbol is white") {
        let (h, _, frame) = try tintedBoard(AdornmentLabel("Person", systemImage: "curlybraces").tinted(solidTint))
        let place = CGRect(x: frame.minX + 7, y: frame.minY + 2, width: 11, height: 14)
        let white = extremes(render(h, dark: false), in: place).lightest
        expect(white > 190, "white on the color: \(white)")
    },
    test("a placeholder's text is dimmed on both") {
        for tint in [solidTint, lightTint] {
            let (h, _, frame) = try tintedBoard(AdornmentLabel(placeholder: "Untitled").tinted(tint))
            let (g, _, _) = try tintedBoard(AdornmentLabel("Untitled").tinted(tint))
            let text = frame.insetBy(dx: 8, dy: 4)
            let dim = extremes(render(h), in: text), full = extremes(render(g), in: text)
            if tint.style == .solid { expect(dim.lightest < full.lightest, "dimmer white: \(dim) < \(full)") } else { expect(dim.darkest > full.darkest, "fainter ink: \(dim) > \(full)") }
        }
    },
    test("an untinted label is drawn as it was: the neutral gray, white text") {
        let (h, _, frame) = try tintedBoard(AdornmentLabel("Person"))
        let fill = pixel(render(h), at: capsulePoint(frame))
        expect(fill.prefix(3).allSatisfy { abs($0 - fill[0]) <= 2 && $0 < 100 }, "dark gray: \(fill)")
    },
    test("the \"+N\" of a group of tinted chips is gray") {
        let names = ["Alexander", "Benjamin", "Charlotte", "Dominique"]
        let h = try adornedHarness([Contributor(id: "tinted") { $0.adornmentsForEveryShape(Chips.self) { _, _ in names.map { chip($0).tinted(solidTint) } } }])
        h.editor.camera = Camera(origin: .zero, zoom: 1)
        let widths = try boxWithChips(names, width: 600).frames.map(\.rect.width)
        let box = h.add(Box(CGRect(x: 100, y: 100, width: widths[0] + widths[1] + 8 + widths[2] - 1, height: 120)))
        let frames = h.editor.adornmentFrames(of: box)
        let more = try require(frames.last)
        expectEqual(more.isOverflow, true)
        let rect = h.editor.camera.toView(more.rect)
        let fill = pixel(render(h), at: capsulePoint(rect))
        expect(fill.prefix(3).allSatisfy { abs($0 - fill[0]) <= 2 }, "gray: \(fill)")
        let first = pixel(render(h), at: capsulePoint(h.editor.camera.toView(frames[0].rect)))
        expect(first[2] > first[0] + 100, "and the chips are blue: \(first)")
    },
])

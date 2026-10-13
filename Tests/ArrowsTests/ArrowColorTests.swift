import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Colors
import Connections
import CoreGraphics
import Geometry
import Mentions
import Palette
import TestKit

// An arrow with a color: its line and heads are the color's solid and its label's text the color's
// ink, in either appearance; zoomed out, the solid; with none (or a name the file lacks), as an
// arrow always looked.

private let canvas = CGSize(width: 600, height: 400)
private let scale: CGFloat = 2
private let pale = ShapeColor("#FFF176")!
private let deep = ShapeColor("#1B2A6B")!
private let paleRGB = RGB(hexString: "#FFF176")!
private let deepRGB = RGB(hexString: "#1B2A6B")!

/// The canvas in either appearance, `scale` pixels to a point.
@MainActor private func drawn(_ editor: CanvasEditor, dark: Bool, size: CGSize = canvas) throws -> NSBitmapImageRep {
    let rep = try require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let cg = try require(NSGraphicsContext(bitmapImageRep: rep)).cgContext
    cg.translateBy(x: 0, y: size.height * scale)
    cg.scaleBy(x: scale, y: -scale)
    try require(NSAppearance(named: dark ? .darkAqua : .aqua)).performAsCurrentDrawingAppearance {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        let bounds = CGRect(origin: .zero, size: size)
        editor.draw(in: cg, bounds: bounds, dirtyRect: bounds)
        NSGraphicsContext.restoreGraphicsState()
    }
    return rep
}

/// A free arrow from (100, 200) to (500, 200), with a head at its end, and `text`, at `zoom`.
@MainActor private func arrowHarness(text: String = "", zoom: CGFloat = 1) throws -> (EditorHarness, ShapeID) {
    let h = try EditorHarness(plugins: arrowsPlugins())
    let id = h.add(Arrow(start: .free(CGPoint(x: 100, y: 200)), end: .free(CGPoint(x: 500, y: 200)), text: MentionText(plain: text)))
    h.editor.camera = Camera(origin: .zero, zoom: zoom)
    return (h, id)
}

/// Whether a pixel is `color`, to a step of rounding.
@MainActor private func expectPixel(_ pixel: [Int], _ color: RGB, _ message: @autoclosure () -> String = "",
                                    file: StaticString = #fileID, line: UInt = #line) {
    let wanted = [color.red, color.green, color.blue].map { Int(($0 * 255).rounded()) }
    let off = zip(pixel.prefix(3), wanted).map { abs($0 - $1) }.max() ?? 255
    expect(off <= 1, "\(Array(pixel.prefix(3))) isn't \(wanted) \(message())", file: file, line: line)
}

@MainActor private func solid(_ h: EditorHarness, _ color: ShapeColor, dark: Bool) throws -> RGB {
    try require(h.editor.colors?.swatch(for: color)).solid[dark: dark]
}

@MainActor private func ink(_ h: EditorHarness, _ color: ShapeColor, dark: Bool) throws -> RGB {
    try require(h.editor.colors?.swatch(for: color)).ink[dark: dark]
}

/// Whether some pixel of a rect (in points) is `color`, to a step or two of rounding.
@MainActor private func has(_ rep: NSBitmapImageRep, _ color: RGB, in rect: CGRect, within step: Int = 2) -> Bool {
    let wanted = [color.red, color.green, color.blue].map { Int(($0 * 255).rounded()) }
    for y in stride(from: rect.minY, to: rect.maxY, by: 0.5) {
        for x in stride(from: rect.minX, to: rect.maxX, by: 0.5) {
            let found = pixel(rep, at: CGPoint(x: x, y: y), scale: scale)
            if zip(found.prefix(3), wanted).allSatisfy({ abs($0 - $1) <= step }) { return true }
        }
    }
    return false
}

private let linePoint = CGPoint(x: 200, y: 200)
/// Where a head's wing is, beside the line, 8 back from its tip.
private let wing = CGRect(x: 484, y: 192, width: 14, height: 6)

@MainActor let arrowColorTests = Suite("An arrow's color", [
    test("an arrow with no color is as it always looked: near-black in the light, near-white in the dark") {
        let (h, _) = try arrowHarness()
        expectEqual(pixel(try drawn(h.editor, dark: false), at: linePoint, scale: scale).prefix(3).map { $0 }, [28, 28, 28], "light")
        expectEqual(pixel(try drawn(h.editor, dark: true), at: linePoint, scale: scale).prefix(3).map { $0 }, [235, 235, 235], "dark")
    },
    test("a named color and a hex value give the line and the heads the color's solid, in each appearance") {
        for (color, label) in [(ShapeColor.blue, "blue"), (pale, "pale hex"), (deep, "deep hex")] {
            let (h, id) = try arrowHarness()
            h.editor.setColor(color, of: [id])
            for dark in [false, true] {
                let rep = try drawn(h.editor, dark: dark), want = try solid(h, color, dark: dark)
                expectPixel(pixel(rep, at: linePoint, scale: scale), want, "\(label) line, dark \(dark)")
                expect(has(rep, want, in: wing), "\(label) head, dark \(dark)")
            }
        }
    },
    test("a pale color is darkened on the light canvas and a dark one lightened on the dark") {
        let (h, _) = try arrowHarness()
        expect(try solid(h, pale, dark: false).luminance < paleRGB.luminance, "pale, light")
        expect(try solid(h, deep, dark: true).luminance > deepRGB.luminance, "deep, dark")
    },
    test("its label's text is the color's ink, in each appearance") {
        for color in [ShapeColor.blue, pale, deep] {
            let (h, id) = try arrowHarness(text: "HHHHHH")
            h.editor.setColor(color, of: [id])
            let label = try require(h.editor.shapeContext.geometry(of: id)?.label)
            for dark in [false, true] {
                expect(has(try drawn(h.editor, dark: dark), try ink(h, color, dark: dark), in: label.insetBy(dx: 4, dy: 4), within: 3),
                       "ink of \(color.text), dark \(dark)")
            }
        }
    },
    test("zoomed out, its skeleton is the solid") {
        for color in [ShapeColor.blue, pale, deep] {
            let (h, id) = try arrowHarness(zoom: 0.3)
            h.editor.setColor(color, of: [id])
            for dark in [false, true] {
                let rep = try drawn(h.editor, dark: dark)
                expectPixel(pixel(rep, at: CGPoint(x: 60, y: 60), scale: scale), try solid(h, color, dark: dark), "\(color.text), dark \(dark)")
            }
        }
        let (plain, _) = try arrowHarness(zoom: 0.3)
        expectEqual(pixel(try drawn(plain.editor, dark: false), at: CGPoint(x: 60, y: 60), scale: scale).prefix(3).map { $0 }, [28, 28, 28], "plain")
    },
    test("Change Color is one step: taking it away draws the arrow plain, undo gives it back") {
        let (h, id) = try arrowHarness()
        h.editor.setColor(.blue, of: [id])
        let blue = try solid(h, .blue, dark: false)
        expectPixel(pixel(try drawn(h.editor, dark: false), at: linePoint, scale: scale), blue, "blue")
        h.editor.setColor(nil, of: [id])
        expectEqual(pixel(try drawn(h.editor, dark: false), at: linePoint, scale: scale).prefix(3).map { $0 }, [28, 28, 28], "plain")
        h.editor.undo()
        expectPixel(pixel(try drawn(h.editor, dark: false), at: linePoint, scale: scale), blue, "and back")
    },
    test("a name the file lacks draws plain") {
        let (h, id) = try arrowHarness()
        h.editor.setColor(ShapeColor("nonesuch"), of: [id])
        expectEqual(pixel(try drawn(h.editor, dark: false), at: linePoint, scale: scale).prefix(3).map { $0 }, [28, 28, 28], "light")
        expectEqual(pixel(try drawn(h.editor, dark: true), at: linePoint, scale: scale).prefix(3).map { $0 }, [235, 235, 235], "dark")
    },
])

import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Colors
import Frames
import Geometry
import Palette
import TestKit

// A frame's color: none, the neutral surface and hairline as always; a color, its surface inside and
// its solid on the border, in each appearance, in full and zoomed out. A frame at `frameRect` (100,
// 100, 400 × 300), at 100% from the origin unless a test zooms.

private let plain = [255, 255, 255]
private let spotInside = CGPoint(x: 300, y: 250), spotBorder = CGPoint(x: 300, y: 100)

@MainActor private func swatch(_ h: EditorHarness, _ color: ShapeColor) throws -> Swatch {
    try require(h.editor.colors?.swatch(for: color), "a swatch for \(color.text)")
}

@MainActor private func expectColored(_ drawn: NSBitmapImageRep, _ swatch: Swatch, dark: Bool, inside: CGPoint, border: CGPoint, _ what: String) {
    expectPixel(pixel(drawn, at: inside), swatch.surface[dark: dark], "\(what): its surface, dark \(dark)")
    expectPixel(pixel(drawn, at: border), swatch.solid[dark: dark], "\(what): its border, dark \(dark)")
}

@MainActor private func expectPixel(_ actual: [Int], _ color: RGB, _ what: String) {
    let wanted = [color.red, color.green, color.blue].map { Int(($0 * 255).rounded()) }
    expectColor(actual, wanted, "\(what) (\(color.hexString))", within: 2)
}

@MainActor let frameColorTests = Suite("A frame's color", [
    test("a frame with no color is as it was, in both appearances") {
        let h = try frameHarness()
        h.addFrame()
        expectColor(pixel(render(h.editor), at: spotInside), plain, "light surface")
        expectColor(pixel(render(h.editor), at: spotBorder), [224, 224, 224], "light border", within: 4)
        expectColor(pixel(render(h.editor, dark: true), at: spotInside), [38, 38, 38], "dark surface")
    },
    test("a named color and a hex value: the surface inside and the solid on the border, light and dark") {
        for color in [ShapeColor.blue, try require(ShapeColor("#E8590C"))] {
            let h = try frameHarness()
            let id = h.addFrame()
            h.editor.setColor(color, of: [id])
            let swatch = try swatch(h, color)
            for dark in [false, true] {
                expectColored(render(h.editor, dark: dark), swatch, dark: dark, inside: spotInside, border: spotBorder, color.text)
            }
        }
    },
    test("zoomed out, it keeps its color: its surface, and its solid in the ring") {
        let h = try frameHarness()
        let id = h.addFrame()
        h.editor.setColor(.green, of: [id])
        h.editor.camera = Camera(origin: .zero, zoom: 0.3)
        let swatch = try swatch(h, .green)
        for dark in [false, true] {
            expectColored(render(h.editor, dark: dark), swatch, dark: dark, inside: CGPoint(x: 90, y: 75), border: CGPoint(x: 30, y: 75), "30%")
        }
    },
    test("no color puts the plain look back, and undo the color") {
        let h = try frameHarness()
        let id = h.addFrame()
        h.editor.setColor(.red, of: [id])
        let swatch = try swatch(h, .red)
        expectPixel(pixel(render(h.editor), at: spotInside), swatch.surface[dark: false], "colored")
        h.editor.setColor(nil, of: [id])
        expectColor(pixel(render(h.editor), at: spotInside), plain, "taken away")
        h.editor.undo()
        expectPixel(pixel(render(h.editor), at: spotInside), swatch.surface[dark: false], "undone")
    },
    test("a name the file lacks draws plain") {
        let h = try frameHarness()
        var frame = ShapeRecord(Frame(frame: frameRect))
        frame[ColorProperty.self] = .named("chartreuse-nowhere")
        h.editor.transact { $0.insert(frame) }
        expectColor(pixel(render(h.editor), at: spotInside), plain, "its surface")
        expectColor(pixel(render(h.editor), at: spotBorder), [224, 224, 224], "its border", within: 4)
    },
])

import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Colors
import Palette
import Subboards
import TestKit

// A card's color: its border and the empty card's symbol are the color's solid, the card its surface,
// in the light and the dark, in full and as a skeleton. With none it is indigo, as it always was.

private let canvas = CGSize(width: 320, height: 240)
private let border = CGPoint(x: 279, y: 120), inside = CGPoint(x: 250, y: 100), skeletonBorder = CGPoint(x: 40, y: 120)

/// The editor with one subboard at `cardFrame` holding `color`, zoomed out when `skeleton`.
@MainActor private func colored(_ color: ShapeColor?, skeleton: Bool = false) throws -> EditorHarness {
    var sub = ShapeRecord(id: ShapeID(), Subboard(frame: cardFrame))
    sub[ColorProperty.self] = color
    let h = try EditorHarness(plugins: subboardPlugins(), file: CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(sub)])))
    if skeleton { h.editor.skeletonZoom = 1.01 }
    return h
}

@MainActor private func draw(_ editor: CanvasEditor, dark: Bool) -> NSBitmapImageRep {
    dark ? renderDark(editor, size: canvas) : renderBitmap(editor, size: canvas)
}

/// The brightest blue minus red in `rect`, for a symbol drawn in a color.
@MainActor private func nearest(_ bitmap: NSBitmapImageRep, to color: RGB, in rect: CGRect) -> Int {
    let wanted = rgb(color)
    var best = 255
    for y in stride(from: rect.minY, to: rect.maxY, by: 1) {
        for x in stride(from: rect.minX, to: rect.maxX, by: 1) {
            let p = pixel(bitmap, at: CGPoint(x: x, y: y))
            best = min(best, zip(p.prefix(3), wanted).map { abs($0 - $1) }.max() ?? 255)
        }
    }
    return best
}

private func rgb(_ color: RGB) -> [Int] { [color.red, color.green, color.blue].map { Int(($0 * 255).rounded()) } }

@MainActor private func expectNear(_ pixel: [Int], _ color: RGB, _ what: String, file: StaticString = #fileID, line: UInt = #line) {
    expectColor(pixel, rgb(color), what, within: 1, file: file, line: line)
}

@MainActor let subboardColorTests = Suite("The card's color", [
    test("with none it is today's indigo: the system's border and the card's fill, full and zoomed out, in both appearances") {
        for dark in [false, true] {
            let solid = RGB(hex: dark ? 0x5E5CE6 : 0x5856D6), surface = dark ? BuiltInColors.cardDark : BuiltInColors.cardLight
            for skeleton in [false, true] {
                let bitmap = draw(try colored(nil, skeleton: skeleton).editor, dark: dark)
                let what = "\(dark ? "dark" : "light")\(skeleton ? ", zoomed out" : "")"
                expectNear(pixel(bitmap, at: inside), surface, "the card, \(what)")
                expectNear(pixel(bitmap, at: skeleton ? skeletonBorder : border), solid, "the border, \(what)")
            }
            expect(nearest(draw(try colored(nil).editor, dark: dark), to: solid, in: Band.symbol) <= 24, "the empty card's symbol, indigo")
        }
    },
    test("a named color and a hex value: its solid on the border and the symbol, its surface inside, in both appearances, full and zoomed out") {
        let book = try require(colored(nil).editor.colors)
        for color in [ShapeColor.teal, ShapeColor("#C23B6E")!] {
            let swatch = try require(book.swatch(for: color))
            for dark in [false, true] {
                for skeleton in [false, true] {
                    let bitmap = draw(try colored(color, skeleton: skeleton).editor, dark: dark)
                    let what = "\(color.text), \(dark ? "dark" : "light")\(skeleton ? ", zoomed out" : "")"
                    expectNear(pixel(bitmap, at: inside), swatch.surface[dark: dark], "the card, \(what)")
                    expectNear(pixel(bitmap, at: skeleton ? skeletonBorder : border), swatch.solid[dark: dark], "the border, \(what)")
                    if !skeleton {
                        expect(nearest(bitmap, to: swatch.solid[dark: dark], in: Band.symbol) <= 24, "the symbol, \(what)")
                    }
                }
            }
        }
    },
    test("setColor changes the card and nil takes it back, one step, undone") {
        let h = try colored(nil)
        let id = try require(h.editor.document.shapes.first?.id)
        let teal = try require(h.editor.colors?.swatch(for: .teal))
        h.editor.setColor(.teal, of: [id])
        expectNear(pixel(draw(h.editor, dark: false), at: border), teal.solid.light, "teal")
        h.editor.setColor(nil, of: [id])
        expectNear(pixel(draw(h.editor, dark: false), at: border), RGB(hex: 0x5856D6), "indigo again")
        h.editor.undo()
        expectNear(pixel(draw(h.editor, dark: false), at: border), teal.solid.light, "undone: teal")
        h.editor.undo()
        expectNear(pixel(draw(h.editor, dark: false), at: border), RGB(hex: 0x5856D6), "undone: indigo")
    },
    test("a name the file lacks draws indigo") {
        let bitmap = draw(try colored(.named("nowhere")).editor, dark: false)
        expectNear(pixel(bitmap, at: border), RGB(hex: 0x5856D6), "the border")
        expectNear(pixel(bitmap, at: inside), BuiltInColors.cardLight, "the card")
    },
])

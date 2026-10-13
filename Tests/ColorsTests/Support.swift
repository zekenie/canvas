import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Colors
import ContextMenus
import Keyboard
import Palette
import Selection
import SlashCommands
import TestKit

// The tests' own kinds, so Colors is shown to need no shipped one: a sheet, yellow with no color of
// its own, that fills its box with its paper; a pane, with no default, that fills its box with its
// solid, or gray with no color. CanvasTesting's box has no colors.

/// A sheet: a box kind with colors, yellow by default, drawn as its paper.
struct Sheet: BoxShapeProps {
    static let kind: ShapeKind = "sheet"
    static let properties = Properties<Sheet> {
        Property("frame", \.frame).required()
    }
    var frame: CGRect
    init(_ frame: CGRect) { self.frame = frame }
    init() { self.init(.zero) }
}

struct SheetDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Sheet>, in context: RenderContext) {
        context.cg.setFillColor(context.colors(of: shape)?.paper ?? Pane.plain)
        context.cg.fill(shape.frame)
    }
}

/// A pane: a box kind with colors and no default, drawn as its solid, or gray with none.
struct Pane: BoxShapeProps {
    static let kind: ShapeKind = "pane"
    static let properties = Properties<Pane> {
        Property("frame", \.frame).required()
    }
    /// What a pane with no color is filled with.
    static let plain = CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
    var frame: CGRect
    init(_ frame: CGRect) { self.frame = frame }
    init() { self.init(.zero) }
}

struct PaneDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Pane>, in context: RenderContext) {
        context.cg.setFillColor(context.colors(of: shape)?.solid ?? Pane.plain)
        context.cg.fill(shape.frame)
    }
}

/// The sheet and the pane, as a vertical would register them.
let swatchKinds = Contributor(id: "swatch-kinds") { registrar in
    registrar.shape(SheetDefinition()) { sheet in
        sheet.colorable(default: .yellow)
        sheet.tool(label: "Sheet", systemImage: "square", placing: sheet.placement(size: CGSize(width: 100, height: 60)) { Sheet() })
    }
    registrar.shape(PaneDefinition()) { pane in
        pane.colorable()
        pane.tool(label: "Pane", systemImage: "square.fill", placing: pane.placement(size: CGSize(width: 100, height: 60)) { Pane() })
    }
}

/// The plugins a list with Colors needs, the fixtures' kinds and the tests' own.
@MainActor func colorPlugins(_ more: [any CanvasPlugin] = []) -> [any CanvasPlugin] {
    [KeyboardPlugin(), SelectionPlugin(), ContextMenusPlugin(), SlashCommandsPlugin(), FixturesPlugin(), swatchKinds, ColorsPlugin()] + more
}

@MainActor func colorHarness(_ more: [any CanvasPlugin] = [], file: CanvasFile = CanvasFile()) throws -> EditorHarness {
    try EditorHarness(plugins: colorPlugins(more), file: file)
}

/// A pixel of a rendered frame as sRGB components, 0 to 255.
func rgb(_ color: RGB) -> [Int] {
    [Int((color.red * 255).rounded()), Int((color.green * 255).rounded()), Int((color.blue * 255).rounded())]
}

/// Whether two pixels are the same color, to a step of rounding.
@MainActor func expectPixel(_ pixel: [Int], _ color: RGB, _ message: @autoclosure () -> String = "",
                            file: StaticString = #fileID, line: UInt = #line) {
    let wanted = rgb(color)
    let off = zip(pixel.prefix(3), wanted).map { abs($0 - $1) }.max() ?? 255
    expect(off <= 1, "\(Array(pixel.prefix(3))) isn't \(wanted) (\(color.hexString)) \(message())", file: file, line: line)
}

/// `editor`'s canvas drawn in an appearance (CanvasTesting's `renderBitmap` draws in the light one).
@MainActor func render(_ editor: CanvasEditor, dark: Bool = false, size: CGSize = CGSize(width: 400, height: 300)) throws -> NSBitmapImageRep {
    let rep = try require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let cg = try require(NSGraphicsContext(bitmapImageRep: rep)).cgContext
    cg.translateBy(x: 0, y: size.height)
    cg.scaleBy(x: 1, y: -1)
    try require(NSAppearance(named: dark ? .darkAqua : .aqua)).performAsCurrentDrawingAppearance {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        let bounds = CGRect(origin: .zero, size: size)
        editor.draw(in: cg, bounds: bounds, dirtyRect: bounds)
        NSGraphicsContext.restoreGraphicsState()
    }
    return rep
}

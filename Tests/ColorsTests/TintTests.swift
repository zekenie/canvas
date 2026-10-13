import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Colors
import Palette
import TestKit

// The tint a listed shape's symbol has (`editor.tint(of:)`): its own color's solid when it holds one,
// else its kind's.

/// A slip: a colorable box kind, yellow by default, whose kind is listed in system yellow.
private struct Slip: BoxShapeProps {
    static let kind: ShapeKind = "slip"
    static let properties = Properties<Slip> {
        Property("frame", \.frame).required()
    }
    var frame: CGRect
    init(_ frame: CGRect) { self.frame = frame }
    init() { self.init(.zero) }
}

private struct SlipDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Slip>, in context: RenderContext) {}
}

private let slips = Contributor(id: "slips") { registrar in
    registrar.shape(SlipDefinition()) { slip in
        slip.colorable(default: .yellow)
        slip.tint(.systemYellow)
    }
}

/// A color as the list draws it in an appearance.
@MainActor private func resolved(_ color: NSColor?, dark: Bool) throws -> RGB {
    let color = try require(color)
    var found: NSColor?
    try require(NSAppearance(named: dark ? .darkAqua : .aqua)).performAsCurrentDrawingAppearance {
        found = color.usingColorSpace(.sRGB)
    }
    let srgb = try require(found)
    return RGB(srgb.redComponent, srgb.greenComponent, srgb.blueComponent)
}

@MainActor let colorTintTests = Suite("Listed symbols' tints", [
    test("a shape with a color of its own is listed in its solid, in the light canvas and the dark") {
        let h = try colorHarness([slips])
        let slip = h.add(Slip(CGRect(x: 0, y: 0, width: 100, height: 100)))
        h.editor.setColor(.blue, of: [slip])
        let tint = try require(h.editor.tint(of: try require(h.editor.document[slip])))
        let swatch = try require(BuiltInColors.named("blue")).swatch
        expectEqual(try resolved(tint, dark: false).hexString, swatch.solid.light.hexString)
        expectEqual(try resolved(tint, dark: true).hexString, swatch.solid.dark.hexString)
    },
    test("a value is listed in its solid too") {
        let h = try colorHarness([slips])
        let pane = h.add(Pane(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let value = RGB(hex: 0x4465E9)
        h.editor.setColor(.value(value), of: [pane])
        let tint = h.editor.tint(of: try require(h.editor.document[pane]))
        expectEqual(try resolved(tint, dark: false).hexString, Swatch(value).solid.light.hexString)
    },
    test("changing the color changes the tint, and taking it away gives back the kind's") {
        let h = try colorHarness([slips])
        let slip = h.add(Slip(CGRect(x: 0, y: 0, width: 100, height: 100)))
        @MainActor func tint() throws -> NSColor? { h.editor.tint(of: try require(h.editor.document[slip])) }
        h.editor.setColor(.teal, of: [slip])
        let teal = try require(tint())
        h.editor.setColor(.red, of: [slip])
        let red = try require(tint())
        expect(teal != red)
        expectEqual(try resolved(red, dark: false).hexString, try require(BuiltInColors.named("red")).swatch.solid.light.hexString)
        expect(try tint() === red, "the same color for the same shape, so a list that compares them sees no change")
        h.editor.setColor(nil, of: [slip])
        expectEqual(try tint(), .systemYellow, "its kind's")
    },
    test("a shape with no color of its own keeps its kind's tint, a default-colored one included; a kind with none, none") {
        let h = try colorHarness([slips])
        let slipID = h.add(Slip(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let sheetID = h.add(Sheet(CGRect(x: 200, y: 0, width: 100, height: 100)))
        let boxID = h.add(Box(CGRect(x: 400, y: 0, width: 100, height: 100)))
        let slip = try require(h.editor.document[slipID]), sheet = try require(h.editor.document[sheetID])
        let box = try require(h.editor.document[boxID])
        expectEqual(h.editor.ownTint(of: slip), nil)
        expectEqual(h.editor.tint(of: slip), .systemYellow)
        expectEqual(h.editor.tint(of: sheet), nil, "yellow by default, and no tint declared")
        expectEqual(h.editor.tint(of: box), nil, "a kind with no colors")
    },
    test("a color the file lacks is no color of its own") {
        let h = try colorHarness([slips])
        let slip = h.add(Slip(CGRect(x: 0, y: 0, width: 100, height: 100)))
        h.editor.transact("Lacking") { $0.update(slip) { $0[ColorProperty.self] = .named("mauve") } }
        let record = try require(h.editor.document[slip])
        expectEqual(h.editor.ownTint(of: record), nil)
        expectEqual(h.editor.tint(of: record), .systemYellow, "its kind's")
    },
    test("the registry's report says the contribution") {
        let h = try colorHarness([slips])
        expect(h.editor.registry.report.contains("shape tints"), h.editor.registry.report)
    },
])

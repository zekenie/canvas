import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import LanguageModels
import Palette
import ShippedTesting
import StickyNotes
import Subboards
import TestKit

// Board pictures (`BoardPicture`, what Quick Look shows of a board file) drawn with the shipped
// plugins: a board's shapes as the app draws them, fitted, and a subboard's card with its board's
// preview built in the one picture.

/// The shipped plugins, on a pasteboard of the test's own, with a model that never reaches the network.
@MainActor private func shippedRegistry() throws -> Registry {
    try ShippedPlugins.registry(pasteboard: NSPasteboard.withUniqueName(), model: ScriptedLanguageModel())
}

/// The picture drawn into a bitmap of `size`, one pixel a point, y up, as Quick Look's are, in the
/// light appearance.
@MainActor private func render(_ picture: BoardPicture, size: CGSize) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    picture.draw(in: NSGraphicsContext(bitmapImageRep: rep)!.cgContext, size: size, appearance: NSAppearance(named: .aqua)!)
    return rep
}

/// A note's yellow (`NoteStyle.color`, sRGB 1, 0.87, 0.45).
private func isNoteYellow(_ color: [Int]) -> Bool { color[0] > 235 && (190...245).contains(color[1]) && color[2] < 150 }

@MainActor let picturesShippedTests = Suite("Board pictures, shipped", [
    test("the sample board's picture shows it whole at 100%: each note in its yellow where it is, the canvas between") {
        let picture = BoardPicture(file: CanvasFile(root: SampleBoard.document()), registry: try shippedRegistry())
        // The notes, 200 square, from (80, 80) to (1040, 620): 960 × 540, with 64 in all.
        let size = picture.size(within: CGSize(width: 1600, height: 1200))
        expectEqual(size, CGSize(width: 1024, height: 604))
        let bitmap = render(picture, size: size)
        // Each note's bottom middle, under its text: the board from (32, 32), (48, 48) off the world.
        for (x, y) in [(132, 212), (512, 212), (892, 212), (132, 552), (512, 552), (892, 552)] {
            expect(isNoteYellow(pixel(bitmap, at: CGPoint(x: x, y: y))), "a note at (\(x), \(y)): \(pixel(bitmap, at: CGPoint(x: x, y: y)))")
        }
        let between = pixel(bitmap, at: CGPoint(x: 322, y: 302))
        expect(between[0...2].allSatisfy { $0 > 200 }, "the canvas between the rows: \(between)")
    },
    test("a subboard's card shows its board's preview, built in the one picture") {
        // The card at (40, 40, 240 × 160), as SubboardsTests' is; its board a note, drawn at a tenth:
        // 20 points across in the card's middle, (160, 120), which is (152, 112) in the picture.
        let card = ShapeRecord(Subboard(frame: CGRect(x: 40, y: 40, width: 240, height: 160)))
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(card)]),
                              children: [card.id: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(StickyNote(frame: CGRect(x: 500, y: 500, width: 200, height: 200))))])])
        let picture = BoardPicture(file: file, registry: try shippedRegistry())
        let size = picture.size(within: CGSize(width: 1600, height: 1200))
        expectEqual(size, CGSize(width: 304, height: 224))
        let bitmap = render(picture, size: size)
        // In the color a note is listed in, its kind's system yellow (`NoteStyle.tint`), in the light, quieted
        // toward the gray a shape with none is drawn in (the default skeleton's, 0.6 0.62 0.64), as far as the
        // previews quiet a color.
        var system: RGB?
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            guard let srgb = NSColor.systemYellow.usingColorSpace(.sRGB) else { return }
            system = RGB(Double(srgb.redComponent), Double(srgb.greenComponent), Double(srgb.blueComponent))
        }
        let muting = CanvasEditor(registry: try shippedRegistry()).boardPreviews.muting
        let quiet = try require(system).muted(by: muting, toward: OKLCH(RGB(0.6, 0.62, 0.64)).lightness)
        let yellow = [quiet.red, quiet.green, quiet.blue].map { Int(($0 * 255).rounded()) }
        for point in [CGPoint(x: 152, y: 112), CGPoint(x: 145, y: 105), CGPoint(x: 159, y: 119)] {
            let silhouette = pixel(bitmap, at: point)
            expect(zip(silhouette, yellow).allSatisfy { abs($0 - $1) <= 4 },
                   "the note's silhouette at \(point), in the yellow it's listed in, quieted: \(silhouette), not \(yellow)")
        }
    },
    test("a board file as saved, in an older format too, is read as the app reads it and drawn") {
        // nested.v4.json: two notes from (80, 80), 200 square, 380 apart, and a subboard under them,
        // to (660, 580): 644 × 564, the board from (48, 48) off the world.
        let data = try Data(contentsOf: URL(fileURLWithPath: "Tests/CompositionTests/Fixtures/files/nested.v4.json"))
        let picture = try BoardPicture(data: data, registry: try shippedRegistry())
        let size = picture.size(within: CGSize(width: 1600, height: 1200))
        expectEqual(size, CGSize(width: 644, height: 564))
        let bitmap = render(picture, size: size)
        for (x, y) in [(132, 212), (512, 212)] {
            expect(isNoteYellow(pixel(bitmap, at: CGPoint(x: x, y: y))), "a note at (\(x), \(y)): \(pixel(bitmap, at: CGPoint(x: x, y: y)))")
        }
    },
])

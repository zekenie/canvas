import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import TestKit

/// A box that owns a board and shows its preview, inset 10 from its edges, on a white body: what a
/// subboard's card does, without Subboards.
struct Cabinet: BoxShapeProps {
    static let kind: ShapeKind = "cabinet"
    static let properties = Properties<Cabinet> {
        Property("frame", \.frame).required()
    }
    var frame: CGRect
}

extension Cabinet {
    init() { self.init(frame: .zero) }
}

struct CabinetDefinition {}

extension CabinetDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Cabinet>, in context: RenderContext) {
        context.cg.setFillColor(.white)
        context.cg.fill(shape.frame)
        _ = context.drawBoardPreview(ofBoardOwnedBy: shape.id, in: shape.frame.insetBy(dx: 10, dy: 10))
    }
}

extension CabinetDefinition: BoardOwning {}

@MainActor private func pictureRegistry() throws -> Registry {
    try Registry(plugins: [FixturesPlugin(), Contributor(id: "cabinets") { $0.shape(CabinetDefinition()) }])
}

private func boxes(_ rects: [CGRect]) -> CanvasFile {
    CanvasFile(root: CanvasDocument(shapes: rects.map { AnyShapeRecord(ShapeRecord(Box($0))) }))
}

/// The picture drawn into a bitmap of `size`, one pixel a point, as Quick Look's contexts are drawn
/// into: from the bottom-left, y up.
@MainActor private func render(_ picture: BoardPicture, size: CGSize, appearance: NSAppearance.Name = .aqua) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    picture.draw(in: NSGraphicsContext(bitmapImageRep: rep)!.cgContext, size: size, appearance: NSAppearance(named: appearance)!)
    return rep
}

/// Whether a pixel is a fixture box's gray (or its skeleton's), well darker than the canvas around it.
private func isBox(_ color: [Int]) -> Bool { color[0] < 190 && abs(color[0] - color[2]) < 20 }

/// The canvas's light background, as `render` draws it, a grid dot on it too (some 207 at its middle).
private func isLightCanvas(_ color: [Int]) -> Bool { color[0...2].allSatisfy { $0 > 200 } }

@MainActor let boardPictureTests = Suite("Board picture", [
    test("it's as big as the board at 100% with a first visit's margin; no bigger than the limit, as close as fits it; no smaller than the minimum") {
        // 500 × 300 of shapes, from (100, 100).
        let picture = BoardPicture(file: boxes([CGRect(x: 100, y: 100, width: 200, height: 100), CGRect(x: 500, y: 300, width: 100, height: 100)]),
                                   registry: try pictureRegistry())
        expect(!picture.isEmpty)
        expectEqual(picture.size(within: CGSize(width: 2000, height: 2000)), CGSize(width: 564, height: 364), "at 100%, with 64 in all")
        expectEqual(picture.size(within: CGSize(width: 2000, height: 2000), minimum: CGSize(width: 800, height: 600)), CGSize(width: 800, height: 600))
        expectEqual(picture.size(within: CGSize(width: 314, height: 2000)), CGSize(width: 314, height: 214), "at 50%, as close as fits 314 wide")
        picture.inset = 20
        picture.maxZoom = 2
        expectEqual(picture.size(within: CGSize(width: 2000, height: 2000)), CGSize(width: 1020, height: 620), "a closer limit, a smaller margin")
        let empty = BoardPicture(file: CanvasFile(), registry: try pictureRegistry())
        expect(empty.isEmpty)
        expectEqual(empty.size(within: CGSize(width: 2000, height: 2000), minimum: CGSize(width: 480, height: 320)), CGSize(width: 480, height: 320))
    },
    test("a box laid out larger than it stores takes room in the picture by its laid-out frame, as it does on the canvas") {
        let gauge = ShapeRecord(Gauge(CGRect(x: 700, y: 100, width: 10, height: 10), width: 600, height: 300))
        let stretch = ShapeRecord(Stretch(CGRect(x: 100, y: 100, width: 200, height: 100), gauge: gauge.id))
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(gauge), AnyShapeRecord(stretch)]))
        let registry = try Registry(plugins: [FixturesPlugin(), StretchesPlugin()])
        let picture = BoardPicture(file: file, registry: registry)
        // The stretch is laid out 600 × 300 from (100, 100); with the gauge at its right, the board
        // is 610 × 300, and without a layout it would be 610 × 100.
        expectEqual(picture.size(within: CGSize(width: 2000, height: 2000)), CGSize(width: 674, height: 364), "at 100%, with 64 in all")
    },
    test("a box laid out smaller than it stores takes room in the picture by its smaller frame: the board's bounds, and so the picture's size, are the frame's") {
        let gauge = ShapeRecord(Gauge(CGRect(x: 400, y: 100, width: 10, height: 10), width: 50, height: 30))
        let stretch = ShapeRecord(Stretch(CGRect(x: 100, y: 100, width: 800, height: 400), gauge: gauge.id))
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(gauge), AnyShapeRecord(stretch)]))
        let registry = try Registry(plugins: [FixturesPlugin(), StretchesPlugin(shrinking: true)])
        let picture = BoardPicture(file: file, registry: registry)
        // The stretch is laid out 50 × 30 from (100, 100); with the gauge at its right the board is 310 × 30,
        // and by its stored box it would be 800 × 400.
        expectEqual(picture.size(within: CGSize(width: 2000, height: 2000)), CGSize(width: 374, height: 94), "at 100%, with 64 in all")
    },
    test("it draws the whole board centered on the canvas, upright, each shape where the fit puts it") {
        // 500 × 300 at 100% in 564 × 364: the board from (32, 32), so the top-left box is at
        // (32, 32, 200 × 100) and the bottom-right one at (432, 232, 100 × 100).
        let picture = BoardPicture(file: boxes([CGRect(x: 100, y: 100, width: 200, height: 100), CGRect(x: 500, y: 300, width: 100, height: 100)]),
                                   registry: try pictureRegistry())
        let size = picture.size(within: CGSize(width: 2000, height: 2000))
        let bitmap = render(picture, size: size)
        for point in [CGPoint(x: 40, y: 40), CGPoint(x: 220, y: 120), CGPoint(x: 440, y: 240), CGPoint(x: 520, y: 320)] {
            expect(isBox(pixel(bitmap, at: point)), "a box at \(point): \(pixel(bitmap, at: point))")
        }
        for point in [CGPoint(x: 10, y: 10), CGPoint(x: 440, y: 120), CGPoint(x: 120, y: 240), CGPoint(x: 554, y: 354)] {
            expect(isLightCanvas(pixel(bitmap, at: point)), "the canvas at \(point): \(pixel(bitmap, at: point))")
        }
    },
    test("a board that doesn't fit at 100% is drawn as far out as it takes to show all of it, past the canvas's 10%") {
        // 20,000 across in 1,000 points: at 4.7%, each 2,000-unit box 94 points wide, at either end.
        let picture = BoardPicture(file: boxes([CGRect(x: 0, y: 0, width: 2000, height: 2000), CGRect(x: 18000, y: 0, width: 2000, height: 2000)]),
                                   registry: try pictureRegistry())
        let size = picture.size(within: CGSize(width: 1000, height: 1000))
        expectEqual(size, CGSize(width: 1000, height: 158))
        let bitmap = render(picture, size: size)
        for point in [CGPoint(x: 80, y: 79), CGPoint(x: 920, y: 79)] {
            expect(isBox(pixel(bitmap, at: point)), "a box at \(point): \(pixel(bitmap, at: point))")
        }
        expect(isLightCanvas(pixel(bitmap, at: CGPoint(x: 500, y: 79))), "the canvas between them")
    },
    test("a card shows its board's preview built, in the one picture, where the canvas builds it over frames") {
        let cabinet = ShapeRecord(Cabinet(frame: CGRect(x: 0, y: 0, width: 300, height: 200)))
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(cabinet)]),
                              children: [cabinet.id: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(Box(CGRect(x: 0, y: 0, width: 1000, height: 1000))))])])
        let picture = BoardPicture(file: file, registry: try pictureRegistry())
        let size = picture.size(within: CGSize(width: 2000, height: 2000))
        expectEqual(size, CGSize(width: 364, height: 264))
        let bitmap = render(picture, size: size)
        // The cabinet at (32, 32, 300 × 200); the box's silhouette fills the preview's middle square,
        // 180 points across, in a muted gray; the cabinet's white at its sides.
        let middle = pixel(bitmap, at: CGPoint(x: 182, y: 132))
        expect(middle[0] < 225 && abs(middle[0] - middle[2]) < 20, "the box's silhouette in the cabinet's middle: \(middle)")
        expect(pixel(bitmap, at: CGPoint(x: 50, y: 132))[0...2].allSatisfy { $0 > 250 }, "the cabinet's white beside it")
    },
    test("it's drawn in the appearance asked for: the canvas light in aqua, dark in dark aqua") {
        let picture = BoardPicture(file: boxes([CGRect(x: 0, y: 0, width: 100, height: 100)]), registry: try pictureRegistry())
        let size = picture.size(within: CGSize(width: 1000, height: 1000))
        expect(isLightCanvas(pixel(render(picture, size: size, appearance: .aqua), at: CGPoint(x: 10, y: 10))))
        let dark = pixel(render(picture, size: size, appearance: .darkAqua), at: CGPoint(x: 10, y: 10))
        expect(dark[0...2].allSatisfy { $0 < 70 }, "the dark canvas, a grid dot on it too: \(dark)")
    },
    test("as an image it's as many pixels as its scale says, drawn at that scale") {
        let picture = BoardPicture(file: boxes([CGRect(x: 0, y: 0, width: 100, height: 100)]), registry: try pictureRegistry())
        // 164 × 164: the box at (32, 32, 100 × 100), at 2× (64, 64, 200 × 200).
        let image = try require(picture.image(size: CGSize(width: 164, height: 164), scale: 2, appearance: NSAppearance(named: .aqua)!))
        expectEqual(image.width, 328)
        expectEqual(image.height, 328)
        let pixels = DeviceRGBPixels(NSBitmapImageRep(cgImage: image))
        let box = try require(pixels[100, 100]), canvas = try require(pixels[30, 30])
        expect(box.gray < 0.8 && canvas.gray > 0.92, "the box at 2× (\(box.gray)) on the canvas (\(canvas.gray))")
        expect(picture.image(size: .zero, scale: 2, appearance: NSAppearance(named: .aqua)!) == nil, "no pixels, no image")
    },
    test("it reads a board file as the app saves it, and one that isn't a board throws") {
        let registry = try pictureRegistry()
        let file = boxes([CGRect(x: 0, y: 0, width: 200, height: 100)])
        let picture = try BoardPicture(data: try BoardCodec(registry: registry).encode(file), registry: registry)
        expectEqual(picture.size(within: CGSize(width: 1000, height: 1000)), CGSize(width: 264, height: 164))
        var threw = false
        do { _ = try BoardPicture(data: Data("not a board".utf8), registry: registry) } catch { threw = true }
        expect(threw, "not a board")
    },
])

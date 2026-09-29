import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import TestKit

/// A bitmap's layout: `renderBitmap`'s (8-bit RGBA), Core Graphics' own (8-bit BGRA, as a window's
/// backing store), or 16-bit float in an extended range's space (wide color, EDR).
private enum Layout {
    case rgba, bgra, extended

    func context(width: Int, height: Int) -> CGContext? {
        switch self {
        case .rgba:
            CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        case .bgra:
            CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        case .extended:
            CGContext(data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: 0,
                      space: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                          | CGBitmapInfo.byteOrder16Little.rawValue)
        }
    }
}

/// A bitmap as `renderBitmap` makes it (y down, `scale` pixels a point), drawn into by `draw` under
/// an appearance, within `clip` (view points) if there is one, turned a quarter about its middle if
/// `turned`.
@MainActor private func picture(_ size: CGSize, scale: CGFloat, layout: Layout = .rgba, dark: Bool = false, clip: CGRect? = nil,
                                turned: Bool = false, _ draw: (CGContext, CGRect) -> Void) throws -> CGContext {
    let cg = try require(layout.context(width: Int(size.width * scale), height: Int(size.height * scale)))
    cg.translateBy(x: 0, y: size.height * scale)
    cg.scaleBy(x: scale, y: -scale)
    if turned {
        // The grid's rows run down the bitmap's columns.
        cg.translateBy(x: size.width / 2, y: size.height / 2)
        cg.rotate(by: .pi / 2)
        cg.translateBy(x: -size.width / 2, y: -size.height / 2)
    }
    if let clip { cg.clip(to: clip) }
    try require(NSAppearance(named: dark ? .darkAqua : .aqua)).performAsCurrentDrawingAppearance {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        draw(cg, CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
    }
    return cg
}

/// An empty board drawn by the editor, and by `drawGridAsEllipses`, into the same kind of bitmap.
@MainActor private func pictures(_ editor: CanvasEditor, _ size: CGSize, scale: CGFloat, layout: Layout = .rgba, dark: Bool = false,
                                 clip: CGRect? = nil, turned: Bool = false) throws -> (tiles: CGContext, ellipses: CGContext) {
    (try picture(size, scale: scale, layout: layout, dark: dark, clip: clip, turned: turned) { editor.draw(in: $0, bounds: $1, dirtyRect: $1) },
     try picture(size, scale: scale, layout: layout, dark: dark, clip: clip, turned: turned) {
         drawGridAsEllipses(in: $0, bounds: $1, camera: editor.camera, dark: dark)
     })
}

/// How many bytes differ between two 8-bit bitmaps of one layout, and by how much at most (0...255).
private func difference(_ a: CGContext, _ b: CGContext) -> (bytes: Int, most: Int) {
    let count = a.bytesPerRow * a.height
    let p = a.data!.assumingMemoryBound(to: UInt8.self), q = b.data!.assumingMemoryBound(to: UInt8.self)
    guard memcmp(p, q, count) != 0 else { return (0, 0) }
    var bytes = 0, most = 0
    for i in 0..<count where p[i] != q[i] {
        bytes += 1
        most = max(most, abs(Int(p[i]) - Int(q[i])))
    }
    return (bytes, most)
}

/// Each dot's middle, pixels (from the top-left corner), and how dark it is: the centroid and the
/// sum of how far each pixel around where it should be is from the background, in red, in an 8-bit
/// RGBA bitmap. Dots too near the edge to be seen whole are left out.
private func dots(in context: CGContext, camera: Camera, scale: CGFloat) -> [(center: CGPoint, ink: Double)] {
    let (start, step) = gridLattice(camera)
    let bytes = context.data!.assumingMemoryBound(to: UInt8.self), row = context.bytesPerRow
    let reach = Int(scale) + 2
    // The middle of the second cell is never a dot's, and always in the bitmap: `start` is within a
    // step before its edge.
    let background = Double(bytes[Int((start.y + step * 1.5) * scale) * row + Int((start.x + step * 1.5) * scale) * 4])
    var found: [(CGPoint, Double)] = []
    var y = start.y
    while y * scale < CGFloat(context.height) {
        var x = start.x
        while x * scale < CGFloat(context.width) {
            let cx = Int(x * scale), cy = Int(y * scale)
            if cx - reach >= 0, cy - reach >= 0, cx + reach < context.width, cy + reach < context.height {
                var ink = 0.0, sx = 0.0, sy = 0.0
                for py in (cy - reach)...(cy + reach) {
                    for px in (cx - reach)...(cx + reach) {
                        let d = abs(Double(bytes[py * row + px * 4]) - background)
                        ink += d
                        sx += d * (Double(px) + 0.5)
                        sy += d * (Double(py) + 0.5)
                    }
                }
                found.append((CGPoint(x: sx / ink, y: sy / ink), ink))
            }
            x += step
        }
        y += step
    }
    return found
}

@MainActor let gridTests = Suite("Dot grid", [
    test("the grid is drawn pixel for pixel as a path of an ellipse per dot at 100%, and where the POC's goldens are zoomed out") {
        let h = try EditorHarness(plugins: [])
        for scale: CGFloat in [1, 2] {
            h.editor.camera = Camera(origin: CGPoint(x: 3.3, y: 7.7), zoom: 1)
            let (tiles, reference) = try pictures(h.editor, CGSize(width: 600, height: 400), scale: scale)
            expectEqual(difference(tiles, reference).bytes, 0, "100% at \(scale)×")
        }
        // Parity's zoomed renders: 60% about (300, 200) and 15% about (370, 180), at 2× in a view of
        // 1,200 × 800, where the spacing is 57.6 pixels (five dots to a tile of 288).
        for (zoom, anchor) in [(0.6, CGPoint(x: 300, y: 200)), (0.15, CGPoint(x: 370, y: 180))] as [(CGFloat, CGPoint)] {
            h.editor.camera = Camera()
            h.editor.camera.setZoom(zoom, around: anchor)
            let (tiles, reference) = try pictures(h.editor, CGSize(width: 1200, height: 800), scale: 2)
            expectEqual(difference(tiles, reference).bytes, 0, "\(zoom * 100)% at 2×")
        }
    },
    test("into Core Graphics' own layout (a window's), the grid is the path's pixel for pixel too, from tiles of that layout") {
        let h = try EditorHarness(plugins: [])
        h.editor.camera = Camera(origin: CGPoint(x: 3.3, y: 7.7), zoom: 1)
        let (tiles, reference) = try pictures(h.editor, CGSize(width: 600, height: 400), scale: 2, layout: .bgra)
        expectEqual(difference(tiles, reference).bytes, 0)
    },
    test("into a 16-bit float context of an extended range, which no 8-bit tile can be in, the grid is drawn from sRGB tiles, as the path draws it") {
        let h = try EditorHarness(plugins: [])
        h.editor.camera = Camera(origin: CGPoint(x: 3.3, y: 7.7), zoom: 1)
        let made = h.editor.gridTilesMade
        let (tiles, reference) = try pictures(h.editor, CGSize(width: 300, height: 200), scale: 2, layout: .extended)
        expectEqual(h.editor.gridTilesMade - made, 1, "drawn from a tile, not as the path")
        let count = tiles.bytesPerRow * tiles.height / 2
        let p = try require(tiles.data).assumingMemoryBound(to: Float16.self), q = try require(reference.data).assumingMemoryBound(to: Float16.self)
        let most = (0..<count).map { abs(Float(p[$0]) - Float(q[$0])) }.max() ?? 0
        expect(most < 2 / 255, "a channel \(most) off")
    },
    test("where the dots are closest (70%, 35%) and at 10%, a whole number of dots spans whole pixels, and the grid is the path's to a level") {
        let h = try EditorHarness(plugins: [])
        for scale: CGFloat in [1, 2] {
            for (zoom, origin) in [(0.7, CGPoint(x: -33.1, y: 12.9)), (0.35, CGPoint(x: 101.7, y: -55.5)), (0.1, CGPoint(x: -1234.5, y: 987.6))]
                as [(CGFloat, CGPoint)] {
                h.editor.camera = Camera(origin: origin, zoom: zoom)
                let (tiles, reference) = try pictures(h.editor, CGSize(width: 600, height: 400), scale: scale)
                expect(difference(tiles, reference).most <= 1, "\(zoom * 100)% at \(scale)×: \(difference(tiles, reference))")
            }
        }
    },
    // A copy puts its dots within an eighth of a pixel of the path's; a dot's ink, where it's measured
    // from, is a pixel or two wide, and moves its centroid a little more, and its sum a few percent,
    // as the dot moves within a pixel. A copy drawn from the wrong tile, or a pixel off, is farther.
    test("at any other zoom, every dot is within a quarter pixel of where the path draws it, and as dark") {
        let h = try EditorHarness(plugins: [])
        for scale: CGFloat in [1, 2] {
            for (zoom, origin) in [(0.7137, CGPoint(x: -123.4, y: 55.5)), (1.2345, CGPoint(x: 17.17, y: -3.3)), (0.4321, CGPoint(x: 9.9, y: 99.9)),
                                   (3.14159, CGPoint(x: -2.71, y: 1.61)), (0.123, CGPoint(x: 5000.5, y: -777.7))] as [(CGFloat, CGPoint)] {
                h.editor.camera = Camera(origin: origin, zoom: zoom)
                let (tiles, reference) = try pictures(h.editor, CGSize(width: 600, height: 400), scale: scale)
                let drawn = dots(in: tiles, camera: h.editor.camera, scale: scale), wanted = dots(in: reference, camera: h.editor.camera, scale: scale)
                expectEqual(drawn.count, wanted.count)
                let farthest = zip(drawn, wanted).map { hypot($0.center.x - $1.center.x, $0.center.y - $1.center.y) }.max() ?? 0
                let darkest = zip(drawn, wanted).map { abs($0.ink - $1.ink) / $1.ink }.max() ?? 0
                expect(!drawn.isEmpty && farthest <= 0.25, "\(zoom * 100)% at \(scale)×: a dot \(farthest) pixels off")
                expect(darkest < 0.05, "\(zoom * 100)% at \(scale)×: a dot \(darkest * 100)% lighter or darker")
            }
        }
    },
    test("dark, the grid is the path's in dark's colors, from tiles made afresh") {
        let h = try EditorHarness(plugins: [])
        h.editor.camera = Camera(origin: CGPoint(x: 3.3, y: 7.7), zoom: 1)
        _ = try pictures(h.editor, CGSize(width: 300, height: 200), scale: 2)
        let (tiles, reference) = try pictures(h.editor, CGSize(width: 300, height: 200), scale: 2, dark: true)
        expectEqual(difference(tiles, reference).bytes, 0)
    },
    test("a frame the camera didn't move makes no tiles; a pan or a zoom makes one for each quarter pixel its copies land on") {
        let h = try EditorHarness(plugins: [])
        let size = CGSize(width: 600, height: 400)
        h.editor.camera = Camera(origin: CGPoint(x: 3.3, y: 7.7), zoom: 1)
        var made = h.editor.gridTilesMade
        @MainActor func frame() -> Int {
            _ = renderBitmap(h.editor, size: size, scale: 2)
            defer { made = h.editor.gridTilesMade }
            return h.editor.gridTilesMade - made
        }
        expectEqual(frame(), 1, "100%: every copy is the one tile")
        expectEqual(frame(), 0, "the same again")
        h.editor.camera.pan(by: CGSize(width: 0.3, height: 0))
        expectEqual(frame(), 1, "panned by less than a pixel")
        h.editor.camera.setZoom(0.6, around: CGPoint(x: 300, y: 200))
        expectEqual(frame(), 1, "60%: five dots span 288 pixels")
        h.editor.camera.setZoom(0.7137, around: CGPoint(x: 300, y: 200))
        let pinched = frame()
        expect(pinched > 1 && pinched <= 4 * 4, "71.37%: \(pinched) tiles, of a quarter pixel's four steps across and down")
        expectEqual(frame(), 0, "still at 71.37%")
    },
    test("a camera whose origin isn't a number draws no grid, and one too far out to have fractions left draws it whole") {
        let h = try EditorHarness(plugins: [])
        let size = CGSize(width: 300, height: 200)
        let background = try picture(size, scale: 1) { $0.setFillColor(NSColor(white: 0.965, alpha: 1).cgColor); $0.fill($1) }
        h.editor.camera = Camera(origin: CGPoint(x: .nan, y: 7.7), zoom: 1)
        let nan = try picture(size, scale: 1) { h.editor.draw(in: $0, bounds: $1, dirtyRect: $1) }
        expectEqual(difference(nan, background).bytes, 0, "the background alone")
        h.editor.camera = Camera(origin: CGPoint(x: 1e20, y: -1e20), zoom: 1)
        let far = try picture(size, scale: 1) { h.editor.draw(in: $0, bounds: $1, dirtyRect: $1) }
        // Dots 24 points apart, however they fall: in each 24-point square of the view, some ink.
        let bytes = try require(far.data).assumingMemoryBound(to: UInt8.self)
        let inked = stride(from: 0, to: 288, by: 24).allSatisfy { left in
            stride(from: 0, to: 192, by: 24).allSatisfy { top in
                (top..<top + 24).contains { y in (left..<left + 24).contains { x in bytes[y * far.bytesPerRow + x * 4] < 240 } }
            }
        }
        expect(inked, "dots all over the view")
    },
    test("in a context turned a quarter, the grid is the path's") {
        let h = try EditorHarness(plugins: [])
        h.editor.camera = Camera(origin: CGPoint(x: 3.3, y: 7.7), zoom: 0.7137)
        let (tiles, reference) = try pictures(h.editor, CGSize(width: 300, height: 300), scale: 2, turned: true)
        expectEqual(difference(tiles, reference).bytes, 0)
    },
    test("redrawing part of the canvas draws the dots across its edges as the whole canvas does") {
        let h = try EditorHarness(plugins: [])
        h.editor.camera = Camera(origin: CGPoint(x: 3.3, y: 7.7), zoom: 1)
        // Dots at 20.7, 44.7, 68.7 … and 16.3, 40.3 …: those at 44.7 and 16.3 straddle the edges.
        let dirty = CGRect(x: 45, y: 17, width: 300, height: 200)
        for scale: CGFloat in [1, 2] {
            let (tiles, reference) = try pictures(h.editor, CGSize(width: 400, height: 300), scale: scale, clip: dirty)
            expectEqual(difference(tiles, reference).bytes, 0, "at \(scale)×")
        }
    },
])

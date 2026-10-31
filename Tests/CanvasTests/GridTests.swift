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

/// An empty board drawn by the editor twice into one kind of bitmap: with the grid's copies clipped
/// to the pixels their dots touch, as into any bitmap (the default), and with them unclipped, as
/// into a context that isn't one (`gridClipOverride`). Each frame is held to what it says of
/// itself, so the two differ only in the clip.
@MainActor private func clippedAndUnclipped(_ editor: CanvasEditor, _ size: CGSize, scale: CGFloat, layout: Layout = .rgba, dark: Bool = false,
                                            clip: CGRect? = nil, _ label: String) throws -> (clipped: CGContext, unclipped: CGContext) {
    @MainActor func frame() throws -> (context: CGContext, clipped: Int, unclipped: Int) {
        let before = (editor.gridFramesClipped, editor.gridFramesUnclipped)
        let context = try picture(size, scale: scale, layout: layout, dark: dark, clip: clip) { editor.draw(in: $0, bounds: $1, dirtyRect: $1) }
        return (context, editor.gridFramesClipped - before.0, editor.gridFramesUnclipped - before.1)
    }
    let clipped = try frame()
    expectEqual(clipped.clipped, 1, "\(label): a bitmap's copies are clipped")
    expectEqual(clipped.unclipped, 0, "\(label): and not drawn unclipped")
    editor.gridClipOverride = false
    defer { editor.gridClipOverride = nil }
    let unclipped = try frame()
    expectEqual(unclipped.clipped, 0, "\(label): once the override says not to, they aren't clipped")
    expectEqual(unclipped.unclipped, 1, "\(label): and are drawn unclipped")
    return (clipped.context, unclipped.context)
}

/// A one-page PDF, y down as `picture`'s bitmaps are: a context that isn't a bitmap, as AppKit's is
/// for a view on screen.
@MainActor private func pdfPage(_ size: CGSize, _ draw: (CGContext, CGRect) -> Void) throws {
    var mediaBox = CGRect(origin: .zero, size: size)
    let pdf = try require(CGContext(consumer: try require(CGDataConsumer(data: NSMutableData())), mediaBox: &mediaBox, nil))
    pdf.beginPDFPage(nil)
    pdf.translateBy(x: 0, y: size.height)
    pdf.scaleBy(x: 1, y: -1)
    try require(NSAppearance(named: .aqua)).performAsCurrentDrawingAppearance {
        draw(pdf, mediaBox)
    }
    pdf.endPDFPage()
    pdf.closePDF()
}

/// How many bytes differ between two 8-bit bitmaps of one layout, and by how much at most (0...255).
private func difference(_ a: CGContext, _ b: CGContext) -> (bytes: Int, most: Int) {
    let count = a.bytesPerRow * a.height
    let p = a.data!.assumingMemoryBound(to: UInt8.self), q = b.data!.assumingMemoryBound(to: UInt8.self)
    guard memcmp(p, q, count) != 0 else { return (0, 0) }
    // A row at a time, the rows alike passed with one memcmp, the others walked with plain loops (no iterator, no generic abs
    // or max: the walk is of millions of bytes, in a build with no optimizer).
    var bytes = 0, most = 0, row = 0
    while row < a.height {
        let start = row * a.bytesPerRow, end = start + a.bytesPerRow
        row += 1
        if memcmp(p + start, q + start, a.bytesPerRow) == 0 { continue }
        var i = start
        while i < end {
            if p[i] != q[i] {
                bytes += 1
                let d = Int(p[i]) - Int(q[i]), size = d < 0 ? -d : d
                if size > most { most = size }
            }
            i += 1
        }
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
        var most: Float = 0, i = 0
        while i < count {
            let off = abs(Float(p[i]) - Float(q[i]))
            if off > most { most = off }
            i += 1
        }
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
    // A tile is clear but for its dots, and its copies never overlap, so what the clip of the pixels
    // the dots touch leaves out is clear anyway. Into a context that isn't a bitmap, where the clip
    // costs far more than it saves, the copies are drawn without it.
    test("drawn unclipped, as into a context that isn't a bitmap, the grid is the clipped grid pixel for pixel, at every zoom") {
        let h = try EditorHarness(plugins: [])
        // 100%; where the dots are closest (70%, 35%); 10%; and zooms whose copies drift from their dots.
        for scale: CGFloat in [1, 2] {
            for (zoom, origin) in [(1, CGPoint(x: 3.3, y: 7.7)), (0.7, CGPoint(x: -33.1, y: 12.9)), (0.35, CGPoint(x: 101.7, y: -55.5)),
                                   (0.1, CGPoint(x: -1234.5, y: 987.6)), (0.7137, CGPoint(x: -123.4, y: 55.5)), (1.2345, CGPoint(x: 17.17, y: -3.3)),
                                   (0.4321, CGPoint(x: 9.9, y: 99.9)), (3.14159, CGPoint(x: -2.71, y: 1.61)), (0.123, CGPoint(x: 5000.5, y: -777.7))]
                as [(CGFloat, CGPoint)] {
                h.editor.camera = Camera(origin: origin, zoom: zoom)
                let label = "\(zoom * 100)% at \(scale)×"
                let (clipped, unclipped) = try clippedAndUnclipped(h.editor, CGSize(width: 600, height: 400), scale: scale, label)
                expectEqual(difference(clipped, unclipped).bytes, 0, label)
            }
        }
        // 87.3% about a point off the middle, and Parity's zoomed renders (60% about (300, 200) and 15%
        // about (370, 180)), at 2× in a view of 1,200 × 800.
        for (zoom, anchor) in [(0.873, CGPoint(x: 431, y: 127)), (0.6, CGPoint(x: 300, y: 200)), (0.15, CGPoint(x: 370, y: 180))] as [(CGFloat, CGPoint)] {
            h.editor.camera = Camera()
            h.editor.camera.setZoom(zoom, around: anchor)
            let label = "\(zoom * 100)% about \(anchor) at 2×"
            let (clipped, unclipped) = try clippedAndUnclipped(h.editor, CGSize(width: 1200, height: 800), scale: 2, label)
            expectEqual(difference(clipped, unclipped).bytes, 0, label)
        }
    },
    test("unclipped, the grid is the clipped grid pixel for pixel in dark, in Core Graphics' own layout and an extended range's, and where part of the canvas is redrawn") {
        let h = try EditorHarness(plugins: [])
        let size = CGSize(width: 400, height: 300)
        // At 100% the dots at 44.7 and 16.3 straddle the redrawn part's edges.
        let dirty = CGRect(x: 45, y: 17, width: 300, height: 200)
        for zoom: CGFloat in [1, 0.7137] {
            h.editor.camera = Camera(origin: CGPoint(x: 3.3, y: 7.7), zoom: zoom)
            for (name, layout, dark) in [("dark", .rgba, true), ("BGRA", .bgra, false), ("extended", .extended, false)] as [(String, Layout, Bool)] {
                let label = "\(name) at \(zoom * 100)%, 2×"
                let (clipped, unclipped) = try clippedAndUnclipped(h.editor, size, scale: 2, layout: layout, dark: dark, label)
                expectEqual(difference(clipped, unclipped).bytes, 0, label)
            }
            for scale: CGFloat in [1, 2] {
                let label = "part redrawn at \(zoom * 100)%, \(scale)×"
                let (clipped, unclipped) = try clippedAndUnclipped(h.editor, size, scale: scale, clip: dirty, label)
                expectEqual(difference(clipped, unclipped).bytes, 0, label)
            }
        }
    },
    test("a bitmap's copies are clipped and a PDF page's aren't, unless gridClipOverride says otherwise; a frame that draws no copies counts neither") {
        let h = try EditorHarness(plugins: [])
        h.editor.camera = Camera(origin: CGPoint(x: 3.3, y: 7.7), zoom: 1)
        let size = CGSize(width: 300, height: 200)
        // How many frames the grid drew clipped and unclipped, in that order, while `draw` ran.
        @MainActor func frames(_ draw: () throws -> Void) throws -> [Int] {
            let before = [h.editor.gridFramesClipped, h.editor.gridFramesUnclipped]
            try draw()
            return [h.editor.gridFramesClipped - before[0], h.editor.gridFramesUnclipped - before[1]]
        }
        @MainActor func bitmap(turned: Bool = false) throws {
            _ = try picture(size, scale: 2, turned: turned) {
                expect($0.bitsPerComponent > 0, "a bitmap has bits to a component")
                h.editor.draw(in: $0, bounds: $1, dirtyRect: $1)
            }
        }
        @MainActor func page() throws {
            try pdfPage(size) {
                expectEqual($0.bitsPerComponent, 0, "a PDF page isn't a bitmap")
                h.editor.draw(in: $0, bounds: $1, dirtyRect: $1)
            }
        }
        expectEqual(try frames { try bitmap() }, [1, 0], "a bitmap's copies are clipped")
        expectEqual(try frames(page), [0, 1], "a PDF page's aren't")
        h.editor.gridClipOverride = false
        expectEqual(try frames { try bitmap() }, [0, 1], "a bitmap's aren't, once the override says not to")
        h.editor.gridClipOverride = true
        expectEqual(try frames(page), [1, 0], "and a PDF page's are, once it says to")
        h.editor.gridClipOverride = nil
        expectEqual(try frames { try bitmap() }, [1, 0], "the context decides again")
        expectEqual(try frames(page), [0, 1], "for a PDF page too")
        expectEqual(try frames { try bitmap(turned: true) }, [0, 0], "turned a quarter, the grid is a path of ellipses: no copies")
        h.editor.camera = Camera(origin: CGPoint(x: .nan, y: 7.7), zoom: 1)
        expectEqual(try frames { try bitmap() }, [0, 0], "no grid at all")
        expectEqual(try frames(page), [0, 0], "in a PDF page too")
    },
])

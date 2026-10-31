import AppKit
@_spi(Host) import Canvas
import Geometry

/// Draws an editor offscreen, as the canvas view would, and returns the bitmap. With `clip` (view
/// points), only that is drawn, as AppKit clips a view to its dirty rect.
@MainActor
public func renderBitmap(_ editor: CanvasEditor, size: CGSize, scale: CGFloat = 1, clip: CGRect? = nil) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let cg = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    // Flip to the canvas's top-left origin, as a flipped NSView's context is.
    cg.translateBy(x: 0, y: size.height * scale)
    cg.scaleBy(x: scale, y: -scale)
    let bounds = CGRect(origin: .zero, size: size)
    if let clip { cg.clip(to: clip) }
    NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        editor.draw(in: cg, bounds: bounds, dirtyRect: clip ?? bounds)
        NSGraphicsContext.restoreGraphicsState()
    }
    return rep
}

/// Draws an editor as `renderBitmap(_:size:scale:)` does, then `editing`, the editing view of the
/// shape being edited (`editor.makeEditingView()`), over it, laid out as `CanvasView` lays it out
/// over its editing frame: its frame in view points, its bounds in world units, so AppKit scales it by the zoom. It's drawn
/// at the bitmap's scale from an unshown window, and taken out of it again, so a test can go on
/// typing into it. Only the editor's drawing, when no shape is being edited.
@MainActor
public func renderBitmap(_ editor: CanvasEditor, size: CGSize, scale: CGFloat = 1, editing: EditingView) -> NSBitmapImageRep {
    let rep = renderBitmap(editor, size: size, scale: scale)
    guard let box = editor.editingFrame else { return rep }
    let host = FlippedView(frame: CGRect(origin: .zero, size: size))
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = host
    host.addSubview(editing.view)
    defer { editing.view.removeFromSuperview() }
    editing.view.frame = editor.camera.toView(box)
    editing.view.bounds = CGRect(origin: .zero, size: box.size)
    host.layoutSubtreeIfNeeded()
    let overlay = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    overlay.size = size                                   // so the view draws at the bitmap's scale
    host.cacheDisplay(in: host.bounds, to: overlay)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    overlay.draw(in: CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh), from: .zero,
                 operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Where each line of text starts, in view points: the top of each run of rows in which `rep`
/// differs from `background` (the same drawing without the text) by more than a quarter in any
/// channel, within `rect`. Every pixel counts; `scale` is pixels per point, as for `pixel`.
@MainActor
public func lineTops(_ rep: NSBitmapImageRep, over background: NSBitmapImageRep, in rect: CGRect, scale: CGFloat? = nil) -> [CGFloat] {
    let scale = scale ?? CGFloat(rep.pixelsWide) / rep.size.width
    var p = [Int](repeating: 0, count: 4), q = [Int](repeating: 0, count: 4)
    var tops: [CGFloat] = []
    var previous = Int.min
    let raw = RawPair(rep, background)
    for y in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
        // A row the two draw alike has no ink in it (one memcmp, not a call a pixel).
        if let raw, Int(rect.maxX * scale) > Int(rect.minX * scale), raw.rowsEqual(y: y, from: Int(rect.minX * scale), to: Int(rect.maxX * scale)) { continue }
        let inked = (Int(rect.minX * scale)..<Int(rect.maxX * scale)).contains { x in
            if let raw { return raw.difference(atX: x, y: y) > 64 }
            rep.getPixel(&p, atX: x, y: y); background.getPixel(&q, atX: x, y: y)
            return zip(p, q).contains { abs($0 - $1) > 64 }
        }
        guard inked else { continue }
        if y != previous + 1 { tops.append(CGFloat(y) / scale) }
        previous = y
    }
    return tops
}

/// Two bitmaps' samples read straight from their data, when both are whole bytes in one plane laid
/// out alike and every byte of a pixel is a sample: what `getPixel` gives, without a call and two
/// arrays for every pixel. (A pixel with a byte that is no sample, as one drawn with its first byte
/// skipped has, puts its samples where getPixel knows and this doesn't: getPixel reads it.)
private struct RawPair {
    let a: UnsafeMutablePointer<UInt8>, b: UnsafeMutablePointer<UInt8>
    let rowA: Int, rowB: Int, channels: Int, bytesPerPixel: Int

    init?(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) {
        guard !a.isPlanar, !b.isPlanar, a.bitsPerSample == 8, b.bitsPerSample == 8, a.samplesPerPixel == b.samplesPerPixel,
              a.bitsPerPixel == b.bitsPerPixel, a.samplesPerPixel * 8 == a.bitsPerPixel,
              let pa = a.bitmapData, let pb = b.bitmapData else { return nil }
        (self.a, self.b, rowA, rowB, channels, bytesPerPixel) = (pa, pb, a.bytesPerRow, b.bytesPerRow, a.samplesPerPixel, a.bitsPerPixel / 8)
    }

    /// The largest difference in any channel between the pixels at (x, y). (Plain `while` and no generic calls: this is
    /// run a pixel at a time, in a build with no optimizer.)
    func difference(atX x: Int, y: Int) -> Int {
        let p = a + y * rowA + x * bytesPerPixel, q = b + y * rowB + x * bytesPerPixel
        var largest = 0, c = 0
        while c < channels {
            let d = Int(p[c]) - Int(q[c])
            let size = d < 0 ? -d : d
            if size > largest { largest = size }
            c += 1
        }
        return largest
    }

    /// Whether the pixels of columns `x0..<x1` of row `y` are the same bytes in both: every byte of a pixel is a sample, so
    /// then every difference there is 0. One `memcmp`, where the answer is mostly yes (a picture mostly of paper).
    func rowsEqual(y: Int, from x0: Int, to x1: Int) -> Bool {
        memcmp(a + y * rowA + x0 * bytesPerPixel, b + y * rowB + x0 * bytesPerPixel, (x1 - x0) * bytesPerPixel) == 0
    }

    /// Whether the pixels at (x, y) are the same bytes in both (the same as `difference(atX:y:) == 0`).
    func pixelsEqual(atX x: Int, y: Int) -> Bool {
        memcmp(a + y * rowA + x * bytesPerPixel, b + y * rowB + x * bytesPerPixel, bytesPerPixel) == 0
    }
}

/// The largest difference in any channel (0...255) between two bitmaps of one size, over every
/// pixel within a rect of view points (`scale` as for `pixel`), but for the pixels whose centers are
/// in `excluded`.
@MainActor
public func largestDifference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, in rect: CGRect, excluding excluded: [CGRect] = [], scale: CGFloat? = nil) -> Int {
    let scale = scale ?? CGFloat(a.pixelsWide) / a.size.width
    var largest = 0
    let raw = RawPair(a, b)
    var p = [Int](repeating: 0, count: 4), q = [Int](repeating: 0, count: 4)
    for y in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
        // A row the two draw alike adds no difference, whatever is excluded.
        if let raw, Int(rect.maxX * scale) > Int(rect.minX * scale), raw.rowsEqual(y: y, from: Int(rect.minX * scale), to: Int(rect.maxX * scale)) { continue }
        for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
            if !excluded.isEmpty {
                let center = CGPoint(x: (CGFloat(x) + 0.5) / scale, y: (CGFloat(y) + 0.5) / scale)
                guard !excluded.contains(where: { $0.contains(center) }) else { continue }
            }
            if let raw { largest = max(largest, raw.difference(atX: x, y: y)); continue }
            a.getPixel(&p, atX: x, y: y); b.getPixel(&q, atX: x, y: y)
            largest = max(largest, zip(p, q).map { abs($0 - $1) }.max() ?? 0)
        }
    }
    return largest
}

/// Every pixel at which two bitmaps of one size differ in any channel, as (x, y) in pixels, row by row.
@MainActor
public func differingPixelPositions(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> [(x: Int, y: Int)] {
    var found: [(x: Int, y: Int)] = []
    if let raw = RawPair(a, b) {
        for y in 0..<a.pixelsHigh {
            if a.pixelsWide > 0, raw.rowsEqual(y: y, from: 0, to: a.pixelsWide) { continue }
            var x = 0
            while x < a.pixelsWide {
                if !raw.pixelsEqual(atX: x, y: y) { found.append((x, y)) }
                x += 1
            }
        }
        return found
    }
    var p = [Int](repeating: 0, count: 4), q = [Int](repeating: 0, count: 4)
    for y in 0..<a.pixelsHigh {
        for x in 0..<a.pixelsWide {
            a.getPixel(&p, atX: x, y: y)
            b.getPixel(&q, atX: x, y: y)
            if p != q { found.append((x, y)) }
        }
    }
    return found
}

/// Draws a view as it is now, in its window (unshown will do), at the window's scale, with its
/// top-left at the bitmap's origin as `pixel` expects. Row highlights and backgrounds draw; a
/// source list's vibrant text and symbols may not.
@MainActor
public func snapshot(_ view: NSView) -> NSBitmapImageRep {
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep
}

/// The color at a view point, as 0...255 RGBA. `scale` is pixels per point; by default the
/// bitmap's own: 1 for `renderBitmap`'s (sized in pixels), the window's for a `snapshot`.
@MainActor
public func pixel(_ rep: NSBitmapImageRep, at point: CGPoint, scale: CGFloat? = nil) -> [Int] {
    let scale = scale ?? CGFloat(rep.pixelsWide) / rep.size.width
    var value = [Int](repeating: 0, count: 4)
    rep.getPixel(&value, atX: Int(point.x * scale), y: Int(point.y * scale))
    return value
}

/// A bitmap's colors in device RGB, exactly as `colorAt(x:y:)?.usingColorSpace(.deviceRGB)` gives
/// them, but each distinct pixel value converted once: read that way pixel by pixel, a panel's
/// render takes seconds.
@MainActor
public final class DeviceRGBPixels {
    public struct Color {
        public let red: CGFloat, green: CGFloat, blue: CGFloat
        /// The mean of the three.
        public var gray: CGFloat { (red + green + blue) / 3 }
    }

    private let rep: NSBitmapImageRep
    /// The pixels, when they're whole bytes in one plane (else each is converted as it's read).
    private let bytes: UnsafeMutablePointer<UInt8>?
    private let bytesPerRow: Int, bytesPerPixel: Int
    private var converted: [UInt64: Color?] = [:]
    /// The last pixel value read, and its color: neighbors are mostly alike.
    private var last: (value: UInt64, color: Color?)?

    public init(_ rep: NSBitmapImageRep) {
        self.rep = rep
        // The data first: a rep backed by a CGImage makes its bitmap, and so its layout, as it's asked for it.
        let data = rep.bitmapData
        bytesPerRow = rep.bytesPerRow
        bytesPerPixel = rep.bitsPerPixel / 8
        bytes = !rep.isPlanar && rep.bitsPerPixel % 8 == 0 && (1...8).contains(bytesPerPixel) ? data : nil
    }

    /// The color of the pixel at column `x`, row `y` from the top; nil where `colorAt` has none.
    public subscript(x: Int, y: Int) -> Color? {
        guard (0..<rep.pixelsWide).contains(x), (0..<rep.pixelsHigh).contains(y) else { return nil }
        guard let bytes else { return convert(x, y) }
        let pixel = UnsafeRawPointer(bytes + y * bytesPerRow + x * bytesPerPixel)
        var value: UInt64
        switch bytesPerPixel {
        case 4: value = UInt64(pixel.loadUnaligned(as: UInt32.self))
        case 8: value = pixel.loadUnaligned(as: UInt64.self)
        default:
            value = 0
            for i in 0..<bytesPerPixel { value = value << 8 | UInt64(pixel.load(fromByteOffset: i, as: UInt8.self)) }
        }
        if let last, last.value == value { return last.color }
        let color: Color?
        if let known = converted[value] {
            color = known
        } else {
            color = convert(x, y)
            converted[value] = color
        }
        last = (value, color)
        return color
    }

    private func convert(_ x: Int, _ y: Int) -> Color? {
        rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB).map { Color(red: $0.redComponent, green: $0.greenComponent, blue: $0.blueComponent) }
    }
}

/// How many points' pixels differ between two renders, within a rect of view points (at more than
/// 1×, a point's first pixel stands for it).
@MainActor
public func changedPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, in rect: CGRect) -> Int {
    // Bitmaps of a pixel a point (as `renderBitmap` makes them), the rect inside both: a row the two draw alike changed nothing,
    // one `memcmp`; in a row that differs, each point's pixel is read straight, as `pixel` would give it.
    let rows = Array(stride(from: rect.minY, to: rect.maxY, by: 1)), columns = stride(from: rect.minX, to: rect.maxX, by: 1).reduce(0) { n, _ in n + 1 }
    if a.size.width > 0, b.size.width > 0, CGFloat(a.pixelsWide) / a.size.width == 1, CGFloat(b.pixelsWide) / b.size.width == 1,
       rect.minX >= 0, rect.minY >= 0, let raw = RawPair(a, b), let last = rows.last,
       Int(rect.minX) + columns <= min(a.pixelsWide, b.pixelsWide), Int(last) < min(a.pixelsHigh, b.pixelsHigh) {
        let x0 = Int(rect.minX)
        var count = 0
        for y in rows {
            let row = Int(y)
            if columns == 0 || raw.rowsEqual(y: row, from: x0, to: x0 + columns) { continue }
            var x = x0
            while x < x0 + columns {
                if !raw.pixelsEqual(atX: x, y: row) { count += 1 }
                x += 1
            }
        }
        return count
    }
    return stride(from: rect.minY, to: rect.maxY, by: 1).reduce(0) { count, y in
        count + stride(from: rect.minX, to: rect.maxX, by: 1).count { x in pixel(a, at: CGPoint(x: x, y: y)) != pixel(b, at: CGPoint(x: x, y: y)) }
    }
}

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
    for y in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
        let inked = (Int(rect.minX * scale)..<Int(rect.maxX * scale)).contains { x in
            rep.getPixel(&p, atX: x, y: y); background.getPixel(&q, atX: x, y: y)
            return zip(p, q).contains { abs($0 - $1) > 64 }
        }
        guard inked else { continue }
        if y != previous + 1 { tops.append(CGFloat(y) / scale) }
        previous = y
    }
    return tops
}

/// The largest difference in any channel (0...255) between two bitmaps of one size, over every
/// pixel within a rect of view points (`scale` as for `pixel`).
@MainActor
public func largestDifference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, in rect: CGRect, scale: CGFloat? = nil) -> Int {
    let scale = scale ?? CGFloat(a.pixelsWide) / a.size.width
    var p = [Int](repeating: 0, count: 4), q = [Int](repeating: 0, count: 4)
    var largest = 0
    for y in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
        for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
            a.getPixel(&p, atX: x, y: y); b.getPixel(&q, atX: x, y: y)
            largest = max(largest, zip(p, q).map { abs($0 - $1) }.max() ?? 0)
        }
    }
    return largest
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
    stride(from: rect.minY, to: rect.maxY, by: 1).reduce(0) { count, y in
        count + stride(from: rect.minX, to: rect.maxX, by: 1).count { x in pixel(a, at: CGPoint(x: x, y: y)) != pixel(b, at: CGPoint(x: x, y: y)) }
    }
}

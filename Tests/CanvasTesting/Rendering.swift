import AppKit
@_spi(Host) import Canvas

/// Draws an editor offscreen, as the canvas view would, and returns the bitmap.
@MainActor
public func renderBitmap(_ editor: CanvasEditor, size: CGSize, scale: CGFloat = 1) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let cg = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    // Flip to the canvas's top-left origin, as a flipped NSView's context is.
    cg.translateBy(x: 0, y: size.height * scale)
    cg.scaleBy(x: scale, y: -scale)
    NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        let bounds = CGRect(origin: .zero, size: size)
        editor.draw(in: cg, bounds: bounds, dirtyRect: bounds)
        NSGraphicsContext.restoreGraphicsState()
    }
    return rep
}

/// The color at a view point, as 0...255 RGBA.
@MainActor
public func pixel(_ rep: NSBitmapImageRep, at point: CGPoint, scale: CGFloat = 1) -> [Int] {
    var value = [Int](repeating: 0, count: 4)
    rep.getPixel(&value, atX: Int(point.x * scale), y: Int(point.y * scale))
    return value
}

/// How many pixels differ between two renders, within a rect of view points.
@MainActor
public func changedPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, in rect: CGRect) -> Int {
    stride(from: rect.minY, to: rect.maxY, by: 1).reduce(0) { count, y in
        count + stride(from: rect.minX, to: rect.maxX, by: 1).count { x in pixel(a, at: CGPoint(x: x, y: y)) != pixel(b, at: CGPoint(x: x, y: y)) }
    }
}

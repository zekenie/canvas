// PNGs side by side at their own sizes (the same zoom stays the same zoom), each labeled above, on white: compose <out.png> <a.png> <label a> ...
import AppKit
let a = CommandLine.arguments
let out = a[1]
var cells: [(NSImage, String, NSSize)] = []
var i = 2
while i + 1 < a.count {
    let img = NSImage(contentsOfFile: a[i])!
    let rep = img.representations.first!
    cells.append((img, a[i + 1], NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)))
    i += 2
}
let gap: CGFloat = 48, head: CGFloat = 72
let size = NSSize(width: cells.map { $0.2.width }.reduce(0, +) + CGFloat(cells.count + 1) * gap, height: cells.map { $0.2.height }.max()! + head + 2 * gap)
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 34), .foregroundColor: NSColor.black]
var x = gap
for (img, label, s) in cells {
    let top = size.height - gap
    (label as NSString).draw(at: NSPoint(x: x, y: top - head + 16), withAttributes: attrs)
    img.draw(in: NSRect(x: x, y: top - head - s.height, width: s.width, height: s.height))
    NSColor(white: 0.8, alpha: 1).setStroke()
    NSBezierPath(rect: NSRect(x: x, y: top - head - s.height, width: s.width, height: s.height)).stroke()
    x += s.width + gap
}
NSGraphicsContext.restoreGraphicsState()
try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))

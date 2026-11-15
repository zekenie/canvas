// svg2png in.svg out.png scale: an SVG drawn by AppKit (NSImage reads SVG on macOS 14 and later) into a bitmap `scale` pixels to a unit.
import AppKit
let a = CommandLine.arguments
guard a.count >= 4, let scale = Double(a[3]) else { print("usage: svg2png in.svg out.png scale"); exit(2) }
guard let img = NSImage(contentsOf: URL(fileURLWithPath: a[1])) else { print("can't read \(a[1])"); exit(1) }
let w = Int((img.size.width * scale).rounded()), h = Int((img.size.height * scale).rounded())
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
img.draw(in: NSRect(x: 0, y: 0, width: w, height: h), from: .zero, operation: .copy, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
print("\(a[2]) \(w)x\(h)")

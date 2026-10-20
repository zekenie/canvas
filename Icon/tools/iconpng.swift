// iconpng: draw an app's (or any file's) icon as the system draws it, to a PNG.
// Usage: iconpng <path> <points> <out.png> [scale]   (a scale of 2 draws a Retina point as 2 pixels)
//        iconpng measure <png>      prints the opaque body's bounds and its corner's profile
//        iconpng pixel <png> <x> <y>  prints one pixel's r g b a, y from the top
import AppKit
import ImageIO
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

func write(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { fail("can't write \(path)") }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

let args = CommandLine.arguments
if args.count == 5, args[1] == "pixel", let x = Int(args[3]), let y = Int(args[4]) {
    // One pixel's stored bytes (no display conversion), y from the top: r g b a.
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fail("can't read \(args[2])") }
    let cg = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    cg.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let data = cg.data!.bindMemory(to: UInt8.self, capacity: image.width * image.height * 4)
    let i = (y * image.width + x) * 4
    print(data[i], data[i + 1], data[i + 2], data[i + 3])
    exit(0)
}
if args.count == 3, args[1] == "measure" {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fail("can't read \(args[2])") }
    let w = image.width, h = image.height
    let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    cg.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let data = cg.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
    func alpha(_ x: Int, _ y: Int) -> Int { Int(data[(y * w + x) * 4 + 3]) }   // y from the top
    for threshold in [250, 128, 8] {
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h { for x in 0..<w where alpha(x, y) >= threshold {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        print("alpha>=\(threshold): x \(minX)...\(maxX) (\(maxX - minX + 1)), y \(minY)...\(maxY) (\(maxY - minY + 1))")
    }
    // The top-left corner: for rows down from the body's top edge, where the body starts (alpha >= 128).
    var top = 0
    while top < h, !(0..<w).contains(where: { alpha($0, top) >= 128 }) { top += 1 }
    var profile: [String] = []
    for dy in [0, 1, 2, 4, 8, 16, 32, 48, 64, 96, 128, 160, 192, 224, 256] where top + dy < h {
        let y = top + dy
        let x = (0..<w).first(where: { alpha($0, y) >= 128 }) ?? -1
        profile.append("\(dy):\(x)")
    }
    print("top \(top); left edge by row below top: " + profile.joined(separator: " "))
    // The center pixel's color, and the body's color near the top edge.
    let cx = w / 2, cy = h / 2
    let i = (cy * w + cx) * 4
    print("center rgba \(data[i]) \(data[i+1]) \(data[i+2]) \(data[i+3])")
    exit(0)
}

guard args.count == 4 || args.count == 5, let points = Int(args[2]), let scale = Int(args.count == 5 ? args[4] : "1"), scale > 0 else {
    fail("usage: iconpng <path> <points> <out.png> [scale] | iconpng measure <png>")
}
let icon = NSWorkspace.shared.icon(forFile: args[1])
let px = points * scale
let cg = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Points as the screen has them, so the image picks the representation a Retina (or 1x) screen gets.
cg.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
NSGraphicsContext.current?.imageInterpolation = .high
icon.draw(in: NSRect(x: 0, y: 0, width: points, height: points), from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
write(cg.makeImage()!, to: args[3])

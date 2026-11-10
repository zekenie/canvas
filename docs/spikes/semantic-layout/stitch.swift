// Lays PNGs out in a grid on white and writes one JPEG. stitch <out.jpg> <columns> <a.png> ...
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
let a = CommandLine.arguments
let out = a[1], cols = Int(a[2])!, files = Array(a[3...])
let imgs = files.map { f -> CGImage in let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: f) as CFURL, nil)!; return CGImageSourceCreateImageAtIndex(s, 0, nil)! }
let cw = imgs.map { $0.width }.max()!, ch = imgs.map { $0.height }.max()!, gap = 24
let rows = (imgs.count + cols - 1) / cols
let W = cols * cw + (cols + 1) * gap, H = rows * ch + (rows + 1) * gap
let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.setFillColor(CGColor(red: 0.91, green: 0.9, blue: 0.88, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
for (i, im) in imgs.enumerated() {
  let r = i / cols, c = i % cols
  let x = gap + c * (cw + gap), y = H - (gap + r * (ch + gap)) - im.height
  ctx.draw(im, in: CGRect(x: x, y: y, width: im.width, height: im.height))
}
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
CGImageDestinationFinalize(dest)
print(out, W, "x", H)

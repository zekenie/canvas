// Lays PNGs out in a grid on white and writes one JPEG, with a header image across the top if one is given.
// stitch <out.jpg> <columns> [--head <head.png>] <a.png> ...
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
var a = CommandLine.arguments
var headFile: String? = nil
if let i = a.firstIndex(of: "--head") { headFile = a[i + 1]; a.removeSubrange(i...(i + 1)) }
let out = a[1], cols = Int(a[2])!, files = Array(a[3...])
func load(_ f: String) -> CGImage { let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: f) as CFURL, nil)!; return CGImageSourceCreateImageAtIndex(s, 0, nil)! }
let imgs = files.map(load), head = headFile.map(load)
let cw = imgs.map { $0.width }.max()!, ch = imgs.map { $0.height }.max()!, gap = 24
let rows = (imgs.count + cols - 1) / cols
let headH = head.map { $0.height + gap } ?? 0
let W = cols * cw + (cols + 1) * gap, H = rows * ch + (rows + 1) * gap + headH
let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.setFillColor(CGColor(red: 0.91, green: 0.9, blue: 0.88, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
if let h = head { ctx.draw(h, in: CGRect(x: gap, y: H - gap - h.height, width: h.width, height: h.height)) }
for (i, im) in imgs.enumerated() {
  let r = i / cols, c = i % cols
  let x = gap + c * (cw + gap), y = H - headH - (gap + r * (ch + gap)) - im.height
  ctx.draw(im, in: CGRect(x: x, y: y, width: im.width, height: im.height))
}
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
CGImageDestinationFinalize(dest)
print(out, W, "x", H)

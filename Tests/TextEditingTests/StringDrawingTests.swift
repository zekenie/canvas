import AppKit
import CanvasTesting
import TestKit
import TextEditing

// `StringDrawingLayout`: where string drawing puts a range of a string, held to the ink string
// drawing leaves in a bitmap.

/// `string` drawn as the canvas draws text (`draw(with:options: .usesLineFragmentOrigin)`) in `box`,
/// on white, in a flipped bitmap of `size` points.
@MainActor private func drawn(_ string: NSAttributedString, in box: CGRect, size: CGSize = CGSize(width: 400, height: 200)) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let cg = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    cg.translateBy(x: 0, y: size.height)
    cg.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
    cg.setFillColor(NSColor.white.cgColor)
    cg.fill(CGRect(origin: .zero, size: size))
    string.draw(with: box, options: [.usesLineFragmentOrigin])
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/// The leftmost and rightmost columns with ink in a band, between two x's.
@MainActor private func ink(_ rep: NSBitmapImageRep, band: ClosedRange<CGFloat>, from: CGFloat, to: CGFloat) -> ClosedRange<CGFloat>? {
    var low: CGFloat?, high: CGFloat?
    for x in stride(from: from, to: to, by: 1) {
        for y in stride(from: band.lowerBound, through: band.upperBound, by: 1) where pixel(rep, at: CGPoint(x: x, y: y)).prefix(3).allSatisfy({ $0 < 128 }) {
            low = low ?? x
            high = x
            break
        }
    }
    guard let low, let high else { return nil }
    return low...high
}

@MainActor private func attributes(_ alignment: NSTextAlignment) -> [NSAttributedString.Key: Any] {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    paragraph.minimumLineHeight = 20
    paragraph.maximumLineHeight = 20
    return [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.black, .paragraphStyle: paragraph]
}

@MainActor let stringDrawingTests = Suite("String drawing layout", [
    test("a range's rect is where its ink is, left-aligned and centered, a line tall") {
        for alignment in [NSTextAlignment.left, .center] {
            let string = NSAttributedString(string: "calls home", attributes: attributes(alignment))
            let box = CGRect(x: 20, y: 20, width: 200, height: 40)
            let layout = StringDrawingLayout(string, width: box.width)
            let rects = layout.lineRects(of: [NSRange(location: 6, length: 4), NSRange(location: 0, length: 5)], height: box.height)
            let home = try require(rects[0].first).offsetBy(dx: box.minX, dy: box.minY)
            let calls = try require(rects[1].first).offsetBy(dx: box.minX, dy: box.minY)
            expectEqual(home.height, 20)
            let image = drawn(string, in: box)
            let homeInk = try require(ink(image, band: (home.minY + 2)...(home.maxY - 2), from: calls.maxX + 1, to: box.maxX))
            let callsInk = try require(ink(image, band: (calls.minY + 2)...(calls.maxY - 2), from: box.minX, to: home.minX))
            for (rect, ink) in [(home, homeInk), (calls, callsInk)] {
                expect(ink.lowerBound >= rect.minX - 1 && ink.upperBound <= rect.maxX + 1, "\(alignment.rawValue): ink \(ink) inside \(rect)")
                expect(rect.minX >= ink.lowerBound - 3 && rect.maxX <= ink.upperBound + 3, "\(alignment.rawValue): \(rect) hugs \(ink)")
            }
        }
    },
    test("a range over two lines has a rect on each; one past the box's height has none; an empty range none") {
        let string = NSAttributedString(string: "one two three four five six", attributes: attributes(.left))
        let layout = StringDrawingLayout(string, width: 70, minimumLineHeight: 20)
        expect(layout.lines.count >= 3)
        let all = layout.lineRects(of: [NSRange(location: 0, length: string.length)])
        expectEqual(all[0].count, layout.lines.count)
        expectEqual(all[0].map(\.minY), layout.lines.map(\.top))
        let cut = layout.lineRects(of: [NSRange(location: 0, length: string.length)], height: 40)
        expectEqual(cut[0].count, 2, "two lines fit in 40")
        expectEqual(layout.lineRects(of: [NSRange(location: 3, length: 0), NSRange(location: 100, length: 2)]), [[], []])
    },
])

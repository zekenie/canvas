import AppKit
import CanvasTesting
import CoreGraphics
import TestKit

// CanvasTesting's bitmap comparisons (`largestDifference`, `differingPixelPositions`, `changedPixels`, `lineTops`) read the bytes
// of two bitmaps and pass over a row they share byte for byte (one `memcmp`, since a picture is mostly paper). Each is held here
// to what `getPixel` says of every pixel, over seeded bitmaps that differ in a few places, of layouts the raw reading takes and
// one it leaves to `getPixel`.

private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private enum Shape: CaseIterable {
    /// 8-bit RGBA with no padding, as `renderBitmap` makes it.
    case packed
    /// The same with 16 bytes after every row.
    case padded
    /// Three samples in four bytes (a pixel with a byte that is no sample): `getPixel` reads it.
    case skipped

    func make(width: Int, height: Int) -> NSBitmapImageRep {
        switch self {
        case .packed:
            NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                             isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        case .padded:
            NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                             isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4 + 16, bitsPerPixel: 32)!
        case .skipped:
            NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                             isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32)!
        }
    }
}

/// A pair of bitmaps of one size: paper (one flat color, a few bars), the second a copy of the first with `changes` pixels changed,
/// some in one channel only, one in the last channel alone.
@MainActor private func pair(_ shape: Shape, other: Shape, width: Int, height: Int, changes: Int, seed: UInt64) -> (NSBitmapImageRep, NSBitmapImageRep) {
    var random = SplitMix(seed: seed)
    let a = shape.make(width: width, height: height), b = other.make(width: width, height: height)
    let channels = a.samplesPerPixel
    var p = [Int](repeating: 0, count: 5)
    for y in 0..<height {
        for x in 0..<width {
            let bar = y % 17 == 3 && x > 5 && x < width - 5
            for c in 0..<channels { p[c] = bar ? Int(random.next() % 256) : 250 }
            a.setPixel(&p, atX: x, y: y)
            b.setPixel(&p, atX: x, y: y)
        }
    }
    for n in 0..<changes {
        let x = Int(random.next() % UInt64(width)), y = Int(random.next() % UInt64(height))
        b.getPixel(&p, atX: x, y: y)
        if n % 3 == 0 {
            p[channels - 1] = (p[channels - 1] + 1 + Int(random.next() % 250)) % 256
        } else {
            let c = Int(random.next() % UInt64(channels))
            p[c] = (p[c] + 1 + Int(random.next() % 250)) % 256
        }
        b.setPixel(&p, atX: x, y: y)
    }
    return (a, b)
}

@MainActor private func samples(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> [Int] {
    var p = [Int](repeating: 0, count: 5)
    rep.getPixel(&p, atX: x, y: y)
    return Array(p[0..<rep.samplesPerPixel])
}

@MainActor private func referenceDifference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, in rect: CGRect, excluding excluded: [CGRect]) -> Int {
    var largest = 0
    for y in Int(rect.minY)..<Int(rect.maxY) {
        for x in Int(rect.minX)..<Int(rect.maxX) {
            let center = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
            guard !excluded.contains(where: { $0.contains(center) }) else { continue }
            largest = max(largest, zip(samples(a, x, y), samples(b, x, y)).map { abs($0 - $1) }.max() ?? 0)
        }
    }
    return largest
}

@MainActor private func referenceChanged(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, in rect: CGRect) -> Int {
    stride(from: rect.minY, to: rect.maxY, by: 1).reduce(0) { count, y in
        count + stride(from: rect.minX, to: rect.maxX, by: 1).count { x in pixel(a, at: CGPoint(x: x, y: y)) != pixel(b, at: CGPoint(x: x, y: y)) }
    }
}

@MainActor private func referenceTops(_ rep: NSBitmapImageRep, over background: NSBitmapImageRep, in rect: CGRect) -> [CGFloat] {
    var tops: [CGFloat] = []
    var previous = Int.min
    for y in Int(rect.minY)..<Int(rect.maxY) {
        let inked = (Int(rect.minX)..<Int(rect.maxX)).contains { x in zip(samples(rep, x, y), samples(background, x, y)).contains { abs($0 - $1) > 64 } }
        guard inked else { continue }
        if y != previous + 1 { tops.append(CGFloat(y)) }
        previous = y
    }
    return tops
}

@MainActor let renderingHelperTests = Suite("Bitmap comparisons", [
    test("every comparison gives what getPixel says of each pixel, whether few pixels differ, many, or none, in packed, padded and byte-skipping bitmaps") {
        let width = 43, height = 31
        var seed: UInt64 = 0
        for (shape, other) in [(Shape.packed, Shape.packed), (.packed, .padded), (.padded, .packed), (.padded, .padded), (.skipped, .skipped)] {
            for changes in [0, 1, 2, 9, 120, 600] {
                seed += 1
                let (a, b) = pair(shape, other: other, width: width, height: height, changes: changes, seed: seed)
                let label = "\(shape) and \(other), \(changes) changes"
                let whole = CGRect(x: 0, y: 0, width: width, height: height)
                let inner = CGRect(x: 3, y: 5, width: 30, height: 21)
                let hole = [CGRect(x: 10, y: 8, width: 14, height: 12), CGRect(x: 25, y: 20, width: 5, height: 5)]
                expectEqual(largestDifference(a, b, in: whole), referenceDifference(a, b, in: whole, excluding: []), "the largest difference, \(label)")
                expectEqual(largestDifference(a, b, in: inner), referenceDifference(a, b, in: inner, excluding: []), "in a rect, \(label)")
                expectEqual(largestDifference(a, b, in: whole, excluding: hole), referenceDifference(a, b, in: whole, excluding: hole), "but for pixels, \(label)")
                var expected: [String] = []
                for y in 0..<height {
                    for x in 0..<width where samples(a, x, y) != samples(b, x, y) { expected.append("\(x),\(y)") }
                }
                expectEqual(differingPixelPositions(a, b).map { "\($0.x),\($0.y)" }, expected, "the differing pixels, \(label)")
                for rect in [whole, inner, CGRect(x: 3.5, y: 2.25, width: 30.5, height: 22), CGRect(x: 0, y: 0, width: 0, height: 5), CGRect(x: 20, y: 14, width: 23, height: 17)] {
                    expectEqual(changedPixels(a, b, in: rect), referenceChanged(a, b, in: rect), "changed points in \(rect), \(label)")
                }
                expectEqual(lineTops(a, over: b, in: whole), referenceTops(a, over: b, in: whole), "line tops, \(label)")
                expectEqual(lineTops(a, over: b, in: inner), referenceTops(a, over: b, in: inner), "line tops in a rect, \(label)")
            }
        }
    },
    test("a bitmap that differs in one pixel of the last row, the last column or the first is found, and only that") {
        for shape in Shape.allCases {
            for (x, y) in [(0, 0), (42, 30), (42, 0), (0, 30), (17, 13)] {
                let (a, b) = pair(shape, other: shape, width: 43, height: 31, changes: 0, seed: 7)
                var p = [Int](repeating: 0, count: 5)
                b.getPixel(&p, atX: x, y: y)
                p[0] = (p[0] + 100) % 256
                b.setPixel(&p, atX: x, y: y)
                expectEqual(differingPixelPositions(a, b).map { "\($0.x),\($0.y)" }, ["\(x),\(y)"], "\(shape) at \(x), \(y)")
                expectEqual(largestDifference(a, b, in: CGRect(x: 0, y: 0, width: 43, height: 31)), samplesDifference(a, b, x, y), "\(shape) at \(x), \(y)")
                expectEqual(changedPixels(a, b, in: CGRect(x: 0, y: 0, width: 43, height: 31)), 1, "\(shape) at \(x), \(y)")
            }
        }
    },
])

@MainActor private func samplesDifference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, _ x: Int, _ y: Int) -> Int {
    zip(samples(a, x, y), samples(b, x, y)).map { abs($0 - $1) }.max() ?? 0
}

import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Geometry
import TestKit

// A chip's number (`AdornmentLabel.counted(_:)`): after its text, in the text's ink softened, part of the chip's width, and
// kept whole where the text gives way. Alone: it knows nothing of what is counted.

/// How many pixels of two bitmaps differ in a rect, by more than a little in any channel.
@MainActor private func differing(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, in rect: CGRect) -> Int {
    stride(from: rect.minY, to: rect.maxY, by: 1).reduce(0) { count, y in
        count + stride(from: rect.minX, to: rect.maxX, by: 1).count {
            zip(pixel(a, at: CGPoint(x: $0, y: y)), pixel(b, at: CGPoint(x: $0, y: y))).contains { abs($0 - $1) > 24 }
        }
    }
}

/// Where a chip's one-figure number is: inside the capsule's right padding (7) and about a figure wide.
private func numberPlace(_ chip: CGRect) -> CGRect { CGRect(x: chip.maxX - 7 - 7, y: chip.minY + 4, width: 7, height: chip.height - 8) }

@MainActor let countTests = Suite("A chip's number", [
    test("a label carries a number, its copies keep it, and it is part of what makes two labels equal") {
        let label = AdornmentLabel("Role")
        expectEqual(label.count, nil)
        let counted = label.counted(3)
        expectEqual(counted.count, 3)
        expect(counted != label)
        expectEqual(counted, label.counted(3))
        expect(counted != label.counted(4))
        expectEqual(label.counted(nil), label)
        expectEqual(label.counted(-1), label, "a negative number is none")
        expectEqual(counted.wrong().count, 3)
        expectEqual(counted.tinted(solidTint).count, 3)
        expectEqual(counted.tagged(AdornmentTag("a")).count, 3)
        expectEqual(counted.opacity(0.5).count, 3)
        expectEqual(AdornmentLabel(systemImage: "lock").counted(2).count, nil, "a symbol alone has no text to follow")
    },
    test("the chip is wider by the gap and the number, and the number is drawn in the room it adds") {
        let (_, _, frame) = try tintedBoard(AdornmentLabel("Role"))
        let (h, _, counted) = try tintedBoard(AdornmentLabel("Role").counted(7))
        expectEqual(counted.minX, frame.minX, "the chip starts where it did")
        expect(counted.width > frame.width + 4 && counted.width < frame.width + 16,
               "wider by the gap and one figure: \(counted.width) against \(frame.width)")
        // Another figure (the system font's figures are a point or so apart in width): the capsule ends about where it did, and
        // only the number's place differs.
        let (other, _, near) = try tintedBoard(AdornmentLabel("Role").counted(1))
        expect(near.minX == counted.minX && abs(near.width - counted.width) <= 1.5, "\(near) against \(counted)")
        let place = numberPlace(near.width < counted.width ? near : counted)
        expect(differing(render(h), render(other), in: place) > 4, "the number is drawn at the right end: \(place)")
        expectEqual(differing(render(h), render(other), in: CGRect(x: counted.minX, y: counted.minY, width: frame.width - 8, height: counted.height)), 0,
                    "and nowhere else")
    },
    test("where the text gives way the number stays whole, at the chip's right end") {
        let long = "A relationship type whose name will not fit above the box"
        let (h, _, frame) = try tintedBoard(AdornmentLabel(long).counted(4))
        let (other, _, same) = try tintedBoard(AdornmentLabel(long).counted(1))
        let (_, _, cut) = try tintedBoard(AdornmentLabel(long))
        expect(frame.width <= boxFrame.width + 0.5 && cut.width <= boxFrame.width + 0.5, "cut to the box: \(frame.width), \(cut.width)")
        expect(same.minX == frame.minX && abs(same.width - frame.width) <= 1.5, "\(same) against \(frame)")
        let place = numberPlace(same.width < frame.width ? same : frame)
        expect(differing(render(h), render(other), in: place) > 4, "the number at the right end of a cut chip: \(place)")
    },
    test("a plain line takes no number: the room it would keep is never drawn") {
        let line = AdornmentLabel.line("from", ink: .secondary)
        expectEqual(line.counted(3).count, nil)
        expectEqual(line.counted(3), line)
    },
    test("the number is drawn in the dark appearance too, on a light tint") {
        let tint = AdornmentTint(.systemTeal, style: .light)
        let (h, _, counted) = try tintedBoard(AdornmentLabel("Role").tinted(tint).counted(7))
        let (other, _, near) = try tintedBoard(AdornmentLabel("Role").tinted(tint).counted(1))
        let place = numberPlace(near.width < counted.width ? near : counted)
        expect(differing(render(h, dark: true), render(other, dark: true), in: place) > 4, "the number in the dark: \(place)")
    },
    test("a plain line is drawn with no capsule, in its ink, the secondary softer than the primary, in both appearances") {
        let (primary, _, frame) = try tintedBoard(.line("from"))
        let (secondary, _, _) = try tintedBoard(.line("from", ink: .secondary))
        let plain = try adornedHarness([Contributor(id: "none") { $0.adornmentsForEveryShape(Chips.self) { _, _ in [] } }])
        plain.add(Box(boxFrame))
        for dark in [false, true] {
            let canvas = render(plain, dark: dark), strong = render(primary, dark: dark), soft = render(secondary, dark: dark)
            let clear = CGPoint(x: frame.midX, y: frame.minY + 1)
            expectEqual(pixel(strong, at: clear), pixel(canvas, at: clear), "no capsule, dark \(dark)")
            let text = frame.insetBy(dx: 1, dy: 2)
            let contrast = { (rep: NSBitmapImageRep) -> Int in
                let background = luminance(pixel(canvas, at: CGPoint(x: frame.midX, y: frame.minY + 1)))
                var most = 0
                for y in stride(from: text.minY, to: text.maxY, by: 1) {
                    for x in stride(from: text.minX, to: text.maxX, by: 1) { most = max(most, abs(luminance(pixel(rep, at: CGPoint(x: x, y: y))) - background)) }
                }
                return most
            }
            let a = contrast(strong), b = contrast(soft)
            expect(a > 60, "the primary ink reads, dark \(dark): \(a)")
            expect(b > 20 && b < a, "the secondary is softer, dark \(dark): \(b) against \(a)")
        }
    },
])

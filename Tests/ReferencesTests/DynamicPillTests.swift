import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Geometry
import Publishing
import References
import TestKit

// A dynamic pill once its query is answered, drawn to bitmaps in light and dark and zoomed out:
// every dynamic pill leads with the magnifier; a first-match one trails the first match's kind
// symbol in its tint, an All one its count in a capsule, one that found nothing (or was refused) a
// "0", dashed, and one whose answer failed the warning, dashed; while it's looked for it's solid with
// its words dimmed. And a direct pill's width keeps room for what may come to trail it: a short name
// gone private isn't cut short by its eye.

/// One answered state: how to build it, and what it must look like.
@MainActor private struct Answered {
    let name: String
    let dashed: Bool
    /// What trails: the first match's tinted symbol (`.symbol`), the count (`.badge`), the warning, or nothing.
    let trailing: Trailing
    let make: (EditorHarness) -> ShapeID

    enum Trailing { case nothing, symbol, badge, warning }
}

/// Two public boxes ("Alpha", "Beta") far below, out of view.
@MainActor private func targets(_ h: EditorHarness) {
    h.addBox("Alpha", at: CGRect(x: 100, y: 2_000, width: 100, height: 60))
    h.addBox("Beta", at: CGRect(x: 300, y: 2_000, width: 100, height: 60))
}

@MainActor private let answered: [Answered] = [
    Answered(name: "first match", dashed: false, trailing: .symbol) { h in h.addReference(words: "the boxes", query: "box") },
    Answered(name: "all matches", dashed: false, trailing: .badge) { h in h.addReference(words: "the boxes", query: "box", all: true) },
    Answered(name: "no matches", dashed: true, trailing: .badge) { h in h.addReference(words: "the tiles", query: "tile") },
    Answered(name: "refused", dashed: true, trailing: .badge) { h in h.addReference(words: "nobody", query: "\"Nobody\"") },
    Answered(name: "not interpreted", dashed: true, trailing: .nothing) { h in h.addReference(words: "blocked work") },
]

private func trailingBox(of frame: CGRect) -> CGRect {
    CGRect(x: frame.maxX - 14 - 30, y: frame.midY - 9, width: 30, height: 18)
}

@MainActor private func ink(_ rep: NSBitmapImageRep, in rect: CGRect, over background: [Int]) -> Int {
    stride(from: rect.minY, to: rect.maxY, by: 1).reduce(0) { count, y in
        count + stride(from: rect.minX, to: rect.maxX, by: 1).count { x in
            zip(pixel(rep, at: CGPoint(x: x, y: y)), background).contains { abs($0 - $1) > 24 }
        }
    }
}

/// How many pixels in `rect` differ much from the same pixel of `canvas` (where the canvas, its dots
/// among it, shows through a pill with no fill).
@MainActor private func ink(_ rep: NSBitmapImageRep, over canvas: NSBitmapImageRep, in rect: CGRect) -> Int {
    stride(from: rect.minY, to: rect.maxY, by: 1).reduce(0) { count, y in
        count + stride(from: rect.minX, to: rect.maxX, by: 1).count { x in
            zip(pixel(rep, at: CGPoint(x: x, y: y)), pixel(canvas, at: CGPoint(x: x, y: y))).contains { abs($0 - $1) > 24 }
        }
    }
}

/// How many pixels in `rect` are a strong color, red over blue (`orange`) or blue over red.
@MainActor private func tinted(_ rep: NSBitmapImageRep, in rect: CGRect, orange: Bool) -> Int {
    var count = 0
    for y in Int(rect.minY)..<Int(rect.maxY) {
        for x in Int(rect.minX)..<Int(rect.maxX) {
            let p = pixel(rep, at: CGPoint(x: x, y: y))
            if orange ? p[0] > p[2] + 60 : p[2] > p[0] + 60 { count += 1 }
        }
    }
    return count
}

@MainActor let dynamicPillTests = Suite("A dynamic pill's look", [
    test("answered, in light and dark: the magnifier first; the first match's symbol, the count or a 0 trailing; dashed when it found nothing") {
        for dark in [false, true] {
            let canvas = render(try referenceHarness().editor, dark: dark)
            let fill = dark ? [44, 44, 46] : [255, 255, 255]
            for item in answered {
                let h = try referenceHarness()
                targets(h)
                let id = item.make(h)
                h.answer()
                let frame = try require(h.editor.document[id]?.box)
                let drawn = render(h.editor, dark: dark)
                let what = "\(item.name), \(dark ? "dark" : "light")"
                let inside = CGPoint(x: frame.minX + 48, y: frame.minY + 4)
                let background = item.dashed ? pixel(canvas, at: inside) : fill
                if item.dashed {
                    expectEqual(pixel(drawn, at: inside), pixel(canvas, at: inside), "\(what): no fill")
                } else {
                    expectColor(pixel(drawn, at: inside), fill, "\(what): its surface", within: 2)
                }
                let symbol = CGRect(x: frame.minX + 10, y: frame.midY - 8, width: 16, height: 16)
                expect(ink(drawn, in: symbol, over: background) > 6, "\(what): the magnifier")
                let trailing = trailingBox(of: frame)
                let inked = item.dashed ? ink(drawn, over: canvas, in: trailing) : ink(drawn, in: trailing, over: background)
                switch item.trailing {
                case .nothing:
                    expectEqual(inked, 0, "\(what): nothing trails")
                case .symbol:
                    expect(tinted(drawn, in: trailing, orange: true) > 6, "\(what): the first match's symbol, in the box's orange")
                case .badge:
                    expect(inked > 6, "\(what): a count")
                    expectEqual(tinted(drawn, in: trailing, orange: true), 0, "\(what): no symbol, no warning")
                case .warning:
                    expect(tinted(drawn, in: trailing, orange: true) > 6, "\(what): the warning")
                }
            }
        }
    },
    test("the count is what it stands for, '50+' past fifty, and a pill that found nothing says 0: each drawn differently") {
        let h = try referenceHarness()
        targets(h)
        let all = h.addReference(words: "the boxes", query: "box", all: true)
        h.answer()
        let frame = try require(h.editor.document[all]?.box)
        let two = render(h.editor)
        for index in 0..<3 { h.addBox("More \(index)", at: CGRect(x: CGFloat(index) * 120, y: 2_200, width: 100, height: 60)) }
        h.answer(after: 250)
        let five = render(h.editor)
        expect(changedPixels(two, five, in: trailingBox(of: frame)) > 6, "2 then 5")
        expectEqual(changedPixels(two, five, in: CGRect(x: frame.minX, y: frame.minY, width: frame.width - 44, height: 32)), 0,
                    "and nothing else of the pill: no refit")
    },
    test("while it's looked for it's solid, its words dimmer than once answered, and nothing trails") {
        let h = try referenceHarness()
        targets(h)
        let id = h.addReference(words: "the boxes", query: "box", all: true)
        let frame = try require(h.editor.document[id]?.box)
        let finding = render(h.editor)
        expectColor(pixel(finding, at: CGPoint(x: frame.minX + 48, y: frame.minY + 4)), [255, 255, 255], "its surface", within: 2)
        expectEqual(ink(finding, in: trailingBox(of: frame), over: [255, 255, 255]), 0, "no count yet")
        h.answer()
        let found = render(h.editor)
        let label = CGRect(x: frame.minX + 32, y: frame.midY - 8, width: 40, height: 16)
        let darkest = { (rep: NSBitmapImageRep) -> Int in
            var least = 255
            for y in Int(label.minY)..<Int(label.maxY) {
                for x in Int(label.minX)..<Int(label.maxX) { least = min(least, pixel(rep, at: CGPoint(x: x, y: y))[0]) }
            }
            return least
        }
        expect(darkest(finding) > darkest(found) + 40, "dimmed while finding: \(darkest(finding)) against \(darkest(found))")
    },
    test("a failed answer trails the warning, dashed") {
        let slow = SlowNames()
        let h = try referenceHarness(names: slowNames(slow))
        slow.h = h
        targets(h)
        slow.armed = true
        let id = h.addReference(words: "alpha", query: "\"Alpha\"")
        h.answer()
        expectEqual(h.status(id), .failed(.tooSlow))
        let canvas = render(try referenceHarness().editor)
        let frame = try require(h.editor.document[id]?.box)
        let drawn = render(h.editor)
        expectEqual(pixel(drawn, at: CGPoint(x: frame.minX + 48, y: frame.minY + 4)), pixel(canvas, at: CGPoint(x: frame.minX + 48, y: frame.minY + 4)), "dashed, no fill")
        expect(tinted(drawn, in: trailingBox(of: frame), orange: true) > 6, "the warning, orange")
    },
    test("zoomed out, the lighter square for a pill that found nothing, the full one for a pill that found shapes") {
        for dark in [false, true] {
            for (item, nothing) in [(answered[0], false), (answered[1], false), (answered[2], true), (answered[3], true), (answered[4], true)] {
                let h = try referenceHarness()
                targets(h)
                let id = item.make(h)
                h.answer()
                h.editor.camera = Camera(origin: .zero, zoom: 0.3)
                let frame = try require(h.editor.document[id]?.box)
                let drawn = render(h.editor, dark: dark)
                let center = CGPoint(x: frame.midX * 0.3, y: frame.midY * 0.3)
                let expected: [Int] = switch (dark, nothing) {
                case (false, false): [216, 216, 221]
                case (false, true): [236, 236, 239]
                case (true, false): [74, 74, 78]
                case (true, true): [58, 58, 60]
                }
                expectColor(pixel(drawn, at: center), expected, "\(item.name), \(dark ? "dark" : "light"): the skeleton's fill", within: 2)
            }
        }
    },
    test("a direct pill keeps room for what may trail it: a short name gone private shows whole beside its eye, and so with a warning") {
        let h = try referenceHarness()
        let secret = h.addBox("Secret")
        let id = h.addReference(to: secret, label: "Secret")
        let frame = try require(h.editor.document[id]?.box)
        let font = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 14, weight: .medium), toHaveTrait: .italicFontMask)
        let whole = NSAttributedString(string: "Secret", attributes: [.font: font]).size().width
        let room = frame.width - 10 - 16 - 6 - 14 - 11 - 6
        expect(room >= whole, "the label's room beside the eye, \(room), takes the name in italic, \(whole)")
        let canvas = render(try referenceHarness().editor)
        h.editor.transact { $0.update(secret) { $0[PublicProperty.self] = nil } }
        let drawn = render(h.editor)
        // The name, whole, reaches the end of its room's width; an ellipsis after "S" would leave most of it bare.
        let tail = CGRect(x: frame.minX + 32 + whole * 0.6, y: frame.midY - 8, width: whole * 0.35, height: 16)
        expect(ink(drawn, over: canvas, in: tail) > 6, "its last letters are drawn")
        let eye = CGRect(x: frame.maxX - 14 - 11, y: frame.midY - 6, width: 11, height: 12)
        expect(ink(drawn, over: canvas, in: eye) > 6, "beside the eye")
    },
])

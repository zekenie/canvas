import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Geometry
import Publishing
import References
import TestKit
import Titles

// The pill's look in every state, drawn to bitmaps: light and dark, at 100% and zoomed out (a
// skeleton). A capsule, 32 tall, filled and bordered, or, standing for nothing, dashed and unfilled;
// a leading symbol (the kind of what it stands for, tinted; a magnifier for words; a dashed square
// for what's gone), its label, and what trails (the eye, once the shape went private).

/// One state of the pill: how to build the board it's on, and what it must look like.
@MainActor private struct Case {
    let name: String
    /// Draws a dashed, unfilled pill: it stands for nothing.
    let dashed: Bool
    let hasSymbol: Bool
    let hasTrailing: Bool
    let make: (EditorHarness) -> ShapeID
}

@MainActor private let cases: [Case] = [
    Case(name: "direct, live", dashed: false, hasSymbol: true, hasTrailing: false) { h in h.addReference(to: h.addBox("shapes"), label: "shapes") },
    Case(name: "direct, missing", dashed: true, hasSymbol: true, hasTrailing: false) { h in h.addReference(to: ShapeID(), label: "Old roadmap") },
    Case(name: "direct, unavailable (a kind that can't be mentioned)", dashed: true, hasSymbol: true, hasTrailing: false) { h in
        h.addReference(to: h.add(Disc(boxFrame)), label: "A disc")
    },
    Case(name: "direct, private", dashed: true, hasSymbol: true, hasTrailing: true) { h in
        h.addReference(to: h.addBox("Pricing and plans", public: false), label: "Pricing and plans")
    },
    Case(name: "dynamic, not interpreted", dashed: true, hasSymbol: true, hasTrailing: false) { h in h.addReference(words: "blocked work") },
    Case(name: "dynamic, finding", dashed: false, hasSymbol: true, hasTrailing: false) { h in h.addReference(words: "payment notes", query: "box") },
    Case(name: "empty", dashed: false, hasSymbol: false, hasTrailing: false) { h in h.addEmptyReference() },
]

/// The pill's frame, and a few places in it, in view points at 100% (the board is at the origin).
private struct Places {
    let frame: CGRect
    /// On the fill, above the label and the symbol.
    var inside: CGPoint { CGPoint(x: frame.minX + 48, y: frame.minY + 4) }
    /// On its top border.
    var border: CGPoint { CGPoint(x: frame.minX + 48, y: frame.minY) }
    var symbol: CGRect { CGRect(x: frame.minX + 10, y: frame.midY - 8, width: 16, height: 16) }
    var label: CGRect { CGRect(x: frame.minX + 32, y: frame.midY - 8, width: 20, height: 16) }
    var trailing: CGRect { CGRect(x: frame.maxX - 25, y: frame.midY - 6, width: 11, height: 12) }
}

@MainActor private func ink(_ rep: NSBitmapImageRep, in rect: CGRect, over background: [Int]) -> Int {
    stride(from: rect.minY, to: rect.maxY, by: 1).reduce(0) { count, y in
        count + stride(from: rect.minX, to: rect.maxX, by: 1).count { x in
            zip(pixel(rep, at: CGPoint(x: x, y: y)), background).contains { abs($0 - $1) > 24 }
        }
    }
}

@MainActor private func blank(dark: Bool) throws -> NSBitmapImageRep {
    render(try referenceHarness().editor, dark: dark)
}

@MainActor let pillTests = Suite("The pill's look", [
    test("every state in light and dark: a capsule, filled and bordered, or dashed with no fill when it stands for nothing; its symbol, label and what trails") {
        for dark in [false, true] {
            let canvas = try blank(dark: dark)
            let fill = dark ? [44, 44, 46] : [255, 255, 255]
            for item in cases {
                let h = try referenceHarness()
                let id = item.make(h)
                // Wide, so what's at its trailing end is alone there.
                h.editor.transact { $0.update(id, as: Reference.self) { $0.props.frame.size.width = 220 } }
                let places = Places(frame: try require(h.editor.document[id]).box ?? .zero)
                expectEqual(places.frame.height, 40, "\(item.name): a pill is 40 tall")
                let drawn = render(h.editor, dark: dark)
                let what = "\(item.name), \(dark ? "dark" : "light")"
                if item.dashed {
                    expectEqual(pixel(drawn, at: places.inside), pixel(canvas, at: places.inside), "\(what): no fill, the canvas shows through")
                    let border = changedPixels(canvas, drawn, in: CGRect(x: places.frame.minX + 40, y: places.frame.minY - 1, width: 8, height: 3))
                    expect(border > 0, "\(what): a dashed border")
                } else {
                    expectColor(pixel(drawn, at: places.inside), fill, "\(what): its surface", within: 2)
                    let edge = pixel(drawn, at: places.border)
                    expect(edge != fill, "\(what): a border, over its surface: \(edge)")
                }
                if item.hasSymbol {
                    expect(ink(drawn, in: places.symbol, over: item.dashed ? pixel(canvas, at: places.symbol.origin) : fill) > 6, "\(what): its leading symbol")
                }
                expect(ink(drawn, in: places.label.insetBy(dx: 0, dy: -2).offsetBy(dx: item.hasSymbol ? 0 : -22, dy: 0),
                           over: item.dashed ? pixel(canvas, at: places.symbol.origin) : fill) > 10, "\(what): its label")
                expectEqual(ink(drawn, in: places.trailing, over: item.dashed ? pixel(canvas, at: places.trailing.origin) : fill) > 6, item.hasTrailing,
                            "\(what): the eye of a shape gone private, and nothing else trailing")
            }
        }
    },
    test("a pill for a shape with no color leads with a gray symbol, in both appearances: the kind's tint is the color book's to give") {
        for dark in [false, true] {
            let h = try referenceHarness()
            let live = h.addReference(to: h.addBox("shapes"), label: "shapes")
            let frame = try require(h.editor.document[live]).box ?? .zero
            let drawn = render(h.editor, dark: dark)
            var colored = 0, inked = 0
            for y in Int(frame.midY - 8)..<Int(frame.midY + 8) {
                for x in Int(frame.minX + 10)..<Int(frame.minX + 26) {
                    let p = pixel(drawn, at: CGPoint(x: x, y: y))
                    if abs(p[0] - p[2]) > 30 { colored += 1 }
                    if abs(p[0] - (dark ? 44 : 255)) > 40 { inked += 1 }
                }
            }
            expect(inked > 10, "the symbol is drawn (\(dark ? "dark" : "light")): \(inked) pixels")
            expectEqual(colored, 0, "and it is gray, as the neutral pill's: \(dark ? "dark" : "light")")
        }
    },
    test("a label that doesn't fit is cut off with an ellipsis, never wider than the pill: a long name's pill is 280 wide at most") {
        let h = try referenceHarness()
        let name = String(repeating: "A rather long name ", count: 10)
        let id = h.addReference(to: h.addBox(name), label: name)
        let frame = try require(h.editor.document[id]).box ?? .zero
        expectEqual(frame.width, 280)
        let drawn = render(h.editor)
        let beyond = CGRect(x: frame.maxX + 2, y: frame.minY, width: 30, height: 32)
        expectEqual(changedPixels(try blank(dark: false), drawn, in: beyond), 0, "nothing drawn past it")
    },
    test("zoomed out, one square fill: no text, no rounding; the lighter one when it stands for nothing, in light and dark") {
        for dark in [false, true] {
            for item in cases {
                let h = try referenceHarness()
                let id = item.make(h)
                h.editor.camera = Camera(origin: .zero, zoom: 0.3)
                let frame = try require(h.editor.document[id]).box ?? .zero
                let drawn = render(h.editor, dark: dark)
                let box = CGRect(x: frame.minX * 0.3, y: frame.minY * 0.3, width: frame.width * 0.3, height: frame.height * 0.3)
                let expected: [Int] = switch (dark, item.dashed) {
                case (false, false): [216, 216, 221]
                case (false, true): [236, 236, 239]
                case (true, false): [74, 74, 78]
                case (true, true): [58, 58, 60]
                }
                let what = "\(item.name), \(dark ? "dark" : "light")"
                // Every pixel inside is that fill: no text, no symbol, a square corner.
                for point in [CGPoint(x: box.minX + 1, y: box.minY + 1), CGPoint(x: box.midX, y: box.midY), CGPoint(x: box.maxX - 2, y: box.maxY - 2),
                              CGPoint(x: box.minX + box.width / 3, y: box.midY)] {
                    expectColor(pixel(drawn, at: point), expected, "\(what): the skeleton's fill at \(point)", within: 2)
                }
            }
        }
    },
    test("a pill being typed into draws its capsule and symbol and leaves its label to the editing view") {
        let h = try referenceHarness()
        let id = h.addReference(to: h.addBox("shapes"), label: "shapes")
        let frame = try require(h.editor.document[id]).box ?? .zero
        let places = Places(frame: frame)
        let plain = render(h.editor)
        h.editor.beginEditing(id)
        let editing = render(h.editor)
        expect(ink(plain, in: places.label, over: [255, 255, 255]) > 10, "its label, as it is")
        expectEqual(ink(editing, in: places.label, over: [255, 255, 255]), 0, "left to the editing view while it's edited")
        expect(ink(editing, in: places.symbol, over: [255, 255, 255]) > 6, "its symbol stays")
    },
    test("a rename of what it stands for is drawn on the next frame, and what's drawn follows a shape made private") {
        let h = try referenceHarness()
        let box = h.addBox("shapes")
        let id = h.addReference(to: box, label: "shapes")
        let places = Places(frame: try require(h.editor.document[id]).box ?? .zero)
        let live = render(h.editor)
        h.editor.transact { $0.update(box) { $0[TitleProperty.self] = "renamed" } }
        let renamed = render(h.editor)
        expect(changedPixels(live, renamed, in: places.frame) > 20, "the new name")
        h.editor.transact { $0.update(box) { $0[PublicProperty.self] = nil } }
        let hidden = render(h.editor)
        expectEqual(pixel(hidden, at: places.inside), pixel(try blank(dark: false), at: places.inside), "dashed: no fill once the shape is private")
    },
])

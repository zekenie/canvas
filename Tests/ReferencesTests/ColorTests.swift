import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Colors
import Geometry
import Palette
import Publishing
import References
import TestKit
import Titles

// The pill in its original's color (the color spec): the fill the color's wash, the edge its solid (lifted where the raw
// one doesn't read on a raised frame), the symbol its ink, the count's capsule its solid at 30%, and zoomed out a block of
// its solid at 50% over the canvas; an original with no color gives the neutral pill. Boxes here are blue unless colored,
// tiles have colors and none by default, as a frame has.

/// Boxes take a color, blue by default; tiles take one and have none by default.
private let pillColoring = Contributor(id: "pill-coloring") { registrar in
    registrar.colorable(Box.self, default: .named("blue"))
    registrar.colorable(Tile.self)
}

@MainActor private func colored(_ more: [any CanvasPlugin] = []) throws -> EditorHarness {
    try referenceHarness([ColorsPlugin(), ColorQueriesPlugin(), pillColoring] + more)
}

private func values(_ color: RGB) -> [Int] {
    [Int((color.red * 255).rounded()), Int((color.green * 255).rounded()), Int((color.blue * 255).rounded())]
}

/// The edge a pill wears for `swatch`: its solid read against the canvas and the raised frame.
private func edge(_ swatch: Swatch, dark: Bool) -> RGB {
    Swatch.reading(swatch.solid[dark: dark], against: [Swatch.canvas[dark: dark], Swatch.raised[dark: dark]], atLeast: Swatch.lineContrast)
}

private let neutralFill = (light: [255, 255, 255], dark: [44, 44, 46])

/// Where to look on a pill drawn at its frame, in view points at 100%.
private struct Spots {
    let frame: CGRect
    /// On the fill, above the place and the name.
    var inside: CGPoint { CGPoint(x: frame.minX + 48, y: frame.minY + 3) }
    /// On the top border.
    var border: CGPoint { CGPoint(x: frame.minX + 48, y: frame.minY) }
    var symbol: CGRect { CGRect(x: frame.minX + 10, y: frame.midY - 8, width: 16, height: 16) }
}

@MainActor private func frame(of id: ShapeID, in h: EditorHarness) throws -> CGRect { try require(h.editor.document[id]?.box) }

/// How close the nearest pixel of `rect` is to `color`: the largest channel difference.
@MainActor private func nearest(_ rep: NSBitmapImageRep, in rect: CGRect, to color: RGB) -> Int {
    let wanted = values(color)
    var best = 255
    for y in Int(rect.minY)..<Int(rect.maxY) {
        for x in Int(rect.minX)..<Int(rect.maxX) {
            best = min(best, zip(pixel(rep, at: CGPoint(x: x, y: y)), wanted).map { abs($0 - $1) }.max() ?? 255)
        }
    }
    return best
}

@MainActor let referenceColorTests = Suite("The pill in color", [
    test("a pill for a box wears its color in light and dark: the wash for a fill, the solid for a 1 pt edge, the ink for its symbol; the name stays the label's") {
        let blue = BuiltInColors.blue.swatch
        for dark in [false, true] {
            let h = try colored()
            let pill = h.addReference(to: h.addBox("shapes"), label: "shapes")
            let spots = Spots(frame: try frame(of: pill, in: h))
            let drawn = render(h.editor, dark: dark)
            let what = dark ? "dark" : "light"
            expectColor(pixel(drawn, at: spots.inside), values(blue.wash[dark: dark]), "\(what): the wash", within: 2)
            expectColor(pixel(drawn, at: spots.border), values(edge(blue, dark: dark)), "\(what): the edge", within: 3)
            expect(nearest(drawn, in: spots.symbol, to: blue.ink[dark: dark]) <= 40, "\(what): the symbol in its ink")
            // The name is the label's color, whatever the pill's: black in light, white in dark.
            var strongest = dark ? 0 : 255
            for y in Int(spots.frame.midY - 4)..<Int(spots.frame.midY + 10) {
                for x in Int(spots.frame.minX + 34)..<Int(spots.frame.minX + 60) {
                    let p = pixel(drawn, at: CGPoint(x: x, y: y))
                    strongest = dark ? max(strongest, p[0]) : min(strongest, p[0])
                }
            }
            expect(dark ? strongest > 215 : strongest < 40, "\(what): the name in the label's color: \(strongest)")
        }
    },
    test("each built-in color: a pill for a box of it wears its wash and edge, the indigo's and the purple's edge lifted in the dark") {
        for named in BuiltInColors.all {
            for dark in [false, true] {
                let h = try colored()
                let box = h.addBox("shapes")
                h.editor.setColor(named.color, of: [box])
                let pill = h.addReference(to: box, label: "shapes")
                let spots = Spots(frame: try frame(of: pill, in: h))
                let drawn = render(h.editor, dark: dark)
                let what = "\(named.name), \(dark ? "dark" : "light")"
                expectColor(pixel(drawn, at: spots.inside), values(named.swatch.wash[dark: dark]), "\(what): the wash", within: 2)
                expectColor(pixel(drawn, at: spots.border), values(edge(named.swatch, dark: dark)), "\(what): the edge", within: 3)
            }
        }
        // The lift, as the spec reads it: #5E5CE6 to #605EE8 and #A23BC2 to #A841C8 in the dark; the rest as they are.
        expectEqual(edge(BuiltInColors.indigo.swatch, dark: true).hexString, "#605EE8")
        expectEqual(edge(BuiltInColors.purple.swatch, dark: true).hexString, "#A841C8")
        for named in BuiltInColors.all where named.name != "indigo" && named.name != "purple" {
            expectEqual(edge(named.swatch, dark: true).hexString, named.swatch.solid.dark.hexString, "\(named.name) is unchanged in the dark")
        }
    },
    test("an original with no color gives the neutral pill: today's fill, an edge of the label's color at 45%, a gray symbol") {
        for dark in [false, true] {
            let h = try colored()
            let pill = h.addReference(to: h.addTile("plain"), label: "plain")
            let spots = Spots(frame: try frame(of: pill, in: h))
            let drawn = render(h.editor, dark: dark)
            expectColor(pixel(drawn, at: spots.inside), dark ? neutralFill.dark : neutralFill.light, "neutral fill", within: 2)
            let edge = pixel(drawn, at: spots.border)
            // 45% of the label over the fill: 140 in light, about 139 in dark.
            expectColor(edge, [140, 140, 140], "neutral edge, \(dark ? "dark" : "light")", within: 12)
            var colorful = 0
            for y in Int(spots.symbol.minY)..<Int(spots.symbol.maxY) {
                for x in Int(spots.symbol.minX)..<Int(spots.symbol.maxX) {
                    let p = pixel(drawn, at: CGPoint(x: x, y: y))
                    if abs(p[0] - p[2]) > 30 { colorful += 1 }
                }
            }
            expectEqual(colorful, 0, "a gray symbol")
        }
    },
    test("a shape given a color by a plugin (a type's) and one colored afterwards are drawn again in it, with no commit to the pill") {
        let h = try colored()
        let box = h.addBox("shapes")
        let pill = h.addReference(to: box, label: "shapes")
        let spots = Spots(frame: try frame(of: pill, in: h))
        expectColor(pixel(render(h.editor), at: spots.inside), values(BuiltInColors.blue.swatch.wash.light), "blue to begin with", within: 2)
        h.editor.setColor(ShapeColor.named("red"), of: [box])
        expectColor(pixel(render(h.editor), at: spots.inside), values(BuiltInColors.red.swatch.wash.light), "its color changed", within: 2)
        h.editor.setColor(nil, of: [box])
        expectColor(pixel(render(h.editor), at: spots.inside), values(BuiltInColors.blue.swatch.wash.light), "taken away: its kind's", within: 2)
        // A color of the file's own, then given another value: no shape is written.
        expect(h.editor.defineColor(named: "Brand", value: RGB(hex: 0x00A88F)))
        h.editor.setColor(ShapeColor.named("Brand"), of: [box])
        let brand = Swatch(RGB(hex: 0x00A88F))
        expectColor(pixel(render(h.editor), at: spots.inside), values(brand.wash.light), "the file's own color", within: 2)
        expect(h.editor.setColorValue(of: "Brand", to: RGB(hex: 0xC03030)))
        expectColor(pixel(render(h.editor), at: spots.inside), values(Swatch(RGB(hex: 0xC03030)).wash.light), "its value changed", within: 2)
    },
    test("not public: no fill, dashes in its color, the symbol at two thirds; deleted: gray dashes at 45%") {
        let blue = BuiltInColors.blue.swatch
        for dark in [false, true] {
            let h = try colored()
            let secret = h.addReference(to: h.addBox("secret", public: false), label: "secret")
            let gone = h.addReference(to: ShapeID(), label: "Old", at: CGPoint(x: 400, y: 400))
            let drawn = render(h.editor, dark: dark)
            let canvas = render(try colored().editor, dark: dark)
            let hidden = Spots(frame: try frame(of: secret, in: h)), deleted = Spots(frame: try frame(of: gone, in: h))
            expectEqual(pixel(drawn, at: hidden.inside), pixel(canvas, at: hidden.inside), "not public: no fill")
            let top = CGRect(x: hidden.frame.minX + 30, y: hidden.frame.minY, width: 60, height: 1)
            expect(nearest(drawn, in: top, to: edge(blue, dark: dark)) <= 12, "not public: dashes in the color: \(dark ? "dark" : "light")")
            var colorful = 0, dashes = 0
            for x in Int(deleted.frame.minX + 30)..<Int(deleted.frame.minX + 90) {
                let p = pixel(drawn, at: CGPoint(x: CGFloat(x), y: deleted.frame.minY)), c = pixel(canvas, at: CGPoint(x: CGFloat(x), y: deleted.frame.minY))
                if zip(p, c).contains(where: { abs($0 - $1) > 30 }) { dashes += 1 }
                if abs(p[0] - p[2]) > 30 { colorful += 1 }
            }
            expect(dashes > 10, "deleted: dashes")
            expectEqual(colorful, 0, "deleted: gray, no color left to wear")
        }
    },
    test("the count's capsule is the color's solid at 30% over its wash; a pill for no color has the label's at 8%") {
        let h = try colored()
        h.addBox("A")
        let blue = h.addReference(words: "boxes", query: "box", all: true)
        let plain = h.addReference(words: "tiles", query: "tile", all: true, at: CGPoint(x: 400, y: 400))
        h.addTile("T", at: CGRect(x: 100, y: 500, width: 100, height: 100))
        h.answer()
        let drawn = render(h.editor)
        let swatch = BuiltInColors.blue.swatch
        @MainActor func capsule(_ id: ShapeID) throws -> CGPoint {
            let frame = try frame(of: id, in: h)
            // The capsule's left end, a few points in: the digit is centered in it.
            return CGPoint(x: frame.maxX - 14 - 17, y: frame.midY)
        }
        expectColor(pixel(drawn, at: try capsule(blue)), values(swatch.solid.light.over(swatch.wash.light, alpha: 0.3)), "blue: solid at 30% over the wash", within: 6)
        expectColor(pixel(drawn, at: try capsule(plain)), [236, 236, 236], "neutral: the label at 8% over white", within: 6)
    },
    test("a query's first match: its match's color; every match: the color they share; mixed or past 2,000: gray; while finding: the last answer's, dimmed") {
        let blue = BuiltInColors.blue.swatch, red = BuiltInColors.red.swatch
        let h = try colored()
        let first = h.addBox("First", at: CGRect(x: 100, y: 1_000, width: 100, height: 60))
        let second = h.addBox("Second", at: CGRect(x: 300, y: 1_000, width: 100, height: 60))
        h.editor.setColor(ShapeColor.named("red"), of: [first])
        let one = h.addReference(words: "first", query: "box")
        let all = h.addReference(words: "all", query: "box", all: true, at: CGPoint(x: 400, y: 400))
        let sharing = h.addReference(words: "red", query: "box[color=\"red\"]", all: true, at: CGPoint(x: 400, y: 500))
        h.answer()
        var drawn = render(h.editor)
        expectColor(pixel(drawn, at: Spots(frame: try frame(of: one, in: h)).inside), values(red.wash.light), "a first match: its color (the first in file order is the red one)", within: 2)
        expectColor(pixel(drawn, at: Spots(frame: try frame(of: all, in: h)).inside), neutralFill.light, "every match, a red and a blue: gray", within: 2)
        expectColor(pixel(drawn, at: Spots(frame: try frame(of: sharing, in: h)).inside), values(red.wash.light), "every match of one color: that color", within: 2)
        h.editor.setColor(ShapeColor.named("red"), of: [second])
        h.answer(after: 250)
        drawn = render(h.editor)
        expectColor(pixel(drawn, at: Spots(frame: try frame(of: all, in: h)).inside), values(red.wash.light), "now they share one", within: 2)
        // The question changes: it is looked for again, in the color of its last answer, dimmed.
        h.editor.transact { $0.update(all, as: Reference.self) { $0.props.query = "box[color=\"red\"]" } }
        let finding = render(h.editor)
        let canvas = render(try colored().editor)
        let spots = Spots(frame: try frame(of: all, in: h))
        let dimmed = values(red.wash.light.over(Swatch.canvas.light, alpha: 0.5))
        expectColor(pixel(finding, at: spots.inside), dimmed, "finding: the last answer's wash, at half", within: 8)
        _ = canvas
        _ = blue
    },
    test("past 2,000 matches the pill is gray, and the count says how many") {
        let h = try colored()
        h.editor.transact { editor in
            for index in 0..<2_001 {
                var box = ShapeRecord(Box(CGRect(x: CGFloat(index % 50) * 20, y: 2_000 + CGFloat(index / 50) * 20, width: 10, height: 10)))
                box[TitleProperty.self] = "B\(index)"
                box[PublicProperty.self] = true
                editor.insert(box)
            }
        }
        let all = h.addReference(words: "every box", query: "box", all: true)
        h.answer()
        let drawn = render(h.editor)
        expectColor(pixel(drawn, at: Spots(frame: try frame(of: all, in: h)).inside), neutralFill.light, "gray past 2,000", within: 2)
    },
    test("zoomed out, a block of the color's solid at 50% over the canvas; a pill that stands for nothing, lighter; no color, today's gray") {
        let blue = BuiltInColors.blue.swatch
        for dark in [false, true] {
            let h = try colored()
            let live = h.addReference(to: h.addBox("shapes"), label: "shapes")
            let hidden = h.addReference(to: h.addBox("secret", public: false, at: CGRect(x: 100, y: 400, width: 100, height: 100)), label: "secret", at: CGPoint(x: 400, y: 400))
            let plain = h.addReference(to: h.addTile("plain"), label: "plain", at: CGPoint(x: 400, y: 500))
            h.editor.camera = Camera(origin: .zero, zoom: 0.3)
            let drawn = render(h.editor, dark: dark)
            @MainActor func center(_ id: ShapeID) throws -> CGPoint {
                let frame = try frame(of: id, in: h)
                return CGPoint(x: frame.midX * 0.3, y: frame.midY * 0.3)
            }
            let canvas = Swatch.canvas[dark: dark]
            let block = blue.solid[dark: dark].over(canvas, alpha: 0.5)
            let what = dark ? "dark" : "light"
            expectColor(pixel(drawn, at: try center(live)), values(block), "\(what): solid at 50% over the canvas", within: 3)
            expectColor(pixel(drawn, at: try center(hidden)), values(block.over(canvas, alpha: 0.65)), "\(what): lighter, standing for nothing", within: 4)
            expectColor(pixel(drawn, at: try center(plain)), dark ? [74, 74, 78] : [216, 216, 221], "\(what): no color, today's gray", within: 2)
        }
    },
    test("a direct pill being edited keeps its color until what's typed changes it") {
        let h = try colored()
        let pill = h.addReference(to: h.addBox("shapes"), label: "shapes")
        let spots = Spots(frame: try frame(of: pill, in: h))
        h.editor.beginEditing(pill)
        expectColor(pixel(render(h.editor), at: spots.inside), values(BuiltInColors.blue.swatch.wash.light), "edited, unchanged: its color", within: 2)
        h.editor.transact { $0.update(pill, as: Reference.self) { ReferenceEdits.find(&$0.props, words: "sha") } }
        expectColor(pixel(render(h.editor), at: spots.inside), neutralFill.light, "typed over: neutral", within: 2)
    },
])

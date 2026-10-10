import Adornments
import AppKit
import Canvas
import CanvasTesting
import Foundation
import TestKit
import Titles
import Types

// A type's color is worked out from its id and never stored: eight of them, a contract (the table
// below never changes, or every board's types change color), readable in both appearances. And
// the pill a type's note shows, solid in it.

/// A seeded stream of ids: the same on every run.
private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func ids(_ count: Int, seed: UInt64 = 7) -> [ShapeID] {
    var generator = SplitMix(state: seed)
    return (0..<count).map { _ in
        let high = generator.next(), low = generator.next()
        let bytes = (0..<8).map { UInt8(truncatingIfNeeded: high >> (8 * UInt64($0))) } + (0..<8).map { UInt8(truncatingIfNeeded: low >> (8 * UInt64($0))) }
        return ShapeID(UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                                   bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])))
    }
}

private func linear(_ c: CGFloat) -> Double { Double(c) <= 0.03928 ? Double(c) / 12.92 : pow((Double(c) + 0.055) / 1.055, 2.4) }
private func luminance(_ c: TypesStyle.RGB) -> Double { 0.2126 * linear(c.0) + 0.7152 * linear(c.1) + 0.0722 * linear(c.2) }
private func contrast(_ a: TypesStyle.RGB, _ b: TypesStyle.RGB) -> Double {
    let (x, y) = (luminance(a), luminance(b))
    return (max(x, y) + 0.05) / (min(x, y) + 0.05)
}
private func over(_ color: TypesStyle.RGB, _ canvas: CGFloat, alpha: CGFloat) -> TypesStyle.RGB {
    (alpha * color.0 + (1 - alpha) * canvas, alpha * color.1 + (1 - alpha) * canvas, alpha * color.2 + (1 - alpha) * canvas)
}
private func hue(_ c: TypesStyle.RGB) -> Double {
    var h: CGFloat = 0
    NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1).getHue(&h, saturation: nil, brightness: nil, alpha: nil)
    return Double(h)
}

@MainActor private func rgb(_ color: NSColor, dark: Bool) throws -> TypesStyle.RGB {
    var resolved: NSColor?
    NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) }
    let c = try require(resolved)
    return (c.redComponent, c.greenComponent, c.blueComponent)
}

@MainActor let typeColorsTests = Suite("Type colors", [
    test("an id's color is fixed, by its first eight bytes: a table that never changes") {
        let table: [(String, Int)] = [("00000000-0000-0000-0000-000000000000", 4), ("01020304-0506-0708-090A-0B0C0D0E0F10", 0),
                                      ("E621E1F8-C36C-495A-93FC-0C247A3E6E5F", 6), ("00000003-0000-0000-0000-000000000000", 7)]
        for (id, index) in table {
            expectEqual(TypeColors.index(of: ShapeID(try require(UUID(uuidString: id)))), index, id)
        }
        let id = ShapeID()
        expectEqual(TypeColors.solid(id), TypeColors.solid(id), "the same every time")
        expectEqual(TypeColors.solid(id).color, TypesStyle.colorTable.map { NSColor(srgbRed: $0.base.0, green: $0.base.1, blue: $0.base.2, alpha: 1) }[TypeColors.index(of: id)])
    },
    test("ids fall in the eight colors about evenly") {
        var counts = [Int](repeating: 0, count: 8)
        for id in ids(1000) { counts[TypeColors.index(of: id)] += 1 }
        for (index, count) in counts.enumerated() { expect(count > 75 && count < 175, "color \(index): \(count) of 1000, in \(counts)") }
    },
    test("white reads on each base, and each ink on its tint over the light canvas and the dark, at 4.5:1; none is red; the eight are distinct") {
        let table = TypesStyle.colorTable
        expectEqual(table.count, 8)
        for (index, entry) in table.enumerated() {
            expect(contrast(entry.base, (1, 1, 1)) >= 4.5, "white on \(index): \(contrast(entry.base, (1, 1, 1)))")
            let onLight = contrast(entry.lightInk, over(entry.base, 0.965, alpha: 0.14))
            let onDark = contrast(entry.darkInk, over(entry.base, 0.11, alpha: 0.14))
            expect(onLight >= 4.5, "ink on the light canvas, \(index): \(onLight)")
            expect(onDark >= 4.5, "ink on the dark canvas, \(index): \(onDark)")
            let h = hue(entry.base)
            expect(min(h, 1 - h) >= 0.05, "not red: \(index) at \(h)")
        }
        let bases = table.map { "\($0.base.0) \($0.base.1) \($0.base.2)" }
        expectEqual(Set(bases).count, 8)
        let hues = table.map { hue($0.base) }.sorted()
        for (a, b) in zip(hues, hues.dropFirst()) { expect(b - a > 0.01, "hues apart: \(hues)") }
    },
    test("the tints are the table's: solid is the base; light is the base with the ink of the appearance") {
        let all = ids(200)
        var seen = Set<Int>()
        for id in all {
            let index = TypeColors.index(of: id)
            guard seen.insert(index).inserted else { continue }
            let entry = TypesStyle.colorTable[index]
            let solid = TypeColors.solid(id), light = TypeColors.light(id)
            expectEqual(solid.style, .solid)
            expectEqual(light.style, .light)
            let base = try rgb(light.color, dark: false)
            expectClose(base.0, entry.base.0, within: 0.002)
            let lightInk = try rgb(light.ink, dark: false), darkInk = try rgb(light.ink, dark: true)
            expectClose(lightInk.1, entry.lightInk.1, within: 0.002)
            expectClose(darkInk.1, entry.darkInk.1, within: 0.002)
            expectEqual(try rgb(light.color, dark: true).0, base.0, "the color is the same in both appearances")
        }
        expectEqual(seen.count, 8)
        expectEqual(TypeColors.gray.style, .solid)
    },
])

extension CanvasEditor {
    /// A shape's title pill, if it shows one.
    fileprivate func pill(_ id: ShapeID) -> AdornmentLabel? { adornmentFrames(of: id).first { $0.adornment == .of(TitlePill.self) }?.label }
}

@MainActor let typePillTests = Suite("Type pills", [
    test("a titled type's pill is its title in its color, solid, after the mark of a type; an untitled type's is a dimmed gray placeholder") {
        let editor = try typeEditor()
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person"), draft = editor.addType(TypeSchemaProperty.starter, at: CGPoint(x: 600, y: 40))
        let pill = try require(editor.pill(person))
        expectEqual(pill.text, "Person")
        expectEqual(pill.systemImage, "curlybraces")
        expectEqual(pill.tint, TypeColors.solid(person))
        let untitled = try require(editor.pill(draft))
        expectEqual(untitled.text, "Untitled")
        expectEqual(untitled.systemImage, "curlybraces")
        expectEqual(untitled.isPlaceholder, true)
        expectEqual(untitled.tint, nil)
        expectEqual(editor.document[draft].flatMap(editor.registry.title(of:)), nil, "never a title")
    },
    test("a plain titled note's pill is as it was, and so is a type's once it is none; naming an untitled type changes its pill") {
        let editor = try typeEditor()
        let ann = editor.addInstance("Ann", of: [], title: "Ann")
        expectEqual(editor.pill(ann), AdornmentLabel("Ann"))
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person")
        editor.removeType(person)
        expectEqual(editor.pill(person), AdornmentLabel("Person"), "Remove Type")
        editor.undo()
        expectEqual(editor.pill(person)?.tint, TypeColors.solid(person), "and undone")
        let draft = editor.addType(TypeSchemaProperty.starter, at: CGPoint(x: 600, y: 40))
        editor.transact("Rename") { $0.update(draft) { $0[TitleProperty.self] = "Draft" } }
        expectEqual(editor.pill(draft)?.tint, TypeColors.solid(draft))
    },
    test("two types of one title and different ids differ in color") {
        let editor = try typeEditor()
        var made: [ShapeID] = []
        var colors = Set<Int>()
        for index in 0..<40 where colors.count < 2 {
            let id = editor.addType(TypeSchemaProperty.starter, title: "Person", at: CGPoint(x: 300 * CGFloat(index % 5), y: 60 * CGFloat(index / 5)))
            made.append(id)
            colors.insert(TypeColors.index(of: id))
        }
        expectEqual(colors.count, 2, "two colors in forty types")
        let a = try require(made.first), b = try require(made.first { TypeColors.index(of: $0) != TypeColors.index(of: a) })
        expect(editor.pill(a)?.tint != editor.pill(b)?.tint)
    },
])

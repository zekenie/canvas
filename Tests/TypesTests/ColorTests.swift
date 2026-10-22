import Adornments
import AppKit
import Canvas
import CanvasTesting
import Colors
import Foundation
import Palette
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

/// Memos have colors, and the book of colors is in the list after Types, as the shipped list has it
/// (its service is made when Types' index asks for it).
@MainActor private func colorEditor(_ more: [any CanvasPlugin] = [], document: CanvasDocument = CanvasDocument()) throws -> CanvasEditor {
    try typeEditor(document: document, more: [Contributor(id: "memo-colors") { $0.colorable(Memo.self) }, ColorsPlugin()] + more)
}

/// How the type of a built-in name is drawn, over a type that holds it.
@MainActor private func lookHeld(as name: ShapeColor) throws -> (look: TypeLook, swatch: Swatch) {
    let editor = try colorEditor()
    let type = editor.addType(TypeSchemaProperty.starter, title: "Person")
    editor.setColor(name, of: [type])
    return (try require(editor.types).look(of: type), try require(BuiltInColors.named(try require(name.name))).swatch)
}

/// A color as the pixels of a drawing in one appearance hold it, 0 to 255.
@MainActor private func resolved(_ color: NSColor, dark: Bool) throws -> RGB {
    var found: NSColor?
    try require(NSAppearance(named: dark ? .darkAqua : .aqua)).performAsCurrentDrawingAppearance { found = NSColor(cgColor: color.cgColor) }
    let c = try require(found?.usingColorSpace(.sRGB))
    return RGB(c.redComponent, c.greenComponent, c.blueComponent)
}

private func close(_ a: RGB, _ b: RGB) -> Bool {
    abs(a.red - b.red) < 0.003 && abs(a.green - b.green) < 0.003 && abs(a.blue - b.blue) < 0.003
}

/// Which shapes Adornments was asked the labels of, and how many times: a probe adornment on every shape
/// that shows nothing, whose labels are made when Adornments makes a shape's again.
@MainActor private final class Asked {
    var counts: [ShapeID: Int] = [:]
    func count(_ id: ShapeID) -> Int { counts[id] ?? 0 }
}

private enum Probe: Adornment {
    static var placement: AdornmentPlacement { .aboveTopRight }
    static var order: Order<Self> { .last }
}

@MainActor private func probing(_ asked: Asked) -> Contributor {
    Contributor(id: "probe") { registrar in
        registrar.forEveryShape { scope in
            scope.adornment(Probe.self) { shape, _ in
                asked.counts[shape.id, default: 0] += 1
                return nil
            }
        }
    }
}

@MainActor let typeColorsTests = Suite("Type colors", [
    test("an id's color is fixed, by its first eight bytes, over the eight names: a table that never changes") {
        let table: [(String, Int, ShapeColor)] = [("00000000-0000-0000-0000-000000000000", 4, .blue), ("01020304-0506-0708-090A-0B0C0D0E0F10", 0, .orange),
                                                  ("E621E1F8-C36C-495A-93FC-0C247A3E6E5F", 6, .purple), ("00000003-0000-0000-0000-000000000000", 7, .pink),
                                                  ("00000001-0000-0000-0000-000000000000", 5, .indigo)]
        for (id, index, name) in table {
            let id = ShapeID(try require(UUID(uuidString: id)))
            expectEqual(TypeColors.index(of: id), index, "\(id)")
            expectEqual(TypeColors.name(of: id), name, "\(id)")
        }
        expectEqual(TypeColors.names, [.orange, .yellow, .green, .teal, .blue, .indigo, .purple, .pink])
        let editor = try typeEditor()
        for (id, _, name) in table {
            let id = ShapeID(try require(UUID(uuidString: id)))
            expectEqual(editor.types?.look(of: id).swatch, BuiltInColors.named(try require(name.name))?.swatch, "its swatch")
        }
        let id = ShapeID()
        expectEqual(editor.types?.look(of: id).solid, editor.types?.look(of: id).solid, "the same every time")
    },
    test("ids fall in the eight colors about evenly") {
        var counts = [Int](repeating: 0, count: 8)
        for id in ids(1000) { counts[TypeColors.index(of: id)] += 1 }
        for (index, count) in counts.enumerated() { expect(count > 75 && count < 175, "color \(index): \(count) of 1000, in \(counts)") }
    },
    test("none of the eight is gray, which reads as no color, or red, which reads as wrong; the eight are distinct") {
        expectEqual(TypeColors.names.count, 8)
        expectEqual(Set(TypeColors.names).count, 8)
        expect(!TypeColors.names.contains(.gray) && !TypeColors.names.contains(.red), "neither gray nor red")
        for name in TypeColors.names { expectEqual(BuiltInColors.named(try require(name.name))?.isBuiltIn, true, "\(name.text) is a built-in name") }
        var seen = Set<Int>()
        for id in ids(200) { seen.insert(TypeColors.index(of: id)) }
        expectEqual(seen.count, 8)
        expectEqual(TypeColors.gray.style, .solid, "gray is for what has no color")
    },
    test("a list without Colors colors a type by its id, solid for its pill and light for its chips") {
        let editor = try typeEditor()
        expect(editor.colors == nil, "no book of colors")
        for id in ids(40) {
            let look = try require(editor.types).look(of: id)
            let swatch = try require(BuiltInColors.named(try require(TypeColors.name(of: id).name))).swatch
            expectEqual(look.swatch, swatch)
            expectEqual(look.solid.style, .solid)
            expectEqual(look.light.style, .light)
            expect(close(try resolved(look.solid.color, dark: false), swatch.solid.light), "the pill's color is the solid")
            expect(close(try resolved(look.light.color, dark: true), swatch.solid.dark), "and the chip's, in the dark")
            expect(close(try resolved(look.row, dark: false), swatch.solid.light), "and the list's row")
        }
    },
    test("a type whose shape holds a color is that color: its pill, its instances' chips and its row; without one, its id's") {
        let editor = try colorEditor()
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person")
        let ann = editor.addInstance("Ann", of: [person], title: "Ann")
        let types = try require(editor.types)
        let byId = types.look(of: person)
        expectEqual(byId.swatch, BuiltInColors.named(try require(TypeColors.name(of: person).name))?.swatch, "none held: its id's")
        // Another of the eight than its id's.
        let held: ShapeColor = TypeColors.name(of: person) == .green ? .teal : .green
        editor.setColor(held, of: [person])
        let look = types.look(of: person)
        expectEqual(look.swatch, BuiltInColors.named(try require(held.name))?.swatch)
        expect(look.swatch != byId.swatch)
        expectEqual(editor.pill(person)?.tint, look.solid, "the pill")
        let chip = try require(editor.adornmentFrames(of: ann).first { $0.adornment == .of(TypeChips.self) })
        expectEqual(chip.label.tint, look.light, "the instance's chip")
        expectEqual(look.solid.style, .solid)
        expectEqual(look.light.style, .light)
        expect(close(try resolved(look.solid.color, dark: false), look.swatch.solid.light))
    },
    test("a hex value is a color too; a name the file lacks is the id's, and so is none") {
        let editor = try colorEditor()
        let types = try require(editor.types)
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person")
        let byId = types.look(of: person)
        editor.setColor(.value(RGB(hex: 0x4465E9)), of: [person])
        expectEqual(types.look(of: person).swatch, Swatch(RGB(hex: 0x4465E9)))
        expectEqual(editor.pill(person)?.tint, types.look(of: person).solid)
        editor.transact("Color") { $0.update(person) { $0[ColorProperty.self] = .named("chartreuse") } }
        expectEqual(types.look(of: person).swatch, byId.swatch, "a name the file lacks")
        expectEqual(editor.pill(person)?.tint, byId.solid)
        editor.setColor(.named("TEAL"), of: [person])
        expectEqual(types.look(of: person).swatch, BuiltInColors.teal.swatch, "found whatever its case")
        editor.setColor(nil, of: [person])
        expectEqual(types.look(of: person).swatch, byId.swatch, "taken away")
        expectEqual(editor.pill(person)?.tint, byId.solid)
    },
    test("the same swatch is the same tint: a color made again is not a new one") {
        let editor = try colorEditor()
        let types = try require(editor.types)
        let a = editor.addType(TypeSchemaProperty.starter, title: "A"), b = editor.addType(TypeSchemaProperty.starter, title: "B", at: CGPoint(x: 400, y: 40))
        editor.setColor(.value(RGB(hex: 0x123456)), of: [a, b])
        expect(types.look(of: a).solid == types.look(of: b).solid, "equal")
        expect(types.look(of: a).solid.color === types.look(of: b).solid.color, "of one NSColor")
    },
    test("setting and clearing a type's color makes its instances' chips again and no one else's; undo puts them back") {
        let asked = Asked()
        let editor = try colorEditor([probing(asked)])
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person"), company = editor.addType(TypeSchemaProperty.starter, title: "Company", at: CGPoint(x: 400, y: 40))
        let ann = editor.addInstance("Ann", of: [person], title: "Ann"), bo = editor.addInstance("Bo", of: [person], title: "Bo", at: CGPoint(x: 400, y: 400))
        let acme = editor.addInstance("Acme", of: [company], title: "Acme", at: CGPoint(x: 800, y: 400))
        let types = try require(editor.types)
        @MainActor func tint(_ id: ShapeID) -> AdornmentTint? { editor.adornmentFrames(of: id).first { $0.adornment == .of(TypeChips.self) }?.label.tint }
        let all = [person, company, ann, bo, acme]
        /// Asks Adornments for every shape's labels, as a frame would: what it was told changed is made again.
        @MainActor func touch() { for id in all { _ = editor.adornmentFrames(of: id) } }
        let before = [tint(ann), tint(bo), tint(acme)]
        touch()
        var base = Dictionary(uniqueKeysWithValues: all.map { ($0, asked.count($0)) })
        @MainActor func remade(_ id: ShapeID) -> Int { asked.count(id) - (base[id] ?? 0) }
        @MainActor func mark() { touch(); base = Dictionary(uniqueKeysWithValues: all.map { ($0, asked.count($0)) }) }
        let held: ShapeColor = TypeColors.name(of: person) == .pink ? .blue : .pink
        editor.setColor(held, of: [person])
        touch()
        let after = [tint(ann), tint(bo), tint(acme)]
        expect(after[0] != before[0] && after[1] != before[1], "both instances' chips are the new color")
        expectEqual(after[0], types.look(of: person).light)
        expectEqual(after[2], before[2], "another type's instance is as it was")
        expectEqual(remade(ann), 1, "Ann's labels were made again, once")
        expectEqual(remade(bo), 1, "and Bo's")
        expectEqual(remade(person), 1, "and the type's own pill, which the commit names")
        expectEqual(remade(acme), 0, "not another type's instance")
        expectEqual(remade(company), 0, "nor another type")
        mark()
        editor.undo()
        touch()
        expectEqual([tint(ann), tint(bo), tint(acme)], before, "undone")
        expectEqual(remade(ann), 1, "once more")
        expectEqual(remade(acme), 0)
        mark()
        editor.redo()
        touch()
        expectEqual(tint(ann), after[0], "redone")
        mark()
        editor.setColor(nil, of: [person])
        touch()
        expectEqual([tint(ann), tint(bo), tint(acme)], before, "cleared")
        expectEqual(remade(ann), 1)
        expectEqual(remade(acme), 0, "and Acme's still never")
        // A rename of a type that holds a color remakes its instances' chips once, as it always did.
        editor.setColor(held, of: [person])
        mark()
        editor.transact("Rename") { $0.update(person) { $0[TitleProperty.self] = "Human" } }
        touch()
        expectEqual(remade(ann), 1, "a rename remakes the chips once, color or none")
        expectEqual(remade(acme), 0)
    },
    test("a color set on a shape that is not a type, or on an instance, changes no type's color") {
        let asked = Asked()
        let editor = try colorEditor([probing(asked)])
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person")
        let ann = editor.addInstance("Ann", of: [person], title: "Ann")
        let types = try require(editor.types)
        let byId = types.look(of: person)
        _ = editor.adornmentFrames(of: ann)
        _ = editor.adornmentFrames(of: person)
        let made = (ann: asked.count(ann), person: asked.count(person))
        editor.setColor(.pink, of: [ann])
        _ = editor.adornmentFrames(of: ann)
        _ = editor.adornmentFrames(of: person)
        expectEqual(types.look(of: person).swatch, byId.swatch)
        expectEqual(asked.count(ann) - made.ann, 1, "Ann's own labels, since she changed, and no more")
        expectEqual(asked.count(person) - made.person, 0, "and the type's not at all")
    },
    test("a type that holds a color is that color when the file opens") {
        var record = typeRecord(TypeSchemaProperty.starter, title: "Person")
        record[ColorProperty.self] = .green
        let document = CanvasDocument(shapes: [record])
        let editor = try colorEditor(document: document)
        expectEqual(try require(editor.types).look(of: record.id).swatch, BuiltInColors.green.swatch, "read as the file is made")
        let without = try typeEditor(document: document)
        expectEqual(try require(without.types).look(of: record.id).swatch, try require(BuiltInColors.named(try require(TypeColors.name(of: record.id).name))).swatch,
                    "and without Colors, the id's")
    },
    test("a pill's text is black on yellow and orange and white on the rest, in both appearances") {
        for name in TypeColors.names {
            let (look, _) = try lookHeld(as: name)
            for dark in [false, true] {
                let ink = try resolved(look.solid.ink, dark: dark)
                let expected: RGB = ["yellow", "orange"].contains(name.name) ? RGB(0, 0, 0) : RGB(1, 1, 1)
                expect(close(ink, expected), "\(name.text), dark \(dark): text \(ink.hexString)")
            }
        }
    },
    test("a chip's colors, in the light appearance and the dark: its fill and line from the solid, its title in the ink") {
        for name in TypeColors.names {
            let (look, swatch) = try lookHeld(as: name)
            for dark in [false, true] {
                expect(close(try resolved(look.light.color, dark: dark), swatch.solid[dark: dark]), "\(name.text) solid, dark \(dark)")
                expect(close(try resolved(look.light.ink, dark: dark), swatch.ink[dark: dark]), "\(name.text) ink, dark \(dark)")
                expect(close(try resolved(look.solid.color, dark: dark), swatch.solid[dark: dark]), "\(name.text) pill, dark \(dark)")
            }
            expect(close(try resolved(look.tick, dark: true), swatch.solid.light), "a tick on a note's paper is the light one")
        }
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
        expectEqual(pill.tint, editor.types?.look(of: person).solid)
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
        expectEqual(editor.pill(person)?.tint, editor.types?.look(of: person).solid, "and undone")
        let draft = editor.addType(TypeSchemaProperty.starter, at: CGPoint(x: 600, y: 40))
        editor.transact("Rename") { $0.update(draft) { $0[TitleProperty.self] = "Draft" } }
        expectEqual(editor.pill(draft)?.tint, editor.types?.look(of: draft).solid)
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

import AppKit
import Canvas
import CanvasTesting
import Colors
import Foundation
import Palette
import TestKit

@MainActor let shapeColorTests = Suite("Shape colors", [
    test("a color is written as a name or a hex value, and read back as it was") {
        expectEqual(ShapeColor("blue"), .named("blue"))
        expectEqual(ShapeColor("#4465E9"), .value(RGB(hex: 0x4465E9)))
        expectEqual(ShapeColor("#46e"), .value(RGB(hex: 0x4466EE)))
        expectEqual(ShapeColor("  Brand \n  Blue "), .named("Brand Blue"), "a name is one line, with no spaces at its ends")
        expectEqual(ShapeColor.named("Brand Blue").text, "Brand Blue")
        expectEqual(ShapeColor.value(RGB(hex: 0x4466EE)).text, "#4466EE")
        expectEqual(ShapeColor.named("blue").name, "blue")
        expect(ShapeColor.value(.black).name == nil)
    },
    test("nothing, and what starts # and isn't a hex value, is no color") {
        for text in ["", "   ", "#", "#12", "#GGGGGG", "#4465E9FF"] { expect(ShapeColor(text) == nil, "\(text) read as a color") }
    },
    test("a name is found whatever its case and spacing") {
        expectEqual(ShapeColor.key(of: "Brand  Blue"), ShapeColor.key(of: " brand blue"))
        expect(ShapeColor.key(of: "blue") != ShapeColor.key(of: "blues"))
    },
    test("on a board it's one string, and any string reads") {
        let coded = try JSONEncoder().encode([ShapeColor.named("blue"), .value(RGB(hex: 0x4465E9))])
        expectEqual(String(decoding: coded, as: UTF8.self), ##"["blue","#4465E9"]"##)
        let read = try JSONDecoder().decode([ShapeColor].self, from: Data(##"["Teal","#46e","#nope","  two  words "]"##.utf8))
        expectEqual(read, [.named("Teal"), .value(RGB(hex: 0x4466EE)), .named("#nope"), .named("two words")])
    },
])

@MainActor let builtInColorTests = Suite("Built-in colors", [
    test("there are ten, in the order every list shows them, found whatever the case") {
        expectEqual(BuiltInColors.all.map(\.name), ["gray", "red", "orange", "yellow", "green", "teal", "blue", "indigo", "purple", "pink"])
        expect(BuiltInColors.all.allSatisfy(\.isBuiltIn))
        expectEqual(BuiltInColors.named("Blue"), BuiltInColors.blue)
        expectEqual(BuiltInColors.named(" BLUE "), BuiltInColors.blue)
        expect(BuiltInColors.named("mauve") == nil)
        expectEqual(ShapeColor.yellow, .named("yellow"))
        expectEqual(Set(BuiltInColors.all.map(\.value)).count, 10, "ten different values")
    },
    test("every role of every one meets its floor on both canvases, once rounded to 8 bits") {
        func rounded(_ color: RGB) -> RGB { RGB(hexString: color.hexString)! }
        for color in BuiltInColors.all {
            let swatch = color.swatch
            for isDark in [false, true] {
                let canvas = Swatch.canvas[dark: isDark], name = "\(color.name) \(isDark ? "dark" : "light")"
                let solid = rounded(swatch.solid[dark: isDark]), wash = rounded(swatch.wash[dark: isDark]), ink = rounded(swatch.ink[dark: isDark])
                expect(solid.contrast(with: canvas) >= Swatch.lineContrast, "\(name): solid at \(solid.contrast(with: canvas))")
                expect(swatch.onSolid[dark: isDark].contrast(with: solid) >= Swatch.textContrast, "\(name): text on solid")
                expect(ink.contrast(with: wash) >= Swatch.textContrast, "\(name): ink on wash at \(ink.contrast(with: wash))")
                expect(ink.contrast(with: canvas) >= Swatch.textContrast, "\(name): ink on the canvas at \(ink.contrast(with: canvas))")
                expect(ink.contrast(with: rounded(swatch.surface[dark: isDark])) >= Swatch.textContrast, "\(name): ink on its surface")
            }
            let paper = swatch.paper.light
            expectEqual(swatch.paper.dark, paper, "\(color.name): one sheet in both appearances")
            expect(paper.luminance > 0.70 && paper.luminance < 0.80, "\(color.name): paper's luminance is \(paper.luminance)")
            expect(swatch.paperInk.light.contrast(with: paper) >= 12, "\(color.name): ink on paper")
        }
    },
    test("white reads on every solid but yellow's and orange's, and the value is its own solid on the light canvas but yellow's") {
        for color in BuiltInColors.all {
            let takesBlack = color == BuiltInColors.yellow || color == BuiltInColors.orange
            expectEqual(color.swatch.onSolid.light, takesBlack ? .black : .white, color.name)
            if color != BuiltInColors.yellow { expectEqual(color.swatch.solid.light, color.value, "\(color.name) reads on the light canvas as it is") }
        }
    },
    test("a few roles are pinned to what the app drew before: yellow's paper is the note's, and indigo's line in the dark and its surface the subboard's") {
        expectEqual(BuiltInColors.yellow.swatch.paper, Tone(RGB(1.0, 0.87, 0.45)))
        let indigo = BuiltInColors.indigo.swatch
        expectEqual(indigo.solid, Tone(light: RGB(hex: 0x5856D6), dark: RGB(hex: 0x5E5CE6)))
        expectEqual(indigo.wash.dark, indigo.solid.dark.over(Swatch.canvas.dark, alpha: Swatch.washStrength), "its wash follows the pinned line")
        expectEqual(indigo.surface, Tone(light: RGB(0.98, 0.98, 1), dark: RGB(0.15, 0.15, 0.19)))
    },
])

@MainActor let colorRegistryTests = Suite("Colorable kinds", [
    test("a kind that opts in holds the property, with its default or none, and the report says so") {
        let registry = try Registry(plugins: colorPlugins())
        expect(registry.isColorable(Sheet.kind) && registry.isColorable(Pane.kind))
        expect(!registry.isColorable(Box.kind))
        expectEqual(registry.defaultColor(of: Sheet.kind), .yellow)
        expect(registry.defaultColor(of: Pane.kind) == nil)
        expect(registry.defaultColor(of: Box.kind) == nil)
        expect(registry.properties(for: Sheet.kind).contains(ColorProperty.key))
        expect(registry.report.contains("property color → sheet · colorable (yellow) → sheet"), registry.report)
        expect(registry.report.contains("property color → pane · colorable → pane"), registry.report)
        expect(registry.report.contains("property color"), registry.report)
    },
    test("in a kind's schema the color is a string with its media type, marked as Colors'") {
        let registry = try Registry(plugins: colorPlugins())
        let schema = try require(registry.schema(for: Sheet.kind)?.json["properties"]?["color"])
        expectEqual(schema["type"], "string")
        expectEqual(schema["contentMediaType"], .string(ShapeColor.mediaType))
        expectEqual(schema["x-canvas-owner"], "colors")
        expectEqual(schema["examples"], ["blue", "#4465E9"])
        expectEqual(registry.schema(for: Box.kind)?.json["properties"]?["color"], nil)
    },
    test("a list without Colors refuses a kind that opts in, a kind opts in once, and a default is a color every file has") {
        expectThrows(RegistryError.ownerNotInstalled(point: "ColorDefaults", owner: .colors, contributor: "swatch-kinds")) {
            _ = try Registry(plugins: [FixturesPlugin(), swatchKinds])
        }
        let twice = Contributor(id: "twice") { $0.colorable(Sheet.self, default: .blue) }
        expectThrows(RegistryError.conflict(point: "PropertyOptIns", key: "sheet's color", plugins: ["swatch-kinds", "twice"])) {
            _ = try Registry(plugins: colorPlugins([twice]))
        }
        let own = Contributor(id: "own") { $0.colorable(Box.self, default: .named("brand")) }
        expectThrows(RegistryError.invalid(point: "ColorDefaults", reason: "box's default color, brand, isn't a built-in color")) {
            _ = try Registry(plugins: colorPlugins([own]))
        }
        let value = Contributor(id: "value") { $0.colorable(Box.self, default: .value(RGB(hex: 0x123456))) }
        let registry = try Registry(plugins: colorPlugins([value]))
        expectEqual(registry.defaultColor(of: Box.kind), .value(RGB(hex: 0x123456)), "another plugin's kind, with a value for a default")
    },
])

@MainActor let colorBookTests = Suite("The color book", [
    test("the names are the built-in ones, found whatever the case, and stored in the list's spelling") {
        let h = try colorHarness(), book = try require(h.editor.colors)
        expectEqual(book.names, BuiltInColors.all)
        expectEqual(book.named("TEAL"), BuiltInColors.teal)
        expectEqual(book.canonical(.named("TEAL")), .teal)
        expectEqual(book.canonical(.value(RGB(hex: 0x123456))), .value(RGB(hex: 0x123456)))
        expect(book.canonical(.named("brand")) == nil)
        expect(book.has(.blue) && book.has(.value(.black)) && !book.has(.named("brand")))
        expectEqual(book.swatch(for: .blue), BuiltInColors.blue.swatch)
        expectEqual(book.swatch(for: .value(RGB(hex: 0x123456))), Swatch(RGB(hex: 0x123456)))
        expect(book.swatch(for: .named("brand")) == nil)
    },
    test("a shape's color is its own, else its kind's default, else none; a name the file lacks is the default") {
        let h = try colorHarness(), book = try require(h.editor.colors)
        let sheet = h.add(Sheet(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let pane = h.add(Pane(CGRect(x: 200, y: 0, width: 100, height: 100)))
        let box = h.add(Box(CGRect(x: 400, y: 0, width: 100, height: 100)))
        let own = { (id: ShapeID) in h.editor.document[id]?.ownColor }
        let color = { (id: ShapeID) in h.editor.document[id].flatMap { book.color(of: $0) } }
        let swatch = { (id: ShapeID) in h.editor.document[id].flatMap { book.swatch(of: $0) } }
        expectEqual(color(sheet), .yellow)
        expectEqual(swatch(sheet), BuiltInColors.yellow.swatch)
        expectEqual(color(pane), nil)
        expectEqual(swatch(pane), nil)
        expectEqual(color(box), nil, "a kind with no colors has none")
        h.editor.setColor(.teal, of: [sheet, pane, box])
        expectEqual(color(sheet), .teal)
        expectEqual(swatch(pane), BuiltInColors.teal.swatch)
        expectEqual(own(box), nil)
        expectEqual(color(box), nil)
        h.editor.setColor(.named("brand"), of: [sheet, pane])
        expectEqual(own(sheet), .named("brand"), "it keeps the name")
        expectEqual(color(sheet), .yellow, "and is drawn as its kind's default")
        expectEqual(color(pane), nil)
    },
    test("a switch of board is nothing to it") {
        let h = try colorHarness(), book = try require(h.editor.colors)
        expect(book.fileColors.isEmpty)
        book.onChange { expect(false, "nothing changed") }
        h.add(Sheet(CGRect(x: 0, y: 0, width: 10, height: 10)))
    },
])

@MainActor let setColorTests = Suite("Setting a color", [
    test("it's one step, Change Color, for every shape, and undo puts each back") {
        let h = try colorHarness()
        let a = h.add(Sheet(CGRect(x: 0, y: 0, width: 100, height: 100))), b = h.add(Pane(CGRect(x: 200, y: 0, width: 100, height: 100)))
        let own = { (id: ShapeID) in h.editor.document[id]?.ownColor }
        h.editor.setColor(.blue, of: [a])
        h.editor.setColor(.value(RGB(hex: 0x123456)), of: [a, b])
        expectEqual(h.editor.undoHistory.undoName, "Change Color")
        expectEqual(own(a), .value(RGB(hex: 0x123456)))
        expectEqual(own(b), .value(RGB(hex: 0x123456)))
        h.editor.undo()
        expectEqual(own(a), .blue)
        expect(own(b) == nil)
        h.editor.redo()
        expectEqual(own(b), .value(RGB(hex: 0x123456)))
    },
    test("none takes it away, a name is stored in its list's spelling, and a change that changes nothing is no step") {
        let h = try colorHarness()
        let a = h.add(Sheet(CGRect(x: 0, y: 0, width: 100, height: 100)))
        h.editor.setColor(.named("PURPLE"), of: [a])
        expectEqual(h.editor.document[a]?.ownColor, .purple)
        let revision = h.editor.revision
        h.editor.setColor(.purple, of: [a])
        h.editor.setColor(.purple, of: [])
        h.editor.setColor(.purple, of: [ShapeID()])
        expectEqual(h.editor.revision, revision, "nothing committed")
        h.editor.setColor(nil, of: [a])
        expect(h.editor.document[a]?.ownColor == nil)
        h.editor.undo()
        expectEqual(h.editor.document[a]?.ownColor, .purple)
    },
    test("a read-only shape refuses it while the rest change") {
        let h = try colorHarness([FreezingPlugin()])
        let a = h.add(Sheet(CGRect(x: 0, y: 0, width: 100, height: 100))), b = h.add(Sheet(CGRect(x: 200, y: 0, width: 100, height: 100)))
        h.editor.freeze([a])
        h.editor.setColor(.green, of: [a, b])
        expect(h.editor.document[a]?.ownColor == nil)
        expectEqual(h.editor.document[b]?.ownColor, .green)
    },
])

@MainActor let colorRenderTests = Suite("Drawing a color", [
    test("a kind draws its default with no color of its own, its own when it has one, and its own look with neither") {
        let h = try colorHarness()
        let sheet = h.add(Sheet(CGRect(x: 20, y: 20, width: 100, height: 100)))
        let pane = h.add(Pane(CGRect(x: 220, y: 20, width: 100, height: 100)))
        let onSheet = CGPoint(x: 70, y: 70), onPane = CGPoint(x: 270, y: 70)
        var bitmap = try render(h.editor)
        expectPixel(pixel(bitmap, at: onSheet), BuiltInColors.notePaper, "yellow's paper, by default")
        expectPixel(pixel(bitmap, at: onPane), RGB(white: 0.5), "a pane with no color is gray")
        h.editor.setColor(.blue, of: [sheet, pane])
        bitmap = try render(h.editor)
        expectPixel(pixel(bitmap, at: onSheet), BuiltInColors.blue.swatch.paper.light)
        expectPixel(pixel(bitmap, at: onPane), BuiltInColors.blue.value)
        h.editor.setColor(.value(RGB(hex: 0x0A1A4A)), of: [pane])
        expectPixel(pixel(try render(h.editor), at: onPane), RGB(hex: 0x0A1A4A), "a value, as it is where it reads")
    },
    test("in the dark the paper is the same sheet and a line is the dark canvas's") {
        let h = try colorHarness()
        let sheet = h.add(Sheet(CGRect(x: 20, y: 20, width: 100, height: 100)))
        let pane = h.add(Pane(CGRect(x: 220, y: 20, width: 100, height: 100)))
        let navy = RGB(hex: 0x0A1A4A), swatch = Swatch(navy)
        h.editor.setColor(.value(navy), of: [sheet, pane])
        let light = try render(h.editor), dark = try render(h.editor, dark: true)
        expectPixel(pixel(light, at: CGPoint(x: 70, y: 70)), swatch.paper.light)
        expectPixel(pixel(dark, at: CGPoint(x: 70, y: 70)), swatch.paper.light, "paper stays paper")
        expectPixel(pixel(light, at: CGPoint(x: 270, y: 70)), navy)
        expectPixel(pixel(dark, at: CGPoint(x: 270, y: 70)), swatch.solid.dark, "lightened until it reads on the dark canvas")
        expect(swatch.solid.dark != navy)
        // And back: the appearance is asked again when it changes.
        expectPixel(pixel(try render(h.editor), at: CGPoint(x: 270, y: 70)), navy)
    },
    test("a name the file lacks is drawn as the kind's default, or its own look") {
        let h = try colorHarness()
        let sheet = h.add(Sheet(CGRect(x: 20, y: 20, width: 100, height: 100)))
        let pane = h.add(Pane(CGRect(x: 220, y: 20, width: 100, height: 100)))
        h.editor.setColor(.named("brand"), of: [sheet, pane])
        let bitmap = try render(h.editor)
        expectPixel(pixel(bitmap, at: CGPoint(x: 70, y: 70)), BuiltInColors.notePaper)
        expectPixel(pixel(bitmap, at: CGPoint(x: 270, y: 70)), RGB(white: 0.5))
    },
])

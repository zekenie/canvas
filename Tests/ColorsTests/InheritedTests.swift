import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Colors
import Observation
import Palette
import TestKit

// The color a shape takes from elsewhere where it holds none of its own (`InheritedColors`): given by a
// plugin of the tests' own, as Types gives a type's notes theirs. Its own color first, then what it's
// given, then its kind's default, wherever a color shows: drawn, in the book, in a list, in the
// panel's row.

/// What the tests' giver gives each shape, and how often it was asked.
@MainActor private final class Given {
    var colors: [ShapeID: ShapeColor] = [:]
    var asked = 0
}

/// A plugin that gives the shapes that hold a color what `given` says, as a concern gives the shapes of
/// the kinds that opted into it.
@MainActor private func giver(_ given: Given, id: PluginID = "giver") -> Contributor {
    Contributor(id: id) { registrar in
        registrar.forShapes(holding: ColorProperty.self) { colored in
            colored.inheritedColor { shape, _ in
                given.asked += 1
                return given.colors[shape]
            }
        }
    }
}

/// Counts what services heard of the tints changing.
@MainActor private final class TintListener {
    var heard = 0
}

extension TintListener: EditorService {
    func shapeTintsDidChange(in editor: CanvasEditor) { heard += 1 }
}

/// Counts what the editor tells its view.
@MainActor private final class Redraws: CanvasEditorDelegate {
    var count = 0
    func editorNeedsDisplay(_ editor: CanvasEditor) { count += 1 }
    func editorCursorDidChange(_ editor: CanvasEditor) {}
    func editorEditingDidChange(_ editor: CanvasEditor) {}
}

/// A color as the list draws it in the light appearance.
@MainActor private func light(_ color: NSColor?) throws -> String {
    var found: NSColor?
    try require(NSAppearance(named: .aqua)).performAsCurrentDrawingAppearance { found = try? require(color).usingColorSpace(.sRGB) }
    let srgb = try require(found)
    return RGB(srgb.redComponent, srgb.greenComponent, srgb.blueComponent).hexString
}

@MainActor let inheritedColorTests = Suite("A color given", [
    test("a shape with no color of its own is drawn in the color it's given, its own wins, and taken away the given one is back") {
        let given = Given()
        let h = try colorHarness([giver(given)])
        let sheet = h.add(Sheet(CGRect(x: 20, y: 20, width: 100, height: 100)))
        let pane = h.add(Pane(CGRect(x: 220, y: 20, width: 100, height: 100)))
        let onSheet = CGPoint(x: 70, y: 70), onPane = CGPoint(x: 270, y: 70)
        given.colors = [sheet: .blue, pane: .teal]
        var bitmap = try render(h.editor)
        expectPixel(pixel(bitmap, at: onSheet), BuiltInColors.blue.swatch.paper.light, "the paper of the color it's given, not its kind's yellow")
        expectPixel(pixel(bitmap, at: onPane), BuiltInColors.teal.value, "a kind with no default too")
        expectPixel(pixel(try render(h.editor, dark: true), at: onPane), BuiltInColors.teal.swatch.solid.dark, "in the dark as its own would be")
        h.editor.setColor(.red, of: [sheet])
        bitmap = try render(h.editor)
        expectPixel(pixel(bitmap, at: onSheet), BuiltInColors.red.swatch.paper.light, "its own color wins")
        expectPixel(pixel(bitmap, at: onPane), BuiltInColors.teal.value)
        h.editor.setColor(nil, of: [sheet])
        expectPixel(pixel(try render(h.editor), at: onSheet), BuiltInColors.blue.swatch.paper.light, "and with none of its own, the given one is back")
        given.colors = [:]
        bitmap = try render(h.editor)
        expectPixel(pixel(bitmap, at: onSheet), BuiltInColors.notePaper, "nothing given: its kind's default")
        expectPixel(pixel(bitmap, at: onPane), RGB(white: 0.5), "nothing given and no default: its kind's own look")
    },
    test("the book says it: the color, its swatch, one role, and what's given apart from the shape's own") {
        let given = Given()
        let h = try colorHarness([giver(given)]), book = try require(h.editor.colors)
        let sheet = h.add(Sheet(CGRect(x: 20, y: 20, width: 100, height: 100)))
        given.colors = [sheet: .green]
        let record = try require(h.editor.document[sheet])
        expectEqual(book.color(of: record), .green)
        expectEqual(book.swatch(of: record), BuiltInColors.green.swatch)
        expectEqual(try light(book.color(\.paper, of: record)), BuiltInColors.green.swatch.paper.light.hexString)
        expectEqual(book.inheritedColor(of: sheet, kind: Sheet.kind), .green)
        h.editor.setColor(.value(RGB(hex: 0x0A1A4A)), of: [sheet])
        let colored = try require(h.editor.document[sheet])
        expectEqual(book.color(of: colored), .value(RGB(hex: 0x0A1A4A)), "its own first")
        expectEqual(book.inheritedColor(of: sheet, kind: Sheet.kind), .green, "what it's given is still what it's given")
        expectEqual(colored.ownColor, .value(RGB(hex: 0x0A1A4A)), "and nothing is written to it")
    },
    test("a name the file lacks is passed over for the next giver's; with none, the kind's default") {
        let first = Given(), second = Given()
        let h = try colorHarness([giver(first, id: "first"), giver(second, id: "second")]), book = try require(h.editor.colors)
        let sheet = h.add(Sheet(CGRect(x: 20, y: 20, width: 100, height: 100)))
        first.colors = [sheet: .named("brand")]
        second.colors = [sheet: .purple]
        @MainActor func color() throws -> ShapeColor? { book.color(of: try require(h.editor.document[sheet])) }
        expectEqual(try color(), .purple, "the next that answers a color the file has")
        first.colors = [sheet: .orange]
        expectEqual(try color(), .orange, "the first, in plugin order")
        first.colors = [sheet: .named("brand")]
        second.colors = [:]
        expectEqual(try color(), .yellow, "its kind's default")
        expectPixel(pixel(try render(h.editor), at: CGPoint(x: 70, y: 70)), BuiltInColors.notePaper)
    },
    test("a shape that holds a color of its own asks no giver, and a kind with no colors is never asked") {
        let given = Given()
        let h = try colorHarness([giver(given)]), book = try require(h.editor.colors)
        let sheet = h.add(Sheet(CGRect(x: 20, y: 20, width: 100, height: 100)))
        let box = h.add(Box(CGRect(x: 220, y: 20, width: 100, height: 100)))
        h.editor.setColor(.red, of: [sheet])
        given.colors = [sheet: .blue, box: .blue]
        _ = try render(h.editor)
        expectEqual(given.asked, 0, "its own color is drawn without asking")
        expectEqual(book.color(of: try require(h.editor.document[box])), nil)
        expectEqual(h.editor.tint(of: try require(h.editor.document[box])), nil)
        expectEqual(given.asked, 0, "a box has no colors")
    },
    test("a listed shape is in the given color's solid; its own wins; nothing given, its kind's tint") {
        let given = Given()
        let h = try colorHarness([giver(given)])
        let sheet = h.add(Sheet(CGRect(x: 20, y: 20, width: 100, height: 100)))
        @MainActor func tint() throws -> NSColor? { h.editor.tint(of: try require(h.editor.document[sheet])) }
        expectEqual(try tint(), nil, "a sheet declares no tint, and its default is no color of its own")
        given.colors = [sheet: .indigo]
        expectEqual(try light(try tint()), BuiltInColors.indigo.swatch.solid.light.hexString)
        expect(try tint() === tint(), "the same color each time, so a list that compares them sees no change")
        h.editor.setColor(.pink, of: [sheet])
        expectEqual(try light(try tint()), BuiltInColors.pink.swatch.solid.light.hexString, "its own wins")
        h.editor.setColor(nil, of: [sheet])
        given.colors = [sheet: .named("brand")]
        expectEqual(try tint(), nil, "a name the file lacks is nothing given")
    },
    test("the panel's row shows what's given, dimmed, as it shows a default") {
        let given = Given()
        let h = try colorHarness([giver(given)]), book = try require(h.editor.colors)
        let sheet = h.add(Sheet(CGRect(x: 20, y: 20, width: 100, height: 100)))
        given.colors = [sheet: .teal]
        var model = ColorRowModel(record: try require(h.editor.document[sheet]), book: book)
        expectEqual(model.title, "Teal")
        expect(model.isDimmed, "not the shape's own")
        expectEqual(model.tone, Tone(BuiltInColors.teal.value))
        expect(BuiltInColors.all.allSatisfy { !model.isRinged($0) }, "no dot is the shape's own")
        h.editor.setColor(.orange, of: [sheet])
        model = ColorRowModel(record: try require(h.editor.document[sheet]), book: book)
        expectEqual(model.title, "Orange")
        expect(!model.isDimmed)
    },
    test("what's given changing with no commit: the canvas draws again, the lists make their tints again, and a view showing the color reads it again") {
        let given = Given(), listener = TintListener(), redraws = Redraws()
        let h = try colorHarness([giver(given), Contributor(id: "tint-listener") { $0.service { _ in listener } }])
        let book = try require(h.editor.colors)
        _ = h.editor.service(TintListener.self)
        h.editor.delegate = redraws
        let sheet = h.add(Sheet(CGRect(x: 20, y: 20, width: 100, height: 100)))
        let record = try require(h.editor.document[sheet])
        let observed = Flag()
        withObservationTracking { _ = book.color(of: record) } onChange: { observed.set() }
        let (heard, drawn) = (listener.heard, redraws.count)
        given.colors = [sheet: .blue]
        book.inheritedColorsDidChange()
        expectEqual(listener.heard, heard + 1)
        expect(redraws.count > drawn, "the canvas draws again")
        expect(observed.isSet, "the row's model reads it again")
    },
    test("the registry's report says the contribution and the shapes it's for") {
        let h = try colorHarness([giver(Given())])
        expect(h.editor.registry.report.contains("inherited color → every shape holding color"), h.editor.registry.report)
    },
])

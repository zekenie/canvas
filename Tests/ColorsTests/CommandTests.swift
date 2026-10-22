import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Colors
import Palette
import SlashCommands
import TestKit

// `/color`: a command that takes one choice, offered on every kind that has colors. Driven headlessly
// through `SlashCommandState`, as the list does.

@MainActor private func colorCommand(_ editor: CanvasEditor, on id: ShapeID) throws -> OfferedSlashCommand {
    try require(try require(editor.slashCommands).commands(for: id).first { $0.name == "color" }, "/color is offered")
}

@MainActor private func rect(_ x: Double) -> CGRect { CGRect(x: x, y: 0, width: 100, height: 100) }

@MainActor let colorCommandTests = Suite("/color", [
    test("it takes a choice, on a kind that has colors, and is not offered on one that has none") {
        let h = try colorHarness()
        let sheet = h.add(Sheet(rect(0))), pane = h.add(Pane(rect(200))), box = h.add(Box(rect(400)))
        for id in [sheet, pane] {
            let command = try colorCommand(h.editor, on: id)
            expectEqual(command.argument, "color")
            expect(command.takesChoice)
            expect(!command.takesShape)
        }
        expect(!(try require(h.editor.slashCommands)).commands(for: box).map(\.name).contains("color"))
        expect(!(try require(h.editor.slashCommands)).run("color", on: sheet, with: SlashArguments("blue")), "it never runs with arguments")
    },
    test("its rows: the built-in colors by name in the book's order, each a chip in its solid; None only with a color of its own") {
        let h = try colorHarness(), book = try require(h.editor.colors)
        let sheet = h.add(Sheet(rect(0)))
        let all = try colorCommand(h.editor, on: sheet).choices()
        expectEqual(all.last?.title, ColorsStyle.editColors, "Edit Colors… is the last row")
        let rows = Array(all.dropLast())
        expectEqual(rows.map(\.title), book.names.map(\.name))
        expectEqual(rows.map(\.title), ["gray", "red", "orange", "yellow", "green", "teal", "blue", "indigo", "purple", "pink"])
        expectEqual(rows.map(\.group), Array(repeating: 0, count: 10), "the file has none yet")
        for (row, named) in zip(rows, book.names) {
            expectChip(row.chip, named.swatch.solid, "\(named.name)'s chip")
        }
        let anyDiffers = rows.contains { ($0.chip?.resolved(dark: false)) != ($0.chip?.resolved(dark: true)) }
        expect(anyDiffers, "dynamic colors: some follow the appearance")
        h.editor.setColor(.blue, of: [sheet])
        let withOwn = try colorCommand(h.editor, on: sheet).choices()
        expectEqual(withOwn.map(\.title), book.names.map(\.name) + ["None", ColorsStyle.editColors])
        expectEqual(withOwn.dropLast().last?.group, 2)
        expectEqual(withOwn.dropLast().last?.chip, nil)
    },
    test("typed text that reads as a hex value is offered as the one row, as it is stored; other text, nothing") {
        let h = try colorHarness()
        let sheet = h.add(Sheet(rect(0)))
        let state = try require(h.editor.slashCommands)
        let command = try colorCommand(h.editor, on: sheet)
        let row = try require(command.choice(otherwise: "#46e"))
        expectEqual(row.title, "#4466EE")
        expectChip(row.chip, Swatch(RGB(hex: 0x4466EE)).solid, "the value's chip")
        expect(command.choice(otherwise: "#4466ee")?.title == "#4466EE")
        expect(command.choice(otherwise: "#zzz") == nil)
        expect(command.choice(otherwise: "nonsense") == nil)
        expect(command.choice(otherwise: "") == nil)
        expect(state.run(command, on: sheet, choosing: row))
        expectEqual(h.editor.document[sheet]?.ownColor, .value(RGB(hex: 0x4466EE)))
    },
    test("a pick is one step, Change Color, and undo puts it back; None takes the color away") {
        let h = try colorHarness()
        let pane = h.add(Pane(rect(0)))
        let state = try require(h.editor.slashCommands)
        let command = try colorCommand(h.editor, on: pane)
        let blue = try require(command.choices().first { $0.title == "blue" })
        let before = h.editor.revision
        expect(state.run(command, on: pane, choosing: blue))
        expectEqual(h.editor.document[pane]?.ownColor, .named("blue"))
        expectEqual(h.editor.undoHistory.undoName, "Change Color")
        expect(h.editor.revision > before)
        h.editor.undo()
        expectEqual(h.editor.document[pane]?.ownColor, nil)
        h.editor.redo()
        let none = try require(try colorCommand(h.editor, on: pane).choices().first { $0.title == "None" })
        expect(state.run(try colorCommand(h.editor, on: pane), on: pane, choosing: none))
        expectEqual(h.editor.document[pane]?.ownColor, nil)
        expectEqual(h.editor.undoHistory.undoName, "Change Color")
        h.editor.undo()
        expectEqual(h.editor.document[pane]?.ownColor, .named("blue"))
    },
    test("it is offered nothing on a read-only shape, which keeps its color") {
        let h = try EditorHarness(plugins: colorPlugins([FreezingPlugin()]))
        let sheet = h.add(Sheet(rect(0)))
        let state = try require(h.editor.slashCommands)
        let command = try colorCommand(h.editor, on: sheet)
        let red = try require(command.choices().first { $0.title == "red" })
        h.editor.freeze([sheet])
        expectEqual(state.commands(for: sheet).map(\.name), [])
        h.editor.setColor(.red, of: [sheet])
        expectEqual(h.editor.document[sheet]?.ownColor, nil, "refused by the core")
        h.editor.freeze([sheet], false)
        expect(state.run(command, on: sheet, choosing: red))
        expectEqual(h.editor.document[sheet]?.ownColor, .named("red"))
    },
])

/// Whether a chip is a color that draws as a tone does in both appearances.
@MainActor private func expectChip(_ chip: NSColor?, _ tone: Tone, _ message: String, file: StaticString = #fileID, line: UInt = #line) {
    guard let chip else { expect(false, "\(message): no chip", file: file, line: line); return }
    let expected = NSColor(tone)
    for dark in [false, true] {
        let a = chip.resolved(dark: dark), b = expected.resolved(dark: dark)
        expect(zip(a, b).allSatisfy { abs($0 - $1) < 0.002 }, "\(message): \(a) isn't \(b) (dark \(dark))", file: file, line: line)
    }
}

extension NSColor {
    /// The color as it's drawn in an appearance, as sRGB components.
    @MainActor func resolved(dark: Bool) -> [CGFloat] {
        var out: [CGFloat] = []
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            let c = self.usingColorSpace(.sRGB) ?? self
            out = [c.redComponent, c.greenComponent, c.blueComponent]
        }
        return out
    }
}

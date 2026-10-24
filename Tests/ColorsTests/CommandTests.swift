import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Colors
import Palette
import SlashCommands
import TestKit
import TextEditing

// `/color`: a command that takes one choice, offered on every kind that has colors, typed in a shape's text
// or for the shapes selected (it acts on all of them together, in one step). Driven headlessly through
// `SlashCommandState`, as the list does.

@MainActor private func colorCommand(_ editor: CanvasEditor, on id: ShapeID) throws -> OfferedSlashCommand {
    try require(try require(editor.slashCommands).commands(for: id).first { $0.name == "color" }, "/color is offered")
}

@MainActor private func rect(_ x: Double) -> CGRect { CGRect(x: x, y: 0, width: 100, height: 100) }

@MainActor private func colors(_ ids: [ShapeID], in editor: CanvasEditor) -> [ShapeColor?] { ids.map { editor.document[$0]?.ownColor } }

/// What identifies each row of a list: its id, title and group (a chip is a dynamic color, so two lists made apart don't compare equal).
@MainActor private func rows(_ choices: [SlashChoice]) -> [String] { choices.map { "\($0.group) \($0.id.debugDescription) \($0.title)" } }

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

    test("a selection of one sheet is its text's /color: the same rows, the same pick, the same step") {
        let h = try colorHarness()
        let sheet = h.add(Sheet(rect(0)))
        let state = try require(h.editor.slashCommands)
        let text = try colorCommand(h.editor, on: sheet)
        let selected = try require(state.command(named: "color", for: .selection([sheet])))
        expectEqual(selected.shapes, [sheet])
        expectEqual(selected.targetCount, 1)
        expect(!selected.isPartial)
        expectEqual(selected.reach, .together)
        expectEqual(selected.argument, text.argument)
        expect(selected.takesChoice && !selected.takesShape)
        expectEqual(rows(selected.choices()), rows(text.choices()), "the rows a sheet's text lists")
        expect(state.run(selected, choosing: try require(selected.choices().first { $0.title == "green" })))
        expectEqual(h.editor.document[sheet]?.ownColor, .named("green"))
        expectEqual(h.editor.undoHistory.undoName, "Change Color")
        h.editor.setColor(.blue, of: [sheet])
        expectEqual(rows(try require(state.command(named: "color", for: .selection([sheet]))).choices()), rows(try colorCommand(h.editor, on: sheet).choices()),
                    "and None, once it has a color of its own")
    },

    test("three sheets selected: the rows are the ones a sheet lists, and None is among them only while one of the three holds a color of its own") {
        let h = try colorHarness(), book = try require(h.editor.colors)
        let sheets = (0..<3).map { h.add(Sheet(rect(Double($0) * 200))) }
        let state = try require(h.editor.slashCommands)
        let command = try require(state.command(named: "color", for: .selection(sheets)))
        expectEqual(command.shapes, sheets)
        expectEqual(command.targetCount, 3)
        expect(!command.isPartial)
        expectEqual(command.reach, .together)
        expectEqual(command.stepName, "Change Color")
        expectEqual(command.choices().map(\.title), book.names.map(\.name) + [ColorsStyle.editColors], "none holds a color: no None")
        expectEqual(rows(command.choices()), rows(try colorCommand(h.editor, on: sheets[0]).choices()))
        expectEqual(command.choice(otherwise: "#46e")?.title, "#4466EE", "a typed hex, as for one")
        h.editor.setColor(.red, of: [sheets[1]])
        let withOwn = try require(state.command(named: "color", for: .selection(sheets)))
        expectEqual(withOwn.choices().map(\.title), book.names.map(\.name) + ["None", ColorsStyle.editColors], "one of the three holds one")
        expectEqual(withOwn.choices().dropLast().last?.group, 2)
        expectEqual(try colorCommand(h.editor, on: sheets[0]).choices().map(\.title), book.names.map(\.name) + [ColorsStyle.editColors],
                    "a sheet that holds none lists none, whatever the others hold")
        expectEqual(try colorCommand(h.editor, on: sheets[1]).choices().map(\.title), withOwn.choices().map(\.title))
    },

    test("a pick colors all three sheets in one step, Change Color, that undo takes back whole; a typed hex does too, and None takes away the color of each that has one") {
        let h = try colorHarness()
        let sheets = (0..<3).map { h.add(Sheet(rect(Double($0) * 200))) }
        let state = try require(h.editor.slashCommands)
        h.editor.setColor(.red, of: [sheets[1]])
        let command = try require(state.command(named: "color", for: .selection(sheets)))
        let blue = try require(command.choices().first { $0.title == "blue" })
        let before = h.editor.revision
        expect(state.run(command, choosing: blue))
        expectEqual(colors(sheets, in: h.editor), Array(repeating: .named("blue"), count: 3))
        expectEqual(h.editor.revision, before + 1, "one transaction")
        expectEqual(h.editor.undoHistory.undoName, "Change Color")
        h.editor.undo()
        expectEqual(colors(sheets, in: h.editor), [nil, .named("red"), nil], "undone whole")
        h.editor.redo()
        expectEqual(colors(sheets, in: h.editor), Array(repeating: .named("blue"), count: 3), "and redone whole")

        let hex = try require(command.choice(otherwise: "#46e"))
        expect(state.run(command, choosing: hex))
        expectEqual(colors(sheets, in: h.editor), Array(repeating: .value(RGB(hex: 0x4466EE)), count: 3))

        let none = try require(try require(state.command(named: "color", for: .selection(sheets))).choices().first { $0.title == "None" })
        expect(state.run(command, choosing: none))
        expectEqual(colors(sheets, in: h.editor), [nil, nil, nil])
        expectEqual(h.editor.undoHistory.undoName, "Change Color")
        h.editor.undo()
        expectEqual(colors(sheets, in: h.editor), Array(repeating: .value(RGB(hex: 0x4466EE)), count: 3), "None undone whole")
    },

    test("a pane and a box selected: /color acts on the pane alone, `1 of 2`, and a pick leaves the box, which has no colors, as it is") {
        let h = try colorHarness()
        let pane = h.add(Pane(rect(0))), box = h.add(Box(rect(200)))
        let state = try require(h.editor.slashCommands)
        let command = try require(state.command(named: "color", for: .selection([pane, box])))
        expectEqual(command.shapes, [pane])
        expectEqual(command.targetCount, 2)
        expect(command.isPartial)
        let row = try require(SlashCommandPicker(at: 0, offering: [command]).rows.compactMap(\.item).first)
        expectEqual(row.detail, "color · 1 of 2")
        expectEqual(row.spoken, "color, takes color, acts on 1 of 2 shapes")
        expect(state.run(command, choosing: try require(command.choices().first { $0.title == "teal" })))
        expectEqual(colors([pane, box], in: h.editor), [.named("teal"), nil])
        expectEqual(h.editor.undoHistory.undoName, "Change Color")
        expect(state.command(named: "color", for: .selection([box])) == nil, "a box alone is offered none")
    },

    test("a sheet that is read-only among three is left out: the command acts on the other two, `2 of 3`, and the frozen one keeps its color") {
        let h = try EditorHarness(plugins: colorPlugins([FreezingPlugin()]))
        let sheets = (0..<3).map { h.add(Sheet(rect(Double($0) * 200))) }
        let state = try require(h.editor.slashCommands)
        h.editor.setColor(.red, of: [sheets[1]])
        h.editor.freeze([sheets[1]])
        let command = try require(state.command(named: "color", for: .selection(sheets)))
        expectEqual(command.shapes, [sheets[0], sheets[2]])
        expect(command.isPartial)
        expect(!command.choices().map(\.title).contains("None"), "the frozen sheet's color is not the command's to take away")
        expect(state.run(command, choosing: try require(command.choices().first { $0.title == "purple" })))
        expectEqual(colors(sheets, in: h.editor), [.named("purple"), .named("red"), .named("purple")])
        h.editor.freeze(sheets)
        expect(state.command(named: "color", for: .selection(sheets)) == nil, "all frozen: none offered")
    },

    test("the same shape named twice in a selection is colored once") {
        let h = try colorHarness()
        let sheet = h.add(Sheet(rect(0)))
        let state = try require(h.editor.slashCommands)
        let command = try require(state.command(named: "color", for: .selection([sheet, sheet])))
        expectEqual(command.shapes, [sheet])
        let before = h.editor.revision
        expect(state.run(command, choosing: try require(command.choices().first { $0.title == "pink" })))
        expectEqual(h.editor.revision, before + 1)
        expectEqual(h.editor.document[sheet]?.ownColor, .named("pink"))
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

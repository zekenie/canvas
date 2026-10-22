import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Colors
import ContextMenus
import Palette
import Selection
import SlashCommands
import TestKit

// Managing a file's own colors by keys: Edit Colors… in Color ▸ and in /color, the list it opens (its
// keys pressed as the app's panel gets them), the grid's arrows and the name form's Escape. The grid and
// the form are SwiftUI, which takes no keyboard focus in an unshown window, so their keys are held as what
// they call (`ColorGridMap`, `ColorGridState`); the list's are real key events.

private let brand = RGB(hex: 0x4465E9)
private let other = RGB(hex: 0x990000)
private let third = RGB(hex: 0x229944)

/// A board with a sheet and three colors of the file's, and the list of them open (off the screen).
@MainActor private struct Listed {
    let h: EditorHarness
    let sheet: ShapeID
    let panel: ColorListPanel
    var editor: CanvasEditor { h.editor }

    init() throws {
        ColorListPanel.ordersFront = false
        ColorListPanel.current?.close()
        h = try colorHarness()
        sheet = h.add(Sheet(CGRect(x: 0, y: 0, width: 100, height: 100)))
        h.editor.defineColor(named: "Brand", value: brand)
        h.editor.defineColor(named: "Other", value: other)
        h.editor.defineColor(named: "Third", value: third)
        h.editor.setColor(.named("Other"), of: [sheet])
        h.editor.undoHistory.seal()
        panel = try require(ColorListPanel.show(for: h.editor))
    }

    func finish() { panel.close() }

    /// A walk over the panel, reading the row that has the keyboard.
    func walk() -> KeyWalk {
        let model = panel.model
        let reader = CustomFocusReader.custom("colors") { _ in
            guard let name = model.selected else { return Focus(surface: "colors", element: "") }
            return Focus(surface: "colors", element: model.renaming == nil ? name : "\(name)/name", role: "AXRow", label: name, isMarked: true)
        }
        return KeyWalk(panel, editor: h.editor, readers: [reader])
    }
}

@MainActor private func fileNames(_ editor: CanvasEditor) -> [String] {
    (editor.colors?.fileColors ?? []).map(\.name)
}

@MainActor let colorKeyTests = Suite("Colors by keys", [
    test("Edit Colors… ends Color ▸ and opens the list, with no undo step") {
        ColorListPanel.ordersFront = false
        ColorListPanel.current?.close()
        let h = try colorHarness()
        let sheet = h.add(Sheet(CGRect(x: 0, y: 0, width: 100, height: 100)))
        h.editor.selectedShapeIDs = [sheet]
        let menu = try require(h.secondaryClick(at: CGPoint(x: 50, y: 50)))
        let outline = menu.outline
        let at = try require(outline.firstIndex { $0.hasSuffix("Color ▸") }, "\(outline)")
        let items = Array(outline[(at + 1)...].prefix { $0.hasPrefix("  ") })
        expectEqual(items.last, "  " + ColorsStyle.editColors, "\(items)")
        expect(ColorListPanel.current == nil, "nothing is open yet")
        let revision = h.editor.revision, step = h.editor.undoHistory.undoName
        try menu.choose("Color", ColorsStyle.editColors)
        expect(ColorListPanel.current != nil, "the list is open")
        expectEqual(h.editor.revision, revision)
        expectEqual(h.editor.undoHistory.undoName, step, "opening it is no step")
        ColorListPanel.current?.close()
    },
    test("/color's list ends with Edit Colors…, and picking it opens the list") {
        ColorListPanel.ordersFront = false
        ColorListPanel.current?.close()
        let h = try colorHarness()
        let sheet = h.add(Sheet(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let state = try require(h.editor.slashCommands)
        let command = try require(state.commands(for: sheet).first { $0.name == "color" })
        let step = h.editor.undoHistory.undoName
        let rows = command.choices()
        expectEqual(rows.last?.title, ColorsStyle.editColors)
        expectEqual(rows.last?.id, "\n", "an id no color name has")
        expect(state.run(command, on: sheet, choosing: try require(rows.last)))
        expect(ColorListPanel.current != nil, "the list is open")
        expectEqual(h.editor.undoHistory.undoName, step, "and nothing was written")
        expectEqual(h.editor.document[sheet]?.ownColor, nil)
        ColorListPanel.current?.close()
    },
    test("the list is the file's own colors: Up and Down walk them and stay at the ends, with Keyboard navigation on or off") {
        let l = try Listed()
        let w = l.walk()
        expectEqual(w.focus.id, "colors/Brand", "the first row has the keyboard")
        w.expectAxis(down: .down, up: .up, over: ["colors/Brand", "colors/Other", "colors/Third"])
        // The setting only decides whether standard controls (Change…) are Tab stops; the keys below do not need it.
        expect(w.keyboardNavigation || !w.keyboardNavigation)
        l.finish()
    },
    test("Return renames the row through the book, Return again gives the name: one step, and a refused name stays in the field") {
        let l = try Listed()
        let w = l.walk()
        w.press(.down)
        expectEqual(w.focus.id, "colors/Other")
        expectEqual(l.panel.model.renaming, nil)
        w.press(.return)
        expectEqual(l.panel.model.renaming, "Other")
        expectEqual(w.focus.id, "colors/Other/name")
        l.panel.model.draft = "Brand"
        w.press(.return)
        expectEqual(l.panel.model.renaming, "Other", "a taken name is not given")
        expectEqual(fileNames(l.editor), ["Brand", "Other", "Third"])
        l.panel.model.draft = "Crimson"
        let before = l.editor.revision
        w.press(.return)
        expectEqual(l.panel.model.renaming, nil)
        expectEqual(fileNames(l.editor), ["Brand", "Crimson", "Third"])
        expectEqual(l.editor.undoHistory.undoName, "Rename Color")
        expectEqual(l.editor.document[l.sheet]?.ownColor, .named("Crimson"), "the shape that held it follows")
        expect(l.editor.revision != before)
        expectEqual(l.panel.model.selected, "Crimson")
        l.editor.undo()
        expectEqual(fileNames(l.editor), ["Brand", "Other", "Third"])
        l.finish()
    },
    test("Escape in the name goes back to the list, the color as it was; a second Escape closes the list") {
        let l = try Listed()
        let w = l.walk()
        w.press(.return)
        l.panel.model.draft = "Half typed"
        w.press(.escape)
        expectEqual(l.panel.model.renaming, nil)
        expectEqual(w.focus.id, "colors/Brand")
        expectEqual(fileNames(l.editor), ["Brand", "Other", "Third"])
        expect(ColorListPanel.current === l.panel, "still open")
        w.press(.escape)
        expect(ColorListPanel.current == nil, "the second Escape closes it")
    },
    test("Delete removes the row in one step, the shapes that held it keep its value, and the keys stay on the row that took its place") {
        let l = try Listed()
        let w = l.walk()
        w.press(.down)
        w.press(.delete)
        expectEqual(fileNames(l.editor), ["Brand", "Third"])
        expectEqual(l.editor.undoHistory.undoName, "Remove Color")
        expectEqual(l.editor.document[l.sheet]?.ownColor, .value(other), "it looks as it did")
        expectEqual(w.focus.id, "colors/Third")
        w.press(.forwardDelete)
        expectEqual(fileNames(l.editor), ["Brand"])
        expectEqual(w.focus.id, "colors/Brand", "the last row's neighbor")
        l.editor.undo()
        expectEqual(fileNames(l.editor), ["Brand", "Third"])
        l.finish()
    },
    test("a held Delete removes one row, and a removal a locked shape refuses leaves the keys on its row") {
        let l = try Listed()
        let driver = KeyDriver(l.panel)
        driver.hold(.delete, repeats: 5)
        expectEqual(fileNames(l.editor), ["Other", "Third"], "the key acted once, not on every repeat")
        l.finish()

        ColorListPanel.ordersFront = false
        let h = try colorHarness([FreezingPlugin()])
        h.editor.defineColor(named: "Brand", value: brand)
        h.editor.defineColor(named: "Other", value: other)
        let sheet = h.add(Sheet(CGRect(x: 0, y: 0, width: 100, height: 100)))
        h.editor.setColor(.named("Brand"), of: [sheet])
        h.editor.freeze([sheet])
        let panel = try require(ColorListPanel.show(for: h.editor))
        KeyDriver(panel).send(.delete)
        expectEqual(fileNames(h.editor), ["Brand", "Other"], "refused whole")
        expectEqual(panel.model.selected, "Brand", "the keys stay on the row that is still there")
        panel.close()
    },
    test("each file has its own list, and a list closes with its file") {
        ColorListPanel.ordersFront = false
        ColorListPanel.current?.close()
        var first: EditorHarness? = try colorHarness()
        let second = try colorHarness()
        let one = try require(ColorListPanel.show(for: try require(first).editor))
        let two = try require(ColorListPanel.show(for: second.editor))
        expect(one !== two)
        expect(ColorListPanel.show(for: try require(first).editor) === one, "a file's list is brought forward, not made again")
        expect(one.isReleasedWhenClosed == false)
        first = nil
        expect(one.book == nil, "the file's book is gone with it")
        expect(!one.isVisible && ColorListPanel.current !== one, "and its list is closed")
        expect(ColorListPanel.current === two, "the other file's list is left open")
        two.close()
    },
    test("Change… gives the row another value in the system color panel's place, one coalesced step") {
        let l = try Listed()
        let model = l.panel.model
        let named = try require(model.colors.first { $0.name == "Third" })
        var report: ((NSColor) -> Void)?
        var started: NSColor?
        model.change(named) { color, send in
            started = color
            report = send
        }
        expectEqual(model.selected, "Third")
        expect(started != nil, "it starts from the row's value")
        let steps = undoSteps(l.editor)
        let color = NSColor(srgbRed: 0.1, green: 0.2, blue: 0.3, alpha: 1)
        try require(report)(color)
        try require(report)(NSColor(srgbRed: 0.1, green: 0.2, blue: 0.4, alpha: 1))
        expectEqual(undoSteps(l.editor), steps + 1, "a drag in the panel is one step")
        expectEqual(l.editor.undoHistory.undoName, "Change Color")
        expect(l.editor.colors?.named("Third")?.value != third, "the value changed")
        l.finish()
    },
    test("an empty list says so, and Delete and Return change nothing") {
        ColorListPanel.ordersFront = false
        ColorListPanel.current?.close()
        let h = try colorHarness()
        let panel = try require(ColorListPanel.show(for: h.editor))
        let driver = KeyDriver(panel)
        expect(panel.model.colors.isEmpty)
        let revision = h.editor.revision
        for key in [Chord.return, .delete, .down, .up] { driver.send(key) }
        expectEqual(h.editor.revision, revision)
        expectEqual(panel.model.renaming, nil)
        panel.close()
    },
    test("the grid's arrows: seven dots a row, left and right across the groups, up and down keeping the column, then the plain rows") {
        let map = ColorGridMap(groups: [10, 2], rows: 3)
        func dot(_ g: Int, _ i: Int) -> ColorGridStop { .dot(group: g, index: i) }
        expectEqual(map.start(ringed: nil), dot(0, 0))
        expectEqual(map.start(ringed: dot(0, 4)), dot(0, 4), "the ringed dot first")
        expectEqual(map.move(.right, from: dot(0, 0)), dot(0, 1))
        expectEqual(map.move(.left, from: dot(0, 0)), dot(0, 0), "stays at the start")
        expectEqual(map.move(.right, from: dot(0, 9)), dot(1, 0), "on to the next group")
        expectEqual(map.move(.left, from: dot(1, 0)), dot(0, 9))
        expectEqual(map.move(.right, from: dot(1, 1)), dot(1, 1), "stays at the last dot")
        expectEqual(map.move(.down, from: dot(0, 2)), dot(0, 9))
        expectEqual(map.move(.down, from: dot(0, 5)), dot(0, 9), "the next row is shorter: its last dot")
        expectEqual(map.move(.up, from: dot(0, 9)), dot(0, 2))
        expectEqual(map.move(.down, from: dot(0, 8)), dot(1, 1), "the next group, the column kept")
        expectEqual(map.move(.up, from: dot(1, 1)), dot(0, 8))
        expectEqual(map.move(.up, from: dot(0, 3)), dot(0, 3), "stays at the top")
        expectEqual(map.move(.down, from: dot(1, 1)), .row(0), "then the plain rows")
        expectEqual(map.move(.down, from: .row(0)), .row(1))
        expectEqual(map.move(.down, from: .row(2)), .row(2))
        expectEqual(map.move(.up, from: .row(1)), .row(0))
        expectEqual(map.move(.up, from: .row(0)), dot(1, 0), "back to the dots")
        for stop in [dot(0, 0), dot(0, 5), dot(0, 9), dot(1, 0), dot(1, 1)] {
            for (there, back) in [(ColorGridMap.Direction.right, ColorGridMap.Direction.left), (.left, .right)] {
                let moved = map.move(there, from: stop)
                if moved != stop { expectEqual(map.move(back, from: moved), stop, "\(there) then \(back) from \(stop)") }
            }
        }
        expectEqual(ColorGridMap(groups: [], rows: 2).start(ringed: nil), .row(0))
        expectEqual(ColorGridMap(groups: [0], rows: 0).start(ringed: nil), nil)
    },
    test("the grid's arrows follow its model: the file's colors are a group after the built-in ones, and the ringed dot is found in it") {
        let l = try Listed()
        let row = ColorRowModel(record: try require(l.editor.document[l.sheet]), book: try require(l.editor.colors))
        expectEqual(row.groups.map(\.count), [10, 3])
        let ringed = row.groups.enumerated().compactMap { g, colors in colors.firstIndex(where: row.isRinged).map { (g, $0) } }
        expectEqual(ringed.count, 1)
        expectEqual(ringed.first?.0, 1)
        expectEqual(ringed.first?.1, 1, "Other, the sheet's color")
        l.finish()
    },
    test("Escape in the name form goes back to the grid, and only then is it not taken (the popover closes)") {
        let l = try Listed()
        let state = ColorGridState()
        expect(!state.escape(), "on the dots it isn't taken")
        state.naming = .new
        expect(state.escape(), "in the form it is")
        expectEqual(state.naming, nil)
        expect(!state.escape(), "a second Escape is the popover's")
        state.naming = .renaming(try require(l.editor.colors?.named("Brand")))
        expect(state.escape())
        expectEqual(state.naming, nil)
        l.finish()
    },
])

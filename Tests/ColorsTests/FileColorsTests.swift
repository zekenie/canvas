import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Colors
import Foundation
import Palette
import SwiftUI
import TestKit

// A file's own named colors: the list on the file (a file value), the book following it, the four
// editor actions, and the file on disk.

private let brand = RGB(hex: 0x0A1A4A), moss = RGB(hex: 0x336633)

/// The editor's colors, by name and value.
@MainActor private func listed(_ editor: CanvasEditor) -> [String] {
    editor.colors?.fileColors.map { "\($0.name) \($0.value.hexString)" } ?? []
}

/// A file with a root holding a pane `a` ("Brand") and a sheet `d` ("Other"), and a pocket `p` whose
/// board holds a sheet `b` (written "BRAND", whatever the list's spelling) and a pane `c` (blue).
@MainActor private struct TwoBoards {
    let h: EditorHarness
    let a: ShapeID, d: ShapeID, p: ShapeID, b: ShapeID, c: ShapeID

    init(_ more: [any CanvasPlugin] = []) throws {
        h = try colorHarness([PocketsPlugin()] + more)
        let editor = h.editor
        editor.defineColor(named: "Brand", value: brand)
        editor.defineColor(named: "Other", value: RGB(hex: 0x990000))
        a = h.add(Pane(CGRect(x: 20, y: 20, width: 100, height: 100)))
        d = h.add(Sheet(CGRect(x: 220, y: 20, width: 100, height: 100)))
        p = h.add(Pocket(CGRect(x: 20, y: 160, width: 100, height: 100)))
        editor.setColor(.named("Brand"), of: [a])
        editor.setColor(.named("Other"), of: [d])
        _ = h.enter(p)
        b = h.add(Sheet(CGRect(x: 20, y: 20, width: 100, height: 100)))
        c = h.add(Pane(CGRect(x: 220, y: 20, width: 100, height: 100)))
        editor.setColor(.blue, of: [c])
        // Written as a pasted shape's might be, in another case than the list's.
        editor.transact("Write") { $0.update(b) { $0[ColorProperty.self] = .named("BRAND") } }
        _ = editor.showBoard(.root)
    }

    func own(_ id: ShapeID) -> ShapeColor? { h.editor.shape(inFile: id)?.ownColor }
}

/// Makes a shape on any board read-only (`FreezingPlugin`), or not.
@MainActor private func freeze(_ id: ShapeID, _ frozen: Bool = true, in editor: CanvasEditor) {
    editor.transact("Freeze") { $0.update(inFile: id) { $0[Frozen.self] = frozen ? true : nil } }
}

@MainActor let fileColorTests = Suite("A file's own colors", [
    test("they are listed after the built-in ones, in the order they were added, in that file only") {
        let h = try colorHarness(), other = try colorHarness()
        let book = try require(h.editor.colors)
        expectEqual(book.fileColors, [])
        expect(h.editor.defineColor(named: "Brand", value: brand))
        expect(h.editor.defineColor(named: "  Moss \n Green ", value: moss))
        expectEqual(listed(h.editor), ["Brand #0A1A4A", "Moss Green #336633"], "a name is on one line")
        expectEqual(book.names.map(\.name), BuiltInColors.all.map(\.name) + ["Brand", "Moss Green"])
        expect(book.names.dropFirst(10).allSatisfy { !$0.isBuiltIn })
        expectEqual(book.named("BRAND")?.value, brand, "found whatever the case")
        expectEqual(book.canonical(.named("moss  green")), .named("Moss Green"))
        expect(book.has(.named("brand")) && !book.has(.named("sale")))
        expectEqual(book.swatch(for: .named("Brand")), Swatch(brand))
        expectEqual(h.editor.undoHistory.undoName, "Add Color")
        expectEqual(try require(other.editor.colors).names, BuiltInColors.all, "another file has its own")
    },
    test("a value is kept to the step of 8 bits a board writes") {
        let h = try colorHarness()
        h.editor.defineColor(named: "Soft", value: RGB(0.2001, 0.4003, 0.6002))
        expectEqual(listed(h.editor), ["Soft #336699"])
        expectEqual(try require(h.editor.colors).named("Soft")?.value, RGB(hex: 0x336699))
    },
    test("a name that is empty, starts with #, is over 40 characters, is a built-in name or is another color's is refused, in any case") {
        let h = try colorHarness()
        let book = try require(h.editor.colors)
        h.editor.defineColor(named: "Brand", value: brand)
        let revision = h.editor.revision
        let refused: [(String, ColorNameRefusal)] = [
            ("", .empty), (" \n ", .empty), ("#", .startsWithHash), ("#4465E9", .startsWithHash), ("  #brand", .startsWithHash),
            (String(repeating: "x", count: 41), .tooLong), ("Blue", .builtIn), ("BLUE", .builtIn), (" teal ", .builtIn),
            ("brand", .taken), ("BRAND", .taken), ("  Brand  ", .taken),
        ]
        for (name, why) in refused {
            expectEqual(book.refusal(ofName: name), why, "“\(name)”")
            expect(!h.editor.defineColor(named: name, value: moss), "“\(name)” was added")
        }
        expectEqual(listed(h.editor), ["Brand #0A1A4A"])
        expectEqual(h.editor.revision, revision, "nothing committed")
        expectEqual(h.editor.undoHistory.undoName, "Add Color")
        // The edges: 40 characters, a # inside, a name that only looks like a built-in one.
        expect(book.refusal(ofName: String(repeating: "x", count: 40)) == nil)
        expect(book.refusal(ofName: "a#b") == nil && book.refusal(ofName: "blueish") == nil && book.refusal(ofName: "Brand 2") == nil)
        expectEqual(ColorNameRefusal.check("Sale", takenKeys: ["sale"]), .taken)
        expect(ColorNameRefusal.check("Sale") == nil)
        // A rename may change a name's case, and may not take another's.
        h.editor.defineColor(named: "Moss", value: moss)
        expect(book.refusal(ofName: "BRAND", renaming: "brand") == nil)
        expectEqual(book.refusal(ofName: "moss", renaming: "Brand"), .taken)
        expectEqual(book.refusal(ofName: "red", renaming: "Brand"), .builtIn)
    },
    test("a shape given a file's color draws its roles, in both appearances, whatever the case it names it in") {
        let h = try colorHarness()
        h.editor.defineColor(named: "Brand", value: brand)
        let sheet = h.add(Sheet(CGRect(x: 20, y: 20, width: 100, height: 100)))
        let pane = h.add(Pane(CGRect(x: 220, y: 20, width: 100, height: 100)))
        h.editor.setColor(.named("BRAND"), of: [sheet, pane])
        expectEqual(h.editor.document[pane]?.ownColor, .named("Brand"), "stored in the list's spelling")
        let swatch = Swatch(brand)
        let light = try render(h.editor), dark = try render(h.editor, dark: true)
        expectPixel(pixel(light, at: CGPoint(x: 70, y: 70)), swatch.paper.light)
        expectPixel(pixel(light, at: CGPoint(x: 270, y: 70)), swatch.solid.light)
        expectPixel(pixel(dark, at: CGPoint(x: 270, y: 70)), swatch.solid.dark)
    },
    test("a name the file lacks, such as a shape pasted from another file's, draws as the kind's default") {
        let h = try colorHarness(), source = try colorHarness()
        source.editor.defineColor(named: "Brand", value: brand)
        let sheet = source.add(Sheet(CGRect(x: 20, y: 20, width: 100, height: 100)))
        let pane = source.add(Pane(CGRect(x: 220, y: 20, width: 100, height: 100)))
        source.editor.setColor(.named("Brand"), of: [sheet, pane])
        // The shapes in a file that lacks the color.
        var file = source.editor.file
        file[FileColorsProperty.self] = FileColorList()
        h.editor.replaceFile(with: file)
        let bitmap = try render(h.editor)
        expectPixel(pixel(bitmap, at: CGPoint(x: 70, y: 70)), BuiltInColors.notePaper)
        expectPixel(pixel(bitmap, at: CGPoint(x: 270, y: 70)), RGB(white: 0.5))
        expectEqual(h.editor.document[pane]?.ownColor, .named("Brand"), "it keeps the name")
    },
    test("a color's value changes in one step that is the list's alone: every shape that names it is redrawn, and none is rewritten") {
        let h = try colorHarness()
        let book = try require(h.editor.colors)
        h.editor.defineColor(named: "Brand", value: brand)
        let pane = h.add(Pane(CGRect(x: 20, y: 20, width: 100, height: 100)))
        let other = h.add(Pane(CGRect(x: 220, y: 20, width: 100, height: 100)))
        h.editor.setColor(.named("Brand"), of: [pane])
        h.editor.setColor(.blue, of: [other])
        expectPixel(pixel(try render(h.editor), at: CGPoint(x: 70, y: 70)), brand)
        var calls = 0
        book.onChange { calls += 1 }
        let before = h.editor.document, revision = h.editor.revision
        expect(h.editor.setColorValue(of: "brand", to: moss), "whatever the case")
        expectEqual(calls, 1, "the handlers hear it once")
        expectEqual(h.editor.document, before, "no shape was committed to")
        expectEqual(h.editor.revision, revision + 1, "one commit")
        expectEqual(h.editor.undoHistory.undoName, "Change Color")
        expectEqual(listed(h.editor), ["Brand #336633"], "it keeps its name")
        let bitmap = try render(h.editor)
        expectPixel(pixel(bitmap, at: CGPoint(x: 70, y: 70)), moss)
        expectPixel(pixel(bitmap, at: CGPoint(x: 270, y: 70)), BuiltInColors.blue.value)
        // Nothing to change, or no such color: no step.
        expect(!h.editor.setColorValue(of: "Brand", to: moss) && !h.editor.setColorValue(of: "Sale", to: moss) && !h.editor.setColorValue(of: "blue", to: moss))
        expectEqual(calls, 1)
        expectEqual(h.editor.revision, revision + 1)
        h.editor.undo()
        expectEqual(calls, 2)
        expectPixel(pixel(try render(h.editor), at: CGPoint(x: 70, y: 70)), brand)
        h.editor.redo()
        expectPixel(pixel(try render(h.editor), at: CGPoint(x: 70, y: 70)), moss)
        expectEqual(calls, 3)
    },
    test("renaming renames it on every shape that holds it, on every board, whatever the case, in one step; undo puts it all back") {
        let t = try TwoBoards(), editor = t.h.editor
        let book = try require(editor.colors)
        var calls = 0
        book.onChange { calls += 1 }
        let before = editor.file
        expect(editor.renameColor("brand", to: "Mark"))
        expectEqual(calls, 1)
        expectEqual(editor.undoHistory.undoName, "Rename Color")
        expectEqual(listed(editor), ["Mark #0A1A4A", "Other #990000"], "in the same place in the list")
        expectEqual(t.own(t.a), .named("Mark"))
        expectEqual(t.own(t.b), .named("Mark"), "on the pocket's board, written in another case")
        expectEqual(t.own(t.c), .blue)
        expectEqual(t.own(t.d), .named("Other"))
        expect(book.named("Brand") == nil && book.named("mark") != nil)
        expectPixel(pixel(try render(editor), at: CGPoint(x: 70, y: 70)), brand, "drawn as it was")
        editor.undo()
        expectEqual(editor.undoHistory.undoName, "Write", "that was the whole step")
        expectEqual(editor.file, before)
        expectEqual(listed(editor), ["Brand #0A1A4A", "Other #990000"])
        expectEqual(t.own(t.b), .named("BRAND"))
        expectEqual(calls, 2)
        editor.redo()
        expectEqual(t.own(t.a), .named("Mark"))
        expectEqual(t.own(t.b), .named("Mark"))
        expectEqual(calls, 3)
    },
    test("renaming may change a name's case; it is refused for a name the rules refuse, the name it has and a color the file lacks") {
        let t = try TwoBoards(), editor = t.h.editor
        let before = editor.file, revision = editor.revision
        for (old, new) in [("Brand", "Other"), ("Brand", "OTHER"), ("Brand", "blue"), ("Brand", "#123456"), ("Brand", ""), ("Brand", "Brand"),
                           ("Brand", " Brand "), ("blue", "Sky"), ("Sale", "Sky"), ("Brand", String(repeating: "x", count: 41))] {
            expect(!editor.renameColor(old, to: new), "\(old) to “\(new)”")
        }
        expectEqual(editor.file, before)
        expectEqual(editor.revision, revision)
        expect(editor.renameColor("BRAND", to: "brand"))
        expectEqual(listed(editor), ["brand #0A1A4A", "Other #990000"])
        expectEqual(t.own(t.a), .named("brand"))
        expectEqual(t.own(t.b), .named("brand"))
    },
    test("removing leaves each shape that held the color looking as it did, with its value as a hex color, in one step") {
        let t = try TwoBoards(), editor = t.h.editor
        let before = editor.file
        let pane = try render(editor)
        let swatch = Swatch(brand)
        expectPixel(pixel(pane, at: CGPoint(x: 70, y: 70)), swatch.solid.light)
        var calls = 0
        try require(editor.colors).onChange { calls += 1 }
        expect(editor.removeColor("BRAND"))
        expectEqual(calls, 1)
        expectEqual(editor.undoHistory.undoName, "Remove Color")
        expectEqual(listed(editor), ["Other #990000"])
        expectEqual(t.own(t.a), .value(brand))
        expectEqual(t.own(t.b), .value(brand), "on the pocket's board, written in another case")
        expectEqual(t.own(t.c), .blue)
        expectEqual(t.own(t.d), .named("Other"))
        expectPixel(pixel(try render(editor), at: CGPoint(x: 70, y: 70)), swatch.solid.light, "drawn as it was")
        expectPixel(pixel(try render(editor, dark: true), at: CGPoint(x: 70, y: 70)), swatch.solid.dark)
        editor.undo()
        expectEqual(editor.file, before)
        expectEqual(t.own(t.a), .named("Brand"))
        expectEqual(t.own(t.b), .named("BRAND"))
        editor.redo()
        expectEqual(t.own(t.b), .value(brand))
        expect(!editor.removeColor("Brand") && !editor.removeColor("blue") && !editor.removeColor("Sale"))
    },
    test("a read-only shape that holds the color keeps its look: a rename or a removal changes nothing and the shape shakes") {
        let log = RefusalLog()
        let t = try TwoBoards([FreezingPlugin(log: log)]), editor = t.h.editor
        freeze(t.b, in: editor)
        let before = editor.file, undo = editor.undoHistory.undoName
        expect(!editor.renameColor("Brand", to: "Mark"))
        expect(!editor.removeColor("Brand"))
        expectEqual(editor.file, before, "no shape, and not the list, changed")
        expectEqual(editor.undoHistory.undoName, undo)
        expectEqual(log.refusals, [[t.b], [t.b]], "the shape is heard refused")
        // A value change rewrites no shape, so it is the same for a frozen one.
        expect(editor.setColorValue(of: "Brand", to: moss))
        // Naming a frozen shape's value adds no color nothing would name.
        editor.setColor(.value(RGB(hex: 0x224466)), of: [t.c])
        freeze(t.c, in: editor)
        let held = editor.file, step = editor.undoHistory.undoName
        expect(!editor.nameColor(of: t.c, "Slate"))
        expectEqual(editor.file, held, "neither the list nor the shape changed")
        expectEqual(editor.undoHistory.undoName, step)
        expectEqual(log.refusals.last, [t.c], "and it shakes")
        freeze(t.c, false, in: editor)
        expect(editor.nameColor(of: t.c, "Slate"))
        expectEqual(t.own(t.c), .named("Slate"))
        // Thawed, it goes through.
        freeze(t.b, false, in: editor)
        expect(editor.renameColor("Brand", to: "Mark"))
        expectEqual(t.own(t.b), .named("Mark"))
    },
    test("each undoes and redoes: the book follows the file") {
        let h = try colorHarness()
        let editor = h.editor, book = try require(editor.colors)
        var calls = 0
        book.onChange { calls += 1 }
        editor.defineColor(named: "Brand", value: brand)
        editor.defineColor(named: "Moss", value: moss)
        editor.setColorValue(of: "Brand", to: .white)
        editor.renameColor("Moss", to: "Fern")
        editor.removeColor("Brand")
        expectEqual(listed(editor), ["Fern #336633"])
        expectEqual(calls, 5)
        let states = [["Brand #FFFFFF", "Fern #336633"], ["Brand #FFFFFF", "Moss #336633"], ["Brand #0A1A4A", "Moss #336633"], ["Brand #0A1A4A"], []]
        for state in states {
            editor.undo()
            expectEqual(listed(editor), state)
            expectEqual(book.names.count, 10 + state.count)
        }
        expectEqual(calls, 10)
        for state in Array(states.reversed().dropFirst()) + [["Fern #336633"]] {
            editor.redo()
            expectEqual(listed(editor), state)
        }
        expectEqual(calls, 15)
        expect(!editor.canRedo)
    },
    test("a file put in place has the colors it has: the book and what is drawn follow, with the board shown or another") {
        let h = try colorHarness([PocketsPlugin()]), editor = h.editor, book = try require(editor.colors)
        editor.defineColor(named: "Brand", value: brand)
        var calls = 0
        book.onChange { calls += 1 }
        let source = try colorHarness()
        source.editor.defineColor(named: "Moss", value: moss)
        let pane = source.add(Pane(CGRect(x: 20, y: 20, width: 100, height: 100)))
        source.editor.setColor(.named("Moss"), of: [pane])
        // The same board shown.
        editor.replaceFile(with: source.editor.file)
        expectEqual(listed(editor), ["Moss #336633"])
        expectEqual(calls, 1)
        expectPixel(pixel(try render(editor), at: CGPoint(x: 70, y: 70)), moss)
        expect(!editor.canUndo, "a file put in place is no step")
        // A file with the same colors changes nothing to hear.
        editor.replaceFile(with: source.editor.file)
        expectEqual(calls, 1)
        // With a switch of board: the file lacks the pocket the editor is in.
        let pocket = h.add(Pocket(CGRect(x: 220, y: 20, width: 100, height: 100)))
        _ = h.enter(pocket)
        expect(!editor.board.isRoot)
        var other = CanvasFile()
        other[FileColorsProperty.self] = FileColorList([FileColor(name: "Sand", value: RGB(hex: 0xC2B280))])
        editor.replaceFile(with: other)
        expect(editor.board.isRoot, "the board it was on is gone")
        expectEqual(listed(editor), ["Sand #C2B280"])
        expectEqual(calls, 2)
        // And a file with none.
        editor.replaceFile(with: CanvasFile())
        expectEqual(listed(editor), [])
        expectEqual(calls, 3)
    },
    test("the book is the same on a board that is not the root, and a switch of board is nothing to it") {
        let h = try colorHarness([PocketsPlugin()]), editor = h.editor, book = try require(editor.colors)
        let pocket = h.add(Pocket(CGRect(x: 20, y: 20, width: 100, height: 100)))
        editor.defineColor(named: "Brand", value: brand)
        var calls = 0
        book.onChange { calls += 1 }
        _ = h.enter(pocket)
        expect(!editor.board.isRoot)
        expectEqual(listed(editor), ["Brand #0A1A4A"])
        expect(editor.defineColor(named: "Moss", value: moss), "added from the pocket's board")
        let pane = h.add(Pane(CGRect(x: 20, y: 20, width: 100, height: 100)))
        editor.setColor(.named("Moss"), of: [pane])
        expectPixel(pixel(try render(editor), at: CGPoint(x: 70, y: 70)), moss)
        expectEqual(calls, 1)
        _ = editor.showBoard(.root)
        expectEqual(listed(editor), ["Brand #0A1A4A", "Moss #336633"], "the file's, from any board")
        _ = h.enter(pocket)
        editor.undo()
        editor.undo()
        editor.undo()
        expectEqual(listed(editor), ["Brand #0A1A4A"])
        expectEqual(calls, 2, "a switch of board told it nothing")
    },
    test("a book made after the file has colors starts with them") {
        let source = try colorHarness()
        source.editor.defineColor(named: "Brand", value: brand)
        let h = try colorHarness(file: source.editor.file)
        expectEqual(listed(h.editor), ["Brand #0A1A4A"])
        expectEqual(try require(h.editor.colors).named("brand")?.value, brand)
    },
    test("without Colors there is no color to define") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        expect(!h.editor.defineColor(named: "Brand", value: brand) && !h.editor.renameColor("Brand", to: "Mark"))
        expect(!h.editor.setColorValue(of: "Brand", to: moss) && !h.editor.removeColor("Brand"))
        expect(!h.editor.canUndo)
    },
])

@MainActor let fileColorsOnDiskTests = Suite("A file's own colors on disk", [
    test("the registry shows the file property, and the file holds the list only while it has a color") {
        let registry = try Registry(plugins: colorPlugins())
        expect(registry.report.contains("file property colors"), registry.report)
        expectEqual(registry.declaredFileProperties, ["colors"])
        expectEqual(registry.owner(ofFileProperty: "colors"), .colors)
        let h = try colorHarness()
        expectEqual(h.editor.file.fileValueKeys, [])
        h.editor.defineColor(named: "Brand", value: brand)
        expectEqual(h.editor.file.fileValueKeys, ["colors"])
        h.editor.removeColor("Brand")
        expectEqual(h.editor.file.fileValueKeys, [], "none left, none held")
    },
    test("it is written as a list of names and hex values at format 6, and a file without is written as it was") {
        let h = try colorHarness()
        let codec = BoardCodec(registry: h.editor.registry)
        let plain = try codec.encode(h.editor.file)
        h.editor.defineColor(named: "Brand Blue", value: RGB(hex: 0x123456))
        h.editor.defineColor(named: "Sale", value: RGB(hex: 0xD6336C))
        let data = try codec.encode(h.editor.file)
        let text = String(decoding: data, as: UTF8.self)
        expect(text.contains(#""format" : 6"#), text)
        expect(text.contains(#"""
              "colors" : {
                "v" : 0,
                "value" : [
                  {
                    "name" : "Brand Blue",
                    "value" : "#123456"
                  },
                  {
                    "name" : "Sale",
                    "value" : "#D6336C"
                  }
                ]
              }
          """#), text)
        h.editor.undo()
        h.editor.undo()
        expectEqual(try codec.encode(h.editor.file), plain, "no colors, no values")
        expect(!String(decoding: plain, as: UTF8.self).contains("colors"))
    },
    test("the colors save and open as they were, whatever boards the file has, with nothing to report") {
        let t = try TwoBoards()
        let codec = BoardCodec(registry: t.h.editor.registry)
        let data = try codec.encode(t.h.editor.file)
        let loaded = try codec.decode(data)
        expectEqual(loaded.file, t.h.editor.file)
        expectEqual(loaded.file[FileColorsProperty.self].entries.map(\.name), ["Brand", "Other"])
        expect(loaded.report.isEmpty, "\(loaded.report)")
        expectEqual(try codec.encode(loaded.file), data)
        // Opened, the editor has the colors and draws its shapes in them.
        let opened = try colorHarness([PocketsPlugin()], file: loaded.file)
        expectEqual(listed(opened.editor), ["Brand #0A1A4A", "Other #990000"])
        expectPixel(pixel(try render(opened.editor), at: CGPoint(x: 70, y: 70)), brand)
    },
    test("an entry that is not a name and a hex value is dropped on reading, and so is a name the rules refuse; the file is not refused") {
        let h = try colorHarness()
        h.editor.defineColor(named: "Brand", value: brand)
        let codec = BoardCodec(registry: h.editor.registry)
        var envelope = try require(JSONSerialization.jsonObject(with: try codec.encode(h.editor.file)) as? [String: Any])
        var values = try require(envelope["values"] as? [String: Any]), colors = try require(values["colors"] as? [String: Any])
        colors["value"] = [
            ["name": "Moss", "value": "#336633"], ["name": "Sale"], ["value": "#336633"], ["name": "Red", "value": "#336633"],
            "text", 4, ["name": "Sky", "value": "blue"], ["name": "#Hash", "value": "#336633"], ["name": "", "value": "#336633"],
            ["name": "moss", "value": "#000000"], ["name": String(repeating: "x", count: 41), "value": "#336633"], ["name": "Tan", "value": "#cc9966"],
        ] as [Any]
        values["colors"] = colors
        envelope["values"] = values
        let loaded = try codec.decode(try JSONSerialization.data(withJSONObject: envelope))
        expectEqual(loaded.file[FileColorsProperty.self].entries, [FileColor(name: "Moss", value: moss), FileColor(name: "Tan", value: RGB(hex: 0xCC9966))])
        expect(loaded.report.isEmpty, "\(loaded.report)")
        expectEqual(loaded.file.keptFileValues, [])
        // What isn't a list at all is kept aside whole, as any value is.
        colors["value"] = "Brand"
        values["colors"] = colors
        envelope["values"] = values
        let kept = try codec.decode(try JSONSerialization.data(withJSONObject: envelope))
        expectEqual(kept.file.keptFileValues, ["colors"])
        expectEqual(kept.file[FileColorsProperty.self].entries, [])
    },
    test("a real board document saves them with the board and opens them again, unedited") {
        BoardDocument.configuration = BoardConfiguration(registry: try Registry(plugins: colorPlugins())) { _ in AnyView(EmptyView()) }
        let board = BoardDocument()
        defer { board.close() }
        let plain = try board.data(ofType: BoardConfiguration.typeIdentifier)
        expect(board.editor.defineColor(named: "Brand", value: brand))
        expect(board.isDocumentEdited, "a color edits the board")
        let data = try board.data(ofType: BoardConfiguration.typeIdentifier)
        expectEqual(data, try BoardCodec(registry: board.editor.registry).encode(board.editor.file))
        expect(data != plain)
        let reopened = BoardDocument()
        defer { reopened.close() }
        try reopened.read(from: data, ofType: BoardConfiguration.typeIdentifier)
        expectEqual(listed(reopened.editor), ["Brand #0A1A4A"])
        expectEqual(reopened.editor.file, board.editor.file)
        expect(reopened.loadReport.isEmpty)
        for _ in 0..<5 { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.002)) }
        expect(!reopened.isDocumentEdited)
        expectEqual(try reopened.data(ofType: BoardConfiguration.typeIdentifier), data)
        // Removed, it saves as it did before there was one.
        reopened.editor.removeColor("Brand")
        expectEqual(try reopened.data(ofType: BoardConfiguration.typeIdentifier), plain)
    },
])

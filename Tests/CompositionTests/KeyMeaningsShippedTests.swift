import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import DetailPanel
@_spi(Host) import CanvasUI
import Foundation
import Locking
import Publishing
import Selection
import ShippedTesting
import StickyNotes
import TestKit
import Titles
import Types
import Validation

// Keyboard navigation's P6, same key, same meaning, held across the app as it ships: on each surface every key of the
// table (CanvasTesting's `KeyMeanings`) is pressed from a middle stop, and what it did is held to what it means there,
// the only other meanings the named exceptions of the principle's text, each a surface takes by name. A key that
// means something else is a line of the pending list, with the slice that closes it, until it is fixed.

/// The P6 gaps the surfaces show, each "<gap>, <slice id>: why it is open". Each needs the lead's call: a named
/// exception in the principle's text, or the key changed.
/// What no named exception yet covers on the surfaces walked: none. An entry here fails once it passes, so it goes.
let meaningsPending: [String] = []

extension SampleBoardWindow {
    /// The sample board's six notes, named by their place in reading order ("1" to "6").
    var noteNames: [ShapeID: String] {
        Dictionary(uniqueKeysWithValues: notes.enumerated().map { ($0.element, "\($0.offset + 1)") })
    }

    /// How deep the keyboard is: the board 0, a shape 1, a part of it or the list 2, a shape being edited 3.
    func depth() -> Int {
        if editor.editingShapeID != nil { return 3 }
        if editor.hasFocusedPart || listHasKeyboard { return 2 }
        return editor.selectedShapeIDs.isEmpty ? 0 : 1
    }

    /// The menu bar's commands sent to this window's controller, as the key window's are (an unshown window is never key).
    func sendsCommandsToItsController() {
        func target(_ menu: NSMenu) {
            for item in menu.items {
                if item.target == nil, item.action == #selector(BoardWindowController.runCommand(_:)) { item.target = controller }
                if let submenu = item.submenu { target(submenu) }
            }
        }
        target(menus.main)
    }

    /// Back to the board as it started, nothing open or edited.
    func restore(_ start: CanvasFile) {
        editor.endEditing()
        editor.closeCard()
        window.settle()
        while editor.file != start, editor.canUndo { editor.undo() }
        editor.setTool(.select)
        editor.selection = nil
    }
}

@MainActor let keyMeaningsShippedTests = Suite("Same key, same meaning, shipped", [
    test("the table is the principle's: every row of its keys has a meaning, and every row with exceptions has them named, each with a reason") {
        // The repository's, found from this file, not from the process's working directory.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent(".claude/rules/keyboard-navigation.md"), encoding: .utf8)
        let sections = text.components(separatedBy: "## What each key means")
        expectEqual(sections.count, 2, "the principle has a section \"What each key means\"")
        let table = sections.last?.components(separatedBy: "\n## ").first ?? ""
        let rows = table.split(separator: "\n").filter { $0.hasPrefix("| ") && !$0.hasPrefix("| Key") && !$0.hasPrefix("| ---") }
        expect(rows.count >= 10, "the table's rows: \(rows.count)")
        let named = Set(KeyMeanings.canonical.map(\.keys))
        var withExceptions: [Chord] = []
        for row in rows {
            let cells = row.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 4 else { continue }
            // "Tab, ⇧Tab", "↑ ↓" (keys side by side) and "Page Up, Page Down" (a key of two words): by commas, then by spaces unless it is a row's.
            let pieces: [String] = cells[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let keys: [String] = pieces.flatMap { (piece: String) -> [String] in named.contains(piece) ? [piece] : piece.split(separator: " ").map(String.init) }
            for key in keys { expect(named.contains(key), "the principle's \(key) has no row in KeyMeanings") }
            let chords = KeyMeanings.canonical.filter { keys.contains($0.keys) }.flatMap(\.chords)
            if !cells[3].isEmpty {
                withExceptions += chords
                expect(KeyMeanings.exceptions.contains { !Set($0.keys).isDisjoint(with: chords) },
                       "the exceptions of \(cells[1]) aren't held as data: \(cells[3])")
            }
        }
        for exception in KeyMeanings.exceptions {
            expect(!exception.reason.isEmpty, "\(exception.id) gives no reason")
            expect(exception.keys.allSatisfy { withExceptions.contains($0) }, "the exception \(exception.id) is for keys whose rows name no exception in the principle")
        }
        for row in KeyMeanings.canonical where row.meaning != .filter { expect(!row.chords.isEmpty, "\(row.keys) has no chord to press") }
    },
    test("a surface that gives a key a meaning of its own with no named exception fails") {
        let surface = KeySurface("A list", axes: .vertical, overrides: [.init(.right, [.acted], exception: "turns-a-row")])
        expect(KeyMeanings.exception("turns-a-row") == nil)
        expectEqual(surface.allowed(.right), [.acted])
        expectEqual(KeySurface("A list", axes: .vertical).allowed(.right), [.none], "a list's → means the item after in a line, which it has none of")
        expectEqual(KeySurface("A list", axes: .vertical).allowed(.down), [.forward])
    },
    test("the canvas: from the second of six notes each key means what the table says, the arrows and Space as the canvas's named exceptions") {
        let w = try SampleBoardWindow()
        defer { w.board.close() }
        let editor = w.editor, names = w.noteNames, second = w.notes[1]
        let walk = KeyWalk(w.window, editor: editor, readers: [.canvas(w.canvas, editor: editor, names: names, part: { editor.focusedPart?.title }),
                                                                .panel(of: w.canvas)])
        walk.pending = meaningsPending
        let start = editor.file
        let surface = KeySurface("The canvas", overrides: [
            .init(.up, [.acted], exception: "canvas-arrows"), .init(.down, [.acted], exception: "canvas-arrows"),
            .init(.left, [.acted], exception: "canvas-arrows"), .init(.right, [.acted], exception: "canvas-arrows"),
            .init(.space, [.acted, .none], exception: "canvas-space"),
        ])
        walk.expectMeanings(of: surface, stops: (1...6).map { "canvas/\($0)" }, at: 1, depth: { _ in w.depth() }, reset: {
            w.restore(start)
            editor.selection = second
            w.window.makeFirstResponder(w.canvas)
            w.window.settle()
        })
    },
    test("a shape's parts: from the lock of a locked public note joined to another, each key means what the table says, Tab going on to the next shape as the canvas's") {
        let w = try NestedWindow()
        defer { w.board.close() }
        let (note, other) = w.nest.notes(on: 1)
        w.editor.makePublic([note])
        w.editor.lock([note])
        w.editor.undoHistory.seal()
        let editor = w.editor, start = editor.file
        let walk = w.partsWalk(names: [note: "note", other: "other"])
        walk.pending = meaningsPending
        let stops = ["canvas/note/Public", "canvas/note/Locked", "canvas/note/Arrow to Note"]
        let surface = KeySurface("A shape's parts", overrides: [
            .init(.tab, [.shallower], exception: "canvas-tab"), .init(.backTab, [.shallower], exception: "canvas-tab"),
            .init(.up, [.acted, .none], exception: "canvas-arrows"), .init(.down, [.acted, .none], exception: "canvas-arrows"),
            .init(.left, [.acted, .none], exception: "canvas-arrows"), .init(.right, [.acted, .none], exception: "canvas-arrows"),
        ])
        walk.expectMeanings(of: surface, stops: stops, at: 1, depth: { _ in
            editor.editingShapeID != nil ? 3 : editor.hasFocusedPart ? 2 : editor.selectedShapeIDs.isEmpty ? 0 : 1
        }, reset: {
            editor.endEditing()
            while editor.file != start, editor.canUndo { editor.undo() }
            editor.selection = nil
            editor.selection = note
            w.window.makeFirstResponder(w.canvas)
            for _ in 0..<4 where editor.focusedPart?.title != "Locked" { walk.driver.send(.optionTab) }
            w.window.settle()
        })
    },
    test("a note's rows, edited: from its middle row each key means what the table says, the rows a column") {
        let m = try Minute()
        defer { m.close() }
        let editor = m.editor, note = m.layerNote
        let rowsView = { m.canvas.descendants(RowsView.self).first }
        let walk = KeyWalk(m.window, editor: editor, readers: [
            .custom("note") { window in
                guard let editing = editor.editingShapeID else { return nil }
                let element = editing == note ? rowsView()?.focusedRow ?? "words" : "other"
                return .of(window, surface: "note", element: element)
            },
            .canvas(m.canvas, editor: editor, names: [note: "Layer"]),
        ], settle: .both(m.h.scheduler))
        walk.pending = meaningsPending
        let start = editor.file
        let surface = KeySurface("A note's rows", axes: .vertical, overrides: [
            .init(.optionTab, [.acted], exception: "text-option-tab"), .init(.optionBackTab, [.acted], exception: "text-option-tab"),
            .init(.return, [.shallower], exception: "text-return"),
        ])
        walk.expectMeanings(of: surface, stops: ["note/words", "note/order", "note/purpose", "note/title"], at: 2, depth: { _ in
            editor.editingShapeID != nil ? 2 : editor.selectedShapeIDs.isEmpty ? 0 : 1
        }, reset: {
            editor.endEditing()
            editor.closeCard()
            m.h.scheduler.advance(by: .zero)
            while editor.file != start, editor.canUndo { editor.undo() }
            editor.selection = note
            _ = editor.beginEditing(note)
            m.h.scheduler.advance(by: .zero)
            m.window.settle()
            for _ in 0..<4 where rowsView()?.focusedRow != "purpose" {
                walk.driver.send(.tab)
                m.h.scheduler.advance(by: .zero)
                m.window.settle()
            }
        })
    },
    test("the issue walk's list: from the second of three stops of a board each key means what the table says, Tab one stop of the panel's loop, Page Up and Page Down going by board as the list's named exception") {
        let scene = try ListWalk(boards: true)
        // A third stop on the root, so the current stop has one above and one below it on a board of the list, with Texas under it.
        try scene.draw(#"sticky-note "Prius" right of "Corolla" is: "Listing" text: "Dented." fieldValues: {"make": "Toyota"}"#, flagged: 5)
        let prius = try require(scene.editor.file[.root].shapes.first { $0[TitleProperty.self] == "Prius" }, "Prius in the file").id
        let start = scene.editor.file
        let w = scene.w, editor = scene.editor, walk = scene.walk
        let names: [ShapeID: String] = [scene.mustang: "Mustang", scene.corolla: "Corolla", scene.camry: "Camry", scene.civic: "Civic", prius: "Prius"]
        let table = { scene.table }
        let keys = KeyWalk(w.window, editor: editor, readers: [
            .custom("list") { window in
                guard let list = table(), window.firstResponder === list, let row = walk.currentRow else { return nil }
                return .of(window, surface: "list", element: names[row.shape] ?? "?")
            },
            .canvas(w.canvas, editor: editor, names: names),
            .panel(of: w.canvas),
        ])
        keys.pending = meaningsPending
        let surface = KeySurface("The issue walk's list", axes: .vertical, isOneStopOfLoop: true, overrides: [
            // Another board shown is a change of the editor's revision, so the walk calls it an act: the check below holds that
            // it is the board that changed.
            .init(.pageUp, [.none, .forward, .backward, .elsewhere, .acted], exception: "board-pages"),
            .init(.pageDown, [.none, .forward, .backward, .elsewhere, .acted], exception: "board-pages"),
        ])
        // The root's three stops between its head and Texas's (folded).
        let stops = ["list/Mustang", "list/Corolla", "list/Prius"]
        keys.expectMeanings(of: surface, stops: stops, at: 1, depth: { focus in
            // The canvas 0, the band 1, the list 2, the shape's panel under a closed list 3 (Return goes into the shape).
            // With Keyboard navigation on, Escape from the list gives the band the keyboard: the panel says where it is.
            if focus.surface == "list" { return 2 }
            if focus.surface == "canvas" { return 0 }
            switch editor.detailPanel?.keyboardPlace {
            case .band: return 1
            case .takeover: return 2
            case .content: return 3
            case nil: return walk.isListOpen ? 2 : (walk.isRunning ? 3 : 0)
            }
        }, reset: {
            while editor.canUndo, editor.file != start { editor.undo() }
            if walk.isRunning { walk.end() }
            try? scene.begin(at: .shape(scene.corolla), stops: 5)
            walk.toggleList()
            w.window.spin { scene.table != nil && w.window.firstResponder === scene.table }
            w.window.settle()
        })
        // The exception's meaning, held directly: from the root's second stop Page Down is Texas's first stop and Page Up the
        // previous board's, wrapping, the board shown following.
        try? scene.begin(at: .shape(scene.corolla), stops: 5)
        walk.toggleList()
        w.window.spin { scene.table != nil && w.window.firstResponder === scene.table }
        keys.press(.init(.pageDown))
        w.window.settle()
        expectEqual(walk.currentRow?.shape, scene.camry, "Page Down: the first stop of the next board")
        expectEqual(editor.board, scene.texas)
        keys.press(.init(.pageUp))
        w.window.settle()
        expectEqual(editor.board, .root, "Page Up: the previous board")
    },
    test("the table of contents: from its third row each key means what the table says, the rows a column") {
        let w = try SampleBoardWindow(sidebar: true)
        defer { w.board.close() }
        w.window.spin { w.rows == 6 }
        w.sendsCommandsToItsController()
        let editor = w.editor, start = editor.file
        let walk = KeyWalk(w.window, editor: editor, menu: w.menus.main, readers: [
            .custom("toc") { window in
                guard let list = w.list, window.firstResponder === list else { return nil }
                return .of(window, surface: "toc", element: "\(list.selectedRow)")
            },
            .canvas(w.canvas, editor: editor, names: w.noteNames),
        ])
        walk.pending = meaningsPending
        var rowsBefore = 0
        let surface = KeySurface("The table of contents", axes: .vertical, overrides: [
            .init(.right, [.acted, .none], exception: "outline-arrows"), .init(.left, [.acted, .none], exception: "outline-arrows"),
        ])
        walk.expectMeanings(of: surface, stops: (0...5).map { "toc/\($0)" }, at: 2, depth: { _ in w.depth() },
                            acted: { w.listHasKeyboard && w.rows != rowsBefore }, reset: {
            w.restore(start)
            w.window.makeFirstResponder(w.canvas)
            w.window.spin { w.list != nil && w.titleField == nil }
            walk.driver.send(.focusSidebar)
            w.window.spin { w.listHasKeyboard && w.rows > 0 }
            for _ in 0..<3 { walk.driver.send(.down) }
            w.window.settle()
            // A row → opened is closed again.
            if w.rows > 6 {
                walk.driver.send(.left)
                w.window.spin { w.rows == 6 }
            }
            rowsBefore = w.rows
        })
    },
])

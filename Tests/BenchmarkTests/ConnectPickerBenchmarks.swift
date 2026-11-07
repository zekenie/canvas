import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Connections
import CoreGraphics
import LanguageModels
import Mentions
import ShippedTesting
import StickyNotes
import Subboards
import TestKit
import Titles

// ⌘L's picker over a board of thousands of shapes and notes on another board: the line that opens it (the picker made for the
// shape, nothing typed: the recent picks and the nearest, then those on other boards) and each keystroke after it, the kinds
// the port table joins to a note ranked in Mentions' catalog and each shape asked once a commit what a pick of it would take.

extension Budget {
    /// A keystroke in ⌘L's picker, the one that opens it included, over a board of 10,000 shapes and 500 notes on another board:
    /// the `@` picker's. The thread's CPU time. Never measured before the picker: set to what a release build did, 2026-11-07, 5.0 ms for the slowest, the one letter that matches most of the board
    /// (see the report line).
    static let connectPickerKeystroke = 8.0
}

@MainActor let connectPickerBenchmarks = Suite("Connect picker benchmarks", [
    test("a keystroke in ⌘L's picker costs what matches, not the board: 10,000 shapes and 500 notes on another board") {
        for size in sizes {
            let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
            let board = generatedBoard(shapes: size)
            let owner = try require(board.shapes.first { $0.kind == Subboard.kind })
            let far = (0..<500).map { index -> AnyShapeRecord in
                var note = AnyShapeRecord(ShapeRecord(StickyNote(frame: CGRect(x: CGFloat(index % 25) * 260, y: CGFloat(index / 25) * 260, width: 200, height: 200), text: "")))
                note[TitleProperty.self] = "Archive \(index)"
                return note
            }
            let file = CanvasFile(root: board, children: [owner.id: CanvasDocument(shapes: far)])
            let editor = CanvasEditor(registry: registry, file: file, scheduler: ManualScheduler())
            let source = try require(board.shapes.first { $0.kind == StickyNote.kind && $0[TitleProperty.self] != nil }).id
            // The first ask makes the kinds' members, one pass over the catalog; every one after costs what they are.
            let first = median(runs: 1, onThread: true) { _ = ConnectPicker(editor: editor, source: source) }
            let opening = median(runs: 21, onThread: true) { _ = ConnectPicker(editor: editor, source: source) }
            let picker = try require(ConnectPicker(editor: editor, source: source))
            expect(picker.rows.count > 1 && picker.rows.last == .itself, "the shapes nearest, then Itself")
            var worst = (query: "", ms: opening)
            for query in ["a", "ar", "arc", "archive", "archive 4", "pn11", "archve 4", "title 40", "zzzzq"] {
                let before = String(query.dropLast())
                let ms = median(runs: 21, prepare: { picker.setQuery(before) }, onThread: true) { picker.setQuery(query) }
                if ms > worst.ms { worst = (query, ms) }
            }
            picker.setQuery("archive 4")
            expect(picker.rows.contains { if case .shape = $0 { true } else { false } }, "the notes of the other board")
            report(String(format: "%6d shapes, 500 notes on another board, ⌘L's picker: first opened %6.3f ms, then %6.3f ms, the slowest keystroke %6.3f ms (\"%@\") (budget %.0f)",
                          size, first, opening, worst.ms, worst.query, Budget.connectPickerKeystroke))
            if holdsToBudgets {
                expect(opening < Budget.connectPickerKeystroke, "opening ⌘L's picker over \(size) shapes took \(opening) ms")
                expect(worst.ms < Budget.connectPickerKeystroke, "a keystroke in ⌘L's picker (\(worst.query)) over \(size) shapes took \(worst.ms) ms")
            }
        }
    },
])

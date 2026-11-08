import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Engineering
import LanguageModels
import LineRows
import ShippedTesting
import TestKit
import Titles

// A keystroke in a table's line (LineRows' field and the column grammar): after `total_cents i`, the `n` that makes it
// `total_cents in`, over a board of thousands of shapes, 500 tables and 50 enums: the line read again (its spans, its
// enum named by name), what fits at the caret offered (SQL's types and the file's enums) and ranked. The file's enums are
// kept until the file changes, so a keystroke reads a list, never the board.

extension Budget {
    /// A keystroke in a table's line over 10,000 shapes, 500 tables and 50 enums: read, offers and their ranking. The
    /// thread's CPU time. Never measured before the line: set from what a release build did on 2026-11-07, 0.25 ms at 1,000
    /// shapes and 0.31 at 10,000 (an enum's name 0.27 at both; the first, which lists the file's enums, 4.0 and 1.3), with
    /// room for a busy machine.
    static let lineKeystroke = 1.0
}

@MainActor let lineBenchmarks = Suite("Line benchmarks", [
    test("a keystroke in a table's line costs the line and what's offered, not the board: 10,000 shapes, 500 tables, 50 enums") {
        for size in sizes {
            let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
            var board = generatedBoard(shapes: size)
            var added: [AnyShapeRecord] = []
            for index in 0..<500 {
                var table = ShapeRecord(DatabaseTable(frame: CGRect(x: CGFloat(index % 25) * 320, y: 40_000 + CGFloat(index / 25) * 200, width: 300, height: 116),
                                                      columns: ["id uuid pk", "customer_id uuid", "status order_status_\(index % 50)", "placed_at timestamptz?"].compactMap { ColumnGrammar.read($0) }))
                table[TitleProperty.self] = "table_\(index)"
                added.append(AnyShapeRecord(table))
            }
            for index in 0..<50 {
                var type = ShapeRecord(DatabaseEnum(frame: CGRect(x: CGFloat(index) * 260, y: 50_000, width: 220, height: 100), values: [EnumValue(text: "a"), EnumValue(text: "b")]))
                type[TitleProperty.self] = "order_status_\(index)"
                added.append(AnyShapeRecord(type))
            }
            board = CanvasDocument(shapes: board.shapes + added)
            let editor = CanvasEditor(registry: registry, file: CanvasFile(root: board), scheduler: ManualScheduler())
            editor.turn(EngineeringKit.self, on: true)
            let table = try require(added.first).id
            editor.beginEditing(table)
            let view = try require(editor.makeEditingView()?.view as? LineRowsView)
            let field = view.field
            let first = median(runs: 1, onThread: true) {
                field.show(LineText("total_cents i"))
                field.insertText("n", replacementRange: NSRange(location: 13, length: 0))
            }
            let keystroke = median(runs: 21, prepare: { field.show(LineText("total_cents i")) }, onThread: true) {
                field.insertText("n", replacementRange: NSRange(location: 13, length: 0))
            }
            expectEqual(Array(field.listedOffers.prefix(5)), ["int", "int8", "integer", "interval", "inet"])
            let named = median(runs: 21, prepare: { field.show(LineText("status order_status_4")) }, onThread: true) {
                field.insertText("9", replacementRange: NSRange(location: 21, length: 0))
            }
            report(String(format: "%6d shapes, 500 tables and 50 enums, a keystroke in a table's line: first %6.3f ms, then %6.3f ms, an enum's name %6.3f ms (budget %.0f)",
                          size, first, keystroke, named, Budget.lineKeystroke))
            if holdsToBudgets {
                expect(keystroke < Budget.lineKeystroke, "a keystroke in a table's line over \(size) shapes took \(keystroke) ms")
                expect(named < Budget.lineKeystroke, "an enum's name typed in a table's line over \(size) shapes took \(named) ms")
            }
            editor.endEditing()
        }
    },
])

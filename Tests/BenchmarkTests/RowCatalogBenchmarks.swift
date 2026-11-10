import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Connections
import CoreGraphics
import Engineering
import LanguageModels
import LineRows
import Mentions
import ShippedTesting
import StickyNotes
import TestKit
import Titles

// Mentions' catalog with rows (K5): a board of thousands of shapes and 500 tables of 10 columns, 5,000 rows. The `@` picker, which
// lists no rows, keeps its budget with the rows in the catalog; ⌘L's picker opened on a row, which ranks them (`orders cust`,
// `orders.cust`), keeps ⌘L's; a keystroke after `→ cu` in a table's line (the tables Mentions finds, their key columns offered)
// keeps the line's; and a commit to one table reads again its rows alone.

@MainActor let rowCatalogBenchmarks = Suite("Row catalog benchmarks", [
    test("rows in the catalog cost what matches: the @ picker, ⌘L's picker on a row and a line's → cu, over 10,000 shapes and 5,000 rows") {
        for size in sizes {
            let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
            var board = generatedBoard(shapes: size)
            var tables: [AnyShapeRecord] = []
            for index in 0..<500 {
                let lines = ["id uuid pk", "email text unique", "customer_id uuid", "status text", "placed_at timestamptz?", "total_cents int",
                             "currency char(3)", "note text", "created_at timestamptz", "updated_at timestamptz"]
                var table = ShapeRecord(DatabaseTable(frame: CGRect(x: CGFloat(index % 25) * 320, y: 40_000 + CGFloat(index / 25) * 300, width: 300, height: 260),
                                                      columns: lines.compactMap { ColumnGrammar.read($0) }))
                table[TitleProperty.self] = "table_\(index)"
                tables.append(AnyShapeRecord(table))
            }
            board = CanvasDocument(shapes: board.shapes + tables)
            let editor = CanvasEditor(registry: registry, file: CanvasFile(root: board), scheduler: ManualScheduler())
            editor.turn(EngineeringKit.self, on: true)
            let mentions = try require(editor.mentions)
            expectEqual(mentions.listedParts(of: tables[0].id).count, 10, "each table's rows in the catalog")

            // The @ picker on a note: no rows listed, the rows in the catalog besides.
            let owner = try require(board.shapes.first { $0.kind == StickyNote.kind }?.id)
            let at = MentionPicker(at: 0, mentions: mentions, scope: AnyMentionable.self, owner: owner)
            var mention = (query: "@", ms: median(runs: 21, onThread: true) { _ = MentionPicker(at: 0, mentions: mentions, scope: AnyMentionable.self, owner: owner) })
            for query in ["p", "pl", "plan 11", "table_4", "table_4 cust", "zzzzq"] {
                let typed = "@" + query as NSString, before = "@" + query.dropLast() as NSString
                let ms = median(runs: 21, prepare: { _ = at.read(before, selection: NSRange(location: before.length, length: 0), isEdit: true) }, onThread: true) {
                    _ = at.read(typed, selection: NSRange(location: typed.length, length: 0), isEdit: true)
                }
                if ms > mention.ms { mention = ("@" + query, ms) }
            }

            // ⌘L's picker opened on a row of a table: tables and the rows of tables, ranked by their paths.
            let source = tables[0].id
            let row = try require(tables[0].typed(as: DatabaseTable.self)?.props.columns[2].id)
            let end = ConnectEnd(source, part: row)
            let opening = median(runs: 21, onThread: true) { _ = ConnectPicker(editor: editor, source: end) }
            let picker = try require(ConnectPicker(editor: editor, source: end))
            var connect = (query: "", ms: opening)
            for query in ["t", "ta", "table_4", "table_4 c", "table_4 cu", "table_41.cust", "cust", "zzzzq"] {
                let before = String(query.dropLast())
                let ms = median(runs: 21, prepare: { picker.setQuery(before) }, onThread: true) { picker.setQuery(query) }
                if ms > connect.ms { connect = (query, ms) }
            }
            picker.setQuery("table_41.cust")
            expect(picker.rows.contains { if case .shape(let choice, _) = $0 { choice.candidate.part?.name == "customer_id" } else { false } }, "a row by its table's name")

            // A keystroke after `→ c` in a table's line: the tables found, each one's key columns offered.
            editor.beginEditing(source)
            let view = try require(editor.makeEditingView()?.view as? LineRowsView)
            let field = view.field
            let line = "customer_id uuid → c", at2 = (line as NSString).length
            let keystroke = median(runs: 21, prepare: { field.show(LineText(line)) }, onThread: true) {
                field.insertText("u", replacementRange: NSRange(location: at2, length: 0))
            }
            editor.endEditing()

            // A commit renaming a column of one table: the next keystroke reads that table's rows again, and no other's, and judges what
            // it lists anew (each shape's verdict, as the picker's own benchmark reports and holds to no budget).
            var renamed = 0
            let upkeep = median(runs: 11, prepare: {
                renamed += 1
                editor.transact("Rename Column") { $0.update(source, as: DatabaseTable.self) { $0.props.columns[3].name = "status_\(renamed)" } }
            }, onThread: true) { picker.setQuery("table_4 cu") }

            report(String(format: "%6d shapes and 5,000 rows: the @ picker's slowest keystroke %6.3f ms (\"%@\") (budget %.0f); ⌘L's picker on a row opened %6.3f ms, the slowest %6.3f ms (\"%@\"), (budget %.0f), the first after a commit %6.3f ms; → cu in a line %6.3f ms (budget %.0f)",
                          size, mention.ms, mention.query, Budget.pickerKeystroke, opening, connect.ms, connect.query, Budget.connectPickerKeystroke, upkeep,
                          keystroke, Budget.lineKeystroke))
            if holdsToBudgets {
                expect(mention.ms < Budget.pickerKeystroke, "a keystroke in the @ picker (\(mention.query)) over \(size) shapes and 5,000 rows took \(mention.ms) ms")
                expect(opening < Budget.connectPickerKeystroke, "opening ⌘L's picker on a row over \(size) shapes and 5,000 rows took \(opening) ms")
                expect(connect.ms < Budget.connectPickerKeystroke, "a keystroke in ⌘L's picker on a row (\(connect.query)) over \(size) shapes took \(connect.ms) ms")
                expect(keystroke < Budget.lineKeystroke, "→ cu in a table's line over \(size) shapes and 500 tables took \(keystroke) ms")
            }
        }
    },
])

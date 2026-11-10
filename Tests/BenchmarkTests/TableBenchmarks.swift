import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Clipboard
import CoreGraphics
import Engineering
import Foundation
import Geometry
import LanguageModels
import ShippedTesting
import TestKit
import Titles

// The engineering kit's tables zoomed out: a bar a name and a bar a type for every row in view, in a card with its title a bar
// above it (Titles' bars). A table draws no more than a note's skeleton would; what's measured is what a board of thousands of
// them, and a few of hundreds of columns, cost a frame when many are in view, where each row is a fraction of a pixel.

extension Budget {
    /// A frame of a board of 10,000 titled tables of four columns and 20 of 300, zoomed out to fit it (10%) and at 6%, where
    /// some 4,000 of them are in view, within what a frame zoomed out may cost. Never measured before the tables: a release
    /// build did on 2026-11-07 8 ms fitted and 10 at 6%, where a row is under 2 points and its bars aren't drawn; with them it
    /// was 20 ms at 6% (some 5 µs a table in view), which is why they aren't. Since K17 the floor is 3 points (about 12%) for every
    /// kind written as lines: at 10% a row is 2.4 points, so the fitted frame draws no row bars either, only each table's title bar,
    /// filled as a plain rect where thinner than 4 points (benchmarks.md has the numbers).
    static let tablesZoomedOut = zoomedOut
    /// What a paste again of a 200-table dump that widens one table costs more than one that changes it without widening it: the
    /// widening put is drawn on a rehearsal of the file and taken in as one step (U7, review R4), so a refused put leaves
    /// nothing. A person feels a pause of about 100 ms more (U10's scope); it was 222 ms more until the put stopped asking a draw
    /// of the whole script which shapes it changes before drawing it, then 10 (release, 2026-11-09): three times that.
    /// benchmarks.md has the numbers.
    static let widenedPaste = 30.0
}

@MainActor let tableBenchmarks = Suite("Table benchmarks", [
    test("a frame zoomed out over 10,000 titled tables, 20 of them 300 columns long, costs the cards in view, no bar a row once a row is under 3 points (about 12%)") {
        let viewport = CGSize(width: 1200, height: 800)
        let context = try bitmapContext(viewport)
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        let columns = ["id uuid pk", "customer_id uuid", "status text", "placed_at timestamptz?"].compactMap { ColumnGrammar.read($0) }
        var added: [AnyShapeRecord] = []
        for index in 0..<10_000 {
            var table = ShapeRecord(DatabaseTable(frame: CGRect(x: CGFloat(index % 100) * 340, y: CGFloat(index / 100) * 220, width: 300, height: 116), columns: columns))
            table[TitleProperty.self] = "table_\(index)"
            added.append(AnyShapeRecord(table))
        }
        let long = (0..<300).map { Column(name: "column_\($0)", type: TypeRef("text")) }
        for index in 0..<20 {
            var table = ShapeRecord(DatabaseTable(frame: CGRect(x: CGFloat(index) * 340, y: -8_000, width: 300, height: 7_000), columns: long))
            table[TitleProperty.self] = "long_\(index)"
            added.append(AnyShapeRecord(table))
        }
        let h = EditorHarness { CanvasEditor(registry: registry, document: CanvasDocument(shapes: added), scheduler: $0) }
        h.editor.viewportDidResize(to: viewport)
        var lines: [String] = [], worst = 0.0
        for (name, camera) in [("fitted", Camera(fitting: h.editor.shapeBounds, in: viewport, inset: 0)),
                               ("at 6%", camera(centering: h.editor.shapeBounds, at: 0.06, in: viewport))] {
            h.editor.camera = camera
            expect(h.editor.drawsSkeletons, "\(name): skeletons")
            draw(h.editor, into: context, size: viewport)
            let frame = median(runs: 11, onThread: true) {
                h.editor.camera.origin.x += 0.5
                draw(h.editor, into: context, size: viewport)
            }
            worst = max(worst, frame)
            lines.append(String(format: "%@ (%.1f%%) %5.1f ms", name, camera.zoom * 100, frame))
        }
        report(String(format: "10,020 titled tables zoomed out: a frame %@ (budget %.0f)", lines.joined(separator: "; "), Budget.tablesZoomedOut))
        if holdsToBudgets { expect(worst < Budget.tablesZoomedOut, "a frame zoomed out over 10,020 titled tables took \(worst) ms") }
    },
    test("a 200-table dump pasted again with one table changed: a column that widens it (drawn on a rehearsal of the file, taken in as one step) costs no pause more than one that doesn't") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let registry = try Registry(plugins: shippedPlugins(pasteboard))
        let h = EditorHarness { CanvasEditor(registry: registry, scheduler: $0) }
        h.editor.viewportDidResize(to: CGSize(width: 1440, height: 900))
        h.editor.turn(EngineeringKit.self, on: true)
        /// The dump: 200 tables, each but the first keyed to the one before; `changed` added to table 100's columns.
        @MainActor func dump(_ changed: String? = nil) -> String {
            (0..<200).map { index in
                var columns = ["id uuid PRIMARY KEY", "name text NOT NULL", "created_at timestamptz"]
                if index > 0 { columns.append("parent_id uuid REFERENCES t\(index - 1)(id)") }
                if index == 100, let changed { columns.append(changed) }
                return "CREATE TABLE t\(index) (\(columns.joined(separator: ", ")));"
            }.joined(separator: "\n")
        }
        @MainActor func holds(_ sql: String) {
            pasteboard.clearContents()
            pasteboard.setString(sql, forType: .string)
        }
        holds(dump())
        h.editor.paste()
        h.editor.undoHistory.seal()
        let table = try require(h.editor.document.shapes.first { $0[TitleProperty.self] == "t100" }).id
        let width = try require(h.editor.document[table]?.box?.width)
        expectEqual(h.editor.document.shapes.filter { $0.kind == DatabaseTable.kind }.count, 200)
        /// The dump with `changed` pasted again, each run from the board as the first paste left it.
        @MainActor func again(_ changed: String) -> Double {
            var pasted = false
            let time = median(runs: 5, prepare: {
                if pasted { h.editor.undo() }
                holds(dump(changed))
                pasted = true
            }, onThread: true) { h.editor.paste() }
            return time
        }
        let plain = again("note text")
        expectEqual(h.editor.document[table]?.box?.width, width, "a short column widens nothing")
        h.editor.undo()
        let widening = again("placed_at_in_the_shoppers_own_time_zone timestamp with time zone")
        expect((h.editor.document[table]?.box?.width ?? 0) > width, "the long column widens t100")
        h.editor.undo()
        report(String(format: "a 200-table dump pasted again: one table given a column %.0f ms, one widened %.0f ms (%.0f more; budget %.0f)",
                      plain, widening, widening - plain, Budget.widenedPaste))
        if holdsToBudgets { expect(widening - plain < Budget.widenedPaste, "widening took \(widening - plain) ms more than not") }
    },
])

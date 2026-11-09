import AppKit
@_spi(Host) import Canvas
import CanvasTesting
@_spi(Host) import CanvasUI
import CoreGraphics
import Engineering
import Foundation
import Geometry
import LanguageModels
import LineRows
import Selection
import ShippedTesting
import StickyNotes
import TestKit
import Titles

// Rows (K11): a board where one shape in ten is a 12-row table and one in a hundred a 60-row table, the rest notes, drawn
// at 100% and 70% (each table's rows in view only, their text set once) and zoomed out at 30% and 10% (a bar a line in
// view, one fill a color, none where a row is under 2 points); and ⌃⌘↑ on 1,000 tables with nothing selected, then the
// frame after (each fold a provided layout input, laid out again only for the tables folded); a row moved by ⌥↑ (K8) and
// one event of a row dragged (K9).

extension Budget {
    /// A frame of the rows board at 100% and at 70%. Never measured before rows were folded: the budget is a frame.
    static let rowsFrame = frame
    /// A frame of the rows board zoomed out, at 30% and 10%: what a frame zoomed out may cost.
    static let rowsSkeleton = zoomedOut
    /// ⌃⌘↑ on 1,000 tables with nothing selected, and the frame after. Never measured before folds: a release build did
    /// 21 to 29 ms on a busy machine on 2026-11-07, the fold itself 3, the rest the frame that lays the 1,000 out again,
    /// which costs 16 to 18 ms with no fold at all (the core's relayout of 1,000 tables, the floor); the budget two frames.
    static let foldMany = 2 * frame
    /// ⌥↑ on a row selected as an item of a 500-row table (K8: the key through the window, Selection's `moveItems`, `moveRows`, one
    /// step, the item selected again). The plan holds it within a keystroke in a field (1 ms): first measured 86 ms (every commit
    /// listed the shape's items and worked out all 500 rows' words), 0.5 ms for `moveRows` alone once the words were lazy, and
    /// through the key 1.25 ms until `moveItems` stopped listing the items it never reads, then 0.89 ms on a quiet machine
    /// (2026-11-08, debug build the bench makes, load average 3.7); two keystrokes of headroom for a loaded one.
    static let rowMoveCommit = 2 * fieldKeystroke
    /// The frame after that key, its table in view with the row selected: a frame (the items' outline reads the kept list).
    static let rowMoveFrame = frame
    /// One event of a drag of rows (K9) over a board of 10,000 shapes: the shape under the pointer (the spatial grid), the gap
    /// nearest it, and where the rows would land there worked out through the kind's move. The plan's: within 1 ms. Never
    /// measured before the drag.
    static let rowDragEvent = 1.0
    /// A frame while 400 rows of a 500-row table are dragged over a board of 4,000 shapes: the ghost (a card of the 400, laid out and
    /// drawn as one layer each frame), the rows it takes faded where they are, the hint and the drop line. A frame, as any.
    static let rowDragFrame = frame
    /// A column added to the top table of a column of 50 in a database, on a board of 4,000 shapes, every table under it
    /// pushed down a line (U3, `Transaction.makeRoom()`) in the commit: the scope's "within the field keystroke budget's
    /// order". Never measured before the push: see benchmarks.md for what it measured, and the same commit with nothing under it.
    static let roomPush = 2 * fieldKeystroke
    /// A column added to a table on the board itself, nothing under it, on the same board: the push finds what is under it by
    /// the editor's index, so it costs what it reaches and not the board (U3). Held to the same two keystrokes.
    static let roomBoard = 2 * fieldKeystroke
}

/// `count` shapes in a grid 280 apart, each tenth a 12-row titled table, each hundredth a 60-row one, the rest notes.
@MainActor private func rowsBoard(_ count: Int) -> [AnyShapeRecord] {
    let short = (0..<12).map { Column(name: "column_\($0)", type: TypeRef("uuid"), primaryKey: $0 == 0) }
    let long = (0..<60).map { Column(name: "column_\($0)", type: TypeRef("text"), unique: $0 == 1, primaryKey: $0 == 0) }
    return (0..<count).map { index in
        let origin = CGPoint(x: CGFloat(index % 40) * 340, y: CGFloat(index / 40) * 360)
        if index % 10 == 0 {
            let columns = index % 100 == 0 ? long : short
            var table = ShapeRecord(DatabaseTable(frame: CGRect(origin: origin, size: CGSize(width: 300, height: KitStyle.height(rows: columns.count))),
                                                  columns: columns))
            table[TitleProperty.self] = "table_\(index)"
            return AnyShapeRecord(table)
        }
        return AnyShapeRecord(ShapeRecord(StickyNote(frame: CGRect(origin: origin, size: CGSize(width: 200, height: 200)))))
    }
}

/// A database at (-4000, -4000) and 50 five-row tables in a column inside it, 20 apart (put in it once the editor has them), the
/// gap inside under the last, so a push down a line grows the database every time and the database pushes at the board's level
/// in turn, beside `rowsBoard(4_000)`: the records, the database first, the top table's id and the last's.
@MainActor private func columnOfTables() -> (records: [AnyShapeRecord], top: ShapeID, last: ShapeID) {
    let columns = (0..<5).map { Column(name: "column_\($0)", type: TypeRef("text"), primaryKey: $0 == 0) }
    let height = KitStyle.height(rows: 5)
    var database = ShapeRecord(Database(frame: CGRect(x: -4000, y: -4000, width: 400, height: 50 * (height + 20) + Settlement.gap)))
    database[TitleProperty.self] = "shop"
    var records = [AnyShapeRecord(database)]
    for index in 0..<50 {
        var table = ShapeRecord(DatabaseTable(frame: CGRect(x: -3970, y: -3980 + CGFloat(index) * (height + 20), width: 300, height: height), columns: columns))
        table[TitleProperty.self] = "column_table_\(index)"
        records.append(AnyShapeRecord(table))
    }
    return (records, records[1].id, records[50].id)
}

@MainActor let rowBenchmarks = Suite("Row benchmarks", [
    test("roomPush: a column added to the top of 50 tables in a database pushes the other 49 down a line, in the commit, within two keystrokes") {
        let viewport = CGSize(width: 1200, height: 800)
        let context = try bitmapContext(viewport)
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        let (column, top, last) = columnOfTables()
        var lone = ShapeRecord(DatabaseTable(frame: CGRect(x: -6000, y: -4000, width: 300, height: KitStyle.height(rows: 5)),
                                             columns: (0..<5).map { Column(name: "column_\($0)", type: TypeRef("text")) }))
        lone[TitleProperty.self] = "lone"
        let h = EditorHarness { CanvasEditor(registry: registry, document: CanvasDocument(shapes: rowsBoard(4_000) + column + [AnyShapeRecord(lone)]), scheduler: $0) }
        h.editor.viewportDidResize(to: viewport)
        h.editor.put(column.dropFirst().map(\.id), in: column[0].id)
        expectEqual(h.editor.holder(of: last), column[0].id)
        // A frame first, as the window draws one: every shape's size kept, as the app keeps them.
        h.editor.camera = camera(centering: CGRect(x: -4000, y: -4000, width: 400, height: 600), at: 1, in: viewport)
        draw(h.editor, into: context, size: viewport)
        var pushing = Double.infinity, board = Double.infinity, none = Double.infinity
        for run in 0..<measuredRuns(9) {
            let was = h.editor.document[last]?.box?.minY ?? 0, heightWas = h.editor.document[column[0].id]?.box?.height ?? 0
            let cost = threadCPUTime {
                h.editor.transact("Add Column") { $0.update(top, as: DatabaseTable.self) { $0.props.columns.append(Column(name: "added_\(run)", type: TypeRef("text"))) } }
            }.milliseconds
            expect((h.editor.document[last]?.box?.minY ?? 0) > was, "the last table pushed")
            expect((h.editor.document[column[0].id]?.box?.height ?? 0) > heightWas, "and the database grew to hold it, every run")
            pushing = min(pushing, cost)
            // A table on the board itself grown, nothing under it: the board's level read for what it reaches.
            board = min(board, threadCPUTime {
                h.editor.transact("Add Column") { $0.update(lone.id, as: DatabaseTable.self) { $0.props.columns.append(Column(name: "added_\(run)", type: TypeRef("text"))) } }
            }.milliseconds)
            // A change that grows nothing (a column renamed): what the commit costs without the push.
            none = min(none, threadCPUTime {
                h.editor.transact("Rename Column") { $0.update(top, as: DatabaseTable.self) { $0.props.columns[1].name = "renamed_\(run)" } }
            }.milliseconds)
        }
        report(String(format: "a column added over a column of 50 tables in a database, 4,000 shapes: %.3f ms pushing 49 and growing the database (budget %.0f); a table on the board grown, nothing under it, %.3f (budget %.0f); a rename, growing nothing, %.3f",
                      pushing, Budget.roomPush, board, Budget.roomBoard, none))
        if holdsToBudgets {
            expect(pushing < Budget.roomPush, "a commit that pushes 49 tables and grows their database took \(pushing) ms")
            expect(board < Budget.roomBoard, "a commit that grows a table on the board, nothing under it, took \(board) ms")
        }
    },
    test("rowsFrame and rowsSkeleton: a frame of a board where one shape in ten is a 12-row table and one in a hundred a 60-row one, at 100%, 70%, 30% and 10%") {
        let viewport = CGSize(width: 1200, height: 800)
        let context = try bitmapContext(viewport)
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        let h = EditorHarness { CanvasEditor(registry: registry, document: CanvasDocument(shapes: rowsBoard(4_000)), scheduler: $0) }
        h.editor.viewportDidResize(to: viewport)
        var lines: [String] = [], full = 0.0, zoomedOut = 0.0
        for zoom in [1.0, 0.7, 0.3, 0.1] {
            h.editor.camera = camera(centering: CGRect(x: 0, y: 0, width: 40 * 340, height: 100 * 360), at: zoom, in: viewport)
            draw(h.editor, into: context, size: viewport)
            let frame = median(runs: 11, onThread: true) {
                h.editor.camera.origin.x += 0.5
                draw(h.editor, into: context, size: viewport)
            }
            if zoom >= 0.35 { full = max(full, frame) } else { zoomedOut = max(zoomedOut, frame) }
            lines.append(String(format: "%.0f%% %5.1f ms", zoom * 100, frame))
        }
        report(String(format: "rows board of 4,000 shapes: a frame %@ (budgets %.0f, %.0f)", lines.joined(separator: "; "), Budget.rowsFrame, Budget.rowsSkeleton))
        if holdsToBudgets {
            expect(full < Budget.rowsFrame, "a frame of the rows board took \(full) ms")
            expect(zoomedOut < Budget.rowsSkeleton, "a frame of the rows board zoomed out took \(zoomedOut) ms")
        }
    },
    test("foldMany: ⌃⌘↑ on 1,000 tables with nothing selected, and the frame after, within a frame") {
        let viewport = CGSize(width: 1200, height: 800)
        let context = try bitmapContext(viewport)
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        let tables = rowsBoard(10_000).filter { $0.kind == DatabaseTable.kind }
        expectEqual(tables.count, 1_000)
        var cost = 0.0, folding = 0.0, frame = 0.0, relaid = 0.0
        for _ in 0..<measuredRuns(5) {
            let h = EditorHarness { CanvasEditor(registry: registry, document: CanvasDocument(shapes: tables), scheduler: $0) }
            h.editor.viewportDidResize(to: viewport)
            h.editor.camera = camera(centering: CGRect(x: 0, y: 0, width: 4 * 340, height: 3 * 360), at: 1, in: viewport)
            draw(h.editor, into: context, size: viewport)
            let ids = h.editor.document.shapes.map(\.id)
            let bare = threadCPUTime { h.editor.shapesDidChangeLayout(ids); draw(h.editor, into: context, size: viewport) }.milliseconds
            relaid = relaid == 0 ? bare : min(relaid, bare)
            let fold = threadCPUTime { _ = h.editor.perform(.foldRows) }.milliseconds
            let after = threadCPUTime { draw(h.editor, into: context, size: viewport) }.milliseconds
            expectEqual(h.editor.rowFolds?.folded.count, 1_000)
            if cost == 0 || fold + after < cost { (cost, folding, frame) = (fold + after, fold, after) }
        }
        report(String(format: "⌃⌘↑ on 1,000 tables and the frame after: %.1f ms (the fold %.1f, the frame %.1f; the 1,000 laid out again unfolded and a frame %.1f; budget %.0f)",
                      cost, folding, frame, relaid, Budget.foldMany))
        if holdsToBudgets { expect(cost < Budget.foldMany, "folding 1,000 tables took \(cost) ms") }
    },
    test("rowMoveCommit: ⌥↑ (the key, through the window) on a row selected as an item of a 500-row table, on a board of 4,000 shapes, within a keystroke, and the frame after within a frame") {
        let viewport = CGSize(width: 1200, height: 800)
        let context = try bitmapContext(viewport)
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        let columns = (0..<500).map { Column(name: "column_\($0)", type: TypeRef("text"), primaryKey: $0 == 0) }
        var big = ShapeRecord(DatabaseTable(frame: CGRect(x: -2000, y: -2000, width: 300, height: KitStyle.height(rows: columns.count)), columns: columns))
        big[TitleProperty.self] = "big"
        let h = EditorHarness { CanvasEditor(registry: registry, document: CanvasDocument(shapes: rowsBoard(4_000) + [AnyShapeRecord(big)]), scheduler: $0) }
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: viewport), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let canvas = CanvasView(editor: h.editor)
        window.contentView = canvas
        h.editor.viewportDidResize(to: viewport)
        h.editor.camera = camera(centering: CGRect(x: -2000, y: -2000, width: 300, height: 600), at: 1, in: viewport)
        var cost = Double.infinity, frameAfter = Double.infinity
        for run in 0..<measuredRuns(9) {
            // A row in the middle, a step of its own each time (sealed), so every move is a commit of its own.
            h.editor.selectItems([AnyHashable(columns[250 + run % 2].id)], of: big.id)
            h.editor.undoHistory.seal()
            let before = h.editor.document[big.id]?.typed(as: DatabaseTable.self)?.props.columns.map(\.id)
            let move = threadCPUTime { _ = window.press(Chord(Key.up, .option)) }.milliseconds
            expect(h.editor.document[big.id]?.typed(as: DatabaseTable.self)?.props.columns.map(\.id) != before, "⌥↑ moved the row")
            let frame = threadCPUTime { draw(h.editor, into: context, size: viewport) }.milliseconds
            cost = min(cost, move)
            frameAfter = min(frameAfter, frame)
        }
        report(String(format: "⌥↑ on a row of a 500-row table over 4,000 shapes: the key %.3f ms (budget %.0f), the frame after %.1f ms (budget %.0f)",
                      cost, Budget.rowMoveCommit, frameAfter, Budget.rowMoveFrame))
        if holdsToBudgets {
            expect(cost < Budget.rowMoveCommit, "moving a row of a 500-row table took \(cost) ms")
            expect(frameAfter < Budget.rowMoveFrame, "the frame after moving a row of a 500-row table took \(frameAfter) ms")
        }
    },
    test("rowDragEvent: one event of a drag of a table's row over a board of 10,000 shapes, from one gap of another table to another, within 1 ms") {
        let viewport = CGSize(width: 1200, height: 800)
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        let board = rowsBoard(10_000)
        // Tables 10 and 50 of the grid, one above the other (12 rows each): a row of the first dragged over the second's gaps.
        let source = board[10].id, target = board[50].id
        let h = EditorHarness { CanvasEditor(registry: registry, document: CanvasDocument(shapes: board), scheduler: $0) }
        h.editor.viewportDidResize(to: viewport)
        h.editor.camera = camera(centering: CGRect(x: 3400, y: 0, width: 300, height: 700), at: 1, in: viewport)
        let columns = try require(h.editor.document[source]?.typed(as: DatabaseTable.self)?.props.columns)
        h.editor.selectedShapeIDs = [source]
        h.editor.selectItems([AnyHashable(columns[3].id)], of: source)
        let row = try require(h.editor.shapeContext.geometry(of: source)?.parts.frame(columns[3].id)?.rect)
        let frame = try require(h.editor.shapeContext.frame(of: h.editor.document[target]!))
        h.press(at: h.view(CGPoint(x: row.midX, y: row.midY)))
        h.drag(to: h.view(CGPoint(x: row.midX, y: row.midY + 8)))
        var costs: [Double] = []
        for run in 0..<measuredRuns(21) {
            // A gap of its own each event, so none is the one worked out last.
            let gap = CGFloat(2 + run % 7)
            let point = h.view(CGPoint(x: frame.midX, y: frame.minY + KitStyle.topInset + gap * KitStyle.rowHeight + 2))
            costs.append(threadCPUTime { h.drag(to: point, after: 0) }.milliseconds)
        }
        expectEqual(h.editor.hintedShapeID, target, "over the other table")
        h.escape()
        h.release()
        let sorted = costs.sorted(), best = sorted[0], middle = sorted[sorted.count / 2]
        report(String(format: "a drag event of a table's row over 10,000 shapes: %.3f ms best, %.3f median (budget %.0f)", best, middle, Budget.rowDragEvent))
        if holdsToBudgets { expect(middle < Budget.rowDragEvent, "a drag event took \(middle) ms") }
    },
    test("rowDragFrame: a frame while 400 rows of a 500-row table are dragged (the ghost, the rows faded where they are, the drop line) over a board of 4,000 shapes, within a frame") {
        let viewport = CGSize(width: 1200, height: 800)
        let context = try bitmapContext(viewport)
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        let columns = (0..<500).map { Column(name: "column_\($0)", type: TypeRef("text"), primaryKey: $0 == 0) }
        var big = ShapeRecord(DatabaseTable(frame: CGRect(x: -2000, y: -2000, width: 300, height: KitStyle.height(rows: columns.count)), columns: columns))
        big[TitleProperty.self] = "big"
        var other = ShapeRecord(DatabaseTable(frame: CGRect(x: -1500, y: -2000, width: 300, height: KitStyle.height(rows: 12)),
                                              columns: Array(columns.prefix(12))))
        other[TitleProperty.self] = "other"
        let h = EditorHarness { CanvasEditor(registry: registry, document: CanvasDocument(shapes: rowsBoard(4_000) + [AnyShapeRecord(big), AnyShapeRecord(other)]), scheduler: $0) }
        h.editor.viewportDidResize(to: viewport)
        h.editor.camera = camera(centering: CGRect(x: -2000, y: -1900, width: 900, height: 600), at: 1, in: viewport)
        h.editor.selectedShapeIDs = [big.id]
        h.editor.selectItems(columns[50..<450].map { AnyHashable($0.id) }, of: big.id)
        let row = try require(h.editor.shapeContext.geometry(of: big.id)?.parts.frame(columns[100].id)?.rect)
        let target = try require(h.editor.shapeContext.frame(of: h.editor.document[other.id]!))
        h.press(at: h.view(CGPoint(x: row.midX, y: row.midY)))
        h.drag(to: h.view(CGPoint(x: row.midX, y: row.midY + 8)))
        h.drag(to: h.view(CGPoint(x: target.midX, y: target.minY + KitStyle.topInset + 4 * KitStyle.rowHeight + 2)))
        expectEqual(h.editor.hintedShapeID, other.id, "over the other table")
        expectEqual(h.editor.session?.ghosts.count, 1, "the ghost")
        var best = Double.infinity
        for _ in 0..<measuredRuns(9) {
            h.editor.setNeedsDisplay()
            best = min(best, threadCPUTime { draw(h.editor, into: context, size: viewport) }.milliseconds)
        }
        h.escape()
        report(String(format: "a frame while 400 rows of a 500-row table are dragged over 4,000 shapes: %.1f ms (budget %.0f)", best, Budget.rowDragFrame))
        if holdsToBudgets { expect(best < Budget.rowDragFrame, "a frame mid-drag took \(best) ms") }
    },
])

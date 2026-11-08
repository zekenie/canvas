import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Engineering
import Foundation
import Geometry
import LanguageModels
import LineRows
import ShippedTesting
import StickyNotes
import TestKit
import Titles

// Rows (K11): a board where one shape in ten is a 12-row table and one in a hundred a 60-row table, the rest notes, drawn
// at 100% and 70% (each table's rows in view only, their text set once) and zoomed out at 30% and 10% (a bar a line in
// view, one fill a color, none where a row is under 2 points); and ⌃⌘↑ on 1,000 tables with nothing selected, then the
// frame after (each fold a provided layout input, laid out again only for the tables folded).

extension Budget {
    /// A frame of the rows board at 100% and at 70%. Never measured before rows were folded: the budget is a frame.
    static let rowsFrame = frame
    /// A frame of the rows board zoomed out, at 30% and 10%: what a frame zoomed out may cost.
    static let rowsSkeleton = zoomedOut
    /// ⌃⌘↑ on 1,000 tables with nothing selected, and the frame after. Never measured before folds: a release build did
    /// 21 to 29 ms on a busy machine on 2026-11-07, the fold itself 3, the rest the frame that lays the 1,000 out again,
    /// which costs 16 to 18 ms with no fold at all (the core's relayout of 1,000 tables, the floor); the budget two frames.
    static let foldMany = 2 * frame
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

@MainActor let rowBenchmarks = Suite("Row benchmarks", [
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
])

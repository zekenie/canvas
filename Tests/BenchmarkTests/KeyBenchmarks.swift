import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import Connections
import CoreGraphics
import Engineering
import Geometry
import LanguageModels
import ShippedTesting
import TestKit
import Titles

// Keys (K3): a pan's frame over 100 keys between four 40-row tables, all in view (each key's two row ends read from the
// tables' kept geometry, the tables' link marks from the key index); a pointer moving over a 200-row table (the row under it
// found by halving, its two dots drawn); and a table with 100 keys deleted on a board of 10,000 shapes (the one pass the core
// makes over the board's binding shapes, the keys counted for the step's name). Each over a generated board of `size` shapes
// placed away from the tables.

extension Budget {
    /// A pan's frame over 100 keys between four 40-row tables at 100%, the board's other shapes away: the thread's CPU time.
    /// Never measured before keys: a release build did 8.7 ms at 1,000 shapes and 9.1 at 10,000 on 2026-11-07; the budget is a
    /// frame.
    static let keyPan = 16.0
    /// A pointer move over a 200-row table, its row's dots found and drawn with the frame: the thread's CPU time. Never measured
    /// before row ports: 1.2 ms at both sizes, release, 2026-11-07; the budget some three times that.
    static let rowHover = 4.0
    /// A table with 100 keys deleted on a board of 10,000 shapes, the commit: the thread's CPU time. Never measured before
    /// tables took their keys: 1.3 ms at 1,000 shapes and 6.7 at 10,000 (the one pass over the board's arrows), release,
    /// 2026-11-07; the budget some three times that.
    static let keyedTableDelete = 20.0
}

/// `count` tables of `rows` rows each, laid in a row from `origin`, 360 apart, each titled `t<n>`, and `keys` keys between
/// neighbors' rows (row `k % rows` of table `k % count` to row 0 of the next), on foreign-key.
@MainActor private func keyedTables(count: Int, rows: Int, keys: Int, at origin: CGPoint) -> (tables: [AnyShapeRecord], arrows: [AnyShapeRecord]) {
    var tables: [ShapeRecord<DatabaseTable>] = []
    for index in 0..<count {
        let columns = (0..<rows).map { Column(name: "c\($0)", type: TypeRef("uuid"), primaryKey: $0 == 0) }
        var table = ShapeRecord(DatabaseTable(frame: CGRect(x: origin.x + CGFloat(index) * 360, y: origin.y + CGFloat(index % 2) * 120,
                                                            width: 260, height: KitStyle.height(rows: rows)), columns: columns))
        table[TitleProperty.self] = "t\(index)"
        tables.append(table)
    }
    var arrows: [AnyShapeRecord] = []
    for k in 0..<keys {
        let from = tables[k % count], to = tables[(k + 1) % count]
        let start = ArrowBinding(shapeID: from.id, normalizedAnchor: CGPoint(x: 1, y: 0.5), isPrecise: true, isExact: true,
                                 part: from.props.columns[(k / count + 1) % rows].id)
        let end = ArrowBinding(shapeID: to.id, normalizedAnchor: CGPoint(x: 1, y: 0.5), isPrecise: true, isExact: true, part: to.props.columns[0].id)
        var arrow = ShapeRecord(Arrow(start: .bound(start), end: .bound(end)))
        arrow[ChannelProperty.self] = ForeignKey.id
        arrows.append(AnyShapeRecord(arrow))
    }
    return (tables.map(AnyShapeRecord.init), arrows)
}

@MainActor let keyBenchmarks = Suite("Key benchmarks", [
    test("a pan's frame over 100 keys between four 40-row tables, and a pointer moving over a 200-row table, each within a frame") {
        let viewport = CGSize(width: 1600, height: 1000)
        let context = try require(CGContext(data: nil, width: Int(viewport.width), height: Int(viewport.height), bitsPerComponent: 8,
                                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: viewport.height)
        context.scaleBy(x: 1, y: -1)
        for size in sizes {
            let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
            let origin = CGPoint(x: 0, y: 60_000)
            let (tables, arrows) = keyedTables(count: 4, rows: 40, keys: 100, at: origin)
            let tall = keyedTables(count: 1, rows: 200, keys: 0, at: CGPoint(x: 0, y: 80_000)).tables
            let document = CanvasDocument(shapes: generatedBoard(shapes: size).shapes + tables + arrows + tall)
            let h = EditorHarness { CanvasEditor(registry: registry, document: document, scheduler: $0) }
            h.editor.turn(EngineeringKit.self, on: true)
            h.editor.viewportDidResize(to: viewport)
            // The keys in view, at 100%.
            let camera = Camera(origin: CGPoint(x: origin.x - 40, y: origin.y - 40), zoom: 1)
            h.editor.camera = camera
            draw(h.editor, into: context, size: viewport)
            var step = 0.0
            let pan = median(runs: 11, prepare: {
                step = step == 0 ? 1 : 0
                h.editor.camera = Camera(origin: CGPoint(x: camera.origin.x + step, y: camera.origin.y), zoom: 1)
            }, onThread: true) { draw(h.editor, into: context, size: viewport) }
            // The pointer over the tall table's rows, a row a move, with its frame.
            let table = try require(tall.first)
            h.editor.camera = Camera(origin: CGPoint(x: -40, y: 80_000 + 1_000), zoom: 1)
            var row = 0
            let hover = median(runs: 21, onThread: true) {
                row += 1
                h.move(to: h.view(CGPoint(x: 130, y: 80_000 + 1_000 + 20 + CGFloat(row % 30) * KitStyle.rowHeight)))
                draw(h.editor, into: context, size: viewport)
            }
            expect(h.editor.document[table.id] != nil)
            report(String(format: "%6d shapes, 100 keys between 4 tables of 40 rows: a pan's frame %5.2f ms (budget %.0f); a pointer over a 200-row table, with its frame, %5.2f ms (budget %.0f)",
                          size, pan, Budget.keyPan, hover, Budget.rowHover))
            if holdsToBudgets {
                expect(pan < Budget.keyPan, "a pan's frame over 100 keys took \(pan) ms over \(size) shapes")
                expect(hover < Budget.rowHover, "a pointer over a 200-row table took \(hover) ms over \(size) shapes")
            }
        }
    },
    test("a table with 100 keys deleted on a board of 10,000 shapes is one pass, its keys counted for the step") {
        for size in sizes {
            let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
            let (tables, arrows) = keyedTables(count: 2, rows: 40, keys: 100, at: CGPoint(x: 0, y: 60_000))
            let document = CanvasDocument(shapes: generatedBoard(shapes: size).shapes + tables + arrows)
            let h = EditorHarness { CanvasEditor(registry: registry, document: document, scheduler: $0) }
            let table = try require(tables.first).id
            let delete = median(runs: 5, prepare: {
                if h.editor.document[table] == nil { h.editor.undo() }
            }, onThread: true) {
                h.editor.transact("Delete") { tx in
                    tx.delete([table])
                    tx.stepName = "Delete Table and \(tx.deletedAlong.first?.count ?? 0) Arrows"
                }
            }
            expectEqual(h.editor.undoHistory.undoName, "Delete Table and 100 Arrows")
            report(String(format: "%6d shapes, a table with 100 keys deleted: %5.2f ms (budget %.0f)", size, delete, Budget.keyedTableDelete))
            if holdsToBudgets { expect(delete < Budget.keyedTableDelete, "deleting a table with 100 keys over \(size) shapes took \(delete) ms") }
        }
    },
])

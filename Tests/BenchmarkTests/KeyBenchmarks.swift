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
    /// A pan's frame over 450 keys at 100% between four 40-row tables in view, each a level curve with its marks (K4), and the
    /// columns' link marks the key index gives the tables: the thread's CPU time. Never measured before level keys: a release
    /// build did 19 ms on a quiet machine and 41 to 43 under a load of 19 (2026-11-07), of which the curves' rasterizing is
    /// about 4 and the marks and link marks about 12 over level arrows with none; the budget some two and a half times the
    /// quiet figure.
    static let levelArrowsFrame = 50.0
    /// How much more the same frame over 450 level arrows (no channel: no marks) may cost than over 450 plain arrows between
    /// the same points of the same tables (which each render works out again, where a level arrow draws what it keeps). Never
    /// measured before: 31 ms against 26 to 27, release, under load; Core Graphics rasterizes a short cubic about half again as
    /// slowly as a line (a probe of 450 strokes: 14 to 16 ms against 9 to 10), so the plan's "no worse" was held at 1.3 (13.3 ms
    /// against 10.9 on 2026-11-08). By 2026-11-09 the level frame was 19.4 to 21.2 against 10.8 to 11.6 (release, load 3 to 9),
    /// all of it Core Graphics stroking the kept paths: the bundles give a level arrow among others at its rows a path of its own
    /// (K17's fans, U12's partings), which these arrows, several from each row, take. The plain arrows' 66 ms hid it from K17 on
    /// (bound to the tables as wholes, bowed into arcs as one path: they are free now), so the budget moved from 1.3 to 2.
    static let levelArrowsSlack = 2.0
    /// A table with 150 keys (of 450 between four tables, nearly every column nullable: a bar and a circle, the line cut inside
    /// it) moved a unit and drawn: the commit that lays the 150 out again and the next frame, the thread's CPU time. Never
    /// measured before: 36 to 40 ms release on 2026-11-07 (46 to 50 under a load of 19), against 20 to 22 for plain arrows and 27
    /// for level ones with no marks; of it the geometries worked out again were 2.5 ms (below), the rest the frame's rasterizing
    /// of the marks and link marks, as the pan's frame is. The budget half as much again as the quiet figure. With the fix
    /// landings' layout, 33 to 37.8 on 2026-11-09 (release, load 3 to 9), of which the geometries are 8.5 to 11.7, against 28.2
    /// for level arrows; the plain arrows, free since, stay where they are as the table moves, so theirs is the frame alone.
    static let keyedTableMove = 60.0
    /// The same move and the 450 arrows' geometries worked out again, without the frame: the keys' look asked, their marks and
    /// cut body made. Never measured before: 2.5 ms for keys (1.9 level arrows, 1.3 plain) at both sizes, release, 2026-11-07.
    /// The fix landings' keys cost more to lay out: a level stub at each marked end (U9), partings and a run's turn columns
    /// (U12), a run's marks said once and stood clear of each other (U13): 8.5 to 11.7 ms on 2026-11-09 (release, load 1 to 9),
    /// some 70 µs a key, inside a move and its frame of 33 to 37.8 (`keyedTableMove`, which holds the two at 60); the budget
    /// moved from 10 to 15.
    static let keyedTableRelay = 15.0
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

/// What the arrows between the tables are: plain arrows from the rows' sides to the rows' sides, free at both ends (tldraw's,
/// straight, worked out again by each render; bound to the tables as wholes, as they were, the bundles read the 150 between two
/// tables as one path since K17 and bowed them apart by 150 slots into arcs thousands of units across, no baseline, so a moved
/// table leaves them where they are); the same bound to the rows, on no channel (level curves, kept); or keys, on foreign-key
/// (level curves with their marks, and the columns' link marks the key index gives the tables).
private enum Arrows450: CaseIterable { case plain, level, keys }

/// Four 40-row tables in a row from `origin`, 360 apart (100 between them), and 450 arrows between neighbors' rows, from row
/// `k / 3 % 40` of table `k % 3` to row `k / 7 % 40` of the next, as `kind` says. The arrows' ids besides.
@MainActor private func arrowsBetween(_ kind: Arrows450, at origin: CGPoint, nullable: Bool = false) -> (shapes: [AnyShapeRecord], arrows: [ShapeID]) {
    let rows = 40
    var tables: [ShapeRecord<DatabaseTable>] = []
    for index in 0..<4 {
        let columns = (0..<rows).map { Column(name: "c\($0)", type: TypeRef("uuid"), nullable: nullable && $0 != 0, primaryKey: $0 == 0) }
        var table = ShapeRecord(DatabaseTable(frame: CGRect(x: origin.x + CGFloat(index) * 360, y: origin.y, width: 260, height: KitStyle.height(rows: rows)),
                                              columns: columns))
        table[TitleProperty.self] = "g\(index)"
        tables.append(table)
    }
    func end(_ table: ShapeRecord<DatabaseTable>, row: Int, side: CGFloat) -> ArrowTerminal {
        let frame = table.props.frame, rect = KitStyle.rowRect(row, in: frame)
        guard kind != .plain else { return .free(CGPoint(x: frame.minX + side * frame.width, y: rect.midY)) }
        let anchor = CGPoint(x: side, y: (rect.midY - frame.minY) / frame.height)
        return .bound(ArrowBinding(shapeID: table.id, normalizedAnchor: anchor, isPrecise: true, isExact: true, part: table.props.columns[row].id))
    }
    var arrows: [AnyShapeRecord] = []
    for k in 0..<450 {
        let from = tables[k % 3], to = tables[k % 3 + 1]
        var arrow = ShapeRecord(Arrow(start: end(from, row: (k / 3) % rows, side: 1), end: end(to, row: (k / 7) % rows, side: 0)))
        if kind == .keys { arrow[ChannelProperty.self] = ForeignKey.id }
        arrows.append(AnyShapeRecord(arrow))
    }
    return (tables.map(AnyShapeRecord.init) + arrows, arrows.map(\.id))
}

@MainActor let keyBenchmarks = Suite("Key benchmarks", [
    test("a pan's frame over 450 level arrows no worse than over 450 plain bound arrows, and over 450 keys with their marks within a frame") {
        let viewport = CGSize(width: 1600, height: 1000)
        let context = try require(CGContext(data: nil, width: Int(viewport.width), height: Int(viewport.height), bitsPerComponent: 8,
                                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: viewport.height)
        context.scaleBy(x: 1, y: -1)
        for size in sizes {
            var frames: [Arrows450: Double] = [:]
            for kind in Arrows450.allCases {
                let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
                let origin = CGPoint(x: 0, y: 60_000)
                let between = arrowsBetween(kind, at: origin)
                let document = CanvasDocument(shapes: generatedBoard(shapes: size).shapes + between.shapes)
                let h = EditorHarness { CanvasEditor(registry: registry, document: document, scheduler: $0) }
                h.editor.turn(EngineeringKit.self, on: true)
                h.editor.viewportDidResize(to: viewport)
                let camera = Camera(origin: CGPoint(x: origin.x - 40, y: origin.y - 40), zoom: 1)
                h.editor.camera = camera
                draw(h.editor, into: context, size: viewport)
                expectEqual(h.editor.paintOrder(in: camera.toWorld(CGRect(origin: .zero, size: viewport))).filter { $0.kind == Arrow.kind }.count, 450,
                            "every arrow in view")
                let any = try require(between.arrows.first)
                expectEqual(try require(h.editor.arrowGeometry(of: any)).isLevel, kind != .plain)
                expectEqual(h.editor.arrowLook(of: any) != nil, kind == .keys)
                var step = 0.0
                frames[kind] = median(runs: 11, prepare: {
                    step = step == 0 ? 1 : 0
                    h.editor.camera = Camera(origin: CGPoint(x: camera.origin.x + step, y: camera.origin.y), zoom: 1)
                }, onThread: true) { draw(h.editor, into: context, size: viewport) }
            }
            let plain = frames[.plain] ?? 0, level = frames[.level] ?? 0, keys = frames[.keys] ?? 0
            report(String(format: "%6d shapes, 450 arrows between four 40-row tables in view, a pan's frame: %5.2f ms plain, %5.2f ms level (at most %.2f times plain), %5.2f ms keys with their marks (budget %.0f)",
                          size, plain, level, Budget.levelArrowsSlack, keys, Budget.levelArrowsFrame))
            if holdsToBudgets {
                expect(level <= plain * Budget.levelArrowsSlack, "450 level arrows (\(level) ms) cost more than 450 plain arrows (\(plain) ms) over \(size) shapes")
                expect(keys < Budget.levelArrowsFrame, "a pan's frame over 450 keys took \(keys) ms over \(size) shapes")
            }
        }
    },
    test("a table with 150 keys moved a unit and drawn: the keys laid out again, within a frame, against plain arrows") {
        let viewport = CGSize(width: 1600, height: 1000)
        let context = try require(CGContext(data: nil, width: Int(viewport.width), height: Int(viewport.height), bitsPerComponent: 8,
                                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: viewport.height)
        context.scaleBy(x: 1, y: -1)
        for size in sizes {
            var costs: [Arrows450: Double] = [:], lays: [Arrows450: Double] = [:]
            for kind in Arrows450.allCases {
                let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
                let origin = CGPoint(x: 0, y: 60_000)
                let between = arrowsBetween(kind, at: origin, nullable: true)
                let document = CanvasDocument(shapes: generatedBoard(shapes: size).shapes + between.shapes)
                let h = EditorHarness { CanvasEditor(registry: registry, document: document, scheduler: $0) }
                h.editor.turn(EngineeringKit.self, on: true)
                h.editor.viewportDidResize(to: viewport)
                h.editor.camera = Camera(origin: CGPoint(x: origin.x - 40, y: origin.y - 40), zoom: 1)
                draw(h.editor, into: context, size: viewport)
                let table = try require(between.shapes.first).id
                var step: CGFloat = 0
                costs[kind] = median(runs: 11, prepare: { step = step == 0 ? 1 : 0 }, onThread: true) {
                    h.editor.transact("Move") { tx in tx.update(table, as: DatabaseTable.self) { $0.props.frame.origin.x = origin.x + step } }
                    draw(h.editor, into: context, size: viewport)
                }
                // The move alone, with the geometry of every arrow worked out again (what a frame would otherwise find stale).
                lays[kind] = median(runs: 11, prepare: { step = step == 0 ? 1 : 0 }, onThread: true) {
                    h.editor.transact("Move") { tx in tx.update(table, as: DatabaseTable.self) { $0.props.frame.origin.x = origin.x + step } }
                    for id in between.arrows { _ = h.editor.shapeContext.geometry(of: id) }
                }
            }
            let plain = costs[.plain] ?? 0, level = costs[.level] ?? 0, keys = costs[.keys] ?? 0
            report(String(format: "%6d shapes, a table with 150 of 450 arrows moved a unit and drawn: %5.2f ms plain, %5.2f ms level, %5.2f ms keys (budget %.0f); the move and the 450 geometries worked out: %5.2f, %5.2f, %5.2f ms (budget %.0f)",
                          size, plain, level, keys, Budget.keyedTableMove, lays[.plain] ?? 0, lays[.level] ?? 0, lays[.keys] ?? 0, Budget.keyedTableRelay))
            if holdsToBudgets {
                expect(keys < Budget.keyedTableMove, "moving a table with 150 keys took \(keys) ms over \(size) shapes")
                expect((lays[.keys] ?? 0) < Budget.keyedTableRelay, "laying out a table's 150 keys again took \(lays[.keys] ?? 0) ms over \(size) shapes")
            }
        }
    },
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

import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Geometry
import TestKit

// The shapes in a rect and under a point are found in the cells that cover them (`SpatialGrid`, kept with the paint
// list), and must be exactly the shapes going through every shape's extent finds, whatever has happened to the board
// since the grid was made: shapes moved, resized, added, deleted and restacked, undone, the camera moved. The
// editor's own search through every extent (`scansEveryShape`) is the control, and an editor made afresh from the
// same shapes the control for what is kept: the paint order, the extents.

/// A generator that gives the same numbers for a seed.
private struct Seeded: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension Seeded {
    mutating func number(_ range: ClosedRange<CGFloat>) -> CGFloat { CGFloat.random(in: range, using: &self) }
    mutating func index(below count: Int) -> Int { Int.random(in: 0..<count, using: &self) }
    mutating func chance(_ odds: Double) -> Bool { Double.random(in: 0..<1, using: &self) < odds }
}

/// Fixtures' boxes, discs, tags (above a shape, with no outline), links, and the index tests' markers (on a shape's corner),
/// wires (hit within 2 world units and 5 view points of their line) and badges (20 view points, whatever the zoom).
@MainActor private func spatialHarness(document: CanvasDocument = CanvasDocument()) throws -> EditorHarness {
    try EditorHarness(plugins: [FixturesPlugin(), LinksPlugin(), IndexKinds(log: IndexLog())], document: document)
}

/// The ids a search finds, in order: the grid's, then through every extent.
@MainActor private func searched(_ editor: CanvasEditor, in rect: CGRect) -> (cells: [ShapeID], every: [ShapeID]) {
    let cells = editor.paintOrder(in: rect).map(\.id)
    editor.scansEveryShape = true
    defer { editor.scansEveryShape = false }
    return (cells, editor.paintOrder(in: rect).map(\.id))
}

@MainActor private func hit(_ editor: CanvasEditor, at point: CGPoint, where include: (AnyShapeRecord) -> Bool = { _ in true }) -> (cells: ShapeID?, every: ShapeID?) {
    let cells = editor.shape(at: point, where: include)
    editor.scansEveryShape = true
    defer { editor.scansEveryShape = false }
    return (cells, editor.shape(at: point, where: include))
}

/// What the searches find, asked of random rects and points over `area`, and of an editor made afresh from the same
/// shapes, as the editor has them: the same shapes in the same order, in every rect, and under every point.
@MainActor private func expectSearchesAgree(_ h: EditorHarness, area: CGRect, random: inout Seeded, rects: Int = 24, points: Int = 24, _ message: String) {
    let editor = h.editor
    var wrong: [String] = []
    func anywhere(in area: CGRect, _ random: inout Seeded) -> CGPoint {
        CGPoint(x: random.number(area.minX...area.maxX), y: random.number(area.minY...area.maxY))
    }
    let fresh = CanvasEditor(registry: editor.registry, document: editor.document, scheduler: ManualScheduler())
    fresh.camera = editor.camera
    fresh.scansEveryShape = true
    if editor.paintOrder().map(\.id) != fresh.paintOrder().map(\.id) { wrong.append("the paint order is not the one built afresh") }
    for _ in 0..<rects {
        let origin = anywhere(in: area, &random)
        // Small to as big as the area, and a few with a negative size.
        let scale: CGFloat = [4, 40, 400, 4_000, 40_000].randomElement(using: &random)!
        var rect = CGRect(x: origin.x, y: origin.y, width: random.number(0...scale), height: random.number(0...scale))
        if random.chance(0.1) { rect = CGRect(x: rect.maxX, y: rect.maxY, width: -rect.width, height: -rect.height) }
        let found = searched(editor, in: rect)
        if found.cells != found.every { wrong.append("\(rect): \(found.cells.count) found in the cells, \(found.every.count) in every extent") }
        if found.every != fresh.paintOrder(in: rect).map(\.id) { wrong.append("\(rect): not what a board made afresh finds") }
    }
    for _ in 0..<points {
        let point = anywhere(in: area, &random)
        let found = hit(editor, at: point)
        if found.cells != found.every { wrong.append("\(point): \(String(describing: found.cells)) in the cells, \(String(describing: found.every)) in every extent") }
        if found.every != fresh.shape(at: point) { wrong.append("\(point): not what a board made afresh finds") }
        let odd = hit(editor, at: point) { record in record.kind != Box.kind }
        if odd.cells != odd.every { wrong.append("\(point), but a box: \(String(describing: odd.cells)) against \(String(describing: odd.every))") }
    }
    expect(wrong.isEmpty, "\(message): \(wrong.prefix(4).joined(separator: "; "))")
}

/// A random board's shapes of every kind, `count` of them, on a square of `side` world units, in clusters and
/// alone, small and large; some are very large (wider than a shape is filed in cells), and tags have no outline.
@MainActor private func addShapes(_ count: Int, to h: EditorHarness, side: CGFloat, random: inout Seeded, existing: [ShapeID] = []) -> [ShapeID] {
    var ids = existing
    var boxes = existing
    for _ in 0..<count {
        let corner = CGPoint(x: random.number(0...side), y: random.number(0...side))
        let size = CGSize(width: random.number(8...300), height: random.number(8...200))
        let frame = CGRect(origin: corner, size: size)
        switch random.index(below: 20) {
        case 0..<8:
            let id = h.add(Box(frame))
            ids.append(id)
            boxes.append(id)
        case 8..<11:
            let id = h.add(Disc(frame))
            ids.append(id)
            boxes.append(id)
        case 11:
            // Wider than any cell: filed with the shapes every search looks at.
            ids.append(h.add(Box(CGRect(x: corner.x - 3_000, y: corner.y, width: random.number(6_000...20_000), height: random.number(10...60)))))
        case 12:
            ids.append(h.add(Wire(from: corner, to: CGPoint(x: corner.x + random.number(-400...400), y: corner.y + random.number(-400...400)))))
        case 13 where !boxes.isEmpty:
            ids.append(h.add(Tag(target: boxes[random.index(below: boxes.count)])))
        case 14 where boxes.count >= 2:
            ids.append(h.add(Link(from: boxes[random.index(below: boxes.count)], to: boxes[random.index(below: boxes.count)])))
        case 15 where !boxes.isEmpty:
            ids.append(h.add(Marker(host: boxes[random.index(below: boxes.count)])))
        case 16:
            ids.append(h.add(Badge()))
        case 17:
            // Nowhere, a size of nothing.
            ids.append(h.add(Box(CGRect(origin: corner, size: .zero))))
        default:
            let id = h.add(Box(frame))
            ids.append(id)
            boxes.append(id)
        }
    }
    return ids
}

/// One change to a random board, in a step of its own.
@MainActor private func changeBoard(_ h: EditorHarness, ids: inout [ShapeID], side: CGFloat, random: inout Seeded) -> String {
    let editor = h.editor
    let live = ids.filter { editor.document[$0] != nil }
    ids = live
    guard !live.isEmpty else { return "nothing" }
    func some(_ most: Int) -> [ShapeID] { (0..<(1 + random.index(below: most))).map { _ in live[random.index(below: live.count)] } }
    switch random.index(below: 14) {
    case 0, 1:
        let moved = Set(some(6)), by = CGPoint(x: random.number(-30...30), y: random.number(-30...30))
        editor.transact("Move a few") { $0.translate(moved, by: by) }
        return "moved \(moved.count) by \(by)"
    case 2:
        let moved = Set(some(4)), by = CGPoint(x: random.number(-9_000...9_000), y: random.number(-9_000...9_000))
        editor.transact("Move far") { $0.translate(moved, by: by) }
        return "moved \(moved.count) far, by \(by)"
    case 3:
        let id = some(1)[0], size = CGSize(width: random.number(1...900), height: random.number(1...700))
        editor.transact("Resize") { transaction in
            transaction.update(id) { record in
                if let box = record.box { record.box = CGRect(origin: box.origin, size: size) }
            }
        }
        return "resized \(id)"
    case 4:
        // Many at once: more than the grid files again one by one.
        let moved = Set(live.filter { _ in random.chance(0.4) }), by = CGPoint(x: random.number(-500...500), y: random.number(-500...500))
        editor.transact("Move many") { $0.translate(moved, by: by) }
        return "moved \(moved.count) of \(live.count) by \(by)"
    case 5, 6:
        let before = ids.count
        ids = addShapes(1 + random.index(below: 4), to: h, side: side, random: &random, existing: live)
        return "added \(ids.count - before)"
    case 7:
        let gone = Set(some(3))
        editor.transact("Delete") { $0.delete(gone) }
        return "deleted \(gone.count)"
    case 8:
        let id = some(1)[0]
        editor.transact("Front") { $0.bringToFront(id) }
        return "brought \(id) to the front"
    case 9:
        let id = some(1)[0]
        editor.transact("Back") { $0.sendToBack(id) }
        return "sent \(id) to the back"
    case 10 where live.count >= 2:
        let a = some(1)[0], b = some(1)[0]
        guard a != b else { return "nothing" }
        editor.transact("Above") { $0.move(a, above: b) }
        return "moved \(a) above \(b)"
    case 11:
        if editor.canUndo {
            editor.undo()
            return "undid"
        }
        if editor.canRedo {
            editor.redo()
            return "redid"
        }
        return "nothing"
    case 12:
        if editor.canRedo {
            editor.redo()
            return "redid"
        }
        return "nothing"
    default:
        let zoom = [0.05, 0.1, 0.35, 1, 2, 8].randomElement(using: &random)!
        editor.camera = Camera(origin: CGPoint(x: random.number(0...side), y: random.number(0...side)), zoom: CGFloat(zoom))
        return "zoomed to \(zoom)"
    }
}

@MainActor let spatialIndexTests = Suite("Spatial index", [
    test("the shapes in a rect and under a point are the ones going through every shape finds, through a seeded run of changes to a board") {
        for seed in 1...8 as ClosedRange<UInt64> {
            var random = Seeded(seed: seed)
            let h = try spatialHarness()
            let side: CGFloat = [3_000, 12_000][Int(seed) % 2]
            // Boards of 120, 260 and 500 shapes (a grid is made from 64).
            var ids = addShapes([120, 260, 500][Int(seed) % 3], to: h, side: side, random: &random)
            let area = CGRect(x: -500, y: -500, width: side + 1_500, height: side + 1_500)
            expectSearchesAgree(h, area: area, random: &random, "seed \(seed), as made")
            for step in 0..<70 {
                let what = changeBoard(h, ids: &ids, side: side, random: &random)
                expectSearchesAgree(h, area: area, random: &random, rects: 8, points: 8, "seed \(seed), step \(step), after it \(what)")
            }
            expectSearchesAgree(h, area: area, random: &random, "seed \(seed), at the end")
        }
    },
    test("an extent touching a rect by an edge or a corner is found, one beside it is not, whatever the rect's size or sign") {
        // Boxes 100 across on a grid of 120, so the gaps are 20 and every edge is a whole number.
        let h = try spatialHarness()
        var ids: [ShapeID] = []
        for row in 0..<16 {
            for column in 0..<16 { ids.append(h.add(Box(CGRect(x: column * 120, y: row * 120, width: 100, height: 100)))) }
        }
        var random = Seeded(seed: 99)
        var wrong: [String] = []
        for _ in 0..<200 {
            let x = CGFloat(random.index(below: 17) * 60), y = CGFloat(random.index(below: 17) * 60)
            let rect = [CGRect(x: x, y: y, width: 0, height: 0), CGRect(x: x, y: y, width: 20, height: 20), CGRect(x: x + 20, y: y + 20, width: -20, height: -20),
                        CGRect(x: x, y: y, width: 100, height: 0), CGRect(x: x - 1, y: y, width: 1, height: 1)][random.index(below: 5)]
            let found = searched(h.editor, in: rect)
            if found.cells != found.every { wrong.append("\(rect)") }
        }
        expect(wrong.isEmpty, "rects whose edges are the boxes': \(wrong.prefix(5))")
        expectEqual(h.editor.paintOrder(in: CGRect(x: 100, y: 0, width: 0, height: 0)).count, 1, "a point on a box's edge: that box")
        expectEqual(h.editor.paintOrder(in: CGRect(x: 120, y: 0, width: 0, height: 0)).count, 1, "and on the next box's")
        expectEqual(h.editor.paintOrder(in: CGRect(x: 110, y: 0, width: 0, height: 0)).count, 0, "in the gap: none")
        expectEqual(h.editor.paintOrder(in: CGRect(x: 100, y: 100, width: 20, height: 20)).count, 4, "a corner of four boxes")
        _ = ids
    },
    test("a rect with no bounds, a rect far off the board and an empty one find what going through every extent finds") {
        var random = Seeded(seed: 5)
        let h = try spatialHarness()
        _ = addShapes(150, to: h, side: 4_000, random: &random)
        let rects: [CGRect] = [.infinite, .null, .zero, CGRect(x: -1e12, y: -1e12, width: 2e12, height: 2e12), CGRect(x: 1e15, y: 0, width: 10, height: 10),
                               CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 10), CGRect(x: -CGFloat.infinity, y: -CGFloat.infinity, width: CGFloat.infinity, height: CGFloat.infinity),
                               CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10), CGRect(x: 0, y: 0, width: 4_000, height: 4_000),
                               CGRect(x: 2_000, y: 2_000, width: 1e-9, height: 1e-9)]
        for rect in rects {
            let found = searched(h.editor, in: rect)
            expectEqual(found.cells, found.every, "\(rect)")
        }
        for point in [CGPoint(x: 1e12, y: 0), CGPoint(x: CGFloat.nan, y: 0), CGPoint(x: CGFloat.infinity, y: 5), CGPoint(x: -3, y: -3)] {
            let found = hit(h.editor, at: point)
            expectEqual(found.cells, found.every, "\(point)")
        }
    },
    test("a shape kept aside has no extent: found nowhere, as the controlling search finds it") {
        func uuid(_ n: Int) -> String { String(format: "00000000-0000-0000-0000-%012d", n) }
        var shapes = (0..<120).map { i in
            """
            { "id" : "\(uuid(i))", "index" : "a\(String(format: "%03d", i))", "kind" : "box", "props" : { "frame" : [[\(i % 12 * 90), \(i / 12 * 90)], [80, 80]] } }
            """
        }
        shapes.insert("""
        { "id" : "\(uuid(900))", "index" : "a0005", "kind" : "gadget", "props" : { "frame" : [[0, 0], [300, 300]] } }
        """, at: 5)
        let json = """
        { "format" : 1, "schema" : { "box" : 0 }, "shapes" : [ \(shapes.joined(separator: ",")) ] }
        """
        let registry = try Registry(plugins: [FixturesPlugin()])
        let document = try BoardCodec(registry: registry).decode(Data(json.utf8)).document
        expectEqual(document.shapes.filter(\.isOpaque).count, 1, "the gadget is kept aside")
        let editor = CanvasEditor(registry: registry, document: document, scheduler: ManualScheduler())
        for rect in [CGRect(x: 0, y: 0, width: 400, height: 400), CGRect(x: 100, y: 100, width: 10, height: 10), CGRect(x: -1_000, y: -1_000, width: 5_000, height: 5_000)] {
            let found = searched(editor, in: rect)
            expectEqual(found.cells, found.every, "\(rect)")
            expect(!found.cells.contains { $0.rawValue == UUID(uuidString: uuid(900)) }, "the gadget is in no rect")
        }
    },
    test("a shape is hit within its hit margin of its extent, at any zoom: the margin's view points grow as the zoom falls") {
        let h = try spatialHarness()
        var random = Seeded(seed: 12)
        // A field of wires, a long way apart, and boxes between; the wires are hit 2 world units and 5 view points from their line.
        for i in 0..<150 {
            h.add(Wire(from: CGPoint(x: CGFloat(i % 15) * 400, y: CGFloat(i / 15) * 400), to: CGPoint(x: CGFloat(i % 15) * 400 + 300, y: CGFloat(i / 15) * 400)))
            h.add(Box(CGRect(x: CGFloat(i % 15) * 400, y: CGFloat(i / 15) * 400 + 100, width: 120, height: 80)))
        }
        for zoom: CGFloat in [4, 1, 0.25, 0.05] {
            h.editor.camera = Camera(origin: .zero, zoom: zoom)
            var wrong: [String] = []
            for _ in 0..<150 {
                // Near a wire's line, at and past the edge of where it is hit.
                let i = random.index(below: 150)
                let line = CGPoint(x: CGFloat(i % 15) * 400 + random.number(-10...310), y: CGFloat(i / 15) * 400)
                let reach = 2 + 5 / zoom
                let point = CGPoint(x: line.x, y: line.y + [reach - 0.01, reach + 0.01, reach + 1, -reach, 0].randomElement(using: &random)!)
                let found = hit(h.editor, at: point)
                if found.cells != found.every { wrong.append("\(point) at \(zoom): \(String(describing: found.cells)) against \(String(describing: found.every))") }
            }
            expect(wrong.isEmpty, "at \(zoom): \(wrong.prefix(3))")
        }
        // The margin reaches a shape a cell away.
        h.editor.camera = Camera(origin: .zero, zoom: 0.05)
        let far = h.add(Wire(from: CGPoint(x: 10_000, y: 10_000), to: CGPoint(x: 10_300, y: 10_000)))
        expectEqual(h.editor.shape(at: CGPoint(x: 10_100, y: 10_000 + 2 + 5 / 0.05 - 1)), far, "within 5 view points at 5%: 100 world units")
        expectEqual(h.editor.shape(at: CGPoint(x: 10_100, y: 10_000 + 2 + 6 / 0.05 + 1)), nil, "and past them")
    },
    test("a commit that adds shapes on top of the stack is put at the end of the paint list, as building it afresh would put it, and the grid follows") {
        #if DEBUG
        let h = try spatialHarness()
        var random = Seeded(seed: 31)
        var boxes: [ShapeID] = []
        for i in 0..<200 { boxes.append(h.add(Box(CGRect(x: CGFloat(i % 20) * 150, y: CGFloat(i / 20) * 150, width: 100, height: 80)))) }
        let area = CGRect(x: -100, y: -100, width: 3_300, height: 1_800)
        expectSearchesAgree(h, area: area, random: &random, "as made")
        let built = h.editor.paintListsBuilt, grids = h.editor.spatialGridsMade
        expectEqual(grids, 1, "one grid, made by the searches")

        // Plain shapes.
        for i in 0..<5 { boxes.append(h.add(Box(CGRect(x: 40 + CGFloat(i) * 7, y: 40, width: 60, height: 60)))) }
        expectSearchesAgree(h, area: area, random: &random, "after five boxes")
        expectEqual(h.editor.paintListsBuilt, built, "no paint list built again")
        expectEqual(h.editor.spatialGridsMade, grids, "nor a grid")
        expectEqual(h.editor.paintOrder().last?.id, boxes.last, "the last box is on top")

        // Several at once, one commit.
        h.editor.transact("Several") { transaction in
            for i in 0..<3 { transaction.insert(ShapeRecord(Box(CGRect(x: 300 + CGFloat(i) * 11, y: 300, width: 50, height: 50)))) }
            transaction.insert(ShapeRecord(Disc(CGRect(x: 900, y: 900, width: 90, height: 90))))
        }
        expectSearchesAgree(h, area: area, random: &random, "after four in a commit")
        expectEqual(h.editor.paintListsBuilt, built, "still none")

        // An anchored shape above the last plain one goes last, and the next plain one after it.
        let last = h.editor.paintOrder().last!.id
        let tag = h.add(Tag(target: last))
        expectEqual(h.editor.paintOrder().map(\.id).suffix(2), [last, tag], "above the last plain shape")
        expectEqual(h.editor.paintListsBuilt, built, "no list built for a tag above the last plain shape")
        let after = h.add(Box(CGRect(x: 10, y: 600, width: 30, height: 30)))
        expectEqual(h.editor.paintOrder().map(\.id).suffix(3), [last, tag, after])
        expectEqual(h.editor.paintListsBuilt, built, "nor for a plain shape after it")
        expectSearchesAgree(h, area: area, random: &random, "after a tag")

        // A tag above another shape goes in the middle: the list is built again, on the next ask.
        _ = h.editor.paintOrder()
        h.add(Tag(target: boxes[3]))
        expectEqual(h.editor.paintOrder().count, h.editor.document.shapes.count)
        expectEqual(h.editor.paintListsBuilt, built + 1, "built again for a tag above the middle of the stack")
        expectSearchesAgree(h, area: area, random: &random, "after a tag in the middle")
        let rebuilt = h.editor.paintListsBuilt, remade = h.editor.spatialGridsMade
        expectEqual(remade, grids + 1, "the grid went with the list")

        // A tag with nothing to be above goes on top, and a plain shape goes under it: built again.
        h.add(Tag(target: nil))
        _ = h.editor.paintOrder()
        expectEqual(h.editor.paintListsBuilt, rebuilt + 1, "a tag on top: the list is built")
        h.add(Box(CGRect(x: 5, y: 5, width: 10, height: 10)))
        expectSearchesAgree(h, area: area, random: &random, "a box under a tag on top")
        expectEqual(h.editor.paintListsBuilt, rebuilt + 2, "a plain shape under the shapes on top: built again")
        #endif
    },
    test("shapes that came in elsewhere in the stack, went, moved in it, or came back by an undo, a redo or a move from another board, build the paint list again") {
        #if DEBUG
        let h = try spatialHarness()
        var random = Seeded(seed: 41)
        var boxes: [ShapeID] = []
        for i in 0..<120 { boxes.append(h.add(Box(CGRect(x: CGFloat(i % 12) * 150, y: CGFloat(i / 12) * 150, width: 100, height: 80)))) }
        let area = CGRect(x: -100, y: -100, width: 1_900, height: 1_600)
        expectSearchesAgree(h, area: area, random: &random, "as made")
        var built = h.editor.paintListsBuilt
        @MainActor func expectBuilt(_ message: String) {
            expectSearchesAgree(h, area: area, random: &random, message)
            built += 1
            expectEqual(h.editor.paintListsBuilt, built, message)
        }
        h.editor.transact("Delete") { $0.delete([boxes[7]]) }
        expectBuilt("a deletion")
        h.editor.undo()
        expectBuilt("its undo")
        h.editor.redo()
        expectBuilt("its redo")
        h.editor.transact("Front") { $0.bringToFront(boxes[3]) }
        expectBuilt("a box to the front")
        h.editor.transact("Back") { $0.sendToBack(boxes[4]) }
        expectBuilt("a box to the back")
        // An addition and a restack in one commit: the order of those that stayed is not the one the list has.
        h.editor.transact("Both") { transaction in
            transaction.insert(ShapeRecord(Box(CGRect(x: 1, y: 1, width: 20, height: 20))))
            transaction.sendToBack(boxes[9])
        }
        expectBuilt("an addition and a restack together")
        // An addition and a deletion in one commit.
        h.editor.transact("Both") { transaction in
            transaction.insert(ShapeRecord(Box(CGRect(x: 2, y: 2, width: 20, height: 20))))
            transaction.delete([boxes[10]])
        }
        expectBuilt("an addition and a deletion together")
        h.editor.undo()
        expectBuilt("their undo, which brings a shape back")
        // The addition alone then undone and done again.
        h.add(Box(CGRect(x: 3, y: 3, width: 20, height: 20)))
        expectSearchesAgree(h, area: area, random: &random, "an addition")
        expectEqual(h.editor.paintListsBuilt, built, "an addition builds none")
        h.editor.undo()
        expectBuilt("its undo")
        h.editor.redo()
        expectBuilt("and its redo, which is no new shape")
        #endif
    },
    test("an arrow-like shape bound to a shape that comes after it, or to one that is not there, is painted above that shape as it comes, as building the list afresh does") {
        // A tag whose target isn't there is painted on top; when the target comes (an undo, or a shape from elsewhere), it is above it.
        let h = try spatialHarness()
        var random = Seeded(seed: 77)
        for i in 0..<100 { h.add(Box(CGRect(x: CGFloat(i % 10) * 150, y: CGFloat(i / 10) * 150, width: 100, height: 80))) }
        let missing = ShapeID()
        let tag = h.add(Tag(target: missing))
        h.add(Box(CGRect(x: 0, y: 2_000, width: 10, height: 10)))
        expectEqual(h.editor.paintOrder().last?.id, tag, "on top, its target missing")
        h.add(Box(CGRect(x: 0, y: 2_100, width: 10, height: 10)), id: missing)
        let order = h.editor.paintOrder().map(\.id)
        expectEqual(order.suffix(2), [missing, tag], "above its target, which came")
        let fresh = CanvasEditor(registry: h.editor.registry, document: h.editor.document, scheduler: ManualScheduler())
        expectEqual(order, fresh.paintOrder().map(\.id))
        expectSearchesAgree(h, area: CGRect(x: -100, y: -100, width: 1_700, height: 2_400), random: &random, "after it")
    },
    test("moving a few shapes files them again where they are; moving most of the board makes the grid again") {
        #if DEBUG
        let h = try spatialHarness()
        var random = Seeded(seed: 61)
        var ids: [ShapeID] = []
        for i in 0..<400 { ids.append(h.add(Box(CGRect(x: CGFloat(i % 20) * 150, y: CGFloat(i / 20) * 150, width: 100, height: 80)))) }
        let area = CGRect(x: -100, y: -100, width: 3_300, height: 3_300)
        expectSearchesAgree(h, area: area, random: &random, "as made")
        expectEqual(h.editor.spatialGridsMade, 1)
        for round in 0..<10 {
            let moved = Set((0..<5).map { _ in ids[random.index(below: ids.count)] })
            let by = CGPoint(x: random.number(-700...700), y: random.number(-700...700))
            h.editor.transact("Move") { $0.translate(moved, by: by) }
            expectSearchesAgree(h, area: area, random: &random, rects: 6, points: 6, "round \(round)")
        }
        expectEqual(h.editor.spatialGridsMade, 1, "five at a time: the one grid, filed again where they went")
        h.editor.transact("Move most") { $0.translate(Set(ids.prefix(300)), by: CGPoint(x: 37, y: 11)) }
        expectSearchesAgree(h, area: area, random: &random, "after moving three quarters of the board")
        expectEqual(h.editor.spatialGridsMade, 2, "made again for the next search")
        // Shapes moved a long way out come back.
        h.editor.transact("Away") { $0.translate(Set(ids.prefix(30)), by: CGPoint(x: 5e6, y: -7e6)) }
        expectSearchesAgree(h, area: area, random: &random, "thirty shapes a long way off")
        h.editor.transact("Away") { $0.translate(Set(ids.prefix(30)), by: CGPoint(x: 5e12, y: 0)) }
        expectSearchesAgree(h, area: area, random: &random, "and past anything on a board")
        h.editor.transact("Back") { $0.translate(Set(ids.prefix(30)), by: CGPoint(x: -5e12, y: 0)) }
        h.editor.transact("Back") { $0.translate(Set(ids.prefix(30)), by: CGPoint(x: -5e6, y: 7e6)) }
        expectSearchesAgree(h, area: area, random: &random, "and back")
        #endif
    },
    test("a board of shapes a cell can't hold goes through every shape as it did, and one of many more shapes than it stays correct") {
        var random = Seeded(seed: 71)
        // All of them wide: every shape is wider than a shape is filed in cells.
        let h = try spatialHarness()
        for i in 0..<100 { h.add(Box(CGRect(x: CGFloat(i) * 10, y: CGFloat(i % 7) * 30, width: 30_000, height: 40))) }
        expectSearchesAgree(h, area: CGRect(x: -100, y: -100, width: 1_500, height: 300), random: &random, "wide shapes")
        // Tiny shapes in one place and a few far away: cells of a size for the many.
        let h2 = try spatialHarness()
        for i in 0..<300 { h2.add(Box(CGRect(x: CGFloat(i % 20) * 12, y: CGFloat(i / 20) * 12, width: 8, height: 8))) }
        for i in 0..<5 { h2.add(Box(CGRect(x: CGFloat(i) * 1e8, y: 1e8, width: 8, height: 8))) }
        expectSearchesAgree(h2, area: CGRect(x: -100, y: -100, width: 500, height: 500), random: &random, "a cluster and its outliers")
        expectSearchesAgree(h2, area: CGRect(x: 0, y: 0, width: 5e8, height: 2e8), random: &random, "and everywhere")
        // Under a hundred: searched through every shape.
        let h3 = try spatialHarness()
        for i in 0..<20 { h3.add(Box(CGRect(x: CGFloat(i) * 50, y: 0, width: 40, height: 40))) }
        expectSearchesAgree(h3, area: CGRect(x: -100, y: -100, width: 1_200, height: 300), random: &random, "a short list")
    },
    test("a search for many shapes puts them in order, each once, through a bitmap of the list and through a sort alike") {
        var random = Seeded(seed: 81)
        let h = try spatialHarness()
        // Overlapping boxes, each in several cells: the same shapes are found cell after cell.
        for i in 0..<600 { h.add(Box(CGRect(x: CGFloat(i % 30) * 40, y: CGFloat(i / 30) * 40, width: 400, height: 300))) }
        for rect in [CGRect(x: 0, y: 0, width: 300, height: 300), CGRect(x: 100, y: 100, width: 700, height: 500), CGRect(x: 200, y: 200, width: 30, height: 30),
                     CGRect(x: -50, y: -50, width: 2_000, height: 1_000)] {
            let found = searched(h.editor, in: rect)
            expectEqual(found.cells, found.every, "\(rect)")
            expectEqual(Set(found.cells).count, found.cells.count, "each once")
        }
        expectSearchesAgree(h, area: CGRect(x: -100, y: -100, width: 1_500, height: 1_000), random: &random, "overlapping boxes")
    },
    test("the shapes a point may hit, front-most in the document first, include every shape that is hit, in the editor's context, and are every shape in another") {
        let h = try spatialHarness()
        var random = Seeded(seed: 91)
        var ids = addShapes(300, to: h, side: 3_000, random: &random)
        for step in 0..<12 {
            _ = changeBoard(h, ids: &ids, side: 3_000, random: &random)
            let context = h.editor.shapeContext
            var wrong: [String] = []
            for _ in 0..<30 {
                let point = CGPoint(x: random.number(-100...3_100), y: random.number(-100...3_100))
                let near = context.shapes(mayHit: point)
                let all = Array(h.editor.document.shapes.reversed())
                let hits = { (records: [AnyShapeRecord]) in records.filter { context.hitTest(point, shape: $0.id) }.map(\.id) }
                if hits(near) != hits(all) { wrong.append("\(point)") }
                // In the document's order, highest first.
                let indices = near.compactMap { h.editor.document.index(of: $0.id) }
                if indices != indices.sorted(by: >) { wrong.append("\(point): not in the document's order") }
            }
            expect(wrong.isEmpty, "step \(step): \(wrong.prefix(3))")
            // A transaction's context has no index: every shape, front-most first.
            h.editor.transact("Look") { transaction in
                expectEqual(transaction.shapes.shapes(mayHit: .zero).map(\.id), h.editor.document.shapes.reversed().map(\.id))
            }
        }
        // Few shapes whatever the board holds.
        let few = h.editor.shapeContext.shapes(mayHit: CGPoint(x: 1_500, y: 1_500)).count
        expect(few < h.editor.document.shapes.count / 4, "only the shapes near the point: \(few) of \(h.editor.document.shapes.count)")
    },
    test("outlines of a long list with a few shapes in view are those shapes' alone: the picture is the one going through every shape of the list draws, and the set is made once for the list") {
        #if DEBUG
        let viewport = CGSize(width: 400, height: 300)
        let outlined = Outlined()
        let h = try outlineHarness(outlined)
        var ids: [ShapeID] = []
        // A grid of boxes a screen wide, 200 across: a few are in view, the rest far off.
        for i in 0..<400 { ids.append(h.add(Box(CGRect(x: CGFloat(i % 20) * 150, y: CGFloat(i / 20) * 150, width: 100, height: 80)))) }
        h.editor.camera = Camera(origin: CGPoint(x: 120, y: 120), zoom: 1)
        outlined.shapes = ids.enumerated().filter { $0.offset % 2 == 0 || $0.offset < 100 }.map(\.element)
        func bytes(_ rep: NSBitmapImageRep) -> Data { Data(bytes: rep.bitmapData!, count: rep.bytesPerRow * rep.pixelsHigh) }
        let counted = h.editor.outlineSetsMade
        let cells = renderBitmap(h.editor, size: viewport)
        expectEqual(h.editor.outlineSetsMade, counted + 1, "a set made for the list")
        _ = renderBitmap(h.editor, size: viewport)
        h.editor.camera = Camera(origin: CGPoint(x: 121, y: 122), zoom: 1)
        _ = renderBitmap(h.editor, size: viewport)
        expectEqual(h.editor.outlineSetsMade, counted + 1, "kept through frames, and a pan")
        h.editor.camera = Camera(origin: CGPoint(x: 120, y: 120), zoom: 1)
        h.editor.scansEveryShape = true
        let every = renderBitmap(h.editor, size: viewport)
        h.editor.scansEveryShape = false
        expect(bytes(cells) == bytes(every), "the same picture, byte for byte")
        // Something is outlined at all.
        let blank = try outlineHarness(Outlined())
        for i in 0..<400 { blank.add(Box(CGRect(x: CGFloat(i % 20) * 150, y: CGFloat(i / 20) * 150, width: 100, height: 80))) }
        blank.editor.camera = Camera(origin: CGPoint(x: 120, y: 120), zoom: 1)
        expect(changedPixels(cells, renderBitmap(blank.editor, size: viewport), in: CGRect(origin: .zero, size: viewport)) > 100, "outlines are drawn")
        // A new list is a new set.
        outlined.shapes = Array(ids.prefix(200))
        _ = renderBitmap(h.editor, size: viewport)
        expectEqual(h.editor.outlineSetsMade, counted + 2)
        // The hint, and a faint group, over a long list that holds neither: stroked as when going through every shape.
        outlined.shapes = ids.prefix(200).filter { $0 != ids[22] && $0 != ids[41] }
        let plain = renderBitmap(h.editor, size: viewport)
        h.editor.hintedShapeID = ids[22]
        outlined.faint = [ids[41], ids[0]]
        let withHint = renderBitmap(h.editor, size: viewport)
        h.editor.scansEveryShape = true
        let hintEvery = renderBitmap(h.editor, size: viewport)
        h.editor.scansEveryShape = false
        expect(bytes(withHint) == bytes(hintEvery), "with the hint and a faint group: the same picture")
        expect(bytes(withHint) != bytes(plain), "and they are drawn")
        #endif
    },
    test("a tinted group of a long list, mostly out of view, is drawn as going through every shape of it draws it") {
        #if DEBUG
        let viewport = CGSize(width: 400, height: 300)
        let outlined = Outlined()
        let h = try outlineHarness(outlined)
        var ids: [ShapeID] = []
        for i in 0..<400 { ids.append(h.add(Box(CGRect(x: CGFloat(i % 20) * 150, y: CGFloat(i / 20) * 150, width: 100, height: 80)))) }
        h.editor.camera = Camera(origin: CGPoint(x: 120, y: 120), zoom: 1)
        outlined.tinted = [TintedOutlines(color: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), shapes: Array(ids.dropFirst(5)), ring: 0)]
        outlined.shapes = Array(ids.prefix(100))
        func bytes(_ rep: NSBitmapImageRep) -> Data { Data(bytes: rep.bitmapData!, count: rep.bytesPerRow * rep.pixelsHigh) }
        for zoom: CGFloat in [1, 0.2] {
            h.editor.camera = Camera(origin: CGPoint(x: 120, y: 120), zoom: zoom)
            let cells = renderBitmap(h.editor, size: viewport)
            h.editor.scansEveryShape = true
            let every = renderBitmap(h.editor, size: viewport)
            h.editor.scansEveryShape = false
            expect(bytes(cells) == bytes(every), "at \(zoom): the same picture")
        }
        #endif
    },
])

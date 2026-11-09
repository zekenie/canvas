@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Draw
import DrawScript
import TestKit
import Topology

// Where Insert puts a shape down with Draw installed (its plugin claims the core's insertion spot): beside the
// selection as `Surroundings.near` lands a box beside a shape, or with none `anywhere`, in the middle of the view
// or the nearest spot round it clear of what's there. Tiles (120 × 80) are what's inserted; the view is 800 × 600
// at the origin at 100%, so its middle is (400, 300).

@MainActor private func harness(view: Bool = true, _ records: AnyShapeRecord...) throws -> EditorHarness {
    let h = try EditorHarness(plugins: [DrawPlugin(), FixturesPlugin(), CorralsPlugin(), TilesPlugin(), LinksPlugin(), TopologyPlugin(), JoinsPlugin()],
                              file: CanvasFile(root: CanvasDocument(shapes: records)))
    if view { h.editor.viewportDidResize(to: CGSize(width: 800, height: 600)) }
    return h
}

@MainActor private func box(_ id: ShapeID, _ x: CGFloat, _ y: CGFloat, size: CGFloat = 100, in container: ShapeID? = nil) -> AnyShapeRecord {
    AnyShapeRecord(ShapeRecord(id: id, Box(CGRect(x: x, y: y, width: size, height: size)))).copy(as: id, container: container)
}

@MainActor private func corral(_ id: ShapeID, _ frame: CGRect) -> AnyShapeRecord {
    AnyShapeRecord(ShapeRecord(id: id, Corral(frame)))
}

private let tile = ToolID(placing: Tile.kind)

/// A link bound at both ends joins them: an edge Topology knows, as a key or an arrow joins two shapes.
private enum JoinEdge {}
extension JoinEdge: EdgeType {
    static let id: EdgeTypeID = "join"
}

private struct JoinsPlugin: CanvasPlugin {
    var id: PluginID { "joins" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.edgeType(JoinEdge.self)
        registrar.edges(Link.self) { record, _, sink in
            guard let link = record.props as? Link, let from = link.from, let to = link.to else { return }
            sink.emit(JoinEdge.id, from: from, to: to)
        }
    }
}

@MainActor private func link(_ from: ShapeID, _ to: ShapeID) -> AnyShapeRecord {
    AnyShapeRecord(ShapeRecord(id: ShapeID(), Link(from: from, to: to)))
}

/// The tile Insert put down last.
@MainActor private func inserted(_ h: EditorHarness) throws -> AnyShapeRecord {
    try require(h.editor.document.shapes.last { $0.kind == Tile.kind })
}

@MainActor let insertingTests = Suite("Inserting", [
    test("beside one shape: where Placing puts the box beside it for a person, right of it when that's free, tops aligned") {
        let a = ShapeID()
        let h = try harness(box(a, 0, 0))
        let expected = try require(Surroundings(on: .root, moving: TilesPlugin.size, in: h.editor)?.near(a, put: .inView(at: 1, panned: true))?.rect)
        expect(h.editor.insert(tile, beside: [a]))
        expectEqual(try inserted(h).box, expected)
        expectEqual(h.editor.announcements, ["Add Tile"], "VoiceOver hears the step, once")
        expectEqual(expected.minX, 180, "80 right of it")
        expectEqual(expected.minY, 0, "its top level with the shape's, as two tables side by side are drawn")
    },
    test("beside a shape in a frame, within the frame, and held by it once put down") {
        let k = ShapeID(), a = ShapeID()
        let h = try harness(corral(k, CGRect(x: -100, y: -100, width: 600, height: 400)), box(a, 0, 0, in: k))
        let expected = try require(Surroundings(on: .root, moving: TilesPlugin.size, in: h.editor)?.near(a, within: k, put: .inView(at: 1, panned: true))?.rect)
        expect(h.editor.insert(tile, beside: [a]))
        let placed = try inserted(h)
        expectEqual(placed.box, expected)
        expect(CGRect(x: -100, y: -100, width: 600, height: 400).contains(expected), "inside the frame")
        expectEqual(placed.container, k)
    },
    test("beside several shapes: beside the box around them") {
        let a = ShapeID(), b = ShapeID()
        let h = try harness(box(a, 0, 0), box(b, 0, 200))
        let expected = try require(Surroundings(on: .root, moving: TilesPlugin.size, in: h.editor)?
            .near(CGRect(x: 0, y: 0, width: 100, height: 300), put: .inView(at: 1, panned: true))?.rect)
        expect(h.editor.insert(tile, beside: [a, b]))
        expectEqual(try inserted(h).box, expected)
        expectEqual(expected.minY, 0, "level with the top of the two")
    },
    test("with nothing beside, in the middle of the view, or the nearest spot round it clear of what's there") {
        let h = try harness()
        expect(h.editor.insert(tile, beside: []))
        expectEqual(try inserted(h).box, CGRect(x: 340, y: 260, width: 120, height: 80), "the middle of the view")
        let a = ShapeID()
        let crowded = try harness(box(a, 350, 250))
        let expected = try require(Surroundings(on: .root, moving: TilesPlugin.size, in: crowded.editor)?.anywhere(put: .inView(at: 1, panned: true)).rect)
        expect(crowded.editor.insert(tile, beside: []))
        let placed = try inserted(crowded)
        expectEqual(placed.box, expected)
        expect(!(placed.box ?? .null).intersects(CGRect(x: 350, y: 250, width: 100, height: 100)), "clear of the box in the middle")
    },
    test("beside a shape: on its right, tops aligned, where the two fit in the clear view together (it's panned to); else a side that does") {
        // Right of it is past the view's right edge (800), but the two fit in view together: right, and the view pans to them.
        let a = ShapeID()
        let h = try harness(box(a, 640, 100))
        expect(h.editor.insert(tile, beside: [a]))
        expectEqual(try inserted(h).box, CGRect(x: 820, y: 100, width: 120, height: 80), "right of it, tops aligned")
        // A wide shape with the inspector about to come in over the right 300 points: right of it, the two wouldn't fit in what's
        // left clear, so below it, where they do.
        let b = ShapeID()
        let ahead = try harness(AnyShapeRecord(ShapeRecord(id: b, Box(CGRect(x: 50, y: 100, width: 400, height: 100)))))
        ahead.editor.coveredEdgesAhead = { CoveredEdges(right: 300) }
        expect(ahead.editor.insert(tile, beside: [b]))
        let below = try require(try inserted(ahead).box)
        expectEqual(below.minY, 280, "below it")
        let bare = ShapeID()
        let wide = try harness(AnyShapeRecord(ShapeRecord(id: bare, Box(CGRect(x: 50, y: 100, width: 400, height: 100)))))
        expect(wide.editor.insert(tile, beside: [bare]))
        expectEqual(try inserted(wide).box?.minX, 530, "with no inspector to come, right of it")
    },
    test("beside a shape whose right needs the view panned off a shape joined to it: a side in view as it is (UX walk 3 tables-1)") {
        // a at the view's left, keyed to b (selected) near its right: right of b, the least pan to show the tile and b takes a out of view.
        let a = ShapeID(), b = ShapeID()
        let h = try harness(box(a, 20, 100), box(b, 560, 100), link(b, a))
        expect(h.editor.insert(tile, beside: [b]))
        let placed = try require(try inserted(h).box)
        expect(CGRect(x: 0, y: 0, width: 800, height: 600).contains(placed), "in view as it is: \(placed)")
        expect(placed.minY > 200, "below b, not right of it: \(placed)")
        // With nothing it would pan off, right of it as ever (T1 panel 3).
        let c = ShapeID()
        let alone = try harness(box(c, 560, 100))
        expect(alone.editor.insert(tile, beside: [c]))
        expectEqual(try inserted(alone).box, CGRect(x: 740, y: 100, width: 120, height: 80), "right of it, tops aligned, panned to")
    },
    test("beside a shape whose right pans off only shapes joined to nothing it's beside: right, panning, so a chain reads on in one row (UX walk 4 firstminute-4-2)") {
        let a = ShapeID(), b = ShapeID()
        let h = try harness(box(a, 20, 100), box(b, 560, 100))
        expect(h.editor.insert(tile, beside: [b]))
        expectEqual(try inserted(h).box, CGRect(x: 740, y: 100, width: 120, height: 80), "right of it, tops aligned: a is joined to nothing")
    },
    test("a run of puts reads on: a side that reads backward never wins over right or below that is seen, with a pan or without") {
        // b low at the view's right, keyed to a high at its left: right and below each pan a off, left and above are in view.
        let a = ShapeID(), b = ShapeID()
        let h = try harness(box(a, 20, 30), box(b, 560, 450), link(b, a))
        expect(h.editor.insert(tile, beside: [b]))
        let placed = try require(try inserted(h).box)
        expect(placed.minX >= 660 || placed.minY >= 550, "right of b or below it, never left or above: \(placed)")
        // A put that isn't one of a run (a type's new note) takes the side seen as it is.
        let surroundings = try require(Surroundings(on: .root, moving: TilesPlugin.size, in: h.editor))
        let settled = try require(surroundings.near(b, put: .inView(at: 1, panned: true))?.rect)
        expect(settled.maxX <= 560 || settled.maxY <= 450, "left or above, in view as it is: \(settled)")
    },
    test("the minimap's corner is no part of the clear view: a side there isn't seen, and anywhere keeps out of it (UX walk 4 firstminute-4-1)") {
        let b = ShapeID()
        let h = try harness(box(b, 40, 300))
        let surroundings = try require(Surroundings(on: .root, moving: TilesPlugin.size, in: h.editor))
        let below = try require(surroundings.near(b, put: .inView(at: 1), sides: [.below, .right])?.rect)
        expectEqual(below.minY, 480, "below it, with the corner clear")
        h.editor.coveredCorners = CoveredCorners(bottomLeft: CGSize(width: 212, height: 162))
        let covered = try require(Surroundings(on: .root, moving: TilesPlugin.size, in: h.editor))
        expect(!covered.shows(below, put: .inView(at: 1)), "under the minimap: not seen")
        let beside = try require(covered.near(b, put: .inView(at: 1), sides: [.below, .right])?.rect)
        expectEqual(beside.minX, 220, "right of it, out of the corner: \(beside)")
        expect(covered.shows(beside, put: .inView(at: 1)))
    },
    test("with nothing beside, and the middle of the view taken: at the nearest clear spot in view, with the row above it in view") {
        let a = ShapeID()
        // A column down the middle of the view, from just under its top to its bottom: the nearest clear spot above the
        // column would put the tile's title row past the view's top, so it goes beside the column instead.
        let h = try harness(box(a, 300, 60, size: 200), box(ShapeID(), 300, 260, size: 200), box(ShapeID(), 300, 460, size: 200))
        expect(h.editor.insert(tile, beside: []))
        let placed = try require(try inserted(h).box)
        expect(placed.minY - 27 >= 16 && placed.maxY <= 584 && placed.minX >= 16 && placed.maxX <= 784, "in view with its row above: \(placed)")
    },
    test("with no view and nothing beside, nowhere to put it: nothing") {
        let h = try harness(view: false)
        expect(!h.editor.insert(tile, beside: []))
        expect(h.editor.document.shapes.isEmpty)
    },
])

@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Draw
import TestKit

// Where `Surroundings.landing(of:joinedFrom:of:)` lands a pill an arrow from a row reaches (connect 24, wave 8): below the shape,
// under the row's left end, then right of it and left of it level with the row, each where the straight line from the row to
// the pill crosses nothing and the pill is clear of what's there; nil where nowhere is.

@MainActor private func harness(_ records: AnyShapeRecord...) throws -> EditorHarness {
    try EditorHarness(plugins: [FixturesPlugin(), CorralsPlugin()], file: CanvasFile(root: CanvasDocument(shapes: records)))
}

@MainActor private func box(_ id: ShapeID, _ rect: CGRect, in container: ShapeID? = nil) -> AnyShapeRecord {
    AnyShapeRecord(ShapeRecord(id: id, Box(rect))).copy(as: id, container: container)
}

@MainActor private func corral(_ id: ShapeID, _ frame: CGRect) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(id: id, Corral(frame))) }

private let pill = CGSize(width: 200, height: 40)
/// The shape the arrow leaves, and the row it leaves from: its second line.
private let near = CGRect(x: 0, y: 0, width: 400, height: 200)
private let row = CGRect(x: 0, y: 100, width: 400, height: 24)
@MainActor private let reach = PlacingStyle.pillReach

@MainActor let pillLandingTests = Suite("A far pill landed by its line", [
    test("nothing round it: below the shape, wholly left of the row's left end where rows are under it (E4 panel 4), a reach down") {
        let a = ShapeID()
        let h = try harness(box(a, near))
        let landing = try require(Surroundings(on: .root, moving: pill, in: h.editor)?.landing(of: pill, joinedFrom: row, of: a))
        expectEqual(landing.rect, CGRect(x: -200, y: 200 + reach, width: 200, height: 40), "straight down would run along the shape's own side")
    },
    test("the shape's last row: below, under the row's left end, the line straight down") {
        let a = ShapeID()
        let h = try harness(box(a, near))
        let last = CGRect(x: 0, y: 176, width: 400, height: 24)
        let landing = try require(Surroundings(on: .root, moving: pill, in: h.editor)?.landing(of: pill, joinedFrom: last, of: a))
        expectEqual(landing.rect, CGRect(x: -100, y: 200 + reach, width: 200, height: 40))
    },
    test("a shape below: right of it, level with the row, the pill's middle at the row's middle") {
        let a = ShapeID(), below = ShapeID()
        let h = try harness(box(a, near), box(below, CGRect(x: -800, y: 260, width: 2000, height: 1000)))
        let landing = try require(Surroundings(on: .root, moving: pill, in: h.editor)?.landing(of: pill, joinedFrom: row, of: a))
        expectEqual(landing.rect, CGRect(x: 400 + reach, y: 92, width: 200, height: 40))
        expectEqual(landing.rect.midY, row.midY)
    },
    test("below taken and a shape on the row's line to the right (connect 24: refunds): left of it, level, never through the shape") {
        let a = ShapeID(), below = ShapeID(), right = ShapeID()
        let h = try harness(box(a, near), box(below, CGRect(x: -800, y: 260, width: 2000, height: 1000)),
                            box(right, CGRect(x: 480, y: 60, width: 100, height: 100)))
        let landing = try require(Surroundings(on: .root, moving: pill, in: h.editor)?.landing(of: pill, joinedFrom: row, of: a))
        expectEqual(landing.rect, CGRect(x: -reach - 200, y: 92, width: 200, height: 40))
    },
    test("the frame the shape is in is no obstacle: the pill lands in it, raised above it") {
        let k = ShapeID(), a = ShapeID()
        let h = try harness(corral(k, CGRect(x: -1000, y: -1000, width: 3000, height: 3000)), box(a, near, in: k))
        let landing = try require(Surroundings(on: .root, moving: pill, in: h.editor)?.landing(of: pill, joinedFrom: row, of: a))
        expectEqual(landing.rect, CGRect(x: -200, y: 200 + reach, width: 200, height: 40))
        expectEqual(landing.above, [k])
    },
    test("a frame's bottom edge within the first reach below: never a pill across the edge, wholly in the frame or wholly out of it") {
        let k = ShapeID(), a = ShapeID()
        let edge = CGRect(x: -1000, y: -1000, width: 3000, height: 1000 + 200 + reach + 20)
        let h = try harness(corral(k, edge), box(a, near, in: k))
        let landing = try require(Surroundings(on: .root, moving: pill, in: h.editor)?.landing(of: pill, joinedFrom: row, of: a))
        expect(edge.contains(landing.rect) || !edge.intersects(landing.rect), "not across the edge: \(landing.rect) \(edge)")
        expectEqual(landing.above, edge.contains(landing.rect) ? [k] : [], "raised above the frame only where it sits on it")
    },
    test("below, slid in under the shape, would cut across the rows under the row (a tall shape, a top row): taken only where the row is the last, else the pill goes level with the row") {
        let a = ShapeID(), left = ShapeID(), right = ShapeID()
        let top = CGRect(x: 0, y: 0, width: 400, height: 24)
        let h = try harness(box(a, CGRect(x: 0, y: 0, width: 400, height: 600)), box(left, CGRect(x: -300, y: 700, width: 240, height: 2000)),
                            box(right, CGRect(x: 250, y: 700, width: 800, height: 2000)))
        let landing = try require(Surroundings(on: .root, moving: pill, in: h.editor)?.landing(of: pill, joinedFrom: top, of: a))
        expectEqual(landing.rect, CGRect(x: 400 + reach, y: top.midY - 20, width: 200, height: 40), "right of it, level with the row")
        // The row is the shape's last: the line under the shape cuts nothing, and the slide in is taken.
        let last = CGRect(x: 0, y: 576, width: 400, height: 24)
        let under = try require(Surroundings(on: .root, moving: pill, in: h.editor)?.landing(of: pill, joinedFrom: last, of: a))
        expect(under.rect.minY >= 600, "below the shape: \(under.rect)")
    },
    test("a line between rows (a key, level): level with the row first, left of the shape, then right (T3 panel 4, T6 panel 3)") {
        let a = ShapeID(), left = ShapeID()
        let h = try harness(box(a, near))
        let landing = try require(Surroundings(on: .root, moving: pill, in: h.editor)?.landing(of: pill, joinedFrom: row, of: a, level: true))
        expectEqual(landing.rect, CGRect(x: -reach - 200, y: 92, width: 200, height: 40), "left, the line leaving the row's side straight")
        let walled = try harness(box(a, near), box(left, CGRect(x: -180, y: 60, width: 100, height: 100)))
        let right = try require(Surroundings(on: .root, moving: pill, in: walled.editor)?.landing(of: pill, joinedFrom: row, of: a, level: true))
        expectEqual(right.rect, CGRect(x: 400 + reach, y: 92, width: 200, height: 40), "a shape on the line to the left: right, level")
    },
    test("a key with both sides of its row taken: below, slid out past the row's end by the mark's room, never under the end") {
        let a = ShapeID(), right = ShapeID(), left = ShapeID()
        let h = try harness(box(a, near), box(right, CGRect(x: 480, y: 60, width: 100, height: 100)), box(left, CGRect(x: -180, y: 60, width: 100, height: 100)))
        let landing = try require(Surroundings(on: .root, moving: pill, in: h.editor)?.landing(of: pill, joinedFrom: row, of: a, level: true))
        expect(landing.rect.minY >= near.maxY, "below the shape: \(landing.rect)")
        expect(landing.rect.maxX <= row.minX - PlacingStyle.markRoom || landing.rect.minX >= row.maxX + PlacingStyle.markRoom,
               "out past the end by the mark's room: \(landing.rect)")
        // The last row too, where an endpoint's pill would go straight under its end.
        let last = CGRect(x: 0, y: 176, width: 400, height: 24)
        let under = try require(Surroundings(on: .root, moving: pill, in: h.editor)?.landing(of: pill, joinedFrom: last, of: a, level: true))
        expect(under.rect.maxX <= last.minX - PlacingStyle.markRoom || under.rect.minX >= last.maxX + PlacingStyle.markRoom, "\(under.rect)")
    },
    test("a pill there already joins clean where its line from the row crosses no shape, the shape and the pill itself aside") {
        let a = ShapeID(), other = ShapeID(), standIn = ShapeID()
        let far = CGRect(x: 0, y: 500, width: 200, height: 40)
        let h = try harness(box(a, near), box(other, CGRect(x: 300, y: 300, width: 300, height: 120)), box(standIn, far))
        let surroundings = try require(Surroundings(on: .root, moving: pill, in: h.editor))
        expect(surroundings.joinsClean(row, of: a, to: far, standIn: standIn), "from the row's left end down to it: clear")
        let across = CGRect(x: 700, y: 500, width: 200, height: 40)
        expect(!surroundings.joinsClean(row, of: a, to: across), "from its right end, through the other shape")
        expect(!surroundings.joinsClean(row, of: a, to: far, avoiding: [CGRect(x: -100, y: 300, width: 200, height: 50)]), "through a box planned")
    },
    test("walled in on every side: nil, for the caller to land it as draw does") {
        let a = ShapeID(), below = ShapeID(), right = ShapeID(), left = ShapeID()
        let h = try harness(box(a, near), box(below, CGRect(x: -800, y: 260, width: 2000, height: 1000)),
                            box(right, CGRect(x: 480, y: 60, width: 100, height: 100)), box(left, CGRect(x: -180, y: 60, width: 100, height: 100)))
        expect(Surroundings(on: .root, moving: pill, in: h.editor)?.landing(of: pill, joinedFrom: row, of: a) == nil)
    },
])

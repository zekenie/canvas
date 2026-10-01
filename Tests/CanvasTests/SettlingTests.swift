@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Geometry
import TestKit

// Settling what's put down by the in-or-out rule (`Transaction.settle`), with CanvasTesting's corrals
// standing in for frames: a container 400 × 300 at (100, 100), whose edges are x 100…500 and y
// 100…400, and 50-point boxes put down across them. A nudge ends 16 world units in from an edge, or
// out from it (`Style.containerGap`). Then drops (a fixture drag tool: the core has no Selection
// here), placements, and the glide.

private let pen = CGRect(x: 100, y: 100, width: 400, height: 300)

@MainActor private func settleHarness(_ more: [any CanvasPlugin] = []) throws -> EditorHarness {
    try EditorHarness(plugins: [FixturesPlugin(), CorralsPlugin()] + more)
}

@MainActor private func square(_ h: EditorHarness, at origin: CGPoint, side: CGFloat = 50) -> ShapeID {
    h.add(Box(CGRect(origin: origin, size: CGSize(width: side, height: side))))
}

extension EditorHarness {
    fileprivate func origin(of shape: ShapeID) -> CGPoint? { editor.document[shape]?.box?.origin }
    fileprivate func settle(_ ids: [ShapeID]) -> Settlement { editor.transact { $0.settle(ids) } }
    fileprivate var stackIDs: [ShapeID] { editor.document.shapes.map(\.id) }
}

/// The glide's ease (`Style.glideOvershoot`, 1.2), worked out apart from the editor's.
private func eased(_ t: CGFloat) -> CGFloat {
    let u = t - 1
    return 1 + 2.2 * u * u * u + 1.2 * u * u
}

@MainActor let settlingTests = Suite("Settling", [
    test("wholly inside goes in, wholly outside stays out, and neither is nudged") {
        let h = try settleHarness()
        let held = h.add(Corral(pen))
        let inside = square(h, at: CGPoint(x: 150, y: 150))
        let outside = square(h, at: CGPoint(x: 600, y: 100))
        expectEqual(h.settle([inside]), .settled(nudges: [:]))
        expectEqual(h.settle([outside]), .settled(nudges: [:]))
        expectEqual(h.editor.holder(of: inside), held)
        expectEqual(h.editor.holder(of: outside), nil)
        expectEqual(h.origin(of: inside), CGPoint(x: 150, y: 150))
    },
    test("mostly inside goes in, nudged fully in, to the gap inside the edge it hangs over") {
        let h = try settleHarness()
        let held = h.add(Corral(pen))
        let right = square(h, at: CGPoint(x: 470, y: 150))             // 60% in
        let bottom = square(h, at: CGPoint(x: 200, y: 370))
        expectEqual(h.settle([right]), .settled(nudges: [right: CGPoint(x: -36, y: 0)]))
        expectEqual(h.origin(of: right), CGPoint(x: 434, y: 150))
        expectEqual(h.editor.holder(of: right), held)
        expectEqual(h.settle([bottom]), .settled(nudges: [bottom: CGPoint(x: 0, y: -36)]))
        expectEqual(h.origin(of: bottom), CGPoint(x: 200, y: 334))
    },
    test("mostly outside goes out, nudged fully out the shortest way, to the gap outside; half in is out") {
        let h = try settleHarness()
        let held = h.add(Corral(pen))
        let leaving = square(h, at: CGPoint(x: 200, y: 150))
        h.editor.put([leaving], in: held)
        h.editor.transact { $0.update(leaving) { $0.box?.origin = CGPoint(x: 490, y: 150) } }     // 20% in
        expectEqual(h.settle([leaving]), .settled(nudges: [leaving: CGPoint(x: 26, y: 0)]))
        expectEqual(h.origin(of: leaving), CGPoint(x: 516, y: 150))
        expectEqual(h.editor.holder(of: leaving), nil, "it left")
        let half = square(h, at: CGPoint(x: 475, y: 250))
        expectEqual(h.settle([half]), .settled(nudges: [half: CGPoint(x: 41, y: 0)]))
        let corner = h.add(Box(CGRect(x: 480, y: 380, width: 40, height: 40)))   // a quarter in
        expectEqual(h.settle([corner]), .settled(nudges: [corner: CGPoint(x: 36, y: 0)]), "of two as short, the first")
    },
    test("where containers nest, the innermost holding most of it goes, and it's nudged out of those it isn't in") {
        let h = try settleHarness()
        let outer = h.add(Corral(pen))
        let inner = h.add(Corral(CGRect(x: 150, y: 150, width: 200, height: 150)))   // x 150…350, y 150…300
        h.editor.put([inner], in: outer)
        let deep = square(h, at: CGPoint(x: 320, y: 200))              // 60% in inner
        let shallow = square(h, at: CGPoint(x: 330, y: 200))           // 40% in inner, all in outer
        expectEqual(h.settle([deep]), .settled(nudges: [deep: CGPoint(x: -36, y: 0)]))
        expectEqual(h.editor.holder(of: deep), inner)
        expectEqual(h.settle([shallow]), .settled(nudges: [shallow: CGPoint(x: 36, y: 0)]))
        expectEqual(h.editor.holder(of: shallow), outer)
        expectEqual(h.origin(of: shallow), CGPoint(x: 366, y: 200))
    },
    test("shapes put down together from one container are judged by their summed area, and nudged together") {
        let h = try settleHarness()
        let held = h.add(Corral(pen))
        let hanging = square(h, at: CGPoint(x: 470, y: 150))
        let inside = square(h, at: CGPoint(x: 380, y: 150))
        expectEqual(h.settle([hanging, inside]), .settled(nudges: [hanging: CGPoint(x: -36, y: 0), inside: CGPoint(x: -36, y: 0)]))
        expectEqual([h.editor.holder(of: hanging), h.editor.holder(of: inside)], [held, held])
        expectEqual(h.origin(of: inside), CGPoint(x: 344, y: 150), "as far from each other as they were")
        let reaching = square(h, at: CGPoint(x: 490, y: 250))           // 20% in
        let beside = square(h, at: CGPoint(x: 550, y: 250))
        expectEqual(h.settle([reaching, beside]), .settled(nudges: [reaching: CGPoint(x: 26, y: 0), beside: CGPoint(x: 26, y: 0)]))
        expectEqual([h.editor.holder(of: reaching), h.editor.holder(of: beside)], [nil, nil])
    },
    test("shapes from different containers are judged by the container each came from, so a small move keeps each in its own") {
        let h = try settleHarness()
        let left = h.add(Corral(CGRect(x: 0, y: 0, width: 200, height: 200)))
        let right = h.add(Corral(CGRect(x: 300, y: 0, width: 200, height: 200)))
        let a = square(h, at: CGPoint(x: 20, y: 20))
        let b = square(h, at: CGPoint(x: 320, y: 20))
        h.editor.put([a], in: left)
        h.editor.put([b], in: right)
        h.editor.transact { $0.translate([a, b], by: CGPoint(x: 10, y: 10)) }
        expectEqual(h.settle([a, b]), .settled(nudges: [:]))
        expectEqual([h.editor.holder(of: a), h.editor.holder(of: b)], [left, right])
    },
    test("a group that doesn't fit the container holding most of it is judged shape by shape") {
        let h = try settleHarness()
        let held = h.add(Corral(pen))
        let long = h.add(Box(CGRect(x: 110, y: 150, width: 300, height: 50)))
        let hanging = h.add(Box(CGRect(x: 380, y: 220, width: 200, height: 50)))   // 60% in; together 470 wide
        expectEqual(h.settle([long, hanging]), .settled(nudges: [hanging: CGPoint(x: -96, y: 0)]))
        expectEqual([h.editor.holder(of: long), h.editor.holder(of: hanging)], [held, held])
        expectEqual(h.origin(of: long), CGPoint(x: 110, y: 150))
    },
    test("a shape too big for a container can't be in it, and is nudged out; one over all of a container is over it, not across it") {
        let h = try settleHarness()
        let held = h.add(Corral(pen))
        let wide = h.add(Box(CGRect(x: 80, y: 150, width: 450, height: 100)))      // 89% in, 450 wide
        expectEqual(h.settle([wide]), .settled(nudges: [wide: CGPoint(x: 0, y: -166)]))
        expectEqual(h.editor.holder(of: wide), nil)
        expectEqual(h.origin(of: wide), CGPoint(x: 80, y: -16))
        let over = h.add(Box(CGRect(x: 50, y: 50, width: 500, height: 400)))
        expectEqual(h.settle([over]), .settled(nudges: [:]))
        expectEqual(h.editor.holder(of: over), nil)
        expectEqual(h.editor.holder(of: held), nil, "and the container isn't in it")
    },
    test("over all of a container, what's put down is over it, neither in it nor across its edge: a container its size dropped on it stays beside it, and takes nothing it holds") {
        let h = try settleHarness()
        let held = h.add(Corral(pen))
        let member = square(h, at: CGPoint(x: 150, y: 150))
        h.editor.put([member], in: held)
        let twin = h.add(Corral(pen))
        expectEqual(h.settle([twin]), .settled(nudges: [:]))
        expectEqual([h.editor.holder(of: twin), h.editor.holder(of: held), h.editor.holder(of: member)], [nil, nil, held])
        let cover = h.add(Box(CGRect(x: 100, y: 100, width: 400, height: 300)))
        expectEqual(h.settle([cover]), .settled(nudges: [:]))
        expectEqual(h.editor.holder(of: cover), nil)
    },
    test("read-only shapes put down stay as they are") {
        let log = RefusalLog()
        let h = try settleHarness([FreezingPlugin(log: log)])
        h.add(Corral(pen))
        let locked = square(h, at: CGPoint(x: 470, y: 150))
        h.editor.freeze([locked])
        expectEqual(h.settle([locked]), .settled(nudges: [:]))
        expectEqual(h.origin(of: locked), CGPoint(x: 470, y: 150))
        expectEqual(h.editor.holder(of: locked), nil)
        expectEqual(log.refusals, [])
    },
    test("a read-only container takes nothing: nothing changes, and it's the one refused; what's mostly outside is nudged out") {
        let log = RefusalLog()
        let h = try settleHarness([FreezingPlugin(log: log)])
        let held = h.add(Corral(pen))
        let other = h.add(Corral(CGRect(x: 600, y: 100, width: 200, height: 200)))
        let into = square(h, at: CGPoint(x: 470, y: 150))
        let hanging = square(h, at: CGPoint(x: 770, y: 150))
        h.editor.put([hanging], in: other)
        h.editor.freeze([held])
        let before = h.editor.document
        expectEqual(h.settle([into, hanging]), .refused(by: held))
        expectEqual(h.editor.document, before)
        expectEqual(log.refusals, [[held]])
        let reaching = square(h, at: CGPoint(x: 490, y: 300))
        expectEqual(h.settle([reaching]), .settled(nudges: [reaching: CGPoint(x: 26, y: 0)]))
        expectEqual(log.refusals, [[held]])
    },
    test("what's put down in a container put down with it goes with it; the container takes in what it lands on, and what's in it hanging over its edge") {
        let h = try settleHarness()
        let held = h.add(Corral(pen))
        let member = square(h, at: CGPoint(x: 470, y: 150))
        h.editor.put([member], in: held)
        let landed = square(h, at: CGPoint(x: 200, y: 200))
        expectEqual(h.settle([held, member]), .settled(nudges: [member: CGPoint(x: -36, y: 0)]))
        expectEqual(h.editor.holder(of: member), held)
        expectEqual(h.editor.holder(of: landed), held, "taken in")
    },
    test("joining raises a shape above what the container holds") {
        let h = try settleHarness()
        let below = square(h, at: CGPoint(x: 150, y: 150))
        let held = h.add(Corral(pen))
        let member = square(h, at: CGPoint(x: 300, y: 150))
        h.editor.put([member], in: held)
        _ = h.settle([below])
        expectEqual(h.stackIDs, [held, member, below])
    },
    test("a shape that can't be in a container rides with what's put down with it, when they're judged as one") {
        let h = try settleHarness([Contributor(id: "trails") { $0.shape(TrailDefinition()) }])
        h.add(Corral(pen))
        let hanging = square(h, at: CGPoint(x: 470, y: 150))
        let trail = h.add(Trail(points: [CGPoint(x: 480, y: 300), CGPoint(x: 600, y: 300)]))
        expectEqual(h.settle([hanging, trail]), .settled(nudges: [hanging: CGPoint(x: -36, y: 0), trail: CGPoint(x: -36, y: 0)]))
        expectEqual(h.editor.document[trail]?.typed(as: Trail.self)?.props.points, [CGPoint(x: 444, y: 300), CGPoint(x: 564, y: 300)])
        // Put down from two containers, it stays where it is.
        let other = h.add(Corral(CGRect(x: 600, y: 500, width: 200, height: 200)))
        let elsewhere = square(h, at: CGPoint(x: 770, y: 550))
        h.editor.put([elsewhere], in: other)
        let again = square(h, at: CGPoint(x: 470, y: 250))
        _ = h.settle([again, elsewhere, trail])
        expectEqual(h.editor.document[trail]?.typed(as: Trail.self)?.props.points, [CGPoint(x: 444, y: 300), CGPoint(x: 564, y: 300)])
    },
    test("nothing settles without a container kind") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        let a = square(h, at: CGPoint(x: 470, y: 150))
        let revision = h.editor.revision
        expectEqual(h.settle([a]), .settled(nudges: [:]))
        expectEqual(h.editor.revision, revision)
    },
])

@MainActor let settlingContainerTests = Suite("Settling a container", [
    test("after a resize, what's in it hanging over its edge is nudged in, or leaves if it's mostly outside; read-only ones stay") {
        let log = RefusalLog()
        let h = try settleHarness([FreezingPlugin(log: log)])
        let held = h.add(Corral(pen))
        let leaving = square(h, at: CGPoint(x: 400, y: 150))
        let gone = square(h, at: CGPoint(x: 440, y: 250))
        let staying = square(h, at: CGPoint(x: 380, y: 200))
        let locked = h.add(Box(CGRect(x: 460, y: 320, width: 30, height: 30)))
        let inside = square(h, at: CGPoint(x: 300, y: 330))
        h.editor.put([leaving, gone, staying, locked, inside], in: held)
        h.editor.freeze([locked])
        let nudges = h.editor.transact { tx in
            tx.update(held) { $0.box = CGRect(x: 100, y: 100, width: 320, height: 300) }     // x 100…420
            return tx.settle(container: held)
        }
        expectEqual(nudges, [leaving: CGPoint(x: 36, y: 0), staying: CGPoint(x: -26, y: 0)])
        expectEqual(h.editor.holder(of: leaving), nil)
        expectEqual(h.origin(of: leaving), CGPoint(x: 436, y: 150))
        expectEqual(h.editor.holder(of: gone), nil, "all of it outside: it leaves, as it is")
        expectEqual(h.origin(of: gone), CGPoint(x: 440, y: 250))
        expectEqual(h.editor.holder(of: staying), held)
        expectEqual(h.origin(of: staying), CGPoint(x: 354, y: 200))
        expectEqual(h.editor.holder(of: locked), held, "hanging, locked")
        expectEqual(h.origin(of: inside), CGPoint(x: 300, y: 330))
        expectEqual(log.refusals, [])
    },
    test("moved onto shapes at its level, it takes in what's mostly inside it, and nudges out what's mostly outside; read-only ones stay out") {
        let h = try settleHarness([FreezingPlugin()])
        let held = h.add(Corral(pen))
        let halfIn = h.add(Box(CGRect(x: 450, y: 150, width: 100, height: 50)))
        let mostlyIn = square(h, at: CGPoint(x: 470, y: 250))
        let locked = h.add(Box(CGRect(x: 480, y: 330, width: 40, height: 40)))
        let wholly = square(h, at: CGPoint(x: 150, y: 150))
        let apart = h.add(Corral(CGRect(x: 700, y: 100, width: 200, height: 200)))
        let elsewhere = square(h, at: CGPoint(x: 720, y: 120))
        h.editor.put([elsewhere], in: apart)
        h.editor.freeze([locked])
        let nudges = h.editor.transact { $0.settle(container: held) }
        expectEqual(nudges, [halfIn: CGPoint(x: 66, y: 0), mostlyIn: CGPoint(x: -36, y: 0)])
        expectEqual([h.editor.holder(of: halfIn), h.editor.holder(of: mostlyIn), h.editor.holder(of: locked), h.editor.holder(of: wholly)],
                    [nil, held, nil, held])
        expectEqual(h.origin(of: locked), CGPoint(x: 480, y: 330))
        expectEqual(h.editor.holder(of: elsewhere), apart)
    },
    test("nudged out of one container toward another too near to fit between, it goes the shortest way clear of both") {
        let h = try settleHarness()
        h.add(Corral(pen))
        h.add(Corral(CGRect(x: 600, y: 100, width: 200, height: 200)))
        let between = h.add(Box(CGRect(x: 450, y: 150, width: 100, height: 50)))     // half in the first
        expectEqual(h.settle([between]), .settled(nudges: [between: CGPoint(x: 0, y: -116)]))
        expectEqual(h.editor.holder(of: between), nil)
    },
    test("a read-only container put down takes in nothing it lands on, though the transaction put it there") {
        let h = try settleHarness([FreezingPlugin()])
        let loose = square(h, at: CGPoint(x: 150, y: 150))
        let nudges = h.editor.transact { tx in
            var frozen = AnyShapeRecord(ShapeRecord(Corral(pen)))
            frozen[Frozen.self] = true
            tx.insert(frozen)
            return tx.settle(container: frozen.id)
        }
        expectEqual(nudges, [:])
        expectEqual(h.editor.holder(of: loose), nil)
    },
    test("a container it takes in brings what that holds, and the nudges say so") {
        let h = try settleHarness()
        let held = h.add(Corral(pen))
        let small = h.add(Corral(CGRect(x: 420, y: 150, width: 100, height: 100)))     // 80% in
        let inSmall = h.add(Box(CGRect(x: 430, y: 160, width: 20, height: 20)))
        h.editor.put([inSmall], in: small)
        let nudges = h.editor.transact { $0.settle(container: held) }
        expectEqual(nudges, [small: CGPoint(x: -36, y: 0), inSmall: CGPoint(x: -36, y: 0)])
        expectEqual(h.editor.holder(of: small), held)
        expectEqual(h.editor.holder(of: inSmall), small)
        expectEqual(h.origin(of: inSmall), CGPoint(x: 394, y: 160))
    },
])

@MainActor private func dropHarness(_ log: RefusalLog = RefusalLog(), _ more: [any CanvasPlugin] = []) throws -> EditorHarness {
    try EditorHarness(plugins: [FixturesPlugin(), CorralsPlugin(), FreezingPlugin(log: log), dragPlugin()] + more)
}

@MainActor let droppingTests = Suite("Dropping into containers", [
    test("a drop mostly inside a container puts it in, nudged fully in, gliding there, all in the drag's step") {
        let h = try dropHarness()
        let held = h.add(Corral(pen))
        let a = square(h, at: CGPoint(x: 600, y: 150))
        h.press(at: CGPoint(x: 625, y: 175))
        h.drag(to: CGPoint(x: 560, y: 175))
        h.drag(to: CGPoint(x: 495, y: 175))                             // at 470: 60% in
        expectEqual(h.editor.hintedShapeID, held)
        h.release()
        expectEqual(h.editor.hintedShapeID, nil)
        expectEqual(h.origin(of: a), CGPoint(x: 434, y: 150))
        expectEqual(h.editor.holder(of: a), held)
        expectEqual(h.editor.drawingOffset(of: a), CGPoint(x: 36, y: 0), "drawn where it was dropped")
        expect(h.editor.isGliding(a))
        h.wait(16)
        expectClose(h.editor.drawingOffset(of: a).x, 36 * (1 - eased(0.064)), within: 1e-9)
        h.wait(144)
        expectClose(h.editor.drawingOffset(of: a).x, 36 * (1 - eased(0.64)), within: 1e-9)
        expect(h.editor.drawingOffset(of: a).x < 0, "a little past where it lands")
        h.wait(96)
        expectEqual(h.editor.drawingOffset(of: a), .zero)
        expect(!h.editor.isGliding(a))
        expectEqual(h.editor.undoHistory.undoName, "Move")
        h.editor.undo()
        expectEqual(h.origin(of: a), CGPoint(x: 600, y: 150))
        expectEqual(h.editor.holder(of: a), nil)
        h.editor.redo()
        expectEqual(h.origin(of: a), CGPoint(x: 434, y: 150))
        expectEqual(h.editor.holder(of: a), held)
    },
    test("past the drag threshold, the hint outlines the container a drop would go into, never a read-only one") {
        let h = try dropHarness()
        let held = h.add(Corral(pen))
        let a = square(h, at: CGPoint(x: 470, y: 150))
        h.press(at: CGPoint(x: 495, y: 175))
        h.drag(to: CGPoint(x: 497, y: 175))
        expectEqual(h.editor.hintedShapeID, nil, "short of the threshold")
        h.drag(to: CGPoint(x: 480, y: 175))
        expectEqual(h.editor.hintedShapeID, held)
        h.drag(to: CGPoint(x: 700, y: 175))
        expectEqual(h.editor.hintedShapeID, nil)
        h.drag(to: CGPoint(x: 480, y: 175))
        expectEqual(h.editor.hintedShapeID, held)
        h.release()
        expectEqual(h.editor.holder(of: a), held)
        let b = square(h, at: CGPoint(x: 600, y: 300))
        h.editor.freeze([held])
        h.press(at: CGPoint(x: 625, y: 325))
        h.drag(to: CGPoint(x: 495, y: 325))
        expectEqual(h.editor.hintedShapeID, nil, "60% in a read-only container")
        h.escape()
        h.release()
        expectEqual(h.editor.holder(of: b), nil)
    },
    test("dragged from two containers, the hint shows a container only where every group would go into it") {
        let picks = Picks()
        let h = try EditorHarness(plugins: [FixturesPlugin(), CorralsPlugin(), FreezingPlugin(log: RefusalLog()), dragPlugin(picks)])
        let first = h.add(Corral(pen)), second = h.add(Corral(CGRect(x: 1200, y: 100, width: 400, height: 300)))
        let below = h.add(Corral(CGRect(x: 100, y: 600, width: 1000, height: 300)))
        let a1 = square(h, at: CGPoint(x: 150, y: 150)), a2 = square(h, at: CGPoint(x: 250, y: 150))
        let b = square(h, at: CGPoint(x: 1250, y: 150))
        h.editor.put([a1, a2], in: first)
        h.editor.put([b], in: second)
        picks.ids = [a1, a2, b]
        h.press(at: CGPoint(x: 175, y: 175))
        h.drag(to: CGPoint(x: 175, y: 425))
        h.drag(to: CGPoint(x: 175, y: 675))
        expectEqual(h.editor.hintedShapeID, nil, "two thirds of what's dragged would go in the one below, but the shape from the other container wouldn't")
        h.release()
        expectEqual(h.editor.holder(of: a1), below)
        expectEqual(h.editor.holder(of: a2), below)
        expectEqual(h.editor.holder(of: b), nil, "out of its container, onto the board")
        expectEqual(h.origin(of: b), CGPoint(x: 1250, y: 650))
    },
    test("a drag out of a container takes a shape out of it") {
        let h = try dropHarness()
        let held = h.add(Corral(pen))
        let a = square(h, at: CGPoint(x: 200, y: 200))
        h.editor.put([a], in: held)
        h.press(at: CGPoint(x: 225, y: 225))
        h.drag(to: CGPoint(x: 625, y: 225))
        h.release()
        expectEqual(h.editor.holder(of: a), nil)
        expectEqual(h.origin(of: a), CGPoint(x: 600, y: 200))
        expect(!h.editor.isGliding(a))
    },
    test("a read-only container refuses a drop: what was dragged goes back, gliding from where it was dropped, and the press leaves no step") {
        let log = RefusalLog()
        let h = try dropHarness(log)
        let held = h.add(Corral(pen))
        let a = square(h, at: CGPoint(x: 600, y: 150))
        h.editor.freeze([held])
        h.press(at: CGPoint(x: 625, y: 175))
        h.drag(to: CGPoint(x: 495, y: 175))
        h.release()
        expectEqual(h.origin(of: a), CGPoint(x: 600, y: 150))
        expectEqual(h.editor.holder(of: a), nil)
        expectEqual(h.editor.drawingOffset(of: a), CGPoint(x: -130, y: 0), "drawn where it was dropped")
        expectEqual(log.refusals, [[held]])
        h.wait(256)
        expectEqual(h.editor.drawingOffset(of: a), .zero)
        h.editor.undo()
        expect(!h.editor.isReadOnly(held), "the step undone is the one before the press")
        expectEqual(h.origin(of: a), CGPoint(x: 600, y: 150))
    },
    test("Escape puts what was dragged back at once, settling nothing and gliding nothing") {
        let h = try dropHarness()
        let held = h.add(Corral(pen))
        let a = square(h, at: CGPoint(x: 600, y: 150))
        h.press(at: CGPoint(x: 625, y: 175))
        h.drag(to: CGPoint(x: 495, y: 175))
        expectEqual(h.editor.hintedShapeID, held)
        h.escape()
        expectEqual(h.editor.hintedShapeID, nil)
        expectEqual(h.origin(of: a), CGPoint(x: 600, y: 150))
        expectEqual(h.editor.drawingOffset(of: a), .zero)
        h.release()
        expectEqual(h.editor.holder(of: a), nil)
    },
    test("a click settles nothing: a lone box short of the drag threshold stays where it's let go") {
        let h = try dropHarness()
        h.add(Corral(pen))
        let a = square(h, at: CGPoint(x: 470, y: 150))
        h.press(at: CGPoint(x: 495, y: 175))
        h.drag(to: CGPoint(x: 497, y: 175))
        h.release()
        expectEqual(h.origin(of: a), CGPoint(x: 472, y: 150))
        expectEqual(h.editor.holder(of: a), nil)
        expect(!h.editor.isGliding(a))
    },
    test("a container dragged carries what it holds, read-only or not, and takes in what it lands on") {
        let log = RefusalLog()
        let h = try dropHarness(log)
        let held = h.add(Corral(pen))
        let locked = square(h, at: CGPoint(x: 150, y: 150))
        let free = square(h, at: CGPoint(x: 300, y: 150))
        let landed = square(h, at: CGPoint(x: 650, y: 150))
        h.editor.put([locked, free], in: held)
        h.editor.freeze([locked])
        h.press(at: CGPoint(x: 120, y: 350))
        h.drag(to: CGPoint(x: 370, y: 350))
        h.release()
        expectEqual(h.origin(of: held), CGPoint(x: 350, y: 100))
        expectEqual(h.origin(of: locked), CGPoint(x: 400, y: 150))
        expectEqual(h.origin(of: free), CGPoint(x: 550, y: 150))
        expectEqual(h.editor.holder(of: landed), held)
        expectEqual(log.refusals, [])
    },
    test("with no container on the board, a drop commits nothing more and glides nothing") {
        let h = try dropHarness()
        let a = square(h, at: CGPoint(x: 470, y: 150))
        h.press(at: CGPoint(x: 495, y: 175))
        h.drag(to: CGPoint(x: 595, y: 175))
        let revision = h.editor.revision
        h.release()
        expectEqual(h.editor.revision, revision)
        expect(!h.editor.isGliding(a))
        expectEqual(h.editor.hintedShapeID, nil)
    },
])

@MainActor let placingIntoContainersTests = Suite("Placing into containers", [
    test("a shape placed mostly inside a container goes in on the release, nudged in, gliding, in the placement's step") {
        let h = try EditorHarness(plugins: [CorralsPlugin(), discTools(), FreezingPlugin()])
        let held = h.add(Corral(pen))
        h.editor.setTool("disc")
        h.press(at: CGPoint(x: 490, y: 200))                             // a 40-point disc at (470, 180): 75% in
        let disc = try require(h.editor.document.shapes.last?.id)
        h.release()
        expectEqual(h.editor.document[disc]?.box?.origin, CGPoint(x: 444, y: 180))
        expectEqual(h.editor.holder(of: disc), held)
        expectEqual(h.editor.drawingOffset(of: disc), CGPoint(x: 26, y: 0))
        expectEqual(h.editor.undoHistory.undoName, "Add Disc")
        h.editor.undo()
        expectEqual(h.editor.document[disc], nil)
    },
    test("placed into a read-only container, the shape is taken away, the container refused, and the press leaves no step") {
        let log = RefusalLog()
        let h = try EditorHarness(plugins: [CorralsPlugin(), discTools(), FreezingPlugin(log: log)])
        let held = h.add(Corral(pen))
        h.editor.freeze([held])
        h.editor.setTool("disc")
        h.press(at: CGPoint(x: 490, y: 200))
        h.release()
        expectEqual(h.editor.document.shapes.map(\.id), [held])
        expectEqual(log.refusals, [[held]])
        h.editor.undo()
        expect(!h.editor.isReadOnly(held))
    },
    test("placed with no press, it settles at once, in the same step; into a read-only container, nothing is placed") {
        let log = RefusalLog()
        let h = try EditorHarness(plugins: [CorralsPlugin(), discTools(), FreezingPlugin(log: log)])
        let held = h.add(Corral(pen))
        let placement = try require(h.editor.registry.placement(for: Disc.kind))
        h.editor.place(placement, at: CGPoint(x: 490, y: 200))
        let disc = try require(h.editor.document.shapes.last?.id)
        expectEqual(h.editor.document[disc]?.box?.origin, CGPoint(x: 444, y: 180))
        expectEqual(h.editor.holder(of: disc), held)
        expectEqual(h.editor.undoHistory.undoName, "Add Disc")
        h.editor.undo()
        expectEqual(h.editor.document[disc], nil)
        h.editor.freeze([held])
        let count = h.editor.document.shapes.count
        h.editor.place(placement, at: CGPoint(x: 490, y: 200))
        expectEqual(h.editor.document.shapes.count, count)
        expectEqual(log.refusals, [[held]])
    },
    test("a shape placed to be edited isn't glided: its editing view is laid out where it is") {
        let h = try EditorHarness(plugins: [CardsPlugin(), CorralsPlugin()])
        let held = h.add(Corral(pen))
        h.editor.setTool("card")
        h.press(at: CGPoint(x: 480, y: 200))                             // a 100 × 60 card at (430, 170): 70% in
        let card = try require(h.editor.document.shapes.last?.id)
        h.release()
        expectEqual(h.editor.editingShapeID, card)
        expectEqual(h.editor.holder(of: card), held)
        expectEqual(h.editor.document[card]?.box?.origin, CGPoint(x: 384, y: 170))
        expectEqual(h.editor.drawingOffset(of: card), .zero)
    },
])

@MainActor let glideTests = Suite("Gliding", [
    test("a glide draws a shape from where it was to where it is, in view points at the zoom now, eased out a little past it") {
        let h = try settleHarness()
        let a = square(h, at: CGPoint(x: 100, y: 100))
        h.editor.camera = Camera(origin: .zero, zoom: 2)
        h.editor.glide([a: CGPoint(x: 10, y: 0)])
        expectEqual(h.editor.drawingOffset(of: a), CGPoint(x: -20, y: 0))
        h.wait(16)
        expectClose(h.editor.drawingOffset(of: a).x, -20 * (1 - eased(0.064)), within: 1e-9)
        h.wait(144)
        expectClose(h.editor.drawingOffset(of: a).x, -20 * (1 - eased(0.64)), within: 1e-9)
        expect(h.editor.drawingOffset(of: a).x > 0)
        h.wait(80)
        expect(h.editor.isGliding(a))
        h.wait(16)
        expectEqual(h.editor.drawingOffset(of: a), .zero)
        expect(!h.editor.isGliding(a))
        expectEqual(h.origin(of: a), CGPoint(x: 100, y: 100), "nothing moved but how it's drawn")
    },
    test("gliding again goes on from where it's drawn; a shape not on the board, or not moved, doesn't glide") {
        let h = try settleHarness()
        let a = square(h, at: CGPoint(x: 100, y: 100))
        h.editor.glide([a: CGPoint(x: 10, y: 0)])
        h.wait(16)
        let drawn = h.editor.drawingOffset(of: a)
        h.editor.glide([a: CGPoint(x: 5, y: 0)])
        expectEqual(h.editor.drawingOffset(of: a), CGPoint(x: drawn.x - 5, y: 0))
        let gone = ShapeID()
        h.editor.glide([gone: CGPoint(x: 10, y: 0), a: .zero])
        expect(!h.editor.isGliding(gone))
    },
    test("a new press, a session starting, a commit that touches it, or another board shown ends a glide where the shape is") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), CorralsPlugin(), PocketsPlugin(), dragPlugin()])
        let a = square(h, at: CGPoint(x: 100, y: 100))
        let pocket = h.add(Pocket(CGRect(x: 600, y: 600, width: 50, height: 50)))
        h.editor.glide([a: CGPoint(x: 10, y: 0)])
        h.press(at: CGPoint(x: 400, y: 400))
        h.release()
        expectEqual(h.editor.drawingOffset(of: a), .zero)
        expect(!h.editor.isGliding(a))
        h.editor.glide([a: CGPoint(x: 10, y: 0)])
        h.editor.session = IdleSession()
        expect(!h.editor.isGliding(a))
        h.editor.session = nil
        h.editor.glide([a: CGPoint(x: 10, y: 0)])
        h.editor.transact { $0.update(pocket) { $0.box?.origin = .zero } }
        expect(h.editor.isGliding(a), "a commit that doesn't touch it")
        h.editor.transact { $0.update(a) { $0.box?.origin = CGPoint(x: 101, y: 100) } }
        expect(!h.editor.isGliding(a))
        expectEqual(h.editor.drawingOffset(of: a), .zero)
        h.editor.glide([a: CGPoint(x: 10, y: 0)])
        h.enter(pocket)
        expect(!h.editor.isGliding(a))
        expectEqual(h.editor.drawingOffset(of: a), .zero)
    },
])

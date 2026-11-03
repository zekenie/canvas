import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import Connections
import CoreGraphics
import Foundation
import Geometry
import TestKit

// Two arrows joining one pair, both aimed at the shapes' centers, lie on one line and read as one arrow with a
// head at each end. So a new arrow aimed at both centers beside another of the pair is stored bent apart from it
// (offsets 0, +1, -1, +2, -2 times 34 along the chord from the lower id to the higher, negated for an arrow that
// runs the other way), whether a port's drag made it or a request did (`canvas draw`'s, a row's pick).

/// A's bottom dot: clear of the first arrow, which leaves by the right one.
let aBottomDot = CGPoint(x: 180, y: 292)

extension PortBoard {
    /// +1 when `from` is the lower id of the pair, else -1: the way the pair's chord runs against an arrow from `from`.
    func chord(from: ShapeID, to: ShapeID) -> CGFloat { from.rawValue.uuidString <= to.rawValue.uuidString ? 1 : -1 }

    /// Makes an arrow by request and inserts it, as the commit of an app writer does; its id.
    @discardableResult
    func put(_ request: ConnectionRequest) throws -> ShapeID {
        let made = try require(make(request))
        h.editor.transact("Add Arrow") { $0.insert(made) }
        return made.id
    }

    func bend(_ id: ShapeID) -> CGFloat? { arrow(id)?.props.bend }

    /// Which side of the chord from A's center to B's the arrow's middle is on: +1 or -1, 0 on it.
    func side(_ id: ShapeID) throws -> CGFloat {
        let middle = try require(h.editor.arrowGeometry(of: id)).middle
        let (from, to) = (boxA.center, boxB.center)
        let cross = (to.x - from.x) * (middle.y - from.y) - (to.y - from.y) * (middle.x - from.x)
        return abs(cross) < 1e-6 ? 0 : cross > 0 ? 1 : -1
    }

    /// Drags from B's top dot to A's center and releases.
    func connectBack(speed: CGFloat = fast) {
        h.move(to: boxB.center)
        h.move(to: CGPoint(x: 560, y: 68))
        h.press()
        h.drag(to: boxA.center, speed: speed)
        h.release()
    }
}

@MainActor let pairTests = Suite("Arrows of one pair", [
    test("arrows made by request between one pair take 0, +1, -1, +2, -2 times 34 along the chord from the lower id to the higher") {
        let board = try PortBoard()
        let s = board.chord(from: board.a, to: board.b)
        var bends: [CGFloat] = []
        for _ in 0..<5 {
            let id = try board.put(ConnectionRequest(from: board.a, to: board.b, channel: Wire.id))
            bends.append(try require(board.bend(id)))
        }
        expectEqual(bends, [0, 34 * s, -34 * s, 68 * s, -68 * s])
    },
    test("an arrow the other way is negated, so it bows to the side the formula says whichever way it runs") {
        let board = try PortBoard()
        let s = board.chord(from: board.a, to: board.b)
        let first = try board.put(ConnectionRequest(from: board.a, to: board.b, channel: Wire.id))
        let back = try board.put(ConnectionRequest(from: board.b, to: board.a, channel: Wire.id))
        let third = try board.put(ConnectionRequest(from: board.a, to: board.b, channel: Wire.id))
        let fourth = try board.put(ConnectionRequest(from: board.b, to: board.a, channel: Wire.id))
        expectEqual(board.bend(first), 0)
        expectEqual(board.bend(back), -34 * s)
        expectEqual(board.bend(third), -34 * s)
        expectEqual(board.bend(fourth), -68 * s)
        // Two arrows of a pair read as two: the second's middle is off the first's line, and the third's is on the other side.
        expectEqual(try board.side(first), 0)
        let (one, two) = (try board.side(back), try board.side(third))
        expect(one != 0 && two != 0 && one != two, "the second and third arrows bow to opposite sides of the chord: \(one) \(two)")
        expectEqual(try board.side(fourth), one)
    },
    test("a pair's first arrow, and an arrow of another pair, are unbent") {
        let board = try PortBoard()
        let first = try board.put(ConnectionRequest(from: board.a, to: board.b, channel: Wire.id))
        let other = try board.put(ConnectionRequest(from: board.a, to: board.c))
        _ = try board.put(ConnectionRequest(from: board.a, to: board.b, channel: Wire.id))
        expectEqual(board.bend(first), 0)
        expectEqual(board.bend(other), 0)
    },
    test("an arrow with a side named, aimed precisely, is left as it is; so is one made again, straight or bent by the person") {
        let board = try PortBoard()
        try board.put(ConnectionRequest(from: board.a, to: board.b, channel: Wire.id))
        let sided = try board.put(ConnectionRequest(from: board.a, to: board.b, fromSide: .right, toSide: .left, channel: Wire.id))
        expectEqual(board.bend(sided), 0)
        let halfSided = try board.put(ConnectionRequest(from: board.a, to: board.b, fromSide: .right, channel: Wire.id))
        expectEqual(board.bend(halfSided), 0)
        let straight = try board.put(ConnectionRequest(from: board.a, to: board.b, channel: Wire.id))
        board.h.editor.transact("Straighten") { $0.update(straight, as: Arrow.self) { $0.props.bend = 0 } }
        let again = try require(board.make(ConnectionRequest(from: board.a, to: board.b, channel: Wire.id), existing: straight)?.typed(as: Arrow.self))
        expectEqual(again.props.bend, 0, "a straightened arrow stays straight: nothing re-separates a pair")
        board.h.editor.transact("Bend") { $0.update(straight, as: Arrow.self) { $0.props.bend = 55 } }
        let kept = try require(board.make(ConnectionRequest(from: board.a, to: board.b, channel: Wire.id), existing: straight)?.typed(as: Arrow.self))
        expectEqual(kept.props.bend, 55)
    },
    test("a request that names the arrows beside it is bent into the first offset none of them holds; none reads the board's") {
        let board = try PortBoard()
        let s = board.chord(from: board.a, to: board.b)
        var beside: [ShapeID] = []
        for bend in [0, 34, -34, 68, -68, 102] {
            let made = try require(board.madeArrow(ConnectionRequest(from: board.a, to: board.b, channel: Wire.id, beside: beside)))
            expectEqual(made.bend, CGFloat(bend) * s, "beside \(beside.count)")
            let id = try board.put(ConnectionRequest(from: board.a, to: board.b, channel: Wire.id))
            beside.append(id)
        }
        expectEqual(try require(board.madeArrow(ConnectionRequest(from: board.a, to: board.b, channel: Wire.id))).bend, -102 * s, "read from the board")
        expectEqual(try require(board.madeArrow(ConnectionRequest(from: board.b, to: board.a, channel: Wire.id, beside: []))).bend, 0, "told none")
    },
    test("after the first arrow of a pair is deleted, the next one made takes the freed offset, not one the arrow left holds") {
        let board = try PortBoard()
        let first = try board.put(ConnectionRequest(from: board.a, to: board.b, channel: Wire.id))
        let back = try board.put(ConnectionRequest(from: board.b, to: board.a, channel: Wire.id))
        board.h.editor.transact("Delete") { $0.delete([first]) }
        let again = try board.put(ConnectionRequest(from: board.a, to: board.b, channel: Wire.id))
        expectEqual(board.bend(again), 0, "the freed first offset")
        let (kept, made) = (try board.side(back), try board.side(again))
        expect(kept != made, "the two lie on one arc: \(kept) \(made)")
    },
    test("after the second of three arrows is deleted, the next one takes its offset, not the third's") {
        let board = try PortBoard()
        let s = board.chord(from: board.a, to: board.b)
        _ = try board.put(ConnectionRequest(from: board.a, to: board.b, channel: Wire.id))
        let second = try board.put(ConnectionRequest(from: board.a, to: board.b, channel: Wire.id))
        let third = try board.put(ConnectionRequest(from: board.a, to: board.b, channel: Wire.id))
        board.h.editor.transact("Delete") { $0.delete([second]) }
        let again = try board.put(ConnectionRequest(from: board.a, to: board.b, channel: Wire.id))
        expectEqual(board.bend(third), -34 * s)
        expectEqual(board.bend(again), 34 * s)
    },
    test("a request for a shape's arrow to itself is a loop, and each one more on its side goes round the last") {
        let board = try PortBoard()
        var bends: [CGFloat] = []
        for _ in 0..<3 {
            bends.append(try require(board.bend(try board.put(ConnectionRequest(from: board.a, to: board.a)))))
        }
        expectEqual(bends, [-64, -98, -132])
    },
    test("a re-aimed arrow is not bent again, and the arrows it leaves behind keep their bends") {
        let board = try PortBoard()
        let first = try board.put(ConnectionRequest(from: board.a, to: board.b, channel: Wire.id))
        let second = try board.put(ConnectionRequest(from: board.a, to: board.b, channel: Wire.id))
        let before = board.bend(second)
        board.reaim(first, from: boxB.center, to: boxD.center)
        expectEqual(board.bend(second), before)
        expectEqual(board.bend(first), 0)
    },
    test("a second port drag keeps its channel, and three drags of a pair each read apart") {
        let board = try PortBoard()
        board.connect(to: boxB.center)
        board.connect(from: aBottomDot, to: boxB.center)
        board.connect(from: CGPoint(x: 180, y: 68), to: boxB.center)
        let second = board.arrows[1]
        expectEqual(second[ChannelProperty.self], Wire.id)
        expectEqual(second.props.bend, 34 * board.chord(from: board.a, to: board.b))
        var middles: [CGPoint] = []
        for arrow in board.arrows { middles.append(try require(board.h.editor.arrowGeometry(of: arrow.id)).middle) }
        for i in 0..<middles.count {
            for j in (i + 1)..<middles.count {
                expect(abs(middles[i].y - middles[j].y) > 1, "arrows \(i) and \(j) lie on one arc")
            }
        }
    },
    test("two drags from a box to one pill bow apart") {
        let board = try PortBoard(more: [relaysPlugin()])
        let relay = board.addRelay(for: [board.b])
        board.connect(to: boxD.center)
        board.connect(from: CGPoint(x: 68, y: 180), to: boxD.center)
        let bends = board.arrows.map { $0.props.bend }
        expectEqual(board.arrows.count, 2)
        expect(board.arrows.allSatisfy { $0.props.end.binding?.shapeID == relay }, "both end at the pill")
        expect(bends[0] == 0 && bends[1] != 0, "the second drag to the pill is bent apart: \(bends)")
    },
    test("a second port drag between the same two shapes is bent apart from the first, and the first is untouched; one step, undone whole") {
        let board = try PortBoard()
        let s = board.chord(from: board.a, to: board.b)
        board.h.editor.replaceDocument(with: board.h.editor.document)
        board.connect(to: boxB.center)
        let first = try require(board.arrows.first)
        expectEqual(first.props.bend, 0)
        let afterFirst = board.h.editor.document
        board.connect(from: aBottomDot, to: boxB.center)
        expectEqual(board.arrows.count, 2)
        let second = try require(board.arrows.last)
        expectEqual(second.props.bend, 34 * s)
        expectEqual(board.arrow(first.id), first)
        expectEqual(board.h.editor.undoHistory.undoName, "Add Arrow")
        board.h.editor.undo()
        expectEqual(board.h.editor.document, afterFirst)
        board.h.editor.redo()
        expectEqual(board.arrow(second.id)?.props.bend, 34 * s)
    },
    test("a drag the other way, then the same way again, takes the next offsets") {
        let board = try PortBoard()
        let s = board.chord(from: board.a, to: board.b)
        board.connect(to: boxB.center)
        board.connectBack()
        board.connect(from: aBottomDot, to: boxB.center)
        expectEqual(board.arrows.map(\.props.bend), [0, -34 * s, -34 * s])
        expectEqual(board.arrows.map { $0.props.start.binding?.shapeID }, [board.a, board.b, board.a])
    },
    test("a second drag that ends precisely is left as drawn") {
        let board = try PortBoard()
        board.connect(to: boxB.center)
        board.connect(from: aBottomDot, to: CGPoint(x: 500, y: 120), speed: slow)
        let second = try require(board.arrows.last)
        expectEqual(second.props.end.binding?.isPrecise, true)
        expectEqual(second.props.bend, 0)
    },
])

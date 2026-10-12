@_spi(Host) import Canvas
import CanvasTesting
import Connections
import CoreGraphics
import Geometry
import Keyboard
import Selection
import TableOfContents
import TestKit

// Arrows made and changed without a drag, through the connector (`registry.connection`), as a
// command that connects shapes by name makes them: bound at both ends, each at the center or at the
// middle of the side it names; on the request's channel, set before the binding rules are asked;
// a change touching only what the request names. And a connection's ends are the shapes its
// arrow is bound to.

/// Every question the binding rules were asked: which end, of an arrow on which channel, bound to
/// which shape.
@MainActor final class RuleQuestions {
    var asked: [String] = []
}

/// A rule that allows everything, and notes what it's asked.
@MainActor func watchingRules(_ questions: RuleQuestions) -> Contributor {
    Contributor(id: "watching-rules") { registrar in
        registrar.arrowBindingRule { query in
            questions.asked.append("\(query.end) \(query.arrow[ChannelProperty.self]?.rawValue ?? "none") \(query.shape.id)")
            return true
        }
    }
}

extension PortBoard {
    var registry: Registry { h.editor.registry }

    /// What the connector makes (or makes of `existing`) for `request`, in the editor's document.
    func make(_ request: ConnectionRequest, existing: ShapeID? = nil) -> AnyShapeRecord? {
        registry.connection(request, existing: existing.flatMap { h.editor.document[$0] }, in: h.editor.shapeContext)
    }

    /// The arrow in what the connector makes.
    func madeArrow(_ request: ConnectionRequest, existing: ShapeID? = nil) -> Arrow? {
        make(request, existing: existing)?.typed(as: Arrow.self)?.props
    }
}

/// Something a plugin keeps about a shape (what Clipboard's copied-from is): where it came from.
enum Provenance {}

extension Provenance: ShapeMetaKey {
    typealias Value = String
    static var owner: PluginID { "provenance" }
    static var name: String { "from" }
}

/// Where a side's middle is, as a binding's anchor.
let sideMiddles: [(side: PortSide, anchor: CGPoint)] = [(.top, CGPoint(x: 0.5, y: 0)), (.right, CGPoint(x: 1, y: 0.5)),
                                                        (.bottom, CGPoint(x: 0.5, y: 1)), (.left, CGPoint(x: 0, y: 0.5))]

@MainActor let connectionMakingTests = Suite("Arrows made without a drag", [
    test("arrows are the connector's kind, and it makes them without a drag") {
        let board = try PortBoard()
        expectEqual(board.registry.connectorKind, Arrow.kind)
        expect(board.registry.makesConnections)
    },
    test("with no side named, an arrow is what a fast drag from a port draws: both ends at their shapes' centers, imprecisely") {
        let board = try PortBoard()
        let made = try require(board.make(ConnectionRequest(from: board.a, to: board.b, channel: Wire.id)))
        expectEqual(made.kind, Arrow.kind)
        expect(board.h.editor.document[made.id] == nil, "not inserted")
        board.connect(to: boxB.center)
        let dragged = try require(board.arrows.first)
        expectEqual(made.typed(as: Arrow.self)?.props, dragged.props)
        expectEqual(made[ChannelProperty.self], dragged[ChannelProperty.self])
        expectEqual(made[ChannelProperty.self], Wire.id)
    },
    test("a side named aims its end at that side's middle, precisely but not exactly; the other end stays at its center") {
        let board = try PortBoard()
        for (side, anchor) in sideMiddles {
            let from = try require(board.madeArrow(ConnectionRequest(from: board.a, to: board.b, fromSide: side, channel: Wire.id)), "\(side)")
            expectEqual(from.start, binding(board.a, anchor, precise: true), "from \(side)")
            expectEqual(from.end, binding(board.b), "from \(side)")
            let to = try require(board.madeArrow(ConnectionRequest(from: board.a, to: board.b, toSide: side, channel: Wire.id)), "\(side)")
            expectEqual(to.start, binding(board.a), "to \(side)")
            expectEqual(to.end, binding(board.b, anchor, precise: true), "to \(side)")
        }
        let both = try require(board.madeArrow(ConnectionRequest(from: board.a, to: board.b, fromSide: .right, toSide: .left)))
        expectEqual(both.start, binding(board.a, CGPoint(x: 1, y: 0.5), precise: true))
        expectEqual(both.end, binding(board.b, CGPoint(x: 0, y: 0.5), precise: true))
        expectEqual(both.bend, 0)
    },
    test("a head at the end, and at the start too when both are asked for") {
        let board = try PortBoard()
        let one = try require(board.madeArrow(ConnectionRequest(from: board.a, to: board.b)))
        expect(!one.startArrowhead && one.endArrowhead)
        let two = try require(board.madeArrow(ConnectionRequest(from: board.a, to: board.b, bothHeads: true)))
        expect(two.startArrowhead && two.endArrowhead)
    },
    test("with no channel, it's a plain arrow, which binds wherever an arrow can") {
        let board = try PortBoard()
        let made = try require(board.make(ConnectionRequest(from: board.a, to: board.c)))
        expectEqual(made[ChannelProperty.self], nil)
        expectEqual(made.typed(as: Arrow.self)?.props.end, binding(board.c))
    },
    test("the binding rules are asked of each end with the channel already set, and a refusal makes nothing") {
        let board = try PortBoard()
        expectEqual(board.make(ConnectionRequest(from: board.a, to: board.c, channel: Wire.id)), nil, "the disc doesn't take the wire")
        expectEqual(board.make(ConnectionRequest(from: board.c, to: board.a, channel: Pipe.id)), nil, "the box doesn't take the pipe")
        expectEqual(board.make(ConnectionRequest(from: board.a, to: board.b, channel: Pipe.id)), nil, "the box can't start one on it")
        let targets = try PortBoard(more: [morePorts(Disc.self, on: Wire.self, role: .target)])
        expect(targets.make(ConnectionRequest(from: targets.a, to: targets.c, channel: Wire.id)) != nil, "a disc that takes the wire")
        expectEqual(targets.make(ConnectionRequest(from: targets.c, to: targets.a, channel: Wire.id)), nil, "but can't start one on it")

        let questions = RuleQuestions()
        let watched = try PortBoard(more: [watchingRules(questions)])
        _ = try require(watched.make(ConnectionRequest(from: watched.a, to: watched.b, channel: Wire.id)))
        expectEqual(questions.asked, ["start wire \(watched.a)", "end wire \(watched.b)"])
    },
    test("an arrow joins only shapes an arrow can bind to, in the document it's given") {
        let board = try PortBoard()
        let arrow = board.addArrow(channel: nil)
        let tag = board.h.add(Tag(target: board.a))
        expectEqual(board.make(ConnectionRequest(from: board.a, to: arrow)), nil, "an arrow")
        expectEqual(board.make(ConnectionRequest(from: tag, to: board.b)), nil, "a shape with no inside")
        expectEqual(board.make(ConnectionRequest(from: board.a, to: ShapeID())), nil, "a shape not on the board")
        expect(!board.h.editor.canBindArrow(to: arrow) && !board.h.editor.shapeContext.canBindArrow(to: arrow))
        expect(board.h.editor.canBindArrow(to: board.a) && board.h.editor.shapeContext.canBindArrow(to: board.a))

        let drawn = ShapeRecord(Box(boxD))
        var bindsInTransaction = false, bindsInEditor = true, outside: AnyShapeRecord?
        board.h.editor.transact { transaction in
            transaction.insert(drawn)
            bindsInTransaction = transaction.shapes.canBindArrow(to: drawn.id)
            bindsInEditor = board.h.editor.canBindArrow(to: drawn.id)
            outside = board.make(ConnectionRequest(from: board.a, to: drawn.id, channel: Wire.id))
            let request = ConnectionRequest(from: board.a, to: drawn.id, toSide: .top, channel: Wire.id)
            if let made = board.registry.connection(request, in: transaction.shapes) { transaction.insert(made) }
        }
        expect(bindsInTransaction && !bindsInEditor)
        expectEqual(outside, nil, "the editor's document hasn't the new box yet")
        let made = try require(board.arrows.last)
        expectEqual(made.props.end, binding(drawn.id, CGPoint(x: 0.5, y: 0), precise: true))
        expectEqual(made[ChannelProperty.self], Wire.id)
    },
    test("an arrow from a shape to itself moves the end off an anchor the start has, as a dragged end does, inward from the right side") {
        let board = try PortBoard()
        let centered = try require(board.madeArrow(ConnectionRequest(from: board.a, to: board.a, channel: Wire.id)))
        expectEqual(centered.start, binding(board.a))
        expectEqual(centered.end, binding(board.a, CGPoint(x: 0.55, y: 0.5)))
        let right = try require(board.madeArrow(ConnectionRequest(from: board.a, to: board.a, fromSide: .right, toSide: .right)))
        expectEqual(right.start, binding(board.a, CGPoint(x: 1, y: 0.5), precise: true))
        expectEqual(right.end, binding(board.a, CGPoint(x: 0.95, y: 0.5), precise: true), "past the side it would be held to it, where the start is")
        let left = try require(board.madeArrow(ConnectionRequest(from: board.a, to: board.a, fromSide: .left, toSide: .left)))
        expectEqual(left.end, binding(board.a, CGPoint(x: 0.05, y: 0.5), precise: true))
        let across = try require(board.madeArrow(ConnectionRequest(from: board.a, to: board.a, fromSide: .left, toSide: .right)))
        expectEqual(across.start, binding(board.a, CGPoint(x: 0, y: 0.5), precise: true))
        expectEqual(across.end, binding(board.a, CGPoint(x: 1, y: 0.5), precise: true))
        // Each draws something: a body with length, not a point.
        for (from, to) in [(nil, nil), (PortSide.right, PortSide.right), (.left, .left), (.top, .top), (.bottom, .bottom)] as [(PortSide?, PortSide?)] {
            let made = try require(board.make(ConnectionRequest(from: board.a, to: board.a, fromSide: from, toSide: to)))
            board.h.editor.transact { $0.insert(made) }
            let body = try require(board.h.editor.shapeContext.geometry(of: made.id)?.bounds)
            expect(max(body.width, body.height) > 5, "from \(from.map { "\($0)" } ?? "center") to \(to.map { "\($0)" } ?? "center"): \(body)")
        }
    },
    test("changed without a drag, an arrow keeps its id, its unnamed ends, its curve and its channel; its heads follow the request") {
        let board = try PortBoard()
        let d = board.h.add(Box(boxD))
        var record = ShapeRecord(Arrow(start: binding(board.a, CGPoint(x: 0.3, y: 0.2), precise: true), end: binding(board.b), bend: 40,
                                       startArrowhead: true))
        record[ChannelProperty.self] = Wire.id
        board.h.editor.transact { $0.insert(record) }
        let existing = try require(board.h.editor.document[record.id])

        let aimed = try require(board.make(ConnectionRequest(from: board.a, to: board.b, toSide: .left, channel: Pipe.id), existing: record.id))
        expectEqual(aimed.id, record.id)
        let arrow = try require(aimed.typed(as: Arrow.self)?.props)
        expectEqual(arrow.start, binding(board.a, CGPoint(x: 0.3, y: 0.2), precise: true), "unnamed: kept")
        expectEqual(arrow.end, binding(board.b, CGPoint(x: 0, y: 0.5), precise: true))
        expectEqual(arrow.bend, 40)
        expect(!arrow.startArrowhead && arrow.endArrowhead)
        expectEqual(aimed[ChannelProperty.self], Wire.id, "the channel's kept")

        let moved = try require(board.madeArrow(ConnectionRequest(from: board.a, to: d, bothHeads: true), existing: record.id))
        expectEqual(moved.start, binding(board.a, CGPoint(x: 0.3, y: 0.2), precise: true))
        expectEqual(moved.end, binding(d), "a new shape: bound anew, at its center")

        let same = try require(board.make(ConnectionRequest(from: board.a, to: board.b, bothHeads: true), existing: record.id))
        expectEqual(same, existing, "nothing to change: the arrow as it is")
        expectEqual(board.make(ConnectionRequest(from: board.a, to: board.c), existing: record.id), nil, "the disc doesn't take its wire")

        board.h.editor.transact { $0.update(record.id) { $0 = aimed } }
        let updated = try require(board.arrow(record.id))
        expectEqual(updated.props, arrow)
        expectEqual(board.h.editor.document[record.id]?.stackingKey, existing.stackingKey)
    },
    test("changed without a drag, an arrow keeps what plugins keep about it and its other added values; unchanged, it's itself") {
        let board = try PortBoard(more: [FreezingPlugin()])
        var record = AnyShapeRecord(ShapeRecord(Arrow(start: binding(board.a), end: binding(board.b))))
        record[ChannelProperty.self] = Wire.id
        record[Frozen.self] = true
        record.meta[Provenance.self] = "pasted"
        board.h.editor.transact { $0.insert(record) }
        let existing = try require(board.h.editor.document[record.id])
        expectEqual(existing.meta[Provenance.self], "pasted")
        let aimed = try require(board.make(ConnectionRequest(from: board.a, to: board.b, toSide: .left), existing: record.id))
        expectEqual(aimed.meta, existing.meta, "what plugins keep about it")
        expectEqual(aimed[Frozen.self], true, "an added value")
        expectEqual(aimed[ChannelProperty.self], Wire.id)
        let same = try require(board.make(ConnectionRequest(from: board.a, to: board.b), existing: record.id))
        expectEqual(same, existing, "nothing to change, metadata and all: the arrow as it is")
    },
    test("a connection's ends are the shapes its arrow is bound to, start first; none with an end free, or for a shape that isn't one") {
        let board = try PortBoard()
        let arrow = board.addArrow(channel: Wire.id)
        let ends = try require(board.registry.connectionEnds(of: try require(board.h.editor.document[arrow])))
        expectEqual([ends.from, ends.to], [board.a, board.b])
        let loose = board.h.add(Arrow(start: binding(board.a), end: .free(CGPoint(x: 400, y: 500))))
        expect(board.registry.connectionEnds(of: try require(board.h.editor.document[loose])) == nil)
        expect(board.registry.connectionEnds(of: try require(board.h.editor.document[board.a])) == nil)
    },
    test("whether an end may bind is every rule's say, as when it binds by pointer; with no rules, yes") {
        let board = try PortBoard()
        let ids = (wired: board.addArrow(channel: Wire.id), plain: board.addArrow(channel: nil))
        let wired = try require(board.h.editor.document[ids.wired]), plain = try require(board.h.editor.document[ids.plain])
        let b = try require(board.h.editor.document[board.b]), c = try require(board.h.editor.document[board.c])
        expect(board.registry.arrowMayBind(wired, .end, to: b))
        expect(!board.registry.arrowMayBind(wired, .end, to: c), "the disc doesn't take the wire")
        expect(board.registry.arrowMayBind(plain, .end, to: c))
        let noRules = try Registry(plugins: PortBoard.plugins().filter { ![PluginID.ports, .arrowPorts, "channels"].contains($0.id) })
        expect(noRules.arrowMayBind(wired, .end, to: c))
    },
])

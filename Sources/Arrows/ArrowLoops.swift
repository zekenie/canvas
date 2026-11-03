import Canvas
import Connections
import CoreGraphics
import Foundation
import Geometry

/// An arrow from a shape to itself is a loop on one of its sides: it leaves the side and comes back into it, bowed out past
/// it, so it reads as a loop and never as a line across the shape. tldraw keeps an arrow bound to one shape at both ends and
/// draws it between its two anchors (`getBoundShapeRelationships`' double-bound: both taken as precise), clipped where it
/// crosses the outline; with both anchors on one side and a bend out past it, that is this loop. Its anchors and its bend
/// are stored, tldraw's own properties, so geometry stays a pure function of the arrow and a person reshapes it as any
/// arrow (its ends, its bend). Where its anchors go and how far it bows are this app's: a port's drag let go on the shape it
/// starts from, Connect on one shape and `canvas draw`'s `edge "A" -> "A"` all make it here.
extension ArrowStyle {
    /// How far a loop reaches out at its middle, in world units, past the line between its ends (its side, on a box; a
    /// little inside a round side, where its ends are on the outline).
    static let loopReach: CGFloat = 64
    /// Half the length of side between where a loop leaves it and where it comes back, in world units.
    static let loopHalfSpan: CGFloat = 28
    /// What each loop further out on one side adds to the one inside it, so they nest: to its reach and to its half span.
    static let loopReachStep: CGFloat = 34
    static let loopHalfSpanStep: CGFloat = 14
    /// The most of its side's length a loop's half span takes, so its ends stay clear of the corners.
    static let loopHalfSpanShare: CGFloat = 0.4
}

/// An arrow from a shape to itself, as a loop: where it leaves the shape, where it comes back, and how far it bows.
struct ArrowLoop: Equatable {
    var start: ArrowBinding
    var end: ArrowBinding
    var bend: CGFloat
}

extension ArrowConnections {
    /// The loop on `side` of `shape`, in the first slot of that side none of the loops `beside` holds (`loopSlot(of:on:)`),
    /// so a second loop on a side goes round the first. It goes clockwise round the shape: it leaves its side where its span
    /// begins going round (the top of the right side, the right of the bottom) and comes back where it ends, its head
    /// pointing in. Its anchors are on the outline (a pill's round end is short of its bounds), measured in its bounds.
    static func loop(on shape: ConnectableShape, side: PortSide, beside: [ShapeID], in document: CanvasDocument) -> ArrowLoop {
        let bounds = shape.bounds
        let slot = freeLoopSlot(on: shape.id, side: side, beside: beside, in: document)
        let length = side == .left || side == .right ? bounds.height : bounds.width
        let half = min(ArrowStyle.loopHalfSpan + CGFloat(slot) * ArrowStyle.loopHalfSpanStep, length * ArrowStyle.loopHalfSpanShare)
        let along = length > 0 ? half / length : 0
        // Clockwise round the shape: along the side from where the span begins to where it ends.
        let (leave, back): (CGFloat, CGFloat) = side == .right || side == .top ? (0.5 - along, 0.5 + along) : (0.5 + along, 0.5 - along)
        let start = outlineAnchor(of: shape, side: side, at: leave), end = outlineAnchor(of: shape, side: side, at: back)
        // A bend is along the chord's perpendicular (`ArrowGeometry.bendAxis`): its sign puts the loop's middle outside.
        let chord = CGPoint(x: (end.x - start.x) * bounds.width, y: (end.y - start.y) * bounds.height)
        let axis = chord.length > 0 ? chord.normalized.perpendicular : CGPoint(x: 0, y: -1)
        let reach = ArrowStyle.loopReach + CGFloat(slot) * ArrowStyle.loopReachStep
        let bend = axis.dot(outward(from: side)) < 0 ? -reach : reach
        return ArrowLoop(start: ArrowBinding(shapeID: shape.id, normalizedAnchor: start, isPrecise: true, isExact: false),
                         end: ArrowBinding(shapeID: shape.id, normalizedAnchor: end, isPrecise: true, isExact: false), bend: bend)
    }

    /// The side a loop of `shape` is on and its slot there, from what the arrow stores: bound to `shape` at both ends, its start
    /// on that side's half of its bounds, its chord running clockwise along the side (down the right, left along the bottom),
    /// and bowed out by a slot's reach. Nil for any other arrow, and for a loop a person has reshaped out of that (its ends
    /// swapped, its bend changed), which holds no slot; one with an end only slid along its side keeps its own.
    static func loopSlot(of arrow: Arrow, on shape: ShapeID) -> (side: PortSide, slot: Int)? {
        guard let start = arrow.start.binding, let end = arrow.end.binding, start.shapeID == shape, end.shapeID == shape else { return nil }
        let chord = end.normalizedAnchor - start.normalizedAnchor
        guard chord != .zero else { return nil }
        let side: PortSide = abs(chord.y) >= abs(chord.x) ? (chord.y > 0 ? .right : .left) : (chord.x > 0 ? .top : .bottom)
        let across = side == .left || side == .right ? start.normalizedAnchor.x : start.normalizedAnchor.y
        guard side == .right || side == .bottom ? across > 0.5 : across < 0.5 else { return nil }
        let steps = (-arrow.bend - ArrowStyle.loopReach) / ArrowStyle.loopReachStep
        guard steps >= 0, steps == steps.rounded(), steps < 1_000 else { return nil }
        return (side, Int(steps))
    }

    /// The lowest slot of `side` none of the loops of `beside` holds: after a delete the next loop takes the slot it freed.
    private static func freeLoopSlot(on shape: ShapeID, side: PortSide, beside: [ShapeID], in document: CanvasDocument) -> Int {
        var held: Set<Int> = []
        for id in beside {
            guard let arrow = document[id]?.typed(as: Arrow.self)?.props, let loop = loopSlot(of: arrow, on: shape), loop.side == side else { continue }
            held.insert(loop.slot)
        }
        return (0...held.count).first { !held.contains($0) } ?? 0
    }

    /// Where `side` of the outline is, `along` its bounds (0 at the top or the left, 1 at the bottom or the right), as an
    /// anchor in its bounds: the outermost crossing of the outline that way, else the bounds' own side.
    private static func outlineAnchor(of shape: ConnectableShape, side: PortSide, at along: CGFloat) -> CGPoint {
        let bounds = shape.bounds
        let onSide: CGPoint = switch side {
        case .top: CGPoint(x: along, y: 0)
        case .right: CGPoint(x: 1, y: along)
        case .bottom: CGPoint(x: along, y: 1)
        case .left: CGPoint(x: 0, y: along)
        }
        guard bounds.width > 0, bounds.height > 0 else { return onSide }
        // From past the far side to past this one: the last crossing is the outermost on this side.
        let point = CGPoint(x: bounds.minX + onSide.x * bounds.width, y: bounds.minY + onSide.y * bounds.height)
        let out = outward(from: side), span = bounds.width + bounds.height + 2
        let from = point - out * span, to = point + out
        guard let t = intersections(ofSegmentFrom: from, to: to, withPolygon: shape.outline).max() else { return onSide }
        let crossing = from + (to - from) * t
        let anchor = CGPoint(x: (crossing.x - bounds.minX) / bounds.width, y: (crossing.y - bounds.minY) / bounds.height)
        // Across the side, where the outline is (the side itself where the outline runs along it, as a box's does); along it,
        // exactly where asked.
        let across = side == .left || side == .right ? (anchor.x, onSide.x) : (anchor.y, onSide.y)
        let at = abs(across.0 - across.1) < 1e-6 ? across.1 : across.0
        return side == .left || side == .right ? CGPoint(x: at, y: onSide.y) : CGPoint(x: onSide.x, y: at)
    }

    /// The way out of a shape through `side`.
    private static func outward(from side: PortSide) -> CGPoint {
        switch side {
        case .top: CGPoint(x: 0, y: -1)
        case .right: CGPoint(x: 1, y: 0)
        case .bottom: CGPoint(x: 0, y: 1)
        case .left: CGPoint(x: -1, y: 0)
        }
    }
}

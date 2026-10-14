import Canvas
import CoreGraphics
import Foundation
import Topology

/// Two arrows joining one pair of shapes, both aimed at the shapes' centers, lie on one line and read as one
/// arrow with a head at each end. So the second arrow made between a pair, with imprecise ends, is stored
/// bent apart from the first: the bend is the arrow's own property (tldraw's), and geometry stays a pure
/// function of the arrow. A person who straightens one puts the pair back on one line; nothing re-separates it.
extension ArrowStyle {
    /// How far the second arrow of a pair bows at its middle, in world units.
    static let pairBend: CGFloat = 34
}

extension ArrowConnections {
    /// The arrows already joining `a` and `b`, either way, but not `except`: one read of the connections
    /// of `a`, at a gesture, never in a frame.
    static func parallels(of a: ShapeID, _ b: ShapeID, except: ShapeID?, in topology: TopologyIndex) -> [ShapeID] {
        topology.edges(of: a, .either, types: .within(ArrowEdge.id), view: .literal).compactMap { edge in
            edge.isConnection && edge.carrier != except
                && (edge.source == a && edge.target == b || edge.source == b && edge.target == a) ? edge.carrier : nil
        }
    }

    /// Slots of a pair, in the order they are taken: 0, +1, -1, +2, -2 ... times `ArrowStyle.pairBend`, along
    /// the chord from the lower id to the higher.
    private static func steps(ofSlot k: Int) -> Int { k.isMultiple(of: 2) ? -(k / 2) : (k + 1) / 2 }

    private static func slot(ofSteps steps: Int) -> Int { steps > 0 ? 2 * steps - 1 : -2 * steps }

    private static func runsForward(from: ShapeID, to: ShapeID) -> Bool { from.rawValue.uuidString <= to.rawValue.uuidString }

    /// The stored bend of the arrow in slot `k` of a pair (0 the first), negated for an arrow that runs the
    /// other way: two arrows of a pair bow apart whichever way each runs.
    static func pairBend(index k: Int, from: ShapeID, to: ShapeID) -> CGFloat {
        guard k > 0 else { return 0 }
        let steps = steps(ofSlot: k)
        return CGFloat(runsForward(from: from, to: to) ? steps : -steps) * ArrowStyle.pairBend
    }

    /// The lowest slot of a pair no arrow of `beside` holds: an arrow holds the slot its stored bend is (a
    /// straight one holds the first), so after a delete the next arrow takes the freed slot, never one a
    /// surviving arrow bows through. An arrow bent some other way, or not an arrow, holds none.
    static func freeSlot(beside: [ShapeID], in document: CanvasDocument) -> Int {
        var held: Set<Int> = []
        for id in beside {
            guard let arrow = document[id]?.typed(as: Arrow.self), let start = arrow.props.start.binding,
                  let end = arrow.props.end.binding else { continue }
            let ratio = arrow.props.bend / ArrowStyle.pairBend
            guard ratio == ratio.rounded(), abs(ratio) < 1_000 else { continue }
            let steps = Int(ratio) * (runsForward(from: start.shapeID, to: end.shapeID) ? 1 : -1)
            held.insert(slot(ofSteps: steps))
        }
        return (0...held.count).first { !held.contains($0) } ?? 0
    }

    /// The bend an arrow bound at both ends takes beside the arrows `beside` that already join its pair: 0
    /// unless both ends are imprecise and it is straight.
    static func pairBend(of arrow: Arrow, beside: [ShapeID], in document: CanvasDocument) -> CGFloat {
        guard arrow.bend == 0, let start = arrow.start.binding, let end = arrow.end.binding,
              !start.isPrecise, !end.isPrecise else { return 0 }
        return pairBend(index: freeSlot(beside: beside, in: document), from: start.shapeID, to: end.shapeID)
    }
}

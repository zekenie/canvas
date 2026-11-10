import Canvas
import CoreGraphics
import Geometry
import Selection
import Topology

// A shape's arrows as its parts (Selection's `ShapeParts`): from a selected shape, ⌥Tab walks the
// connections bound to it and Return selects one, so an arrow is reached without being a Tab stop. The
// connector's kind is read from the registry, never named; its edges come from Topology.

extension CanvasEditor {
    /// The connections bound to `id`, as parts: outgoing ones first, then incoming, each titled by the
    /// shape at its other end ("Arrow to Payment", "Arrow from Cart"), or the row there ("Arrow to id in customers"), at the segment where it leaves
    /// `id`, the whole arrow lit while it has the focus (`lights`). Pressing one selects the arrow. Selection puts the whole list in reading order of the rects.
    func connectionParts(of id: ShapeID) -> [ShapePart] {
        guard registry.makesConnections, let kind = registry.connectorKind, let topology else { return [] }
        let context = shapeContext
        let own = context.geometry(of: id)?.bounds
        var outgoing: [(part: ShapePart, other: CGPoint)] = [], incoming: [(part: ShapePart, other: CGPoint)] = []
        var seen = Set<ShapeID>()
        for edge in topology.edges(of: id, .either, view: .literal) where edge.isConnection {
            guard document[edge.carrier]?.kind == kind, seen.insert(edge.carrier).inserted else { continue }
            let leaves = edge.source == id
            let otherID = leaves ? edge.target : edge.source
            // A bundle's member is its lead's: the lead is listed once, for all of them.
            guard let geometry = context.geometry(of: edge.carrier), !geometry.outline.isEmpty, !geometry.isHidden else { continue }
            let other = context.geometry(of: otherID)?.bounds
            let near = leavingSegment(of: geometry.outline, from: leaves, around: own)
            // A row at the far end by the row's name, read with its shape's ("Arrow to id in customers").
            // A bundle's lead draws for several from the fold's line that stands for their rows: it says the count, and names that line
            // where the far end is the shape folded (a row the fold hides isn't one a person sees).
            var count = 1, otherPart = edge.otherPart(from: id, leaves ? .outgoing : .incoming)
            if case .lead(let bundled, let standing)? = connectionBundle(of: edge.carrier)?.role {
                count = bundled
                if let standing, standing.shape == otherID { otherPart = standing.part }
            }
            let name = accessibleName(readingThrough: PartAddress(otherID, part: otherPart)) ?? accessibleDescription(of: otherID)?.name
                ?? registry.label(of: document[otherID]?.kind ?? kind).name
            let carrier = edge.carrier
            // A bundle's lead selects its bundle whole, as a click on it does.
            let unit = selectionUnit(of: carrier)
            let part = ShapePart(id: carrier, title: (count > 1 ? (leaves ? ConnectionsStyle.arrowsTo(count) : ConnectionsStyle.arrowsFrom(count))
                                    : (leaves ? ConnectionsStyle.arrowTo : ConnectionsStyle.arrowFrom)) + name,
                                 role: .connection, rect: near.insetBy(dx: -ConnectionsStyle.partPad / camera.zoom, dy: -ConnectionsStyle.partPad / camera.zoom),
                                 lights: [carrier]) { editor in
                editor.selectedShapeIDs = unit
            }
            let middle = other.map { CGPoint(x: $0.midX, y: $0.midY) } ?? CGPoint(x: near.midX, y: near.midY)
            if leaves { outgoing.append((part, middle)) } else { incoming.append((part, middle)) }
        }
        func byPosition(_ list: [(part: ShapePart, other: CGPoint)]) -> [ShapePart] {
            list.sorted { ($0.other.y, $0.other.x) < ($1.other.y, $1.other.x) }.map(\.part)
        }
        return byPosition(outgoing) + byPosition(incoming)
    }

    /// The stretch of `outline` just outside `shape` at the end the arrow leaves it from (its start when
    /// `fromStart`, else its end): where the outline crosses out of the shape's bounds, when it begins
    /// inside them; else (an arrow's own outline begins at the shape's edge, or its standoff) the first
    /// `ConnectionsStyle.partLength` view points of it from that end, or all of it when it is shorter. Never
    /// the whole arrow: a long one's ring would cover the board.
    private func leavingSegment(of outline: [CGPoint], from fromStart: Bool, around shape: CGRect?) -> CGRect {
        let points = fromStart ? outline : outline.reversed()
        guard points.count > 1 else { return CGRect(origin: points[0], size: .zero) }
        if let shape, !shape.isNull, shape.contains(points[0]), let out = points.firstIndex(where: { !shape.contains($0) }), out > 0 {
            return CGRect(enclosing: [points[out - 1], points[out]])
        }
        var left = ConnectionsStyle.partLength / camera.zoom
        var reached = [points[0]]
        for index in 1..<points.count {
            let from = reached[reached.count - 1], to = points[index]
            let length = hypot(to.x - from.x, to.y - from.y)
            if length >= left {
                let t = length > 0 ? left / length : 0
                reached.append(CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
                break
            }
            reached.append(to)
            left -= length
        }
        return CGRect(enclosing: reached)
    }
}

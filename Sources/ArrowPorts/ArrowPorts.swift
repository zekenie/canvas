import Arrows
import Canvas
import CoreGraphics
import Ports
import Topology

extension PluginID {
    public static let arrowPorts: PluginID = "arrow-ports"
}

/// The family of edges arrows drawn between shapes are: a plain arrow's type, and every channel's
/// parent. Its id is the arrow kind's name, `arrow`, taken from the kind rather than written again:
/// the build's id audit gives a string one owner to depend on, and that's Arrows.
public enum ArrowEdge {}

extension ArrowEdge: EdgeType {
    public static let id = EdgeTypeID(rawValue: Arrow.kind.rawValue)
}

/// Arrows are what ports draw, though neither plugin has heard of the other: a drag from a port
/// draws an arrow, its end binding (by tldraw's rules, as the arrow tool's does) only to shapes that
/// take one of the port's channels, and an arrow so drawn keeps its channel (`ChannelProperty`).
/// Released on nothing, nothing is drawn. An arrow with a channel, re-aimed or moved, binds only to
/// shapes that take its channel, at that end; one without (the arrow tool's), or with a channel no
/// installed plugin declares, binds wherever an arrow can. Without a drag (`registry.connection`),
/// an arrow is made bound at both ends (`ArrowConnections`), and its ends are the shapes it's bound
/// to. An arrow bound at both ends is an edge (Topology's) of the `arrow` family, or of its
/// channel's type, under it.
public struct ArrowPortsPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { .arrowPorts }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.connects(Arrow.self, edgeType: ArrowEdge.self, canConnect: { id, shapes in shapes.canBindArrow(to: id) },
                           make: { request, existing, shapes in ArrowConnections.arrow(for: request, existing: existing, in: shapes) },
                           ends: { ArrowConnections.ends(of: $0) }) { connection, editor in
            editor.beginArrow(from: connection.shape, at: connection.origin,
                              canBind: { editor.channel(of: connection, endingAt: $0) != nil },
                              complete: { arrow, end in
                                  guard let shape = editor.document[end] else { return }
                                  arrow[ChannelProperty.self] = editor.channel(of: connection, endingAt: shape)
                              })
        }
        registrar.arrowBindingRule { query in
            guard let channel = query.arrow[ChannelProperty.self], query.registry.declares(channel) else { return true }
            return query.registry.accepts(query.shape, on: channel, as: query.end == .start ? .source : .target)
        }
    }
}

/// Arrows made without a drag, as a connection request says: bound at both ends, each aimed at the
/// middle of the side it names (precise, not exact, so it stops at the outline with its head's gap,
/// as an end the arrow tool binds slowly does) or, with none, at the shape's center (imprecise, as
/// a port's drag starts one). Where a named side faces away from the other shape, the arrow still
/// leaves from the side facing it: an end is clipped where the line first crosses the outline
/// (tldraw's).
@MainActor
enum ArrowConnections {
    /// A new arrow (`existing` nil) or `existing` changed: an end the request names a side for, or
    /// whose shape isn't the one it's bound to, is bound anew; any other end keeps its binding; its
    /// heads are the request's (one at the end, and at the start too with `bothHeads`); and a
    /// changed arrow keeps its curve, its channel and everything plugins keep about it. A new one's
    /// channel is the request's, set before any rule is asked. Nil if an arrow can't bind to either
    /// shape in `shapes`, or a rule (`ArrowBindingRules`) won't let an end bind to its shape.
    static func arrow(for request: ConnectionRequest, existing: AnyShapeRecord?, in shapes: ShapeContext) -> AnyShapeRecord? {
        guard shapes.canBindArrow(to: request.from), shapes.canBindArrow(to: request.to),
              let from = shapes.shape(request.from), let to = shapes.shape(request.to) else { return nil }
        var arrow: ShapeRecord<Arrow>
        if let existing {
            guard let old = existing.typed(as: Arrow.self) else { return nil }
            arrow = old
        } else {
            arrow = ShapeRecord(Arrow(start: .free(.zero), end: .free(.zero)))
            // First, so the rules below see the channel the arrow is drawn on.
            arrow[ChannelProperty.self] = request.channel
        }
        var rebound: Set<ArrowEnd> = []
        for (end, shape, side) in [(ArrowEnd.start, request.from, request.fromSide), (.end, request.to, request.toSide)]
        where side != nil || arrow.props[end].binding?.shapeID != shape {
            arrow.props[end] = .bound(binding(to: shape, side: side))
            rebound.insert(end)
        }
        // Both ends on one shape at one anchor would draw nothing: an end bound here (the end, if
        // both were) moves off it, as the arrow tool moves the end it binds, but inward from a
        // right side (x = 1), past which it'd be held to the side and still meet the other end.
        if let start = arrow.props.start.binding, let end = arrow.props.end.binding, start.shapeID == end.shapeID,
           start.normalizedAnchor == end.normalizedAnchor, let moved = [ArrowEnd.end, .start].first(where: rebound.contains) {
            var binding = moved == .end ? end : start
            let nudge: CGFloat = 0.05
            binding.normalizedAnchor.x += binding.normalizedAnchor.x + nudge > 1 ? -nudge : nudge
            arrow.props[moved] = .bound(binding)
        }
        arrow.props.startArrowhead = request.bothHeads
        arrow.props.endArrowhead = true
        var made = AnyShapeRecord(arrow)
        if let existing { made.meta = existing.meta }
        let registry = shapes.registry
        guard registry.arrowMayBind(made, .start, to: from), registry.arrowMayBind(made, .end, to: to) else { return nil }
        return made
    }

    /// Where an end aims on `shape`: the middle of `side`, precisely; with none, the center.
    static func binding(to shape: ShapeID, side: PortSide?) -> ArrowBinding {
        guard let side else {
            return ArrowBinding(shapeID: shape, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false)
        }
        let anchor = switch side {
        case .top: CGPoint(x: 0.5, y: 0)
        case .right: CGPoint(x: 1, y: 0.5)
        case .bottom: CGPoint(x: 0.5, y: 1)
        case .left: CGPoint(x: 0, y: 0.5)
        }
        return ArrowBinding(shapeID: shape, normalizedAnchor: anchor, isPrecise: true, isExact: false)
    }

    /// The shapes an arrow's start and end are bound to; nil unless both are.
    static func ends(of record: AnyShapeRecord) -> (from: ShapeID, to: ShapeID)? {
        guard let arrow = record.typed(as: Arrow.self)?.props, let start = arrow.start.binding, let end = arrow.end.binding else { return nil }
        return (start.shapeID, end.shapeID)
    }
}

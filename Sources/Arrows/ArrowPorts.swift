import Canvas
import Connections
import CoreGraphics
import Topology
import Types

extension PluginID {
    public static let arrowPorts: PluginID = "arrow-ports"
}

/// The family of edges arrows drawn between shapes are: a plain arrow's type, and every channel's
/// parent. Its id is the arrow kind's name, `arrow`, taken from the kind rather than written again,
/// so the string is said once.
public enum ArrowEdge {}

extension ArrowEdge: EdgeType {
    public static let id = EdgeTypeID(rawValue: Arrow.kind.rawValue)
    public static let summary: String? = "an arrow bound at both ends, from the shape it starts on to the shape it ends on, whatever its arrowheads"
}

/// Arrows are what ports draw: a drag from a port draws an arrow, its end binding (by tldraw's
/// rules, as a re-aimed end does) only to shapes that take one of the port's channels, and an arrow
/// so drawn keeps its channel (`ChannelProperty`); onto a shape that stands for others (a reference),
/// only if what it stands for takes one (`PortState.ports(of:)`). Released on nothing, nothing is drawn; released on the
/// shape it starts from, it is a loop on the side of the dot it was pulled from (`ArrowConnections.loop`). An arrow
/// with a channel, re-aimed or moved, binds only to shapes that take its channel, at that end; one
/// without (`canvas draw`'s `channel: none`, a board's from before ports), or with a channel no
/// installed plugin declares, binds wherever an arrow can. Without a drag (`registry.connection`),
/// an arrow is made bound at both ends (`ArrowConnections`), and its ends are the shapes it's bound
/// to. An arrow bound at both ends is an edge (Topology's) of the `arrow` family, or of its
/// channel's type, under it. It's a plugin of its own, so a list can have arrows without ports (as
/// ArrowsTests do) or ports with a connector of its own (as PortsTests do).
public struct ArrowPortsPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .arrowPorts }

    public func register(into registrar: inout PluginRegistrar) {
        // A relationship's row in the table of contents is titled by its type; after Types, whose changes it hears.
        registrar.service { ArrowTypeRows(editor: $0) }
        registrar.connects(Arrow.self, edgeType: ArrowEdge.self, canConnect: { id, shapes in shapes.canBindArrow(to: id) },
                           make: { request, existing, shapes in ArrowConnections.arrow(for: request, existing: existing, in: shapes) },
                           ends: { ArrowConnections.ends(of: $0) }, parts: { ArrowConnections.parts(of: $0) }) { connection, editor in
            editor.beginArrow(from: connection.shape, part: connection.part, side: connection.side, at: connection.origin,
                              canBind: { editor.channel(of: connection, endingAt: $0) != nil },
                              // Onto a shape whose rows take the channel it'll be drawn on: the row under the end.
                              bindsPart: { shape in
                                  editor.channel(of: connection, endingAt: shape).map { editor.registry.takesOnParts(shape.kind, $0, as: .target) } ?? false
                              },
                              channelAt: { editor.channel(of: connection, endingAt: $0) },
                              complete: { arrow, end in
                                  guard let shape = editor.document[end] else { return }
                                  arrow[ChannelProperty.self] = editor.channel(of: connection, endingAt: shape)
                                  // A second arrow of a pair, aimed at the centers, is bent apart from the first (a loop is
                                  // precise at both ends, and kept as the drag made it).
                                  guard var typed = arrow.typed(as: Arrow.self), let topology = editor.topology,
                                        let start = typed.props.start.binding, let finish = typed.props.end.binding else { return }
                                  let beside = ArrowConnections.parallels(of: start.shapeID, finish.shapeID, except: arrow.id, in: topology)
                                  let bend = ArrowConnections.pairBend(of: typed.props, beside: beside, in: editor.document)
                                  guard bend != 0 else { return }
                                  typed.props.bend = bend
                                  var bent = AnyShapeRecord(typed)
                                  bent.meta = arrow.meta
                                  arrow = bent
                              },
                              // Released bound: the release every connection has (Connections' `connectionMade`: what
                              // each plugin says it is, a list where several fit), in the press's own step; then the
                              // relationships count it.
                              finished: { arrow in
                                  editor.connectionMade(arrow)
                                  editor.connectionReleased(arrow)
                              })
        }
        // An end binds a row where the arrow's channel is on the rows of the shape it's at, in that end's role (a key's ends,
        // column to column); a plain arrow, or one on a channel the shape takes whole, binds the shape.
        registrar.arrowPartRule { query in
            guard let channel = query.arrow[ChannelProperty.self], query.registry.declares(channel) else { return false }
            return query.registry.takesOnParts(query.shape.kind, channel, as: query.end == .start ? .source : .target)
        }
        registrar.arrowBindingRule { query in
            // Never a container and what it holds, either way round, whatever the arrow's channel: Connections' rule.
            if let other = query.arrow.typed(as: Arrow.self)?.props[query.end.opposite].binding?.shapeID,
               !query.shapes.mayConnect(other, query.shape.id) { return false }
            guard let channel = query.arrow[ChannelProperty.self], query.registry.declares(channel) else { return true }
            return query.registry.accepts(query.shape, on: channel, as: query.end == .start ? .source : .target)
        }
    }
}

/// Arrows made without a drag, as a connection request says: bound at both ends, each aimed at the
/// middle of the side it names (precise, not exact, so it stops at the outline with its head's gap,
/// as an end bound slowly does) or, with none, at the shape's center (imprecise, as
/// a port's drag starts one). Where a named side faces away from the other shape, the arrow still
/// leaves from the side facing it: an end is clipped where the line first crosses the outline
/// (tldraw's). A shape joined to itself is a loop on one of its sides (`loop(on:side:beside:in:)`).
@MainActor
enum ArrowConnections {
    /// A new arrow (`existing` nil) or `existing` changed: an end the request names a side for, or
    /// whose shape isn't the one it's bound to, is bound anew (from a shape to itself, a loop on the side
    /// named, else the right, and one already made changed only for a side it isn't on); any other end keeps its binding; its
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
        // The connections already joining the pair, but this one (`request.beside` names them; none: read now, from
        // Topology's committed arrows).
        let id = arrow.id
        let beside = {
            (request.beside ?? shapes.service(TopologyIndex.self).map { parallels(of: request.from, request.to, except: id, in: $0) } ?? [])
                .filter { $0 != id }
        }
        if request.from == request.to, request.fromPart == nil, request.toPart == nil {
            // A shape joined to itself is a loop on one of its sides (`loop(on:side:beside:in:)`): the side the request
            // names (its start's, else its end's), else the right. One made already keeps its ends and its bend, unless a
            // side is named that it isn't on.
            let side = request.fromSide ?? request.toSide
            if existing == nil || side.map({ $0 != loopSlot(of: arrow.props, on: request.from)?.side }) == true {
                guard let shape = Connectables(shapes: shapes)[request.from] else { return nil }
                let loop = loop(on: shape, side: side ?? .right, beside: beside(), in: shapes.document)
                arrow.props.start = .bound(loop.start)
                arrow.props.end = .bound(loop.end)
                arrow.props.bend = loop.bend
            }
        } else {
            // A key from a row to itself joins nothing.
            if request.from == request.to, request.fromPart != nil, request.fromPart == request.toPart { return nil }
            for (end, shape, side, part) in [(ArrowEnd.start, request.from, request.fromSide, request.fromPart),
                                             (.end, request.to, request.toSide, request.toPart)]
            where side != nil || arrow.props[end].binding?.shapeID != shape || arrow.props[end].binding?.part != part {
                if let part, let connectable = Connectables(shapes: shapes)[shape], connectable.parts.isEmpty {
                    // A row through a pill for its shape (a column of a table on another board): the pill met as a whole, at its
                    // middle, the row named on the binding for Topology and the key index.
                    arrow.props[end] = .bound(ArrowBinding(shapeID: shape, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false, part: part))
                } else if let part {
                    // A row's end: drawn at its side facing the other end, wherever the two are; kept as its right side's middle
                    // (where it's drawn only while the row is gone), so one made by name is the same wherever its shapes stand.
                    arrow.props[end] = .bound(binding(to: shape, part: part, side: .right, in: shapes)
                                              ?? ArrowBinding(shapeID: shape, normalizedAnchor: CGPoint(x: 1, y: 0.5), isPrecise: true, isExact: true, part: part))
                } else {
                    arrow.props[end] = .bound(binding(to: shape, side: side))
                }
            }
            // A new arrow aimed at the centers beside another of the pair is bent apart from it.
            if existing == nil {
                arrow.props.bend = pairBend(of: arrow.props, beside: beside(), in: shapes.document)
            }
        }
        arrow.props.startArrowhead = request.bothHeads
        arrow.props.endArrowhead = true
        var made = AnyShapeRecord(arrow)
        if let existing { made.meta = existing.meta }
        let registry = shapes.registry
        guard registry.arrowMayBind(made, .start, to: from, in: shapes), registry.arrowMayBind(made, .end, to: to, in: shapes) else { return nil }
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

    /// An end bound to a row of `shape`, at `side` of it (precise and exact, its anchor that side's middle); nil for a part the
    /// shape's geometry doesn't list.
    static func binding(to shape: ShapeID, part: PartID, side: PartSide, in shapes: ShapeContext) -> ArrowBinding? {
        guard let connectable = Connectables(shapes: shapes)[shape], let rect = connectable.parts.frame(part)?.rect else { return nil }
        let bounds = connectable.bounds
        let point = side.point(of: rect)
        let anchor = bounds.width > 0 && bounds.height > 0 ? normalizedAnchor(point, in: bounds) : CGPoint(x: 0.5, y: 0.5)
        return ArrowBinding(shapeID: shape, normalizedAnchor: anchor, isPrecise: true, isExact: true, part: part)
    }

    /// The parts an arrow's start and end are bound to (rows), each nil for an end bound to a whole shape or free.
    static func parts(of record: AnyShapeRecord) -> (from: PartID?, to: PartID?) {
        guard let arrow = record.typed(as: Arrow.self)?.props else { return (nil, nil) }
        return (arrow.start.binding?.part, arrow.end.binding?.part)
    }

    /// The shapes an arrow's start and end are bound to; nil unless both are.
    static func ends(of record: AnyShapeRecord) -> (from: ShapeID, to: ShapeID)? {
        guard let arrow = record.typed(as: Arrow.self)?.props, let start = arrow.start.binding, let end = arrow.end.binding else { return nil }
        return (start.shapeID, end.shapeID)
    }
}

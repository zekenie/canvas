import Canvas
import CoreGraphics

/// A connection from one shape to another, by id, as an arrow bound at both ends is: the kind a
/// fixture connector draws (a Ports connector's, an edge maker's), so tests that connect shapes
/// needn't depend on Arrows. It has no box: its geometry is the segment from its start's center to
/// its end's (open, so nothing presses it), and nothing while an end names no shape it can find.
public struct Link: ShapeProps {
    public static let kind: ShapeKind = "link"
    public static let properties = Properties<Link> {
        Property("from", \.from)
        Property("to", \.to)
    }
    public var from: ShapeID?
    public var to: ShapeID?
    public init(from: ShapeID?, to: ShapeID?) {
        self.from = from
        self.to = to
    }
}

extension Link {
    public init() { self.init(from: nil, to: nil) }
}

struct LinkDefinition {}

extension LinkDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Link>, in context: RenderContext) {}

    func geometry(of shape: ShapeRecord<Link>, in context: ShapeContext) -> ShapeGeometry {
        func center(_ id: ShapeID?) -> CGPoint? {
            guard let bounds = id.flatMap(context.geometry(of:))?.bounds, !bounds.isNull, !bounds.isInfinite else { return nil }
            return CGPoint(x: bounds.midX, y: bounds.midY)
        }
        guard let from = center(shape.props.from), let to = center(shape.props.to) else {
            return ShapeGeometry(outline: [], bounds: .zero, isClosed: false)
        }
        return ShapeGeometry(outline: [from, to], isClosed: false)
    }
}

extension LinkDefinition: ShapeReferencing {
    /// A shape that goes (or is left out of a copy) is let go of: that end links nothing.
    func remappingReferences(of shape: ShapeRecord<Link>, _ map: (ShapeID) -> ShapeID?, in _: ShapeContext) -> Link? {
        Link(from: shape.props.from.flatMap(map), to: shape.props.to.flatMap(map))
    }
}

/// Links ("link"), no tool: what tests connect shapes with. Install beside `FixturesPlugin`.
public struct LinksPlugin: CanvasPlugin {
    public let id: PluginID
    public init(id: PluginID = "links") { self.id = id }
    public func register(into registrar: inout PluginRegistrar) {
        registrar.shape(LinkDefinition())
    }
}

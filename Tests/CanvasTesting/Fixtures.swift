import AppKit
@_spi(Host) import Canvas

/// A plain box: frame geometry, frame hit testing.
public struct Box: BoxShapeProps {
    public static let kind: ShapeKind = "box"
    public static let properties = Properties<Box> {
        Property("frame", \.frame).required()
    }
    public var frame: CGRect
    public init(_ frame: CGRect) { self.frame = frame }
}

extension Box {
    public init() { self.init(.zero) }
}

/// A disc: analytic hit test and a 128-point outline, as a round shape needs.
public struct Disc: BoxShapeProps {
    public static let kind: ShapeKind = "disc"
    public static let properties = Properties<Disc> {
        Property("frame", \.frame).required()
    }
    public var frame: CGRect
    public init(_ frame: CGRect) { self.frame = frame }
}

extension Disc {
    public init() { self.init(.zero) }
}

/// A box shown above another shape, like a connector.
public struct Tag: ShapeProps {
    public static let kind: ShapeKind = "tag"
    public static let properties = Properties<Tag> {
        Property("target", \.target)
    }
    public var target: ShapeID?
    public init(target: ShapeID?) { self.target = target }
}

extension Tag {
    public init() { self.init(target: nil) }
}

struct BoxDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Box>, in context: RenderContext) {
        context.fillWithShadow(CGPath(rect: shape.frame, transform: nil), .systemGray)
    }
}

struct DiscDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Disc>, in context: RenderContext) {
        context.fillWithShadow(CGPath(ellipseIn: shape.frame, transform: nil), .systemGray)
    }
    func geometry(of shape: ShapeRecord<Disc>, in context: ShapeContext) -> ShapeGeometry {
        let f = shape.frame, count = 128
        return ShapeGeometry(outline: (0..<count).map { i in
            let a = CGFloat(i) / CGFloat(count) * 2 * .pi
            return CGPoint(x: f.midX + cos(a) * f.width / 2, y: f.midY + sin(a) * f.height / 2)
        }, bounds: f)
    }
    func hitTest(_ point: CGPoint, on shape: ShapeRecord<Disc>, in context: ShapeContext) -> Bool {
        let f = shape.frame
        let x = (point.x - f.midX) / (f.width / 2), y = (point.y - f.midY) / (f.height / 2)
        return x * x + y * y <= 1
    }
}

struct TagDefinition: ShapeDefinition, PaintOrderAnchored {
    func render(_ shape: ShapeRecord<Tag>, in context: RenderContext) {}
    func geometry(of shape: ShapeRecord<Tag>, in context: ShapeContext) -> ShapeGeometry {
        ShapeGeometry(outline: [], bounds: .zero, isClosed: false)
    }
    func paintAnchor(of shape: ShapeRecord<Tag>, in document: CanvasDocument) -> ShapeID? { shape.props.target }
}

extension TagDefinition: ShapeReferencing {
    /// A tag whose shape goes (or is left out of a copy) is shown above nothing.
    func remappingReferences(of shape: ShapeRecord<Tag>, _ map: (ShapeID) -> ShapeID?, in _: ShapeContext) -> Tag? {
        Tag(target: shape.props.target.flatMap(map))
    }
}

/// A box shown below another shape, as a connector bound to rows of cards is (`paintsBelowAnchor`): `Tag`'s reverse.
public struct Underlay: ShapeProps {
    public static let kind: ShapeKind = "underlay"
    public static let properties = Properties<Underlay> {
        Property("target", \.target)
    }
    public var target: ShapeID?
    public init(target: ShapeID?) { self.target = target }
}

extension Underlay {
    public init() { self.init(target: nil) }
}

struct UnderlayDefinition: ShapeDefinition, PaintOrderAnchored {
    func render(_ shape: ShapeRecord<Underlay>, in context: RenderContext) {}
    func geometry(of shape: ShapeRecord<Underlay>, in context: ShapeContext) -> ShapeGeometry {
        ShapeGeometry(outline: [], bounds: .zero, isClosed: false)
    }
    func paintAnchor(of shape: ShapeRecord<Underlay>, in document: CanvasDocument) -> ShapeID? { shape.props.target }
    func paintsBelowAnchor(_ shape: ShapeRecord<Underlay>, in document: CanvasDocument) -> Bool { true }
}

/// The "underlay" kind, no tool, apart from `FixturesPlugin` so the registry reports tests pin don't change.
public struct UnderlaysPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { "underlays" }
    public func register(into registrar: inout PluginRegistrar) {
        registrar.shape(UnderlayDefinition())
    }
}

/// "box", "disc" and "tag" kinds, no tools. What core and horizontal tests draw with, so they
/// never depend on a real vertical.
public struct FixturesPlugin: CanvasPlugin {
    public let id: PluginID
    public init(id: PluginID = "fixtures") { self.id = id }
    public func register(into registrar: inout PluginRegistrar) {
        registrar.shape(BoxDefinition())
        registrar.shape(DiscDefinition())
        registrar.shape(TagDefinition())
    }
}

/// A plugin written inline.
public struct Contributor: CanvasPlugin, Sendable {
    public let id: PluginID
    let body: @MainActor (inout PluginRegistrar) -> Void
    public nonisolated init(id: PluginID, _ body: @escaping @MainActor (inout PluginRegistrar) -> Void) {
        self.id = id
        self.body = body
    }
    public func register(into registrar: inout PluginRegistrar) { body(&registrar) }
}

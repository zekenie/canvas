import AppKit
import Geometry

/// A shape's outline, in world coordinates.
public struct ShapeGeometry: Sendable {
    /// A closed polygon for shapes with an inside; the path's points otherwise.
    public var outline: [CGPoint]
    public var bounds: CGRect
    /// Whether the shape has an inside. Open shapes are hit near their outline only by their own
    /// `hitTest`, and nothing can be attached inside them.
    public var isClosed: Bool

    public init(outline: [CGPoint], bounds: CGRect? = nil, isClosed: Bool = true) {
        self.outline = outline
        self.bounds = bounds ?? CGRect(enclosing: outline)
        self.isClosed = isClosed
    }
}

/// Read-only lookups for definitions, overlays and plugins.
@MainActor
public struct ShapeContext {
    public let document: CanvasDocument
    public let registry: Registry
    public let camera: Camera
    public var zoom: CGFloat { camera.zoom }

    init(document: CanvasDocument, registry: Registry, camera: Camera) {
        self.document = document
        self.registry = registry
        self.camera = camera
    }

    public func geometry(of id: ShapeID) -> ShapeGeometry? {
        guard let record = document[id], let definition = registry.definition(for: record.kind) else { return nil }
        return definition.erasedGeometry(of: record, in: self)
    }

    /// Whether a world point hits the shape, by its definition's own test.
    public func hitTest(_ point: CGPoint, shape id: ShapeID) -> Bool {
        guard let record = document[id], let definition = registry.definition(for: record.kind) else { return false }
        return definition.erasedHitTest(point, on: record, in: self)
    }
}

/// What a shape draws with. Each render gets a fresh graphics state, and AppKit drawing
/// (`NSAttributedString.draw`, `NSColor.setFill`) goes to the same context.
@MainActor
public struct RenderContext {
    /// The camera transform is applied: draw in world units.
    public let cg: CGContext
    public let shapes: ShapeContext
    /// This shape's editing view is showing.
    public let isEditing: Bool
    public var zoom: CGFloat { shapes.zoom }

    /// The canvas's standard shape shadow. Shadows ignore the transform, so the blur is scaled by
    /// hand; the offset is zero because shadow offsets live in device space.
    public func fillWithShadow(_ path: CGPath, _ color: NSColor) {
        cg.saveGState()
        cg.setShadow(offset: .zero, blur: 6 * zoom, color: Style.shapeShadow.cgColor)
        cg.addPath(path)
        cg.setFillColor(color.cgColor)
        cg.fillPath()
        cg.restoreGState()
    }
}

/// How one kind of shape looks and behaves. Stateless; one per kind, registered by its plugin.
/// What else a kind can do comes from the capability protocols that refine this one.
///
/// `geometry` is the one source of truth: hit testing and the outline follow it unless you
/// override them (for an exact test, say, or a smoother outline). Box kinds get their frame as
/// geometry, so the smallest definition is just `render`. Conform in an extension
/// (`extension MyDefinition: ShapeDefinition { ... }`): only there does Swift flag a member that
/// nearly matches a defaulted requirement, and the build fails on it.
@MainActor
public protocol ShapeDefinition<Props> {
    associatedtype Props: ShapeProps
    func render(_ shape: ShapeRecord<Props>, in context: RenderContext)
    /// Box kinds get their frame by default; any other kind must say.
    func geometry(of shape: ShapeRecord<Props>, in context: ShapeContext) -> ShapeGeometry
    /// Whether a world point is on the shape: for pressing, hovering and attaching to it.
    /// Default: inside a closed outline (an open shape can't be hit unless it says how).
    func hitTest(_ point: CGPoint, on shape: ShapeRecord<Props>, in context: ShapeContext) -> Bool
    /// The outline drawn for it: the target hint, and whatever plugins outline (hover, selection).
    /// The core strokes them all in one pass.
    func indicatorPath(of shape: ShapeRecord<Props>, in context: ShapeContext) -> CGPath
}

extension ShapeDefinition {
    public func hitTest(_ point: CGPoint, on shape: ShapeRecord<Props>, in context: ShapeContext) -> Bool {
        let geometry = geometry(of: shape, in: context)
        return geometry.isClosed && polygonContains(geometry.outline, point)
    }

    public func indicatorPath(of shape: ShapeRecord<Props>, in context: ShapeContext) -> CGPath {
        let geometry = geometry(of: shape, in: context)
        let path = CGMutablePath()
        path.addLines(between: geometry.outline)
        if geometry.isClosed { path.closeSubpath() }
        return path
    }
}

extension ShapeDefinition where Props: BoxShapeProps {
    public func geometry(of shape: ShapeRecord<Props>, in context: ShapeContext) -> ShapeGeometry {
        ShapeGeometry(outline: shape.frame.polygon, bounds: shape.frame)
    }
}

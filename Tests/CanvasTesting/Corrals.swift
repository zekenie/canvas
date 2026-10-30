import AppKit
@_spi(Host) import Canvas

/// A box that holds shapes on its board (`ShapeContaining`), as a frame does: what core and
/// horizontal tests put shapes in containers with, so they never depend on Frames. It's hit anywhere
/// inside, by the default hit test.
public struct Corral: BoxShapeProps {
    public static let kind: ShapeKind = "corral"
    public static let properties = Properties<Corral> {
        Property("frame", \.frame).required()
    }
    public var frame: CGRect
    public init(_ frame: CGRect) { self.frame = frame }
}

extension Corral {
    public init() { self.init(.zero) }
}

struct CorralDefinition {}

extension CorralDefinition: ShapeDefinition {
    /// A pale fill with a gray edge.
    func render(_ shape: ShapeRecord<Corral>, in context: RenderContext) {
        context.cg.setFillColor(NSColor(white: 0.9, alpha: 1).cgColor)
        context.cg.fill(shape.frame)
        context.cg.setStrokeColor(NSColor.systemGray.cgColor)
        context.cg.setLineWidth(1 / context.zoom)
        context.cg.stroke(shape.frame)
    }
}

extension CorralDefinition: ShapeContaining {}

/// The "corral" kind, no tool. Apart from `FixturesPlugin`, so the registry reports tests pin don't
/// change.
public struct CorralsPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { "corrals" }
    public func register(into registrar: inout PluginRegistrar) {
        registrar.shape(CorralDefinition())
    }
}

/// A box that holds shapes, hit as a frame is: while it holds any, only on its edge, `edgeReach`
/// view points either side (its inside is the canvas); while it holds none, anywhere inside too.
public struct Paddock: BoxShapeProps {
    public static let kind: ShapeKind = "paddock"
    public static let properties = Properties<Paddock> {
        Property("frame", \.frame).required()
    }
    /// How far either side of its edge it's pressed, in view points: a frame's.
    public static let edgeReach: CGFloat = 6
    public var frame: CGRect
    public init(_ frame: CGRect) { self.frame = frame }
}

extension Paddock {
    public init() { self.init(.zero) }
}

struct PaddockDefinition {}

extension PaddockDefinition: ShapeDefinition {
    /// A pale fill with a gray edge, as a corral's.
    func render(_ shape: ShapeRecord<Paddock>, in context: RenderContext) {
        context.cg.setFillColor(NSColor(white: 0.9, alpha: 1).cgColor)
        context.cg.fill(shape.frame)
        context.cg.setStrokeColor(NSColor.systemGray.cgColor)
        context.cg.setLineWidth(1 / context.zoom)
        context.cg.stroke(shape.frame)
    }

    func hitTest(_ point: CGPoint, on shape: ShapeRecord<Paddock>, in context: ShapeContext) -> Bool {
        let box = shape.frame, reach = Paddock.edgeReach / context.zoom
        guard box.insetBy(dx: -reach, dy: -reach).contains(point) else { return false }
        guard context.hasContents(shape.id) else { return true }
        let inside = box.insetBy(dx: reach, dy: reach)
        return inside.isEmpty || !inside.contains(point)
    }

    var hitMargin: HitMargin { HitMargin(view: Paddock.edgeReach) }
}

extension PaddockDefinition: ShapeContaining {}

/// The "paddock" kind, no tool: a container hollow as a frame is. Apart from `FixturesPlugin`, so
/// the registry reports tests pin don't change.
public struct PaddocksPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { "paddocks" }
    public func register(into registrar: inout PluginRegistrar) {
        registrar.shape(PaddockDefinition())
    }
}

extension CanvasEditor {
    /// Puts each shape of `ids` in `container` (nil: on the board directly), in one transaction.
    public func put(_ ids: [ShapeID], in container: ShapeID?) {
        transact { transaction in
            for id in ids { transaction.setContainer(id, to: container) }
        }
    }

    /// The container a shape is in, as the core goes by it; nil on the board directly.
    public func holder(of id: ShapeID) -> ShapeID? {
        document.container(of: id, containingKinds: registry.containingKinds)
    }
}

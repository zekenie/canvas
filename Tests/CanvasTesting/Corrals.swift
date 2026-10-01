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

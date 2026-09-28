import AppKit
@_spi(Host) import Canvas

/// A box that owns a board (`BoardOwning`): what core and horizontal tests nest boards with, so
/// they never depend on Subboards.
public struct Pocket: BoxShapeProps {
    public static let kind: ShapeKind = "pocket"
    public static let properties = Properties<Pocket> {
        Property("frame", \.frame).required()
    }
    public var frame: CGRect
    public init(_ frame: CGRect) { self.frame = frame }
}

extension Pocket {
    public init() { self.init(.zero) }
}

struct PocketDefinition {}

extension PocketDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Pocket>, in context: RenderContext) {
        context.fillWithShadow(CGPath(rect: shape.frame, transform: nil), .systemGray)
    }
}

extension PocketDefinition: BoardOwning {}

/// The "pocket" kind, no tool. Apart from `FixturesPlugin`, so the registry reports tests pin
/// don't change.
public struct PocketsPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { "pockets" }
    public func register(into registrar: inout PluginRegistrar) {
        registrar.shape(PocketDefinition())
    }
}

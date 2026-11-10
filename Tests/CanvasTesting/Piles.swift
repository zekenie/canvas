import AppKit
@_spi(Host) import Canvas

// A shape that makes room below it as it grows (`MakesRoomAsItGrows`): what the core's tests of the push draw with, so
// they never depend on the engineering kit. A pile is laid out as tall as its layers, as a table is as tall as its rows,
// and a value a plugin sets for it (`Piles.waiting`) lays it out a layer taller, as an editing view's waiting line does.

/// A box laid out `Pile.layer` tall a layer, its width as stored.
public struct Pile: BoxShapeProps {
    public static let kind: ShapeKind = "pile"
    public static let properties = Properties<Pile> {
        Property("frame", \.frame).required()
        Property("layers", \.layers)
    }
    /// How tall a layer is, in world units.
    public static let layer: CGFloat = 20
    public var frame: CGRect
    public var layers: Int
    public init(_ frame: CGRect, layers: Int = 1) {
        self.frame = frame
        self.layers = layers
    }
}

extension Pile {
    public init() { self.init(.zero) }
}

/// A pile that keeps room below it as it grows (`MakesRoomAsItGrows.roomKeptBelow`): `Keeper.kept` world units.
public struct Keeper: BoxShapeProps {
    public static let kind: ShapeKind = "keeper"
    public static let properties = Properties<Keeper> {
        Property("frame", \.frame).required()
        Property("layers", \.layers)
    }
    /// The room it keeps clear below its bottom, world units.
    public static let kept: CGFloat = 30
    public var frame: CGRect
    public var layers: Int
    public init(_ frame: CGRect, layers: Int = 1) {
        self.frame = frame
        self.layers = layers
    }
}

extension Keeper {
    public init() { self.init(.zero) }
}

struct KeeperDefinition {}

extension KeeperDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Keeper>, in context: RenderContext) {
        context.cg.setFillColor(NSColor.systemOrange.cgColor)
        context.cg.fill(context.shapes.frame(of: shape))
    }
}

extension KeeperDefinition: LaidOutBox {
    func laidOutSize(of shape: ShapeRecord<Keeper>, in context: ShapeContext) -> CGSize {
        CGSize(width: shape.frame.width, height: Pile.layer * CGFloat(max(shape.props.layers, 1)))
    }
}

extension KeeperDefinition: MakesRoomAsItGrows {
    var roomKeptBelow: CGFloat { Keeper.kept }
}

public enum Piles {
    /// A layer shown while a pile is handled, never written: what the push never counts.
    public static let waiting = LayoutInputKey<Bool>("pile-waiting")
}

struct PileDefinition {}

extension PileDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Pile>, in context: RenderContext) {
        context.cg.setFillColor(NSColor.systemBrown.cgColor)
        context.cg.fill(context.shapes.frame(of: shape))
    }
}

extension PileDefinition: LaidOutBox {
    func laidOutSize(of shape: ShapeRecord<Pile>, in context: ShapeContext) -> CGSize {
        let layers = max(shape.props.layers, 1) + (context.layoutInput(Piles.waiting, of: shape) == true ? 1 : 0)
        return CGSize(width: shape.frame.width, height: Pile.layer * CGFloat(layers))
    }
}

extension PileDefinition: MakesRoomAsItGrows {}

extension CanvasEditor {
    /// Sets how many layers a pile has, in one step called "Add Layer".
    public func setLayers(_ layers: Int, of id: ShapeID) {
        transact("Add Layer") { $0.update(id, as: Pile.self) { $0.props.layers = layers } }
    }

    /// The same for a `Keeper`.
    public func setKeeperLayers(_ layers: Int, of id: ShapeID) {
        transact("Add Layer") { $0.update(id, as: Keeper.self) { $0.props.layers = layers } }
    }
}

/// The "pile" kind, no tool. Apart from `FixturesPlugin`, as `CorralsPlugin` is, so the registry reports tests pin don't
/// change.
public struct PilesPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { "piles" }
    public func register(into registrar: inout PluginRegistrar) {
        registrar.shape(PileDefinition())
        registrar.shape(KeeperDefinition())
    }
}

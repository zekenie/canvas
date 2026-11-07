import AppKit
@_spi(Host) import Canvas

/// A ledger: a box whose shapes take the shapes bound to them along (`TakesBoundShapes`), so deleting one deletes the links
/// bound to it (CanvasTesting's `Link`, bound at both ends as an arrow is) and copying two keeps the link between them. A tool
/// places one (Ledger, 100 × 60), so ⇧↩ has a kind to make beside one.
public struct Ledger: BoxShapeProps {
    public static let kind: ShapeKind = "ledger"
    public static let properties = Properties<Ledger> {
        Property("frame", \.frame).required()
    }
    public var frame: CGRect
    public init(_ frame: CGRect) { self.frame = frame }
}

extension Ledger {
    public init() { self.init(.zero) }
}

struct LedgerDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Ledger>, in context: RenderContext) {
        context.fillWithShadow(CGPath(rect: shape.frame, transform: nil), .systemTeal)
    }
}

extension LedgerDefinition: TakesBoundShapes {}

/// Ledgers, in a plugin of their own so no other test's registry report changes. Install beside `FixturesPlugin` and
/// `LinksPlugin`.
public struct LedgersPlugin: CanvasPlugin {
    public let id: PluginID
    public init(id: PluginID = "ledgers") { self.id = id }
    public func register(into registrar: inout PluginRegistrar) {
        registrar.shape(LedgerDefinition()) { ledger in
            ledger.tool(label: "Ledger", systemImage: "book", placing: ledger.placement(size: CGSize(width: 100, height: 60)) { Ledger() })
        }
    }
}

import AppKit
@_spi(Host) import Canvas

/// The tests' kit (`Kit`): what each module's tests join with plugins of their own, to see a kit switch what
/// they give and leave the rest, so no test depends on a kit the app ships.
public enum Workshop {}

extension Workshop: Kit {
    public static let id: KitID = "workshop"
    public static var title: String { "Workshop" }
}

/// A second kit, for what two do.
public enum Studio {}

extension Studio: Kit {
    public static let id: KitID = "studio"
    public static var title: String { "Studio" }
}

/// A plank: the workshop's own kind, a box, so a test sees a kit's tool and Insert item, and the shapes drawn
/// with them while the kit is off.
public struct Plank: BoxShapeProps {
    public static let kind: ShapeKind = "plank"
    public static let properties = Properties<Plank> {
        Property("frame", \.frame).required()
    }
    public var frame: CGRect
    public init(_ frame: CGRect) { self.frame = frame }
}

extension Plank {
    public init() { self.init(.zero) }
}

struct PlankDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Plank>, in context: RenderContext) {
        context.fillWithShadow(CGPath(rect: shape.frame, transform: nil), .systemBrown)
    }
}

extension CanvasCommand {
    /// The workshop's command: Edit ▸ Carve, which counts its runs (`WorkshopLog.carved`).
    public static let carve: CanvasCommand = "carve"
}

/// The workshop's section of Edit, which Carve's item is in.
public enum WorkshopSection {}

extension WorkshopSection: MenuBarSection {
    public static var menu: MenuBarMenu { "Edit" }
}

/// What the workshop's ways in did.
@MainActor
public final class WorkshopLog {
    public var carved = 0
    public init() {}
}

/// A plugin in a kit (`Workshop` unless it says another, or none): planks, with a placing tool (Plank, and its
/// Insert item, in Insert's submenu for the kit) and Carve, a command in Edit, both the kit's ways in.
public struct WorkshopPlugin: CanvasPlugin {
    public let id: PluginID
    let kit: (any Kit.Type)?
    let log: WorkshopLog

    public init(id: PluginID = "workshop", kit: (any Kit.Type)? = Workshop.self, log: WorkshopLog = WorkshopLog()) {
        self.id = id
        self.kit = kit
        self.log = log
    }

    public func register(into registrar: inout PluginRegistrar) {
        if let kit { registrar.join(kit) }
        registrar.shape(PlankDefinition()) { plank in
            plank.tool(label: "Plank", systemImage: "rectangle", placing: plank.placement(size: CGSize(width: 120, height: 30)) { Plank() })
        }
        let log = log
        registrar.command(.carve, title: "Carve", in: WorkshopSection.self) { _ in log.carved += 1 }
    }
}

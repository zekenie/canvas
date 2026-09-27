/// The core's own extension points. They work exactly like a plugin's; the core just owns them.
enum CorePoints {
    enum Shapes: KeyedExtensionPoint {
        typealias Contribution = ShapeRegistration
        static var owner: PluginID { .core }
        static func uniqueKeys(of c: ShapeRegistration, for _: ShapeTarget) -> [AnyHashable] { [c.kind] }
    }

    enum Tools: KeyedExtensionPoint {
        typealias Contribution = ToolRegistration
        static var owner: PluginID { .core }
        static func uniqueKeys(of c: ToolRegistration, for _: ShapeTarget) -> [AnyHashable] {
            [ToolKey.id(c.descriptor.id)] + (c.descriptor.shortcut.map { [ToolKey.shortcut(Character($0.lowercased()))] } ?? [])
        }
    }

    enum Services: KeyedExtensionPoint {
        typealias Contribution = ServiceRegistration
        static var owner: PluginID { .core }
        /// Module-qualified, so two plugins' services that share a type name don't collide.
        static func uniqueKeys(of c: ServiceRegistration, for _: ShapeTarget) -> [AnyHashable] { [c.qualifiedName] }
    }

    enum Overlays: ExtensionPoint {
        typealias Contribution = any CanvasOverlay
        static var owner: PluginID { .core }
    }

    enum WillDelete: ExtensionPoint {
        typealias Contribution = @MainActor (Set<ShapeID>, inout Transaction) -> Void
        static var owner: PluginID { .core }
    }

    enum DoubleClickPlacement: KeyedExtensionPoint {
        typealias Contribution = Placement
        static var owner: PluginID { .core }
        static func uniqueKeys(of _: Placement, for _: ShapeTarget) -> [AnyHashable] { ["double-click on empty canvas"] }
    }
}

enum ToolKey: Hashable, CustomStringConvertible {
    case id(ToolID), shortcut(Character)
    var description: String {
        switch self {
        case .id(let id): "tool \(id)"
        case .shortcut(let key): "shortcut \(key)"
        }
    }
}

struct ShapeRegistration {
    let kind: ShapeKind
    let definition: any ShapeDefinition
}

struct ToolRegistration {
    let descriptor: ToolDescriptor
    let make: @MainActor (CanvasEditor) -> any Tool
}

struct ServiceRegistration {
    let type: ObjectIdentifier
    /// The type's name, for the report.
    let name: String
    let qualifiedName: String
    let make: @MainActor (CanvasEditor) -> any EditorService

    init<S: EditorService>(type: S.Type, make: @escaping @MainActor (CanvasEditor) -> S) {
        self.type = ObjectIdentifier(S.self)
        name = "\(S.self)"
        qualifiedName = String(reflecting: S.self)
        self.make = make
    }
}

/// Installed ahead of every plugin list.
struct CorePlugin: CanvasPlugin {
    var id: PluginID { .core }
    func register(into registrar: inout PluginRegistrar) {
        registrar.tool(ToolDescriptor(id: .select, label: "Select", systemImage: "cursorarrow", shortcut: "v")) { _ in SelectTool() }
        registrar.tool(ToolDescriptor(id: .hand, label: "Hand", systemImage: "hand.raised", shortcut: "h")) { _ in HandTool() }
    }
}

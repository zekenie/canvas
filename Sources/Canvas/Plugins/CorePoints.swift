import AppKit

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
        static func uniqueKeys(of c: ToolRegistration, for _: ShapeTarget) -> [AnyHashable] { [ToolKey(id: c.descriptor.id)] }
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

    enum OutlineSources: ExtensionPoint {
        typealias Contribution = @MainActor (CanvasEditor) -> Outlines
        static var owner: PluginID { .core }
    }

    /// Which shapes can't change (`registrar.readOnlyShapes`): a shape is read-only when any rule
    /// says so.
    enum ReadOnlyRules: ExtensionPoint {
        typealias Contribution = @MainActor (AnyShapeRecord) -> Bool
        static var owner: PluginID { .core }
    }

    enum Commands: KeyedExtensionPoint {
        typealias Contribution = CommandRegistration
        static var owner: PluginID { .core }
        static func uniqueKeys(of c: CommandRegistration, for _: ShapeTarget) -> [AnyHashable] { [c.command] }
    }

    /// The tool the editor starts in, and returns to on Escape and after placing a shape. One
    /// plugin may claim it; otherwise it's the Hand.
    enum DefaultTool {}

    /// What a secondary click opens. One plugin may claim it; otherwise there's no menu.
    enum SecondaryClickMenu: KeyedExtensionPoint {
        typealias Contribution = @MainActor (CanvasEditor, Pointer) -> NSMenu?
        static var owner: PluginID { .core }
        static func uniqueKeys(of _: Contribution, for _: ShapeTarget) -> [AnyHashable] { ["the secondary-click menu"] }
    }

    /// What a key pressed on the canvas does. One plugin may claim it; otherwise no key does
    /// anything there.
    enum KeyStrokes: KeyedExtensionPoint {
        typealias Contribution = @MainActor (CanvasEditor, KeyStroke) -> Bool
        static var owner: PluginID { .core }
        static func uniqueKeys(of _: Contribution, for _: ShapeTarget) -> [AnyHashable] { ["key strokes"] }
    }
}

extension CorePoints.DefaultTool: KeyedExtensionPoint {
    typealias Contribution = ToolID
    static var owner: PluginID { .core }
    static func uniqueKeys(of _: ToolID, for _: ShapeTarget) -> [AnyHashable] { ["the default tool"] }
    /// The claimed tool must exist.
    static func check(_ registry: Registry) throws(RegistryError) {
        let id = registry.defaultTool
        guard registry.tools.contains(where: { $0.id == id }) else {
            throw .invalid(point: "DefaultTool", reason: "no plugin registers tool \(id)")
        }
    }
}

struct ToolKey: Hashable, CustomStringConvertible {
    let id: ToolID
    var description: String { "tool \(id)" }
}

struct ShapeRegistration {
    let kind: ShapeKind
    let definition: any ShapeDefinition
}

struct CommandRegistration {
    let command: CanvasCommand
    let isEnabled: @MainActor (CanvasEditor) -> Bool
    let run: @MainActor (CanvasEditor) -> Void
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
        registrar.tool(ToolDescriptor(id: .hand, label: "Hand", systemImage: "hand.raised")) { _ in HandTool() }
    }
}

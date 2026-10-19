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

    /// What a kind is called, and its symbol (`ShapeRegistrar.label`). One per kind.
    enum KindLabels: KeyedExtensionPoint {
        typealias Contribution = KindLabel
        static var owner: PluginID { .core }
        static func uniqueKeys(of _: KindLabel, for target: ShapeTarget) -> [AnyHashable] { [KindLabelKey(target: target)] }
    }

    /// A kind's color where a shape is shown by its kind (`ShapeRegistrar.tint`). One per kind.
    enum KindTints: KeyedExtensionPoint {
        typealias Contribution = KindTint
        static var owner: PluginID { .core }
        static func uniqueKeys(of _: KindTint, for target: ShapeTarget) -> [AnyHashable] { [KindTintKey(target: target)] }
    }

    /// The tint a shape has of its own (`PluginRegistrar.shapeTints`): the first that answers is
    /// the shape's, else its kind's.
    enum ShapeTints: ExtensionPoint {
        typealias Contribution = @MainActor (AnyShapeRecord, CanvasEditor) -> NSColor?
        static var owner: PluginID { .core }
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

    /// What a kind keeps in step as its shapes are written (`ShapeRegistrar.keepsInStep`).
    enum KeepsInStep: ExtensionPoint {
        typealias Contribution = StepRule
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

    /// What provides a layout input (`PluginRegistrar.layoutInput`). One provider a key.
    enum LayoutProviders: KeyedExtensionPoint {
        typealias Contribution = LayoutProvider
        static var owner: PluginID { .core }
        static func uniqueKeys(of c: LayoutProvider, for _: ShapeTarget) -> [AnyHashable] { [LayoutProviderKey(name: c.name)] }
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

    /// What the selection's menu holds (a menu bar's Shape menu): the items a secondary click on the
    /// selection would open, less the commands the menu bar already runs. One plugin may claim it;
    /// otherwise there is none.
    enum SelectionMenu: KeyedExtensionPoint {
        typealias Contribution = @MainActor (CanvasEditor, Set<CanvasCommand>) -> NSMenu?
        static var owner: PluginID { .core }
        static func uniqueKeys(of _: Contribution, for _: ShapeTarget) -> [AnyHashable] { ["the selection's menu"] }
    }

    /// What a key pressed on the canvas does. One plugin may claim it; otherwise no key does
    /// anything there.
    enum KeyStrokes: KeyedExtensionPoint {
        typealias Contribution = @MainActor (CanvasEditor, KeyStroke) -> Bool
        static var owner: PluginID { .core }
        static func uniqueKeys(of _: Contribution, for _: ShapeTarget) -> [AnyHashable] { ["key strokes"] }
    }

    /// What a key let go on the canvas does (nil: every key, the canvas having lost the keyboard).
    /// One plugin may claim it, the one that claims key strokes, for a key held down (Space's pan).
    enum KeyReleases: KeyedExtensionPoint {
        typealias Contribution = @MainActor (CanvasEditor, KeyStroke?) -> Void
        static var owner: PluginID { .core }
        static func uniqueKeys(of _: Contribution, for _: ShapeTarget) -> [AnyHashable] { ["key releases"] }
    }

    /// Where a drag that moves shapes puts them (`TranslationAdjuster`). One plugin may claim it;
    /// otherwise they follow the pointer.
    enum TranslationAdjusters: KeyedExtensionPoint {
        typealias Contribution = @MainActor (CanvasEditor, TranslationStart) -> (any TranslationAdjuster)?
        static var owner: PluginID { .core }
        static func uniqueKeys(of _: Contribution, for _: ShapeTarget) -> [AnyHashable] { ["the translation adjuster"] }
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

struct LayoutProviderKey: Hashable, CustomStringConvertible {
    let name: String
    var description: String { "layout input \(name)" }
}

struct LayoutProvider {
    let name: String
    let provide: @MainActor (AnyShapeRecord, LayoutReading) -> AnyHashable?
}

struct KindLabelKey: Hashable, CustomStringConvertible {
    let target: ShapeTarget
    var description: String { "the label of \(target)" }
}

struct KindTint {
    let color: NSColor
}

struct KindTintKey: Hashable, CustomStringConvertible {
    let target: ShapeTarget
    var description: String { "the tint of \(target)" }
}

struct ShapeRegistration {
    let kind: ShapeKind
    let definition: any ShapeDefinition
}

struct CommandRegistration {
    let command: CanvasCommand
    /// What it's called, as its menu item is ("Delete", "Zoom to Fit"): the name the Keyboard
    /// Shortcuts window lists its keys under.
    let title: String
    /// What its menu item is called now, for a command that is named for the step it would take
    /// (`editor.menuTitle(of:)`); `title` otherwise.
    let menuTitle: (@MainActor (CanvasEditor) -> String)?
    let isEnabled: @MainActor (CanvasEditor) -> Bool
    let run: @MainActor (CanvasEditor) -> Void
}

struct ToolRegistration {
    let descriptor: ToolDescriptor
    /// What it places, for a tool that places a shape (`ShapeRegistrar.tool(placing:)`).
    var placement: Placement?
    let make: @MainActor (CanvasEditor) -> any Tool

    init(descriptor: ToolDescriptor, placement: Placement? = nil, make: @escaping @MainActor (CanvasEditor) -> any Tool) {
        self.descriptor = descriptor
        self.placement = placement
        self.make = make
    }
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

/// Installed ahead of every plugin list: the Hand, undo and redo, and zooming (whose keys Keyboard
/// gives). Zoom In and Zoom Out are dimmed at the last stop, Actual Size at 100%, and Zoom to Fit
/// with nothing to fit.
struct CorePlugin: CanvasPlugin {
    var id: PluginID { .core }
    func register(into registrar: inout PluginRegistrar) {
        registrar.tool(ToolDescriptor(id: .hand, label: "Hand", systemImage: "hand.raised")) { _ in HandTool() }
        registrar.command(.undo, "Undo", isEnabled: { $0.canUndo }) { $0.undo() }
        registrar.command(.redo, "Redo", isEnabled: { $0.canRedo }) { $0.redo() }
        registrar.command(.zoomIn, "Zoom In", isEnabled: { $0.zoomInStop != nil }) { editor in
            if let stop = editor.zoomInStop { editor.zoom(toPercent: stop) }
        }
        registrar.command(.zoomOut, "Zoom Out", isEnabled: { $0.zoomOutStop != nil }) { editor in
            if let stop = editor.zoomOutStop { editor.zoom(toPercent: stop) }
        }
        registrar.command(.zoomToActualSize, "Actual Size", isEnabled: { $0.zoomPercentage != 100 }) { $0.zoom(toPercent: 100) }
        registrar.command(.zoomToFit, "Zoom to Fit", isEnabled: { $0.canZoomToFit }) { $0.zoomToFit() }
    }
}

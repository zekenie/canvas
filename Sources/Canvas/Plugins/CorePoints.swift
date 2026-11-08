import AppKit

/// The core's own extension points. They work exactly like a plugin's; the core just owns them.
enum CorePoints {
    enum Shapes: KeyedExtensionPoint {
        typealias Contribution = ShapeRegistration
        static var owner: PluginID { .core }
        static func uniqueKeys(of c: ShapeRegistration, for _: ShapeTarget) -> [AnyHashable] { [c.kind] }
    }

    /// The toolbar's tools. A kit switches its plugins' (`editor.isToolEnabled`).
    enum Tools: KeyedExtensionPoint, KitSwitched {
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

    /// What hears parts moved from one shape to another (`Transaction.moveParts`, `registrar.partsMoved`).
    enum PartsMoved: ExtensionPoint {
        typealias Contribution = @MainActor ([PartAddress: PartAddress], inout Transaction) -> Void
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

    /// Each command once, and each standard action answered by one command at most; the menu bar their
    /// items make, as `Commands.swift`'s check holds it.
    enum Commands {}

    /// What a command run from a key or the menu bar acts on (`registrar.commandShapes`): the
    /// selection, and how VoiceOver's press on a shape sets it. One plugin may claim it; otherwise
    /// such a command acts on no shapes.
    enum CommandShapes: KeyedExtensionPoint {
        typealias Contribution = CommandShapesClaim
        static var owner: PluginID { .core }
        static func uniqueKeys(of _: Contribution, for _: ShapeTarget) -> [AnyHashable] { ["the shapes commands act on"] }
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

    /// The tool ⇧↩ puts a shape down with when the selection is no one kind a tool places
    /// (`registrar.insertsBesideByDefault`). One plugin may claim it; otherwise ⇧↩ does nothing then.
    enum InsertBesideByDefault {}

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
        typealias Contribution = @MainActor (CanvasEditor, Set<CanvasCommand>, Bool) -> NSMenu?
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

    /// What box a drag that resizes a shape gives it (`ResizeAdjuster`). One plugin may claim it;
    /// otherwise the box follows the pointer.
    enum ResizeAdjusters: KeyedExtensionPoint {
        typealias Contribution = @MainActor (CanvasEditor, ResizeStart) -> (any ResizeAdjuster)?
        static var owner: PluginID { .core }
        static func uniqueKeys(of _: Contribution, for _: ShapeTarget) -> [AnyHashable] { ["the resize adjuster"] }
    }

    /// Where a shape Insert puts down goes (`registrar.insertionSpot`). One plugin may claim it;
    /// otherwise it goes in the middle of the view.
    enum InsertionSpots: KeyedExtensionPoint {
        typealias Contribution = @MainActor (CanvasEditor, CGSize, [ShapeID]) -> CGRect?
        static var owner: PluginID { .core }
        static func uniqueKeys(of _: Contribution, for _: ShapeTarget) -> [AnyHashable] { ["the insertion spot"] }
    }

    /// How a kind's shape Insert puts down beside one shape is made (`ShapeRegistrar.madeBeside`). One per kind.
    enum MadeBeside: KeyedExtensionPoint {
        typealias Contribution = MadeBesideShape
        static var owner: PluginID { .core }
        static func uniqueKeys(of _: MadeBesideShape, for target: ShapeTarget) -> [AnyHashable] { [MadeBesideKey(target: target)] }
    }

    /// What VoiceOver says of a shape (`scope.accessibility`, `shape.accessibility`): every
    /// contribution that reaches its kind, in plugin order, the kind's own first.
    enum ShapeAccessibility: ExtensionPoint {
        typealias Contribution = @MainActor (AnyShapeRecord, CanvasEditor) -> AccessibleTraits?
        static var owner: PluginID { .core }
        static var scope: PointScope { .scoped }
    }

    /// The order VoiceOver walks a board's shapes in (`registrar.accessibleOrder`): the current
    /// scope's Tab stops. One plugin may claim it; otherwise paint order, the selection first.
    enum AccessibleOrder: KeyedExtensionPoint {
        typealias Contribution = @MainActor (CanvasEditor) -> [ShapeID]
        static var owner: PluginID { .core }
        static func uniqueKeys(of _: Contribution, for _: ShapeTarget) -> [AnyHashable] { ["the accessible order"] }
    }

    /// A shape's drawn parts as VoiceOver sees them, and the one focused (`registrar.accessibleParts`).
    /// One plugin may claim it; otherwise a shape has none.
    enum AccessibleParts: KeyedExtensionPoint {
        typealias Contribution = AccessiblePartsClaim
        static var owner: PluginID { .core }
        static func uniqueKeys(of _: Contribution, for _: ShapeTarget) -> [AnyHashable] { ["the accessible parts"] }
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

extension CorePoints.InsertBesideByDefault: KeyedExtensionPoint {
    typealias Contribution = ToolID
    static var owner: PluginID { .core }
    static func uniqueKeys(of _: ToolID, for _: ShapeTarget) -> [AnyHashable] { ["the tool that inserts beside by default"] }
    /// The claimed tool must exist and place a shape.
    static func check(_ registry: Registry) throws(RegistryError) {
        guard let id = registry.insertsBesideByDefault else { return }
        guard registry.placement(forTool: id) != nil else {
            throw .invalid(point: "InsertBesideByDefault", reason: "no plugin registers a tool \(id) that places a shape")
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

struct MadeBesideShape {
    let make: @MainActor (AnyShapeRecord, AnyShapeRecord) -> AnyShapeRecord
}

struct MadeBesideKey: Hashable, CustomStringConvertible {
    let target: ShapeTarget
    var description: String { "how \(target) is made beside a shape" }
}

struct ShapeRegistration {
    let kind: ShapeKind
    let definition: any ShapeDefinition
}

/// A standard action as a key a command claims: "the standard action cut" in a conflict.
struct StandardActionKey: Hashable, CustomStringConvertible {
    let action: StandardAction
    var description: String { "the standard action \(action)" }
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

/// Installed ahead of every plugin list: the Hand, undo and redo (Edit › Undo and Redo, AppKit's own
/// items, which text answers first), Insert's first item, a shape of the selection's kind beside it (`.insertBeside`), and
/// zooming, in View (their keys Keyboard gives). Zoom In and
/// Zoom Out are dimmed at the last stop, Actual Size at 100%, and Zoom to Fit with nothing to fit.
/// Paging, the commands of Page Up, Page Down, Home and End (Keyboard's keys too), have no menu
/// item: a key a menu names that no ⌘ is held with would take it from text, where those keys move
/// the caret. They run while the view has a size, Home and End while the board has shapes.
struct CorePlugin: CanvasPlugin {
    var id: PluginID { .core }
    func register(into registrar: inout PluginRegistrar) {
        registrar.tool(ToolDescriptor(id: .hand, label: "Hand", systemImage: "hand.raised")) { _ in HandTool() }
        registrar.command(.undo, title: "Undo", answering: .undo, isEnabled: { $0.editor.canUndo }) { $0.editor.undo() }
        registrar.command(.redo, title: "Redo", answering: .redo, isEnabled: { $0.editor.canRedo }) { $0.editor.redo() }
        // Insert's first item: a shape of the selection's kind beside it (⇧↩, Keyboard's), named for what it will make.
        registrar.command(.insertBeside, title: "New Shape Beside", in: InsertMenu.Shapes.self, placed: .first, runs: .whenIdle,
                          menuTitle: { editor in editor.insertBesideTitle(editor.commandSubject.shapes) },
                          isEnabled: { $0.editor.canInsertBeside($0.shapes) }) { subject in
            if let tool = subject.editor.toolBeside(subject.shapes) { subject.editor.insert(tool, beside: subject.shapes) }
        }
        registrar.command(.zoomIn, title: "Zoom In", in: ViewMenu.Zoom.self, isEnabled: { $0.editor.zoomInStop != nil }) { subject in
            if let stop = subject.editor.zoomInStop { subject.editor.zoom(toPercent: stop) }
        }
        registrar.command(.zoomOut, title: "Zoom Out", in: ViewMenu.Zoom.self, isEnabled: { $0.editor.zoomOutStop != nil }) { subject in
            if let stop = subject.editor.zoomOutStop { subject.editor.zoom(toPercent: stop) }
        }
        registrar.command(.zoomToActualSize, title: "Actual Size", in: ViewMenu.Zoom.self,
                          isEnabled: { $0.editor.zoomPercentage != 100 }) { $0.editor.zoom(toPercent: 100) }
        registrar.command(.zoomToFit, title: "Zoom to Fit", in: ViewMenu.Zoom.self, isEnabled: { $0.editor.canZoomToFit }) { $0.editor.zoomToFit() }
        registrar.command(.pageUp, title: "Page Up", isEnabled: { $0.editor.canPan }) { $0.editor.pan(.up, far: true) }
        registrar.command(.pageDown, title: "Page Down", isEnabled: { $0.editor.canPan }) { $0.editor.pan(.down, far: true) }
        registrar.command(.scrollToStart, title: "Start of Board", isEnabled: { $0.editor.canScrollToEnds }) { $0.editor.scrollToStart() }
        registrar.command(.scrollToEnd, title: "End of Board", isEnabled: { $0.editor.canScrollToEnds }) { $0.editor.scrollToEnd() }
    }
}

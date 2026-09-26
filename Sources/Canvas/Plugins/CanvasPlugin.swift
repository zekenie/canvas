import CoreGraphics

/// A plugin: a value that says what it adds. Plugins are compiled in, and the app's plugin list is
/// the single place that decides which ship.
@MainActor
public protocol CanvasPlugin {
    /// Unique in the plugin list. An instance property, so a function can generate plugins.
    var id: PluginID { get }
    /// Called once, while the registry is built.
    func register(into registrar: inout PluginRegistrar)
}

/// What a plugin registers into. Only the registry makes one, and it's frozen once built.
@MainActor
public struct PluginRegistrar {
    let pluginID: PluginID
    var contributions: [RawContribution] = []

    init(pluginID: PluginID) { self.pluginID = pluginID }

    /// Contributes to any extension point: another plugin's, or the core's.
    public mutating func contribute<P: ExtensionPoint>(_ value: P.Contribution, to point: P.Type, for target: ShapeTarget = .any) {
        contributions.append(RawContribution(value, to: P.self, for: target, from: pluginID))
    }

    /// A shape kind. Everything registered inside `configure` is stamped with the definition's kind.
    public mutating func shape<D: ShapeDefinition>(_ definition: D, _ configure: (inout ShapeRegistrar<D>) -> Void = { _ in }) {
        contribute(ShapeRegistration(kind: D.Props.kind, definition: definition), to: CorePoints.Shapes.self, for: .kind(D.Props.kind))
        var scope = ShapeRegistrar<D>(pluginID: pluginID)
        configure(&scope)
        contributions += scope.contributions
    }

    /// A toolbar tool. `make` runs once per editor, after the editor's services exist, so it may
    /// look them up with `editor.service(S.self)`.
    public mutating func tool(_ descriptor: ToolDescriptor, _ make: @escaping @MainActor (CanvasEditor) -> any Tool) {
        contribute(ToolRegistration(descriptor: descriptor, make: make), to: CorePoints.Tools.self)
    }

    /// Per-editor state: an engine, a cache, timers. Made when the editor is (before any tool), and
    /// found with `editor.service(S.self)`. A service's `make` may look up other services, whatever
    /// their order in the plugin list; it must not touch tools.
    public mutating func service<S: EditorService>(_ make: @escaping @MainActor (CanvasEditor) -> S) {
        contribute(ServiceRegistration(type: S.self, make: make), to: CorePoints.Services.self)
    }

    /// Something drawn above every shape. Overlays draw in plugin order.
    public mutating func overlay(_ overlay: any CanvasOverlay) {
        contribute(overlay, to: CorePoints.Overlays.self)
    }

    /// Runs inside the deleting transaction, before the shapes are removed. It may change other
    /// shapes, and delete more (their handlers run too). Each shape's handlers run once per
    /// transaction, and every shape being deleted still exists while any handler runs.
    public mutating func willDelete(_ handler: @escaping @MainActor (Set<ShapeID>, inout Transaction) -> Void) {
        contribute(handler, to: CorePoints.WillDelete.self)
    }
}

/// Registers things for one shape kind; everything is stamped with that kind.
@MainActor
public struct ShapeRegistrar<Definition: ShapeDefinition> {
    let pluginID: PluginID
    var contributions: [RawContribution] = []

    init(pluginID: PluginID) { self.pluginID = pluginID }

    public var kind: ShapeKind { Definition.Props.kind }

    /// A contribution for this kind. A horizontal plugin publishes its sugar as a `ShapeRegistrar`
    /// extension in its own module, calling this with its own point, so a vertical opts in with
    /// one line (`shape.title { ... }`) and never names the kind.
    public mutating func contribute<P: ExtensionPoint>(_ value: P.Contribution, to point: P.Type) {
        contributions.append(RawContribution(value, to: P.self, for: .kind(kind), from: pluginID))
    }

    /// A toolbar tool that places this shape where the canvas is pressed. Its id is the kind's,
    /// unless you give one (a kind with two place tools needs to).
    public mutating func tool(_ id: ToolID? = nil, label: String, systemImage: String, shortcut: Character? = nil, placing placement: Placement) {
        precondition(placement.kind == kind, "\(kind)'s tool must place \(kind), not \(placement.kind)")
        let descriptor = ToolDescriptor(id: id ?? ToolID(placing: kind), label: label, systemImage: systemImage, shortcut: shortcut)
        contributions.append(RawContribution(ToolRegistration(descriptor: descriptor) { _ in PlaceShapeTool(placement) },
                                             to: CorePoints.Tools.self, for: .any, from: pluginID))
    }

    /// Double-clicking empty canvas with the select tool places this. At most one kind may claim it.
    public mutating func createOnDoubleClick(_ placement: Placement) {
        precondition(placement.kind == kind, "\(kind) can't claim double-click for \(placement.kind)")
        contributions.append(RawContribution(placement, to: CorePoints.DoubleClickPlacement.self, for: .kind(kind), from: pluginID))
    }
}

// Placements, gated by the type system: only box shapes can be placed, and only editable ones can
// be placed straight into editing.
extension ShapeRegistrar where Definition.Props: BoxShapeProps {
    /// Centered where the canvas is pressed, selected, and following the pointer until release.
    public func placement(size: CGSize, props: @escaping @MainActor () -> Definition.Props) -> Placement {
        Placement(kind: kind, size: size, completion: .translate, props: props)
    }
}

extension ShapeRegistrar where Definition: Editable {
    /// Centered where the canvas is pressed, selected, and being edited.
    public func editingPlacement(size: CGSize, props: @escaping @MainActor () -> Definition.Props) -> Placement {
        Placement(kind: kind, size: size, completion: .edit, props: props)
    }
}

public struct ToolDescriptor: Identifiable, Sendable {
    public var id: ToolID
    public var label: String
    public var systemImage: String
    /// An unmodified key, handled by the canvas (typing into a note never switches tools).
    public var shortcut: Character?

    public init(id: ToolID, label: String, systemImage: String, shortcut: Character? = nil) {
        self.id = id
        self.label = label
        self.systemImage = systemImage
        self.shortcut = shortcut
    }
}

/// "Put one of these here": used by place tools and the double-click claim alike.
public struct Placement {
    public let kind: ShapeKind
    let size: CGSize
    let completion: Completion
    let make: @MainActor (CGRect) -> AnyShapeRecord

    enum Completion { case translate, edit }

    init<P: BoxShapeProps>(kind: ShapeKind, size: CGSize, completion: Completion, props: @escaping @MainActor () -> P) {
        self.kind = kind
        self.size = size
        self.completion = completion
        make = { frame in
            var shape = props()
            shape.frame = frame
            return AnyShapeRecord(ShapeRecord(shape))
        }
    }
}

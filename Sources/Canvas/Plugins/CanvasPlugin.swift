import AppKit
import CoreGraphics
import Geometry

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
    /// look them up with `editor.service(S.self)`. `placesShapes`: it puts shapes on the board, as a
    /// kind's tool does (`ShapeRegistrar.tool`), though it places none by a placement of its own (a tool
    /// that puts down a shape built when the pointer lands, a custom shape's): it is dimmed, and its key
    /// does nothing, on a board that takes none (`editor.isToolEnabled`), and a tool in use is left
    /// for the default tool when the board becomes read-only.
    public mutating func tool(_ descriptor: ToolDescriptor, placesShapes: Bool = false,
                              _ make: @escaping @MainActor (CanvasEditor) -> any Tool) {
        contribute(ToolRegistration(descriptor: descriptor, placesShapes: placesShapes, make: make), to: CorePoints.Tools.self)
    }

    /// A menu on a tool's segment of the toolbar (`ToolMenuEntry`): what the toolbar shows when it's
    /// opened, asked of `entries` then, so it lists what the file holds at that moment, never what it
    /// held when the editor was made. A click on the segment still picks the tool; a tool that
    /// remembers a choice made in the menu keeps it in its own service. One menu per tool, and the tool
    /// must be registered (otherwise `RegistryError.invalid`). `editor.toolMenu(for:)` asks it,
    /// `editor.choose(_:)` runs an item.
    public mutating func toolMenu(for tool: ToolID, _ entries: @escaping @MainActor (CanvasEditor) -> [ToolMenuEntry]) {
        contribute(ToolMenuRegistration(tool: tool, entries: entries), to: CorePoints.ToolMenus.self)
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

    /// Shapes (and rects) to outline, asked on every redraw. See `Outlines`.
    public mutating func outlines(_ outlines: @escaping @MainActor (CanvasEditor) -> Outlines) {
        contribute(outlines, to: CorePoints.OutlineSources.self)
    }

    /// What a command does (`editor.perform`): what a menu item runs (Edit › Delete, Go › Back), and
    /// what any key or plugin may run by name; and whether it can now (`editor.canPerform`, which a
    /// menu asks to enable its item): by default, always. At most one plugin may claim each.
    public mutating func command(_ command: CanvasCommand, isEnabled: @escaping @MainActor (CanvasEditor) -> Bool = { _ in true },
                                 _ run: @escaping @MainActor (CanvasEditor) -> Void) {
        contribute(CommandRegistration(command: command, isEnabled: isEnabled, run: run), to: CorePoints.Commands.self)
    }

    /// What a key pressed on the canvas does: return true if it did something with it (or keeps
    /// it); false, and it goes on to AppKit's key bindings, as any view's key would. At most one
    /// plugin may claim it (Keyboard, in the shipped app, whose shortcuts say what every key does);
    /// otherwise no key does anything on the canvas. Keys typed where something else has the
    /// keyboard (a note being edited, a panel's field) never come here.
    public mutating func keyStrokes(_ handle: @escaping @MainActor (CanvasEditor, KeyStroke) -> Bool) {
        contribute(handle, to: CorePoints.KeyStrokes.self)
    }

    /// What a key let go on the canvas does, for a key that does something while it's held (Space's
    /// pan): `release` gets the key, or nil when every key is let go at once (the canvas lost the
    /// keyboard, or its window stopped being key, so no key's release will come). At most one plugin
    /// may claim it (Keyboard, in the shipped app).
    public mutating func keyReleases(_ release: @escaping @MainActor (CanvasEditor, KeyStroke?) -> Void) {
        contribute(release, to: CorePoints.KeyReleases.self)
    }

    /// The tool the editor starts in, and returns to on Escape and after placing a shape (a
    /// registered tool, any plugin's). At most one plugin may claim it; otherwise it's the Hand.
    public mutating func defaultTool(_ id: ToolID) {
        contribute(id, to: CorePoints.DefaultTool.self)
    }

    /// The menu a secondary click (a right-click, or a Control-click) opens at the pointer, made
    /// as the click happens; nil, and the click does nothing. At most one plugin may claim it;
    /// otherwise secondary clicks do nothing. It isn't asked while a press is under way.
    public mutating func menuForSecondaryClick(_ make: @escaping @MainActor (CanvasEditor, Pointer) -> NSMenu?) {
        contribute(make, to: CorePoints.SecondaryClickMenu.self)
    }

    /// Where a drag that moves shapes (a `TranslatingSession`: the selection dragged, a shape just
    /// placed) puts them: `begin` gets the drag as it begins, and returns what each of its events
    /// asks how far to move them, and what draws while it runs (`TranslationAdjuster`), or nil to
    /// leave them following the pointer. At most one plugin may claim it (Snapping, in the shipped
    /// app); otherwise shapes always follow the pointer.
    public mutating func translationAdjuster(_ begin: @escaping @MainActor (CanvasEditor, TranslationStart) -> (any TranslationAdjuster)?) {
        contribute(begin, to: CorePoints.TranslationAdjusters.self)
    }

    /// Runs inside the deleting transaction, before the shapes are removed. It may change other
    /// shapes, and delete more (their handlers run too), read-only ones included: what it does keeps
    /// the board whole, which a lock doesn't stand in the way of. It may change shapes on other boards
    /// of the file too (`transaction.update(_:on:_:)`), read-only ones included, in the same undo
    /// step: one undo brings back what it took back, on every board. Each shape's handlers run once
    /// per transaction, and every shape being deleted still exists while any handler runs.
    public mutating func willDelete(_ handler: @escaping @MainActor (Set<ShapeID>, inout Transaction) -> Void) {
        contribute(handler, to: CorePoints.WillDelete.self)
    }

    /// Shapes that can't change while `isReadOnly` says so of them (Locking's locked shapes): no
    /// transaction changes, restacks or deletes one, a drag leaves it where it is, and it isn't
    /// edited. Each such try is refused, and services hear which shapes it was
    /// (`EditorService.didRefuseChanges`). The change that leaves a shape no longer read-only (the
    /// one that unlocks it) goes through, and so does what a deletion does to keep the board whole:
    /// its `willDelete` handlers' changes (a read-only dependent goes with its shape), and a
    /// read-only shape letting go of one that's deleted (`ShapeReferencing`), which keeps it as it's
    /// drawn. What a read-only shape holds is read-only too, and takes nothing new: what's in it, if
    /// it's a container (a locked frame), and the board it owns, if it owns one, and every board under
    /// that (a locked subboard: entered, but nothing on it changes). The rule reads only the record
    /// it's given: a transaction asks it of a shape before and after a change, and the detail panel of
    /// the record it shows. A transaction asks about every shape it changes, so keep it cheap.
    public mutating func readOnlyShapes(where isReadOnly: @escaping @MainActor (AnyShapeRecord) -> Bool) {
        contribute(isReadOnly, to: CorePoints.ReadOnlyRules.self)
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
    public mutating func tool(_ id: ToolID? = nil, label: String, systemImage: String, placing placement: Placement) {
        tool(id, label: label, systemImage: systemImage, placing: placement) { _ in PlaceShapeTool(placement) }
    }

    /// A toolbar tool that puts this shape down its own way (a drag that draws its rect, as the Frame
    /// tool's does), made per editor by `make`. `placement` is what it places, for the tool to put
    /// down (`editor.place`, a click's) and for what makes shapes without the pointer, which reads
    /// it as the kind's tool's (`registry.placement(for:)`: `canvas draw`). Its id is the kind's,
    /// unless you give one.
    public mutating func tool(_ id: ToolID? = nil, label: String, systemImage: String, placing placement: Placement,
                              _ make: @escaping @MainActor (CanvasEditor) -> any Tool) {
        precondition(placement.kind == kind, "\(kind)'s tool must place \(kind), not \(placement.kind)")
        let descriptor = ToolDescriptor(id: id ?? ToolID(placing: kind), label: label, systemImage: systemImage)
        contributions.append(RawContribution(ToolRegistration(descriptor: descriptor, placement: placement, make: make),
                                             to: CorePoints.Tools.self, for: .any, from: pluginID))
    }

    /// What the kind is called, and its symbol, wherever a shape is shown by its kind (a panel's
    /// header, a row, a message): for a kind no tool places (an arrow, drawn from a port), which is
    /// otherwise called by its id. `registry.label(of:)` reads it.
    public mutating func label(_ name: String, systemImage: String) {
        contribute(KindLabel(name: name, systemImage: systemImage), to: CorePoints.KindLabels.self)
    }
}

// Placements, gated by the type system: only box shapes can be placed, and only editable ones can
// be placed straight into editing.
extension ShapeRegistrar where Definition.Props: BoxShapeProps {
    /// Centered where the canvas is pressed, and following the pointer until release. `minimumSize`:
    /// the smallest its shapes are drawn, whoever draws one (`Placement.minimumSize`).
    public func placement(size: CGSize, minimumSize: CGSize = .zero, props: @escaping @MainActor () -> Definition.Props) -> Placement {
        Placement(kind: kind, size: size, minimumSize: minimumSize, completion: .translate, props: props)
    }
}

extension ShapeRegistrar where Definition: Editable, Definition.Props: BoxShapeProps {
    /// Centered where the canvas is pressed, following the pointer until release, and then being
    /// edited (placed with no press under way, at once).
    public func editingPlacement(size: CGSize, props: @escaping @MainActor () -> Definition.Props) -> Placement {
        Placement(kind: kind, size: size, minimumSize: .zero, completion: .edit, props: props)
    }
}

/// A toolbar tool. Its key, if it has one, is a keyboard shortcut, which the plugin that claims key
/// strokes keeps (Keyboard, in the shipped app).
public struct ToolDescriptor: Identifiable, Sendable {
    public var id: ToolID
    public var label: String
    public var systemImage: String

    public init(id: ToolID, label: String, systemImage: String) {
        self.id = id
        self.label = label
        self.systemImage = systemImage
    }
}

/// What a kind is called, and its symbol, wherever a shape is shown by its kind:
/// `registry.label(of:)`.
public struct KindLabel: Hashable, Sendable {
    public var name: String
    /// An SF Symbol; nil for a kind that has none.
    public var systemImage: String?

    public init(name: String, systemImage: String?) {
        self.name = name
        self.systemImage = systemImage
    }
}

/// "Put one of these here", with `editor.place`: used by place tools, and by any plugin that
/// creates shapes the same way (the select tool's double-click). What a kind's tool places is
/// `registry.placement(for:)`.
public struct Placement {
    public let kind: ShapeKind
    /// The size of what it places.
    public let size: CGSize
    /// The smallest its shapes are drawn, the one place a kind says it, which whatever draws one keeps
    /// to: a tool that draws its shape's rect with a drag (the Frame tool), `canvas draw`, which refuses
    /// a `size:` under it, and the kind's own resizing, which it hands this (`resizable(minimumSize:)`).
    /// Zero for none.
    public let minimumSize: CGSize
    let completion: Completion
    let make: @MainActor (CGRect) -> AnyShapeRecord

    enum Completion { case translate, edit }

    init<P: BoxShapeProps>(kind: ShapeKind, size: CGSize, minimumSize: CGSize, completion: Completion, props: @escaping @MainActor () -> P) {
        self.init(kind: kind, size: size, minimumSize: minimumSize, completion: completion) { frame in
            var shape = props()
            shape.frame = frame
            return AnyShapeRecord(ShapeRecord(shape))
        }
    }

    private init(kind: ShapeKind, size: CGSize, minimumSize: CGSize, completion: Completion, make: @escaping @MainActor (CGRect) -> AnyShapeRecord) {
        self.kind = kind
        self.size = size
        self.minimumSize = minimumSize
        self.completion = completion
        self.make = make
    }

    /// The shape it puts down centered on `point` (what `editor.place` inserts there), in no
    /// document yet: for a plugin that creates shapes some other way than with the pointer (the
    /// command line's `draw`).
    @MainActor
    public func shape(at point: CGPoint) -> AnyShapeRecord {
        make(CGRect(center: point, size: size))
    }

    /// The same placement, with an added property set on every shape it places:
    /// `note.placement(size: size) { StickyNote() }.setting(TitleProperty.self, to: "Zone")`. A
    /// value its kind doesn't opt into is dropped as the shape is placed.
    public func setting<P: ShapeProperty>(_: P.Type, to value: P.Value) -> Placement {
        let make = make
        return Placement(kind: kind, size: size, minimumSize: minimumSize, completion: completion) { frame in
            var record = make(frame)
            record[P.self] = value
            return record
        }
    }
}

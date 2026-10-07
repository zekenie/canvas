import AppKit
import Foundation

/// Everything the installed plugins registered: built once from the plugin list, checked, then
/// frozen and handed to each editor. Tests build their own.
@MainActor
public struct Registry {
    /// Core first, then the plugin list's order.
    let pluginIDs: [PluginID]
    private let byPoint: [ObjectIdentifier: [RawContribution]]
    /// What `contributions(to:for:)` returns, worked out once, since plugins ask per shape (every
    /// shape in a frame, some of them): each kind with contributions of its own to a point, then
    /// every kind's (`forAnyKind`, which is also the answer for a kind with none of its own).
    private let forKind: [ObjectIdentifier: [ShapeKind: [RawContribution]]]
    private let forAnyKind: [ObjectIdentifier: [RawContribution]]
    private let all: [RawContribution]
    private let definitions: [ShapeKind: any ShapeDefinition]
    /// Kinds whose props are bound to other shapes (`ShapeReferencing`): what a deletion asks to
    /// let go, and what a plugin that follows bindings asks (`record.boundShapes(in:)`), so only
    /// these are walked. Not the kinds that only name shapes (`namingKinds`).
    public let referencingKinds: Set<ShapeKind>
    /// Kinds whose shapes can hold names of shapes (`ShapeNaming`): in their own props, or in an
    /// added property they opt into. A copy renames the names of these kinds' shapes, and a plugin
    /// that follows names walks only these (`record.forEachNamingValue`); no other shape holds one.
    public let namingKinds: Set<ShapeKind>
    /// Kinds whose shapes own boards (`BoardOwning`).
    public let boardOwningKinds: Set<ShapeKind>
    /// Kinds whose shapes contain shapes on their own board (`ShapeContaining`: a frame). Without
    /// one, nothing is in a container, and the core does nothing of containment (Containment.swift).
    public let containingKinds: Set<ShapeKind>
    /// Kinds that draw a skeleton of their own (`CustomSkeleton`), found once: a frame zoomed out
    /// asks for every shape it draws.
    let customSkeletons: [ShapeKind: any CustomSkeleton]
    /// Those outlined their own way (`CustomSkeletonOutline`), found once: ⌘A zoomed out outlines
    /// every shape in view, and asks only these.
    let skeletonOutlines: [ShapeKind: any CustomSkeletonOutline]
    /// Those drawn as a line (`StrokedShape`), found once: a tinted outline of an open shape is
    /// stroked to cover its line, and asks only these.
    let strokedShapes: [ShapeKind: any StrokedShape]
    /// Every plugin's rule for which shapes can't change (`registrar.readOnlyShapes`), found once:
    /// a transaction asks them about every shape it changes.
    private let readOnlyRules: [@MainActor (AnyShapeRecord) -> Bool]
    /// The tools that place a kind's shapes (`ShapeRegistrar.tool`): none is enabled on a board that
    /// can't change (`editor.isToolEnabled`).
    let placingTools: Set<ToolID>
    /// Added properties: who declares each, and which kinds opt in.
    let propertyTable: PropertyTable
    /// Each kind's schema (`schema(for:)`), described once, as the registry is built.
    private let schemas: [ShapeKind: JSONSchema]
    /// The same, compiled to check its shapes against (`schemaViolations(of:)`).
    let schemaValidators: [ShapeKind: SchemaValidator]

    public init(plugins: [any CanvasPlugin]) throws(RegistryError) {
        let plugins: [any CanvasPlugin] = [CorePlugin()] + plugins
        var ids: [PluginID] = []
        var contributions: [RawContribution] = []
        for plugin in plugins {
            guard !ids.contains(plugin.id) else { throw .duplicatePlugin(plugin.id) }
            ids.append(plugin.id)
            var registrar = PluginRegistrar(pluginID: plugin.id)
            plugin.register(into: &registrar)
            contributions += registrar.contributions
        }
        try Self.check(contributions, installed: ids)
        pluginIDs = ids
        // Stable: contributions keep plugin order within each point.
        all = ids.flatMap { id in contributions.filter { $0.pluginID == id } }
        byPoint = Dictionary(grouping: all, by: \.point)
        forAnyKind = byPoint.mapValues { $0.filter { $0.target == .any } }
        forKind = byPoint.mapValues { point in
            let anyKind = point.filter { $0.target == .any }
            return Dictionary(grouping: point.filter { $0.target != .any }, by: \.target).reduce(into: [:]) { kinds, own in
                if case .kind(let kind) = own.key { kinds[kind] = own.value + anyKind }
            }
        }
        let shapes = byPoint[ObjectIdentifier(CorePoints.Shapes.self)] ?? []
        definitions = Dictionary(shapes.map {
            let shape = $0.value as! ShapeRegistration
            return (shape.kind, shape.definition)
        }, uniquingKeysWith: { first, _ in first })
        referencingKinds = Set(definitions.filter { $0.value is any ShapeReferencing }.keys)
        boardOwningKinds = Set(definitions.filter { $0.value is any BoardOwning }.keys)
        containingKinds = Set(definitions.filter { $0.value is any ShapeContaining }.keys)
        customSkeletons = definitions.compactMapValues { $0 as? any CustomSkeleton }
        skeletonOutlines = definitions.compactMapValues { $0 as? any CustomSkeletonOutline }
        strokedShapes = definitions.compactMapValues { $0 as? any StrokedShape }
        readOnlyRules = (byPoint[ObjectIdentifier(CorePoints.ReadOnlyRules.self)] ?? []).map { $0.value as! CorePoints.ReadOnlyRules.Contribution }
        placingTools = Set((byPoint[ObjectIdentifier(CorePoints.Tools.self)] ?? []).compactMap {
            let tool = $0.value as! ToolRegistration
            return tool.placement == nil ? nil : tool.descriptor.id
        })
        let declarations = byPoint[ObjectIdentifier(CorePoints.PropertyDeclarations.self)] ?? []
        let table = try PropertyTable(declarations: declarations,
                                      optIns: byPoint[ObjectIdentifier(CorePoints.PropertyOptIns.self)] ?? [],
                                      definitions: definitions,
                                      kinds: shapes.map { ($0.value as! ShapeRegistration).kind })
        propertyTable = table
        namingKinds = Set(definitions.filter { kind, definition in
            definition.propsNameShapes || (table.byKind[kind] ?? []).contains { table.codecs[$0]?.naming != nil }
        }.keys)
        // Every declared property's schema, and every kind's, is described and compiled once now, so
        // that what can't be described (two types under one name, a struct that holds itself in
        // place), a member some struct doesn't list (which a board would never save), and a schema
        // that can't be checked against (a `$ref` to nowhere, or back to itself without end, a
        // pattern that isn't a regular expression) refuse the plugin list now, not at the first save,
        // or as a warning on every shape of the kind. Properties first, so a problem in a property's
        // value is its declarer's, not that of the first kind that opts in.
        for c in declarations {
            let codec = (c.value as! PropertyDeclaration).codec
            var described = SchemaDefinitions()
            var json = codec.schema(&described)
            if !described.json.isEmpty { json["$defs"] = .object(described.json) }
            let problems = (codec.holdsOptionals ? ["its value is an optional, or holds optionals in a collection, which a schema can't say"] : [])
                + (codec.defaultValue.map(codec.isNone) == true ? ["its default is a value that's none (isNone), which no shape holds"] : [])
                + Self.problems(of: described) + SchemaValidator(JSONSchema(json)).problems.map { "its schema is broken: \($0)" }
            if let problem = problems.first {
                throw .invalid(point: c.pointName, reason: "property \(codec.key) (from \(c.pluginID)): \(problem)")
            }
        }
        var schemas: [ShapeKind: JSONSchema] = [:], validators: [ShapeKind: SchemaValidator] = [:]
        for c in shapes {
            let shape = c.value as! ShapeRegistration
            var described = SchemaDefinitions()
            let schema = Self.schema(of: shape.kind, defined: shape.definition, properties: propertyTable, in: &described)
            let validator = SchemaValidator(schema)
            if let problem = Self.problems(of: described, props: shape.definition.propsType).first
                ?? validator.problems.first.map({ "its schema is broken: \($0)" }) {
                throw .invalid(point: c.pointName, reason: "\(shape.kind) (from \(c.pluginID)): \(problem)")
            }
            schemas[shape.kind] = schema
            validators[shape.kind] = validator
        }
        self.schemas = schemas
        schemaValidators = validators
        // Owners are installed and keys unique by now, so a point's own rules can rely on both.
        var checked: Set<ObjectIdentifier> = []
        for c in all where checked.insert(c.point).inserted {
            do { try c.pointType.check(self) }
            catch let error as RegistryError { throw error }
            catch { throw .invalid(point: c.pointName, reason: "\(error)") }
        }
    }

    private static func check(_ contributions: [RawContribution], installed: [PluginID]) throws(RegistryError) {
        let kinds = Set(contributions.filter { $0.point == ObjectIdentifier(CorePoints.Shapes.self) }.map(\.target))
        var claimed: [ObjectIdentifier: [AnyHashable: PluginID]] = [:]
        for c in contributions {
            guard installed.contains(c.owner) else {
                throw .ownerNotInstalled(point: c.pointName, owner: c.owner, contributor: c.pluginID)
            }
            if case .kind(let kind) = c.target, !kinds.contains(c.target) {
                throw .unknownKind(kind, point: c.pointName, contributor: c.pluginID)
            }
            for key in c.keys {
                if let first = claimed[c.point]?[key] {
                    throw .conflict(point: c.pointName, key: "\(key.base)", plugins: [first, c.pluginID])
                }
                claimed[c.point, default: [:]][key] = c.pluginID
            }
        }
    }

    // MARK: Extension points

    /// Every contribution to a point, in plugin order.
    public func contributions<P: ExtensionPoint>(to point: P.Type) -> [Contributed<P.Contribution>] {
        (byPoint[ObjectIdentifier(P.self)] ?? []).map { Contributed(value: $0.value as! P.Contribution, target: $0.target, pluginID: $0.pluginID) }
    }

    /// The contributions that apply to a kind: those for that kind, then those for every kind,
    /// each in plugin order.
    public func contributions<P: ExtensionPoint>(to point: P.Type, for kind: ShapeKind) -> [P.Contribution] {
        let point = ObjectIdentifier(P.self)
        // A closure, not `\.value`: a key path in a generic function is built again on every call.
        return (forKind[point]?[kind] ?? forAnyKind[point] ?? []).map { $0.value as! P.Contribution }
    }

    /// For a point that takes one contribution per kind, plus one for every kind (keyed by
    /// `[target]`, as a rule is): each installed kind's own, else every kind's. A kind with neither
    /// isn't in it. Worked out on each call: keep what it returns, as the registry never changes.
    public func contributionByKind<P: ExtensionPoint>(to point: P.Type) -> [ShapeKind: P.Contribution] {
        kinds.reduce(into: [:]) { byKind, kind in byKind[kind] = contributions(to: P.self, for: kind).first }
    }

    // MARK: The core's points

    public var kinds: [ShapeKind] { contributions(to: CorePoints.Shapes.self).map(\.value.kind) }

    public func definition(for kind: ShapeKind) -> (any ShapeDefinition)? { definitions[kind] }

    /// A shape's outline as its kind draws it (its kind's `indicatorPath`), in world units: on the
    /// shape's own edge, which the core grows outward before it strokes a selection, a hover or the
    /// hint (`CanvasEditor.outlinePath(of:)`, `outlineGap`). For an overlay that decorates a shape
    /// along it and grows the outline itself (Validation's ring). Nil for a shape kept aside, or of
    /// a kind no plugin defines.
    public func indicatorPath(of shape: AnyShapeRecord, in context: ShapeContext) -> CGPath? {
        shape.isOpaque ? nil : definition(for: shape.kind)?.erasedIndicatorPath(of: shape, in: context)
    }

    /// How wide a shape's line is drawn, in world units, if its kind is drawn as a line
    /// (`StrokedShape`): what the canvas covers it with when it's lit (`Outlines.tinted`), and what an
    /// overlay that decorates the line goes by. Nil for any other kind, a shape kept aside, or one of
    /// a kind no plugin defines.
    public func lineWidth(of shape: AnyShapeRecord, in context: ShapeContext) -> CGFloat? {
        shape.isOpaque ? nil : strokedShapes[shape.kind]?.erasedLineWidth(of: shape, in: context)
    }

    /// Whether a shape's board can be shown wherever the shape's own board can: it isn't kept
    /// aside, and its kind owns boards (`BoardOwning`). What `canShow` asks of every owner on a
    /// board's path, so what walks a file's boards from the root down asks it too.
    public func ownsShowableBoard(_ shape: AnyShapeRecord) -> Bool { !shape.isOpaque && boardOwningKinds.contains(shape.kind) }

    /// Whether a plugin's rule says the shape can't change (`registrar.readOnlyShapes`), by the record
    /// alone: what a rule says of one shape. A shape in a read-only container is read-only too, which
    /// this doesn't see: what goes by a shape in its board asks `isReadOnly(_:in:)`.
    public func isReadOnly(_ shape: AnyShapeRecord) -> Bool {
        readOnlyRules.contains { $0(shape) }
    }

    /// Whether any installed plugin says some shapes can't change: without one, nothing need ask.
    var hasReadOnlyRules: Bool { !readOnlyRules.isEmpty }

    /// A kind's properties as one JSON Schema (draft 2020-12): an object with each of its own
    /// properties, then each added property it opts into (marked with its owner, `x-canvas-owner`),
    /// with their types, defaults and constraints; only those marked `required()` required, and nothing
    /// else allowed; a kind whose shapes own boards (`BoardOwning`) is marked `x-canvas-board`. Shared
    /// definitions are under `$defs`, named after their modules (`core.rect`, `mentions.text`),
    /// and every `$ref` is local. It describes a shape as one object, own and added properties side
    /// by side (a board keeps the two apart). Nil for a kind no plugin registers.
    public func schema(for kind: ShapeKind) -> JSONSchema? { schemas[kind] }

    /// A kind's schema, as `schema(for:)` has it: its own properties and those it opts into, as an
    /// object schema, with the definitions they share, which `shared` holds too.
    private static func schema(of kind: ShapeKind, defined definition: any ShapeDefinition, properties table: PropertyTable,
                               in shared: inout SchemaDefinitions) -> JSONSchema {
        var json = definition.propsSchema(in: &shared)
        var properties = json["properties"]?.objectValue ?? [:]
        for key in table.byKind[kind] ?? [] {
            guard let codec = table.codecs[key], let owner = table.owners[key] else { continue }
            var property = codec.schema(&shared)
            property["x-canvas-owner"] = .string(owner.rawValue)
            if let value = codec.defaultValue, let encoded = try? JSONValue(encoding: value) { property["default"] = encoded }
            properties[key.rawValue] = .object(property)
        }
        json["properties"] = .object(properties)
        if definition is any BoardOwning { json["x-canvas-board"] = true }
        if json["title"] == nil { json["title"] = .string(kind.rawValue) }
        json["$schema"] = .string(JSONSchema.dialect)
        json["$id"] = .string("tag:infinite-canvas,2026:kinds/\(kind)")
        if !shared.json.isEmpty { json["$defs"] = .object(shared.json) }
        return JSONSchema(json)
    }

    /// What describing found wrong, then what's wrong with the list of each struct it described, in
    /// the order it met them (a kind's own props first), and whether one that holds names of shapes
    /// doesn't adopt `ShapeNaming`: every struct but the kind's `props`, which is walked by its list.
    private static func problems(of described: SchemaDefinitions, props: (any ShapeProps.Type)? = nil) -> [String] {
        described.problems + described.described.flatMap { type in
            let isProps = props.map { ObjectIdentifier($0) == ObjectIdentifier(type) } ?? false
            return propertyListProblems(of: type) + (isProps ? [] : namingProblems(of: type))
        }
    }

    /// The added properties installed plugins declare.
    public var declaredProperties: [PropertyKey] {
        contributions(to: CorePoints.PropertyDeclarations.self).map(\.value.codec.key)
    }

    /// The added properties a kind opts into, in plugin order.
    public func properties(for kind: ShapeKind) -> [PropertyKey] { propertyTable.byKind[kind] ?? [] }

    /// The plugin that declares an added property.
    public func owner(of property: PropertyKey) -> PluginID? { propertyTable.owners[property] }

    /// The document with every shape as its kind has it: each added property its kind opts into
    /// that has a default, and that the shape has no value for, set to the default. What an editor
    /// does to a document it's given, and what opening a board does.
    public func fillingDefaults(_ document: CanvasDocument) -> CanvasDocument {
        var document = document
        for (index, record) in document.shapes.enumerated() {
            let normalized = propertyTable.normalized(record)
            if normalized != record { document.replace(at: index, with: normalized) }
        }
        return document
    }

    /// The file with every board's shapes as their kinds have them (`fillingDefaults(_:)` of each).
    public func fillingDefaults(_ file: CanvasFile) -> CanvasFile {
        var file = file
        file.transformBoards { fillingDefaults($0) }
        return file
    }

    /// The toolbar: the default tool, then the rest in plugin order (the core's Hand first).
    public var tools: [ToolDescriptor] {
        let all = contributions(to: CorePoints.Tools.self).map(\.value.descriptor)
        let lead = defaultTool
        return all.filter { $0.id == lead } + all.filter { $0.id != lead }
    }

    /// Where the editor starts, and returns to on Escape and after placing a shape: the tool a
    /// plugin claimed (`registrar.defaultTool`), else the Hand.
    public var defaultTool: ToolID { contributions(to: CorePoints.DefaultTool.self).first?.value ?? .hand }

    /// What the kind's tool places (the first tool's, if several place it): its size and its
    /// props. Nil for a kind no tool places (an arrow), or one a tool draws instead (a line).
    public func placement(for kind: ShapeKind) -> Placement? {
        contributions(to: CorePoints.Tools.self).lazy.compactMap(\.value.placement).first { $0.kind == kind }
    }

    /// What a kind is called, and its symbol, wherever a shape is shown by its kind (a panel's
    /// header, a row, a message): what it declares (`ShapeRegistrar.label`), else its placing
    /// tool's label and symbol ("Note"), else its id, with no symbol.
    public func label(of kind: ShapeKind) -> KindLabel {
        if let declared = contributions(to: CorePoints.KindLabels.self, for: kind).first { return declared }
        let placing = ToolID(placing: kind)
        if let tool = contributions(to: CorePoints.Tools.self).first(where: { $0.value.descriptor.id == placing })?.value.descriptor {
            return KindLabel(name: tool.label, systemImage: tool.systemImage)
        }
        return KindLabel(name: kind.rawValue, systemImage: nil)
    }

    var toolFactories: [(ToolID, @MainActor (CanvasEditor) -> any Tool)] {
        contributions(to: CorePoints.Tools.self).map { ($0.value.descriptor.id, $0.value.make) }
    }
    var services: [ServiceRegistration] { contributions(to: CorePoints.Services.self).map(\.value) }
    var overlays: [any CanvasOverlay] { contributions(to: CorePoints.Overlays.self).map(\.value) }
    var willDeleteHandlers: [@MainActor (Set<ShapeID>, inout Transaction) -> Void] {
        contributions(to: CorePoints.WillDelete.self).map(\.value)
    }
    var outlineSources: [@MainActor (CanvasEditor) -> Outlines] { contributions(to: CorePoints.OutlineSources.self).map(\.value) }
    func command(_ command: CanvasCommand) -> CommandRegistration? {
        contributions(to: CorePoints.Commands.self).first { $0.value.command == command }?.value
    }

    /// Whether a plugin (or the core) claims the command, so `editor.perform` can run it.
    public func claims(_ command: CanvasCommand) -> Bool { self.command(command) != nil }
    var secondaryClickMenu: (@MainActor (CanvasEditor, Pointer) -> NSMenu?)? {
        contributions(to: CorePoints.SecondaryClickMenu.self).first?.value
    }
    var keyStrokeHandler: (@MainActor (CanvasEditor, KeyStroke) -> Bool)? {
        contributions(to: CorePoints.KeyStrokes.self).first?.value
    }
    var keyReleaseHandler: (@MainActor (CanvasEditor, KeyStroke?) -> Void)? {
        contributions(to: CorePoints.KeyReleases.self).first?.value
    }
    var translationAdjuster: (@MainActor (CanvasEditor, TranslationStart) -> (any TranslationAdjuster)?)? {
        contributions(to: CorePoints.TranslationAdjusters.self).first?.value
    }

    /// Who contributes what, where: the runtime counterpart of Package.swift. A test pins it.
    public var report: String {
        let width = max(14, (pluginIDs.map(\.rawValue.count).max() ?? 0) + 2)
        return pluginIDs.map { id in
            let items = all.filter { $0.pluginID == id }.map(\.summary)
            return "\(id.rawValue.padding(toLength: width, withPad: " ", startingAt: 0))\(items.joined(separator: " · "))"
        }.joined(separator: "\n")
    }
}

public enum RegistryError: Error, Equatable, CustomStringConvertible {
    case duplicatePlugin(PluginID)
    /// Contributing to a point whose owning plugin isn't in the list.
    case ownerNotInstalled(point: String, owner: PluginID, contributor: PluginID)
    /// A contribution for a shape kind no plugin registers.
    case unknownKind(ShapeKind, point: String, contributor: PluginID)
    /// Two contributions claim the same key (a kind, a tool id, a keyboard shortcut, ...).
    case conflict(point: String, key: String, plugins: [PluginID])
    /// A point's own `check` refused the plugin list.
    case invalid(point: String, reason: String)

    public var description: String {
        switch self {
        case .duplicatePlugin(let id): "plugin \(id) is installed twice"
        case .ownerNotInstalled(let point, let owner, let contributor):
            "\(contributor) contributes to \(point), but \(owner), which owns it, isn't installed"
        case .unknownKind(let kind, let point, let contributor):
            "\(contributor) contributes to \(point) for kind \(kind), which no plugin registers"
        case .conflict(let point, let key, let plugins):
            "\(plugins.map(\.rawValue).joined(separator: " and ")) both claim \(key) in \(point)"
        case .invalid(let point, let reason): "\(point): \(reason)"
        }
    }
}

/// A contribution as stored: the value is opaque to the core.
@MainActor
struct RawContribution {
    let pointType: any ExtensionPoint.Type
    let pluginID: PluginID
    let target: ShapeTarget
    let value: Any
    let keys: [AnyHashable]
    let summary: String

    var point: ObjectIdentifier { ObjectIdentifier(pointType) }
    var pointName: String { "\(pointType)" }
    var owner: PluginID { pointType.owner }

    init<P: ExtensionPoint>(_ value: P.Contribution, to _: P.Type, for target: ShapeTarget, from plugin: PluginID) {
        pointType = P.self
        pluginID = plugin
        self.target = target
        self.value = value
        keys = (P.self as? any KeyedExtensionPoint.Type).map { Self.keys(of: value, for: target, claimedIn: $0) } ?? []
        summary = switch value {
        case let shape as ShapeRegistration:
            // A kind's version shows once it has one, so the pinned report shows every bump.
            "shape \(shape.kind)" + (shape.definition.kindCodec.version > 0 ? " v\(shape.definition.kindCodec.version)" : "")
        case let tool as ToolRegistration: "tool \(tool.descriptor.id)"
        case let service as ServiceRegistration: "service \(service.name)"
        case let overlay as any CanvasOverlay: "overlay \(type(of: overlay))"
        case let command as CommandRegistration: "command \(command.command)"
        case let declaration as PropertyDeclaration:
            "property \(declaration.codec.key)" + (declaration.codec.version > 0 ? " v\(declaration.codec.version)" : "")
        case let optIn as PropertyOptIn: "property \(optIn.key) → \(target == .any ? "every shape" : "\(target)")"
        case let label as KindLabel: "label \(label.name) → \(target)"
        default:
            switch P.self {
            case is CorePoints.WillDelete.Type: "willDelete"
            case is CorePoints.ReadOnlyRules.Type: "read-only shapes"
            case is CorePoints.OutlineSources.Type: "outlines"
            case is CorePoints.DefaultTool.Type: "default tool \(value)"
            case is CorePoints.SecondaryClickMenu.Type: "secondary-click menu"
            case is CorePoints.KeyStrokes.Type: "key strokes"
            case is CorePoints.KeyReleases.Type: "key releases"
            case is CorePoints.TranslationAdjusters.Type: "translation adjuster"
            default: P.summary(of: value, for: target)
            }
        }
    }

    private static func keys<K: KeyedExtensionPoint>(of value: Any, for target: ShapeTarget, claimedIn _: K.Type) -> [AnyHashable] {
        K.uniqueKeys(of: value as! K.Contribution, for: target)
    }
}

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
    /// Kinds whose props name other shapes (`ShapeReferencing`): what a deletion asks to let go.
    let referencingKinds: Set<ShapeKind>
    /// Added properties: who declares each, and which kinds opt in.
    let propertyTable: PropertyTable

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
        let declarations = byPoint[ObjectIdentifier(CorePoints.PropertyDeclarations.self)] ?? []
        propertyTable = try PropertyTable(declarations: declarations,
                                          optIns: byPoint[ObjectIdentifier(CorePoints.PropertyOptIns.self)] ?? [],
                                          definitions: definitions,
                                          kinds: shapes.map { ($0.value as! ShapeRegistration).kind })
        // Every declared property's schema, and every kind's, is described once now, so that what
        // can't be (two types under one name, a struct that holds itself in place) and a member some
        // struct doesn't list (which a board would never save) refuse the plugin list now, not at the
        // first save or the first schema asked for. Properties first, so a problem in a property's
        // value is its declarer's, not that of the first kind that opts in.
        for c in declarations {
            let codec = (c.value as! PropertyDeclaration).codec
            var described = SchemaDefinitions()
            _ = codec.schema(&described)
            let problems = (codec.holdsOptionals ? ["its value is an optional, or holds optionals in a collection, which a schema can't say"] : [])
                + Self.problems(of: described)
            if let problem = problems.first {
                throw .invalid(point: c.pointName, reason: "property \(codec.key) (from \(c.pluginID)): \(problem)")
            }
        }
        for c in shapes {
            let shape = c.value as! ShapeRegistration
            var described = SchemaDefinitions()
            _ = composedSchema(of: shape.kind, in: &described)
            if let problem = Self.problems(of: described).first {
                throw .invalid(point: c.pointName, reason: "\(shape.kind) (from \(c.pluginID)): \(problem)")
            }
        }
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

    /// A kind's properties as one JSON Schema (draft 2020-12): an object with each of its own
    /// properties, then each added property it opts into (marked with its owner, `x-canvas-owner`),
    /// with their types, defaults and constraints; only those marked `required()` required, and nothing
    /// else allowed. Shared definitions are under `$defs`, named after their modules (`core.rect`,
    /// `checklists.item`), and every `$ref` is local. It describes a shape as one object, own and
    /// added properties side by side (a board keeps the two apart). Nil for a kind no plugin
    /// registers.
    public func schema(for kind: ShapeKind) -> JSONSchema? {
        var shared = SchemaDefinitions()
        guard var json = composedSchema(of: kind, in: &shared) else { return nil }
        json["$schema"] = .string(JSONSchema.dialect)
        json["$id"] = .string("tag:infinite-canvas,2026:kinds/\(kind)")
        if !shared.json.isEmpty { json["$defs"] = .object(shared.json) }
        return JSONSchema(json)
    }

    /// The kind's own properties and those it opts into, as an object schema, with the definitions
    /// they share in `shared`.
    private func composedSchema(of kind: ShapeKind, in shared: inout SchemaDefinitions) -> JSONObject? {
        guard let definition = definitions[kind] else { return nil }
        var json = definition.propsSchema(in: &shared)
        var properties = json["properties"]?.objectValue ?? [:]
        for key in propertyTable.byKind[kind] ?? [] {
            guard let codec = propertyTable.codecs[key], let owner = propertyTable.owners[key] else { continue }
            var property = codec.schema(&shared)
            property["x-canvas-owner"] = .string(owner.rawValue)
            if let value = codec.defaultValue, let encoded = try? JSONValue(encoding: value) { property["default"] = encoded }
            properties[key.rawValue] = .object(property)
        }
        json["properties"] = .object(properties)
        if json["title"] == nil { json["title"] = .string(kind.rawValue) }
        return json
    }

    /// What describing found wrong, then what's wrong with the list of each struct it described, in
    /// the order it met them (a kind's own props first).
    private static func problems(of described: SchemaDefinitions) -> [String] {
        described.problems + described.described.flatMap { propertyListProblems(of: $0) }
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

    /// The toolbar: the default tool, then the rest in plugin order (the core's Hand first).
    public var tools: [ToolDescriptor] {
        let all = contributions(to: CorePoints.Tools.self).map(\.value.descriptor)
        let lead = defaultTool
        return all.filter { $0.id == lead } + all.filter { $0.id != lead }
    }

    /// Where the editor starts, and returns to on Escape and after placing a shape: the tool a
    /// plugin claimed (`registrar.defaultTool`), else the Hand.
    public var defaultTool: ToolID { contributions(to: CorePoints.DefaultTool.self).first?.value ?? .hand }

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
    var secondaryClickMenu: (@MainActor (CanvasEditor, Pointer) -> NSMenu?)? {
        contributions(to: CorePoints.SecondaryClickMenu.self).first?.value
    }
    var keyStrokeHandler: (@MainActor (CanvasEditor, KeyStroke) -> Bool)? {
        contributions(to: CorePoints.KeyStrokes.self).first?.value
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
        default:
            switch P.self {
            case is CorePoints.WillDelete.Type: "willDelete"
            case is CorePoints.OutlineSources.Type: "outlines"
            case is CorePoints.DefaultTool.Type: "default tool \(value)"
            case is CorePoints.SecondaryClickMenu.Type: "secondary-click menu"
            case is CorePoints.KeyStrokes.Type: "key strokes"
            default: P.summary(of: value, for: target)
            }
        }
    }

    private static func keys<K: KeyedExtensionPoint>(of value: Any, for target: ShapeTarget, claimedIn _: K.Type) -> [AnyHashable] {
        K.uniqueKeys(of: value as! K.Contribution, for: target)
    }
}

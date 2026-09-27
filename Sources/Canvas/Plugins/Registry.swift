import AppKit
import Foundation

/// Everything the installed plugins registered: built once from the plugin list, checked, then
/// frozen and handed to each editor. Tests build their own.
@MainActor
public struct Registry {
    /// Core first, then the plugin list's order.
    let pluginIDs: [PluginID]
    private let byPoint: [ObjectIdentifier: [RawContribution]]
    private let all: [RawContribution]
    private let definitions: [ShapeKind: any ShapeDefinition]

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
        definitions = Dictionary((byPoint[ObjectIdentifier(CorePoints.Shapes.self)] ?? []).map {
            let shape = $0.value as! ShapeRegistration
            return (shape.kind, shape.definition)
        }, uniquingKeysWith: { first, _ in first })
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
        let all = contributions(to: P.self)
        return all.filter { $0.target == .kind(kind) }.map(\.value) + all.filter { $0.target == .any }.map(\.value)
    }

    // MARK: The core's points

    public var kinds: [ShapeKind] { contributions(to: CorePoints.Shapes.self).map(\.value.kind) }

    public func definition(for kind: ShapeKind) -> (any ShapeDefinition)? { definitions[kind] }

    /// The toolbar: the default tool, then the rest in plugin order (the core's Hand first).
    public var tools: [ToolDescriptor] {
        let all = contributions(to: CorePoints.Tools.self).map(\.value.descriptor)
        let lead = defaultTool
        return all.filter { $0.id == lead } + all.filter { $0.id != lead }
    }

    /// Where the editor starts, and returns to on Escape and after placing a shape: the tool a
    /// plugin claimed (`registrar.defaultTool`), else the Hand.
    public var defaultTool: ToolID { contributions(to: CorePoints.DefaultTool.self).first?.value ?? .hand }

    public func tool(forShortcut key: Character) -> ToolID? {
        let key = Character(key.lowercased())
        return tools.first { $0.shortcut.map { Character($0.lowercased()) } == key }?.id
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
    func command(_ command: CanvasCommand) -> (@MainActor (CanvasEditor) -> Void)? {
        contributions(to: CorePoints.Commands.self).first { $0.value.command == command }?.value.run
    }
    var secondaryClickMenu: (@MainActor (CanvasEditor, Pointer) -> NSMenu?)? {
        contributions(to: CorePoints.SecondaryClickMenu.self).first?.value
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
    /// Two contributions claim the same key (a kind, a tool id, a shortcut, ...).
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
        case let tool as ToolRegistration: "tool \(tool.descriptor.id)" + (tool.descriptor.shortcut.map { " [\($0)]" } ?? "")
        case let service as ServiceRegistration: "service \(service.name)"
        case let overlay as any CanvasOverlay: "overlay \(type(of: overlay))"
        case let command as CommandRegistration: "command \(command.command)"
        default:
            switch P.self {
            case is CorePoints.WillDelete.Type: "willDelete"
            case is CorePoints.OutlineSources.Type: "outlines"
            case is CorePoints.DefaultTool.Type: "default tool \(value)"
            case is CorePoints.SecondaryClickMenu.Type: "secondary-click menu"
            default: "\(P.self)" + (target == .any ? "" : " → \(target)")
            }
        }
    }

    private static func keys<K: KeyedExtensionPoint>(of value: Any, for target: ShapeTarget, claimedIn _: K.Type) -> [AnyHashable] {
        K.uniqueKeys(of: value as! K.Contribution, for: target)
    }
}

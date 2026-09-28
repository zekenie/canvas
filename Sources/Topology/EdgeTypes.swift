import Canvas

/// An edge type as declared: its id, and its parent, which may follow from the registry as built (a
/// channel's type is under whatever family the connector draws: Ports). Only the sugar makes one.
@MainActor
public struct EdgeTypeDeclaration {
    public let id: EdgeTypeID
    let parent: @MainActor (Registry) -> EdgeTypeID?
}

/// The edge types plugins declare. Each id once: two declarations of one is
/// `RegistryError.conflict`. A parent must be declared, and no type may be under itself.
public enum EdgeTypes {}

extension EdgeTypes: KeyedExtensionPoint {
    public typealias Contribution = EdgeTypeDeclaration
    public static var owner: PluginID { .topology }
    public static func uniqueKeys(of type: EdgeTypeDeclaration, for _: ShapeTarget) -> [AnyHashable] { [EdgeTypeKey(id: type.id)] }
    public static func summary(of type: EdgeTypeDeclaration, for _: ShapeTarget) -> String { "edge type \(type.id)" }

    /// Every parent is a type some installed plugin declares, and going up from any type never comes
    /// back to it.
    public static func check(_ registry: Registry) throws(RegistryError) {
        let declared = registry.contributions(to: EdgeTypes.self)
        var parents: [EdgeTypeID: EdgeTypeID] = [:]
        for type in declared {
            guard let parent = type.value.parent(registry) else { continue }
            guard declared.contains(where: { $0.value.id == parent }) else {
                throw .invalid(point: "EdgeTypes", reason: "\(type.pluginID) declares edge type \(type.value.id) under \(parent), which no installed plugin declares")
            }
            parents[type.value.id] = parent
        }
        for type in declared {
            var chain = [type.value.id], met: Set<EdgeTypeID> = [type.value.id]
            var current = type.value.id
            while let parent = parents[current] {
                chain.append(parent)
                guard met.insert(parent).inserted else {
                    throw .invalid(point: "EdgeTypes", reason: "\(type.pluginID) declares edge type \(type.value.id) under itself: \(chain.map(\.rawValue).joined(separator: " → "))")
                }
                current = parent
            }
        }
    }
}

struct EdgeTypeKey: Hashable, CustomStringConvertible {
    let id: EdgeTypeID
    var description: String { "edge type \(id)" }
}

extension PluginRegistrar {
    /// Declares an edge type this plugin owns, under its `parent`, if it has one.
    public mutating func edgeType<T: EdgeType>(_ type: T.Type) {
        let parent = T.parent
        contribute(EdgeTypeDeclaration(id: T.id, parent: { _ in parent }), to: EdgeTypes.self)
    }

    /// Declares an edge type whose parent follows from the registry as built: a channel's, whose
    /// family is the one the connector draws (nil, a root, without one). Asked once the registry is
    /// built (its points' keys unique, their owners installed), and never again changes.
    public mutating func edgeType(_ id: EdgeTypeID, parent: @escaping @MainActor (Registry) -> EdgeTypeID?) {
        contribute(EdgeTypeDeclaration(id: id, parent: parent), to: EdgeTypes.self)
    }
}

// MARK: The tree

/// The edge types installed plugins declare, as a tree: each type's parent, children and the plugin
/// that declares it. Worked out from a registry once (`registry.edgeTypes`, or an editor's
/// `topology.types`, which keeps it), since the registry never changes. A type no plugin declares is
/// a root with nothing under it.
public struct EdgeTypeTree: Sendable {
    /// Every declared type, in plugin order.
    public let declared: [EdgeTypeID]
    private let parents: [EdgeTypeID: EdgeTypeID]
    private let childrenByType: [EdgeTypeID: [EdgeTypeID]]
    private let plugins: [EdgeTypeID: PluginID]
    private let order: [EdgeTypeID: Int]

    @MainActor
    public init(_ registry: Registry) {
        let declarations = registry.contributions(to: EdgeTypes.self)
        var declared: [EdgeTypeID] = [], parents: [EdgeTypeID: EdgeTypeID] = [:], plugins: [EdgeTypeID: PluginID] = [:]
        for declaration in declarations where plugins[declaration.value.id] == nil {
            declared.append(declaration.value.id)
            plugins[declaration.value.id] = declaration.pluginID
            if let parent = declaration.value.parent(registry) { parents[declaration.value.id] = parent }
        }
        var children: [EdgeTypeID: [EdgeTypeID]] = [:]
        for type in declared {
            if let parent = parents[type] { children[parent, default: []].append(type) }
        }
        self.declared = declared
        self.parents = parents
        self.plugins = plugins
        childrenByType = children
        order = Dictionary(uniqueKeysWithValues: declared.enumerated().map { ($1, $0) })
    }

    /// Whether some installed plugin declares `type`.
    public func isDeclared(_ type: EdgeTypeID) -> Bool { plugins[type] != nil }

    /// The plugin that declares `type`; nil for one nobody declares.
    public func plugin(declaring type: EdgeTypeID) -> PluginID? { plugins[type] }

    /// The type `type` is a kind of; nil for a root, and for a type nobody declares.
    public func parent(of type: EdgeTypeID) -> EdgeTypeID? { parents[type] }

    /// The types right under `type`, in plugin order.
    public func children(of type: EdgeTypeID) -> [EdgeTypeID] { childrenByType[type] ?? [] }

    /// The types above `type`, its parent first.
    public func ancestors(of type: EdgeTypeID) -> [EdgeTypeID] {
        var found: [EdgeTypeID] = [], met: Set<EdgeTypeID> = [type], current = type
        while let parent = parents[current], met.insert(parent).inserted {
            found.append(parent)
            current = parent
        }
        return found
    }

    /// Every type under `type`, at any depth (not `type` itself), in plugin order.
    public func descendants(of type: EdgeTypeID) -> [EdgeTypeID] {
        var found: Set<EdgeTypeID> = [], next = [type]
        while let current = next.popLast() {
            for child in children(of: current) where child != type && found.insert(child).inserted { next.append(child) }
        }
        return found.sorted { order[$0]! < order[$1]! }
    }

    /// Where a type goes among others: declared ones in plugin order, then the rest by name.
    func precedes(_ a: EdgeTypeID, _ b: EdgeTypeID) -> Bool {
        switch (order[a], order[b]) {
        case let (x?, y?): x < y
        case (.some, nil): true
        case (nil, .some): false
        case (nil, nil): a.rawValue < b.rawValue
        }
    }
}

extension Registry {
    /// The edge types installed plugins declare, as a tree: worked out on each call, so keep it (an
    /// editor's is `topology.types`).
    public var edgeTypes: EdgeTypeTree { EdgeTypeTree(self) }

    /// Whether some installed plugin declares `type`, without working out the tree: one pass over
    /// the declarations.
    public func declaresEdgeType(_ type: EdgeTypeID) -> Bool {
        contributions(to: EdgeTypes.self).contains { $0.value.id == type }
    }
}

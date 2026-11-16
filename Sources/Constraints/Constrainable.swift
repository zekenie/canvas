import Canvas

// Which kinds hold a list of constraints of their own: only kinds that hold shapes or own a board, since a constraint is
// a place's (`constrainable()`).

extension PluginID {
    public static let constraints: PluginID = "constraints"
}

/// The kinds whose shapes hold constraints of their own (`ConstraintsProperty`), one contribution a kind: only a kind
/// that holds shapes on its board (`ShapeContaining`, a frame) or owns a board (`BoardOwning`, a subboard), since a
/// constraint is a place's. The report's `constrainable → frame`.
public enum ConstrainableKinds {}

extension ConstrainableKinds: KeyedExtensionPoint {
    public typealias Contribution = Constrainable
    public static var owner: PluginID { .constraints }
    public static func uniqueKeys(of _: Constrainable, for target: ShapeTarget) -> [AnyHashable] { [target] }
    public static func summary(of _: Constrainable, for target: ShapeTarget) -> String { "constrainable → \(target)" }

    /// A kind that holds no shapes and owns no board has no place to constrain.
    public static func check(_ registry: Registry) throws(RegistryError) {
        let places = registry.containingKinds.union(registry.boardOwningKinds)
        for kind in registry.kinds where !registry.contributions(to: ConstrainableKinds.self, for: kind).isEmpty {
            guard places.contains(kind) else {
                throw .invalid(point: "ConstrainableKinds", reason: "\(kind) holds no shapes and owns no board, so it has no place to constrain")
            }
        }
    }
}

/// What `ConstrainableKinds` stores: only the sugar makes one.
public struct Constrainable: Sendable {}

extension ShapeRegistrar {
    /// This kind's shapes hold constraints of their own (`ConstraintsProperty`): every shape within each one's reach
    /// must match its query. Only for a kind that holds shapes (`ShapeContaining`) or owns a board (`BoardOwning`): the
    /// registry refuses any other. `frame.constrainable()`.
    public mutating func constrainable() {
        optIn(to: ConstraintsProperty.self)
        contribute(Constrainable(), to: ConstrainableKinds.self)
    }
}

extension PluginRegistrar {
    /// Lets another plugin's kind hold constraints, as `constrainable()` does a plugin's own.
    public mutating func constrainable<P: ShapeProps>(_: P.Type) {
        optIn(P.self, to: ConstraintsProperty.self)
        contribute(Constrainable(), to: ConstrainableKinds.self, for: .kind(P.kind))
    }
}

extension Registry {
    /// Whether a kind's shapes hold constraints of their own: it opted in, and it holds shapes or owns a board.
    public func isConstrainable(_ kind: ShapeKind) -> Bool {
        memo(ConstrainableKey(kind: kind)) {
            properties(for: kind).contains(ConstraintsProperty.key) && (containingKinds.contains(kind) || boardOwningKinds.contains(kind))
        }
    }
}

private struct ConstrainableKey: Hashable { let kind: ShapeKind }

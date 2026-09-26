/// A typed hook that one plugin declares and any plugin contributes to. The type is the key, as
/// with SwiftUI's `EnvironmentKey`. The core stores contributions without knowing what they mean;
/// its own points (shapes, tools, services, overlays, ...) are declared the same way.
///
/// Contributions to a point form a list, in plugin order. A point where two contributions must
/// never claim the same thing (one title per kind, one tool per shortcut) is a `KeyedExtensionPoint`.
@MainActor
public protocol ExtensionPoint {
    associatedtype Contribution
    /// The plugin that declares and consumes this point. Contributing to it when that plugin isn't
    /// installed is `RegistryError.ownerNotInstalled`: the runtime requirement follows from the
    /// compile-time import, so plugins never list their dependencies a second time.
    static var owner: PluginID { get }
}

/// A point whose contributions claim keys. Two contributions claiming the same key make the
/// registry throw `RegistryError.conflict`, so plugin order never picks a winner.
@MainActor
public protocol KeyedExtensionPoint: ExtensionPoint {
    /// The keys `contribution` claims. `[target]` allows one contribution per kind, plus one for
    /// every kind (`.any`), which `contributions(to:for:)` returns after the kind's own.
    static func uniqueKeys(of contribution: Contribution, for target: ShapeTarget) -> [AnyHashable]
}

/// Which shapes a contribution is for.
public enum ShapeTarget: Hashable, Sendable, CustomStringConvertible {
    case kind(ShapeKind)
    /// Every kind, or not about shapes at all (tools, overlays).
    case any

    public var description: String {
        switch self {
        case .kind(let kind): "\(kind)"
        case .any: "*"
        }
    }
}

/// A contribution, with where it came from.
public struct Contributed<Value> {
    public let value: Value
    public let target: ShapeTarget
    public let pluginID: PluginID
}

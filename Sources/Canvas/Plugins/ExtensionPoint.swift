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
    /// Which shapes its contributions may be for (`PointScope`): anything, by default.
    static var scope: PointScope { get }
    /// Rules that span contributions, beyond what keys express: runs once the registry is built,
    /// for each point that has at least one contribution. Throwing refuses the plugin list: a
    /// `RegistryError` as it is, any other error as `RegistryError.invalid` for this point. The
    /// default checks nothing.
    ///
    /// Untyped, so both `throws` and `throws(RegistryError)` implement it: a typed requirement
    /// would let a plain `throws` spelling silently fall back to the default.
    static func check(_ registry: Registry) throws
    /// How the registry's report (`registry.report`) shows a contribution. The default is the
    /// point's name, and the shapes it's for, if not every kind: `ValidationRules → sticky-note`,
    /// `ValidationRules → every shape holding color`.
    static func summary(of contribution: Contribution, for target: ShapeTarget) -> String
}

extension ExtensionPoint {
    public static var scope: PointScope { .anything }

    public static func check(_ registry: Registry) throws {}

    public static func summary(of contribution: Contribution, for target: ShapeTarget) -> String {
        "\(Self.self)" + (target == .any ? "" : " → \(target)")
    }
}

/// A point whose contributions claim keys. Two contributions claiming the same key make the
/// registry throw `RegistryError.conflict`, so plugin order never picks a winner.
@MainActor
public protocol KeyedExtensionPoint: ExtensionPoint {
    /// The keys `contribution` claims. `[target]` allows one contribution per kind, plus one for
    /// every kind (`.any`), which `contributions(to:for:)` returns after the kind's own. A scoped
    /// contribution (`.holding`, `.adopting`) also claims, on each kind it reaches, the keys it would
    /// claim for that kind alone, so two scopes that reach one kind can't both put a thing there.
    static func uniqueKeys(of contribution: Contribution, for target: ShapeTarget) -> [AnyHashable]
}

/// Which shapes a contribution is for.
public enum ShapeTarget: Hashable, Sendable, CustomStringConvertible {
    case kind(ShapeKind)
    /// Every kind whose shapes hold an added property, opted into it however
    /// (`registrar.forShapes(holding:)`): a feature's faces go only on the kinds that opted into it.
    case holding(PropertyKey)
    /// Every kind that has a capability (`registrar.forShapes(adopting:)`), and every kind on purpose
    /// (`ShapeCapability.everyKind`, `registrar.forEveryShape`).
    case adopting(ShapeCapability)
    /// Every kind, or not about shapes at all (tools, overlays).
    case any

    /// As the registry's report says it: the kind, "every shape holding locked", "every shape with a
    /// title", "every shape" (every kind, on purpose), or `*`.
    public var description: String {
        switch self {
        case .kind(let kind): "\(kind)"
        case .holding(let key): "every shape holding \(key)"
        case .adopting(let capability): capability == .everyKind ? "every shape" : "every shape \(capability.phrase)"
        case .any: "*"
        }
    }

    /// Whether it names kinds by a scope (`.holding`, `.adopting`), which the registry resolves to
    /// kinds as it's built.
    var isScoped: Bool {
        switch self {
        case .holding, .adopting: true
        case .kind, .any: false
        }
    }
}

/// Which shapes a point's contributions may be for (`ExtensionPoint.scope`).
public enum PointScope: Sendable {
    /// A kind, a scope, or every kind (`.any`); and what isn't about shapes at all. The default.
    case anything
    /// A kind's own, or the kinds a scope names: a feature's face on other kinds' shapes says which
    /// (`registrar.forShapes(holding:)`, `forShapes(adopting:)`, or `forEveryShape` for what is on
    /// every shape by its nature), so one for every kind with no scope (`.any`) is refused.
    case scoped
    /// One kind each (what opens a kind's boards, a channel a kind offers): a scope, or every kind,
    /// is refused.
    case kinds
}

/// A contribution, with where it came from.
public struct Contributed<Value> {
    public let value: Value
    public let target: ShapeTarget
    public let pluginID: PluginID
}

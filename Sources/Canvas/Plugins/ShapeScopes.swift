// Scopes: which kinds a contribution for many kinds reaches, said as data the registry resolves when
// it's built, rather than a closure each horizontal asks for itself. A feature's faces on shapes it
// doesn't define go only on the kinds that opted into the feature: those that hold its property
// (`forShapes(holding:)`), or that have a capability (`forShapes(adopting:)`); and what is on every
// shape by its nature says so (`forEveryShape`).

/// What a kind can do or is, as a scope picks kinds by it (`registrar.forShapes(adopting:)`): a
/// capability protocol its definition adopts (`ShapeCapability((any BoardOwning).self)`), or a fact about
/// kinds that the module owning it states once, by a name the registry's report shows ("with a box",
/// Titles' "with a title"). The registry asks it of each kind once, as it's built.
///
/// A fact's test reads the kind as the registry has it: its definition, what it holds, what it
/// adopts, and kinds' own contributions to other points. It must not ask for the contributions to a
/// point that has scoped ones (a precondition), since those are what's being worked out.
public struct ShapeCapability: Hashable, Sendable, CustomStringConvertible {
    /// What makes two the same capability: a protocol's full name, or a fact's phrase.
    let id: String
    /// What the report says of the kinds it picks, after "every shape": "adopting BoardOwning",
    /// "with a title".
    public let phrase: String
    let test: @MainActor @Sendable (RegisteredKind) -> Bool

    /// The kinds whose definition adopts `C`, a capability protocol: `ShapeCapability((any BoardOwning).self)`.
    public init<C>(_: C.Type) {
        id = String(reflecting: C.self)
        let name = "\(C.self)"
        phrase = "adopting " + (name.hasPrefix("any ") ? String(name.dropFirst(4)) : name)
        test = { $0.definition is C }
    }

    /// A fact about kinds, by what it says of them ("with a title"): one phrase names one fact.
    public init(_ phrase: String, _ test: @escaping @MainActor @Sendable (RegisteredKind) -> Bool) {
        id = phrase
        self.phrase = phrase
        self.test = test
    }

    public static func == (lhs: ShapeCapability, rhs: ShapeCapability) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    public var description: String { phrase }
}

extension ShapeCapability {
    /// Every kind: what `forEveryShape` scopes to. The report says "every shape".
    public static let everyKind = ShapeCapability("of every kind") { _ in true }

    /// The kinds whose shapes are boxes (props that are `BoxShapeProps`, which a frame edits).
    public static let box = ShapeCapability("with a box") { $0.definition.propsType is any BoxShapeProps.Type }

    /// The kinds whose shapes can hold names of shapes (`registry.namingKinds`: in their own props,
    /// or in an added property they opt into).
    public static let namingShapes = ShapeCapability("naming shapes") { $0.registry.namingKinds.contains($0.kind) }
}

/// A kind as the registry has it, for what decides by kind (a capability's test, a channel's rule):
/// its definition (so its capabilities), the registry (what else it takes part in), and what it holds
/// and adopts.
@MainActor
public struct RegisteredKind {
    public let kind: ShapeKind
    public let definition: any ShapeDefinition
    public let registry: Registry

    /// Whether this kind's shapes hold an added property: opted into it, however.
    public func holds<P: ShapeProperty>(_: P.Type) -> Bool { registry.properties(for: kind).contains(P.key) }

    /// Whether this kind's definition adopts `C`, a capability protocol.
    public func adopts<C>(_: C.Type) -> Bool { definition is C }

    /// Whether this kind has a capability.
    public func adopts(_ capability: ShapeCapability) -> Bool { capability.test(self) }
}

extension Registry {
    /// A kind as the registry has it; nil for a kind no plugin registers.
    public func registeredKind(_ kind: ShapeKind) -> RegisteredKind? {
        definition(for: kind).map { RegisteredKind(kind: kind, definition: $0, registry: self) }
    }
}

/// Registers things for the shapes of every kind a scope reaches: everything is stamped with the
/// scope, as a `ShapeRegistrar` stamps its kind's. A horizontal publishes its face for other kinds'
/// shapes as an extension of this in its own module (Adornments' `adornment`, the table of contents'
/// `contentsMark`), so a feature says once which shapes it's on:
///
///     registrar.forShapes(holding: LockedProperty.self) { lock in
///         lock.adornment(LockChip.self) { shape, context in … }
///         lock.contentsMark { shape, _ in … }
///     }
@MainActor
public struct ScopedRegistrar {
    let pluginID: PluginID
    /// The kinds it's for: `.holding` or `.adopting`.
    public let scope: ShapeTarget
    var contributions: [RawContribution] = []

    init(pluginID: PluginID, scope: ShapeTarget) {
        self.pluginID = pluginID
        self.scope = scope
    }

    /// A contribution for the kinds the scope reaches.
    public mutating func contribute<P: ExtensionPoint>(_ value: P.Contribution, to point: P.Type) {
        contributions.append(RawContribution(value, to: P.self, for: scope, from: pluginID))
    }
}

extension PluginRegistrar {
    /// What `contribute` registers is for the shapes of every kind that holds `P`, opted into it
    /// however, and no other: where a feature's property is, its faces are. The report says "every
    /// shape holding <key>". A kind's own contribution of the same thing takes its place.
    public mutating func forShapes<P: ShapeProperty>(holding _: P.Type, _ contribute: (inout ScopedRegistrar) -> Void) {
        scoped(.holding(P.key), contribute)
    }

    /// What `contribute` registers is for the shapes of every kind that has `capability`: a protocol's
    /// (`ShapeCapability((any BoardOwning).self)`), or a fact a module states (`.box`).
    public mutating func forShapes(adopting capability: ShapeCapability, _ contribute: (inout ScopedRegistrar) -> Void) {
        scoped(.adopting(capability), contribute)
    }

    /// What `contribute` registers is for the shapes of every kind whose definition adopts `C`, a
    /// capability protocol: `forShapes(adopting: (any BoardOwning).self)`.
    public mutating func forShapes<C>(adopting _: C.Type, _ contribute: (inout ScopedRegistrar) -> Void) {
        scoped(.adopting(ShapeCapability(C.self)), contribute)
    }

    /// What `contribute` registers is for every shape, whatever its kind: for what is on every shape
    /// by its nature (a shape's schema checked, its issues, what it's connected to), never for a
    /// feature that kinds opt into. The report says "every shape".
    public mutating func forEveryShape(_ contribute: (inout ScopedRegistrar) -> Void) {
        scoped(.adopting(.everyKind), contribute)
    }

    private mutating func scoped(_ scope: ShapeTarget, _ contribute: (inout ScopedRegistrar) -> Void) {
        var registrar = ScopedRegistrar(pluginID: pluginID, scope: scope)
        contribute(&registrar)
        contributions += registrar.contributions
    }
}

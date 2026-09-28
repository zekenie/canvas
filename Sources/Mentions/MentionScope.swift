import Canvas

/// What a mention text may mention: its type's scope, `ScopedMentionText<Scope>`. The scope limits
/// what the `@` picker offers, and says so in the text's schema. It never refuses a mention that's
/// there already (pasted, or written by an agent): that stays, as a bound is a guideline.
///
/// Shipped: `AnyMentionable` (every mentionable shape), `Only<Kind>` (a vertical's own kind, which
/// only it can name, since no vertical imports another), and declared scopes that kinds join from
/// any plugin (`DeclaredMentionScope`). Conform in an extension.
public protocol MentionScope: Sendable {
    /// Whether the scope admits the shape. It's mentionable already when this is asked.
    @MainActor static func admits(_ shape: AnyShapeRecord, in registry: Registry) -> Bool
    /// What the text's schema says of the scope, beside its reference to mention text
    /// (`x-canvas-mentions`); nil for nothing.
    static func schemaAnnotation() -> JSONObject?
}

extension MentionScope {
    public static func schemaAnnotation() -> JSONObject? { nil }
}

/// Every mentionable shape: what `MentionText` may mention.
public enum AnyMentionable {}

extension AnyMentionable: MentionScope {
    @MainActor public static func admits(_ shape: AnyShapeRecord, in registry: Registry) -> Bool {
        registry.isMentionable(shape.kind)
    }
}

/// Only shapes of one kind, which must be mentionable: a vertical's own text restricted to its own
/// kind (`ScopedMentionText<Only<SchemaCard>>`). Its schema says which kind, from the kind itself.
public enum Only<Kind: ShapeProps> {}

extension Only: MentionScope {
    @MainActor public static func admits(_ shape: AnyShapeRecord, in registry: Registry) -> Bool {
        shape.kind == Kind.kind && registry.isMentionable(shape.kind)
    }

    public static func schemaAnnotation() -> JSONObject? { ["kinds": [.string(Kind.kind.rawValue)]] }
}

/// A scope any plugin declares (`registrar.mentionScope(S.self)`) and kinds join, from their own
/// plugin or a bridge (`x.mentionable(in: S.self)`): what may block a task, say, which tasks and
/// notes join though neither plugin knows the other. The type is the key, as a detail tab's is;
/// its title only names it, and no two declared scopes share one. Nothing about a scope is saved
/// in a board, so it has no id.
public protocol DeclaredMentionScope: MentionScope {
    static var title: String { get }
}

extension DeclaredMentionScope {
    /// The kinds that joined it.
    @MainActor public static func admits(_ shape: AnyShapeRecord, in registry: Registry) -> Bool {
        registry.isMentionable(shape.kind) && registry.joins(shape.kind, Self.self)
    }

    public static func schemaAnnotation() -> JSONObject? { ["scope": .string(title)] }
}

// MARK: Declaring and joining

/// The declared scopes, one declaration per type, from the plugin that owns what the scope means.
/// No two may share a title (its check).
public enum MentionScopes {}

extension MentionScopes: KeyedExtensionPoint {
    public typealias Contribution = MentionScopeDeclaration
    public static var owner: PluginID { .mentions }
    public static func uniqueKeys(of declaration: MentionScopeDeclaration, for _: ShapeTarget) -> [AnyHashable] { [declaration.id] }
    public static func summary(of declaration: MentionScopeDeclaration, for _: ShapeTarget) -> String { "mention scope \(declaration.title)" }

    /// Two scopes titled alike would read as one in a schema.
    public static func check(_ registry: Registry) throws {
        var seen: [String: Contributed<MentionScopeDeclaration>] = [:]
        for declared in registry.contributions(to: MentionScopes.self) {
            if let first = seen[declared.value.title] {
                throw RegistryError.invalid(point: "\(MentionScopes.self)", reason:
                    "\(first.value.name) (from \(first.pluginID)) and \(declared.value.name) (from \(declared.pluginID)) are both mention scopes titled \"\(declared.value.title)\"; retitle one")
            }
            seen[declared.value.title] = declared
        }
    }
}

/// A declared scope, as `MentionScopes` keeps it.
public struct MentionScopeDeclaration: Sendable {
    let id: ObjectIdentifier
    let title: String
    let name: String

    init<S: DeclaredMentionScope>(_: S.Type) {
        id = ObjectIdentifier(S.self)
        title = S.title
        name = String(reflecting: S.self)
    }
}

/// Which kinds joined which declared scopes: one join per kind and scope. A kind may join only a
/// scope an installed plugin declares, and only if it's mentionable (its check).
public enum MentionScopeJoins {}

extension MentionScopeJoins: KeyedExtensionPoint {
    public typealias Contribution = MentionScopeDeclaration
    public static var owner: PluginID { .mentions }
    public static func uniqueKeys(of join: MentionScopeDeclaration, for target: ShapeTarget) -> [AnyHashable] {
        [JoinKey(scope: join.id, target: target)]
    }
    public static func summary(of join: MentionScopeDeclaration, for target: ShapeTarget) -> String {
        "mention scope \(join.title) → \(target)"
    }

    public static func check(_ registry: Registry) throws {
        let declared = Set(registry.contributions(to: MentionScopes.self).map(\.value.id))
        for join in registry.contributions(to: MentionScopeJoins.self) {
            guard case .kind(let kind) = join.target else { continue }
            guard declared.contains(join.value.id) else {
                throw RegistryError.invalid(point: "\(MentionScopeJoins.self)", reason:
                    "\(join.pluginID) makes \(kind) join mention scope \(join.value.name), which no installed plugin declares")
            }
            guard registry.isMentionable(kind) else {
                throw RegistryError.invalid(point: "\(MentionScopeJoins.self)", reason:
                    "\(join.pluginID) makes \(kind) join mention scope \(join.value.name), but \(kind) can't be mentioned; make it mentionable too")
            }
        }
    }

    private struct JoinKey: Hashable {
        let scope: ObjectIdentifier
        let target: ShapeTarget
    }
}

extension PluginRegistrar {
    /// Declares a scope kinds may join: the plugin that owns what it means declares it once.
    public mutating func mentionScope<S: DeclaredMentionScope>(_: S.Type) {
        contribute(MentionScopeDeclaration(S.self), to: MentionScopes.self)
    }

    /// Another plugin's kind joins a declared scope (bridges). The kind must be mentionable.
    public mutating func mentionable<P: ShapeProps, S: DeclaredMentionScope>(_: P.Type, in _: S.Type) {
        contribute(MentionScopeDeclaration(S.self), to: MentionScopeJoins.self, for: .kind(P.kind))
    }
}

extension ShapeRegistrar {
    /// This kind joins a declared scope, so text of that scope may mention its shapes. The kind
    /// must be mentionable (`mentionable(...)`).
    public mutating func mentionable<S: DeclaredMentionScope>(in _: S.Type) {
        contribute(MentionScopeDeclaration(S.self), to: MentionScopeJoins.self)
    }
}

extension Registry {
    /// Whether a kind joined a declared scope.
    public func joins<S: DeclaredMentionScope>(_ kind: ShapeKind, _: S.Type) -> Bool {
        let id = ObjectIdentifier(S.self)
        return contributions(to: MentionScopeJoins.self, for: kind).contains { $0.id == id }
    }
}

import Canvas
import Palette

/// The chip the band draws beside a scope's title: a name and the color it is drawn in (Palette's roles: its ink on a wash
/// of it, as a type's chip is drawn in a rule's line). Given by the scope's owner, which knows the look; Validation knows
/// no type.
public struct IssueScopeChip: Equatable, Sendable {
    public var name: String
    public var swatch: Swatch

    public init(_ name: String, swatch: Swatch) {
        self.name = name
        self.swatch = swatch
    }
}

/// What a walk's band says of its scope (`IssueScope.label`): "Rule 1" beside the chip of the type that holds the rule,
/// "All Issues" alone. Said to VoiceOver as `spoken`, "Rule 1 of Vote", else as `title`.
public struct IssueScopeLabel: Equatable, Sendable {
    public var title: String
    /// The shape whose chip the band draws beside the title (a rule's type), if there is one.
    public var owner: ShapeID?
    public var spoken: String?
    /// The chip itself, if there is one: a label without it draws its title alone.
    public var chip: IssueScopeChip?

    public init(_ title: String, owner: ShapeID? = nil, spoken: String? = nil, chip: IssueScopeChip? = nil) {
        self.title = title
        self.owner = owner
        self.spoken = spoken
        self.chip = chip
    }
}

/// Which issues a walk goes through. A walk of every issue is Validation's own (`IssueScope.all`); a plugin gives a scope
/// for the issues it owns (`registrar.issueScopes`), a rule's, so the same walk covers any error or warning.
@MainActor
public struct IssueScope {
    /// What names the scope across changes to the words that make it up: a rule reworded is the same scope.
    public let id: AnyHashable
    /// Whether an issue is among the scope's stops. Only issues that show are asked (`Severity.shows`).
    public let includes: @MainActor (ValidationIssue) -> Bool
    /// What the band says, nil once the scope no longer exists (its rule deleted), which ends the walk.
    public let label: @MainActor (CanvasEditor) -> IssueScopeLabel?
    /// The shapes that may have an issue in the scope, when the owner knows them (a rule's flagged shapes), else the walk
    /// asks the query `:invalid, :warned`.
    public let candidates: (@MainActor (CanvasEditor) -> Set<ShapeID>)?
    /// Whether a commit changed what the scope is made of (the type a rule is written in changed: reworded, or its rule
    /// moved): the walk follows the scope in place, its place kept (`IssueWalk.scopeDidChange`).
    public let isChanged: (@MainActor (ChangeSet, CanvasEditor) -> Bool)?
    /// Whether a shape's issue of the scope's source, now gone, was set aside (the rule ignored on it) rather than fixed, when the
    /// owner can say: its row reads ignored, else holds. Nil leaves it to the last Ignore the walk ran (`IssueWalk.ignoreCurrent`).
    public let isSetAside: (@MainActor (ShapeID, CanvasEditor) -> Bool)?

    public init(id: AnyHashable, includes: @escaping @MainActor (ValidationIssue) -> Bool, label: @escaping @MainActor (CanvasEditor) -> IssueScopeLabel?,
                candidates: (@MainActor (CanvasEditor) -> Set<ShapeID>)? = nil,
                isChanged: (@MainActor (ChangeSet, CanvasEditor) -> Bool)? = nil,
                isSetAside: (@MainActor (ShapeID, CanvasEditor) -> Bool)? = nil) {
        self.id = id
        self.includes = includes
        self.label = label
        self.candidates = candidates
        self.isChanged = isChanged
        self.isSetAside = isSetAside
    }

    /// Every error and warning: Validation's own scope.
    public static var all: IssueScope {
        IssueScope(id: "all", includes: { _ in true }, label: { _ in IssueScopeLabel(IssueWalkStyle.allIssues) })
    }
}

/// Issue scopes: this plugin declares the point, any plugin contributes the scopes of the issues it owns. Asked with an
/// issue's source, a plugin answers the scope of it when the source is its own and the scope is still there. Validation
/// knows no source: a rule's count, and a warning's line, begin the walk of that rule through it.
public enum IssueScopes: ExtensionPoint {
    public typealias Contribution = @MainActor (IssueSource, CanvasEditor) -> IssueScope?
    public static var owner: PluginID { .validation }
}

extension PluginRegistrar {
    /// The scope of the issues of a source this plugin owns (`IssueScopes`), nil for another's or one that is gone.
    public mutating func issueScopes(_ scope: @escaping @MainActor (IssueSource, CanvasEditor) -> IssueScope?) {
        contribute(scope, to: IssueScopes.self)
    }
}

extension Registry {
    /// The scope the plugin that owns `source` gives its issues, if it still has one.
    @MainActor public func issueScope(for source: IssueSource, in editor: CanvasEditor) -> IssueScope? {
        for contribution in contributions(to: IssueScopes.self) where contribution.pluginID == source.plugin {
            if let scope = contribution.value(source, editor) { return scope }
        }
        return nil
    }
}

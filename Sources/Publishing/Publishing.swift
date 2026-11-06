import Canvas
import ContextMenus
import SwiftUI
import TableOfContents

/// Publishing, as a plugin: a shape is public or private. Only a public shape can be stood for by
/// another (`Topology`'s stand-ins admit it, `PublishingState.admitting`), so what a lot of shapes
/// point at doesn't need an arrow from each: a stand-in for it takes theirs. Every shape is public
/// until a person makes it private, and being private is something the shape knows, as being locked
/// is: an added property every kind opts into (`private: true`, nil while public), set from the
/// context menu, with `/private` and `/public`, or from the chip a private shape wears (the crossed
/// eye, as a locked shape wears the lock). Making a shape private is refused while anything stands for
/// it (the shape shakes, and its panel shows what, in its Connections tab); a click on the open eye a
/// shape just went public with, before it fades, makes it private again. Publishing knows no kind that
/// stands in, and no reference: it asks Topology what stands for a shape.
extension PluginID {
    public static let publishing: PluginID = "publishing"
}

/// Whether a shape is private: `true` on a private shape, and nothing on the rest (making it public
/// takes it away), so a board holds it only for the shapes a person made private.
public enum PrivateProperty {}

extension PrivateProperty: ShapeProperty {
    public static let key: PropertyKey = "private"
    public static var defaultValue: Bool? { nil }
}

/// A kind whose shapes are never public: its definition adopts it, in an extension, and the kind
/// holds no `private` property (nothing could stand for one: an arrow). One dial of two; a
/// definition that adopts both is refused when the registry is built.
public protocol NeverPublic {}

/// A kind whose every shape is public: its definition adopts it, in an extension, and the kind
/// holds no `private` property, so there's nothing to toggle, no chip and no menu item. The other
/// dial; see `NeverPublic`.
public protocol AlwaysPublic {}

extension Registry {
    /// Whether the shape is public: its kind holds `private` and the shape isn't private (nor kept
    /// aside), or its kind's every shape is (`AlwaysPublic`). One lookup in a table the registry keeps,
    /// for the places that hold a registry and no editor (a stand-in's admission).
    public func isPublic(_ record: AnyShapeRecord) -> Bool {
        privacyKinds.admits(record)
    }

    /// `isPublic` for any thread, the kinds read once here: what a stand-in kind admits
    /// (`standsIn(admitting: { $0.publicShapes })`), which Topology reads off the main actor too.
    public var publicShapes: @Sendable (AnyShapeRecord) -> Bool {
        let kinds = privacyKinds
        return { record in kinds.admits(record) }
    }

    /// Whether shapes of the kind can be public: they hold the property, or every one is.
    public func canBePublic(_ kind: ShapeKind) -> Bool {
        privacyKinds.always.contains(kind) || privacyKinds.holding.contains(kind)
    }

    /// Makes the record public, the one writer that takes `private` off a record (`editor.makePublic`
    /// calls it, and a stand-in kind asks it through `standsIn(fulfilling:)`, as a person picking a
    /// private shape would): true when the record is public afterward, already or now; false for a
    /// kind that holds no `private` and isn't always public (`NeverPublic`), and for a shape kept aside.
    /// Whether the record may be written is its caller's transaction's to say.
    public func makePublic(_ record: inout AnyShapeRecord) -> Bool {
        if isPublic(record) { return true }
        guard !record.isOpaque, holdsPrivate(record.kind) else { return false }
        record[PrivateProperty.self] = nil
        return true
    }

    /// Whether the kind holds `PrivateProperty`: its shapes can be made private and public again.
    func holdsPrivate(_ kind: ShapeKind) -> Bool { privacyKinds.holding.contains(kind) }

    /// Which kinds hold the property and which are always public, read once a registry.
    var privacyKinds: PrivacyKinds {
        memo(PrivacyKindsKey()) {
            PrivacyKinds(holding: Set(kinds.filter { properties(for: $0).contains(PrivateProperty.key) }),
                         always: Set(kinds.filter { definition(for: $0) is any AlwaysPublic }))
        }
    }
}

/// The kinds that hold `private` and those whose every shape is public: what says whether a shape is
/// public, on any thread.
struct PrivacyKinds: Sendable {
    let holding: Set<ShapeKind>
    let always: Set<ShapeKind>

    /// Whether the shape is public.
    func admits(_ record: AnyShapeRecord) -> Bool {
        if always.contains(record.kind) { return true }
        return holding.contains(record.kind) && record[PrivateProperty.self] != true && !record.isOpaque
    }
}

/// The key `privacyKinds` is kept under.
private struct PrivacyKindsKey: Hashable {}

extension CanvasEditor {
    /// Publishing's service for this editor; nil without PublishingPlugin.
    public var publishing: PublishingState? { service(PublishingState.self) }

    /// Makes these shapes public, on whichever board of the file each is, in one transaction (an undo
    /// step "Make Public", unless it's part of another). A kind that holds no `private` property takes
    /// nothing; a read-only shape is refused by the core, and shakes.
    public func makePublic(_ ids: [ShapeID]) {
        let registry = registry
        transact("Make Public") { transaction in
            for id in ids { transaction.update(inFile: id) { _ = registry.makePublic(&$0) } }
        }
    }

    /// Makes these shapes private, as a person asks (the chip, the menu, `/private`): in one
    /// transaction ("Make Private"), but for those something stands for, which stay public: nothing
    /// is written for them, they shake (`refuseChanges(to:)`), and, when the panel shows one, it
    /// shows what stands for it (its Connections tab, Neighbors'). Returns those it left public. What gets a shape
    /// private another way (undo, a paste, a board edited by hand, `canvas draw`) isn't asked.
    @discardableResult
    public func makePrivate(_ ids: [ShapeID]) -> [ShapeID] {
        guard let publishing else {
            let registry = registry
            transact("Make Private") { transaction in
                for id in ids { transaction.update(id) { if registry.holdsPrivate($0.kind) { $0[PrivateProperty.self] = true } } }
            }
            return []
        }
        return publishing.makePrivate(ids)
    }
}

/// Make Public and Make Private, right after Lock and Unlock (`StateMenuGroup`), before Delete.
public enum PublishMenuGroup {}
extension PublishMenuGroup: MenuGroup {
    public static var order: Order<Self> { .after(StateMenuGroup.self) }
}

/// A rule over the plugin list that always has a contribution, so the registry checks it: a
/// definition may adopt `NeverPublic` or `AlwaysPublic`, never both.
public enum PublishingDials {}

extension PublishingDials: ExtensionPoint {
    public typealias Contribution = Bool
    public static var owner: PluginID { .publishing }

    public static func check(_ registry: Registry) throws(RegistryError) {
        for kind in registry.kinds {
            guard let definition = registry.definition(for: kind), definition is any NeverPublic, definition is any AlwaysPublic else { continue }
            throw .invalid(point: "PublishingDials", reason: "\(kind) is both NeverPublic and AlwaysPublic")
        }
    }

    public static func summary(of _: Bool, for _: ShapeTarget) -> String { "public dials" }
}

public struct PublishingPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .publishing }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.declare(PrivateProperty.self)
        // Every kind that's neither: a kind that's never public holds none, and one that's always
        // public has nothing to toggle.
        registrar.optInEveryShape(to: PrivateProperty.self, where: { !($0 is any NeverPublic) && !($0 is any AlwaysPublic) })
        registrar.contribute(true, to: PublishingDials.self)
        registrar.service { PublishingState(editor: $0) }
        registerPublishMenus(into: &registrar)
        // What Publishing puts on shapes goes on the kinds that can be private, and no other.
        registrar.forShapes(holding: PrivateProperty.self) { publishable in
            registerPrivateChip(into: &publishable)
            // The crossed eye at the end of a private shape's row, as on the shape.
            publishable.contentsMark { shape, _ in
                guard shape[PrivateProperty.self] == true else { return nil }
                return ContentsMark(symbol: PublicStyle.privateSymbol, color: .secondary, help: PublicStyle.privateWord)
            }
            registerPublishSlashCommands(into: &publishable)
        }
    }
}

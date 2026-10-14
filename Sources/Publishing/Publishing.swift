import Canvas
import ContextMenus
import SwiftUI
import TableOfContents

/// Publishing, as a plugin: a shape is public or private. Only a public shape can be stood for by
/// another (`Topology`'s stand-ins admit it, `PublishingState.admitting`), so what a lot of shapes
/// point at doesn't need an arrow from each: a stand-in for it takes theirs. Whether a shape is
/// public is something it knows, as whether it's locked: an added property every kind opts into
/// (`public: true`, nil while private), set from the context menu, with `/public` and `/private`,
/// or from the chip a public shape wears (a text chip, "Public", with how many things stand for the
/// shape: "Public · 3"). Making a shape private is refused while anything stands for it (the chip
/// shakes the shape, and its panel shows what, in its Connections tab); a click on the "Private" a shape
/// just went to for a moment, before it fades, makes it public again. Publishing knows no kind that
/// stands in, and no reference: it asks Topology what stands for a shape.
extension PluginID {
    public static let publishing: PluginID = "publishing"
}

/// Whether a shape is public: `true` on a public shape, and nothing on the rest (making it private
/// takes it away), so a board holds it only for the shapes that are.
public enum PublicProperty {}

extension PublicProperty: ShapeProperty {
    public static let key: PropertyKey = "public"
    public static var defaultValue: Bool? { nil }
}

/// A kind whose shapes are never public: its definition adopts it, in an extension, and the kind
/// holds no `public` property (nothing could stand for one: an arrow). One dial of two; a
/// definition that adopts both is refused when the registry is built.
public protocol NeverPublic {}

/// A kind whose every shape is public: its definition adopts it, in an extension, and the kind
/// holds no `public` property, so there's nothing to toggle, no chip and no menu item. The other
/// dial; see `NeverPublic`.
public protocol AlwaysPublic {}

extension Registry {
    /// Whether the shape is public: `public: true` on it, or its kind's every shape is (`AlwaysPublic`).
    /// One dictionary hit and a cast, for the places that hold a registry and no editor (a
    /// stand-in's admission).
    public func isPublic(_ record: AnyShapeRecord) -> Bool {
        record[PublicProperty.self] == true || definition(for: record.kind) is any AlwaysPublic
    }

    /// Whether shapes of the kind can be public: they hold the property, or every one is.
    public func canBePublic(_ kind: ShapeKind) -> Bool {
        definition(for: kind) is any AlwaysPublic || holdsPublic(kind)
    }

    /// Makes the record public, the one writer of `public` on a record (`editor.makePublic` calls it,
    /// and a stand-in kind asks it through `standsIn(fulfilling:)`, as a person picking a private
    /// shape would): true when the record is public afterward, already or now; false for a kind that
    /// holds no `public` and isn't always public (`NeverPublic`). Whether the record may be written
    /// is its caller's transaction's to say.
    public func makePublic(_ record: inout AnyShapeRecord) -> Bool {
        if isPublic(record) { return true }
        guard !record.isOpaque, holdsPublic(record.kind) else { return false }
        record[PublicProperty.self] = true
        return true
    }

    /// Whether the kind holds `PublicProperty`: its shapes can be made public and private.
    func holdsPublic(_ kind: ShapeKind) -> Bool { properties(for: kind).contains(PublicProperty.key) }
}

extension CanvasEditor {
    /// Publishing's service for this editor; nil without PublishingPlugin.
    public var publishing: PublishingState? { service(PublishingState.self) }

    /// Makes these shapes public, in one transaction (an undo step "Make Public", unless it's part
    /// of another). A kind that holds no `public` property takes nothing; a read-only shape is
    /// refused by the core, and shakes.
    public func makePublic(_ ids: [ShapeID]) {
        let registry = registry
        transact("Make Public") { transaction in
            for id in ids { transaction.update(id) { _ = registry.makePublic(&$0) } }
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
            transact("Make Private") { transaction in
                for id in ids { transaction.update(id) { $0[PublicProperty.self] = nil } }
            }
            return []
        }
        return publishing.makePrivate(ids)
    }
}

/// Make Public and Make Private, after Lock and Unlock and before Delete (`StateMenuGroup`'s 300,
/// `SelectionMenuGroup`'s 400).
public enum PublishMenuGroup {}
extension PublishMenuGroup: MenuGroup {
    public static var order: Int { 310 }
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
        registrar.declare(PublicProperty.self)
        // Every kind that's neither: a kind that's never public holds none, and one that's always
        // public has nothing to toggle.
        registrar.optInEveryShape(to: PublicProperty.self, where: { !($0 is any NeverPublic) && !($0 is any AlwaysPublic) })
        registrar.contribute(true, to: PublishingDials.self)
        registrar.service { PublishingState(editor: $0) }
        registerPublicChip(into: &registrar)
        registerPublishMenus(into: &registrar)
        // A globe at the end of a public shape's row, on the kinds that can be, saying how many
        // things stand for the shape: its row is made again when they change (`contentsDidChange(for:)`,
        // from the state's follower of Topology).
        registrar.contentsMarkForEveryShape(where: { $0.holds(PublicProperty.self) }) { shape, context in
            guard shape[PublicProperty.self] == true else { return nil }
            return ContentsMark(symbol: PublicStyle.symbol, color: .secondary, help: PublicStyle.help(references: context.service(PublishingState.self)?.count(for: shape.id) ?? 0))
        }
    }
}

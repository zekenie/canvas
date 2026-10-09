import Canvas
import ContextMenus
import SlashCommands

/// Transform, as a plugin: turning a shape into another kind, under its own id, so whatever binds or
/// names it goes on doing so (an arrow's end, a mention), and its place in the stack, its container and
/// its title stay. Which kinds turn into which is a graph, and its edges are channels: a kind offers
/// one (`x.turnable(through: C.self)`), another takes it and says how
/// (`registrar.turnable(into: P.self, through: C.self) { source, transaction in … }`), and the two meet
/// only in the channel, never in each other. A vertical can't import another, so Frames, which offers
/// the container channel, doesn't know Subboards, which takes it. A shape that can turn has Turn into …
/// in its context menu, and `/turn-into-…` for a line of its text (slash commands). Several selected
/// turn in one undo step, innermost first, all or nothing: none does if any of them, or anything the
/// turn would move, is read-only. The core never learns what turns into what: it lends only
/// `transaction.turn(_:into:)` and `transaction.move(_:toBoardOwnedBy:)`, which a target turns with.
extension PluginID {
    public static let transform: PluginID = "transform"
}

// MARK: Channels

/// A way one kind's shapes turn into another's: what a source and a target agree on, so that neither names
/// the other. A kind offers it (`x.turnable(through: C.self)`), a target takes it and says how
/// (`registrar.turnable(into: T.self, through: C.self) { source, transaction in … }`), and a shape can turn
/// into each target that takes a channel its kind offers. The channel says which kinds may offer it, and what
/// a shape coming through it hands the target. Conform in an extension: `admits` has a default, and only
/// there does the compiler flag a near miss on it.
@MainActor
public protocol TransformChannel {
    /// What a shape coming through the channel hands the target.
    associatedtype Source
    /// What the registry's report calls it: "container".
    static var name: String { get }
    /// Whether a kind may offer it; the registry refuses a plugin list where one that may not does. Every
    /// kind may, by default.
    static func admits(_ kind: TransformKind) -> Bool
    /// What a shape of a kind that offers it hands the target, read in the transaction that turns it, before
    /// the target changes anything. Nil if it has nothing to hand over: the target's turn doesn't run, and the
    /// shape stays as it is.
    static func source(of id: ShapeID, in transaction: Transaction) -> Source?
}

extension TransformChannel {
    public static func admits(_ kind: TransformKind) -> Bool { true }
}

/// A kind, as a channel's `admits` sees it: its definition (so its capabilities) and the registry (so what
/// else it takes part in).
@MainActor
public struct TransformKind {
    public let kind: ShapeKind
    public let definition: any ShapeDefinition
    public let registry: Registry
}

// MARK: The extension points

/// The extension point: which kinds' shapes offer a channel. Keyed by kind and channel: a kind offers a
/// channel once, so two plugins offering one to a kind are `RegistryError.conflict` at startup. Only a kind
/// the channel admits (`TransformChannel.admits`) may offer it, and only a kind, not every shape: a plugin
/// list where one doesn't is `RegistryError.invalid`.
public enum TransformSources {}

extension TransformSources: KeyedExtensionPoint {
    public typealias Contribution = TransformSource
    public static var owner: PluginID { .transform }

    public static func uniqueKeys(of source: TransformSource, for target: ShapeTarget) -> [AnyHashable] {
        [TransformSourceKey(target: target, channel: source.channel, name: source.name)]
    }

    /// A channel offered by a kind it doesn't admit, or by every kind.
    public static func check(_ registry: Registry) throws(RegistryError) {
        for contributed in registry.contributions(to: TransformSources.self) {
            let source = contributed.value
            guard case .kind(let kind) = contributed.target else {
                throw .invalid(point: "TransformSources", reason: "\(contributed.pluginID) offers the \(source.name) channel on every kind; "
                               + "only a kind the channel admits offers it")
            }
            guard let definition = registry.definition(for: kind),
                  source.admits(TransformKind(kind: kind, definition: definition, registry: registry)) else {
                throw .invalid(point: "TransformSources",
                               reason: "\(contributed.pluginID) offers the \(source.name) channel on \(kind), which can't offer it")
            }
        }
    }

    /// "offers channel container → frame".
    public static func summary(of source: TransformSource, for target: ShapeTarget) -> String {
        "offers channel \(source.name) → \(target == .any ? "every shape" : "\(target)")"
    }
}

/// What a source contribution claims: "frame offering container".
struct TransformSourceKey: Hashable, CustomStringConvertible {
    let target: ShapeTarget
    let channel: ObjectIdentifier
    let name: String
    var description: String { "\(target) offering \(name)" }
}

/// What `TransformSources` stores for a kind: the channel it offers, its name and which kinds it admits.
/// Only the sugar below makes one.
@MainActor
public struct TransformSource {
    let channel: ObjectIdentifier
    let name: String
    let admits: @MainActor (TransformKind) -> Bool

    init<C: TransformChannel>(_: C.Type) {
        channel = ObjectIdentifier(C.self)
        name = C.name
        admits = { C.admits($0) }
    }
}

/// The extension point: which kinds take a channel, and how: what the shapes that offer it become. Keyed by
/// kind: a shape turns into a kind one way, so a kind takes one channel (two claims to it are
/// `RegistryError.conflict` at startup), as a second channel into one kind would share its menu item and its
/// command, Turn into … and `/turn-into-…`, if one is ever needed. Only a kind takes a channel, not every
/// shape (`RegistryError.invalid`).
public enum TransformTargets {}

extension TransformTargets: KeyedExtensionPoint {
    public typealias Contribution = TransformTarget
    public static var owner: PluginID { .transform }

    public static func uniqueKeys(of _: TransformTarget, for target: ShapeTarget) -> [AnyHashable] { [target] }

    /// A channel taken into every kind.
    public static func check(_ registry: Registry) throws(RegistryError) {
        for contributed in registry.contributions(to: TransformTargets.self) where contributed.target == .any {
            throw .invalid(point: "TransformTargets", reason: "\(contributed.pluginID) takes the \(contributed.value.channelName) channel "
                           + "into every kind; a shape turns into one kind")
        }
    }

    /// "takes channel container → subboard".
    public static func summary(of target: TransformTarget, for kind: ShapeTarget) -> String {
        "takes channel \(target.channelName) → \(kind == .any ? "every shape" : "\(kind)")"
    }
}

/// What `TransformTargets` stores for a kind: the channel it takes, its name, what it's called in the menu
/// ("Turn into Subboard"), and the turn, erased: it reads what the channel hands over for a shape and runs
/// the target's own, or says the channel has none. Only the sugar below makes one.
@MainActor
public struct TransformTarget {
    let channel: ObjectIdentifier
    let channelName: String
    let label: String
    /// Turns the shape; false, having changed nothing, if the channel has no source for it.
    let turn: @MainActor (ShapeID, inout Transaction) throws -> Bool

    init<C: TransformChannel>(_: C.Type, label: String,
                              _ turn: @escaping @MainActor (C.Source, inout Transaction) throws -> Void) {
        channel = ObjectIdentifier(C.self)
        channelName = C.name
        self.label = label
        self.turn = { id, transaction in
            guard let source = C.source(of: id, in: transaction) else { return false }
            try turn(source, &transaction)
            return true
        }
    }
}

// MARK: Offers and vetoes (what a file, not the registry, decides)

/// One way the shapes of a menu can be turned that the registry doesn't know, because it comes from what's in
/// the file (a shape someone made): "Employee card". `turn` does it to one shape, in the transaction that
/// turns them all, as a target's closure does (`transaction.turn(_:into:)` and what else it needs); the
/// shape keeps its id. `id` is stable and names the offer in the menu; `label` is the words after "Turn
/// into".
@MainActor
public struct TurnOffer {
    public let id: String
    public let label: String
    let turn: @MainActor (ShapeID, inout Transaction) throws -> Void

    public init(id: String, label: String, turn: @escaping @MainActor (ShapeID, inout Transaction) throws -> Void) {
        self.id = id
        self.label = label
        self.turn = turn
    }
}

/// The extension point: what the shapes of a context menu can be turned into, decided when the menu opens
/// (`registrar.turnOffers`). A list, in plugin order. `TransformPlugin` renders what the providers offer: one
/// offer as an item, "Turn into <label>", several as a "Turn into" submenu, in the order given, in the same
/// band as a kind's own targets, which stay flat items beside it, in plugin order.
public enum TransformOffers {}

extension TransformOffers: ExtensionPoint {
    public typealias Contribution = TurnOfferProvider
    public static var owner: PluginID { .transform }

    public static func summary(of _: TurnOfferProvider, for _: ShapeTarget) -> String { "turn offers → every shape" }
}

/// What `TransformOffers` stores. Only the sugar below makes one.
@MainActor
public struct TurnOfferProvider {
    let offers: @MainActor ([AnyShapeRecord], CanvasEditor) -> [TurnOffer]
}

/// What is about to be turned, as a veto sees it.
public struct TurnRequest {
    /// The shapes about to turn (each once, on the board shown, not kept aside), innermost first (the deepest in containers, then back to front).
    public let shapes: [ShapeID]
    /// What they turn into, as the menu says it: a target's label, an offer's.
    public let label: String
    /// The kind they turn into, for a target of the registry; nil for an offer.
    public let kind: ShapeKind?
    /// The offer's `id`; nil for a target.
    public let offer: String?
}

/// A refusal to turn some shapes: which, and what to do about it (open a panel at the reason).
@MainActor
public struct TurnVeto {
    public let shapes: Set<ShapeID>
    let action: @MainActor () -> Void

    /// `action` runs when the turn is refused, once the shapes have been heard refused. It may change
    /// the document only through `editor.transact`.
    public init(shapes: Set<ShapeID>, then action: @escaping @MainActor () -> Void = {}) {
        self.shapes = shapes
        self.action = action
    }
}

/// The extension point: rules that refuse a turn, whatever it is into (a target of the registry or an offer),
/// asked before anything changes. A contribution looks at what's about to turn and may refuse some of the
/// shapes (`registrar.vetoTurns`); every contribution is asked, in plugin order. If any refuses, Transform
/// turns nothing, makes no step, has the refused shapes heard refused (`editor.refuseChanges`: Locking
/// shakes them) and runs the refusals' actions in plugin order.
public enum TransformVetoes {}

extension TransformVetoes: ExtensionPoint {
    public typealias Contribution = TurnVetoRule
    public static var owner: PluginID { .transform }

    public static func summary(of _: TurnVetoRule, for _: ShapeTarget) -> String { "turn veto → every shape" }
}

/// What `TransformVetoes` stores. Only the sugar below makes one.
@MainActor
public struct TurnVetoRule {
    let veto: @MainActor (TurnRequest, CanvasEditor) -> TurnVeto?
}

/// The band of items a transform brings to a menu: after Mentions' (50), before Cut, Copy and Paste (100),
/// as a feature's items go.
public enum TransformMenuGroup {}
extension TransformMenuGroup: MenuGroup {
    public static var order: Int { 60 }
}

// MARK: Sugar (what verticals and horizontals write)

extension ShapeRegistrar {
    /// This kind's shapes can be turned into whatever takes `channel`, as a frame's can into a subboard
    /// through the container channel:
    ///
    ///     frame.turnable(through: ContainerChannel.self)
    ///
    /// The registry refuses the plugin list if the channel doesn't admit the kind (`TransformSources.check`).
    public mutating func turnable<C: TransformChannel>(through _: C.Type) {
        contribute(TransformSource(C.self), to: TransformSources.self)
    }
}

extension PluginRegistrar {
    /// The same, for a kind another plugin registers.
    public mutating func turnable<P: ShapeProps, C: TransformChannel>(_: P.Type, through _: C.Type) {
        contribute(TransformSource(C.self), to: TransformSources.self, for: .kind(P.kind))
    }

    /// Shapes of the kinds that offer `channel` can be turned into `P`'s, and `turn` is how: it gets what the
    /// channel hands over for the shape (a container, and what it holds) and the transaction, turns the shape
    /// (`transaction.turn(_:into:)`) and puts what it held where it goes. It changes the document only through
    /// the transaction, and what it throws commits nothing.
    ///
    ///     registrar.turnable(into: Subboard.self, through: ContainerChannel.self) { container, transaction in
    ///         guard transaction.turn(container.id, into: Subboard(frame: …)) else { return }
    ///         transaction.move(container.held, toBoardOwnedBy: container.id)
    ///     }
    ///
    /// It brings Turn into `label` to the context menu of any shapes that can all turn into `P` (`label` is what
    /// `P`'s schema is titled, else its id, unless given), and `/turn-into-` followed by `P`'s id to the commands
    /// of the kinds that offer the channel, `P` apart. The undo step is named as the item is. The registry
    /// refuses a plugin list without `TransformPlugin()`, or without `ContextMenusPlugin()` or
    /// `SlashCommandsPlugin()`, which the item and the command belong to, and one where `P`'s id can't be typed
    /// as a command's name.
    public mutating func turnable<P: ShapeProps, C: TransformChannel>(into _: P.Type, through _: C.Type, label: String? = nil,
                                                                      _ turn: @escaping @MainActor (C.Source, inout Transaction) throws -> Void) {
        let kind = P.kind, label = label ?? P.properties.title ?? kind.rawValue
        contribute(TransformTarget(C.self, label: label, turn), to: TransformTargets.self, for: .kind(kind))
        // An item for the canvas, as Show What Mentions is: whether a shape can turn is what the registry
        // knows, not what the shape does. Shown when every shape of the menu can turn into `P`.
        contextMenuForCanvas {
            MenuItem("Turn into \(label)", in: TransformMenuGroup.self, when: { subject in
                guard let transforms = subject.editor.transforms, !subject.shapes.isEmpty else { return false }
                return subject.shapes.allSatisfy { transforms.canTurn($0, into: kind) }
            }) { ids, editor in
                editor.transforms?.turn(ids, into: kind)
            }
        }
        // On the kinds that offer the channel, but `P`: it has nothing to turn into.
        slashCommandsForEveryShape(where: { $0.registry.offers($0.kind, C.self) && $0.kind != kind }) {
            SlashCommand("turn-into-\(kind.rawValue)") { id, _, editor in
                editor.transforms?.turn([id], into: kind)
            }
        }
    }
}

extension PluginRegistrar {
    /// What the shapes of a menu can be turned into that depends on the file, asked when the menu opens
    /// (and again by `editor.transforms?.offers(for:)`): the shapes, in the menu's order, all on the board
    /// shown and none kept aside. Return no offers for a selection it doesn't suit (shapes of two kinds, say).
    /// One offer is a menu item, several a "Turn into" submenu; choosing one is `turn(_:by:)`: one undo step,
    /// "Turn into <label>", all or nothing, as for a target. The registry refuses a plugin list without
    /// `TransformPlugin()`.
    ///
    ///     registrar.turnOffers { shapes, editor in
    ///         shapes.allSatisfy { $0.kind == "note" } ? cards.map { TurnOffer(id: $0.id, label: $0.title) { id, transaction in … } } : []
    ///     }
    public mutating func turnOffers(_ offers: @escaping @MainActor (_ shapes: [AnyShapeRecord], _ editor: CanvasEditor) -> [TurnOffer]) {
        contribute(TurnOfferProvider(offers: offers), to: TransformOffers.self)
    }

    /// A rule that refuses some turns before any happens, whatever they turn into: given what is about to
    /// turn, nil to let it, or the shapes it refuses and what to do about it. Transform then turns nothing,
    /// shakes the shapes and runs the action.
    ///
    ///     registrar.vetoTurns { request, editor in
    ///         let held = request.shapes.filter { hasInstances($0) }
    ///         return held.isEmpty ? nil : TurnVeto(shapes: Set(held)) { editor.openPanel(at: held[0]) }
    ///     }
    public mutating func vetoTurns(_ veto: @escaping @MainActor (_ request: TurnRequest, _ editor: CanvasEditor) -> TurnVeto?) {
        contribute(TurnVetoRule(veto: veto), to: TransformVetoes.self)
    }
}

// MARK: The graph of transforms

extension Registry {
    /// The kinds a shape of `kind` can be turned into: its edges in the graph of transforms, each kind whose
    /// target takes a channel `kind` offers, in plugin order, never `kind` itself.
    public func turnTargets(of kind: ShapeKind) -> [ShapeKind] {
        let offered = Set(contributions(to: TransformSources.self, for: kind).map(\.channel))
        guard !offered.isEmpty else { return [] }
        return contributions(to: TransformTargets.self).compactMap { contributed in
            guard case .kind(let into) = contributed.target, into != kind, offered.contains(contributed.value.channel) else { return nil }
            return into
        }
    }

    /// Whether shapes of `kind` offer the channel (`x.turnable(through:)`).
    func offers<C: TransformChannel>(_ kind: ShapeKind, _: C.Type) -> Bool {
        contributions(to: TransformSources.self, for: kind).contains { $0.channel == ObjectIdentifier(C.self) }
    }
}

// MARK: The plugin

/// Makes the service that says what a shape can turn into, and turns shapes. It adds no item or command for
/// the registry's targets: the kinds that take a channel (Subboards') bring them to the kinds that offer it
/// (Frames'). Its one item for the canvas is "Turn into" for what the file offers (`turnOffers`), made when
/// the menu opens. A list with either needs it (`ownerNotInstalled` otherwise), and a target's item and
/// command need `ContextMenusPlugin()` and `SlashCommandsPlugin()` too, as does the plugin.
public struct TransformPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { .transform }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.service { TransformState(editor: $0) }
        registrar.contextMenuForCanvas {
            MenuItems(in: TransformMenuGroup.self, id: "turn-offers") { subject in
                let offers = subject.editor.transforms?.offers(for: subject.shapes) ?? []
                if offers.count == 1, let offer = offers.first {
                    MenuItem("Turn into \(offer.label)", in: TransformMenuGroup.self, id: "turn-offer:\(offer.id)") { ids, editor in
                        editor.transforms?.turn(ids, by: offer)
                    }
                } else if !offers.isEmpty {
                    Submenu("Turn into", in: TransformMenuGroup.self, id: "turn-offers-menu") {
                        for offer in offers {
                            MenuItem(offer.label, in: TransformMenuGroup.self, id: "turn-offer:\(offer.id)", stepName: "Turn into \(offer.label)") { ids, editor in
                                editor.transforms?.turn(ids, by: offer)
                            }
                        }
                    }
                }
            }
        }
    }
}

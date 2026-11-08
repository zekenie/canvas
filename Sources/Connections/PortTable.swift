import AppKit
import Canvas
import Topology

// The port table: each kind's ports, gathered from the `ShapePorts` contributions. Everything that
// asks about ports reads it (the dots and a drag from one, where a connection may end,
// `accepts`, and the lookups below), so all of them put a kind's channels in one order.
//
// That order is plugin order: the order of the `ShapePorts` contributions in the plugin list (as
// `registry.contributions(to:)` gives them), whether a contribution is for the kind or for every
// kind; and a kind's first contribution on a channel is its only one there, its role and its sides.
// A contribution for every channel (`portsOnEveryChannel`) is expanded here, to each channel the
// registry declares, in plugin order, at the place it has in the list.
//
// That is a kind's ports; a shape that stands for others (Topology's stand-ins: a reference) has
// ports of its own, instance by instance: its kind's, as far as every shape it stands for takes
// them, in the order of the first (`standing(for:)`, and `PortState.ports(of:)`). A lookup below that
// asks about a kind may ask about a stand-in of that kind instead, by the kinds of what it stands for
// (`standingFor`): what a connection made by name asks of one that isn't in the editor, on a board that
// isn't shown.

/// A kind's ports, as the port table has them. Only `KindPorts(of:in:)` makes one.
@MainActor
struct KindPorts {
    /// Ports on one channel: what they let the kind be, and on which sides (no side twice).
    struct Entry {
        let channel: ChannelID
        let role: PortRole
        let sides: [PortSide]
        /// On its parts (its rows), not its sides: a connection on it starts at a row's dot, and ends on a row.
        var onParts = false
    }

    /// Each channel it has ports on, once, in plugin order.
    private(set) var entries: [Entry] = []
    /// The channels each side's dot starts connections on, in plugin order. A side with none has no dot.
    private(set) var dots: [PortSide: [ChannelID]] = [:]
    /// The channels a part's dots start connections on, in plugin order: none, no dots on its rows.
    private(set) var partDots: [ChannelID] = []
    /// Each channel it has ports on, and what they let it be.
    private(set) var roles: [ChannelID: PortRole] = [:]

    /// A kind's ports, from the registry's `ShapePorts` contributions in plugin order: nil if it has
    /// none, or no installed plugin registers it. Built on demand from the frozen registry (a few
    /// contributions to look through), so cheap enough to ask per shape; an editor keeps every kind's
    /// (`table(in:)`).
    init?(of kind: ShapeKind, in registry: Registry) {
        guard registry.definition(for: kind) != nil else { return nil }
        var declared: [ChannelID]?
        for contribution in registry.contributions(to: ShapePorts.self) where contribution.target == .any || contribution.target == .kind(kind) {
            if let channel = contribution.value.channel {
                add(channel, contribution.value)
            } else {
                // Every channel any shape may be at an end of; and, for a stand-in, whose ports follow what it stands for,
                // every channel there is (`Channel.isOnEveryChannel`).
                let every = declared ?? {
                    let channels = registry.contributions(to: Channels.self).map(\.value)
                    let standsIn = channels.contains { !$0.isOnEveryChannel } && registry.standIns.kinds.contains(kind)
                    return channels.filter { standsIn || $0.isOnEveryChannel }.map(\.id)
                }()
                declared = every
                for channel in every { add(channel, contribution.value) }
            }
        }
        // A channel any kind may start (`Channel.anyKindMayStart`: the kit's `calls`) is started from every kind's dots, after the
        // channels it has ports on, on the sides its dots are on.
        if !dots.isEmpty {
            let sides = PortSide.allCases.filter { dots[$0] != nil }
            for channel in registry.contributions(to: Channels.self).map(\.value) where channel.anyKindMayStart && roles[channel.id] == nil {
                add(channel.id, .source, sides, onParts: false)
            }
        }
        guard !entries.isEmpty else { return nil }
    }

    private init(entries: [Entry]) {
        for entry in entries { add(entry.channel, entry.role, entry.sides, onParts: entry.onParts) }
    }

    /// What a shape of this kind has ports on while it stands for shapes of `targets`' kinds (nil:
    /// a kind with no ports): each channel the first of them has ports on that this kind has ports
    /// on too and every other of them has, in the first's order and not this kind's (which, for ports
    /// on every channel, is the order they're declared in), so a stand-in's dots and its drags go as
    /// the first shape's would: a stand-in for a subboard has indigo dots, and links to a subboard on
    /// its own channel. On this kind's own sides, with the role all of them allow (a kind whose
    /// connections only start and one whose connections only end share none); nil if there is none,
    /// or no target, or the first has no ports. With one target, that kind's channels and roles; with
    /// several, the channels they all take.
    ///
    /// A channel the shapes take on their rows (a table's keys) the stand-in takes on its parts too, as they do: it has no rows,
    /// so no dot of it shows and no drag ends on it, and a connection made by name that names a row through it (a key to a
    /// column of a table on another board: the pill, with the column on the binding) is taken. A stand-in for one row
    /// (`asRow`: a pill for an endpoint) is that row: what the row takes on its rows it takes on its own sides, as a whole.
    func standing(for targets: [KindPorts?], asRow: Bool = false) -> KindPorts? {
        guard let head = targets.first, let first = head else { return nil }
        var shared: [Entry] = []
        for lead in first.entries {
            // A pill for a row takes what rows take, and nothing a shape takes as a whole.
            if asRow, !lead.onParts { continue }
            guard let own = entry(on: lead.channel) else { continue }
            var role: PortRole? = own.role
            for target in targets {
                guard let theirs = target?.entry(on: lead.channel) else {
                    role = nil
                    break
                }
                role = role?.shared(with: theirs.role)
                if role == nil { break }
            }
            if let role { shared.append(Entry(channel: lead.channel, role: role, sides: own.sides, onParts: lead.onParts && !asRow)) }
        }
        guard !shared.isEmpty else { return nil }
        var ports = KindPorts(entries: shared)
        // A stand-in has no rows for a drag to be let go on to name one: what its shapes take on their rows is taken by name only
        // (Connect, `canvas draw`, a typed key), never by a drop on the pill, which would end a key at no row.
        for entry in shared where entry.onParts { ports.roles[entry.channel] = nil }
        return ports
    }

    /// Every installed kind's ports, by kind: what an editor keeps (the registry never changes).
    static func table(in registry: Registry) -> [ShapeKind: KindPorts] {
        Dictionary(registry.kinds.compactMap { kind in KindPorts(of: kind, in: registry).map { (kind, $0) } }) { first, _ in first }
    }

    /// Ports on a channel, unless an earlier contribution gave the kind ports on it.
    private mutating func add(_ channel: ChannelID, _ ports: PortContribution) {
        add(channel, ports.role, ports.sides, onParts: ports.onParts)
    }

    private mutating func add(_ channel: ChannelID, _ role: PortRole, _ sides: [PortSide], onParts: Bool) {
        guard roles[channel] == nil else { return }
        let sides = onParts ? [] : sides.reduce(into: [PortSide]()) { sides, side in if !sides.contains(side) { sides.append(side) } }
        entries.append(Entry(channel: channel, role: role, sides: sides, onParts: onParts))
        roles[channel] = role
        guard role != .target else { return }
        if onParts { partDots.append(channel) }
        for side in sides { dots[side, default: []].append(channel) }
    }

    /// Whether it has any dot: on a side, or on its rows.
    var hasDots: Bool { !dots.isEmpty || !partDots.isEmpty }

    /// Its ports on `channel`, if it has some.
    func entry(on channel: ChannelID) -> Entry? { entries.first { $0.channel == channel } }
}

// MARK: Lookups

extension Registry {
    /// The kind connections are: the connector's (`registrar.connects`); nil without a connector.
    public var connectorKind: ShapeKind? { connector?.kind }

    /// The family of edges connections are, the connector's (`registrar.connects(_:edgeType:…)`):
    /// every channel's edge type is under it. Nil without a connector.
    public var connectorEdgeType: EdgeTypeID? { connector?.edgeType }

    /// Whether the connector makes connections without a drag (it was given `make` and `ends`):
    /// what a caller that connects shapes by name asks before it tries.
    public var makesConnections: Bool { connector?.make != nil && connector?.ends != nil }

    var connector: ConnectorContribution? { contributions(to: Connectors.self).first?.value }

    /// What a shape of `kind` has ports on: its kind's; or, for a stand-in of that kind standing for
    /// shapes of `targets`' kinds, what it takes while it does (`KindPorts.standing(for:)`: none if
    /// they have no ports). With no `targets`, the kind's.
    func kindPorts(_ kind: ShapeKind, standingFor targets: [ShapeKind]) -> KindPorts? {
        guard let own = KindPorts(of: kind, in: self) else { return nil }
        guard !targets.isEmpty else { return own }
        return own.standing(for: targets.map { KindPorts(of: $0, in: self) })
    }

    /// Whether `kind` has ports on any channel, with any role (a stand-in of it standing for shapes
    /// of the kinds `standingFor`: while it does).
    public func hasPorts(_ kind: ShapeKind, standingFor targets: [ShapeKind] = []) -> Bool {
        kindPorts(kind, standingFor: targets) != nil
    }

    /// The channels `kind` has ports on, with any role, in the port table's order (plugin order).
    public func portChannels(of kind: ShapeKind, standingFor targets: [ShapeKind] = []) -> [ChannelID] {
        kindPorts(kind, standingFor: targets)?.entries.map(\.channel) ?? []
    }

    /// The channels a drag from `kind`'s dot on `side` starts connections on, in the port table's
    /// order, as `Connection.channels` has them; with no side, those of all its dots, each once, in
    /// that order. Ports that only take connections (`.target`) have no dot.
    public func dotChannels(of kind: ShapeKind, standingFor targets: [ShapeKind] = [], side: PortSide? = nil) -> [ChannelID] {
        guard let ports = kindPorts(kind, standingFor: targets) else { return [] }
        if let side { return ports.dots[side] ?? [] }
        return ports.entries.filter { $0.role != .target && !$0.sides.isEmpty }.map(\.channel)
    }

    /// Whether `kind` has ports on `channel` that let it be `role` (`PortRole.allows`), on `side` if
    /// one is named: where a connection starts (`.source`, a dot there) or ends (`.target`).
    public func takes(_ kind: ShapeKind, standingFor targets: [ShapeKind] = [], _ channel: ChannelID, as role: PortRole,
                      side: PortSide? = nil) -> Bool {
        guard let entry = kindPorts(kind, standingFor: targets)?.entry(on: channel), entry.role.allows(role) else { return false }
        return side.map(entry.sides.contains) ?? true
    }

    /// The sides on which `kind` has ports on `channel` that let it be `role`, in the order its
    /// ports were given (`x.ports(C.self, sides:)`); none if it has no such ports.
    public func portSides(of kind: ShapeKind, standingFor targets: [ShapeKind] = [], on channel: ChannelID, as role: PortRole) -> [PortSide] {
        guard let entry = kindPorts(kind, standingFor: targets)?.entry(on: channel), entry.role.allows(role) else { return [] }
        return entry.sides
    }

    /// The sides on which `kind` has ports on any channel, each once, in the order they were first
    /// given: where a stand-in of it standing for shapes of the kinds `standingFor` takes
    /// connections at all (a reference's, its left and right).
    public func portSides(of kind: ShapeKind, standingFor targets: [ShapeKind] = []) -> [PortSide] {
        guard let ports = kindPorts(kind, standingFor: targets) else { return [] }
        return ports.entries.reduce(into: [PortSide]()) { sides, entry in
            for side in entry.sides where !sides.contains(side) { sides.append(side) }
        }
    }

    /// The channel a connection from a shape of `kind` (leaving by `fromSide`, if one is named) to a
    /// shape of `target` (arriving by `toSide`, if one is named) is on, as a drag from a port picks
    /// one (`CanvasEditor.channel(of:endingAt:)`): the first of `kind`'s dot channels, in the port
    /// table's order, that `target` takes as a target; nil if they share none. What connects shapes
    /// by name goes by it (Connections' `PortEdgesPlugin`), so a script's edge picks as a drag does.
    /// An end may be a stand-in (`fromStandingFor`, `toStandingFor`: the kinds of what it stands
    /// for), which has the ports of what it stands for on its own sides.
    public func connectionChannel(from kind: ShapeKind, fromSide: PortSide? = nil, fromStandingFor fromTargets: [ShapeKind] = [],
                                  to target: ShapeKind, toSide: PortSide? = nil, toStandingFor toTargets: [ShapeKind] = []) -> ChannelID? {
        dotChannels(of: kind, standingFor: fromTargets, side: fromSide).first {
            takes(target, standingFor: toTargets, $0, as: .target, side: toSide)
        }
    }

    /// Whether `kind` has ports on `channel` on its parts (its rows: `partPorts`) that let it be `role`: a connection on it
    /// that starts or ends on one of its shapes is at a row, not the shape as a whole.
    public func takesOnParts(_ kind: ShapeKind, standingFor targets: [ShapeKind] = [], _ channel: ChannelID, as role: PortRole) -> Bool {
        guard let entry = kindPorts(kind, standingFor: targets)?.entry(on: channel) else { return false }
        return entry.onParts && entry.role.allows(role)
    }

    /// Whether `kind` has ports on its parts (`onParts`) or on its sides (or, for a stand-in, on what it stands for).
    public func hasPorts(_ kind: ShapeKind, standingFor targets: [ShapeKind] = [], onParts: Bool) -> Bool {
        kindPorts(kind, standingFor: targets)?.entries.contains { $0.onParts == onParts } ?? false
    }

    /// The channels `kind` has ports on on its parts (its rows), whatever their role, in the port table's order.
    public func partChannels(of kind: ShapeKind) -> [ChannelID] {
        kindPorts(kind, standingFor: [])?.entries.filter(\.onParts).map(\.channel) ?? []
    }

    /// The channels a drag from a dot on one of `kind`'s parts starts connections on, in the port table's order.
    public func partDotChannels(of kind: ShapeKind, standingFor targets: [ShapeKind] = []) -> [ChannelID] {
        kindPorts(kind, standingFor: targets)?.partDots ?? []
    }

    /// Whether `shape`'s kind has ports on `channel` that let it be `role`: where a connection starts
    /// (`.source`), or where it ends (`.target`). What rules for connections already drawn go by. A
    /// shape kept aside takes nothing.
    public func accepts(_ shape: AnyShapeRecord, on channel: ChannelID, as role: PortRole) -> Bool {
        !shape.isOpaque && takes(shape.kind, channel, as: role)
    }

    /// Whether some installed plugin declares `channel`.
    public func declares(_ channel: ChannelID) -> Bool {
        contributions(to: Channels.self).contains { $0.value.id == channel }
    }

    /// What a connection on `channel` is called (`Channel.title`: its pill on the line, its row in a release's list); nil for an
    /// untitled channel, or one no plugin declares.
    public func channelTitle(_ channel: ChannelID) -> String? {
        contributions(to: Channels.self).first { $0.value.id == channel }?.value.title
    }

    /// The capsule of a titled channel's pill (`Channel.tint`, else its dots' color); nil for an untitled one.
    public func channelTint(_ channel: ChannelID) -> NSColor? {
        contributions(to: Channels.self).first { $0.value.id == channel }?.value.tint
    }

    /// The color of a channel's dots (`Channel.color`); nil for one no plugin declares.
    public func channelColor(_ channel: ChannelID) -> NSColor? {
        contributions(to: Channels.self).first { $0.value.id == channel }?.value.color
    }

    /// The parts (rows) a connection's start and end are bound to, by the connector's `parts`: nil each for an end bound to a
    /// shape as a whole, a free end, or a shape that isn't a connection.
    public func connectionParts(of record: AnyShapeRecord) -> (from: PartID?, to: PartID?) {
        guard let connector, record.kind == connector.kind, !record.isOpaque, let parts = connector.parts else { return (nil, nil) }
        return parts(record)
    }

    /// Whether the connector can start a connection from the shape `id` in `shapes` or end one there
    /// (its `canConnect`): false without a connector, or for a shape `shapes` doesn't have or keeps
    /// aside. Ask it of the document the connection will be in: a transaction's (`transaction.shapes`)
    /// has the shapes it inserted.
    public func canConnect(_ id: ShapeID, in shapes: ShapeContext) -> Bool {
        guard let connector, let record = shapes.shape(id), !record.isOpaque else { return false }
        return connector.canConnect(id, shapes)
    }

    /// A connection made without a drag, by the connector's `make`: with no `existing`, a new one
    /// (not inserted: the caller inserts it); else `existing` (a connection) changed as `request`
    /// says, keeping its id, which is `existing` itself when nothing would change, so `==` tells an
    /// unchanged one (a changed one has no place in the stack yet: `transaction.update(existing.id)
    /// { $0 = made }` keeps its place). Nil if the connector can't make it (it has no `make`, it
    /// refuses, `existing` isn't a connection), or there's no connector. `shapes` is the document it
    /// will be in: ask `canConnect` of both ends first, and choose the channel (`dotChannels`,
    /// `takes`), as a drag from a port would.
    public func connection(_ request: ConnectionRequest, existing: AnyShapeRecord? = nil, in shapes: ShapeContext) -> AnyShapeRecord? {
        guard let connector, let make = connector.make else { return nil }
        if let existing, existing.kind != connector.kind || existing.isOpaque { return nil }
        guard let made = make(request, existing, shapes) else { return nil }
        if let existing, made == existing.copy(as: existing.id) { return existing }
        return made
    }

    /// The shapes a connection starts and ends on, by the connector's `ends`: nil for a shape that
    /// isn't a connection (or is kept aside), one not bound at both ends, or when the connector has
    /// no `ends`.
    public func connectionEnds(of record: AnyShapeRecord) -> (from: ShapeID, to: ShapeID)? {
        guard let connector, record.kind == connector.kind, !record.isOpaque, let ends = connector.ends else { return nil }
        return ends(record)
    }
}

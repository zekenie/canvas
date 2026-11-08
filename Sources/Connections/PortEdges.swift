import Canvas
import Draw

/// Draw's edges, in Connections: `canvas draw`'s edges are Connections' connections. An edge is
/// what the connector draws (`registry.connectorKind`, while it makes connections without a drag),
/// it takes a channel (`channel:`, Connections' key), its sides are where a kind has ports, and
/// it's made by the connector (`registry.connection`), on the channel this plugin picks from the
/// port table, as a drag from a port would: a connection runs only from a shape with ports on its
/// channel to one that takes it.
public struct PortEdgesPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { "port-edges" }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.drawEdges(kind: { registry in registry.makesConnections ? registry.connectorKind : nil },
                            attributes: [ChannelProperty.key.rawValue],
                            sides: { kind, registry in EdgeChannels.sides(of: kind, in: registry) },
                            ends: { record, registry in registry.connectionEnds(of: record) },
                            make: { request, existing, shapes throws(DrawError) in
                                try EdgeChannels.connection(for: request, existing: existing, in: shapes)
                            })
    }
}

/// The channel policy: which channel an edge a script writes is on, and whether its ends and sides
/// take it.
///
/// - `channel: <id>`: that channel, one some plugin declares; the start's kind has a dot on it (on
///   `from:`'s side, if named), and the end's kind takes it as a target (on `to:`'s side, if
///   named). A named side without such a port is `invalid_value`; a kind without one, `no_channel`.
/// - `channel: none`: a plain connection, on no channel, from and to any side.
/// - Unwritten: the first of the start's dot channels (on `from:`'s side, if named; else all its
///   dots', in the port table's order) that the end takes as a target (on `to:`'s side, if named).
///   With none, a plain connection if neither kind has ports on anything, else `no_channel`.
/// - A shape joined to itself takes a channel as any pair does (the connector draws it: arrows, as a
///   loop on the side named), and is joined on one side: `from:` and `to:` naming two is `invalid_value`.
/// - A connection already drawn keeps its channel: a different one written is `invalid_value` (to
///   put it on another, delete it and draw it again), and a side the statement names must have a
///   port on it.
///
/// - An end that's a stand-in (`EdgeRequest.fromStandsFor`, `toStandsFor`: a reference put beside the
///   shape it stands for, which is on another board) takes the channels of what it stands for, as a
///   drag would find them (`registry.connectionChannel`), on its own sides: a named side it has no
///   ports on (a reference has them on its left and right) is `invalid_value`, saying where it does.
///
/// Before any of that, the connector must be able to connect both ends in the board as the script
/// leaves it (`canConnect`), or it's `cannot_connect`, naming the end; and neither end may hold the
/// other (`mayConnect`: a frame and a shape in it), or it's `cannot_connect`, on any channel or none.
@MainActor
enum EdgeChannels {
    /// What `channel: none` says: no channel.
    static let plain = "none"

    /// Why an edge can't be drawn, as `canvas draw` reports it.
    enum Reason: String {
        case noChannel = "no_channel"
        case cannotConnect = "cannot_connect"
        case invalidValue = "invalid_value"
        case `internal`
    }

    static func refuse(_ reason: Reason, _ message: String, hint: String? = nil) -> DrawError {
        DrawError(message, reason: reason.rawValue, hint: hint)
    }

    // MARK: For canvas kinds

    /// The channels an edge may leave a shape of `kind` on, by side: its dots'; none for a kind draw
    /// can't name.
    static func sides(of kind: ShapeKind, in registry: Registry) -> [EdgeRequest.Side: [String]] {
        var sides: [EdgeRequest.Side: [String]] = [:]
        // An edge names its ends: a kind draw can't name has none to offer.
        guard registry.drawCanName(kind) else { return sides }
        for side in EdgeRequest.Side.allCases {
            let channels = registry.dotChannels(of: kind, side: side.port)
            if !channels.isEmpty { sides[side] = channels.map(\.rawValue) }
        }
        return sides
    }

    // MARK: Making one

    /// A channel as a statement writes it.
    enum Written: Equatable {
        /// No `channel:`: this plugin picks one.
        case unwritten
        /// `channel: none`.
        case plain
        case channel(ChannelID)

        /// The channel it names; nil for none.
        var channel: ChannelID? {
            if case .channel(let channel) = self { channel } else { nil }
        }
    }

    /// An end of a connection as ports see it: the shape, and, when it's a stand-in, the kinds of
    /// what it stands for, whose ports it has on its own sides.
    @MainActor
    struct End {
        let record: AnyShapeRecord
        let standsFor: [ShapeKind]
        /// Whether the end is a part of the shape (a row), which takes connections on its kind's part ports, never its sides'.
        var isPart = false

        var kind: ShapeKind { record.kind }

        /// The kind the script wrote, as a message names it: what a stand-in stands for.
        var named: ShapeKind { standsFor.first ?? kind }

        /// What a message about its own ports (its sides) calls it: a stand-in, and what for.
        var described: String { standsFor.first.map { "\(indefinite(kind)) for \(indefinite($0))" } ?? indefinite(kind) }

        /// Whether it takes `channel` as `role`: a row on its kind's part ports, a shape as a whole on its sides'.
        func takes(_ channel: ChannelID, as role: PortRole, side: PortSide? = nil, in registry: Registry) -> Bool {
            let onParts = registry.takesOnParts(kind, standingFor: standsFor, channel, as: role)
            if isPart { return onParts && side == nil }
            return !onParts && registry.takes(kind, standingFor: standsFor, channel, as: role, side: side)
        }

        func sides(on channel: ChannelID, as role: PortRole, in registry: Registry) -> [PortSide] {
            registry.portSides(of: kind, standingFor: standsFor, on: channel, as: role)
        }

        func hasPorts(in registry: Registry) -> Bool { registry.hasPorts(kind, standingFor: standsFor, onParts: isPart) }

        /// The channels a connection may start on from it, on `side` if one is named: a row's dots', or its sides'.
        func starts(side: PortSide?, in registry: Registry) -> [ChannelID] {
            isPart ? registry.partDotChannels(of: kind, standingFor: standsFor)
                   : registry.dotChannels(of: kind, standingFor: standsFor, side: side)
        }
    }

    /// The connection `request` asks for: new (`existing` nil), or `existing` changed as it says.
    static func connection(for request: EdgeRequest, existing: AnyShapeRecord?, in shapes: ShapeContext) throws(DrawError) -> AnyShapeRecord {
        let registry = shapes.registry
        guard let fromRecord = shapes.shape(request.from), let toRecord = shapes.shape(request.to) else {
            throw refuse(.internal, "\(request.written) names a shape that isn't on the board")
        }
        let from = End(record: fromRecord, standsFor: request.fromStandsFor, isPart: request.fromPart != nil)
        let to = End(record: toRecord, standsFor: request.toStandsFor, isPart: request.toPart != nil)
        for (isStart, name, end) in [(true, request.fromName, from), (false, request.toName, to)] where !registry.canConnect(end.record.id, in: shapes) {
            throw refuse(.cannotConnect, "\(name) can't be connected: nothing here connects \(indefinite(end.named))",
                         hint: "connect \(isStart ? "from" : "to") another shape")
        }
        // One holding the other (`mayConnect`'s rule): refused on any channel, and on none.
        let startIsHeld = shapes.containers(of: request.from).contains(request.to)
        if startIsHeld || shapes.containers(of: request.to).contains(request.from) {
            throw refuse(.cannotConnect, "\(request.fromName) can't be connected to \(request.toName), which \(startIsHeld ? "holds it" : "it holds")",
                         hint: "connect \(startIsHeld ? request.fromName : request.toName) to a shape that doesn't hold it")
        }
        // A shape joined to itself is joined on one side: two sides named would say two things.
        if request.from == request.to, let fromSide = request.fromSide, let toSide = request.toSide, fromSide != toSide {
            throw refuse(.invalidValue, "\(request.written) names two sides, from: \(fromSide.rawValue) and to: \(toSide.rawValue), and an edge from a shape to itself is on one",
                         hint: "name one: from: \(fromSide.rawValue), or to: \(toSide.rawValue)")
        }
        let written = try self.written(request, in: registry)
        let channel: ChannelID?
        if let existing {
            let current = existing[ChannelProperty.self]
            if written != .unwritten, written.channel != current {
                let pair = "\(request.fromName) \(request.bothHeads ? "<->" : "->") \(request.toName)"
                throw refuse(.invalidValue, "the edge from \(request.fromName) to \(request.toName) is \(on(current)), not \(on(written.channel))",
                             hint: "delete edge \(pair) above this line to draw it \(on(written.channel))")
            }
            channel = current
            if current != nil { try checkStandInSides(request, from: from, to: to, in: registry) }
            if let current, registry.declares(current) {
                try checkSides(request, from: from, to: to, on: current, written: written != .unwritten, in: registry)
            }
        } else {
            if written != .plain { try checkStandInSides(request, from: from, to: to, in: registry) }
            channel = try pick(request, from: from, to: to, written: written, in: registry)
        }
        let made = registry.connection(ConnectionRequest(from: request.from, to: request.to, fromSide: request.fromSide?.port,
                                                         toSide: request.toSide?.port, fromPart: request.fromPart, toPart: request.toPart,
                                                         channel: channel, bothHeads: request.bothHeads, beside: request.beside),
                                       existing: existing, in: shapes)
        guard let made else {
            throw refuse(.cannotConnect, "\(request.fromName) can't be connected to \(request.toName)\(channel.map { " on \($0)" } ?? "")",
                         hint: channel == nil ? "connect other shapes" : "\(ChannelProperty.key): \(plain) draws a plain arrow between them")
        }
        return made
    }

    /// The channel a request writes: none, `none`, or one some plugin declares.
    static func written(_ request: EdgeRequest, in registry: Registry) throws(DrawError) -> Written {
        guard let word = request.attributes[ChannelProperty.key.rawValue] else { return .unwritten }
        if word == plain { return .plain }
        let channel = ChannelID(rawValue: word)
        guard registry.declares(channel) else {
            let all = declared(in: registry).map(\.rawValue) + [plain]
            throw refuse(.invalidValue, "\(ChannelProperty.key): \(word) isn't a channel", hint: "\(ChannelProperty.key): takes \(all.joined(separator: "|"))")
        }
        return .channel(channel)
    }

    /// The channel of a new connection, or why there's none.
    private static func pick(_ request: EdgeRequest, from: End, to: End, written: Written, in registry: Registry) throws(DrawError) -> ChannelID? {
        let channel: ChannelID
        switch written {
        case .plain:
            return nil
        case .channel(let wanted):
            guard from.takes(wanted, as: .source, in: registry), to.takes(wanted, as: .target, in: registry) else {
                throw refuse(.noChannel, "\(request.written) can't be on \(wanted): \(described([from, to], sides: true, in: registry))",
                             hint: "\(ChannelProperty.key): \(plain) draws a plain arrow between them")
            }
            try checkSides(request, from: from, to: to, on: wanted, written: true, in: registry)
            channel = wanted
        case .unwritten:
            if let first = from.starts(side: request.fromSide?.port, in: registry).first(where: {
                to.takes($0, as: .target, side: request.toSide?.port, in: registry)
            }) {
                channel = first
            } else if !from.hasPorts(in: registry), !to.hasPorts(in: registry) {
                return nil
            } else {
                let sides = [request.fromSide.map { "from: \($0)" }, request.toSide.map { "to: \($0)" }].compactMap { $0 }
                let ends = "\(request.fromName) and \(request.toName)" + (sides.isEmpty ? "" : " (\(sides.joined(separator: ", ")))")
                throw refuse(.noChannel, "\(ends) share no channel: \(described([from, to], sides: !sides.isEmpty, in: registry))",
                             hint: (sides.isEmpty ? "" : "name sides with ports on one channel, or ")
                                 + "\(ChannelProperty.key): \(plain) draws a plain arrow between them anyway")
            }
        }
        return channel
    }

    /// Refuses a named side where its end's kind has no port on `channel` (a start's, with a dot; an
    /// end's, taking it). With the channel written, that's a value that doesn't fit; with it worked
    /// out, no channel fits.
    private static func checkSides(_ request: EdgeRequest, from: End, to: End, on channel: ChannelID, written: Bool,
                                   in registry: Registry) throws(DrawError) {
        for (key, side, end, role) in [("from", request.fromSide, from, PortRole.source), ("to", request.toSide, to, .target)] {
            guard let side, !end.takes(channel, as: role, side: side.port, in: registry) else { continue }
            let sides = end.sides(on: channel, as: role, in: registry).map(\.word)
            let has = sides.isEmpty ? "no \(channel) ports" : "\(channel) ports on its \(list(sides))"
            throw refuse(written ? .invalidValue : .noChannel, "\(key): \(side): \(end.described) has \(has)",
                         hint: sides.isEmpty ? "\(ChannelProperty.key): \(plain) draws a plain arrow" : "\(key): takes \(sides.joined(separator: "|"))")
        }
    }

    /// Refuses a side named for an end that's a stand-in where it takes no connections at all, on any
    /// channel: the sides of a reference's ports are its left and right, whatever it stands for, so
    /// `to: top` there is a value that doesn't fit. (A plain connection, on no channel, leaves and
    /// arrives by any side, and a stand-in that takes none, standing for a shape with no ports, says
    /// nothing of sides.)
    private static func checkStandInSides(_ request: EdgeRequest, from: End, to: End, in registry: Registry) throws(DrawError) {
        for (key, side, end) in [("from", request.fromSide, from), ("to", request.toSide, to)] where !end.standsFor.isEmpty {
            guard let side else { continue }
            let has = registry.portSides(of: end.kind, standingFor: end.standsFor).map(\.word)
            guard !has.isEmpty, !has.contains(side.rawValue) else { continue }
            throw refuse(.invalidValue, "\(key): \(side): \(indefinite(end.kind)) has no ports on its \(side)",
                         hint: "\(indefinite(end.kind)) takes arrows on its \(list(has)): \(key): takes \(has.joined(separator: "|"))")
        }
    }

    // MARK: Messages

    /// What some ends connect on, as a message says it: `a sticky-note connects on note-link, a
    /// subboard on subboard-link`; by side, `a sticky-note has note-link ports on its top, right,
    /// bottom and left`; `a reference has no ports`. An end that's a stand-in is named for what it
    /// stands for, the shape the script wrote; by side, as what it is, with its own sides (`a
    /// reference for a sticky-note has note-link ports on its left and right`).
    static func described(_ ends: [End], sides: Bool, in registry: Registry) -> String {
        var said: [String] = [], seen: Set<String> = []
        for end in ends {
            let channels = registry.portChannels(of: end.kind, standingFor: end.standsFor), name = sides ? end.described : indefinite(end.named)
            let each = channels.map { channel in "\(channel) ports on its \(list(portSides(of: end, on: channel, in: registry).map(\.word)))" }
            // Each once, as it's said: two ends alike (two tiles) are one.
            guard seen.insert("\(name): \(sides ? each.joined(separator: ", ") : channels.map(\.rawValue).joined(separator: ", "))").inserted else { continue }
            if channels.isEmpty {
                said.append("\(name) has no ports")
            } else if sides {
                said.append("\(name) has \(list(each))")
            } else {
                said.append("\(name) \(said.isEmpty ? "connects on" : "on") \(list(channels.map(\.rawValue)))")
            }
        }
        return said.joined(separator: ", ")
    }

    /// The sides an end has ports on a channel on, whatever they let it be.
    static func portSides(of end: End, on channel: ChannelID, in registry: Registry) -> [PortSide] {
        let sources = end.sides(on: channel, as: .source, in: registry)
        return sources.isEmpty ? end.sides(on: channel, as: .target, in: registry) : sources
    }

    /// Every channel some plugin declares, in plugin order.
    static func declared(in registry: Registry) -> [ChannelID] {
        registry.contributions(to: Channels.self).map(\.value.id)
    }

    /// A kind with its article: `a sticky-note`, `an arrow`.
    static func indefinite(_ kind: ShapeKind) -> String {
        (kind.rawValue.first.map { "aeiou".contains($0) } ?? false ? "an " : "a ") + kind.rawValue
    }

    /// `a`, `a and b`, `a, b and c`.
    static func list(_ items: [String]) -> String {
        guard let last = items.last else { return "" }
        return items.count == 1 ? last : "\(items.dropLast().joined(separator: ", ")) and \(last)"
    }

    /// `on note-link`, or `plain, on no channel`.
    static func on(_ channel: ChannelID?) -> String {
        channel.map { "on \($0)" } ?? "plain, on no channel"
    }
}

extension EdgeRequest.Side {
    /// The side of a shape Ports puts a port on.
    var port: PortSide {
        switch self {
        case .top: .top
        case .right: .right
        case .bottom: .bottom
        case .left: .left
        }
    }
}

extension PortSide {
    /// As a script writes it.
    var word: String {
        switch self {
        case .top: EdgeRequest.Side.top.rawValue
        case .right: EdgeRequest.Side.right.rawValue
        case .bottom: EdgeRequest.Side.bottom.rawValue
        case .left: EdgeRequest.Side.left.rawValue
        }
    }
}

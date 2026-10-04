import Automation
import Canvas
import Connections

/// Draw's edges, in DrawLexicon: `canvas draw`'s edges are Connections' connections. An edge is
/// what the connector draws (`registry.connectorKind`, while it makes connections without a drag),
/// it takes a channel (`channel:`, Connections' key), its sides are where a kind has ports, and
/// it's made by the connector (`registry.connection`), on the channel this plugin picks from the
/// port table, as a drag from a port would: a connection runs only from a shape with ports on its
/// channel to one that takes it.
public struct PortEdgesPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { "port-edges" }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.drawEdges(kind: { registry in registry.makesConnections ? registry.connectorKind : nil },
                            attributes: [ChannelProperty.key.rawValue],
                            sides: { kind, registry in EdgeChannels.sides(of: kind, in: registry) },
                            ends: { record, registry in registry.connectionEnds(of: record) },
                            make: { request, existing, shapes throws(AutomationError) in
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
/// - A connection on a channel never ends where it starts: a shape joined to itself is plain, or
///   `no_channel`.
/// - A connection already drawn keeps its channel: a different one written is `invalid_value` (to
///   put it on another, delete it and draw it again), and a side the statement names must have a
///   port on it.
///
/// Before any of that, the connector must be able to connect both ends in the board as the script
/// leaves it (`canConnect`), or it's `cannot_connect`, naming the end.
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

    static func refuse(_ reason: Reason, _ message: String, hint: String? = nil) -> AutomationError {
        AutomationError(message, reason: reason.rawValue, hint: hint)
    }

    // MARK: For canvas kinds

    /// The channels an edge may leave a shape of `kind` on, by side: its dots'.
    static func sides(of kind: ShapeKind, in registry: Registry) -> [EdgeRequest.Side: [String]] {
        var sides: [EdgeRequest.Side: [String]] = [:]
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

    /// The connection `request` asks for: new (`existing` nil), or `existing` changed as it says.
    static func connection(for request: EdgeRequest, existing: AnyShapeRecord?, in shapes: ShapeContext) throws(AutomationError) -> AnyShapeRecord {
        let registry = shapes.registry
        guard let from = shapes.shape(request.from), let to = shapes.shape(request.to) else {
            throw refuse(.internal, "\(request.written) names a shape that isn't on the board")
        }
        for (isStart, name, record) in [(true, request.fromName, from), (false, request.toName, to)] where !registry.canConnect(record.id, in: shapes) {
            throw refuse(.cannotConnect, "\(name) can't be connected: nothing here connects \(indefinite(record.kind))",
                         hint: "connect \(isStart ? "from" : "to") another shape")
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
            if let current, registry.declares(current) {
                try checkSides(request, from: from, to: to, on: current, written: written != .unwritten, in: registry)
            }
        } else {
            channel = try pick(request, from: from, to: to, written: written, in: registry)
        }
        let made = registry.connection(ConnectionRequest(from: request.from, to: request.to, fromSide: request.fromSide?.port,
                                                         toSide: request.toSide?.port, channel: channel, bothHeads: request.bothHeads),
                                       existing: existing, in: shapes)
        guard let made else {
            throw refuse(.cannotConnect, "\(request.fromName) can't be connected to \(request.toName)\(channel.map { " on \($0)" } ?? "")",
                         hint: channel == nil ? "connect other shapes" : "\(ChannelProperty.key): \(plain) draws a plain arrow between them")
        }
        return made
    }

    /// The channel a request writes: none, `none`, or one some plugin declares.
    static func written(_ request: EdgeRequest, in registry: Registry) throws(AutomationError) -> Written {
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
    private static func pick(_ request: EdgeRequest, from: AnyShapeRecord, to: AnyShapeRecord, written: Written,
                             in registry: Registry) throws(AutomationError) -> ChannelID? {
        let channel: ChannelID
        switch written {
        case .plain:
            return nil
        case .channel(let wanted):
            guard registry.takes(from.kind, wanted, as: .source), registry.takes(to.kind, wanted, as: .target) else {
                throw refuse(.noChannel, "\(request.written) can't be on \(wanted): \(described([from.kind, to.kind], sides: true, in: registry))",
                             hint: "\(ChannelProperty.key): \(plain) draws a plain arrow between them")
            }
            try checkSides(request, from: from, to: to, on: wanted, written: true, in: registry)
            channel = wanted
        case .unwritten:
            if let first = registry.connectionChannel(from: from.kind, fromSide: request.fromSide?.port, to: to.kind, toSide: request.toSide?.port) {
                channel = first
            } else if !registry.hasPorts(from.kind), !registry.hasPorts(to.kind) {
                return nil
            } else {
                let sides = [request.fromSide.map { "from: \($0)" }, request.toSide.map { "to: \($0)" }].compactMap { $0 }
                let ends = "\(request.fromName) and \(request.toName)" + (sides.isEmpty ? "" : " (\(sides.joined(separator: ", ")))")
                throw refuse(.noChannel, "\(ends) share no channel: \(described([from.kind, to.kind], sides: !sides.isEmpty, in: registry))",
                             hint: (sides.isEmpty ? "" : "name sides with ports on one channel, or ")
                                 + "\(ChannelProperty.key): \(plain) draws a plain arrow between them anyway")
            }
        }
        if request.from == request.to {
            throw refuse(.noChannel, "a connection on \(channel) can't end where it starts",
                         hint: "write \(ChannelProperty.key): \(plain) for a plain arrow from \(request.fromName) to itself")
        }
        return channel
    }

    /// Refuses a named side where its end's kind has no port on `channel` (a start's, with a dot; an
    /// end's, taking it). With the channel written, that's a value that doesn't fit; with it worked
    /// out, no channel fits.
    private static func checkSides(_ request: EdgeRequest, from: AnyShapeRecord, to: AnyShapeRecord, on channel: ChannelID, written: Bool,
                                   in registry: Registry) throws(AutomationError) {
        for (key, side, record, role) in [("from", request.fromSide, from, PortRole.source), ("to", request.toSide, to, .target)] {
            guard let side, !registry.takes(record.kind, channel, as: role, side: side.port) else { continue }
            let sides = registry.portSides(of: record.kind, on: channel, as: role).map(\.word)
            let has = sides.isEmpty ? "no \(channel) ports" : "\(channel) ports on its \(list(sides))"
            throw refuse(written ? .invalidValue : .noChannel, "\(key): \(side): \(indefinite(record.kind)) has \(has)",
                         hint: sides.isEmpty ? "\(ChannelProperty.key): \(plain) draws a plain arrow" : "\(key): takes \(sides.joined(separator: "|"))")
        }
    }

    // MARK: Messages

    /// What some kinds connect on, as a message says it: `a sticky-note connects on note-link, a
    /// schema-card on schema-link`; by side, `a sticky-note has note-link ports on its left, right and
    /// bottom`; `a subboard has no ports`.
    static func described(_ kinds: [ShapeKind], sides: Bool, in registry: Registry) -> String {
        var said: [String] = []
        var seen: Set<ShapeKind> = []
        for kind in kinds where seen.insert(kind).inserted {
            let channels = registry.portChannels(of: kind)
            if channels.isEmpty {
                said.append("\(indefinite(kind)) has no ports")
            } else if sides {
                let each = channels.map { channel in "\(channel) ports on its \(list(portSides(of: kind, on: channel, in: registry).map(\.word)))" }
                said.append("\(indefinite(kind)) has \(list(each))")
            } else {
                said.append("\(indefinite(kind)) \(said.isEmpty ? "connects on" : "on") \(list(channels.map(\.rawValue)))")
            }
        }
        return said.joined(separator: ", ")
    }

    /// The sides a kind has ports on a channel on, whatever they let it be.
    static func portSides(of kind: ShapeKind, on channel: ChannelID, in registry: Registry) -> [PortSide] {
        let sources = registry.portSides(of: kind, on: channel, as: .source)
        return sources.isEmpty ? registry.portSides(of: kind, on: channel, as: .target) : sources
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

import AppKit
import Canvas
import CanvasRPC
import Selection
import Topology

/// Ports, as a plugin (data-canvas's): drag targets just outside the sides of a hovered shape, each a
/// dot, from which a drag draws a connection (an arrow) that may end only on a shape that takes its
/// channel. A channel is a kind of connection, declared by the plugin that owns what it means
/// (`registrar.channel(NoteLink.self)`); a kind has ports on the channels it opts into
/// (`note.ports(NoteLink.self)`), and a connection drawn on one keeps it (`ChannelProperty`). What a
/// connection is, is the connector's business: one plugin draws them (`registrar.connects(Arrow.self,
/// edgeType: ArrowEdge.self) { … }`, `ArrowPortsPlugin`'s), and the ports code reads no arrow. A
/// connection bound at both ends is an edge in Topology's graph, of its channel's type (each channel
/// is an edge type, under the family the connector names), or the family's without one. The dots
/// are canvas buttons (Selection's `CanvasButtons`), dragged rather than clicked.
extension PluginID {
    public static let ports: PluginID = "ports"
}

// MARK: Channels

/// A channel's id: what a connection drawn on the channel keeps (`ChannelProperty`), so never changed
/// once shipped. Only its channel type writes it (`static let id: ChannelID = "note-link"`); the
/// build's id audit refuses another module that writes it without depending on the channel's.
public struct ChannelID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public var description: String { rawValue }
}

extension ChannelID {
    /// What a person calls the connections on it, in the plural, from its id: "note links" for
    /// `note-link`. A line of the panel says it ("“Order” doesn’t take note links.").
    public var pluralName: String { rawValue.replacingOccurrences(of: "-", with: " ") + "s" }
}

extension EdgeTypeID {
    /// A channel's edge type: the same name, so a connection's type is the channel it keeps.
    init(_ channel: ChannelID) { self.init(rawValue: channel.rawValue) }
}

extension ChannelID: SchemaDescribed {
    /// A string: the channels are whatever plugins declare, so a schema can't list them.
    public static func schema(in _: inout SchemaDefinitions) -> JSONObject {
        ["type": "string", "minLength": 1, "description": "The kind of connection it is: a channel some plugin declares."]
    }
}

/// A kind of connection (data-canvas's channel): what a drag from a port draws, and what may take it.
/// The type is the key: the plugin that owns what it means declares it (`registrar.channel(C.self)`),
/// and kinds have ports on it (`x.ports(C.self)`), so both import that plugin's module.
///
///     public enum NoteLink {}
///     extension NoteLink: Channel {
///         public static let id: ChannelID = "note-link"
///         public static var color: NSColor { .systemBrown }
///         public static let summary: String? = "an arrow drawn on the note-link channel"
///     }
public protocol Channel {
    /// What a connection drawn on it keeps: never change it once shipped.
    static var id: ChannelID { get }
    /// Its ports' dots. Computed (`static var`), as colors aren't `Sendable`. Default: gray.
    static var color: NSColor { get }
    /// What a connection drawn on it is, in one line: its edge type's summary (`EdgeType.summary`).
    /// Nil (the default): nothing said.
    static var summary: String? { get }
    /// Whether a kind with ports on every channel (`portsOnEveryChannel`: a subboard, which connects to anything with
    /// ports) has ports on it too: true (the default) for a channel any shape may be at an end of; false for one only the
    /// kinds that opt into it are (a key, column to column: a subboard takes no keys). A stand-in's ports on every channel
    /// (a reference's) include it all the same, since what it stands for decides.
    static var isOnEveryChannel: Bool { get }
    /// Whether every kind with dots on its sides starts connections on it too (`.source`, on its dots' sides, after the channels
    /// it has ports on), so a note or a frame may start one though nothing about it opted in: the kit's `calls`, which any shape
    /// may make of an endpoint. False by default.
    static var anyKindMayStart: Bool { get }
    /// What a connection on it is called (`writes`): its pill on the line, in `tint`, and its row in the list a release opens
    /// where several fit. Nil (the default): no pill, and never offered (a key, a note link).
    static var title: String? { get }
    /// The pill's capsule, white text on it, the same in both appearances; nil (the default): its dots' `color`.
    static var tint: NSColor? { get }
}

extension Channel {
    public static var color: NSColor { .systemGray }
    public static var summary: String? { nil }
    public static var isOnEveryChannel: Bool { true }
    public static var anyKindMayStart: Bool { false }
    public static var title: String? { nil }
    public static var tint: NSColor? { nil }
}

/// What a connection drawn on a channel knows: which it is. An added property the connector's kind
/// opts into (`registrar.connects`), with no default, so a connection made any other way (`canvas
/// draw`'s `channel: none`) has none, and binds wherever it's let to.
public enum ChannelProperty {}

extension ChannelProperty: ShapeProperty {
    public static let key: PropertyKey = "channel"
    public static var defaultValue: ChannelID? { nil }
}

/// A channel as declared: `Channels` stores one per channel.
@MainActor
public struct ChannelDeclaration {
    public let id: ChannelID
    let color: NSColor
    /// Whether kinds with ports on every channel have ports on it (`Channel.isOnEveryChannel`).
    let isOnEveryChannel: Bool
    /// Whether every kind with dots starts connections on it (`Channel.anyKindMayStart`).
    var anyKindMayStart = false
    /// What a connection on it is called, and its pill's capsule (`Channel.title`, `tint`).
    var title: String? = nil
    var tint: NSColor? = nil
}

/// The channels plugins declare. Each id once: two declarations of one is `RegistryError.conflict`.
public enum Channels {}

extension Channels: KeyedExtensionPoint {
    public typealias Contribution = ChannelDeclaration
    public static var owner: PluginID { .ports }
    public static func uniqueKeys(of channel: ChannelDeclaration, for _: ShapeTarget) -> [AnyHashable] { [ChannelKey(id: channel.id)] }
    public static func summary(of channel: ChannelDeclaration, for _: ShapeTarget) -> String { "channel \(channel.id)" }
}

struct ChannelKey: Hashable, CustomStringConvertible {
    let id: ChannelID
    var description: String { "channel \(id)" }
}

// MARK: Ports

/// A side of a shape's bounds, where a port's dot sits, just outside its middle.
public enum PortSide: CaseIterable, Hashable, Sendable {
    case top, right, bottom, left
}

/// What a kind's ports on a channel do (data-canvas's port end).
public enum PortRole: Hashable, Sendable {
    /// Its dots start connections, and connections end on it: the default.
    case both
    /// Its dots start connections; none ends on it.
    case source
    /// Connections end on it; it has no dots.
    case target

    /// Whether a kind with this role may be `role`: where a connection starts (`.source`), where it
    /// ends (`.target`), or either (`.both`, which only a kind whose ports do both may be).
    public func allows(_ role: PortRole) -> Bool { self == .both || self == role }

    /// What a shape that stands for others is, taking the ports of what it stands for: what both
    /// allow. `.both` with a role is that role; nil for connections that only start and ones that
    /// only end, which nothing both are can be.
    func shared(with other: PortRole) -> PortRole? {
        if self == .both { return other }
        return other == .both || other == self ? self : nil
    }
}

/// A kind's ports on one channel, from `x.ports(C.self, sides:role:)`, or on every channel there is,
/// from `x.portsOnEveryChannel(sides:role:)` (`channel` nil: the port table expands it, when it's
/// built, to every channel the registry declares); or on its parts (`x.partPorts(C.self, role:)`:
/// `onParts`, a dot at each end of the row the pointer is on, and connections ending on a row). Only
/// the sugar makes one.
@MainActor
public struct PortContribution {
    let channel: ChannelID?
    let sides: [PortSide]
    let role: PortRole
    var onParts = false
}

/// Which kinds have ports, on which channels, where. One contribution per kind and channel; a kind may
/// have ports on several.
public enum ShapePorts {}

extension ShapePorts: KeyedExtensionPoint {
    public typealias Contribution = PortContribution
    public static var owner: PluginID { .ports }
    public static func uniqueKeys(of ports: PortContribution, for target: ShapeTarget) -> [AnyHashable] {
        [PortKey(target: target, channel: ports.channel)]
    }
    public static func summary(of ports: PortContribution, for target: ShapeTarget) -> String {
        "ports " + (ports.channel.map(\.rawValue) ?? "on every channel") + (ports.onParts ? " on rows" : "") + (target == .any ? "" : " → \(target)")
    }

    /// Every channel a kind has ports on is declared, and the connector's own kind has none: a
    /// connection doesn't start or end on another; and only a kind with parts (`PartedShape`) has ports on its parts.
    public static func check(_ registry: Registry) throws(RegistryError) {
        let declared = Set(registry.contributions(to: Channels.self).map(\.value.id))
        let connector = registry.connectorKind
        for ports in registry.contributions(to: ShapePorts.self) {
            if ports.value.onParts, case .kind(let kind) = ports.target, !registry.partedKinds.contains(kind) {
                throw .invalid(point: "ShapePorts", reason: "\(ports.pluginID) gives \(kind) ports on its parts, but its shapes have none (PartedShape)")
            }
            if let channel = ports.value.channel, !declared.contains(channel) {
                throw .invalid(point: "ShapePorts", reason: "\(ports.pluginID) gives \(ports.target) ports on channel \(channel), which no installed plugin declares")
            }
            if let connector, ports.target == .kind(connector) {
                throw .invalid(point: "ShapePorts", reason: "\(ports.pluginID) gives \(connector) ports, but it's what connections are")
            }
        }
    }
}

struct PortKey: Hashable, CustomStringConvertible {
    let target: ShapeTarget
    /// Nil: on every channel.
    let channel: ChannelID?
    var description: String { "\(target)'s ports on " + (channel.map(\.rawValue) ?? "every channel") }
}

// MARK: The connector

/// A drag from a port, as the connector gets it: where it starts, and on what it may be drawn.
public struct Connection: Sendable {
    /// The shape whose port was pressed: where the connection starts.
    public let shape: ShapeID
    public let side: PortSide
    /// The part of it the dot was at (a row: `partPorts`), the connection starting there; nil for a dot on a side.
    public let part: PartID?
    /// The channels of the port pressed, in the port table's order (plugin order, as
    /// `registry.dotChannels(of:side:)` has them). A connection ends only on a shape that takes one
    /// (`CanvasEditor.channel(of:endingAt:)`), and is drawn on the first it takes.
    public let channels: [ChannelID]
    /// Where the press was, in world units.
    public let origin: CGPoint

    public init(shape: ShapeID, side: PortSide, part: PartID? = nil, channels: [ChannelID], origin: CGPoint) {
        self.shape = shape
        self.side = side
        self.part = part
        self.channels = channels
        self.origin = origin
    }
}

/// A connection asked for without a drag (`registry.connection(_:existing:in:)`): from which shape
/// to which, aimed at which of their sides (none: where the connector aims by itself, an arrow at
/// the shape's center), on which channel (none: a plain connection, as one drawn some other way),
/// and whether it has a head at its start as well as its end. The caller chooses the channel, as a
/// drag from a port would (`dotChannels`, `takes`), and the sides (`portSides`).
public struct ConnectionRequest: Hashable, Sendable {
    public var from: ShapeID
    public var to: ShapeID
    public var fromSide: PortSide?
    public var toSide: PortSide?
    /// The part of `from` it starts at (a row), and of `to` it ends at; nil for the shapes as wholes.
    public var fromPart: PartID?
    public var toPart: PartID?
    public var channel: ChannelID?
    public var bothHeads: Bool
    /// The connections already joining the pair, for a new arrow aimed at both centers, which is bent apart
    /// from them (into the first offset none of them holds); nil: read when it is made. A run of `canvas draw` says it: it has arrows of its own the
    /// file doesn't hold yet.
    public var beside: [ShapeID]?

    public init(from: ShapeID, to: ShapeID, fromSide: PortSide? = nil, toSide: PortSide? = nil, fromPart: PartID? = nil, toPart: PartID? = nil,
                channel: ChannelID? = nil, bothHeads: Bool = false, beside: [ShapeID]? = nil) {
        self.beside = beside
        self.fromPart = fromPart
        self.toPart = toPart
        self.from = from
        self.to = to
        self.fromSide = fromSide
        self.toSide = toSide
        self.channel = channel
        self.bothHeads = bothHeads
    }
}

/// What draws connections: its kind, which opts into `ChannelProperty`; which shapes it can start
/// from and end on; for a drag from a port, the session that draws one; and, to connect shapes
/// without a drag, how it makes (or changes) one and reads where one runs. Only the sugar makes one.
@MainActor
public struct ConnectorContribution {
    let kind: ShapeKind
    let canConnect: @MainActor (ShapeID, ShapeContext) -> Bool
    let make: (@MainActor (ConnectionRequest, AnyShapeRecord?, ShapeContext) -> AnyShapeRecord?)?
    let ends: (@MainActor (AnyShapeRecord) -> (from: ShapeID, to: ShapeID)?)?
    let begin: @MainActor (Connection, CanvasEditor) -> (any Session)?
    /// The parts (rows) a connection's start and end are bound to, nil each for a whole shape.
    var parts: (@MainActor (AnyShapeRecord) -> (from: PartID?, to: PartID?))? = nil
    /// The family of edges its connections are (Topology's): each channel's edge type is under it.
    let edgeType: EdgeTypeID
}

/// Who draws connections: at most one plugin. Without one, no shape shows ports.
public enum Connectors {}

extension Connectors: KeyedExtensionPoint {
    public typealias Contribution = ConnectorContribution
    public static var owner: PluginID { .ports }
    public static func uniqueKeys(of _: ConnectorContribution, for _: ShapeTarget) -> [AnyHashable] { ["the connector"] }
    public static func summary(of connector: ConnectorContribution, for _: ShapeTarget) -> String { "connector → \(connector.kind)" }
}

// MARK: Sugar

extension ShapeRegistrar {
    /// Gives this kind ports on `channel`: a dot just outside the middle of each of `sides`, shown as
    /// the pointer comes near one of its shapes in the select tool, from which a drag draws a
    /// connection on the channel (unless `role` is `.target`); and connections on it may end on its
    /// shapes (unless `role` is `.source`). `note.ports(NoteLink.self)` is on all four sides, and
    /// `note.ports(NoteLink.self, sides: [.left, .right])` on two.
    public mutating func ports<C: Channel>(_ channel: C.Type, sides: [PortSide] = PortSide.allCases, role: PortRole = .both) {
        contribute(PortContribution(channel: C.id, sides: sides, role: role), to: ShapePorts.self)
    }

    /// Gives this kind ports on every channel an installed plugin declares (the port table expands
    /// it, in plugin order, when it's built), as `ports` does one, so the kind names none: a kind
    /// can't import the plugins that own the channels. For a kind that stands for other shapes,
    /// whose instance-level ports follow what it stands for (`CanvasEditor.channel(of:endingAt:)`):
    /// `x.portsOnEveryChannel(sides: [.left, .right])`. And for a kind that connects to anything
    /// that has ports, after the channel of its own (a subboard's: `x.ports(SubboardLink.self)`,
    /// then `x.portsOnEveryChannel()`), so its dots are its own channel's and a drag to another of
    /// its kind is drawn on it. An earlier contribution of the kind's on a channel is its only one
    /// there.
    public mutating func portsOnEveryChannel(sides: [PortSide] = PortSide.allCases, role: PortRole = .both) {
        contribute(PortContribution(channel: nil, sides: sides, role: role), to: ShapePorts.self)
    }

    /// Gives this kind's parts (its rows: the kind must be a `PartedShape`) ports on `channel`: the row the pointer is on
    /// shows a dot at each end, from which a drag draws a connection on the channel starting at that row (unless `role` is
    /// `.target`); and a connection on it ending on one of its shapes binds the row under its end (unless `role` is
    /// `.source`). A table's columns: `table.partPorts(ForeignKey.self)`.
    public mutating func partPorts<C: Channel>(_ channel: C.Type, role: PortRole = .both) {
        contribute(PortContribution(channel: C.id, sides: [], role: role, onParts: true), to: ShapePorts.self)
    }
}

extension PluginRegistrar {
    /// Declares a channel this plugin owns, so kinds can have ports on it, and its edge type
    /// (Topology's, of the same name, with the channel's summary), under the family of edges the
    /// connector draws (a root without a connector): a connection drawn on it is an edge of that type.
    public mutating func channel<C: Channel>(_ channel: C.Type) {
        contribute(ChannelDeclaration(id: C.id, color: C.color, isOnEveryChannel: C.isOnEveryChannel, anyKindMayStart: C.anyKindMayStart,
                                      title: C.title, tint: C.tint ?? (C.title == nil ? nil : C.color)), to: Channels.self)
        edgeType(EdgeTypeID(C.id), parent: { $0.connector?.edgeType }, summary: C.summary)
    }

    /// Ports on `channel` for a kind another plugin registers, as `ports` on a kind's own
    /// registrar.
    public mutating func ports<K: ShapeProps, C: Channel>(_ kind: K.Type, on channel: C.Type, sides: [PortSide] = PortSide.allCases,
                                                          role: PortRole = .both) {
        contribute(PortContribution(channel: C.id, sides: sides, role: role), to: ShapePorts.self, for: .kind(K.kind))
    }

    /// Ports on every channel for a kind another plugin registers, as `portsOnEveryChannel` on a
    /// kind's own registrar.
    public mutating func portsOnEveryChannel<K: ShapeProps>(_ kind: K.Type, sides: [PortSide] = PortSide.allCases, role: PortRole = .both) {
        contribute(PortContribution(channel: nil, sides: sides, role: role), to: ShapePorts.self, for: .kind(K.kind))
    }

    /// Ports on `channel` on the parts of a kind another plugin registers, as `partPorts` on a kind's own registrar.
    public mutating func partPorts<K: ShapeProps, C: Channel>(_ kind: K.Type, on channel: C.Type, role: PortRole = .both) {
        contribute(PortContribution(channel: C.id, sides: [], role: role, onParts: true), to: ShapePorts.self, for: .kind(K.kind))
    }

    /// `K` is what connections are, and this plugin draws them: a drag from a port calls `begin` with
    /// the connection, for the session that draws it (nil to draw nothing), and `canConnect` says
    /// which shapes one can start from and end on (those it can attach to), in the document it's
    /// given (the editor's, or a transaction's). `K` opts into `ChannelProperty`, which a connection
    /// drawn on a channel sets. To connect shapes without a drag (`registry.connection`), `make`
    /// makes one as a request says, not inserted, with the request's channel set before it asks
    /// any rule; or, given an existing connection, changes it: only the sides the request names, and
    /// its heads, keeping the rest (its channel, its curve); nil if it can't. And `ends` reads which
    /// shapes a connection starts and ends on (nil unless both). Without them, a connection is only
    /// ever drawn from a port. `F` is the family of edges its connections are (Topology's), which
    /// this declares: a connection `ends` finds bound at both ends is one edge from the one to the
    /// other, of its channel's type (`F`'s child) or, drawn on none, of `F`; one without `ends`
    /// carries none. A channel no plugin declares (a file from a newer app) is kept as written, its
    /// type one nobody declares, unless it's another edge type's id (`mention`): a connection is
    /// never an edge of a type that isn't a channel's, so it's then of `F`.
    public mutating func connects<K: ShapeProps, F: EdgeType>(_ kind: K.Type, edgeType family: F.Type,
                                                              canConnect: @escaping @MainActor (ShapeID, ShapeContext) -> Bool,
                                                              make: (@MainActor (ConnectionRequest, AnyShapeRecord?, ShapeContext) -> AnyShapeRecord?)? = nil,
                                                              ends: (@MainActor (AnyShapeRecord) -> (from: ShapeID, to: ShapeID)?)? = nil,
                                                              parts: (@MainActor (AnyShapeRecord) -> (from: PartID?, to: PartID?))? = nil,
                                                              begin: @escaping @MainActor (Connection, CanvasEditor) -> (any Session)?) {
        optIn(K.self, to: ChannelProperty.self)
        edgeType(F.self)
        contribute(ConnectorContribution(kind: K.kind, canConnect: canConnect, make: make, ends: ends, begin: begin, parts: parts, edgeType: F.id),
                   to: Connectors.self, for: .kind(K.kind))
        guard let ends else { return }
        let familyID = F.id
        edges(K.self) { record, registry, sink in
            guard let (from, to) = ends(record) else { return }
            var type = familyID
            if let channel = record[ChannelProperty.self] {
                let named = EdgeTypeID(channel)
                if registry.declares(channel) || !registry.declaresEdgeType(named) { type = named }
            }
            let ends = parts?(record)
            sink.emit(type, from: from, to: to, fromPart: ends?.from, toPart: ends?.to)
        }
    }
}

// MARK: Lookups (the rest are the port table's, `PortTable.swift`)

extension CanvasEditor {
    /// The channel `connection` would be drawn on if it ended at `shape`: the first of its channels
    /// that `shape` takes as a target (as `registry.takes(_:_:as:)` has it for its kind; for a
    /// shape that stands for others, a reference, what it stands for now: `ports(of:)`); nil if it
    /// takes none (or it holds where the connection starts or is held by it: `mayConnect`, or it's
    /// kept aside). The shape it starts from is asked as any other: a drag let go back on it joins it
    /// to itself, which the connector draws as it says (arrows: a loop). Cheap enough to ask of each
    /// shape under the pointer: it reads the port table the editor keeps, a stand-in's, kept until
    /// what it stands for changes, and the two shapes' containers.
    public func channel(of connection: Connection, endingAt shape: AnyShapeRecord) -> ChannelID? {
        guard !shape.isOpaque, shapeContext.mayConnect(shape.id, connection.shape),
              let ports = service(PortState.self)?.ports(of: shape) else { return nil }
        return connection.channels.first { ports.roles[$0]?.allows(.target) == true }
    }

    /// Whether `connection`, already drawn, may have its end in `role` (where it starts, `.source`;
    /// where it ends, `.target`) at `shape`, as far as what a stand-in stands for goes: for a
    /// stand-in (a reference), the connection's channel must be one it takes now in that role, the
    /// judgement a drag's end gets from `channel(of:endingAt:)`. True for any other shape, for a
    /// connection on no channel or one no plugin declares, and without ports (`PortsPlugin`). What
    /// the connector adds to its own rules when it re-aims an end, since the static rule lets any
    /// channel end at a stand-in.
    public func portsAllow(_ connection: AnyShapeRecord, as role: PortRole, at shape: AnyShapeRecord) -> Bool {
        service(PortState.self)?.allows(connection, as: role, at: shape) ?? true
    }

    #if DEBUG
    /// How many stand-ins' ports are kept (debug builds): one for each it was asked about, until it
    /// or its file goes (and, as what it stands for changes, they're worked out again).
    public var standingPortsKept: Int { service(PortState.self)?.standingPortsKept ?? 0 }
    #endif
}

extension ShapeContext {
    /// Whether a connection may join two shapes where they are: not when one holds the other, at any
    /// depth (a frame and a note in it, or a frame inside it), either way round. One between them
    /// would run from inside the one (an arrow aims its end at a shape that holds its other end at a
    /// point inside it), and the containment says already what it would. A port's drag ends on
    /// neither (`channel(of:endingAt:)`), Connect refuses the pair, `canvas draw` refuses the edge,
    /// and the connector keeps its ends to it (`ArrowPortsPlugin`'s rule). True for a shape and
    /// itself, which is another rule's. O(the shapes' depth).
    public func mayConnect(_ a: ShapeID, _ b: ShapeID) -> Bool { !nests(a, b) }
}

// MARK: The plugin

/// A horizontal any kind can opt into: ports, dots on its shapes' sides that a drag connects from,
/// on channels that say what may connect to what. The connector (arrows, through `ArrowPortsPlugin`)
/// draws the connections. Needs Selection, whose canvas buttons the dots are.
public struct PortsPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .ports }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.declare(ChannelProperty.self)
        registrar.service { PortState(editor: $0) }
        registrar.overlay(PortOverlay())
        registrar.canvasButtons(at: { editor, point in editor.service(PortState.self)?.dot(atViewPoint: point) },
                                drag: { dot, origin, editor in editor.service(PortState.self)?.connect(from: dot, at: origin) })
        // ⌘L connects two selected shapes, or one to itself: the port's drag from the keyboard (its item: `ConnectMenuPlugin`).
        registrar.connectCommand()
        // The release of every connection: a titled channel's, the first answer (several fit: drawn plain, and offered).
        registrar.connectionMade(ChannelRelease.answer)
        // A shape's arrows are its ⌥Tab parts: every shape by its nature can have one bound to it.
        registrar.forEveryShape { shapes in
            shapes.shapeParts(named: "arrows") { editor, shape in editor.connectionParts(of: shape.id) }
        }
    }
}

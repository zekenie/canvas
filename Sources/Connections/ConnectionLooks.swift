import Canvas
import CoreGraphics

// What a connection looks like beyond what the connector draws for any: a mark at each end and a line width, answered by the
// plugin that owns what the connection means (its channel), never stored. A key is a crow's foot at its column and two bars at
// the row it references, 2.5 wide (the engineering kit's). The connector asks when it works out a connection's geometry and
// keeps the answer with it, so nothing is asked per frame, and what the answer read (a column made nullable) works it out
// again, as any shape a geometry reads does.

/// What a connection's end is drawn with.
public enum EndMark: Hashable, Sendable, CaseIterable {
    /// Nothing: the line runs to the end.
    case none
    /// The connector's head (an arrow's chevron), whatever the connection stores.
    case arrowhead
    /// Exactly one: two bars across the line.
    case one
    /// None or one: a bar, then a hollow circle.
    case zeroOrOne
    /// Many: a crow's foot.
    case many
}

/// How a connection looks: each end's mark and its line's width. Nil for any of them: the connector's own (an arrow's stored
/// head, its width).
public struct ConnectionLook: Hashable, Sendable {
    public var start: EndMark?
    public var end: EndMark?
    /// In world units.
    public var lineWidth: CGFloat?

    public init(start: EndMark? = nil, end: EndMark? = nil, lineWidth: CGFloat? = nil) {
        self.start = start
        self.end = end
        self.lineWidth = lineWidth
    }

    /// The mark at an end where the connection starts (`isStart`) or ends.
    public func mark(atStart isStart: Bool) -> EndMark? { isStart ? start : end }
}

/// What a plugin is asked of a connection: it, the channel it is on, where each end is bound (a shape, and a part of it: a row),
/// nil for a free end, and the shapes to read through (a read here is a read of the connection's geometry: a change to what is
/// read works the look out again).
@MainActor
public struct ConnectionLookQuery {
    public let connection: AnyShapeRecord
    public let channel: ChannelID?
    public let from: PartAddress?
    public let to: PartAddress?
    public let shapes: ShapeContext

    public init(connection: AnyShapeRecord, channel: ChannelID?, from: PartAddress?, to: PartAddress?, shapes: ShapeContext) {
        self.connection = connection
        self.channel = channel
        self.from = from
        self.to = to
        self.shapes = shapes
    }
}

/// How connections look, from the plugins that own what they mean: a list, asked in plugin order, the first answer winning; an
/// answer is nil for a connection the plugin has nothing to say about (one on another channel).
public enum ConnectionLooks {}

extension ConnectionLooks: ExtensionPoint {
    public typealias Contribution = @MainActor (ConnectionLookQuery) -> ConnectionLook?
    public static var owner: PluginID { .ports }
    public static func summary(of _: Contribution, for _: ShapeTarget) -> String { "connection look" }
}

extension PluginRegistrar {
    /// Says how connections look that this plugin knows the meaning of (`ConnectionLooks`): nil for any other.
    public mutating func connectionLook(_ look: @escaping @MainActor (ConnectionLookQuery) -> ConnectionLook?) {
        contribute(look, to: ConnectionLooks.self)
    }
}

extension Registry {
    /// How `connection` looks, its ends bound at `from` and `to`: the first plugin's answer; nil when none answers (nor are any
    /// installed). The connector asks it when it works out the connection's geometry, and keeps it.
    @MainActor
    public func connectionLook(of connection: AnyShapeRecord, from: PartAddress?, to: PartAddress?, in shapes: ShapeContext) -> ConnectionLook? {
        let looks = contributions(to: ConnectionLooks.self)
        guard !looks.isEmpty else { return nil }
        let query = ConnectionLookQuery(connection: connection, channel: connection[ChannelProperty.self], from: from, to: to, shapes: shapes)
        for look in looks { if let answer = look.value(query) { return answer } }
        return nil
    }
}

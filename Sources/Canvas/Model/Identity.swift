import Foundation

/// Names a kind of shape. Stated once, as `static let kind` on the kind's props type.
public struct ShapeKind: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public var description: String { rawValue }
}

/// A shape's identity. Pass one in to build a shape with a known id (decoding, tests).
public struct ShapeID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString }
}

/// A plugin's identity, unique in the plugin list. A plugin that owns an extension point publishes
/// its id as a static member (`extension PluginID { static let tags: PluginID = "tags" }`)
/// so the point can name its owner without a string typo compiling.
public struct PluginID: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public var description: String { rawValue }
    /// The core's own plugin: the select tool and the core's extension points.
    public static let core: PluginID = "core"
}

public struct ToolID: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    /// A tool that places a shape is named after the shape's kind.
    public init(placing kind: ShapeKind) { rawValue = kind.rawValue }
    public var description: String { rawValue }
    public static let select: ToolID = "select"
}

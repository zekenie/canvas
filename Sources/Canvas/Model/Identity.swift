import Foundation

/// Names a kind of shape. Stated once, as `static let kind` on the kind's props type.
public struct ShapeKind: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public var description: String { rawValue }
}

/// A shape's identity. Pass one in to build a shape with a known id (decoding, tests).
public struct ShapeID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString }
}

/// As the UUID's string, wherever an id is written: in a board, and in props that name a shape.
extension ShapeID: Codable {
    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A plugin's identity, unique in the plugin list. A plugin that owns an extension point publishes
/// its id as a static member (`extension PluginID { static let tags: PluginID = "tags" }`)
/// so the point can name its owner without a string typo compiling.
public struct PluginID: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public var description: String { rawValue }
    /// The core's own plugin: the Hand tool and the core's extension points.
    public static let core: PluginID = "core"
}

public struct ToolID: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    /// A tool that places a shape is named after the shape's kind.
    public init(placing kind: ShapeKind) { rawValue = kind.rawValue }
    public var description: String { rawValue }
    public static let hand: ToolID = "hand"
}

/// Something to do, by name, for a plugin to claim with `registrar.command`: what a menu item sends
/// (the canvas view forwards AppKit's standard actions as these, and the board's window its own
/// menu items), and what a key or any plugin can run with `editor.perform`. The core only routes it.
public struct CanvasCommand: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public var description: String { rawValue }
    /// Edit › Delete.
    public static let delete: CanvasCommand = "delete"
    /// Edit › Select All.
    public static let selectAll: CanvasCommand = "selectAll"
    /// Go › Back (⌘[), whatever has the keyboard.
    public static let goBack: CanvasCommand = "goBack"
    /// Edit › Cut, Copy and Paste, from the board's window, wherever the keyboard is but in text.
    public static let cut: CanvasCommand = "cut"
    public static let copy: CanvasCommand = "copy"
    public static let paste: CanvasCommand = "paste"
}

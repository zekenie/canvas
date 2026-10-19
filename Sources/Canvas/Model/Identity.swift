import Foundation

/// Names a kind of shape. Stated once, as `static let kind` on the kind's props type.
public struct ShapeKind: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public var description: String { rawValue }
}

/// Names a property a plugin adds to the kinds that opt in (`ShapeProperty`). Stated once, as
/// `static let key` on the property's type: where boards keep its values, and its name in each
/// kind's schema.
public struct PropertyKey: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public var description: String { rawValue }
}

/// A shape's identity. Pass one in to build a shape with a known id (decoding, tests).
///
/// Kept as its UUID's two words: a layout every module knows, so an id, and every value that holds
/// one (an edge, a record, a set or dictionary key), is copied, compared and hashed as two words
/// are. Foundation's `UUID` is resilient: a value holding one goes through witnesses for each.
public struct ShapeID: Hashable, Sendable, CustomStringConvertible {
    private let high: UInt64
    private let low: UInt64

    public init(_ rawValue: UUID = UUID()) {
        (high, low) = withUnsafeBytes(of: rawValue.uuid) { ($0.loadUnaligned(as: UInt64.self), $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self)) }
    }

    /// The UUID it is.
    public var rawValue: UUID {
        var uuid: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &uuid) { bytes in
            bytes.storeBytes(of: high, as: UInt64.self)
            bytes.storeBytes(of: low, toByteOffset: 8, as: UInt64.self)
        }
        return UUID(uuid: uuid)
    }

    public var description: String { rawValue.uuidString }
}

/// As the UUID's string, wherever an id is written: in a board, and in props that name a shape.
extension ShapeID: Codable {
    public init(from decoder: any Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(UUID.self))
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

/// Something to do, by name: a command a plugin declares once with `registrar.command`, saying what
/// it's called, where its menu bar item is and what it runs, and that any key, menu item, button or
/// plugin runs with `editor.perform`. Stated once, as a static member in the plugin that declares it
/// (`extension CanvasCommand { static let group: CanvasCommand = "group" }`): the core knows what a
/// command is, never which commands exist, as it knows kinds and tools. Its own are undo, redo and
/// the zooms.
public struct CanvasCommand: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public var description: String { rawValue }
    /// Edit › Undo and Redo: the core's own (`editor.undo()`, `editor.redo()`).
    public static let undo: CanvasCommand = "undo"
    public static let redo: CanvasCommand = "redo"
    /// View › Zoom In, Zoom Out and Actual Size: the core's own, the camera to the next of the zoom
    /// stops (`Camera.zoomStops`) in or out, or to 100%, around the view's center.
    public static let zoomIn: CanvasCommand = "zoomIn"
    public static let zoomOut: CanvasCommand = "zoomOut"
    public static let zoomToActualSize: CanvasCommand = "zoomToActualSize"
    /// View › Zoom to Fit: the core's own, every shape of the board shown in view.
    public static let zoomToFit: CanvasCommand = "zoomToFit"
}

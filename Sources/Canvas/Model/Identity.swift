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
    /// Edit › Undo and Redo: the core's own (`editor.undo()`, `editor.redo()`).
    public static let undo: CanvasCommand = "undo"
    public static let redo: CanvasCommand = "redo"
    /// Go › Open Selection (⌘↓): the only selected shape's board, or whatever opening that shape does.
    public static let openSelection: CanvasCommand = "openSelection"
    /// Go › Enclosing Board (⌘↑): the board holding the shown board's owner.
    public static let enclosingBoard: CanvasCommand = "enclosingBoard"
    /// View › Zoom In, Zoom Out and Actual Size: the core's own, the camera to the next of the zoom
    /// stops (`Camera.zoomStops`) in or out, or to 100%, around the view's center.
    public static let zoomIn: CanvasCommand = "zoomIn"
    public static let zoomOut: CanvasCommand = "zoomOut"
    public static let zoomToActualSize: CanvasCommand = "zoomToActualSize"
    /// View › Zoom to Fit: the core's own, every shape of the board shown in view.
    public static let zoomToFit: CanvasCommand = "zoomToFit"
    /// View › Zoom to Selection: what's selected in view, for the plugin that keeps the selection.
    public static let zoomToSelection: CanvasCommand = "zoomToSelection"
    /// A two-finger double-tap on a trackpad (smart zoom), for a plugin to claim: in the shipped app,
    /// Selection's, which brings the shape under the pointer into view, and again goes back.
    public static let smartMagnify: CanvasCommand = "smartMagnify"
}

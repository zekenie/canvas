import Boards
import Canvas
import CoreGraphics
import Keyboard
import Mentions
import Titles

extension PluginID {
    public static let subboards: PluginID = "subboards"
}

/// A board inside the board: a card on the canvas that holds a board of its own, which opening it
/// shows. Its props are only its frame. What it's called is the title Titles adds to it, and its
/// board is the core's, kept under its id (`BoardID(owner:)`), so nothing about either is here.
public struct Subboard: BoxShapeProps {
    public static let kind: ShapeKind = "subboard"
    public static let properties = Properties<Subboard>(title: "Subboard") {
        Property("frame", \.frame).required()
    }
    public static let defaultSize = CGSize(width: 240, height: 160)

    public var frame: CGRect

    public init(frame: CGRect) { self.frame = frame }
    public init() { self.init(frame: .zero) }
}

extension Subboard {
    /// What a subboard, and its board, is called while it has no title: on its card, its row, its
    /// panel's header and the path.
    static let placeholder = "Untitled Subboard"
    /// Its symbol, on its tool, card, row, header and crumb.
    static let systemImage = "rectangle.stack"
}

/// Subboards: the Subboard tool (B), which places a card that opens onto a board of its own. It
/// opts into Boards (opening it: a double-click, Return, ⌘↓, Open in its menu and panel), Titles
/// (its name, drawn on the card, so no pill), Mentions (by its name; following a mention enters
/// it; a Mentioned In tab in its panel), the table of contents (a row Titles names) and the detail
/// panel (a header that renames it). Going back up, and the path, are Boards'.
public struct SubboardsPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { .subboards }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.shape(SubboardDefinition()) { sub in
            let place = sub.placement(size: Subboard.defaultSize) { Subboard() }
            sub.tool(label: "Subboard", systemImage: Subboard.systemImage, shortcut: "b", placing: place)
            sub.title(pill: false)                         // Titles keeps its name; the card draws it
            sub.opensBoard(placeholder: Subboard.placeholder, systemImage: Subboard.systemImage)
            sub.mentionable(following: .opens)             // by its name, else "Untitled Subboard"; followed, it's entered
            sub.subboardRow()                              // the table of contents, named by Titles
            sub.subboardHeader()                           // renamed in the panel's header
        }
    }
}

import Boards
import Canvas
import Colors
import Connections
import CoreGraphics
import Keyboard
import Mentions
import Palette
import Titles
import Transform

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
    /// What a subboard, and its board, is called while it has no title: its row, its panel's
    /// header and the path.
    static let placeholder = "Untitled Subboard"
    /// Its symbol, on its tool, title's pill, card (while its board is empty), row, header and crumb.
    static let systemImage = "rectangle.stack"
}

/// Subboards: the Subboard tool (B), which places a card that opens onto a board of its own. It
/// opts into Boards (opening it: a double-click, Return, ⌘↓, Open in its menu and panel), Titles
/// (its name, in a pill above the card after the kind's symbol), Mentions (by
/// its name; following a mention enters it), the table of contents
/// (a row Titles names), the detail panel (a header that renames it) and ports (a link on a channel
/// of its own, `SubboardLink`, and on every other: anything with ports connects to a subboard, and
/// a subboard to anything). Going back up, and the path, are Boards'. It takes Transform's container
/// channel: a shape that holds shapes (a frame) can be turned into a subboard, a subboard's size at
/// its top-left corner, holding on its board what the shape held.
public struct SubboardsPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .subboards }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.shape(SubboardDefinition()) { sub in
            let place = sub.placement(size: Subboard.defaultSize) { Subboard() }
            sub.tool(label: "Subboard", systemImage: Subboard.systemImage, shortcut: "b", placing: place)
            sub.tint(SubboardStyle.border)                 // its indigo, wherever it's listed by its kind
            sub.title(symbolInPill: true, coverSurface: SubboardStyle.cardFill)  // Titles keeps its name, in a pill after the symbol
            sub.titleCoverSurface { shape, context in          // a colored card's cover is drawn over its own surface
                context.service(ColorBook.self)?.color(\.surface, for: shape[ColorProperty.self], kind: Subboard.kind)
            }
            sub.opensBoard(placeholder: Subboard.placeholder, systemImage: Subboard.systemImage)
            sub.colorable(default: .indigo)                // the card's border, symbol and fill, indigo until it has a color
            sub.mentionable(following: .opens)             // by its name, else "Untitled Subboard"; followed, it's entered
            sub.subboardRow()                              // the table of contents, named by Titles
            sub.subboardHeader()                           // renamed in the panel's header
            sub.subboardLinks()                            // and ports: arrows to and from a subboard, on its channel and every other
        }
        registrar.channel(SubboardLink.self)               // which this plugin declares
        // Shapes that hold shapes (a frame) turn into a subboard: one a subboard's size at their top-left
        // corner, holding on its board what they held. Turn into Subboard in their menu, and /turn-into-subboard.
        registrar.turnable(into: Subboard.self, through: ContainerChannel.self) { container, transaction in
            // A refused turn leaves the shape as it was, which owns no board to move onto.
            guard transaction.turn(container.id, into: Subboard(frame: CGRect(origin: container.frame.origin, size: Subboard.defaultSize))) else { return }
            transaction.move(container.inside, toBoardOwnedBy: container.id)
        }
    }
}

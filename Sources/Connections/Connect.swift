import CoreGraphics
import Canvas
import ContextMenus
import Draw
import Keyboard

extension CanvasCommand {
    /// Connect (⌘L): the first of two selected shapes connected to the second, as a port's drag would.
    public static let connect: CanvasCommand = "connect"
}

extension PluginRegistrar {
    /// ⌘L, Connect: for two shapes, a connection from the one selected first to the other, while
    /// something makes connections; never mid-press or while a shape is edited.
    mutating func connectCommand() {
        command(.connect, title: ConnectionsStyle.connect, shortcut: KeyChord("l", .command), runs: .whenIdle,
                isEnabled: { $0.shapes.count == 2 && $0.editor.registry.drawsConnections }) { $0.editor.connect($0.shapes) }
    }
}

/// What a connection made without a drag (Connect) is told once it is committed, inside the Connect step: the
/// same word a port's drag gives its connection when released, from whoever owns what the connection then is (a
/// relationship type, Types'), so Connections names no kind and the key and the pointer give the same document. A
/// plugin value of its own after the connector; the hook gets the connection and the editor.
public enum ConnectionMade {}

extension ConnectionMade: ExtensionPoint {
    public typealias Contribution = @MainActor (ShapeID, CanvasEditor) -> Void
    public static var owner: PluginID { .ports }
    public static func summary(of _: Contribution, for _: ShapeTarget) -> String { "connection made" }
}

extension PluginRegistrar {
    /// Hears of every connection Connect makes, after its commit and inside its step.
    public mutating func connectionMade(_ hook: @escaping @MainActor (ShapeID, CanvasEditor) -> Void) {
        contribute(hook, to: ConnectionMade.self)
    }
}

extension PluginID {
    public static let connectMenu: PluginID = "connect-menu"
}

/// Connect in a right-click on two shapes, and so in the menu bar's Shape menu: the item that runs
/// Ports' ⌘L. A plugin value of its own after `ContextMenusPlugin` and `PortsPlugin`, so a list with
/// ports and no context menus has the key and no item.
public struct ConnectMenuPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .connectMenu }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.contextMenuForCanvas {
            MenuItem(command: .connect)
        }
    }
}

extension CanvasEditor {
    /// Connects the first of two shapes to the second (from a key, the one selected first to the other):
    /// what `.connect` does to its shapes, the connection the connector makes by name, as `canvas draw` makes `edge "A" -> "B"` (on the first
    /// channel the start has a dot on that the end takes; a second between a pair bent apart from the
    /// first), one step, "Connect". A stand-in (a reference pill) is an end as what it stands for, as a
    /// drag from a port reads it (`PortState.ports(of:)`): one that stands for nothing now is no end.
    /// The selection stays. Where the connector refuses the pair (no channel joins them; a frame, which
    /// has no ports), or the board takes nothing, nothing changes and both shake. Nothing for any other
    /// number of shapes.
    public func connect(_ ids: [ShapeID]) {
        guard ids.count == 2 else { return }
        let ports = service(PortState.self)
        let standing = ids.map { id in document[id].flatMap { record in ports.map { $0.standingKinds(of: record) } ?? [] } }
        guard let from = standing[0], let to = standing[1] else {
            refuseChanges(to: Set(ids))
            return
        }
        // Whole or not at all (`transactWhole`): a pair the connector refuses, or a board that takes nothing, commits
        // nothing and shakes both.
        // The step is a group around the commit and the hooks (`ConnectionMade`), as a drag's press is: what a hook
        // changes (a relationship type given to the arrow) is the step's, and a menu it pops needs the arrow committed.
        undoHistory.group(ConnectionsStyle.connect) {
            let made: ShapeID? = transactWhole(ConnectionsStyle.connect, shaking: Set(ids)) { transaction in
                guard let made = registry.drawConnection(from: ids[0], to: ids[1], in: transaction.shapes, standingFor: (from, to))
                else { throw Transaction.Refused() }
                transaction.insert(made)
                guard transaction.document[made.id] != nil else { throw Transaction.Refused() }
                return made.id
            }
            guard let made else { return }
            for hook in registry.contributions(to: ConnectionMade.self) { hook.value(made, self) }
        }
    }
}

@MainActor
enum ConnectionsStyle {
    static let connect = "Connect"
    /// A shape's arrows as its parts: "Arrow to Payment".
    static let arrowTo = "Arrow to "
    static let arrowFrom = "Arrow from "
    /// How far a part's ring stands off the arrow's segment, in view points.
    static let partPad: CGFloat = 6
    /// How much of an arrow, from where it leaves a shape, its part takes in, in view points.
    static let partLength: CGFloat = 48
}

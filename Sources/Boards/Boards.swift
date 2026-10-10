import Canvas
import ContextMenus
import DetailPanel
import Keyboard
import Selection
import Titles

/// Boards, as a plugin: getting around a file's boards, whatever kind owns them. A kind whose shapes
/// own boards (the core's `BoardOwning`) opts in with one line, `x.opensBoard(placeholder:systemImage:)`,
/// and its shapes open onto their boards: a double-click, Return, ⌘↓, their row, Open in their
/// context menu and in their panel. ⌘↑ (`.enclosingBoard`) goes back up, selecting the shape whose
/// board it left, and `BoardPath` shows where you are over the canvas. What a board is called is its
/// owner's title (Titles), else its kind's placeholder. The core never learns what a board is called.
extension PluginID {
    /// Not "boards": that's what a file calls its boards, and the command line lists them by.
    public static let boards: PluginID = "board-navigation"
}

/// The extension point: which kinds' shapes open onto their boards, and what a board is called
/// before its owner is named. At most one per kind. Only a `BoardOwning` kind can open one: a plugin
/// naming another (`registrar.opensBoard(P.self, …)`) is `RegistryError.invalid` at startup.
public enum BoardKinds {}

extension BoardKinds: KeyedExtensionPoint {
    public typealias Contribution = BoardKind
    public static var owner: PluginID { .boards }
    public static func uniqueKeys(of _: BoardKind, for target: ShapeTarget) -> [AnyHashable] { [target] }

    /// A kind that isn't `BoardOwning` has no board to open; nor has every kind (`.any`).
    public static func check(_ registry: Registry) throws(RegistryError) {
        for contribution in registry.contributions(to: BoardKinds.self) {
            guard case .kind(let kind) = contribution.target else {
                throw .invalid(point: "BoardKinds", reason: "\(contribution.pluginID) opens boards for every kind; only a BoardOwning kind has one")
            }
            guard registry.boardOwningKinds.contains(kind) else {
                throw .invalid(point: "BoardKinds", reason: "\(contribution.pluginID) opens the boards of \(kind), whose definition isn't BoardOwning")
            }
        }
    }

    public static func summary(of kind: BoardKind, for target: ShapeTarget) -> String { "board → \(target) \"\(kind.placeholder)\"" }
}

/// What `BoardKinds` stores for a kind: what its boards are called while their owners have no title
/// ("Untitled Subboard"), and their symbol. Only the sugar makes one.
public struct BoardKind: Sendable {
    public let placeholder: String
    public let systemImage: String
}

/// Open, first in the menu of a shape that owns a board, as Finder's is.
public enum BoardsMenuGroup {}
extension BoardsMenuGroup: MenuGroup {
    public static var order: Int { 0 }
}

/// The tab opening a board brings to the kinds that opt in: after the kind's own, before Style.
public enum BoardTab {}
extension BoardTab: DetailTab {
    public static var title: String { "Board" }
    public static var order: Int { 50 }
}

/// A horizontal any board-owning kind opts into (`x.opensBoard(…)`): opening its shapes shows their
/// boards, ⌘↑ goes back up, and the path over the canvas (`BoardPath`) shows where you are.
public struct BoardsPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { .boards }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.service { BoardCrumbs(editor: $0) }
        // ⌘↑ and Go › Enclosing Board: up to the board above, off the root, and never mid-press or
        // while a shape is being edited (⌘↑ is then the text's).
        registrar.command(.enclosingBoard, shortcuts: [KeyChord(KeyChord.upArrow.key, .command)],
                          isEnabled: { !$0.board.isRoot && $0.session == nil && $0.editingShapeID == nil }) { $0.goToEnclosingBoard() }
    }
}

extension CanvasEditor {
    /// ⌘↑ and `.enclosingBoard`: the board above the one shown, with the shape whose board this is
    /// selected there (`goUp(to:)`). Nothing on the root.
    public func goToEnclosingBoard() {
        guard boardPath.count > 1 else { return }
        goUp(to: boardPath[boardPath.count - 2])
    }

    /// Shows `board`, one of the boards above the one shown (on `boardPath`), and selects there the
    /// shape that owns the board below it on the path, the way you came, as one step back
    /// (`showBoard(_:selecting:)`): what ⌘↑ and a crumb of the path do. False for a board that isn't
    /// above this one, or while a press runs.
    @discardableResult
    public func goUp(to board: BoardID) -> Bool {
        guard let index = boardPath.firstIndex(of: board), index < boardPath.count - 1,
              let below = boardPath[index + 1].owner else { return false }
        return showBoard(board, selecting: [below])
    }

    /// Follows a shape wherever it is in the file, as the crumbs' menus and Jump To pick one: into it
    /// if its kind opens its board (`opensBoard`: `goInto`, which shows the board), else to it
    /// (`goTo`: its board shown, the shape selected and in view); either is one step back. Nothing
    /// for a shape that isn't in the file, or mid-gesture.
    public func follow(_ id: ShapeID) {
        guard let record = file.record(id) else { return }
        if registry.boardKind(of: record.kind) == nil {
            goTo([id])
        } else {
            goInto(id)
        }
    }

    /// What a board is called, the root by the file's name, as the host has it (the core's
    /// `rootName`), else "Board": what the path, the table of contents' heading and Find's list call
    /// it. Whoever reads the root's observes the name, and only the root's.
    public func name(of board: BoardID) -> String {
        name(of: board, root: board.isRoot ? (rootName.isEmpty ? BoardsStyle.rootFallback : rootName) : "")
    }

    /// What a board is called: its owner's title (Titles), else its kind's placeholder
    /// (`opensBoard`), else the kind's label (`registry.label(of:)`); `root` for the root, for a
    /// caller that names it its own way.
    public func name(of board: BoardID, root: String) -> String {
        guard let owner = owner(of: board) else { return board.isRoot ? root : "Board" }
        if let title = registry.title(of: owner) { return title }
        return registry.boardPlaceholder(of: owner.kind) ?? registry.label(of: owner.kind).name
    }

    /// A board's symbol: its owner's kind's (`opensBoard`), else its kind's label's; nil for the root.
    public func symbol(of board: BoardID) -> String? {
        guard let owner = owner(of: board) else { return nil }
        return registry.boardKind(of: owner.kind)?.systemImage ?? registry.label(of: owner.kind).systemImage
    }
}

extension Registry {
    /// What a board a shape of `kind` owns is called while the shape has no title: the kind's
    /// placeholder (`opensBoard(placeholder:systemImage:)`, "Untitled Subboard"); nil for a kind
    /// that doesn't open its boards. What `editor.name(of:root:)` reads, and anything that names a
    /// board as it does without an editor (a query's rows).
    public func boardPlaceholder(of kind: ShapeKind) -> String? { boardKind(of: kind)?.placeholder }

    /// What `BoardKinds` holds for a kind: at most one.
    func boardKind(of kind: ShapeKind) -> BoardKind? { contributions(to: BoardKinds.self, for: kind).first }
}

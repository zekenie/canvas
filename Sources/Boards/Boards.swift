import Canvas
import ContextMenus
import Keyboard
import Selection
import SwiftUI
import Titles

/// Boards, as a plugin: getting around a file's boards, whatever kind owns them. A kind whose shapes
/// own boards (the core's `BoardOwning`) opts in with one line, `x.opensBoard(placeholder:systemImage:)`,
/// and its shapes open onto their boards: a double-click, Return, ⌘↓, their row and Open in their
/// context menu. ⌘↑ (`.enclosingBoard`) goes back up, selecting the shape whose
/// board it left, and `BoardPath` shows where you are over the canvas. What a board is called is its
/// owner's title (Titles), else its kind's placeholder. The core never learns what a board is called.
extension PluginID {
    /// Not "boards": that's what a file calls its boards, and the command line lists them by.
    public static let boards: PluginID = "board-navigation"
}

extension CanvasCommand {
    /// Go › Enclosing Board (⌘↑), named for the step it takes (Enclosing Group, Enclosing Frame): one
    /// step out of what the selection is in, the group it's inside, else the container its shapes are
    /// in, else the board holding the shown board's owner.
    public static let enclosingBoard: CanvasCommand = "enclosingBoard"
    /// Up to the board above the one shown, whatever is selected: what a list's header button runs
    /// (the table of contents'), where ⌘↑ may step out of a group or a container first.
    public static let goUpBoard: CanvasCommand = "goUpBoard"
    /// Go › Board Path (⌥⌘P): the keyboard goes to the path over the canvas, on its last crumb.
    public static let boardPath: CanvasCommand = "boardPath"
}

/// Go's section of going by where shapes are: Board Path, the keyboard to the path's crumbs, and what goes
/// to a shape by its path (Jump To…, first), after the section of moving between shapes and boards.
public enum PathSection {}
extension PathSection: MenuBarSection {
    public static var menu: MenuBarMenu { "Go" }
}

/// The extension point: which kinds' shapes open onto their boards, and what a board is called
/// before its owner is named. At most one per kind. Only a `BoardOwning` kind can open one: a plugin
/// naming another (`registrar.opensBoard(P.self, …)`) is `RegistryError.invalid` at startup.
public enum BoardKinds {}

extension BoardKinds: KeyedExtensionPoint {
    public typealias Contribution = BoardKind
    public static var owner: PluginID { .boards }
    /// A kind's boards open one kind at a time.
    public static var scope: PointScope { .kinds }
    public static func uniqueKeys(of _: BoardKind, for target: ShapeTarget) -> [AnyHashable] { [target] }

    /// A kind that isn't `BoardOwning` has no board to open.
    public static func check(_ registry: Registry) throws(RegistryError) {
        for contribution in registry.contributions(to: BoardKinds.self) {
            guard case .kind(let kind) = contribution.target else { continue }
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

/// Open, first in the menu of a shape that owns a board, as Finder's is: before a kind's own items.
public enum BoardsMenuGroup {}
extension BoardsMenuGroup: MenuGroup {
    public static var order: Order<Self> { .before(ShapeMenuGroup.self) }
}

/// A horizontal any board-owning kind opts into (`x.opensBoard(…)`): opening its shapes shows their
/// boards, ⌘↑ goes back up, and the path over the canvas (`BoardPath`) shows where you are.
public struct BoardsPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .boards }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.service { BoardCrumbs(editor: $0) }
        // ⌘↑ and Go › Enclosing Board: one step out, never mid-press or while a shape is being edited
        // (⌘↑ is then the text's): of the group the selection is inside, else of the container its
        // shapes are in (selecting it, Selection's), else up to the board above, off the root. The item
        // is named for the step it takes (Enclosing Group, Enclosing Frame, Enclosing Board).
        registrar.command(.enclosingBoard, title: BoardsStyle.enclosingBoard, in: NavigationSection.self, placed: .after(.goForward),
                          shortcut: KeyChord(KeyChord.upArrow.key, .command), runs: .whenIdle, menuTitle: { $0.enclosingTitle },
                          isEnabled: { $0.editor.canStepItems || $0.editor.selectionEnclosure != nil || !$0.editor.board.isRoot }) { $0.editor.goToEnclosing() }
        // Up to the board above whatever is selected: the table of contents' header button.
        registrar.command(.goUpBoard, title: BoardsStyle.enclosingBoard, runs: .whenIdle,
                          isEnabled: { !$0.editor.board.isRoot }) { $0.editor.goToEnclosingBoard() }
        // Go › Board Path: the keyboard to the path's pill (Left and Right walk the crumbs, Return goes up
        // to one, Down shows its menu, Escape comes back); nothing on the root, where there is no pill.
        registrar.command(.boardPath, title: BoardsStyle.boardPath, in: PathSection.self,
                          shortcut: KeyChord("p", [.command, .option]), runs: .whenIdle,
                          isEnabled: { !$0.editor.board.isRoot }) { $0.editor.boardCrumbs?.requestKeyboard() }
        // What the window hosts of it: the path over the top of the canvas, which a fit leaves clear
        // of as far down as its pill reaches, and the board shown's name as the window's subtitle
        // (its crumb's title; none on the root, which the window's title, the file's name, names).
        registrar.hostOverlay(alignment: .top, coveredTop: { BoardPath.coveredHeight(on: $0) }) { editor, exit in BoardPath(editor: editor, onExit: exit) }
        registrar.windowSubtitle { $0.boardCrumbs?.crumbs.last?.title }
    }
}

extension CanvasEditor {
    /// ⌘↑ and `.enclosingBoard`: one step out. Items selected inside a shape (a table's rows) let go, the shape still
    /// selected, as Escape does; else the group the selection is inside, selected whole as Escape selects it, else the
    /// container all the selected shapes are in, selected (Selection's `selectEnclosure`, which brings it into view if it
    /// is not); else the board above (`goToEnclosingBoard`). Never two levels at once.
    public func goToEnclosing() {
        if stepOutOfItems() { return }
        if !selectEnclosure() { goToEnclosingBoard() }
    }

    /// What the Go item that runs `.enclosingBoard` is called now, for the step ⌘↑ would take: Enclosing
    /// Group, "Enclosing " and what the container's kind is called (`registry.label(of:)`: Enclosing Frame),
    /// else Enclosing Board; with items selected inside a shape, that shape's ("Enclosing Table").
    var enclosingTitle: String {
        if canStepItems, let id = selection, let record = document[id] { return BoardsStyle.enclosing + registry.label(of: record.kind).name }
        return switch selectionEnclosure {
        case .group?: BoardsStyle.enclosingGroup
        case .container(let id)?: document[id].map { BoardsStyle.enclosing + registry.label(of: $0.kind).name } ?? BoardsStyle.enclosingBoard
        case nil: BoardsStyle.enclosingBoard
        }
    }

    /// The board above the one shown, with the shape whose board this is selected there
    /// (`goUp(to:)`), whatever is selected here. Nothing on the root. What `.goUpBoard` does.
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

    /// What a shape that others are inside (a frame, a board's owner) is called in a path of where
    /// a shape is, "Alpha › Beta": its title, else what its kind is called, as a board with no
    /// title is (`boardPlaceholder(of:)`, else the kind's label). Whatever writes such a path names
    /// each shape this way (Jump To's rows, a reference's row in the table of contents), so they
    /// agree with one another and with the path over the canvas.
    public func containerName(of record: AnyShapeRecord) -> ContainerName {
        ContainerName(title: record.isOpaque ? nil : title(of: record),
                      placeholder: boardPlaceholder(of: record.kind) ?? label(of: record.kind).name,
                      opensBoard: !record.isOpaque && boardOwningKinds.contains(record.kind))
    }
}

/// What a shape is called in a path of the shapes a shape is inside (`registry.containerName(of:)`).
public struct ContainerName: Hashable, Sendable {
    /// Its title; nil while it has none.
    public let title: String?
    /// What its kind is called, said in a title's place: "Untitled Subboard", "Frame".
    public let placeholder: String
    /// Whether it owns a board, so that what is inside it is on another board than it is (a subboard), not a region of the
    /// board it is on (a frame): what a place says in semibold.
    public let opensBoard: Bool

    public init(title: String?, placeholder: String, opensBoard: Bool = false) {
        self.title = title
        self.placeholder = placeholder
        self.opensBoard = opensBoard
    }

    /// What the path says: the title, else the placeholder.
    public var text: String { title ?? placeholder }
    public var isPlaceholder: Bool { title == nil }
}

import Canvas
import Observation
import Selection
import TableOfContents

/// A board on the path to the one shown, as the path shows it: what it's called and its symbol.
public struct BoardCrumb: Equatable, Identifiable, Sendable {
    public let board: BoardID
    public let title: String
    public let systemImage: String?
    public var id: BoardID { board }

    public init(board: BoardID, title: String, systemImage: String? = nil) {
        self.board = board
        self.title = title
        self.systemImage = systemImage
    }
}

/// What a crumb's menu lists: the crumb's own board, with the shape whose board is next on the path
/// (the way you came) highlighted there; nothing is for the board shown. So hovering a crumb shows
/// what's in that board, as data-canvas's crumbs first did (they later showed the board above).
public struct CrumbMenu: Equatable, Sendable {
    /// The board listed: the crumb's.
    public let board: BoardID
    /// The shape on it whose board is next on the path; nil for the board shown's crumb.
    public let highlighted: ShapeID?

    public init(board: BoardID, highlighted: ShapeID?) {
        self.board = board
        self.highlighted = highlighted
    }
}

/// The path from the root to the board shown, as crumbs, kept for `BoardPath`: made again when
/// another board is shown, or when a board above this one changes (only there are the owners on
/// the path, whose titles name the crumbs), so a commit on the board shown, a drag's every event,
/// costs a look at each board above's revision and redraws nothing. And which crumb's menu shows,
/// as the pointer goes over the crumbs and their menus.
@MainActor
@Observable
public final class BoardCrumbs {
    /// The boards below the root, root first, the board shown last: empty on the root. The root's
    /// crumb is the host's to name (`BoardPath`'s `rootName`).
    public private(set) var crumbs: [BoardCrumb] = []
    /// The crumb whose menu shows, by its board (`menu(of:)` says what the menu lists); nil while
    /// none does. One at a time, as the pointer goes (`pointerEntered(crumb:)` and the rest).
    public private(set) var openMenu: BoardID?
    /// Whether the board shown has no shapes, so its crumb has no menu: kept as commits change it,
    /// so the path reads it without reading the document, which every commit changes.
    private(set) var shownIsEmpty = true

    @ObservationIgnored private unowned let editor: CanvasEditor
    /// The revision of each board above the one shown when the crumbs were made, root first.
    @ObservationIgnored private var above: [Int] = []
    /// The menu about to show, the pointer on its crumb; and the one showing, about to close, the
    /// pointer off it and its crumb.
    @ObservationIgnored private var pendingOpen: (board: BoardID, task: ScheduledTask)?
    @ObservationIgnored private var pendingClose: ScheduledTask?
    #if DEBUG
    /// How many times `BoardPath` has drawn its crumbs (debug builds only), so tests can hold it to
    /// redrawing only when the path changes.
    @ObservationIgnored public var pathRedrawn = 0
    /// How many times the crumbs have been made (debug builds only), so tests can hold a commit on
    /// the board shown to making none.
    @ObservationIgnored public private(set) var remade = 0
    #endif

    init(editor: CanvasEditor) {
        self.editor = editor
        remake()
    }

    /// The most crumbs shown before the middle folds into "…": root, parent and the board shown stay.
    public static let mostShown = 4

    /// `crumbs` with the root's first, as the path lays them out: every one, while there are no more
    /// than `mostShown`; else the root, "…" (`folded`: the ones between, root side first), the parent
    /// and the board shown.
    public func layout(rootName: String) -> (leading: [BoardCrumb], folded: [BoardCrumb], trailing: [BoardCrumb]) {
        let all = [BoardCrumb(board: .root, title: rootName)] + crumbs
        guard all.count > Self.mostShown else { return (all, [], []) }
        return ([all[0]], Array(all[1..<(all.count - 2)]), Array(all.suffix(2)))
    }

    private func remake() {
        #if DEBUG
        remade += 1
        #endif
        let path = editor.boardPath
        let file = editor.file
        above = path.dropLast().map { file.revision(of: $0) }
        let made = path.dropFirst().map { BoardCrumb(board: $0, title: editor.name(of: $0, root: ""), systemImage: editor.symbol(of: $0)) }
        if made != crumbs { crumbs = made }
        noteEmptiness()
        if let openMenu, menu(of: openMenu) == nil { closeMenu() }
    }

    /// Whether the board shown has shapes, as it is now: a look at its count.
    private func noteEmptiness() {
        let empty = editor.document.shapes.isEmpty
        if empty != shownIsEmpty { shownIsEmpty = empty }
    }

    // MARK: The crumbs' menus

    /// What the menu of the crumb of `board` lists: that board, with the shape whose board is next
    /// on the path highlighted (none on the board shown's); nil for a board off the path, the board
    /// shown while it has no shapes, and without the table of contents, whose rows a menu shows.
    public func menu(of board: BoardID) -> CrumbMenu? {
        let path = editor.boardPath
        guard editor.tableOfContents != nil, let index = path.firstIndex(of: board) else { return nil }
        guard index + 1 < path.count else { return shownIsEmpty ? nil : CrumbMenu(board: board, highlighted: nil) }
        return CrumbMenu(board: board, highlighted: path[index + 1].owner)
    }

    /// The pointer is on the crumb of `board`: its menu shows once the pointer has stayed there
    /// `BoardsStyle.menuDelay` (150 ms, data-canvas's hover intent), in place of any other, which
    /// stays till then. Nothing for a crumb without a menu (an empty board shown's).
    public func pointerEntered(crumb board: BoardID) {
        guard menu(of: board) != nil else { return }
        cancelClose()
        guard openMenu != board else { return cancelOpen() }
        guard pendingOpen?.board != board else { return }
        cancelOpen()
        pendingOpen = (board, editor.scheduler.schedule(after: BoardsStyle.menuDelay) { [weak self] in
            guard let self else { return }
            pendingOpen = nil
            openMenu = board
        })
    }

    /// The pointer left the crumb of `board`: its menu won't show if it was about to, and the one
    /// that shows closes after `BoardsStyle.menuDelay`, unless the pointer is on it, or on a crumb,
    /// by then.
    public func pointerExited(crumb board: BoardID) {
        if pendingOpen?.board == board { cancelOpen() }
        closeSoon()
    }

    /// The pointer is on the menu that shows: it stays.
    public func pointerEnteredMenu() { cancelClose() }

    /// The pointer left the menu that shows: it closes after `BoardsStyle.menuDelay`, unless the
    /// pointer is back on it, or on a crumb, by then.
    public func pointerExitedMenu() { closeSoon() }

    /// Closes the menu that shows, now, and any about to show won't: a click on a crumb, a row
    /// picked, another board shown.
    public func closeMenu() {
        cancelOpen()
        cancelClose()
        if openMenu != nil { openMenu = nil }
    }

    /// A row of the menu that shows, picked: the menu closes, then its shape is followed
    /// (`editor.follow`): gone into if its kind opens its board (`opensBoard`), which shows the
    /// board, as following a mention of it does (`goInto`), and else gone to, shown selected on its
    /// board (`goTo`). Either is one step back.
    public func pick(_ id: ShapeID) {
        closeMenu()
        editor.follow(id)
    }

    private func closeSoon() {
        guard openMenu != nil, pendingClose == nil else { return }
        pendingClose = editor.scheduler.schedule(after: BoardsStyle.menuDelay) { [weak self] in
            guard let self else { return }
            pendingClose = nil
            openMenu = nil
        }
    }

    private func cancelOpen() {
        pendingOpen?.task.cancel()
        pendingOpen = nil
    }

    private func cancelClose() {
        pendingClose?.cancel()
        pendingClose = nil
    }
}

extension BoardCrumbs: EditorService {
    /// The owners on the path are on the boards above this one, so the crumbs change only if one of
    /// those did (a file put in place, or a write to another board). The board shown's crumb has a
    /// menu only while that board has shapes.
    public func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        let path = editor.boardPath
        let file = editor.file
        guard path.count - 1 == above.count, zip(path, above).allSatisfy({ file.revision(of: $0) == $1 }) else { return remake() }
        noteEmptiness()
        if shownIsEmpty, openMenu == editor.board { closeMenu() }
    }

    /// Another board shown: the crumbs are made again, and the menu that showed closes.
    public func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        closeMenu()
        remake()
    }
}

extension CanvasEditor {
    /// The path to the board shown, as crumbs (`BoardsPlugin`); nil without it.
    public var boardCrumbs: BoardCrumbs? { service(BoardCrumbs.self) }
}

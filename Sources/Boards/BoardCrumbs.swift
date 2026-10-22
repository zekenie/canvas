import AppKit
import Canvas
import Observation
import TableOfContents

/// A board on the path to the one shown, as the path shows it: what it's called and its symbol, and
/// whether it can't change.
public struct BoardCrumb: Equatable, Identifiable, Sendable {
    public let board: BoardID
    public let title: String
    public let systemImage: String?
    /// Whether the board is read-only (`editor.isReadOnly(board:)`): the shape that owns it can't
    /// change (a locked subboard), or a board above it is read-only. The root never is.
    public let isReadOnly: Bool
    public var id: BoardID { board }

    public init(board: BoardID, title: String, systemImage: String? = nil, isReadOnly: Bool = false) {
        self.board = board
        self.title = title
        self.systemImage = systemImage
        self.isReadOnly = isReadOnly
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

/// A place in the path the keyboard can be: a crumb, by its board, or "…".
public enum PathStop: Hashable, Sendable {
    case crumb(BoardID)
    case fold
}

/// The path from the root to the board shown, as crumbs, kept for `BoardPath`: made again when
/// another board is shown, or when a board above this one changes (only there are the owners on
/// the path, whose titles name the crumbs, and whose locks make boards read-only), so a commit on
/// the board shown, a drag's every event, costs a look at each board above's revision and redraws
/// nothing. And which crumb's menu shows, as the pointer goes over the crumbs and their menus.
@MainActor
@Observable
public final class BoardCrumbs {
    /// The boards below the root, root first, the board shown last: empty on the root. The root's
    /// crumb is the host's to name (`editor.rootName`, which `BoardPath` hands `layout(rootName:)`).
    public private(set) var crumbs: [BoardCrumb] = []
    /// Where the path's read-only part starts: the first crumb whose board is read-only (every board
    /// under it is too), which the path marks with a lock, once. Nil while none is. The editor's
    /// (`editor.readOnlyStart`), kept with the crumbs, so each crumb asks in O(1).
    public private(set) var readOnlyStart: BoardID?
    /// The crumb whose menu shows, by its board (`menu(of:)` says what the menu lists); nil while
    /// none does. One at a time, as the pointer goes (`pointerEntered(crumb:)` and the rest).
    public private(set) var openMenu: BoardID?
    /// Where the keyboard is in the pill (`BoardPath`'s key view has it); nil while it is elsewhere,
    /// or in the menu that shows (`menuKeyboard`). Another board shown clears it.
    public var focus: PathStop?
    /// The keyboard in the menu that shows, opened with it (`openFromKeyboard`): the row that has it.
    public let menuKeyboard = OutlineKeyboard()
    /// The view that takes the pill's keys, as the path made it (`requestKeyboard` makes it the first
    /// responder).
    @ObservationIgnored weak var keyView: NSView?
    /// Gives the keyboard back to the canvas (the path's `onExit`), for a change the pill's keys
    /// didn't make: another board shown while the pill or its menu has the keyboard.
    @ObservationIgnored var giveKeyboardBack: (@MainActor () -> Void)?
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
        // Read-only from where the path turns so, as the editor worked it out in one climb (each board
        // asked on its own would cost the path's depth squared).
        let start = editor.readOnlyStart, from = start.flatMap { path.firstIndex(of: $0) } ?? path.count
        let made = path.indices.dropFirst().map {
            BoardCrumb(board: path[$0], title: editor.name(of: path[$0], root: ""), systemImage: editor.symbol(of: path[$0]), isReadOnly: $0 >= from)
        }
        if made != crumbs { crumbs = made }
        if start != readOnlyStart { readOnlyStart = start }
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

    /// Go › Board Path: the keyboard goes to the pill, on the crumb of the board shown (the path's
    /// deepest). Nothing on the root, where the path shows nothing. False if the pill has no key
    /// view to take it.
    @discardableResult
    public func requestKeyboard() -> Bool {
        guard let last = crumbs.last, let view = keyView, let window = view.window else { return false }
        closeMenu()
        focus = .crumb(last.board)
        defer { NSAccessibility.post(element: view, notification: .valueChanged) }
        return window.makeFirstResponder(view)
    }

    /// Whether the pill, or its menu, has the keyboard.
    public var hasKeyboard: Bool { focus != nil || menuKeyboard.isTaken }

    /// Down on a crumb (the keyboard's way to what hovering does): its menu shows now, and takes the
    /// keyboard on its rows. False for a crumb with no menu. Asked by an assistive app's Show
    /// Contents too, with the canvas holding the keyboard: the pill's key view takes it, which the
    /// menu's rows are answered through.
    @discardableResult
    public func openFromKeyboard(_ board: BoardID) -> Bool {
        guard menu(of: board) != nil else { return false }
        cancelOpen()
        cancelClose()
        openMenu = board
        focus = nil
        menuKeyboard.take()
        if let view = keyView, let window = view.window, window.firstResponder !== view { window.makeFirstResponder(view) }
        return true
    }

    /// Escape in the menu: it closes, and the keyboard goes to its crumb.
    public func closeMenuToCrumb() {
        let board = openMenu
        closeMenu()
        if let board { focus = .crumb(board) }
    }

    /// The keyboard has gone from the pill and its menu (another view took it): the stop is cleared,
    /// and a menu it opened closes.
    func keyboardLeft() {
        let hadMenu = menuKeyboard.isTaken
        focus = nil
        if hadMenu { closeMenu() }
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
            show(board)
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
        menuKeyboard.reset()
    }

    /// A row of the menu that shows, picked: the menu closes, then its shape is followed
    /// (`editor.follow`): gone into if its kind opens its board (`opensBoard`), which shows the
    /// board, as following a mention of it does (`goInto`), and else gone to, shown selected on its
    /// board (`goTo`). Either is one step back.
    public func pick(_ id: ShapeID) {
        closeMenu()
        editor.follow(id)
    }

    /// Shows the menu of `board` in place of any other. The keyboard, if the menu being replaced had
    /// it, goes to the new one's rows: a row of the old menu is no row of this one.
    private func show(_ board: BoardID) {
        guard openMenu != board else { return }
        let hadKeyboard = menuKeyboard.isTaken
        if hadKeyboard { menuKeyboard.reset() }
        openMenu = board
        if hadKeyboard { menuKeyboard.take() }
    }

    private func closeSoon() {
        guard openMenu != nil, pendingClose == nil else { return }
        pendingClose = editor.scheduler.schedule(after: BoardsStyle.menuDelay) { [weak self] in
            guard let self else { return }
            pendingClose = nil
            guard !menuKeyboard.isTaken else { return }
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

    /// Another board shown: the crumbs are made again, and the menu that showed closes. If the pill
    /// or its menu had the keyboard (a board picked from "…", Back or ⌘↑ from the menu bar), it goes
    /// back to the canvas: the stop it was on is gone, and a key view with none would hold the keys.
    public func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        let hadKeyboard = hasKeyboard
        closeMenu()
        focus = nil
        remake()
        if hadKeyboard { giveKeyboardBack?() }
    }
}

extension CanvasEditor {
    /// The path to the board shown, as crumbs (`BoardsPlugin`); nil without it.
    public var boardCrumbs: BoardCrumbs? { service(BoardCrumbs.self) }
}

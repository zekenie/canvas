import AppKit
import Canvas
import DetailPanel
import Observation
import Selection
import SwiftUI

// The issue walk's list: Go › Issue List (⌃⌘'), and the takeover it opens over the panel (IssueWalkPanelPlugin): the walk's
// rows by board, over the current stop's Issues tab, so the band, the list and what the model was shown are one screen.

extension CanvasCommand {
    /// Go › Issue List (⌃⌘'): opens the list of the walk running, else begins a walk of every issue with the list open; with
    /// the list open, closes it, the keyboard going back where it was.
    public static let issueList: CanvasCommand = "issueList"
}

/// Where the keyboard was when the list opened, and where it goes back to (the exact way back, P3). The band tells it the
/// window it is in; the editor has none of its own.
@MainActor
final class IssueListKeyboard {
    weak var window: NSWindow?
    private weak var before: NSResponder?
    /// Whether the canvas had the keyboard when the list opened. The band, which tells the window, is not mounted yet when a
    /// walk begins with the list open, so then the canvas is remembered by this and given the keyboard back by the panel (`exitToCanvas()`).
    private var canvasHadIt = false
    private unowned let editor: CanvasEditor

    init(editor: CanvasEditor) { self.editor = editor }

    func remember(canvasHasKeyboard: Bool) {
        before = window?.firstResponder
        canvasHadIt = canvasHasKeyboard
    }

    func forget() {
        before = nil
        canvasHadIt = false
    }

    /// Gives the keyboard back to the control it was in, if that is still in the window: the canvas, or a control of the band.
    /// A control of the shape's panel is gone with the panel the list replaced. Whether it did.
    func restore() -> Bool {
        defer { forget() }
        if let window, let view = before as? NSView, view.window === window, !view.isHiddenOrHasHiddenAncestor, view.acceptsFirstResponder {
            return window.makeFirstResponder(view)
        }
        guard canvasHadIt, let panel = editor.detailPanel else { return false }
        panel.exitToCanvas()
        return true
    }
}

extension IssueWalk {
    /// Whether another takeover of the panel, listed before the walk's (Find's panel), shows in place of the list: the list is
    /// then closed, and cannot be opened behind it.
    var isListCovered: Bool { editor.detailPanel?.hasTakeover(over: IssueWalkPanelPlugin.pluginID) ?? false }

    /// Whether Go › Issue List has something to do. Closing the list is never refused (it needs no step, and an open list is
    /// never covered: `listShown` closes it as another takeover shows); opening it is as the steps are, not during a gesture nor
    /// while shapes wait to be placed, and not while another takeover covers the list. The command, the key and the band's count
    /// share it.
    public var canToggleList: Bool { isListOpen || (canStep && !isListCovered) }

    /// Opens the list over the panel: editing ends and a number being typed is written first (the list takes the panel over,
    /// and the shape's panel goes as it stands), and where the keyboard is is kept for closing. The list takes the keyboard.
    public func openList() {
        guard isRunning, !isListOpen, !isListCovered else { return }
        editor.endEditing()
        editor.detailPanel?.commitDraft()
        listKeyboard.remember(canvasHasKeyboard: editor.hasKeyboard)
        isListOpen = true
    }

    /// Closes the list and gives the keyboard back where it was when the list opened; the band if that is gone (a field of the
    /// shape's panel, which the list replaced), else the shape's panel.
    public func closeList() {
        guard isListOpen else { return }
        isListOpen = false
        if listKeyboard.restore() { return }
        if editor.detailPanel?.focusBand() == true { return }
        editor.detailPanel?.focusContent()
    }

    /// The selection left the current stop (a line's Show Rule selects the rule's type): the list gives way to the shape's panel
    /// the selection shows, the band staying; ⌘' comes back to the walk. The keyboard is where the person put it.
    func closeListOnSelectionMoved() {
        guard isListOpen else { return }
        isListOpen = false
        listKeyboard.forget()
    }

    /// Escape closed the list (the takeover's `onEscape`): the panel gives the keyboard to the band or the canvas, so where it
    /// was is forgotten.
    public func closeListOnEscape() {
        guard isListOpen else { return }
        isListOpen = false
        listKeyboard.forget()
    }

    /// The list's view appeared or went. It goes with `isListOpen` still true only when another takeover (Find's panel, listed
    /// before the walk's) opens over it: the list is closed then, and where the keyboard was forgotten, as the keyboard is not
    /// moved (the other takeover's field has it). The ways the list closes itself have already said so by the time its view goes
    /// (Return, Escape, ⌃⌘', a selection that left the stop, the walk ending). A table that goes with the keyboard in it leaves it
    /// on the window, which the panel gives to the canvas (the band going with the walk, a selection that changed: `reclaimSoon`).
    func listShown(_ isShown: Bool) {
        if isListShown != isShown { isListShown = isShown }
        if !isShown, isRunning, isListOpen {
            isListOpen = false
            listKeyboard.forget()
        }
    }

    /// Closes the list on the current stop and puts the keyboard in the shape's panel, to fix its data; the band stays.
    public func closeListOnStop() {
        guard isListOpen else { return }
        isListOpen = false
        listKeyboard.forget()
        editor.detailPanel?.focusContent()
    }

    /// ⌃⌘' and the band's count: opens the list or closes it; with no walk running, begins one through every issue with the list
    /// open. Closing is always allowed; opening is not during a gesture, nor while shapes wait to be placed, as the walk's steps
    /// are not, nor while another takeover covers the list (`canToggleList`, which the command and the band's count ask).
    public func toggleList() {
        if isRunning {
            if isListOpen { closeList() } else { openList() }
            return
        }
        guard canToggleList else { return }
        begin(.all, at: .afterSelection)
        openList()
    }
}

/// A line of the list: a board's head, or a row.
enum IssueListID: Hashable, Sendable {
    case head(BoardID)
    case row(IssueKey)
}

/// The list takeover: the walk's rows grouped by board in a `DetailRowList` (every board folded but the current stop's as it
/// opens; only an unfolded board's rows are built), under it the current stop's Issues tab.
///
/// The list's highlight is the walk's current row, written from outside as the walk steps (so the list scrolls to it); a key
/// or a click landing on a row that is a stop goes to it. A head, or a row that is no stop, takes the highlight for a while
/// (`detour`) and moves nothing; the next step of the walk takes it back.
struct IssueList: View {
    let editor: CanvasEditor
    @State private var handle = DetailListHandle()
    @State private var unfolded: Set<BoardID> = []
    /// Whether `unfolded` is the list's own yet: until `opened`, the current stop's board is the one unfolded, so the first
    /// thing drawn already has the current row in it.
    @State private var started = false
    @State private var detour: IssueListID?
    /// The boards the person unfolded (← →, Return, a click on a head) among `unfolded`: the rest are open because the walk is
    /// in them, and fold as it leaves, so a walk through the file builds the rows of the board it is in and those the person opened.
    @State private var unfoldedByPerson: Set<BoardID> = []
    /// The board the walk was last in.
    @State private var lastBoard: BoardID?

    var body: some View {
        if let walk = editor.issueWalk {
            VStack(spacing: 0) {
                list(walk)
                Divider()
                evidence(walk)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onAppear {
                walk.listShown(true)
                opened(walk)
            }
            .onDisappear { walk.listShown(false) }
            // A step, from the list or outside it: the board it reaches shows its rows.
            .onChange(of: walk.currentRow?.key) { follow(walk) }
            // A step, even to the stop it is at, takes the highlight back from a head or a row that is no stop, and shows its board
            // (one the person folded, the stop being in it).
            .onChange(of: walk.moveRevision) { follow(walk) }
            // The stop's shape landing on another board (Move To ▸, a drop onto a subboard's card) is a change of its row in place,
            // the key the same: the board it lands on shows its rows, and the one it left folds.
            .onChange(of: walk.currentRow?.board) { follow(walk) }
            // A head or a row the highlight was left on may be gone from the list.
            .onChange(of: walk.boards) { dropStaleDetour(walk) }
            // A button of the evidence that selects another shape (Show Rule): the list gives way to what the selection shows.
            .onChange(of: editor.selectedShapeIDs) { leave(walk) }
        }
    }

    /// The boards whose rows are built.
    private func shown(_ walk: IssueWalk) -> Set<BoardID> {
        started ? unfolded : Set(walk.currentRow.map { [$0.board] } ?? [])
    }

    // MARK: The list

    private func list(_ walk: IssueWalk) -> some View {
        let open = shown(walk)
        let (items, rows) = items(of: walk, unfolding: open)
        // Drawn again as the file's colors change and as a commit may have changed a name or a value.
        let stamp = walk.tintRevision &+ walk.textRevision
        return DetailRowList(items, label: IssueWalkStyle.issueList, handle: handle, highlight: highlight(walk),
                             pages: { page(walk, forward: $0) }, maxHeightShare: IssueWalkStyle.listShare) { item in
            switch item.id {
            case .head(let board):
                if let run = walk.boards.first(where: { $0.board == board }) {
                    let isFolded = !open.contains(board)
                    // A rename of the board's owner is a commit that wrote more than moves: `textRevision` draws the head again.
                    let title = editor.withoutObservingDocument { editor.boardHeading(of: board).title }
                    DetailGroupHeader(title, count: run.open, isCollapsed: isFolded, isRow: true) {}
                        .detailRowAccessibility(label: title, value: DetailGroupHeader.spoken(count: run.open, isCollapsed: isFolded), activate: item.activate)
                }
            case .row(let key):
                if let row = rows[key] {
                    IssueRowView(editor: editor, walk: walk, row: row, place: walk.place(ofRow: key), stamp: stamp, activate: item.activate).equatable()
                }
            }
        }
    }

    /// Each board's head, then its rows while it is unfolded: the rows of a folded board are not built.
    private func items(of walk: IssueWalk, unfolding open: Set<BoardID>) -> ([DetailRowItem<IssueListID>], [IssueKey: IssueRow]) {
        var items: [DetailRowItem<IssueListID>] = []
        var rows: [IssueKey: IssueRow] = [:]
        for run in walk.boards {
            let isFolded = !open.contains(run.board)
            items.append(DetailRowItem(id: .head(run.board), kind: .head(isFolded: isFolded)) { toggle(run.board) })
            guard !isFolded else { continue }
            for index in run.rows {
                let row = walk.rows[index]
                // Return and Space close the list on the current stop; a click only moves the walk (the highlight did).
                var item = DetailRowItem(id: IssueListID.row(row.key), parent: .head(run.board)) { [weak walk] in
                    guard let walk else { return }
                    if walk.currentRow?.key != row.key { walk.go(toRow: row.key) }
                    walk.closeListOnStop()
                }
                item.click = {}
                items.append(item)
                rows[row.key] = row
            }
        }
        return (items, rows)
    }

    private func toggle(_ board: BoardID) {
        if unfolded.contains(board) {
            unfolded.remove(board)
            unfoldedByPerson.remove(board)
        } else {
            unfolded.insert(board)
            unfoldedByPerson.insert(board)
        }
    }

    /// The walk's current row, or, after a key or click on a line that moves nothing, that line. A row that is a stop goes to
    /// the walk: the place moves, the stop's shape is selected and its board shown.
    private func highlight(_ walk: IssueWalk) -> Binding<IssueListID?> {
        Binding(
            get: { detour ?? walk.currentRow.map { .row($0.key) } },
            set: { id in
                guard let id else { return }
                guard case .row(let key) = id else {
                    detour = id
                    return
                }
                if walk.currentRow?.key == key, editor.selectedShapeIDs == [key.shape] {
                    detour = nil
                } else if walk.go(toRow: key) {
                    detour = nil
                } else {
                    detour = id
                }
            })
    }

    /// Page Up and Page Down: the first stop of the previous or next board, wrapping. The walk moves there itself (its board may
    /// be folded, so its row is not a line yet); the list follows it.
    private func page(_ walk: IssueWalk, forward: Bool) -> IssueListID? {
        // A line the highlight was left on that is gone from the list pages from the current stop's board.
        let board: BoardID? = liveDetourBoard(walk) ?? walk.currentRow?.board
        if let key = walk.firstStop(besideBoard: board, forward: forward), key != walk.currentRow?.key { walk.go(toRow: key) }
        return nil
    }

    // MARK: Opening and following

    private func opened(_ walk: IssueWalk) {
        unfolded = shown(walk)
        unfoldedByPerson = []
        lastBoard = walk.currentRow?.board
        started = true
        detour = nil
        Self.enter(handle, in: editor, retries: IssueWalkStyle.enterRetries)
    }

    private func leave(_ walk: IssueWalk) {
        guard walk.isListOpen, let shape = walk.currentRow?.shape else { return }
        let selected = editor.selectedShapeIDs
        if !selected.isEmpty, !selected.contains(shape) { walk.closeListOnSelectionMoved() }
    }

    /// The walk went to a stop (or stayed at it): its board shows its rows, and the board it left folds, unless the person
    /// unfolded that one.
    private func follow(_ walk: IssueWalk) {
        if let board = walk.currentRow?.board {
            if let left = lastBoard, left != board, !unfoldedByPerson.contains(left) { unfolded.remove(left) }
            unfolded.insert(board)
            lastBoard = board
        }
        started = true
        detour = nil
    }

    /// The board of the line the highlight was left on, if that line is still in the list: a head whose board has rows, a row of
    /// the walk on a board that shows its rows.
    private func liveDetourBoard(_ walk: IssueWalk) -> BoardID? {
        switch detour {
        case .head(let board)?: walk.boards.contains { $0.board == board } ? board : nil
        case .row(let key)?: walk.row(for: key).flatMap { shown(walk).contains($0.board) ? $0.board : nil }
        case nil: nil
        }
    }

    /// The rows changed: a detour on a line that is gone goes with it, the highlight back on the walk's stop.
    private func dropStaleDetour(_ walk: IssueWalk) {
        if detour != nil, liveDetourBoard(walk) == nil { detour = nil }
    }

    /// The keyboard goes into the list on its highlighted row, once its table is in the window, and the table scrolls to that row
    /// (the list's `enter` does: a list that opens on a stop deep in a board shows it, as nothing else scrolls a list as it appears).
    private static func enter(_ handle: DetailListHandle, in editor: CanvasEditor, retries: Int) {
        guard editor.issueWalk?.isListOpen == true else { return }
        // Rows still on their way (the first answer) wait for no one: the table is there either way.
        if handle.enter() || retries == 0 { return }
        _ = editor.scheduler.schedule(after: IssueWalkStyle.enterRetry) { [weak editor] in
            guard let editor else { return }
            enter(handle, in: editor, retries: retries - 1)
        }
    }

    // MARK: The evidence

    /// The current stop's Issues tab as its panel draws it: its warning line with Ignore and Show Rule, and whatever other
    /// plugins put in the tab (a rule's Rules section, what the model was shown), following each step.
    @ViewBuilder
    private func evidence(_ walk: IssueWalk) -> some View {
        if let shape = walk.currentRow?.shape {
            ScrollView {
                DetailTabView(editor: editor, shape: shape, tab: IssuesTab.self)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            // Each stop's evidence begins at its top, as a shape's own panel does (`ShapePanel` is keyed by its shape).
            .id(shape)
        } else {
            Spacer(minLength: 0)
        }
    }
}

/// What a row of the list says: the walk's name for the shape, what ends it (the first value plugins give the shape, or for a
/// row that is no stop why: "ignored", "holds"), and what VoiceOver hears besides the name: the board and the place ("Texas, 12 of 63").
public struct IssueRowLine: Equatable, Sendable {
    public let name: String
    public let detail: String?
    /// Whether the row is drawn dimmed: it is no stop (ignored, or holds).
    public let isDimmed: Bool
    public let spoken: String
}

extension IssueWalk {
    /// What a row of the list says. The first value is asked of the plugins for this row alone (`IssueRowValues`), as it is
    /// drawn.
    public func line(of row: IssueRow) -> IssueRowLine {
        line(of: row, place: place(ofRow: row.key))
    }

    /// The same for a row whose place the caller has: a row's view is given it by the list, which reads it observed, so the
    /// view reads nothing of the walk's rows and is drawn again only as its stamp says. The reads of the file are unobserved
    /// too (as Neighbors' lines are): a name, a tint and a first value are drawn again as `textRevision` and `tintRevision` tell
    /// it, never on every commit.
    func line(of row: IssueRow, place: IssuePlace?) -> IssueRowLine {
        editor.withoutObservingDocument {
            let detail: String? = switch row.state {
            case .open: editor.shape(inFile: row.shape).flatMap { editor.registry.issueRowValue(of: $0, in: editor) }
            case .ignored: IssueWalkStyle.ignored
            case .holds: IssueWalkStyle.holds
            }
            return IssueRowLine(name: name(of: row.shape), detail: detail, isDimmed: !row.isOpen,
                                spoken: IssueWalkStyle.spoken(board: editor.boardHeading(of: row.board).title, place: place, state: row.state))
        }
    }
}

/// One row: the kind's symbol in the shape's tint, the walk's name for the shape, and at its end its first value, or, for a
/// row that is no stop, why, dimmed. Drawn again only when its stop's place or state, the board it names, or the walk's tint or
/// text revisions change: it reads the file unobserved, so a commit that changes none of those draws no row.
struct IssueRowView: View, Equatable {
    let editor: CanvasEditor
    let walk: IssueWalk
    let row: IssueRow
    let place: IssuePlace?
    /// The walk's tint and text revisions it was drawn for.
    let stamp: Int
    let activate: @MainActor () -> Void

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.row.key == b.row.key && a.row.state == b.row.state && a.row.board == b.row.board && a.place == b.place && a.stamp == b.stamp
    }

    var body: some View {
        let (symbol, tint, line) = editor.withoutObservingDocument {
            let record = editor.shape(inFile: row.shape)
            let label = record.map { editor.registry.label(of: $0.kind) }
            return (label?.systemImage ?? IssueWalkStyle.fallbackSymbol, record.flatMap { editor.tint(of: $0) } ?? label?.tint,
                    walk.line(of: row, place: place))
        }
        DetailShapeRow(symbol: symbol, tint: tint, name: line.name, detail: line.detail, detailTruncation: .tail, dimmed: line.isDimmed)
            .foregroundStyle(.primary)
            .detailRowAccessibility(label: line.name, value: line.spoken, activate: activate)
    }
}

import AppKit
import Canvas
import Selection
import SwiftUI
import TextEditing

// The table of contents' list: AppKit's outline, a source list, whose rows are read from the state as
// the outline asks for them. It makes views only for the rows in view (each row's view, as its kind
// drew it, hosted in a cell the outline reuses), with rows all of one height, so a board of 100,000
// shapes shows, and its rows are replaced, at the cost of the rows in view and a pass over the rows
// listed; a commit costs the rows it changed. A row's nested rows are read only once it's open (a
// subboard's board's rows among them). Its header is the outline's first row, a group row.

/// What the list shows, as the view's body reads it, so SwiftUI hands the list each change: the board,
/// which listing (`ContentsListing.serial`) and how often it changed, the editor's revision (a board
/// open under its owner's row follows its board) and the selection.
struct ContentsShown: Equatable {
    let board: BoardID
    let listing: Int?
    let version: Int
    let revision: Int
    let selection: [ShapeID]
}

/// The outline in SwiftUI: made once, and brought up to date by its controller (`ContentsListController`)
/// each time what it shows changes.
struct ContentsList: NSViewRepresentable {
    let state: ContentsState
    let editor: CanvasEditor
    let onExit: @MainActor () -> Void
    let shown: ContentsShown

    func makeCoordinator() -> ContentsListController { ContentsListController(state: state, editor: editor) }

    func makeNSView(context: Context) -> ContentsListView {
        context.coordinator.onExit = onExit
        context.coordinator.update()
        return context.coordinator.view
    }

    func updateNSView(_ view: ContentsListView, context: Context) {
        context.coordinator.onExit = onExit
        context.coordinator.update()
    }

    static func dismantleNSView(_ view: ContentsListView, coordinator: ContentsListController) {
        coordinator.dismantle()
    }
}

/// A row as the outline holds it: its entry (the shape's row, as listed), where it's from (the board
/// shown's listing, or the outline of a board open under its owner's row) and, while it's open, the
/// rows nested under it as shown. One object for a row for as long as it stays where it is: a row
/// that moves, or comes back, is a new one.
@MainActor
final class ContentsItem {
    let id: ShapeID
    var entry: ContentsEntry
    /// The board whose outline (`ContentsState.outline(of:)`) it's a row of; nil for a row of the
    /// board shown's listing.
    let board: BoardID?
    weak var parent: ContentsItem?
    /// The rows nested under it, front to back, while the outline has them (it's open): the rows of
    /// the board its shape owns first (`boardRows` of them, as of `boardVersion`), then those nested
    /// under it where it is. Nil until the outline asks, and again once it closes.
    var children: [ContentsItem]?
    var boardRows = 0
    var boardVersion = 0
    /// Whether the outline showed it with a disclosure triangle, as of the last time it asked.
    var wasExpandable = false

    init(_ entry: ContentsEntry, board: BoardID?, parent: ContentsItem?) {
        id = entry.id
        self.entry = entry
        self.board = board
        self.parent = parent
    }

    /// Where its shape is in its stack, which orders it among its siblings (front to back).
    var key: StackingKey { entry.row.key }
}

/// The header's row: the outline's first, a group row.
@MainActor
final class ContentsHeaderItem {}

/// The list's controller: the outline's data source and delegate, which reads the state's rows as the
/// outline asks for them, brings the outline up to date as the listing changes (row by row, as the
/// listing's own updates say: `ContentsListingChanges`), and carries the selection, the keys, the
/// hover, the disclosure and the drags between them.
@MainActor
final class ContentsListController: NSObject {
    let state: ContentsState
    let editor: CanvasEditor
    var onExit: @MainActor () -> Void = {}
    let view = ContentsListView()
    var outline: ContentsTable { view.outline }

    private let header = ContentsHeaderItem()
    private lazy var headerCell = ContentsHeaderCell(state: state, editor: editor)
    /// The top-level rows, front to back.
    private var top: [ContentsItem] = []
    /// Each row the outline has, by shape (one object a shape at most).
    private var items: [ShapeID: ContentsItem] = [:]
    /// The rows it has whose shapes own boards: their triangles follow those boards, and their
    /// boards' rows too, while they're open.
    private var owners: Set<ShapeID> = []
    /// The listing shown (`ContentsListing.serial`), and the editor's selection as shown.
    private var shownListing: Int?
    private var shownSelection: [ShapeID]?
    /// The selection the list made last, as of `editor.selectionRevision`: its rows show already, so
    /// showing it opens and scrolls to nothing.
    private var listSelection: Int?
    /// A key reached the outline this turn: what it selects meanwhile is the key's (↑ ↓, Tab and ⇧Tab,
    /// ⇧ with them), and the list keeps the keyboard; what it selects otherwise is a click's.
    private var keyArrived = false
    /// The state's `boardsMayHaveChanged` as the boards open under rows were last followed: a drag's
    /// every event leaves it, and costs them nothing.
    private var followedBoards: Int?
    /// While the list changes the outline itself (its rows, their selection, their disclosure), what
    /// the outline tells its delegate is the list's own doing, not the person's.
    private var updating = 0
    /// The row the pointer is on, whose shape it hovers (`ContentsState.hover`).
    private var pointerRow: ShapeID?
    /// The rows an update made again where they are, redrawn as it ends where they're in view.
    private var remade: Set<ShapeID> = []

    init(state: ContentsState, editor: CanvasEditor) {
        self.state = state
        self.editor = editor
        super.init()
        outline.list = self
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(rowClicked(_:))
        outline.doubleAction = #selector(openClicked(_:))
        view.onHide = { [weak self] in self?.reclaimSoon() }
        state.watchTurns(self)
        state.keyboardEntry = outline
    }

    // MARK: Keeping up

    /// Brings the outline up to date with the state: the listing shown whole if it's another (another
    /// board, another scope, a listing made afresh), else row by row as its updates changed it; the
    /// rows of boards open under their owners' rows, as their boards changed; then the selection.
    func update() {
        _ = state.entries
        updating += 1
        defer { updating -= 1 }
        if state.listedSerial != shownListing {
            reload()
        } else if let changes = state.takeListedChanges(by: self) {
            if !changes.isEmpty { follow(changes) }
        } else {
            reload()
        }
        if followedBoards != state.boardsMayHaveChanged {
            followedBoards = state.boardsMayHaveChanged
            followBoards()
        }
        redrawRemade()
        showSelection()
    }

    /// Shows the listing whole: its top-level rows, and under each row that's open (`isExpanded`)
    /// its rows, read as they open. What it costs is a pass over the top-level rows and the rows in
    /// view, whatever's listed.
    private func reload() {
        let entries = state.entries
        shownListing = state.listedSerial
        followedBoards = state.boardsMayHaveChanged
        _ = state.takeListedChanges(by: self)
        items.removeAll(keepingCapacity: true)
        owners.removeAll()
        top = entries.reversed().map { make($0, board: nil, parent: nil) }
        outline.reloadData()
        for item in top where isExpandable(item) && state.isExpanded(item.entry) {
            outline.expandItem(item)
        }
        if let pointed = pointerRow, items[pointed] == nil { endPointing() }
        shownSelection = nil
        // Rows of another listing (another board, the selection a row of it went to there): brought into view.
        listSelection = nil
    }

    /// Follows the listing's updates row by row: the rows that left their place out of it, the rows
    /// that came or moved in where they are now (open as they were), the triangles of rows whose
    /// nested rows changed, and the rows made again where they are redrawn.
    private func follow(_ changes: ContentsListingChanges) {
        for id in changes.moved {
            if let item = items[id] { remove(item) }
        }
        var arrived: [ContentsItem] = []
        var parents = changes.parents
        for id in changes.moved {
            let place = state.listedPlace(of: id)
            guard place.isListed, items[id] == nil, let entry = state.listedEntry(id) else { continue }
            guard let parentID = place.parent else {
                let slot = Self.slot(for: entry.row.key, in: top, from: 0)
                let item = make(entry, board: nil, parent: nil)
                top.insert(item, at: slot)
                outline.insertItems(at: [slot + 1], inParent: nil, withAnimation: [])
                arrived.append(item)
                continue
            }
            // Under a row the outline doesn't have, it's read as that row opens.
            guard let parent = items[parentID] else { continue }
            guard var level = parent.children, outline.isItemExpanded(parent), isShown(parent) else {
                parents.insert(parentID)
                continue
            }
            let slot = Self.slot(for: entry.row.key, in: level, from: parent.boardRows)
            let item = make(entry, board: nil, parent: parent)
            level.insert(item, at: slot)
            parent.children = level
            outline.insertItems(at: [slot], inParent: parent, withAnimation: [])
            arrived.append(item)
        }
        for id in parents {
            guard let item = items[id], item.board == nil, isShown(item), let entry = state.listedEntry(id) else { continue }
            item.entry = entry
            let expandable = isExpandable(item)
            if expandable != item.wasExpandable {
                if !expandable { forgetChildren(of: item) }
                reloadTriangle(of: item)
            }
            if expandable, !outline.isItemExpanded(item), state.isExpanded(entry) { outline.expandItem(item) }
        }
        for id in changes.replaced {
            guard let item = items[id], item.board == nil, let row = state.listedRow(id), row !== item.entry.row else { continue }
            item.entry.row = row
            remade.insert(id)
        }
        for item in arrived where items[item.id] === item && isExpandable(item) && state.isExpanded(item.entry) {
            outline.expandItem(item)
        }
        if !changes.moved.isEmpty { shownSelection = nil }
    }

    /// The rows of each board open under its owner's row follow that board as it changes, though
    /// it isn't shown (what another board's commit, or a sync, writes there), and its owner's
    /// triangle shows while the board has shapes.
    private func followBoards() {
        for id in Array(owners) {
            guard let item = items[id], isShown(item) else { continue }
            let expandable = isExpandable(item)
            if expandable != item.wasExpandable {
                if !expandable { forgetChildren(of: item) }
                reloadTriangle(of: item)
                if expandable, !outline.isItemExpanded(item), state.isExpanded(item.entry) { outline.expandItem(item) }
                continue
            }
            guard item.children != nil, outline.isItemExpanded(item) else { continue }
            resyncBoard(of: item)
        }
    }

    /// Brings the rows of the board an open row opens onto up to the board's outline, by shape: those
    /// gone out, those come in, those made again redrawn, and the open ones' own rows likewise.
    private func resyncBoard(of item: ContentsItem) {
        guard let board = item.entry.nestedBoard else { return }
        let rows = state.boardToOpen(under: item.entry) == nil ? ([], item.boardVersion) : state.outlineRows(of: board)
        guard rows.1 != item.boardVersion || rows.0.isEmpty != (item.boardRows == 0) else { return }
        item.boardVersion = rows.1
        item.boardRows = resync(item, rows: 0..<item.boardRows, to: rows.0.reversed(), board: board)
        shownSelection = nil
    }

    /// Brings `range` of an open row's rows up to `fresh` (front to back), by shape: the rows gone
    /// out, the rows come in (open as they were), and each that stayed holding its row as it is now,
    /// redrawn if that's another, its own open rows brought up to date too (a board's rows are made
    /// again as it changes). How many rows the range has now.
    private func resync(_ parent: ContentsItem, rows range: Range<Int>, to fresh: [ContentsEntry], board: BoardID?) -> Int {
        guard var level = parent.children else { return fresh.count }
        let old = level[range]
        let difference = fresh.map(\.id).difference(from: old.map(\.id))
        for change in difference.removals.reversed() {
            guard case .remove(let offset, _, _) = change else { continue }
            let item = level.remove(at: range.lowerBound + offset)
            parent.children = level
            outline.removeItems(at: [range.lowerBound + offset], inParent: parent, withAnimation: [])
            forget(item)
        }
        var arrived: [ContentsItem] = []
        for change in difference.insertions {
            guard case .insert(let offset, _, _) = change else { continue }
            let item = make(fresh[offset], board: board, parent: parent)
            level.insert(item, at: range.lowerBound + offset)
            parent.children = level
            outline.insertItems(at: [range.lowerBound + offset], inParent: parent, withAnimation: [])
            arrived.append(item)
        }
        for (offset, entry) in fresh.enumerated() {
            let item = level[range.lowerBound + offset]
            if item.entry.row !== entry.row { remade.insert(item.id) }
            item.entry = entry
            guard let rows = item.children, outline.isItemExpanded(item) else {
                if isExpandable(item) != item.wasExpandable { reloadTriangle(of: item) }
                continue
            }
            if item.entry.nestedBoard != nil { resyncBoard(of: item) }
            let start = item.boardRows
            _ = resync(item, rows: start..<max(start, item.children?.count ?? rows.count), to: (entry.children ?? []).reversed(), board: item.board)
        }
        for item in arrived where isExpandable(item) && state.isExpanded(item.entry) { outline.expandItem(item) }
        return fresh.count
    }

    // MARK: Rows

    /// A row the outline will have, under `parent` (nil at the top).
    private func make(_ entry: ContentsEntry, board: BoardID?, parent: ContentsItem?) -> ContentsItem {
        let item = ContentsItem(entry, board: board, parent: parent)
        items[entry.id] = item
        if entry.nestedBoard != nil { owners.insert(entry.id) }
        return item
    }

    /// Takes a row out of the outline, where it shows, and forgets it and the rows under it.
    private func remove(_ item: ContentsItem) {
        defer { forget(item) }
        guard items[item.id] === item else { return }
        guard let parent = item.parent else {
            guard let index = Self.index(of: item, in: top, among: 0..<top.count) else { return }
            top.remove(at: index)
            outline.removeItems(at: [index + 1], inParent: nil, withAnimation: [])
            return
        }
        guard var level = parent.children else { return }
        // Rows read for a row the outline shows closed are read again as it opens.
        guard isShown(parent), outline.isItemExpanded(parent) else { return forgetChildren(of: parent) }
        // A row of the board its parent owns is among the first of its rows; any other after them.
        let ofBoard = item.board != nil && item.board == parent.entry.nestedBoard
        let among = ofBoard ? 0..<parent.boardRows : parent.boardRows..<level.count
        guard let index = Self.index(of: item, in: level, among: among) else { return }
        level.remove(at: index)
        if index < parent.boardRows { parent.boardRows -= 1 }
        parent.children = level
        outline.removeItems(at: [index], inParent: parent, withAnimation: [])
    }

    /// Forgets a row the outline no longer has, and the rows under it; a hover its pointer set goes
    /// with it.
    private func forget(_ item: ContentsItem) {
        if items[item.id] === item {
            items[item.id] = nil
            owners.remove(item.id)
            if pointerRow == item.id { endPointing() }
        }
        forgetChildren(of: item)
    }

    private func forgetChildren(of item: ContentsItem) {
        item.children?.forEach(forget)
        item.children = nil
        item.boardRows = 0
    }

    /// The rows nested under a row, front to back, read the first time the outline asks (it asks
    /// only once the row is open): the rows of the board it owns, then those nested under it.
    func children(of item: ContentsItem) -> [ContentsItem] {
        if let children = item.children { return children }
        var rows: [ContentsItem] = []
        item.boardRows = 0
        if let board = state.boardToOpen(under: item.entry) {
            let outlined = state.outlineRows(of: board)
            rows = outlined.entries.reversed().map { make($0, board: board, parent: item) }
            item.boardRows = rows.count
            item.boardVersion = outlined.version
        }
        let nested = item.board == nil ? state.listedChildren(of: item.id) : (item.entry.children ?? [])
        rows += nested.reversed().map { make($0, board: item.board, parent: item) }
        item.children = rows
        return rows
    }

    /// Whether a row has rows nested under it: some of its own, or a board with shapes.
    func isExpandable(_ item: ContentsItem) -> Bool {
        item.entry.children != nil || state.boardToOpen(under: item.entry) != nil
    }

    /// Whether the outline shows the row's level: every row it's under open.
    private func isShown(_ item: ContentsItem) -> Bool {
        guard items[item.id] === item else { return false }
        var parent = item.parent
        while let above = parent {
            guard above.children != nil, outline.isItemExpanded(above) else { return false }
            parent = above.parent
        }
        return true
    }

    /// Where a row is among its siblings `among` (front to back: by its key, else by itself).
    private static func index(of item: ContentsItem, in level: [ContentsItem], among: Range<Int>) -> Int? {
        let slot = slot(for: item.key, in: level, among: among)
        if slot < among.upperBound, level[slot] === item { return slot }
        return level[among].firstIndex { $0 === item }
    }

    /// Where a row with `key` goes among siblings `among` (front to back): after every row in front of it.
    private static func slot(for key: StackingKey, in level: [ContentsItem], among: Range<Int>) -> Int {
        var low = among.lowerBound, high = among.upperBound
        while low < high {
            let middle = (low + high) / 2
            if level[middle].key > key { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// Where a row with `key` goes among a level's rows from `start` to its end.
    private static func slot(for key: StackingKey, in level: [ContentsItem], from start: Int) -> Int {
        slot(for: key, in: level, among: start..<level.count)
    }

    /// A row whose disclosure triangle comes or goes (its first nested row came, its last went): the
    /// outline asks again whether it has one (and, where it has the row open, what's under it), and
    /// the row is redrawn with it.
    private func reloadTriangle(of item: ContentsItem) {
        outline.reloadItem(item, reloadChildren: outline.isItemExpanded(item))
        #if DEBUG
        let row = outline.row(forItem: item)
        if row >= 0, outline.rowView(atRow: row, makeIfNecessary: false) != nil { state.rowsRedrawn += 1 }
        #endif
    }

    /// Shows the rows an update made again as they are now, where the outline has views of them (in
    /// view, or about to be); a row out of view is drawn as it is once it comes into view.
    private func redrawRemade() {
        guard !remade.isEmpty else { return }
        let rows = remade
        remade = []
        let size = outline.effectiveRowSizeStyle
        outline.enumerateAvailableRowViews { rowView, row in
            guard let item = self.outline.item(atRow: row) as? ContentsItem, rows.contains(item.id),
                  let cell = rowView.view(atColumn: 0) as? ContentsCell else { return }
            cell.show(item.entry, size: size)
            (rowView as? ContentsTableRow)?.show(item)
            #if DEBUG
            self.state.rowsRedrawn += 1
            #endif
        }
    }

    // MARK: The selection

    /// Shows the editor's selection as the outline's: the rows of the shapes selected that show. A
    /// selection the list didn't make (on the canvas, Jump To, Find, an undo) is brought into view too:
    /// the first selected row scrolled to, and for one shape the rows its row is nested under opened
    /// first (an arrow's under the note it starts from), as the person would open them. Several
    /// selected open nothing: ⌘A would open every row.
    private func showSelection() {
        let selected = editor.selectedShapeIDs
        guard selected != shownSelection else { return }
        shownSelection = selected
        let fromList = listSelection == editor.selectionRevision
        var rows = IndexSet()
        if !fromList, selected.count == 1 { openRows(above: selected[0]) }
        if selected.count <= ContentsStyle.selectedRowLookups {
            for id in selected {
                guard let item = items[id], isShown(item) else { continue }
                let row = outline.row(forItem: item)
                if row > 0 { rows.insert(row) }
            }
        } else {
            // Many: one pass over the rows shown.
            let wanted = Set(selected)
            for row in 1..<max(1, outline.numberOfRows) {
                if let item = outline.item(atRow: row) as? ContentsItem, wanted.contains(item.id) { rows.insert(row) }
            }
        }
        if rows != outline.selectedRowIndexes { outline.selectRowIndexes(rows, byExtendingSelection: false) }
        if !fromList, let first = rows.first { outline.scrollRowToVisible(first) }
    }

    /// Opens the rows the shape's row is nested under, the outermost first, each kept open as the
    /// person would leave it (`setExpanded`), so the row shows.
    private func openRows(above id: ShapeID) {
        var above: [ShapeID] = [], next = state.listedPlace(of: id)
        guard next.isListed else { return }
        while let parent = next.parent, !above.contains(parent) {
            above.append(parent)
            next = state.listedPlace(of: parent)
        }
        for parent in above.reversed() {
            guard let item = items[parent], isShown(item), isExpandable(item) else { return }
            guard !outline.isItemExpanded(item) else { continue }
            state.setExpanded(item.entry, true)
            outline.expandItem(item)
        }
    }

    /// The person changed the outline's selection (a click, ⌘- and ⇧-clicks, a key): their shapes
    /// selected (`ContentsState.select`). A click's pick gives the canvas the keyboard, so its keys act
    /// on the shapes picked at once, a nudge or Delete; a key's keeps it in the list, for the next key to
    /// walk on (the list has it by View ▸ Focus Sidebar).
    private func selectionChanged() {
        var ids: Set<ShapeID> = []
        for row in outline.selectedRowIndexes {
            if let item = outline.item(atRow: row) as? ContentsItem { ids.insert(item.id) }
        }
        state.select(ids)
        listSelection = editor.selectionRevision
        if !keyArrived { giveCanvasTheKeyboardSoon() }
    }

    /// A click on a row, once it's let go (the outline's action; not a press that dragged, nor the
    /// header's row): one on a row already selected, which changes no selection, gives the canvas the
    /// keyboard as one that picks does. The second click of a double-click opens the shape
    /// (`openClicked`).
    @objc private func rowClicked(_ sender: Any?) {
        guard outline.clickedRow > 0 else { return }
        giveCanvasTheKeyboardSoon()
    }

    /// The canvas gets the keyboard a turn on, once the click is done with, if the list still has it.
    private func giveCanvasTheKeyboardSoon() {
        _ = editor.scheduler.schedule(after: .zero) { [weak self] in
            guard let self, let window = outline.window, window.firstResponder === outline else { return }
            onExit()
        }
    }

    // MARK: Opening

    /// A double-click on a row: its shape opened (`ContentsState.open`).
    @objc private func openClicked(_ sender: Any?) {
        let row = outline.clickedRow
        guard row > 0, let item = outline.item(atRow: row) as? ContentsItem else { return }
        state.open([item.id])
    }

    /// The selected rows' shapes, for Return: the one opened, as Return on the canvas opens it.
    var selectedShapes: Set<ShapeID> {
        Set(outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? ContentsItem)?.id })
    }

    // MARK: The keyboard

    /// The keyboard back to the canvas: Escape, ⌘↑, ⌘↩, ⌘.
    func exit() { onExit() }

    /// After AppKit has hidden the list: if the keyboard fell to the window, hand it to the canvas.
    private func reclaimSoon() {
        _ = editor.scheduler.schedule(after: .zero) { [weak window = view.window, onExit] in
            if let window, window.firstResponder === window { onExit() }
        }
    }

    /// A key the outline heard, before it handles it: what it is to the list. What the outline selects
    /// for it, before the next turn, is the key's.
    func key(_ event: NSEvent) -> ContentsKey {
        if !keyArrived {
            keyArrived = true
            _ = editor.scheduler.schedule(after: .zero) { [weak self] in self?.keyArrived = false }
        }
        let held = KeyMeaning.Modifiers(event.modifierFlags)
        let characters = event.charactersIgnoringModifiers ?? ""
        // ⌥Tab and ⌥⇧Tab go into a thing's drawn parts, which a row has none of (keyboard navigation's
        // P6: same key, same meaning).
        if characters == "\t" || characters == ContentsStyle.backTab, held.contains(.option) { return .handled }
        guard let reading = KeyMeaning.Reading(event: event) else { return .table }
        switch reading.meaning {
        // ⌘↑ is out to the list's container, the canvas, and ⌘↩ finishes, as Escape gives the canvas
        // the keyboard (Go › Enclosing Board takes ⌘↑ first on a board inside another).
        case .up where held == .command, .finish, .back:
            exit()
            return .handled
        // Tab and ⇧Tab step the rows as ↓ and ↑ do (Caps Lock or not), and stay in the list.
        case .next, .previous:
            return .step(up: reading.meaning == .previous || held.contains(.shift))
        case .activate:
            state.open(selectedShapes)
            return .handled
        case .delete where held.subtracting(.shift).isEmpty:
            editor.perform(.delete)
            return .handled
        default:
            return .table
        }
    }

    // MARK: Hover

    /// The pointer moved over the outline: the shape of the row it's on hovered, and the last one's
    /// let go of.
    func pointerMoved(to point: CGPoint) {
        let row = outline.row(at: point)
        let id = row > 0 ? (outline.item(atRow: row) as? ContentsItem)?.id : nil
        guard id != pointerRow else { return }
        if let old = pointerRow { state.endHover(old) }
        pointerRow = id
        if let id { state.hover(id) }
    }

    /// The pointer left the outline, or its row went: the hover it set let go of.
    func endPointing() {
        guard let old = pointerRow else { return }
        pointerRow = nil
        state.endHover(old)
    }

    // MARK: Dragging

    /// The row a drag is over, and how far down it (0 its top, 1 its bottom).
    private func rowUnder(_ info: any NSDraggingInfo) -> (item: ContentsItem, fraction: CGFloat)? {
        let point = outline.convert(info.draggingLocation, from: nil)
        let row = outline.row(at: point)
        guard row > 0, let item = outline.item(atRow: row) as? ContentsItem else { return nil }
        let rect = outline.rect(ofRow: row)
        guard rect.height > 0 else { return nil }
        let fraction = outline.isFlipped ? (point.y - rect.minY) / rect.height : (rect.maxY - point.y) / rect.height
        return (item, min(max(fraction, 0), 1))
    }

    /// A drag left the outline, or ended: nothing pointed at.
    func dragLeft() { state.point(nil) }

    /// Lets go of what the list holds of the editor as it goes: the pointer's hover.
    func dismantle() {
        endPointing()
    }
}

/// What a key is to the list: handled by it, a step through the rows (Tab and ⇧Tab, as ↓ and ↑), or
/// the outline's own (↑ ↓ → ← and the rest).
enum ContentsKey {
    case handled
    case step(up: Bool)
    case table
}

extension ContentsListController: ContentsTurnWatcher {
    /// A row turned other than in the outline (spring-loading, a headless turn): the outline opens or
    /// closes it, where it shows.
    func rowTurned(_ id: ShapeID) {
        guard updating == 0, let item = items[id], isShown(item) else { return }
        let open = state.isExpanded(item.entry) && isExpandable(item)
        guard open != outline.isItemExpanded(item) else { return }
        updating += 1
        defer { updating -= 1 }
        if open { outline.expandItem(item) } else { outline.collapseItem(item) }
    }
}

extension ContentsListController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item else { return top.count + 1 }
        guard let item = item as? ContentsItem else { return 0 }
        return children(of: item).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item else { return index == 0 ? header : top[index - 1] }
        guard let item = item as? ContentsItem else { return header }
        return children(of: item)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let item = item as? ContentsItem else { return false }
        item.wasExpandable = isExpandable(item)
        return item.wasExpandable
    }

    // MARK: Dragging rows

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let item = item as? ContentsItem else { return nil }
        return state.pasteboardWriter(from: item.id)
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        // On the outline as a whole: where it points is the list's to say (`target(onRow:at:)`), and so
        // is what shows it, the line and the ring, and what springs open.
        outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
        guard state.dragShapes != nil, let (row, fraction) = rowUnder(info) else {
            state.point(nil)
            return []
        }
        return state.dragMoved(over: row.entry, at: fraction) == nil ? [] : .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let (row, fraction) = rowUnder(info) else {
            state.point(nil)
            return false
        }
        return state.drop(onRow: row.entry, at: fraction)
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint,
                     operation: NSDragOperation) {
        state.point(nil)
    }
}

extension ContentsListController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { item is ContentsHeaderItem }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { item is ContentsItem }

    func outlineView(_ outlineView: NSOutlineView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        proposed.contains(0) ? proposed.subtracting([0]) : proposed
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if item is ContentsHeaderItem { return headerCell }
        guard let item = item as? ContentsItem else { return nil }
        let cell = outlineView.makeView(withIdentifier: ContentsCell.identifier, owner: nil) as? ContentsCell ?? ContentsCell()
        cell.show(item.entry, size: outlineView.effectiveRowSizeStyle)
        #if DEBUG
        state.rowsRedrawn += 1
        #endif
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        guard let item = item as? ContentsItem else { return nil }
        let row = outlineView.makeView(withIdentifier: ContentsTableRow.identifier, owner: nil) as? ContentsTableRow ?? ContentsTableRow()
        row.list = self
        row.show(item)
        return row
    }

    func outlineView(_ outlineView: NSOutlineView, didAdd rowView: NSTableRowView, forRow row: Int) {
        (rowView as? ContentsTableRow)?.nameTriangle()
    }

    func outlineView(_ outlineView: NSOutlineView, didRemove rowView: NSTableRowView, forRow row: Int) {
        (rowView as? ContentsTableRow)?.show(nil)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard updating == 0 else { return }
        selectionChanged()
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as? ContentsItem else { return }
        if updating == 0 { state.setExpanded(item.entry, true) }
        // The rows under it that are open, open: what the person left them as, a container's from the start.
        updating += 1
        defer { updating -= 1 }
        for child in children(of: item) where isExpandable(child) && state.isExpanded(child.entry) && !outline.isItemExpanded(child) {
            outline.expandItem(child)
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as? ContentsItem else { return }
        if updating == 0 { state.setExpanded(item.entry, false) }
        // Read again as it opens, as they are then.
        forgetChildren(of: item)
    }
}

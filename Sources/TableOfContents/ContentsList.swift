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
// subboard's board's rows among them). Its header is the outline's first row, a group row. The rows of
// a kind that gathers them in a section (`ContentsSections`) are under the section's row, after their
// level's other rows: read with their level, shown once the section is open.

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
    /// The section's row it's under, its kind's rows gathered there at its level (`ContentsSections`);
    /// nil for a row of the level's own.
    weak var section: ContentsSectionItem?
    /// The rows nested under it, front to back, while the outline has them (it's open): the rows of
    /// the board its shape owns first (`boardRows` of them, as of `boardVersion`), then those nested
    /// under it where it is. Nil until the outline asks, and again once it closes.
    var children: [ContentsItem]?
    var boardRows = 0
    var boardVersion = 0
    /// The sections of the rows nested under it, after `children`, read and forgotten with them.
    var sections: [ContentsSectionItem] = []
    /// Whether the outline showed it with a disclosure triangle, as of the last time it asked.
    var wasExpandable = false

    init(_ entry: ContentsEntry, board: BoardID?, parent: ContentsItem?, section: ContentsSectionItem?) {
        id = entry.id
        self.entry = entry
        self.board = board
        self.parent = parent
        self.section = section
    }

    /// Where its shape is in its stack, which orders it among its siblings (front to back).
    var key: StackingKey { entry.row.key }
}

/// A section's row (`ContentsSections`): its kinds' rows at one level, gathered under it after the
/// level's other rows, read with the level whether it's open or not, so it says how many it holds.
/// One object for as long as the level has rows of the section.
@MainActor
final class ContentsSectionItem {
    let key: ContentsSectionKey
    /// The row whose nested rows it's among; nil at the top.
    weak var parent: ContentsItem?
    /// Its rows, front to back: those of the board its parent's shape owns first (`boardRows` of
    /// them), then those nested under the parent where it is.
    var rows: [ContentsItem] = []
    var boardRows = 0

    init(_ key: ContentsSectionKey, parent: ContentsItem?) {
        self.key = key
        self.parent = parent
    }
}

#if DEBUG
/// What a test reads of the outline's rows (`String(describing: outline.item(atRow:))`), which are
/// internal: a row's name (`ContentsEntry.spokenName`), a section's row its title and count.
extension ContentsItem: CustomStringConvertible {
    nonisolated var description: String { MainActor.assumeIsolated { entry.spokenName } }
}

extension ContentsSectionItem: CustomStringConvertible {
    nonisolated var description: String {
        MainActor.assumeIsolated { "\(key.section.title) · \(ContentsStyle.sectionCount(rows.count))" }
    }
}
#endif

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
    /// The top-level rows, front to back, and the top level's sections, after them.
    private var top: [ContentsItem] = []
    private var topSections: [ContentsSectionItem] = []
    /// Each row the outline has, by shape (one object a shape at most), and each section's row, by
    /// its key.
    private var items: [ShapeID: ContentsItem] = [:]
    private var sectionItems: [ContentsSectionKey: ContentsSectionItem] = [:]
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
    /// The rows an update made again where they are, and the sections whose count it changed, redrawn
    /// as it ends where they're in view.
    private var remade: Set<ShapeID> = []
    private var recounted: Set<ContentsSectionKey> = []

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

    /// Shows the listing whole: its top-level rows and sections, and under each row or section that's
    /// open (`isExpanded`) its rows, read as they open. What it costs is a pass over the top-level rows
    /// and the rows in view, whatever's listed.
    private func reload() {
        let entries = state.entries
        shownListing = state.listedSerial
        followedBoards = state.boardsMayHaveChanged
        _ = state.takeListedChanges(by: self)
        items.removeAll(keepingCapacity: true)
        sectionItems.removeAll()
        owners.removeAll()
        let level = state.gathered(entries)
        top = level.rows.map { make($0, board: nil, parent: nil, section: nil) }
        topSections = level.sections.map { makeSection($0, under: nil) }
        outline.reloadData()
        for item in top where isExpandable(item) && state.isExpanded(item.entry) {
            outline.expandItem(item)
        }
        for section in topSections where state.isExpanded(section.key) {
            outline.expandItem(section)
        }
        if let pointed = pointerRow, items[pointed] == nil { endPointing() }
        shownSelection = nil
        // Rows of another listing (another board, the selection a row of it went to there): brought into view.
        listSelection = nil
    }

    /// Follows the listing's updates row by row: the rows that left their place out of it, the rows
    /// that came or moved in where they are now (open as they were; a section's row coming in with
    /// its first and going with its last), the triangles of rows whose nested rows changed, and the
    /// rows made again where they are redrawn.
    private func follow(_ changes: ContentsListingChanges) {
        for id in changes.moved {
            if let item = items[id] { remove(item) }
        }
        var arrived: [ContentsItem] = []
        var arrivedSections: [ContentsSectionItem] = []
        var parents = changes.parents
        for id in changes.moved {
            let place = state.listedPlace(of: id)
            guard place.isListed, items[id] == nil, let entry = state.listedEntry(id) else { continue }
            var parent: ContentsItem?
            if let parentID = place.parent {
                // Under a row the outline doesn't have, it's read as that row opens.
                guard let found = items[parentID] else { continue }
                guard found.children != nil, outline.isItemExpanded(found), isShown(found) else {
                    parents.insert(parentID)
                    continue
                }
                parent = found
            }
            let (item, section) = insert(entry, under: parent)
            arrived.append(item)
            if let section { arrivedSections.append(section) }
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
        for item in arrived where items[item.id] === item && isShown(item) && isExpandable(item) && state.isExpanded(item.entry) {
            outline.expandItem(item)
        }
        for section in arrivedSections where sectionItems[section.key] === section && state.isExpanded(section.key) {
            outline.expandItem(section)
        }
        if !changes.moved.isEmpty { shownSelection = nil }
    }

    /// Puts a row the listing brought in where the outline shows it, at `parent`'s level (nil: the
    /// top): among the level's own rows, or among its section's, whose row comes in with its first.
    /// The row, and the section's row when it came in with it.
    private func insert(_ entry: ContentsEntry, under parent: ContentsItem?) -> (ContentsItem, ContentsSectionItem?) {
        guard let gathered = entry.section else {
            let item = make(entry, board: nil, parent: parent, section: nil)
            guard let parent else {
                let slot = Self.slot(for: item.key, in: top, from: 0)
                top.insert(item, at: slot)
                outline.insertItems(at: [slot + 1], inParent: nil, withAnimation: [])
                return (item, nil)
            }
            var level = parent.children ?? []
            let slot = Self.slot(for: item.key, in: level, from: parent.boardRows)
            level.insert(item, at: slot)
            parent.children = level
            outline.insertItems(at: [slot], inParent: parent, withAnimation: [])
            return (item, nil)
        }
        let key = sectionKey(gathered, under: parent)
        if let section = sectionItems[key] {
            let item = make(entry, board: nil, parent: parent, section: section)
            let slot = Self.slot(for: item.key, in: section.rows, from: section.boardRows)
            section.rows.insert(item, at: slot)
            if outline.isItemExpanded(section) { outline.insertItems(at: [slot], inParent: section, withAnimation: []) }
            recounted.insert(key)
            return (item, nil)
        }
        let section = ContentsSectionItem(key, parent: parent)
        section.rows = [make(entry, board: nil, parent: parent, section: section)]
        add(section)
        return (section.rows[0], section)
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
    /// gone out, those come in, those made again redrawn, and the open ones' own rows likewise; those
    /// of its sections too.
    private func resyncBoard(of item: ContentsItem) {
        guard let board = item.entry.nestedBoard else { return }
        let rows = state.boardToOpen(under: item.entry) == nil ? ([], item.boardVersion) : state.outlineRows(of: board)
        let hadRows = item.boardRows > 0 || item.sections.contains { $0.boardRows > 0 }
        guard rows.1 != item.boardVersion || rows.0.isEmpty == hadRows else { return }
        item.boardVersion = rows.1
        let fresh = state.gathered(rows.0)
        item.boardRows = resync(.rows(item), range: 0..<item.boardRows, to: fresh.rows, board: board)
        resyncSections(of: item, ofBoard: true, to: fresh.sections, board: board)
        shownSelection = nil
    }

    /// Brings the rows nested under an open row where it is (after those of the board it owns) up to
    /// `fresh` (as listed, back to front), its sections' among them.
    private func resyncNested(of item: ContentsItem, to fresh: [ContentsEntry]) {
        let gathered = state.gathered(fresh)
        let start = item.boardRows
        _ = resync(.rows(item), range: start..<max(start, item.children?.count ?? start), to: gathered.rows, board: item.board)
        resyncSections(of: item, ofBoard: false, to: gathered.sections, board: item.board)
    }

    /// Brings the rows of an open row's sections that are of the board its shape owns (`ofBoard`), or
    /// else those nested under it where it is, up to `fresh`: a section's row comes in with its first
    /// row and goes with its last.
    private func resyncSections(of item: ContentsItem, ofBoard: Bool, to fresh: [ContentsGathering.Section], board: BoardID?) {
        for section in item.sections {
            let rows = fresh.first { $0.section == section.key.section }?.rows ?? []
            let count = resync(.section(section), range: ofBoard ? 0..<section.boardRows : section.boardRows..<section.rows.count, to: rows, board: board)
            if ofBoard { section.boardRows = count }
        }
        for section in item.sections where section.rows.isEmpty { removeSection(section) }
        for gathered in fresh where !item.sections.contains(where: { $0.key.section == gathered.section }) {
            let section = makeSection(gathered, under: item, fromBoard: ofBoard ? gathered.rows.count : 0, ownBoard: board)
            add(section)
            if state.isExpanded(section.key) { outline.expandItem(section) }
        }
    }

    /// Where a level keeps rows: an open row's own (`children`), or a section's.
    private enum Lane {
        case rows(ContentsItem)
        case section(ContentsSectionItem)
    }

    /// Brings `range` of a lane's rows up to `fresh` (front to back), by shape: the rows gone out, the
    /// rows come in (open as they were), and each that stayed holding its row as it is now, redrawn if
    /// that's another, its own open rows brought up to date too (a board's rows are made again as it
    /// changes). The outline is told only where it shows the lane's rows (a closed section's are read
    /// as it opens, and its count redrawn). How many rows the range has now.
    private func resync(_ lane: Lane, range: Range<Int>, to fresh: [ContentsEntry], board: BoardID?) -> Int {
        var level: [ContentsItem]
        let parent: ContentsItem?, section: ContentsSectionItem?, holder: Any, shows: Bool
        switch lane {
        case .rows(let item):
            guard let children = item.children else { return fresh.count }
            level = children
            parent = item
            section = nil
            holder = item
            shows = true
        case .section(let gathered):
            level = gathered.rows
            parent = gathered.parent
            section = gathered
            holder = gathered
            shows = outline.isItemExpanded(gathered)
        }
        func store() {
            if let section { section.rows = level } else { parent?.children = level }
        }
        let old = level[range]
        let difference = fresh.map(\.id).difference(from: old.map(\.id))
        for change in difference.removals.reversed() {
            guard case .remove(let offset, _, _) = change else { continue }
            let item = level.remove(at: range.lowerBound + offset)
            store()
            if shows { outline.removeItems(at: [range.lowerBound + offset], inParent: holder, withAnimation: []) }
            forget(item)
        }
        var arrived: [ContentsItem] = []
        for change in difference.insertions {
            guard case .insert(let offset, _, _) = change else { continue }
            let item = make(fresh[offset], board: board, parent: parent, section: section)
            level.insert(item, at: range.lowerBound + offset)
            store()
            if shows { outline.insertItems(at: [range.lowerBound + offset], inParent: holder, withAnimation: []) }
            arrived.append(item)
        }
        if let section, !difference.isEmpty { recounted.insert(section.key) }
        for (offset, entry) in fresh.enumerated() {
            let item = level[range.lowerBound + offset]
            if item.entry.row !== entry.row { remade.insert(item.id) }
            item.entry = entry
            guard shows, item.children != nil, outline.isItemExpanded(item) else {
                if shows, isExpandable(item) != item.wasExpandable { reloadTriangle(of: item) }
                continue
            }
            if item.entry.nestedBoard != nil { resyncBoard(of: item) }
            resyncNested(of: item, to: entry.children ?? [])
        }
        for item in arrived where shows && isExpandable(item) && state.isExpanded(item.entry) { outline.expandItem(item) }
        return fresh.count
    }

    // MARK: Rows

    /// A row the outline will have, under `parent` (nil at the top), in `section`'s row if it's
    /// gathered in one.
    private func make(_ entry: ContentsEntry, board: BoardID?, parent: ContentsItem?, section: ContentsSectionItem?) -> ContentsItem {
        let item = ContentsItem(entry, board: board, parent: parent, section: section)
        items[entry.id] = item
        if entry.nestedBoard != nil { owners.insert(entry.id) }
        return item
    }

    /// A section's row the outline will have at `parent`'s level (nil: the top), with its rows: the
    /// first `fromBoard` of them of the board the parent's shape owns, `ownBoard`; the rest where the
    /// parent is.
    private func makeSection(_ gathered: ContentsGathering.Section, under parent: ContentsItem?, fromBoard: Int = 0,
                             ownBoard: BoardID? = nil) -> ContentsSectionItem {
        let section = ContentsSectionItem(sectionKey(gathered.section, under: parent), parent: parent)
        section.boardRows = fromBoard
        section.rows = gathered.rows.indices.map { index in
            make(gathered.rows[index], board: index < fromBoard ? ownBoard : parent?.board, parent: parent, section: section)
        }
        sectionItems[section.key] = section
        return section
    }

    /// A section at `parent`'s level (nil: the top of the board shown).
    private func sectionKey(_ section: ContentsSection, under parent: ContentsItem?) -> ContentsSectionKey {
        ContentsSectionKey(section, at: parent.map { .under($0.id) } ?? .top(editor.board))
    }

    /// The sections at `parent`'s level (nil: the top), in their order, after the level's rows.
    private func sections(under parent: ContentsItem?) -> [ContentsSectionItem] { parent?.sections ?? topSections }

    private func setSections(_ sections: [ContentsSectionItem], under parent: ContentsItem?) {
        if let parent { parent.sections = sections } else { topSections = sections }
    }

    /// Where the sections at `parent`'s level start among the outline's rows there: after its rows
    /// (and, at the top, the header).
    private func sectionsStart(under parent: ContentsItem?) -> Int { parent.map { $0.children?.count ?? 0 } ?? top.count + 1 }

    /// A section's row comes into the outline at its level, in its place among the level's sections.
    private func add(_ section: ContentsSectionItem) {
        sectionItems[section.key] = section
        var sections = sections(under: section.parent)
        let rank = state.rank(of: section.key.section)
        let index = sections.firstIndex { state.rank(of: $0.key.section) > rank } ?? sections.count
        sections.insert(section, at: index)
        setSections(sections, under: section.parent)
        outline.insertItems(at: [sectionsStart(under: section.parent) + index], inParent: section.parent, withAnimation: [])
    }

    /// Takes a section's row out of the outline, its last row gone.
    private func removeSection(_ section: ContentsSectionItem) {
        var sections = sections(under: section.parent)
        guard let index = sections.firstIndex(where: { $0 === section }) else { return }
        sections.remove(at: index)
        setSections(sections, under: section.parent)
        if sectionItems[section.key] === section { sectionItems[section.key] = nil }
        outline.removeItems(at: [sectionsStart(under: section.parent) + index], inParent: section.parent, withAnimation: [])
    }

    /// Takes a row out of the outline, where it shows, and forgets it and the rows under it.
    private func remove(_ item: ContentsItem) {
        defer { forget(item) }
        guard items[item.id] === item else { return }
        if let section = item.section { return remove(item, from: section) }
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

    /// Takes a row out of its section's, where that shows; the section's row goes with its last.
    private func remove(_ item: ContentsItem, from section: ContentsSectionItem) {
        if case .under = section.key.level {
            guard let parent = section.parent else { return }
            // Rows read for a row the outline shows closed are read again as it opens.
            guard isShown(parent), outline.isItemExpanded(parent) else { return forgetChildren(of: parent) }
        }
        // A row of the board its parent owns is among the first of its rows; any other after them.
        let ofBoard = item.board != nil && item.board == section.parent?.entry.nestedBoard
        let among = ofBoard ? 0..<section.boardRows : section.boardRows..<section.rows.count
        guard let index = Self.index(of: item, in: section.rows, among: among) else { return }
        section.rows.remove(at: index)
        if index < section.boardRows { section.boardRows -= 1 }
        guard !section.rows.isEmpty else { return removeSection(section) }
        if outline.isItemExpanded(section) { outline.removeItems(at: [index], inParent: section, withAnimation: []) }
        recounted.insert(section.key)
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
        for section in item.sections {
            section.rows.forEach(forget)
            if sectionItems[section.key] === section { sectionItems[section.key] = nil }
        }
        item.sections = []
    }

    /// The rows nested under a row, front to back, read the first time the outline asks (it asks
    /// only once the row is open): the rows of the board it owns, then those nested under it; and,
    /// gathered in its `sections`, those of their kinds' sections, which the outline shows after them.
    func children(of item: ContentsItem) -> [ContentsItem] {
        if let children = item.children { return children }
        var level = ContentsGathering()
        var fromBoard: [ContentsSection: Int] = [:]
        var ownBoard: BoardID?
        item.boardRows = 0
        if let board = state.boardToOpen(under: item.entry) {
            let outlined = state.outlineRows(of: board)
            level = state.gathered(outlined.entries)
            item.boardRows = level.rows.count
            item.boardVersion = outlined.version
            for section in level.sections { fromBoard[section.section] = section.rows.count }
            ownBoard = board
        }
        let nested = item.board == nil ? state.listedChildren(of: item.id) : (item.entry.children ?? [])
        level.append(state.gathered(nested))
        let rows = level.rows.indices.map { index in
            make(level.rows[index], board: index < item.boardRows ? ownBoard : item.board, parent: item, section: nil)
        }
        item.sections = level.sections.map { makeSection($0, under: item, fromBoard: fromBoard[$0.section] ?? 0, ownBoard: ownBoard) }
        item.children = rows
        return rows
    }

    /// Whether a row has rows nested under it: some of its own, or a board with shapes.
    func isExpandable(_ item: ContentsItem) -> Bool {
        item.entry.children != nil || state.boardToOpen(under: item.entry) != nil
    }

    /// Whether the outline shows the row's level: every row it's under open, and the section's row
    /// it, or any of those, is under.
    private func isShown(_ item: ContentsItem) -> Bool {
        guard items[item.id] === item else { return false }
        var row = item
        while true {
            if let section = row.section, !outline.isItemExpanded(section) { return false }
            guard let above = row.parent else { return true }
            guard above.children != nil, outline.isItemExpanded(above) else { return false }
            row = above
        }
    }

    /// Whether the outline shows a section's row: it's the outline's, and the row it's under shows open.
    private func isShown(_ section: ContentsSectionItem) -> Bool {
        guard sectionItems[section.key] === section else { return false }
        guard case .under = section.key.level else { return true }
        guard let parent = section.parent else { return false }
        return parent.children != nil && outline.isItemExpanded(parent) && isShown(parent)
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

    /// Shows the rows an update made again as they are now, and the sections' rows whose counts it
    /// changed, where the outline has views of them (in view, or about to be); a row out of view is
    /// drawn as it is once it comes into view.
    private func redrawRemade() {
        guard !remade.isEmpty || !recounted.isEmpty else { return }
        let rows = remade, sections = recounted
        remade = []
        recounted = []
        let size = outline.effectiveRowSizeStyle
        outline.enumerateAvailableRowViews { rowView, row in
            guard let cell = rowView.view(atColumn: 0) as? ContentsCell else { return }
            switch self.outline.item(atRow: row) {
            case let item as ContentsItem where rows.contains(item.id):
                cell.show(item.entry, size: size)
                (rowView as? ContentsTableRow)?.show(item)
            case let section as ContentsSectionItem where sections.contains(section.key):
                cell.show(section.key.section, count: section.rows.count, size: size)
            default:
                return
            }
            #if DEBUG
            self.state.rowsRedrawn += 1
            #endif
        }
    }

    // MARK: The selection

    /// Shows the editor's selection as the outline's: the rows of the shapes selected that show, and
    /// the row of a closed section whose rows are all selected. A selection the list didn't make (on
    /// the canvas, Jump To, Find, an undo) is brought into view too: the first selected row scrolled
    /// to, and for one shape the rows its row is nested under opened first (an arrow's under the note
    /// it starts from), and the section's it's in, as the person would open them. Several selected open
    /// nothing: ⌘A would open every row.
    private func showSelection() {
        let selected = editor.selectedShapeIDs
        guard selected != shownSelection else { return }
        shownSelection = selected
        let fromList = listSelection == editor.selectionRevision
        var rows = IndexSet()
        if !fromList, selected.count == 1 { openRows(above: selected[0]) }
        let wanted = Set(selected)
        if selected.count <= ContentsStyle.selectedRowLookups {
            var closed: [ContentsSectionItem] = []
            for id in selected {
                guard let item = items[id] else { continue }
                if isShown(item) {
                    let row = outline.row(forItem: item)
                    if row > 0 { rows.insert(row) }
                } else if let section = item.section, !closed.contains(where: { $0 === section }) {
                    closed.append(section)
                }
            }
            for section in closed where showsSelected(section, wanted) {
                let row = outline.row(forItem: section)
                if row > 0 { rows.insert(row) }
            }
        } else {
            // Many: one pass over the rows shown.
            for row in 1..<max(1, outline.numberOfRows) {
                switch outline.item(atRow: row) {
                case let item as ContentsItem where wanted.contains(item.id): rows.insert(row)
                case let section as ContentsSectionItem where showsSelected(section, wanted): rows.insert(row)
                default: break
                }
            }
        }
        if fromList {
            // A section's row the list selected stays the selection of its rows, open or not, as the person
            // left it: opened before this update (→ pressed before SwiftUI caught up), its rows aren't picked.
            for row in outline.selectedRowIndexes {
                guard let section = outline.item(atRow: row) as? ContentsSectionItem, section.rows.allSatisfy({ wanted.contains($0.id) }) else {
                    continue
                }
                rows.insert(row)
                for member in section.rows {
                    let shown = outline.row(forItem: member)
                    if shown > 0, !outline.isRowSelected(shown) { rows.remove(shown) }
                }
            }
        }
        if rows != outline.selectedRowIndexes { outline.selectRowIndexes(rows, byExtendingSelection: false) }
        if !fromList, let first = rows.first { outline.scrollRowToVisible(first) }
    }

    /// Whether a section's row shows the selection: it's closed, so its rows don't, and every one of
    /// them is selected (as selecting it selects them).
    private func showsSelected(_ section: ContentsSectionItem, _ selected: Set<ShapeID>) -> Bool {
        !outline.isItemExpanded(section) && section.rows.allSatisfy { selected.contains($0.id) }
    }

    /// Opens the rows the shape's row is nested under, the outermost first, and the sections' rows
    /// it and they are under, each kept open as the person would leave it (`setExpanded`), so the
    /// row shows.
    private func openRows(above id: ShapeID) {
        var above: [ShapeID] = [], next = state.listedPlace(of: id)
        guard next.isListed else { return }
        while let parent = next.parent, !above.contains(parent) {
            above.append(parent)
            next = state.listedPlace(of: parent)
        }
        for parent in above.reversed() {
            guard let item = items[parent] else { return }
            openSection(of: item)
            guard isShown(item), isExpandable(item) else { return }
            guard !outline.isItemExpanded(item) else { continue }
            state.setExpanded(item.entry, true)
            outline.expandItem(item)
        }
        if let item = items[id] { openSection(of: item) }
    }

    /// Opens the section's row a row is under, where that shows, kept open as the person would leave
    /// it (`setExpanded`).
    private func openSection(of item: ContentsItem) {
        guard let section = item.section, isShown(section), !outline.isItemExpanded(section) else { return }
        state.setExpanded(section.key, true)
        outline.expandItem(section)
    }

    /// The person changed the outline's selection (a click, ⌘- and ⇧-clicks, a key): their shapes
    /// selected (`ContentsState.select`), every row's of a section whose row is selected. A click's pick
    /// gives the canvas the keyboard, so its keys act on the shapes picked at once, a nudge or Delete; a
    /// key's keeps it in the list, for the next key to walk on (the list has it by View ▸ Focus
    /// Sidebar), and a walk by keys is one step back.
    private func selectionChanged() {
        var ids: Set<ShapeID> = []
        for row in outline.selectedRowIndexes {
            switch outline.item(atRow: row) {
            case let item as ContentsItem: ids.insert(item.id)
            case let section as ContentsSectionItem: ids.formUnion(section.rows.lazy.map(\.id))
            default: break
            }
        }
        state.select(ids, byKey: keyArrived)
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

    /// A double-click on a row: its shape opened (`ContentsState.open`); on a section's row, the
    /// section opened or closed.
    @objc private func openClicked(_ sender: Any?) {
        let row = outline.clickedRow
        guard row > 0 else { return }
        switch outline.item(atRow: row) {
        case let item as ContentsItem: state.open([item.id])
        case let section as ContentsSectionItem: toggle(section)
        default: break
        }
    }

    /// The selected rows' shapes, for Return: the one opened, as Return on the canvas opens it.
    var selectedShapes: Set<ShapeID> {
        Set(outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? ContentsItem)?.id })
    }

    /// The section's row, when it's the one row selected: Return opens or closes it.
    private var selectedSection: ContentsSectionItem? {
        guard outline.selectedRowIndexes.count == 1, let row = outline.selectedRowIndexes.first else { return nil }
        return outline.item(atRow: row) as? ContentsSectionItem
    }

    /// Opens a section's row or closes it, as its disclosure triangle does (and so as the person
    /// leaves it, `setExpanded`).
    private func toggle(_ section: ContentsSectionItem) {
        if outline.isItemExpanded(section) { outline.collapseItem(section) } else { outline.expandItem(section) }
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
            if let section = selectedSection { toggle(section) } else { state.open(selectedShapes) }
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

    /// A section turned other than in the outline (a headless turn): the outline opens or closes its
    /// row, where it shows.
    func sectionTurned(_ key: ContentsSectionKey) {
        guard updating == 0, let section = sectionItems[key], isShown(section) else { return }
        let open = state.isExpanded(key)
        guard open != outline.isItemExpanded(section) else { return }
        updating += 1
        defer { updating -= 1 }
        if open { outline.expandItem(section) } else { outline.collapseItem(section) }
    }
}

extension ContentsListController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item else { return top.count + topSections.count + 1 }
        if let section = item as? ContentsSectionItem { return section.rows.count }
        guard let item = item as? ContentsItem else { return 0 }
        return children(of: item).count + item.sections.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item else {
            guard index > 0 else { return header }
            return index - 1 < top.count ? top[index - 1] : topSections[index - 1 - top.count]
        }
        if let section = item as? ContentsSectionItem { return section.rows[index] }
        guard let item = item as? ContentsItem else { return header }
        let rows = children(of: item)
        return index < rows.count ? rows[index] : item.sections[index - rows.count]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if let section = item as? ContentsSectionItem { return !section.rows.isEmpty }
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

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { item is ContentsItem || item is ContentsSectionItem }

    func outlineView(_ outlineView: NSOutlineView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        proposed.contains(0) ? proposed.subtracting([0]) : proposed
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if item is ContentsHeaderItem { return headerCell }
        guard item is ContentsItem || item is ContentsSectionItem else { return nil }
        let cell = outlineView.makeView(withIdentifier: ContentsCell.identifier, owner: nil) as? ContentsCell ?? ContentsCell()
        if let item = item as? ContentsItem {
            cell.show(item.entry, size: outlineView.effectiveRowSizeStyle)
        } else if let section = item as? ContentsSectionItem {
            cell.show(section.key.section, count: section.rows.count, size: outlineView.effectiveRowSizeStyle)
        }
        #if DEBUG
        state.rowsRedrawn += 1
        #endif
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        guard item is ContentsItem || item is ContentsSectionItem else { return nil }
        let row = outlineView.makeView(withIdentifier: ContentsTableRow.identifier, owner: nil) as? ContentsTableRow ?? ContentsTableRow()
        row.list = self
        if let item = item as? ContentsItem { row.show(item) } else if let section = item as? ContentsSectionItem { row.show(section: section) }
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
        let object = notification.userInfo?["NSObject"]
        if let section = object as? ContentsSectionItem {
            if updating == 0 { state.setExpanded(section.key, true) }
            updating += 1
            defer { updating -= 1 }
            for row in section.rows where isExpandable(row) && state.isExpanded(row.entry) && !outline.isItemExpanded(row) {
                outline.expandItem(row)
            }
            return
        }
        guard let item = object as? ContentsItem else { return }
        if updating == 0 { state.setExpanded(item.entry, true) }
        // The rows under it that are open, open: what the person left them as, a container's from the
        // start; and its sections the person opened.
        updating += 1
        defer { updating -= 1 }
        for child in children(of: item) where isExpandable(child) && state.isExpanded(child.entry) && !outline.isItemExpanded(child) {
            outline.expandItem(child)
        }
        for section in item.sections where state.isExpanded(section.key) && !outline.isItemExpanded(section) {
            outline.expandItem(section)
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        let object = notification.userInfo?["NSObject"]
        if let section = object as? ContentsSectionItem {
            if updating == 0 { state.setExpanded(section.key, false) }
            // Its rows stay, counted; what's under them is read again as they show, as it is then (the
            // outline closes them, and opens them again as the person left them).
            updating += 1
            defer { updating -= 1 }
            for row in section.rows {
                if outline.isItemExpanded(row) { outline.collapseItem(row) } else { forgetChildren(of: row) }
            }
            return
        }
        guard let item = object as? ContentsItem else { return }
        if updating == 0 { state.setExpanded(item.entry, false) }
        // Read again as it opens, as they are then.
        forgetChildren(of: item)
    }
}

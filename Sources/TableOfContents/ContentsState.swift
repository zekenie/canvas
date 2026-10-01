import Canvas
import CoreGraphics
import Observation
import Selection
import SwiftUI

/// One row of the table of contents, with the rows nested under it.
@MainActor
public struct ContentsEntry: Identifiable {
    public let id: ShapeID
    public var kind: ShapeKind { row.record.kind }
    /// The row, when it's a plain `ContentsLabel` (as most are); nil for any other view.
    public var label: ContentsLabel? { row.label }
    /// The kind's symbol (`registry.label(of:)`), which a `ContentsLabel` without its own shows.
    public var symbol: String { row.symbol }
    /// The dots at the row's trailing end (`ContentsMarks`), in contribution order.
    public var marks: [ContentsMark] { row.marks }
    /// The rows nested under this one, in document order; nil when there are none, so the list
    /// shows no disclosure triangle.
    public internal(set) var children: [ContentsEntry]?
    /// The board this row's shape owns (a `BoardOwning` kind's, not kept aside), whose rows the list
    /// nests under this one's, before `children`: that board's `ContentsState.outline(of:)`, read only
    /// once the row is expanded. Nil for a shape that owns none. The board may have no shapes yet.
    public var nestedBoard: BoardID? { row.ownsBoard ? BoardID(owner: id) : nil }
    /// Whether the row starts expanded: a container's (`registry.isContainer`), whose nested rows
    /// are what it holds, on the board shown, as the canvas shows them inside it; every other row
    /// starts collapsed (the arrows that start from a shape, a subboard's board). What the person
    /// turns its disclosure triangle to holds after that (`ContentsState.isExpanded(_:)`).
    public var startsExpanded: Bool { row.startsExpanded }
    /// The shape's row, as its kind made it for the shape as listed, with its marks: the same
    /// object until the shape changes other than by moving, or its marks change.
    var row: ShapeRow

    init(row: ShapeRow, children: [ContentsEntry]?) {
        id = row.id
        self.row = row
        self.children = children
    }
}

/// A shape's row as its kind made it for one version of the shape, with its marks and what places
/// it in the list. Made again only when the shape changes other than by moving (a row says what a
/// shape is, never where it is), copied with its new marks when they change while the shape
/// doesn't, and shared by every scope that lists it.
@MainActor
final class ShapeRow {
    /// The shape as it is: as the row was made, or moved since (`follow(_:)`).
    private(set) var record: AnyShapeRecord
    /// Whether the kind lists the shape (`when`).
    let isListed: Bool
    /// The shape the row nests under, listed or not: the one its kind names (`nestedUnder`), else
    /// the container it's in, as the core goes by it (`registry.container(of:in:)`).
    let parent: ShapeID?
    let view: AnyView
    let label: ContentsLabel?
    let symbol: String
    let marks: [ContentsMark]
    /// Where the shape is in the stack, which orders rows among their siblings. Every shape in a
    /// document has a key.
    let key: StackingKey
    /// Whether the shape owns a board the editor can show wherever it shows the shape's own
    /// (`registry.ownsShowableBoard`): that board's rows nest under its row.
    let ownsBoard: Bool
    /// Whether the row starts expanded: a container's (`registry.isContainer`) that owns no board,
    /// whose nested rows are of what it holds on the board shown.
    let startsExpanded: Bool

    init(record: AnyShapeRecord, isListed: Bool, parent: ShapeID?, ownsBoard: Bool, startsExpanded: Bool, row: ResolvedRow, symbol: String,
         marks: [ContentsMark]) {
        self.record = record
        self.isListed = isListed
        self.parent = parent
        self.ownsBoard = ownsBoard
        self.startsExpanded = startsExpanded
        view = row.view
        label = row.label
        self.symbol = symbol
        self.marks = marks
        key = record.stackingKey!
    }

    /// `row` made again (`resolved`, nil to keep its view) with other marks, for a shape whose row or
    /// marks changed while it didn't.
    init(_ row: ShapeRow, resolved: ResolvedRow?, marks: [ContentsMark]) {
        record = row.record
        isListed = row.isListed
        parent = row.parent
        ownsBoard = row.ownsBoard
        startsExpanded = row.startsExpanded
        if let resolved {
            view = resolved.view
            label = resolved.label
        } else {
            view = row.view
            label = row.label
        }
        symbol = row.symbol
        self.marks = marks
        key = row.key
    }

    /// The shape only moved (`ChangeSet.moved`): the row, which says what it is and not where, stays
    /// the same object, so no list redraws it, and holds the shape as it is now.
    func follow(_ moved: AnyShapeRecord) { record = moved }

    var id: ShapeID { record.id }
}

/// Per editor (so per window): what the table of contents lists, and each shape's row, made again
/// only when that shape changes other than by moving. What a commit changed is all a read after it
/// redoes: the rows of the shapes its change set names, and where those nest, but for those it only
/// moved (a drag's every event, a container carrying what it holds), whose rows stay and whose
/// marks are read again; and the rows and marks of the shapes whose rows and marks it may change
/// though it doesn't change them (`affected`). It lists the board shown; the rows and the listing of
/// every row of the boards shown last are kept for going back to them, and taken back while those
/// boards are as they were left (`BoardStash`). What changed on other boards meanwhile is handed to
/// `affected` on going back (as `ChangeSet.elsewhere`), so a row that reads a shape on another board
/// that was renamed or deleted since is made again. Which rows are expanded is kept too, by shape,
/// whatever's listed (`isExpanded(_:)`).
@MainActor
@Observable
public final class ContentsState {
    /// What the table of contents listed when it last selected, and the selection it made then.
    private struct Pin {
        let scope: [ShapeID]?
        let selectionRevision: Int
    }

    /// What's kept of a board that isn't shown: its rows, the listing of all of them, which rows to
    /// make again and whose marks to read again, and the editor's revision as it was left.
    private struct Kept {
        let rows: [ShapeID: ShapeRow]
        let remakes: Set<ShapeID>
        let remarks: Set<ShapeID>
        let board: ContentsListing?
        let revision: Int
    }

    /// What's kept of a board's outline (`outline(of:)`): its rows, as listed, and the revisions
    /// they're up to date with.
    private struct Outline {
        /// The board's (`file.revision(of:)`), as its rows were made.
        let revision: Int
        /// The editor's, as its rows that read more than their shapes were last made.
        var heard: Int
        var rows: [ShapeID: ShapeRow]
        var entries: [ContentsEntry]
    }

    /// How a kind's shapes get their rows.
    private struct KindRows {
        let contribution: ContentsContribution?
        /// What its rows are called (`ContentsTitles`): the kind's own name for them, else every kind's.
        let title: ContentsTitles.Contribution?
        /// What marks its rows (`ContentsMarks`): the kind's own, then every kind's.
        let marks: [ContentsMarkContribution]
        /// The kind's label and symbol (`registry.label(of:)`), a dashed square for a kind without one.
        let name: String
        let symbol: String

        /// Whether its rows read more than their shapes, so a commit may change them without
        /// changing their shapes (`affected`).
        var readsOtherShapes: Bool { contribution?.affected != nil }
    }

    @ObservationIgnored private unowned let editor: CanvasEditor
    /// Each kind's, found once: the registry is frozen.
    @ObservationIgnored private var kinds: [ShapeKind: KindRows] = [:]
    /// Each shape's row, made when a scope first takes the shape in, and again after it changes.
    @ObservationIgnored private var rows: [ShapeID: ShapeRow] = [:]
    /// Shapes whose rows are kept but whose marks may have changed (only shapes with a row here):
    /// the next read of each reads its marks again, and keeps the row object unless they changed.
    @ObservationIgnored private var remarks: Set<ShapeID> = []
    /// Shapes whose rows are kept but read more than their shapes, which a commit may have changed
    /// (only shapes with a row here): the next read of each makes its row again, and keeps the row
    /// object unless its label changed.
    @ObservationIgnored private var remakes: Set<ShapeID> = []
    /// What's listed for the whole board, and for the last scope of some shapes: each kept, and
    /// brought up to date as it's read.
    @ObservationIgnored private var board: ContentsListing?
    @ObservationIgnored private var filtered: ContentsListing?
    /// The revision the rows and listings are up to date with. Read before this service hears of
    /// a commit (by a service that hears first), it keeps the rows whose shapes are as they were
    /// and lists them again, making again the rows of kinds whose rows name what a commit affects,
    /// and reading their marks again when a mark's contributor does, since only hearing of the
    /// commit says which.
    @ObservationIgnored private var heardRevision: Int
    /// What the rows' and the marks' contributors say a commit affects besides the shapes it
    /// changes (`affected`).
    @ObservationIgnored private let rowAffected: [@MainActor (ChangeSet, ContentsContext) -> Set<ShapeID>]
    @ObservationIgnored private let markAffected: [@MainActor (ChangeSet, ContentsContext) -> Set<ShapeID>]
    /// The boards shown last, as they were left.
    @ObservationIgnored private var kept = BoardStash<Kept>()
    /// While boards are kept and some rows or marks read more than their shapes: the editor's
    /// revision as each shape was last touched on the board shown or elsewhere since the board kept
    /// longest was left. Going back to a board, those touched after it was left are what changed
    /// away from it.
    @ObservationIgnored private var touchedAway: [ShapeID: Int] = [:]
    /// The editor's revision as each board kept was left.
    @ObservationIgnored private var leftAt: [BoardID: Int] = [:]
    /// What changed on other boards while the board shown was away, still to hand the rows' and
    /// the marks' `affected` (on the next read, once every service has followed the switch).
    @ObservationIgnored private var missed: Set<ShapeID> = []
    /// The shape the pointer on its row hovered, until it leaves the row: all a row's leaving
    /// lets go of.
    @ObservationIgnored private var rowHover: ShapeID?
    /// The boards whose outlines have been read (`outline(of:)`), while they're on the path.
    @ObservationIgnored private var outlines: [BoardID: Outline] = [:]
    /// The editor's revision as of the last commit whose change set this service has heard, and as
    /// of the last that did more than move shapes: what the rows of an outline that read more than
    /// their shapes may have changed with (a move names nothing anew: a drag's every event).
    @ObservationIgnored private var changesHeard: Int
    @ObservationIgnored private var lastBeyondMoves: Int
    /// The rows whose disclosure triangle the person turned from how it starts
    /// (`ContentsEntry.startsExpanded`): observed per row, through `isExpanded(_:)`.
    @ObservationIgnored private var turned: Set<ShapeID> = []
    /// The shapes commits only moved since the rows were last read (`ChangeSet.moved`), whose rows,
    /// if kept, stay: the next read has them hold their shapes as they are, and reads their marks
    /// again (`followMoves`). So a drag's every event costs the table of contents one set's upkeep,
    /// whatever it carries (a frame and all it holds), and the rest only once something reads them.
    @ObservationIgnored private var movedSinceRead: Set<ShapeID> = []
    private var pin: Pin?
    #if DEBUG
    /// How many times the list has asked a row for its view (debug builds only), so tests can hold
    /// a change to redrawing the rows it changes.
    @ObservationIgnored public var rowsRedrawn = 0
    /// How many rows have been made (debug builds only): a kind asked for a shape's row. Going back
    /// to a board as it was left makes none.
    @ObservationIgnored public var rowsMade = 0
    #endif

    init(editor: CanvasEditor) {
        self.editor = editor
        heardRevision = editor.revision
        changesHeard = editor.revision
        lastBeyondMoves = editor.revision
        rowAffected = editor.registry.contributions(to: ContentsRows.self).compactMap(\.value.affected)
        markAffected = editor.registry.contributions(to: ContentsMarks.self).compactMap(\.value.affected)
    }

    // MARK: What's listed

    /// The shapes listed, nil for every shape. It follows the selection: select shapes (on the
    /// canvas, or anywhere but here) and just they are listed; select nothing and every shape is.
    /// Selecting rows (`select`) leaves it as it was, so a row of a long list can be picked without
    /// the rest going away, and `showAll` lists every shape without deselecting. Either holds until
    /// the selection next changes some other way.
    public var scope: [ShapeID]? {
        if let pin, pin.selectionRevision == editor.selectionRevision { return pin.scope }
        let selected = editor.selectedShapeIDs
        return selected.isEmpty ? nil : selected
    }

    public var isFiltered: Bool { scope != nil }

    /// The top-level rows in document order (back to front, as data-canvas's z-ordered outline),
    /// each with the rows nested under it. Only listed shapes in `scope` have rows. A row nests
    /// under the shape its kind names (`nestedUnder`) when that shape has a row too, unless that
    /// would make a loop: then the later shape stays at the top. Kept from one read to the next,
    /// so a read after a commit costs what the commit changed.
    public var entries: [ContentsEntry] {
        catchUp()
        followMoves()
        catchUpAway()
        guard let scope else {
            keepUp(&board, scope: nil)
            return board!.entries
        }
        keepUp(&filtered, scope: Set(scope))
        return filtered!.entries
    }

    /// How many times a commit has brought rows in at more than one place (a script that draws a
    /// shape and connects shapes far apart, whose arrows nest under the shapes they start from; a
    /// deleted shape whose nested rows come out from under it, to their places far apart), or made
    /// a listing start over: each time, the list replaces its rows rather than bring them in around
    /// the rows it kept, and rows that were expanded collapse, as they do when what's listed
    /// changes. Rows arriving at several places at once make AppKit, which sizes a `List`'s rows,
    /// log a reentrant update (`TableOfContentsView`), in a list of any length.
    @ObservationIgnored private(set) var replacements = 0

    /// Brings a listing up to date with what the commits since changed, or lists `scope` from
    /// scratch (a new scope, or one listing again is quicker for), and notes a replacement when
    /// its rows didn't come in as one run.
    private func keepUp(_ listing: inout ContentsListing?, scope: Set<ShapeID>?) {
        if var kept = listing, kept.scope == scope {
            listing = nil               // so updating it doesn't copy it
            if kept.update(row: row(of:)) {
                if kept.isScattered { replacements += 1 }
                listing = kept
                return
            }
            replacements += 1
        }
        listing = self.listing(of: scope)
    }

    /// Every row in scope (nil for every shape), listed from scratch, from the rows made already.
    private func listing(of scope: Set<ShapeID>?) -> ContentsListing {
        ContentsListing(scope: scope, shapes: inDocumentOrder(scope), row: row(of:))
    }

    /// Every shape, or the shapes of `ids` still in the document, back to front.
    private func inDocumentOrder(_ ids: Set<ShapeID>?) -> [ShapeID] {
        let document = editor.document
        guard let ids else { return document.shapes.map(\.id) }
        return ids.compactMap { id in document.index(of: id).map { (id, $0) } }.sorted { $0.1 < $1.1 }.map(\.0)
    }

    /// After a commit this service hasn't heard of: keeps the rows whose shapes are as they were,
    /// and lists them again, making again those that read more than their shapes. Reading the
    /// revision also ties whoever reads `entries` to every commit, as reading the document would.
    private func catchUp() {
        guard heardRevision != editor.revision else { return }
        heardRevision = editor.revision
        let document = editor.document
        // A row whose shape only moved since it was made isn't the shape's now either: made again.
        movedSinceRead = []
        rows = rows.filter { document[$0.key] == $0.value.record }
        remakes = rowAffected.isEmpty ? remakes.filter { rows[$0] != nil }
            : Set(rows.lazy.filter { self.kindRows($0.value.record.kind).readsOtherShapes }.map(\.key))
        remarks = markAffected.isEmpty ? remarks.filter { rows[$0] != nil } : Set(rows.keys)
        if board != nil || filtered != nil { replacements += 1 }       // listed again, its rows anywhere
        board = nil
        filtered = nil
    }

    /// After going back to a board: the rows and marks that read what changed on other boards
    /// while it wasn't shown (`affected`, given those shapes as `elsewhere`) are made and read again.
    private func catchUpAway() {
        guard !missed.isEmpty else { return }
        let changes = ChangeSet(elsewhere: missed)
        missed = []
        noteAffected(by: changes)
    }

    // MARK: Selecting

    /// What selecting rows does (a click, ⌘- and ⇧-clicks, the arrow keys): selects their shapes,
    /// in document order, and brings them into view, zoomed to fit (no closer than 120%; Selection's
    /// `editor.reveal`). What's listed stays as it was. Selecting what's already selected moves
    /// nothing. A row of a board nested under its owner's (`nestedBoard`) is of a shape on another
    /// board, so selecting it goes there, as following a link does (Selection's `editor.goTo`: its
    /// board shown and it selected, one step back), and leaves the rest of the rows selected behind;
    /// but only when such rows are all a selection adds: a ⇧-click whose range passes over an open
    /// board's rows selects the board shown's rows in it, and no others.
    public func select(_ ids: Set<ShapeID>) {
        let away = elsewhere(ids)
        if !away.isEmpty, ids.subtracting(editor.selectedShapeIDs).isSubset(of: away) { return editor.goTo(away) }
        let listed = scope
        let ordered = inDocumentOrder(ids)
        let isNew = Set(ordered) != Set(editor.selectedShapeIDs)
        editor.selectedShapeIDs = ordered
        pin = Pin(scope: listed, selectionRevision: editor.selectionRevision)
        if isNew { editor.reveal(editor.selectedShapeIDs) }
    }

    /// A row's primary action (a double-click or Return on it): opens its shape as Return on the
    /// canvas does (Selection's `editor.open`: entering the board it owns, editing it, whatever its
    /// kind opens to), selecting it first if it isn't the only shape selected. Does nothing for
    /// several rows, or a shape that can't be opened (`editor.canOpen`).
    public func open(_ ids: Set<ShapeID>) {
        guard ids.count == 1, let id = ids.first else { return }
        // A row of a nested board: going to its shape and opening it there, one step back.
        guard elsewhere(ids).isEmpty else { return editor.goInto(id) }
        guard editor.canOpen(id) else { return }
        if editor.selectedShapeIDs != [id] { select(ids) }
        editor.open(id)
    }

    /// Those of `ids` on a board of the file other than the one shown (rows of a board nested under
    /// its owner's), in the order the list nests them, so which board several go to (the first's) is
    /// the one listed first, whatever a set's order.
    private func elsewhere(_ ids: Set<ShapeID>) -> [ShapeID] {
        let file = editor.file, board = editor.board
        return ids.filter { file.board(containing: $0).map { $0 != board } ?? false }
            .map { ($0, Self.place(of: $0, in: file)) }
            .sorted { $0.1.lexicographicallyPrecedes($1.1) }.map(\.0)
    }

    /// Where a shape is listed when every board's rows are under their owner's: its owners' places in
    /// the stack, the outermost first, then its own. Compared, places order shapes as the list does.
    private static func place(of id: ShapeID, in file: CanvasFile) -> [Int] {
        var place: [Int] = [], current = id, met: Set<ShapeID> = []
        while met.insert(current).inserted, let board = file.board(containing: current), let index = file[board].index(of: current) {
            place.append(index)
            guard let owner = board.owner else { break }
            current = owner
        }
        return place.reversed()
    }

    /// Lists every shape, keeping the selection, until the selection next changes.
    public func showAll() {
        pin = Pin(scope: nil, selectionRevision: editor.selectionRevision)
    }

    // MARK: Hovering

    /// The pointer is on the shape's row (and, called again as it moves there, still is): the
    /// shape is hovered (`editor.hovered`), as though the pointer were on it on the canvas. A shape
    /// on another board (a row of a board nested under its owner's) isn't: the canvas doesn't show it.
    public func hover(_ id: ShapeID) {
        guard editor.document[id] != nil else { return }
        rowHover = id
        editor.hovered = id
    }

    /// The pointer left the shape's row, or the row went away: the shape isn't hovered any more,
    /// if the pointer on the row hovered it. Leaves any other hover: another row's, or one the
    /// canvas set (the pointer on a shape there, while the rows are replaced under it).
    public func endHover(_ id: ShapeID) {
        guard rowHover == id else { return }
        rowHover = nil
        if editor.hovered == id { editor.hovered = nil }
    }

    /// Whether the shape's row shows as hovered: its shape is hovered, whether the pointer is on the
    /// row or on the shape on the canvas, and isn't selected (as the canvas outlines the hover only
    /// on an unselected shape). Observing it hears only this shape's hover change, and the selection
    /// only while the shape is hovered, so the hover moving down the list redraws the row it leaves
    /// and the row it reaches, not every row.
    public func isHovered(_ id: ShapeID) -> Bool { editor.isHovered(id) && !editor.isSelected(id) }

    // MARK: Expanding

    /// Whether the row shows the rows nested under it: as it starts (`startsExpanded`: a container's
    /// expanded, every other row collapsed) until the person turns its disclosure triangle, then as
    /// they left it, kept by shape for the editor's life, whatever's listed, so a row stays as it
    /// was through Show All, the list's rows replaced, or another board shown and back. Observing it
    /// hears only this row's turning, so turning one redraws that row and its own rows alone.
    public func isExpanded(_ entry: ContentsEntry) -> Bool {
        access(keyPath: \.[turned: entry.id])
        return entry.startsExpanded != turned.contains(entry.id)
    }

    /// The person turned the row's disclosure triangle (a click on it, → or ← in the list).
    public func setExpanded(_ entry: ContentsEntry, _ isExpanded: Bool) {
        guard isExpanded != (entry.startsExpanded != turned.contains(entry.id)) else { return }
        withMutation(keyPath: \.[turned: entry.id]) {
            if isExpanded == entry.startsExpanded { turned.remove(entry.id) } else { turned.insert(entry.id) }
        }
    }

    /// Only a key: one key path per shape, under which Observation keeps the observers of each row's
    /// disclosure apart.
    private subscript(turned id: ShapeID) -> Bool { turned.contains(id) }

    // MARK: Another board

    /// A board's rows as the table of contents lists every shape of it, whether it's shown or not:
    /// what a view of a board of the file lists, the one shown or another (the path's crumb menus,
    /// each its crumb's board; the rows of a board nested under its owner's, `nestedBoard`). The rows
    /// are those `entries` would list there with nothing selected, less their marks, which are the
    /// board shown's (validation checks only it). Made on the first read, and kept while the board is
    /// as it was (its revision) and, once another board is shown, on the path to it; a read after a
    /// commit that did more than move shapes makes again the rows that read more than their shapes
    /// (`affected`, whose answers are the board shown's, can't say which), and keeps each unless its
    /// label changed. Reading it ties the reader to every commit, as `entries` does.
    public func outline(of board: BoardID) -> [ContentsEntry] {
        let revision = editor.file.revision(of: board), now = editor.revision
        guard var kept = outlines.removeValue(forKey: board), kept.revision == revision else {
            let made = makeOutline(of: board, revision: revision, at: now)
            outlines[board] = made
            return made.entries
        }
        // A commit since that did more than move shapes, or one this service hasn't heard yet (read
        // by a service that hears first), may have changed what they read.
        if kept.heard != now {
            if lastBeyondMoves > kept.heard || changesHeard != now, remakeRowsReadingOthers(in: &kept.rows) {
                let rows = kept.rows
                kept.entries = ContentsListing(scope: nil, shapes: editor.contents(of: board).shapes.map(\.id)) { rows[$0] }.entries
            }
            kept.heard = now
        }
        outlines[board] = kept
        return kept.entries
    }

    /// The board a row opens onto (`nestedBoard`), while it has shapes: nil for one with none, so its
    /// row shows no disclosure triangle. O(1): its rows are read only once the row is expanded
    /// (`outline(of:)`).
    func boardToOpen(under entry: ContentsEntry) -> BoardID? {
        guard let board = entry.nestedBoard, !editor.contents(of: board).shapes.isEmpty else { return nil }
        return board
    }

    /// Every row of `board`, listed as `outline(of:)` lists them.
    private func makeOutline(of board: BoardID, revision: Int, at now: Int) -> Outline {
        let document = editor.contents(of: board)
        var rows: [ShapeID: ShapeRow] = [:]
        rows.reserveCapacity(document.shapes.count)
        let listing = ContentsListing(scope: nil, shapes: document.shapes.map(\.id)) { id in
            guard let record = document[id] else { return nil }
            let made = makeRow(of: record, in: document, marked: false)
            rows[id] = made
            return made
        }
        return Outline(revision: revision, heard: now, rows: rows, entries: listing.entries)
    }

    /// Makes again the rows of kinds whose rows read more than their shapes: whether any label changed.
    private func remakeRowsReadingOthers(in rows: inout [ShapeID: ShapeRow]) -> Bool {
        guard !rowAffected.isEmpty else { return false }
        var changed = false
        for (id, made) in rows {
            let kind = kindRows(made.record.kind)
            guard kind.readsOtherShapes else { continue }
            let row = resolvedRow(of: made.record, kind: kind)
            if let label = row.label, let old = made.label, label.showsSame(as: old) { continue }
            rows[id] = ShapeRow(made, resolved: row, marks: [])
            changed = true
        }
        return changed
    }

    // MARK: Rows

    /// The shape's row: its kind's, else its kind's label; called what `ContentsTitles` names it, if
    /// it's a `ContentsLabel`; with its marks. Made again after the shape changes other than by moving;
    /// made again when a commit may change it without changing the shape (`affected`), and kept
    /// unless its label changed; and copied with new marks when a commit changes them without
    /// changing the shape, or moves it; nil once it's gone. A shape the board keeps aside isn't
    /// listed, whatever its kind: nothing on the canvas sees it.
    private func row(of id: ShapeID) -> ShapeRow? {
        if let made = rows[id] {
            let remake = remakes.remove(id) != nil, remark = remarks.remove(id) != nil
            guard remake || remark else { return made }
            let kind = kindRows(made.record.kind)
            var remade: ResolvedRow?
            if remake {
                let row = resolvedRow(of: made.record, kind: kind)
                let isSame = if let label = row.label, let old = made.label { label.showsSame(as: old) } else { false }
                if !isSame { remade = row }
            }
            let marks = remark ? marks(of: made.record, isListed: made.isListed, kind: kind) : made.marks
            guard remade != nil || marks != made.marks else { return made }
            let replaced = ShapeRow(made, resolved: remade, marks: marks)
            rows[id] = replaced
            return replaced
        }
        let document = editor.document
        guard let record = document[id] else { return nil }
        let made = makeRow(of: record, in: document, marked: true)
        rows[id] = made
        return made
    }

    /// A shape of `document`'s row as its kind makes it, with its marks when `marked` (the board
    /// shown's rows are). It nests under the shape its kind names (`nestedUnder`), else under the
    /// container it's in: read from its record, as the core goes by it (a container the board keeps
    /// aside, or of a kind that holds nothing here, holds nothing). O(1) more than its row.
    private func makeRow(of record: AnyShapeRecord, in document: CanvasDocument, marked: Bool) -> ShapeRow {
        let kind = kindRows(record.kind), contribution = kind.contribution, registry = editor.registry
        let isListed = !record.isOpaque && (contribution?.isListed(record) ?? true)
        let ownsBoard = registry.ownsShowableBoard(record)
        #if DEBUG
        rowsMade += 1
        #endif
        return ShapeRow(record: record, isListed: isListed,
                        parent: contribution?.parent?(record) ?? registry.container(of: record, in: document),
                        ownsBoard: ownsBoard, startsExpanded: !ownsBoard && registry.isContainer(record),
                        row: resolvedRow(of: record, kind: kind), symbol: kind.symbol,
                        marks: marked ? marks(of: record, isListed: isListed, kind: kind) : [])
    }

    /// The shape's row as its kind makes it, else its kind's label, called what `ContentsTitles`
    /// names it if it's a `ContentsLabel`. A kind whose rows another plugin names has its label as a
    /// placeholder, dimmed until the shape is named, as an untitled note's is: twenty unnamed
    /// shapes of a kind don't read as named after it. A kind nobody names (an arrow) has its label at
    /// full strength: it's all such a shape is called.
    private func resolvedRow(of record: AnyShapeRecord, kind: KindRows) -> ResolvedRow {
        let fallback = kind.title == nil ? ContentsLabel(kind.name) : ContentsLabel("", placeholder: kind.name)
        let row = kind.contribution?.row?(record, ContentsContext(editor: editor)) ?? ResolvedRow(fallback)
        if let label = row.label, let title = kind.title?(record), !title.allSatisfy(\.isWhitespace) {
            return ResolvedRow(label.retitled(title))
        }
        return row
    }

    /// The marks of a shape's row: none for a shape that isn't listed.
    private func marks(of record: AnyShapeRecord, isListed: Bool, kind: KindRows) -> [ContentsMark] {
        guard isListed, !kind.marks.isEmpty else { return [] }
        let context = ContentsContext(editor: editor)
        return kind.marks.compactMap { $0.mark(record, context) }
    }

    private func kindRows(_ kind: ShapeKind) -> KindRows {
        if let found = kinds[kind] { return found }
        let registry = editor.registry
        let label = registry.label(of: kind)
        let markable = ContentsKind(kind: kind, registry: registry)
        let found = KindRows(contribution: registry.contributions(to: ContentsRows.self, for: kind).first,
                             title: registry.contributions(to: ContentsTitles.self, for: kind).first,
                             marks: registry.contributions(to: ContentsMarks.self, for: kind).filter { $0.appliesTo(markable) },
                             name: label.name, symbol: label.systemImage ?? ContentsSymbolKey.defaultValue)
        kinds[kind] = found
        return found
    }
}

extension ContentsState: EditorService {
    /// Forgets the rows of the shapes the commit touched, for the next read to make again and
    /// place, but for those it only moved (`ChangeSet.moved`: a drag's every event, a container
    /// carrying all it holds), whose rows say what they are and not where, so they stay, noted for
    /// the next read to follow them (`followMoves`); and notes the shapes whose rows or marks it may
    /// change though it doesn't touch them (as the rows' and the marks' contributors say), for the
    /// next read to make their rows again or read their marks again. Each scope's listing notes
    /// them all.
    public func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        changesHeard = editor.revision
        if !changes.onlyMoves { lastBeyondMoves = editor.revision }
        if heardRevision != editor.revision {          // else read since, and caught up
            heardRevision = editor.revision
            let moved = changes.moved
            let forgotten: Set<ShapeID>
            if moved.isEmpty {
                forgotten = changes.shapeIDs
            } else {
                movedSinceRead.formUnion(moved)
                let onlyMoved = changes.added.isEmpty && changes.removed.isEmpty && changes.changed.count == moved.count
                forgotten = onlyMoved ? [] : changes.shapeIDs.subtracting(moved)
            }
            for id in forgotten {
                rows[id] = nil
                remakes.remove(id)
                remarks.remove(id)
            }
            note(forgotten)
        }
        guard readsOtherShapes else { return }
        if !kept.boards.isEmpty {
            for id in changes.shapeIDs { touchedAway[id] = editor.revision }
            for id in changes.elsewhere { touchedAway[id] = editor.revision }
        }
        noteAffected(by: changes)
    }

    /// Whether some row or mark reads more than its shape (`affected`).
    private var readsOtherShapes: Bool { !rowAffected.isEmpty || !markAffected.isEmpty }

    /// The shapes commits only moved since the rows were last read, as the rows are read (or kept
    /// for going back to their board): each kept row stays, the same object, holding its shape as it
    /// is now, since a row says what a shape is, never where (its kind's row, `when`, `nestedUnder`,
    /// its name; and its container, which a move never changes); and those listed with marks have
    /// their marks read again, since a mark from a service may follow where a shape is (a
    /// validation rule that doesn't ignore moves), each scope's listing noting them. A row made
    /// again since, or gone, needs nothing.
    private func followMoves() {
        guard !movedSinceRead.isEmpty else { return }
        let document = editor.document
        var marked: Set<ShapeID> = []
        for id in movedSinceRead {
            guard let row = rows[id], let record = document[id] else { continue }
            row.follow(record)
            if row.isListed, !kindRows(record.kind).marks.isEmpty { marked.insert(id) }
        }
        movedSinceRead = []
        remarks.formUnion(marked)
        note(marked)
    }

    /// Notes the shapes whose rows or marks `changes` may change though it doesn't touch them (as
    /// the rows' and the marks' contributors say), for the next read to make their rows again or
    /// read their marks again.
    private func noteAffected(by changes: ChangeSet) {
        // A shape without a kept row gets its row and marks when its row is made.
        let context = ContentsContext(editor: editor)
        if !rowAffected.isEmpty {
            let remade = rowAffected.reduce(into: Set<ShapeID>()) { $0.formUnion($1(changes, context)) }
                .filter { id in rows[id].map { kindRows($0.record.kind).readsOtherShapes } ?? false }
            remakes.formUnion(remade)
            note(remade)
        }
        if !markAffected.isEmpty {
            let remarked = markAffected.reduce(into: Set<ShapeID>()) { $0.formUnion($1(changes, context)) }.filter { rows[$0] != nil }
            remarks.formUnion(remarked)
            note(remarked)
        }
    }

    /// Keeps the board left's rows, and its listing of every row, for going back to it.
    public func boardWillChange(from old: BoardID, to new: BoardID, in editor: CanvasEditor) {
        guard old != new else { return }            // a file put in place over the board shown
        catchUp()
        followMoves()
        catchUpAway()
        kept.keep(Kept(rows: rows, remakes: remakes, remarks: remarks, board: board, revision: editor.revision), for: old, in: editor)
        leftAt[old] = editor.revision
    }

    /// Lists the board shown: what was kept of it, if it's as it was left (and, when some rows read
    /// other shapes, no file was put in place since), else nothing yet (the next read makes its rows). A scope of some shapes pinned (`select`, `showAll`) and the last scope's
    /// listing were the board left's, and go.
    public func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        // A file put in place says nothing of what it changed on the boards kept, so rows that
        // read other boards can't tell what they missed: they're made again.
        if change.isFileReplaced, readsOtherShapes {
            kept.removeAll()
            touchedAway = [:]
        }
        let taken = kept.take(for: change.to, in: editor)
        movedSinceRead = []                 // the board left's, followed as it was kept
        rows = taken?.rows ?? [:]
        remakes = taken?.remakes ?? []
        remarks = taken?.remarks ?? []
        board = taken?.board
        filtered = nil
        rowHover = nil                  // the board left's, whose hover Selection let go of
        if pin != nil { pin = nil }
        heardRevision = editor.revision
        missed = []
        if let taken, readsOtherShapes {
            missed = Set(touchedAway.lazy.filter { $0.value > taken.revision }.map(\.key))
        }
        forgetTouchedAway()
        let path = Set(editor.boardPath)
        outlines = outlines.filter { path.contains($0.key) }
        // A switch names nothing anew; a file put in place with it may have renamed anything.
        changesHeard = editor.revision
        if change.isFileReplaced { lastBeyondMoves = editor.revision }
    }

    /// Keeps what was touched away only as far back as the board kept longest ago was left.
    private func forgetTouchedAway() {
        let boards = kept.boards
        leftAt = leftAt.filter { boards.contains($0.key) }
        guard !touchedAway.isEmpty else { return }
        guard let oldest = leftAt.values.min() else { return touchedAway = [:] }
        touchedAway = touchedAway.filter { $0.value > oldest }
    }

    /// Tells each scope's listing to look at these shapes' rows again on its next read.
    private func note(_ ids: Set<ShapeID>) {
        guard !ids.isEmpty else { return }
        board?.pending.formUnion(ids)
        filtered?.pending.formUnion(ids)
    }
}

extension CanvasEditor {
    /// The table of contents' state; nil without TableOfContentsPlugin.
    public var tableOfContents: ContentsState? { service(ContentsState.self) }
}

extension ChangeSet {
    /// Whether the commit only moved shapes on its board (a drag's every event, its undo): it named
    /// nothing anew, so what a row reads of other shapes is as it was.
    var onlyMoves: Bool {
        added.isEmpty && removed.isEmpty && changed == moved && elsewhere.isEmpty && boardsReached.isEmpty && !replacedDocument
    }
}

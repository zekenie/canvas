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
    /// The symbol of the tool that places the kind, which a `ContentsLabel` without its own shows.
    public var symbol: String { row.symbol }
    /// The dots at the row's trailing end (`ContentsMarks`), in contribution order.
    public var marks: [ContentsMark] { row.marks }
    /// The rows nested under this one, in document order; nil when there are none, so the list
    /// shows no disclosure triangle.
    public internal(set) var children: [ContentsEntry]?
    /// The shape's row, as its kind made it for the shape as listed, with its marks: the same
    /// object until the shape or its marks change.
    var row: ShapeRow

    init(row: ShapeRow, children: [ContentsEntry]?) {
        id = row.id
        self.row = row
        self.children = children
    }
}

/// A shape's row as its kind made it for one version of the shape, with its marks and what places
/// it in the list. Made again only when the shape changes, copied with its new marks when they
/// change while the shape doesn't, and shared by every scope that lists it.
@MainActor
final class ShapeRow {
    let record: AnyShapeRecord
    /// Whether the kind lists the shape (`when`).
    let isListed: Bool
    /// The shape the kind nests it under (`nestedUnder`), listed or not.
    let parent: ShapeID?
    let view: AnyView
    let label: ContentsLabel?
    let symbol: String
    let marks: [ContentsMark]
    /// Where the shape is in the stack, which orders rows among their siblings. Every shape in a
    /// document has a key.
    let key: StackingKey

    init(record: AnyShapeRecord, isListed: Bool, parent: ShapeID?, row: ResolvedRow, symbol: String, marks: [ContentsMark]) {
        self.record = record
        self.isListed = isListed
        self.parent = parent
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

    var id: ShapeID { record.id }
}

/// Per editor (so per window): what the table of contents lists, and each shape's row, made again
/// only when that shape changes. What a commit changed is all a read after it redoes: the rows of
/// the shapes its change set names, and where those nest, and the rows and marks of the shapes
/// whose rows and marks it may change though it doesn't change them (`affected`). It lists the
/// board shown; the rows and the listing of every row of the boards shown last are kept for going
/// back to them, and taken back while those boards are as they were left (`BoardStash`). What
/// changed on other boards meanwhile is handed to `affected` on going back (as `ChangeSet.elsewhere`),
/// so a row that reads a shape on another board that was renamed or deleted since is made again.
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

    /// How a kind's shapes get their rows.
    private struct KindRows {
        let contribution: ContentsContribution?
        /// What its rows are called (`ContentsTitles`): the kind's own name for them, else every kind's.
        let title: ContentsTitles.Contribution?
        /// What marks its rows (`ContentsMarks`): the kind's own, then every kind's.
        let marks: [ContentsMarkContribution]
        /// The label and symbol of the tool that places the kind, else its name and a dashed square.
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
        catchUpAway()
        guard let scope else {
            if board == nil || !board!.update(row: row(of:)) { board = listing(of: nil) }
            return board!.entries
        }
        let ids = Set(scope)
        if filtered?.scope != ids || !filtered!.update(row: row(of:)) { filtered = listing(of: ids) }
        return filtered!.entries
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
        rows = rows.filter { document[$0.key] == $0.value.record }
        remakes = rowAffected.isEmpty ? remakes.filter { rows[$0] != nil }
            : Set(rows.lazy.filter { self.kindRows($0.value.record.kind).readsOtherShapes }.map(\.key))
        remarks = markAffected.isEmpty ? remarks.filter { rows[$0] != nil } : Set(rows.keys)
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
    /// nothing.
    public func select(_ ids: Set<ShapeID>) {
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
        guard ids.count == 1, let id = ids.first, editor.canOpen(id) else { return }
        if editor.selectedShapeIDs != [id] { select(ids) }
        editor.open(id)
    }

    /// Lists every shape, keeping the selection, until the selection next changes.
    public func showAll() {
        pin = Pin(scope: nil, selectionRevision: editor.selectionRevision)
    }

    // MARK: Hovering

    /// The pointer is on the shape's row (and, called again as it moves there, still is): the
    /// shape is hovered (`editor.hovered`), as though the pointer were on it on the canvas.
    public func hover(_ id: ShapeID) { editor.hovered = id }

    /// The pointer left the shape's row, or the row went away: the shape isn't hovered any more.
    /// Leaves any other shape's hover, which the canvas or another row may have set since.
    public func endHover(_ id: ShapeID) {
        if editor.hovered == id { editor.hovered = nil }
    }

    /// Whether the shape's row shows as hovered: its shape is hovered, whether the pointer is on the
    /// row or on the shape on the canvas, and isn't selected (as the canvas outlines the hover only
    /// on an unselected shape). Observing it hears only this shape's hover change, and the selection
    /// only while the shape is hovered, so the hover moving down the list redraws the row it leaves
    /// and the row it reaches, not every row.
    public func isHovered(_ id: ShapeID) -> Bool { editor.isHovered(id) && !editor.isSelected(id) }

    // MARK: Rows

    /// The shape's row: its kind's, else its tool's label; called what `ContentsTitles` names it, if
    /// it's a `ContentsLabel`; with its marks. Made again after the shape changes; made again when a
    /// commit may change it without changing the shape (`affected`), and kept unless its label
    /// changed; and copied with new marks when a commit changes them without changing the shape; nil
    /// once it's gone. A shape the board keeps aside isn't listed, whatever its kind: nothing on the
    /// canvas sees it.
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
        guard let record = editor.document[id] else { return nil }
        let kind = kindRows(record.kind), contribution = kind.contribution
        let isListed = !record.isOpaque && (contribution?.isListed(record) ?? true)
        #if DEBUG
        rowsMade += 1
        #endif
        let made = ShapeRow(record: record, isListed: isListed, parent: contribution?.parent?(record), row: resolvedRow(of: record, kind: kind),
                            symbol: kind.symbol, marks: marks(of: record, isListed: isListed, kind: kind))
        rows[id] = made
        return made
    }

    /// The shape's row as its kind makes it, else its tool's label, called what `ContentsTitles`
    /// names it if it's a `ContentsLabel`.
    private func resolvedRow(of record: AnyShapeRecord, kind: KindRows) -> ResolvedRow {
        let row = kind.contribution?.row?(record, ContentsContext(editor: editor)) ?? ResolvedRow(ContentsLabel(kind.name))
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
        let tool = registry.tools.first { $0.id == ToolID(placing: kind) }
        let found = KindRows(contribution: registry.contributions(to: ContentsRows.self, for: kind).first,
                             title: registry.contributions(to: ContentsTitles.self, for: kind).first,
                             marks: registry.contributions(to: ContentsMarks.self, for: kind),
                             name: tool?.label ?? kind.rawValue, symbol: tool?.systemImage ?? ContentsSymbolKey.defaultValue)
        kinds[kind] = found
        return found
    }
}

extension ContentsState: EditorService {
    /// Forgets the rows of the shapes the commit touched, for the next read to make again and
    /// place, and notes the shapes whose rows or marks it may change though it doesn't touch them
    /// (as the rows' and the marks' contributors say), for the next read to make their rows again
    /// or read their marks again. Each scope's listing notes them all.
    public func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        let touched = changes.shapeIDs
        if heardRevision != editor.revision {          // else read since, and caught up
            heardRevision = editor.revision
            for id in touched {
                rows[id] = nil
                remakes.remove(id)
                remarks.remove(id)
            }
            note(touched)
        }
        guard readsOtherShapes else { return }
        if !kept.boards.isEmpty {
            for id in touched { touchedAway[id] = editor.revision }
            for id in changes.elsewhere { touchedAway[id] = editor.revision }
        }
        noteAffected(by: changes)
    }

    /// Whether some row or mark reads more than its shape (`affected`).
    private var readsOtherShapes: Bool { !rowAffected.isEmpty || !markAffected.isEmpty }

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
        rows = taken?.rows ?? [:]
        remakes = taken?.remakes ?? []
        remarks = taken?.remarks ?? []
        board = taken?.board
        filtered = nil
        if pin != nil { pin = nil }
        heardRevision = editor.revision
        missed = []
        if let taken, readsOtherShapes {
            missed = Set(touchedAway.lazy.filter { $0.value > taken.revision }.map(\.key))
        }
        forgetTouchedAway()
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

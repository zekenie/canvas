import Canvas
import CoreGraphics
import Foundation
import Find

// Folds: what the person asked each shape written as lines to show (⌃⌘↑ to its marked rows, ⌃⌘↓ back to every row), kept
// per file on this Mac with its view (a view value), never in the file and never a step. The lines a folded shape shows are
// a provided layout input (`LineRowsLayout.shown`), worked out from its record and its fold as it's laid out, so a commit
// to a folded table keeps it folded, and every reader of its layout (its frame, its render, its rows' rects and so the
// arrows bound to them, culling, the minimap) follows the fold. A fold changes no record: unfolding may overlap a
// neighbor, as nothing is settled again for a view.

/// The folds of an editor's file: what the person asked for per shape, the rows shown though folded (peeks: a row just
/// dropped, Find's hits while Find is open), never remembered, and the lines each folded shape shows.
@MainActor
public final class RowFolds {
    unowned let editor: CanvasEditor
    /// What the person asked for, per shape: shapes gone from the file keep theirs for the session (an undo brings them
    /// back folded), but aren't saved.
    private var folds: [ShapeID: RowFold] = [:]
    /// The folded shapes in the order they were last folded, the latest last: what the saved cap keeps.
    private var order: [ShapeID] = []
    /// Rows shown in place though folded, asked for by a plugin (`peek`), until let go.
    private var peeks: [ShapeID: Set<PartID>] = [:]
    /// Rows shown in place while Find is open and they hold its hits (`FindState.fieldsHit`).
    private var findPeeks: [ShapeID: Set<PartID>] = [:]
    /// +1 for every change to what a shape shows, so what's kept of a shape's lines is let go.
    private var generation = 0
    /// +1 for every fold, unfold, "+N ›" opened and header closed or opened: a line a fold drew is one of an epoch, so the
    /// keys' focus on a line that was opened does not come back on the next "+N ›" the same shape draws.
    public private(set) var epoch = 0
    /// Each folded shape's lines, as the editor's own reading lays it out, while the file (`editor.revision`) and the folds
    /// (`generation`) are as they were.
    private var kept: [ShapeID: (revision: Int, generation: Int, shown: RowsShown?)] = [:]

    /// The view value folds are saved in: the shapes folded to their marks and the closed headers of each, the latest
    /// folded last.
    static let memory = ViewValueKey<SavedFolds>("line-rows.folds")
    /// How many folds a file saves: the latest folded.
    public static let savedLimit = 2000

    /// The folds as saved: a list of ids for the common case (folded to marks), so a thousand folds encode in a moment.
    struct SavedFolds: Codable, Hashable {
        /// Every folded shape, the latest folded last.
        var shapes: [ShapeID] = []
        /// Those not folded to their marks (only headers closed).
        var unmarked: [ShapeID] = []
        /// The closed headers of the shapes that have any.
        var closed: [ShapeID: [PartID]] = [:]
    }

    init(editor: CanvasEditor) {
        self.editor = editor
        load()
        editor.find?.whenResultsChange { [weak self] in self?.findDidChange() }
    }

    // MARK: Asking

    /// What the person asked `id` to show; nil for every row.
    public func fold(of id: ShapeID) -> RowFold? { folds[id] }

    /// Whether `id` is folded (to its marks, or a header closed).
    public func isFolded(_ id: ShapeID) -> Bool { folds[id] != nil }

    /// Every folded shape, in the order they were folded.
    public var folded: [ShapeID] { order }

    /// The lines `record` shows, as `reading` lays it out: nil for a shape showing every row (unfolded, edited unless the
    /// reading is at rest (`LayoutReading.isResting`: a fold isn't peeled back for what a step writes), of a kind
    /// not written as lines). What `LineRowsLayout.shown` is provided from; kept for the editor's own reading.
    public func shown(of record: AnyShapeRecord, in reading: LayoutReading) -> RowsShown? {
        guard reading.isResting || editor.editingShapeID != record.id else { return nil }
        return lines(of: record, in: reading)
    }

    /// The lines `id` shows folded, though it's being edited (and so laid out showing every row): what a press that began
    /// the editing was made against. Nil for a shape that is not folded.
    public func foldedLines(of id: ShapeID) -> RowsShown? {
        guard let record = editor.document[id], let reading = editor.shapeContext.reading else { return nil }
        return lines(of: record, in: reading)
    }

    private func lines(of record: AnyShapeRecord, in reading: LayoutReading) -> RowsShown? {
        guard let fold = folds[record.id], let kind = reading.registry.lineRows(of: record.kind) else { return nil }
        let committed = reading.isCommitted
        if committed, let known = kept[record.id], known.revision == editor.revision, known.generation == generation { return known.shown }
        guard let rows = kind.rows(record) else { return nil }
        let peeked = (peeks[record.id] ?? []).union(findPeeks[record.id] ?? [])
        let shown = RowsShown.make(rows: rows, fold: fold, marked: fold.toMarked ? kind.marked(record, reading) : [], peeked: peeked)
        if committed { kept[record.id] = (editor.revision, generation, shown) }
        return shown
    }

    // MARK: Folding

    /// What ⌃⌘↑ asks of `id`: folded to its marked rows, and every header closed (an API's path prefixes, each showing its count,
    /// E8; rows under no header fold to the marks). Nil for a shape not written as lines.
    func foldAsked(of id: ShapeID) -> RowFold? {
        guard let record = editor.document[id], let rows = editor.registry.lineRows(of: record.kind)?.rows(record) else { return nil }
        return RowFold(toMarked: true, closed: Set(rows.filter(\.isHeader).map(\.id)))
    }

    /// Whether `id` is folded as far as ⌃⌘↑ folds it: to its marks, every header closed.
    public func isFoldedWhole(_ id: ShapeID) -> Bool {
        guard let fold = folds[id], let asked = foldAsked(of: id) else { return false }
        return fold.toMarked && asked.closed.isSubset(of: fold.closed)
    }

    /// Folds `ids` as ⌃⌘↑ does: to their marked rows, every header closed. Laid out again at once, and saved with the file's view.
    /// No step. Returns those it folded: not the ones folded so already.
    @discardableResult
    public func fold(_ ids: some Sequence<ShapeID>) -> [ShapeID] {
        var changed: [ShapeID] = []
        for id in ids {
            guard let asked = foldAsked(of: id), !isFoldedWhole(id) else { continue }
            var fold = folds[id] ?? RowFold()
            fold.toMarked = true
            fold.closed.formUnion(asked.closed)
            folds[id] = fold
            changed.append(id)
        }
        guard !changed.isEmpty else { return [] }
        // The latest folded last, once each: one pass however many are folded.
        let moved = Set(changed)
        order.removeAll { moved.contains($0) }
        order += changed
        didChange(changed)
        return changed
    }

    /// Shows every row of `ids` again (⌃⌘↓): its marks' fold and its closed headers let go. Returns those it unfolded: not the ones
    /// showing every row already.
    @discardableResult
    public func unfold(_ ids: some Sequence<ShapeID>) -> [ShapeID] {
        let changed = ids.filter { folds.removeValue(forKey: $0) != nil }
        guard !changed.isEmpty else { return [] }
        let gone = Set(changed)
        order.removeAll { gone.contains($0) }
        didChange(changed)
        return changed
    }

    /// Puts back `fold` on `id`, as `unfold` let it go: for a change that was refused.
    func restore(_ fold: RowFold, of id: ShapeID) {
        guard !fold.isEmpty, folds[id] == nil else { return }
        folds[id] = fold
        order.removeAll { $0 == id }
        order.append(id)
        didChange([id])
    }

    /// Opens the "+N ›" line of `id`: every row its marks' fold hid shows, its closed headers stay closed.
    public func openMore(of id: ShapeID) {
        guard var fold = folds[id], fold.toMarked else { return }
        fold.toMarked = false
        if fold.isEmpty {
            unfold([id])
        } else {
            folds[id] = fold
            didChange([id])
        }
    }

    /// Closes or opens header `header` of `id`.
    public func setClosed(_ isClosed: Bool, header: PartID, of id: ShapeID) {
        var fold = folds[id] ?? RowFold()
        guard fold.closed.contains(header) != isClosed else { return }
        if isClosed { fold.closed.insert(header) } else { fold.closed.remove(header) }
        if fold.isEmpty {
            unfold([id])
            return
        }
        if folds[id] == nil { order.append(id) }
        folds[id] = fold
        didChange([id])
    }

    /// Shows `rows` of `id` in place though folded (a row just dropped), until `release(of:)`: never remembered.
    public func peek(_ rows: Set<PartID>, of id: ShapeID) {
        guard peeks[id] != rows else { return }
        peeks[id] = rows.isEmpty ? nil : rows
        if folds[id] != nil { relayOut([id]) }
    }

    /// Lets go of what `peek` showed of `id`.
    public func release(of id: ShapeID) { peek([], of: id) }

    /// The marks of these shapes may have changed with no commit to them (a key drawn or deleted reads as a table's mark):
    /// those folded are laid out again, once the change has settled.
    public func marksMayHaveChanged(_ ids: some Sequence<ShapeID>) {
        guard !folds.isEmpty else { return }
        let folded = ids.filter { folds[$0]?.toMarked == true }
        guard !folded.isEmpty else { return }
        editor.onceSettled { [weak self] in self?.relayOut(folded) }
    }

    /// Editing is about to begin on `id`: a folded shape shows every row while it's edited.
    public func editingWillBegin(_ id: ShapeID) {
        if folds[id] != nil { relayOut([id]) }
    }

    private func didChange(_ ids: [ShapeID]) {
        guard !ids.isEmpty else { return }
        epoch += 1
        let peeking = editor.find?.isActive == true ? findDidChange(relayingOut: false) : []
        relayOut(ids + peeking)
        save()
    }

    /// What `ids` show changed: let go of what's kept and lay them out again (the arrows bound to them follow, as readers
    /// of their geometry).
    private func relayOut(_ ids: [ShapeID]) {
        guard !ids.isEmpty else { return }
        generation += 1
        for id in ids { kept[id] = nil }
        editor.shapesDidChangeLayout(ids)
        for listener in lineListeners { listener(ids) }
    }

    /// What hears that shapes' lines changed with no commit (a fold, a peek, editing begun or ended): the bundles of their
    /// connections.
    private var lineListeners: [@MainActor ([ShapeID]) -> Void] = []

    /// Runs `body` with the shapes each time what they show changes with no commit to them.
    func whenLinesChange(_ body: @escaping @MainActor ([ShapeID]) -> Void) {
        lineListeners.append(body)
    }

    // MARK: Find

    /// Find's results changed (or it opened or closed): each folded shape shows the rows holding hits, while it's open,
    /// laid out again once what changed them has settled. Returns the shapes whose peeks changed.
    @discardableResult
    private func findDidChange(relayingOut: Bool = true) -> [ShapeID] {
        guard !folds.isEmpty || !findPeeks.isEmpty else { return [] }
        let find = editor.find, isOpen = find?.isActive == true
        var changed: [ShapeID] = []
        for id in Set(folds.keys).union(findPeeks.keys) {
            var hit: Set<PartID> = []
            if isOpen, let find, folds[id] != nil, find.hasHits(id) {
                // The field of a row's text is its id's UUID: read as it is. A row whose hits its kind draws elsewhere (an
                // endpoint's in its group's prefix, on the header) stays folded.
                let record = editor.shape(inFile: id), kind = record.flatMap { editor.registry.lineRows(of: $0.kind) }
                for (field, ranges) in find.rangesHit(of: id) {
                    guard let part = UUID(uuidString: field).map(PartID.init) else { continue }
                    if let record, let kind, !kind.peeks(record, part, ranges) { continue }
                    hit.insert(part)
                }
            }
            guard hit != (findPeeks[id] ?? []) else { continue }
            findPeeks[id] = hit.isEmpty ? nil : hit
            changed.append(id)
        }
        guard !changed.isEmpty else { return [] }
        if relayingOut {
            generation += 1
            editor.onceSettled { [weak self] in self?.relayOut(changed) }
        }
        return changed
    }

    /// The rows of `id` Find's hits show though folded.
    public func findPeeks(of id: ShapeID) -> Set<PartID> { findPeeks[id] ?? [] }

    // MARK: Remembered

    /// The folds the file's view keeps (`RowFolds.memory`): the shapes in the file, the latest `savedLimit` folded.
    private func save() {
        var saved = SavedFolds()
        for id in order.filter({ editor.shape(inFile: $0) != nil }).suffix(Self.savedLimit) {
            guard let fold = folds[id] else { continue }
            saved.shapes.append(id)
            if !fold.toMarked { saved.unmarked.append(id) }
            if !fold.closed.isEmpty { saved.closed[id] = Array(fold.closed) }
        }
        editor.setViewValue(Self.memory, saved.shapes.isEmpty ? nil : saved)
    }

    /// Takes the folds the file's view kept: those of shapes gone are dropped as they're read.
    private func load() {
        let saved = editor.viewValue(Self.memory) ?? SavedFolds()
        let unmarked = Set(saved.unmarked)
        folds = [:]
        order = []
        for id in saved.shapes where folds[id] == nil {
            let fold = RowFold(toMarked: !unmarked.contains(id), closed: Set(saved.closed[id] ?? []))
            guard !fold.isEmpty else { continue }
            folds[id] = fold
            order.append(id)
        }
    }
}

extension RowFolds: EditorService {
    /// A shape edited shows every row: its fold comes back as editing ends.
    public func editingDidEnd(_ id: ShapeID, in editor: CanvasEditor) {
        if folds[id] != nil { relayOut([id]) }
    }

    /// A folded shape gone from the file, or back (an undo), changes what's saved.
    public func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        guard !folds.isEmpty else { return }
        let touched = changes.added.union(changes.removed).union(changes.elsewhere)
        if touched.contains(where: { folds[$0] != nil }) { save() }
    }

    /// Another file put in place: its folds are what the view kept of it.
    public func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        guard change.isFileReplaced, !folds.isEmpty else { return }
        save()
    }

    /// The host handed back what an earlier session saved: those folds, and what they change laid out again.
    public func viewValuesDidChange(in editor: CanvasEditor) {
        let before = Set(folds.keys)
        load()
        findPeeks = [:]
        relayOut(Array(before.union(folds.keys)))
    }
}

extension CanvasEditor {
    /// The file's folds; nil without LineRows.
    public var rowFolds: RowFolds? { service(RowFolds.self) }
}

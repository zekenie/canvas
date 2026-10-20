import Canvas
import Validation

/// Titles' warning, as a Validation rule: a warning on each shape whose title another shape in
/// the file also has (“Checkout” is another shape’s title too.), about its `title` where Titles
/// keeps it. A title is what names a shape for everything that finds one by it (`canvas draw`, a
/// query, the `@` picker), and two shapes called one thing are found by it no longer: `draw`
/// refuses the title. Titles as Titles reads them (`registry.title(of:)`: named, or derived), folded, compared exactly; an untitled note's first line is no title. On every
/// board the editor can show, but shapes kept aside. A warning, never an error: each shape is fine
/// alone.
///
/// The titles are the file's, in an index of its own (`TitleIndex`), read as the editor opens
/// and kept up to date by each commit, wherever it changed a title, so the rule reads no other
/// shape: it names, with `affected`, the shapes a commit gives a title's first other holder or takes
/// its last from, which Validation checks again, on the board shown or once theirs is. Where shapes
/// are is nothing it reads, so it ignores moves. Writes that have not committed (a run of `canvas draw`)
/// are answered too: the rule reads the titles as the run leaves them (`isShared(_:by:in:)`: the
/// committed holders the run has not written, and what it wrote) and `touches` names the other holders
/// of a title the run gives a shape or takes from one, so a run that gives a shape the title of a shape
/// on another board warns of both. A plugin of its own, so a list can have Titles
/// without Validation (the registry refuses its rule where Validation isn't installed).
public struct TitleValidationPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { "title-validation" }

    #if DEBUG
    /// How many titled shapes the rule has checked in this process, debug builds only: tests hold a
    /// move to checking none.
    @MainActor public private(set) static var titlesChecked = 0
    #endif

    public func register(into registrar: inout PluginRegistrar) {
        registrar.service { TitleIndex(editor: $0) }
        registrar.forShapes(adopting: .titled) { titled in
            titled.validate(ignoringMoves: true, affected: { changes, editor in
                editor.service(TitleIndex.self)?.affected(by: changes) ?? []
            }, touches: { changes, shapes in
                // Writes that have not committed (a run's): the other holders of a title they give a shape or take from one.
                guard let reading = shapes.reading, let index = reading.service(TitleIndex.self) else { return [] }
                return index.touched(by: changes, reading: reading)
            }) { shape, context in
                guard let title = context.registry.title(of: shape) else { return [] }
                // Without an editor (a run's check, before it commits) the index is asked through the reading the shapes have,
                // for the titles as the run leaves them.
                let shared: Bool
                if let index = context.service(TitleIndex.self) {
                    shared = index.isShared(title, by: shape.id)
                } else if let reading = context.reading, let index = reading.service(TitleIndex.self) {
                    shared = index.isShared(title, by: shape.id, in: reading)
                } else {
                    return []
                }
                #if DEBUG
                Self.titlesChecked += 1
                #endif
                guard shared else { return [] }
                let named = context.registry.properties(for: shape.kind).contains(TitleProperty.key)
                return [.warning("“\(title)” is another shape’s title too.", field: named ? TitleProperty.key.rawValue : nil)]
            }
        }
    }
}

/// Every title in the file and the shapes it names, on every board the editor can show, but shapes
/// kept aside: read whole as the editor opens (and again for a file put in place), as Mentions' catalog
/// is, so no check pays for it (a query's slice), then kept up to date by each commit, for what it
/// changed on any board, never for a move. It never transacts.
@MainActor
final class TitleIndex {
    private unowned let editor: CanvasEditor
    /// The shapes each title names.
    private var holders: [String: Set<ShapeID>] = [:]
    /// Each titled shape's title.
    private var titles: [ShapeID: String] = [:]
    /// The shapes the last commit heard gave a title's first other holder, or took its last from,
    /// and those still in the file whose title it changed: whose warning it may change.
    private var lastAffected: Set<ShapeID> = []

    init(editor: CanvasEditor) {
        self.editor = editor
        read()
    }

    /// Whether a shape other than `id` is called `title`.
    func isShared(_ title: String, by id: ShapeID) -> Bool {
        guard let named = holders[title] else { return false }
        return named.count > 1 || !named.contains(id)
    }

    /// What a run has written, by the titles its shapes have now: made once for each state of a run's log.
    private var run: (id: Int, writes: Int, revision: Int, written: Set<ShapeID>, holders: [String: Set<ShapeID>])?

    /// The run's writes filed by title, for a reading that hasn't committed: every shape it wrote, and under each title the
    /// written shapes called that now. O(its writes), once for each state of the log.
    private func written(in reading: LayoutReading) -> (written: Set<ShapeID>, holders: [String: Set<ShapeID>]) {
        if let run, run.id == reading.runID, run.writes == reading.writeCount, run.revision == editor.revision { return (run.written, run.holders) }
        var written: Set<ShapeID> = [], now: [String: Set<ShapeID>] = [:]
        for id in reading.changes where written.insert(id).inserted {
            if let record = reading.shape(inFile: id), let title = title(of: record) { now[title, default: []].insert(id) }
        }
        run = (reading.runID, reading.writeCount, editor.revision, written, now)
        return (written, now)
    }

    /// Whether a shape other than `id` is called `title` as a reading that hasn't committed has the file: the committed
    /// holders the run has not written, and the shapes it wrote that are called that now.
    func isShared(_ title: String, by id: ShapeID, in reading: LayoutReading) -> Bool {
        guard !reading.isCommitted else { return isShared(title, by: id) }
        let run = written(in: reading)
        if run.holders[title]?.contains(where: { $0 != id }) == true { return true }
        // A committed holder counts if the run has not taken it (deleted, or with its board).
        return holders[title]?.contains(where: { $0 != id && !run.written.contains($0) && reading.shape(inFile: $0) != nil }) ?? false
    }

    /// The shapes whose warning writes that have not committed may change though they do not write them: for each
    /// written shape whose title is another now, the committed holders of the title it has (they share it now) and,
    /// where one holder of the title it had is left, that one (it shares it no longer). O(the writes).
    func touched(by changes: ChangeSet, reading: LayoutReading) -> Set<ShapeID> {
        guard !reading.isCommitted else { return [] }
        let run = written(in: reading)
        var found: Set<ShapeID> = []
        func look(_ id: ShapeID) {
            let before = titles[id]
            let now = reading.shape(inFile: id).flatMap(title(of:))
            guard before != now else { return }
            if let now, let others = holders[now] { for other in others where !run.written.contains(other) { found.insert(other) } }
            if let before, let others = holders[before] {
                let left = others.filter { !run.written.contains($0) }
                if left.count == 1, run.holders[before]?.isEmpty != false { found.formUnion(left) }
            }
        }
        for id in changes.added { look(id) }
        for id in changes.changed where !changes.moved.contains(id) { look(id) }
        for id in changes.removed { look(id) }
        for id in changes.elsewhere { look(id) }
        return found
    }

    /// The shapes a commit may change the warning of: those still in the file whose title it
    /// changed, and those it gave a title's first other holder or took its last from (never what it
    /// deleted, so a subboard's deletion names none of what its boards held). Asked once every
    /// service has the commit; asked again for the same commit, the same.
    func affected(by changes: ChangeSet) -> Set<ShapeID> {
        lastAffected
    }

    /// Files the titles a commit changed, noting whose warning that changes.
    private func follow(_ changes: ChangeSet) {
        lastAffected = []
        guard !changes.shapeIDs.isEmpty || !changes.elsewhere.isEmpty else { return }
        // The file read once, each board's showing asked once: a subboard's deletion hands it every
        // shape its boards held (`elsewhere`). A shape seen twice is filed once.
        let (document, file) = editor.withoutObservingDocument { (editor.document, editor.file) }
        let owning = editor.registry.boardOwningKinds
        var showable: [BoardID: Bool] = [:]
        func follow(_ id: ShapeID, elsewhere: Bool = false) {
            let record: AnyShapeRecord?
            if !elsewhere, let shown = document[id] {
                record = shown
            } else if let board = file.board(containing: id) {
                let shows = showable[board] ?? file.canShow(board, boardOwningKinds: owning)
                showable[board] = shows
                record = shows ? file[board][id] : nil
            } else {
                // Gone from the file: nothing to do for one that had no title.
                guard titles[id] != nil else { return }
                record = nil
            }
            retitle(id, to: record.flatMap(title(of:)), isGone: record == nil)
        }
        for id in changes.removed { follow(id) }
        for id in changes.added where !changes.moved.contains(id) { follow(id) }
        for id in changes.changed where !changes.moved.contains(id) { follow(id) }
        // A commit that only took boards (a subboard's deletion) hands over every shape they held,
        // all gone: only those that had a title need filing, whichever is fewer to go through. Not one
        // that brought some of them to the board shown as it took their board (undoing a turn, whose
        // move put them there): those aren't gone.
        let onlyTook = !changes.replacedDocument && changes.boardsAdded.isEmpty && changes.boardsChanged.isEmpty
            && changes.added.isDisjoint(with: changes.elsewhere)
        if onlyTook, titles.count < changes.elsewhere.count {
            let gone = titles.filter { changes.elsewhere.contains($0.key) }
            for (id, title) in gone {
                titles[id] = nil
                guard let slot = holders.index(forKey: title) else { continue }
                holders.values[slot].remove(id)
                if holders.values[slot].isEmpty {
                    holders.remove(at: slot)
                } else if holders.values[slot].count == 1 {
                    lastAffected.formUnion(holders.values[slot])
                }
            }
        } else {
            for id in changes.elsewhere { follow(id, elsewhere: true) }
        }
    }

    /// Files a shape under its title now, noting whose warning that changes.
    private func retitle(_ id: ShapeID, to now: String?, isGone: Bool) {
        let before = titles[id]
        guard now != before else { return }
        if !isGone { lastAffected.insert(id) }
        if let before {
            holders[before]?.remove(id)
            if let left = holders[before] {
                if left.count == 1 { lastAffected.formUnion(left) }
                if left.isEmpty { holders[before] = nil }
            }
        }
        if let now {
            if let alone = holders[now], alone.count == 1 { lastAffected.formUnion(alone) }
            holders[now, default: []].insert(id)
        }
        titles[id] = now
    }

    /// A shape's title as Titles reads it; none for one kept aside.
    private func title(of record: AnyShapeRecord) -> String? {
        record.isOpaque ? nil : editor.registry.title(of: record)
    }

    /// Reads every title on every board the editor can show (`editor.showableBoards`).
    private func read() {
        holders = [:]
        titles = [:]
        let registry = editor.registry
        editor.withoutObservingDocument {
            for board in editor.showableBoards {
                for record in editor.contents(of: board).shapes where !record.isOpaque {
                    guard let title = registry.title(of: record) else { continue }
                    titles[record.id] = title
                    holders[title, default: []].insert(record.id)
                }
            }
        }
    }
}

extension TitleIndex: EditorService {
    /// Follows the commit.
    func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        follow(changes)
    }

    /// Nothing, but for a file put in place with the switch, whose titles it reads: the titles are
    /// the file's, kept up to date by every commit, whatever board it was on.
    func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        lastAffected = []
        if change.isFileReplaced { read() }
    }
}

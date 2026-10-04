import Canvas
import Validation

/// Titles' warning, as a Validation rule: a warning on each shape whose title another shape in
/// the file also has (“Checkout” is another shape’s title too.), about its `title` where Titles
/// keeps it. A title is what names a shape for everything that finds one by it (`canvas draw`, a
/// query, the `@` picker), and two shapes called one thing are found by it no longer: `draw`
/// refuses the title. Titles as Titles reads them (`registry.title(of:)`: named, or derived, as a
/// schema card's), folded, compared exactly; an untitled note's first line is no title. On every
/// board the editor can show, but shapes kept aside. A warning, never an error: each shape is fine
/// alone.
///
/// The titles are the file's, in an index of its own (`TitleIndex`), read as the editor opens
/// and kept up to date by each commit, wherever it changed a title, so the rule reads no other
/// shape: it names, with `affected`, the shapes a commit gives a title's first other holder or takes
/// its last from, which Validation checks again, on the board shown or once theirs is. Where shapes
/// are is nothing it reads, so it ignores moves. A plugin of its own, so a list can have Titles
/// without Validation (the registry refuses its rule where Validation isn't installed).
public struct TitleValidationPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { "title-validation" }

    #if DEBUG
    /// How many titled shapes the rule has checked in this process, debug builds only: tests hold a
    /// move to checking none.
    @MainActor public private(set) static var titlesChecked = 0
    #endif

    public func register(into registrar: inout PluginRegistrar) {
        registrar.service { TitleIndex(editor: $0) }
        registrar.validateEveryShape(ignoringMoves: true, affected: { changes, editor in
            editor.service(TitleIndex.self)?.affected(by: changes) ?? []
        }) { shape, context in
            guard let title = context.registry.title(of: shape), let index = context.service(TitleIndex.self) else { return [] }
            #if DEBUG
            Self.titlesChecked += 1
            #endif
            guard index.isShared(title, by: shape.id) else { return [] }
            let named = context.registry.properties(for: shape.kind).contains(TitleProperty.key)
            return [.warning("“\(title)” is another shape’s title too.", field: named ? TitleProperty.key.rawValue : nil)]
        }
    }
}

/// Every title in the file and the shapes it names, on every board the editor can show, but shapes
/// kept aside: read whole as the editor opens (and again for a file put in place, or a commit heard
/// out of turn), as Mentions' catalog is, so no check pays for it (a query's slice), then kept up to
/// date by each commit, for what it changed on any board, never for a move. It never transacts.
@MainActor
final class TitleIndex {
    private unowned let editor: CanvasEditor
    /// The shapes each title names.
    private var holders: [String: Set<ShapeID>] = [:]
    /// Each titled shape's title.
    private var titles: [ShapeID: String] = [:]
    /// Whether it holds the file's titles; else it reads them as it's next asked (one asked before
    /// it heard a commit).
    private var isRead = false
    /// The revision it's up to date with.
    private var heardRevision: Int
    /// The shapes the last commit heard gave a title's first other holder, or took its last from,
    /// and those still in the file whose title it changed: whose warning it may change.
    private var lastAffected: Set<ShapeID> = []

    init(editor: CanvasEditor) {
        self.editor = editor
        heardRevision = editor.revision
        read()
    }

    /// Whether a shape other than `id` is called `title`.
    func isShared(_ title: String, by id: ShapeID) -> Bool {
        readIfNeeded()
        guard let named = holders[title] else { return false }
        return named.count > 1 || !named.contains(id)
    }

    /// The shapes a commit may change the warning of: those still in the file whose title it
    /// changed, and those it gave a title's first other holder or took its last from (never what it
    /// deleted, so a subboard's deletion names none of what its boards held). Asked again for the
    /// same commit, the same.
    func affected(by changes: ChangeSet) -> Set<ShapeID> {
        catchUp(changes)
        return lastAffected
    }

    private func catchUp(_ changes: ChangeSet) {
        guard heardRevision != editor.revision else { return }
        // A commit heard out of turn: what the one before changed isn't known.
        let outOfTurn = heardRevision < editor.revision - 1
        heardRevision = editor.revision
        lastAffected = []
        guard isRead else { return }                        // read whole as it's next asked
        guard !outOfTurn else { return readAgain() }
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
        // all gone: only those that had a title need filing, whichever is fewer to go through.
        let onlyTook = !changes.replacedDocument && changes.boardsAdded.isEmpty && changes.boardsChanged.isEmpty
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

    private func readIfNeeded() {
        if heardRevision != editor.revision {
            // Asked before hearing a commit (by a service that hears first): what changed isn't known.
            heardRevision = editor.revision
            lastAffected = []
            isRead = false
        }
        guard !isRead else { return }
        read()
    }

    /// Reads every title afresh, noting the shapes whose warning that may change: every shape that
    /// shared a title before or does now.
    private func readAgain() {
        let shared = { (holders: [String: Set<ShapeID>]) in holders.values.lazy.filter { $0.count > 1 }.reduce(into: Set<ShapeID>()) { $0.formUnion($1) } }
        let before = shared(holders)
        read()
        lastAffected = before.union(shared(holders))
    }

    /// Reads every title: the root's shapes, then, from it down, those on the boards whose owners own
    /// boards the editor can show (`registry.ownsShowableBoard`, what `canShow` asks of each owner on
    /// a path), each board once.
    private func read() {
        holders = [:]
        titles = [:]
        isRead = true
        let registry = editor.registry
        editor.withoutObservingDocument {
            let children = editor.file.children
            var boards: [BoardID] = [.root], met: Set<BoardID> = [.root], next = 0
            while next < boards.count {
                let board = boards[next]
                next += 1
                for record in editor.contents(of: board).shapes where !record.isOpaque {
                    if let title = registry.title(of: record) {
                        titles[record.id] = title
                        holders[title, default: []].insert(record.id)
                    }
                    let owned = BoardID(owner: record.id)
                    if children[record.id] != nil, registry.ownsShowableBoard(record), met.insert(owned).inserted { boards.append(owned) }
                }
            }
        }
    }
}

extension TitleIndex: EditorService {
    /// Follows the commit, unless Validation's `affected` asked about it first.
    func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        catchUp(changes)
    }

    /// Nothing, but for a file put in place with the switch, whose titles it reads: the titles are
    /// the file's, kept up to date by every commit, whatever board it was on.
    func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        heardRevision = editor.revision
        lastAffected = []
        if change.isFileReplaced { read() }
    }
}

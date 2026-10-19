import Canvas
import FuzzyMatching
import Foundation

/// One text of a shape, as the index keeps it: whose it is (`source`, the contribution's place in
/// the kind's list), which of its texts (`field`), what it says, and that folded for searching.
struct IndexedText: Sendable {
    let source: Int
    let field: String
    let text: String
    let folded: FoldedText
}

/// A shape's texts, and its board.
struct IndexedShape: Sendable {
    let board: BoardID
    let texts: [IndexedText]
}

/// Every text every shape shows on every board the editor can show (none kept aside), folded once,
/// for a search per keystroke to run off the main actor (`entries` is a value, handed over whole).
/// Built on the first ⌘F, a slice of the main actor at a time (`FindStyle.buildSlice`, on the
/// editor's scheduler), so opening Find on a big file drops no frame; until then a commit costs a
/// revision noted. Built, each commit reads again only what it removed, added, changed other than
/// by moving, touched elsewhere, or a contribution's `affected` names; one heard out of turn, or a
/// file put in place, reads everything again. Never keeps file order: what's searched is ordered as
/// it's searched (`FindSearch`).
@MainActor
final class FindIndex {
    private unowned let editor: CanvasEditor
    /// Each kind's contributions, found once (the registry is frozen).
    private var contributions: [ShapeKind: [(source: Int, value: FindableTextsContribution)]] = [:]
    /// Every contribution that names shapes a commit changes the texts of without changing them.
    private let affecting: [FindableTextsContribution]
    private(set) var entries: [ShapeID: IndexedShape] = [:]
    /// Not started (no ⌘F yet), building (`pending` left to read), or built.
    private(set) var phase = Phase.idle
    /// The shapes left to read, as the build walked the file; each is read as it is when its turn
    /// comes (a commit meanwhile reads what it changes as it's heard).
    private var pending: [ShapeID] = []
    private var slice: ScheduledTask?
    /// The revision it's up to date with.
    private var heardRevision: Int
    /// Told what changed in the index once it's built (or building): the shapes whose texts it read
    /// again, or dropped; nil for everything (read afresh).
    var didChange: (@MainActor (Set<ShapeID>?) -> Void)?
    /// Told the build is done.
    var didBuild: (@MainActor () -> Void)?
    /// The slices the last build took, and the longest's and all of them's thread CPU, nanoseconds.
    private(set) var slices = 0
    private(set) var longestSlice: UInt64 = 0
    private(set) var totalBuild: UInt64 = 0
    #if DEBUG
    /// How many records have been read (debug builds): a move reads none.
    private(set) var recordsRead = 0
    #endif

    enum Phase: Equatable {
        case idle, building, built
    }

    init(editor: CanvasEditor) {
        self.editor = editor
        heardRevision = editor.revision
        affecting = editor.registry.contributions(to: FindableTexts.self).compactMap { $0.value.affected == nil ? nil : $0.value }
    }

    var isBuilt: Bool { phase == .built }

    // MARK: Building

    /// Starts the build, if it hasn't started: the first slice runs now.
    func start() {
        guard phase == .idle else { return }
        rebuild()
    }

    /// Reads everything afresh, in slices.
    private func rebuild() {
        slice?.cancel()
        slice = nil
        entries = [:]
        heardRevision = editor.revision
        phase = .building
        slices = 0
        longestSlice = 0
        totalBuild = 0
        pending = walk()
        buildSlice()
    }

    /// Every shape on a board the editor can show, in no particular order: the root's, then, from it
    /// down, those on the boards whose owners own boards the editor can show (`ownsShowableBoard`,
    /// `canShow`'s rule for each owner on a path), each board once. Ids only: what's read is read in
    /// its slice.
    private func walk() -> [ShapeID] {
        let registry = editor.registry
        return editor.withoutObservingDocument {
            let children = editor.file.children
            var ids: [ShapeID] = []
            var boards: [BoardID] = [.root], met: Set<BoardID> = [.root], next = 0
            while next < boards.count {
                let board = boards[next]
                next += 1
                for record in editor.contents(of: board).shapes where !record.isOpaque {
                    ids.append(record.id)
                    let owned = BoardID(owner: record.id)
                    if children[record.id] != nil, registry.ownsShowableBoard(record), met.insert(owned).inserted { boards.append(owned) }
                }
            }
            return ids
        }
    }

    /// Reads what's pending for a slice's time, then asks for the next turn, until none is left.
    private func buildSlice() {
        slice = nil
        guard phase == .building else { return }
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let budget = FindStyle.buildSlice.nanoseconds
        let (file, document) = editor.withoutObservingDocument { (editor.file, editor.document) }
        let board = editor.board
        var done = 0
        while let id = pending.popLast() {
            if let found = file.board(containing: id) {
                let record = found == board ? document[id] : file[found][id]
                if let record { read(record, on: found) } else { entries[id] = nil }
            }
            done += 1
            // The clock read every 16 shapes: reading it costs what reading a short note does.
            if done % 16 == 0, clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start >= budget { break }
        }
        let spent = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start
        slices += 1
        longestSlice = max(longestSlice, spent)
        totalBuild += spent
        guard pending.isEmpty else {
            slice = editor.scheduler.schedule(after: .zero) { [weak self] in self?.buildSlice() }
            return
        }
        phase = .built
        didBuild?()
    }

    // MARK: Reading a shape

    /// Reads a shape's texts into the index (none: out of it).
    private func read(_ record: AnyShapeRecord, on board: BoardID) {
        #if DEBUG
        recordsRead += 1
        #endif
        guard !record.isOpaque else {
            entries[record.id] = nil
            return
        }
        let context = FindContext(editor: editor)
        var texts: [IndexedText] = []
        for (source, contribution) in contributions(for: record.kind) {
            for text in contribution.texts(record, context) where !text.text.isEmpty {
                texts.append(IndexedText(source: source, field: text.field, text: text.text, folded: FoldedText(text.text)))
            }
        }
        entries[record.id] = texts.isEmpty ? nil : IndexedShape(board: board, texts: texts)
    }

    /// A kind's contributions, its own and those whose scope reaches it, found once.
    func contributions(for kind: ShapeKind) -> [(source: Int, value: FindableTextsContribution)] {
        if let known = contributions[kind] { return known }
        let registry = editor.registry
        guard registry.definition(for: kind) != nil else { return [] }
        let found = registry.contributions(to: FindableTexts.self, for: kind)
            .enumerated().map { (source: $0.offset, value: $0.element) }
        contributions[kind] = found
        return found
    }

    /// The contribution a shape's text came from.
    func contribution(_ source: Int, of kind: ShapeKind) -> FindableTextsContribution? {
        let all = contributions(for: kind)
        return all.indices.contains(source) ? all[source].value : nil
    }

    // MARK: Upkeep

    /// Follows a commit: nothing before the first ⌘F but the revision; afterwards what it changed.
    func hear(_ changes: ChangeSet) {
        guard heardRevision != editor.revision else { return }
        let outOfTurn = heardRevision < editor.revision - 1
        heardRevision = editor.revision
        guard phase != .idle else { return }
        guard !outOfTurn else {
            rebuild()
            didChange?(nil)
            return
        }
        // Asked first: a contribution's `affected` may have its plugin hear the commit, after which
        // what it reads (live names) is current.
        let context = FindContext(editor: editor)
        var affected = Set<ShapeID>()
        for contribution in affecting { affected.formUnion(contribution.affected?(changes, context) ?? []) }
        guard !changes.shapeIDs.isEmpty || !changes.elsewhere.isEmpty || !affected.isEmpty else { return }
        let (document, file) = editor.withoutObservingDocument { (editor.document, editor.file) }
        let owning = editor.registry.boardOwningKinds
        var showable: [BoardID: Bool] = [:]
        var touched = Set<ShapeID>()
        func follow(_ id: ShapeID, elsewhere: Bool = false) {
            guard touched.insert(id).inserted else { return }
            if !elsewhere, let shown = document[id] { return read(shown, on: editor.board) }
            guard let board = file.board(containing: id) else {
                entries[id] = nil
                return
            }
            let shows = showable[board] ?? file.canShow(board, boardOwningKinds: owning)
            showable[board] = shows
            if shows, let record = file[board][id] { read(record, on: board) } else { entries[id] = nil }
        }
        for id in changes.removed { follow(id) }
        for id in changes.added where !changes.moved.contains(id) { follow(id) }
        for id in changes.changed where !changes.moved.contains(id) { follow(id) }
        // A commit that only took boards (a subboard's deletion) hands over every shape they held,
        // all gone: only those indexed need dropping, whichever is fewer to go through.
        let onlyTook = !changes.replacedDocument && changes.boardsAdded.isEmpty && changes.boardsChanged.isEmpty
        if onlyTook, entries.count < changes.elsewhere.count {
            for id in entries.keys where changes.elsewhere.contains(id) && file.board(containing: id) == nil {
                entries[id] = nil
                touched.insert(id)
            }
        } else {
            for id in changes.elsewhere { follow(id, elsewhere: true) }
        }
        for id in affected { follow(id) }
        // A shape still waiting for the build is read as its turn comes, as it is then.
        didChange?(touched)
    }

    /// Another board is shown: nothing, the index is the file's; but a file put in place is read
    /// again.
    func boardDidChange(_ change: BoardChange) {
        heardRevision = editor.revision
        guard change.isFileReplaced, phase != .idle else { return }
        rebuild()
        didChange?(nil)
    }
}

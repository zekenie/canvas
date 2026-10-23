import AppKit
import Boards
import Canvas
import FuzzyMatching
import Observation
import TextEditing
import Titles
import Topology

/// What Jump To knows of an editor's file, one per editor: whether its palette is open, what's
/// typed, the rows that lists, this window's recent picks and the catalog of titled shapes those
/// rows are ranked from. It never transacts: a pick only goes somewhere (`editor.follow`).
///
/// The catalog (`JumpToCatalog`) is every titled shape on every board the editor can show, named or
/// derived (`registry.title(of:)`: a note's title), none kept aside. It's built the
/// first time the palette opens, in slices of a couple of milliseconds on the main actor
/// (`editor.scheduler`, the first slice at once), so before then a commit costs one test; after, each commit costs what it changed: the shapes it removed, added and changed (a
/// move changes no title, and reads nothing), and those it reached on other boards
/// (`ChangeSet.elsewhere`: a deleted subboard's, a paste's), a rename of a container costing only the
/// name it's shown by. A file put in place reads the file again, as Titles' index does, and a commit while the catalog is being built is applied to what's read so far (the shapes on boards not yet read are read when their turn comes), so a stream of commits can't keep it from finishing.
///
/// A query is ranked by what it names: with one piece (a word), by the titles of shapes alone
/// (`FuzzyMatcher.rank`, the `@` picker's workload); with several, by the containment tree too, as
/// VS Code's file switcher ranks paths: "alpha gamma check" is a shape called "check…" in a "gamma…"
/// inside an "alpha…", whatever's between (`PathMatcher`; `JumpToSearch.swift`).
@MainActor
@Observable
public final class JumpToState {
    @ObservationIgnored unowned let editor: CanvasEditor
    public var registry: Registry { editor.registry }

    /// Whether the palette is open.
    public private(set) var isOpen = false
    /// What's typed.
    public private(set) var query = ""
    /// +1 each time ⌘K asks for the palette: its field takes the keyboard, its text selected.
    public private(set) var focusRequest = 0
    /// How far down over the canvas its capsule is, in view points: the part the host leaves clear
    /// of its top (below the path over a subboard) and a fixed offset, taken as it opens.
    public private(set) var top: CGFloat = 0

    /// The rows the list shows for `query`, index for index (`list`'s rows are these as they're drawn).
    @ObservationIgnored public private(set) var rows: [JumpToRow] = []
    /// The list the palette shows: its rows as they're drawn and said, and the highlight. The
    /// palette's window follows its changes.
    @ObservationIgnored public let list = CaretList(metrics: JumpToStyle.metrics)

    /// This window's picks, the latest first; never saved.
    @ObservationIgnored public private(set) var recent: [ShapeID] = []

    // The catalog, and what keeps it.
    @ObservationIgnored var catalog = JumpToCatalog()
    @ObservationIgnored var phase = Phase.unbuilt
    @ObservationIgnored private var buildTask: ScheduledTask?
    /// What each container on a path is called and directly in, found once and kept until a commit
    /// changes that shape (Boards' `ShapePaths`, the one rule every path is made by).
    @ObservationIgnored var paths: ShapePaths
    /// Called as the palette closes, so its window goes at once, not when its view does.
    @ObservationIgnored var onClose: (@MainActor () -> Void)?

    /// How the catalog's build went (release builds too, for the benchmarks): the slices it took,
    /// the longest, and all of them, in thread CPU time. Reset as a build starts.
    @ObservationIgnored public private(set) var buildSlices = 0
    @ObservationIgnored public private(set) var longestBuildSlice: Duration = .zero
    @ObservationIgnored public private(set) var buildTime: Duration = .zero

    #if DEBUG
    /// How many titles have been read, by a build or a commit (debug builds), so tests can hold a
    /// commit to what it changed.
    @ObservationIgnored public private(set) var entriesRead = 0
    #endif

    /// Where the catalog is: not read yet (nothing until the first ⌘K), being read in slices, or read.
    enum Phase {
        case unbuilt
        case building(Build)
        case ready
    }

    /// Where a build has got to: the boards the editor could show as it began (`editor.showableBoards`:
    /// what a commit since brings arrives through it), the one being read (its shapes as they were when its
    /// turn came) and how far.
    struct Build {
        var boards: [BoardID]
        var board = 0
        var index = 0
        var shapes: [AnyShapeRecord]?
        /// The shapes a commit read again since `shapes` was taken: read as they are now, not as they were.
        var touched: Set<ShapeID> = []
    }

    init(editor: CanvasEditor) {
        self.editor = editor
        paths = ShapePaths(editor: editor)
    }

    /// Whether the catalog is read: before, a query lists what's been read so far.
    public var isReady: Bool {
        if case .ready = phase { true } else { false }
    }

    /// How many shapes the catalog holds.
    public var catalogCount: Int { catalog.count }

    // MARK: Opening and closing

    /// Opens the palette, empty, its field to take the keyboard; or, open, asks for the keyboard
    /// again, the text selected. The catalog is read the first time (the first slice now).
    public func open() {
        focusRequest += 1
        guard !isOpen else { return }
        top = max(editor.unobscuredViewport.minY, 0) + JumpToStyle.topOffset
        query = ""
        isOpen = true
        if case .unbuilt = phase { startBuild() }
        refreshRows()
    }

    /// Closes the palette, whatever closed it: what's typed goes, and its window.
    public func close() {
        guard isOpen else { return }
        isOpen = false
        query = ""
        onClose?()
    }

    /// What's typed changed: the rows are what it names now.
    public func setQuery(_ text: String) {
        guard text != query else { return }
        query = text
        refreshRows()
    }

    /// Lists what `query` finds, the first shape highlighted.
    func refreshRows() {
        rows = search(query)
        list.setRows(JumpToRow.listRows(rows))
    }

    // MARK: Picking

    /// The highlighted row's shape.
    public var highlighted: JumpToCandidate? { list.highlighted.flatMap { rows[$0].candidate } }

    /// Highlights a row (the pointer's over it); a header or an empty state highlights nothing new.
    public func highlight(row index: Int) { list.highlight(row: index) }

    /// Picks the highlighted row, if there is one: the palette closes and its shape is followed.
    public func pickHighlighted() {
        guard let index = list.highlighted else { return }
        pick(row: index)
    }

    /// Picks a row: the palette closes, then the shape is followed (`editor.follow`: into it if its
    /// kind opens its board, else to it), one step back, and it's the latest recent pick.
    public func pick(row index: Int) {
        guard rows.indices.contains(index), let candidate = rows[index].candidate else { return }
        pick(candidate.id)
    }

    /// Follows a shape, as picking its row does.
    public func pick(_ id: ShapeID) {
        guard editor.file.record(id) != nil else { return }
        let previous = recent
        recent.removeAll { $0 == id }
        recent.insert(id, at: 0)
        if recent.count > JumpToStyle.recentKept { recent.removeLast(recent.count - JumpToStyle.recentKept) }
        catalog.markRecent(recent, previous: previous)
        close()
        editor.follow(id)
    }

    // MARK: Building the catalog

    /// Reads the catalog afresh, the first slice now and the rest on the scheduler's next turns.
    private func startBuild() {
        buildTask?.cancel()
        buildTask = nil
        catalog = JumpToCatalog()
        paths.forgetAll()
        phase = .building(Build(boards: editor.withoutObservingDocument { editor.showableBoards }))
        buildSlices = 0
        longestBuildSlice = .zero
        buildTime = .zero
        continueBuild()
    }

    private func continueBuild() {
        buildTask = nil
        runSlice()
        guard case .building = phase else {
            catalog.markRecent(recent, previous: [])
            if isOpen { refreshRows() }
            return
        }
        buildTask = editor.scheduler.schedule(after: .zero) { [weak self] in self?.continueBuild() }
    }

    /// Reads shapes, board by board, until `JumpToStyle.buildSlice` of this thread's CPU has gone (the
    /// clock read every few shapes), at least one read.
    private func runSlice() {
        guard case .building(var build) = phase else { return }
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let budget = UInt64(JumpToStyle.buildSlice.components.attoseconds / 1_000_000_000)
        editor.withoutObservingDocument {
            var sinceClock = 0
            slice: while build.board < build.boards.count {
                if build.shapes == nil {
                    build.shapes = editor.contents(of: build.boards[build.board]).shapes
                    build.touched = []
                }
                let shapes = build.shapes ?? []
                while build.index < shapes.count {
                    var record = shapes[build.index]
                    build.index += 1
                    // A commit meanwhile read this one again (or took it out): it's as it is now.
                    if build.touched.contains(record.id) {
                        guard let current = editor.shape(inFile: record.id) else { continue }
                        record = current
                    }
                    guard !record.isOpaque else { continue }
                    read(record)
                    sinceClock += 1
                    if sinceClock >= JumpToStyle.clockStride {
                        sinceClock = 0
                        if clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start >= budget { break slice }
                    }
                }
                build.board += 1
                build.index = 0
                build.shapes = nil
            }
        }
        let took = Duration.nanoseconds(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start)
        buildSlices += 1
        buildTime += took
        longestBuildSlice = max(longestBuildSlice, took)
        phase = build.board >= build.boards.count ? .ready : .building(build)
    }

    /// A shape's catalog entry, read: in if it has a title, out if not.
    private func read(_ record: AnyShapeRecord) {
        #if DEBUG
        entriesRead += 1
        #endif
        guard let title = registry.title(of: record) else {
            catalog.remove(record.id)
            return
        }
        catalog.set(record.id, title: title, parent: editor.topology?.parent(of: record.id), recentRank: -1)
    }

    // MARK: Following the file

    /// Reads again the shapes a commit changed, wherever they are, and takes those it removed out; the
    /// containers it changed are read again when a path next goes through them.
    private func apply(_ changes: ChangeSet) {
        paths.forget(changes)
        for id in changes.removed { catalog.remove(id) }
        for id in changes.added where !changes.moved.contains(id) { refresh(id) }
        for id in changes.changed where !changes.moved.contains(id) { refresh(id) }
        guard !changes.elsewhere.isEmpty else { return }
        // A commit that only took boards (a subboard's deletion) hands over every shape they held,
        // all gone: whichever is fewer to go through. Not one that brought some of them to the board
        // shown as it took their board (undoing a turn, whose move put them there): those aren't gone,
        // and only an entry no longer on a board the app can show is.
        let onlyTook = !changes.replacedDocument && changes.boardsAdded.isEmpty && changes.boardsChanged.isEmpty
            && changes.added.isDisjoint(with: changes.elsewhere)
        if onlyTook, catalog.count < changes.elsewhere.count {
            for id in catalog.entries.map(\.id) where changes.elsewhere.contains(id) && !isOnShowableBoard(id) { catalog.remove(id) }
        } else {
            for id in changes.elsewhere { refresh(id) }
        }
    }

    /// A shape read again, from wherever it is in the file; gone from the catalog if it's gone from
    /// the file, kept aside or untitled.
    private func refresh(_ id: ShapeID) {
        #if DEBUG
        entriesRead += 1
        #endif
        guard let record = editor.shape(inFile: id), !record.isOpaque, isOnShowableBoard(id),
              let title = registry.title(of: record) else {
            catalog.remove(id)
            return
        }
        catalog.set(id, title: title, parent: editor.topology?.parent(of: id), recentRank: recent.firstIndex(of: id) ?? -1)
    }

    /// Whether a shape is on a board the app can show (`canShow`'s rule, as the build descends): a
    /// commit that reaches a shape on a board the app can't show doesn't list it.
    private func isOnShowableBoard(_ id: ShapeID) -> Bool {
        let file = editor.file
        return file.board(containing: id).map { file.canShow($0, boardOwningKinds: registry.boardOwningKinds) } ?? false
    }

    /// Whether a commit changed anything a catalog is made of: a move alone doesn't.
    private func isTouching(_ changes: ChangeSet) -> Bool {
        !changes.removed.isEmpty || !changes.elsewhere.isEmpty
            || changes.added.contains { !changes.moved.contains($0) } || changes.changed.contains { !changes.moved.contains($0) }
    }

    /// The catalog is read again: now if the palette is open, else at its next opening.
    private func readAgain() {
        buildTask?.cancel()
        buildTask = nil
        catalog = JumpToCatalog()
        paths.forgetAll()
        phase = .unbuilt
        if isOpen {
            startBuild()
            refreshRows()
        }
    }

    func hear(_ changes: ChangeSet) {
        switch phase {
        case .unbuilt:
            return
        case .building(var build):
            guard isTouching(changes) else { return }
            // What the commit changed is read now, as it is; the shapes on boards not read yet are
            // read when their turn comes (setting a shape twice is the same as once), and what's on
            // boards the commit brought arrives through `elsewhere`. The one board being read is
            // read from the shapes it had, but for those the commit touched.
            build.touched.formUnion(changes.removed)
            build.touched.formUnion(changes.added)
            build.touched.formUnion(changes.changed)
            build.touched.formUnion(changes.elsewhere)
            phase = .building(build)
            apply(changes)
            if isOpen { refreshRows() }
        case .ready:
            guard isTouching(changes) else { return }
            apply(changes)
            if isOpen { refreshRows() }
        }
    }

    func heardBoardChange(_ change: BoardChange) {
        if change.isFileReplaced {
            readAgain()
        } else if isOpen, query.isEmpty {
            // What's nearby is the board shown's.
            refreshRows()
        }
    }
}

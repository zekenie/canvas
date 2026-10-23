import AppKit
import Canvas
import FuzzyMatching
import Observation
import Queries
import Selection
import TableOfContents
import Topology

/// One of the lists a shape's panel shows of what's connected to it: a title, the query that finds
/// its shapes, and, for a light's, the color hovering outlines them in.
public struct NeighborGroup: Sendable {
    public let title: String
    /// The light's color; nil for a list no light gives (what the shape is inside, what it holds).
    public let color: NSColor?
    let query: @Sendable (String) -> String
    let caption: (@MainActor @Sendable (_ editor: CanvasEditor, _ subject: ShapeID, _ neighbor: ShapeID) -> String?)?
}

/// A shape in one of the lists, as the query engine answered it.
public struct NeighborRow: Equatable, Identifiable, Sendable {
    public let id: ShapeID
    public let kind: ShapeKind
    /// Nil for a shape with no name.
    public let title: String?
    public let board: BoardID
    /// What it's inside, outermost first, as a query's row names them.
    public let inside: [String]
}

/// What the lists hold for one shape, as the last answer left them.
public struct NeighborListing: Equatable, Sendable {
    public struct Group: Equatable, Sendable {
        /// How many shapes the list has, read or not.
        public var count: Int
        /// The shapes, in the engine's order; nil for a folded list, which is only counted.
        public var rows: [NeighborRow]?
    }

    public let subject: ShapeID
    /// A list for each of `NeighborList.groups`, in their order.
    public var groups: [Group]
    /// Counts the answers shown: every row is drawn again for each, since a row's name and caption
    /// are read as it's drawn.
    public var stamp = 0
}

/// A row as the panel draws it.
public struct NeighborLine: Equatable {
    public let symbol: String
    public let tint: NSColor?
    public let name: String
    /// Where it is, when that isn't the board shown or the subject's own: the containers it is inside, outermost first
    /// ("Alpha › Beta"), else the name of its board.
    public let detail: String?
    public let caption: String?

    /// What assistive apps read of the row: its name, where it is, and its caption, as the row
    /// draws them.
    public var spoken: String { [name, detail, caption].compactMap { $0 }.joined(separator: ", ") }
}

/// What's connected to the shape a panel shows, in lists by how, one per editor: each light's
/// matches under its title (what the shape points to, what points to it, what it mentions, what
/// mentions it: whatever the plugins that own the edges gave), then what it's inside and what it
/// holds. The lists are queries, asked of the query engine, so they hold what hovering the shape
/// outlines, less what runs between (a light's `between`: the arrows), and this module still knows
/// no kind, edge type or concern.
///
/// **The subject.** The shape whose list is on screen: the panel's view says so as it appears
/// (`watch`) and as it goes (`unwatch`), so nothing is asked while no list shows.
///
/// **Asking.** One ask for a subject: every folded list is counted in one batch of ids, and every
/// open one is run for its rows (id, kind, title, board), each in the edge view `.resolved` and,
/// where some shape stands in for others, in `.literal` too, as the hover asks. The answer lands a
/// turn or so later, whole. A list unfolded, or text typed to search, asks again where rows it
/// needs weren't read.
///
/// **Asking again.** After any commit that does more than move shapes (a name, an edge, a container
/// joined or left), once commits have stopped for a moment (`NeighborStyle.settle`: a resize's
/// every event is a commit), and after any change to the edges that no commit made (an answer
/// provided for a stand-in). Its answer is shown though it reads as the last one: a row's name and
/// caption are read as it's drawn, from shapes the commit may have changed.
///
/// **Names.** A row is called its title, as the engine names it; a shape with none, what the table of
/// contents calls it (a note with no title, its text), else its kind's name.
///
/// **Where a row is.** The containers it is inside, outermost first, as the query engine names them (`inside`), less
/// those the board shown is inside and the subject is, when the row is inside them, joined by " › " as a path says
/// them: a shape's identity is its path, so two called alike are told apart. A shape in no container left but on
/// another board says that board's name.
///
/// **Searching.** Typed text keeps, in every list, folded or not, the rows whose names it matches,
/// ranked as every list ranks what's typed (`FuzzyMatcher`). Of several words it also keeps the rows whose
/// containers the words before the last name (a path, as the `@` picker and Jump To match one): the rows whose
/// names have the whole text first, then those found by their paths, then the loose matches of the name.
@MainActor
@Observable
public final class NeighborList {
    @ObservationIgnored private unowned let editor: CanvasEditor
    /// The lists, in order: each light's, then what the shape is inside and what it holds.
    @ObservationIgnored public let groups: [NeighborGroup]

    /// The shape whose lists are on screen. Observed: a view of another shape's lists, drawn before
    /// it has said so, shows nothing of this one's.
    public private(set) var subject: ShapeID?
    /// The last answer: the subject's once it has landed, the shape before's until then.
    public private(set) var listing: NeighborListing?
    /// What's typed to search the lists: none, each list shows all it has.
    public private(set) var search = ""
    /// The folded lists, by their place in `groups`: kept while the editor lives, for every shape.
    private var folded: Set<Int> = []

    @ObservationIgnored private var asking: Task<Void, Never>?
    /// Whether the ask due, or out, follows a change to the file: its answer is shown whatever it reads.
    @ObservationIgnored private var followsChange = false
    /// What each untitled shape listed is called, read once for an answer and let go of with it.
    @ObservationIgnored private var names: [ShapeID: String] = [:]
    @ObservationIgnored private var turn: ScheduledTask?
    @ObservationIgnored private var following: TopologyFollowing?
    /// The shape a row's pointer hovered, on the board shown or elsewhere: only that hover is let
    /// go of as the pointer leaves.
    @ObservationIgnored private var rowHover: ShapeID?
    @ObservationIgnored private var rowHoverElsewhere: ShapeID?

    #if DEBUG
    /// How many times the engine was asked (debug builds): a drag asks nothing.
    @ObservationIgnored public private(set) var asked = 0
    /// How many answers were shown (debug builds): one that reads as the last shows nothing.
    @ObservationIgnored public private(set) var shown = 0
    /// How many rows were drawn (debug builds): a long list draws the rows in view, not all it has.
    @ObservationIgnored public private(set) var linesDrawn = 0
    #endif

    init(editor: CanvasEditor, lights: [NeighborLight]) {
        self.editor = editor
        groups = lights.map { NeighborGroup(title: $0.title, color: $0.color, query: $0.query, caption: $0.caption) } + [
            // What it's inside, outermost first, and what's directly inside it: the language's own
            // words for Topology's one tree, a frame's shapes and a subboard's board alike. What runs
            // between the shapes it holds (a connection that starts at a shape: an arrow) isn't
            // listed, as no list has what runs between.
            NeighborGroup(title: NeighborStyle.inside, color: nil, query: { ":has(\($0))" }, caption: nil),
            NeighborGroup(title: NeighborStyle.contains, color: nil, query: { "\($0) > *:not(:starts-at(*))" }, caption: nil),
        ]
        following = editor.topology?.follow { [weak self] change in
            // A commit's change is heard as the commit is.
            if change.cause != .commit { self?.askSoon(after: .zero) }
        }
    }

    // MARK: The subject

    /// A list of `id`'s is on screen: it's the subject, and asked about.
    public func watch(_ id: ShapeID) {
        guard subject != id else { return }
        subject = id
        if !search.isEmpty { search = "" }
        ask()
    }

    /// The list of `id`'s went: nothing is asked until another shows.
    public func unwatch(_ id: ShapeID) {
        guard subject == id else { return }
        subject = nil
        // What a shape is called may change while no list shows, with nothing heard of it.
        names = [:]
        turn?.cancel()
        turn = nil
        asking?.cancel()
        asking = nil
    }

    /// Whether an answer is on its way, or an ask is due: what a test waits out.
    public var isAsking: Bool { asking != nil || turn != nil }

    /// Returns once no answer is on its way.
    public func landed() async {
        while let asking { await asking.value }
    }

    // MARK: Folding and searching

    public func isFolded(_ group: Int) -> Bool { folded.contains(group) }

    /// Folds a list, or unfolds it: one unfolded whose rows weren't read is asked for them.
    public func setFolded(_ group: Int, _ isFolded: Bool) {
        if isFolded { folded.insert(group) } else { folded.remove(group) }
        askIfRowsMissing()
    }

    /// Searches the lists for `text`: the folded ones too, whose rows are asked for.
    public func setSearch(_ text: String) {
        guard text != search else { return }
        search = text
        askIfRowsMissing()
    }

    /// Whether a list's rows show: it's unfolded, or the lists are being searched.
    public func showsRows(of group: Int) -> Bool { !search.isEmpty || !folded.contains(group) }

    private func askIfRowsMissing() {
        guard subject != nil else { return }
        let current = listing?.subject == subject ? listing : nil
        if groups.indices.contains(where: { showsRows(of: $0) && current?.groups[$0].rows == nil }) { ask() }
    }

    // MARK: What the lists show

    /// The subject's answer, once it has landed.
    private var current: NeighborListing? {
        guard let listing, listing.subject == subject else { return nil }
        return listing
    }

    /// Whether the subject's answer has landed.
    public var hasLanded: Bool { current != nil }

    /// How many shapes the subject's lists have in all, searched or not.
    public var total: Int { current?.groups.reduce(0) { $0 + $1.count } ?? 0 }

    /// A list as shown: how many it has, and its rows. Not searching, it has all the engine counted,
    /// and its rows in the engine's order, none while it's folded; searching, the rows whose names
    /// the text matches, the best first, folded or not.
    public func shown(in group: Int) -> (count: Int, rows: [NeighborRow]) {
        guard let listed = current?.groups[group] else { return (0, []) }
        guard !search.isEmpty else { return (listed.count, folded.contains(group) ? [] : listed.rows ?? []) }
        // A folded list searched before its rows are read keeps its head until they land.
        guard let rows = listed.rows else { return (listed.count, []) }
        let names = rows.map(name(of:))
        let matches = FuzzyMatcher.matches(search, in: names)
        let matcher = PathMatcher(search)
        // Of several words: the whole text in a name strongly, a path the words name, the name loosely.
        func band(_ index: Int) -> (band: Int, score: Int)? {
            let named = matches[index]
            guard matcher.pieceCount > 1 else { return named.map { (0, $0.score) } }
            if let named, named.score >= FuzzyRanking.substring { return (0, named.score) }
            if let path = matcher.match(path: rows[index].inside + [names[index]], placingAtLeast: 1) { return (1, path.score) }
            return named.map { (2, $0.score) }
        }
        let ranked = rows.indices.compactMap { index in band(index).map { (index: index, band: $0.band, score: $0.score) } }
            .sorted { ($0.band, $1.score, $0.index) < ($1.band, $0.score, $1.index) }
            .map { rows[$0.index] }
        return (ranked.count, ranked)
    }

    /// How a row is drawn: its kind's symbol, in the tint the shape has (`editor.tint(of:)`: its
    /// kind's unless it has a color of its own), read as the row is drawn, its name (its title, else its kind's), the
    /// board it's on when that isn't the one shown, and what its list's light says under it.
    public func line(for row: NeighborRow, in group: Int) -> NeighborLine {
        #if DEBUG
        linesDrawn += 1
        #endif
        let label = editor.registry.label(of: row.kind)
        // The board shown is observed (a row says where it is); the file isn't: a row is
        // drawn again as an answer lands, never on every commit. What's inside the subject (what a
        // subboard holds) needs no saying.
        let isElsewhere = row.board != editor.board && row.board != subject.map { BoardID(owner: $0) }
        return editor.withoutObservingDocument {
            NeighborLine(symbol: label.systemImage ?? NeighborStyle.fallbackSymbol,
                         tint: editor.shape(inFile: row.id).flatMap { editor.tint(of: $0) } ?? label.tint, name: name(of: row),
                         detail: place(of: row, isElsewhere: isElsewhere),
                         caption: subject.flatMap { groups[group].caption?(editor, $0, row.id) })
        }
    }

    /// What a row is called: its title, as the engine names it; with none, what the table of contents
    /// calls the shape (a note with no title, its text), kept for the answer; else its kind's name.
    private func name(of row: NeighborRow) -> String {
        if let title = row.title, !title.isEmpty { return title }
        if let kept = names[row.id] { return kept }
        let name = editor.withoutObservingDocument {
            editor.shape(inFile: row.id).flatMap { editor.tableOfContents?.name(of: $0) }
        } ?? editor.registry.label(of: row.kind).name
        names[row.id] = name
        return name
    }

    /// Where a row is: the containers it is inside less those the board shown is inside and the subject is, when the row
    /// is inside them (the rows of a subboard's own list, and the shapes on the board shown, say nothing of what holds
    /// them all), joined as a path; else, on another board, that board's name; nil if it needs no saying.
    private func place(of row: NeighborRow, isElsewhere: Bool) -> String? {
        var names = row.inside[...]
        if let topology = editor.topology {
            // The ids of what the row is inside, outermost first, when they are the names `inside` has.
            let above = Array(topology.ancestors(of: row.id).reversed())
            if above.count == row.inside.count {
                var dropped = 0
                for held in [editor.board.owner, subject].compactMap({ $0 }) {
                    let chain = Array(topology.ancestors(of: held).reversed()) + [held]
                    if chain.count > dropped, above.starts(with: chain) { dropped = chain.count }
                }
                names = row.inside[dropped...]
            }
        }
        if !names.isEmpty { return names.joined(separator: NeighborStyle.pathSeparator) }
        return isElsewhere ? boardName(of: row) : nil
    }

    /// What the board a row is on is called: its owner's name, as the engine named it among what
    /// the row is inside (the root's, the file's name).
    private func boardName(of row: NeighborRow) -> String {
        guard let owner = editor.owner(of: row.board) else {
            return rootName
        }
        // `inside` is outermost first; the ancestors, nearest first.
        if let ancestors = editor.topology?.ancestors(of: row.id), ancestors.count == row.inside.count,
           let depth = ancestors.firstIndex(of: owner.id) {
            return row.inside[row.inside.count - 1 - depth]
        }
        return row.inside.last ?? editor.registry.label(of: owner.kind).name
    }

    /// What the root board is called: the file's name, which the editor holds (observed: a rename
    /// redraws the rows that say it), else "Board".
    private var rootName: String { editor.rootName.isEmpty ? NeighborStyle.rootName : editor.rootName }

    // MARK: Rows' clicks and hovers

    /// Goes to a listed shape (`editor.goTo`: its board shown first, if it's on another, selected, in
    /// view; one step back), on the scheduler's next turn: the click's own view goes with the panel.
    public func go(to id: ShapeID) {
        _ = editor.scheduler.schedule(after: .zero) { [weak editor] in editor?.goTo([id]) }
    }

    /// The pointer on a row hovers its shape: on the canvas, if it's on the board shown, else as a
    /// shape hovered elsewhere, whose card the canvas outlines.
    public func hover(_ id: ShapeID) {
        if editor.document[id] != nil {
            rowHover = id
            editor.hovered = id
        } else if editor.file.board(containing: id) != nil {
            rowHoverElsewhere = id
            editor.hoveredElsewhere = id
        }
    }

    /// The pointer left a row, or the row went: lets go of the hover that row set, no other.
    public func endHover(_ id: ShapeID) {
        if rowHoverElsewhere == id {
            rowHoverElsewhere = nil
            if editor.hoveredElsewhere == id { editor.hoveredElsewhere = nil }
        }
        guard rowHover == id else { return }
        rowHover = nil
        if editor.hovered == id { editor.hovered = nil }
    }

    // MARK: Asking

    /// Asks once the scheduler has turned for `delay` with no other call: commits in a run (typing, a
    /// resize) are one ask.
    private func askSoon(after delay: Duration) {
        guard subject != nil else { return }
        followsChange = true
        turn?.cancel()
        turn = editor.scheduler.schedule(after: delay) { [weak self] in
            guard let self else { return }
            turn = nil
            ask()
        }
    }

    /// Asks the engine for the subject's lists, letting go of an ask under way. Without the engine or
    /// Topology, the lists are empty.
    private func ask() {
        asking?.cancel()
        asking = nil
        guard let subject else { return }
        guard let queries = editor.queries, let topology = editor.topology else {
            return land(NeighborListing(subject: subject, groups: groups.map { _ in .init(count: 0, rows: []) }))
        }
        // The literal view reads other edges than the resolved one only where a shape stands in.
        let views: [EdgeView] = topology.hasStandIns ? [.resolved, .literal] : [.resolved]
        let selector = "#\(subject)"
        let texts = groups.map { $0.query(selector) }
        let open = groups.indices.map(showsRows(of:))
        #if DEBUG
        asked += 1
        #endif
        asking = Task { [weak self, queries] in
            let answered = await NeighborList.answer(queries, texts: texts, open: open, views: views, subject: subject)
            // One let go of lands nothing: whoever did that asked again, or the list went.
            guard !Task.isCancelled, let self else { return }
            asking = nil
            land(NeighborListing(subject: subject, groups: answered))
        }
    }

    /// Shows an answer, unless it reads as the one shown and no change to the file asked for it: one
    /// a commit asked for is shown anyway, with the names read again, since what a row is called and
    /// what its caption quotes are read from shapes the commit may have changed.
    private func land(_ next: NeighborListing) {
        var next = next
        let followed = followsChange
        followsChange = false
        if let listing, listing.subject == next.subject, listing.groups == next.groups, !followed { return }
        next.stamp = (listing?.stamp ?? 0) + 1
        names = [:]
        listing = next
        #if DEBUG
        shown += 1
        #endif
    }

    /// What one of an ask's tasks answered: an open list's rows, or every folded list's count.
    private enum Answered: Sendable {
        case rows(Int, NeighborListing.Group)
        case counts([Int])
    }

    /// Every list's answer: the folded ones counted in one batch of ids, each open one run for its
    /// rows, all at once.
    private static func answer(_ queries: QueryState, texts: [String], open: [Bool], views: [EdgeView], subject: ShapeID) async -> [NeighborListing.Group] {
        var groups = [NeighborListing.Group](repeating: .init(count: 0, rows: nil), count: texts.count)
        let closed = texts.indices.filter { !open[$0] }
        await withTaskGroup(of: Answered.self) { tasks in
            if !closed.isEmpty {
                tasks.addTask { await .counts(NeighborList.counts(queries, closed.map { texts[$0] }, views: views, subject: subject)) }
            }
            for group in texts.indices where open[group] {
                tasks.addTask { await .rows(group, NeighborList.rows(queries, texts[group], views: views, subject: subject)) }
            }
            for await answered in tasks {
                switch answered {
                case .rows(let group, let listed): groups[group] = listed
                case .counts(let counts): for (group, count) in zip(closed, counts) { groups[group].count = count }
                }
            }
        }
        return groups
    }

    /// How many shapes each query matches, the subject left out: the union of its views' ids. A
    /// request the engine refuses (a shape that holds nothing asked what it holds) counts none.
    private static func counts(_ queries: QueryState, _ texts: [String], views: [EdgeView], subject: ShapeID) async -> [Int] {
        let requests = texts.flatMap { text in
            views.map { QueryMatchRequest(text, edges: $0, admitting: { $0.id != subject }) }
        }
        let answers = await queries.matches(requests)
        return texts.indices.map { index in
            var ids: Set<ShapeID> = [], most = 0
            for case .success(let answer) in answers[index * views.count ..< (index + 1) * views.count] {
                ids.formUnion(answer.ids)
                most = max(most, answer.count)
            }
            return max(ids.count, most)
        }
    }

    /// A query's rows, the subject left out: each view's, a shape once, the first view's first.
    private static func rows(_ queries: QueryState, _ text: String, views: [EdgeView], subject: ShapeID) async -> NeighborListing.Group {
        var rows: [NeighborRow] = [], seen: Set<ShapeID> = [subject], most = 0
        for view in views {
            guard let result = try? await queries.run(QueryRequest(text, limit: QueryBudget.maxRows, properties: .none, edges: view)) else { continue }
            var own = 0
            for row in result.rows {
                if row.id == subject { own = 1 }
                guard seen.insert(row.id).inserted else { continue }
                rows.append(NeighborRow(id: row.id, kind: row.kind, title: row.title, board: row.board, inside: row.inside))
            }
            most = max(most, result.count - own)
        }
        return .init(count: max(rows.count, most), rows: rows)
    }
}

extension NeighborList: EditorService {
    /// A commit that does more than move shapes may change a list (an edge, a name, a container
    /// joined or left), so the engine is asked again once commits have stopped for a moment; a drag's
    /// every event costs a look at its change set.
    public func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        guard subject != nil else { return }
        if !changes.onlyMoves { askSoon(after: NeighborStyle.settle) }
    }

    /// The file's colors changed: every row is drawn again, as an answer drawn again does, since a
    /// row's symbol is in the tint its shape has, read as it's drawn.
    public func shapeTintsDidChange(in editor: CanvasEditor) {
        listing?.stamp += 1
    }
}

extension CanvasEditor {
    /// The lists of what's connected to the shape a panel shows; nil without `NeighborDetailsPlugin`.
    public var neighborList: NeighborList? { service(NeighborList.self) }
}

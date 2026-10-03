import AppKit
import Canvas
import Observation
import Selection
import TextEditing
import Titles
import Topology

/// What Mentions knows about an editor's file, one per editor: how each mentioned shape shows now,
/// what mentions each shape, on any board (`backlinks(of:)`), the catalog of shapes that can be
/// mentioned (what the `@` picker searches), and this editor's recent picks. It never transacts: it
/// follows the file.
///
/// Who mentions whom is Topology's: each mention is an edge of type `mention` (`MentionEdge`), from
/// the shape whose text holds it, which Mentions' source reads out of the mention text (of a kind
/// whose shapes can hold names, `registry.namingKinds`), in the index Topology keeps of the whole
/// file (`editor.topology`). This service reads it: `mentions(in:)`, `mentioners(of:)`, and which
/// shapes are mentioned, whose resolutions it keeps. Each commit costs what it changed: the shapes
/// it touched that are mentioned (or observed) are resolved again, on any board, and only a
/// resolution that changed tells its observers, bumps its `labelRevision`, and names its
/// mentioners' rows (`rowsAffected`); and the backlinks of what the shapes it added, changed or
/// removed mention, and of what those rows mention, change (`backlinkRevision`). A commit that only
/// moved shapes (a drag) changes no text and no name, so it costs nothing here; nor does showing
/// another board (but that every shape's backlinks are listed in another order, that board's
/// first), since the index and the resolutions are the file's, kept up to date by each commit, the
/// shapes it changed on other boards (`ChangeSet.elsewhere`: the boards a deletion took or a paste
/// brought, a write to a board that isn't shown) included. The catalog is the file's too (the `@` picker lists what's on any
/// board the editor can show): read whole as the editor opens, or a file or board is put in place,
/// and kept up to date the same way.
@MainActor
@Observable
public final class MentionState {
    @ObservationIgnored private unowned let editor: CanvasEditor
    public var registry: Registry { editor.registry }

    /// How each shape that's mentioned (anywhere in the file) or observed shows now.
    @ObservationIgnored private var resolutions: [ShapeID: MentionResolution] = [:]
    /// +1 for a target each time its resolution changes, observed a target at a time.
    @ObservationIgnored private var revisions: [ShapeID: Int] = [:]
    /// +1 for a target each time what mentions it may have changed (`backlinkRevision`), and the
    /// targets whose revision was read since it last changed: only those can have an observer to
    /// tell, so a commit tells no one else.
    @ObservationIgnored private var backlinkRevisions: [ShapeID: Int] = [:]
    @ObservationIgnored private var backlinksRead: Set<ShapeID> = []
    /// +1 each time another board is shown, where every shape's mentioners are listed that board's
    /// first.
    @ObservationIgnored private var boardsShown = 0

    /// Each observation's targets and closure, by its key, and the keys observing each target.
    @ObservationIgnored private var observations: [Int: Observer] = [:]
    @ObservationIgnored private var observersByTarget: [ShapeID: Set<Int>] = [:]
    @ObservationIgnored private var nextObservation = 0

    /// Every mentionable shape on every board the editor can show that its kind names (not the
    /// "Untitled …" placeholder), ready to match.
    @ObservationIgnored private var catalog = MentionCatalog()
    /// Those a commit changed since, on any board, to read again at the next query.
    @ObservationIgnored private var stale: Set<ShapeID> = []
    @ObservationIgnored private var kindDefaults: [ShapeKind: MentionKindDefaults] = [:]

    /// This editor's picks, the latest first; never saved.
    @ObservationIgnored private var recent: [ShapeID] = []

    /// The revision the resolutions are up to date with, and the rows its last commit affected: the
    /// table of contents hears each commit first, and asks (`rowsAffected`) before this service
    /// hears it.
    @ObservationIgnored private var heardRevision: Int
    @ObservationIgnored private var lastAffected: Set<ShapeID> = []
    /// Mentions, as Topology's edges: made once, as a filter's types are a set.
    @ObservationIgnored private let mentionEdges = EdgeTypeFilter.only(MentionEdge.id)

    /// Who mentions whom: Topology's index, made before this service (so it hears each commit
    /// first), and brought up to date when this one is asked about a commit first (`catchUp`).
    @ObservationIgnored private let topology: TopologyIndex?

    #if DEBUG
    /// How many catalog entries have been read (debug builds), so tests can hold a commit to what it
    /// changed. The mention text read is Topology's (`recordsRead`).
    @ObservationIgnored public private(set) var entriesRead = 0
    /// What each panel's Mentioned In list last showed, by the shape it's in, each time it draws
    /// (debug builds): its lines are drawn by SwiftUI, which a test can't read. A test clears it to
    /// see whether a list draws again.
    @ObservationIgnored public var backlinksShown: [ShapeID: [MentionBacklink]] = [:]
    #endif

    init(editor: CanvasEditor) {
        self.editor = editor
        topology = editor.topology
        heardRevision = editor.revision
        trackMentioned()
        readCatalog()
    }

    /// Resolves every shape that's mentioned anywhere in the file.
    private func trackMentioned() {
        for edge in topology?.edges(ofType: mentionEdges) ?? [] { track(edge.target) }
    }

    // MARK: Reading

    /// The shapes that mention `target`, each once, on any board of the file the editor can show:
    /// those on the board shown in document order, then those on the other boards in the file's
    /// order (a board's in its order, each board where its owner is, depth first). `target` needn't
    /// be anywhere.
    public func mentioners(of target: ShapeID) -> [ShapeID] {
        ordered(mentionerSet(of: target), shown: editor.document, in: editor.file)
    }

    /// Shapes of the file in `mentioners(of:)`'s order: those on `document` (the board shown) in its
    /// order, then the others in the file's.
    private func ordered(_ ids: Set<ShapeID>, shown document: CanvasDocument, in file: CanvasFile) -> [ShapeID] {
        guard !ids.isEmpty else { return [] }
        var shown: [(id: ShapeID, index: Int)] = [], away: [(id: ShapeID, place: [Int])] = []
        for id in ids {
            if let index = document.index(of: id) {
                shown.append((id, index))
            } else {
                away.append((id, place(of: id, in: file)))
            }
        }
        return shown.sorted { $0.index < $1.index }.map(\.id) + away.sorted { $0.place.lexicographicallyPrecedes($1.place) }.map(\.id)
    }

    /// Where a shape is in the file's order: the indices, root first, of each owner on the way down
    /// to it, then its own on its board.
    private func place(of id: ShapeID, in file: CanvasFile) -> [Int] {
        var place: [Int] = [], current = id, met: Set<ShapeID> = []
        while met.insert(current).inserted, let board = file.board(containing: current), let index = file[board].index(of: current) {
            place.append(index)
            guard let owner = board.owner else { break }
            current = owner
        }
        return place.reversed()
    }

    /// The shapes whose mention text mentions `target`, in no order.
    private func mentionerSet(of target: ShapeID) -> Set<ShapeID> {
        guard let topology else { return [] }
        return Set(topology.edges(of: target, .incoming, types: mentionEdges).lazy.map(\.carrier))
    }

    /// Whether any shape's mention text mentions `target`, anywhere in the file, its own included:
    /// whether its resolution is kept.
    private func isMentionedAnywhere(_ target: ShapeID) -> Bool {
        topology?.hasEdges(of: target, .incoming, types: mentionEdges) ?? false
    }

    /// The shapes a shape's mention text mentions, in text order, each once.
    public func mentions(in shape: ShapeID) -> [ShapeID] {
        var seen: Set<ShapeID> = []
        return (topology?.edges(carriedBy: shape) ?? []).compactMap { edge in
            edge.type == MentionEdge.id && seen.insert(edge.target).inserted ? edge.target : nil
        }
    }

    // MARK: What mentions a shape

    /// Whether another shape mentions `target`, on any board of the file the editor can show (a
    /// shape's mention of itself doesn't count). It reads the target's own mentions, never a board.
    /// It stops at the first, and makes nothing: it's the Mentioned In section's `shownWhile`, asked
    /// on every commit (a drag's every event).
    public func isMentioned(_ target: ShapeID) -> Bool {
        topology?.hasEdges(of: target, .incoming, types: mentionEdges) { $0.carrier != target } ?? false
    }

    /// The shapes whose mention text mentions any of `targets`, but the targets themselves (their
    /// mentions of themselves), each once, in no order.
    private func mentionersOfAny(_ targets: [ShapeID]) -> Set<ShapeID> {
        var found: Set<ShapeID> = []
        for target in targets {
            for edge in topology?.edges(of: target, .incoming, types: mentionEdges) ?? [] where edge.carrier != target {
                found.insert(edge.carrier)
            }
        }
        return found
    }

    /// What mentions `target`, on any board of the file the editor can show, in `mentioners(of:)`'s
    /// order (the board shown's first), the target itself left out: each mentioner as it's called
    /// where it's mentioned (else its title, else its kind), and its text around its first mention
    /// of the target, with the names its mentions show now. It reads the target's own edges, how
    /// each shape the file mentions shows, and its mentioners' records, from the board shown and the
    /// file without observing them (`withoutObservingDocument`), so a view that reads it redraws
    /// only as `backlinkRevision` says, never on every commit; and it keeps no copy of the file, which
    /// would make the next commit that adds or removes shapes copy its table of where each is.
    public func backlinks(of target: ShapeID) -> [MentionBacklink] {
        editor.withoutObservingDocument {
            let document = editor.document, file = editor.file
            return ordered(mentionersOfAny([target]), shown: document, in: file).compactMap { id in
                guard let record = document[id] ?? file.record(id) else { return nil }
                let name = backlinkName(of: record)
                return MentionBacklink(id: id, label: name.label, systemImage: name.systemImage, quote: quote(of: record, around: target) ?? "",
                                       tint: name.tint)
            }
        }
    }

    /// A target's backlinks' revision: it changes each time `backlinks(of:)` or `isMentioned` may
    /// read differently: a commit that adds, changes or removes a shape that mentions it, or
    /// mentioned it, on any board (not one that only moves it: a drag costs nothing), or that
    /// changes a name one of its mentioners' quotes shows; and a switch of board, after which the
    /// new board's mentioners come first. Reading it observes only that target, so a
    /// SwiftUI view of one shape's backlinks redraws when they change, as `labelRevision` does.
    public func backlinkRevision(of target: ShapeID) -> Int {
        backlinksRead.insert(target)
        access(keyPath: \.[backlinks: target])
        access(keyPath: \.boardsShownKey)
        return (backlinkRevisions[target] ?? 0) + boardsShown
    }

    /// Only keys, as `[revision:]` is.
    private subscript(backlinks target: ShapeID) -> Int { backlinkRevisions[target] ?? 0 }
    private var boardsShownKey: Int { boardsShown }

    /// Goes to what mentions `targets` (their mentioners, each target's own mention of itself left
    /// out) as following a mention goes to its target (`editor.goTo`: one step back, and the camera
    /// brings them into view): those on the board shown, if any are, else those on the board of the
    /// first in `mentioners(of:)`'s order, which it shows. On the scheduler's next turn: from a menu
    /// in text being edited, going ends the editing that menu's view is part of. Nothing, if nothing
    /// mentions them.
    public func showWhatMentions(_ targets: [ShapeID]) {
        _ = editor.scheduler.schedule(after: .zero) { [weak self] in self?.goToMentioners(of: targets) }
    }

    private func goToMentioners(of targets: [ShapeID]) {
        editor.endEditing()                                     // what the text saves as it closes, indexed first
        let mentioners = ordered(mentionersOfAny(targets), shown: editor.document, in: editor.file)
        guard !mentioners.isEmpty else { return }
        editor.goTo(mentioners)
    }

    /// Goes to a mentioner (`editor.goTo`: its board shown first, if it's on another; one step
    /// back) on the scheduler's next turn, as a Mentioned In line does.
    func goToMentioner(_ id: ShapeID) {
        _ = editor.scheduler.schedule(after: .zero) { [weak editor] in editor?.goTo([id]) }
    }

    /// How a mentioner is named in a backlink: as it's mentioned, if it can be; else by its title,
    /// else its kind's label; with its kind's symbol, and the tint it's mentioned with.
    private func backlinkName(of record: AnyShapeRecord) -> (label: String, systemImage: String, tint: NSColor?) {
        if let appearance = appearance(of: record) { return (appearance.label, appearance.systemImage, appearance.tint) }
        let kind = registry.label(of: record.kind)
        return (oneLine(registry.title(of: record)) ?? kind.name, kind.systemImage ?? MentionStyle.unknownSymbol, nil)
    }

    /// The quote around a mentioner's first mention of `target`: in the first of its texts that
    /// mentions it, wherever the shape keeps it.
    private func quote(of record: AnyShapeRecord, around target: ShapeID) -> String? {
        guard !record.isOpaque else { return nil }
        var quote: String?
        record.forEachNamingValue(in: registry) { _, value in
            guard quote == nil else { return }
            value.forEachNamingLeaf { leaf in
                guard quote == nil, let text = leaf as? any MentionTextHolding else { return }
                var runs: [MentionRun] = []
                text.forEachMentionRun { runs.append($0) }
                // Every shape the file mentions is tracked, so its name is kept.
                quote = MentionQuote.quote(runs, around: target, length: MentionStyle.quoteLength) {
                    (resolutions[$0] ?? resolve($0)).appearance?.label
                }
            }
        }
        return quote
    }

    /// What a mention of `target` shows now: live wherever it is in the file, on the board shown or
    /// another the editor can show; unavailable on a board it can't show (the app keeps it without
    /// using it, so it isn't followed there); missing if it isn't in the file.
    public func resolve(_ target: ShapeID) -> MentionResolution {
        if let record = editor.document[target] { return resolve(record) }
        return resolve(elsewhere: target, in: editor.file)
    }

    /// What a mention of a shape that isn't on the board shown shows, in the file as it is.
    private func resolve(elsewhere target: ShapeID, in file: CanvasFile) -> MentionResolution {
        guard file.board(containing: target) != nil else { return .missing }
        return editor.shape(inFile: target).map(resolve) ?? .unavailable
    }

    /// What a mention of a shape shows, found (nil: missing).
    private func resolve(_ record: AnyShapeRecord?) -> MentionResolution {
        guard let record else { return .missing }
        return appearance(of: record).map { .live($0) } ?? .unavailable
    }

    /// Whether `target` is on the board shown: what hovering it can outline.
    func isShown(_ target: ShapeID) -> Bool { editor.document[target] != nil }

    /// The text as plain text, each mention "@" and its target's live name, or the name it holds
    /// where its target isn't live.
    public func plainText<S>(_ text: ScopedMentionText<S>) -> String {
        text.plainText { resolve($0).appearance?.label }
    }

    /// The names mentions show now, to read anywhere (`MentionLabels`): for every shape the file
    /// mentions, what `plainText` reads, so `text.plainText { labels.label(of: $0) }` is
    /// `plainText(text)` for the text of any shape the editor can show. Taking them costs nothing:
    /// they share what the state keeps, which the next change to it (a rename, a shape mentioned
    /// anew) copies once while they're held. They're as of the last commit the state heard: every
    /// commit, but to a service hearing one.
    public var labels: MentionLabels { MentionLabels(resolutions) }

    /// A target's revision: +1 each time what a mention of it shows changes. Reading it observes
    /// only that target, so a SwiftUI view of a pill redraws when its own target changes.
    public func labelRevision(of target: ShapeID) -> Int {
        access(keyPath: \.[revision: target])
        return revisions[target] ?? 0
    }

    /// Only a key: one key path per target, under which Observation keeps each target's observers.
    private subscript(revision target: ShapeID) -> Int { revisions[target] ?? 0 }

    /// Calls `changed` with those of `targets` whose resolution a commit changed, once per commit,
    /// as it hears it (an AppKit view's pills: it updates their images, and transacts nothing).
    /// Until the observation is cancelled, or let go of.
    public func observe(_ targets: Set<ShapeID>, _ changed: @escaping @MainActor (Set<ShapeID>) -> Void) -> MentionObservation {
        let key = nextObservation
        nextObservation += 1
        observations[key] = Observer(targets: targets, changed: changed)
        for target in targets {
            observersByTarget[target, default: []].insert(key)
            track(target)
        }
        return MentionObservation(state: self, key: key)
    }

    /// Ends an observation: its closure isn't called again.
    fileprivate func cancel(_ key: Int) {
        guard let observer = observations.removeValue(forKey: key) else { return }
        for target in observer.targets {
            observersByTarget[target]?.remove(key)
            if observersByTarget[target]?.isEmpty == true { observersByTarget[target] = nil }
            untrackIfUnused(target)
        }
    }

    /// The mentioners whose rows a commit may change without changing them: those of the targets
    /// whose resolution it changed. Answers for the commit it's given the first time it's asked
    /// about a revision, and from then on as it answered; and, asked again with shapes elsewhere
    /// (what changed on other boards while the board shown wasn't, which the table of contents
    /// hands its rows on going back to it), the mentioners of those shapes too.
    public func rowsAffected(by changes: ChangeSet) -> Set<ShapeID> {
        if heardRevision != editor.revision {
            hear(changes)
            return lastAffected
        }
        guard !changes.elsewhere.isEmpty else { return lastAffected }
        var affected = lastAffected
        for id in changes.elsewhere { affected.formUnion(mentionerSet(of: id)) }
        return affected
    }

    // MARK: Going to and hovering

    /// Follows a mention of the target on the next turn of the scheduler (`editor.followMention`:
    /// ends editing, goes to it or into it; ⌘[ comes back): a click inside the text being edited is
    /// still being tracked by the view that going ends.
    public func follow(_ target: ShapeID) {
        _ = editor.scheduler.schedule(after: .zero) { [weak editor] in editor?.followMention(of: target) }
    }

    /// Hovers the target (`editor.hovered`): outlined faintly on the canvas, its row tinted. Only
    /// one on the board shown: one elsewhere has neither there.
    public func hover(_ target: ShapeID) {
        guard isShown(target) else { return }
        editor.hovered = target
    }

    /// Ends the target's hover, only if it's still what's hovered.
    public func endHover(_ target: ShapeID) {
        if editor.hovered == target { editor.hovered = nil }
    }

    // MARK: The picker's candidates

    /// A pick: it's first among the recent ones.
    public func didPick(_ target: ShapeID) {
        let previous = recent
        recent.removeAll { $0 == target }
        recent.insert(target, at: 0)
        if recent.count > MentionRanking.recentKept { recent.removeLast(recent.count - MentionRanking.recentKept) }
        catalog.markRecent(recent, previous: previous)
    }

    /// What the `@` picker lists for `query` in text of `scope`, on `owner` (the text's shape, which
    /// may mention itself: it's left out of an empty query's Nearby, where it would always be
    /// first, and of a typed query's matches while its name holds what's typed, as a note's does
    /// when the `@` is in its first line; nearness is measured from it): every mentionable shape
    /// the scope admits on any board of the file the editor can show, but those kept aside and
    /// those its kind gives no name (called by the "Untitled …" placeholder: a mention of one
    /// stays, but there's no point picking it). An empty query lists recent picks, then the shapes nearest the
    /// owner on the board shown and, while there's room, the shapes whose boards it's inside, the
    /// board shown's own first; any other, one ranked list of the best matches (`CaretListMatcher`'s
    /// tiers, then `MentionRanking`'s adjustments, nearness on the board shown among them; ties to
    /// the shorter label, then the front-most shape, the board shown's before any other's).
    public func candidates<S: MentionScope>(matching query: String, in scope: S.Type, for owner: ShapeID?) -> MentionCandidates {
        refreshStale()
        let document = editor.document, file = editor.file, registry = registry
        let admitsAll = S.self == AnyMentionable.self
        /// Whether the scope admits a shape in the catalog: every one, for `AnyMentionable`.
        func admits(_ id: ShapeID) -> Bool {
            admitsAll || (document[id] ?? file.record(id)).map { S.admits($0, in: registry) } ?? false
        }
        let shapes = editor.shapeContext
        let origin = owner.flatMap { shapes.geometry(of: $0)?.bounds }.map { CGPoint(x: $0.midX, y: $0.midY) }
        func distance(_ id: ShapeID) -> Double? {
            guard let origin, let bounds = shapes.geometry(of: id)?.bounds else { return nil }
            return Double(hypot(bounds.midX - origin.x, bounds.midY - origin.y))
        }

        let q = CaretListMatcher.Query(query)
        guard !q.isEmpty else {
            let recentShown = Array(recent.lazy.filter { self.catalog.contains($0) && admits($0) }
                .prefix(MentionRanking.recentShown)).map { candidate($0, matched: []) }
            var taken = Set(recentShown.map(\.id))
            if let owner { taken.insert(owner) }
            var nearby = origin.map { nearest(to: $0, excluding: taken, admits: admits, distance: distance) } ?? []
            taken.formUnion(nearby)
            for inside in editor.boardPath.reversed().lazy.compactMap(\.owner) where nearby.count < MentionRanking.nearbyShown {
                if !taken.contains(inside), catalog.contains(inside), admits(inside) { nearby.append(inside) }
            }
            return MentionCandidates(recent: recentShown, nearby: nearby.map { candidate($0, matched: []) }, matches: [])
        }

        // A shape named by its own text (a note's first line) holds the `@query` being typed in its
        // name, so it would match what's typed: it's left out then, listed once its name says more.
        let typed = "@" + query.trimmingCharacters(in: .whitespacesAndNewlines)
        let leavesOutOwner = owner.flatMap { catalog.appearance(of: $0) }.map { $0.label.range(of: typed, options: [.caseInsensitive, .diacriticInsensitive]) != nil } ?? false

        // Two linear passes over the catalog's keys, as every caret list matches (`rank`): every
        // tier but the typo's, then, if that found few, the typo's over the rest.
        var found: [Found] = []
        q.withView { view in
            catalog.keys.withUnsafeBufferPointer { keys in
                catalog.entries.withUnsafeBufferPointer { entries in
                    CaretListMatcher.rank(view, count: entries.count, wantSpans: false, label: { slot in
                        let entry = entries[slot]
                        guard !(leavesOutOwner && entry.id == owner), admits(entry.id) else { return nil }
                        return UnsafeBufferPointer(rebasing: keys[entry.start..<entry.start + entry.count])
                    }) { slot, score, _ in found.append(Found(slot: slot, score: score)) }
                }
            }
        }
        let entries = catalog.entries
        for i in found.indices {
            let entry = entries[found[i].slot]
            if entry.recentRank >= 0 {
                found[i].score += MentionRanking.recentBonus * (MentionRanking.recentKept - entry.recentRank) / MentionRanking.recentKept
            }
        }
        /// Lower score, then longer label, then further back.
        func isWorse(_ a: Found, _ b: Found) -> Bool {
            if a.score != b.score { return a.score < b.score }
            let al = entries[a.slot].labelLength, bl = entries[b.slot].labelLength
            if al != bl { return al > bl }
            return (document.index(of: entries[a.slot].id) ?? 0) < (document.index(of: entries[b.slot].id) ?? 0)
        }
        // Nearness, for the best only: whatever it adds, the rest can't pass them.
        var best = BoundedHeap<Found>(capacity: MentionRanking.nearnessCandidates, isWorse: isWorse)
        for scored in found { best.insert(scored) }
        var ranked = best.sorted()
        if origin != nil {
            for i in ranked.indices {
                guard let d = distance(entries[ranked[i].slot].id) else { continue }
                ranked[i].score += Int((Double(MentionRanking.nearnessBonus) / (1 + d / MentionRanking.nearnessScale)).rounded())
            }
            ranked.sort { isWorse($1, $0) }
        }
        let matches = ranked.prefix(MentionRanking.maxMatches).map { found in
            let id = entries[found.slot].id
            let label = catalog.appearances[found.slot].label
            return candidate(id, matched: CaretListMatcher.match(q, in: CaretListMatcher.Label(label))?.matched ?? [])
        }
        return MentionCandidates(recent: [], nearby: [], matches: matches)
    }

    /// The shapes in the catalog on the board shown nearest `origin` the scope admits, up to
    /// `nearbyShown`, nearest first: looked for in a square around it, grown until it holds enough,
    /// so a board of many mentionable shapes costs what's around the text; else in the board's
    /// entries of the catalog. A square's shapes are gathered from the whole board, so once one
    /// holds as many shapes as the board has in the catalog, reading those costs less than growing
    /// it again: a board with few mentionable shapes, or few the scope admits, reads its entries
    /// after at most one square that holds them all.
    private func nearest(to origin: CGPoint, excluding taken: Set<ShapeID>, admits: (ShapeID) -> Bool,
                         distance: (ShapeID) -> Double?) -> [ShapeID] {
        let wanted = MentionRanking.nearbyShown
        func best(of ids: some Sequence<ShapeID>) -> [(id: ShapeID, distance: Double)] {
            var heap = BoundedHeap<(id: ShapeID, distance: Double)>(capacity: wanted) { $0.distance > $1.distance }
            for id in ids where !taken.contains(id) && catalog.contains(id) && admits(id) {
                if let d = distance(id) { heap.insert((id, d)) }
            }
            return heap.sorted()
        }
        // A board of no more than the shapes it could list, and those it leaves out, is read whole.
        let board = editor.board, onBoard = catalog.count(on: board)
        let searchesSquares = onBoard > wanted + taken.count
        var half: CGFloat = MentionStyle.nearbySearch
        for _ in 0..<MentionStyle.nearbySearchSteps where searchesSquares {
            let square = CGRect(x: origin.x - half, y: origin.y - half, width: 2 * half, height: 2 * half)
            let shapes = editor.paintOrder(in: square)
            let found = best(of: shapes.lazy.map(\.id))
            if found.count == wanted, found[wanted - 1].distance <= Double(half) { return found.map(\.id) }
            if shapes.count >= onBoard { break }
            half *= 4
        }
        return best(of: catalog.entries.lazy.filter { $0.board == board }.map(\.id)).map(\.id)
    }

    private func candidate(_ id: ShapeID, matched: [Range<Int>]) -> MentionCandidate {
        MentionCandidate(id: id, appearance: catalog.appearance(of: id)!, isReadOnly: isReadOnly(id), matched: matched)
    }

    /// Whether a shape, on whichever board of the file it's on, can't change, as that board goes by
    /// it: locked, or in a locked frame, at any depth (`registry.isReadOnly(_:in:)`). O(its depth).
    private func isReadOnly(_ id: ShapeID) -> Bool {
        let document = editor.document
        if let record = document[id] { return registry.isReadOnly(record, in: document) }
        let file = editor.file
        guard let board = file.board(containing: id) else { return false }
        let holding = file[board]
        return holding[id].map { registry.isReadOnly($0, in: holding) } ?? false
    }

    // MARK: Following the document

    /// What a commit changed, applied: what's mentioned (Topology's index, brought up to date with
    /// it first), the resolutions, the catalog; then the observers of the targets whose resolution
    /// changed, and the rows it affects.
    private func hear(_ changes: ChangeSet) {
        heardRevision = editor.revision
        // The targets whose backlinks the commit may change (`backlinkRevision`): the shapes whose
        // mentions it added or removed, and what the shapes it added or changed mention, on any
        // board (an edit that keeps a mention changes its quote, and no edge).
        var backlinksChanged: Set<ShapeID> = []
        if let topology {
            topology.catchUp(changes)
            // The shapes whose mentions it changed, at either end (another type's edges, an arrow
            // bound to a mentioned shape, change none of what mentions it): those mentioned now are
            // tracked, and those no longer mentioned (nor observed) aren't. Those mentioned before
            // (so tracked) or by another shape now may read other backlinks; `touched` doesn't say
            // which mentions changed, so one mentioned before only by itself counts too, though a
            // shape's own text is none of its backlinks.
            for id in topology.touched(types: mentionEdges) {
                let isTracked = resolutions[id] != nil
                let isMentioned = isMentionedAnywhere(id)
                if isTracked || (isMentioned && self.isMentioned(id)) { backlinksChanged.insert(id) }
                guard observersByTarget[id] == nil else { continue }
                if isMentioned, !isTracked {
                    resolutions[id] = resolve(id)
                } else if !isMentioned, isTracked {
                    resolutions[id] = nil
                }
            }
            for id in changes.added where !changes.moved.contains(id) { noteTargets(of: id, into: &backlinksChanged) }
            for id in changes.changed where !changes.moved.contains(id) { noteTargets(of: id, into: &backlinksChanged) }
            for id in changes.elsewhere { noteTargets(of: id, into: &backlinksChanged) }
        }
        for id in changes.removed {
            catalog.remove(id)
            stale.remove(id)
        }
        for id in changes.added where !changes.moved.contains(id) { stale.insert(id) }
        for id in changes.changed where !changes.moved.contains(id) { stale.insert(id) }
        var changedTargets: Set<ShapeID> = []
        for id in changes.shapeIDs where !changes.moved.contains(id) { resolveAgain(id, into: &changedTargets) }
        // Shapes on other boards it reached: those a deletion took with a board, or a paste
        // brought, or a write to a board that isn't shown changed.
        for id in changes.elsewhere { resolveAgain(id, into: &changedTargets) }
        stale.formUnion(changes.elsewhere)
        lastAffected = changedTargets.reduce(into: Set<ShapeID>()) { $0.formUnion(mentionerSet(of: $1)) }
        // A mentioner whose mentions show another name now quotes it.
        for mentioner in lastAffected { noteTargets(of: mentioner, into: &backlinksChanged) }
        if changes.replacedDocument { readCatalog() }                   // a board or file put in place: read now, not at the first `@`
        tell(changedTargets)
        bumpBacklinks(backlinksChanged)
    }

    /// Notes what a shape's mention text mentions now, but itself.
    private func noteTargets(of id: ShapeID, into targets: inout Set<ShapeID>) {
        for edge in topology?.edges(carriedBy: id) ?? [] where edge.type == MentionEdge.id && edge.target != id {
            targets.insert(edge.target)
        }
    }

    /// Bumps the targets' backlink revisions, telling only the observers of those read since they
    /// last changed (an observer reads what it observes, and hears one change).
    private func bumpBacklinks(_ targets: Set<ShapeID>) {
        for target in targets {
            if backlinksRead.remove(target) != nil {
                withMutation(keyPath: \.[backlinks: target]) { backlinkRevisions[target, default: 0] += 1 }
            } else {
                backlinkRevisions[target, default: 0] += 1
            }
        }
    }

    /// Resolves a tracked target again, noting it in `changed` if what it shows changed.
    private func resolveAgain(_ id: ShapeID, into changed: inout Set<ShapeID>) {
        guard let before = resolutions[id] else { return }
        let now = resolve(id)
        if now != before {
            resolutions[id] = now
            changed.insert(id)
        }
    }

    /// Bumps the revisions of the targets whose resolution changed, and tells their observers.
    private func tell(_ changedTargets: Set<ShapeID>) {
        guard !changedTargets.isEmpty else { return }
        for target in changedTargets {
            withMutation(keyPath: \.[revision: target]) { revisions[target, default: 0] += 1 }
        }
        var notified: [Int: Set<ShapeID>] = [:]
        for target in changedTargets {
            for key in observersByTarget[target] ?? [] { notified[key, default: []].insert(target) }
        }
        // In the order they began; one cancelled by another's closure isn't called.
        for key in notified.keys.sorted() {
            guard let observer = observations[key], let targets = notified[key] else { continue }
            observer.changed(targets)
        }
    }

    private func track(_ target: ShapeID) {
        if resolutions[target] == nil { resolutions[target] = resolve(target) }
    }

    private func untrackIfUnused(_ target: ShapeID) {
        if observersByTarget[target] == nil, !isMentionedAnywhere(target) { resolutions[target] = nil }
    }

    // MARK: The catalog

    /// Reads the catalog afresh: every mentionable shape on every board the editor can show, which
    /// are the root and, from it down, the boards whose owners own showable boards
    /// (`registry.ownsShowableBoard`, what `canShow` asks of each owner on a path), each once.
    private func readCatalog() {
        catalog = MentionCatalog()
        stale = []
        let children = editor.file.children
        var boards: [BoardID] = [.root], met: Set<BoardID> = [.root], next = 0
        while next < boards.count {
            let board = boards[next]
            next += 1
            for record in editor.contents(of: board).shapes {
                readEntry(record, on: board)
                let owned = BoardID(owner: record.id)
                if children[record.id] != nil, registry.ownsShowableBoard(record), met.insert(owned).inserted { boards.append(owned) }
            }
        }
    }

    /// Reads again the entries commits made stale, wherever they are: out of the catalog if they're
    /// on no board the editor can show.
    private func refreshStale() {
        guard !stale.isEmpty else { return }
        let document = editor.document, board = editor.board, file = editor.file
        for id in stale {
            if let record = document[id] {
                readEntry(record, on: board)
            } else if let record = editor.shape(inFile: id), let elsewhere = file.board(containing: id) {
                readEntry(record, on: elsewhere)
            } else {
                catalog.remove(id)
            }
        }
        stale = []
    }

    /// A shape's catalog entry, read again: out of the catalog if it can't be mentioned, or its kind
    /// gives it no name.
    private func readEntry(_ record: AnyShapeRecord, on board: BoardID) {
        guard let appearance = appearance(of: record), !appearance.isPlaceholder else {
            catalog.remove(record.id)
            return
        }
        #if DEBUG
        entriesRead += 1
        #endif
        catalog.set(record.id, appearance, on: board, recentRank: recent.firstIndex(of: record.id) ?? -1)
    }

    /// How a shape shows where it's mentioned, with its kind's defaults found once.
    private func appearance(of record: AnyShapeRecord) -> MentionAppearance? {
        guard !record.isOpaque else { return nil }
        let defaults: MentionKindDefaults
        if let found = kindDefaults[record.kind] {
            defaults = found
        } else {
            defaults = MentionKindDefaults(record.kind, in: registry)
            kindDefaults[record.kind] = defaults
        }
        return registry.mentionAppearance(of: record, defaults: defaults)
    }
}

extension MentionState: EditorService {
    /// Follows the commit, unless the table of contents asked about it first (`rowsAffected`).
    public func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        guard heardRevision != editor.revision else { return }
        hear(changes)
    }

    /// Nothing, but for a file put in place with the switch: what's mentioned, how each shows, and
    /// the catalog are the file's, kept up to date by every commit, whatever board it was on, so
    /// showing another board reads no mention text and resolves nothing. A file put in place has
    /// what it mentions resolved and its catalog read afresh. Recent picks and observations stay
    /// (the views observing pills of the board left go with it).
    public func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        heardRevision = editor.revision
        lastAffected = []
        // Every shape's backlinks list the new board's mentioners first.
        withMutation(keyPath: \.boardsShownKey) { boardsShown += 1 }
        backlinksRead = []
        guard change.isFileReplaced else { return }
        resolutions = [:]
        trackMentioned()
        for target in observersByTarget.keys { track(target) }
        readCatalog()
    }
}

extension CanvasEditor {
    /// Mentions' state; nil without MentionsPlugin.
    public var mentions: MentionState? { service(MentionState.self) }

    /// Follows a mention of `target`, wherever it is in the file, as its kind has it
    /// (`MentionFollowing`): into it (`goInto`: a subboard shows its board), or to it (`goTo`).
    func followMention(of target: ShapeID) {
        let following = file.record(target).flatMap { registry.mentionContribution(for: $0.kind) }?.following
        if following == .opens { goInto(target) } else { goTo([target]) }
    }
}

/// An observation of targets (`MentionState.observe`): it lasts until it's cancelled, or let go of.
@MainActor
public final class MentionObservation {
    private weak var state: MentionState?
    private let key: Int

    fileprivate init(state: MentionState, key: Int) {
        self.state = state
        self.key = key
    }

    /// Stops it: its closure isn't called again.
    public func cancel() {
        state?.cancel(key)
        state = nil
    }

    /// Let go of, it stops as cancelled, so the state keeps no closure of an observer that's gone.
    deinit {
        guard let state else { return }
        let key = key
        if Thread.isMainThread {
            MainActor.assumeIsolated { state.cancel(key) }
        } else {
            Task { @MainActor in state.cancel(key) }
        }
    }
}

/// An observation as the state keeps it.
@MainActor
private struct Observer {
    let targets: Set<ShapeID>
    let changed: @MainActor (Set<ShapeID>) -> Void
}

/// A shape the picker can list: how it shows, whether it's read-only (a lock beside its name: it's
/// locked, or in a locked frame), and which characters of its label the query matched (`Character`
/// offsets).
public struct MentionCandidate: Hashable, Sendable {
    public let id: ShapeID
    public let appearance: MentionAppearance
    public let isReadOnly: Bool
    public let matched: [Range<Int>]

    public init(id: ShapeID, appearance: MentionAppearance, isReadOnly: Bool, matched: [Range<Int>]) {
        self.id = id
        self.appearance = appearance
        self.isReadOnly = isReadOnly
        self.matched = matched
    }
}

/// What the picker lists: for an empty query, recent picks and nearby shapes; for any other, the
/// best matches, best first.
public struct MentionCandidates: Hashable, Sendable {
    public var recent: [MentionCandidate]
    public var nearby: [MentionCandidate]
    public var matches: [MentionCandidate]

    public init(recent: [MentionCandidate] = [], nearby: [MentionCandidate] = [], matches: [MentionCandidate] = []) {
        self.recent = recent
        self.nearby = nearby
        self.matches = matches
    }

    /// Every row, in order.
    public var all: [MentionCandidate] { recent + nearby + matches }
}

/// A catalog entry a query matched, by its slot, and its score.
private struct Found {
    let slot: Int
    var score: Int
}

/// The best `capacity` of what's inserted: a heap with the worst on top, so each insert costs a
/// logarithm of the capacity, whatever was inserted before.
struct BoundedHeap<Element> {
    let capacity: Int
    let isWorse: (Element, Element) -> Bool
    private var heap: [Element] = []

    init(capacity: Int, isWorse: @escaping (Element, Element) -> Bool) {
        self.capacity = capacity
        self.isWorse = isWorse
    }

    mutating func insert(_ element: Element) {
        guard capacity > 0 else { return }
        if heap.count < capacity {
            heap.append(element)
            siftUp(heap.count - 1)
        } else if isWorse(heap[0], element) {
            heap[0] = element
            siftDown(0)
        }
    }

    /// Best first.
    func sorted() -> [Element] { heap.sorted { isWorse($1, $0) } }

    private mutating func siftUp(_ index: Int) {
        var child = index
        while child > 0 {
            let parent = (child - 1) / 2
            guard isWorse(heap[child], heap[parent]) else { return }
            heap.swapAt(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(_ index: Int) {
        var parent = index
        while true {
            let left = 2 * parent + 1, right = left + 1
            var worst = parent
            if left < heap.count, isWorse(heap[left], heap[worst]) { worst = left }
            if right < heap.count, isWorse(heap[right], heap[worst]) { worst = right }
            guard worst != parent else { return }
            heap.swapAt(parent, worst)
            parent = worst
        }
    }
}

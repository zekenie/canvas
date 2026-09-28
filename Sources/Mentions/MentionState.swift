import AppKit
import Canvas
import Observation
import Selection

/// What Mentions knows about an editor's board, one per editor: who mentions whom (both ways), how
/// each mentioned shape shows now, the catalog of shapes that can be mentioned (what the `@` picker
/// searches), and this editor's recent picks. It never transacts: it follows the document.
///
/// The index is built as the board opens (an editor made with a document, in `init`; one given a
/// board, through `replaceDocument`'s commit), walking only the kinds whose shapes can hold names
/// (`registry.namingKinds`). Each commit then costs what it changed: the mention text of the shapes
/// it added or changed is read again, and the shapes it touched that are mentioned are resolved
/// again; only a resolution that changed tells its observers, bumps its `labelRevision`, and names
/// its mentioners' rows (`rowsAffected`). A commit that only moved shapes (a drag) changes no text
/// and no name, so it costs nothing here.
///
/// In a file of several boards, the index and the catalog are the board shown's (the `@` picker
/// lists what's on it), kept for the boards shown lately; a board entered for the first time has
/// its mention text read on the way in, and its catalog on the scheduler's next turn, once it's on
/// screen (or at the first `@`, if that comes first). A mention names a shape anywhere in the
/// file, and shows it as it's called now: what a commit changes on other boards
/// (`ChangeSet.elsewhere`: the boards a deletion took or a paste brought, a write to a board that
/// isn't shown) is resolved again, and so, on going back to a board, is every shape its mentions
/// name on the others, which may have changed while it wasn't shown.
@MainActor
@Observable
public final class MentionState {
    @ObservationIgnored private unowned let editor: CanvasEditor
    public var registry: Registry { editor.registry }

    /// Each mentioning shape's targets, in text order, each once.
    @ObservationIgnored private var forward: [ShapeID: [ShapeID]] = [:]
    /// Each mentioned shape's mentioners, kept while they mention it, whether it's on the board or not.
    @ObservationIgnored private var backward: [ShapeID: Set<ShapeID>] = [:]
    /// How each shape that's mentioned or observed shows now.
    @ObservationIgnored private var resolutions: [ShapeID: MentionResolution] = [:]
    /// +1 for a target each time its resolution changes, observed a target at a time.
    @ObservationIgnored private var revisions: [ShapeID: Int] = [:]

    /// Each observation's targets and closure, by its key, and the keys observing each target.
    @ObservationIgnored private var observations: [Int: Observer] = [:]
    @ObservationIgnored private var observersByTarget: [ShapeID: Set<Int>] = [:]
    @ObservationIgnored private var nextObservation = 0

    /// Every mentionable shape on the board, ready to match.
    @ObservationIgnored private var catalog = MentionCatalog()
    /// Those a commit changed since, to read again at the next query.
    @ObservationIgnored private var stale: Set<ShapeID> = []
    /// False while the catalog of a board entered for the first time isn't read yet: the next
    /// query reads it whole, or the scheduler's next turn after the switch (`catalogTurn`), once the
    /// board is on screen, so entering a board doesn't wait for what only the `@` picker needs.
    @ObservationIgnored private var catalogIsRead = true
    @ObservationIgnored private var catalogTurn: ScheduledTask?
    @ObservationIgnored private var kindDefaults: [ShapeKind: MentionKindDefaults] = [:]

    /// This editor's picks, the latest first; never saved.
    @ObservationIgnored private var recent: [ShapeID] = []

    /// The revision the index is up to date with, and the rows its last commit affected: the table
    /// of contents hears each commit first, and asks (`rowsAffected`) before this service hears it.
    @ObservationIgnored private var heardRevision: Int
    @ObservationIgnored private var lastAffected: Set<ShapeID> = []

    /// The index and catalog of boards shown lately, for going back to them (`BoardStash`).
    @ObservationIgnored private var kept = BoardStash<Kept>()

    #if DEBUG
    /// How many shapes' mention text has been read, and how many catalog entries (debug builds), so
    /// tests can hold a commit to what it changed.
    @ObservationIgnored public private(set) var textsRead = 0
    @ObservationIgnored public private(set) var entriesRead = 0
    #endif

    init(editor: CanvasEditor) {
        self.editor = editor
        heardRevision = editor.revision
        index(editor.document)
    }

    /// Indexes a board as it opens: every shape's mention text, and every mentionable shape.
    private func index(_ document: CanvasDocument) {
        for record in document.shapes {
            reindex(record.id, record)
            readEntry(record)
        }
    }

    /// Indexes a board entered for the first time: every shape's mention text now (who mentions
    /// whom, for the rows and the pills), and the catalog on the scheduler's next turn, or at the
    /// first query if that comes first.
    private func indexEntered(_ document: CanvasDocument) {
        for record in document.shapes { reindex(record.id, record) }
        catalogIsRead = false
        catalogTurn?.cancel()
        catalogTurn = editor.scheduler.schedule(after: .zero) { [weak self] in
            self?.catalogTurn = nil
            self?.refreshStale()
        }
    }

    // MARK: Reading

    /// The shapes that mention `target`, in document order, each once. It needn't be on the board.
    public func mentioners(of target: ShapeID) -> [ShapeID] {
        guard let ids = backward[target] else { return [] }
        let document = editor.document
        return ids.compactMap { id in document.index(of: id).map { (id, $0) } }.sorted { $0.1 < $1.1 }.map(\.0)
    }

    /// The shapes a shape's mention text mentions, in text order, each once.
    public func mentions(in shape: ShapeID) -> [ShapeID] { forward[shape] ?? [] }

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
        for id in changes.elsewhere { affected.formUnion(backward[id] ?? []) }
        return affected
    }

    // MARK: Going to and hovering

    /// Goes to the target on the next turn of the scheduler (`editor.goTo`: ends editing, selects
    /// it, brings it into view; ⌘[ comes back): a click inside the text being edited is still being
    /// tracked by the view that going ends.
    public func follow(_ target: ShapeID) {
        _ = editor.scheduler.schedule(after: .zero) { [weak editor] in editor?.goTo([target]) }
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

    /// What the `@` picker lists for `query` in text of `scope`, on `owner` (the text's shape, never
    /// listed): every mentionable shape on the board the scope admits, but those kept aside. An
    /// empty query lists recent picks and the shapes nearest the owner; any other, one ranked list
    /// of the best matches (`MentionMatcher`'s tiers, then `MentionRanking`'s adjustments; ties to
    /// the shorter label, then the front-most shape).
    public func candidates<S: MentionScope>(matching query: String, in scope: S.Type, for owner: ShapeID?) -> MentionCandidates {
        refreshStale()
        let document = editor.document, registry = registry
        let admitsAll = S.self == AnyMentionable.self
        /// Whether the scope admits a shape in the catalog: every one, for `AnyMentionable`.
        func admits(_ id: ShapeID) -> Bool {
            admitsAll || document[id].map { S.admits($0, in: registry) } ?? false
        }
        let shapes = editor.shapeContext
        let origin = owner.flatMap { shapes.geometry(of: $0)?.bounds }.map { CGPoint(x: $0.midX, y: $0.midY) }
        func distance(_ id: ShapeID) -> Double? {
            guard let origin, let bounds = shapes.geometry(of: id)?.bounds else { return nil }
            return Double(hypot(bounds.midX - origin.x, bounds.midY - origin.y))
        }

        let q = MentionMatcher.Query(query)
        guard !q.isEmpty else {
            let recentShown = Array(recent.lazy.filter { $0 != owner && self.catalog.contains($0) && admits($0) }
                .prefix(MentionRanking.recentShown)).map { candidate($0, matched: []) }
            var taken = Set(recentShown.map(\.id))
            if let owner { taken.insert(owner) }
            let nearby = origin.map { nearest(to: $0, excluding: taken, admits: admits, distance: distance) } ?? []
            return MentionCandidates(recent: recentShown, nearby: nearby.map { candidate($0, matched: []) }, matches: [])
        }

        // Two linear passes over the catalog's keys: every tier but the typo's, then, if that found
        // few, the typo's over the rest.
        var found: [Found] = []
        q.withView { view in
            catalog.keys.withUnsafeBufferPointer { keys in
                catalog.entries.withUnsafeBufferPointer { entries in
                    var none: [Range<Int>] = []
                    for slot in entries.indices {
                        let entry = entries[slot]
                        guard entry.id != owner, admits(entry.id) else { continue }
                        let label = UnsafeBufferPointer(rebasing: keys[entry.start..<entry.start + entry.count])
                        if let score = MentionMatcher.tier(view, label, &none, wantSpans: false) { found.append(Found(slot: slot, score: score)) }
                    }
                    guard found.count < MentionRanking.typoPassBelow, view.characterCount >= MentionRanking.typoMinimumQuery else { return }
                    let matched = Set(found.map(\.slot))
                    for slot in entries.indices where !matched.contains(slot) {
                        let entry = entries[slot]
                        guard entry.id != owner, admits(entry.id) else { continue }
                        let label = UnsafeBufferPointer(rebasing: keys[entry.start..<entry.start + entry.count])
                        if let score = MentionMatcher.typo(view, label, &none, wantSpans: false) { found.append(Found(slot: slot, score: score)) }
                    }
                }
            }
        }
        let entries = catalog.entries
        for i in found.indices {
            let entry = entries[found[i].slot]
            if entry.isPlaceholder { found[i].score -= MentionRanking.placeholderPenalty }
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
            return candidate(id, matched: MentionMatcher.match(q, in: MentionMatcher.Label(label))?.matched ?? [])
        }
        return MentionCandidates(recent: [], nearby: [], matches: matches)
    }

    /// The shapes in the catalog nearest `origin` the scope admits, up to `nearbyShown`, nearest
    /// first: looked for in a square around it, grown until it holds enough, so a board of many
    /// mentionable shapes costs what's around the text; else in the whole catalog. A square's shapes
    /// are gathered from the whole board, so once one holds as many shapes as the catalog, reading
    /// the catalog costs less than growing it again: a board with few mentionable shapes, or few the
    /// scope admits, reads its catalog after at most one square that holds them all.
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
        // A catalog of no more than the shapes it could list, and those it leaves out, is read whole.
        let searchesSquares = catalog.count > wanted + taken.count
        var half: CGFloat = MentionStyle.nearbySearch
        for _ in 0..<MentionStyle.nearbySearchSteps where searchesSquares {
            let square = CGRect(x: origin.x - half, y: origin.y - half, width: 2 * half, height: 2 * half)
            let shapes = editor.paintOrder(in: square)
            let found = best(of: shapes.lazy.map(\.id))
            if found.count == wanted, found[wanted - 1].distance <= Double(half) { return found.map(\.id) }
            if shapes.count >= catalog.count { break }
            half *= 4
        }
        return best(of: catalog.entries.lazy.map(\.id)).map(\.id)
    }

    private func candidate(_ id: ShapeID, matched: [Range<Int>]) -> MentionCandidate {
        let isReadOnly = editor.document[id].map(registry.isReadOnly) ?? false
        return MentionCandidate(id: id, appearance: catalog.appearance(of: id)!, isReadOnly: isReadOnly, matched: matched)
    }

    // MARK: Following the document

    /// What a commit changed, applied: the index, the resolutions, the catalog; then the observers
    /// of the targets whose resolution changed, and the rows it affects.
    private func hear(_ changes: ChangeSet) {
        heardRevision = editor.revision
        let document = editor.document
        for id in changes.removed {
            reindex(id, nil)
            catalog.remove(id)
            stale.remove(id)
        }
        for id in changes.added.union(changes.changed) where !changes.moved.contains(id) {
            reindex(id, document[id])
            stale.insert(id)
        }
        var changedTargets: Set<ShapeID> = []
        for id in changes.shapeIDs where !changes.moved.contains(id) { resolveAgain(id, into: &changedTargets) }
        // Shapes on other boards it reached: those a deletion took with a board, or a paste
        // brought, or a write to a board that isn't shown changed.
        for id in changes.elsewhere { resolveAgain(id, into: &changedTargets) }
        lastAffected = changedTargets.reduce(into: Set<ShapeID>()) { $0.formUnion(backward[$1] ?? []) }
        if changes.replacedDocument { refreshStale() }                  // a board opened: read now, not at the first `@`
        tell(changedTargets)
    }

    /// Resolves a tracked target again (or takes what it shows now, `shown`), noting it in
    /// `changed` if that changed.
    private func resolveAgain(_ id: ShapeID, as shown: @autoclosure () -> MentionResolution? = nil, into changed: inout Set<ShapeID>) {
        guard let before = resolutions[id] else { return }
        let now = shown() ?? resolve(id)
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

    /// Reads a shape's mention text again (nil: it's gone), and keeps both directions in step.
    private func reindex(_ id: ShapeID, _ record: AnyShapeRecord?) {
        let new = record.map(targets(of:)) ?? []
        let old = forward[id] ?? []
        guard new != old else { return }
        forward[id] = new.isEmpty ? nil : new
        let newSet = Set(new), oldSet = Set(old)
        for target in oldSet.subtracting(newSet) {
            backward[target]?.remove(id)
            if backward[target]?.isEmpty == true { backward[target] = nil }
            untrackIfUnused(target)
        }
        for target in newSet.subtracting(oldSet) {
            backward[target, default: []].insert(id)
            track(target)
        }
    }

    /// The shapes a record's mention text mentions, in text order, each once, wherever the record
    /// keeps it (a property's value, or in a struct, list, set or dictionary there): only kinds that
    /// can hold names are read.
    private func targets(of record: AnyShapeRecord) -> [ShapeID] {
        guard registry.namingKinds.contains(record.kind), !record.isOpaque else { return [] }
        #if DEBUG
        textsRead += 1
        #endif
        var seen: Set<ShapeID> = [], ordered: [ShapeID] = []
        record.forEachNamingValue(in: registry) { _, value in
            value.forEachNamingLeaf { leaf in
                guard let text = leaf as? any MentionTextHolding else { return }
                text.forEachMentionRun { run in
                    if case .mention(let id, _) = run, seen.insert(id).inserted { ordered.append(id) }
                }
            }
        }
        return ordered
    }

    private func track(_ target: ShapeID) {
        if resolutions[target] == nil { resolutions[target] = resolve(target) }
    }

    private func untrackIfUnused(_ target: ShapeID) {
        if backward[target] == nil, observersByTarget[target] == nil { resolutions[target] = nil }
    }

    // MARK: The catalog

    private func refreshStale() {
        guard catalogIsRead else {
            for record in editor.document.shapes { readEntry(record) }
            catalogIsRead = true
            stale = []
            return
        }
        guard !stale.isEmpty else { return }
        let document = editor.document
        for id in stale {
            if let record = document[id] { readEntry(record) } else { catalog.remove(id) }
        }
        stale = []
    }

    /// A shape's catalog entry, read again: out of the catalog if it can't be mentioned.
    private func readEntry(_ record: AnyShapeRecord) {
        guard let appearance = appearance(of: record) else {
            catalog.remove(record.id)
            return
        }
        #if DEBUG
        entriesRead += 1
        #endif
        catalog.set(record.id, appearance, recentRank: recent.firstIndex(of: record.id) ?? -1)
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

    /// Keeps the board left's index and catalog, as they are, for going back to it.
    public func boardWillChange(from old: BoardID, to new: BoardID, in editor: CanvasEditor) {
        guard old != new, heardRevision == editor.revision else { return }
        kept.keep(Kept(forward: forward, backward: backward, resolutions: resolutions, catalog: catalog, stale: stale,
                       catalogIsRead: catalogIsRead, recent: recent),
                  for: old, in: editor)
    }

    /// Takes back the shown board's index and catalog, if it's as it was left, or indexes it as it
    /// opens (its catalog a turn later, `indexEntered`). Only the board shown is indexed (the picker lists what's on it), but its mentions of
    /// shapes on other boards show them live: taken back, what they name on other boards is resolved
    /// again, since a rename there (or a deletion, or its undo) while the board wasn't shown leaves
    /// its revision as it was, and those whose resolution changed bump their revisions and tell
    /// their observers, and their mentioners are the rows it affects (`rowsAffected`). Recent picks
    /// and observations stay (the picker lists only what's in the catalog; the views observing
    /// pills of the board left go with it).
    public func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        heardRevision = editor.revision
        lastAffected = []
        var changedTargets: Set<ShapeID> = []
        if let taken = kept.take(for: change.to, in: editor) {
            forward = taken.forward
            backward = taken.backward
            resolutions = taken.resolutions
            catalog = taken.catalog
            stale = taken.stale
            catalogIsRead = taken.catalogIsRead
            catalog.markRecent(recent, previous: taken.recent)
            // A change to a target on this board would have changed its revision, so those are as
            // kept; those elsewhere may not be.
            let document = editor.document, file = editor.file
            for id in Array(resolutions.keys) where document[id] == nil { resolveAgain(id, as: resolve(elsewhere: id, in: file), into: &changedTargets) }
            lastAffected = changedTargets.reduce(into: Set<ShapeID>()) { $0.formUnion(backward[$1] ?? []) }
        } else {
            forward = [:]
            backward = [:]
            resolutions = [:]
            catalog = MentionCatalog()
            stale = []
            indexEntered(editor.document)
        }
        for target in observersByTarget.keys { track(target) }
        tell(changedTargets)
    }
}

/// A board's index and catalog, kept while another board is shown.
private struct Kept {
    let forward: [ShapeID: [ShapeID]]
    let backward: [ShapeID: Set<ShapeID>]
    let resolutions: [ShapeID: MentionResolution]
    let catalog: MentionCatalog
    let stale: Set<ShapeID>
    let catalogIsRead: Bool
    /// The recent picks then, which the catalog's ranks follow.
    let recent: [ShapeID]
}

extension CanvasEditor {
    /// Mentions' state; nil without MentionsPlugin.
    public var mentions: MentionState? { service(MentionState.self) }
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

/// A shape the picker can list: how it shows, whether it's read-only (a lock beside its name), and
/// which characters of its label the query matched (`Character` offsets).
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

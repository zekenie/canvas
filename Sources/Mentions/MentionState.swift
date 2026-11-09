import AppKit
import Boards
import Canvas
import FuzzyMatching
import Observation
import Selection
import SlashCommands
import Titles
import Topology

/// What Mentions knows about an editor's file, one per editor: how each mentioned shape shows now,
/// what mentions each shape, on any board (`mentioners(of:)`), the catalog of shapes that can be
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
/// mentioners' rows (`rowsAffected`). A commit that only
/// moved shapes (a drag) changes no text and no name, so it costs nothing here; nor does showing
/// another board, since the index and the resolutions are the file's, kept up to date by each commit, the
/// shapes it changed on other boards (`ChangeSet.elsewhere`: the boards a deletion took or a paste
/// brought, a write to a board that isn't shown) included. The catalog is the file's too (the `@` picker lists what's on any
/// board the editor can show): read whole as the editor opens, or a file or board is put in place,
/// and kept up to date the same way.
@MainActor
@Observable
public final class MentionState {
    @ObservationIgnored unowned let editor: CanvasEditor
    public var registry: Registry { editor.registry }

    /// How each shape that's mentioned (anywhere in the file) or observed shows now.
    @ObservationIgnored var resolutions: [ShapeID: MentionResolution] = [:]
    /// How each row that's mentioned or observed shows now, by its shape: resolved again with its shape, so a commit costs the
    /// rows of the shapes it changed. A row's shape is always among `resolutions` too (a mention of a row is an edge into it).
    @ObservationIgnored var rowResolutions: [ShapeID: [PartID: MentionResolution]] = [:]
    /// The rows text views observe (`observe(_:rows:_:)`), each as many times as it's observed: kept resolved though nothing
    /// mentions them yet (a pill just picked, before its text is written).
    @ObservationIgnored private var observedRows: [PartAddress: Int] = [:]
    /// The kinds that lay out by the names their mentions show (`registrar.mentionLayout`), and the
    /// shapes of them given names other than the ones their text holds (`MentionLayout.names`).
    @ObservationIgnored lazy var layoutKinds: Set<ShapeKind> = Set(registry.kinds.filter {
        !registry.contributions(to: MentionLayouts.self, for: $0).isEmpty
    })
    @ObservationIgnored var laidOutByNames: Set<ShapeID> = []
    /// +1 for a target each time its resolution changes, observed a target at a time.
    @ObservationIgnored private var revisions: [ShapeID: Int] = [:]
    /// Each observation's targets and closure, by its key, and the keys observing each target.
    @ObservationIgnored private var observations: [Int: Observer] = [:]
    @ObservationIgnored private var observersByTarget: [ShapeID: Set<Int>] = [:]
    @ObservationIgnored private var nextObservation = 0

    /// Every mentionable shape on every board the editor can show that its kind names, ready to
    /// match; the shapes it gives no name (the "Untitled …" placeholder) are in the catalog's side
    /// table, read only by `candidates(…listingUnnamed: true)`.
    @ObservationIgnored private var catalog = MentionCatalog()
    /// The rows of the catalog's named shapes (`PartedShape`'s parts), read with their shapes' entries: what a list that asks for
    /// rows ranks besides the shapes (`candidates(…listingParts:)`).
    @ObservationIgnored private var partCatalog = MentionPartCatalog()
    /// The containment tree's names, for the path a query of several words is matched along and the place a
    /// list says for a shape (Boards' `ShapePaths`): read as a query or a list goes through a container,
    /// let go of by the commit that changes it.
    @ObservationIgnored var paths: ShapePaths
    /// The catalog's shapes each scope but `AnyMentionable` admits, and those of each set of kinds a
    /// text's command takes (`candidates(…kinds:)`), made when first asked about and kept up to date
    /// by every entry read after, so a scope or a command that admits few ranks its few.
    @ObservationIgnored private var memberSets: [MemberSet: ScopeMembers] = [:]
    /// Those a commit changed since, on any board, to read again at the next query.
    @ObservationIgnored private var stale: Set<ShapeID> = []
    @ObservationIgnored private var kindDefaults: [ShapeKind: MentionKindDefaults] = [:]

    /// This editor's picks, the latest first; never saved.
    @ObservationIgnored private var recent: [ShapeID] = []

    /// The rows its last commit affected (`rowsAffected`), asked once every service has the commit.
    @ObservationIgnored private var lastAffected: Set<ShapeID> = []
    /// Mentions, as Topology's edges: made once, as a filter's types are a set.
    @ObservationIgnored private let mentionEdges = EdgeTypeFilter.only(MentionEdge.id)

    /// Who mentions whom: Topology's index, looked up as this service is made, so it is made first and takes
    /// each change in first (`CanvasEditor.tell`).
    @ObservationIgnored private let topology: TopologyIndex?
    /// Following Topology's changes to the edges (`follow`): how the mentions that came and went
    /// are heard, whatever changed them.
    @ObservationIgnored private var following: TopologyFollowing?
    #if DEBUG
    /// How many catalog entries have been read (debug builds), so tests can hold a commit to what it
    /// changed. The mention text read is Topology's (`recordsRead`).
    @ObservationIgnored public private(set) var entriesRead = 0
    #endif

    init(editor: CanvasEditor) {
        self.editor = editor
        paths = ShapePaths(editor: editor)
        topology = editor.topology
        trackMentioned()
        readCatalog()
        layOutMentioners()
        following = topology?.follow { [weak self] change in self?.follow(change) }
    }

    /// The editor's slash commands, if it has them: what a mention text view hosts for its shape.
    var slashCommandState: SlashCommandState? { editor.service(SlashCommandState.self) }

    /// Resolves every shape and row that's mentioned anywhere in the file.
    private func trackMentioned() {
        var rows: [ShapeID: Set<PartID>] = [:]
        for edge in topology?.edges(ofType: mentionEdges) ?? [] {
            track(edge.target)
            if let part = edge.targetPart { rows[edge.target, default: []].insert(part) }
        }
        // A shape's rows read once for all the rows of it that are mentioned, not once for each.
        for (shape, parts) in rows { trackRows(parts, of: shape) }
    }

    /// Lays out every shape that mentions anything, as the names show now: what a file put in place
    /// holds names written before renames that were never written to it.
    private func layOutMentioners() {
        guard !layoutKinds.isEmpty else { return }
        refreshLayout(of: Set(topology?.edges(ofType: mentionEdges).map(\.carrier) ?? []))
    }

    // MARK: Reading

    /// The shapes that mention `target`, each once, on any board of the file the editor can show:
    /// those on the board shown in document order, then those on the other boards in the file's
    /// order (a board's in its order, each board where its owner is, depth first). `target` needn't
    /// be anywhere.
    public func mentioners(of target: ShapeID) -> [ShapeID] {
        ordered(mentionerSet(of: target), shown: editor.document, in: editor.file)
    }

    /// The shapes that mention a row (`target.part`), each once, in `mentioners(of:)`'s order; for a shape as a whole (part
    /// nil), those that mention it or any of its rows, as `mentioners(of:)` says.
    public func mentioners(of target: PartAddress) -> [ShapeID] {
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

    /// The shapes whose mention text mentions `target` (or one of its rows), in no order.
    private func mentionerSet(of target: ShapeID) -> Set<ShapeID> {
        guard let topology else { return [] }
        return Set(topology.edges(of: target, .incoming, types: mentionEdges).lazy.map(\.carrier))
    }

    /// The shapes whose mention text mentions the row (its shape, or any of its rows, for a shape as a whole), in no order.
    private func mentionerSet(of target: PartAddress) -> Set<ShapeID> {
        guard let part = target.part else { return mentionerSet(of: target.shape) }
        guard let topology else { return [] }
        return Set(topology.edges(of: target.shape, .incoming, types: mentionEdges).lazy.filter { $0.targetPart == part }.map(\.carrier))
    }

    /// The rows of `shape` that some text mentions.
    private func mentionedRows(of shape: ShapeID) -> Set<PartID> {
        guard let topology else { return [] }
        return Set(topology.edges(of: shape, .incoming, types: mentionEdges).compactMap(\.targetPart))
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
    /// It stops at the first, and makes nothing: a menu asks it as it opens.
    public func isMentioned(_ target: ShapeID) -> Bool {
        topology?.hasEdges(of: target, .incoming, types: mentionEdges) { $0.carrier != target } ?? false
    }

    /// Whether another shape mentions the row (`isMentioned(_:)` for a shape as a whole): the row's own shape's text doesn't count.
    public func isMentioned(_ target: PartAddress) -> Bool {
        guard let part = target.part else { return isMentioned(target.shape) }
        return topology?.hasEdges(of: target.shape, .incoming, types: mentionEdges) { $0.carrier != target.shape && $0.targetPart == part } ?? false
    }

    /// The shapes whose mention text mentions any of `targets` (a row's, only that row; a shape's, it or its rows), but the
    /// targets' own shapes (their mentions of themselves), each once, in no order.
    private func mentionersOfAny(_ targets: [PartAddress]) -> Set<ShapeID> {
        var found: Set<ShapeID> = []
        for target in targets {
            for edge in topology?.edges(of: target.shape, .incoming, types: mentionEdges) ?? []
            where edge.carrier != target.shape && (target.part == nil || edge.targetPart == target.part) {
                found.insert(edge.carrier)
            }
        }
        return found
    }

    /// Goes to what mentions `targets` (their mentioners, each target's own mention of itself left
    /// out) as following a mention goes to its target (`editor.goTo`: one step back, and the camera
    /// brings them into view): those on the board shown, if any are, else those on the board of the
    /// first in `mentioners(of:)`'s order, which it shows. On the scheduler's next turn: from a menu
    /// in text being edited, going ends the editing that menu's view is part of. Nothing, if nothing
    /// mentions them.
    public func showWhatMentions(_ targets: [ShapeID]) {
        showWhatMentions(targets.map { PartAddress($0) })
    }

    /// `showWhatMentions(_:)` of rows, or shapes (part nil): what mentions a row is what mentions that row.
    public func showWhatMentions(_ targets: [PartAddress]) {
        _ = editor.scheduler.schedule(after: .zero) { [weak self] in self?.goToMentioners(of: targets) }
    }

    private func goToMentioners(of targets: [PartAddress]) {
        editor.endEditing()                                     // what the text saves as it closes, indexed first
        let mentioners = ordered(mentionersOfAny(targets), shown: editor.document, in: editor.file)
        guard !mentioners.isEmpty else { return }
        editor.goTo(mentioners)
    }

    /// A mentioner's text around its first mention of `target`, as plain text with the names its
    /// mentions show now, on one line, about `MentionStyle.quoteLength` characters: what a list of
    /// what mentions a shape says under a mentioner's name (Neighbors' list, through mentions'
    /// light). Nil for a shape that isn't in the file, or whose text doesn't mention it (a pointer,
    /// which is no text). It reads the mentioner's record without observing the file.
    public func quote(of mentioner: ShapeID, around target: ShapeID) -> String? {
        quote(of: mentioner, around: PartAddress(target))
    }

    /// The quote around a mentioner's first mention of a row (`target.part`); of a shape as a whole, its first mention of the
    /// shape or one of its rows.
    public func quote(of mentioner: ShapeID, around target: PartAddress) -> String? {
        editor.withoutObservingDocument {
            (editor.document[mentioner] ?? editor.file.record(mentioner)).flatMap { quote(of: $0, around: target) }
        }
    }

    /// The quote around a mentioner's first mention of `target`: in the first of its texts that
    /// mentions it, wherever the shape keeps it.
    private func quote(of record: AnyShapeRecord, around target: PartAddress) -> String? {
        guard !record.isOpaque else { return nil }
        var quote: String?
        record.forEachNamingValue(in: registry) { _, value in
            guard quote == nil else { return }
            value.forEachNamingLeaf { leaf in
                guard quote == nil, let text = leaf as? any MentionTextHolding else { return }
                var runs: [MentionRun] = []
                text.forEachMentionRun { runs.append($0) }
                // Every shape the file mentions is tracked, so its name is kept.
                quote = MentionQuote.quote(runs, around: target, length: MentionStyle.quoteLength) { kept(of: $0).appearance?.label }
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

    /// What a mention of a row shows now: its shape's row, by its live full name (an endpoint's method and full path; a column
    /// with its table's name, "orders.customer_id"), wherever the shape is; missing when the shape is there and the row isn't;
    /// as its shape's otherwise. A shape as a whole (part nil): `resolve(_:)`.
    public func resolve(_ target: PartAddress) -> MentionResolution {
        guard let part = target.part else { return resolve(target.shape) }
        let record = editor.document[target.shape] ?? (editor.file.board(containing: target.shape) != nil ? editor.shape(inFile: target.shape) : nil)
        guard let record else { return editor.file.board(containing: target.shape) == nil ? .missing : .unavailable }
        return MentionResolution.row(part, of: record, shape: appearance(of: record), in: registry)
    }

    /// What mentions of these rows of `shape` show now: the shape looked up, and its rows read, once for them all.
    private func resolveRows(_ parts: [PartID], of shape: ShapeID) -> [PartID: MentionResolution] {
        let record = editor.document[shape] ?? (editor.file.board(containing: shape) != nil ? editor.shape(inFile: shape) : nil)
        guard let record else {
            let gone: MentionResolution = editor.file.board(containing: shape) == nil ? .missing : .unavailable
            return Dictionary(uniqueKeysWithValues: parts.map { ($0, gone) })
        }
        guard let appearance = appearance(of: record) else { return Dictionary(uniqueKeysWithValues: parts.map { ($0, .unavailable) }) }
        var names: [PartID: PartName] = [:]
        for part in registry.parts(of: record) ?? [] where names[part.id] == nil { names[part.id] = part }
        return Dictionary(uniqueKeysWithValues: parts.map { part in
            (part, names[part].map { .live(MentionAppearance.row($0, of: appearance)) } ?? .missing)
        })
    }

    /// What a mention of `target` shows, as kept where it's tracked (every shape and row the file mentions), else resolved now.
    func kept(of target: PartAddress) -> MentionResolution {
        if let part = target.part { return rowResolutions[target.shape]?[part] ?? resolve(target) }
        return resolutions[target.shape] ?? resolve(target.shape)
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
    public var labels: MentionLabels { MentionLabels(resolutions, rows: rowResolutions) }

    /// A target's revision: +1 each time what a mention of it shows changes. Reading it observes
    /// only that target, so a SwiftUI view of a pill redraws when its own target changes.
    public func labelRevision(of target: ShapeID) -> Int {
        access(keyPath: \.[revision: target])
        return revisions[target] ?? 0
    }

    /// Only a key: one key path per target, under which Observation keeps each target's observers.
    private subscript(revision target: ShapeID) -> Int { revisions[target] ?? 0 }

    /// Calls `changed` with those of `targets` whose resolution a commit changed, once per commit,
    /// as it hears it (an AppKit view's pills: it updates their images, and transacts nothing): a
    /// shape is changed when it or one of its rows `rows` names (a row's pill: its shape is among
    /// `targets`) shows otherwise. Until the observation is cancelled, or let go of.
    public func observe(_ targets: Set<ShapeID>, rows: Set<PartAddress> = [], _ changed: @escaping @MainActor (Set<ShapeID>) -> Void) -> MentionObservation {
        let key = nextObservation
        nextObservation += 1
        let rows = rows.filter { $0.part != nil }
        let targets = targets.union(rows.map(\.shape))
        observations[key] = Observer(targets: targets, rows: rows, changed: changed)
        for target in targets {
            observersByTarget[target, default: []].insert(key)
            track(target)
        }
        for row in rows {
            observedRows[row, default: 0] += 1
            trackRow(row)
        }
        return MentionObservation(state: self, key: key)
    }

    /// Ends an observation: its closure isn't called again.
    fileprivate func cancel(_ key: Int) {
        guard let observer = observations.removeValue(forKey: key) else { return }
        for row in observer.rows {
            observedRows[row, default: 1] -= 1
            if observedRows[row] == 0 { observedRows[row] = nil }
        }
        for target in observer.targets {
            observersByTarget[target]?.remove(key)
            if observersByTarget[target]?.isEmpty == true { observersByTarget[target] = nil }
            untrackIfUnused(target)
        }
        for row in observer.rows { untrackRowIfUnused(row) }
    }

    /// The mentioners whose rows a commit may change without changing them: those of the targets
    /// whose resolution it changed, asked once every service has it; and, asked with shapes elsewhere
    /// (what changed on other boards while the board shown wasn't, which the table of contents
    /// hands its rows on going back to it), the mentioners of those shapes too.
    public func rowsAffected(by changes: ChangeSet) -> Set<ShapeID> {
        guard !changes.elsewhere.isEmpty else { return lastAffected }
        var affected = lastAffected
        for id in changes.elsewhere { affected.formUnion(mentionerSet(of: id)) }
        return affected
    }

    // MARK: Going to and hovering

    // MARK: The text with the keyboard

    /// The mention text that has the keyboard (a note's editor, a panel's box): what Go to Mention, Show
    /// What Mentions and Remove Mention act on, as the pill's menu does. Set as a text takes the keyboard,
    /// and let go as it gives it up.
    @ObservationIgnored private weak var keyboardText: (any PillCommandText)?

    func enter(_ text: any PillCommandText) { keyboardText = text }

    func leave(_ text: any PillCommandText) {
        if keyboardText === text { keyboardText = nil }
    }

    /// The pill on the caret of the text with the keyboard.
    var pillOnCaret: MentionAttachment? { keyboardText?.pillOnCaret }

    /// Go to Mention: the live pill on the caret, followed on the next turn as a double-click does.
    var canFollowPillOnCaret: Bool { pillOnCaret?.resolution.isLive == true }

    func followPillOnCaret() {
        guard let pill = pillOnCaret, pill.resolution.isLive else { return }
        follow(pill.target)
    }

    var canShowWhatMentionsOnCaret: Bool { pillOnCaret.map { keyboardText?.canShowWhatMentions(of: $0) == true } ?? false }

    func showWhatMentionsOnCaret() {
        guard let pill = pillOnCaret, keyboardText?.canShowWhatMentions(of: pill) == true else { return }
        showWhatMentions([pill.target])
    }

    var canRemovePillOnCaret: Bool { keyboardText?.canRemovePillOnCaret == true }

    func removePillOnCaret() { keyboardText?.removePillOnCaret() }

    /// Follows a mention of the target on the next turn of the scheduler (`editor.followMention`:
    /// ends editing, goes to it or into it; ⌘[ comes back): a click inside the text being edited is
    /// still being tracked by the view that going ends.
    public func follow(_ target: ShapeID) {
        follow(PartAddress(target))
    }

    /// Follows a mention of a row (`target.part`): goes to its shape and selects the row there, as an item of its shape; a shape
    /// as a whole, as `follow(_:)` does.
    public func follow(_ target: PartAddress) {
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

    /// What the `@` picker lists for `query` in text of `scope` on `owner`, the text's shape (or none):
    /// `candidates(matching:in:for:kinds:among:listingUnnamed:admitting:)` for it alone.
    public func candidates<S: MentionScope>(matching query: String, in scope: S.Type, for owner: ShapeID?,
                                            kinds: Set<ShapeKind>? = nil, among: [ShapeID]? = nil,
                                            listingUnnamed: Bool = false,
                                            admitting rule: (@MainActor (ShapeID) -> Bool)? = nil,
                                            listingParts parts: (@MainActor (PartAddress) -> Bool)? = nil) -> MentionCandidates {
        candidates(matching: query, in: scope, for: owner.map { [$0] } ?? [], kinds: kinds, among: among, listingUnnamed: listingUnnamed,
                   admitting: rule, listingParts: parts)
    }

    /// What the `@` picker lists for `query` in text of `scope`, for `owners`: the text's shape, which
    /// may mention itself, or the shapes the command bar's text is typed for (the selection). Each is
    /// left out of an empty query's Nearby, where it would always be first, and of a typed query's
    /// matches while its name holds what's typed, as a note's does when the `@` is in its first line;
    /// nearness is measured from the middle of the box around them, one owner's own middle. It lists
    /// every mentionable shape the scope admits on any board of the file the editor can show, but those kept aside and
    /// those its kind gives no name (called by the "Untitled …" placeholder: a mention of one
    /// stays, but there's no point picking it), unless `listingUnnamed` (below). An empty query lists recent picks, then the shapes nearest the
    /// owners on the board shown and, while there's room, the shapes whose boards they're inside, the
    /// board shown's own first; any other, one ranked list of the best matches (`FuzzyMatcher`'s
    /// tiers, then `MentionRanking`'s adjustments, nearness on the board shown among them; ties to
    /// the shorter label, then the front-most shape, the board shown's before any other's).
    ///
    /// A query of several words (`MentionMatcher.words(in:)`, `MentionCandidates.words`) also finds a shape by its
    /// path, as Jump To ranks one: the words before the last in the containers it is inside, in order, any skipped,
    /// the last in its name (`ShapePaths`, `PathMatcher`). The matches are in three bands: the shapes whose own name
    /// has the whole query from a substring up, then those found by their path, then the loose matches of the name
    /// (a subsequence, a typo); the recent pick and nearness adjust within a band. Every filter below holds for a
    /// path match; the unnamed are matched by their placeholder alone. `forgave` is true if either pass ran its typo's tier.
    ///
    /// `kinds` and `admitting`, if given, are what a shape must satisfy too (a slash command's, for
    /// the one shape it takes: `SlashCommandTyping.admittedShapes(at:)`), wherever a shape would be
    /// listed (a recent pick, a nearby shape, a board the text is inside, a match), besides the
    /// scope: `kinds` are the most kinds of shape to list, and `admitting` a rule asked of each
    /// shape of them the scope admits, so the list is what all three admit. With `kinds`, the shapes
    /// ranked are the catalog's of those kinds, its **members** (`ScopeMembers`, as a scope's: made
    /// at the first ask, one pass, and kept up to date as entries are read and taken out), so when
    /// there are few of them an empty query reads them whole for the nearest, never growing squares
    /// over a board, and a typed one ranks them alone, whatever the board holds; the rule is asked
    /// of them alone. And an empty query lists as many of them as a typed one may (`maxMatches`, not
    /// `nearbyShown`), on every board: a command's few shapes are the places it can go, wherever they
    /// are (`/move-to`'s frames and subboards), so after the nearest on the board shown and the
    /// boards it's inside come those on the other boards, the nearest board first (`farther`). With
    /// none of either, which is every text but a command line's, nothing more is asked of a shape.
    ///
    /// `among`, if given, is a set of shapes the caller has already found (a relationship row's
    /// list: the notes that fit the row), which a shape must be in too. It does what `kinds`
    /// does for a set no kind names: only the given shapes of the catalog are ranked, so a typed query
    /// ranks them alone, and an empty one reads them whole and lists as many as a typed one, nearest on
    /// the board shown first, then on every other board. A shape of it that isn't in the catalog (kept
    /// aside, named by no mention) is dropped. With `kinds` too, the shapes of both.
    ///
    /// `listingUnnamed`, with `among` or `kinds`, lists the shapes their kind gives no name as well,
    /// as members: after the named ones, an empty query reads them into the nearby (the board shown's,
    /// nearest first) and then the other boards' (the nearest board first), and a typed one matches
    /// them only by their placeholder label ("Untitled Note"), after the named matches. A list of
    /// the notes that fit a relationship row asks, since a note with nothing in it fits and is
    /// pickable; `@`, `/move-to` and the reference list do not, and nothing they cost moves. A shape
    /// handed in `among` is of the catalog, or an unnamed one.
    ///
    /// `listingParts`, if given, lists the rows of the shapes it would list too (`PartedShape`'s parts, a table's columns), those
    /// the rule admits, as candidates of their own (`MentionCandidate.part`), for a typed query only: a row that stands alone (an
    /// endpoint) by its name, in the name's band, and every row by its path, its shape's containers and the shape's own name
    /// before its name, in the path's band (`orders cust`). The query's words split at a dot followed by a letter too
    /// (`orders.cust`), for shapes as for rows. A row that doesn't stand alone is never matched by its name alone: a column is
    /// listed under its table's name, so `id` doesn't list every table's.
    public func candidates<S: MentionScope>(matching query: String, in scope: S.Type, for owners: [ShapeID],
                                            kinds: Set<ShapeKind>? = nil, among: [ShapeID]? = nil,
                                            listingUnnamed: Bool = false,
                                            admitting rule: (@MainActor (ShapeID) -> Bool)? = nil,
                                            listingParts parts: (@MainActor (PartAddress) -> Bool)? = nil) -> MentionCandidates {
        refreshStale()
        let document = editor.document, file = editor.file, registry = registry
        let admitsAll = S.self == AnyMentionable.self
        // A scope that admits some of the catalog ranks only those (`scopeMembers`), and a command
        // that names the kinds it takes only the shapes of those (`kindMembers`, which take the
        // scope's place): kept up to date as entries are read, so what a keystroke costs is what
        // they are, not the catalog.
        let scopeMembers = admitsAll ? nil : self.members(of: S.self)
        let kindMembers = kinds.map { self.members(ofKinds: $0) }
        // What the caller gave, in the catalog and of the kinds, once each (`given`); else the kinds' members.
        // And, with `listingUnnamed`, the unnamed among them, apart: `given.ids` stays the named.
        var unnamedIds: [ShapeID] = []
        let given: (ids: [ShapeID], contains: (ShapeID) -> Bool)?
        if let among {
            var seen = Set<ShapeID>()
            var unnamedSeen = Set<ShapeID>()
            let ids = among.filter {
                if listingUnnamed, let unnamed = catalog.unnamed[$0] {
                    if kinds?.contains(unnamed.kind) ?? true, unnamedSeen.insert($0).inserted { unnamedIds.append($0) }
                    return false
                }
                return catalog.contains($0) && (kindMembers?.contains($0) ?? true) && seen.insert($0).inserted
            }
            let kept = seen.union(unnamedSeen)
            given = (ids, { kept.contains($0) })
        } else if let kindMembers {
            if listingUnnamed, let kinds {
                unnamedIds = catalog.unnamed.lazy.filter { kinds.contains($0.value.kind) }.map(\.key)
            }
            let kept = Set(unnamedIds)
            given = (kindMembers.ids, { kindMembers.contains($0) || kept.contains($0) })
        } else {
            given = nil
        }
        let members = (given?.ids ?? scopeMembers?.ids)
        /// Whether what's ranked is the scope's members, which it admitted as they were kept.
        let scopeAdmitted = given == nil && scopeMembers != nil
        /// Whether the scope admits a shape in the catalog: every one, for `AnyMentionable`.
        func admits(_ id: ShapeID) -> Bool {
            admitsAll || (document[id] ?? file.record(id)).map { S.admits($0, in: registry) } ?? false
        }
        /// Whether a shape in the catalog can be listed: of the kinds, if there are any, the scope
        /// admits it, and the rule, if there is one.
        func listable(_ id: ShapeID) -> Bool { (given?.contains(id) ?? true) && admits(id) && (rule?(id) ?? true) }
        let shapes = editor.shapeContext
        let around = owners.lazy.compactMap { shapes.geometry(of: $0)?.bounds }.reduce(nil as CGRect?) { $0?.union($1) ?? $1 }
        let origin = around.map { CGPoint(x: $0.midX, y: $0.midY) }
        func distance(_ id: ShapeID) -> Double? {
            guard let origin, let bounds = shapes.geometry(of: id)?.bounds else { return nil }
            return Double(hypot(bounds.midX - origin.x, bounds.midY - origin.y))
        }

        let q = FuzzyMatcher.Query(query)
        guard !q.isEmpty else {
            let recentShown = Array(recent.lazy.filter { (self.catalog.contains($0) || (listingUnnamed && self.catalog.unnamed[$0] != nil)) && listable($0) }
                .prefix(MentionRanking.recentShown)).map { candidate($0, matched: []) }
            var taken = Set(recentShown.map(\.id))
            taken.formUnion(owners)
            // A command's kinds are few shapes, each somewhere it can go: every one, as many as a query lists.
            let room = given == nil ? MentionRanking.nearbyShown : MentionRanking.maxMatches
            var nearby = origin.map { nearest(to: $0, count: room, excluding: taken, members: members, admits: listable, distance: distance) } ?? []
            taken.formUnion(nearby)
            for inside in editor.boardPath.reversed().lazy.compactMap(\.owner) where nearby.count < room {
                if !taken.contains(inside), catalog.contains(inside), listable(inside) {
                    nearby.append(inside)
                    taken.insert(inside)
                }
            }
            if let given, nearby.count < room {
                nearby += farther(given.ids, count: room - nearby.count, excluding: taken, admits: listable)
            }
            // The unnamed come after every named one.
            if nearby.count < room {
                nearby += unnamedInOrder(unnamedIds, excluding: taken.union(nearby), admits: listable, distance: distance,
                                         limit: room - nearby.count)
            }
            return MentionCandidates(recent: recentShown, nearby: nearby.map { candidate($0, matched: []) }, matches: [])
        }

        // A shape named by its own text (a note's first line) holds the `@query` being typed in its
        // name, so it would match what's typed: it's left out then, listed once its name says more.
        // (A name with no `@` holds no `@query`: looked at first, the command bar's owners being the shapes selected, however many.)
        let typed = "@" + query.trimmingCharacters(in: .whitespacesAndNewlines)
        let leftOut = Set(owners.filter { owner in
            catalog.appearance(of: owner).map {
                $0.label.utf8.contains(0x40) && $0.label.range(of: typed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            } ?? false
        })
        let leavesOut = !leftOut.isEmpty

        // Two linear passes over the catalog's keys, as every caret list matches (`rank`): every
        // tier but the typo's, then, if that found few, the typo's over the rest.
        var found: [Found] = []
        var forgave = false
        /// How many the other tiers than the typo's found.
        var tierFound = 0
        // Words before the last may name the containers a shape is inside (`byPath`); a query of one word
        // is its name's alone, as ever.
        let matcher = PathMatcher(query, splittingDots: parts != nil)
        let byPath = matcher.pieceCount > 1
        /// A member's slot in the catalog, member for member (its entry may have gone since: nil).
        let memberSlots = members?.map { catalog.slot(of: $0) }
        /// A pass of `query` over the shapes that can be listed, but those `skipped` (by slot): `hear`
        /// hears each shape matched, its slot and the tier's score. Whether the typo pass ran.
        func pass(of query: FuzzyMatcher.Query, skipping skipped: ((Int) -> Bool)? = nil, hearing hear: (_ slot: Int, _ score: Int) -> Void) -> Bool {
            query.withView { view in
                catalog.keys.withUnsafeBufferPointer { keys in
                    catalog.entries.withUnsafeBufferPointer { entries in
                        /// A place in the ranking's order: a catalog slot, or a member's, which has a slot of its own.
                        func slot(_ index: Int) -> Int? { memberSlots.map { $0[index] } ?? index }
                        return FuzzyMatcher.ranking(view, count: members?.count ?? entries.count, wantSpans: false, label: { index in
                            guard let slot = slot(index), !(skipped?(slot) ?? false) else { return nil }
                            let entry = entries[slot]
                            guard !(leavesOut && leftOut.contains(entry.id)), scopeAdmitted || admits(entry.id) else { return nil }
                            // The rule is every shape's to pass.
                            if let rule, !rule(entry.id) { return nil }
                            return UnsafeBufferPointer(rebasing: keys[entry.start..<entry.start + entry.count])
                        }) { index, score, _ in
                            if let slot = slot(index) { hear(slot, score) }
                        }
                    }
                }
            }
        }
        forgave = pass(of: q, hearing: { slot, score in
            // Of several words, a name that holds them loosely (a subsequence, a typo) comes after the shapes found by their paths.
            found.append(Found(slot: slot, score: score, band: byPath && score < FuzzyRanking.substring ? .loose : .name))
            if score != FuzzyRanking.typo { tierFound += 1 }
        })
        let entries = catalog.entries
        if byPath {
            // The shapes the last word names, which a container's name or a skip of it may place the rest of the
            // words before, scored along their paths (Jump To's ranking), but those whose own names have the whole
            // query strongly: they are listed first already.
            var isStrong = [Bool](repeating: false, count: entries.count)
            for scored in found where scored.band == .name { isStrong[scored.slot] = true }
            var named: [Int] = []
            let ranTypo = pass(of: FuzzyMatcher.Query(matcher.pieces[matcher.pieceCount - 1]), skipping: { isStrong[$0] }, hearing: { slot, _ in
                named.append(slot)
            })
            forgave = forgave || ranTypo
            // Each by its path, through the row of its container (made once for all it holds: shapes of one container
            // are mostly together, so the last is remembered before the memo is asked).
            var chains: [ShapeID: PathMatcher.Row] = [:]
            let root = matcher.rootRow
            var pathScores = [Int](repeating: Int.min, count: entries.count)
            var scored = false
            var last: (container: ShapeID, row: PathMatcher.Row, isUsable: Bool)?
            for slot in named {
                // A shape in no container has no word to place but its own name's.
                guard let container = catalog.parent(at: slot, using: { [topology] in topology?.parent(of: $0) }) else { continue }
                if last?.container != container {
                    let row = paths.row(after: container, matcher, root: root, memo: &chains)
                    last = (container, row, row.best.dropFirst().contains { $0 != PathMatcher.Row.unreachable })
                }
                guard let known = last, known.isUsable else { continue }
                let entry = entries[slot]
                let score = catalog.keys.withUnsafeBufferPointer { keys in
                    matcher.leafScore(after: known.row, keys: UnsafeBufferPointer(rebasing: keys[entry.start..<entry.start + entry.count]), placingAtLeast: 1)
                }
                if let score {
                    pathScores[slot] = score
                    scored = true
                }
            }
            if scored {
                // A loose match of the name that is found by its path is in the path's band, by the path's score.
                for i in found.indices where found[i].band == .loose && pathScores[found[i].slot] != Int.min {
                    found[i].score = pathScores[found[i].slot]
                    found[i].band = .path
                    pathScores[found[i].slot] = Int.min
                }
                for slot in named where pathScores[slot] != Int.min { found.append(Found(slot: slot, score: pathScores[slot], band: .path)) }
            }
        }
        for i in found.indices {
            let entry = entries[found[i].slot]
            if entry.recentRank >= 0 {
                found[i].score += MentionRanking.recentBonus * (MentionRanking.recentKept - entry.recentRank) / MentionRanking.recentKept
            }
        }
        /// The shapes whose names have the query, then those found by their paths, then the loose matches of the name; within
        /// a band: lower score, then longer label, then further back, then later in the catalog.
        func isWorse(_ a: Found, _ b: Found) -> Bool {
            if a.band != b.band { return a.band > b.band }
            if a.score != b.score { return a.score < b.score }
            let al = entries[a.slot].labelLength, bl = entries[b.slot].labelLength
            if al != bl { return al > bl }
            let ai = document.index(of: entries[a.slot].id) ?? 0, bi = document.index(of: entries[b.slot].id) ?? 0
            // Shapes of other boards have no place on this one: the catalog's order, whatever order a scope's members are kept in.
            return ai != bi ? ai < bi : a.slot > b.slot
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
        func shapeCandidate(_ found: Found) -> MentionCandidate {
            let id = entries[found.slot].id
            let label = catalog.appearances[found.slot].label
            if found.band == .path {
                // The words along the shape's whole path: which characters of its name and of its containers' they took.
                let names = paths.containers(of: id).map { paths.node($0).name.title ?? "" } + [label]
                let match = matcher.match(path: names, placingAtLeast: 1)
                return candidate(id, matched: match?.matched.last ?? [], containersMatched: match.map { Array($0.matched.dropLast()) } ?? [])
            }
            return candidate(id, matched: FuzzyMatcher.match(q, in: FuzzyMatcher.Label(label))?.matched ?? [])
        }
        var matches: [MentionCandidate]
        if let parts {
            // The rows found, in among the shapes by band and score: a band's shapes and rows ranked together.
            let rows = partMatches(q, matcher, listable: listable, admitting: parts, leavingOut: leavesOut ? leftOut : [])
            var merged: [(band: MatchBand, score: Int, length: Int, make: () -> MentionCandidate)] = []
            var listed: Set<ShapeID> = []
            for found in ranked.prefix(MentionRanking.maxMatches) {
                merged.append((found.band, found.score, entries[found.slot].labelLength, { shapeCandidate(found) }))
                listed.insert(entries[found.slot].id)
            }
            // A shape whose one row stands alone is that row (an endpoint taken out of an API): listed once, as the shape when
            // it's found, its row only when it isn't (found by its path, while it's called by its name).
            for row in rows where !(listed.contains(partCatalog.entries[row.slot].shape) && partCatalog.isItsOwnRow(row.slot)) {
                merged.append((row.band, row.score, partCatalog.entries[row.slot].labelLength, { self.partCandidate(row.slot, band: row.band, q, matcher) }))
            }
            // Stable: within a band and score, the shorter name, then shapes before rows as each list had them.
            let order = merged.indices.sorted { a, b in
                let x = merged[a], y = merged[b]
                if x.band != y.band { return x.band < y.band }
                if x.score != y.score { return x.score > y.score }
                if x.length != y.length { return x.length < y.length }
                return a < b
            }
            matches = order.prefix(MentionRanking.maxMatches).map { merged[$0].make() }
        } else {
            matches = ranked.prefix(MentionRanking.maxMatches).map(shapeCandidate)
        }
        // The unnamed, by their placeholder label alone (one match a label), after the named. The typo's tier is
        // tried as the named are: only when the other tiers found fewer than `typoPassBelow` shapes, named and
        // unnamed together, so a narrowed list and a fresh one agree (`forgave`).
        if matches.count < MentionRanking.maxMatches, !unnamedIds.isEmpty {
            var spans: [String: FuzzyMatch?] = [:]
            var fits = unnamedIds.filter { id in
                guard !(leavesOut && leftOut.contains(id)), listable(id), let label = catalog.unnamed[id]?.appearance.label else { return false }
                if spans[label] == nil { spans[label] = .some(FuzzyMatcher.match(q, in: FuzzyMatcher.Label(label))) }
                return spans[label]! != nil
            }
            func isTypo(_ id: ShapeID) -> Bool { spans[catalog.unnamed[id]!.appearance.label]!!.score == FuzzyRanking.typo }
            let firstPass = tierFound + fits.lazy.filter { !isTypo($0) }.count
            let typoPass = firstPass < FuzzyRanking.typoPassBelow && q.withView { $0.characterCount } >= FuzzyRanking.typoMinimumQuery
            if !typoPass { fits = fits.filter { !isTypo($0) } }
            forgave = forgave || typoPass
            for id in unnamedInOrder(fits, excluding: [], admits: { _ in true }, distance: distance, limit: MentionRanking.maxMatches - matches.count) {
                matches.append(candidate(id, matched: spans[catalog.unnamed[id]!.appearance.label]!!.matched))
            }
        }
        return MentionCandidates(recent: [], nearby: [], matches: matches, forgave: forgave, words: matcher.pieceCount)
    }

    /// The rows a typed query finds (`candidates(…listingParts:)`), best first, as many as a list shows: a row that stands alone by
    /// its name, in the name's band; every row by its path (its shape's containers, then the shape's own name, then its name; at
    /// least one word placed before its name), in the path's band. Only the rows of shapes the list would list (`listable`), but
    /// those left out, and that `rule` admits. Two linear passes over the rows' keys, and a path row a shape.
    private func partMatches(_ q: FuzzyMatcher.Query, _ matcher: PathMatcher, listable: (ShapeID) -> Bool, admitting rule: (PartAddress) -> Bool,
                             leavingOut leftOut: Set<ShapeID>) -> [(slot: Int, score: Int, band: MatchBand)] {
        let rows = partCatalog.entries
        guard !rows.isEmpty else { return [] }
        var shapeListed: [ShapeID: Bool] = [:]
        func admits(_ slot: Int) -> Bool {
            let entry = rows[slot]
            if leftOut.contains(entry.shape) { return false }
            let listed: Bool
            if let known = shapeListed[entry.shape] {
                listed = known
            } else {
                listed = catalog.contains(entry.shape) && listable(entry.shape)
                shapeListed[entry.shape] = listed
            }
            return listed && rule(PartAddress(entry.shape, part: entry.part.id))
        }
        var found: [Int: (score: Int, band: MatchBand)] = [:]
        // Those that stand alone, by their names.
        if rows.contains(where: \.part.standsAlone) {
            q.withView { view in
                partCatalog.keys.withUnsafeBufferPointer { keys in
                    _ = FuzzyMatcher.ranking(view, count: rows.count, wantSpans: false, label: { slot in
                        let entry = rows[slot]
                        guard entry.part.standsAlone, admits(slot) else { return nil }
                        return UnsafeBufferPointer(rebasing: keys[entry.start..<entry.start + entry.count])
                    }) { slot, score, _ in found[slot] = (score, .name) }
                }
            }
        }
        // Every row by its path: the last word in its name, the words before along its shape's path, through the shape's own name.
        if matcher.pieceCount > 1 {
            var named: [Int] = []
            FuzzyMatcher.Query(matcher.pieces[matcher.pieceCount - 1]).withView { view in
                partCatalog.keys.withUnsafeBufferPointer { keys in
                    _ = FuzzyMatcher.ranking(view, count: rows.count, wantSpans: false, label: { slot in
                        guard admits(slot) else { return nil }
                        let entry = rows[slot]
                        return UnsafeBufferPointer(rebasing: keys[entry.start..<entry.start + entry.count])
                    }) { slot, _, _ in named.append(slot) }
                }
            }
            var chains: [ShapeID: PathMatcher.Row] = [:]
            let root = matcher.rootRow
            var last: (shape: ShapeID, row: PathMatcher.Row, isUsable: Bool)?
            for slot in named {
                let entry = rows[slot]
                if last?.shape != entry.shape {
                    let row = paths.row(after: entry.shape, matcher, root: root, memo: &chains)
                    last = (entry.shape, row, row.best.dropFirst().contains { $0 != PathMatcher.Row.unreachable })
                }
                guard let known = last, known.isUsable else { continue }
                let score = partCatalog.keys.withUnsafeBufferPointer { keys in
                    matcher.leafScore(after: known.row, keys: UnsafeBufferPointer(rebasing: keys[entry.start..<entry.start + entry.count]), placingAtLeast: 1)
                }
                guard let score, found[slot] == nil else { continue }
                found[slot] = (score, .path)
            }
        }
        let ranked = found.map { (slot: $0.key, score: $0.value.score, band: $0.value.band) }.sorted { a, b in
            if a.band != b.band { return a.band < b.band }
            if a.score != b.score { return a.score > b.score }
            if rows[a.slot].labelLength != rows[b.slot].labelLength { return rows[a.slot].labelLength < rows[b.slot].labelLength }
            return a.slot < b.slot
        }
        return Array(ranked.prefix(MentionRanking.maxMatches))
    }

    /// A row as a list shows it (`MentionCandidate.part`): its name, its lead's symbol (else its shape's), its kind word, and where it is,
    /// its shape's place and then the shape's own name; the characters a path's words took in each.
    private func partCandidate(_ slot: Int, band: MatchBand, _ q: FuzzyMatcher.Query, _ matcher: PathMatcher) -> MentionCandidate {
        let entry = partCatalog.entries[slot]
        let shape = catalog.anyAppearance(of: entry.shape)
        let symbol: String = if case .symbol(let name) = entry.part.lead { name } else { shape?.systemImage ?? "" }
        let appearance = MentionAppearance(label: entry.part.name, systemImage: symbol, kindName: entry.part.kindWord, detail: entry.part.kindWord,
                                           tint: shape?.tint)
        var matched: [Range<Int>] = [], along: [[Range<Int>]] = []
        let owner = paths.node(entry.shape).name
        if band == .path {
            let names = paths.containers(of: entry.shape).map { paths.node($0).name.title ?? "" } + [owner.title ?? shape?.label ?? "", entry.part.name]
            if let match = matcher.match(path: names, placingAtLeast: 1) {
                matched = match.matched.last ?? []
                along = Array(match.matched.dropLast())
            }
        } else {
            matched = FuzzyMatcher.match(q, in: FuzzyMatcher.Label(entry.part.name))?.matched ?? []
        }
        let containers = containersShown(of: entry.shape) + [(owner, paths.containers(of: entry.shape).count)]
        let place = MentionPlace(names: containers.map(\.name), matched: containers.map { along.indices.contains($0.index) ? along[$0.index] : [] })
        return MentionCandidate(id: entry.shape, appearance: appearance, isReadOnly: isReadOnly(entry.shape), matched: matched, place: place,
                                part: entry.part)
    }

    /// The rows the catalog holds of a shape, in its order (tests: the catalog's upkeep).
    public func listedParts(of shape: ShapeID) -> [PartName] {
        refreshStale()
        return partCatalog.rows(of: shape).map(\.part)
    }

    /// The shapes in the catalog on the board shown nearest `origin` that can be listed, up to
    /// `count`, nearest first: looked for in a square around it, grown until it holds enough,
    /// so a board of many mentionable shapes costs what's around the text; else in the board's
    /// entries of the catalog. A square's shapes are gathered from the whole board, so once one
    /// holds as many shapes as the board has in the catalog, reading those costs less than growing
    /// it again: a board with few mentionable shapes, or few the scope admits, reads its entries
    /// after at most one square that holds them all.
    private func nearest(to origin: CGPoint, count wanted: Int, excluding taken: Set<ShapeID>, members: [ShapeID]?,
                         admits: (ShapeID) -> Bool, distance: (ShapeID) -> Double?) -> [ShapeID] {
        func best(of ids: some Sequence<ShapeID>) -> [(id: ShapeID, distance: Double)] {
            var heap = BoundedHeap<(id: ShapeID, distance: Double)>(capacity: wanted) { $0.distance > $1.distance }
            for id in ids where !taken.contains(id) && catalog.contains(id) && admits(id) {
                if let d = distance(id) { heap.insert((id, d)) }
            }
            return heap.sorted()
        }
        let board = editor.board
        // A scope or a command that admits few shapes is read whole: its members, the nearest of them
        // on the board shown, however far they are (a square would grow over the board to find them).
        // Those on other boards have no distance, so they aren't asked.
        if let members, members.count <= MentionRanking.narrowScope || members.count * 8 <= catalog.entries.count {
            return best(of: members.lazy.filter { self.catalog.slot(of: $0).map { self.catalog.entries[$0].board == board } ?? false }).map(\.id)
        }
        // A board of no more than the shapes it could list, and those it leaves out, is read whole.
        let onBoard = catalog.count(on: board)
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

    /// Up to `count` of `members` that can be listed, but those taken, on any board, the nearest board
    /// first: the fewest boards from the board shown, up the file's tree to where the two paths meet
    /// and down again (the board shown's own 0, the board above it and those its shapes own 1, and so
    /// on); on a tie, in the catalog's order (read board by board from the root, each board's shapes
    /// in order; one that came since, after them). What a command's kinds list after what's near, so
    /// a frame or subboard on another board is listed with nothing typed. O(the members, and each of
    /// their boards' depth once).
    private func farther(_ members: [ShapeID], count: Int, excluding taken: Set<ShapeID>, admits: (ShapeID) -> Bool) -> [ShapeID] {
        let shown = editor.boardPath, file = editor.file
        var boardsApart: [BoardID: Int] = [:]
        var ranked: [(apart: Int, slot: Int, id: ShapeID)] = []
        for id in members where !taken.contains(id) {
            guard let slot = catalog.slot(of: id) else { continue }
            let board = catalog.entries[slot].board, apart: Int
            if let known = boardsApart[board] {
                apart = known
            } else {
                guard let path = file.path(to: board) else { continue }
                let shared = zip(shown, path).prefix { $0.0 == $0.1 }.count
                apart = shown.count + path.count - 2 * shared
                boardsApart[board] = apart
            }
            ranked.append((apart, slot, id))
        }
        ranked.sort { ($0.apart, $0.slot) < ($1.apart, $1.slot) }
        var found: [ShapeID] = []
        for entry in ranked where admits(entry.id) {
            found.append(entry.id)
            if found.count == count { break }
        }
        return found
    }

    /// The first `limit` of these unnamed shapes that can be listed, but those taken: the board shown's
    /// first, nearest the owner first, then the other boards', the nearest board first, a board's in
    /// document order where it has one, else by id. O(the shapes, and their boards' depth once, and
    /// a logarithm of `limit` for each): a heap keeps the best `limit`, never a sort of all of them.
    private func unnamedInOrder(_ ids: [ShapeID], excluding taken: Set<ShapeID>, admits: (ShapeID) -> Bool,
                                distance: (ShapeID) -> Double?, limit: Int) -> [ShapeID] {
        let shown = editor.boardPath, file = editor.file, document = editor.document
        var boardsApart: [BoardID: Int] = [:]
        typealias Place = (apart: Int, distance: Double, index: Int, id: ShapeID)
        // The id's text only breaks a tie of the rest.
        var best = BoundedHeap<Place>(capacity: limit) { a, b in
            if a.apart != b.apart { return a.apart > b.apart }
            if a.distance != b.distance { return a.distance > b.distance }
            if a.index != b.index { return a.index > b.index }
            return a.id.description > b.id.description
        }
        for id in ids where !taken.contains(id) {
            guard let unnamed = catalog.unnamed[id], admits(id) else { continue }
            let apart: Int
            if let known = boardsApart[unnamed.board] {
                apart = known
            } else {
                guard let path = file.path(to: unnamed.board) else { continue }
                let shared = zip(shown, path).prefix { $0.0 == $0.1 }.count
                apart = shown.count + path.count - 2 * shared
                boardsApart[unnamed.board] = apart
            }
            best.insert((apart, apart == 0 ? distance(id) ?? .infinity : 0, apart == 0 ? document.index(of: id) ?? 0 : 0, id))
        }
        return best.sorted().map(\.id)
    }

    /// A shape as the picker lists it: how it shows, where it is (`place(ofShape:)`), and the characters of its name and of
    /// its containers' the query matched.
    private func candidate(_ id: ShapeID, matched: [Range<Int>], containersMatched: [[Range<Int>]] = []) -> MentionCandidate {
        MentionCandidate(id: id, appearance: catalog.anyAppearance(of: id)!, isReadOnly: isReadOnly(id), matched: matched,
                         place: place(ofShape: id, matched: containersMatched))
    }

    /// Whether a shape, on whichever board of the file it's on, can't change: locked, in a locked
    /// frame, or on a locked subboard's board, at any depth (`editor.isReadOnly(inFile:)`). O(its
    /// depth).
    private func isReadOnly(_ id: ShapeID) -> Bool { editor.isReadOnly(inFile: id) }

    // MARK: Following the document

    /// What a commit changed, applied: what's mentioned (Topology's index, which takes the commit in first,
    /// having been looked up as this service was made, and tells its change, `follow`, as it does), the
    /// resolutions, the catalog; then the observers of the targets whose resolution changed (once this service
    /// has the commit), and the rows it affects.
    private func hear(_ changes: ChangeSet) {
        paths.forget(changes)
        for id in changes.removed {
            removeEntry(id)
            stale.remove(id)
        }
        forgetLayout(of: changes.removed)
        for id in changes.added where !changes.moved.contains(id) { stale.insert(id) }
        for id in changes.changed where !changes.moved.contains(id) { stale.insert(id) }
        var changedTargets: Set<ShapeID> = []
        for id in changes.shapeIDs where !changes.moved.contains(id) { resolveAgain(id, into: &changedTargets) }
        // Shapes on other boards it reached: those a deletion took with a board, or a paste
        // brought, or a write to a board that isn't shown changed.
        for id in changes.elsewhere { resolveAgain(id, into: &changedTargets) }
        stale.formUnion(changes.elsewhere)
        let affected = changedTargets.reduce(into: Set<ShapeID>()) { $0.formUnion(mentionerSet(of: $1)) }
        // The shapes that lay out by names: those whose names changed, and those whose text did (a
        // paste of a rename's stale names, an edit, an undo), on any board.
        if !layoutKinds.isEmpty {
            refreshLayout(of: affected)
            // A pure move changes no text, so a drag costs nothing here.
            refreshLayout(of: changes.added.lazy.filter { !changes.moved.contains($0) })
            refreshLayout(of: changes.changed.lazy.filter { !changes.moved.contains($0) })
            refreshLayout(of: changes.elsewhere)
        }
        lastAffected = affected
        if changes.replacedDocument { readCatalog() }                   // a board or file put in place: read now, not at the first `@`
        if !changedTargets.isEmpty { editor.onceHeard { [weak self] in self?.tell(changedTargets) } }
    }

    /// A change to the edges, heard from Topology: the shapes whose mentions it changed, at either
    /// end (another type's edges, an arrow bound to a mentioned shape, change none of what mentions
    /// it). Those mentioned now are tracked, and those no longer mentioned (nor observed) aren't.
    private func follow(_ change: TopologyChange) {
        guard let topology else { return }
        for id in change.touched(types: mentionEdges, in: topology.types) {
            followRows(of: id)
            guard observersByTarget[id] == nil else { continue }
            let isTracked = resolutions[id] != nil
            let isMentioned = isMentionedAnywhere(id)
            if isMentioned, !isTracked {
                resolutions[id] = resolve(id)
            } else if !isMentioned, isTracked {
                resolutions[id] = nil
            }
        }
    }

    /// The rows of `shape` tracked again after a change to the mentions into it: those mentioned, and those observed.
    private func followRows(of shape: ShapeID) {
        let mentioned = mentionedRows(of: shape)
        var rows = rowResolutions[shape] ?? [:]
        for part in rows.keys where !mentioned.contains(part) && observedRows[PartAddress(shape, part: part)] == nil { rows[part] = nil }
        let fresh = mentioned.filter { rows[$0] == nil }
        if !fresh.isEmpty { rows.merge(resolveRows(Array(fresh), of: shape)) { _, new in new } }
        rowResolutions[shape] = rows.isEmpty ? nil : rows
    }

    /// Resolves a tracked target again, and its tracked rows, noting it in `changed` if what it or one of them shows changed.
    private func resolveAgain(_ id: ShapeID, into changed: inout Set<ShapeID>) {
        if let rows = rowResolutions[id] {
            let now = resolveRows(Array(rows.keys), of: id)
            if now != rows {
                rowResolutions[id] = now
                changed.insert(id)
            }
        }
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

    /// Resolves a row, kept with its shape's (which is tracked too).
    private func trackRow(_ target: PartAddress) {
        guard let part = target.part else { return track(target.shape) }
        trackRows([part], of: target.shape)
    }

    /// Resolves rows of one shape, those not yet kept, with its parts read once.
    private func trackRows(_ parts: Set<PartID>, of shape: ShapeID) {
        track(shape)
        let fresh = parts.filter { rowResolutions[shape]?[$0] == nil }
        guard !fresh.isEmpty else { return }
        rowResolutions[shape, default: [:]].merge(resolveRows(Array(fresh), of: shape)) { _, new in new }
    }

    private func untrackRowIfUnused(_ target: PartAddress) {
        guard let part = target.part, observedRows[target] == nil, !mentionedRows(of: target.shape).contains(part) else { return }
        rowResolutions[target.shape]?[part] = nil
        if rowResolutions[target.shape]?.isEmpty == true { rowResolutions[target.shape] = nil }
    }

    // MARK: The catalog

    /// Reads the catalog afresh: every mentionable shape on every board the editor can show
    /// (`editor.showableBoards`).
    private func readCatalog() {
        catalog = MentionCatalog()
        partCatalog = MentionPartCatalog()
        paths.forgetAll()
        memberSets = [:]
        stale = []
        for board in editor.showableBoards {
            for record in editor.contents(of: board).shapes { readEntry(record, on: board) }
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
                removeEntry(id)
            }
        }
        stale = []
    }

    /// A shape's catalog entry, read again: out of the catalog if it can't be mentioned, or its kind
    /// gives it no name.
    private func readEntry(_ record: AnyShapeRecord, on board: BoardID) {
        guard let appearance = appearance(of: record) else {
            removeEntry(record.id)
            return
        }
        guard !appearance.isPlaceholder else {
            removeEntry(record.id)
            catalog.setUnnamed(record.id, kind: record.kind, appearance, on: board)
            return
        }
        catalog.removeUnnamed(record.id)
        #if DEBUG
        entriesRead += 1
        #endif
        catalog.set(record.id, appearance, on: board, recentRank: recent.firstIndex(of: record.id) ?? -1)
        // Its rows with it: read again only where their names changed.
        partCatalog.set(record.id, parts: registry.parts(of: record) ?? [])
        for members in memberSets.values { members.set(record.id, admitted: members.admits(record, registry)) }
    }

    /// Takes a shape out of the catalog, and out of every set of members.
    private func removeEntry(_ id: ShapeID) {
        catalog.removeUnnamed(id)
        catalog.remove(id)
        partCatalog.remove(id)
        for members in memberSets.values { members.remove(id) }
    }

    /// The catalog's shapes `scope` admits, made at the first ask: one pass over the catalog, never again.
    private func members<S: MentionScope>(of scope: S.Type) -> ScopeMembers {
        members(.scope(ObjectIdentifier(S.self))) { record, registry in S.admits(record, in: registry) }
    }

    /// The catalog's shapes of these kinds, made at the first ask as a scope's are, and kept as they are.
    private func members(ofKinds kinds: Set<ShapeKind>) -> ScopeMembers {
        members(.kinds(kinds)) { record, _ in kinds.contains(record.kind) }
    }

    private func members(_ key: MemberSet, admitting admits: @escaping @MainActor (AnyShapeRecord, Registry) -> Bool) -> ScopeMembers {
        if let found = memberSets[key] { return found }
        let made = ScopeMembers(admits: admits)
        let document = editor.document, file = editor.file, registry = registry
        for entry in catalog.entries {
            if let record = document[entry.id] ?? file.record(entry.id), made.admits(record, registry) { made.set(entry.id, admitted: true) }
        }
        memberSets[key] = made
        return made
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
        return registry.mentionAppearance(of: record, defaults: defaults, shapeTint: editor.ownTint(of: record))
    }
}

extension MentionState: EditorService {
    /// The file's colors changed, and with them the tint of the shapes that hold one: what's mentioned
    /// is resolved again, telling those whose pill changed, and the catalog's entries are read again
    /// at the next query (the `@` picker's rows are the entries' appearances).
    public func shapeTintsDidChange(in editor: CanvasEditor) {
        var changed: Set<ShapeID> = []
        for id in Array(resolutions.keys) { resolveAgain(id, into: &changed) }
        stale.formUnion(catalog.entries.lazy.map(\.id))
        tell(changed)
    }

    /// Follows the commit.
    public func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        hear(changes)
    }

    /// Nothing, but for a file put in place with the switch: what's mentioned, how each shows, and
    /// the catalog are the file's, kept up to date by every commit, whatever board it was on, so
    /// showing another board reads no mention text and resolves nothing. A file put in place has
    /// what it mentions resolved and its catalog read afresh. Recent picks and observations stay
    /// (the views observing pills of the board left go with it).
    public func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        lastAffected = []
        guard change.isFileReplaced else { return }
        resolutions = [:]
        rowResolutions = [:]
        forgetLayout(of: Array(laidOutByNames))
        trackMentioned()
        for target in observersByTarget.keys { track(target) }
        var observed: [ShapeID: Set<PartID>] = [:]
        for row in observedRows.keys { if let part = row.part { observed[row.shape, default: []].insert(part) } }
        for (shape, parts) in observed { trackRows(parts, of: shape) }
        readCatalog()
        layOutMentioners()
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

    /// Follows a mention of a row: to its shape (`goTo`, its board shown first), the row then selected as an item of it (Selection's
    /// `selectItems`); a row that's gone, the shape alone. A shape as a whole, as `followMention(of:)` for its id.
    func followMention(of target: PartAddress) {
        guard let part = target.part else { return followMention(of: target.shape) }
        goTo([target.shape])
        guard document[target.shape] != nil, registry.parts(of: document[target.shape]!)?.contains(where: { $0.id == part }) == true else { return }
        selectItems([AnyHashable(part)], of: target.shape)
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
    let rows: Set<PartAddress>
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
    /// Where the shape is, from the board shown (`MentionState.place(ofShape:)`): nil on the board shown, in no container. For a
    /// row, the place of its shape and the shape's own name.
    public let place: MentionPlace?
    /// The row of the shape it is, for a list that asks for rows (`candidates(…listingParts:)`): its `appearance` is the row's
    /// (its name, its kind word); nil for the shape as a whole.
    public let part: PartName?

    public init(id: ShapeID, appearance: MentionAppearance, isReadOnly: Bool, matched: [Range<Int>], place: MentionPlace? = nil, part: PartName? = nil) {
        self.id = id
        self.appearance = appearance
        self.isReadOnly = isReadOnly
        self.matched = matched
        self.place = place
        self.part = part
    }

    /// What it is: its shape, and its row if it is one.
    public var address: PartAddress { PartAddress(id, part: part?.id) }
}

/// What the picker lists: for an empty query, recent picks and nearby shapes; for any other, the
/// best matches, best first.
public struct MentionCandidates: Hashable, Sendable {
    public var recent: [MentionCandidate]
    public var nearby: [MentionCandidate]
    public var matches: [MentionCandidate]
    /// Whether the matcher's typo pass ran for the query: it reads every label, so a list that ranked a narrowed set
    /// (`among:`) and not the whole one would have missed a typo of the query among the rest.
    public var forgave: Bool
    /// How many words the query had (`MentionMatcher.words(in:)`): 0 for an empty one. A query of more than one word also finds the
    /// shapes whose containers' names it has, so a longer query matches fewer shapes only among queries of as many words.
    public var words: Int

    public init(recent: [MentionCandidate] = [], nearby: [MentionCandidate] = [], matches: [MentionCandidate] = [], forgave: Bool = false,
                words: Int = 0) {
        self.recent = recent
        self.nearby = nearby
        self.matches = matches
        self.forgave = forgave
        self.words = words
    }

    /// Every row, in order.
    public var all: [MentionCandidate] { recent + nearby + matches }
}

/// Which shapes of the catalog a set of members is: those a scope admits, or those of the kinds a
/// text's command takes. A set of kinds is its own key.
private enum MemberSet: Hashable {
    case scope(ObjectIdentifier)
    case kinds(Set<ShapeKind>)
}

/// The catalog's shapes a scope admits, or those of some kinds, in no order of their own: what a
/// scope or a command that admits few ranks in place of the whole catalog.
@MainActor
private final class ScopeMembers {
    let admits: @MainActor (AnyShapeRecord, Registry) -> Bool
    private(set) var ids: [ShapeID] = []
    private var positions: [ShapeID: Int] = [:]

    init(admits: @escaping @MainActor (AnyShapeRecord, Registry) -> Bool) { self.admits = admits }

    /// Whether a shape is a member.
    func contains(_ id: ShapeID) -> Bool { positions[id] != nil }

    /// A member, or no longer one.
    func set(_ id: ShapeID, admitted: Bool) {
        guard admitted else { return remove(id) }
        guard positions[id] == nil else { return }
        positions[id] = ids.count
        ids.append(id)
    }

    /// Takes a shape out: the last takes its place.
    func remove(_ id: ShapeID) {
        guard let position = positions.removeValue(forKey: id) else { return }
        let last = ids.count - 1
        if position != last {
            ids[position] = ids[last]
            positions[ids[position]] = position
        }
        ids.removeLast()
    }
}

/// Where a query of several words ranks a match: by its name (a tier from a substring up), by its path (a word or more in the
/// containers the shape is inside), or by its name loosely (a subsequence, a typo). A query of one word has the first alone.
private enum MatchBand: Comparable {
    case name, path, loose
}

/// A catalog entry a query matched, by its slot, and its score.
private struct Found {
    let slot: Int
    var score: Int
    var band: MatchBand = .name
}

/// A mention text view the pill commands act on (`MentionState.enter`).
@MainActor
protocol PillCommandText: AnyObject {
    var pillOnCaret: MentionAttachment? { get }
    var canRemovePillOnCaret: Bool { get }
    func removePillOnCaret()
    func canShowWhatMentions(of pill: MentionAttachment) -> Bool
}

extension MentionTextView: PillCommandText {}

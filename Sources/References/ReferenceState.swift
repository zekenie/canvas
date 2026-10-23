import AppKit
import Boards
import Canvas
import Connections
import Geometry
import LanguageModels
import Mentions
import Publishing
import Queries
import Selection
import Topology

/// Per editor, for the whole file: what each reference stands for now (`state(of:)`), the one place
/// the panel, the table of contents and the menu ask. A pill reads the same condition from its render
/// context, where it can't ask a service.
///
/// What a direct reference stands for is a function of its record and the file, so there's nothing
/// to be told: a rename, a deletion or a change of publicness of the shape it names changes what the
/// pill, its row and its panel show, and `directReferences(naming:)` says which references that is,
/// in O(what changed), for the rows the list makes again: Topology's, which keeps which stand-in
/// names which shape (`standIns(naming:)`) on every board the app can show and hears each commit
/// before anyone reads it. What a dynamic reference stands for is what its query finds, which this
/// service asks the engine and hands to Topology (`ReferenceAnswers.swift`).
@MainActor
public final class ReferenceState {
    unowned let editor: CanvasEditor
    /// The reference being typed into whose list has only the words row left (the hand-off to
    /// natural language): its pill leads with the magnifier.
    private var handingOff: ShapeID?
    /// What each reference's channel mismatch was (`channelMismatch(of:)`), at the revision of its
    /// edges in Topology it was worked out at.
    var mismatches: [ShapeID: (revision: Int, mismatch: ChannelMismatch?)] = [:]
    /// What each direct reference's pill was last drawn standing for, and the target it was worked
    /// out for (`drawnCondition(of:target:_:)`): a frame of a thousand pills looks up none of their
    /// shapes again. A commit lets go of those it changed and those that name a shape it changed
    /// (Topology's `standIns(naming:)`, as the rows' `affected`), a file put in place of all.
    /// With where its shape is when that isn't where the pill is (`drawnPlace(of:)`), and the shapes that was read
    /// from (the containers the shape is inside: a change to one lets go of the places kept).
    private var drawnConditions: [ShapeID: (target: ReferenceTarget, condition: ReferenceCondition, place: String?)] = [:]
    private var drawnPlaceSources: Set<ShapeID> = []
    /// The containment tree's names, for the places and the rows' paths (Boards' `ShapePaths`).
    var paths: ShapePaths
    /// What each pill drawn shows of a channel mismatch (`drawnMismatch(of:)`), kept until a change to
    /// the edges touches its reference: what bumps the revision `mismatches` is kept by, heard
    /// without reading one (each read makes an observation's key path, a cost a frame of a thousand
    /// pills shouldn't pay).
    private var drawnMismatches: [ShapeID: ChannelID?] = [:]
    /// Following Topology's changes to the edges, for `drawnMismatches`.
    private var following: TopologyFollowing?
    /// The shapes each direct reference's row in the table of contents read its path from (the shapes
    /// its original and it are inside: `rowPath(of:to:)`), and which rows read each, so a commit that
    /// changes one (renamed, put in another frame, moved to another board) names those rows
    /// (`rowsAffected(by:)`). Noted as a row is made and kept until its reference changes or goes: a
    /// row the list keeps for a board not shown is still a row to make again.
    var pathSources = ReverseIndex()

    // What dynamic references found (`ReferenceAnswers.swift`).
    /// Every reference with a query on a board the app can show, and what its query found.
    var dynamic: [ShapeID: Finding] = [:]
    /// Whether every dynamic reference's answer may be out of date (a commit that changed something
    /// else than their own questions): asked of them all at the next batch.
    var everyDirty = false
    /// The last answers of each reference, by key, newest last: kept past its deletion, for its undo,
    /// for at most `ReferenceStyle.memosKept` references, naming at most `ReferenceStyle.memoIDsKept`
    /// shapes between them (`remember(_:for:)`), which `memoIDs` counts.
    var memo: [ShapeID: Memo] = [:]
    var memoIDs = 0
    var memoIDBound = ReferenceStyle.memoIDsKept
    /// What stamps a memo as it's landed or used, so the bound lets go of the least recent.
    var memoClock = 0
    /// The wait for quiet after a commit, a hop to ask at once, and the batch out.
    var debounce: ScheduledTask?
    var hop: ScheduledTask?
    var batch: Task<Void, Never>?
    /// The questions out for every match of a reference (`everyMatch(of:admitting:then:)`): what Show
    /// Matches selects (the last asked), and what Make Public writes, per reference.
    private var showing: Task<Void, Never>?
    private var makingPublic: [ShapeID: Task<Void, Never>] = [:]
    /// Whether the batch out has been out past `ReferenceStyle.findingDelay`, and the timer that says so.
    var isSlow = false
    var slowTimer: ScheduledTask?
    /// Which references' answers changed, observed per reference.
    let answered = AnswerRevisions()
    /// Topology's settling counts this service's work.
    private var settling: SettleSource?
    /// What typing and interpreting have made of references' words, by reference: never in the
    /// document (`ReferenceInterpreting.swift`).
    var interpretations: [ShapeID: Interpretation] = [:]
    var lastGeneration = 0
    private var keyObserver: (any NSObjectProtocol)?
    #if DEBUG
    /// How many batches have been asked, and how many have landed (debug builds).
    public internal(set) var batchesAsked = 0
    public internal(set) var batchesLanded = 0
    /// How many references answers are kept for (at most `ReferenceStyle.memosKept`), and whether
    /// any are for `id` (debug builds).
    public var memoCount: Int { memo.count }
    /// How many shapes the answers kept name between them (debug builds).
    public var memoIDCount: Int { memoIDs }
    /// Bounds the shapes the answers kept may name to `ids`, in place of `ReferenceStyle.memoIDsKept`
    /// (debug builds): for a test of the bound, which a million ids would make slow.
    public func boundMemo(toIDs ids: Int) { memoIDBound = ids }
    public func isRemembered(_ id: ShapeID) -> Bool { memo[id] != nil }
    /// How many times a row has read its path (`rowPath(of:to:)`: a direct reference's row made, or
    /// made again), so a test holds a change to remaking the rows whose paths it changes (debug builds).
    public internal(set) var pathsRead = 0
    #endif

    init(editor: CanvasEditor) {
        self.editor = editor
        paths = ShapePaths(editor: editor)
        settling = editor.topology?.keepsSettling { [weak self] in self?.isFinding ?? false }
        following = editor.topology?.follow { [weak self] change in self?.edgesChanged(change) }
        rebuildDynamic()
        // A key saved in Settings tries again the words that failed for want of one.
        keyObserver = NotificationCenter.default.addObserver(forName: .languageModelKeyDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keyDidChange() }
        }
    }

    /// The file closed and the editor went: whatever is out for it stops. A model call in flight is
    /// cancelled, so it doesn't run on (a minute at most) spending the person's tokens on an answer
    /// nothing lands; so are the batch, the waits and the draft's request. Isolated, so every one of
    /// them is the main actor's to cancel, as it is while the editor lives.
    isolated deinit {
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        debounce?.cancel()
        hop?.cancel()
        slowTimer?.cancel()
        batch?.cancel()
        showing?.cancel()
        for task in makingPublic.values { task.cancel() }
        for entry in interpretations.values { entry.cancelWork() }
        settling?.cancel()
        following?.cancel()
    }

    // MARK: What a reference stands for

    /// What the reference stands for now; nil for a shape that isn't a reference, or isn't in the file.
    public func state(of id: ShapeID) -> ReferenceCondition? {
        editor.shape(inFile: id)?.typed(as: Reference.self).map { state(of: $0.props, id: id) }
    }

    /// What a reference with these props stands for now: the reference `id`'s answer, for a dynamic
    /// one (observed, so a view that reads it draws again as answers come); none, not answered yet.
    public func state(of props: Reference, id: ShapeID? = nil) -> ReferenceCondition {
        ReferenceCondition.of(shown(props, id: id), status: id.flatMap(status(of:)), registry: editor.registry, lookup: { editor.shape(inFile: $0) },
                              isElsewhere: isElsewhere, appearance: { [editor] in editor.mentionAppearance(of: $0) })
    }

    /// Whether the file holds a shape the app can't show (on a board it can't, or kept aside), which a
    /// reference to it shows as not available, not as deleted.
    func isElsewhere(_ id: ShapeID) -> Bool { editor.file.board(containing: id) != nil }

    // MARK: Pills drawn

    /// What a direct reference's pill stands for, for a render: kept from the frame before unless a
    /// commit changed it or what it names; `compute` works it out (with the render's lookups) when
    /// it isn't kept, or was kept for another target (a record drawn that isn't the one committed).
    func drawnCondition(of id: ShapeID, target: ReferenceTarget, _ compute: () -> ReferenceCondition) -> ReferenceCondition {
        if let kept = drawnConditions[id], kept.target == target { return kept.condition }
        let condition = compute()
        var place: String?
        if condition.appearance != nil { place = placeOfTarget(from: id, target.id) }
        drawnConditions[id] = (target, condition, place)
        return condition
    }

    /// Where the shape a pill stands for is, from where the pill is: the containers it is inside less those the
    /// pill is inside too (`rowPath`'s), joined as a path says them; for a shape in none, on another board, that board's
    /// name; nil for a shape in the pill's own place. Notes the shapes it was read from (`drawnPlaceSources`).
    private func placeOfTarget(from pill: ShapeID, _ target: ShapeID) -> String? {
        let above = paths.containers(of: target), own = paths.containers(of: pill)
        let names = Self.pathBeyond(own, above).map { paths.node($0).name.text }
        if !names.isEmpty {
            drawnPlaceSources.formUnion(above)
            drawnPlaceSources.formUnion(own)
            return names.joined(separator: ShapePath.separator)
        }
        guard let there = editor.file.board(containing: target), there != editor.file.board(containing: pill) else { return nil }
        if let owner = there.owner { drawnPlaceSources.insert(owner) }
        return editor.name(of: there, root: ReferenceStyle.rootBoardName)
    }

    /// Where the shape a direct pill stands for is, when it isn't where the pill is (the pill says it, after the
    /// shape's name, "Alpha › Beta"; the name of its board for a shape in no container); nil for a pill in the same
    /// place as its shape, or one whose shape isn't there. As `drawnCondition` kept it: a rename of a container, or
    /// of the board, lets go of it.
    public func drawnPlace(of id: ShapeID) -> String? { drawnConditions[id]?.place }

    /// `mismatchedChannel(of:)`, for a render: kept until a change to the edges touches the reference.
    func drawnMismatch(of id: ShapeID) -> ChannelID? {
        if let kept = drawnMismatches[id] { return kept }
        let found = mismatchedChannel(of: id)
        drawnMismatches.updateValue(found, forKey: id)
        return found
    }

    /// A change to the edges: the mismatches drawn of the references it touched are worked out again.
    private func edgesChanged(_ change: TopologyChange) {
        guard !drawnMismatches.isEmpty else { return }
        if drawnMismatches.count < change.touched.count {
            for id in Array(drawnMismatches.keys) where change.touched.contains(id) { drawnMismatches.removeValue(forKey: id) }
        } else {
            for id in change.touched { drawnMismatches.removeValue(forKey: id) }
        }
    }

    /// A commit: the conditions drawn of the references it touched (`touched`) and of those that name
    /// a shape it changed are worked out again, and the mismatches of those it removed let go of.
    private func forgetDrawn(_ changes: ChangeSet, touched: [ShapeID: AnyShapeRecord?]) {
        if !drawnConditions.isEmpty {
            for id in touched.keys { drawnConditions.removeValue(forKey: id) }
            for id in references(namingWhatChanged: changes) { drawnConditions.removeValue(forKey: id) }
            // A place changes with the containers it was read from (renamed, put elsewhere, deleted, a board's
            // owner): the places kept are worked out again.
            if !drawnPlaceSources.isEmpty, changes.changed.contains(where: { drawnPlaceSources.contains($0) })
                || changes.removed.contains(where: { drawnPlaceSources.contains($0) })
                || changes.elsewhere.contains(where: { drawnPlaceSources.contains($0) }) {
                for (id, kept) in drawnConditions where kept.place != nil { drawnConditions.removeValue(forKey: id) }
                drawnPlaceSources = []
            }
        }
        if !drawnMismatches.isEmpty {
            for id in changes.removed { drawnMismatches.removeValue(forKey: id) }
        }
    }

    // MARK: Who names what

    /// The direct references, on boards the app can show, that name any of these shapes: those whose
    /// pill, row and panel show what a change to the shape changed. Topology's (`standIns(naming:)`),
    /// the references among them.
    public func directReferences(naming ids: some Sequence<ShapeID>) -> Set<ShapeID> {
        guard let topology = editor.topology, topology.hasStandIns else { return [] }
        var found: Set<ShapeID> = []
        for id in ids { insertReferences(naming: id, from: topology, into: &found) }
        return found
    }

    /// The shape the direct reference names, wherever it is (a reference on a board the app can show).
    public func target(of reference: ShapeID) -> ShapeID? {
        guard let topology = editor.topology, Self.isReference(reference, in: topology) else { return nil }
        return topology.directTarget(of: reference)
    }

    /// The references a commit may change the rows of without changing them: those that name a shape it
    /// changed (renamed, made private, deleted, brought back by an undo), and those whose row's path
    /// names a shape it changed or was read from one (a frame or a board's owner renamed, or put
    /// somewhere else: `pathSources.by`), moved ones aside. O(what the commit changed).
    func rowsAffected(by changes: ChangeSet) -> Set<ShapeID> {
        var found = references(namingWhatChanged: changes)
        if !pathSources.by.isEmpty {
            forEachChanged(by: changes) { id in if let readers = pathSources.by[id] { found.formUnion(readers) } }
        }
        return found
    }

    /// The direct references that name a shape a commit changed, moved ones aside: those whose pill
    /// may stand for something else now.
    private func references(namingWhatChanged changes: ChangeSet) -> Set<ShapeID> {
        guard let topology = editor.topology, topology.hasStandIns else { return [] }
        var found: Set<ShapeID> = []
        forEachChanged(by: changes) { id in insertReferences(naming: id, from: topology, into: &found) }
        return found
    }

    /// The references among the stand-ins whose record names `id`.
    private func insertReferences(naming id: ShapeID, from topology: TopologyIndex, into found: inout Set<ShapeID>) {
        for standIn in topology.standIns(naming: id) where Self.isReference(standIn, in: topology) { found.insert(standIn) }
    }

    /// Whether the shape is a reference Topology keeps (on a board the app can show), as it has heard the file.
    static func isReference(_ id: ShapeID, in topology: TopologyIndex) -> Bool { topology.standInKind(of: id) == Reference.kind }

    /// Every shape a commit added, changed other than by moving it, or removed, on any board.
    private func forEachChanged(by changes: ChangeSet, _ body: (ShapeID) -> Void) {
        for id in changes.added { body(id) }
        for id in changes.changed where !changes.moved.contains(id) { body(id) }
        for id in changes.removed { body(id) }
        for id in changes.elsewhere { body(id) }
    }

    /// A file put in place: what was drawn is let go of, and what rows read their paths from is kept for the
    /// rows the list kept, but for the references that went.
    private func filePutInPlace() {
        drawnConditions = [:]
        drawnPlaceSources = []
        paths.forgetAll()
        drawnMismatches = [:]
        let topology = editor.topology
        for id in Array(pathSources.of.keys) where !(topology.map { Self.isReference(id, in: $0) } ?? false) { forgetPath(of: id) }
    }

    /// The references a commit touched, each once, as they are now: those it added, changed (moves
    /// aside), removed from the board shown to put elsewhere, or touched elsewhere (every shape of a board
    /// it brought or took, and what it wrote on a board it changed), and, as nil, those of its shapes that
    /// are no reference now but something is kept of (a reference it deleted, or took with a board). What
    /// is a reference is Topology's to say (`standInKind(of:)`: a stand-in of this kind on a board the app
    /// can show), which has heard the commit, so a commit of thousands of shapes and no reference costs a
    /// dictionary hit a shape (none while the file has no stand-in and nothing is kept), never a lookup in
    /// the file.
    private func referencesTouched(by changes: ChangeSet) -> [ShapeID: AnyShapeRecord?] {
        var touched: [ShapeID: AnyShapeRecord?] = [:]
        guard let topology = editor.topology,
              topology.hasStandIns || !pathSources.of.isEmpty || !dynamic.isEmpty || !drawnConditions.isEmpty else { return touched }
        let file = editor.file
        forEachChanged(by: changes) { id in
            if Self.isReference(id, in: topology) {
                touched.updateValue(file.record(id), forKey: id)
            } else if pathSources.of[id] != nil || dynamic[id] != nil || drawnConditions[id] != nil {
                touched.updateValue(nil, forKey: id)
            }
        }
        return touched
    }

    // MARK: Typing

    /// Whether the list over the reference's field has only the words row left, which its pill, while
    /// it's edited, shows by leading with the magnifier.
    public func isHandingOff(_ id: ShapeID) -> Bool { handingOff == id }

    /// The field of the reference `id` says whether its list has only the words row left; the canvas is
    /// drawn again when that changes, since the pill's leading symbol does.
    func setHandingOff(_ on: Bool, for id: ShapeID) {
        let now: ShapeID? = on ? id : (handingOff == id ? nil : handingOff)
        guard now != handingOff else { return }
        handingOff = now
        editor.setNeedsDisplay()
    }

    // MARK: Going to the original

    /// Goes to what a reference stands for: the shape a direct one names, as following a mention of it
    /// does (to it, or into it, as its kind has it: one step back either way), and what a dynamic one
    /// found (the first match as a mention's, every match by going to them): on the next turn of the
    /// scheduler, since a click on the pill that began it is still being tracked. Nothing for one that
    /// stands for nothing there is (missing, not available, no matches) or no shape.
    func goToOriginal(_ reference: ShapeID) {
        guard let targets = originals(of: reference), let first = targets.first else { return }
        if targets.count == 1 {
            editor.mentions?.follow(first)
        } else {
            go(to: targets)
        }
    }

    /// The only reference among these goes to its original.
    func goToOriginal(of ids: Set<ShapeID>) {
        guard ids.count == 1, let id = ids.first else { return }
        goToOriginal(id)
    }

    func canGoToOriginal(of ids: Set<ShapeID>) -> Bool {
        guard ids.count == 1, let id = ids.first else { return false }
        return originals(of: id) != nil
    }

    /// Whether the menu offers Go to Original on these shapes: one reference that names a shape.
    func canOffer(goingTo ids: [ShapeID]) -> Bool {
        guard ids.count == 1, let record = editor.document[ids[0]]?.typed(as: Reference.self) else { return false }
        return record.props.target != nil
    }

    /// Whether the menu offers Show Matches on these shapes: one reference of words or a query.
    func canOffer(showingMatches ids: [ShapeID]) -> Bool {
        guard ids.count == 1, let record = editor.document[ids[0]]?.typed(as: Reference.self) else { return false }
        return record.props.mode == .dynamic
    }

    /// The matches a dynamic reference was given (the first and what All would add, or every one); nil
    /// while it has none.
    func matches(of reference: ShapeID) -> [ShapeID]? {
        guard case .found(_, let found)? = state(of: reference) else { return nil }
        return found.ids
    }

    /// Shows the matches of the only reference among these: their board, every one its header counts
    /// selected on it. A reference given fewer than it counts (a first-match one is given eight) has its
    /// query asked for every one first.
    func showMatches(of ids: Set<ShapeID>) {
        guard ids.count == 1, let id = ids.first, case .found(_, let found)? = state(of: id) else { return }
        showing?.cancel()
        guard found.count > found.ids.count else { return go(to: found.ids) }
        // Answered in a turn of its own, after the click that asked: gone to at once.
        showing = everyMatch(of: id, admitting: admission) { [weak self] matches in
            self?.showing = nil
            if let matches { self?.editor.goTo(matches) }
        }
    }

    /// Makes public every shape the reference's query finds that would be stood for once it is
    /// (Publishing's `admittable`), wherever it is: one step, "Make Public". Asked of the query first,
    /// as the reference holds only how many there are; the reference takes them in as it does any
    /// change, once its wait for quiet ends.
    public func makeMatchesPublic(of id: ShapeID) {
        guard let publishing = editor.publishing else { return }
        makingPublic[id]?.cancel()
        makingPublic[id] = everyMatch(of: id, admitting: publishing.admittable) { [weak self] matches in
            guard let self else { return }
            makingPublic[id] = nil
            if let matches { editor.makePublic(matches) }
        }
    }

    /// Asks the reference's query (its draft's, while it's typed into) for every match `admitting`
    /// takes, as its own answers are asked (on the recorded view), and hands them to `then` on the main
    /// actor: nil when the query was refused or isn't the reference's any more (words typed since).
    /// Nothing is handed over once the task is cancelled (the file closing cancels it); nil, no task,
    /// when there's no query to ask.
    private func everyMatch(of id: ShapeID, admitting: @escaping @Sendable (AnyShapeRecord) -> Bool,
                            then: @escaping @MainActor @Sendable ([ShapeID]?) -> Void) -> Task<Void, Never>? {
        guard let queries = editor.queries, let props = editor.shape(inFile: id)?.typed(as: Reference.self)?.props,
              let query = shown(props, id: id).query else { return nil }
        return Task { @MainActor [weak self, queries] in
            let results = await queries.matches([QueryMatchRequest(query, edges: .recorded, limit: QueryMatchRequest.every, admitting: admitting)])
            guard !Task.isCancelled, let self else { return }
            let asks = editor.shape(inFile: id)?.typed(as: Reference.self).flatMap { shown($0.props, id: id).query }
            guard asks == query, case .success(let matches)? = results.first else { return then(nil) }
            then(matches.ids)
        }
    }

    /// What going to the original goes to, while there's something: a direct reference's shape (public
    /// or not), or what a dynamic one stands for.
    private func originals(of reference: ShapeID) -> [ShapeID]? {
        guard let record = editor.shape(inFile: reference)?.typed(as: Reference.self) else { return nil }
        switch state(of: record.props, id: reference) {
        case .live, .notPublic: return record.props.target.map { [$0.id] }
        case .found(_, let found): return found.standsFor
        default: return nil
        }
    }

    /// Goes to these shapes (their board, them selected), on the next turn of the scheduler.
    private func go(to ids: [ShapeID]) {
        _ = editor.scheduler.schedule(after: .zero) { [weak editor] in editor?.goTo(ids) }
    }

    // MARK: The leading symbol, as a canvas button

    /// The button the leading symbol of the reference under a view point is, if it goes anywhere: in
    /// full (a skeleton shows no symbol), not while the pill is edited, and only on the shape the select
    /// tool would press there.
    func goButton(atViewPoint point: CGPoint) -> GoButton? {
        guard !editor.drawsSkeletons else { return nil }
        let camera = editor.camera, world = camera.toWorld(point)
        guard let id = editor.selectableShape(at: world), id != editor.editingShapeID,
              let record = editor.document[id]?.typed(as: Reference.self), state(of: record.props, id: id).hasOriginal else { return nil }
        return ReferenceStyle.goBox(of: record.frame, zoom: camera.zoom).contains(world) ? GoButton(reference: id) : nil
    }

    // MARK: The pointer resting on a pill

    /// What a pill that stands for nothing says while the pointer rests on it.
    func popover(on record: AnyShapeRecord) -> CanvasPopover? {
        guard let reference = record.typed(as: Reference.self), editor.editingShapeID != record.id,
              let help = Self.help(for: state(of: reference.props, id: record.id)) else { return nil }
        let text = NSAttributedString(string: help, attributes: [.font: ReferenceStyle.helpFont, .foregroundColor: ReferenceStyle.label])
        return CanvasPopover(id: record.id, anchor: reference.frame, text: text)
    }

    static func help(for condition: ReferenceCondition) -> String? {
        switch condition {
        case .missing: ReferenceStyle.deletedHelp
        case .unavailable: ReferenceStyle.unavailableHelp
        case .notPublic, .privateMatches: ReferenceStyle.privateHelp
        default: nil
        }
    }

    // MARK: The panel's header

    /// What the panel's header says of a reference: its symbol, what it stands for, and a line under it
    /// (for a dynamic one, how many it found: "First of 7", "12 matches", "1,284 matches", "No matches",
    /// or "Not public" when none of what it found is; none while it's being looked for or failed,
    /// which the Query section says).
    public func header(of props: Reference, id: ShapeID? = nil) -> ReferenceHeaderContent {
        switch state(of: props, id: id) {
        case .empty:
            return ReferenceHeaderContent(symbol: ReferenceStyle.systemImage, title: ReferenceStyle.placeholder, subtitle: nil)
        case .live(let appearance):
            return ReferenceHeaderContent(symbol: appearance.systemImage, title: appearance.label, subtitle: kindAndPlace(appearance, of: props.target))
        case .missing(let label):
            return ReferenceHeaderContent(symbol: ReferenceStyle.missingSymbol, title: label, subtitle: ReferenceStyle.deletedHelp)
        case .unavailable(let label):
            return ReferenceHeaderContent(symbol: ReferenceStyle.missingSymbol, title: label, subtitle: ReferenceStyle.unavailableHelp)
        case .notPublic(let appearance):
            return ReferenceHeaderContent(symbol: appearance.systemImage, title: appearance.label, subtitle: ReferenceStyle.privateHelp)
        case .found(let text, let found):
            return ReferenceHeaderContent(symbol: ReferenceStyle.dynamicSymbol, title: text, subtitle: ReferenceStyle.matchesLine(found))
        case .noMatches(let text), .refused(let text, _):
            return ReferenceHeaderContent(symbol: ReferenceStyle.dynamicSymbol, title: text, subtitle: ReferenceStyle.noMatches)
        case .privateMatches(let text, _):
            return ReferenceHeaderContent(symbol: ReferenceStyle.dynamicSymbol, title: text, subtitle: ReferenceStyle.privateHelp)
        case .notInterpreted(let text), .interpreting(let text), .finding(let text), .failed(let text, _), .cannotFind(let text):
            return ReferenceHeaderContent(symbol: ReferenceStyle.dynamicSymbol, title: text, subtitle: nil)
        }
    }

    /// "Note · Payments › Invoices": the kind, then where the shape is when that isn't the board shown, directly:
    /// the containers it is inside (`MentionState.place(ofShape:)`), else its board's name.
    private func kindAndPlace(_ appearance: MentionAppearance, of target: ReferenceTarget?) -> String {
        guard let target, let place = place(ofShape: target.id) else { return appearance.kindName }
        return appearance.kindName + " · " + place
    }

    /// Where a shape is from the board shown, as lists of shapes say it (nil: directly on the board shown).
    func place(ofShape id: ShapeID) -> String? {
        if let place = editor.mentions?.place(ofShape: id) { return place.text }
        guard let board = editor.file.board(containing: id), board != editor.board else { return nil }
        return editor.name(of: board, root: ReferenceStyle.rootBoardName)
    }
}

/// What the panel's header says: a symbol, a title and an optional line under it.
public struct ReferenceHeaderContent: Equatable {
    public var symbol: String
    public var title: String
    public var subtitle: String?

    public init(symbol: String, title: String, subtitle: String?) {
        self.symbol = symbol
        self.title = title
        self.subtitle = subtitle
    }
}

/// The leading symbol of a reference, as a canvas button (`CanvasButtons`): clicking it goes to the
/// original.
struct GoButton: Hashable, Sendable {
    let reference: ShapeID
}

extension ReferenceStyle {
    /// Where the leading symbol's button is in a pill's frame: the symbol's box and a margin of
    /// `goMargin` view points all round, in world units.
    static func goBox(of frame: CGRect, zoom: CGFloat) -> CGRect {
        let margin = goMargin / zoom
        return CGRect(x: frame.minX + leadingPad - margin, y: frame.midY - symbolBox / 2 - margin,
                      width: symbolBox + margin * 2, height: symbolBox + margin * 2)
    }
}

extension ReferenceState: EditorService {
    /// A tint changed with no commit (the file's colors): a pill's kept condition holds its target's
    /// tint, so the kept ones are let go of and the pills drawn again.
    public func shapeTintsDidChange(in editor: CanvasEditor) {
        drawnConditions.removeAll(keepingCapacity: true)
        editor.setNeedsDisplay()
    }

    /// Lets go of what's kept of the references the commit touched (`referencesTouched(by:)`) and of
    /// those that name a shape it changed, and hears their questions: a commit that touches none costs a
    /// dictionary hit for what it touched, whatever the file holds.
    public func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        // A drag's every event: one test.
        if changes.changed.count == changes.moved.count, changes.added.isEmpty, changes.removed.isEmpty, changes.elsewhere.isEmpty,
           !changes.reordered, changes.boardsAdded.isEmpty, changes.boardsRemoved.isEmpty, !changes.replacedDocument { return }
        paths.forget(changes)
        hearInterpretations(changes)
        if !mismatches.isEmpty {
            for id in changes.removed { mismatches[id] = nil }
        }
        // A board put in place: every board read afresh.
        guard !changes.replacedDocument else {
            filePutInPlace()
            rebuildDynamic()
            return
        }
        let touched = referencesTouched(by: changes)
        forgetDrawn(changes, touched: touched)
        hearDynamic(changes, touched: touched)
        // Its row, made again for the reference as it is now, notes what its path reads then.
        for id in touched.keys { forgetPath(of: id) }
    }

    /// Editing ended: nothing is being handed off.
    public func editingDidEnd(_ id: ShapeID, in editor: CanvasEditor) {
        setHandingOff(false, for: id)
        editingEnded(id)
        interpretationEditingEnded(id)
    }

    /// A file put in place is read afresh. Another board shown changes nothing: what's kept is the file's,
    /// kept by every commit, whatever board it was on (`elsewhere`), so a switch works out no change set.
    public func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        if change.isFileReplaced {
            dropInterpretations()
            filePutInPlace()
            rebuildDynamic()
        }
    }
}

extension CanvasEditor {
    /// References' state; nil without ReferencesPlugin.
    public var references: ReferenceState? { service(ReferenceState.self) }
}

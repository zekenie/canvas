import AppKit
import Canvas
import Connections
import Geometry
import LanguageModels
import Mentions
import Publishing
import Queries
import Selection
import Topology

/// Per editor, for the whole file: which references name which shapes, kept as commits change shapes
/// (a commit's `ChangeSet`, `elsewhere` and the boards it brought or took included, and a file put
/// in place read afresh), and what each reference stands for now (`state(of:)`), the one place the
/// panel, the table of contents and the menu ask. A pill reads the same condition from its render
/// context, where it can't ask a service.
///
/// What a direct reference stands for is a function of its record and the file, so there's nothing
/// to be told: a rename, a deletion or a change of publicness of the shape it names changes what the
/// pill, its row and its panel show, and `directReferences(naming:)` says which references that is,
/// in O(what changed), for the rows the list makes again. Services before the table of contents in
/// the plugin list hear a commit before it asks. What a dynamic reference stands for is what its
/// query finds, which this service asks the engine and hands to Topology (`ReferenceAnswers.swift`).
@MainActor
public final class ReferenceState {
    unowned let editor: CanvasEditor
    /// The shape each reference names, and which references name each shape: every board of the file.
    private var targetOf: [ShapeID: ShapeID] = [:]
    private var referencesTo: [ShapeID: Set<ShapeID>] = [:]
    /// Every reference in the file, on any board: what a commit's shapes are held against, since a
    /// shape's kind never changes (`referencesTouched(by:)`).
    private var known: Set<ShapeID> = []
    /// The reference being typed into whose list has only the words row left (the hand-off to
    /// natural language): its pill leads with the magnifier.
    private var handingOff: ShapeID?
    /// What each reference's channel mismatch was (`channelMismatch(of:)`), at the revision of its
    /// edges in Topology it was worked out at.
    var mismatches: [ShapeID: (revision: Int, mismatch: ChannelMismatch?)] = [:]
    /// What each direct reference's pill was last drawn standing for, and the target it was worked
    /// out for (`drawnCondition(of:target:_:)`): a frame of a thousand pills looks up none of their
    /// shapes again. A commit lets go of those it changed and those that name a shape it changed
    /// (the reverse map, as the rows' `affected`), a file put in place of all.
    private var drawnConditions: [ShapeID: (target: ReferenceTarget, condition: ReferenceCondition)] = [:]
    /// What each pill drawn shows of a channel mismatch (`drawnMismatch(of:)`), kept until a change to
    /// the edges touches its reference: what bumps the revision `mismatches` is kept by, heard
    /// without reading one (each read makes an observation's key path, a cost a frame of a thousand
    /// pills shouldn't pay).
    private var drawnMismatches: [ShapeID: ChannelMismatch?] = [:]
    /// Following Topology's changes to the edges, for `drawnMismatches`.
    private var following: TopologyFollowing?

    // What dynamic references found (`ReferenceAnswers.swift`).
    /// Every reference with a query, on every board of the file, and what its query found.
    var dynamic: [ShapeID: Finding] = [:]
    /// Whether every dynamic reference's answer may be out of date (a commit that changed something
    /// else than their own questions): asked of them all at the next batch.
    var everyDirty = false
    /// The last answers of each reference, by key, newest last: kept past its deletion, for its undo,
    /// for at most `ReferenceStyle.memosKept` references (`remember(_:for:)`).
    var memo: [ShapeID: Memo] = [:]
    /// What stamps a memo as it's landed or used, so the bound lets go of the least recent.
    var memoClock = 0
    /// The wait for quiet after a commit, a hop to ask at once, and the batch out.
    var debounce: ScheduledTask?
    var hop: ScheduledTask?
    var batch: Task<Void, Never>?
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
    public func isRemembered(_ id: ShapeID) -> Bool { memo[id] != nil }
    #endif

    init(editor: CanvasEditor) {
        self.editor = editor
        rebuild()
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
                              isElsewhere: isElsewhere)
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
        drawnConditions[id] = (target, condition)
        return condition
    }

    /// `channelMismatch(of:)`, for a render: kept until a change to the edges touches the reference.
    func drawnMismatch(of id: ShapeID) -> ChannelMismatch? {
        if let kept = drawnMismatches[id] { return kept }
        let found = channelMismatch(of: id)
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
            for id in rowsAffected(by: changes) { drawnConditions.removeValue(forKey: id) }
        }
        if !drawnMismatches.isEmpty {
            for id in changes.removed { drawnMismatches.removeValue(forKey: id) }
        }
    }

    // MARK: Who names what

    /// The direct references that name any of these shapes: those whose pill, row and panel show what
    /// a change to the shape changed.
    public func directReferences(naming ids: some Sequence<ShapeID>) -> Set<ShapeID> {
        var found: Set<ShapeID> = []
        for id in ids {
            if let references = referencesTo[id] { found.formUnion(references) }
        }
        return found
    }

    /// The shape the direct reference names, wherever it is.
    public func target(of reference: ShapeID) -> ShapeID? { targetOf[reference] }

    /// The references a commit may change the rows of without changing them: those that name a shape it
    /// changed (renamed, made private, deleted, brought back by an undo), moved ones aside.
    func rowsAffected(by changes: ChangeSet) -> Set<ShapeID> {
        guard !referencesTo.isEmpty else { return [] }
        var found: Set<ShapeID> = []
        func add(_ id: ShapeID) {
            if let references = referencesTo[id] { found.formUnion(references) }
        }
        for id in changes.added { add(id) }
        for id in changes.changed where !changes.moved.contains(id) { add(id) }
        for id in changes.removed { add(id) }
        for id in changes.elsewhere { add(id) }
        return found
    }

    /// Keeps what the shape `id` is now (`record`, nil when it's in no board of the file) in the
    /// index: whether it's a reference, and what it names.
    private func index(_ id: ShapeID, _ record: AnyShapeRecord?) {
        if let old = targetOf.removeValue(forKey: id) {
            referencesTo[old]?.remove(id)
            if referencesTo[old]?.isEmpty == true { referencesTo[old] = nil }
        }
        guard let record, record.kind == Reference.kind else {
            known.remove(id)
            return
        }
        known.insert(id)
        guard let target = record.typed(as: Reference.self)?.props.target?.id else { return }
        targetOf[id] = target
        referencesTo[target, default: []].insert(id)
    }

    private func rebuild() {
        targetOf = [:]
        referencesTo = [:]
        known = []
        drawnConditions = [:]
        drawnMismatches = [:]
        let file = editor.file
        func scan(_ document: CanvasDocument) {
            for record in document.shapes where record.kind == Reference.kind { index(record.id, record) }
        }
        scan(file.root)
        for document in file.children.values { scan(document) }
    }

    /// The references a commit touched, each once, as they are now (nil: in no board of the file): the
    /// file's that it added, changed (moves aside), removed or touched elsewhere, and those it brought,
    /// added on the board shown, on a board it brought (read from the board's shapes, as `rebuild`
    /// reads one) or elsewhere on a board it changed. A shape's kind never changes, so any other
    /// shape is no reference: a commit of thousands of shapes and no reference costs a set hit a shape
    /// (and a look at those it added), never a lookup in the file.
    private func referencesTouched(by changes: ChangeSet) -> [ShapeID: AnyShapeRecord?] {
        var touched: [ShapeID: AnyShapeRecord?] = [:]
        let file = editor.file, document = editor.document
        func readAgain(_ id: ShapeID) { touched.updateValue(file.record(id), forKey: id) }
        if !known.isEmpty {
            for id in changes.changed where known.contains(id) && !changes.moved.contains(id) { readAgain(id) }
            for id in changes.removed where known.contains(id) { readAgain(id) }
            for id in changes.elsewhere where known.contains(id) { readAgain(id) }
        }
        for id in changes.added {
            if known.contains(id) {
                readAgain(id)
            } else if let record = document[id], record.kind == Reference.kind {
                touched.updateValue(record, forKey: id)
            }
        }
        for board in changes.boardsAdded {
            for record in file[board].shapes where record.kind == Reference.kind { touched.updateValue(record, forKey: record.id) }
        }
        // What else `elsewhere` holds is on the boards it took, gone, unless it changed a board.
        if !changes.boardsChanged.isEmpty {
            for id in changes.elsewhere where !known.contains(id) {
                if let record = file.record(id), record.kind == Reference.kind { touched.updateValue(record, forKey: id) }
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

    /// The matches a dynamic reference was given (the first and what All would add, or up to fifty);
    /// nil while it has none.
    func matches(of reference: ShapeID) -> [ShapeID]? {
        guard case .found(_, let found)? = state(of: reference) else { return nil }
        return found.ids
    }

    /// Shows the matches of the only reference among these: their board, selected on it.
    func showMatches(of ids: Set<ShapeID>) {
        guard ids.count == 1, let id = ids.first, let matches = matches(of: id) else { return }
        go(to: matches)
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
        case .notPublic: ReferenceStyle.privateHelp
        default: nil
        }
    }

    // MARK: The panel's header

    /// What the panel's header says of a reference: its symbol, what it stands for, and a line under it
    /// (for a dynamic one, how many it found: "First of 7", "12 matches", "50 of 73", "No matches";
    /// none while it's being looked for or failed, which the Query section says).
    public func header(of props: Reference, id: ShapeID? = nil) -> ReferenceHeaderContent {
        switch state(of: props, id: id) {
        case .empty:
            return ReferenceHeaderContent(symbol: ReferenceStyle.systemImage, title: ReferenceStyle.placeholder, subtitle: nil)
        case .live(let appearance):
            return ReferenceHeaderContent(symbol: appearance.systemImage, title: appearance.label, subtitle: kindAndBoard(appearance, of: props.target))
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
        case .notInterpreted(let text), .interpreting(let text), .finding(let text), .failed(let text, _), .cannotFind(let text):
            return ReferenceHeaderContent(symbol: ReferenceStyle.dynamicSymbol, title: text, subtitle: nil)
        }
    }

    /// "Note · Payments": the kind, then the board's name when the shape isn't on the board shown.
    private func kindAndBoard(_ appearance: MentionAppearance, of target: ReferenceTarget?) -> String {
        guard let target, let board = editor.file.board(containing: target.id), board != editor.board else { return appearance.kindName }
        return appearance.kindName + " · " + (editor.publishing?.boardName(of: board) ?? "Board")
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
    /// Keeps which references name which shapes: those the commit added, changed (but for those it only
    /// moved) or removed, on the board shown or, as `elsewhere`, on any other. What it reads is the
    /// references it touched (`referencesTouched(by:)`), so a commit that touches none costs what it
    /// touched a set hit, whatever the file holds.
    public func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        // A drag's every event: one test.
        if changes.changed.count == changes.moved.count, changes.added.isEmpty, changes.removed.isEmpty, changes.elsewhere.isEmpty,
           !changes.reordered, changes.boardsAdded.isEmpty, changes.boardsRemoved.isEmpty, !changes.replacedDocument { return }
        hearInterpretations(changes)
        if !mismatches.isEmpty {
            for id in changes.removed { mismatches[id] = nil }
        }
        // A board put in place: every board read afresh.
        guard !changes.replacedDocument else {
            rebuild()
            rebuildDynamic()
            return
        }
        let touched = referencesTouched(by: changes)
        forgetDrawn(changes, touched: touched)
        hearDynamic(changes, touched: touched)
        for (id, record) in touched { index(id, record) }
    }

    /// Editing ended: nothing is being handed off.
    public func editingDidEnd(_ id: ShapeID, in editor: CanvasEditor) {
        setHandingOff(false, for: id)
        editingEnded(id)
        interpretationEditingEnded(id)
    }

    /// A file put in place is read afresh. Another board shown changes nothing: the file's index is kept
    /// by every commit, whatever board it was on (`elsewhere`), so a switch works out no change set.
    public func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        if change.isFileReplaced {
            dropInterpretations()
            rebuild()
            rebuildDynamic()
        }
    }
}

extension CanvasEditor {
    /// References' state; nil without ReferencesPlugin.
    public var references: ReferenceState? { service(ReferenceState.self) }
}

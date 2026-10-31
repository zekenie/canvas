import Canvas
import CoreGraphics
import DetailPanel
import Keyboard
import Observation
import Queries
import Selection
import Titles
import Topology

/// The issue walk: one issue at a time through a file's errors and warnings, across every board, holding the place. Validation
/// owns it, so the same walk covers any issue; a plugin that owns a source of issues gives a scope for them
/// (`IssueScopes`) and the walk goes through those alone (LanguageRules': a rule's). A walk's stops are the issues that show
/// (`Severity.shows`: what a shape still needs is no stop, and an answer a rule is unsure of is no issue) that its scope
/// includes, each one stop: a shape with two issues is two. They are listed in board order (Find's: `boardOrderKey`), and the
/// stepping is `ShapeWalk`'s (Selection's), whose rows these are, one row to a stop.
///
/// A stop that is gone (its issue ignored, or fixed so that it holds) keeps its row, dimmed, with no stop in it, reading
/// "ignored" or "holds", so the count drops and the place does not move. Stops that arrive while answers come in join in
/// board order, the current stop staying current.

/// A stop's name: the shape and the issue's source, else, for an issue that says none, where in the shape it is (its field
/// and path; never its words, which may carry figures that change as a value is fixed). It names the stop across changes: an
/// issue found again is the same stop, and two of the same name in a shape are told apart by their occurrence, worst first.
public struct IssueKey: Hashable, Sendable {
    public let shape: ShapeID
    public let source: IssueSource?
    public let field: String?
    public let path: String?
    public let occurrence: Int

    /// The stop of a shape's issue of a source.
    public init(shape: ShapeID, source: IssueSource) {
        self.init(shape: shape, source: source, field: nil, path: nil, occurrence: 0)
    }

    public init(shape: ShapeID, issue: ValidationIssue, occurrence: Int = 0) {
        if let source = issue.source {
            self.init(shape: shape, source: source, field: nil, path: nil, occurrence: occurrence)
        } else {
            self.init(shape: shape, source: nil, field: issue.field, path: issue.path, occurrence: occurrence)
        }
    }

    private init(shape: ShapeID, source: IssueSource?, field: String?, path: String?, occurrence: Int) {
        self.shape = shape
        self.source = source
        self.field = field
        self.path = path
        self.occurrence = occurrence
    }

    fileprivate func occurring(_ n: Int) -> IssueKey {
        IssueKey(shape: shape, source: source, field: field, path: path, occurrence: n)
    }
}

/// Whether a row's issue is still there, and if not, why.
public enum IssueRowState: Sendable {
    /// The issue is found: the row is a stop.
    case open
    /// Set aside by an action whose role is `.ignore`.
    case ignored
    /// No longer found otherwise (a fix): reads "holds".
    case holds
}

/// A row of the walk: one stop, kept in place when its issue goes.
public struct IssueRow: Identifiable, Sendable {
    public let key: IssueKey
    public var id: IssueKey { key }
    public var shape: ShapeID { key.shape }
    public fileprivate(set) var board: BoardID
    /// The issue's words, as they were last found.
    public fileprivate(set) var message: String
    public fileprivate(set) var severity: Severity
    public fileprivate(set) var state: IssueRowState
    fileprivate var order: BoardOrderKey
    fileprivate var slot: Int

    public var isOpen: Bool { state == .open }
}

/// One board's rows in the walk, which follow one another in board order: its place among the rows, how many are stops now,
/// and the first of them (the stop a page to the board goes to).
public struct IssueBoard: Equatable, Sendable {
    public let board: BoardID
    public let rows: Range<Int>
    public let open: Int
    /// The index of the board's first row that is a stop.
    public let firstOpen: Int?
}

/// The tab a kind had chosen before the walk chose its Issues tab: none, or one.
fileprivate struct PriorTab {
    let tab: DetailTabID?
}

/// One stop as read from a shape's issues.
fileprivate struct DraftRow {
    let key: IssueKey
    let board: BoardID
    let message: String
    let severity: Severity
    let order: BoardOrderKey
    let slot: Int
}

/// What a read of some shapes found.
fileprivate struct Found {
    var drafts: [IssueKey: DraftRow] = [:]
    /// The shapes that are in the file, on a board that can be shown.
    var alive: Set<ShapeID> = []
    /// Where each of those is now: its board and its place in board order.
    var places: [ShapeID: (board: BoardID, order: BoardOrderKey)] = [:]
}

/// Where a stop is among the walk's: its number, and how many there are.
public struct IssuePlace: Equatable, Sendable {
    public let number: Int
    public let total: Int

    public init(number: Int, total: Int) {
        self.number = number
        self.total = total
    }
}

/// Where a walk begins.
public enum IssueEntry: Sendable {
    /// The first stop (the last, going back).
    case first
    /// The first stop after the selection (before it, going back).
    case afterSelection
    /// The shape's first stop.
    case shape(ShapeID)
}

/// The walk, per editor (`editor.issueWalk`): its scope, its rows, whether its list is open (state only: the band and the list
/// are views of it), and the moves. It never transacts but through an issue's own action (Ignore).
@MainActor
@Observable
public final class IssueWalk {
    @ObservationIgnored unowned let editor: CanvasEditor
    /// The editor, held weakly as well: what a task or a turn of the scheduler does after it waited asks first whether the editor
    /// is still there (`isEditorGone`), since reading `editor` once it has gone is fatal.
    @ObservationIgnored private weak var liveEditor: CanvasEditor?
    /// The stepping and the one step back (Selection's), arriving by selecting the stop's shape.
    @ObservationIgnored let walk: ShapeWalk

    /// What the walk goes through; nil while no walk runs.
    public private(set) var scope: IssueScope?
    /// The stops, in board order, those that are gone among them. Told to observers when something shown of a row changed or
    /// rows came, went or moved, never for the board-order keys the walk takes again.
    public var rows: [IssueRow] {
        access(keyPath: \.rows)
        return stored
    }
    @ObservationIgnored private var stored: [IssueRow] = []
    /// How many rows are stops now.
    public private(set) var openCount = 0
    /// The rows by board, in order, found as the rows are set: what the list heads its boards with.
    public private(set) var boards: [IssueBoard] = []
    /// Whether the list of stops is open over the panel (state: the list is a view of it; `toggleList()` opens and closes
    /// it with the keyboard).
    public var isListOpen = false
    /// Where the keyboard was when the list opened, to give back.
    @ObservationIgnored let listKeyboard: IssueListKeyboard
    /// Whether the list's own view is what the panel shows: `isListOpen` while Find's panel, listed before it, is not over it.
    /// The list's view says so as it appears and goes (`listShown(_:)`); the walk's light reads it.
    public internal(set) var isListShown = false
    /// +1 when the file's colors may have changed what a shape is tinted: the list's rows are drawn again.
    public private(set) var tintRevision = 0
    /// +1 for each commit that wrote more than moves: the words of a row (a shape's name, its first value) may have changed
    /// with no row changing, so the list's rows are drawn again. Not one for each shape the commit named: a row's words come from
    /// more than its shape (an arrow's name is its ends' titles, its first value and a note's are its fields and its type's, a
    /// board's heading its owner's name), so a bump for each shape would need every contributor to say what it read. It costs, with
    /// the list open, the items of the boards unfolded (the walk's board and those the person opened) and the rows drawn, once a
    /// commit that wrote more than moves.
    public private(set) var textRevision = 0
    /// +1 each time the walk goes to a stop (even the one it is at): the list lets go of a line it held the highlight on.
    public private(set) var moveRevision = 0
    /// Whether the first answer is still on its way (the query for every issue is asked of the engine off the main actor).
    public private(set) var isGathering = false
    /// +1 each time an answer has been used: the first, and one asked again (a scope reworded, a paste past the read limit).
    /// A reader that waits for an answer that does not set `isGathering` waits on this.
    public private(set) var answers = 0

    /// Each row's place, the stops before each, and a shape's rows.
    @ObservationIgnored private var placeByKey: [IssueKey: Int] = [:]
    @ObservationIgnored private var byShape: [ShapeID: [Int]] = [:]
    @ObservationIgnored private var offsets: [Int] = []
    /// +1 for each walk begun or restarted, and for a question asked: an answer for an older one is dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Where the walk goes when its rows have come.
    @ObservationIgnored private var entry: (IssueEntry, forward: Bool)?
    /// The issues that an Ignore was run on, until they are found again or the row says why.
    @ObservationIgnored private var ranIgnore: Set<IssueKey> = []
    /// The shapes whose issues may have changed without a commit to say so (`recheck`), read again on the next turn.
    @ObservationIgnored private var pendingIDs: Set<ShapeID> = []
    @ObservationIgnored private var flushing: ScheduledTask?
    /// The tab each kind had chosen before a stop chose its Issues tab (nil: none), to give back.
    @ObservationIgnored private var priorTabs: [ShapeKind: PriorTab] = [:]
    /// The board said last, so a step names it only when it changes.
    @ObservationIgnored private var announcedBoard: BoardID?
    /// The shape the place was on when the rows were made again from nothing (a rule reworded), until it has a row again.
    @ObservationIgnored private var placeHint: ShapeID?
    /// The selection when the hint was taken: a hint is a promise to stay where the person was, so a selection moved since
    /// (a click elsewhere) lets it go.
    @ObservationIgnored private var placeHintSelection: [ShapeID] = []
    /// The shapes that commits and rechecks named while the first answer was on its way: that answer may be older than they,
    /// so they are read with it.
    @ObservationIgnored private var missed: Set<ShapeID> = []
    /// Where a shape is among a scope's candidates, for the line that says "9 of 63" while no walk of the scope runs.
    @ObservationIgnored let linePlaces = IssueLinePlaces()

    init(editor: CanvasEditor) {
        self.editor = editor
        liveEditor = editor
        listKeyboard = IssueListKeyboard(editor: editor)
        walk = ShapeWalk(editor: editor, arrival: .selects)
        walk.source = self
    }

    // MARK: Reading

    /// Whether a walk runs.
    public var isRunning: Bool { scope != nil }

    /// How many stops there are now: the rows that are not gone.
    public var total: Int { openCount }

    /// Whether the editor has gone (its window closed) while a task or a turn of the scheduler waited: such a continuation does
    /// nothing, and reads nothing of the editor.
    private var isEditorGone: Bool { liveEditor == nil }

    /// The current stop's row, which may be one that is gone.
    public var currentRow: IssueRow? {
        guard let current = walk.current, rows.indices.contains(current.row) else { return nil }
        return rows[current.row]
    }

    /// The current stop's number among the stops, from 1; a row that is gone keeps the number it had.
    public var number: Int? { walk.number }

    /// Where the issue of a source is among the stops, if a walk runs and it is one: for a line that says "9 of 63". Not
    /// for an issue that has no source.
    public func place(of shape: ShapeID, source: IssueSource?) -> IssuePlace? {
        guard isRunning, let source, let index = placeByKey[IssueKey(shape: shape, source: source)], rows[index].isOpen else { return nil }
        return IssuePlace(number: offsets[index] + 1, total: openCount)
    }

    /// Whether the keys may begin or step a walk: not during a gesture, nor while shapes wait to be placed, nor with Topology
    /// missing, whose order the stops are listed in.
    public var canStep: Bool { editor.topology != nil && editor.session == nil && !editor.isPlacingLater }

    /// Whether Ignore Issue has something to run: the current stop is open and its issue has an action for it.
    public var canIgnore: Bool { currentRow.flatMap(ignoreAction(of:)) != nil }

    // MARK: Beginning and ending

    /// Begins a walk through `scope`'s issues, going to the first stop `entry` says; a walk running is ended and begun anew.
    /// A scope that gives its candidates is read at once; the rest wait for the answer of the query for every issue, and
    /// begin when it comes. A scope with no stop is no walk.
    public func begin(_ scope: IssueScope = .all, at entry: IssueEntry = .afterSelection, forward: Bool = true) {
        guard canStep else { return }
        if isRunning { end() }
        self.scope = scope
        self.entry = (entry, forward)
        announcedBoard = nil
        placeHint = nil
        missed = []
        gather(scope, blocking: true) { [weak self] ids in
            guard let self, self.scope != nil else { return }
            setRows(drafts(for: read(ids.union(missed))))
            pendingIDs = []
            missed = []
            guard let (entry, forward) = self.entry else { return }
            self.entry = nil
            if !walk.begin(at: walkEntry(entry, forward: forward)) { end() }
        }
    }

    /// Ends the walk: each kind has the tab it had back, the rows go, and the editor stays where the walk left it.
    public func end() {
        guard isRunning else { return }
        generation += 1
        task?.cancel()
        task = nil
        flushing?.cancel()
        flushing = nil
        walk.end()
        if let panel = editor.detailPanel {
            for (kind, prior) in priorTabs {
                if let tab = prior.tab { panel.choose(tab, for: kind) } else { panel.forgetChoice(for: kind) }
            }
        }
        priorTabs = [:]
        scope = nil
        entry = nil
        isGathering = false
        isListOpen = false
        isListShown = false
        listKeyboard.forget()
        ranIgnore = []
        pendingIDs = []
        missed = []
        placeHint = nil
        setRows([])
        walk.rowsDidChange()
    }

    // MARK: Moving

    /// The next stop, or the one before, wrapping. With no walk running, begins one through every issue, at the first stop
    /// after the selection (before it, going back).
    public func step(forward: Bool) {
        guard canStep else { return }
        guard isRunning else {
            begin(.all, at: .afterSelection, forward: forward)
            return
        }
        guard !isGathering else { return }
        placeHint = nil
        walk.step(forward: forward)
    }

    /// Goes to the stop of the shape's issue of a source (a line's "9 of 63" with that scope's walk running): the place moves to
    /// it as a click on its row would, the whole walk still one step back.
    func go(to shape: ShapeID, source: IssueSource) {
        guard canStep, isRunning, !isGathering, let index = placeByKey[IssueKey(shape: shape, source: source)], rows[index].isOpen else { return }
        placeHint = nil
        walk.pick(row: index)
    }

    /// Goes to the stop of a row of the list, as a click on it does: the place moves to it, the whole walk still one step back.
    /// A row that is no stop moves nothing. Whether the walk moved.
    @discardableResult
    func go(toRow key: IssueKey) -> Bool {
        guard canStep, isRunning, !isGathering, let index = placeByKey[key], rows[index].isOpen else { return false }
        placeHint = nil
        walk.pick(row: index)
        return true
    }

    /// A row by its key.
    func row(for key: IssueKey) -> IssueRow? { placeByKey[key].map { rows[$0] } }

    /// Where a row is among the stops, if it is one: for the list, which says "12 of 63" of a row.
    func place(ofRow key: IssueKey) -> IssuePlace? {
        guard let index = placeByKey[key], rows[index].isOpen else { return nil }
        return IssuePlace(number: offsets[index] + 1, total: openCount)
    }

    /// The first stop of the board `forward` (else before) the one given, wrapping, over boards that have a stop; the first
    /// stop of its own board when it is the only one. Nil with no stops.
    func firstStop(besideBoard board: BoardID?, forward: Bool) -> IssueKey? {
        let withStops = boards.indices.filter { boards[$0].firstOpen != nil }
        guard !withStops.isEmpty else { return nil }
        let here = board ?? currentRow?.board
        let at = boards.firstIndex { $0.board == here }
        let target: Int
        if let at {
            if forward { target = withStops.first { $0 > at } ?? withStops[0] } else { target = withStops.last { $0 < at } ?? withStops[withStops.count - 1] }
        } else {
            target = forward ? withStops[0] : withStops[withStops.count - 1]
        }
        return boards[target].firstOpen.map { rows[$0].key }
    }

    /// Runs the current stop's Ignore (the action of its issue whose role is `.ignore`): one step of the editor's undo, the
    /// walk staying where it is, its row dimmed and the count dropping. Whether the stop was set aside: an Ignore that is
    /// refused (a locked shape) writes nothing, leaves the stop open, and says nothing.
    @discardableResult
    public func ignoreCurrent() -> Bool {
        guard let row = currentRow, let action = ignoreAction(of: row) else { return false }
        ranIgnore.insert(row.key)
        action.perform()
        // The commit has been heard already; this is for an action that wrote nothing yet.
        refresh([row.shape])
        if let index = placeByKey[row.key], rows[index].isOpen {
            ranIgnore.remove(row.key)
            return false
        }
        editor.announce(IssueWalkStyle.ignored(openCount))
        return true
    }

    /// The Issues tab's button for an action ran: an Ignore its line offers is the walk's too, so its row reads "ignored".
    /// Told before the action runs, with the issue's place among the shape's (`worstFirst`), which names it apart from an
    /// issue of the same name.
    func willPerform(_ role: IssueActionRole?, onIssueAt index: Int, among issues: [ValidationIssue], of shape: ShapeID) {
        guard isRunning, issues.indices.contains(index) else { return }
        let base = IssueKey(shape: shape, issue: issues[index])
        let before = issues[..<index].filter { IssueKey(shape: shape, issue: $0) == base }.count
        let key = before == 0 ? base : base.occurring(before)
        if role == .ignore { ranIgnore.insert(key) } else { ranIgnore.remove(key) }
    }

    /// A scope that is made of other things now (a rule reworded, a rule moved) is followed in place: the rows are made again
    /// from the new scope, the place kept on the shape it was on. A row of an issue the new scope still includes (a rule that
    /// only moved) is kept as it was, ignored and holds ones too; the rest of the old rows go with the old words.
    public func scopeDidChange(from old: IssueScope, to new: IssueScope) {
        guard let scope, scope.id == old.id else { return }
        self.scope = new
        let hint = currentRow?.shape ?? placeHint
        let hintSelection = editor.selectedShapeIDs
        gather(new, blocking: false) { [weak self] ids in
            guard let self, self.scope != nil else { return }
            // The place as it is now, not as it was asked for: a commit during the wait (the current stop deleted) has moved it
            // to the stop after, and `previous` no longer holds the one it was on.
            let kept = walk.kept
            let previous = stored
            let found = read(ids.union(byShape.keys))
            var next = drafts(for: found)
            let have = Set(next.map(\.key))
            for var row in previous where !have.contains(row.key) && found.alive.contains(row.shape) && includes(row.key, in: new) {
                if row.isOpen { row.state = goneState(of: row) }
                // A row kept with no issue found has the place its shape has now, as the rows found do.
                if let place = found.places[row.shape] { (row.board, row.order) = place }
                next.append(row)
            }
            setRows(Self.sorted(next))
            walk.rowsDidChange(keeping: keeping(kept, across: previous))
            placeHint = hint
            placeHintSelection = hintSelection
            restorePlace()
        }
    }

    /// Why a row's issue is gone: set aside (`.ignored`) or made to hold (`.holds`, a fix). The plugin that owns the issue's source
    /// says it, through its scope (`IssueScope.isSetAside`, asked of `registry.issueScope(for:in:)`, so in an All Issues walk as
    /// in a rule's), so an Ignore redone or run from a menu reads ignored as one run from the walk does; for an issue whose owner
    /// gives none, the last action run on it (`ranIgnore`) is the answer.
    private func goneState(of row: IssueRow) -> IssueRowState {
        let ran = ranIgnore.remove(row.key) != nil
        if let source = row.key.source, let asked = editor.registry.issueScope(for: source, in: editor)?.isSetAside {
            return asked(row.shape, editor) ? .ignored : .holds
        }
        return ran ? .ignored : .holds
    }

    /// Whether the scope still takes the issues of a row's source.
    private func includes(_ key: IssueKey, in scope: IssueScope) -> Bool {
        key.source.map { scope.includes(.warning("", source: $0)) } ?? false
    }

    // MARK: Upkeep

    /// Shapes whose issues may have changed without a commit (Validation's `recheck`, `recheckWords`, and the shapes a rule's
    /// `affected` named, any board): read again soon, once for all that come together.
    func shapesMayHaveChanged(_ ids: Set<ShapeID>) {
        guard isRunning, !ids.isEmpty else { return }
        pendingIDs.formUnion(ids)
        guard flushing == nil else { return }
        flushing = editor.scheduler.schedule(after: .zero) { [weak self] in
            guard let self, !isEditorGone else { return }
            flushing = nil
            let ids = pendingIDs
            pendingIDs = []
            refresh(ids)
        }
    }

    /// Reads these shapes' issues again and brings the rows to them: a gone issue keeps its row, an issue that arrives joins
    /// in board order, and the current stop stays current. `own` are the shapes the commit itself added or changed: they are
    /// read whatever the scope's candidates say, since the candidates are another service's and may not have heard the commit
    /// yet (a shape that stops ignoring a rule is a candidate by this very commit); `ids` are the shapes it may have affected,
    /// of which a scope with candidates reads those among them or with a row.
    private func refresh(_ ids: Set<ShapeID>, own: Set<ShapeID> = []) {
        guard let scope, !ids.isEmpty || !own.isEmpty else { return }
        // The first answer is on its way and may be older than these: they are read with it.
        guard !isGathering else {
            missed.formUnion(ids)
            missed.formUnion(own)
            return
        }
        var ids = ids
        if let candidates = scope.candidates {
            // A stop of such a scope is a shape it flags or one that has a row: no other can have an issue to arrive or change.
            let flagged = candidates(editor)
            let keeps: (ShapeID) -> Bool = { flagged.contains($0) || self.byShape[$0] != nil }
            ids = ids.filter(keeps)
            // A paste is not read shape by shape: its shapes are held to the candidates as the rest are.
            ids.formUnion(own.count > IssueWalkStyle.readLimit ? own.filter(keeps) : own)
            guard !ids.isEmpty else { return }
        } else {
            ids.formUnion(own)
        }
        guard ids.count > IssueWalkStyle.readLimit, scope.candidates == nil else {
            merge(read(ids), considering: ids)
            return
        }
        // A paste, a bulk create: ask for the shapes with issues again rather than read each of these.
        gather(scope, blocking: false) { [weak self] found in
            guard let self else { return }
            let all = found.union(byShape.keys)
            merge(read(all), considering: all)
        }
    }

    /// Brings the rows to what was found of the shapes `ids`. A row whose issue is found again is changed where it stands; the
    /// rows are made again (and sorted) only when one arrives, leaves or is put elsewhere by its key, and the numbers after a
    /// row that flips between being a stop and not are redone from it.
    fileprivate func merge(_ found: Found, considering ids: Set<ShapeID>) {
        let kept = walk.kept
        var updated: [Int: IssueRow] = [:]
        var removed: Set<Int> = []
        var changed = false, reordered = false, flipped = Int.max
        for id in ids {
            for index in byShape[id] ?? [] {
                var row = stored[index]
                let key = row.key
                if let draft = found.drafts[key] {
                    ranIgnore.remove(key)
                    let (differs, moved) = row.update(from: draft)
                    if differs {
                        updated[index] = row
                        if !stored[index].isOpen { flipped = min(flipped, index) }
                    }
                    changed = changed || differs
                    reordered = reordered || moved
                } else if !found.alive.contains(id) {
                    removed.insert(index)
                } else if row.isOpen {
                    row.state = goneState(of: row)
                    updated[index] = row
                    changed = true
                    flipped = min(flipped, index)
                }
            }
        }
        let arrivals = found.drafts.values.filter { placeByKey[$0.key] == nil }
        guard changed || !removed.isEmpty || !arrivals.isEmpty else { return }
        if removed.isEmpty, arrivals.isEmpty, !reordered {
            // Nothing arrived, left or moved: the rows are changed where they stand.
            withMutation(keyPath: \.rows) {
                for (index, row) in updated { stored[index] = row }
            }
            if flipped != Int.max { recount(from: flipped) }
            walk.rowsDidChange(keeping: kept)
            restorePlace()
            return
        }
        let previous = stored
        var next = previous
        for (index, row) in updated { next[index] = row }
        if !removed.isEmpty { next = next.enumerated().filter { !removed.contains($0.offset) }.map(\.element) }
        next += arrivals.map(IssueRow.init)
        if reordered || !arrivals.isEmpty { next = Self.sorted(next) }
        setRows(next)
        walk.rowsDidChange(keeping: keeping(kept, across: previous))
        restorePlace()
    }

    /// A commit has been heard by every service: the shapes it changed, and those their rules affect, are read again.
    private func documentChanged(_ changes: ChangeSet) {
        guard let scope else { return }
        if scope.label(editor) == nil {
            end()
            return
        }
        // Not while the first answer is on its way: it reads the scope as it began (the shapes are kept in `missed`).
        if !isGathering, scope.isChanged?(changes, editor) == true {
            scopeDidChange(from: scope, to: scope)
            return
        }
        // The keys the rows were sorted by hold places in the stack, which a commit may have shifted for shapes it did not name.
        retakeKeys(if: changes)
        var own = changes.added
        var ids: Set<ShapeID> = []
        ids.formUnion(changes.removed)
        ids.formUnion(changes.elsewhere)
        let engine = editor.validation
        for id in changes.changed {
            if !changes.moved.contains(id) {
                own.insert(id)
            } else if let kind = editor.withoutObservingDocument({ editor.file.record(id)?.kind }), engine?.rulesReadPlacement(of: kind) == true {
                // A shape that only moved has the issues it had, and the place in board order (a box moved is in the same
                // place in the stack and the same container), unless a rule of its kind reads where shapes are.
                ids.insert(id)
            }
        }
        // What the rules affect is told to `shapesMayHaveChanged` as it is asked; it is read here, so the turn it scheduled
        // has nothing left to do. Those that only moved are affected only through the rules that read where shapes are.
        if let engine { ids.formUnion(engine.affected(by: changes)) }
        ids.formUnion(pendingIDs)
        pendingIDs = []
        flushing?.cancel()
        flushing = nil
        refresh(ids, own: own)
    }

    // MARK: Board order

    /// A commit that may have put shapes in another board order (`ChangeSet.mayHaveChangedBoardOrder`) leaves the rows with
    /// keys that no longer compare with the keys of shapes read after it: every row's key is taken again from one snapshot of
    /// the file, and the rows sorted again if that put them in another order, the current stop kept. A row whose shape has no
    /// key now (it is gone, or on a board that cannot be shown) is a row no more, as `read` counts such a shape: it is taken out
    /// here, so a stale key is never compared with a fresh one, in the sort or in `setRows`' runs, and the current stop's
    /// successor is found across the rows as they were before the commit (`previous`), the one order every key of which was
    /// true. Costs O(rows × depth) for such a commit, never for a commit that only edits or moves.
    private func retakeKeys(if changes: ChangeSet) {
        guard !stored.isEmpty, changes.mayHaveChangedBoardOrder(in: editor.withoutObservingDocument { editor.file }),
              let snapshot = editor.topology?.snapshot() else { return }
        var taken: [ShapeID: BoardOrderKey?] = [:]
        var next: [IssueRow] = []
        next.reserveCapacity(stored.count)
        var differs = false, left = false, rehomed = false
        // A shape the commit named may be on another board now (Move To ▸): its row goes with it, else its key and its board
        // disagree and the board's run is broken. No other shape's board changed.
        let named = changes.added.union(changes.changed).union(changes.elsewhere)
        let file = editor.withoutObservingDocument { editor.file }
        for var row in stored {
            if named.contains(row.shape), let board = file.board(containing: row.shape), board != row.board {
                row.board = board
                differs = true
                rehomed = true
            }
            let key: BoardOrderKey?
            if let known = taken[row.shape] {
                key = known
            } else {
                key = snapshot.boardOrderKey(of: row.shape)
                taken[row.shape] = key
            }
            guard let key else {
                left = true
                continue
            }
            if key != row.order {
                row.order = key
                differs = true
            }
            next.append(row)
        }
        guard differs || left else { return }
        let ordered = Self.isSorted(next)
        if !left, ordered, !rehomed {
            // Only keys moved: the order, the runs and the counts are what they were.
            stored = next
            return
        }
        let kept = walk.kept, previous = stored
        setRows(ordered ? next : Self.sorted(next))
        walk.rowsDidChange(keeping: keeping(kept, across: previous))
        restorePlace()
    }

    /// The place to find again after the rows were made again from `old`: the same row if it is there, else the first row at
    /// or after where it was in `old`'s order, which is found by the rows that stayed (the stop after it that is still a
    /// row), never by an index or a key that the same commit shifted. None of them left: past the end, as the walk wraps.
    private func keeping(_ kept: WalkKept?, across old: [IssueRow]) -> WalkKept? {
        guard let kept, let key = kept.key as? IssueKey, placeByKey[key] == nil, let at = old.firstIndex(where: { $0.key == key }) else { return kept }
        let successor = old[(at + 1)...].lazy.compactMap { self.placeByKey[$0.key] }.first
        return WalkKept(key: kept.key, ordinal: kept.ordinal, rank: successor ?? stored.count)
    }

    // MARK: Gathering

    /// The shapes that may have issues in the scope: its candidates, at once, else the answer of the query for every issue.
    /// `use` is not called once the walk or the editor has gone, nor for an answer an older question got.
    private func gather(_ scope: IssueScope, blocking: Bool, then use: @escaping @MainActor (Set<ShapeID>) -> Void) {
        generation += 1
        let mine = generation
        task?.cancel()
        task = nil
        if let candidates = scope.candidates {
            isGathering = false
            use(candidates(editor))
            answers &+= 1
            return
        }
        isGathering = blocking
        // Neither the walk nor the editor is held across the wait: whatever has gone by the time the answer comes is not read.
        let queries = editor.queries
        task = Task { @MainActor [weak self] in
            let answered = await Self.matching(queries)
            guard !Task.isCancelled, let self, !isEditorGone, mine == generation else { return }
            // No query engine: the board shown is the one Validation has checked.
            let ids = answered ?? editor.validation.map { Set($0.results.keys) } ?? []
            isGathering = false
            task = nil
            use(ids)
            answers &+= 1
        }
    }

    /// The query's answer, nil without a query engine or when it refuses.
    private static func matching(_ queries: QueryState?) async -> Set<ShapeID>? {
        guard let queries else { return nil }
        let answers = await queries.matches([QueryMatchRequest(IssueWalkStyle.query)])
        if case .success(let matches)? = answers.first { return Set(matches.ids) }
        return nil
    }

    // MARK: Reading issues

    /// What these shapes' issues are now, on whichever board each is, as the scope includes them. A shape on the board shown
    /// that Validation has checked is read from its cache, any other by running its rules against its own board.
    fileprivate func read(_ ids: Set<ShapeID>) -> Found {
        guard let scope, let snapshot = editor.topology?.snapshot() else { return Found() }
        return editor.withoutObservingDocument {
            let file = editor.file
            let registry = editor.registry
            var contexts: [BoardID: ShapeContext] = [:]
            var found = Found()
            for id in ids {
                guard let board = file.board(containing: id), let record = file.record(id), !record.isOpaque,
                      file.canShow(board, boardOwningKinds: registry.boardOwningKinds),
                      let order = snapshot.boardOrderKey(of: id) else { continue }
                found.alive.insert(id)
                found.places[id] = (board, order)
                for stop in keyed(issues(of: record, on: board, &contexts), of: id, in: scope) {
                    found.drafts[stop.key] = DraftRow(key: stop.key, board: board, message: stop.issue.message, severity: stop.issue.severity,
                                                   order: order, slot: stop.slot)
                }
            }
            return found
        }
    }

    private func issues(of record: AnyShapeRecord, on board: BoardID, _ contexts: inout [BoardID: ShapeContext]) -> [ValidationIssue] {
        if board == editor.board, case .current(let result)? = editor.validation?.cachedResult(for: record.id) {
            return result?.issues ?? []
        }
        let context = contexts[board] ?? ShapeContext(document: editor.contents(of: board), registry: editor.registry)
        contexts[board] = context
        return editor.registry.validationIssues(of: record, in: context, editor: editor)
    }

    /// A shape's stops: the issues that show and the scope includes, worst first, each with its key.
    private func keyed(_ issues: [ValidationIssue], of shape: ShapeID, in scope: IssueScope) -> [(slot: Int, key: IssueKey, issue: ValidationIssue)] {
        var seen: [IssueKey: Int] = [:]
        var stops: [(slot: Int, key: IssueKey, issue: ValidationIssue)] = []
        for (slot, issue) in ValidationResult(issues: issues).worstFirst.enumerated() where scope.includes(issue) {
            let key = IssueKey(shape: shape, issue: issue)
            let n = seen[key, default: 0]
            seen[key] = n + 1
            stops.append((slot, n == 0 ? key : key.occurring(n), issue))
        }
        return stops
    }

    /// The action of the current stop's issue whose role is Ignore, read afresh.
    private func ignoreAction(of row: IssueRow) -> IssueAction? {
        guard row.isOpen, let scope, let record = editor.withoutObservingDocument({ editor.file.record(row.shape) }) else { return nil }
        var contexts: [BoardID: ShapeContext] = [:]
        let board = row.board
        return editor.withoutObservingDocument {
            keyed(issues(of: record, on: board, &contexts), of: row.shape, in: scope).first { $0.key == row.key }?
                .issue.actions.first { $0.role == .ignore }
        }
    }

    fileprivate func drafts(for found: Found) -> [IssueRow] {
        Self.sorted(found.drafts.values.map(IssueRow.init))
    }

    /// Board order, then the issue's place among the shape's (worst first); equal rows keep their order.
    private static func sorted(_ rows: [IssueRow]) -> [IssueRow] {
        rows.indices.sorted { a, b in
            rows[a].order != rows[b].order ? rows[a].order < rows[b].order : rows[a].slot != rows[b].slot ? rows[a].slot < rows[b].slot : a < b
        }.map { rows[$0] }
    }

    private static func isSorted(_ rows: [IssueRow]) -> Bool {
        zip(rows, rows.dropFirst()).allSatisfy { a, b in a.order != b.order ? a.order < b.order : a.slot <= b.slot }
    }

    // MARK: Rows

    private func setRows(_ next: [IssueRow]) {
        withMutation(keyPath: \.rows) { stored = next }
        placeByKey = Dictionary(uniqueKeysWithValues: next.enumerated().map { ($1.key, $0) })
        byShape = [:]
        offsets = []
        offsets.reserveCapacity(next.count)
        var open = 0
        var runs: [IssueBoard] = []
        var runStart = 0, runOpen = 0, runFirst: Int?
        for (index, row) in next.enumerated() {
            byShape[row.shape, default: []].append(index)
            offsets.append(open)
            if index > 0, row.board != next[index - 1].board {
                runs.append(IssueBoard(board: next[index - 1].board, rows: runStart..<index, open: runOpen, firstOpen: runFirst))
                runStart = index
                runOpen = 0
                runFirst = nil
            }
            if row.isOpen {
                open += 1
                runOpen += 1
                if runFirst == nil { runFirst = index }
            }
        }
        if let last = next.last { runs.append(IssueBoard(board: last.board, rows: runStart..<next.count, open: runOpen, firstOpen: runFirst)) }
        // A board has one run: its rows follow one another in board order. Keys taken again for every commit that may have put
        // shapes in another order keep it so; were one ever wrong, a board met again after another's run is a fault, and the
        // list still makes no two heads with one id: the later run is left out (its rows are stops still, and the first run is the
        // board's head).
        var seen: Set<BoardID> = []
        let single = runs.filter { seen.insert($0.board).inserted }
        if single.count != runs.count {
            assertionFailure("the issue walk's rows are not in board runs: \(runs.map(\.board))")
            runs = single
        }
        boards = runs
        openCount = open
    }

    /// Counts the stops before each row again, from the board that holds `first` on: the rows after a row that is a stop now, or
    /// is not, number differently. The rows, their places and their shapes are as they were.
    private func recount(from first: Int) {
        guard let at = boards.lastIndex(where: { $0.rows.lowerBound <= first }) else { return }
        var open = offsets[boards[at].rows.lowerBound]
        var runs = Array(boards[..<at])
        for board in boards[at...] {
            var runOpen = 0
            var runFirst: Int?
            for index in board.rows {
                offsets[index] = open
                if stored[index].isOpen {
                    open += 1
                    runOpen += 1
                    if runFirst == nil { runFirst = index }
                }
            }
            runs.append(IssueBoard(board: board.board, rows: board.rows, open: runOpen, firstOpen: runFirst))
        }
        boards = runs
        openCount = open
    }

    /// Puts the place back on the shape it was on, once that shape has a row again: a walk made again from nothing (a rule
    /// reworded) waits for the answers that bring its stops back.
    private func restorePlace() {
        guard let hint = placeHint else { return }
        guard editor.selectedShapeIDs == placeHintSelection else {
            placeHint = nil
            return
        }
        if let current = walk.current, rows.indices.contains(current.row), rows[current.row].shape == hint {
            placeHint = nil
            return
        }
        guard let index = rows.firstIndex(where: { $0.shape == hint && $0.isOpen }) ?? rows.firstIndex(where: { $0.shape == hint }) else { return }
        walk.land(at: WalkPosition(row: index, ordinal: 0))
        placeHint = nil
    }

    private func walkEntry(_ entry: IssueEntry, forward: Bool) -> WalkEntry {
        switch entry {
        case .first: forward ? .first : .last
        case .afterSelection: .afterSelection(forward: forward)
        case .shape(let id): .shape(id)
        }
    }

    // MARK: Arriving

    /// Chooses the Issues tab for the stop's kind, keeping the tab the kind had to give back.
    private func chooseIssuesTab(for shape: ShapeID) {
        guard let panel = editor.detailPanel, let kind = editor.shape(inFile: shape)?.kind else { return }
        if priorTabs[kind] == nil { priorTabs[kind] = PriorTab(tab: panel.chosenTab(for: kind)) }
        panel.choose(.of(IssuesTab.self), for: kind)
    }

    /// What VoiceOver hears of a stop: its number, the board when it is not the one said before, the shape and what is wrong.
    /// The names are worked out here, for this one stop.
    private func announce(_ row: IssueRow) {
        let board = row.board == announcedBoard ? nil : editor.boardHeading(of: row.board).title
        announcedBoard = row.board
        let words: String
        switch row.state {
        case .open: words = row.message
        case .ignored: words = IssueWalkStyle.ignored
        case .holds: words = IssueWalkStyle.holds
        }
        editor.announce(IssueWalkStyle.step(number: walk.number ?? 0, of: openCount, board: board, name: name(of: row.shape), says: words))
    }

    /// A shape's name: an arrow by the ends of the connection it carries ("Roger Williams → Laken Riley Act"), else its
    /// title, else what its kind is called.
    func name(of shape: ShapeID) -> String {
        if let edge = editor.topology?.edges(carriedBy: shape).first(where: \.isConnection) {
            return "\(label(of: edge.source)) → \(label(of: edge.target))"
        }
        return label(of: shape)
    }

    private func label(of shape: ShapeID) -> String {
        guard let record = editor.shape(inFile: shape) else { return "" }
        return editor.registry.title(of: record) ?? editor.registry.label(of: record.kind).name
    }
}

extension IssueWalk: ShapeWalkSource {
    public var walkRowCount: Int { stored.count }

    public func walkRow(at index: Int) -> WalkRow {
        let row = stored[index]
        return WalkRow(key: row.key, shape: row.shape, board: row.board, stops: row.isOpen ? 1 : 0, rank: index)
    }

    public func walkPlace(ofKey key: AnyHashable) -> Int? { (key as? IssueKey).flatMap { placeByKey[$0] } }

    public func walkStops(before index: Int) -> Int { offsets[index] }

    /// The row to go on from, with the selection's shapes in walk order: after the last of them going forward, before the
    /// first going back. A selected shape that holds rows counts as its last (first) row; one that holds none by where
    /// Topology's key puts it among them. Of the places those make, the furthest on is the one.
    public func walkPlace(of selection: [ShapeID], forward: Bool) -> Int? {
        guard !selection.isEmpty, !stored.isEmpty else { return nil }
        let selected = Set(selection)
        var places: [Int] = []
        if let index = forward ? stored.lastIndex(where: { selected.contains($0.shape) }) : stored.firstIndex(where: { selected.contains($0.shape) }) {
            places.append(index)
        }
        let held = Set(byShape.keys)
        if let snapshot = editor.topology?.snapshot() {
            let keys = selected.subtracting(held).compactMap { snapshot.boardOrderKey(of: $0) }
            if let key = forward ? keys.max() : keys.min(), let index = rowNear(key, forward: forward) { places.append(index) }
        }
        return forward ? places.max() : places.min()
    }

    /// The last row before `key` in board order (forward), the first after it (going back), by binary search.
    private func rowNear(_ key: BoardOrderKey, forward: Bool) -> Int? {
        var low = 0, high = stored.count
        if forward {
            // The first row at or after the key; the one before it is the last row before the selection.
            while low < high {
                let middle = (low + high) / 2
                if stored[middle].order < key { low = middle + 1 } else { high = middle }
            }
            return low == 0 ? nil : low - 1
        }
        while low < high {
            let middle = (low + high) / 2
            if stored[middle].order <= key { low = middle + 1 } else { high = middle }
        }
        return low == stored.count ? nil : low
    }

    /// The walk went to a stop: its kind's panel opens on the Issues tab, and VoiceOver hears the stop.
    public func walkDidMove() {
        moveRevision &+= 1
        guard let position = walk.current, stored.indices.contains(position.row) else { return }
        let row = stored[position.row]
        chooseIssuesTab(for: row.shape)
        announce(row)
    }
}

extension IssueWalk: EditorService {
    public func documentDidSettle(_ changes: ChangeSet, in editor: CanvasEditor) {
        // The order a line's place goes by may have changed, walk or none.
        linePlaces.commitDidSettle(changes, in: editor.file)
        guard isRunning else { return }
        if !changes.added.isEmpty || !changes.removed.isEmpty || !changes.elsewhere.isEmpty
            || changes.changed.contains(where: { !changes.moved.contains($0) }) {
            textRevision &+= 1
        }
        // A board read again (the file put in place over the board shown) is another file's issues.
        if changes.replacedDocument {
            end()
            return
        }
        documentChanged(changes)
    }

    public func shapeTintsDidChange(in editor: CanvasEditor) {
        tintRevision &+= 1
    }

    /// A file put in place with another board shown is another file's issues: the walk ends.
    public func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        if change.isFileReplaced {
            linePlaces.removeAll()
            end()
        }
    }
}

extension CanvasEditor {
    /// The issue walk; nil without IssueWalkPlugin.
    public var issueWalk: IssueWalk? { service(IssueWalk.self) }
}

extension IssueRow {
    fileprivate init(_ draft: DraftRow) {
        self.init(key: draft.key, board: draft.board, message: draft.message, severity: draft.severity, state: .open,
                  order: draft.order, slot: draft.slot)
    }

    /// Takes what is found of the issue now. Whether anything shown changed, and whether the row's place may have.
    fileprivate mutating func update(from draft: DraftRow) -> (changed: Bool, moved: Bool) {
        let moved = order != draft.order || slot != draft.slot || board != draft.board
        let changed = moved || message != draft.message || severity != draft.severity || state != .open
        board = draft.board
        message = draft.message
        severity = draft.severity
        state = .open
        order = draft.order
        slot = draft.slot
        return (changed, moved)
    }
}

// MARK: The plugin and its Go items

extension CanvasCommand {
    /// Go › Next Issue (⌘'): the walk's next stop, wherever you are; with no walk running, every issue from the first stop
    /// after the selection.
    public static let nextIssue: CanvasCommand = "nextIssue"
    /// Go › Previous Issue (⇧⌘'): the stop before, undoing Next Issue.
    public static let previousIssue: CanvasCommand = "previousIssue"
    /// Go › Ignore Issue (⌥⌘'): the current stop's Ignore, one step, staying where you are.
    public static let ignoreIssue: CanvasCommand = "ignoreIssue"
    /// Go › End Issue Walk: the band's Done, for a keyboard that does not reach it.
    public static let endIssueWalk: CanvasCommand = "endIssueWalk"
}

/// Go's section of walking issues, right after the section of moving between shapes and boards.
public enum IssuesSection {}
extension IssuesSection: MenuBarSection {
    public static var menu: MenuBarMenu { "Go" }
    public static var order: Order<Self> { .after(NavigationSection.self) }
}

/// Walking issues, as a plugin: `editor.issueWalk` and Go's items (Next Issue ⌘', Previous Issue ⇧⌘', Ignore Issue ⌥⌘', End
/// Issue Walk). A plugin of its own, so a list can install Validation without it.
/// Needs Topology, whose order the stops are listed in.
public struct IssueWalkPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { "issue-walk" }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.service { IssueWalk(editor: $0) }
        // ⌘' and ⇧⌘' repeat while held; ⇧⌘' is the " key with ⌘ (the ⌘? convention: ⇧ is what types the character).
        registrar.command(.nextIssue, title: IssueWalkStyle.nextIssue, in: IssuesSection.self, runs: .betweenPresses,
                          isEnabled: { $0.editor.issueWalk?.canStep ?? false }) { $0.editor.issueWalk?.step(forward: true) }
        registrar.command(.previousIssue, title: IssueWalkStyle.previousIssue, in: IssuesSection.self, placed: .after(.nextIssue), runs: .betweenPresses,
                          isEnabled: { $0.editor.issueWalk?.canStep ?? false }) { $0.editor.issueWalk?.step(forward: false) }
        registrar.shortcut(KeyChord("'", .command), forCommand: .nextIssue, repeats: true)
        registrar.shortcut(KeyChord("\"", .command), forCommand: .previousIssue, repeats: true)
        registrar.command(.ignoreIssue, title: IssueWalkStyle.ignoreIssue, in: IssuesSection.self, placed: .after(.issueList),
                          shortcut: KeyChord("'", [.command, .option]), runs: .betweenPresses, isEnabled: { $0.editor.issueWalk?.canIgnore ?? false }) {
            $0.editor.issueWalk?.ignoreCurrent()
        }
        registrar.command(.endIssueWalk, title: IssueWalkStyle.endIssueWalk, in: IssuesSection.self, placed: .after(.ignoreIssue), runs: .betweenPresses,
                          isEnabled: { $0.editor.issueWalk?.isRunning ?? false }) { $0.editor.issueWalk?.end() }
    }
}

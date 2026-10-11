import Canvas
import CoreGraphics
import Foundation
import FuzzyMatching
import Geometry
import Observation
import Selection
import Topology

/// Find, per editor (`editor.find`): whether it's open, what's typed, what it found and which hit is
/// current, and the index it searches. Views read it (`@Observable`): the panel, and, through the
/// panel's takeover (`FindPanelPlugin`), the window, which shows a hidden inspector while Find is
/// open and hides it again as Find closes.
///
/// Typing searches the board shown when the query last changed (or ⌘F opened Find) and every board
/// under it, off the main actor, the newest keystroke's search cancelling the one before; results
/// list each shape with hits once, in order (`FindSearch.order`), and the count is hits. Stepping
/// (Return, ⌘G, the buttons) goes hit by hit, wrapping, and shows each one's board; a session of it
/// is one step back (`editor.navigate(from:_:)`). It never changes the selection, and never
/// transacts.
@MainActor
@Observable
public final class FindState {
    @ObservationIgnored private unowned let editor: CanvasEditor
    @ObservationIgnored let index: FindIndex
    /// What a plugin calls each board (`FindHeadings`), if one does.
    @ObservationIgnored private let namedHeading: FindHeadings.Contribution?

    /// Whether Find is open: its panel shows, its highlights draw.
    public private(set) var isActive = false
    /// What's typed. Setting it searches again.
    public var query = "" {
        didSet { if query != oldValue { queryDidChange() } }
    }
    /// The shapes with hits, in order, each once.
    public private(set) var results: [FindResult] = []
    /// How many hits, exact and typos alike.
    public private(set) var total = 0
    /// The current hit: a result, and which of its hits.
    public private(set) var current: FindPosition?
    /// +1 each ⌘F: the panel focuses its field and selects what's typed.
    public private(set) var focusRequest = 0
    /// Whether the index is still being built: the field shows a spinner.
    public private(set) var isIndexing = false

    /// The board searched: the one shown when the query last changed.
    @ObservationIgnored public private(set) var scope: BoardID = .root
    /// Each result's place in `results`.
    @ObservationIgnored private var places: [ShapeID: Int] = [:]
    /// The hits before each result: `offsets[i]` + ordinal + 1 is a hit's number.
    @ObservationIgnored private var offsets: [Int] = []
    @ObservationIgnored private var search = TextSearch("")
    /// +1 per search started: an answer for an older one is dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var answered = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    /// What picks the current hit as the answer lands.
    @ObservationIgnored private var landing = Landing.typed
    /// A step asked for before there was anything to step to (⇧⌘G with Find closed, a Return before
    /// the answer): taken as the answer lands.
    @ObservationIgnored private var pendingStep: Bool?
    /// The scope's shapes in order, as the last answer went by, while nothing has changed the file's
    /// shapes but moves.
    @ObservationIgnored private var order: (scope: BoardID, ids: [ShapeID])?
    /// Where a Find session began: Back after it returns there.
    @ObservationIgnored private var start: NavigationStart?
    /// Each result's hits, worked out when first asked (in view, current, listed), for this query.
    @ObservationIgnored private var hitsByShape: [ShapeID: [[TextHit]]] = [:]
    /// Where each shape's hits are drawn, kept for this query while the shape's size (and, for a
    /// contribution that `followsZoom`, the zoom) stays.
    @ObservationIgnored var laidOut: [ShapeID: LaidOutHits] = [:]
    /// Whether the overlay has asked for another frame, for shapes in view it had no time to lay
    /// out (tinted meanwhile).
    @ObservationIgnored public internal(set) var awaitsFrame = false
    /// The index's last build: how many slices of the main actor it took, and the longest's and all
    /// of them's thread CPU time.
    public var indexSlices: (count: Int, longest: Duration, total: Duration) {
        (index.slices, .nanoseconds(Int64(index.longestSlice)), .nanoseconds(Int64(index.totalBuild)))
    }
    /// How many shapes the index holds texts of.
    public var indexedShapes: Int { index.entries.count }
    #if DEBUG
    /// How many searches have run to their end, how many shapes' hits were patched by a commit, and
    /// how many records the index has read (debug builds): before the first ⌘F, and for a move,
    /// none.
    @ObservationIgnored public private(set) var searchesAnswered = 0
    @ObservationIgnored public private(set) var shapesPatched = 0
    public var recordsRead: Int { index.recordsRead }
    #endif

    enum Landing {
        /// Typed: the first hit in view on the board shown, else its first (revealed), else the first.
        case typed
        /// After an edit: the current hit kept, else the next; the camera stays.
        case kept(ShapeID, ordinal: Int, rank: Int)
    }

    init(editor: CanvasEditor) {
        self.editor = editor
        index = FindIndex(editor: editor)
        namedHeading = editor.registry.contributions(to: FindHeadings.self).first?.value
        index.didChange = { [weak self] ids in self?.indexDidChange(ids) }
        index.didBuild = { [weak self] in self?.indexDidBuild() }
    }

    // MARK: Reading

    /// What heads a board's rows in the panel: what a plugin calls the board (`registrar.findHeading`),
    /// else "Board" for the root and no name for any other.
    public func heading(of board: BoardID) -> FindHeading {
        namedHeading?(board, editor) ?? FindHeading(board.isRoot ? FindStyle.rootHeading : "")
    }

    /// The current hit's number, from 1, in `total`.
    public var currentNumber: Int? {
        guard let current, offsets.indices.contains(current.result) else { return nil }
        return offsets[current.result] + current.ordinal + 1
    }

    /// Whether the search for what's typed has answered and nothing is being indexed: what tests and
    /// benchmarks wait for.
    public var isSettled: Bool { !isIndexing && task == nil }

    /// Waits until `isSettled`.
    public func settled() async {
        while !isSettled {
            if let task { await task.value } else { await Task.yield() }
        }
    }

    /// A result's hits, a list per text, in order.
    public func hits(of id: ShapeID) -> [[TextHit]] {
        if let known = hitsByShape[id] { return known }
        guard let entry = index.entries[id] else { return [] }
        let found = entry.texts.map { search.hits(in: $0.folded) }
        hitsByShape[id] = found
        return found
    }

    /// A result's texts, as the index read them, in order.
    public func texts(of id: ShapeID) -> [String] { index.entries[id]?.texts.map(\.text) ?? [] }

    /// Whether a shape has hits.
    public func hasHits(_ id: ShapeID) -> Bool { places[id] != nil }

    /// Where a hit is drawn on the board shown, world units, where its shape is: its line rects, as
    /// its contribution lays its text out now (empty for a shape that isn't there).
    public func rects(of hit: FindHit, in id: ShapeID) -> [CGRect] {
        guard let record = editor.document[id] else { return [] }
        return FindOverlay.rects(of: hit, in: record, state: self, editor: editor) ?? []
    }

    /// The current hit's shape, text and range.
    public var currentHit: (shape: ShapeID, hit: FindHit)? {
        guard let current, results.indices.contains(current.result) else { return nil }
        let id = results[current.result].id
        var left = current.ordinal
        for (text, hits) in hits(of: id).enumerated() {
            if left < hits.count { return (id, FindHit(text: text, range: hits[left].range, isExact: hits[left].isExact)) }
            left -= hits.count
        }
        return nil
    }

    // MARK: Opening and closing

    /// ⌘F: opens Find (open, focuses its field and selects what's typed), ending editing first, and
    /// what's selected in the text being edited, if anything, is what's typed.
    public func open() {
        guard editor.session == nil else { return }
        let seed = editor.editingSelectedText.flatMap { FindState.seed(from: $0) }
        editor.endEditing()
        let opening = !isActive
        if opening {
            isActive = true
            scope = editor.board
            start = editor.navigationStart
            index.start()
            isIndexing = !index.isBuilt
        }
        if let seed, seed != query {
            query = seed
        } else if opening, !query.isEmpty {
            searchAgain(landing: .typed)
        }
        focusRequest += 1
        editor.setNeedsDisplay()
    }

    /// Closes Find: the highlights go and the panel shows what the selection says again; what's
    /// typed is kept for the next ⌘F, which selects it. The selection and the camera stay.
    public func close() {
        guard isActive else { return }
        isActive = false
        cancelSearch()
        pendingStep = nil
        start = nil
        laidOut = [:]
        editor.setNeedsDisplay()
    }

    /// One line of what was selected, as a query: nil for nothing but whitespace.
    static func seed(from selected: String) -> String? {
        let line = selected.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(FindStyle.longestSeed))
    }

    // MARK: Searching

    private func queryDidChange() {
        scope = editor.board
        searchAgain(landing: .typed)
    }

    /// Searches again for what's typed, over the index as it is now (once it's built).
    private func searchAgain(landing: Landing) {
        cancelSearch()
        self.landing = landing
        search = TextSearch(query)
        hitsByShape = [:]
        laidOut = [:]
        generation += 1
        guard !search.isEmpty else {
            apply(SearchAnswer(generation: generation, order: [], results: []))
            return
        }
        guard isActive || pendingStep != nil else { return }
        guard index.isBuilt else { return }                     // searched once it is
        let topology = editor.topology
        let file = editor.withoutObservingDocument { editor.file }
        let request = SearchRequest(generation: generation, query: search, entries: index.entries, scope: scope,
                                    order: order?.scope == scope ? order?.ids : nil, topology: topology?.snapshot(), file: file)
        let handover = Handover(request)
        task = Task { [weak self] in
            let answer = await FindSearch.run(handover)
            guard let self, let answer, !Task.isCancelled else { return }
            self.task = nil
            self.apply(answer)
        }
    }

    private func cancelSearch() {
        task?.cancel()
        task = nil
    }

    /// The answer of the newest search: its results, and the current hit picked as `landing` says.
    private func apply(_ answer: SearchAnswer) {
        guard answer.generation == generation else { return }
        answered = answer.generation
        #if DEBUG
        if !search.isEmpty { searchesAnswered += 1 }
        #endif
        if !search.isEmpty { order = (scope, answer.order) }
        setResults(answer.results, places: answer.places, offsets: answer.offsets, total: answer.total)
        let landing = self.landing
        self.landing = .typed
        switch landing {
        case .typed:
            land()
        case .kept(let id, let ordinal, let rank):
            keep(id, ordinal: ordinal, rank: rank)
        }
        if let forward = pendingStep {
            pendingStep = nil
            step(forward: forward)
        }
        editor.setNeedsDisplay()
    }

    private func setResults(_ list: [FindResult]) {
        let counted = SearchAnswer(generation: generation, order: [], results: list)
        setResults(list, places: counted.places, offsets: counted.offsets, total: counted.total)
    }

    private func setResults(_ list: [FindResult], places: [ShapeID: Int], offsets: [Int], total: Int) {
        results = list
        self.places = places
        self.offsets = offsets
        self.total = total
        if let current, !list.indices.contains(current.result) { self.current = nil }
    }

    /// Typing's current hit: the first on the board shown that's in view, else the first on the
    /// board shown (brought into view), else the first anywhere (not gone to: typing never shows
    /// another board). The first few results on the board shown are asked their bounds; past them,
    /// the shapes in view are looked up among the results instead, so a query with thousands of hits
    /// out of view costs what's in view.
    private func land() {
        guard !results.isEmpty else {
            current = nil
            return
        }
        let board = editor.board
        let view = editor.unobscuredViewport
        let visible = view.isEmpty ? CGRect.null : editor.cameraTarget.toWorld(view)
        var firstHere: Int?
        var asked = 0
        for (i, result) in results.enumerated() where result.board == board {
            if firstHere == nil { firstHere = i }
            if asked == FindStyle.landingProbe { break }
            asked += 1
            if let bounds = editor.shapeContext.bounds(of: [result.id]), visible.intersects(bounds) {
                current = FindPosition(result: i, ordinal: 0)
                return
            }
        }
        if asked == FindStyle.landingProbe, !visible.isNull {
            let inView = editor.paintOrder(in: visible).lazy.compactMap { self.places[$0.id] }.filter { $0 >= asked }.min()
            if let inView {
                current = FindPosition(result: inView, ordinal: 0)
                return
            }
        }
        if let firstHere {
            current = FindPosition(result: firstHere, ordinal: 0)
            go(to: firstHere)
        } else {
            current = FindPosition(result: 0, ordinal: 0)
        }
    }

    /// After an edit: the hit that was current, if its shape still has as many, else its shape's
    /// last, else the first of the next shape with hits.
    private func keep(_ id: ShapeID, ordinal: Int, rank: Int) {
        guard !results.isEmpty else {
            current = nil
            return
        }
        if let i = places[id] {
            current = FindPosition(result: i, ordinal: min(ordinal, results[i].hitCount - 1))
        } else {
            let next = results.firstIndex { $0.rank >= rank } ?? 0
            current = FindPosition(result: next, ordinal: 0)
        }
    }

    // MARK: Stepping

    /// Whether ⌘G and ⇧⌘G can run: nothing under way, and hits to step to, or, with Find closed, a
    /// query to open it on.
    func canStep(in editor: CanvasEditor) -> Bool {
        guard editor.session == nil, !search.isEmpty || !query.isEmpty else { return false }
        return isActive ? total > 0 : true
    }

    /// ⌘G, ⇧⌘G, Return and ⇧Return in the field, the buttons: the next hit (or the one before),
    /// wrapping, its board shown and the hit brought into view. With Find closed, ⌘G opens on what
    /// was typed and lands on the first hit in view, which is its step; ⇧⌘G lands there and steps back.
    public func step(forward: Bool) {
        guard editor.session == nil else { return }
        guard isActive else {
            guard !query.isEmpty else { return }
            // Opening lands on the first hit in view, which is ⌘G's step; ⇧⌘G lands there, then steps back.
            pendingStep = forward ? nil : false
            open()
            return
        }
        guard answered == generation, task == nil, index.isBuilt else {
            pendingStep = forward
            return
        }
        guard !results.isEmpty else { return }
        let next: FindPosition
        if let current, results.indices.contains(current.result) {
            if forward {
                next = current.ordinal + 1 < results[current.result].hitCount
                    ? FindPosition(result: current.result, ordinal: current.ordinal + 1)
                    : FindPosition(result: (current.result + 1) % results.count, ordinal: 0)
            } else if current.ordinal > 0 {
                next = FindPosition(result: current.result, ordinal: current.ordinal - 1)
            } else {
                let previous = (current.result + results.count - 1) % results.count
                next = FindPosition(result: previous, ordinal: results[previous].hitCount - 1)
            }
        } else {
            next = forward ? FindPosition(result: 0, ordinal: 0) : FindPosition(result: results.count - 1, ordinal: results[results.count - 1].hitCount - 1)
        }
        current = next
        go(to: next.result)
        editor.setNeedsDisplay()
    }

    /// A row clicked: its shape's first hit is current, brought into view.
    public func select(_ id: ShapeID) {
        guard isActive, editor.session == nil, let i = places[id] else { return }
        current = FindPosition(result: i, ordinal: 0)
        go(to: i)
        editor.setNeedsDisplay()
    }

    /// Shows a result's board, if it isn't shown, and brings the current hit into view unless it's
    /// there: part of the session's one step back.
    private func go(to i: Int) {
        let result = results[i]
        let move = { [self] in
            if result.board != editor.board {
                guard editor.showBoard(result.board) else { return }
            }
            let view = editor.unobscuredViewport
            guard !view.isEmpty, let bounds = hitBounds(of: result.id) ?? editor.shapeContext.bounds(of: [result.id]) else { return }
            if !editor.cameraTarget.toWorld(view).contains(bounds) { editor.reveal([result.id]) }
        }
        if let start { editor.navigate(from: start, move) } else { move() }
    }

    /// Where the current hit is drawn, world units, if it's in this shape and laid out: what has to
    /// be in view.
    private func hitBounds(of id: ShapeID) -> CGRect? {
        guard let hit = currentHit, hit.shape == id, let record = editor.document[id],
              let rects = FindOverlay.rects(of: hit.hit, in: record, state: self, editor: editor) else { return nil }
        return rects.reduce(CGRect.null) { $0.union($1) }.nilIfNull
    }

    // MARK: Upkeep

    /// The index read some shapes again (nil: all of them). The scope's order goes (a move reads
    /// nothing, so keeps it), query or not. While Find is open with a query, what they show now
    /// patches the results, O(those shapes): a shape's count, a shape gone; one that gains its first
    /// hit has the scope searched again, off the main actor, keeping the current hit. A search under
    /// way read the index as it began, and its answer would undo a patch: it starts again instead.
    private func indexDidChange(_ ids: Set<ShapeID>?) {
        if let ids, ids.isEmpty { return }
        order = nil
        if isActive, rescopeIfGone() {
            searchAgain(landing: .typed)
            return
        }
        guard let ids else {
            isIndexing = !index.isBuilt
            if !search.isEmpty, isActive { searchAgain(landing: task == nil ? keptLanding() : landing) }
            return
        }
        for id in ids {
            hitsByShape[id] = nil
            laidOut[id] = nil
        }
        guard !search.isEmpty, isActive else { return }
        guard task == nil else {
            searchAgain(landing: landing)
            return
        }
        let kept = keptLanding()
        var needsSearch = false
        var list = results
        var removed = Set<ShapeID>()
        for id in ids {
            let count = index.entries[id].map { $0.texts.reduce(0) { $0 + search.hits(in: $1.folded).count } } ?? 0
            #if DEBUG
            shapesPatched += 1
            #endif
            if let i = places[id] {
                if count == 0 {
                    removed.insert(id)
                } else if let entry = index.entries[id], entry.board == list[i].board {
                    let first = entry.texts.enumerated().lazy.compactMap { index, text in
                        search.hits(in: text.folded).first.map { FindHit(text: index, range: $0.range, isExact: $0.isExact) }
                    }.first ?? list[i].first
                    list[i] = FindResult(id: id, board: entry.board, hitCount: count, first: first, rank: list[i].rank)
                } else {
                    needsSearch = true
                }
            } else if count > 0 {
                needsSearch = true
            }
        }
        if needsSearch {
            searchAgain(landing: kept)
            return
        }
        if !removed.isEmpty { list.removeAll { removed.contains($0.id) } }
        setResults(list)
        if case .kept(let id, let ordinal, let rank) = kept { keep(id, ordinal: ordinal, rank: rank) } else { current = nil }
        editor.setNeedsDisplay()
    }

    /// If the scope's board can no longer be shown (it was deleted, or a file put in place has none
    /// such), scopes to the board shown instead: whether it did, so the search is made again.
    private func rescopeIfGone() -> Bool {
        guard !editor.withoutObservingDocument({ editor.canShow(scope) }) else { return false }
        scope = editor.board
        return true
    }

    /// What keeps the current hit across a search again.
    private func keptLanding() -> Landing {
        guard let current, results.indices.contains(current.result) else { return .kept(ShapeID(), ordinal: 0, rank: 0) }
        let result = results[current.result]
        return .kept(result.id, ordinal: current.ordinal, rank: result.rank)
    }

    private func indexDidBuild() {
        isIndexing = false
        if !search.isEmpty, isActive || pendingStep != nil { searchAgain(landing: landing) }
    }
}

/// A hit among the results: a result's place, and which of its hits (from 0).
public struct FindPosition: Hashable, Sendable {
    public let result: Int
    public let ordinal: Int

    public init(result: Int, ordinal: Int) {
        self.result = result
        self.ordinal = ordinal
    }
}

extension FindState: EditorService {
    /// Follows the commit: before the first ⌘F, nothing but the revision. Topology first, whose
    /// snapshot a search orders by.
    public func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        editor.topology?.catchUp(changes)
        index.hear(changes)
    }

    /// The index is the file's: nothing, but a file put in place, read again. The scope stays.
    public func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        index.boardDidChange(change)
    }

    /// Kept layouts go when the canvas starts or stops drawing skeletons: the shape being edited's
    /// are made in full again.
    public func drawsSkeletonsDidChange(in editor: CanvasEditor) {
        laidOut = [:]
    }
}

extension CGRect {
    var nilIfNull: CGRect? { isNull ? nil : self }
}

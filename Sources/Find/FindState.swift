import AppKit
import Canvas
import CoreGraphics
import DetailPanel
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
/// transacts. Up and Down (Page Up, Page Down) in the field move between results without selecting
/// anything; ⌘↩ (`finish()`) closes Find and selects the current hit's shape.
@MainActor
@Observable
public final class FindState {
    @ObservationIgnored private unowned let editor: CanvasEditor
    @ObservationIgnored let index: FindIndex
    /// The stepping: the place among the results, its moves, and the one step back (Selection's).
    @ObservationIgnored let walk: ShapeWalk

    /// Whether Find is open: its panel shows, its highlights draw.
    public private(set) var isActive = false
    /// What's typed. Setting it searches again.
    public var query = "" {
        didSet { if query != oldValue { queryDidChange() } }
    }
    /// The shapes with hits, in order, each once.
    public private(set) var results: [FindResult] = []
    @ObservationIgnored private var labelStems: [Int: String] = [:]
    /// What `whenResultsChange` asked to be told.
    @ObservationIgnored private var resultListeners: [@MainActor () -> Void] = []
    /// How many hits, exact and typos alike.
    public private(set) var total = 0
    /// The current hit: a result, and which of its hits (the walk's place).
    public private(set) var current: FindPosition? {
        get { walk.current.map { FindPosition(result: $0.row, ordinal: $0.ordinal) } }
        set { walk.land(at: newValue.map { WalkPosition(row: $0.result, ordinal: $0.ordinal) }) }
    }
    /// +1 each step to another hit (⌘G, the arrows and buttons, a click on a row), never for typing's
    /// landing: what VoiceOver announces by, so typing is not talked over.
    public var stepCount: Int { walk.stepCount }
    /// +1 each ⌘F: the panel focuses its field and selects what's typed.
    public private(set) var focusRequest = 0
    /// Whether the index is still being built: the field shows a spinner.
    public private(set) var isIndexing = false
    /// Bumped when a row's symbol may have another tint (a result shape's commit, the file's
    /// colors): a row reads it, to be drawn again, since it reads its shape's tint as it's drawn and
    /// keeps none.
    public private(set) var tintRevision = 0

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
        case kept(WalkKept)
    }

    init(editor: CanvasEditor) {
        self.editor = editor
        walk = ShapeWalk(editor: editor, arrival: .shows)
        index = FindIndex(editor: editor)
        index.didChange = { [weak self] ids in self?.indexDidChange(ids) }
        index.didBuild = { [weak self] in self?.indexDidBuild() }
        walk.source = self
    }

    // MARK: Reading

    /// The current hit's number, from 1, in `total`.
    public var currentNumber: Int? { walk.number }

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

    /// What a result's row leads with: the text that names its shape (its title, a contribution's `names`), when the row's
    /// first hit is in another of its texts (a table's row); nil when it has none, or the hit is in that text, which the
    /// snippet then shows.
    public func rowName(of result: FindResult) -> String? {
        guard let entry = index.entries[result.id], let kind = editor.withoutObservingDocument({ editor.file.record(result.id)?.kind }),
              let named = entry.texts.indices.first(where: { index.contribution(entry.texts[$0].source, of: kind)?.names == true }),
              named != result.first.text else { return nil }
        let name = entry.texts[named].text.replacingOccurrences(of: "\n", with: " ")
        return name.isEmpty ? nil : name
    }

    /// Whether a shape has hits.
    public func hasHits(_ id: ShapeID) -> Bool { places[id] != nil }

    /// The fields of a shape's texts that hold hits (`FindableText.field`: a row's id, for a kind whose rows are found a
    /// text a row), read from its result, which the search (off the main actor) and a commit's patch keep: what a plugin
    /// that hides some of a shape's texts shows while Find is open (a folded table's rows). Costs the texts that hold hits,
    /// never a search again. Empty while Find is closed, and for a shape with none.
    public func fieldsHit(of id: ShapeID) -> Set<String> {
        guard isActive, let place = places[id], results.indices.contains(place), let entry = index.entries[id] else { return [] }
        var fields: Set<String> = []
        for text in results[place].textsHit where entry.texts.indices.contains(text) { fields.insert(entry.texts[text].field) }
        return fields
    }

    /// The ranges hit in each field of a shape's texts that holds hits (UTF-16, of the field's text): what a plugin that hides some
    /// of a shape's texts reads to show only those whose hits are drawn where they are (an endpoint's row, never for a hit in its
    /// group's prefix, which is drawn on the group's header). Costs the shape's hits; empty while Find is closed.
    public func rangesHit(of id: ShapeID) -> [String: [Range<Int>]] {
        guard isActive, places[id] != nil, let entry = index.entries[id] else { return [:] }
        var ranges: [String: [Range<Int>]] = [:]
        for (text, hits) in hits(of: id).enumerated() where entry.texts.indices.contains(text) && !hits.isEmpty {
            ranges[entry.texts[text].field, default: []] += hits.map(\.range)
        }
        return ranges
    }

    /// Runs `body` each time what `fieldsHit(of:)` answers may have changed: new results, a commit's patch of them, Find
    /// opened or closed. Called after the change, never during a search; a plugin that lays shapes out by the answer says
    /// so then (`shapesDidChangeLayout`).
    public func whenResultsChange(_ body: @escaping @MainActor () -> Void) {
        resultListeners.append(body)
    }

    /// Where a hit is drawn on the board shown, world units, where its shape is: its line rects, as
    /// its contribution lays its text out now (empty for a shape that isn't there).
    public func rects(of hit: FindHit, in id: ShapeID) -> [CGRect] {
        guard let record = editor.document[id] else { return [] }
        return FindOverlay.rects(of: hit, in: record, state: self, editor: editor) ?? []
    }

    /// The current hit's shape, text and range.
    public var currentHit: (shape: ShapeID, hit: FindHit)? {
        current.flatMap(hit(at:))
    }

    private func hit(at position: FindPosition) -> (shape: ShapeID, hit: FindHit)? {
        guard results.indices.contains(position.result) else { return nil }
        let id = results[position.result].id
        var left = position.ordinal
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
            walk.begin()
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
        walk.end()
        laidOut = [:]
        tellResultListeners()
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
        case .kept(let kept):
            walk.rowsDidChange(keeping: kept)
        }
        if let forward = pendingStep {
            pendingStep = nil
            // A step is refused while shapes wait to be placed; the landing ⇧⌘G opens on is not.
            if editor.isPlacingLater { walk.land(stepping: forward) } else { step(forward: forward) }
        }
        editor.setNeedsDisplay()
    }

    private func setResults(_ list: [FindResult]) {
        let counted = SearchAnswer(generation: generation, order: [], results: list)
        setResults(list, places: counted.places, offsets: counted.offsets, total: counted.total)
    }

    private func setResults(_ list: [FindResult], places: [ShapeID: Int], offsets: [Int], total: Int) {
        results = list
        labelStems.removeAll(keepingCapacity: true)
        self.places = places
        self.offsets = offsets
        self.total = total
        walk.rowsDidChange()
        tellResultListeners()
    }

    private func tellResultListeners() {
        for listener in resultListeners { listener() }
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
            walk.land(at: WalkPosition(row: firstHere, ordinal: 0), arriving: true)
        } else {
            current = FindPosition(result: 0, ordinal: 0)
        }
    }

    // MARK: Stepping

    /// Whether ⌘G and ⇧⌘G can run: nothing under way, and with Find open hits to step to and no shapes
    /// waiting to be placed (the walker's own guard, which refuses a step then); with Find closed, a
    /// query to open it on, which ⌘F does while shapes wait too.
    func canStep(in editor: CanvasEditor) -> Bool {
        guard editor.session == nil, !search.isEmpty || !query.isEmpty else { return false }
        return isActive ? total > 0 && !editor.isPlacingLater : true
    }

    /// ⌘G, ⇧⌘G, Return and ⇧Return in the field, the buttons: the next hit (or the one before),
    /// wrapping, its board shown and the hit brought into view. With Find closed, ⌘G opens on what
    /// was typed and lands on the first hit in view, which is its step; ⇧⌘G lands there and steps back,
    /// as one landing while shapes wait to be placed (a step is refused then: `ShapeWalk.land(stepping:)`).
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
        walk.step(forward: forward)
    }

    /// A row clicked: its shape's first hit is current, brought into view.
    public func select(_ id: ShapeID) {
        guard isActive, editor.session == nil, let i = places[id] else { return }
        walk.pick(row: i)
    }

    /// Up, Down, Page Up and Page Down in the field: the result `by` rows on (negative: before),
    /// wrapping, its first hit current and brought into view, as a click on its row does. Nothing
    /// current yet: the first result going down, the last going up. Changes neither the selection
    /// nor the document.
    public func move(by rows: Int) {
        guard isActive, editor.session == nil, answered == generation, task == nil, !results.isEmpty else { return }
        walk.move(by: rows)
    }

    /// ⌘↩ in the field: closes Find and selects the current hit's shape, taking the hit along. The
    /// selection and the board shown are the only things it changes, as one step back to where the
    /// session began (Back returns there, even after the stepping moved the camera or showed another
    /// board). False, with Find left open, when there is no hit.
    @discardableResult
    public func finish() -> Bool {
        guard isActive, editor.session == nil, currentHit != nil else { return false }
        return walk.finish { close() }
    }

    /// What VoiceOver reads for a result's row: the text around its first hit, the kind's name, the
    /// board when it isn't the one shown, and the hit's number among all.
    public func rowLabel(of index: Int) -> String {
        guard results.indices.contains(index) else { return "" }
        var parts = [labelStem(of: index)]
        let number = current?.result == index ? currentNumber : offsets[safe: index].map { $0 + 1 }
        if let number { parts.append("hit \(number) of \(total)") }
        return parts.joined(separator: ", ")
    }

    /// The part of a row's label that holds until the results change: its text, kind and board. Made once a
    /// row and kept, since every row is asked again at each step, with or without VoiceOver.
    private func labelStem(of index: Int) -> String {
        if let known = labelStems[index] { return known }
        let result = results[index]
        var parts = (rowName(of: result).map { [$0] } ?? []) + [FindSnippet.text(of: result, in: self), kindName(of: result.id)]
        if result.board != editor.board {
            let board = editor.boardHeading(of: result.board).title
            if !board.isEmpty { parts.append(board) }
        }
        let made = parts.joined(separator: ", ")
        labelStems[index] = made
        return made
    }

    /// What each step announces: "Hit 3 of 12, Note, the text around it".
    public var announcement: String? {
        guard isActive, let current, results.indices.contains(current.result), let number = currentNumber else { return nil }
        let result = results[current.result]
        return ["Hit \(number) of \(total)", kindName(of: result.id), FindSnippet.text(of: result, in: self)].joined(separator: ", ")
    }

    private func kindName(of id: ShapeID) -> String {
        editor.withoutObservingDocument { editor.file.record(id).map { editor.registry.label(of: $0.kind).name } ?? "" }
    }

    /// Where the current hit is drawn, world units, if it's in this shape and laid out: what has to
    /// be in view.
    private func hitBounds(of id: ShapeID, at position: FindPosition) -> CGRect? {
        guard let hit = hit(at: position), hit.shape == id, let record = editor.document[id],
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
                    let found = entry.texts.enumerated().compactMap { index, text in
                        search.hits(in: text.folded).first.map { (text: index, hit: FindHit(text: index, range: $0.range, isExact: $0.isExact)) }
                    }
                    list[i] = FindResult(id: id, board: entry.board, hitCount: count, first: found.first?.hit ?? list[i].first,
                                         textsHit: found.map(\.text), rank: list[i].rank)
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
        if case .kept(let place) = kept { walk.rowsDidChange(keeping: place) } else { current = nil }
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
        .kept(walk.kept ?? WalkKept(key: ShapeID(), ordinal: 0, rank: 0))
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

/// The results are the walk's rows: a result is a shape with as many stops as it has hits.
extension FindState: ShapeWalkSource {
    public var walkRowCount: Int { results.count }

    public func walkRow(at index: Int) -> WalkRow {
        let result = results[index]
        return WalkRow(key: result.id, shape: result.id, board: result.board, stops: result.hitCount, rank: result.rank)
    }

    public func walkPlace(ofKey key: AnyHashable) -> Int? { (key as? ShapeID).flatMap { places[$0] } }

    public func walkStops(before index: Int) -> Int { offsets[index] }

    /// Where the current hit is drawn on the board just shown.
    public func walkFocus(of position: WalkPosition) -> CGRect? {
        guard results.indices.contains(position.row) else { return nil }
        return hitBounds(of: results[position.row].id, at: FindPosition(result: position.row, ordinal: position.ordinal))
    }

    /// The rows name the board shown, which the move may have changed; the hits are drawn again.
    public func walkDidMove() {
        labelStems.removeAll(keepingCapacity: true)
        editor.setNeedsDisplay()
    }
}

extension FindState: EditorService {
    /// A move changes no tint: a drag's every event is a look at the results it touched, if any.
    public func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        if !places.isEmpty, changes.changed.contains(where: { places[$0] != nil && !changes.moved.contains($0) })
            || changes.elsewhere.contains(where: { places[$0] != nil }) {
            tintRevision &+= 1
        }
    }

    /// The index follows the commit once every service has it: the contributions' `affected` ask their
    /// plugins' services, and a search orders by Topology's snapshot.
    public func documentDidSettle(_ changes: ChangeSet, in editor: CanvasEditor) {
        index.hear(changes)
    }

    /// A result's symbol in the panel: its kind's, in the tint the shape has (`editor.tint(of:)`: its
    /// kind's unless it has a color of its own). Read as a row is drawn, never kept, and observed through
    /// `tintRevision`, so the row is drawn again when the shape's tint may have changed.
    public func symbol(of id: ShapeID) -> (systemImage: String?, tint: NSColor?) {
        _ = tintRevision
        return editor.withoutObservingDocument {
            guard let record = editor.file.record(id) else { return (nil, nil) }
            return (editor.registry.label(of: record.kind).systemImage, editor.tint(of: record))
        }
    }

    /// The file's colors changed: the rows' symbols are drawn again.
    public func shapeTintsDidChange(in editor: CanvasEditor) {
        tintRevision &+= 1
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

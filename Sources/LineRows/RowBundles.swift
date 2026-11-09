import Canvas
import Connections
import CoreGraphics
import Selection
import Topology

// How the connections at shapes written as lines are drawn among those that share their path (Connections'
// `ConnectionBundle`), provided by LineRows, the owner of what's folded: the lines a fold shows say where each row's
// connections end. Worked out per shape written as lines from Topology's literal connections at it, and again only for the
// shapes a change reaches (a connection drawn, re-aimed or deleted; a shape's rows changed; a fold, a peek, editing begun or
// ended) and the shapes at their connections' other ends, O(their connections); the connections whose answer moved are laid
// out again. Nothing is stored in the file.
//
// - Connections whose two ends are drawn at one place (a row's line, the fold line standing for it, a shape as a whole) share
//   a path. Those of one channel with an end a fold hides are a bundle: the first in the board's order leads (drawn once, its
//   pill counting them, "writes · 9"), the rest are its members (drawn, hit, spoken and selected by it). The rest of them (a
//   writes and a reads from one row to one table) and the leads each take a slot, bowed apart.
// - Connections that end at one place with their other ends on one shape, at different lines (six rows into one table, two
//   keys into one row), are fanned there: each comes in at an angle of its own, by where its other end is along that shape.
// - A connection to a shape written as lines as a whole comes in at a row clear of the rows other connections end at on its
//   side (nil where its first row is: the kind's own entry), from the end of the shape nearer its other end.

/// Where a connection's end is drawn on its shape, as far as sharing a path goes.
private enum Standing: Hashable {
    /// The shape as a whole: a shape not written as lines whatever part its binding names (a pill meets it whole), or one
    /// written as lines with no part named.
    case whole(ShapeID)
    /// A line of a shape written as lines: a row's own, or the fold's line standing for it.
    case line(ShapeID, Int)

    var shape: ShapeID {
        switch self {
        case .whole(let id), .line(let id, _): id
        }
    }

    var line: Int? { if case .line(_, let line) = self { line } else { nil } }
}

/// The connections at shapes written as lines, and how each is drawn among those sharing its path, on every board of the file
/// a layout reads (the board shown, and any other read for `canvas draw --on`, a capture or a preview): a board is read when
/// it is first asked, and kept until a commit reaches it.
@MainActor
final class RowBundles {
    unowned let editor: CanvasEditor
    private var following: TopologyFollowing?
    /// What is worked out of each board read.
    private var states: [BoardID: BoardState] = [:]

    /// One board's bundles.
    private final class BoardState {
        let board: BoardID
        /// Each shape written as lines worked out, with what it says of each connection at it, and the bundles it found, each
        /// lead's connections, the lead first.
        var partials: [ShapeID: Partial] = [:]
        /// The shapes worked out that each connection is at.
        var shapesOf: [ShapeID: [ShapeID]] = [:]
        /// Each connection's answer, its ends' partials joined; none for a connection drawn as ever.
        var answers: [ShapeID: ConnectionBundle] = [:]
        /// Each bundle's connections, its lead first: what a press on any of them selects.
        var bundles: [ShapeID: [ShapeID]] = [:]
        /// The shapes at connections' far ends whose boxes a shape's entry rows were read from, by that shape: when one moves
        /// the shape is worked out again.
        var readers: [ShapeID: Set<ShapeID>] = [:]
        /// The shapes written as lines to work out again once the change being delivered has settled.
        var dirty: Set<ShapeID> = []
        var flushAsked = false

        init(board: BoardID) { self.board = board }
    }

    private struct Partial {
        var answers: [ShapeID: ConnectionBundle] = [:]
        var bundles: [ShapeID: [ShapeID]] = [:]
        /// The shapes whose boxes this was read from.
        var reads: Set<ShapeID> = []
    }

    init(editor: CanvasEditor) {
        self.editor = editor
        following = editor.topology?.follow { [weak self] change in self?.heard(change) }
        // A fold, a peek, editing begun or ended: what a shape's lines show changed.
        editor.rowFolds?.whenLinesChange { [weak self] ids in self?.mark(ids) }
    }

    // MARK: Asking

    /// The board's shapes as they are committed: the editor's own for the board shown.
    private func document(of board: BoardID) -> CanvasDocument { board == editor.board ? editor.document : editor.file[board] }

    /// What is worked out of `board`, read the first time it is asked; nil for a board that can't be shown.
    private func state(of board: BoardID) -> BoardState? {
        if let known = states[board] { return known }
        guard editor.canShow(board) else { return nil }
        let state = BoardState(board: board)
        states[board] = state
        let registry = editor.registry
        let shapes = document(of: board).shapes.lazy.filter { registry.lineRows(of: $0.kind) != nil }.map(\.id)
        let touched = work(Set(shapes), in: state)
        for id in touched { join(id, in: state) }
        return state
    }

    /// The answer for a connection as `reading` lays it out: mid-transaction, the committed one unless the transaction changed it.
    func answer(for record: AnyShapeRecord, in reading: LayoutReading) -> ConnectionBundle? {
        guard let board = reading.board(containing: record.id), let state = state(of: board),
              !state.answers.isEmpty, let answer = state.answers[record.id] else { return nil }
        // Mid-transaction, a connection the transaction changed keeps its answer while its ends are where they were (a bend
        // dragged keeps its slot's bow, and a pill typed in stays on its line); re-aimed, it is drawn as ever until the commit.
        if !reading.isCommitted, reading.isChanged(record.id) {
            guard let committed = document(of: board)[record.id], endsOf(committed) == endsOf(record) else { return nil }
        }
        return answer
    }

    /// Where a connection's two ends are, as its record says them: its literal connection edges' ends.
    private func endsOf(_ record: AnyShapeRecord) -> [Edge] {
        editor.registry.edges(of: record).filter(\.isConnection)
    }

    /// The shapes `id` is selected with: its bundle's, lead first; nil for a connection in none.
    func unit(of id: ShapeID) -> [ShapeID]? {
        guard let board = editor.file.board(containing: id), let state = state(of: board),
              !state.bundles.isEmpty, let answer = state.answers[id] else { return nil }
        switch answer.role {
        case .lead: return state.bundles[id]
        case .member(let lead): return state.bundles[lead]
        case .alone: return nil
        }
    }

    // MARK: Hearing

    private func heard(_ change: TopologyChange) {
        switch change.cause {
        case .rebuild: rebuildLater()
        case .provide: return
        case .commit: mark(change.touched)
        }
    }

    /// Works out again the shapes written as lines among `ids` (and those that read where an id is), once what changed has
    /// settled; only on the boards read.
    private func mark(_ ids: some Sequence<ShapeID>) {
        guard !states.isEmpty else { return }
        let registry = editor.registry, ids = Array(ids)
        for state in states.values {
            let document = document(of: state.board)
            var marked: Set<ShapeID> = []
            for id in ids {
                if let readers = state.readers[id] { marked.formUnion(readers) }
                if state.partials[id] != nil || document[id].map({ registry.lineRows(of: $0.kind) != nil }) == true { marked.insert(id) }
            }
            guard !marked.isEmpty else { continue }
            state.dirty.formUnion(marked)
            guard !state.flushAsked else { continue }
            state.flushAsked = true
            let board = state.board
            editor.onceSettled { [weak self] in self?.flush(board) }
        }
    }

    private func rebuildLater() {
        guard !states.isEmpty else { return }
        editor.onceSettled { [weak self] in
            guard let self else { return }
            let boards = Array(states.keys)
            var before = Set<ShapeID>()
            for state in states.values { before.formUnion(state.answers.keys) }
            states = [:]
            var after = before
            for board in boards { if let state = state(of: board) { after.formUnion(state.answers.keys) } }
            editor.connectionBundlesDidChange(after)
        }
    }

    /// A commit reached other boards: what is worked out of them is read again as asked, and their connections are laid out again.
    private func forget(_ boards: Set<BoardID>) {
        var ids = Set<ShapeID>()
        for board in boards {
            guard let state = states.removeValue(forKey: board) else { continue }
            ids.formUnion(state.answers.keys)
        }
        guard !ids.isEmpty else { return }
        editor.onceSettled { [weak self] in self?.editor.connectionBundlesDidChange(ids) }
    }

    private func flush(_ board: BoardID) {
        guard let state = states[board] else { return }
        state.flushAsked = false
        guard !state.dirty.isEmpty else { return }
        var shapes = state.dirty
        state.dirty = []
        // The shapes at the other ends of their connections: what is drawn at one end of a path is read from both.
        let registry = editor.registry, document = document(of: board)
        for id in shapes {
            for arrow in state.partials[id].map({ Array($0.answers.keys) }) ?? [] { shapes.formUnion(state.shapesOf[arrow] ?? []) }
            for edge in connections(at: id, in: document) {
                for end in [edge.source, edge.target] where document[end].map({ registry.lineRows(of: $0.kind) != nil }) == true { shapes.insert(end) }
            }
        }
        let touched = work(shapes, in: state)
        var changed: Set<ShapeID> = []
        for id in touched where join(id, in: state) { changed.insert(id) }
        editor.connectionBundlesDidChange(changed)
        keepSelectionWhole(among: changed, in: state)
    }

    /// A connection selected that a fold has just bundled under its lead (a member, drawn by it) is selected with its bundle,
    /// as a click on the lead selects it: the selection setter takes the rest.
    private func keepSelectionWhole(among changed: Set<ShapeID>, in state: BoardState) {
        guard state.board == editor.board else { return }
        let selected = editor.selectedShapeIDs
        let members = selected.filter { changed.contains($0) && state.answers[$0]?.lead != nil }
        guard !members.isEmpty else { return }
        // Laid out as the member it is now (hidden), which is what the selection takes a pick by.
        for id in members { _ = editor.shapeContext.geometry(of: id) }
        editor.selectedShapeIDs = selected
    }

    // MARK: Working out

    /// The literal connections at `id` that are on `document`'s board, each once.
    private func connections(at id: ShapeID, in document: CanvasDocument) -> [Edge] {
        guard let topology = editor.topology, let kind = editor.registry.connectorKind else { return [] }
        var seen = Set<ShapeID>()
        return topology.edges(of: id, .either, view: .literal).filter { edge in
            edge.isConnection && document[edge.carrier]?.kind == kind && seen.insert(edge.carrier).inserted
        }
    }

    /// Works `shapes` out again: each one's partial answers. Returns the connections whose answer may have moved.
    private func work(_ shapes: Set<ShapeID>, in state: BoardState) -> Set<ShapeID> {
        var touched: Set<ShapeID> = []
        for id in shapes {
            for arrow in state.partials[id].map({ Array($0.answers.keys) }) ?? [] {
                touched.insert(arrow)
                state.shapesOf[arrow]?.removeAll { $0 == id }
                if state.shapesOf[arrow]?.isEmpty == true { state.shapesOf[arrow] = nil }
            }
            for far in state.partials[id]?.reads ?? [] {
                state.readers[far]?.remove(id)
                if state.readers[far]?.isEmpty == true { state.readers[far] = nil }
            }
            let found = partial(of: id, in: state)
            state.partials[id] = found.answers.isEmpty ? nil : found
            for arrow in found.answers.keys {
                touched.insert(arrow)
                state.shapesOf[arrow, default: []].append(id)
            }
            if !found.answers.isEmpty { for far in found.reads { state.readers[far, default: []].insert(id) } }
        }
        return touched
    }

    /// Joins a connection's answer from its ends' partials. Returns whether it changed.
    @discardableResult
    private func join(_ arrow: ShapeID, in state: BoardState) -> Bool {
        var joined: ConnectionBundle?
        var led: [ShapeID]?
        var partings: [ConnectionBundle.Fan] = []
        for shape in state.shapesOf[arrow] ?? [] {
            guard let partial = state.partials[shape], let part = partial.answers[arrow] else { continue }
            if let parting = part.parting { partings.append(parting) }
            if led == nil, case .lead = part.role { led = partial.bundles[arrow] }
            guard var answer = joined else {
                joined = part
                continue
            }
            for fan in part.fans where answer.fan(at: fan.end) == nil { answer.fans.append(fan) }
            answer.entries.merge(part.entries) { first, _ in first }
            joined = answer
        }
        // Parting says something only beside a fan (it spaces pills a fan slides toward the other end): the one at the end that is
        // not fanned, whichever of the ends' shapes said it first; alone, the connection is drawn as ever.
        if let fanned = joined { joined?.parting = fanned.fans.isEmpty ? nil : partings.first { fanned.fan(at: $0.end) == nil } }
        let answer = joined.flatMap { $0.isPlain ? nil : $0 }
        let before = state.answers[arrow]
        state.answers[arrow] = answer
        state.bundles[arrow] = led
        return before != answer
    }

    /// What `shape`, written as lines, says of each connection at it: bundles and slots among those sharing both drawn ends,
    /// fans among those with their other end at one place and theirs at different lines of it, and the row a connection to it as a
    /// whole comes in at.
    private func partial(of shape: ShapeID, in state: BoardState) -> Partial {
        let document = document(of: state.board), registry = editor.registry, context = editor.shapeContext
        guard let record = document[shape], registry.lineRows(of: record.kind) != nil else { return Partial() }
        let edges = connections(at: shape, in: document)
        guard !edges.isEmpty else { return Partial() }
        var reader = StandingReader(document: document, context: context, registry: registry)

        struct Drawn {
            let arrow: ShapeID
            let order: Int
            let channel: EdgeTypeID
            let start: Standing
            let end: Standing
            /// An end a fold hides, and the line that stands for it.
            let hidden: Bool
            let foldLine: PartAddress?
            let sourcePart: PartID?
            let targetPart: PartID?
            let source: ShapeID
            let target: ShapeID
        }
        var drawn: [Drawn] = []
        for edge in edges {
            let start = reader.standing(of: edge.source, part: edge.sourcePart)
            let end = reader.standing(of: edge.target, part: edge.targetPart)
            let hiddenStart = start.hidden, hiddenEnd = end.hidden
            drawn.append(Drawn(arrow: edge.carrier, order: document.index(of: edge.carrier) ?? 0, channel: edge.type,
                               start: start.standing, end: end.standing, hidden: hiddenStart || hiddenEnd,
                               foldLine: hiddenStart ? start.foldLine : hiddenEnd ? end.foldLine : nil,
                               sourcePart: edge.sourcePart, targetPart: edge.targetPart, source: edge.source, target: edge.target))
        }
        drawn.sort { $0.order < $1.order }
        var answers: [ShapeID: ConnectionBundle] = [:], bundles: [ShapeID: [ShapeID]] = [:]
        for item in drawn { answers[item.arrow] = ConnectionBundle() }

        // Sharing both drawn ends, whichever way each runs (a call and its callback between two rows): a bundle of a channel where a
        // fold hides an end, of those running one way, then a slot each for what is drawn. An arrow running the other way from the
        // path's first takes the mirror of its slot, since its bow is measured across its own chord, the other way (review R23).
        struct Path: Hashable { let ends: Set<Standing> }
        var paths: [Path: [Drawn]] = [:], pathOrder: [Path] = []
        for item in drawn {
            let path = Path(ends: [item.start, item.end])
            if paths[path] == nil { pathOrder.append(path) }
            paths[path, default: []].append(item)
        }
        var members = Set<ShapeID>()
        for path in pathOrder {
            guard let sharing = paths[path], sharing.count > 1 else { continue }
            var shown: [ShapeID] = []
            struct Way: Hashable { let channel: EdgeTypeID; let start: Standing }
            var channels: [Way: [Drawn]] = [:], channelOrder: [Way] = []
            for item in sharing where item.hidden {
                let way = Way(channel: item.channel, start: item.start)
                if channels[way] == nil { channelOrder.append(way) }
                channels[way, default: []].append(item)
            }
            for channel in channelOrder {
                guard let bundle = channels[channel], bundle.count > 1, let lead = bundle.first else { continue }
                answers[lead.arrow]?.role = .lead(count: bundle.count, standing: lead.foldLine)
                bundles[lead.arrow] = bundle.map(\.arrow)
                for member in bundle.dropFirst() {
                    answers[member.arrow]?.role = .member(lead: lead.arrow)
                    members.insert(member.arrow)
                }
            }
            var reversed = Set<ShapeID>()
            for item in sharing where !members.contains(item.arrow) {
                shown.append(item.arrow)
                if item.start != sharing[0].start { reversed.insert(item.arrow) }
            }
            guard shown.count > 1 else { continue }
            for (slot, arrow) in shown.enumerated() {
                answers[arrow]?.slot = reversed.contains(arrow) ? shown.count - 1 - slot : slot
                answers[arrow]?.slots = shown.count
            }
        }

        // Fans: those drawn with their other end at one place, their end here at different lines of this shape.
        struct Far: Hashable { let far: Standing; let farEnd: ConnectionBundle.End }
        var fans: [Far: [(arrow: ShapeID, here: Standing)]] = [:]
        for item in drawn where !members.contains(item.arrow) && item.source != item.target {
            let (here, far, farEnd): (Standing, Standing, ConnectionBundle.End) =
                item.source == shape ? (item.start, item.end, .end) : (item.end, item.start, .start)
            fans[Far(far: far, farEnd: farEnd), default: []].append((item.arrow, here))
        }
        for (far, group) in fans {
            // Ordered along this shape: by line, a connection to it as a whole first.
            let lines = Array(Set(group.map(\.here))).sorted { ($0.line ?? -1) < ($1.line ?? -1) }
            guard lines.count > 1 else { continue }
            for (arrow, here) in group {
                guard let index = lines.firstIndex(of: here) else { continue }
                answers[arrow]?.fans.append(ConnectionBundle.Fan(end: far.farEnd, index: index, count: lines.count))
            }
        }

        // What is read of other shapes, so that a commit to one works this out again (the parting's far ends, the sides' containers).
        var reads: Set<ShapeID> = []

        // Parting: those with their end here at one line and their other ends at different places (a row's writes and reads to two
        // tables), ordered by where those are, top to bottom; their pills, slid toward this end by a fan at the other, are spaced
        // apart along their lines rather than stacked (UX walk 3 evolve-5).
        struct Here: Hashable { let here: Standing; let end: ConnectionBundle.End }
        var parting: [Here: [(arrow: ShapeID, far: Standing)]] = [:]
        for item in drawn where !members.contains(item.arrow) && item.source != item.target {
            let (here, far, end): (Standing, Standing, ConnectionBundle.End) =
                item.source == shape ? (item.start, item.end, .start) : (item.end, item.start, .end)
            guard here.line != nil else { continue }
            parting[Here(here: here, end: end), default: []].append((item.arrow, far))
        }
        // By where the far ends are, top to bottom; ties (aligned shapes, wholes at -1) by the board's order and then the line, never by
        // a set's order, which differs from one pass to the next and would swap which pill steps out (review U9-C6).
        func height(of far: Standing) -> (CGFloat, Int, Int) {
            (document[far.shape]?.box?.midY ?? 0, document.index(of: far.shape) ?? 0, far.line ?? -1)
        }
        for (here, group) in parting {
            var fars: [Standing] = []
            for item in group where !fars.contains(item.far) { fars.append(item.far) }
            fars.sort { height(of: $0) < height(of: $1) }
            guard fars.count > 1 else { continue }
            for far in fars { reads.insert(far.shape) }
            for (arrow, far) in group {
                guard let index = fars.firstIndex(of: far) else { continue }
                answers[arrow]?.parting = ConnectionBundle.Fan(end: here.end, index: index, count: fars.count)
            }
        }

        // A connection to this shape as a whole: a row clear of the rows others end at on its side. Read from the boxes of the
        // shapes at its other ends (`reads`: when one moves, this is worked out again).
        let wholes = drawn.filter { item in
            (item.source == shape && item.sourcePart == nil) || (item.target == shape && item.targetPart == nil)
        }
        if !wholes.isEmpty, let entries = reader.entryRows(of: record), let box = record.box {
            // Which side of this shape an end at it is on (true: the right), by the one rule the connector draws by (Connections'
            // `PartSide`): rows sided together by the boxes at rest, else facing the other end; inside a container both are in, a
            // side with no room flipped; an end here at the shape as a whole, joined to a row of a shape whose span overlaps, comes
            // in at the side that row leaves by.
            func row(_ id: ShapeID, _ part: PartID?) -> CGRect? { part.flatMap { context.geometry(of: id)?.parts.frame($0)?.rect } }
            // The container a shape with parts is in, as the connector reads it (`Connectables`: none for a shape with no parts, where
            // a curve leaves no row). Read, so the shape holding it is `reads`: a database resized or moved works the sides out again.
            func container(of id: ShapeID) -> CGRect? {
                guard let geometry = context.geometry(of: id), !geometry.parts.isEmpty,
                      let holder = document[id]?.container, let record = document[holder],
                      registry.containingKinds.contains(record.kind), !record.isOpaque else { return nil }
                reads.insert(holder)
                return context.geometry(of: holder)?.bounds
            }
            func side(here part: PartID?, toward far: ShapeID, farPart: PartID?) -> Bool {
                reads.insert(far)
                guard let other = document[far]?.box else { return true }
                let shared = container(of: shape).flatMap { mine in container(of: far).flatMap { $0 == mine ? mine : nil } }
                let hereRow = row(shape, part), farRow = row(far, farPart)
                // Aimed at the far end as the connector aims: a row's middle, else the middle of the shape it is bound to as a whole
                // (its handle, on its bounds as laid out now).
                let farX = farRow?.midX ?? context.geometry(of: far)?.bounds.midX ?? other.midX
                if let hereRow {
                    let drawn = PartSide.drawn(start: (hereRow, box, hereRow.midX), end: (farRow, other, farX), container: shared)
                    return drawn.start != .left
                }
                let farSide = farRow.flatMap { PartSide.drawn(start: ($0, other, $0.midX), end: (nil, box, box.midX), container: shared).start }
                if let entered = PartSide.entered(box, joinedTo: other, leavingBy: farSide) { return entered == .right }
                return other.midX >= box.midX
            }
            var taken: [Bool: Set<Int>] = [:]
            for item in drawn {
                if item.source == shape, item.sourcePart != nil, let line = item.start.line {
                    taken[side(here: item.sourcePart, toward: item.target, farPart: item.targetPart), default: []].insert(line)
                }
                if item.target == shape, item.targetPart != nil, let line = item.end.line {
                    taken[side(here: item.targetPart, toward: item.source, farPart: item.sourcePart), default: []].insert(line)
                }
            }
            for item in wholes {
                let far = item.source == shape ? item.target : item.source
                // Joined to a row of the other shape: sided with it, as Arrows comes in (`ArrowGeometry`).
                let farPart = item.source == shape ? item.targetPart : item.sourcePart
                guard let lines = taken[side(here: nil, toward: far, farPart: farPart)], !lines.isEmpty else { continue }
                reads.insert(far)
                let below = (document[far]?.box?.midY ?? .infinity) > box.midY
                guard let row = RowBundles.clear(entries, taken: lines, fromTheEnd: below) else { continue }
                let end: ConnectionBundle.End = item.target == shape && item.targetPart == nil ? .end : .start
                answers[item.arrow]?.entries[end] = row
            }
        }
        return Partial(answers: answers, bundles: bundles, reads: reads)
    }

    /// The row a line to a shape as a whole comes in at, clear of the lines in `taken` (other lines' ends on that side): the first,
    /// from the end the line comes from (`fromTheEnd`: the last row first), with no taken line beside it; else the first not taken.
    /// Nil where the kind's own entry (the first row) is clear already, or every line is taken.
    static func clear(_ entries: [(line: Int, row: PartID)], taken: Set<Int>, fromTheEnd: Bool) -> PartID? {
        func isClear(_ line: Int) -> Bool { !taken.contains(line) && !taken.contains(line - 1) && !taken.contains(line + 1) }
        if let first = entries.first, isClear(first.line) { return nil }
        let ordered = fromTheEnd ? Array(entries.reversed()) : entries
        if let clear = ordered.first(where: { isClear($0.line) }) { return clear.row }
        return ordered.first { !taken.contains($0.line) }?.row
    }
}

/// Reads where connections' ends are drawn on shapes written as lines: each shape's rows and the lines its fold shows, read once.
@MainActor
private struct StandingReader {
    /// The board the shapes are on.
    let document: CanvasDocument
    let context: ShapeContext
    let registry: Registry
    private var read: [ShapeID: (index: [PartID: Int], rows: [FoldRow], shown: RowsShown?)?] = [:]

    init(document: CanvasDocument, context: ShapeContext, registry: Registry) {
        self.document = document
        self.context = context
        self.registry = registry
    }

    private mutating func lines(of id: ShapeID) -> (index: [PartID: Int], rows: [FoldRow], shown: RowsShown?)? {
        if let known = read[id] { return known }
        var found: (index: [PartID: Int], rows: [FoldRow], shown: RowsShown?)?
        if let record = document[id], let kind = registry.lineRows(of: record.kind), let rows = kind.rows(record) {
            var index: [PartID: Int] = [:]
            for (at, row) in rows.enumerated() where index[row.id] == nil { index[row.id] = at }
            found = (index, rows, context.layoutInput(LineRowsLayout.shown, of: record))
        }
        read[id] = .some(found)
        return found
    }

    /// Where an end at `part` of `id` is drawn: whether a fold hides its row, and the fold's line standing for it then.
    mutating func standing(of id: ShapeID, part: PartID?) -> (standing: Standing, hidden: Bool, foldLine: PartAddress?) {
        guard let part, let lines = lines(of: id), let index = lines.index[part] else { return (.whole(id), false, nil) }
        guard let shown = lines.shown else { return (.line(id, index), false, nil) }
        let line = shown.line(standingFor: index)
        let hidden = !shown.isShown(index)
        let header = hidden ? shown.row(atLine: line).map { PartAddress(id, part: lines.rows[$0].id) } : nil
        return (.line(id, line), hidden, hidden ? header ?? PartAddress(id, part: nil) : nil)
    }

    /// The lines of a shape a connection to it as a whole may come in at, each with the row drawn there: its rows shown, by line.
    mutating func entryRows(of record: AnyShapeRecord) -> [(line: Int, row: PartID)]? {
        guard let lines = lines(of: record.id), !lines.rows.isEmpty else { return nil }
        guard let shown = lines.shown else { return lines.rows.enumerated().map { ($0.offset, $0.element.id) } }
        return shown.lines.indices.compactMap { line in shown.row(atLine: line).map { (line, lines.rows[$0].id) } }
    }
}

extension RowBundles: EditorService {
    /// A shape written as lines changed (its rows), or a shape moved that a connection's entry row was read from: what its
    /// connections stand at may have moved. A commit that reached other boards (an agent's `--on`) drops what is read of them.
    func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        guard !states.isEmpty else { return }
        if changes.replacedDocument { return rebuildLater() }
        forget(changes.boardsReached)
        mark(changes.changed.union(changes.added).union(changes.removed))
    }

    /// Another board shown, or another file: read afresh as it is first asked.
    func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        states = [:]
    }
}

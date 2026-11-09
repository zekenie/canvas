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
// - A connection to a shape written as lines as a whole comes in at the row clearest of the rows other connections end at
//   (nil where none do: the kind's own entry), on the side of the shape nearer its other end where two are as clear.

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

/// The connections at shapes written as lines, and how each is drawn among those sharing its path.
@MainActor
final class RowBundles {
    unowned let editor: CanvasEditor
    private var following: TopologyFollowing?
    /// Each shape written as lines worked out, with what it says of each connection at it, and the bundles it found, each
    /// lead's connections, the lead first.
    private var partials: [ShapeID: Partial] = [:]
    private struct Partial {
        var answers: [ShapeID: ConnectionBundle] = [:]
        var bundles: [ShapeID: [ShapeID]] = [:]
    }
    /// The shapes worked out that each connection is at.
    private var shapesOf: [ShapeID: [ShapeID]] = [:]
    /// Each connection's answer, its ends' partials joined; none for a connection drawn as ever.
    private var answers: [ShapeID: ConnectionBundle] = [:]
    /// Each bundle's connections, its lead first: what a press on any of them selects.
    private var bundles: [ShapeID: [ShapeID]] = [:]
    /// The shapes written as lines to work out again once the change being delivered has settled.
    private var dirty: Set<ShapeID> = []
    private var flushAsked = false
    /// Whether the board shown has been read: until it is, the first ask reads it.
    private var built = false

    init(editor: CanvasEditor) {
        self.editor = editor
        following = editor.topology?.follow { [weak self] change in self?.heard(change) }
        // A fold, a peek, editing begun or ended: what a shape's lines show changed.
        editor.rowFolds?.whenLinesChange { [weak self] ids in self?.mark(ids) }
    }

    // MARK: Asking

    /// The answer for a connection as `reading` lays it out: mid-transaction, the committed one unless the transaction changed it.
    func answer(for record: AnyShapeRecord, in reading: LayoutReading) -> ConnectionBundle? {
        if !built { build() }
        guard !answers.isEmpty, let answer = answers[record.id] else { return nil }
        if !reading.isCommitted, reading.isChanged(record.id) { return nil }
        return answer
    }

    /// The shapes `id` is selected with: its bundle's, lead first; nil for a connection in none.
    func unit(of id: ShapeID) -> [ShapeID]? {
        guard !bundles.isEmpty, let answer = answers[id] else { return nil }
        switch answer.role {
        case .lead: return bundles[id]
        case .member(let lead): return bundles[lead]
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

    /// Works out again the shapes written as lines among `ids`, once what changed has settled.
    private func mark(_ ids: some Sequence<ShapeID>) {
        guard built else { return }
        let registry = editor.registry, document = editor.document
        var any = false
        for id in ids where !dirty.contains(id) {
            guard partials[id] != nil || document[id].map({ registry.lineRows(of: $0.kind) != nil }) == true else { continue }
            dirty.insert(id)
            any = true
        }
        guard any, !flushAsked else { return }
        flushAsked = true
        editor.onceSettled { [weak self] in self?.flush() }
    }

    private func rebuildLater() {
        guard built else { return }
        editor.onceSettled { [weak self] in
            guard let self else { return }
            let before = Set(answers.keys)
            built = false
            build()
            editor.connectionBundlesDidChange(before.union(answers.keys))
        }
    }

    /// Reads every shape written as lines on the board shown.
    private func build() {
        built = true
        partials = [:]
        shapesOf = [:]
        answers = [:]
        bundles = [:]
        dirty = []
        let registry = editor.registry
        let shapes = editor.document.shapes.lazy.filter { registry.lineRows(of: $0.kind) != nil }.map(\.id)
        let touched = work(Set(shapes))
        for id in touched { join(id) }
    }

    private func flush() {
        flushAsked = false
        guard built, !dirty.isEmpty else { return }
        var shapes = dirty
        dirty = []
        // The shapes at the other ends of their connections: what is drawn at one end of a path is read from both.
        let registry = editor.registry, document = editor.document
        for id in shapes {
            for arrow in partials[id].map({ Array($0.answers.keys) }) ?? [] { shapes.formUnion(shapesOf[arrow] ?? []) }
            for edge in connections(at: id) {
                for end in [edge.source, edge.target] where document[end].map({ registry.lineRows(of: $0.kind) != nil }) == true { shapes.insert(end) }
            }
        }
        let touched = work(shapes)
        var changed: Set<ShapeID> = []
        for id in touched where join(id) { changed.insert(id) }
        editor.connectionBundlesDidChange(changed)
    }

    // MARK: Working out

    /// The literal connections at `id`, each once.
    private func connections(at id: ShapeID) -> [Edge] {
        guard let topology = editor.topology, let kind = editor.registry.connectorKind else { return [] }
        var seen = Set<ShapeID>()
        let document = editor.document
        return topology.edges(of: id, .either, view: .literal).filter { edge in
            edge.isConnection && document[edge.carrier]?.kind == kind && seen.insert(edge.carrier).inserted
        }
    }

    /// Works `shapes` out again: each one's partial answers. Returns the connections whose answer may have moved.
    private func work(_ shapes: Set<ShapeID>) -> Set<ShapeID> {
        var touched: Set<ShapeID> = []
        for id in shapes {
            for arrow in partials[id].map({ Array($0.answers.keys) }) ?? [] {
                touched.insert(arrow)
                shapesOf[arrow]?.removeAll { $0 == id }
                if shapesOf[arrow]?.isEmpty == true { shapesOf[arrow] = nil }
            }
            let found = partial(of: id)
            partials[id] = found.answers.isEmpty ? nil : found
            for arrow in found.answers.keys {
                touched.insert(arrow)
                shapesOf[arrow, default: []].append(id)
            }
        }
        return touched
    }

    /// Joins a connection's answer from its ends' partials. Returns whether it changed.
    @discardableResult
    private func join(_ arrow: ShapeID) -> Bool {
        var joined: ConnectionBundle?
        var led: [ShapeID]?
        for shape in shapesOf[arrow] ?? [] {
            guard let partial = partials[shape], let part = partial.answers[arrow] else { continue }
            if led == nil, case .lead = part.role { led = partial.bundles[arrow] }
            guard var answer = joined else {
                joined = part
                continue
            }
            for fan in part.fans where answer.fan(at: fan.end) == nil { answer.fans.append(fan) }
            answer.entries.merge(part.entries) { first, _ in first }
            joined = answer
        }
        let answer = joined.flatMap { $0.isPlain ? nil : $0 }
        let before = answers[arrow]
        answers[arrow] = answer
        bundles[arrow] = led
        return before != answer
    }

    /// What `shape`, written as lines, says of each connection at it: bundles and slots among those sharing both drawn ends,
    /// fans among those with their other end at one place and theirs at different lines of it, and the row a connection to it as a
    /// whole comes in at.
    private func partial(of shape: ShapeID) -> Partial {
        let document = editor.document, registry = editor.registry, context = editor.shapeContext
        guard let record = document[shape], registry.lineRows(of: record.kind) != nil else { return Partial() }
        let edges = connections(at: shape)
        guard !edges.isEmpty else { return Partial() }
        var reader = StandingReader(context: context, registry: registry)

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

        // Sharing both drawn ends: a bundle of a channel where a fold hides an end, then a slot each for what is drawn.
        struct Path: Hashable { let start: Standing; let end: Standing }
        var paths: [Path: [Drawn]] = [:], pathOrder: [Path] = []
        for item in drawn {
            let path = Path(start: item.start, end: item.end)
            if paths[path] == nil { pathOrder.append(path) }
            paths[path, default: []].append(item)
        }
        var members = Set<ShapeID>()
        for path in pathOrder {
            guard let sharing = paths[path], sharing.count > 1 else { continue }
            var shown: [ShapeID] = []
            var channels: [EdgeTypeID: [Drawn]] = [:], channelOrder: [EdgeTypeID] = []
            for item in sharing where item.hidden {
                if channels[item.channel] == nil { channelOrder.append(item.channel) }
                channels[item.channel, default: []].append(item)
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
            for item in sharing where !members.contains(item.arrow) { shown.append(item.arrow) }
            guard shown.count > 1 else { continue }
            for (slot, arrow) in shown.enumerated() {
                answers[arrow]?.slot = slot
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

        // A connection to this shape as a whole: the row clearest of the rows others end at.
        let wholes = drawn.filter { item in
            (item.source == shape && item.sourcePart == nil) || (item.target == shape && item.targetPart == nil)
        }
        if !wholes.isEmpty, let entries = reader.entryRows(of: record) {
            var taken = Set<Int>()
            for item in drawn {
                if item.source == shape, item.sourcePart != nil, let line = item.start.line { taken.insert(line) }
                if item.target == shape, item.targetPart != nil, let line = item.end.line { taken.insert(line) }
            }
            if !taken.isEmpty {
                for item in wholes {
                    let far = item.source == shape ? item.target : item.source
                    let below = (document[far]?.box?.midY ?? .infinity) > (record.box?.midY ?? 0)
                    guard let row = RowBundles.clearest(entries, taken: taken, preferringLater: below) else { continue }
                    let end: ConnectionBundle.End = item.target == shape && item.targetPart == nil ? .end : .start
                    answers[item.arrow]?.entries[end] = row
                }
            }
        }
        return Partial(answers: answers, bundles: bundles)
    }

    /// The row of `entries` (each line's row, by line) farthest from every line in `taken`, the earlier of two as far unless
    /// `preferringLater`; nil where every line is taken.
    static func clearest(_ entries: [(line: Int, row: PartID)], taken: Set<Int>, preferringLater: Bool) -> PartID? {
        var best: (row: PartID, distance: Int)?
        let ordered = preferringLater ? Array(entries.reversed()) : entries
        for entry in ordered where !taken.contains(entry.line) {
            let distance = taken.map { abs($0 - entry.line) }.min() ?? Int.max
            if best == nil || distance > best!.distance { best = (entry.row, distance) }
        }
        return best?.row
    }
}

/// Reads where connections' ends are drawn on shapes written as lines: each shape's rows and the lines its fold shows, read once.
@MainActor
private struct StandingReader {
    let context: ShapeContext
    let registry: Registry
    private var read: [ShapeID: (index: [PartID: Int], rows: [FoldRow], shown: RowsShown?)?] = [:]

    init(context: ShapeContext, registry: Registry) {
        self.context = context
        self.registry = registry
    }

    private mutating func lines(of id: ShapeID) -> (index: [PartID: Int], rows: [FoldRow], shown: RowsShown?)? {
        if let known = read[id] { return known }
        var found: (index: [PartID: Int], rows: [FoldRow], shown: RowsShown?)?
        if let record = context.shape(id), let kind = registry.lineRows(of: record.kind), let rows = kind.rows(record) {
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
    /// A shape written as lines changed (its rows): what its connections stand at may have moved.
    func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        guard built else { return }
        if changes.replacedDocument { return rebuildLater() }
        mark(changes.changed.union(changes.added).union(changes.removed))
    }

    /// Another board shown, or another file: read afresh as it is first asked.
    func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        guard built else { return }
        built = false
        partials = [:]
        shapesOf = [:]
        answers = [:]
        bundles = [:]
    }
}

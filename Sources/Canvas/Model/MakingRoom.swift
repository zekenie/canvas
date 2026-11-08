import CoreGraphics
import Geometry

// Making room below a shape that grows (`MakesRoomAsItGrows`: a table gaining a row): a best effort, never a layout
// engine. When a step writes a shape of such a kind taller at rest, each shape below it in its container (or on the
// board) that its new bottom now reaches moves down by as much as its bottom went down, so the gap it had stays, and
// pushes what it reaches in turn, so a column moves down together. A container whose members the push takes past its
// bottom grows to hold them, and pushes in its own container the same way. Where it stops, the person takes over:
// read-only shapes never move and push nothing, a read-only container doesn't grow, a step moves at most
// `Style.roomMoves` shapes, shrinking pulls nothing up, and only what a step writes pushes (a fold, an editing view's
// waiting line, are views). Only down, only by the growth, never sideways.
extension Transaction {
    /// Makes room below the shapes this transaction grew, so far, of the kinds that make room as they grow
    /// (`MakesRoomAsItGrows`): `editor.transact` runs it as the body finishes, before the commit, so the growth and the
    /// moves are one step under the step's own name; a body that reports what moved (`canvas draw`) runs it first and
    /// reads `madeRoom`. Each growth makes room once, however often it's asked.
    ///
    /// A shape grew when its frame at rest (laid out without the values plugins set for it while it's handled,
    /// `editor.setLayoutInput`) reaches lower than it did when the transaction began, or than when this last made
    /// room for it, a move of its box aside. Below it are the shapes in the same container (or on the board, with
    /// none) whose top was at or under its bottom and that overlap it across: each whose top its new bottom comes
    /// nearer than `Style.roomReach` moves down by as much as its bottom went down (the larger, if two reach it), and
    /// pushes what it reaches the same way. A shape this transaction put in or moved isn't pushed: the step put it
    /// where it meant to. A container whose members it took past its bottom (from inside it, less the gap) grows to
    /// hold them `Style.containerGap` inside, and pushes in its own container; innermost containers first.
    /// Read-only shapes stay, and push nothing; a read-only container doesn't grow; past `Style.roomMoves` shapes
    /// moved or grown, the rest stay. Returns what it moved this time, by how far: the shapes pushed, not what they
    /// carried (`translate` carries a container's contents, and arrows bound to them follow). O(the levels it pushes
    /// in), and nothing at all where nothing that makes room changed.
    @discardableResult
    public mutating func makeRoom() -> [ShapeID: CGPoint] {
        let kinds = registry.roomMakingKinds
        guard !kinds.isEmpty, didChange else { return [:] }
        let grown = changes.changed.filter { id in
            guard !changes.moved.contains(id), !changes.added.contains(id), let record = document[id] else { return false }
            return kinds.contains(record.kind) && record.box != nil && !record.isOpaque
        }
        guard !grown.isEmpty else { return [:] }
        // Their growth at rest, each from its baseline: one context over the board as it began, one as it is now.
        var sources: [ShapeID?: [ShapeID: Growth]] = [:]
        do {
            let before = restingShapes(over: startDocument, reading: { [startDocument, layout] in startDocument[$0] ?? layout?.shape($0) })
            let here = self
            let after = restingShapes(over: document, reading: { here.record(inFile: $0) })
            for id in grown.sorted(by: { $0.description < $1.description }) {
                guard let record = document[id], let origin = record.box?.origin, let now = after.frame(of: record) else { continue }
                let was: CGRect
                if let baseline = roomBaselines[id] {
                    was = baseline.frame.offsetBy(dx: origin.x - baseline.origin.x, dy: origin.y - baseline.origin.y)
                } else if let old = startDocument[id], let oldOrigin = old.box?.origin, let frame = before.frame(of: old) {
                    was = frame.offsetBy(dx: origin.x - oldOrigin.x, dy: origin.y - oldOrigin.y)
                } else {
                    continue
                }
                roomBaselines[id] = (origin, now)
                guard now.maxY > was.maxY + Self.roomEpsilon else { continue }
                sources[document.container(of: record, containingKinds: registry.containingKinds), default: [:]][id] = Growth(was: was, now: now)
            }
        }
        guard !sources.isEmpty else { return [:] }
        var pushed: [ShapeID: CGPoint] = [:], budget = Style.roomMoves
        // Innermost first: a container grown by what moved in it pushes at its own level after.
        while let level = sources.keys.max(by: { depth(of: $0) < depth(of: $1) }) {
            let growths = sources.removeValue(forKey: level)!
            let (moves, grownLevel) = makeRoom(in: level, for: growths, budget: &budget)
            for (id, delta) in moves { pushed[id, default: .zero].y += delta }
            if let level, let growth = grownLevel {
                let outer = document[level].flatMap { document.container(of: $0, containingKinds: registry.containingKinds) }
                sources[outer, default: [:]][level] = growth
            }
        }
        for (id, delta) in pushed {
            madeRoom[id, default: .zero].y += delta.y
            // What it pushed carries its baseline along, so it isn't taken for a move of its own.
            if let baseline = roomBaselines[id] { roomBaselines[id] = (baseline.origin + delta, baseline.frame.offsetBy(dx: 0, dy: delta.y)) }
        }
        return pushed
    }

    /// A shape's frame before and after it grew, in world units.
    struct Growth {
        var was: CGRect
        var now: CGRect
    }

    /// Below this, in world units, a bottom that went down didn't (a layout's rounding).
    static var roomEpsilon: CGFloat { 0.001 }

    /// How many containers a level is in: the board's is 0.
    private func depth(of level: ShapeID?) -> Int {
        guard let level else { return 0 }
        return 1 + document.containers(of: level, containingKinds: registry.containingKinds).count
    }

    /// The push at one level, the shapes in `level` (a container, or the board for nil), for `growths` there: what it
    /// moved down, by how far, and how much `level` grew to hold them, if it did. Each shape's frame is read once, as
    /// the transaction leaves it (a grown one's from its growth), and the moves are worked out top to bottom before any
    /// is made: a shape reaches only shapes whose tops are below its own, so one pass settles the column.
    private mutating func makeRoom(in level: ShapeID?, for growths: [ShapeID: Growth], budget: inout Int) -> (moves: [ShapeID: CGFloat], grew: Growth?) {
        let kinds = registry.containingKinds
        struct Node {
            let id: ShapeID
            let frame: CGRect
            /// How far its bottom went down by itself (a growth), before any push.
            let growth: CGFloat
            /// Whether it stays: read-only, or put in or moved by the step.
            let stays: Bool
        }
        var nodes: [Node] = []
        do {
            let context = shapes
            let members: [ShapeID]
            if let level {
                members = document.contents(of: level, containingKinds: kinds)
            } else {
                var top: [ShapeID] = []
                document.shapes.forEach { if $0.box != nil && document.container(of: $0, containingKinds: kinds) == nil { top.append($0.id) } }
                members = top
            }
            for id in members {
                guard let record = document[id], record.box != nil else { continue }
                if let growth = growths[id] {
                    nodes.append(Node(id: id, frame: growth.was, growth: growth.now.maxY - growth.was.maxY, stays: holds(record) || placedHere(record)))
                } else if let frame = context.frame(of: record) {
                    nodes.append(Node(id: id, frame: frame, growth: 0, stays: holds(record) || placedHere(record)))
                }
            }
        }
        nodes.sort { ($0.frame.minY, $0.id.description) < ($1.frame.minY, $1.id.description) }
        let tops = nodes.map(\.frame.minY)
        var push = [CGFloat](repeating: 0, count: nodes.count)
        let reach = Style.roomReach
        for (index, node) in nodes.enumerated() {
            let down = node.growth + push[index]
            guard down > Self.roomEpsilon else { continue }
            // The shapes whose tops are from its old bottom to short of its new bottom and the reach: found by halves.
            var low = 0, high = tops.count
            while low < high {
                let middle = (low + high) / 2
                if tops[middle] < node.frame.maxY - Self.roomEpsilon { low = middle + 1 } else { high = middle }
            }
            var other = low
            while other < nodes.count, tops[other] < node.frame.maxY + down + reach {
                defer { other += 1 }
                let below = nodes[other]
                guard other != index, !below.stays, push[other] < down,
                      min(node.frame.maxX, below.frame.maxX) - max(node.frame.minX, below.frame.minX) > 0 else { continue }
                if push[other] == 0 {
                    guard budget > 0 else { continue }
                    budget -= 1
                }
                push[other] = down
            }
        }
        var moves: [ShapeID: CGFloat] = [:]
        var byDelta: [CGFloat: Set<ShapeID>] = [:]
        for (index, node) in nodes.enumerated() where push[index] > 0 {
            moves[node.id] = push[index]
            byDelta[push[index], default: []].insert(node.id)
        }
        for (delta, ids) in byDelta.sorted(by: { $0.key < $1.key }) { translate(ids, by: CGPoint(x: 0, y: delta)) }
        // The container grows to hold what went down in it, from inside it, the gap inside its edge.
        guard let level, let holder = document[level], let edge = holder.box, !holds(holder), budget > 0 else { return (moves, nil) }
        var needed = edge.maxY
        for (index, node) in nodes.enumerated() {
            let down = node.growth + push[index]
            guard down > Self.roomEpsilon, node.frame.maxY <= edge.maxY + Self.roomEpsilon else { continue }
            needed = max(needed, node.frame.maxY + down + Style.containerGap)
        }
        guard needed > edge.maxY + Self.roomEpsilon else { return (moves, nil) }
        update(level) { $0.box?.size.height += needed - edge.maxY }
        guard let grownEdge = document[level]?.box, grownEdge.maxY > edge.maxY else { return (moves, nil) }
        budget -= 1
        return (moves, Growth(was: edge, now: grownEdge))
    }

    /// Whether this transaction put the shape in, or moved its box (other than by making room): where the step put it.
    private func placedHere(_ record: AnyShapeRecord) -> Bool {
        guard changes.changed.contains(record.id) || changes.added.contains(record.id) else { return false }
        guard let old = startDocument[record.id]?.box?.origin, let now = record.box?.origin else { return true }
        return now - (madeRoom[record.id] ?? .zero) != old
    }

    /// Geometry lookups over `document`, a board as this transaction began or leaves it, laid out at rest: with no
    /// value a plugin set for a shape (`editor.setLayoutInput`: what it shows while it's handled), and none of the sizes
    /// the editor keeps (those are laid out with them); what a provider answers (`registrar.layoutInput`) counts.
    /// `reading` is a shape on any board of the file, as that context reads the file.
    private func restingShapes(over document: CanvasDocument, reading: @escaping @MainActor (ShapeID) -> AnyShapeRecord?) -> ShapeContext {
        guard let layout else { return ShapeContext(document: document, registry: registry, camera: camera) }
        let here = self
        let source = LayoutSource(inputs: layout.inputs, sizes: layout.sizes, lend: layout.lend, shape: reading,
                                  board: { here.board(containing: $0) ?? layout.board($0) }, fileValues: { here.fileValues },
                                  isChanged: { _ in true }, writes: [], run: LayoutSource.nextRun())
        return ShapeContext(document: document, registry: registry, camera: camera, index: nil, layout: source)
    }
}

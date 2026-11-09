import CoreGraphics
import Geometry

// Making room below a shape that grows (`MakesRoomAsItGrows`: a table gaining a row): a best effort, never a layout
// engine. When a step writes a shape of such a kind taller at rest, each shape below it in its container (or on the
// board) that its new bottom now reaches moves down by as much as its bottom went down, so the gap it had stays, and
// pushes what it reaches in turn, so a column moves down together. A container whose members the push takes past its
// bottom grows to hold them, and pushes in its own container the same way. Where it stops, the person takes over:
// read-only shapes never move and push nothing, a read-only container doesn't grow, a step moves at most
// `Style.roomMoves` shapes, shrinking pulls nothing up, and only what a step writes pushes (a fold, an editing view's
// waiting line and width, are views). Only down, only by the growth, never sideways.
extension Transaction {
    /// Makes room below the shapes this transaction grew, so far, of the kinds that make room as they grow
    /// (`MakesRoomAsItGrows`): `editor.transact` runs it as the body finishes, before the commit, so the growth and the
    /// moves are one step under the step's own name; a body that reports what moved (`canvas draw`) runs it first and
    /// reads `madeRoom`. Each growth makes room once, however often it's asked. Nothing when `makesRoom` is off.
    ///
    /// A shape grew when its frame at rest (laid out without the values plugins set for it while it's handled,
    /// `editor.setLayoutInput`, and as a provider answers at rest, `LayoutReading.isResting`) reaches lower than it did
    /// when the transaction began, or than when this last made room for it, a move of its box aside. A shape this
    /// transaction put in or moved (other than by making room) places itself and grows nothing. Below a grown shape are
    /// the shapes in the same container (or on the board, with none) whose top was at or under its old bottom and that
    /// overlap it across (its widest, before and after): each whose top its new bottom comes nearer than
    /// `Style.roomReach` moves down by as much as its bottom went down (the larger, if two reach it), and pushes what
    /// it reaches the same way; one the step put in or moved too, if it comes to that, but one it placed against the growth
    /// already (`placedAgainstGrowth`) only by what pushed the shape above it. A container whose members it took
    /// past its bottom (from inside it, less the gap) grows to hold them `Style.containerGap` inside, and pushes in its
    /// own container; innermost containers first. Read-only shapes stay, and push nothing; a read-only container
    /// doesn't grow; past `Style.roomMoves` shapes moved or grown, the rest stay. Returns what it moved this time, by
    /// how far: the shapes pushed, not what they carried (`translate` carries a container's contents, and arrows bound
    /// to them follow). O(the shapes it reaches) on the board shown once the editor keeps its index (the spatial grid
    /// finds them), else O(the level); nothing at all where nothing that makes room changed.
    @discardableResult
    public mutating func makeRoom() -> [ShapeID: CGPoint] {
        let kinds = registry.roomMakingKinds
        guard makesRoom, !kinds.isEmpty, didChange else { return [:] }
        let grown = changes.changed.filter { id in
            guard !changes.moved.contains(id), !changes.added.contains(id), let record = document[id] else { return false }
            return kinds.contains(record.kind) && record.box != nil && !record.isOpaque && !placedHere(record)
        }
        guard !grown.isEmpty else { return [:] }
        // Their growth at rest, each from its baseline: one context over the board as it began, one as it is now.
        var sources: [ShapeID?: [ShapeID: Growth]] = [:]
        do {
            let before = restingShapes(over: startDocument, reading: { [startDocument, layout] in startDocument[$0] ?? layout?.shape($0) })
            let here = self
            let after = restingShapes(over: document, reading: { here.record(inFile: $0) }, writes: writes)
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
                let keep = (registry.definition(for: record.kind) as? any MakesRoomAsItGrows)?.roomKeptBelow ?? 0
                sources[document.container(of: record, containingKinds: registry.containingKinds), default: [:]][id] = Growth(was: was, now: now, keep: keep)
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

    /// How far making room moved a shape, in world units: the push it was given and the pushes of the containers that
    /// carried it. Zero for a shape it didn't move.
    public func roomShift(of id: ShapeID) -> CGPoint {
        var shift = madeRoom[id] ?? .zero
        for holder in document.containers(of: id, containingKinds: registry.containingKinds) { shift.y += madeRoom[holder]?.y ?? 0 }
        return shift
    }

    /// A shape at a level of the push: its stored record, the frame it is pushed from, and how far it reaches across.
    fileprivate struct RoomNode {
        let record: AnyShapeRecord
        let frame: CGRect
        /// Across: the grown shape's widest, before and after.
        let minX: CGFloat
        let maxX: CGFloat
        /// How far its bottom went down by itself (a growth), before any push.
        let growth: CGFloat
        /// The room it keeps clear below its new bottom as it grows (`Growth.keep`).
        var keep: CGFloat = 0
        /// Where it is in the stack: of two at one height, the one behind first.
        let order: Int
    }

    /// What the push at one level keeps as it goes, in one place the helpers share: the nodes made, the members of the level
    /// (built once, in the order of their tops), the shapes the step wrote, and the queue of shapes that push.
    @MainActor fileprivate final class RoomWork {
        var made: [ShapeID: RoomNode?] = [:]
        var members: [RoomNode] = []
        var membersBuilt = false
        var written: [RoomNode] = []
        var writtenBuilt = false
        var queue: [RoomNode] = []
        var queued: Set<ShapeID> = []
    }

    /// A shape's frame before and after it grew, in world units.
    struct Growth {
        var was: CGRect
        var now: CGRect
        /// The room its kind keeps clear below its new bottom (`MakesRoomAsItGrows.roomKeptBelow`); none for a container grown.
        var keep: CGFloat = 0
    }

    /// Below this, in world units, a bottom that went down didn't (a layout's rounding).
    static var roomEpsilon: CGFloat { 0.001 }

    /// How many containers a level is in: the board's is 0.
    private func depth(of level: ShapeID?) -> Int {
        guard let level else { return 0 }
        return 1 + document.containers(of: level, containingKinds: registry.containingKinds).count
    }

    /// The push at one level, the shapes in `level` (a container, or the board for nil), for `growths` there: what it
    /// moved down, by how far, and how much `level` grew to hold them, if it did. Worked out from the top: the grown
    /// shapes, the shapes their bottoms reach, those pushed in turn, each taken in order of its top, so a shape's push
    /// is the largest that reaches it by the time it pushes; the moves are made after, all at once. In a container each
    /// member is read once; on the board shown, with the editor's index kept, only the shapes in the band a shape
    /// reaches (the index's grid finds them) and those the step wrote.
    private mutating func makeRoom(in level: ShapeID?, for growths: [ShapeID: Growth], budget: inout Int) -> (moves: [ShapeID: CGFloat], grew: Growth?) {
        let kinds = registry.containingKinds
        let reach = Style.roomReach, epsilon = Self.roomEpsilon
        var push: [ShapeID: CGFloat] = [:]
        var processed: [(node: RoomNode, down: CGFloat)] = []
        do {
            let context = shapes
            let document = document
            let work = RoomWork()
            func node(_ record: AnyShapeRecord) -> RoomNode? {
                if let known = work.made[record.id] { return known }
                var node: RoomNode?
                if record.box != nil, let order = document.index(of: record.id) {
                    if let growth = growths[record.id] {
                        node = RoomNode(record: record, frame: growth.was, minX: min(growth.was.minX, growth.now.minX), maxX: max(growth.was.maxX, growth.now.maxX),
                                        growth: growth.now.maxY - growth.was.maxY, keep: growth.keep, order: order)
                    } else if let frame = context.frame(of: record) {
                        node = RoomNode(record: record, frame: frame, minX: frame.minX, maxX: frame.maxX, growth: 0, order: order)
                    }
                }
                work.made[record.id] = .some(node)
                return node
            }
            // The shapes with a top from `low` to short of `high`, from the members of the level: found by halves in a
            // container's, whose members are read once; by the index's grid on the board shown, with those written by this step.
            func buildMembers() {
                guard !work.membersBuilt else { return }
                work.membersBuilt = true
                if let level {
                    for id in document.contents(of: level, containingKinds: kinds) { if let record = document[id], let n = node(record) { work.members.append(n) } }
                } else {
                    document.shapes.forEach { if document.container(of: $0, containingKinds: kinds) == nil, let n = node($0) { work.members.append(n) } }
                }
                work.members.sort { ($0.frame.minY, $0.order) < ($1.frame.minY, $1.order) }
            }
            let layout = layout, board = board, changes = changes, madeKeys = Array(madeRoom.keys)
            func candidates(from low: CGFloat, to high: CGFloat, across: ClosedRange<CGFloat>) -> [RoomNode] {
                // The board shown, with the editor's index kept: the shapes it finds in the band, and those this step
                // wrote (it hasn't heard of them, or heard them where they were).
                if level == nil, !work.membersBuilt,
                   let near = layout?.nearby?(board, CGRect(x: across.lowerBound, y: low, width: max(across.upperBound - across.lowerBound, 1), height: max(high - low, 1))) {
                    if !work.writtenBuilt {
                        work.writtenBuilt = true
                        for id in changes.changed.union(changes.added).union(madeKeys) {
                            if let record = document[id], document.container(of: record, containingKinds: kinds) == nil, let n = node(record) { work.written.append(n) }
                        }
                    }
                    var found: [RoomNode] = []
                    var seen: Set<ShapeID> = []
                    for id in near where seen.insert(id).inserted {
                        guard let record = document[id], document.container(of: record, containingKinds: kinds) == nil, let n = node(record) else { continue }
                        found.append(n)
                    }
                    for n in work.written where seen.insert(n.record.id).inserted { found.append(n) }
                    return found.filter { $0.frame.minY >= low && $0.frame.minY < high }
                }
                buildMembers()
                var start = 0, end = work.members.count
                while start < end {
                    let middle = (start + end) / 2
                    if work.members[middle].frame.minY < low { start = middle + 1 } else { end = middle }
                }
                var found: [RoomNode] = []
                var index = start
                while index < work.members.count, work.members[index].frame.minY < high {
                    found.append(work.members[index])
                    index += 1
                }
                return found
            }
            // The queue of shapes that push, by top; a shape is queued once, when it first is reached.
            func enqueue(_ node: RoomNode) {
                guard work.queued.insert(node.record.id).inserted else { return }
                var start = 0, end = work.queue.count
                while start < end {
                    let middle = (start + end) / 2
                    if (work.queue[middle].frame.minY, work.queue[middle].order) > (node.frame.minY, node.order) { start = middle + 1 } else { end = middle }
                }
                work.queue.insert(node, at: start)
            }
            // Descending by top, so the next to push is the last.
            for id in growths.keys { if let record = document[id], let n = node(record) { enqueue(n) } }
            var stays: [ShapeID: Bool] = [:]
            var done: Set<ShapeID> = []
            while let current = work.queue.popLast() {
                let id = current.record.id
                done.insert(id)
                let down = current.growth + (push[id] ?? 0)
                guard down > epsilon else { continue }
                processed.append((current, down))
                let low = current.frame.maxY - epsilon, high = current.frame.maxY + down + max(reach, current.keep)
                for other in candidates(from: low, to: high, across: current.minX...current.maxX) {
                    let otherID = other.record.id
                    // Placed against the growth already (draw's `below`): moved only by what pushed the shape above it. Else by the
                    // growth, and further where the grown shape keeps room below it that the gap left is short of.
                    let down = placedAgainstGrowth.contains(otherID)
                        ? (push[id] ?? 0) : max(down, current.frame.maxY + down + current.keep - other.frame.minY)
                    guard down > epsilon, otherID != id, !done.contains(otherID), (push[otherID] ?? 0) < down,
                          min(current.maxX, other.maxX) - max(current.minX, other.minX) > 0 else { continue }
                    if stays[otherID] == nil { stays[otherID] = holds(other.record) }
                    guard stays[otherID] == false else { continue }
                    if push[otherID] == nil {
                        guard budget > 0 else { continue }
                        budget -= 1
                    }
                    push[otherID] = down
                    enqueue(other)
                }
            }
        }
        var moves: [ShapeID: CGFloat] = [:]
        var byDelta: [CGFloat: Set<ShapeID>] = [:]
        for (id, delta) in push where delta > 0 {
            moves[id] = delta
            byDelta[delta, default: []].insert(id)
        }
        for (delta, ids) in byDelta.sorted(by: { $0.key < $1.key }) { translate(ids, by: CGPoint(x: 0, y: delta)) }
        // The container grows to hold what went down in it, from inside it, the gap inside its edge.
        guard let level, let holder = document[level], let edge = holder.box, !holds(holder), budget > 0 else { return (moves, nil) }
        var needed = edge.maxY
        for (node, down) in processed where node.frame.maxY <= edge.maxY + epsilon {
            needed = max(needed, node.frame.maxY + down + Style.containerGap)
        }
        guard needed > edge.maxY + epsilon else { return (moves, nil) }
        update(level) { $0.box?.size.height += needed - edge.maxY }
        guard let grownEdge = document[level]?.box, grownEdge.maxY > edge.maxY else { return (moves, nil) }
        budget -= 1
        return (moves, Growth(was: edge, now: grownEdge))
    }

    /// Whether this transaction put the shape in, or moved its box (other than by making room): where the step put it.
    private func placedHere(_ record: AnyShapeRecord) -> Bool {
        if placedElsewhere.contains(record.id) { return true }
        guard changes.changed.contains(record.id) || changes.added.contains(record.id) else { return false }
        guard let old = startDocument[record.id]?.box?.origin, let now = record.box?.origin else { return true }
        return now - roomShift(of: record.id) != old
    }

    /// Geometry lookups over `document`, a board as this transaction began or leaves it, laid out at rest: with no
    /// value a plugin set for a shape (`editor.setLayoutInput`: what it shows while it's handled), and none of the sizes
    /// the editor keeps (those are laid out with them); what a provider answers (`registrar.layoutInput`) counts.
    /// `reading` is a shape on any board of the file, as that context reads the file.
    /// `writes`: what the transaction wrote, for the board as it leaves it (`LayoutReading.changes`: a provider that answers from
    /// what a service keeps of the committed file reads what the step wrote besides, as a folded table's marks read a key the step
    /// drew); none for the board as it began.
    private func restingShapes(over document: CanvasDocument, reading: @escaping @MainActor (ShapeID) -> AnyShapeRecord?,
                               writes: [ShapeID] = []) -> ShapeContext {
        guard let layout else { return ShapeContext(document: document, registry: registry, camera: camera) }
        let here = self
        let source = LayoutSource(inputs: layout.inputs, sizes: layout.sizes, lend: layout.lend, shape: reading,
                                  board: { here.board(containing: $0) ?? layout.board($0) }, fileValues: { here.fileValues },
                                  isChanged: { _ in true }, writes: writes, run: LayoutSource.nextRun(), isResting: true)
        return ShapeContext(document: document, registry: registry, camera: camera, index: nil, layout: source)
    }
}

import CoreGraphics
import Geometry

// How boxes are placed, modified from reladraw's resolve and constrain (THIRD_PARTY_NOTICES.md).
//
// Every placement becomes the same kind of fact, one per axis: `pos[to] ≥ pos[from] + weight`, a
// box at least so far along from another. The nodes are the board, O, at 0 (every box that stays
// put is O plus a constant), and one per free box, its top-left. Each solve is from scratch:
//
// 1. lo: the longest path from O. A box O reaches sits against the furthest of its lower bounds,
//    as close as its placements allow. A loop that asks for more room each time round is `no_room`,
//    quoting the placements on it.
// 2. Until nothing changes: a box O doesn't reach, but that reaches one with a position, goes as
//    far along as its upper bounds let it (hi, a shortest path back), which is where `left of`
//    and `above` leave a box; then the longest path again, from those too, so a box placed below
//    one of them follows it. Nothing is ever pinned: where a box sits is a rule, not a constraint.
// 3. A box still without a position on an axis is tied to nothing there.
//
// Around that: region alignments (a placement against boxes that move apart, measured on a solve,
// in rounds: one waits for those of what it lines up with), then separation rounds (the first
// overlapping pair in a fixed order, pushed apart along what the placements already say, one pair
// a round, each pair once, and every box that moves reported), repeated until a pass separates
// nothing; and one drawing with nothing to hang on, solved alone and put where the view is clear.
// An obstacle a restated box takes along (a container's contents) is part of that box: met where
// that box puts it, and kept clear of by a bound against that box's node, not the board's.

extension LayoutProblem {
    /// Places every free box, or says why they can't all go where the script says: the first
    /// error, since one mistake here makes others.
    public func solve() throws(ScriptError) -> LayoutSolution {
        var solver = try Solver(self)
        return try solver.solve()
    }
}

/// One inequality on one axis: `pos[to] ≥ pos[from] + weight`.
struct Bound {
    var from: Int
    var to: Int
    var weight: CGFloat
    var why: Why
}

/// Where a bound came from, so a loop through it can be quoted in the script's words.
enum Why: Equatable {
    /// A placement: a direction, an alignment, `on`, or `inside`'s direction.
    case clause(box: Int, clause: Int)
    /// A lone direction centering the other axis on its targets.
    case centering(box: Int, clause: Int)
    /// A list's step, to this member from the one before.
    case list(box: Int, after: Int)
    /// A restated shape staying where it is on an axis nothing settles.
    case keep(box: Int)
    /// A region alignment, measured on a solve.
    case settled(box: Int, clause: Int)
    /// Keeping two boxes apart: `Solver.separations[index]`.
    case separation(Int)
    /// A drawing with nothing to hang on, solved with its unplaced shape at the origin.
    case anchor
}

/// Two of anything, one per axis.
struct PerAxis<Value> {
    var x: Value
    var y: Value

    init(_ x: Value, _ y: Value) {
        self.x = x
        self.y = y
    }

    subscript(axis: Axis) -> Value {
        get { axis == .x ? x : y }
        set { if axis == .x { x = newValue } else { y = newValue } }
    }
}

/// One axis solved.
struct AxisSolution {
    /// Each node's position; −∞ where nothing ties it to the board.
    var pos: [CGFloat]
    /// Whether it sits at an upper bound (placed `left of` or `above` something, with nothing
    /// holding it from the other side), rather than against its lower bounds.
    var upper: [Bool]
    /// How far along it may go at most, from what ties it to O; +∞ if nothing holds it back.
    var hi: [CGFloat]
}

/// How far two boxes share each axis.
struct Overlap {
    var x: CGFloat
    var y: CGFloat
    subscript(axis: Axis) -> CGFloat { axis == .x ? x : y }
}

struct Solver {
    let problem: LayoutProblem
    let count: Int
    /// Node 0 is the board; node i + 1 is free box i.
    var nodes: Int { count + 1 }
    func node(_ box: Int) -> Int { box + 1 }

    /// Each box's size as it's placed: a list's head is as tall as its list.
    var placed: [CGSize] = []
    var base = PerAxis<[Bound]>([], [])
    var pending: [Pending] = []
    /// What `inside` keeps a box within, checked after each solve rather than solved for: as a
    /// bound, the side a box isn't placed against would decide where it sits.
    var inside: [Inside] = []
    var lists: [List] = []
    var listOf: [Int?] = []
    /// Pairs of free boxes `inside` or `on` makes overlap.
    var exemptPairs: Set<Pair> = []
    /// For each free box, the obstacles it's `inside` or `on`.
    var exemptObstacles: [Set<Int>] = []
    /// Boxes that name a fixed box, or keep an axis where they are: tied to the board by what they say.
    var boardTied: [Bool] = []
    /// The one new shape with no placements.
    var anchor: Int?

    /// Whether each box is in the drawing with nothing to hang on, drawn where the view is clear.
    var inDrawing: [Bool] = []

    var separations: [Separation] = []
    var separated: Set<PairKey> = []
    /// Whether each obstacle asked about wholly holds another: the board doesn't move while a
    /// script is placed, so each is worked out once, unless a box takes obstacles along
    /// (`Placement.holders`).
    let holders = Holders()
    /// For each obstacle a restated box takes along (`Free.carries`), that box: where two take it
    /// along (a container moved in one that moves), the inner one, which takes along fewer. Every
    /// other box meets the obstacle where that box takes it.
    var carrierOf: [Int: Int] = [:]
    /// The boxes in `carrierOf`, in script order.
    var carriers: [Int] = []

    static let slack: CGFloat = 1e-6
    static let relax: CGFloat = 1e-9
    /// How many times bigger (in area) than what it wholly holds a zone must be: than a shape the
    /// box is placed against, or than the box itself, for a zone that holds other shapes too.
    static let zoneArea: CGFloat = 2

    final class Holders {
        var known: [Int: Bool] = [:]
    }

    /// One solve's free boxes as zones are asked about them: where each is (nil while it's nowhere
    /// yet), and, for each zone asked about, the boxes it counts as holding (`counted(by:in:)`),
    /// worked out once; and, while boxes take obstacles along, whether each obstacle asked about
    /// wholly holds another where this solve has them.
    final class Placement {
        let rects: [CGRect?]
        var counted: [Int: [Bool]] = [:]
        let holders = Holders()

        init(_ rects: [CGRect?]) {
            self.rects = rects
        }
    }

    struct Pending {
        var box: Int
        var clause: Int
        var axis: Axis
        var side: AlignSide
        var targets: [LayoutProblem.ResolvedTarget]
    }

    /// `inside T` (or `in "T"`, its holder): within T's bounds on one axis, the gap in from each side.
    struct Inside {
        var box: Int
        /// What keeps it there, as written: the placement (`inside "T" top-left`), or its holder's
        /// `in "T"`.
        var written: String
        var axis: Axis
        var target: LayoutProblem.ResolvedTarget
        var gap: CGFloat
    }

    struct List {
        var members: [Int]
        var step: CGFloat
        var height: CGFloat
    }

    struct Pair: Hashable {
        var a: Int
        var b: Int
        init(_ a: Int, _ b: Int) {
            self.a = min(a, b)
            self.b = max(a, b)
        }
    }

    enum PairKey: Hashable {
        case free(Pair)
        case obstacle(box: Int, id: Int)
    }

    struct Separation {
        var box: Int
        var other: LayoutProblem.Ref
        var axis: Axis
        /// The free boxes it moved, the pair's and any that went along with them.
        var moved: [Int] = []
    }

    struct Clash {
        var box: Int
        var other: LayoutProblem.Ref
        var otherRect: CGRect
        var overlap: Overlap
        /// For an obstacle a restated box takes along, that box: it's kept clear of where that box
        /// takes it.
        var carrier: Int?
    }

    // MARK: Building the bounds

    init(_ problem: LayoutProblem) throws(ScriptError) {
        self.problem = problem
        count = problem.free.count
        exemptObstacles = Array(repeating: [], count: count)
        boardTied = Array(repeating: false, count: count)
        inDrawing = Array(repeating: false, count: count)
        listOf = Array(repeating: nil, count: count)
        try validate()
        for (index, box) in problem.free.enumerated() where box.current != nil {
            for id in box.carries where carrierOf[id].map({ problem.free[$0].carries.count > box.carries.count }) ?? true {
                carrierOf[id] = index
            }
        }
        carriers = Set(carrierOf.values).sorted()

        let unplaced = problem.free.indices.filter { problem.free[$0].clauses.isEmpty && problem.free[$0].current == nil }
        if unplaced.count > 1 {
            throw ScriptError(line: problem.free[unplaced[1]].line, reason: .unplaced,
                              "exactly one new shape may say nothing about where it goes, but \(unplaced.count) do: \(listed(unplaced.map { problem.free[$0].name }))",
                              hint: "place all but one of them against something")
        }
        anchor = unplaced.first

        findLists()
        placed = problem.free.indices.map { index in
            let size = problem.free[index].size
            guard let list = listOf[index], lists[list].members[0] == index else { return size }
            return CGSize(width: size.width, height: lists[list].height)
        }
        for list in lists {
            for (previous, next) in zip(list.members, list.members.dropFirst()) {
                fix(.y, node(previous), node(next), problem.free[previous].size.height + list.step, .list(box: next, after: previous))
            }
        }
        for index in problem.free.indices { try build(index) }
    }

    func validate() throws(ScriptError) {
        for (index, box) in problem.free.enumerated() {
            func broken(_ what: String) -> ScriptError {
                ScriptError(line: box.line, reason: .internal, "\(box.name) can't be placed: \(what)")
            }
            guard box.size.width.isFinite, box.size.height.isFinite, box.size.width > 0, box.size.height > 0 else { throw broken("its size isn't a size") }
            if let current = box.current, !current.isFinite { throw broken("where it is isn't a place") }
            for clause in box.clauses {
                guard !clause.targets.isEmpty else { throw broken("\(clause.written) names nothing") }
                for target in clause.targets {
                    switch target.ref {
                    case .free(let other): guard problem.free.indices.contains(other) else { throw broken("\(clause.written) names a box there isn't") }
                    case .fixed(let other):
                        guard problem.fixed.indices.contains(other), problem.fixed[other].rect.isFinite else { throw broken("\(clause.written) names a box there isn't") }
                    case .obstacle: throw broken("\(clause.written) names an obstacle, not a box")
                    }
                    if let rect = target.partRect, !rect.isFinite { throw broken("\(clause.written) names a part that isn't anywhere") }
                    if target.ref == .free(index) {
                        throw ScriptError(line: box.line, reason: .circular, "\(box.name) is placed against itself", hint: "place it against another shape")
                    }
                }
                switch clause.relation {
                case .inside, .outside, .on:
                    guard clause.targets.count == 1 else { throw broken("\(clause.written) names more than one box") }
                    if clause.relation != .on, clause.targets[0].part?.inward == nil { throw broken("\(clause.written) names no side or corner") }
                case .direction, .level: break
                }
            }
            if let holder = box.holder {
                switch holder.ref {
                case .free(let other):
                    guard problem.free.indices.contains(other), other != index else { throw broken("\(holder.written) names a box there isn't") }
                case .fixed(let other):
                    guard problem.fixed.indices.contains(other), problem.fixed[other].rect.isFinite else { throw broken("\(holder.written) names a box there isn't") }
                case .obstacle:
                    throw broken("\(holder.written) names an obstacle, not a box")
                }
            }
        }
    }

    /// Boxes whose placements are written alike, in script order: two or more stack down the page
    /// as one, each the list's step below the one before.
    mutating func findLists() {
        var keys: [String] = []
        var members: [String: [Int]] = [:]
        for (index, box) in problem.free.enumerated() where !box.clauses.isEmpty && !box.overlapAllowed {
            let key = box.clauses.map(\.written).joined(separator: "\n")
            if members[key] == nil { keys.append(key) }
            members[key, default: []].append(index)
        }
        for key in keys {
            guard let list = members[key], list.count > 1 else { continue }
            let gaps = list.map { problem.free[$0].gap }
            let step = gaps.allSatisfy({ $0 != nil && $0 == gaps[0] }) ? gaps[0]!.value : LayoutProblem.listStep
            let height = list.reduce(0) { $0 + problem.free[$1].size.height } + step * CGFloat(list.count - 1)
            for member in list { listOf[member] = lists.count }
            lists.append(List(members: list, step: step, height: height))
        }
    }

    /// Whether a box's placements speak for this axis: a list's later members take their vertical
    /// from the list.
    func speaks(_ box: Int, _ axis: Axis) -> Bool {
        guard axis == .y, let list = listOf[box] else { return true }
        return lists[list].members[0] == box
    }

    mutating func build(_ index: Int) throws(ScriptError) {
        let box = problem.free[index]
        var spoken = PerAxis(false, false)
        for clause in box.clauses {
            switch clause.relation {
            case .level(let side): spoken[side.isHorizontal ? .x : .y] = true
            case .on: spoken = PerAxis(true, true)
            case .direction, .inside, .outside:
                guard let direction = clause.direction else { continue }
                if direction.horizontal != 0 { spoken.x = true }
                if direction.vertical != 0 { spoken.y = true }
            }
        }

        for (number, clause) in box.clauses.enumerated() {
            if clause.targets.contains(where: { if case .fixed = $0.ref { true } else { false } }) { boardTied[index] = true }
            let why = Why.clause(box: index, clause: number)
            switch clause.relation {
            case .level(let side):
                align(index, number, side.isHorizontal ? .x : .y, side, clause.targets, why)
            case .on:
                exempt(index, clause.targets[0])
                align(index, number, .x, .center, clause.targets, why)
                align(index, number, .y, .center, clause.targets, why)
            case .direction, .inside, .outside:
                guard let direction = clause.direction else { continue }
                let isInside = clause.relation == .inside
                for target in clause.targets {
                    let gap = gap(index, clause, target, inside: isInside)
                    let x = span(target, .x), y = span(target, .y)
                    if speaks(index, .x), direction.horizontal > 0 { add(.x, x.node, node(index), x.start + x.length + gap, why) }
                    if speaks(index, .x), direction.horizontal < 0 { add(.x, node(index), x.node, placed[index].width + gap - x.start, why) }
                    if speaks(index, .y), direction.vertical > 0 { add(.y, y.node, node(index), y.start + y.length + gap, why) }
                    if speaks(index, .y), direction.vertical < 0 { add(.y, node(index), y.node, placed[index].height + gap - y.start, why) }
                }
                if isInside {
                    let target = clause.targets[0]
                    exempt(index, target)
                    for axis in Axis.allCases where speaks(index, axis) {
                        inside.append(Inside(box: index, written: clause.written, axis: axis, target: target, gap: gap(index, clause, target, inside: true)))
                    }
                }
            }
        }
        // What holds it keeps it within, as `inside` does, wherever its placements put it there; it
        // names a shape on the board, as a placement against one does.
        if let holder = box.holder {
            let target = LayoutProblem.ResolvedTarget(holder.ref, written: holder.written)
            if case .fixed = holder.ref { boardTied[index] = true }
            exempt(index, target)
            for axis in Axis.allCases where speaks(index, axis) {
                inside.append(Inside(box: index, written: holder.written, axis: axis, target: target, gap: GapName.tight.value))
            }
        }
        // What goes with it is never in its way.
        exemptObstacles[index].formUnion(box.carries)

        // A lone direction also centers the axis nothing else speaks for; failing that, a restated
        // shape stays where it is on it, and a new one says nothing about it.
        for axis in Axis.allCases where !spoken[axis] && speaks(index, axis) {
            let offers = box.clauses.indices.filter { box.clauses[$0].direction != nil }
            func keep() {
                guard let current = box.current else { return }
                boardTied[index] = true
                fix(axis, 0, node(index), current.origin[axis], .keep(box: index))
            }
            guard let first = offers.first else {
                if box.current != nil { keep() } else if !box.clauses.isEmpty {
                    let targets = box.clauses[0].targets.map(\.written)
                    throw ScriptError(line: box.line, reason: .unplaced, "\(box.name) says nothing about where it sits \(axis.adverb)",
                                      hint: "add a placement that does, as \(example(for: axis, listed(targets)))")
                }
                continue
            }
            let named = { (clause: Int) in box.clauses[clause].targets.map { TargetKey(ref: $0.ref, part: $0.part) } }
            if let other = offers.first(where: { named($0) != named(first) }) {
                if box.current != nil {
                    keep()
                    continue
                }
                throw ScriptError(line: box.line, reason: .unplaced,
                                  "\(box.name) does not say where it sits \(axis.adverb): \(box.clauses[first].written) and \(box.clauses[other].written) would put it in different places",
                                  hint: "add a placement that does, as \(example(for: axis, listed(box.clauses[first].targets.map(\.written))))")
            }
            align(index, first, axis, .center, box.clauses[first].targets, .centering(box: index, clause: first))
        }
    }

    /// A placement that says where a box sits on an axis, against these targets, for a hint.
    func example(for axis: Axis, _ targets: String) -> String {
        axis == .x ? "left level with \(targets) or right of \(targets)" : "level with \(targets) or below \(targets)"
    }

    struct TargetKey: Equatable {
        var ref: LayoutProblem.Ref
        var part: Part?
    }

    /// A target's part on one axis: the node it moves with, where the part starts along the axis
    /// from that node, and how long it is.
    func span(_ target: LayoutProblem.ResolvedTarget, _ axis: Axis, whole: Bool = false) -> (node: Int, start: CGFloat, length: CGFloat) {
        let size: CGSize, origin: CGFloat, owner: Int
        switch target.ref {
        case .free(let box):
            size = problem.free[box].size
            origin = 0
            owner = node(box)
        case .fixed(let box):
            size = problem.fixed[box].rect.size
            origin = problem.fixed[box].rect.origin[axis]
            owner = 0
        case .obstacle:
            return (0, 0, 0)
        }
        let part = whole ? CGRect(origin: .zero, size: size)
            : target.partRect ?? target.part?.rect(in: size) ?? CGRect(origin: .zero, size: size)
        return (owner, origin + part.origin[axis], part.size[axis])
    }

    /// A placement's gap against one target: its bracket; `tight` inside; the larger of the box's
    /// `gap:` and the target's; `normal`.
    func gap(_ box: Int, _ clause: LayoutProblem.ResolvedClause, _ target: LayoutProblem.ResolvedTarget, inside: Bool) -> CGFloat {
        if let gap = clause.gap { return gap.value }
        if inside { return GapName.tight.value }
        var stated: [CGFloat] = []
        if let gap = problem.free[box].gap { stated.append(gap.value) }
        switch target.ref {
        case .free(let other): if let gap = problem.free[other].gap { stated.append(gap.value) }
        case .fixed(let other): if let gap = problem.fixed[other].gap { stated.append(gap.value) }
        case .obstacle: break
        }
        return stated.max() ?? GapName.normal.value
    }

    /// Lines a box up with its targets on one axis: exactly, when they all move together (or stay
    /// put); else once a solve says where the region they bound is.
    mutating func align(_ box: Int, _ clause: Int, _ axis: Axis, _ side: AlignSide, _ targets: [LayoutProblem.ResolvedTarget], _ why: Why) {
        guard speaks(box, axis) else { return }
        let spans = targets.map { span($0, axis) }
        guard spans.allSatisfy({ $0.node == spans[0].node }) else {
            pending.append(Pending(box: box, clause: clause, axis: axis, side: side, targets: targets))
            return
        }
        let start = spans.map { $0.start }.min()!, end = spans.map { $0.start + $0.length }.max()!
        fix(axis, spans[0].node, node(box), aligned(side, start: start, length: end - start, own: placed[box][axis]), why)
    }

    /// Where a box this long starts so its side meets the span's.
    func aligned(_ side: AlignSide, start: CGFloat, length: CGFloat, own: CGFloat) -> CGFloat {
        switch side {
        case .center: start + (length - own) / 2
        case .top, .left: start
        case .bottom, .right: start + length - own
        }
    }

    mutating func exempt(_ box: Int, _ target: LayoutProblem.ResolvedTarget) {
        switch target.ref {
        case .free(let other): exemptPairs.insert(Pair(box, other))
        case .fixed(let other): if let obstacle = problem.fixed[other].obstacle { exemptObstacles[box].insert(obstacle) }
        case .obstacle: break
        }
    }

    mutating func add(_ axis: Axis, _ from: Int, _ to: Int, _ weight: CGFloat, _ why: Why) {
        base[axis].append(Bound(from: from, to: to, weight: weight, why: why))
    }

    /// An exact distance: two bounds, opposite ways.
    mutating func fix(_ axis: Axis, _ from: Int, _ to: Int, _ distance: CGFloat, _ why: Why) {
        add(axis, from, to, distance, why)
        add(axis, to, from, -distance, why)
    }

    // MARK: Solving

    mutating func solve() throws(ScriptError) -> LayoutSolution {
        var rects = Array(repeating: CGRect.null, count: count)
        var pushes: [LayoutSolution.Push] = []
        guard count > 0 else { return LayoutSolution(rects: [], pushes: []) }
        let everyone = Array(0..<count)
        if let anchor, let cluster = pureCluster(of: anchor) {
            for box in cluster { inDrawing[box] = true }
            let rest = everyone.filter { !cluster.contains($0) }
            let tied = try run(rest, obstacles: true, anchored: nil)
            try checkTied(rest, tied.solution)
            for box in rest { rects[box] = rect(box, tied.solution) }
            let drawing = try run(cluster, obstacles: false, anchored: anchor)
            try checkTied(cluster, drawing.solution)
            let at = spot(for: cluster.map { (box: $0, rect: rect($0, drawing.solution)) }, clearOf: rest.map { rects[$0] },
                          among: Placement(rects.map { $0.isNull ? nil : $0 }))
            for box in cluster { rects[box] = rect(box, drawing.solution).offsetBy(dx: at.x, dy: at.y) }
            pushes = tied.pushes + drawing.pushes
        } else {
            let all = try run(everyone, obstacles: true, anchored: nil)
            try checkTied(everyone, all.solution)
            for box in everyone { rects[box] = rect(box, all.solution) }
            pushes = all.pushes
        }
        let placement = Placement(rects.map { $0.isNull ? nil : $0 })
        return LayoutSolution(rects: rects, pushes: pushes, zones: everyone.map { zones(of: $0, placement) })
    }

    /// The obstacles a box overlaps, where it's placed, that are zones for it, in stacking order:
    /// neither what it's `inside` or `on` nor in its way, but what it sits in.
    func zones(of box: Int, _ placement: Placement) -> [LayoutProblem.Obstacle] {
        guard let mine = placement.rects[box], mine.isFinite else { return [] }
        return obstacles(in: mine, placement).filter { obstacle in
            !exemptObstacles[box].contains(obstacle.id) && overlap(mine, obstacle.rect) != nil && isZone(obstacle, for: box, placement)
        }
    }

    /// The obstacles that meet `area` where `placement` has them, each once, in stacking order: a
    /// board shape where it is, and one a restated box takes along (`Free.carries`) moved as far as
    /// that box moves, or nowhere while that box is nowhere. With no box taking any along, it's
    /// the one question `problem.obstacles` answers; with some, one more for each.
    func obstacles(in area: CGRect, _ placement: Placement) -> [LayoutProblem.Obstacle] {
        var seen: Set<Int> = []
        var found = problem.obstacles(area).filter { carrierOf[$0.id] == nil && seen.insert($0.id).inserted }
        guard !carriers.isEmpty else { return found.sorted { $0.id < $1.id } }
        for carrier in carriers {
            guard let moved = offset(of: carrier, placement) else { continue }
            for obstacle in problem.obstacles(area.offsetBy(dx: -moved.x, dy: -moved.y))
            where carrierOf[obstacle.id] == carrier && seen.insert(obstacle.id).inserted {
                found.append(LayoutProblem.Obstacle(id: obstacle.id, rect: obstacle.rect.offsetBy(dx: moved.x, dy: moved.y)))
            }
        }
        return found.sorted { $0.id < $1.id }
    }

    /// How far a restated box is from where it is now in `placement`: how far what it takes along
    /// moves. Nil while it's nowhere.
    func offset(of box: Int, _ placement: Placement) -> CGPoint? {
        guard let rect = placement.rects[box], let current = problem.free[box].current else { return nil }
        return CGPoint(x: rect.minX - current.minX, y: rect.minY - current.minY)
    }

    /// Where an obstacle `obstacles(in:_:)` gave is now, before anything moves.
    func unmoved(_ obstacle: LayoutProblem.Obstacle, _ placement: Placement) -> CGRect {
        guard let carrier = carrierOf[obstacle.id], let moved = offset(of: carrier, placement) else { return obstacle.rect }
        return obstacle.rect.offsetBy(dx: -moved.x, dy: -moved.y)
    }

    func rect(_ box: Int, _ solution: PerAxis<AxisSolution>) -> CGRect {
        CGRect(origin: CGPoint(x: solution.x.pos[node(box)], y: solution.y.pos[node(box)]), size: problem.free[box].size)
    }

    /// Where a solve has the free boxes: nil for one it doesn't tie to the board.
    func placement(_ solution: PerAxis<AxisSolution>) -> Placement {
        Placement((0..<count).map { isTied($0, solution) ? rect($0, solution) : nil })
    }

    func isTied(_ box: Int, _ solution: PerAxis<AxisSolution>) -> Bool {
        solution.x.pos[node(box)] > -.infinity && solution.y.pos[node(box)] > -.infinity
    }

    /// The anchor's drawing, if nothing in it is tied to the board: the boxes placed against it,
    /// and against those, either way round (a list is placed together).
    func pureCluster(of anchor: Int) -> [Int]? {
        var neighbors = Array(repeating: [Int](), count: count)
        for (index, box) in problem.free.enumerated() {
            for target in box.clauses.flatMap(\.targets).map(\.ref) + (box.holder.map { [$0.ref] } ?? []) {
                if case .free(let other) = target {
                    neighbors[index].append(other)
                    neighbors[other].append(index)
                }
            }
        }
        for list in lists {
            for (previous, next) in zip(list.members, list.members.dropFirst()) {
                neighbors[previous].append(next)
                neighbors[next].append(previous)
            }
        }
        var member = Array(repeating: false, count: count)
        member[anchor] = true
        var queue = [anchor]
        while let box = queue.popLast() {
            for other in neighbors[box] where !member[other] {
                member[other] = true
                queue.append(other)
            }
        }
        let cluster = (0..<count).filter { member[$0] }
        return cluster.contains(where: { boardTied[$0] }) ? nil : cluster
    }

    /// Every box it names has a position on both axes, or says why not: the unplaced shape of a
    /// drawing tied to the board through what's placed against it first.
    func checkTied(_ boxes: [Int], _ solution: PerAxis<AxisSolution>) throws(ScriptError) {
        let order = boxes.filter { $0 == anchor } + boxes.filter { $0 != anchor }
        for box in order {
            for axis in Axis.allCases where solution[axis].pos[node(box)] == -.infinity {
                let free = problem.free[box]
                if box == anchor {
                    throw ScriptError(line: free.line, reason: .unplaced,
                                      "\(free.name) says nothing about where it sits \(axis.adverb), and nothing placed against it ties it to the board that way",
                                      hint: "place it, or leave everything placed against it unplaced too")
                }
                throw ScriptError(line: free.line, reason: .unanchored, "nothing ties \(free.name) to the board \(axis.adverb)",
                                  hint: "place it (or what it's placed against) against a shape on the board, or leave one shape unplaced to draw them in view")
            }
        }
    }

    /// Solves these boxes: the bounds they say, region alignments measured, then separation rounds
    /// until a pass adds none; with the anchor at the origin, for a drawing solved alone.
    mutating func run(_ boxes: [Int], obstacles: Bool, anchored: Int?) throws(ScriptError)
        -> (solution: PerAxis<AxisSolution>, pushes: [LayoutSolution.Push]) {
        var inRun = Array(repeating: false, count: nodes)
        inRun[0] = true
        for box in boxes { inRun[node(box)] = true }
        var kept = PerAxis(base.x.filter { inRun[$0.from] && inRun[$0.to] }, base.y.filter { inRun[$0.from] && inRun[$0.to] })
        if let anchored {
            for axis in Axis.allCases {
                kept[axis].append(Bound(from: 0, to: node(anchored), weight: 0, why: .anchor))
                kept[axis].append(Bound(from: node(anchored), to: 0, weight: 0, why: .anchor))
            }
        }
        let aligning = pending.filter { inRun[node($0.box)] }
        var moved: [LayoutSolution.Push] = []
        let within = inside.filter { inRun[node($0.box)] }
        var bounds = kept
        var solution: PerAxis<AxisSolution>
        while true {
            bounds = kept
            let unsettled = try solveAll(bounds)
            solution = try settle(aligning, &bounds, from: unsettled)
            try keepInside(within, solution)
            var added = false
            while let clash = firstClash(boxes, solution, obstacles: obstacles) {
                let (axis, bound) = try separate(clash, solution, bounds)
                kept[axis].append(bound)
                bounds[axis].append(bound)
                let before = solution
                solution = try solveAll(bounds)
                let found = pushes(clash, axis, boxes, before, solution)
                separations[separations.count - 1].moved = found.map(\.box)
                moved += found
                try keepInside(within, solution)
                added = true
            }
            if !added { break }
        }
        try confirm(aligning, solution)
        for index in moved.indices {
            moved[index].placementsHold = placementsHold(moved[index].box, moved[index].way.axis, solution, bounds)
        }
        return (solution, moved)
    }

    /// What one separation moved on its axis: each of the pair kept apart, past the other (or the
    /// obstacle); then, in script order, every other box that went along, past what the one of the
    /// pair that went its way was pushed past. A box is never moved without saying so.
    func pushes(_ clash: Clash, _ axis: Axis, _ boxes: [Int], _ before: PerAxis<AxisSolution>, _ after: PerAxis<AxisSolution>)
        -> [LayoutSolution.Push] {
        func way(_ box: Int) -> Direction? {
            let from = before[axis].pos[node(box)], to = after[axis].pos[node(box)]
            guard from.isFinite, to.isFinite, abs(to - from) > Self.slack else { return nil }
            return axis == .x ? (to > from ? .right : .left) : (to > from ? .below : .above)
        }
        var pair: [(box: Int, past: LayoutProblem.Ref)] = [(clash.box, clash.other)]
        if case .free(let other) = clash.other { pair.append((other, .free(clash.box))) }
        var pushes: [LayoutSolution.Push] = []
        for (box, past) in pair {
            if let way = way(box) { pushes.append(LayoutSolution.Push(box: box, past: past, way: way)) }
        }
        let pushed = pushes
        for box in boxes where !pair.contains(where: { $0.box == box }) {
            guard let way = way(box), let leader = pushed.first(where: { $0.way == way }) ?? pushed.first else { continue }
            pushes.append(LayoutSolution.Push(box: box, past: leader.past, way: way, along: leader.box))
        }
        return pushes
    }

    /// Whether each of a box's own placements on an axis holds as written in this solve: some bound
    /// it gives is tight (for a direction, against its furthest target; an alignment always is).
    func placementsHold(_ box: Int, _ axis: Axis, _ solution: PerAxis<AxisSolution>, _ bounds: PerAxis<[Bound]>) -> Bool {
        var holds: [Int: Bool] = [:]
        for bound in bounds[axis] {
            guard let clause = own(bound.why, box) else { continue }
            holds[clause] = holds[clause] == true || isTight(bound, solution[axis])
        }
        return holds.values.allSatisfy { $0 }
    }

    /// The placement of this box's that a bound comes from, if it's one of its own: a clause, its
    /// centering, or a region alignment of its, settled.
    func own(_ why: Why, _ box: Int) -> Int? {
        switch why {
        case .clause(box, let clause), .centering(box, let clause), .settled(box, let clause): clause
        default: nil
        }
    }

    /// Whether a bound holds with no room to spare: its two ends as close as it lets them be.
    func isTight(_ bound: Bound, _ solved: AxisSolution) -> Bool {
        let from = solved.pos[bound.from], to = solved.pos[bound.to]
        return from.isFinite && to.isFinite && to - from - bound.weight <= Self.slack
    }

    /// Solves both axes, or quotes the placements that leave no room.
    func solveAll(_ bounds: PerAxis<[Bound]>) throws(ScriptError) -> PerAxis<AxisSolution> {
        PerAxis(try solveAxis(bounds.x, .x), try solveAxis(bounds.y, .y))
    }

    func solveAxis(_ bounds: [Bound], _ axis: Axis) throws(ScriptError) -> AxisSolution {
        let nodes = nodes
        // A loop that asks for more room each time round, anywhere: every node starts at 0, as in
        // reladraw, so one that O doesn't reach is found too.
        var trial = Array(repeating: CGFloat(0), count: nodes)
        var cameFrom = Array(repeating: -1, count: nodes)
        for pass in 0...nodes {
            var last = -1
            for (index, bound) in bounds.enumerated() where trial[bound.from] + bound.weight > trial[bound.to] + Self.relax {
                trial[bound.to] = trial[bound.from] + bound.weight
                cameFrom[bound.to] = index
                last = bound.to
            }
            if last < 0 { break }
            if pass == nodes { throw noRoom(loop(from: last, cameFrom, bounds), bounds, axis) }
        }

        // lo: the longest path from O.
        var pos = Array(repeating: -CGFloat.infinity, count: nodes)
        pos[0] = 0
        func lengthen() {
            var changed = true
            while changed {
                changed = false
                for bound in bounds where bound.to != 0 && pos[bound.from] > -.infinity && pos[bound.from] + bound.weight > pos[bound.to] + Self.relax {
                    pos[bound.to] = pos[bound.from] + bound.weight
                    changed = true
                }
            }
        }
        lengthen()

        // Boxes O doesn't reach go as far along as their upper bounds let them, then what's placed
        // after them follows; until nothing more gets a position.
        var upper = Array(repeating: false, count: nodes)
        while true {
            var hi = Array(repeating: CGFloat.infinity, count: nodes)
            var changed = true
            while changed {
                changed = false
                for bound in bounds where pos[bound.from] == -.infinity {
                    let value = pos[bound.to] > -.infinity ? pos[bound.to] : hi[bound.to]
                    guard value < .infinity, value - bound.weight < hi[bound.from] - Self.relax else { continue }
                    hi[bound.from] = value - bound.weight
                    changed = true
                }
            }
            let reached = (0..<nodes).filter { pos[$0] == -.infinity && hi[$0] < .infinity }
            if reached.isEmpty { break }
            for node in reached {
                pos[node] = hi[node]
                upper[node] = true
            }
            lengthen()
        }

        // How far along each may go at most, from what ties it to O.
        var hi = Array(repeating: CGFloat.infinity, count: nodes)
        hi[0] = 0
        var changed = true
        while changed {
            changed = false
            for bound in bounds where bound.from != 0 && hi[bound.to] < .infinity && hi[bound.to] - bound.weight < hi[bound.from] - Self.relax {
                hi[bound.from] = hi[bound.to] - bound.weight
                changed = true
            }
        }
        return AxisSolution(pos: pos, upper: upper, hi: hi)
    }

    /// The bounds on a loop, in order round it, from a node that moved on the last pass.
    func loop(from start: Int, _ cameFrom: [Int], _ bounds: [Bound]) -> [Bound] {
        var at = start
        for _ in 0..<nodes where cameFrom[at] >= 0 { at = bounds[cameFrom[at]].from }
        var loop: [Bound] = []
        let first = at
        repeat {
            guard cameFrom[at] >= 0 else { break }
            let bound = bounds[cameFrom[at]]
            loop.append(bound)
            at = bound.from
        } while at != first && loop.count <= nodes
        return loop.reversed()
    }

    /// Every box `inside` another is still within it, the gap in from each side, or there's no room:
    /// naming what the box was kept clear of, and any other pair kept apart that moved it (a shape
    /// centered on it, kept clear of the zone they're drawn in, takes it along), unless it never fit.
    func keepInside(_ within: [Inside], _ solution: PerAxis<AxisSolution>) throws(ScriptError) {
        for entry in within {
            let axis = entry.axis, whole = span(entry.target, axis, whole: true)
            let at = solution[axis].pos[node(entry.box)], holder = solution[axis].pos[whole.node]
            guard at > -.infinity, holder > -.infinity else { continue }
            let start = holder + whole.start, end = start + whole.length
            guard at < start + entry.gap - Self.slack || at + placed[entry.box][axis] > end - entry.gap + Self.slack else { continue }
            let box = problem.free[entry.box]
            let holderName = name(entry.target.ref)
            var clear: [String] = [], apart: [String] = [], lines = [box.line]
            for separation in separations where separation.axis == axis && separation.moved.contains(entry.box) {
                if separation.box == entry.box || separation.other == .free(entry.box) {
                    let other = separation.box == entry.box ? separation.other : .free(separation.box)
                    if !clear.contains(name(other)) { clear.append(name(other)) }
                } else {
                    // Whichever of the two moved, named first: "N" kept clear of "Zone".
                    let (moved, still) = separation.moved.contains(separation.box) || separation.other.freeIndex == nil
                        ? (name(.free(separation.box)), name(separation.other)) : (name(separation.other), name(.free(separation.box)))
                    let pair = "\(moved) kept clear of \(still)"
                    if !apart.contains(pair) { apart.append(pair) }
                    lines.append(problem.free[separation.box].line)
                    if case .free(let other) = separation.other { lines.append(problem.free[other].line) }
                }
            }
            let fits = placed[entry.box][axis] + 2 * entry.gap <= whole.length + Self.slack
            // Only a shape can be made bigger: a script can't widen the view, or the board.
            let grows = if case .fixed(let holder) = entry.target.ref { problem.fixed[holder].word == nil } else { true }
            throw ScriptError(line: lines.max()!, reason: .noRoom,
                              "\(box.name) is \(entry.written), and there's no room left in \(holderName)"
                                  + (clear.isEmpty ? "" : " clear of \(listed(clear))")
                                  + (apart.isEmpty ? "" : "\(clear.isEmpty ? "" : ",") with \(listed(apart))"),
                              hint: fits && !(clear + apart).isEmpty ? "place it elsewhere, or say overlap: allow"
                                  : grows ? "make \(holderName) bigger, or this smaller" : "make this smaller, or place it elsewhere")
        }
    }

    // MARK: Region alignments

    /// Settles the region alignments in rounds, each measured on a solve once what it lines up with
    /// is where it'll be: first those whose targets wait on no other alignment on that axis, then
    /// those that waited on them, and so on. Alignments that wait on each other round a loop are
    /// measured together, and `confirm` says if one moved after. Returns the solve with them held.
    func settle(_ aligning: [Pending], _ bounds: inout PerAxis<[Bound]>, from unsettled: PerAxis<AxisSolution>) throws(ScriptError)
        -> PerAxis<AxisSolution> {
        var solution = unsettled
        var waiting = aligning
        while !waiting.isEmpty {
            // What settling each waiting box may move on its axis: the box, and every box placed
            // against it either way round (over free boxes only: the board never moves).
            var moves = PerAxis<[Int: [Bool]]>([:], [:])
            for axis in Axis.allCases {
                let on = Reach(bounds[axis], nodes: nodes), back = Reach(bounds[axis], nodes: nodes, reversed: true)
                for entry in waiting where entry.axis == axis && moves[axis][entry.box] == nil {
                    moves[axis][entry.box] = zip(on.reachable(from: node(entry.box)), back.reachable(from: node(entry.box))).map { $0 || $1 }
                }
            }
            let ready = waiting.indices.filter { index in
                let entry = waiting[index], targets = entry.targets.compactMap { $0.ref.freeIndex }.map(node)
                return !moves[entry.axis].contains { box, moved in box != entry.box && targets.contains { moved[$0] } }
            }
            let now = ready.isEmpty ? Array(waiting.indices) : ready
            try measure(now.map { waiting[$0] }, &bounds, solution)
            solution = try solveAll(bounds)
            waiting = waiting.indices.filter { !now.contains($0) }.map { waiting[$0] }
        }
        return solution
    }

    /// Measures each alignment against boxes that move apart on this solve and holds it there, unless
    /// what it aligns with is placed against it in turn (over free boxes only: the board never waits).
    func measure(_ aligning: [Pending], _ bounds: inout PerAxis<[Bound]>, _ solution: PerAxis<AxisSolution>) throws(ScriptError) {
        let reaches = PerAxis(Reach(bounds.x, nodes: nodes), Reach(bounds.y, nodes: nodes))
        var added = PerAxis<[Bound]>([], [])
        for entry in aligning {
            let axis = entry.axis, me = node(entry.box)
            for target in entry.targets {
                guard case .free(let other) = target.ref, reaches[axis].reaches(from: me, to: node(other), throughBoard: false) else { continue }
                let box = problem.free[entry.box]
                throw ScriptError(line: box.line, reason: .circular,
                                  "\(box.name) is \(box.clauses[entry.clause].written), but \(name(target.ref)) is placed \(axis.adverb) against \(box.name) in turn, so neither can wait for the other",
                                  hint: "place one of them against something else")
            }
            let spans = entry.targets.map { span($0, axis) }
            guard spans.allSatisfy({ solution[axis].pos[$0.node] > -.infinity }) else { continue }
            let start = spans.map { solution[axis].pos[$0.node] + $0.start }.min()!
            let end = spans.map { solution[axis].pos[$0.node] + $0.start + $0.length }.max()!
            let anchorNode = spans[0].node
            let at = aligned(entry.side, start: start, length: end - start, own: placed[entry.box][axis])
            let why = Why.settled(box: entry.box, clause: entry.clause)
            added[axis].append(Bound(from: anchorNode, to: me, weight: at - solution[axis].pos[anchorNode], why: why))
            added[axis].append(Bound(from: me, to: anchorNode, weight: solution[axis].pos[anchorNode] - at, why: why))
        }
        bounds.x += added.x
        bounds.y += added.y
    }

    /// Each region alignment still holds once separation is done.
    func confirm(_ aligning: [Pending], _ solution: PerAxis<AxisSolution>) throws(ScriptError) {
        for entry in aligning {
            let axis = entry.axis
            let spans = entry.targets.map { span($0, axis) }
            guard solution[axis].pos[node(entry.box)] > -.infinity, spans.allSatisfy({ solution[axis].pos[$0.node] > -.infinity }) else { continue }
            let start = spans.map { solution[axis].pos[$0.node] + $0.start }.min()!
            let end = spans.map { solution[axis].pos[$0.node] + $0.start + $0.length }.max()!
            let at = aligned(entry.side, start: start, length: end - start, own: placed[entry.box][axis])
            guard abs(at - solution[axis].pos[node(entry.box)]) > 0.5 else { continue }
            let box = problem.free[entry.box]
            throw ScriptError(line: box.line, reason: .noRoom,
                              "\(box.name) can't be \(box.clauses[entry.clause].written): keeping shapes clear of each other moved what it lines up with after that was measured",
                              hint: "place it against one shape instead")
        }
    }

    // MARK: Separation

    /// The first overlapping pair: free boxes in script order; for each, the free boxes after it,
    /// then the obstacles near it in stacking order. Pairs `inside`, `on` or `overlap: allow`
    /// exempts are skipped, and so is a zone (`isZone`): an obstacle the box already sat on, that
    /// holds a shape it's placed against, that it lands among other shapes on, or that holds the
    /// `view` it's placed against. An obstacle a restated box takes along is where that box takes it.
    func firstClash(_ boxes: [Int], _ solution: PerAxis<AxisSolution>, obstacles: Bool) -> Clash? {
        let placement = placement(solution)
        for (at, box) in boxes.enumerated() where !problem.free[box].overlapAllowed && isTied(box, solution) {
            let mine = rect(box, solution)
            for other in boxes[(at + 1)...] where !problem.free[other].overlapAllowed && isTied(other, solution) && !exemptPairs.contains(Pair(box, other)) {
                let theirs = rect(other, solution)
                if let overlap = overlap(mine, theirs) { return Clash(box: box, other: .free(other), otherRect: theirs, overlap: overlap) }
            }
            guard obstacles else { continue }
            for obstacle in self.obstacles(in: mine, placement) where !exemptObstacles[box].contains(obstacle.id) {
                guard let overlap = overlap(mine, obstacle.rect), !isZone(obstacle, for: box, placement) else { continue }
                return Clash(box: box, other: .obstacle(obstacle.id), otherRect: obstacle.rect, overlap: overlap, carrier: carrierOf[obstacle.id])
            }
        }
        return nil
    }

    func overlap(_ a: CGRect, _ b: CGRect) -> Overlap? {
        let x = min(a.maxX, b.maxX) - max(a.minX, b.minX), y = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        return x > Self.slack && y > Self.slack ? Overlap(x: x, y: y) : nil
    }

    /// Whether an obstacle is a zone for this box, a region it sits on rather than a shape in its
    /// way: one that wholly holds
    /// - (b) the box where it is now, a restated one's: the region it already sat on, however snug;
    /// - (a) a shape the box is placed against, and is at least `zoneArea` times that one's area (a
    ///   shape placed against one on a bigger one isn't overlapping the bigger one, but one only a
    ///   little bigger, a card a note was laid on, is a neighbor);
    /// - (c) the box where it lands and another shape, and is at least `zoneArea` times the box's
    ///   area: a container, which the box lands among what's in it;
    /// - (d) the `view` the box is placed against, or, for a box of the drawing with nothing to
    ///   hang on, the view it's drawn in: the region the user is zoomed into.
    /// What holds only the box where it lands is in its way, however big: a note or a card beside
    /// where a smaller shape lands, and a lone shape that's the whole board, for one placed inside
    /// `board`, would be covered without a word. Held by (a), (b) or (d), the box may hang over the
    /// zone's edge where it lands (the caller says so). A shape held is a board shape where it is,
    /// or a free box the zone counts (`counted(by:in:)`), where `placement` says. For a box whose
    /// holder it goes in directly (`Holder.direct`), nothing wholly within the holder is a zone.
    func isZone(_ zone: LayoutProblem.Obstacle, for box: Int, _ placement: Placement) -> Bool {
        isZone(zone, for: box, placement, among: true) { counted(by: zone, in: placement)[$0] }
    }

    /// `isZone`, counting as held the free boxes `counts` says; with `among` false, landing among
    /// board shapes only, for (c).
    func isZone(_ zone: LayoutProblem.Obstacle, for box: Int, _ placement: Placement, among: Bool, counts: (Int) -> Bool) -> Bool {
        let free = problem.free[box]
        // A box that goes in its holder itself: what the holder holds is in its way, never under it.
        if let holder = free.holder, holder.direct, let held = rect(of: holder.ref, placement), holds(held, zone.rect) { return false }
        // Where it sat: the zone held it before anything moved, wherever a box takes the zone.
        if let current = free.current, holds(unmoved(zone, placement), current) { return true }
        if inDrawing[box], let view = problem.view, holds(zone.rect, view) { return true }
        for clause in free.clauses {
            for target in clause.targets {
                switch target.ref {
                case .free(let other):
                    if let theirs = placement.rects[other], holds(zone.rect, theirs, times: Self.zoneArea), counts(other) { return true }
                case .fixed(let other):
                    let fixed = problem.fixed[other]
                    switch fixed.word {
                    case nil: if holds(zone.rect, fixed.rect, times: Self.zoneArea) { return true }
                    case .view?: if holds(zone.rect, fixed.rect) { return true }
                    case .board?: break
                    }
                case .obstacle: break
                }
            }
        }
        guard let mine = placement.rects[box], holds(zone.rect, mine, times: Self.zoneArea) else { return false }
        return holdsAnother(zone, placement) || among && (0..<count).contains { $0 != box && counts($0) }
    }

    /// The free boxes a zone counts as holding: those it wholly holds that are on it for a reason
    /// of their own, not because other free boxes are. That's one placed `inside` or `on` it; one
    /// it's a zone for by what's already there (where the box sat, a board shape it's placed
    /// against, the view, or the board shapes it lands among); and one placed against a box it
    /// counts, at twice that one's area. Worked out from the first two up, until nothing is added,
    /// so two new shapes can't put each other on an empty note, and the same boxes count whatever
    /// order they're asked in.
    func counted(by zone: LayoutProblem.Obstacle, in placement: Placement) -> [Bool] {
        if let known = placement.counted[zone.id] { return known }
        var counts = Array(repeating: false, count: count)
        let held = (0..<count).filter { box in placement.rects[box].map { holds(zone.rect, $0) } ?? false }
        var added = true
        while added {
            added = false
            for box in held where !counts[box] {
                guard exemptObstacles[box].contains(zone.id) || isZone(zone, for: box, placement, among: false, counts: { counts[$0] }) else { continue }
                counts[box] = true
                added = true
            }
        }
        placement.counted[zone.id] = counts
        return counts
    }

    /// Where a box a placement or a holder names is: a fixed box's rect, or a free box's where `placement`
    /// has it (nil while it's nowhere yet).
    func rect(of ref: LayoutProblem.Ref, _ placement: Placement) -> CGRect? {
        switch ref {
        case .fixed(let box): problem.fixed[box].rect
        case .free(let box): placement.rects[box]
        case .obstacle: nil
        }
    }

    /// Whether `outer` wholly holds `inner`, and is at least `times` its area.
    func holds(_ outer: CGRect, _ inner: CGRect, times: CGFloat = 0) -> Bool {
        outer.minX <= inner.minX + Self.slack && outer.minY <= inner.minY + Self.slack
            && outer.maxX >= inner.maxX - Self.slack && outer.maxY >= inner.maxY - Self.slack
            && outer.width * outer.height >= times * inner.width * inner.height
    }

    /// Whether an obstacle wholly holds another, where `placement` has them: worked out once for
    /// the run, or once for the placement while boxes take obstacles along, which move with each
    /// solve.
    func holdsAnother(_ obstacle: LayoutProblem.Obstacle, _ placement: Placement) -> Bool {
        let kept = carriers.isEmpty ? holders : placement.holders
        if let known = kept.known[obstacle.id] { return known }
        let found = obstacles(in: obstacle.rect, placement).contains { $0.id != obstacle.id && holds(obstacle.rect, $0.rect) }
        kept.known[obstacle.id] = found
        return found
    }

    /// Which way a free box can move on an axis to clear an obstacle: on, if it's against its lower
    /// bounds with room (or nothing) above; back, if it's at an upper bound; neither, if it's held.
    /// Its own placements hold it against the free boxes they name: a way that would drag one of
    /// them off where its placements put it (a box centered on one, or level with it) is closed.
    /// What's placed against it still follows it.
    enum Freedom { case after, before, held }

    func freedom(_ box: Int, _ axis: Axis, _ solution: PerAxis<AxisSolution>, _ bounds: PerAxis<[Bound]>) -> Freedom {
        let solved = solution[axis], at = node(box)
        /// Whether one of its placements has it as far that way as it goes from a free box it names.
        func dragging(on: Bool) -> Bool {
            bounds[axis].contains { bound in
                guard own(bound.why, box) != nil, on ? bound.from == at : bound.to == at else { return false }
                return (on ? bound.to : bound.from) != 0 && isTight(bound, solved)
            }
        }
        if solved.upper[at] { return dragging(on: false) ? .held : .before }
        if solved.hi[at] == .infinity || solved.hi[at] - solved.pos[at] > Self.slack { return dragging(on: true) ? .held : .after }
        return .held
    }

    func isHeld(_ box: Int, _ solution: PerAxis<AxisSolution>, _ bounds: PerAxis<[Bound]>) -> Bool {
        freedom(box, .x, solution, bounds) == .held && freedom(box, .y, solution, bounds) == .held
    }

    /// Of the axes a pair can be separated on, the one they overlap least on (x on a tie).
    func pick(_ axes: [Axis], _ overlap: Overlap) -> Axis? {
        axes.count == 2 ? (overlap.x <= overlap.y ? .x : .y) : axes.first
    }

    /// The bound that pushes a clashing pair apart, read off what's already said: never a guess.
    mutating func separate(_ clash: Clash, _ solution: PerAxis<AxisSolution>, _ bounds: PerAxis<[Bound]>)
        throws(ScriptError) -> (Axis, Bound) {
        let box = clash.box
        let key: PairKey = switch clash.other {
        case .free(let other): .free(Pair(box, other))
        case .obstacle(let id): .obstacle(box: box, id: id)
        case .fixed: .obstacle(box: box, id: -1)
        }
        guard separated.insert(key).inserted else {
            let free = problem.free[box]
            throw ScriptError(line: free.line, reason: .internal, "\(free.name) and \(name(clash.other)) overlap again after being moved apart")
        }
        let index = separations.count
        switch clash.other {
        case .free(let other):
            var orders = PerAxis<(before: Int, after: Int)?>(nil, nil)
            for axis in Axis.allCases { orders[axis] = order(box, other, axis, solution, Reach(bounds[axis], nodes: nodes)) }
            let axis: Axis, order: (before: Int, after: Int)
            if let ordered = pick(Axis.allCases.filter { orders[$0] != nil }, clash.overlap), let found = orders[ordered] {
                (axis, order) = (ordered, found)
            } else if let yielded = yielding(box, other, clash.overlap, solution, bounds) {
                (axis, order) = yielded
            } else {
                throw unordered(box, other, solution, bounds)
            }
            separations.append(Separation(box: box, other: .free(other), axis: axis))
            let weight = problem.free[order.before].size[axis] + clearance(axis)
            return (axis, Bound(from: node(order.before), to: node(order.after), weight: weight, why: .separation(index)))
        case .obstacle, .fixed:
            let freedoms = PerAxis(freedom(box, .x, solution, bounds), freedom(box, .y, solution, bounds))
            guard let axis = pick(Axis.allCases.filter { freedoms[$0] != .held }, clash.overlap) else {
                // Wholly on a shape at least twice its size, it would sit on it, if that one held
                // anything that counts.
                let region = holds(clash.otherRect, rect(box, solution), times: Self.zoneArea) ? clash.otherRect : nil
                throw held(box, clash.other, region: region, placement(solution))
            }
            separations.append(Separation(box: box, other: clash.other, axis: axis))
            // Kept clear of the board, or of what a box takes along as part of that box, so it
            // follows if that box moves on.
            let anchor = clash.carrier.map(node) ?? 0
            let start = clash.otherRect.origin[axis] - solution[axis].pos[anchor]
            let bound = freedoms[axis] == .after
                ? Bound(from: anchor, to: node(box), weight: start + clash.otherRect.size[axis] + clearance(axis), why: .separation(index))
                : Bound(from: node(box), to: anchor, weight: problem.free[box].size[axis] + clearance(axis) - start, why: .separation(index))
            return (axis, bound)
        }
    }

    func clearance(_ axis: Axis) -> CGFloat {
        axis == .x ? LayoutProblem.horizontalClearance : LayoutProblem.verticalClearance
    }

    /// How a box the caller made up (`Free.implied`) gets out of the way of a free box that nothing
    /// orders it against: the later of two such boxes, or the one that is, goes past the other, on the
    /// axis it's free to go on that they overlap less on (`freedom`), the way its own placements
    /// leave it free to go. Nil if neither is implied, or the one that is can't move.
    func yielding(_ a: Int, _ b: Int, _ overlap: Overlap, _ solution: PerAxis<AxisSolution>, _ bounds: PerAxis<[Bound]>)
        -> (axis: Axis, order: (before: Int, after: Int))? {
        // `a` is the earlier of the two in script order.
        guard let mover = problem.free[b].implied ? b : problem.free[a].implied ? a : nil else { return nil }
        let anchor = mover == b ? a : b
        let freedoms = PerAxis(freedom(mover, .x, solution, bounds), freedom(mover, .y, solution, bounds))
        guard let axis = pick(Axis.allCases.filter { freedoms[$0] != .held }, overlap) else { return nil }
        return (axis, freedoms[axis] == .after ? (before: anchor, after: mover) : (before: mover, after: anchor))
    }

    /// Which of two free boxes the placements let the other move past on an axis: one reaches the
    /// other over the bounds and not back. An order only through the board counts only if it's the
    /// way round they already are, so two boxes are never flipped past each other.
    func order(_ a: Int, _ b: Int, _ axis: Axis, _ solution: PerAxis<AxisSolution>, _ reach: Reach) -> (before: Int, after: Int)? {
        let forward = reach.reaches(from: node(a), to: node(b), throughBoard: true)
        guard forward != reach.reaches(from: node(b), to: node(a), throughBoard: true) else { return nil }
        let (before, after) = forward ? (a, b) : (b, a)
        if !reach.reaches(from: node(before), to: node(after), throughBoard: false) {
            let middle = { (box: Int) in solution[axis].pos[self.node(box)] + self.problem.free[box].size[axis] / 2 }
            guard middle(before) <= middle(after) + Self.slack else { return nil }
        }
        return (before, after)
    }

    // MARK: Messages

    func name(_ ref: LayoutProblem.Ref) -> String {
        if case .free(let box) = ref { return problem.free[box].name }
        return problem.name(ref)
    }

    func unordered(_ a: Int, _ b: Int, _ solution: PerAxis<AxisSolution>, _ bounds: PerAxis<[Bound]>) -> ScriptError {
        if isHeld(a, solution, bounds) { return held(a, .free(b)) }
        if isHeld(b, solution, bounds) { return held(b, .free(a)) }
        let (earlier, later) = problem.free[a].line <= problem.free[b].line ? (a, b) : (b, a)
        return ScriptError(line: problem.free[later].line, reason: .unordered,
                           "\(problem.free[earlier].name) and \(problem.free[later].name) overlap, and nothing says which side of the other either one sits on",
                           hint: "place one against the other, or say overlap: allow")
    }

    /// A box that can't move off what it overlaps. `region`: where that is, when it holds the box
    /// at twice its area, and would be its zone if it held anything that counts. The hint then says
    /// what it does hold (nothing, or no shape wholly: one hangs over its edge), and offers placing
    /// the box elsewhere first, since the region may be a note whose words the box would cover; a
    /// first shape inside it is how to start it as a zone. What's around it is where `placement`
    /// has it.
    func held(_ box: Int, _ other: LayoutProblem.Ref, region: CGRect? = nil, _ placement: Placement? = nil) -> ScriptError {
        let free = problem.free[box]
        let where_ = free.clauses.isEmpty ? "stays where it is" : "is \(listed(free.clauses.map(\.written)))"
        var line = free.line
        if case .free(let other) = other { line = max(line, problem.free[other].line) }
        let named = name(other)
        var hint = "say overlap: allow, or place it elsewhere"
        if let region, let placement, case .obstacle(let id) = other {
            let partly = obstacles(in: region, placement).contains { $0.id != id && overlap(region, $0.rect) != nil && !holds($0.rect, region) }
            hint = "\(named) \(partly ? "holds no shape wholly yet" : "holds nothing yet"), so it's in the way: place it elsewhere, "
                + "or, if \(named) is meant to hold shapes, place a first one inside it"
        }
        return ScriptError(line: line, reason: .unordered, "\(free.name) \(where_) and can't move, but it overlaps \(named)", hint: hint)
    }

    /// A loop of bounds that can't all hold, in the script's words.
    func noRoom(_ loop: [Bound], _ bounds: [Bound], _ axis: Axis) -> ScriptError {
        // What each box on the loop says: its placements (quoted as written), and anything implicit.
        var subjects: [Int] = []
        var placements: [Int: [String]] = [:]
        var others: [Int: [String]] = [:]
        var apart: [Separation] = []
        func say(_ box: Int, placement: String? = nil, other: String? = nil) {
            if !subjects.contains(box) { subjects.append(box) }
            if let placement, !(placements[box]?.contains(placement) ?? false) { placements[box, default: []].append(placement) }
            if let other, !(others[box]?.contains(other) ?? false) { others[box, default: []].append(other) }
        }
        for bound in loop {
            switch bound.why {
            case .clause(let box, let clause), .centering(let box, let clause), .settled(let box, let clause):
                say(box, placement: problem.free[box].clauses[clause].written)
            case .keep(let box): say(box, other: "stays where it is \(axis.adverb)")
            case .list(let box, let after): say(box, other: "is listed under \(problem.free[after].name)")
            case .separation(let index): apart.append(separations[index])
            case .anchor: break
            }
        }
        /// `is right of "A" and left of "B"`, `stays where it is horizontally`.
        func described(_ box: Int) -> String? {
            let said = (placements[box].map { ["is \(listed($0))"] } ?? []) + (others[box] ?? [])
            return said.isEmpty ? nil : listed(said)
        }
        let lines = subjects.map { problem.free[$0].line } + apart.map { problem.free[$0.box].line }
        let line = lines.max() ?? problem.free.first?.line ?? 1
        var clear: [String] = []
        for separation in apart {
            for party in [LayoutProblem.Ref.free(separation.box), separation.other] where !(subjects.count == 1 && party == .free(subjects[0])) {
                let named = name(party)
                if !clear.contains(named) { clear.append(named) }
            }
        }
        let clearOf = clear.isEmpty ? "" : " clear of \(listed(clear))"
        let hint = apart.isEmpty ? "drop or change one of them, or ask for a smaller gap" : "place it elsewhere, or say overlap: allow"
        // One box that can't go where it says: every placement of its on this axis, as the design
        // quotes them (`"C" is right of "A" and left of "B"`), not only those on the loop.
        if subjects.count == 1 {
            let box = subjects[0]
            var clauses: [Int] = []
            for bound in bounds {
                switch bound.why {
                case .clause(box, let clause), .centering(box, let clause), .settled(box, let clause): if !clauses.contains(clause) { clauses.append(clause) }
                default: break
                }
            }
            placements[box] = clauses.sorted().map { problem.free[box].clauses[$0].written }
        }
        if subjects.count == 1, let said = described(subjects[0]) {
            let room = (placements[subjects[0]]?.count ?? 0) > 1 && others[subjects[0]] == nil ? "between them" : axis.adverb
            return ScriptError(line: line, reason: .noRoom, "\(problem.free[subjects[0]].name) \(said), and there's no room \(room)\(clearOf)", hint: hint)
        }
        let facts = subjects.compactMap { box in described(box).map { "\(problem.free[box].name) \($0)" } }
        if !facts.isEmpty {
            return ScriptError(line: line, reason: .noRoom, "\(listed(facts)) can't all hold: there's no room \(axis.adverb)\(clearOf)", hint: hint)
        }
        return ScriptError(line: line, reason: .noRoom, "these placements run in a circle \(axis.adverb) and can't all hold\(clearOf)", hint: hint)
    }

    // MARK: A drawing with nothing to hang on

    /// Where a drawing solved alone goes: its bounds' middle at the view's middle, or the nearest
    /// spot around it, on square rings `ringStep` apart (each ring nearest the middle first; then
    /// higher, then further left), where none of it (but what may overlap) comes within
    /// `anchorClearance` of an obstacle (but one that holds the whole view) or a box placed on the
    /// board. Past the last ring, right of everything, top-aligned with it. Returns how far to move
    /// it. The obstacles are where `placement` (the boxes placed on the board) has them: what a box
    /// in the drawing takes along goes with the drawing.
    func spot(for drawing: [(box: Int, rect: CGRect)], clearOf placed: [CGRect], among placement: Placement) -> CGPoint {
        let bounds = drawing.map(\.rect).reduce(CGRect.null) { $0.union($1) }
        let solid = drawing.filter { !problem.free[$0.box].overlapAllowed }.map(\.rect)
        let margin = LayoutProblem.anchorClearance, step = LayoutProblem.ringStep
        let reach = CGFloat(LayoutProblem.rings) * step + margin
        let region = CGRect(center: problem.viewMiddle, size: bounds.size).insetBy(dx: -reach, dy: -reach)
        // A region that holds the whole view isn't in the way: the drawing is drawn on it, as a
        // shape placed against the view is (`isZone`).
        let found = obstacles(in: region, placement).filter { obstacle in problem.view.map { !holds(obstacle.rect, $0) } ?? true }.map(\.rect)
        let middle = bounds.center
        let start = CGPoint(x: problem.viewMiddle.x - middle.x, y: problem.viewMiddle.y - middle.y)
        // A box moved to a spot takes it if, grown by the margin, it shares more than a sliver of
        // both axes with a shape: that is, if the move is strictly between two values on each axis,
        // so each box and shape rule out a rectangle of spots at once.
        var spots = Spots(rings: LayoutProblem.rings)
        for other in found + placed where other.isFinite && other.width > Self.slack && other.height > Self.slack {
            for box in solid {
                guard let i = spots.steps(after: other.minX - box.maxX - margin + Self.slack, before: other.maxX - box.minX + margin - Self.slack,
                                          from: start.x, step: step),
                      let j = spots.steps(after: other.minY - box.maxY - margin + Self.slack, before: other.maxY - box.minY + margin - Self.slack,
                                          from: start.y, step: step)
                else { continue }
                spots.take(i, j)
            }
        }
        let taken = spots.counted()
        for ring in 0...LayoutProblem.rings {
            for (i, j) in Self.ring(ring) where !taken(i, j) {
                return CGPoint(x: problem.viewMiddle.x + CGFloat(i) * step - middle.x, y: problem.viewMiddle.y + CGFloat(j) * step - middle.y)
            }
        }
        var board = problem.boardBounds ?? found.reduce(CGRect.null) { $0.union($1) }
        for rect in placed { board = board.union(rect) }
        guard !board.isNull else { return problem.viewMiddle - middle }
        return CGPoint(x: board.maxX + LayoutProblem.fallbackGap - bounds.minX, y: board.minY - bounds.minY)
    }

    /// The offsets on one square ring, in steps: ring 0 is the middle; ring k every point k steps
    /// out, nearest the middle first, then higher, then further left. A point k steps out one way
    /// and m the other is further out the larger m is, so they come m by m, never sorted all at
    /// once: the last rings are tried only when the view is crowded, and must cost no more then.
    static func ring(_ k: Int) -> [(Int, Int)] {
        guard k > 0 else { return [(0, 0)] }
        var points: [(Int, Int)] = []
        for m in 0...k {
            var alike: [(Int, Int)] = []
            for point in [(k, m), (k, -m), (-k, m), (-k, -m), (m, k), (-m, k), (m, -k), (-m, -k)] where !alike.contains(where: { $0 == point }) {
                alike.append(point)
            }
            points += alike.sorted { ($0.1, $0.0) < ($1.1, $1.0) }
        }
        return points
    }
}

extension LayoutProblem.Ref {
    var freeIndex: Int? {
        if case .free(let box) = self { box } else { nil }
    }
}

/// Which nodes reach which over one axis's bounds.
struct Reach {
    var next: [[Int]]

    /// Over the bounds as they go, or (`reversed`) back along them: which nodes reach each one.
    init(_ bounds: [Bound], nodes: Int, reversed: Bool = false) {
        next = Array(repeating: [], count: nodes)
        for bound in bounds {
            if reversed { next[bound.to].append(bound.from) } else { next[bound.from].append(bound.to) }
        }
    }

    /// Every node `start` reaches, itself included, with the board as a dead end.
    func reachable(from start: Int) -> [Bool] {
        var seen = Array(repeating: false, count: next.count)
        var stack = [start]
        seen[start] = true
        while let at = stack.popLast() {
            if at == 0 && at != start { continue }
            for node in next[at] where !seen[node] {
                seen[node] = true
                stack.append(node)
            }
        }
        return seen
    }

    /// Whether `to` is reachable from `from`; through the board, or with the board as a dead end.
    func reaches(from: Int, to: Int, throughBoard: Bool) -> Bool {
        var seen = Array(repeating: false, count: next.count)
        var stack = [from]
        seen[from] = true
        while let at = stack.popLast() {
            if at == 0 && !throughBoard && at != from { continue }
            for node in next[at] where !seen[node] {
                if node == to { return true }
                seen[node] = true
                stack.append(node)
            }
        }
        return false
    }
}

/// The spots a drawing with nothing to hang on may go, `rings` steps out from the middle each way,
/// and which of them something takes: each box and shape near it take a rectangle of spots,
/// marked at its corners and summed once (a difference array). So the search costs the pairs and
/// the spots, however big the shapes are or wherever they sit, and never counts past the rings.
struct Spots {
    let rings: Int
    /// The marks, a row of `side + 1` for each step down from (-rings, -rings): one more each way
    /// than there are spots, for the far corners of a rectangle that reaches the last ring.
    var marks: [Int]
    var side: Int { 2 * rings + 1 }

    init(rings: Int) {
        self.rings = rings
        marks = Array(repeating: 0, count: (2 * rings + 2) * (2 * rings + 2))
    }

    /// The steps k, from -rings to rings, for which `start + k × step` is strictly between `after`
    /// and `before`; nil if none is.
    func steps(after low: CGFloat, before high: CGFloat, from start: CGFloat, step: CGFloat) -> ClosedRange<Int>? {
        let first = ((low - start) / step).rounded(.down) + 1, last = ((high - start) / step).rounded(.up) - 1
        let limit = CGFloat(rings)
        guard !first.isNaN, !last.isNaN, first <= last, first <= limit, last >= -limit else { return nil }
        return Int(max(first, -limit))...Int(min(last, limit))
    }

    func index(_ i: Int, _ j: Int) -> Int { (j + rings) * (side + 1) + i + rings }

    /// Takes every spot from `i` across and `j` down.
    mutating func take(_ i: ClosedRange<Int>, _ j: ClosedRange<Int>) {
        marks[index(i.lowerBound, j.lowerBound)] += 1
        marks[index(i.upperBound + 1, j.lowerBound)] -= 1
        marks[index(i.lowerBound, j.upperBound + 1)] -= 1
        marks[index(i.upperBound + 1, j.upperBound + 1)] += 1
    }

    /// Whether a spot is taken, once every rectangle is marked.
    func counted() -> (Int, Int) -> Bool {
        var sums = marks
        let width = side + 1
        for j in 0..<width {
            for i in 0..<width {
                let at = j * width + i
                if i > 0 { sums[at] += sums[at - 1] }
                if j > 0 { sums[at] += sums[at - width] }
                if i > 0 && j > 0 { sums[at] -= sums[at - width - 1] }
            }
        }
        let rings = rings
        return { i, j in sums[(j + rings) * width + i + rings] > 0 }
    }
}

extension Direction {
    /// The axis a side direction goes along.
    var axis: Axis { horizontal != 0 ? .x : .y }
}

extension CGPoint {
    subscript(axis: Axis) -> CGFloat { axis == .x ? x : y }
}

extension CGSize {
    subscript(axis: Axis) -> CGFloat { axis == .x ? width : height }
}

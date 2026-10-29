/// A board's stack as a run of restacks leaves it, worked out over the stack the run began with and not by moving
/// anything in it: what a restack changes (the shapes either side of those it moves, and their keys) is kept apart, by
/// each shape's place in the stack as it was, and the rest is read from that stack. Keys rise up the stack, so the order
/// of two shapes is their keys'. A restack in a run costs the shapes it moves and those it looks at, never the shapes
/// between where they were and where they go, and the run changes the board once, at the end
/// (`CanvasDocument.restack(_:)`): what `Transaction`'s Bring to Front, Send to Back and steps of several shapes go
/// through, where moving each shape in the stack in turn cost each the shapes it passed, the board's square for a
/// board's worth.
struct StackReplay {
    /// The stack the run began with.
    let stack: ShapeStack
    /// The shape just above and just below each shape a restack moved or left beside another, by place in `stack`
    /// (-1 for none); every other shape's are the places either side of its own.
    private var aboveOf: [Int: Int] = [:], belowOf: [Int: Int] = [:]
    /// The keys the run gave, by place in `stack`: the shapes it restacked.
    private(set) var keyed: [Int: StackingKey] = [:]
    /// The bottom shape and the top one, by place in `stack`; nil for none.
    private(set) var bottom: Int?, top: Int?

    init(_ stack: ShapeStack) {
        self.stack = stack
        bottom = stack.isEmpty ? nil : 0
        top = stack.isEmpty ? nil : stack.count - 1
    }

    /// Where the shape is in the stack the run began with: how the run names it.
    func place(of id: ShapeID) -> Int? { stack.position(of: id) }

    func id(at place: Int) -> ShapeID { stack[place].id }

    func key(at place: Int) -> StackingKey? { keyed[place] ?? stack[place].stackingKey }

    /// The shape just above the one at `place`, as the run has left them.
    func above(_ place: Int) -> Int? {
        let above = aboveOf[place] ?? place + 1
        return above < 0 || above >= stack.count ? nil : above
    }

    /// The shape just below the one at `place`, as the run has left them.
    func below(_ place: Int) -> Int? {
        let below = belowOf[place] ?? place - 1
        return below < 0 ? nil : below
    }

    /// Whether the shape at `a` is below the one at `b`, as the run has left them: a key that doesn't compare is above.
    func isBelow(_ a: Int, _ b: Int) -> Bool {
        guard let low = key(at: a) else { return false }
        guard let high = key(at: b) else { return true }
        return low < high
    }

    /// The shapes at `places`, bottom to top.
    func sorted(_ places: [Int]) -> [Int] { places.sorted(by: isBelow) }

    /// Whether the shapes at `block` (bottom to top) are just above the one at `anchor`, one after another (at the
    /// bottom, for nil).
    func isBlock(_ block: [Int], justAbove anchor: Int?) -> Bool {
        var next: Int? = if let anchor { above(anchor) } else { bottom }
        for place in block {
            guard next == place else { return false }
            next = above(place)
        }
        return true
    }

    /// Moves the shapes at `block` (bottom to top), none of them the one at `anchor`, to just above it, or to the bottom
    /// for nil, in their order, each with its key in `keys`.
    mutating func move(_ block: [Int], above anchor: Int?, keys: [StackingKey]) {
        for place in block { unlink(place) }
        var after = anchor
        for (place, key) in zip(block, keys) {
            link(place, above: after)
            keyed[place] = key
            after = place
        }
    }

    private mutating func unlink(_ place: Int) {
        let above = above(place), below = below(place)
        if let below { aboveOf[below] = above ?? -1 } else { bottom = above }
        if let above { belowOf[above] = below ?? -1 } else { top = below }
    }

    private mutating func link(_ place: Int, above anchor: Int?) {
        let next: Int? = if let anchor { above(anchor) } else { bottom }
        if let anchor { aboveOf[anchor] = place } else { bottom = place }
        belowOf[place] = anchor ?? -1
        aboveOf[place] = next ?? -1
        if let next { belowOf[next] = place } else { top = place }
    }
}

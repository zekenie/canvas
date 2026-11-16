import Canvas

/// A breadth-first walk of a graph, a layer at a time: the one transitive walk the engine has, which
/// `:downstream-of` and `:upstream-of` (every shape a path of one edge or more reaches) and a reach
/// (`QueryState.reaches(_:)`, which asks what each shape's hop, ways and share are) both go by. The
/// caller says what a shape steps to (an edge read off the snapshot, or a step query evaluated bound
/// to the shape: the walk is async-free, so a caller that awaits drives it), and the walk keeps what
/// was met: each shape's **hop** is its shortest distance from the starts (they are at hop 0), and
/// a shape is never met twice, so a cycle ends where it began.
///
/// With `tracksShares` it also keeps, for what a reach lights, each shape's **ways** (the distinct
/// shapes of the layer before that step to it) and **share**: 1 at hop 1, and past it the sum, over
/// its ways in, of their share divided by how many shapes of the next layer each steps to, so what
/// reaches a shape divides among what it reaches and adds up where paths meet. What a walk that
/// only wants the shapes met leaves untracked costs it nothing.
struct LayeredWalk {
    /// The shortest distance from the starts of every shape met, the starts at 0.
    private(set) var hop: [ShapeID: Int] = [:]
    /// The shapes met, in the order they were, nearest layer first; the starts are not among them.
    /// Only when tracking shares.
    private(set) var order: [ShapeID] = []
    /// How many distinct shapes of the layer before step to each shape met. Only when tracking shares.
    private(set) var ways: [ShapeID: Int] = [:]
    /// Each shape's share (the starts' is 1). Only when tracking shares.
    private(set) var share: [ShapeID: Double] = [:]
    /// The layer being stepped from: the shapes first met in the layer before.
    private(set) var frontier: [ShapeID]
    /// The hop the shapes met from `frontier` get.
    private(set) var layer = 1
    private let tracksShares: Bool
    private var next: [ShapeID] = []
    private var children: [ShapeID] = []

    init(starts: some Sequence<ShapeID>, tracksShares: Bool = false) {
        self.tracksShares = tracksShares
        frontier = Array(starts)
        for start in frontier {
            hop[start] = 0
            if tracksShares { share[start] = 1 }
        }
    }

    /// Notes that a shape of `frontier` steps to `shape`, for a walk that tracks nothing: met for
    /// the first time (hop `layer`), or not. Whether it is new.
    @discardableResult
    mutating func meet(_ shape: ShapeID) -> Bool {
        guard hop.updateValue(layer, forKey: shape) == nil else { return false }
        next.append(shape)
        return true
    }

    /// Notes that `from`, a shape of `frontier`, steps to all of `shapes`. A shape met before the
    /// layer (an earlier one, or the starts) is left as it is, as is one of `from`'s own layer.
    mutating func meet(_ shapes: some Sequence<ShapeID>, from: ShapeID) {
        children.removeAll(keepingCapacity: true)
        for shape in shapes {
            switch hop[shape] {
            case nil:
                hop[shape] = layer
                order.append(shape)
                next.append(shape)
                ways[shape] = 1
                children.append(shape)
            case layer?:
                ways[shape, default: 0] += 1
                children.append(shape)
            default:
                break
            }
        }
        guard !children.isEmpty else { return }
        // The start's share goes whole to each direct neighbor; past it, a shape's divides among what it steps to.
        let passed = layer == 1 ? 1 : (share[from] ?? 0) / Double(children.count)
        for shape in children { share[shape, default: 0] += passed }
    }

    /// Moves to the next layer: what was met is stepped from. False when nothing was.
    mutating func advance() -> Bool {
        frontier = next
        next.removeAll(keepingCapacity: true)
        layer += 1
        return !frontier.isEmpty
    }
}

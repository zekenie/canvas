// Order: where one of a set of things goes among the others shown with it (a tab among a shape's tabs,
// a group in a menu, an adornment in its place, a section of a menu in the menu bar and an item in its
// section), said beside the others rather than by a number. A thing says it goes first, last, or right
// before or after another it can name; one that says nothing goes where it first appears. Each point
// that orders things declares the protocol its things adopt and gives `Order` the sugar that names
// them, so a tab can only be placed beside a tab.

/// Where a thing goes among the others it's shown with: a requirement of the protocol that makes the
/// things (`DetailTab`, `MenuGroup`, `Adornment`, `MenuBarSection`), `Order<Self>`, defaulting to
/// `.natural`; and a menu bar item's place in its section, an `Order<CanvasCommand>`, which names the
/// item that runs a command (`.after(.paste)`).
///
///     extension TypeSchemaTab: DetailTab {
///         public static var title: String { "Schema" }
///         public static var order: Order<Self> { .after(NeighborsTab.self) }
///     }
///
/// Whatever orders them (`OrderRule.arranged(_:by:)`) starts from the order they first appear in (the
/// kind's own first, then the rest in plugin order), puts the first ones before the rest and the last
/// ones after, and puts one placed before or after another right beside it. One placed beside another
/// that isn't among them goes where that one's own order would put it. A thing can name only what its
/// module can import, so two that don't know each other are ordered by where they first appear.
public struct Order<Subject>: Sendable, CustomStringConvertible {
    /// What it says, without the type: how it's kept, compared and reported.
    public let rule: OrderRule

    /// For the sugar that names the things a point orders (`.after(NeighborsTab.self)`).
    public init(_ rule: OrderRule) { self.rule = rule }

    /// Where it first appears among the others: the default.
    public static var natural: Self { Self(.natural) }
    /// Before everything that isn't first: a kind's own items, ahead of every feature's.
    public static var first: Self { Self(.first) }
    /// After everything that isn't last: what every kind shares, or a state that comes and goes,
    /// so the rest keep their places.
    public static var last: Self { Self(.last) }

    public var description: String { rule.description }
}

/// An order without its thing's type: as a point keeps it, the resolver reads it and the report says it.
public enum OrderRule: Hashable, Sendable, CustomStringConvertible {
    case natural
    case first
    case last
    /// Right before the thing named.
    case before(OrderAnchor)
    /// Right after the thing named.
    case after(OrderAnchor)

    /// The thing it's placed beside, if any.
    public var anchor: OrderAnchor? {
        switch self {
        case .before(let anchor), .after(let anchor): anchor
        case .natural, .first, .last: nil
        }
    }

    /// As the registry's report says it: nothing for the default, "last", "after Connections".
    public var description: String {
        switch self {
        case .natural: ""
        case .first: "first"
        case .last: "last"
        case .before(let anchor): "before \(anchor)"
        case .after(let anchor): "after \(anchor)"
        }
    }
}

/// A thing one is placed beside: its identity (a type, or the menu bar's item that runs a command), the
/// name the report gives it, and its own order, read only when it isn't among the things being ordered
/// (its module's plugin isn't installed, or it isn't shown here), to put it, and what's beside it, where
/// it would go.
public struct OrderAnchor: Hashable, Sendable, CustomStringConvertible {
    let id: ID
    public let name: String
    let rule: @Sendable () -> OrderRule

    enum ID: Hashable, Sendable {
        case type(ObjectIdentifier)
        case command(CanvasCommand)
    }

    /// `rule` is the anchor type's own order, read lazily: two that name each other would otherwise
    /// read each other's forever, and the registry refuses them by following these.
    public init(_ type: Any.Type, name: String, rule: @escaping @Sendable () -> OrderRule) {
        id = .type(ObjectIdentifier(type))
        self.name = name
        self.rule = rule
    }

    /// The menu bar's item that runs `command`, a command's own or one of the window's (Edit › Paste,
    /// which runs the command answering `.paste`). Its own place is its command's declaration, which
    /// an anchor doesn't carry: one placed beside it where it isn't goes where an item that says nothing
    /// would, and the registry, which has the declarations, follows them to refuse a circle.
    public init(_ command: CanvasCommand) {
        id = .command(command)
        name = command.rawValue
        rule = { .natural }
    }

    public static func == (lhs: OrderAnchor, rhs: OrderAnchor) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    public var description: String { name }
}

extension OrderRule {
    /// `items` (in the order they first appear) arranged by each one's anchor (its own identity, as
    /// another would name it; nil for one nothing can name, a menu bar item that runs no command) and
    /// order: the first ones, then those that say nothing, then the last ones, each with those placed
    /// right before it ahead of it and those placed right after it behind it, nearest first in the order
    /// they appear, and so on down. One placed beside a thing that isn't in `items` goes where that
    /// thing's own order puts it, after every thing of its kind that is (it has no turn of its own).
    /// Every item comes out once (two of one thing together, where the first is): those caught in a
    /// cycle, which the registry refuses where it can see one, come last, as they appear.
    public static func arranged<Item>(_ items: [Item], by place: (Item) -> (anchor: OrderAnchor?, rule: OrderRule)) -> [Item] {
        guard items.count > 1 else { return items }
        var nodes: [(anchor: OrderAnchor?, rule: OrderRule, items: [Int])] = []
        var index: [OrderAnchor: Int] = [:]
        for (offset, item) in items.enumerated() {
            let (anchor, rule) = place(item)
            if let anchor, let node = index[anchor] {
                nodes[node].items.append(offset)
            } else {
                if let anchor { index[anchor] = nodes.count }
                nodes.append((anchor, rule, [offset]))
            }
        }
        // The things named that aren't here, and those they're placed beside in turn, each where its own
        // order puts it.
        var next = 0
        while next < nodes.count {
            if let missing = nodes[next].rule.anchor, index[missing] == nil {
                index[missing] = nodes.count
                nodes.append((missing, missing.rule(), []))
            }
            next += 1
        }
        var before = [[Int]](repeating: [], count: nodes.count)
        var after = [[Int]](repeating: [], count: nodes.count)
        var firsts: [Int] = [], naturals: [Int] = [], lasts: [Int] = []
        for (node, entry) in nodes.enumerated() {
            switch entry.rule {
            case .before(let anchor) where index[anchor] != node: before[index[anchor]!].append(node)
            case .after(let anchor) where index[anchor] != node: after[index[anchor]!].append(node)
            case .first: firsts.append(node)
            case .last: lasts.append(node)
            default: naturals.append(node)
            }
        }
        var placed = [Bool](repeating: false, count: nodes.count)
        var order: [Int] = []
        order.reserveCapacity(items.count)
        func emit(_ node: Int) {
            guard !placed[node] else { return }
            placed[node] = true
            for earlier in before[node] { emit(earlier) }
            order += nodes[node].items
            for later in after[node] { emit(later) }
        }
        for node in firsts + naturals + lasts { emit(node) }
        for node in nodes.indices where !placed[node] { emit(node) }
        return order.map { items[$0] }
    }

    /// The first cycle of things placed beside each other, following each one's order from `anchors`
    /// through whatever they name, as "A after B, B after A"; nil when there's none. What a point's
    /// `check` refuses a plugin list with. Each one's order is its anchor's own unless `rule` says it
    /// (a menu bar item's, which is its command's declaration).
    public static func cycle(from anchors: [OrderAnchor], rule given: ((OrderAnchor) -> OrderRule)? = nil) -> String? {
        var done = Set<OrderAnchor>()
        for start in anchors where !done.contains(start) {
            var path: [OrderAnchor] = []
            var rules: [OrderRule] = []
            var current = start
            while !done.contains(current) {
                let rule = given?(current) ?? current.rule()
                if let loop = path.firstIndex(of: current) {
                    return zip(path[loop...], rules[loop...]).map { "\($0) \($1)" }.joined(separator: ", ")
                }
                path.append(current)
                rules.append(rule)
                guard let anchor = rule.anchor else { break }
                current = anchor
            }
            done.formUnion(path)
        }
        return nil
    }
}
